import Foundation

public enum AppUpdateConfig {
    /// Ссылка на GitHub-репозиторий приложения для проверки обновлений.
    public static let githubRepositoryURL: String = "https://github.com/wanrd/Droply"
    public static let fallbackVersion: String = "1.0"
}

public struct GitHubRepoRef: Sendable, Equatable {
    public let owner: String
    public let repo: String
    public let repoWebURL: URL
    public let releasesURL: URL
    public let latestReleaseAPIURL: URL
    public let tagsAPIURL: URL
    public let manifestAPIURL: URL
}

public struct AppUpdateInfo: Sendable, Equatable {
    public let latestVersion: String
    public let currentVersion: String
    public let releaseURL: URL
    public let title: String?
    public let releaseNotes: String?
    public let source: String

    public var promptSignature: String {
        "\(latestVersion)|\(title ?? "")|\(releaseNotes ?? "")"
    }

    public init(
        latestVersion: String,
        currentVersion: String,
        releaseURL: URL,
        title: String? = nil,
        releaseNotes: String? = nil,
        source: String = "release"
    ) {
        self.latestVersion = latestVersion
        self.currentVersion = currentVersion
        self.releaseURL = releaseURL
        self.title = title
        self.releaseNotes = releaseNotes
        self.source = source
    }
}

public enum UpdateCheckOutcome: Sendable, Equatable {
    case updateAvailable(AppUpdateInfo)
    case upToDate
    case notConfigured
    case networkFailed
}

public enum AppUpdateChecker {
    private static let maxResponseBytes = 256 * 1024

    public static func currentAppVersion() -> String {
        if let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return AppUpdateConfig.fallbackVersion
    }

    /// Parses and validates a GitHub repository URL strictly (HTTPS on github.com).
    public static func parseRepository(_ rawURL: String) -> GitHubRepoRef? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let rawHost = components.host?.lowercased(),
              rawHost == "github.com" || rawHost == "www.github.com" else {
            return nil
        }

        let segments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard segments.count >= 2 else { return nil }

        let owner = segments[0]
        var repo = segments[1]
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }
        guard isValidIdentifier(owner, maxLength: 39),
              isValidIdentifier(repo, maxLength: 100) else {
            return nil
        }

        guard let repoWebURL = URL(string: "https://github.com/\(owner)/\(repo)"),
              let releasesURL = URL(string: "https://github.com/\(owner)/\(repo)/releases"),
              let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"),
              let tagsAPIURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/tags?per_page=10"),
              let manifestAPIURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/contents/version.json") else {
            return nil
        }

        return GitHubRepoRef(
            owner: owner,
            repo: repo,
            repoWebURL: repoWebURL,
            releasesURL: releasesURL,
            latestReleaseAPIURL: latestReleaseAPIURL,
            tagsAPIURL: tagsAPIURL,
            manifestAPIURL: manifestAPIURL
        )
    }

    /// Strictly checks that a target URL stays on https://github.com/<owner>/<repo> without traversal or credentials.
    public static func strictlyValidatedGitHubURL(_ candidate: String?, repo: GitHubRepoRef) -> URL? {
        guard let candidate else { return nil }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let comps = URLComponents(string: trimmed),
              comps.scheme?.lowercased() == "https",
              comps.user == nil,
              comps.password == nil,
              let host = comps.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return nil
        }

        let pathParts = comps.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard pathParts.count >= 2,
              !pathParts.contains("."),
              !pathParts.contains(".."),
              pathParts[0].caseInsensitiveCompare(repo.owner) == .orderedSame else {
            return nil
        }
        let pathRepo = pathParts[1].hasSuffix(".git") ? String(pathParts[1].dropLast(4)) : pathParts[1]
        guard pathRepo.caseInsensitiveCompare(repo.repo) == .orderedSame else {
            return nil
        }
        return comps.url
    }

    /// Ensures any browser launch target remains strictly on https://github.com/<owner>/<repo>.
    public static func validatedGitHubURL(_ candidate: String?, repo: GitHubRepoRef) -> URL {
        strictlyValidatedGitHubURL(candidate, repo: repo) ?? repo.releasesURL
    }

    public static func isStrictNumericVersion(_ raw: String) -> Bool {
        let stripped = displayVersionLabel(raw)
        guard !stripped.isEmpty, stripped.count <= 32 else { return false }
        let parts = stripped.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 8 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && Int(part) != nil
        }
    }

    public static func extractNumericVersionComponents(_ raw: String) -> [Int]? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let firstDigitIdx = cleaned.firstIndex(where: { $0.isNumber }) else {
            return nil
        }
        let slice = cleaned[firstDigitIdx...]
        let numericPrefix = slice.prefix { ch in
            ch.isNumber || ch == "."
        }
        let parts = numericPrefix.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 8 else { return nil }
        var values: [Int] = []
        values.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty, let num = Int(part), num >= 0 else { return nil }
            values.append(num)
        }
        return values
    }

    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let a = extractNumericVersionComponents(lhs),
              let b = extractNumericVersionComponents(rhs) else {
            return .orderedSame
        }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }

    public static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        guard extractNumericVersionComponents(candidate) != nil,
              extractNumericVersionComponents(current) != nil else {
            return false
        }
        return compareVersions(candidate, current) == .orderedDescending
    }

    public static func displayVersionLabel(_ raw: String) -> String {
        let clean = SecureChannel.sanitizeDisplayText(raw, maxLength: 32)
        if clean.lowercased().hasPrefix("v"), clean.count > 1 {
            return String(clean.dropFirst())
        }
        return clean
    }

    public static func parseReleaseResponse(
        data: Data,
        currentVersion: String,
        repo: GitHubRepoRef
    ) -> AppUpdateInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if (obj["draft"] as? Bool) == true || (obj["prerelease"] as? Bool) == true {
            return nil
        }
        let rawTag = (obj["tag_name"] as? String) ?? (obj["name"] as? String) ?? ""
        let latest = displayVersionLabel(rawTag)
        guard !latest.isEmpty, isVersion(latest, newerThan: currentVersion) else {
            return nil
        }
        let targetURL = validatedGitHubURL(obj["html_url"] as? String, repo: repo)
        let title = (obj["name"] as? String)
            .map { SecureChannel.sanitizeDisplayText($0, maxLength: 80) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let notes = sanitizeReleaseNotes(obj["body"] as? String)
        return AppUpdateInfo(
            latestVersion: latest,
            currentVersion: displayVersionLabel(currentVersion),
            releaseURL: targetURL,
            title: title,
            releaseNotes: notes,
            source: "release"
        )
    }

    public static func parseTagsResponse(
        data: Data,
        currentVersion: String,
        repo: GitHubRepoRef
    ) -> AppUpdateInfo? {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var bestVersion: String?
        for item in items {
            guard let name = item["name"] as? String else { continue }
            let clean = displayVersionLabel(name)
            guard isVersion(clean, newerThan: currentVersion) else { continue }
            if let existing = bestVersion {
                if compareVersions(clean, existing) == .orderedDescending {
                    bestVersion = clean
                }
            } else {
                bestVersion = clean
            }
        }
        guard let latest = bestVersion else { return nil }
        return AppUpdateInfo(
            latestVersion: latest,
            currentVersion: displayVersionLabel(currentVersion),
            releaseURL: repo.releasesURL,
            title: nil,
            releaseNotes: nil,
            source: "tag"
        )
    }

    public static func parseManifestResponse(
        data: Data,
        currentVersion: String,
        repo: GitHubRepoRef
    ) -> AppUpdateInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let platformRaw = (obj["macVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackRaw = (obj["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawVersion = (platformRaw?.isEmpty == false ? platformRaw : fallbackRaw) ?? ""
        let latest = displayVersionLabel(rawVersion)
        guard !latest.isEmpty, isVersion(latest, newerThan: currentVersion) else {
            return nil
        }
        let title = (obj["title"] as? String)
            .map { SecureChannel.sanitizeDisplayText($0, maxLength: 80) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let notes = sanitizeReleaseNotes(obj["notes"] as? String)
        let releaseUrl = validatedGitHubURL(obj["releaseUrl"] as? String, repo: repo)
        return AppUpdateInfo(
            latestVersion: latest,
            currentVersion: displayVersionLabel(currentVersion),
            releaseURL: releaseUrl,
            title: title,
            releaseNotes: notes,
            source: "manifest"
        )
    }

    /// Selects the highest available update and prioritizes admin-authored title/notes from version.json.
    public static func resolvePreferredUpdate(
        release: AppUpdateInfo?,
        manifest: AppUpdateInfo?,
        tags: AppUpdateInfo?,
        repo: GitHubRepoRef
    ) -> AppUpdateInfo? {
        switch (release, manifest) {
        case (.some(let rel), .some(let man)):
            switch compareVersions(man.latestVersion, rel.latestVersion) {
            case .orderedDescending:
                return man
            case .orderedSame:
                let url = man.releaseURL == repo.releasesURL ? rel.releaseURL : man.releaseURL
                return AppUpdateInfo(
                    latestVersion: man.latestVersion,
                    currentVersion: man.currentVersion,
                    releaseURL: url,
                    title: man.title ?? rel.title,
                    releaseNotes: man.releaseNotes ?? rel.releaseNotes,
                    source: "manifest+release"
                )
            case .orderedAscending:
                return rel
            }
        case (.none, .some(let man)):
            return man
        case (.some(let rel), .none):
            return rel
        case (.none, .none):
            return tags
        }
    }

    public static func checkForUpdates(
        repositoryURL: String = AppUpdateConfig.githubRepositoryURL,
        currentVersion: String = currentAppVersion()
    ) async -> AppUpdateInfo? {
        switch await checkForUpdatesOutcome(repositoryURL: repositoryURL, currentVersion: currentVersion) {
        case .updateAvailable(let info):
            return info
        default:
            return nil
        }
    }

    public static func checkForUpdatesOutcome(
        repositoryURL: String = AppUpdateConfig.githubRepositoryURL,
        currentVersion: String = currentAppVersion()
    ) async -> UpdateCheckOutcome {
        guard let repo = parseRepository(repositoryURL) else {
            return .notConfigured
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = APIRedirectGuardDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        async let manifestTask = fetchGitHubJSONStatus(url: repo.manifestAPIURL, accept: "application/vnd.github.raw+json", session: session)
        async let releaseTask = fetchGitHubJSONStatus(url: repo.latestReleaseAPIURL, accept: "application/vnd.github+json", session: session)

        let manifestRes = await manifestTask
        let releaseRes = await releaseTask

        let manifestInfo = manifestRes.data.flatMap { parseManifestResponse(data: $0, currentVersion: currentVersion, repo: repo) }
        let releaseInfo = releaseRes.data.flatMap { parseReleaseResponse(data: $0, currentVersion: currentVersion, repo: repo) }

        if let preferred = resolvePreferredUpdate(release: releaseInfo, manifest: manifestInfo, tags: nil, repo: repo) {
            return .updateAvailable(preferred)
        }

        let tagsRes = await fetchGitHubJSONStatus(url: repo.tagsAPIURL, accept: "application/vnd.github+json", session: session)
        if let tagsInfo = tagsRes.data.flatMap({ parseTagsResponse(data: $0, currentVersion: currentVersion, repo: repo) }) {
            return .updateAvailable(tagsInfo)
        }

        let anyReachable = manifestRes.reachable || releaseRes.reachable || tagsRes.reachable
        return anyReachable ? .upToDate : .networkFailed
    }

    private static func fetchGitHubJSONStatus(
        url: URL,
        accept: String,
        session: URLSession
    ) async -> (data: Data?, reachable: Bool) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("Droply-Updater/1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return (nil, false)
        }
        if http.statusCode == 404 {
            return (nil, true)
        }
        guard http.statusCode == 200, data.count <= maxResponseBytes else {
            return (nil, false)
        }
        return (data, true)
    }

    private static func sanitizeReleaseNotes(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let clean = SecureChannel.sanitizeDisplayText(raw, maxLength: 500, allowNewlines: true)
        return clean.isEmpty ? nil : clean
    }

    private static func isValidIdentifier(_ value: String, maxLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maxLength, value != ".", value != ".." else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || // 0-9
            (scalar.value >= 65 && scalar.value <= 90) || // A-Z
            (scalar.value >= 97 && scalar.value <= 122) || // a-z
            scalar == "-" || scalar == "_" || scalar == "."
        }
    }
}

public enum AdminManifestError: Error, LocalizedError, Sendable {
    case invalidVersion
    case invalidReleaseURL
    case emptyNotes
    case notesTooLong(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidVersion:
            return "Некорректный формат версии (укажите только числа и точки, например 1.1 или 1.2.0)."
        case .invalidReleaseURL:
            return "Ссылка для установки должна вести на https://github.com того же репозитория без посторонних путей."
        case .emptyNotes:
            return "Введите текст уведомления, который увидят пользователи."
        case .notesTooLong(let count):
            return "Текст уведомления слишком длинный (\(count) символов, максимум 500)."
        }
    }
}

public struct AdminUpdateManifest: Codable, Sendable, Equatable {
    public let version: String
    public let macVersion: String
    public let androidVersion: String
    public let title: String
    public let notes: String
    public let releaseUrl: String
    public let updatedAt: String?

    public init(
        version: String,
        macVersion: String,
        androidVersion: String,
        title: String,
        notes: String,
        releaseUrl: String,
        updatedAt: String? = nil
    ) {
        self.version = version
        self.macVersion = macVersion
        self.androidVersion = androidVersion
        self.title = title
        self.notes = notes
        self.releaseUrl = releaseUrl
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let ver = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        self.version = ver
        self.macVersion = try c.decodeIfPresent(String.self, forKey: .macVersion) ?? ver
        self.androidVersion = try c.decodeIfPresent(String.self, forKey: .androidVersion) ?? ver
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        self.releaseUrl = try c.decodeIfPresent(String.self, forKey: .releaseUrl) ?? ""
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    public func validated(for repo: GitHubRepoRef) throws -> AdminUpdateManifest {
        let cleanVersion = AppUpdateChecker.displayVersionLabel(version)
        let cleanMac = AppUpdateChecker.displayVersionLabel(macVersion.isEmpty ? cleanVersion : macVersion)
        let cleanAndroid = AppUpdateChecker.displayVersionLabel(androidVersion.isEmpty ? cleanVersion : androidVersion)

        guard AppUpdateChecker.isStrictNumericVersion(cleanVersion),
              AppUpdateChecker.isStrictNumericVersion(cleanMac),
              AppUpdateChecker.isStrictNumericVersion(cleanAndroid) else {
            throw AdminManifestError.invalidVersion
        }

        let trimmedUrl = releaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeUrl: String
        if trimmedUrl.isEmpty {
            safeUrl = repo.releasesURL.absoluteString
        } else {
            guard let checked = AppUpdateChecker.strictlyValidatedGitHubURL(trimmedUrl, repo: repo) else {
                throw AdminManifestError.invalidReleaseURL
            }
            safeUrl = checked.absoluteString
        }

        let cleanTitle = SecureChannel.sanitizeDisplayText(title, maxLength: 80)
        let sanitizedNotesUnbounded = SecureChannel.sanitizeDisplayText(notes, maxLength: 5000, allowNewlines: true)
        guard !sanitizedNotesUnbounded.isEmpty else {
            throw AdminManifestError.emptyNotes
        }
        guard sanitizedNotesUnbounded.count <= 500 else {
            throw AdminManifestError.notesTooLong(sanitizedNotesUnbounded.count)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())

        return AdminUpdateManifest(
            version: cleanVersion,
            macVersion: cleanMac,
            androidVersion: cleanAndroid,
            title: cleanTitle,
            notes: sanitizedNotesUnbounded,
            releaseUrl: safeUrl,
            updatedAt: stamp
        )
    }

    public func encodedJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}

private final class APIRedirectGuardDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if let url = request.url,
           url.scheme?.lowercased() == "https",
           url.host?.lowercased() == "api.github.com" {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}
