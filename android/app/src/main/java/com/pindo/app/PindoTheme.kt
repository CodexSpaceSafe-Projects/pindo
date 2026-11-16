package com.pindo.app

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private val LightPindoColors = lightColorScheme(
    primary = Color(0xFF4058AF), onPrimary = Color.White,
    primaryContainer = Color(0xFFE8EDFF), onPrimaryContainer = Color(0xFF263C87),
    secondary = Color(0xFF606575), onSecondary = Color.White,
    secondaryContainer = Color(0xFFEFEEE9), onSecondaryContainer = Color(0xFF3D414B),
    tertiary = Color(0xFF8B6B48), onTertiary = Color.White,
    tertiaryContainer = Color(0xFFF4E9D9), onTertiaryContainer = Color(0xFF614424),
    background = Color(0xFFFAF9F6), onBackground = Color(0xFF252831),
    surface = Color(0xFFFFFEFB), onSurface = Color(0xFF252831),
    surfaceVariant = Color(0xFFF0EFEB), onSurfaceVariant = Color(0xFF686C77),
    surfaceContainerLowest = Color(0xFFFFFEFB), surfaceContainerLow = Color(0xFFF5F4F0),
    surfaceContainer = Color(0xFFEFEEE9), surfaceContainerHigh = Color(0xFFE9E8E3),
    surfaceContainerHighest = Color(0xFFE3E2DD),
    outline = Color(0xFF858995), outlineVariant = Color(0xFFE1E1DD),
    error = Color(0xFFAD443E), onError = Color.White,
    errorContainer = Color(0xFFFBE9E4), onErrorContainer = Color(0xFF7D2D29)
)
private val DarkPindoColors = darkColorScheme(
    primary = Color(0xFFBBC8FF), onPrimary = Color(0xFF203576),
    primaryContainer = Color(0xFF2C3D72), onPrimaryContainer = Color(0xFFDFE5FF),
    secondary = Color(0xFFC1C5D3), onSecondary = Color(0xFF2A2F3B),
    secondaryContainer = Color(0xFF303540), onSecondaryContainer = Color(0xFFE1E5EF),
    tertiary = Color(0xFFE4C291), onTertiary = Color(0xFF49371E),
    tertiaryContainer = Color(0xFF51412B), onTertiaryContainer = Color(0xFFF7E3C7),
    background = Color(0xFF14171D), onBackground = Color(0xFFE7E9EF),
    surface = Color(0xFF1B1F27), onSurface = Color(0xFFE7E9EF),
    surfaceVariant = Color(0xFF303641), onSurfaceVariant = Color(0xFFAFB5C4),
    surfaceContainerLowest = Color(0xFF101319), surfaceContainerLow = Color(0xFF1B1F27),
    surfaceContainer = Color(0xFF222730), surfaceContainerHigh = Color(0xFF2A303B),
    surfaceContainerHighest = Color(0xFF343B48),
    outline = Color(0xFF8C93A3), outlineVariant = Color(0xFF353C48),
    error = Color(0xFFFFB4A8), onError = Color(0xFF651B17),
    errorContainer = Color(0xFF5C302D), onErrorContainer = Color(0xFFFFDAD2)
)
private val PindoTypography = Typography().let { base ->
    base.copy(
        headlineLarge = base.headlineLarge.copy(fontSize = 30.sp, lineHeight = 38.sp, fontWeight = FontWeight.Bold, letterSpacing = (-.6).sp),
        headlineMedium = base.headlineMedium.copy(fontSize = 27.sp, lineHeight = 36.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-.4).sp),
        headlineSmall = base.headlineSmall.copy(fontSize = 24.sp, lineHeight = 34.sp, fontWeight = FontWeight.SemiBold),
        titleLarge = base.titleLarge.copy(fontSize = 22.sp, lineHeight = 30.sp, fontWeight = FontWeight.SemiBold),
        titleMedium = base.titleMedium.copy(fontSize = 16.sp, lineHeight = 24.sp, fontWeight = FontWeight.SemiBold),
        bodyLarge = base.bodyLarge.copy(fontSize = 16.sp, lineHeight = 25.sp, letterSpacing = 0.sp),
        bodyMedium = base.bodyMedium.copy(fontSize = 14.sp, lineHeight = 22.sp, letterSpacing = 0.sp),
        bodySmall = base.bodySmall.copy(fontSize = 12.sp, lineHeight = 18.sp),
        labelLarge = base.labelLarge.copy(fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.Medium),
        labelMedium = base.labelMedium.copy(fontSize = 12.sp, lineHeight = 18.sp, fontWeight = FontWeight.Medium)
    )
}
@Composable internal fun isPindoDarkTheme(theme: String): Boolean = when (theme) {
    "light" -> false
    "dark" -> true
    else -> isSystemInDarkTheme()
}
@Composable fun PindoTheme(theme: String = "system", content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isPindoDarkTheme(theme)) DarkPindoColors else LightPindoColors,
        typography = PindoTypography,
        shapes = Shapes(extraSmall = RoundedCornerShape(4.dp), small = RoundedCornerShape(8.dp),
            medium = RoundedCornerShape(12.dp), large = RoundedCornerShape(16.dp), extraLarge = RoundedCornerShape(24.dp)),
        content = content)
}
