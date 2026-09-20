package com.codevoke.android.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.codevoke.android.ui.theme.CodevokeAlpha
import com.codevoke.android.ui.theme.CodevokeColor
import com.codevoke.android.ui.theme.CodevokeMotion
import com.codevoke.android.ui.theme.CodevokeRadius
import com.codevoke.android.ui.theme.CodevokeShadow
import com.codevoke.android.ui.theme.CodevokeSize
import com.codevoke.android.ui.theme.CodevokeSpace
import com.codevoke.android.ui.theme.CodevokeStroke

@Composable
fun WhiteGlassBackground(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier.background(
            Brush.linearGradient(
                listOf(
                    CodevokeColor.BackgroundTop,
                    CodevokeColor.BackgroundMiddle,
                    CodevokeColor.BackgroundBottom,
                )
            )
        )
    ) {
        Box(
            modifier = Modifier
                .offset(x = (-70).dp, y = (-80).dp)
                .size(240.dp)
                .blur(34.dp)
                .background(Color.White.copy(alpha = 0.98f), CircleShape)
        )
    }
}

@Composable
fun CodevokeGlassCard(
    modifier: Modifier = Modifier,
    corner: Dp = CodevokeRadius.Chrome,
    fill: Color = CodevokeColor.GlassCardFill,
    shadowAlpha: Float = CodevokeShadow.CardAlpha,
    content: @Composable BoxScope.() -> Unit,
) {
    val shape = RoundedCornerShape(corner)
    Box(
        modifier = modifier
            .shadow(CodevokeShadow.CardRadius, shape, ambientColor = Color.Black.copy(shadowAlpha), spotColor = Color.Black.copy(shadowAlpha))
            .clip(shape)
            .background(fill)
            .border(BorderStroke(CodevokeStroke.Thin, CodevokeColor.GlassCardStroke), shape)
            .border(BorderStroke(CodevokeStroke.Thin, CodevokeColor.GlassCardHairline), shape),
        content = content,
    )
}

@Composable
fun CodevokeSoftGlass(
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(CodevokeRadius.Control),
    fill: Color = CodevokeColor.GlassFill,
    content: @Composable BoxScope.() -> Unit,
) {
    Box(
        modifier = modifier
            .shadow(CodevokeShadow.ControlRadius, shape, ambientColor = Color.Black.copy(CodevokeShadow.ControlAlpha), spotColor = Color.Black.copy(CodevokeShadow.ControlAlpha))
            .clip(shape)
            .background(fill)
            .border(BorderStroke(CodevokeStroke.Thin, CodevokeColor.GlassStroke), shape),
        content = content,
    )
}

@Composable
fun CodevokeIconButton(
    imageVector: ImageVector,
    contentDescription: String,
    modifier: Modifier = Modifier,
    size: Dp = CodevokeSpace.Control,
    iconSize: Dp = CodevokeSize.ToolbarIcon,
    enabled: Boolean = true,
    dark: Boolean = false,
    onClick: () -> Unit,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed) CodevokeMotion.PressScale else 1f,
        animationSpec = tween(durationMillis = CodevokeMotion.PressMillis),
        label = "codevoke-press-scale",
    )
    val shape = CircleShape
    val background = if (dark) CodevokeColor.Ink else CodevokeColor.GlassFill
    val foreground = if (dark) Color.White else CodevokeColor.Ink

    Surface(
        modifier = modifier
            .size(size)
            .scale(scale)
            .alpha(if (pressed) CodevokeAlpha.PressedOpacity else 1f)
            .shadow(CodevokeShadow.ControlRadius, shape, ambientColor = Color.Black.copy(CodevokeShadow.ControlAlpha), spotColor = Color.Black.copy(CodevokeShadow.ControlAlpha))
            .clip(shape)
            .clickable(
                enabled = enabled,
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            ),
        shape = shape,
        color = background,
        border = if (dark) null else BorderStroke(CodevokeStroke.Thin, CodevokeColor.GlassStroke),
    ) {
        Box(contentAlignment = androidx.compose.ui.Alignment.Center) {
            Icon(
                imageVector = imageVector,
                contentDescription = contentDescription,
                tint = foreground.copy(alpha = if (enabled) 1f else CodevokeAlpha.DisabledContent),
                modifier = Modifier.size(iconSize),
            )
        }
    }
}
