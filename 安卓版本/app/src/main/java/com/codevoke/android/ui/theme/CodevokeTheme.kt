package com.codevoke.android.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

object CodevokeColor {
    val Ink = Color(0xFF141414)
    val Muted = Color(0xFF6B6B6B)
    val Hairline = Color(0x0E000000)
    val Line = Color(0x14000000)
    val Soft = Color(0xFFF5F5F2)
    val BackgroundTop = Color.White
    val BackgroundMiddle = Color(0xFFFDFDFC)
    val BackgroundBottom = Color(0xFFF9F9F8)
    val GlassFill = Color(0x85FFFFFF)
    val GlassPanel = Color(0xB8FFFFFF)
    val GlassStroke = Color(0xBDFFFFFF)
    val GlassCardFill = Color(0xD1FFFFFF)
    val GlassCardStroke = Color(0xD1FFFFFF)
    val GlassCardHairline = Color(0x0B000000)
    val AuthGlassFill = Color(0xADFFFFFF)
    val AuthGlassStroke = Color(0xE0FFFFFF)
    val ControlFill = Color(0x6BFFFFFF)
    val ControlBrightFill = Color(0xC2FFFFFF)
    val Scrim = Color(0x3D000000)
    val Green = Color(0xFF5CCB63)
}

private val CodevokeLightScheme = lightColorScheme(
    primary = CodevokeColor.Ink,
    onPrimary = Color.White,
    background = Color.White,
    onBackground = CodevokeColor.Ink,
    surface = Color.White,
    onSurface = CodevokeColor.Ink,
    outline = CodevokeColor.Hairline,
)

@Composable
fun CodevokeTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = CodevokeLightScheme,
        typography = MaterialTheme.typography,
        content = content,
    )
}
