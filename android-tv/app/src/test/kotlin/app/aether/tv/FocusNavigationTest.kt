package app.aether.tv

import android.app.Application
import androidx.compose.foundation.layout.Row
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.requestFocus
import app.aether.core.model.MetaItem
import app.aether.tv.nav.Routes
import app.aether.tv.ui.components.ContentRow
import app.aether.tv.ui.components.FocusMemory
import app.aether.tv.ui.components.PosterCard
import app.aether.tv.ui.components.SideNav
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.theme.AetherTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertEquals

/**
 * The remote, without a television: the D-pad and OK keys are sent to the real composables (on the JVM, through Robolectric) and what
 * gets focus or is activated is checked. This does not replace trying the app on a TV, but it catches a lost focus or a dead button.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class FocusNavigationTest {
    @get:Rule val rule = createComposeRule()

    private val accent = Color(0xFF8B7CFF)

    @Test fun okOnAFocusedButtonActivatesIt() {
        var clicks = 0
        rule.setContent { AetherTheme(accent) { TvButton("Guarda", { clicks++ }, testTag = "play") } }
        rule.onNodeWithTag("play").requestFocus()
        rule.onNodeWithTag("play").assertIsFocused()
        rule.onNodeWithTag("play").performKeyInput { pressKey(Key.DirectionCenter) }
        assertEquals(1, clicks)
        rule.onNodeWithTag("play").performKeyInput { pressKey(Key.Enter) }
        assertEquals(2, clicks, "Enter works like OK")
    }

    @Test fun aDisabledButtonIsNotActivated() {
        var clicks = 0
        rule.setContent { AetherTheme(accent) { TvButton("Guarda", { clicks++ }, enabled = false, testTag = "play") } }
        rule.onNodeWithTag("play").performKeyInput { pressKey(Key.DirectionCenter) }
        assertEquals(0, clicks)
    }

    @Test fun rightAndLeftWalkAlongARowOfButtons() {
        rule.setContent {
            AetherTheme(accent) {
                Row {
                    TvButton("Uno", {}, testTag = "a")
                    TvButton("Due", {}, testTag = "b")
                    TvButton("Tre", {}, testTag = "c")
                }
            }
        }
        rule.onNodeWithTag("a").requestFocus()
        rule.onNodeWithTag("a").performKeyInput { pressKey(Key.DirectionRight) }
        rule.onNodeWithTag("b").assertIsFocused()
        rule.onNodeWithTag("b").performKeyInput { pressKey(Key.DirectionRight) }
        rule.onNodeWithTag("c").assertIsFocused()
        rule.onNodeWithTag("c").performKeyInput { pressKey(Key.DirectionLeft) }
        rule.onNodeWithTag("b").assertIsFocused()
    }

    @Test fun theSideMenuOpensWhenTheRemoteIsOnItAndOkChoosesASection() {
        var chosen: String? = null
        rule.setContent { AetherTheme(accent) { SideNav(current = Routes.HOME, onSelect = { chosen = it }, modifier = Modifier) } }
        rule.onNodeWithText("Scopri").assertDoesNotExist()
        rule.onNodeWithTag("nav.${Routes.DISCOVER}").requestFocus()
        rule.onNodeWithText("Scopri").assertExists()
        rule.onNodeWithTag("nav.${Routes.DISCOVER}").performKeyInput { pressKey(Key.DirectionCenter) }
        assertEquals(Routes.DISCOVER, chosen)
        rule.onNodeWithTag("nav.${Routes.DISCOVER}").performKeyInput { pressKey(Key.DirectionDown) }
        rule.onNodeWithTag("nav.${Routes.SEARCH}").assertIsFocused()
    }

    @Test fun backOnARowReturnsTheFocusToThePosterWhereTheViewerWas() {
        val items = (0 until 12).map { MetaItem("tt$it", "movie", "Titolo $it") }
        val memory = FocusMemory("row|tt9") {}
        rule.setContent {
            AetherTheme(accent) {
                ContentRow("Film", items, { it.id }, rowId = "row", memory = memory) { meta, requester, onFocused ->
                    PosterCard(meta, {}, focusRequester = requester, onFocused = onFocused, testTag = "p-${meta.id}")
                }
            }
        }
        rule.waitForIdle()
        rule.onNodeWithTag("p-tt9").assertIsFocused()
    }

    @Test fun movingOverPostersRemembersTheLastOne() {
        val items = (0 until 5).map { MetaItem("tt$it", "movie", "Titolo $it") }
        var remembered = ""
        val memory = FocusMemory("") { remembered = it }
        rule.setContent {
            AetherTheme(accent) {
                ContentRow("Film", items, { it.id }, rowId = "row", memory = memory) { meta, requester, onFocused ->
                    PosterCard(meta, {}, focusRequester = requester, onFocused = onFocused, testTag = "p-${meta.id}")
                }
            }
        }
        rule.onNodeWithTag("p-tt0").requestFocus()
        rule.onNodeWithTag("p-tt0").performKeyInput { pressKey(Key.DirectionRight) }
        rule.onNodeWithTag("p-tt1").assertIsFocused()
        assertEquals("row|tt1", remembered)
    }
}
