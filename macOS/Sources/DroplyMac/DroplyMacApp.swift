import AppKit
import QuartzCore
import SwiftUI
@preconcurrency import UserNotifications
import DroplyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private weak var viewModel: DroplyViewModel?
    private weak var mainWindow: NSWindow?
    private var openMainWindowAction: (() -> Void)?
    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?
    private var lastStatusTitle: String?
    private var lastStatusIconName: String?
    private var wasTransferring = false
    private var isPostTransferHold = false
    private var postTransferHoldTask: Task<Void, Never>?
    private var windowObservers: [NSObjectProtocol] = []
    private let toastController = FloatingToastController()
    private var activeThemeOverlay: NSView?
    private var themeTransitionToken: Int = 0
    private var notificationAuthorized = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        setupStatusItem()
        registerWindowObservers()
        configureUserNotificationsIfBundled()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        viewModel?.checkForUpdates(userInitiated: false)
    }

    func attach(
        viewModel: DroplyViewModel,
        window: NSWindow?,
        isDark: Bool,
        openMainWindow: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        if let window {
            self.mainWindow = window
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            let resolvedTitlebarHeight = window.standardWindowButton(.closeButton)?.superview?.frame.height ?? 32
            if resolvedTitlebarHeight >= 24, abs(viewModel.titlebarHeight - resolvedTitlebarHeight) > 0.5 {
                viewModel.titlebarHeight = resolvedTitlebarHeight
            }
            let desiredName: NSAppearance.Name = isDark ? .darkAqua : .aqua
            if window.appearance?.name != desiredName {
                window.appearance = NSAppearance(named: desiredName)
            }
        }
        toastController.updateTheme(isDark: isDark)
        statusPopover?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        self.openMainWindowAction = openMainWindow
        viewModel.onRequestShowMainWindow = { [weak self] in
            self?.showMainWindow()
        }
        viewModel.onStatusChange = { [weak self] in
            self?.updateStatusItemAppearance()
        }
        viewModel.onRequestThemeToggle = { [weak self] in
            self?.performSmoothThemeToggle()
        }
        viewModel.onUpdateFound = { [weak self] info in
            self?.notifyAboutUpdate(info)
        }
        viewModel.onPresentBannerToast = { [weak self] text, kind in
            self?.presentBannerToast(text: text, kind: kind)
        }
        viewModel.onDismissBannerToast = { [weak self] in
            self?.toastController.dismiss()
        }
        updateStatusItemAppearance()
    }

    private func performSmoothThemeToggle() {
        guard let viewModel else { return }
        let nextDark = !viewModel.isDarkTheme

        guard let window = resolvedMainWindow(),
              let themeFrame = window.contentView?.superview,
              let hostView = window.contentView else {
            viewModel.isDarkTheme = nextDark
            return
        }

        // Remove any previous overlay before capturing the current window state.
        activeThemeOverlay?.removeFromSuperview()
        activeThemeOverlay = nil

        // Capture the full-size NSHostingView (body + top titlebar strip + "Droply" title)
        // cleanly at 1x resolution (~1.5ms) with zero backdrop vibrancy mismatch.
        let bounds = hostView.bounds
        guard let bitmap = makeFastSnapshotBitmap(for: hostView, bounds: bounds) else {
            viewModel.isDarkTheme = nextDark
            return
        }
        hostView.cacheDisplay(in: bounds, to: bitmap)

        guard let cgImage = bitmap.cgImage else {
            viewModel.isDarkTheme = nextDark
            return
        }

        let overlay = ThemeSnapshotOverlayView(frame: hostView.frame)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.contents = cgImage
        overlay.layer?.contentsGravity = .resize

        // Non-flipped AppKit coordinates: originate the reveal directly from the theme
        // toggle button center and sweep radially across the whole window and titlebar.
        let origin = resolvedThemeRevealOrigin(in: bounds, viewModel: viewModel)
        let startPath = makeRevealCutoutPath(in: bounds, origin: origin, radius: 4)

        let maskLayer = CAShapeLayer()
        maskLayer.frame = bounds
        maskLayer.fillRule = .evenOdd
        maskLayer.fillColor = NSColor.black.cgColor
        maskLayer.path = startPath
        overlay.layer?.mask = maskLayer

        themeFrame.addSubview(overlay, positioned: .above, relativeTo: hostView)

        themeTransitionToken &+= 1
        let token = themeTransitionToken
        activeThemeOverlay = overlay

        // Flip AppKit appearance & SwiftUI palette together underneath the masked snapshot.
        window.appearance = NSAppearance(named: nextDark ? .darkAqua : .aqua)
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            viewModel.isDarkTheme = nextDark
        }
        hostView.layoutSubtreeIfNeeded()

        animateRadialThemeReveal(token: token, origin: origin)
    }

    private func resolvedThemeRevealOrigin(in bounds: CGRect, viewModel: DroplyViewModel) -> CGPoint {
        if let center = viewModel.themeButtonCenter {
            return CGPoint(
                x: min(max(center.x, bounds.minX), bounds.maxX),
                y: min(max(bounds.height - center.y, bounds.minY), bounds.maxY)
            )
        }
        return CGPoint(x: bounds.maxX - 64, y: bounds.maxY - 64)
    }

    private func makeFastSnapshotBitmap(for view: NSView, bounds: CGRect) -> NSBitmapImageRep? {
        let pixelsWide = max(1, Int(ceil(bounds.width)))
        let pixelsHigh = max(1, Int(ceil(bounds.height)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return view.bitmapImageRepForCachingDisplay(in: bounds)
        }
        rep.size = bounds.size
        return rep
    }

    private func animateRadialThemeReveal(token: Int, origin: CGPoint) {
        guard themeTransitionToken == token,
              let currentOverlay = activeThemeOverlay,
              let activeMask = currentOverlay.layer?.mask as? CAShapeLayer else {
            return
        }

        let bounds = currentOverlay.bounds
        let startPath = makeRevealCutoutPath(in: bounds, origin: origin, radius: 4)
        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.minX, y: bounds.maxY),
            CGPoint(x: bounds.maxX, y: bounds.maxY)
        ]
        let maxDistance = corners.map { hypot($0.x - origin.x, $0.y - origin.y) }.max()
            ?? hypot(bounds.width, bounds.height)
        let endPath = makeRevealCutoutPath(in: bounds, origin: origin, radius: maxDistance + 24)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, token] in
            Task { @MainActor in
                self?.cleanupThemeOverlay(matching: token)
            }
        }
        let pathAnim = CABasicAnimation(keyPath: "path")
        pathAnim.fromValue = startPath
        pathAnim.toValue = endPath
        pathAnim.duration = 0.48
        pathAnim.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.45, 0.22, 1.0)
        activeMask.path = endPath
        activeMask.add(pathAnim, forKey: "radialThemeReveal")
        CATransaction.commit()
    }

    private func makeRevealCutoutPath(in rect: CGRect, origin: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(rect.insetBy(dx: -48, dy: -48))
        let circleRect = CGRect(
            x: origin.x - radius,
            y: origin.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        path.addEllipse(in: circleRect)
        return path
    }

    private func cleanupThemeOverlay(matching token: Int) {
        guard themeTransitionToken == token else { return }
        activeThemeOverlay?.removeFromSuperview()
        activeThemeOverlay = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard let viewModel else { return true }
        return !viewModel.shouldKeepAliveInBackground
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
            return false
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel, viewModel.isTransferring else {
            return .terminateNow
        }
        showMainWindow()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Идёт передача файлов"
        alert.informativeText = "Если сейчас завершить Droply, текущая передача будет прервана."
        alert.addButton(withTitle: "Оставить работать")
        alert.addButton(withTitle: "Прервать и выйти")
        let response = alert.runModal()
        return response == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        postTransferHoldTask?.cancel()
        postTransferHoldTask = nil
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
        toastController.closeImmediately()
        statusPopover?.close()
        statusPopover = nil
        viewModel?.shutdown()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func showMainWindow() {
        statusPopover?.performClose(nil)
        if let window = resolvedMainWindow(), (window.isVisible || window.isMiniaturized) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?()
        }
        NSApp.activate(ignoringOtherApps: true)
        updateStatusItemAppearance()
    }

    private func resolvedMainWindow() -> NSWindow? {
        if let mainWindow, mainWindow.canBecomeMain {
            return mainWindow
        }
        return NSApp.windows.first { $0.canBecomeMain && $0.title == "Droply" }
    }

    private var hasVisibleMainWindow: Bool {
        if let window = resolvedMainWindow() {
            return window.isVisible && !window.isMiniaturized
        }
        return false
    }

    private func registerWindowObservers() {
        guard windowObservers.isEmpty else { return }
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateStatusItemAppearance()
                }
            }
            windowObservers.append(token)
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: "Droply")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            button.target = self
            button.action = #selector(toggleStatusPopover(_:))
        }
        item.isVisible = false
        statusItem = item
        updateStatusItemAppearance()
    }

    private func ensureStatusPopover() -> NSPopover {
        if let existing = statusPopover {
            return existing
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        statusPopover = popover
        return popover
    }

    private func refreshStatusPopoverContent() {
        guard let viewModel, let popover = statusPopover else { return }
        let rootView = MenuBarTransferPopoverView(
            viewModel: viewModel,
            isPostTransferHold: isPostTransferHold,
            onOpenApp: { [weak self] in
                self?.showMainWindow()
            },
            onOpenUpdate: { [weak self] in
                self?.showMainWindow()
                self?.viewModel?.presentUpdatePrompt()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
        if let controller = popover.contentViewController as? NSHostingController<MenuBarTransferPopoverView> {
            controller.rootView = rootView
        } else {
            let controller = NSHostingController(rootView: rootView)
            popover.contentViewController = controller
        }
    }

    private func schedulePostTransferHold() {
        postTransferHoldTask?.cancel()
        isPostTransferHold = true
        postTransferHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.isPostTransferHold = false
            self.updateStatusItemAppearance()
        }
    }

    private func updateStatusItemAppearance() {
        guard let item = statusItem, let button = item.button else { return }

        let currentlyTransferring = viewModel?.isTransferring ?? false
        if currentlyTransferring {
            if !wasTransferring {
                postTransferHoldTask?.cancel()
                postTransferHoldTask = nil
                isPostTransferHold = false
            }
        } else if wasTransferring {
            if viewModel?.errorBanner == nil {
                schedulePostTransferHold()
            } else {
                postTransferHoldTask?.cancel()
                postTransferHoldTask = nil
                isPostTransferHold = false
            }
        }
        wasTransferring = currentlyTransferring

        let isPopoverShown = statusPopover?.isShown == true
        let keepVisibleInBackground = (viewModel?.shouldKeepAliveInBackground == true) && !hasVisibleMainWindow
        let shouldShow = currentlyTransferring || isPostTransferHold || isPopoverShown || keepVisibleInBackground
        if item.isVisible != shouldShow {
            item.isVisible = shouldShow
        }

        let iconName: String
        let titleText: String
        let accessibilityText: String

        if currentlyTransferring, let progress = viewModel?.activeProgress {
            let pct = max(0, min(100, Int(progress.percent.rounded(.down))))
            iconName = progress.isIncoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
            titleText = " \(pct)%"
            let dir = progress.isIncoming ? "Получение" : "Отправка"
            accessibilityText = "Droply: \(dir) \(pct)%"
        } else if currentlyTransferring {
            iconName = "paperplane.fill"
            titleText = " 0%"
            accessibilityText = "Droply: передача файлов"
        } else if isPostTransferHold {
            iconName = "checkmark.circle.fill"
            titleText = " 100%"
            accessibilityText = "Droply: передача завершена"
        } else {
            iconName = "paperplane.fill"
            titleText = ""
            accessibilityText = "Droply"
        }

        if lastStatusIconName != iconName {
            lastStatusIconName = iconName
            let image = NSImage(systemSymbolName: iconName, accessibilityDescription: accessibilityText)
            image?.isTemplate = true
            button.image = image
        }

        if lastStatusTitle != titleText {
            lastStatusTitle = titleText
            button.title = titleText
        }

        button.toolTip = accessibilityText

        if let popover = statusPopover, popover.isShown {
            popover.appearance = NSAppearance(named: (viewModel?.isDarkTheme == true) ? .darkAqua : .aqua)
            refreshStatusPopoverContent()
        }
    }

    @objc private func toggleStatusPopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        if let popover = statusPopover, popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let viewModel else {
            showMainWindow()
            return
        }
        let popover = ensureStatusPopover()
        popover.appearance = NSAppearance(named: viewModel.isDarkTheme ? .darkAqua : .aqua)
        refreshStatusPopoverContent()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        updateStatusItemAppearance()
    }

    private func presentBannerToast(text: String, kind: BannerToastKind) {
        let preferredScreen = resolvedMainWindow()?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let isDark = viewModel?.isDarkTheme ?? false
        toastController.show(
            text: text,
            kind: kind,
            isDark: isDark,
            preferredScreen: preferredScreen,
            onOpenApp: { [weak self] in
                self?.showMainWindow()
            },
            onDismiss: { [weak self] in
                self?.viewModel?.dismissAllBanners()
            }
        )
    }

    private var isRunningAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private func configureUserNotificationsIfBundled() {
        guard isRunningAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                self?.notificationAuthorized = granted
            }
        }
    }

    private func notifyAboutUpdate(_ info: AppUpdateInfo) {
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
        guard isRunningAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [info] settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            guard allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = info.title ?? "Доступна новая версия Droply"
            content.subtitle = "Версия \(info.latestVersion)"
            content.body = info.releaseNotes ?? "Нажмите, чтобы перейти на GitHub и установить обновление."
            content.sound = .default
            content.userInfo = ["releaseURL": info.releaseURL.absoluteString]

            let request = UNNotificationRequest(
                identifier: "droply.update.\(info.latestVersion)",
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let releaseURLString = response.notification.request.content.userInfo["releaseURL"] as? String
        completionHandler()
        Task { @MainActor [weak self] in
            self?.showMainWindow()
            if let releaseURLString,
               let repo = AppUpdateChecker.parseRepository(AppUpdateConfig.githubRepositoryURL) {
                let safeURL = AppUpdateChecker.validatedGitHubURL(releaseURLString, repo: repo)
                NSWorkspace.shared.open(safeURL)
            } else {
                self?.viewModel?.presentUpdatePrompt()
            }
        }
    }
}

private struct WindowHookView: NSViewRepresentable {
    let isDarkTheme: Bool
    let onWindowResolved: (NSWindow?, Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = HookNSView()
        view.onWindowResolved = { window in
            onWindowResolved(window, isDarkTheme)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let hookView = nsView as? HookNSView {
            hookView.onWindowResolved = { window in
                onWindowResolved(window, isDarkTheme)
            }
            if hookView.window !== hookView.lastAttachedWindow {
                hookView.lastAttachedWindow = hookView.window
                DispatchQueue.main.async {
                    onWindowResolved(hookView.window, isDarkTheme)
                }
            }
        }
    }

    private final class HookNSView: NSView {
        var onWindowResolved: ((NSWindow?) -> Void)?
        weak var lastAttachedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            lastAttachedWindow = window
            onWindowResolved?(window)
        }
    }
}

private final class ThemeSnapshotOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@main
struct DroplyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = DroplyViewModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Droply", id: "main") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 820, minHeight: 592)
                .background(
                    WindowHookView(isDarkTheme: viewModel.isDarkTheme) { window, isDark in
                        appDelegate.attach(viewModel: viewModel, window: window, isDark: isDark) {
                            openWindow(id: "main")
                        }
                    }
                )
        }
        .windowStyle(.titleBar)
    }
}
