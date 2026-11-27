package com.droply.android.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.graphics.Color

private val LightColors = lightColorScheme(
    primary = Color(0xFF0A7AFF),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFE8F1FF),
    onPrimaryContainer = Color(0xFF0A3275),
    background = Color(0xFFF6F7FA),
    onBackground = Color(0xFF111318),
    surface = Color.White,
    onSurface = Color(0xFF111318),
    surfaceVariant = Color(0xFFEEF1F6),
    onSurfaceVariant = Color(0xFF6B7280),
    outline = Color(0xFFE6E9F0),
    error = Color(0xFFDC2626)
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFF4B95FF),
    onPrimary = Color(0xFF071A38),
    primaryContainer = Color(0xFF192B4A),
    onPrimaryContainer = Color(0xFFD6E5FF),
    background = Color(0xFF0D0F14),
    onBackground = Color(0xFFF3F5FA),
    surface = Color(0xFF151820),
    onSurface = Color(0xFFF3F5FA),
    surfaceVariant = Color(0xFF1E222D),
    onSurfaceVariant = Color(0xFF8F97A8),
    outline = Color(0xFF242936),
    error = Color(0xFFF87171)
)

@Composable
private fun animatedThemeColor(target: Color): Color {
    val color by animateColorAsState(
        targetValue = target,
        animationSpec = tween(durationMillis = 360, easing = FastOutSlowInEasing),
        label = "themeColor"
    )
    return color
}

@Composable
private fun rememberAnimatedColorScheme(target: ColorScheme): ColorScheme {
    return target.copy(
        primary = animatedThemeColor(target.primary),
        onPrimary = animatedThemeColor(target.onPrimary),
        primaryContainer = animatedThemeColor(target.primaryContainer),
        onPrimaryContainer = animatedThemeColor(target.onPrimaryContainer),
        background = animatedThemeColor(target.background),
        onBackground = animatedThemeColor(target.onBackground),
        surface = animatedThemeColor(target.surface),
        onSurface = animatedThemeColor(target.onSurface),
        surfaceVariant = animatedThemeColor(target.surfaceVariant),
        onSurfaceVariant = animatedThemeColor(target.onSurfaceVariant),
        outline = animatedThemeColor(target.outline),
        error = animatedThemeColor(target.error)
    )
}

@Composable
fun DroplyTheme(
    darkTheme: Boolean,
    content: @Composable () -> Unit
) {
    val targetScheme = if (darkTheme) DarkColors else LightColors
    val animatedScheme = rememberAnimatedColorScheme(targetScheme)

    MaterialTheme(
        colorScheme = animatedScheme,
        content = content
    )
}
