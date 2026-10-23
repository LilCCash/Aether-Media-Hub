package app.aether.tv.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.drawBehind
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The look of Aether on a television: dark, cinematic, one accent colour the viewer picks. */
object AetherColors {
    val Background = Color(0xFF0B0A12)
    val Surface = Color(0xFF15131F)
    val SurfaceRaised = Color(0xFF1E1B2E)
    val SurfaceFocused = Color(0xFF2A2640)
    val OnBackground = Color(0xFFF3F1FB)
    val OnSurfaceMuted = Color(0xFFB9B4CE)
    val OnSurfaceFaint = Color(0xFF857F9C)
    val Danger = Color(0xFFFF6B6B)
    val Success = Color(0xFF3DDC97)
    val Warning = Color(0xFFFFB347)
    val Scrim = Color(0xE60B0A12)
}

/** The area TVs may crop (overscan) and the margins the layouts keep. */
object AetherDimens {
    val ScreenHorizontal = 48.dp
    val ScreenVertical = 28.dp
    val RailCollapsed = 76.dp
    val RailExpanded = 236.dp
    val RowSpacing = 14.dp
}

val LocalAccent = compositionLocalOf { Color(0xFF8B7CFF) }
val LocalAnimations = compositionLocalOf { true }

/** Corner radius of cards and buttons, chosen in the settings. */
val LocalCorner = compositionLocalOf { 12.dp }

private val Sans = FontFamily.SansSerif

private val AetherTypography = Typography(
    displayLarge = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Bold, fontSize = 52.sp, lineHeight = 58.sp, letterSpacing = (-0.5).sp),
    displayMedium = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Bold, fontSize = 40.sp, lineHeight = 46.sp),
    headlineLarge = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Bold, fontSize = 32.sp, lineHeight = 38.sp),
    headlineMedium = TextStyle(fontFamily = Sans, fontWeight = FontWeight.SemiBold, fontSize = 26.sp, lineHeight = 32.sp),
    titleLarge = TextStyle(fontFamily = Sans, fontWeight = FontWeight.SemiBold, fontSize = 22.sp, lineHeight = 28.sp),
    titleMedium = TextStyle(fontFamily = Sans, fontWeight = FontWeight.SemiBold, fontSize = 18.sp, lineHeight = 24.sp),
    bodyLarge = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Normal, fontSize = 18.sp, lineHeight = 26.sp),
    bodyMedium = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Normal, fontSize = 16.sp, lineHeight = 23.sp),
    bodySmall = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Normal, fontSize = 14.sp, lineHeight = 20.sp),
    labelLarge = TextStyle(fontFamily = Sans, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, lineHeight = 20.sp),
    labelMedium = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Medium, fontSize = 14.sp, lineHeight = 18.sp),
    labelSmall = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Medium, fontSize = 12.sp, lineHeight = 16.sp, letterSpacing = 0.4.sp),
)

@Composable
fun AetherTheme(accent: Color, animations: Boolean = true, corner: androidx.compose.ui.unit.Dp = 12.dp, content: @Composable () -> Unit) {
    val scheme = darkColorScheme(
        primary = accent,
        onPrimary = Color(0xFF0B0A12),
        secondary = accent,
        background = AetherColors.Background,
        onBackground = AetherColors.OnBackground,
        surface = AetherColors.Surface,
        onSurface = AetherColors.OnBackground,
        surfaceVariant = AetherColors.SurfaceRaised,
        onSurfaceVariant = AetherColors.OnSurfaceMuted,
        error = AetherColors.Danger,
        outline = AetherColors.OnSurfaceFaint,
    )
    CompositionLocalProvider(LocalAccent provides accent, LocalAnimations provides animations, LocalCorner provides corner) {
        MaterialTheme(colorScheme = scheme, typography = AetherTypography, content = content)
    }
}

/** A veil over a backdrop so text on it stays readable from the couch. */
fun backdropScrimHorizontal(): Brush = Brush.horizontalGradient(
    0f to Color(0xF20B0A12), 0.45f to Color(0xB30B0A12), 0.8f to Color(0x330B0A12), 1f to Color.Transparent,
)

fun backdropScrimVertical(): Brush = Brush.verticalGradient(0f to Color.Transparent, 0.55f to Color(0x990B0A12), 1f to Color(0xFF0B0A12))

/** The coloured glow behind every screen; "Aurora" drifts slowly (only when animations are on). */
@Composable
fun AppBackdrop(style: app.aether.core.settings.BackgroundStyle, accent: Color, animated: Boolean) {
    val (a, b) = when (style) {
        app.aether.core.settings.BackgroundStyle.NIGHT -> return
        app.aether.core.settings.BackgroundStyle.AURORA -> accent to Color(0xFF3DDC97)
        app.aether.core.settings.BackgroundStyle.CINEMA -> Color(0xFF8B1E2D) to Color(0xFF3A0F18)
        app.aether.core.settings.BackgroundStyle.OCEAN -> Color(0xFF1C6FB8) to Color(0xFF0E8F8A)
        app.aether.core.settings.BackgroundStyle.EMBER -> Color(0xFFD9541E) to Color(0xFF7A1F3D)
    }
    val drift = if (animated && style == app.aether.core.settings.BackgroundStyle.AURORA) {
        val t = androidx.compose.animation.core.rememberInfiniteTransition(label = "aurora")
        t.animateFloat(0f, 1f, androidx.compose.animation.core.infiniteRepeatable(androidx.compose.animation.core.tween(18000, easing = androidx.compose.animation.core.LinearEasing), androidx.compose.animation.core.RepeatMode.Reverse), label = "drift").value
    } else 0.5f
    androidx.compose.foundation.layout.Box(
        androidx.compose.ui.Modifier.fillMaxSize().drawBehind {
            drawRect(Brush.radialGradient(listOf(a.copy(alpha = 0.34f), Color.Transparent), center = androidx.compose.ui.geometry.Offset(size.width * (0.15f + 0.5f * drift), size.height * 0.1f), radius = size.width * 0.6f))
            drawRect(Brush.radialGradient(listOf(b.copy(alpha = 0.28f), Color.Transparent), center = androidx.compose.ui.geometry.Offset(size.width * (0.95f - 0.5f * drift), size.height * 0.95f), radius = size.width * 0.55f))
        },
    )
}
