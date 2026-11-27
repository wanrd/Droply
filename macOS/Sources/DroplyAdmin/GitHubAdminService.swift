import Foundation
import DroplyCore

enum AdminPublishError: Error, LocalizedError, Sendable {
    case invalidRepositoryURL
    case missingToken
    case invalidVersion
    case invalidManifest
    case httpError(Int, String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryURL:
            return "Укажите корректную HTTPS-ссылку на GitHub-репозиторий (например, https://github.com/user/Droply)."
        case .missingToken:
            return "Введите GitHub Personal Access Token с правом Contents: Read & write."
        case .invalidVersion:
            return "Укажите корректный числовой номер версии (например, 1.1 или 1.2.0)."
        case .invalidManifest:
            return "Не удалось сформировать корректный JSON манифеста обновления."
        case .httpError(let code, let detail):
            if code == 401 || code == 403 {
                return "Токен GitHub отклонён или не имеет прав на запись в репозиторий (HTTP \(code))."
            }
            if code == 404 {
                return "Репозиторий или ветка не найдены на GitHub (HTTP 404)."
            }
            return "Ошибка GitHub API (HTTP \(code)): \(detail)"
        case .networkError(let msg):
            return "Сетевая ошибка: \(msg)"
        }
    }
}

struct AdminPublishResult: Sendable {
    let manifest: AdminUpdateManifest
    let webTargetURL: URL
    let releaseNoteStatus: String?
}

enum GitHubAdminService {
    private static let maxResponseBytes = 256 * 1024

    static func fetchRemoteManifest(
        repositoryURL: String,
        token: String
    ) async throws -> (manifest: AdminUpdateManifest?, sha: String?) {
        guard let repo = AppUpdateChecker.parseRepository(repositoryURL) else {
            throw AdminPublishError.invalidRepositoryURL
        }
        let session = makeSecureSession()
        defer { session.invalidateAndCancel() }
        return try await fetchManifestFile(repo: repo, token: token, session: session)
    }

    static func publishUpdate(
        repositoryURL: String,
        token: String,
        manifest: AdminUpdateManifest,
        createGitHubRelease: Bool
    ) async throws -> AdminPublishResult {
        guard let repo = AppUpdateChecker.parseRepository(repositoryURL) else {
            throw AdminPublishError.invalidRepositoryURL
        }
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty,
              !cleanToken.contains(where: { $0.isNewline }) else {
            throw AdminPublishError.missingToken
        }

        let sanitized = try manifest.validated(for: repo)
        let session = makeSecureSession()
        defer { session.invalidateAndCancel() }

        let manifestData = try sanitized.encodedJSONData()

        var publishHTTPStatus = 0
        var lastRespData = Data()
        for attempt in 0..<2 {
            let existing = try await fetchManifestFile(repo: repo, token: cleanToken, session: session)
            var putBody: [String: Any] = [
                "message": "Выпуск обновления Droply \(sanitized.version)",
                "content": manifestData.base64EncodedString()
            ]
            if let sha = existing.sha {
                putBody["sha"] = sha
            }
            let bodyData = try JSONSerialization.data(withJSONObject: putBody)

            let (respData, http) = try await performGitHubAPI(
                url: repo.manifestAPIURL,
                method: "PUT",
                token: cleanToken,
                body: bodyData,
                session: session
            )
            publishHTTPStatus = http.statusCode
            lastRespData = respData
            if http.statusCode == 200 || http.statusCode == 201 {
                break
            }
            // Retry once on 409 SHA conflict (concurrent push/update on GitHub)
            if http.statusCode == 409 && attempt == 0 {
                continue
            }
            let msg = extractGitHubMessage(from: respData) ?? "Не удалось обновить version.json"
            throw AdminPublishError.httpError(http.statusCode, msg)
        }
        guard publishHTTPStatus == 200 || publishHTTPStatus == 201 else {
            let msg = extractGitHubMessage(from: lastRespData) ?? "Не удалось обновить version.json"
            throw AdminPublishError.httpError(publishHTTPStatus, msg)
        }

        var finalURL = URL(string: sanitized.releaseUrl) ?? repo.releasesURL
        var releaseNoteStatus: String?

        if createGitHubRelease {
            let tag = "v\(sanitized.version)"
            let releaseName = sanitized.title.isEmpty ? "Droply \(sanitized.version)" : sanitized.title
            let relPayload: [String: Any] = [
                "tag_name": tag,
                "name": releaseName,
                "body": sanitized.notes,
                "draft": false,
                "prerelease": false
            ]
            let relData = try JSONSerialization.data(withJSONObject: relPayload)
            let releasesEndpoint = URL(string: "https://api.github.com/repos/\(repo.owner)/\(repo.repo)/releases")!
            let (relRespData, relHTTP) = try await performGitHubAPI(
                url: releasesEndpoint,
                method: "POST",
                token: cleanToken,
                body: relData,
                session: session
            )
            if relHTTP.statusCode == 200 || relHTTP.statusCode == 201 {
                if let obj = try? JSONSerialization.jsonObject(with: relRespData) as? [String: Any],
                   let html = obj["html_url"] as? String {
                    finalURL = AppUpdateChecker.validatedGitHubURL(html, repo: repo)
                }
                releaseNoteStatus = "Создан GitHub Release \(tag)"
            } else if relHTTP.statusCode == 422 {
                releaseNoteStatus = "Манифест обновлён (тег \(tag) уже существовал на GitHub)"
            } else {
                let errMsg = extractGitHubMessage(from: relRespData) ?? "HTTP \(relHTTP.statusCode)"
                releaseNoteStatus = "Манифест опубликован, но Release не создан: \(errMsg)"
            }
        }

        return AdminPublishResult(
            manifest: sanitized,
            webTargetURL: finalURL,
            releaseNoteStatus: releaseNoteStatus
        )
    }

    private static func fetchManifestFile(
        repo: GitHubRepoRef,
        token: String,
        session: URLSession
    ) async throws -> (manifest: AdminUpdateManifest?, sha: String?) {
        let (data, http) = try await performGitHubAPI(
            url: repo.manifestAPIURL,
            method: "GET",
            token: token,
            body: nil,
            session: session
        )
        if http.statusCode == 404 {
            return (nil, nil)
        }
        guard http.statusCode == 200 else {
            let msg = extractGitHubMessage(from: data) ?? "Не удалось прочитать version.json"
            throw AdminPublishError.httpError(http.statusCode, msg)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        if let entryType = obj["type"] as? String, entryType != "file" {
            throw AdminPublishError.httpError(422, "version.json на GitHub должен быть файлом, а не папкой")
        }
        let sha = obj["sha"] as? String
        if let rawContent = obj["content"] as? String {
            let cleanBase64 = rawContent.replacingOccurrences(of: "\n", with: "")
            if let decoded = Data(base64Encoded: cleanBase64),
               let parsed = try? JSONDecoder().decode(AdminUpdateManifest.self, from: decoded) {
                return (parsed, sha)
            }
        }
        return (nil, sha)
    }

    private static func performGitHubAPI(
        url: URL,
        method: String,
        token: String,
        body: Data?,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("Droply-Admin/1.0", forHTTPHeaderField: "User-Agent")
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanToken.isEmpty {
            req.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw AdminPublishError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AdminPublishError.networkError("Некорректный HTTP-ответ")
        }
        guard data.count <= maxResponseBytes else {
            throw AdminPublishError.networkError("Ответ сервера превысил допустимый размер")
        }
        return (data, http)
    }

    private static func extractGitHubMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? String else {
            return nil
        }
        return SecureChannel.sanitizeDisplayText(message, maxLength: 140)
    }

    private static func makeSecureSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: AdminRedirectGuard(), delegateQueue: nil)
    }
}

private final class AdminRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
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
