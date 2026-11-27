import AppKit
import SwiftUI
import DroplyCore

enum BannerToastKind: Sendable {
    case success
    case warning
    case error
}

@MainActor
final class FloatingToastModel: ObservableObject {
    @Published var text: String = ""
    @Published var kind: BannerToastKind = .success
    @Published var isDark: Bool = false
    @Published var isPresented: Bool = false

    var onOpenApp: (() -> Void)?
    var onDismiss: (() -> Void)?
}

private final class NonActivatingToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class FloatingToastController {
    private let model = FloatingToastModel()
    private var panel: NonActivatingToastPanel?
    private var hostingView: FirstClickHostingView<FloatingToastContentView>?
    private var animationToken: Int = 0

    func show(
        text: String,
        kind: BannerToastKind,
        isDark: Bool,
        preferredScreen: NSScreen?,
        onOpenApp: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        animationToken &+= 1
        let wasVisible = panel?.isVisible == true

        model.text = text
        model.kind = kind
        model.isDark = isDark
        model.onOpenApp = onOpenApp
        model.onDismiss = onDismiss

        let panel = ensurePanel()
        if let host = hostingView {
            host.rootView = FloatingToastContentView(model: model)
            host.invalidateIntrinsicContentSize()
            host.layoutSubtreeIfNeeded()
        }

        positionPanel(panel, on: preferredScreen)
        panel.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)

        if !wasVisible {
            panel.alphaValue = 0
            model.isPresented = false
            panel.orderFrontRegardless()
            withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                model.isPresented = true
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
            }
        } else {
            model.isPresented = true
            panel.alphaValue = 1.0
            panel.orderFrontRegardless()
        }
    }

    func updateTheme(isDark: Bool) {
        model.isDark = isDark
        panel?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    func dismiss() {
        guard let panel, panel.isVisible else {
            model.isPresented = false
            return
        }
        animationToken &+= 1
        let token = animationToken

        withAnimation(.easeIn(duration: 0.16)) {
            model.isPresented = false
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, token] in
            Task { @MainActor in
                guard let self, self.animationToken == token else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    func closeImmediately() {
        animationToken &+= 1
        model.isPresented = false
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NonActivatingToastPanel {
        if let existing = panel {
            return existing
        }
        let contentView = FloatingToastContentView(model: model)
        let host = FirstClickHostingView(rootView: contentView)
        host.translatesAutoresizingMaskIntoConstraints = false

        let newPanel = NonActivatingToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .statusBar
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.isMovable = false
        newPanel.ignoresMouseEvents = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        newPanel.contentView = host

        self.hostingView = host
        self.panel = newPanel
        return newPanel
    }

    private func positionPanel(_ panel: NonActivatingToastPanel, on preferredScreen: NSScreen?) {
        let fitting = hostingView?.fittingSize ?? NSSize(width: 400, height: 92)
        let width = min(max(fitting.width, 310), 440)
        let height = min(max(fitting.height, 76), 190)

        let screen = preferredScreen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let x = visible.maxX - width - 10
        let y = visible.maxY - height - 6
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

private struct FloatingToastContentView: View {
    @ObservedObject var model: FloatingToastModel

    private var tintColor: Color {
        switch model.kind {
        case .success: Color.green
        case .warning: Color.orange
        case .error: Color.red
        }
    }

    private var iconName: String {
        switch model.kind {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.shield.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        HStack(alignment: .center, spacing: 11) {
            ZStack {
                Circle()
                    .fill(tintColor.opacity(model.isDark ? 0.24 : 0.16))
                    .frame(width: 30, height: 30)
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tintColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Droply")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(model.text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                model.onDismiss?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(model.isDark ? 0.10 : 0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("Закрыть")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minWidth: 280, maxWidth: 396, alignment: .leading)
        .contentShape(shape)
        .onTapGesture {
            model.onOpenApp?()
            model.onDismiss?()
        }
        .modifier(ToastFrostedGlassModifier(shape: shape, tint: tintColor, isDark: model.isDark))
        .shadow(color: Color.black.opacity(model.isDark ? 0.42 : 0.18), radius: 14, x: 0, y: 6)
        .scaleEffect(model.isPresented ? 1.0 : 0.96)
        .offset(y: model.isPresented ? 0 : -8)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .preferredColorScheme(model.isDark ? .dark : .light)
    }
}

private struct ToastFrostedGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color
    let isDark: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(tint.opacity(isDark ? 0.22 : 0.14)), in: shape)
                .overlay(
                    shape.strokeBorder(
                        Color.white.opacity(isDark ? 0.16 : 0.45),
                        lineWidth: 0.75
                    )
                )
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(
                    shape.fill(tint.opacity(isDark ? 0.16 : 0.10))
                )
                .overlay(
                    shape.strokeBorder(
                        Color.white.opacity(isDark ? 0.18 : 0.55),
                        lineWidth: 0.85
                    )
                )
        }
    }
}

struct MenuBarTransferPopoverView: View {
    @ObservedObject var viewModel: DroplyViewModel
    let isPostTransferHold: Bool
    let onOpenApp: () -> Void
    let onOpenUpdate: () -> Void
    let onQuit: () -> Void

    private var accentColor: Color {
        if viewModel.isTransferring, let progress = viewModel.activeProgress {
            return progress.isIncoming ? Color.blue : Color.accentColor
        }
        if isPostTransferHold {
            return Color.green
        }
        return Color.accentColor
    }

    private var headerIconName: String {
        if viewModel.isTransferring, let progress = viewModel.activeProgress {
            return progress.isIncoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
        }
        if isPostTransferHold {
            return "checkmark.circle.fill"
        }
        return "paperplane.circle.fill"
    }

    private var headerTitle: String {
        if viewModel.isTransferring, let progress = viewModel.activeProgress {
            return progress.isIncoming ? "Получение файлов" : "Отправка файлов"
        }
        if isPostTransferHold {
            return "Передача завершена"
        }
        return "Droply"
    }

    private var headerSubtitle: String {
        if let peer = viewModel.connectedDeviceName {
            return peer
        }
        return "Wi-Fi передача"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accentColor.opacity(viewModel.isDarkTheme ? 0.24 : 0.14))
                        .frame(width: 36, height: 36)
                    Image(systemName: headerIconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(headerSubtitle)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if viewModel.isTransferring, let progress = viewModel.activeProgress {
                    let pct = max(0, min(100, Int(progress.percent.rounded(.down))))
                    Text("\(pct)%")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(accentColor)
                } else if isPostTransferHold {
                    Text("100%")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.green)
                }
            }

            if viewModel.isTransferring, let progress = viewModel.activeProgress {
                let fraction = min(max(progress.percent / 100.0, 0), 1)
                VStack(alignment: .leading, spacing: 7) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(viewModel.isDarkTheme ? 0.14 : 0.09))
                            Capsule()
                                .fill(accentColor)
                                .frame(width: max(6, geo.size.width * fraction))
                        }
                    }
                    .frame(height: 7)
                    .animation(.easeOut(duration: 0.15), value: fraction)

                    HStack(spacing: 6) {
                        Text(progress.currentFileName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if progress.totalFiles > 1 {
                            Text("\(progress.fileIndex)/\(progress.totalFiles)")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 4) {
                        Text("\(NetworkUtils.formatBytes(progress.batchBytesReceived)) из \(NetworkUtils.formatBytes(progress.batchTotalBytes))")
                            .font(.system(size: 11, weight: .regular))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if progress.speedBytesPerSecond > 0 {
                            Text("• \(NetworkUtils.formatSpeed(bytesPerSecond: progress.speedBytesPerSecond))")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(viewModel.isDarkTheme ? 0.08 : 0.045))
                )
            } else {
                Text(
                    isPostTransferHold
                        ? "Все файлы успешно переданы по локальной сети."
                        : "Откройте окно Droply, чтобы выбрать или принять файлы."
                )
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                Button(action: onOpenApp) {
                    HStack(spacing: 7) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Перейти в приложение")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accentColor)
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                if viewModel.isTransferring {
                    Button {
                        viewModel.requestCancelTransfer()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 12, weight: .medium))
                            Text("Отменить передачу")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.red.opacity(viewModel.isDarkTheme ? 0.20 : 0.11))
                        )
                        .foregroundStyle(Color.red)
                    }
                    .buttonStyle(.plain)
                }

                if let update = viewModel.availableUpdate {
                    Button(action: onOpenUpdate) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.app.fill")
                                .font(.system(size: 12, weight: .medium))
                            Text("Обновить Droply (v\(update.latestVersion))")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.orange.opacity(viewModel.isDarkTheme ? 0.20 : 0.12))
                        )
                        .foregroundStyle(Color.orange)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
                .opacity(0.6)

            HStack {
                Spacer()
                Button("Завершить Droply", action: onQuit)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 300)
        .preferredColorScheme(viewModel.isDarkTheme ? .dark : .light)
    }
}
