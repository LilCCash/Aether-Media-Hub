package app.aether.core

import app.aether.core.json.Flex
import app.aether.core.model.AddonManifest
import app.aether.core.model.ExtraValue
import app.aether.core.model.ManifestParseResult
import app.aether.core.model.ManifestParser
import app.aether.core.model.ResourcePath
import app.aether.core.support.Samples
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.fail

class ManifestTest {
    private fun parse(text: String): AddonManifest = when (val r = ManifestParser.parse(Flex.parse(text))) {
        is ManifestParseResult.Success -> r.manifest
        is ManifestParseResult.Failure -> fail("manifest refused: ${r.message}")
    }

    @Test fun readsAFullManifest() {
        val manifest = parse(Samples.CINEMETA_MANIFEST)
        assertEquals("Cinemeta", manifest.name)
        assertEquals(3, manifest.catalogs.size)
        assertEquals(listOf("catalog", "meta", "stream"), manifest.resources.map { it.name })
        assertEquals(listOf("Azione", "Dramma"), manifest.catalogs[0].genreOptions)
    }

    @Test fun tolerantToNumbersAsStringsAndLegacyExtra() {
        val manifest = parse(
            """{"id":123,"version":2,"name":"X","resources":["catalog"],"types":"movie",
               "catalogs":[{"type":"movie","id":"a","extraSupported":["search","skip"],"extraRequired":["search"]}]}""",
        )
        assertEquals("123", manifest.id)
        assertEquals("2", manifest.version)
        assertEquals(listOf("movie"), manifest.types)
        val catalog = manifest.catalogs[0]
        assertEquals("a", catalog.name)
        assertTrue(catalog.supportsSearch && catalog.supportsSkip)
        assertEquals(listOf("search"), catalog.requiredExtraNames)
    }

    @Test fun refusesAManifestWithoutResources() {
        val result = ManifestParser.parse(Flex.parse("""{"id":"a","version":"1","name":"n","resources":[],"catalogs":[]}"""))
        assertTrue(result is ManifestParseResult.Failure)
    }

    @Test fun refusesMissingRequiredFields() {
        val result = ManifestParser.parse(Flex.parse("""{"id":"a","version":"1","resources":["catalog"]}"""))
        assertTrue(result is ManifestParseResult.Failure && result.message.contains("name"))
    }

    @Test fun badCatalogEntriesAreDroppedNotFatal() {
        val manifest = parse("""{"id":"a","version":"1","name":"n","resources":["catalog"],"catalogs":[{"type":"movie"},{"type":"movie","id":"ok"},5]}""")
        assertEquals(listOf("ok"), manifest.catalogs.map { it.id })
    }

    @Test fun plainResourceInheritsTypesAndPrefixes() {
        val manifest = parse("""{"id":"a","version":"1","name":"n","types":["movie"],"idPrefixes":["tt"],"resources":["stream"]}""")
        assertTrue(manifest.supports(ResourcePath("stream", "movie", "tt1")))
        assertFalse(manifest.supports(ResourcePath("stream", "movie", "kitsu:1")))
        assertFalse(manifest.supports(ResourcePath("stream", "series", "tt1")))
    }

    @Test fun fullResourceUsesItsOwnTypesAndPrefixes() {
        val manifest = parse(Samples.CINEMETA_MANIFEST)
        assertTrue(manifest.supports(ResourcePath("stream", "movie", "tt1")))
        assertFalse(manifest.supports(ResourcePath("stream", "series", "tt1")))
    }

    @Test fun catalogExtraRulesFollowStremioCore() {
        val manifest = parse(Samples.CINEMETA_MANIFEST)
        val searchOnly = manifest.catalogs[2]
        assertFalse(searchOnly.isPlainFeed)
        assertFalse(searchOnly.isExtraSupported(emptyList()))
        assertTrue(searchOnly.isExtraSupported(listOf(ExtraValue("search", "x"))))
        val top = manifest.catalogs[0]
        assertTrue(top.isExtraSupported(listOf(ExtraValue("genre", "Azione"), ExtraValue("skip", "100"))))
        assertFalse(top.isExtraSupported(listOf(ExtraValue("unknown", "1"))))
        assertTrue(manifest.supports(ResourcePath("catalog", "movie", "top", listOf(ExtraValue("skip", "20")))))
    }
}
