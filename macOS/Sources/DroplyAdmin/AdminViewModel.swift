import AppKit
import Foundation
import SwiftUI
import DroplyCore

@MainActor
final class AdminViewModel: ObservableObject {
    private enum PrefKey {
        static let repoURL = "droply.admin.repoURL"
        static let isDark = "droply.admin.isDarkTheme"
    }

    @Published var isDarkTheme: Bool = false {
        didSet { UserDefaults.standard.set(isDarkTheme, forKey: PrefKey.isDark) }
    }
    @Published var repositoryURL: String = "" {
        didSet { UserDefaults.standard.set(repositoryURL, forKey: PrefKey.repoURL) }
    }
    @Published var githubToken: String = ""
    @Published var hasSavedToken: Bool = false

    @Published var versionText: String = "1.1" {
        didSet {
            if !separatePlatformVersions {
                if macVersionText != versionText { macVersionText = versionText }
                if androidVersionText != versionText { androidVersionText = versionText }
            }
        }
    }
    @Published var separatePlatformVersions: Bool = false
    @Published var macVersionText: String = "1.1"
    @Published var androidVersionText: String = "1.1"
    @Published var notificationTitle: String = "Вышла новая версия Droply"
    @Published var notificationBody: String = ""
    @Published var customReleaseURL: String = ""
    @Published var createGitHubRelease: Bool = true

    @Published var isBusy: Bool = false
    @Published var statusBanner: String?
    @Published var errorBanner: String?

    var parsedRepository: GitHubRepoRef? {
        AppUpdateChecker.parseRepository(repositoryURL)
    }

    var effectiveMacVersion: String {
        let raw = separatePlatformVersions ? macVersionText : versionText
        return AppUpdateChecker.displayVersionLabel(raw)
    }

    var effectiveAndroidVersion: String {
        let raw = separatePlatformVersions ? androidVersionText : versionText
        return AppUpdateChecker.displayVersionLabel(raw)
    }

    var previewUpdateInfo: AppUpdateInfo {
        let targetVersion = effectiveMacVersion.isEmpty ? "1.1" : effectiveMacVersion
        let repo = parsedRepository
        let fallbackURL = repo?.releasesURL ?? URL(string: "https://github.com")!
        let resolvedURL: URL = if let repo, !customReleaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            AppUpdateChecker.validatedGitHubURL(customReleaseURL, repo: repo)
        } else {
            fallbackURL
        }
        let cleanTitle = SecureChannel.sanitizeDisplayText(notificationTitle, maxLength: 80)
        let cleanNotes = SecureChannel.sanitizeDisplayText(notificationBody, maxLength: 500, allowNewlines: true)
        return AppUpdateInfo(
            latestVersion: targetVersion,
            currentVersion: AppUpdateConfig.fallbackVersion,
            releaseURL: resolvedURL,
            title: cleanTitle.isEmpty ? nil : cleanTitle,
            releaseNotes: cleanNotes.isEmpty ? nil : cleanNotes,
            source: "preview"
        )
    }

    init() {
        let defaults = UserDefaults.standard
        self.isDarkTheme = defaults.bool(forKey: PrefKey.isDark)
        let savedRepo = defaults.string(forKey: PrefKey.repoURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.repositoryURL = !savedRepo.isEmpty ? savedRepo : AppUpdateConfig.githubRepositoryURL

        if let storedToken = KeychainStore.loadToken(), !storedToken.isEmpty {
            self.githubToken = storedToken
            self.hasSavedToken = true
        }
    }

    func saveTokenToKeychain() {
        let trimmed = githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            KeychainStore.deleteToken()
            hasSavedToken = false
            setStatus("Токен удалён из Связки ключей")
            return
        }
        if KeychainStore.saveToken(trimmed) {
            githubToken = trimmed
            hasSavedToken = true
            setStatus("Токен надёжно сохранён в Связке ключей macOS")
        } else {
            setError("Не удалось сохранить токен в Связку ключей")
        }
    }

    func clearTokenFromKeychain() {
        KeychainStore.deleteToken()
        githubToken = ""
        hasSavedToken = false
        setStatus("Токен удалён из Связки ключей")
    }

    func bumpMinorVersion() {
        let base = separatePlatformVersions ? macVersionText : versionText
        let next = incrementedMinor(from: base)
        if separatePlatformVersions {
            macVersionText = incrementedMinor(from: macVersionText)
            androidVersionText = incrementedMinor(from: androidVersionText)
            versionText = macVersionText
        } else {
            versionText = next
            macVersionText = next
            androidVersionText = next
        }
    }

    func loadFromGitHub() {
        guard parsedRepository != nil else {
            setError(AdminPublishError.invalidRepositoryURL.localizedDescription)
            return
        }
        guard !isBusy else { return }
        isBusy = true
        clearBanners()

        let repoURL = repositoryURL
        let token = githubToken

        Task { [weak self] in
            do {
                let fetched = try await GitHubAdminService.fetchRemoteManifest(repositoryURL: repoURL, token: token)
                await MainActor.run {
                    guard let self else { return }
                    self.isBusy = false
                    if let manifest = fetched.manifest {
                        self.applyManifestToForm(manifest)
                        self.setStatus("Загружена опубликованная конфигурация (v\(manifest.version))")
                    } else {
                        self.setStatus("На GitHub ещё нет файла version.json — будет создан при публикации")
                    }
                }
            } catch {
                await MainActor.run {
                    self?.isBusy = false
                    self?.setError(error.localizedDescription)
                }
            }
        }
    }

    func publishToGitHub() {
        guard !isBusy else { return }
        guard let repo = parsedRepository else {
            setError(AdminPublishError.invalidRepositoryURL.localizedDescription)
            return
        }

        let token = githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            setError(AdminPublishError.missingToken.localizedDescription)
            return
        }
        if KeychainStore.saveToken(token) {
            hasSavedToken = true
        }

        let draft = buildDraftManifest(for: repo)
        let shouldCreateRelease = createGitHubRelease
        let repoURL = repositoryURL

        isBusy = true
        clearBanners()

        Task { [weak self] in
            do {
                let result = try await GitHubAdminService.publishUpdate(
                    repositoryURL: repoURL,
                    token: token,
                    manifest: draft,
                    createGitHubRelease: shouldCreateRelease
                )
                await MainActor.run {
                    guard let self else { return }
                    self.isBusy = false
                    var msg = "Обновление \(result.manifest.version) опубликовано на GitHub! Пользователи получат уведомление."
                    if let note = result.releaseNoteStatus {
                        msg += " (\(note))"
                    }
                    self.setStatus(msg)
                }
            } catch {
                await MainActor.run {
                    self?.isBusy = false
                    self?.setError(error.localizedDescription)
                }
            }
        }
    }

    func saveLocalManifestFile() {
        let validationRepo = parsedRepository
            ?? AppUpdateChecker.parseRepository(customReleaseURL)
            ?? AppUpdateChecker.parseRepository("https://github.com/owner/Droply")!
        do {
            let trimmedCustom = customReleaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let draft = AdminUpdateManifest(
                version: separatePlatformVersions ? effectiveMacVersion : AppUpdateChecker.displayVersionLabel(versionText),
                macVersion: separatePlatformVersions ? effectiveMacVersion : AppUpdateChecker.displayVersionLabel(versionText),
                androidVersion: separatePlatformVersions ? effectiveAndroidVersion : AppUpdateChecker.displayVersionLabel(versionText),
                title: notificationTitle,
                notes: notificationBody,
                releaseUrl: parsedRepository != nil || !trimmedCustom.isEmpty ? trimmedCustom : ""
            )
            let validated = try draft.validated(for: validationRepo)
            let manifestToWrite = parsedRepository != nil || !trimmedCustom.isEmpty
                ? validated
                : AdminUpdateManifest(
                    version: validated.version,
                    macVersion: validated.macVersion,
                    androidVersion: validated.androidVersion,
                    title: validated.title,
                    notes: validated.notes,
                    releaseUrl: "",
                    updatedAt: validated.updatedAt
                )
            let data = try manifestToWrite.encodedJSONData()

            let panel = NSSavePanel()
            panel.nameFieldStringValue = "version.json"
            panel.canCreateDirectories = true
            panel.title = "Сохранить version.json"
            let defaultProjectDir = URL(fileURLWithPath: "/Users/islam/.gemini/antigravity/scratch/WiFiDrop", isDirectory: true)
            if FileManager.default.fileExists(atPath: defaultProjectDir.path) {
                panel.directoryURL = defaultProjectDir
            }

            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            setStatus("Файл \(url.lastPathComponent) сохранён — теперь можно сделать git push на GitHub")
        } catch {
            setError(error.localizedDescription)
        }
    }

    func openGitHubPage() {
        NSWorkspace.shared.open(previewUpdateInfo.releaseURL)
    }

    private func buildDraftManifest(for repo: GitHubRepoRef) -> AdminUpdateManifest {
        let baseVer = separatePlatformVersions ? effectiveMacVersion : AppUpdateChecker.displayVersionLabel(versionText)
        let macVer = separatePlatformVersions ? effectiveMacVersion : baseVer
        let andVer = separatePlatformVersions ? effectiveAndroidVersion : baseVer
        let targetUrl = customReleaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return AdminUpdateManifest(
            version: baseVer,
            macVersion: macVer,
            androidVersion: andVer,
            title: notificationTitle,
            notes: notificationBody,
            releaseUrl: targetUrl.isEmpty ? repo.releasesURL.absoluteString : targetUrl
        )
    }

    private func applyManifestToForm(_ manifest: AdminUpdateManifest) {
        let baseVer = manifest.version.trimmingCharacters(in: .whitespacesAndNewlines)
        let macVer = manifest.macVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let andVer = manifest.androidVersion.trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedBase = baseVer.isEmpty ? "1.0" : baseVer
        let resolvedMac = macVer.isEmpty ? resolvedBase : macVer
        let resolvedAnd = andVer.isEmpty ? resolvedBase : andVer

        separatePlatformVersions = resolvedMac != resolvedAnd
        versionText = resolvedBase
        macVersionText = resolvedMac
        androidVersionText = resolvedAnd
        if !manifest.title.isEmpty {
            notificationTitle = manifest.title
        }
        notificationBody = manifest.notes

        let trimmedUrl = manifest.releaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDefaultReleaseUrl = trimmedUrl.isEmpty ||
            (parsedRepository.map {
                trimmedUrl.caseInsensitiveCompare($0.releasesURL.absoluteString) == .orderedSame ||
                trimmedUrl.lowercased().contains("/releases/tag/")
            } ?? false)
        customReleaseURL = isDefaultReleaseUrl ? "" : trimmedUrl
    }

    private func incrementedMinor(from raw: String) -> String {
        guard var parts = AppUpdateChecker.extractNumericVersionComponents(raw), !parts.isEmpty else {
            return "1.1"
        }
        if parts.count == 1 {
            parts.append(1)
        } else {
            parts[1] += 1
            for i in 2..<parts.count {
                parts[i] = 0
            }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    private func clearBanners() {
        errorBanner = nil
        statusBanner = nil
    }

    private func setStatus(_ text: String) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            errorBanner = nil
            statusBanner = text
        }
    }

    private func setError(_ text: String) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            statusBanner = nil
            errorBanner = text
        }
    }
}
