package com.zhylee.discipline.mobile.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable

private val DisciplineColors = lightColorScheme(
    primary = DisciplinePrimary,
    onPrimary = DisciplineOnPrimary,
    background = DisciplineBackground,
    onBackground = DisciplineOnSurface,
    surface = DisciplineSurface,
    onSurface = DisciplineOnSurface,
    surfaceVariant = DisciplineSurfaceVariant,
    onSurfaceVariant = DisciplineOnSurfaceVariant,
    outline = DisciplineOutline,
    outlineVariant = DisciplineOutline,
  )

@Composable
fun DisciplineTheme(content: @Composable () -> Unit) {
  MaterialTheme(colorScheme = DisciplineColors, typography = Typography, content = content)
}
