import SwiftUI
import UniformTypeIdentifiers
import DroplyCore

struct ContentView: View {
    @ObservedObject var viewModel: DroplyViewModel
    @Namespace private var filterNamespace
    @StateObject private var dropState = ToggleFlag()

    private var palette: ThemePalette {
        viewModel.isDarkTheme ? .dark : .light
    }

    private var canAcceptDrop: Bool {
        viewModel.connectedDeviceName != nil && !viewModel.isTransferring
    }

    var body: some View {
        VStack(spacing: 0) {
            titlebarStrip

            ZStack {
                ambientSurface

                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .padding(.bottom, 14)

                HStack(spacing: 18) {
                    pairingCard
                        .frame(width: 318)

                    historyCard
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 24)
                .padding(.top, 2)
                .padding(.bottom, viewModel.isTransferring ? 12 : 24)
                .frame(maxHeight: .infinity)

                if viewModel.isTransferring, let progress = viewModel.activeProgress {
                    bottomProgressBar(progress: progress)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.98)),
                            removal: .move(edge: .bottom).combined(with: .opacity)
                        ))
                }
            }

            if dropState.value && canAcceptDrop {
                dropTargetOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(30)
            }

            if viewModel.showTextComposer {
                MacTextComposerModal(
                    palette: palette,
                    isDark: viewModel.isDarkTheme,
                    onSend: { name, body in
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                            viewModel.showTextComposer = false
                        }
                        viewModel.requestSendTextNote(fileName: name, content: body)
                    },
                    onDismiss: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                            viewModel.showTextComposer = false
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(40)
            }

            if viewModel.showSettings {
                MacSettingsModal(
                    viewModel: viewModel,
                    palette: palette,
                    isDark: viewModel.isDarkTheme,
                    onDismiss: {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                            viewModel.showSettings = false
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(45)
            }

            if let confirmation = viewModel.pendingConfirmation {
                ConfirmationModalView(
                    confirmation: confirmation,
                    palette: palette,
                    isDark: viewModel.isDarkTheme,
                    onDismiss: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                            viewModel.pendingConfirmation = nil
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(50)
            }

            if viewModel.showUpdatePrompt, let update = viewModel.availableUpdate {
                UpdateAvailableModalView(
                    update: update,
                    palette: palette,
                    isDark: viewModel.isDarkTheme,
                    onInstall: { viewModel.openUpdateOnGitHub() },
                    onDismiss: { viewModel.dismissUpdatePrompt() }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(55)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: viewModel.connectedDeviceName != nil)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: viewModel.isTransferring)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: viewModel.availableUpdate != nil)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: viewModel.showUpdatePrompt)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: dropState.value)
        .onDrop(of: [.fileURL], isTargeted: $dropState.value) { providers in
            guard canAcceptDrop else { return false }
            handleFileDrop(providers: providers)
            return true
        }
        }
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(viewModel.isDarkTheme ? .dark : .light)
    }

    private var titlebarStrip: some View {
        VStack(spacing: 0) {
            ZStack {
                viewModel.isDarkTheme
                    ? Color(red: 0.132, green: 0.142, blue: 0.174)
                    : Color(red: 0.922, green: 0.925, blue: 0.937)

                Text("Droply")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        viewModel.isDarkTheme
                            ? Color.white.opacity(0.84)
                            : Color.black.opacity(0.76)
                    )
            }
            .frame(height: max(viewModel.titlebarHeight - 1, 27))

            Rectangle()
                .fill(viewModel.isDarkTheme ? Color.white.opacity(0.08) : Color.black.opacity(0.08))
                .frame(height: 1)
        }
        .allowsHitTesting(false)
    }

    private func handleFileDrop(providers: [NSItemProvider]) {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return }

        Task {
            var collectedURLs: [URL] = []
            for provider in fileProviders {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        if let data, let resolved = URL(dataRepresentation: data, relativeTo: nil) {
                            continuation.resume(returning: resolved)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
                if let url {
                    collectedURLs.append(url)
                }
            }
            if !collectedURLs.isEmpty {
                await MainActor.run {
                    viewModel.requestSendDroppedURLs(collectedURLs)
                }
            }
        }
    }

    private var ambientSurface: some View {
        ZStack {
            LinearGradient(
                colors: viewModel.isDarkTheme
                    ? [Color(red: 0.065, green: 0.072, blue: 0.095), Color(red: 0.095, green: 0.105, blue: 0.138)]
                    : [Color(red: 0.952, green: 0.962, blue: 0.984), Color(red: 0.978, green: 0.982, blue: 0.994)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    palette.accent.opacity(viewModel.isDarkTheme ? 0.08 : 0.06),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 560
            )
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 11) {
                ZStack {
                    Image(systemName: "wifi")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
                .frame(width: 34, height: 34)
                .modifier(FloatingGlassModifier(shape: RoundedRectangle(cornerRadius: 10, style: .continuous), tint: palette.accent.opacity(0.14), isDark: viewModel.isDarkTheme))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Droply")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.textPrimary)
                }
            }

            Spacer()

            if let update = viewModel.availableUpdate {
                Button {
                    viewModel.presentUpdatePrompt()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.accent)
                        Text("Обновить")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
                .modifier(
                    NativeGlassButtonModifier(
                        shape: .capsule,
                        isDark: viewModel.isDarkTheme,
                        tint: palette.accent
                    )
                )
                .foregroundStyle(palette.textPrimary)
                .help("Доступна версия \(update.latestVersion)")
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }

            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    viewModel.showSettings = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(width: 14, height: 14)
                    Text("Настройки")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }
            .modifier(NativeGlassButtonModifier(isDark: viewModel.isDarkTheme, tint: nil))
            .foregroundStyle(palette.textPrimary)
            .help("Открыть настройки")
        }
    }

    private var pairingCard: some View {
        VStack(spacing: 16) {
            if viewModel.connectedDeviceName != nil {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.green)

                    Text("Подключено: \(viewModel.connectedDeviceName ?? "")")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(palette.controlSurface.opacity(viewModel.isDarkTheme ? 0.75 : 0.9))
                )
                .transition(.opacity.combined(with: .move(edge: .top)))

                connectedHubContent
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Button {
                        viewModel.requestRefreshQRCode()
                    } label: {
                        Label("Новый QR", systemImage: "qrcode")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(
                        FlatMacButtonStyle(
                            fill: palette.controlSurface,
                            pressedFill: palette.controlPressed
                        )
                    )
                    .foregroundStyle(palette.textPrimary)

                    Button {
                        viewModel.requestDisconnectPeer()
                    } label: {
                        Label("Отключить", systemImage: "xmark.circle")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(
                        FlatMacButtonStyle(
                            fill: Color.red.opacity(0.11),
                            pressedFill: Color.red.opacity(0.20)
                        )
                    )
                    .foregroundStyle(Color.red)
                }
                .transition(.opacity)
            } else {
                qrPairingContent
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.cardSurface)
                .shadow(
                    color: Color.black.opacity(viewModel.isDarkTheme ? 0.24 : 0.045),
                    radius: 22,
                    y: 8
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private var qrPairingContent: some View {
        VStack(spacing: 0) {
            Button {
                viewModel.requestRefreshQRCode()
            } label: {
                Label("Обновить QR-код", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
            }
            .buttonStyle(
                FlatMacButtonStyle(
                    fill: palette.controlSurface,
                    pressedFill: palette.controlPressed
                )
            )
            .padding(.top, 2)

            Spacer(minLength: 16)

            QRPairingStage(
                qrImage: viewModel.qrImage,
                sessionToken: viewModel.sessionToken,
                palette: palette,
                isDark: viewModel.isDarkTheme
            )

            Spacer(minLength: 24)

            Text("Отсканируйте QR-код на вашем смартфоне")
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
    }

    private var connectedHubContent: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 2)

            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(palette.accent.opacity(0.10))
                        .frame(width: 56, height: 56)

                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(palette.accent)
                }

                Text(viewModel.connectedDeviceName ?? "Смартфон")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)

                if let remoteIP = viewModel.connectedRemoteIP {
                    Text("\(remoteIP) · порт \(String(viewModel.port))")
                        .font(.system(size: 11, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(palette.textSecondary)
                }
            }

            VStack(spacing: 10) {
                Text("Отправить на смартфон")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.textSecondary)

                HStack(spacing: 10) {
                    MacSendTile(
                        title: "Файлы",
                        systemImage: "doc.badge.plus",
                        palette: palette,
                        disabled: viewModel.isTransferring,
                        action: { viewModel.requestPickFilesToSend() }
                    )

                    MacSendTile(
                        title: "Папка",
                        systemImage: "folder.badge.plus",
                        palette: palette,
                        disabled: viewModel.isTransferring,
                        action: { viewModel.requestPickFolderToSend() }
                    )

                    MacSendTile(
                        title: "Текст",
                        systemImage: "text.badge.plus",
                        palette: palette,
                        disabled: viewModel.isTransferring,
                        action: {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                viewModel.showTextComposer = true
                            }
                        }
                    )
                }

                Text("или перетащите файлы в окно")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(palette.textSecondary.opacity(0.75))
                    .padding(.top, 2)
            }

            Spacer(minLength: 2)
        }
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Text("История файлов")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)

                    if !viewModel.filteredHistory.isEmpty {
                        Text("\(viewModel.filteredHistory.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(palette.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(palette.controlSurface))
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        viewModel.openDestinationFolder()
                    } label: {
                        Label("Открыть папку", systemImage: "arrow.up.right.square")
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(
                        FlatMacButtonStyle(
                            fill: palette.controlSurface,
                            pressedFill: palette.controlPressed
                        )
                    )
                    .foregroundStyle(palette.textPrimary)

                    if !viewModel.receivedFiles.isEmpty {
                        Button {
                            viewModel.requestClearHistory()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11.5, weight: .medium))
                                .padding(7)
                        }
                        .buttonStyle(
                            FlatMacButtonStyle(
                                shape: .circle,
                                fill: Color.red.opacity(0.10),
                                pressedFill: Color.red.opacity(0.20)
                            )
                        )
                        .foregroundStyle(Color.red)
                        .help("Очистить всю историю")
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }

            LiquidGlassFilterBar(
                selection: $viewModel.historyFilter,
                palette: palette,
                isDark: viewModel.isDarkTheme,
                namespace: filterNamespace
            )

            if viewModel.filteredHistory.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: viewModel.historyFilter == .sent ? "paperplane" : "tray.and.arrow.down")
                        .font(.system(size: 32, weight: .ultraLight))
                        .foregroundStyle(palette.textSecondary.opacity(0.55))
                        .contentTransition(.symbolEffect(.replace))
                    Text(
                        viewModel.historyFilter == .sent
                            ? "История отправки пока пуста"
                            : (viewModel.historyFilter == .received ? "История получения пока пуста" : "История пока пуста")
                    )
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    Text("Передавайте файлы, папки и текст между Android и MacBook по Wi-Fi.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 270)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(viewModel.filteredHistory) { item in
                            ReceivedFileRow(
                                item: item,
                                palette: palette,
                                onCopyText: { viewModel.copyTextItem(item) },
                                onReveal: { viewModel.revealInFinder(item.savedURL) },
                                onDelete: { viewModel.requestDeleteHistoryItem(item) }
                            )
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .scale(scale: 0.94).combined(with: .opacity)
                            ))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.cardSurface)
                .shadow(
                    color: Color.black.opacity(viewModel.isDarkTheme ? 0.24 : 0.045),
                    radius: 22,
                    y: 8
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private func bottomProgressBar(progress: TransferProgressSnapshot) -> some View {
        VStack(spacing: 9) {
            HStack(spacing: 12) {
                Image(systemName: progress.isIncoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.currentFileName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)

                    Text(
                        "Файл \(progress.fileIndex + 1) из \(max(progress.totalFiles, 1)) · "
                        + "\(NetworkUtils.formatBytes(progress.batchBytesReceived)) / \(NetworkUtils.formatBytes(progress.batchTotalBytes)) · "
                        + NetworkUtils.formatSpeed(bytesPerSecond: progress.speedBytesPerSecond)
                    )
                    .font(.system(size: 11, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(palette.textSecondary)
                }

                Spacer()

                Text(String(format: "%.1f%%", progress.percent))
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(palette.accent)

                Button {
                    viewModel.requestCancelTransfer()
                } label: {
                    Text("Отменить")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(
                    FlatMacButtonStyle(
                        fill: Color.red.opacity(0.11),
                        pressedFill: Color.red.opacity(0.22)
                    )
                )
                .foregroundStyle(Color.red)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(palette.border)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [palette.accent, palette.accent.opacity(0.75)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, geo.size.width * CGFloat(min(max(progress.percent, 0), 100) / 100.0)))
                        .animation(.easeOut(duration: 0.14), value: progress.percent)
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .modifier(FloatingGlassModifier(shape: RoundedRectangle(cornerRadius: 20, style: .continuous), tint: palette.accent.opacity(0.08), isDark: viewModel.isDarkTheme))
        .modifier(GlassTransitionModifier())
    }

    private var dropTargetOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(palette.cardSurface.opacity(0.84))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                )
                .padding(16)

            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(palette.accent.opacity(0.14))
                        .frame(width: 64, height: 64)
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }

                Text("Отпустите для отправки")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)

                if let device = viewModel.connectedDeviceName {
                    Text("Файлы и папки будут отправлены на \(device)")
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(palette.textSecondary)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct MacSendTile: View {
    let title: String
    let systemImage: String
    let palette: ThemePalette
    let disabled: Bool
    let action: () -> Void

    @StateObject private var hoverState = ToggleFlag()

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(palette.accent.opacity(0.13))
                        .frame(width: 36, height: 36)
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }

                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(
            FlatMacButtonStyle(
                shape: .roundedRect(18),
                fill: hoverState.value ? palette.controlSurface : palette.rowSurface,
                pressedFill: palette.controlPressed,
                border: palette.border
            )
        )
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1.0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                hoverState.value = hovering
            }
        }
    }
}

// MARK: - Native macOS 26+ Liquid Glass Helpers

private struct LiquidGlassFilterBar: View {
    @Binding var selection: HistoryFilter
    let palette: ThemePalette
    let isDark: Bool
    let namespace: Namespace.ID

    var body: some View {
        ZStack {
            Capsule()
                .fill(palette.controlSurface)

            HStack(spacing: 4) {
                ForEach(HistoryFilter.allCases) { filter in
                    if selection == filter {
                        Capsule()
                            .fill(palette.accent.opacity(isDark ? 0.22 : 0.14))
                            .modifier(
                                FloatingGlassModifier(
                                    shape: Capsule(),
                                    tint: palette.accent.opacity(0.20),
                                    isDark: isDark
                                )
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .matchedGeometryEffect(id: "historyGlassThumb", in: namespace)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .padding(3.5)
            .allowsHitTesting(false)

            HStack(spacing: 4) {
                ForEach(HistoryFilter.allCases) { filter in
                    let isSelected = selection == filter
                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                            selection = filter
                        }
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? palette.accent : palette.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal, 8)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(FilterTabButtonStyle())
                }
            }
            .padding(3.5)
        }
        .frame(height: 36)
    }
}

@MainActor
private final class ButtonPressAnimator: ObservableObject {
    @Published var isVisuallyPressed: Bool = false
    @Published var isHovering: Bool = false

    private var pressedAt: CFAbsoluteTime = 0
    private var releaseWorkItem: DispatchWorkItem?
    private let minimumPressDuration: TimeInterval
    private let postReleaseHold: TimeInterval

    init(minimumPressDuration: TimeInterval = 0.085, postReleaseHold: TimeInterval = 0) {
        self.minimumPressDuration = minimumPressDuration
        self.postReleaseHold = postReleaseHold
    }

    func handlePressChange(_ pressed: Bool) {
        releaseWorkItem?.cancel()
        releaseWorkItem = nil

        if pressed {
            pressedAt = CFAbsoluteTimeGetCurrent()
            withAnimation(.spring(response: 0.14, dampingFraction: 0.78)) {
                isVisuallyPressed = true
            }
        } else {
            let elapsed = CFAbsoluteTimeGetCurrent() - pressedAt
            let delay = max(postReleaseHold, minimumPressDuration - elapsed)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.56)) {
                    self.isVisuallyPressed = false
                }
            }
            releaseWorkItem = work
            if delay > 0.004 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            } else {
                work.perform()
            }
        }
    }

    func setHovering(_ hovering: Bool) {
        withAnimation(.easeOut(duration: 0.14)) {
            isHovering = hovering
        }
    }
}

private struct NativeGlassButtonModifier: ViewModifier {
    let shape: FlatMacButtonStyle.ShapeKind
    let isDark: Bool
    let tint: Color?
    let postReleaseHold: TimeInterval

    init(
        shape: FlatMacButtonStyle.ShapeKind = .capsule,
        isDark: Bool,
        tint: Color?,
        postReleaseHold: TimeInterval = 0
    ) {
        self.shape = shape
        self.isDark = isDark
        self.tint = tint
        self.postReleaseHold = postReleaseHold
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(
                    TactileGlassButtonStyle(
                        shape: shape,
                        isDark: isDark,
                        tint: tint,
                        postReleaseHold: postReleaseHold
                    )
                )
        } else {
            content
                .buttonStyle(
                    FrostedGlassFallbackButtonStyle(
                        shape: shape,
                        isDark: isDark,
                        tint: tint,
                        postReleaseHold: postReleaseHold
                    )
                )
        }
    }
}

private struct FrostedGlassSurfaceModifier<S: Shape>: ViewModifier {
    let shape: S
    let isDark: Bool
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .background(
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(
                        shape.fill(
                            LinearGradient(
                                colors: isDark
                                    ? [Color.white.opacity(0.09), Color.white.opacity(0.03)]
                                    : [Color.white.opacity(0.46), Color.white.opacity(0.18)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
                    .overlay(
                        Group {
                            if let tint {
                                shape.fill(tint.opacity(isDark ? 0.20 : 0.12))
                            }
                        }
                    )
            )
            .overlay(
                shape.stroke(
                    LinearGradient(
                        colors: isDark
                            ? [Color.white.opacity(0.24), Color.white.opacity(0.07)]
                            : [Color.white.opacity(0.84), Color.white.opacity(0.28)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
    }
}

private struct FrostedGlassFallbackButtonStyle: ButtonStyle {
    let shape: FlatMacButtonStyle.ShapeKind
    let isDark: Bool
    let tint: Color?
    let postReleaseHold: TimeInterval

    func makeBody(configuration: Configuration) -> some View {
        FrostedGlassFallbackButtonBody(
            configuration: configuration,
            shape: shape,
            isDark: isDark,
            tint: tint,
            postReleaseHold: postReleaseHold
        )
    }

    private struct FrostedGlassFallbackButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let shape: FlatMacButtonStyle.ShapeKind
        let isDark: Bool
        let tint: Color?
        @StateObject private var press: ButtonPressAnimator

        init(
            configuration: ButtonStyle.Configuration,
            shape: FlatMacButtonStyle.ShapeKind,
            isDark: Bool,
            tint: Color?,
            postReleaseHold: TimeInterval
        ) {
            self.configuration = configuration
            self.shape = shape
            self.isDark = isDark
            self.tint = tint
            _press = StateObject(wrappedValue: ButtonPressAnimator(postReleaseHold: postReleaseHold))
        }

        var body: some View {
            let scale: CGFloat = press.isVisuallyPressed ? 0.90 : (press.isHovering ? 1.025 : 1.0)
            let resolvedShape = FlatMacButtonStyle.anyShape(for: shape)
            let padded = configuration.label
                .padding(.horizontal, shape.isCircle ? 3 : 7)
                .padding(.vertical, shape.isCircle ? 3 : 4)
            padded
                .modifier(FrostedGlassSurfaceModifier(shape: resolvedShape, isDark: isDark, tint: tint))
                .contentShape(resolvedShape)
                .compositingGroup()
                .opacity(press.isVisuallyPressed ? 0.86 : 1.0)
                .scaleEffect(scale, anchor: .center)
                .onChange(of: configuration.isPressed) { _, pressed in
                    press.handlePressChange(pressed)
                }
                .onHover { hovering in
                    press.setHovering(hovering)
                }
        }
    }
}

@available(macOS 26.0, *)
private struct TactileGlassButtonStyle: ButtonStyle {
    let shape: FlatMacButtonStyle.ShapeKind
    let isDark: Bool
    let tint: Color?
    let postReleaseHold: TimeInterval

    init(
        shape: FlatMacButtonStyle.ShapeKind = .capsule,
        isDark: Bool,
        tint: Color?,
        postReleaseHold: TimeInterval = 0
    ) {
        self.shape = shape
        self.isDark = isDark
        self.tint = tint
        self.postReleaseHold = postReleaseHold
    }

    func makeBody(configuration: Configuration) -> some View {
        TactileGlassButtonBody(
            configuration: configuration,
            shape: shape,
            isDark: isDark,
            tint: tint,
            postReleaseHold: postReleaseHold
        )
    }

    private struct TactileGlassButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let shape: FlatMacButtonStyle.ShapeKind
        let isDark: Bool
        let tint: Color?
        @StateObject private var press: ButtonPressAnimator

        init(
            configuration: ButtonStyle.Configuration,
            shape: FlatMacButtonStyle.ShapeKind,
            isDark: Bool,
            tint: Color?,
            postReleaseHold: TimeInterval
        ) {
            self.configuration = configuration
            self.shape = shape
            self.isDark = isDark
            self.tint = tint
            _press = StateObject(wrappedValue: ButtonPressAnimator(postReleaseHold: postReleaseHold))
        }

        var body: some View {
            // Keep Glass non-interactive and outside GlassEffectContainer so label and
            // backdrop scale together inside one centered CoreAnimation transform.
            let glass: Glass = tint.map { Glass.regular.tint($0.opacity(0.24)) } ?? .regular
            let scale: CGFloat = press.isVisuallyPressed ? 0.90 : (press.isHovering ? 1.025 : 1.0)
            let resolvedShape = FlatMacButtonStyle.anyShape(for: shape)
            configuration.label
                .padding(.horizontal, shape.isCircle ? 3 : 7)
                .padding(.vertical, shape.isCircle ? 3 : 4)
                .contentShape(resolvedShape)
                .glassEffect(glass, in: resolvedShape)
                .opacity(press.isVisuallyPressed ? 0.92 : 1.0)
                .scaleEffect(scale, anchor: .center)
                .onChange(of: configuration.isPressed) { _, pressed in
                    press.handlePressChange(pressed)
                }
                .onHover { hovering in
                    press.setHovering(hovering)
                }
        }
    }
}

private struct FilterTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FilterTabButtonBody(configuration: configuration)
    }

    private struct FilterTabButtonBody: View {
        let configuration: ButtonStyle.Configuration
        @StateObject private var press = ButtonPressAnimator()

        var body: some View {
            configuration.label
                .compositingGroup()
                .opacity(press.isVisuallyPressed ? 0.72 : (press.isHovering ? 0.92 : 1.0))
                .scaleEffect(press.isVisuallyPressed ? 0.92 : (press.isHovering ? 1.015 : 1.0), anchor: .center)
                .onChange(of: configuration.isPressed) { _, pressed in
                    press.handlePressChange(pressed)
                }
                .onHover { hovering in
                    press.setHovering(hovering)
                }
        }
    }
}

private struct GlassTransitionModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffectTransition(.matchedGeometry)
        } else {
            content
        }
    }
}

private struct FloatingGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let isDark: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let glass: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(
                    shape
                        .fill(.regularMaterial)
                        .overlay(shape.fill(isDark ? Color.white.opacity(0.04) : Color.white.opacity(0.75)))
                )
                .overlay(
                    shape.stroke(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.08), lineWidth: 1)
                )
        }
    }
}

private struct FlatMacButtonStyle: ButtonStyle {
    enum ShapeKind {
        case capsule
        case circle
        case roundedRect(CGFloat)

        var isCircle: Bool {
            if case .circle = self { return true }
            return false
        }
    }

    static func anyShape(for kind: ShapeKind) -> AnyShape {
        switch kind {
        case .capsule:
            return AnyShape(Capsule())
        case .circle:
            return AnyShape(Circle())
        case .roundedRect(let radius):
            return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    let shape: ShapeKind
    let fill: Color
    let pressedFill: Color
    let border: Color?
    let postReleaseHold: TimeInterval

    init(
        shape: ShapeKind = .capsule,
        fill: Color,
        pressedFill: Color,
        border: Color? = nil,
        postReleaseHold: TimeInterval = 0
    ) {
        self.shape = shape
        self.fill = fill
        self.pressedFill = pressedFill
        self.border = border
        self.postReleaseHold = postReleaseHold
    }

    func makeBody(configuration: Configuration) -> some View {
        FlatMacButtonBody(
            configuration: configuration,
            shape: shape,
            fill: fill,
            pressedFill: pressedFill,
            border: border,
            postReleaseHold: postReleaseHold
        )
    }
}

private struct FlatMacButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let shape: FlatMacButtonStyle.ShapeKind
    let fill: Color
    let pressedFill: Color
    let border: Color?

    @StateObject private var press: ButtonPressAnimator

    init(
        configuration: ButtonStyle.Configuration,
        shape: FlatMacButtonStyle.ShapeKind,
        fill: Color,
        pressedFill: Color,
        border: Color?,
        postReleaseHold: TimeInterval
    ) {
        self.configuration = configuration
        self.shape = shape
        self.fill = fill
        self.pressedFill = pressedFill
        self.border = border
        _press = StateObject(wrappedValue: ButtonPressAnimator(postReleaseHold: postReleaseHold))
    }

    var body: some View {
        let baseBg = press.isVisuallyPressed ? pressedFill : fill
        let scale: CGFloat = press.isVisuallyPressed ? 0.91 : (press.isHovering ? 1.02 : 1.0)
        Group {
            switch shape {
            case .capsule:
                configuration.label
                    .background(Capsule().fill(baseBg))
                    .overlay(Capsule().stroke(border ?? .clear, lineWidth: border == nil ? 0 : 1))
                    .contentShape(Capsule())
            case .circle:
                configuration.label
                    .background(Circle().fill(baseBg))
                    .overlay(Circle().stroke(border ?? .clear, lineWidth: border == nil ? 0 : 1))
                    .contentShape(Circle())
            case .roundedRect(let radius):
                let rr = RoundedRectangle(cornerRadius: radius, style: .continuous)
                configuration.label
                    .background(rr.fill(baseBg))
                    .overlay(rr.stroke(border ?? .clear, lineWidth: border == nil ? 0 : 1))
                    .contentShape(rr)
            }
        }
        .compositingGroup()
        .opacity(press.isVisuallyPressed ? 0.88 : 1.0)
        .scaleEffect(scale, anchor: .center)
        .onChange(of: configuration.isPressed) { _, pressed in
            press.handlePressChange(pressed)
        }
        .onHover { hovering in
            press.setHovering(hovering)
        }
    }
}

private struct ReceivedFileRow: View {
    let item: ReceivedFileRecord
    let palette: ThemePalette
    let onCopyText: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @StateObject private var hoverState = ToggleFlag()

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.accent.opacity(0.11))
                    .frame(width: 36, height: 36)
                Image(systemName: item.isText ? "doc.text" : (item.relativePath.contains("/") ? "folder.fill" : "doc.fill"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(item.isIncoming ? "Получено" : "Отправлено")
                        .fontWeight(.medium)
                        .foregroundStyle(item.isIncoming ? Color.green : palette.accent)
                    Text("·")
                    Text(NetworkUtils.formatBytes(item.size))
                        .monospacedDigit()
                    if item.relativePath != item.fileName {
                        Text("·")
                        Text(item.relativePath)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(palette.textSecondary)
            }

            Spacer()

            HStack(spacing: 6) {
                if item.isText {
                    Button(action: onCopyText) {
                        Label("Копировать", systemImage: "doc.on.clipboard")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(
                        FlatMacButtonStyle(
                            fill: palette.accent.opacity(0.12),
                            pressedFill: palette.accent.opacity(0.22)
                        )
                    )
                    .foregroundStyle(palette.accent)
                }

                if item.isIncoming || FileManager.default.fileExists(atPath: item.savedURL.path) {
                    Button(action: onReveal) {
                        Text("Finder")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(
                        FlatMacButtonStyle(
                            fill: palette.controlSurface,
                            pressedFill: palette.controlPressed
                        )
                    )
                    .foregroundStyle(palette.textPrimary)
                }

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .padding(6)
                }
                .buttonStyle(
                    FlatMacButtonStyle(
                        shape: .circle,
                        fill: Color.red.opacity(hoverState.value ? 0.14 : 0.08),
                        pressedFill: Color.red.opacity(0.24)
                    )
                )
                .foregroundStyle(Color.red)
                .help("Удалить из списка")
            }
            .opacity(hoverState.value ? 1.0 : 0.78)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(hoverState.value ? palette.rowSurface : palette.rowSurface.opacity(0.42))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(palette.border.opacity(hoverState.value ? 0.9 : 0.0), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.16), value: hoverState.value)
        .onHover { hovering in
            hoverState.value = hovering
        }
    }
}

@MainActor
private final class ToggleFlag: ObservableObject {
    @Published var value: Bool = false
}

private struct QRPairingStage: View {
    let qrImage: NSImage?
    let sessionToken: String
    let palette: ThemePalette
    let isDark: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white)
                .shadow(
                    color: Color.black.opacity(isDark ? 0.34 : 0.06),
                    radius: 18,
                    y: 7
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(palette.border, lineWidth: isDark ? 0 : 1)
                )

            if let qrImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
                    .id(sessionToken)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else {
                ProgressView()
                    .padding(40)
            }
        }
        .frame(width: 208, height: 208)
    }
}

private struct MacTextComposerModal: View {
    let palette: ThemePalette
    let isDark: Bool
    let onSend: (String, String) -> Void
    let onDismiss: () -> Void

    @StateObject private var form = TextFormState()

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Отправить текстовый файл")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.textSecondary)
                            .padding(6)
                    }
                    .buttonStyle(FlatMacButtonStyle(shape: .circle, fill: palette.controlSurface, pressedFill: palette.controlPressed))
                }

                TextField("Имя файла (.txt)", text: $form.fileName)
                    .textFieldStyle(.roundedBorder)

                TextEditor(text: $form.content)
                    .font(.system(size: 13))
                    .frame(height: 150)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(palette.rowSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(palette.border, lineWidth: 1)
                    )

                HStack(spacing: 10) {
                    Button(action: onDismiss) {
                        Text("Отмена")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(FlatMacButtonStyle(fill: palette.controlSurface, pressedFill: palette.controlPressed))
                    .foregroundStyle(palette.textPrimary)

                    Button {
                        onSend(form.fileName, form.content)
                    } label: {
                        Text("Отправить")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(FlatMacButtonStyle(fill: palette.accent, pressedFill: palette.accent.opacity(0.82)))
                    .foregroundStyle(Color.white)
                    .disabled(form.content.isEmpty)
                }
            }
            .padding(22)
            .frame(width: 400)
            .modifier(FloatingGlassModifier(shape: RoundedRectangle(cornerRadius: 22, style: .continuous), tint: nil, isDark: isDark))
            .shadow(color: Color.black.opacity(0.22), radius: 24, y: 10)
        }
    }
}

@MainActor
private final class TextFormState: ObservableObject {
    @Published var fileName: String = "note_\(Int(Date().timeIntervalSince1970)).txt"
    @Published var content: String = ""
}

@MainActor
private final class SettingsNameFormState: ObservableObject {
    @Published var deviceName: String = ""
}

private struct MacSettingsModal: View {
    @ObservedObject var viewModel: DroplyViewModel
    let palette: ThemePalette
    let isDark: Bool
    let onDismiss: () -> Void

    @StateObject private var form = SettingsNameFormState()

    var body: some View {
        ZStack {
            Color.black.opacity(isDark ? 0.34 : 0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.updateDeviceName(form.deviceName)
                    onDismiss()
                }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Настройки")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    Spacer()
                    Button {
                        viewModel.updateDeviceName(form.deviceName)
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.textSecondary)
                            .padding(4)
                    }
                    .modifier(NativeGlassButtonModifier(shape: .circle, isDark: isDark, tint: nil))
                }

                VStack(spacing: 8) {
                    // 1. Theme toggle moved here cleanly, still triggering radial ripple from its center
                    settingsRow(icon: viewModel.isDarkTheme ? "sun.max.fill" : "moon.fill", title: "Тема оформления") {
                        Button {
                            viewModel.toggleTheme()
                        } label: {
                            HStack(spacing: 6) {
                                ZStack {
                                    Image(systemName: "sun.max.fill").hidden()
                                    Image(systemName: viewModel.isDarkTheme ? "sun.max.fill" : "moon.fill")
                                }
                                .font(.system(size: 11.5, weight: .medium))
                                .frame(width: 14, height: 14)

                                ZStack(alignment: .center) {
                                    Text("Светлая").hidden()
                                    Text(viewModel.isDarkTheme ? "Светлая" : "Тёмная")
                                }
                                .font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                        }
                        .modifier(NativeGlassButtonModifier(shape: .capsule, isDark: isDark, tint: nil))
                        .foregroundStyle(palette.textPrimary)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear {
                                        let frame = geo.frame(in: .global)
                                        viewModel.themeButtonCenter = CGPoint(x: frame.midX, y: frame.midY)
                                    }
                                    .onChange(of: geo.frame(in: .global)) { _, frame in
                                        viewModel.themeButtonCenter = CGPoint(x: frame.midX, y: frame.midY)
                                    }
                            }
                        )
                    }

                    // 2. Device name
                    settingsRow(icon: "desktopcomputer", title: "Имя устройства") {
                        TextField("MacBook", text: $form.deviceName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(palette.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(width: 165)
                            .modifier(
                                FrostedGlassSurfaceModifier(
                                    shape: RoundedRectangle(cornerRadius: 9, style: .continuous),
                                    isDark: isDark
                                )
                            )
                            .onSubmit {
                                viewModel.updateDeviceName(form.deviceName)
                            }
                            .onChange(of: form.deviceName) { _, newValue in
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    viewModel.updateDeviceName(trimmed)
                                }
                            }
                    }

                    // 3. Download folder
                    settingsRow(
                        icon: "folder",
                        title: "Папка сохранения",
                        subtitle: viewModel.destinationFolder.lastPathComponent
                    ) {
                        Button {
                            viewModel.chooseDestinationFolderFromSettings()
                        } label: {
                            Text("Выбрать")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                        }
                        .modifier(NativeGlassButtonModifier(shape: .capsule, isDark: isDark, tint: nil))
                        .foregroundStyle(palette.textPrimary)
                    }

                    // 4. Overwrite existing files
                    settingsRow(icon: "doc.on.doc", title: "Перезаписывать файлы") {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.overwriteExisting },
                                set: { viewModel.updateOverwriteExisting($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    // 5. Confirm incoming transfers
                    settingsRow(icon: "checkmark.shield", title: "Подтверждать приём") {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.requireIncomingConfirmation },
                                set: { viewModel.updateRequireIncomingConfirmation($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    // 6. Updates
                    settingsRow(
                        icon: "arrow.down.circle",
                        title: "Обновление приложения",
                        subtitle: viewModel.availableUpdate.map { "Доступна версия \($0.latestVersion)" }
                            ?? "Версия \(viewModel.currentAppVersionLabel)"
                    ) {
                        Button {
                            if viewModel.availableUpdate != nil {
                                viewModel.showSettings = false
                                viewModel.presentUpdatePrompt()
                            } else {
                                viewModel.checkForUpdates(userInitiated: true)
                            }
                        } label: {
                            Text(
                                viewModel.availableUpdate != nil
                                    ? "Обновить"
                                    : (viewModel.isCheckingForUpdates ? "Поиск..." : "Проверить")
                            )
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                        }
                        .modifier(
                            NativeGlassButtonModifier(
                                shape: .capsule,
                                isDark: isDark,
                                tint: viewModel.availableUpdate != nil ? palette.accent : nil
                            )
                        )
                        .foregroundStyle(palette.textPrimary)
                        .disabled(viewModel.isCheckingForUpdates)
                    }
                }
            }
            .padding(22)
            .frame(width: 430)
            .modifier(FloatingGlassModifier(shape: RoundedRectangle(cornerRadius: 22, style: .continuous), tint: nil, isDark: isDark))
            .shadow(color: Color.black.opacity(0.22), radius: 24, y: 10)
            .onAppear {
                form.deviceName = viewModel.deviceName
            }
        }
    }

    private func settingsRow<Control: View>(
        icon: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(palette.accent.opacity(isDark ? 0.20 : 0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.accent)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .modifier(
            FrostedGlassSurfaceModifier(
                shape: RoundedRectangle(cornerRadius: 13, style: .continuous),
                isDark: isDark
            )
        )
    }
}

private struct ConfirmationModalView: View {
    let confirmation: PendingConfirmation
    let palette: ThemePalette
    let isDark: Bool
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    confirmation.onCancel()
                    onDismiss()
                }

            VStack(spacing: 18) {
                let badgeColor: Color = confirmation.isDestructive
                    ? .red
                    : (confirmation.isWarning ? .orange : palette.accent)
                let iconName: String = (confirmation.isDestructive || confirmation.isWarning)
                    ? "exclamationmark.triangle.fill"
                    : "questionmark.circle.fill"
                ZStack {
                    Circle()
                        .fill(badgeColor.opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: iconName)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(badgeColor)
                }

                Text(confirmation.message)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        confirmation.onCancel()
                        onDismiss()
                    } label: {
                        Text(confirmation.cancelLabel)
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(
                        FlatMacButtonStyle(
                            fill: palette.controlSurface,
                            pressedFill: palette.controlPressed
                        )
                    )
                    .foregroundStyle(palette.textPrimary)

                    Button {
                        confirmation.onConfirm()
                        onDismiss()
                    } label: {
                        Text(confirmation.confirmLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(
                        FlatMacButtonStyle(
                            fill: confirmation.isDestructive ? Color.red : palette.accent,
                            pressedFill: (confirmation.isDestructive ? Color.red : palette.accent).opacity(0.82)
                        )
                    )
                    .foregroundStyle(Color.white)
                }
            }
            .padding(22)
            .frame(width: 368)
            .modifier(FloatingGlassModifier(shape: RoundedRectangle(cornerRadius: 22, style: .continuous), tint: nil, isDark: isDark))
            .shadow(color: Color.black.opacity(0.22), radius: 24, y: 10)
        }
    }
}

private struct UpdateAvailableModalView: View {
    let update: AppUpdateInfo
    let palette: ThemePalette
    let isDark: Bool
    let onInstall: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(isDark ? 0.36 : 0.20)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(palette.accent.opacity(isDark ? 0.22 : 0.14))
                        .frame(width: 50, height: 50)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }

                VStack(spacing: 6) {
                    Text(update.title ?? "Доступна новая версия Droply")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("Нажмите «Установить», чтобы открыть GitHub и скачать обновление.")
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Text("Текущая: \(update.currentVersion)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    Text("Новая: \(update.latestVersion)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .modifier(
                    FrostedGlassSurfaceModifier(
                        shape: Capsule(),
                        isDark: isDark,
                        tint: palette.accent
                    )
                )

                if let notes = update.releaseNotes, !notes.isEmpty {
                    ScrollView {
                        Text(notes)
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(palette.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .modifier(
                        FrostedGlassSurfaceModifier(
                            shape: RoundedRectangle(cornerRadius: 12, style: .continuous),
                            isDark: isDark
                        )
                    )
                }

                HStack(spacing: 10) {
                    Button(action: onDismiss) {
                        Text("Позже")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .modifier(NativeGlassButtonModifier(shape: .capsule, isDark: isDark, tint: nil))
                    .foregroundStyle(palette.textPrimary)

                    Button(action: onInstall) {
                        Text("Установить")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .modifier(NativeGlassButtonModifier(shape: .capsule, isDark: isDark, tint: palette.accent))
                    .foregroundStyle(palette.accent)
                }
            }
            .padding(22)
            .frame(width: 392)
            .modifier(FloatingGlassModifier(shape: RoundedRectangle(cornerRadius: 22, style: .continuous), tint: nil, isDark: isDark))
            .shadow(color: Color.black.opacity(0.24), radius: 26, y: 12)
        }
    }
}

private struct ThemePalette {
    let cardSurface: Color
    let rowSurface: Color
    let controlSurface: Color
    let controlPressed: Color
    let border: Color
    let textPrimary: Color
    let textSecondary: Color
    let accent: Color

    static let light = ThemePalette(
        cardSurface: Color.white,
        rowSurface: Color(red: 0.968, green: 0.972, blue: 0.982),
        controlSurface: Color(red: 0.945, green: 0.950, blue: 0.965),
        controlPressed: Color(red: 0.894, green: 0.902, blue: 0.925),
        border: Color.black.opacity(0.065),
        textPrimary: Color(red: 0.09, green: 0.10, blue: 0.13),
        textSecondary: Color(red: 0.43, green: 0.46, blue: 0.52),
        accent: Color(red: 0.04, green: 0.48, blue: 1.0)
    )

    static let dark = ThemePalette(
        cardSurface: Color(red: 0.115, green: 0.123, blue: 0.152),
        rowSurface: Color(red: 0.148, green: 0.157, blue: 0.194),
        controlSurface: Color(red: 0.172, green: 0.182, blue: 0.222),
        controlPressed: Color(red: 0.23, green: 0.24, blue: 0.29),
        border: Color.white.opacity(0.09),
        textPrimary: Color(red: 0.95, green: 0.96, blue: 0.98),
        textSecondary: Color(red: 0.60, green: 0.64, blue: 0.72),
        accent: Color(red: 0.28, green: 0.58, blue: 1.0)
    )
}
