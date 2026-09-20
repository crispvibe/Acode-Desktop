package com.codevoke.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Divider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.codevoke.android.ui.theme.CodevokeAlpha
import com.codevoke.android.ui.theme.CodevokeColor
import com.codevoke.android.ui.theme.CodevokeRadius
import com.codevoke.android.ui.theme.CodevokeSize
import com.codevoke.android.ui.theme.CodevokeSpace
import com.codevoke.android.ui.theme.CodevokeStroke
import com.codevoke.android.ui.theme.CodevokeType

@Composable
fun SectionTitle(title: String, subtitle: String, modifier: Modifier = Modifier) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(CodevokeSpace.MicroGap)) {
        Text(title, color = CodevokeColor.Ink, fontSize = CodevokeType.Title, fontWeight = FontWeight.SemiBold)
        Text(subtitle, color = CodevokeColor.Muted, fontSize = CodevokeType.CaptionSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
fun SettingsRow(
    title: String,
    subtitle: String,
    icon: ImageVector,
    modifier: Modifier = Modifier,
    showChevron: Boolean = true,
    onClick: (() -> Unit)? = null,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = CodevokeSpace.RowPaddingX, vertical = CodevokeSpace.RowPaddingY),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(CodevokeSpace.RowGap),
    ) {
        Icon(icon, contentDescription = null, tint = CodevokeColor.Ink.copy(alpha = 0.58f), modifier = Modifier.size(CodevokeSize.SettingsIcon))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(CodevokeSpace.NanoGap)) {
            Text(title, color = CodevokeColor.Ink, fontSize = CodevokeType.Body, fontWeight = FontWeight.SemiBold, maxLines = 1)
            Text(subtitle, color = CodevokeColor.Muted, fontSize = CodevokeType.Caption, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (showChevron) {
            Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = CodevokeColor.Muted.copy(alpha = 0.55f), modifier = Modifier.size(CodevokeSize.RowIcon))
        }
    }
}

@Composable
fun SettingsDivider(modifier: Modifier = Modifier) {
    Divider(
        modifier = modifier
            .padding(start = CodevokeSpace.DividerStart)
            .fillMaxWidth(),
        color = Color.Black.copy(alpha = 0.08f),
        thickness = CodevokeStroke.Thin,
    )
}

@Composable
fun BlackCapsuleButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.height(CodevokeSize.PrimaryButtonHeight),
        colors = ButtonDefaults.buttonColors(
            containerColor = CodevokeColor.Ink,
            contentColor = Color.White,
            disabledContainerColor = CodevokeColor.Ink.copy(alpha = CodevokeAlpha.PrimaryDisabledFill),
            disabledContentColor = Color.White.copy(alpha = CodevokeAlpha.PrimaryDisabledText),
        ),
        shape = RoundedCornerShape(CodevokeRadius.CircleControl),
        elevation = ButtonDefaults.buttonElevation(defaultElevation = 0.dp, pressedElevation = 0.dp),
        contentPadding = ButtonDefaults.ContentPadding,
    ) {
        Text(text, fontSize = CodevokeType.Body, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
fun StatusDot(online: Boolean, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(CodevokeSize.StatusDotLarge)
            .background(if (online) CodevokeColor.Green else CodevokeColor.Muted.copy(alpha = CodevokeAlpha.OfflineDot), CircleShape)
    )
}

@Composable
fun SelectionPill(selected: Boolean, text: String, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .background(if (selected) CodevokeColor.Ink else Color.Transparent, RoundedCornerShape(CodevokeRadius.Control))
            .padding(horizontal = CodevokeSpace.SegmentedPillX, vertical = CodevokeSpace.SegmentedPillY),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            color = if (selected) Color.White else CodevokeColor.Muted,
            fontSize = CodevokeType.Body,
            fontWeight = FontWeight.SemiBold,
        )
    }
}
