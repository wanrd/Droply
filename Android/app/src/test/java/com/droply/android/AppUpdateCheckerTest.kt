package com.droply.android

import com.droply.android.update.AppUpdateChecker
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppUpdateCheckerTest {

    @Test
    fun parseRepositoryValidatesHttpsGitHubOnly() {
        val parsed = AppUpdateChecker.parseRepository("https://github.com/islam-dev/Droply.git")
        assertNotNull(parsed)
        assertEquals("islam-dev", parsed!!.owner)
        assertEquals("Droply", parsed.repo)
        assertEquals("https://github.com/islam-dev/Droply/releases", parsed.releasesUrl)

        assertNull(AppUpdateChecker.parseRepository("http://github.com/islam/droply"))
        assertNull(AppUpdateChecker.parseRepository("https://evil.com/islam/droply"))
        assertNull(AppUpdateChecker.parseRepository("https://user@github.com/islam/droply"))
        assertNull(AppUpdateChecker.parseRepository("https://github.com/../etc/droply"))
        assertNull(AppUpdateChecker.parseRepository(""))
    }

    @Test
    fun validatedGitHubUrlBlocksRedirectsToOtherDomainsOrRepos() {
        val repo = AppUpdateChecker.parseRepository("https://github.com/islam/droply")!!

        assertEquals(
            "https://github.com/islam/droply/releases/tag/v1.2",
            AppUpdateChecker.validatedGitHubUrl("https://github.com/islam/droply/releases/tag/v1.2", repo)
        )
        assertEquals(
            repo.releasesUrl,
            AppUpdateChecker.validatedGitHubUrl("https://evil.example/malware.apk", repo)
        )
        assertEquals(
            repo.releasesUrl,
            AppUpdateChecker.validatedGitHubUrl("https://github.com/attacker/fake-droply/releases", repo)
        )
        assertEquals(
            repo.releasesUrl,
            AppUpdateChecker.validatedGitHubUrl("javascript:alert(1)", repo)
        )
    }

    @Test
    fun semanticVersionComparisonHandlesMultiDigitSegments() {
        assertTrue(AppUpdateChecker.isVersionNewer("v1.1", "1.0"))
        assertTrue(AppUpdateChecker.isVersionNewer("1.10.0", "1.2.9"))
        assertFalse(AppUpdateChecker.isVersionNewer("1.0", "1.0.0"))
        assertFalse(AppUpdateChecker.isVersionNewer("0.9.9", "1.0"))
    }

    @Test
    fun releaseTagsAndManifestParsingEnforceSecurityRules() {
        val repo = AppUpdateChecker.parseRepository("https://github.com/islam/droply")!!

        val releaseJson = """
            {
              "tag_name": "v1.2.0",
              "html_url": "https://github.com/islam/droply/releases/tag/v1.2.0",
              "body": "Bug\u202Efixes\nand speed boost",
              "draft": false,
              "prerelease": false
            }
        """.trimIndent()
        val info = AppUpdateChecker.parseReleaseResponse(releaseJson, "1.0", repo)
        assertNotNull(info)
        assertEquals("1.2.0", info!!.latestVersion)
        assertEquals("https://github.com/islam/droply/releases/tag/v1.2.0", info.releaseUrl)
        assertFalse(info.releaseNotes!!.contains('\u202E'))

        val draftJson = """{"tag_name":"v2.0","draft":true,"prerelease":false}"""
        assertNull(AppUpdateChecker.parseReleaseResponse(draftJson, "1.0", repo))

        val tagsJson = """[{"name":"v1.0"},{"name":"v1.3"},{"name":"v1.2"}]"""
        val tagInfo = AppUpdateChecker.parseTagsResponse(tagsJson, "1.1", repo)
        assertNotNull(tagInfo)
        assertEquals("1.3", tagInfo!!.latestVersion)
        assertEquals(repo.releasesUrl, tagInfo.releaseUrl)

        val manifestJson = """{"version":"1.4","androidVersion":"1.5","title":"Свежий релиз\u202E","notes":"Строка 1\nСтрока 2\u202E","releaseUrl":"https://evil.com/apk"}"""
        val manifestInfo = AppUpdateChecker.parseManifestResponse(manifestJson, "1.0", repo)
        assertNotNull(manifestInfo)
        assertEquals("1.5", manifestInfo!!.latestVersion)
        assertEquals("Свежий релиз", manifestInfo.title)
        assertEquals("Строка 1\nСтрока 2", manifestInfo.releaseNotes)
        assertEquals(repo.releasesUrl, manifestInfo.releaseUrl)

        val matchingReleaseJson = """{"tag_name":"v1.5","html_url":"https://github.com/islam/droply/releases/tag/v1.5","body":"Auto","draft":false,"prerelease":false}"""
        val releaseInfo = AppUpdateChecker.parseReleaseResponse(matchingReleaseJson, "1.0", repo)
        val merged = AppUpdateChecker.resolvePreferredUpdate(releaseInfo, manifestInfo, null, repo)
        assertNotNull(merged)
        assertEquals("Свежий релиз", merged!!.title)
        assertEquals("Строка 1\nСтрока 2", merged.releaseNotes)
        assertEquals("https://github.com/islam/droply/releases/tag/v1.5", merged.releaseUrl)

        val editedSameVersion = merged.copy(releaseNotes = "Обновлённый текст сообщения")
        assertFalse(merged.promptSignature == editedSameVersion.promptSignature)
        assertEquals(
            com.droply.android.update.UpdateCheckOutcome.NotConfigured,
            AppUpdateChecker.checkForUpdatesOutcome("", "1.0")
        )
    }
}
