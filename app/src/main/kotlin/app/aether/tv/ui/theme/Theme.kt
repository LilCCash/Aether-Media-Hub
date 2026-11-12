package app.aether.tv.ui.theme

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.aether.core.settings.AppearanceSettings
import app.aether.core.settings.BackgroundStyle
import app.aether.core.settings.GraphicsQuality

/**
 * The look of Aether on a television, in the manner of tvOS: a deep neutral black, translucent «glass» surfaces, white text, and an
 * element under the remote that lifts towards the viewer (brighter, a little larger, with a soft shadow). The accent colour the
 * viewer picks is kept for small touches (progress, selected marks), never for large areas.
 */
object AetherColors {
    val Background = Color(0xFF0A0A0C)
    /** Opaque panel (dialogs, sheets). */
    val Surface = Color(0xFF1A1A1F)
    /** Glass surfaces: white at low opacity over the dark background (cheap to draw, no blur needed). */
    val SurfaceRaised = Color(0x1AFFFFFF)
    val SurfaceFocused = Color(0x38FFFFFF)
    val Glass = Color(0x12FFFFFF)
    val GlassStroke = Color(0x21FFFFFF)
    val OnBackground = Color(0xFFF5F5F7)
    val OnSurfaceMuted = Color(0xFFAEAEB6)
    val OnSurfaceFaint = Color(0xFF75757E)
    /** Text on a focused (white) control. */
    val OnFocused = Color(0xFF111114)
    val Danger = Color(0xFFFF6961)
    val Success = Color(0xFF32D74B)
    val Warning = Color(0xFFFFB340)
    val Scrim = Color(0xE60A0A0C)
}

/** The area TVs may crop (overscan) and the margins the layouts keep. */
object AetherDimens {
    val ScreenHorizontal = 56.dp
    val ScreenVertical = 28.dp
    /** Room left at the top of a section for the tab bar. */
    val TopBar = 78.dp
    val RailCollapsed = 0.dp
    val RailExpanded = 0.dp
    val RowSpacing = 18.dp
}

/** What the interface is allowed to draw, from Impostazioni ▸ Aspetto ▸ Grafica (and the power of the TV). */
data class Graphics(
    val quality: GraphicsQuality,
    val animations: Boolean,
    val blur: Boolean,
    val shadows: Boolean,
    val backdropArt: Boolean,
    val imageFades: Boolean,
) {
    /** Milliseconds for a transition, 0 without animations. */
    fun ms(full: Int) = if (!animations) 0 else if (quality == GraphicsQuality.BALANCED) full * 2 / 3 else full

    companion object {
        val Default = Graphics(GraphicsQuality.FULL, animations = true, blur = true, shadows = true, backdropArt = true, imageFades = true)

        /** The level of a TV left on «Automatica»: low-RAM devices and slow boxes get the light one. */
        fun autoLevel(context: Context): GraphicsQuality {
            val am = context.getSystemService(ActivityManager::class.java)
            val cores = Runtime.getRuntime().availableProcessors()
            val memoryClass = am?.memoryClass ?: 128
            return when {
                am?.isLowRamDevice == true || memoryClass < 160 || cores <= 2 || Build.VERSION.SDK_INT < 26 -> GraphicsQuality.LIGHT
                memoryClass < 256 || cores <= 4 -> GraphicsQuality.BALANCED
                else -> GraphicsQuality.FULL
            }
        }

        fun resolve(appearance: AppearanceSettings, autoLevel: GraphicsQuality): Graphics {
            val level = if (appearance.graphics == GraphicsQuality.AUTO) autoLevel else appearance.graphics
            val o = appearance.graphicsOverrides
            val full = level == GraphicsQuality.FULL
            val light = level == GraphicsQuality.LIGHT
            return Graphics(
                quality = level,
                animations = appearance.animationsEnabled && !light,
                // Real blur needs Android 12 (RenderEffect); older TVs get the plain glass.
                blur = (o.blur ?: full) && Build.VERSION.SDK_INT >= 31,
                shadows = o.shadows ?: !light,
                backdropArt = o.backdropArt ?: !light,
                imageFades = o.imageFades ?: !light,
            )
        }
    }
}

val LocalAccent = compositionLocalOf { Color(0xFF0A84FF) }
val LocalAnimations = compositionLocalOf { true }
val LocalGraphics = staticCompositionLocalOf { Graphics.Default }

/** Corner radius of cards and buttons, chosen in the settings. */
val LocalCorner = compositionLocalOf { 14.dp }

private val Sans = FontFamily.SansSerif

private val AetherTypography = Typography(
    displayLarge = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Bold, fontSize = 54.sp, lineHeight = 60.sp, letterSpacing = (-0.8).sp),
    displayMedium = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Bold, fontSize = 42.sp, lineHeight = 48.sp, letterSpacing = (-0.6).sp),
    displaySmall = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Bold, fontSize = 34.sp, lineHeight = 40.sp, letterSpacing = (-0.4).sp),
    headlineLarge = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Bold, fontSize = 32.sp, lineHeight = 38.sp, letterSpacing = (-0.3).sp),
    headlineMedium = TextStyle(fontFamily = Sans, fontWeight = FontWeight.SemiBold, fontSize = 26.sp, lineHeight = 32.sp, letterSpacing = (-0.2).sp),
    titleLarge = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Bold, fontSize = 21.sp, lineHeight = 27.sp, letterSpacing = (-0.1).sp),
    titleMedium = TextStyle(fontFamily = Sans, fontWeight = FontWeight.SemiBold, fontSize = 18.sp, lineHeight = 24.sp),
    titleSmall = TextStyle(fontFamily = Sans, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, lineHeight = 21.sp),
    bodyLarge = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Normal, fontSize = 18.sp, lineHeight = 26.sp),
    bodyMedium = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Normal, fontSize = 16.sp, lineHeight = 23.sp),
    bodySmall = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Normal, fontSize = 14.sp, lineHeight = 20.sp),
    labelLarge = TextStyle(fontFamily = Sans, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, lineHeight = 20.sp),
    labelMedium = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Medium, fontSize = 14.sp, lineHeight = 18.sp),
    labelSmall = TextStyle(fontFamily = Sans, fontWeight = FontWeight.Medium, fontSize = 12.sp, lineHeight = 16.sp, letterSpacing = 0.2.sp),
)

@Composable
fun AetherTheme(accent: Color, animations: Boolean = true, corner: Dp = 14.dp, graphics: Graphics = Graphics.Default, content: @Composable () -> Unit) {
    val scheme = darkColorScheme(
        primary = accent,
        onPrimary = Color.White,
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
    CompositionLocalProvider(
        LocalAccent provides accent,
        LocalAnimations provides (animations && graphics.animations),
        LocalCorner provides corner,
        LocalGraphics provides graphics,
    ) {
        MaterialTheme(colorScheme = scheme, typography = AetherTypography, content = content)
    }
}

/** A veil over a backdrop so text on it stays readable from the couch. */
fun backdropScrimHorizontal(): Brush = Brush.horizontalGradient(
    0f to Color(0xF00A0A0C), 0.38f to Color(0xB30A0A0C), 0.7f to Color(0x330A0A0C), 1f to Color.Transparent,
)

fun backdropScrimVertical(): Brush = Brush.verticalGradient(0f to Color(0x660A0A0C), 0.25f to Color.Transparent, 0.6f to Color(0x800A0A0C), 1f to Color(0xFF0A0A0C))

/** The soft light behind every screen; «Aurora» drifts slowly (only with animations). Nothing is drawn on the light level. */
@Composable
fun AppBackdrop(style: BackgroundStyle, accent: Color, animated: Boolean) {
    val graphics = LocalGraphics.current
    if (graphics.quality == GraphicsQuality.LIGHT) return
    val (a, b) = when (style) {
        BackgroundStyle.NIGHT -> accent.copy(alpha = 0.5f) to Color(0xFF2C2C3A)
        BackgroundStyle.AURORA -> accent to Color(0xFF32D7A0)
        BackgroundStyle.CINEMA -> Color(0xFF8B1E2D) to Color(0xFF3A0F18)
        BackgroundStyle.OCEAN -> Color(0xFF1C6FB8) to Color(0xFF0E8F8A)
        BackgroundStyle.EMBER -> Color(0xFFD9541E) to Color(0xFF7A1F3D)
    }
    val drift = if (animated && graphics.animations && style == BackgroundStyle.AURORA) {
        val t = rememberInfiniteTransition(label = "aurora")
        val value by t.animateFloat(0f, 1f, infiniteRepeatable(tween(18000, easing = LinearEasing), RepeatMode.Reverse), label = "drift")
        value
    } else 0.5f
    Box(
        Modifier.fillMaxSize().drawBehind {
            drawRect(Brush.radialGradient(listOf(a.copy(alpha = 0.20f), Color.Transparent), center = Offset(size.width * (0.15f + 0.5f * drift), -size.height * 0.1f), radius = size.width * 0.7f))
            drawRect(Brush.radialGradient(listOf(b.copy(alpha = 0.16f), Color.Transparent), center = Offset(size.width * (0.95f - 0.5f * drift), size.height * 1.05f), radius = size.width * 0.6f))
        },
    )
}
