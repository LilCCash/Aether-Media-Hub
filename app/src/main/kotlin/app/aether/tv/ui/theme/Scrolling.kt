package app.aether.tv.ui.theme

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.BringIntoViewSpec
import kotlin.math.abs
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue

/**
 * How lists follow the remote. Vertically the element under the remote is held at a fixed height of the screen (a «pivot», as on
 * Google TV and tvOS): rows and grid lines arrive whole, never half cut at the top or the bottom. Horizontally a row scrolls only as
 * much as needed, keeping a card of margin so the next one is always in view.
 */
@OptIn(ExperimentalFoundationApi::class)
object PivotScroll : BringIntoViewSpec {
    private const val PARENT_FRACTION = 0.32f

    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
        if (size >= containerSize) return offset // taller than the screen: its top goes to the top
        // Already whole and well inside the screen (the buttons of the featured titles, a row just reached from above): no move.
        if (offset >= containerSize * 0.06f && offset + size <= containerSize * 0.94f) return 0f
        val target = PARENT_FRACTION * containerSize - 0.0f * size
        val space = containerSize - target
        val leading = if (space < size) containerSize - size else target
        val distance = offset - leading
        // Very small moves are not worth a scroll (avoids a nervous list).
        return if (abs(distance) < 2f) 0f else distance
    }
}

@OptIn(ExperimentalFoundationApi::class)
object EdgeScroll : BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
        val margin = minOf(size * 0.9f, containerSize * 0.18f)
        val leadingEdge = offset
        val trailingEdge = offset + size
        return when {
            leadingEdge < margin -> leadingEdge - margin
            trailingEdge > containerSize - margin -> trailingEdge - (containerSize - margin)
            else -> 0f
        }
    }
}

/** Grids of posters: the line under the remote goes to the top of the grid, whole; no half line is left above it. */
@OptIn(ExperimentalFoundationApi::class)
object GridScroll : BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
        if (offset >= 0f && offset + size <= containerSize) return 0f
        return offset - 12f
    }
}

/** Whether the tab bar has the remote (the Home goes back to its top then, so the bar never covers it). */
object Chrome {
    var barFocused by androidx.compose.runtime.mutableStateOf(false)
}
