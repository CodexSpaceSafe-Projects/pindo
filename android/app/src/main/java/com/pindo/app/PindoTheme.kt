package com.pindo.app

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

private val LightPindoColors = lightColorScheme(
    primary = Color(0xFF2C6855), onPrimary = Color.White,
    primaryContainer = Color(0xFFDDEBE1), onPrimaryContainer = Color(0xFF153C2F),
    secondary = Color(0xFF607568), onSecondary = Color.White,
    secondaryContainer = Color(0xFFE6EDE5), onSecondaryContainer = Color(0xFF293D31),
    tertiary = Color(0xFF91683D), tertiaryContainer = Color(0xFFF5E7CF), onTertiaryContainer = Color(0xFF583A18),
    background = Color(0xFFF5F6F2), onBackground = Color(0xFF202A25),
    surface = Color(0xFFFCFDF9), onSurface = Color(0xFF202A25),
    surfaceVariant = Color(0xFFE8ECE5), onSurfaceVariant = Color(0xFF637067),
    surfaceContainerLowest = Color.White, surfaceContainerLow = Color(0xFFF1F4ED),
    surfaceContainer = Color(0xFFEBEFE7), surfaceContainerHigh = Color(0xFFE5EAE1),
    surfaceContainerHighest = Color(0xFFDFE5DB),
    outline = Color(0xFF89968B), outlineVariant = Color(0xFFD9E0D5),
    error = Color(0xFFAB423B), errorContainer = Color(0xFFFFE4DE), onErrorContainer = Color(0xFF70251F)
)

private val DarkPindoColors = darkColorScheme(
    primary = Color(0xFFA2D3BA), onPrimary = Color(0xFF12392A),
    primaryContainer = Color(0xFF294B3C), onPrimaryContainer = Color(0xFFC4EBD5),
    secondary = Color(0xFFB7CDBD), secondaryContainer = Color(0xFF354B3C), onSecondaryContainer = Color(0xFFD8E9DA),
    tertiary = Color(0xFFE4C18C), tertiaryContainer = Color(0xFF584127), onTertiaryContainer = Color(0xFFF5E2C6),
    background = Color(0xFF111713), onBackground = Color(0xFFDFE7DE),
    surface = Color(0xFF151D17), onSurface = Color(0xFFDFE7DE),
    surfaceVariant = Color(0xFF303C32), onSurfaceVariant = Color(0xFFB3BEB3),
    surfaceContainerLowest = Color(0xFF0D130F), surfaceContainerLow = Color(0xFF19221C),
    surfaceContainer = Color(0xFF1E2921), surfaceContainerHigh = Color(0xFF263229),
    surfaceContainerHighest = Color(0xFF303D33),
    outline = Color(0xFF829183), outlineVariant = Color(0xFF3F4D41),
    error = Color(0xFFFFB4A8), errorContainer = Color(0xFF65342E), onErrorContainer = Color(0xFFFFDAD2)
)

@Composable internal fun isPindoDarkTheme(theme: String): Boolean = when (theme) {
    "light" -> false
    "dark" -> true
    else -> isSystemInDarkTheme()
}

@Composable fun PindoTheme(theme: String = "system", content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isPindoDarkTheme(theme)) DarkPindoColors else LightPindoColors,
        shapes = Shapes(
            extraSmall = RoundedCornerShape(6.dp), small = RoundedCornerShape(10.dp),
            medium = RoundedCornerShape(16.dp), large = RoundedCornerShape(22.dp),
            extraLarge = RoundedCornerShape(28.dp)
        ),
        content = content
    )
}
