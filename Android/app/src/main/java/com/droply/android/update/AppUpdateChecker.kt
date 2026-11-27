package com.droply.android.update

import android.content.Context
import android.content.Intent
import android.net.Uri
import com.droply.android.protocol.SecureChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.URL
import java.util.Locale
import javax.net.ssl.HttpsURLConnection

object AppUpdateConfig {
    /**
     * Ссылка на GitHub-репозиторий приложения для проверки обновлений.
     */
    const val GITHUB_REPOSITORY_URL: String = "https://github.com/wanrd/Droply"
    const val FALLBACK_VERSION: String = "1.0"
}

data class GitHubRepoRef(
    val owner: String,
    val repo: String,
    val repoWebUrl: String,
    val releasesUrl: String,
    val latestReleaseApiUrl: String,
    val tagsApiUrl: String,
    val manifestApiUrl: String
)

data class AppUpdateInfo(
    val latestVersion: String,
    val currentVersion: String,
    val releaseUrl: String,
    val title: String? = null,
    val releaseNotes: String? = null,
    val source: String = "release"
) {
    val promptSignature: String
        get() = "$latestVersion|${title.orEmpty()}|${releaseNotes.orEmpty()}"
}

sealed class UpdateCheckOutcome {
    data class Available(val info: AppUpdateInfo) : UpdateCheckOutcome()
    data object UpToDate : UpdateCheckOutcome()
    data object NotConfigured : UpdateCheckOutcome()
    data object NetworkFailed : UpdateCheckOutcome()
}

object AppUpdateChecker {
    private const val MAX_RESPONSE_BYTES = 256 * 1024

    fun currentAppVersion(context: Context): String {
        val raw = runCatching {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        }.getOrNull()?.trim().orEmpty()
        return raw.ifEmpty { AppUpdateConfig.FALLBACK_VERSION }
    }

    fun isConfigured(): Boolean = parseRepository(AppUpdateConfig.GITHUB_REPOSITORY_URL) != null

    /**
     * Parses and validates a GitHub repository URL strictly (HTTPS on github.com).
     */
    fun parseRepository(rawUrl: String): GitHubRepoRef? {
        val trimmed = rawUrl.trim()
        if (trimmed.isEmpty()) return null
        val uri = runCatching { java.net.URI(trimmed) }.getOrNull() ?: return null
        if (!uri.scheme.equals("https", ignoreCase = true)) return null
        if (!uri.userInfo.isNullOrEmpty()) return null

        val host = uri.host?.lowercase(Locale.US) ?: return null
        if (host != "github.com" && host != "www.github.com") return null

        val segments = (uri.rawPath ?: "")
            .split('/')
            .filter { it.isNotEmpty() }
        if (segments.size < 2) return null

        val owner = segments[0]
        var repo = segments[1]
        if (repo.endsWith(".git")) {
            repo = repo.removeSuffix(".git")
        }
        if (!isValidIdentifier(owner, maxLen = 39) || !isValidIdentifier(repo, maxLen = 100)) {
            return null
        }

        return GitHubRepoRef(
            owner = owner,
            repo = repo,
            repoWebUrl = "https://github.com/$owner/$repo",
            releasesUrl = "https://github.com/$owner/$repo/releases",
            latestReleaseApiUrl = "https://api.github.com/repos/$owner/$repo/releases/latest",
            tagsApiUrl = "https://api.github.com/repos/$owner/$repo/tags?per_page=10",
            manifestApiUrl = "https://api.github.com/repos/$owner/$repo/contents/version.json"
        )
    }

    /**
     * Ensures any browser launch target stays pinned strictly to https://github.com/<owner>/<repo>.
     */
    fun validatedGitHubUrl(candidate: String?, repo: GitHubRepoRef): String {
        val trimmed = candidate?.trim().orEmpty()
        if (trimmed.isEmpty()) return repo.releasesUrl

        val uri = runCatching { java.net.URI(trimmed) }.getOrNull() ?: return repo.releasesUrl
        if (!uri.scheme.equals("https", ignoreCase = true)) return repo.releasesUrl
        if (!uri.userInfo.isNullOrEmpty()) return repo.releasesUrl

        val host = uri.host?.lowercase(Locale.US) ?: return repo.releasesUrl
        if (host != "github.com" && host != "www.github.com") return repo.releasesUrl

        val parts = (uri.rawPath ?: "")
            .split('/')
            .filter { it.isNotEmpty() }
        if (parts.size < 2 || parts.any { it == "." || it == ".." }) return repo.releasesUrl
        if (!parts[0].equals(repo.owner, ignoreCase = true)) return repo.releasesUrl

        val pathRepo = if (parts[1].endsWith(".git")) parts[1].removeSuffix(".git") else parts[1]
        if (!pathRepo.equals(repo.repo, ignoreCase = true)) return repo.releasesUrl

        return uri.toASCIIString()
    }

    fun extractNumericVersionComponents(raw: String): List<Int>? {
        val cleaned = raw.trim()
        if (cleaned.isEmpty()) return null
        val firstDigitIdx = cleaned.indexOfFirst { it.isDigit() }
        if (firstDigitIdx < 0) return null

        val numericPrefix = buildString {
            for (i in firstDigitIdx until cleaned.length) {
                val ch = cleaned[i]
                if (ch.isDigit() || ch == '.') append(ch) else break
            }
        }
        val parts = numericPrefix.split('.')
        if (parts.isEmpty() || parts.size > 8) return null
        val values = ArrayList<Int>(parts.size)
        for (part in parts) {
            if (part.isEmpty()) return null
            val n = part.toIntOrNull() ?: return null
            if (n < 0) return null
            values.add(n)
        }
        return values
    }

    fun compareVersions(lhs: String, rhs: String): Int {
        val a = extractNumericVersionComponents(lhs) ?: return 0
        val b = extractNumericVersionComponents(rhs) ?: return 0
        val count = maxOf(a.size, b.size)
        for (i in 0 until count) {
            val av = if (i < a.size) a[i] else 0
            val bv = if (i < b.size) b[i] else 0
            if (av != bv) return av.compareTo(bv)
        }
        return 0
    }

    fun isVersionNewer(candidate: String, current: String): Boolean {
        if (extractNumericVersionComponents(candidate) == null ||
            extractNumericVersionComponents(current) == null
        ) {
            return false
        }
        return compareVersions(candidate, current) > 0
    }

    fun displayVersionLabel(raw: String): String {
        val clean = SecureChannel.sanitizeDisplayText(raw, maxLength = 32)
        return if ((clean.startsWith("v") || clean.startsWith("V")) && clean.length > 1) {
            clean.substring(1)
        } else {
            clean
        }
    }

    fun parseReleaseResponse(
        jsonBody: String,
        currentVersion: String,
        repo: GitHubRepoRef
    ): AppUpdateInfo? {
        val obj = runCatching { JSONObject(jsonBody) }.getOrNull() ?: return null
        if (obj.optBoolean("draft", false) || obj.optBoolean("prerelease", false)) {
            return null
        }
        val rawTag = obj.optString("tag_name").takeIf { it.isNotBlank() }
            ?: obj.optString("name")
        val latest = displayVersionLabel(rawTag)
        if (latest.isEmpty() || !isVersionNewer(latest, currentVersion)) return null

        val targetUrl = validatedGitHubUrl(obj.optString("html_url"), repo)
        val title = SecureChannel.sanitizeDisplayText(obj.optString("name"), maxLength = 80)
            .ifEmpty { null }
        val notes = sanitizeReleaseNotes(obj.optString("body"))
        return AppUpdateInfo(
            latestVersion = latest,
            currentVersion = displayVersionLabel(currentVersion),
            releaseUrl = targetUrl,
            title = title,
            releaseNotes = notes,
            source = "release"
        )
    }

    fun parseTagsResponse(
        jsonBody: String,
        currentVersion: String,
        repo: GitHubRepoRef
    ): AppUpdateInfo? {
        val arr = runCatching { JSONArray(jsonBody) }.getOrNull() ?: return null
        var bestVersion: String? = null
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            val clean = displayVersionLabel(obj.optString("name"))
            if (!isVersionNewer(clean, currentVersion)) continue
            bestVersion = if (bestVersion == null || compareVersions(clean, bestVersion) > 0) {
                clean
            } else {
                bestVersion
            }
        }
        val latest = bestVersion ?: return null
        return AppUpdateInfo(
            latestVersion = latest,
            currentVersion = displayVersionLabel(currentVersion),
            releaseUrl = repo.releasesUrl,
            title = null,
            releaseNotes = null,
            source = "tag"
        )
    }

    fun parseManifestResponse(
        jsonBody: String,
        currentVersion: String,
        repo: GitHubRepoRef
    ): AppUpdateInfo? {
        val obj = runCatching { JSONObject(jsonBody) }.getOrNull() ?: return null
        val platformRaw = obj.optString("androidVersion").trim()
        val fallbackRaw = obj.optString("version").trim()
        val rawVersion = platformRaw.ifEmpty { fallbackRaw }
        val latest = displayVersionLabel(rawVersion)
        if (latest.isEmpty() || !isVersionNewer(latest, currentVersion)) return null

        val title = SecureChannel.sanitizeDisplayText(obj.optString("title"), maxLength = 80)
            .ifEmpty { null }
        val notes = sanitizeReleaseNotes(obj.optString("notes"))
        val targetUrl = validatedGitHubUrl(obj.optString("releaseUrl"), repo)
        return AppUpdateInfo(
            latestVersion = latest,
            currentVersion = displayVersionLabel(currentVersion),
            releaseUrl = targetUrl,
            title = title,
            releaseNotes = notes,
            source = "manifest"
        )
    }

    /**
     * Picks whichever update has the higher version, preferring admin-authored title/notes from version.json.
     */
    fun resolvePreferredUpdate(
        release: AppUpdateInfo?,
        manifest: AppUpdateInfo?,
        tags: AppUpdateInfo?,
        repo: GitHubRepoRef
    ): AppUpdateInfo? {
        return when {
            release != null && manifest != null -> {
                val cmp = compareVersions(manifest.latestVersion, release.latestVersion)
                when {
                    cmp > 0 -> manifest
                    cmp == 0 -> {
                        val url = if (manifest.releaseUrl == repo.releasesUrl) release.releaseUrl else manifest.releaseUrl
                        AppUpdateInfo(
                            latestVersion = manifest.latestVersion,
                            currentVersion = manifest.currentVersion,
                            releaseUrl = url,
                            title = manifest.title ?: release.title,
                            releaseNotes = manifest.releaseNotes ?: release.releaseNotes,
                            source = "manifest+release"
                        )
                    }
                    else -> release
                }
            }
            manifest != null -> manifest
            release != null -> release
            else -> tags
        }
    }

    fun checkForUpdates(
        repositoryUrl: String = AppUpdateConfig.GITHUB_REPOSITORY_URL,
        currentVersion: String
    ): AppUpdateInfo? = when (val outcome = checkForUpdatesOutcome(repositoryUrl, currentVersion)) {
        is UpdateCheckOutcome.Available -> outcome.info
        else -> null
    }

    fun checkForUpdatesOutcome(
        repositoryUrl: String = AppUpdateConfig.GITHUB_REPOSITORY_URL,
        currentVersion: String
    ): UpdateCheckOutcome {
        val repo = parseRepository(repositoryUrl) ?: return UpdateCheckOutcome.NotConfigured

        val manifestRes = fetchGitHubJsonStatus(repo.manifestApiUrl, "application/vnd.github.raw+json")
        val releaseRes = fetchGitHubJsonStatus(repo.latestReleaseApiUrl, "application/vnd.github+json")

        val manifestInfo = manifestRes.body?.let { parseManifestResponse(it, currentVersion, repo) }
        val releaseInfo = releaseRes.body?.let { parseReleaseResponse(it, currentVersion, repo) }

        resolvePreferredUpdate(releaseInfo, manifestInfo, null, repo)?.let {
            return UpdateCheckOutcome.Available(it)
        }

        val tagsRes = fetchGitHubJsonStatus(repo.tagsApiUrl, "application/vnd.github+json")
        tagsRes.body?.let { body ->
            parseTagsResponse(body, currentVersion, repo)?.let {
                return UpdateCheckOutcome.Available(it)
            }
        }

        val anyHttpReachable = manifestRes.reachable || releaseRes.reachable || tagsRes.reachable
        return if (anyHttpReachable) UpdateCheckOutcome.UpToDate else UpdateCheckOutcome.NetworkFailed
    }

    fun buildOpenGitHubIntent(url: String, fallbackRepoUrl: String = AppUpdateConfig.GITHUB_REPOSITORY_URL): Intent? {
        val repo = parseRepository(fallbackRepoUrl)
        val safeUrl = if (repo != null) {
            validatedGitHubUrl(url, repo)
        } else {
            val uri = runCatching { java.net.URI(url) }.getOrNull() ?: return null
            val host = uri.host?.lowercase(Locale.US) ?: return null
            if (!uri.scheme.equals("https", ignoreCase = true) ||
                (host != "github.com" && host != "www.github.com")
            ) {
                return null
            }
            uri.toASCIIString()
        }
        return Intent(Intent.ACTION_VIEW, Uri.parse(safeUrl)).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
    }

    private data class FetchResult(val body: String?, val reachable: Boolean)

    private fun fetchGitHubJsonStatus(urlStr: String, accept: String): FetchResult {
        var currentUrl = urlStr
        repeat(3) {
            val parsed = runCatching { URL(currentUrl) }.getOrNull() ?: return FetchResult(null, false)
            if (!parsed.protocol.equals("https", ignoreCase = true) ||
                !parsed.host.equals("api.github.com", ignoreCase = true)
            ) {
                return FetchResult(null, false)
            }
            val conn = (parsed.openConnection() as? HttpsURLConnection) ?: return FetchResult(null, false)
            try {
                conn.instanceFollowRedirects = false
                conn.requestMethod = "GET"
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                conn.useCaches = false
                conn.setRequestProperty("Accept", accept)
                conn.setRequestProperty("Cache-Control", "no-cache")
                conn.setRequestProperty("User-Agent", "Droply-Updater/1.0")

                val code = conn.responseCode
                if (code in 301..308) {
                    val location = conn.getHeaderField("Location") ?: return FetchResult(null, false)
                    val nextUrl = runCatching { URL(parsed, location) }.getOrNull() ?: return FetchResult(null, false)
                    if (!nextUrl.protocol.equals("https", ignoreCase = true) ||
                        !nextUrl.host.equals("api.github.com", ignoreCase = true)
                    ) {
                        return FetchResult(null, false)
                    }
                    currentUrl = nextUrl.toString()
                    return@repeat
                }
                if (code == 404) return FetchResult(null, true)
                if (code != 200) return FetchResult(null, false)
                return FetchResult(readBoundedText(conn.inputStream), true)
            } catch (_: Exception) {
                return FetchResult(null, false)
            } finally {
                conn.disconnect()
            }
        }
        return FetchResult(null, false)
    }

    private fun readBoundedText(input: InputStream): String? {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(4096)
        var total = 0
        input.use { stream ->
            while (true) {
                val n = stream.read(buf)
                if (n <= 0) break
                total += n
                if (total > MAX_RESPONSE_BYTES) return null
                out.write(buf, 0, n)
            }
        }
        return String(out.toByteArray(), Charsets.UTF_8)
    }

    private fun sanitizeReleaseNotes(raw: String?): String? {
        if (raw.isNullOrBlank()) return null
        val clean = SecureChannel.sanitizeDisplayText(raw, maxLength = 500, allowNewlines = true)
        return clean.ifEmpty { null }
    }

    private fun isValidIdentifier(value: String, maxLen: Int): Boolean {
        if (value.isEmpty() || value.length > maxLen || value == "." || value == "..") {
            return false
        }
        return value.all { ch ->
            ch in '0'..'9' || ch in 'A'..'Z' || ch in 'a'..'z' || ch == '-' || ch == '_' || ch == '.'
        }
    }
}
