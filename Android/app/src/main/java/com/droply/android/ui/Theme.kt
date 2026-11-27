package com.droply.android.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// Exact palette aligned with Droply macOS ThemePalette (light & deep navy dark)
private val LightColors = lightColorScheme(
    primary = Color(0xFF0A7AFF),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFE7F1FF),
    onPrimaryContainer = Color(0xFF0A3275),
    background = Color(0xFFF4F6FB),
    onBackground = Color(0xFF171A21),
    surface = Color.White,
    onSurface = Color(0xFF171A21),
    surfaceVariant = Color(0xFFF1F3F9),
    onSurfaceVariant = Color(0xFF6E7585),
    outline = Color(0xFFE3E7F0),
    error = Color(0xFFDC2626)
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFF4794FF),
    onPrimary = Color.White,
    primaryContainer = Color(0xFF1D3254),
    onPrimaryContainer = Color(0xFFD6E6FF),
    background = Color(0xFF111319),
    onBackground = Color(0xFFF2F5FA),
    surface = Color(0xFF1D1F27),
    onSurface = Color(0xFFF2F5FA),
    surfaceVariant = Color(0xFF262831),
    onSurfaceVariant = Color(0xFF99A3B8),
    outline = Color(0xFF2F323E),
    error = Color(0xFFF87171)
)

@Composable
fun DroplyTheme(
    darkTheme: Boolean,
    content: @Composable () -> Unit
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        content = content
    )
}
