import SwiftUI
import DroplyCore

struct AdminContentView: View {
    @ObservedObject var viewModel: AdminViewModel

    private var isDark: Bool { viewModel.isDarkTheme }

    private var accentColor: Color {
        Color(red: 0.17, green: 0.50, blue: 0.96)
    }

    private var textPrimary: Color {
        isDark ? .white : Color(red: 0.08, green: 0.09, blue: 0.12)
    }

    private var textSecondary: Color {
        isDark ? Color.white.opacity(0.65) : Color(red: 0.36, green: 0.40, blue: 0.48)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: isDark
                    ? [Color(red: 0.065, green: 0.072, blue: 0.098), Color(red: 0.10, green: 0.112, blue: 0.148)]
                    : [Color(red: 0.942, green: 0.958, blue: 0.986), Color(red: 0.978, green: 0.984, blue: 0.996)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 14)

                if let error = viewModel.errorBanner {
                    statusPill(text: error, isError: true)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 10)
                } else if let status = viewModel.statusBanner {
                    statusPill(text: status, isError: false)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 10)
                }

                HStack(alignment: .top, spacing: 18) {
                    editorColumn
                        .frame(maxWidth: .infinity)

                    previewColumn
                        .frame(width: 358)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(isDark ? .dark : .light)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(accentColor.opacity(isDark ? 0.22 : 0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: "megaphone.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accentColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Droply Admin")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(textPrimary)
                Text("Панель публикации обновлений для MacBook и Android")
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(textSecondary)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    viewModel.isDarkTheme.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isDark ? "sun.max.fill" : "moon.fill")
                        .font(.system(size: 11.5, weight: .medium))
                    Text(isDark ? "Светлая" : "Тёмная")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(AdminGlassButtonStyle(isDark: isDark, tint: nil))
            .foregroundStyle(textPrimary)
        }
    }

    private var editorColumn: some View {
        ScrollView {
            VStack(spacing: 14) {
                glassCard {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            Label("Репозиторий GitHub и доступ", systemImage: "link.badge.plus")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(textPrimary)
                            Spacer()
                            repoStatusChip
                        }

                        glassTextField("https://github.com/username/Droply", text: $viewModel.repositoryURL)

                        HStack(spacing: 8) {
                            SecureField("GitHub Token (PAT с правом Contents: Read & write)", text: $viewModel.githubToken)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(textPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .modifier(AdminFrostedModifier(cornerRadius: 10, isDark: isDark))

                            Button {
                                viewModel.saveTokenToKeychain()
                            } label: {
                                Text(viewModel.hasSavedToken ? "Обновить токен" : "Сохранить в Keychain")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 7)
                            }
                            .buttonStyle(AdminGlassButtonStyle(isDark: isDark, tint: nil))
                            .foregroundStyle(textPrimary)

                            Button {
                                viewModel.loadFromGitHub()
                            } label: {
                                Text("Загрузить")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 7)
                            }
                            .buttonStyle(AdminGlassButtonStyle(isDark: isDark, tint: accentColor))
                            .foregroundStyle(accentColor)
                            .disabled(viewModel.isBusy)
                        }

                        if viewModel.hasSavedToken {
                            HStack {
                                Label("Токен сохранён в Связке ключей macOS", systemImage: "lock.shield.fill")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.green)
                                Spacer()
                                Button("Очистить") {
                                    viewModel.clearTokenFromKeychain()
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(textSecondary)
                            }
                        }
                    }
                }

                glassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Текст и версия для пользователей", systemImage: "text.bubble.fill")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(textPrimary)
                            Spacer()
                            Toggle("Разные версии", isOn: $viewModel.separatePlatformVersions)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .font(.system(size: 11.5))
                                .foregroundStyle(textSecondary)
                        }

                        if viewModel.separatePlatformVersions {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Версия macOS")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(textSecondary)
                                    glassTextField("1.1", text: $viewModel.macVersionText)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Версия Android")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(textSecondary)
                                    glassTextField("1.1", text: $viewModel.androidVersionText)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(" ")
                                        .font(.system(size: 11.5))
                                    Button {
                                        viewModel.bumpMinorVersion()
                                    } label: {
                                        Text("+0.1")
                                            .font(.system(size: 12, weight: .semibold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                    }
                                    .buttonStyle(AdminGlassButtonStyle(isDark: isDark, tint: accentColor))
                                    .foregroundStyle(accentColor)
                                }
                            }
                        } else {
                            HStack(spacing: 8) {
                                Text("Новая версия:")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(textSecondary)
                                glassTextField("1.1", text: $viewModel.versionText)
                                    .frame(width: 110)
                                Button {
                                    viewModel.bumpMinorVersion()
                                } label: {
                                    Text("+0.1")
                                        .font(.system(size: 12, weight: .semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(AdminGlassButtonStyle(isDark: isDark, tint: accentColor))
                                .foregroundStyle(accentColor)
                                Spacer()
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Заголовок уведомления")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(textSecondary)
                            glassTextField("Вышла новая версия Droply", text: $viewModel.notificationTitle)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Текст уведомления (увидят все на смартфонах и MacBook)")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(textSecondary)
                                Spacer()
                                Text("\(viewModel.notificationBody.count)/500")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(viewModel.notificationBody.count > 500 ? Color.red : textSecondary)
                            }
                            TextEditor(text: $viewModel.notificationBody)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .foregroundStyle(textPrimary)
                                .frame(height: 118)
                                .padding(8)
                                .modifier(AdminFrostedModifier(cornerRadius: 11, isDark: isDark))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ссылка для кнопки «Установить» (необязательно — по умолчанию страница релизов)")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(textSecondary)
                            glassTextField("https://github.com/.../releases", text: $viewModel.customReleaseURL)
                        }

                        Toggle("Также создать GitHub Release (тег v\(viewModel.effectiveMacVersion))", isOn: $viewModel.createGitHubRelease)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(textPrimary)

                        HStack(spacing: 10) {
                            Button {
                                viewModel.saveLocalManifestFile()
                            } label: {
                                Label("Сохранить version.json", systemImage: "square.and.arrow.down")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                            }
                            .buttonStyle(AdminGlassButtonStyle(isDark: isDark, tint: nil))
                            .foregroundStyle(textPrimary)

                            Button {
                                viewModel.publishToGitHub()
                            } label: {
                                Label(
                                    viewModel.isBusy ? "Публикация..." : "Опубликовать обновление",
                                    systemImage: "paperplane.fill"
                                )
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                            }
                            .buttonStyle(AdminGlassButtonStyle(isDark: isDark, tint: accentColor))
                            .foregroundStyle(accentColor)
                            .disabled(viewModel.isBusy)
                        }
                    }
                }
            }
            .padding(2)
        }
    }

    private var previewColumn: some View {
        let preview = viewModel.previewUpdateInfo
        return VStack(alignment: .leading, spacing: 12) {
            Label("Предпросмотр у пользователей", systemImage: "eye.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(textSecondary)

            // Live popup card matching user apps
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(isDark ? 0.22 : 0.14))
                        .frame(width: 48, height: 48)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(accentColor)
                }

                VStack(spacing: 5) {
                    Text(preview.title ?? "Доступна новая версия Droply")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(textPrimary)
                        .multilineTextAlignment(.center)

                    Text("Нажмите «Установить», чтобы открыть GitHub и скачать обновление.")
                        .font(.system(size: 12))
                        .foregroundStyle(textSecondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 8) {
                    Text("Текущая: \(preview.currentVersion)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(textSecondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accentColor)
                    Text("Новая: \(preview.latestVersion)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(accentColor)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .modifier(AdminFrostedModifier(cornerRadius: 999, isDark: isDark, tint: accentColor))

                if let notes = preview.releaseNotes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 12))
                        .foregroundStyle(textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .modifier(AdminFrostedModifier(cornerRadius: 11, isDark: isDark))
                } else {
                    Text("Здесь появится ваш текст обновления…")
                        .font(.system(size: 12))
                        .foregroundStyle(textSecondary.opacity(0.65))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .modifier(AdminFrostedModifier(cornerRadius: 11, isDark: isDark))
                }

                HStack(spacing: 8) {
                    Text("Позже")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .modifier(AdminFrostedModifier(cornerRadius: 999, isDark: isDark))

                    Button {
                        viewModel.openGitHubPage()
                    } label: {
                        Text("Установить")
                            .font(.system(size: 12.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(AdminGlassButtonStyle(isDark: isDark, tint: accentColor))
                    .foregroundStyle(accentColor)
                }
            }
            .padding(20)
            .modifier(AdminFrostedModifier(cornerRadius: 22, isDark: isDark))

            // Mobile/Desktop OS notification preview strip
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(accentColor)
                    Text(preview.title ?? "Доступна новая версия Droply (\(preview.latestVersion))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(textPrimary)
                        .lineLimit(1)
                }
                Text(preview.releaseNotes ?? "Версия \(preview.latestVersion) — нажмите «Установить», чтобы перейти на GitHub.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .modifier(AdminFrostedModifier(cornerRadius: 16, isDark: isDark))

            Spacer(minLength: 0)
        }
    }

    private var repoStatusChip: some View {
        let valid = viewModel.parsedRepository != nil
        return HStack(spacing: 5) {
            Circle()
                .fill(valid ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(valid ? "GitHub OK" : "Укажите URL")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(valid ? Color.green : Color.orange)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .modifier(AdminFrostedModifier(cornerRadius: 999, isDark: isDark))
    }

    private func glassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .modifier(AdminFrostedModifier(cornerRadius: 18, isDark: isDark))
    }

    private func glassTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .modifier(AdminFrostedModifier(cornerRadius: 10, isDark: isDark))
    }

    private func statusPill(text: String, isError: Bool) -> some View {
        let color: Color = isError ? .red : .green
        return HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(color)
                .font(.system(size: 13))
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(textPrimary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(AdminFrostedModifier(cornerRadius: 14, isDark: isDark, tint: color))
    }
}

private struct AdminFrostedModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isDark: Bool
    var tint: Color? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
                                shape.fill(tint.opacity(isDark ? 0.18 : 0.11))
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

private struct AdminGlassButtonStyle: ButtonStyle {
    let isDark: Bool
    let tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                let glass: Glass = tint.map { Glass.regular.tint($0.opacity(0.24)) } ?? .regular
                configuration.label
                    .contentShape(Capsule())
                    .glassEffect(glass, in: Capsule())
            } else {
                configuration.label
                    .modifier(AdminFrostedModifier(cornerRadius: 999, isDark: isDark, tint: tint))
                    .contentShape(Capsule())
            }
        }
        .opacity(configuration.isPressed ? 0.85 : 1.0)
        .scaleEffect(configuration.isPressed ? 0.94 : 1.0, anchor: .center)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
