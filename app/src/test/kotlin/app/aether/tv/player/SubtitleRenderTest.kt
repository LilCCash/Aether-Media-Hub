package app.aether.tv.player

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.text.Cue
import androidx.media3.ui.SubtitleView
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** The overlay the player draws its subtitles with really puts the lines on the screen. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w960dp-h540dp-land-television-xhdpi")
class SubtitleRenderTest {
    @get:Rule val rule = createComposeRule()

    @Test fun cuesAreDrawn() {
        var cues by mutableStateOf<List<Cue>>(emptyList())
        rule.setContent {
            Box(Modifier.size(640.dp, 360.dp).background(Color.Black).testTag("video")) {
                AndroidView(
                    modifier = Modifier.size(640.dp, 360.dp),
                    factory = { SubtitleView(it) },
                    update = { it.setCues(cues) },
                )
            }
        }
        rule.waitForIdle()
        fun bright(): Int = rule.onNodeWithTag("video").captureToImage().toPixelMap().let { map ->
            var n = 0
            for (x in 0 until map.width step 2) for (y in 0 until map.height step 2) if (map[x, y].red > 0.8f) n++
            n
        }
        val before = bright()
        cues = listOf(Cue.Builder().setText("Ciao, questo è un sottotitolo").build())
        rule.waitForIdle()
        val after = bright()
        println("SUBTITLE before=$before after=$after")
        assertTrue("subtitle drawn: $before -> $after", after > before + 50)
    }
}
