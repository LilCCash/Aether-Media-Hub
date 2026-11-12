package app.aether.core

import app.aether.core.downloads.DownloadState
import app.aether.core.downloads.DownloadStore
import app.aether.core.model.MetaItem
import app.aether.core.model.Video
import app.aether.core.util.InMemorySecretStore
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadsTest {
    @Test fun theSourceStaysSecretAndIsForgottenWhenDone() {
        val dir = Files.createTempDirectory("dl").toFile()
        val secrets = InMemorySecretStore()
        val store = DownloadStore(dir, secrets)
        val item = store.add(MetaItem("tt1", "series", "Serie"), Video("tt1:1:2", "Ep", season = 1, episode = 2), "https://cdn.example/f.mkv?token=SECRET", mapOf("Referer" to "x"), "mkv")
        assertEquals("Serie · S1E2", item.label)
        assertTrue(item.fileName.endsWith(".mkv"))
        assertFalse(dir.resolve("downloads.json").readText().contains("SECRET"))
        assertEquals("https://cdn.example/f.mkv?token=SECRET" to mapOf("Referer" to "x"), store.source(item.id))
        assertEquals(item.id, store.add(MetaItem("tt1", "series", "Serie"), Video("tt1:1:2"), "https://other", emptyMap(), "mp4").id)
        store.fileOf(item).writeText("video")
        store.finished(item.id, 5)
        assertNull(store.source(item.id))
        assertEquals(DownloadState.DONE, store.item(item.id)?.state)
        assertEquals(item.id, store.completed("tt1", "tt1:1:2")?.id)
        // A download interrupted while running comes back paused.
        val second = store.add(MetaItem("tt2", "movie", "Film"), null, "https://a/b.mp4", emptyMap(), "mp4")
        store.update(second.id) { it.copy(state = DownloadState.RUNNING) }
        assertEquals(DownloadState.PAUSED, DownloadStore(dir, secrets).item(second.id)?.state)
        store.remove(item.id)
        assertFalse(store.fileOf(item).exists())
        assertEquals("mkv", DownloadStore.extension("https://x/y/file.MKV?x=1", null))
        assertEquals("mp4", DownloadStore.extension("https://x/y/stream", null))
        assertEquals("avi", DownloadStore.extension("https://x/y/stream", "Film.avi"))
    }
}

class IphoneBackupKeysTest {
    @Test fun theKeysOfAnIphoneBackupAreRead() {
        val text = """{"marker":"app.aether.backup","formatVersion":1,"createdAt":"2026-11-12T10:00:00Z","appVersion":"2.1",
            "library":{"entries":{},"progress":{},"searchHistory":[]},"addons":[{"addon":{"id":"x"},"url":"https://a.example/manifest.json"}],
            "includesAddonURLs":true,"serviceKeys":{"tmdb":"T1","torbox":"TB","realdebrid":"RD","mdblist":"M","fanart":"F","tvdb":"V","tvdbPin":"P"}}"""
        val contents = app.aether.core.library.BackupCodec.decode(text)
        org.junit.Assert.assertEquals(mapOf("tmdb" to "T1", "torbox" to "TB", "realdebrid" to "RD", "mdblist" to "M", "fanart" to "F", "tvdb" to "V", "tvdbPin" to "P"), contents.keys)
        org.junit.Assert.assertEquals(listOf("https://a.example/manifest.json"), contents.addonUrls)
        val again = app.aether.core.library.BackupCodec.encode(contents.library, contents.addonUrls, true, "tv", keys = contents.keys)
        org.junit.Assert.assertTrue(again.contains("\"serviceKeys\""))
        org.junit.Assert.assertEquals(contents.keys, app.aether.core.library.BackupCodec.decode(again).keys)
    }
}
