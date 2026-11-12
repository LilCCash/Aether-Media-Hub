package app.aether.tv

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.requestFocus
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.unit.dp
import app.aether.core.model.MetaItem
import app.aether.tv.nav.Routes
import app.aether.tv.ui.components.ContentRow
import app.aether.tv.ui.components.HeroBanner
import app.aether.tv.ui.components.PosterCard
import app.aether.tv.ui.components.TopBar
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.components.TvChip
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherTheme
import app.aether.tv.ui.theme.AppBackdrop
import java.io.File
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Pictures of the main pieces of the interface, for checking the look by eye. Runs only with -PaetherScreenshots=true. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], application = Application::class, qualifiers = "w960dp-h540dp-land-television-xhdpi")
class ScreenshotGallery {
    @get:Rule val rule = createComposeRule()

    private fun shoot(name: String, focusTag: String? = null, content: @Composable () -> Unit) {
        assumeTrue(System.getProperty("aether.screenshots") == "true")
        rule.setContent {
            // A TV is never in touch mode: the focus is drawn as with the remote.
            val inputMode = androidx.compose.ui.platform.LocalInputModeManager.current
            androidx.compose.runtime.SideEffect { inputMode.requestInputMode(androidx.compose.ui.input.InputMode.Keyboard) }
            AetherTheme(Color(0xFF0A84FF)) {
                Box(Modifier.fillMaxSize().background(AetherColors.Background)) {
                    AppBackdrop(app.aether.core.settings.BackgroundStyle.NIGHT, Color(0xFF0A84FF), false)
                    content()
                }
            }
        }
        rule.waitForIdle()
        focusTag?.let { rule.onNodeWithTag(it).requestFocus(); rule.waitForIdle(); rule.onNodeWithTag(it).assertIsFocused(); rule.mainClock.advanceTimeBy(800); rule.waitForIdle() }
        val bitmap = rule.onRoot().captureToImage().asAndroidBitmap()
        val dir = File("build/screenshots").apply { mkdirs() }
        File(dir, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private val items = (1..8).map { MetaItem("tt$it", "movie", listOf("Dune: Parte due", "Oppenheimer", "Il gladiatore", "Interstellar", "Blade Runner 2049", "Arrival", "Barbie", "Povere creature!")[it - 1], description = "Una storia epica tra deserti e destino.", releaseInfo = "202$it", imdbRating = "8.$it", genres = listOf("Fantascienza", "Avventura")) }

    @Test fun home() = shoot("home", focusTag = "hero.play") {
        Column {
            Box {
                HeroBanner(items.take(4), autoScroll = false, onPlay = {}, onDetails = {})
                TopBar(Routes.HOME, {})
            }
            ContentRow("Film popolari", items, { it.id }) { meta, r, f -> PosterCard(meta, {}, focusRequester = r, onFocused = f, testTag = "p-${meta.id}") }
        }
    }

    @Test fun focus() = shoot("focus", focusTag = "poster") {
        Column(Modifier.padding(48.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
            TopBar(Routes.DISCOVER, {})
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                TvButton("Guarda", {}, primary = true)
                TvButton("Dettagli", {}, testTag = "focused")
                TvChip("Film", true, {})
                TvChip("Serie", false, {})
            }
            Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                PosterCard(items[0], {}, testTag = "poster")
                PosterCard(items[1], {})
                PosterCard(items[2], {})
            }
        }
    }
}
