import AppKit
import Foundation
import Network
import SwiftUI
import DroplyCore

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "Все"
    case sent = "Отправка"
    case received = "Получение"

    var id: String { rawValue }
}

struct PendingConfirmation: Identifiable {
    let id = UUID()
    let message: String
    let confirmLabel: String
    let cancelLabel: String
    let isDestructive: Bool
    let isWarning: Bool
    let onConfirm: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    init(
        message: String,
        confirmLabel: String = "Да",
        cancelLabel: String = "Нет",
        isDestructive: Bool = false,
        isWarning: Bool = false,
        onConfirm: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void = {}
    ) {
        self.message = message
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.isDestructive = isDestructive
        self.isWarning = isWarning
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }
}

@MainActor
final class DroplyViewModel: ObservableObject {
    private enum PrefKey {
        static let isDarkTheme = "droply.isDarkTheme"
        static let deviceName = "droply.deviceName"
        static let destinationPath = "droply.destinationPath"
        static let overwriteExisting = "droply.overwriteExisting"
        static let requireIncomingConfirmation = "droply.requireIncomingConfirmation"
    }

    @Published var isDarkTheme: Bool = false {
        didSet { UserDefaults.standard.set(isDarkTheme, forKey: PrefKey.isDarkTheme) }
    }
    @Published var isListening: Bool = false
    @Published var hostIP: String = NetworkUtils.primaryWiFiIPv4()
    @Published var availableInterfaces: [LocalNetworkInterface] = NetworkUtils.activeIPv4Interfaces()
    @Published var port: UInt16 = DroplyProtocol.defaultPort
    @Published var sessionToken: String = ""
    @Published var qrImage: NSImage?
    @Published var connectedDeviceName: String?
    @Published var connectedRemoteIP: String?
    @Published var activeProgress: TransferProgressSnapshot?
    @Published var isTransferring: Bool = false
    @Published var receivedFiles: [ReceivedFileRecord] = []
    @Published var historyFilter: HistoryFilter = .all
    @Published var statusBanner: String? {
        didSet { handleBannerChange(kind: .success, oldValue: oldValue, newValue: statusBanner) }
    }
    @Published var warningBanner: String? {
        didSet { handleBannerChange(kind: .warning, oldValue: oldValue, newValue: warningBanner) }
    }
    @Published var errorBanner: String? {
        didSet { handleBannerChange(kind: .error, oldValue: oldValue, newValue: errorBanner) }
    }
    @Published var destinationFolder: URL {
        didSet { UserDefaults.standard.set(destinationFolder.path, forKey: PrefKey.destinationPath) }
    }
    @Published var overwriteExisting: Bool = false {
        didSet { UserDefaults.standard.set(overwriteExisting, forKey: PrefKey.overwriteExisting) }
    }
    @Published var requireIncomingConfirmation: Bool = true {
        didSet { UserDefaults.standard.set(requireIncomingConfirmation, forKey: PrefKey.requireIncomingConfirmation) }
    }
    @Published var deviceName: String = "" {
        didSet { UserDefaults.standard.set(deviceName, forKey: PrefKey.deviceName) }
    }
    @Published var pendingConfirmation: PendingConfirmation?
    @Published var showTextComposer: Bool = false
    @Published var showSettings: Bool = false
    @Published var availableUpdate: AppUpdateInfo?
    @Published var showUpdatePrompt: Bool = false
    @Published var isCheckingForUpdates: Bool = false
    @Published var titlebarHeight: CGFloat = 32
    var themeButtonCenter: CGPoint?

    private var server: DroplyServer?
    private let pathMonitor = NWPathMonitor()
    private var activePairingRequestId: String?
    private let historyFileURL: URL
    private let backgroundController = BackgroundTransferController()
    private var lastUpdateCheckDate: Date?
    private var lastPromptedUpdateVersion: String?
    private var updateMonitorTask: Task<Void, Never>?
    private var bannerDismissTask: Task<Void, Never>?
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?
    private var isUpdatingBanner = false

    var onRequestShowMainWindow: (@MainActor () -> Void)?
    var onStatusChange: (@MainActor () -> Void)?
    var onRequestThemeToggle: (@MainActor () -> Void)?
    var onUpdateFound: (@MainActor (AppUpdateInfo) -> Void)?
    var onPresentBannerToast: (@MainActor (_ text: String, _ kind: BannerToastKind) -> Void)?
    var onDismissBannerToast: (@MainActor () -> Void)?

    var currentAppVersionLabel: String {
        AppUpdateChecker.displayVersionLabel(AppUpdateChecker.currentAppVersion())
    }

    var shouldKeepAliveInBackground: Bool {
        isTransferring || connectedDeviceName != nil
    }

    var filteredHistory: [ReceivedFileRecord] {
        switch historyFilter {
        case .all:
            return receivedFiles
        case .sent:
            return receivedFiles.filter { !$0.isIncoming }
        case .received:
            return receivedFiles.filter { $0.isIncoming }
        }
    }

    var sentHistoryCount: Int {
        receivedFiles.filter { !$0.isIncoming }.count
    }

    var receivedHistoryCount: Int {
        receivedFiles.filter { $0.isIncoming }.count
    }

    init() {
        let defaults = UserDefaults.standard
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let defaultDir = downloads.appendingPathComponent("Droply", isDirectory: true)
        try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)

        var resolvedDir = defaultDir
        if let savedPath = defaults.string(forKey: PrefKey.destinationPath),
           !savedPath.isEmpty,
           FileManager.default.fileExists(atPath: savedPath) {
            resolvedDir = URL(fileURLWithPath: savedPath, isDirectory: true)
        }
        self.destinationFolder = resolvedDir
        self.isDarkTheme = defaults.bool(forKey: PrefKey.isDarkTheme)
        self.overwriteExisting = defaults.bool(forKey: PrefKey.overwriteExisting)
        if defaults.object(forKey: PrefKey.requireIncomingConfirmation) != nil {
            self.requireIncomingConfirmation = defaults.bool(forKey: PrefKey.requireIncomingConfirmation)
        } else {
            self.requireIncomingConfirmation = true
        }
        let defaultHostName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = (defaultHostName?.isEmpty == false ? defaultHostName! : "MacBook")
        let savedName = defaults.string(forKey: PrefKey.deviceName)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.deviceName = (savedName?.isEmpty == false ? savedName! : fallbackName)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dataDir = appSupport.appendingPathComponent("Droply", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dataDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: dataDir.path)
        let targetHistoryURL = dataDir.appendingPathComponent("history.json")
        let legacyHistoryURL = appSupport
            .appendingPathComponent("WiFiDrop", isDirectory: true)
            .appendingPathComponent("history.json")
        if !FileManager.default.fileExists(atPath: targetHistoryURL.path),
           FileManager.default.fileExists(atPath: legacyHistoryURL.path) {
            try? FileManager.default.copyItem(at: legacyHistoryURL, to: targetHistoryURL)
        }
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: targetHistoryURL.path)
        self.historyFileURL = targetHistoryURL

        loadHistory()
        startServer()
        startNetworkMonitor()
        startWakeObserver()
        syncBackgroundActivity()
        startUpdateMonitor()
        checkForUpdates(userInitiated: false)
    }

    deinit {
        pathMonitor.cancel()
        updateMonitorTask?.cancel()
        bannerDismissTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func toggleTheme() {
        if let onRequestThemeToggle {
            onRequestThemeToggle()
        } else {
            isDarkTheme.toggle()
        }
    }

    func shutdown() {
        pathMonitor.cancel()
        updateMonitorTask?.cancel()
        updateMonitorTask = nil
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        onDismissBannerToast?()
        server?.stop()
        backgroundController.shutdown()
    }

    func dismissAllBanners() {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        guard statusBanner != nil || warningBanner != nil || errorBanner != nil else {
            onDismissBannerToast?()
            return
        }
        isUpdatingBanner = true
        statusBanner = nil
        warningBanner = nil
        errorBanner = nil
        isUpdatingBanner = false
        onDismissBannerToast?()
    }

    private func handleBannerChange(kind: BannerToastKind, oldValue: String?, newValue: String?) {
        guard !isUpdatingBanner else { return }
        if newValue == nil && oldValue == nil { return }

        if let text = newValue {
            isUpdatingBanner = true
            switch kind {
            case .success:
                if warningBanner != nil { warningBanner = nil }
                if errorBanner != nil { errorBanner = nil }
            case .warning:
                if statusBanner != nil { statusBanner = nil }
                if errorBanner != nil { errorBanner = nil }
            case .error:
                if statusBanner != nil { statusBanner = nil }
                if warningBanner != nil { warningBanner = nil }
            }
            isUpdatingBanner = false
            scheduleBannerAutoDismiss()
            onPresentBannerToast?(text, kind)
        } else if let error = errorBanner {
            scheduleBannerAutoDismiss()
            onPresentBannerToast?(error, .error)
        } else if let warning = warningBanner {
            scheduleBannerAutoDismiss()
            onPresentBannerToast?(warning, .warning)
        } else if let status = statusBanner {
            scheduleBannerAutoDismiss()
            onPresentBannerToast?(status, .success)
        } else {
            bannerDismissTask?.cancel()
            bannerDismissTask = nil
            onDismissBannerToast?()
        }
    }

    private func scheduleBannerAutoDismiss() {
        bannerDismissTask?.cancel()
        bannerDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.dismissAllBanners()
        }
    }

    private func syncBackgroundActivity() {
        backgroundController.update(
            isTransferring: isTransferring,
            isConnected: connectedDeviceName != nil,
            progress: activeProgress
        )
        onStatusChange?()
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyFileURL),
              let decoded = try? JSONDecoder().decode([ReceivedFileRecord].self, from: data) else {
            return
        }
        self.receivedFiles = decoded
    }

    private func saveHistory() {
        let snapshot = receivedFiles
        let url = historyFileURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
            }
        }
    }

    private func startWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshInterfacesIfNeeded()
                if self.server?.isRunning != true {
                    self.startServer()
                }
            }
        }
    }

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshInterfacesIfNeeded()
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func refreshInterfacesIfNeeded() {
        let updated = NetworkUtils.activeIPv4Interfaces()
        guard updated != availableInterfaces else { return }
        availableInterfaces = updated
        if !updated.contains(where: { $0.address == hostIP }) {
            hostIP = updated.first?.address ?? NetworkUtils.primaryWiFiIPv4()
        }
        rebuildQRCode()
    }

    func startServer() {
        let newServer = DroplyServer(
            destinationDirectory: destinationFolder,
            overwriteExisting: overwriteExisting,
            requireIncomingConfirmation: requireIncomingConfirmation,
            requirePairingConfirmation: true,
            deviceName: deviceName
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleServerEvent(event)
            }
        }
        self.server = newServer

        do {
            try newServer.start(port: DroplyProtocol.defaultPort)
        } catch {
            do {
                try newServer.start(port: 0)
            } catch {
                self.errorBanner = error.localizedDescription
            }
        }
    }

    func selectHostIP(_ ip: String) {
        hostIP = ip
        rebuildQRCode()
    }

    func updateOverwriteExisting(_ newValue: Bool) {
        overwriteExisting = newValue
        server?.updateOverwriteExisting(newValue)
    }

    func updateRequireIncomingConfirmation(_ newValue: Bool) {
        requireIncomingConfirmation = newValue
        server?.updateRequireIncomingConfirmation(newValue)
    }

    func updateDeviceName(_ rawName: String) {
        let trimmed = SecureChannel.sanitizeDisplayText(rawName)
        let defaultHostName = Host.current().localizedName.map { SecureChannel.sanitizeDisplayText($0) }
        let resolved = !trimmed.isEmpty ? trimmed : (defaultHostName?.isEmpty == false ? defaultHostName! : "MacBook")
        guard resolved != deviceName else { return }
        deviceName = resolved
        server?.updateDeviceName(resolved)
        rebuildQRCode()
    }

    func chooseDestinationFolderFromSettings() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать папку"
        panel.directoryURL = destinationFolder

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        destinationFolder = selectedURL
        server?.updateDestinationDirectory(selectedURL)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            statusBanner = "Папка сохранения обновлена"
        }
    }

    func requestRefreshQRCode() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            pendingConfirmation = PendingConfirmation(
                message: "Вы уверены, что хотите сгенерировать новый QR-код и сбросить текущее подключение?",
                isDestructive: true
            ) { [weak self] in
                guard let self else { return }
                self.availableInterfaces = NetworkUtils.activeIPv4Interfaces()
                if let primary = self.availableInterfaces.first {
                    self.hostIP = primary.address
                }
                self.server?.regenerateTokenAndDisconnectPeer()
            }
        }
    }

    func requestDisconnectPeer() {
        guard connectedDeviceName != nil else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            pendingConfirmation = PendingConfirmation(
                message: "Вы уверены, что хотите отключиться от устройства \(connectedDeviceName ?? "")?",
                isDestructive: true
            ) { [weak self] in
                self?.server?.disconnectCurrentPeer()
            }
        }
    }

    func requestCancelTransfer() {
        guard isTransferring else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            pendingConfirmation = PendingConfirmation(
                message: "Вы уверены, что хотите отменить текущую передачу файлов?",
                isDestructive: true
            ) { [weak self] in
                self?.server?.cancelCurrentTransfer()
            }
        }
    }

    func requestDeleteHistoryItem(_ item: ReceivedFileRecord) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            pendingConfirmation = PendingConfirmation(
                message: "Вы уверены, что хотите удалить «\(item.fileName)» из истории?",
                isDestructive: true
            ) { [weak self] in
                guard let self else { return }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                    self.receivedFiles.removeAll { $0.id == item.id }
                }
                self.saveHistory()
            }
        }
    }

    func requestClearHistory() {
        guard !receivedFiles.isEmpty else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            pendingConfirmation = PendingConfirmation(
                message: "Вы уверены, что хотите очистить всю историю файлов?",
                isDestructive: true
            ) { [weak self] in
                guard let self else { return }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                    self.receivedFiles.removeAll()
                }
                self.saveHistory()
            }
        }
    }

    func requestChooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать папку"
        panel.directoryURL = destinationFolder

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            pendingConfirmation = PendingConfirmation(
                message: "Вы уверены, что хотите изменить папку сохранения на «\(selectedURL.lastPathComponent)»?",
                isDestructive: false
            ) { [weak self] in
                guard let self else { return }
                self.destinationFolder = selectedURL
                self.server?.updateDestinationDirectory(selectedURL)
                self.statusBanner = "Папка сохранения обновлена"
            }
        }
    }

    func requestPickFilesToSend() {
        guard connectedDeviceName != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Выбрать"

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let items = MacFileCollector.collect(urls: panel.urls)
        confirmAndSend(items, label: "выбранные файлы")
    }

    func requestPickFolderToSend() {
        guard connectedDeviceName != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать папку"

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let items = MacFileCollector.collect(urls: panel.urls)
        confirmAndSend(items, label: "папку с файлами")
    }

    func requestSendTextNote(fileName: String, content: String) {
        let item = MacFileCollector.buildTextNote(fileName: fileName, content: content)
        confirmAndSend([item], label: "текстовый файл «\(item.relativePath)»")
    }

    func requestSendDroppedURLs(_ urls: [URL]) {
        guard connectedDeviceName != nil, !isTransferring, !urls.isEmpty else { return }
        let items = MacFileCollector.collect(urls: urls)
        guard !items.isEmpty else { return }
        let label = urls.count == 1 ? "«\(urls[0].lastPathComponent)»" : "выбранные объекты"
        confirmAndSend(items, label: label)
    }

    private func confirmAndSend(_ items: [MacSendItem], label: String) {
        guard !items.isEmpty, let peer = connectedDeviceName else { return }
        let total = items.reduce(UInt64(0)) { $0 &+ $1.sizeBytes }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            pendingConfirmation = PendingConfirmation(
                message: "Вы уверены, что хотите отправить \(label) (\(items.count) шт., \(NetworkUtils.formatBytes(total))) на \(peer)?",
                isDestructive: false
            ) { [weak self] in
                self?.server?.sendItems(items)
            }
        }
    }

    func copyTextItem(_ item: ReceivedFileRecord) {
        if let cached = item.textContent {
            copyToPasteboard(cached)
            return
        }
        let maxCopyBytes: UInt64 = 5 * 1024 * 1024
        guard item.size <= maxCopyBytes else {
            errorBanner = "Файл слишком большой для копирования целиком (> 5 МБ)"
            return
        }
        do {
            let data = try Data(contentsOf: item.savedURL)
            if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
                copyToPasteboard(text)
            } else {
                errorBanner = "Не удалось распознать кодировку текста"
            }
        } catch {
            errorBanner = "Не удалось прочитать файл: \(error.localizedDescription)"
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            errorBanner = nil
            warningBanner = nil
            statusBanner = "Текст скопирован в буфер обмена"
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openDestinationFolder() {
        NSWorkspace.shared.open(destinationFolder)
    }

    func checkForUpdates(userInitiated: Bool) {
        guard AppUpdateChecker.parseRepository(AppUpdateConfig.githubRepositoryURL) != nil else {
            if userInitiated {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    errorBanner = nil
                    warningBanner = nil
                    statusBanner = "Ссылка на GitHub ещё не настроена (версия \(currentAppVersionLabel))"
                }
            }
            return
        }

        if !userInitiated,
           let lastCheck = lastUpdateCheckDate,
           Date().timeIntervalSince(lastCheck) < 30 * 60 {
            return
        }

        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true

        Task { [weak self] in
            let outcome = await AppUpdateChecker.checkForUpdatesOutcome()
            await MainActor.run {
                guard let self else { return }
                self.isCheckingForUpdates = false
                switch outcome {
                case .updateAvailable(let info):
                    self.lastUpdateCheckDate = Date()
                    self.availableUpdate = info
                    self.onStatusChange?()
                    let signature = info.promptSignature
                    if userInitiated || self.lastPromptedUpdateVersion != signature {
                        self.lastPromptedUpdateVersion = signature
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                            self.showUpdatePrompt = true
                        }
                        self.onUpdateFound?(info)
                    }
                case .upToDate:
                    self.lastUpdateCheckDate = Date()
                    self.availableUpdate = nil
                    self.onStatusChange?()
                    if userInitiated {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                            self.errorBanner = nil
                            self.warningBanner = nil
                            self.statusBanner = "У вас установлена актуальная версия (\(self.currentAppVersionLabel))"
                        }
                    }
                case .notConfigured:
                    if userInitiated {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                            self.errorBanner = nil
                            self.warningBanner = nil
                            self.statusBanner = "Ссылка на GitHub ещё не настроена (версия \(self.currentAppVersionLabel))"
                        }
                    }
                case .networkFailed:
                    if userInitiated {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                            self.statusBanner = nil
                            self.warningBanner = nil
                            self.errorBanner = "Не удалось связаться с GitHub для проверки обновлений"
                        }
                    }
                }
            }
        }
    }

    func presentUpdatePrompt() {
        guard availableUpdate != nil else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            showUpdatePrompt = true
        }
    }

    func dismissUpdatePrompt() {
        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
            showUpdatePrompt = false
        }
    }

    func openUpdateOnGitHub() {
        guard let update = availableUpdate else { return }
        let safeURL: URL
        if let repo = AppUpdateChecker.parseRepository(AppUpdateConfig.githubRepositoryURL) {
            safeURL = AppUpdateChecker.validatedGitHubURL(update.releaseURL.absoluteString, repo: repo)
        } else {
            safeURL = update.releaseURL
        }
        NSWorkspace.shared.open(safeURL)
        dismissUpdatePrompt()
    }

    private func startUpdateMonitor() {
        updateMonitorTask?.cancel()
        updateMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 3600))
                guard !Task.isCancelled else { break }
                self?.checkForUpdates(userInitiated: false)
            }
        }
    }

    private func rebuildQRCode() {
        guard !sessionToken.isEmpty else { return }
        let allHosts = ([hostIP] + availableInterfaces.map(\.address))
            .reduce(into: [String]()) { acc, ip in
                if !acc.contains(ip) { acc.append(ip) }
            }
        let payload = QRPairingPayload(
            host: hostIP,
            hosts: allHosts,
            port: port,
            token: sessionToken,
            name: deviceName
        )
        if let json = try? payload.toJSONString() {
            qrImage = QRCodeRenderer.renderImage(from: json, size: 260)
        }
    }

    private func handleServerEvent(_ event: ServerEvent) {
        switch event {
        case .started(let host, let port, let token):
            self.availableInterfaces = NetworkUtils.activeIPv4Interfaces()
            self.hostIP = self.availableInterfaces.first?.address ?? host
            self.port = port
            self.sessionToken = token
            self.isListening = true
            self.errorBanner = nil
            rebuildQRCode()

        case .stopped:
            self.isListening = false
            self.isTransferring = false
            self.activeProgress = nil
            self.connectedDeviceName = nil
            self.connectedRemoteIP = nil
            syncBackgroundActivity()

        case .incomingPairingRequest(let req):
            onRequestShowMainWindow?()
            NSApp.activate(ignoringOtherApps: true)
            self.activePairingRequestId = req.requestId
            withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                self.pendingConfirmation = PendingConfirmation(
                    message: "Внимание! Совершается подключение по QR-коду с устройства «\(req.deviceName)» (\(req.remoteIP)). Разрешить подключение?",
                    confirmLabel: "Да",
                    cancelLabel: "Нет",
                    isDestructive: false,
                    isWarning: true,
                    onConfirm: { [weak self] in
                        self?.activePairingRequestId = nil
                        self?.server?.respondToPairingRequest(requestId: req.requestId, accepted: true)
                    },
                    onCancel: { [weak self] in
                        self?.activePairingRequestId = nil
                        self?.server?.respondToPairingRequest(requestId: req.requestId, accepted: false)
                    }
                )
            }

        case .incomingPairingCancelled(let requestId):
            if activePairingRequestId == requestId {
                activePairingRequestId = nil
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                    self.pendingConfirmation = nil
                }
            }

        case .peerConnected(let deviceName, let remoteIP):
            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                self.connectedDeviceName = deviceName
                self.connectedRemoteIP = remoteIP
                self.errorBanner = nil
                self.statusBanner = nil
                self.warningBanner = "Внимание: выполнено подключение устройства «\(deviceName)» (\(remoteIP)) по Wi-Fi"
            }
            syncBackgroundActivity()

        case .peerDisconnected(let reason):
            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                self.connectedDeviceName = nil
                self.connectedRemoteIP = nil
                self.isTransferring = false
                self.activeProgress = nil
                self.warningBanner = nil
                if self.activePairingRequestId == nil {
                    self.pendingConfirmation = nil
                }
                if let reason {
                    self.statusBanner = reason
                }
            }
            syncBackgroundActivity()

        case .incomingBatchRequest(let request):
            onRequestShowMainWindow?()
            NSApp.activate(ignoringOtherApps: true)
            let desc: String
            if request.totalFiles == 1, let preview = request.previewName {
                let name = URL(fileURLWithPath: preview).lastPathComponent
                desc = "файл «\(name)» (\(NetworkUtils.formatBytes(request.totalBytes)))"
            } else {
                desc = "файлы (\(request.totalFiles) шт., \(NetworkUtils.formatBytes(request.totalBytes)))"
            }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                self.pendingConfirmation = PendingConfirmation(
                    message: "Получить \(desc) от устройства \(request.senderName)?",
                    confirmLabel: "Да",
                    cancelLabel: "Нет",
                    isDestructive: false,
                    onConfirm: { [weak self] in
                        self?.server?.respondToIncomingBatch(batchId: request.batchId, accepted: true)
                    },
                    onCancel: { [weak self] in
                        self?.server?.respondToIncomingBatch(batchId: request.batchId, accepted: false)
                    }
                )
            }

        case .awaitingPeerConfirmation(let deviceName, _, _):
            withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                self.warningBanner = nil
                self.statusBanner = "Ожидание подтверждения на \(deviceName)..."
            }

        case .batchStarted(_, let totalFiles, let totalBytes, let isIncoming):
            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                self.isTransferring = true
                self.errorBanner = nil
                self.statusBanner = nil
                self.warningBanner = nil
                self.activeProgress = TransferProgressSnapshot(
                    fileIndex: 0,
                    totalFiles: totalFiles,
                    currentFileName: isIncoming ? "Получение..." : "Отправка...",
                    fileBytesReceived: 0,
                    fileTotalBytes: totalBytes,
                    batchBytesReceived: 0,
                    batchTotalBytes: totalBytes,
                    percent: 0,
                    speedBytesPerSecond: 0,
                    isIncoming: isIncoming
                )
            }
            syncBackgroundActivity()

        case .fileStarted(let fileIndex, let totalFiles, let relativePath, let fileSize, _):
            let currentBatch = activeProgress?.batchBytesReceived ?? 0
            let totalBatch = activeProgress?.batchTotalBytes ?? fileSize
            let pct = totalBatch == 0 ? 0 : min(100.0, Double(currentBatch) * 100.0 / Double(totalBatch))
            self.activeProgress = TransferProgressSnapshot(
                fileIndex: fileIndex,
                totalFiles: totalFiles,
                currentFileName: URL(fileURLWithPath: relativePath).lastPathComponent,
                fileBytesReceived: 0,
                fileTotalBytes: fileSize,
                batchBytesReceived: currentBatch,
                batchTotalBytes: totalBatch,
                percent: pct,
                speedBytesPerSecond: activeProgress?.speedBytesPerSecond ?? 0,
                isIncoming: activeProgress?.isIncoming ?? true
            )
            syncBackgroundActivity()

        case .progress(let snapshot):
            self.activeProgress = snapshot
            syncBackgroundActivity()

        case .fileCompleted(let record):
            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                self.receivedFiles.insert(record, at: 0)
            }
            saveHistory()

        case .batchCompleted(_, let count, let isIncoming):
            withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                self.isTransferring = false
                self.activeProgress = nil
                self.statusBanner = isIncoming
                    ? "Передача завершена: получено файлов — \(count)"
                    : "Передача завершена: отправлено файлов — \(count)"
            }
            syncBackgroundActivity()
            if !NSApp.isActive {
                NSApp.requestUserAttention(.informationalRequest)
            }

        case .transferCancelled(let reason):
            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                self.isTransferring = false
                self.activeProgress = nil
                self.statusBanner = reason
            }
            syncBackgroundActivity()

        case .error(let message):
            withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                self.isTransferring = false
                self.activeProgress = nil
                self.errorBanner = message
            }
            syncBackgroundActivity()
        }
    }
}
