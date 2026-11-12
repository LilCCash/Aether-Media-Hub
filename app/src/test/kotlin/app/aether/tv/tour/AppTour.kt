package app.aether.tv.tour

import android.graphics.Bitmap
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.requestFocus
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import app.aether.tv.AetherRoot
import java.io.File
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * A walk through the whole app with the remote on fake data: pictures of every screen (build/tour) and a report of what is cut off
 * by the edges of a 1080p TV. Runs only with -PaetherScreenshots=true (it is slow).
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], application = TestAetherApp::class, qualifiers = "w960dp-h540dp-land-television-xhdpi")
class AppTour {
    @get:Rule val rule = createComposeRule()

    private val dir = File("build/tour").apply { mkdirs() }
    private val report = StringBuilder()

    private fun settle(ms: Long = 1500) {
        repeat((ms / 100).toInt()) { rule.mainClock.advanceTimeBy(100); Thread.sleep(15) }
        rule.waitForIdle()
    }

    /** A press of the remote on whatever has the focus. */
    private fun key(key: Key, times: Int = 1) {
        repeat(times) {
            val focused = rule.onAllNodes(isFocused()).fetchSemanticsNodes()
            if (focused.isEmpty()) report.append("nessun elemento ha il focus prima di ${keyName(key)}\n")
            else rule.onAllNodes(isFocused())[0].performKeyInput { pressKey(key) }
            settle(350)
        }
    }

    private fun keyName(key: Key) = when (key) { Key.DirectionDown -> "giù"; Key.DirectionUp -> "su"; Key.DirectionLeft -> "sinistra"; Key.DirectionRight -> "destra"; else -> "OK" }

    private fun start() {
        rule.setContent { AetherRoot(null, keyboardInputOnly = true) }
        settle(5000)
        val focused = rule.onAllNodes(isFocused()).fetchSemanticsNodes()
        report.append("focus iniziale: ${focused.firstOrNull()?.config?.let { c -> if (c.contains(SemanticsProperties.TestTag)) c[SemanticsProperties.TestTag] else "senza nome" } ?: "nessuno"}\n")
        // On the TV the first focus lands on the tab bar when nothing asks for it: the tour starts from there, as the viewer does.
        if (focused.isEmpty()) runCatching { rule.onNodeWithTag("nav.home").requestFocus(); settle(500) }
    }

    private fun shot(name: String) {
        settle(800)
        val bitmap = rule.onAllNodes(androidx.compose.ui.test.isRoot())[0].captureToImage().asAndroidBitmap()
        File(dir, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 90, it) }
        audit(name)
    }

    /** Every text whose bounds go past the screen (or are clipped by a too narrow box) goes into the report. */
    private fun audit(name: String) {
        val root = rule.onAllNodes(androidx.compose.ui.test.isRoot())[0].fetchSemanticsNode()
        val screen = root.boundsInRoot
        val nodes = rule.onAllNodes(SemanticsMatcher("text") { it.config.contains(SemanticsProperties.Text) }, useUnmergedTree = true).fetchSemanticsNodes()
        for (node in nodes) {
            val text = node.config[SemanticsProperties.Text].joinToString { it.text }.take(40)
            val b: Rect = node.boundsInRoot
            if (b.width <= 0f || b.height <= 0f) continue
            if (b.left < screen.left - 1 || b.right > screen.right + 1) report.append("$name: «$text» esce dai lati (${b.left.toInt()}..${b.right.toInt()})\n")
            if (b.left < screen.width * 0.03f && b.right > 0) report.append("$name: «$text» nella zona di overscan a sinistra (x=${b.left.toInt()})\n")
            if (b.top < screen.height * 0.03f && b.bottom > 0) report.append("$name: «$text» nella zona di overscan in alto (y=${b.top.toInt()})\n")
        }
    }

    @Test fun walkThroughTheApp() {
        assumeTrue(System.getProperty("aether.screenshots") == "true")
        start()
        shot("01-home")
        key(Key.DirectionDown); shot("02-home-row")
        key(Key.DirectionDown, 2); shot("03-home-rows")
        key(Key.DirectionRight, 3); shot("04-home-row-right")
        // Up to the tab bar and back down: the Home must scroll again.
        key(Key.DirectionUp, 6); shot("05-tabbar")
        key(Key.DirectionDown, 2); shot("06-back-down")
        key(Key.DirectionUp, 6); key(Key.DirectionRight); key(Key.DirectionCenter); settle(2500); shot("07-discover")
        key(Key.DirectionDown, 2); shot("08-discover-grid")
        key(Key.DirectionUp, 6); key(Key.DirectionRight); key(Key.DirectionCenter); settle(2500); shot("09-per-te")
        key(Key.DirectionUp, 6); key(Key.DirectionRight); key(Key.DirectionCenter); settle(2500); shot("10-libreria")
        key(Key.DirectionUp, 6); key(Key.DirectionRight); key(Key.DirectionCenter); settle(2500); shot("11-addon")
        key(Key.DirectionUp, 6); key(Key.DirectionRight); key(Key.DirectionCenter); settle(2500); shot("12-impostazioni")
        key(Key.DirectionDown, 2); shot("13-impostazioni-riproduzione")
        key(Key.DirectionDown, 6); shot("14-impostazioni-informazioni")
        key(Key.DirectionRight); key(Key.DirectionDown, 3); shot("15-impostazioni-righe")
        File(dir, "report.txt").writeText(report.toString().ifEmpty { "Nessun testo fuori dai bordi.\n" })
    }

    @Test fun titleAndSources() {
        assumeTrue(System.getProperty("aether.screenshots") == "true")
        start()
        key(Key.DirectionDown); key(Key.DirectionCenter); settle(3000); shot("20-scheda")
        key(Key.DirectionDown); shot("21-scheda-sotto")
        key(Key.DirectionDown, 2); shot("22-scheda-fondo")
        key(Key.DirectionUp, 6); key(Key.DirectionCenter); settle(3000); shot("23-sorgenti")
        File(dir, "report-title.txt").writeText(report.toString().ifEmpty { "Nessun testo fuori dai bordi.\n" })
    }
}
