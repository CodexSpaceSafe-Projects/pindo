package com.pindo.app

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private val LightPindoColors = lightColorScheme(
    primary = Color(0xFF2C6855), onPrimary = Color.White,
    primaryContainer = Color(0xFFDDEBE1), onPrimaryContainer = Color(0xFF153C2F),
    secondary = Color(0xFF607568), onSecondary = Color.White,
    secondaryContainer = Color(0xFFE6EDE5), onSecondaryContainer = Color(0xFF293D31),
    tertiary = Color(0xFF91683D), tertiaryContainer = Color(0xFFF5E7CF), onTertiaryContainer = Color(0xFF583A18),
    background = Color(0xFFFCFDFC), onBackground = Color(0xFF202A25),
    surface = Color.White, onSurface = Color(0xFF202A25),
    surfaceVariant = Color(0xFFE7EDE9), onSurfaceVariant = Color(0xFF56635C),
    surfaceContainerLowest = Color.White, surfaceContainerLow = Color(0xFFF0F4F1),
    surfaceContainer = Color(0xFFEAF0EC), surfaceContainerHigh = Color(0xFFE3EBE6),
    surfaceContainerHighest = Color(0xFFDBE5DF),
    outline = Color(0xFF79877F), outlineVariant = Color(0xFFD6E0D9),
    error = Color(0xFFAB423B), errorContainer = Color(0xFFFFE4DE), onErrorContainer = Color(0xFF70251F)
)

private val DarkPindoColors = darkColorScheme(
    primary = Color(0xFFA2D3BA), onPrimary = Color(0xFF12392A),
    primaryContainer = Color(0xFF294B3C), onPrimaryContainer = Color(0xFFC4EBD5),
    secondary = Color(0xFFB7CDBD), secondaryContainer = Color(0xFF354B3C), onSecondaryContainer = Color(0xFFD8E9DA),
    tertiary = Color(0xFFE4C18C), tertiaryContainer = Color(0xFF584127), onTertiaryContainer = Color(0xFFF5E2C6),
    background = Color(0xFF151B17), onBackground = Color(0xFFE2E9E4),
    surface = Color(0xFF19211C), onSurface = Color(0xFFE2E9E4),
    surfaceVariant = Color(0xFF303C34), onSurfaceVariant = Color(0xFFB9C6BD),
    surfaceContainerLowest = Color(0xFF0D130F), surfaceContainerLow = Color(0xFF19221C),
    surfaceContainer = Color(0xFF1E2921), surfaceContainerHigh = Color(0xFF263229),
    surfaceContainerHighest = Color(0xFF303D33),
    outline = Color(0xFF829183), outlineVariant = Color(0xFF3F4D41),
    error = Color(0xFFFFB4A8), errorContainer = Color(0xFF65342E), onErrorContainer = Color(0xFFFFDAD2)
)

private val PindoTypography = Typography().let { defaults ->
    defaults.copy(
        headlineLarge = defaults.headlineLarge.copy(fontSize = 24.sp, lineHeight = 32.sp),
        headlineMedium = defaults.headlineMedium.copy(fontSize = 24.sp, lineHeight = 32.sp),
        titleLarge = defaults.titleLarge.copy(fontSize = 22.sp, lineHeight = 30.sp),
        titleMedium = defaults.titleMedium.copy(lineHeight = 24.sp),
        bodyLarge = defaults.bodyLarge.copy(lineHeight = 26.sp),
        bodyMedium = defaults.bodyMedium.copy(lineHeight = 22.sp)
    )
}

@Composable internal fun isPindoDarkTheme(theme: String): Boolean = when (theme) {
    "light" -> false
    "dark" -> true
    else -> isSystemInDarkTheme()
}

@Composable fun PindoTheme(theme: String = "system", content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isPindoDarkTheme(theme)) DarkPindoColors else LightPindoColors,
        typography = PindoTypography,
        shapes = Shapes(
            extraSmall = RoundedCornerShape(6.dp), small = RoundedCornerShape(10.dp),
            medium = RoundedCornerShape(16.dp), large = RoundedCornerShape(22.dp),
            extraLarge = RoundedCornerShape(28.dp)
        ),
        content = content
    )
}
