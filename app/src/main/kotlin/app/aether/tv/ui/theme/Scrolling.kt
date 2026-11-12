package app.aether.tv.ui.theme

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.BringIntoViewSpec
import kotlin.math.abs

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
