package com.droply.android.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val LightColors = lightColorScheme(
    primary = Color(0xFF111216),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFEBECEF),
    onPrimaryContainer = Color(0xFF111216),
    background = Color(0xFFF6F6F8),
    onBackground = Color(0xFF111216),
    surface = Color.White,
    onSurface = Color(0xFF111216),
    surfaceVariant = Color(0xFFECEEF2),
    onSurfaceVariant = Color(0xFF686D78),
    outline = Color(0xFFE2E4EA),
    error = Color(0xFFDC2626)
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFFF4F4F6),
    onPrimary = Color(0xFF09090B),
    primaryContainer = Color(0xFF1E1E24),
    onPrimaryContainer = Color(0xFFF4F4F6),
    background = Color(0xFF09090B),
    onBackground = Color(0xFFF4F4F6),
    surface = Color(0xFF121216),
    onSurface = Color(0xFFF4F4F6),
    surfaceVariant = Color(0xFF1B1B21),
    onSurfaceVariant = Color(0xFF8C909C),
    outline = Color(0xFF24242C),
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
