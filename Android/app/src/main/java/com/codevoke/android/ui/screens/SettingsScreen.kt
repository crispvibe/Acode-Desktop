package com.codevoke.android.ui.screens

import android.os.Build
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Code
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalContext
import com.codevoke.android.ui.components.WhiteGlassBackground
import com.codevoke.android.ui.theme.CodevokeColor

@Composable
fun SettingsScreen(
    connectionStatus: String,
    selectedCLI: String,
    goBack: () -> Unit,
    openDevices: () -> Unit,
) {
    val context = LocalContext.current
    val packageInfo = remember {
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull()
    }
    val versionName = packageInfo?.versionName.orEmpty().ifBlank { "1.0" }
    val versionCode = remember(packageInfo) {
        packageInfo?.let {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                it.longVersionCode.toString()
            } else {
                @Suppress("DEPRECATION")
                val legacyVersionCode = it.versionCode
                legacyVersionCode.toString()
            }
        }.orEmpty().ifBlank { "1" }
    }
    val versionText = "版本 $versionName ($versionCode)"

    Box(Modifier.fillMaxSize()) {
        WhiteGlassBackground(Modifier.fillMaxSize())
        Column(
            Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 22.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            TopTitleBar(title = "设置", goBack = goBack)
            SettingsSectionCard {
                Column {
                    SettingsMenuRow("远程设备", connectionStatus, Icons.Rounded.Computer, onClick = openDevices)
                    SettingsDivider()
                    SettingsMenuRow("CLI", if (selectedCLI == "codex") "Codex" else "Claude Code", Icons.Rounded.Code, showChevron = false)
                }
            }
            SettingsSectionCard {
                Column {
                    SettingsMenuRow("关于 Codevoke", versionText, Icons.Rounded.Info, showChevron = false)
                }
            }
        }
    }
}

@Composable
private fun SettingsSectionCard(
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit,
) {
    val shape = RoundedCornerShape(26.dp)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .shadow(16.dp, shape, ambientColor = Color.Black.copy(alpha = 0.055f), spotColor = Color.Black.copy(alpha = 0.055f))
            .clip(shape)
            .background(Color.White.copy(alpha = 0.62f))
            .border(BorderStroke(1.dp, Color.Black.copy(alpha = 0.055f)), shape),
        content = content,
    )
}

@Composable
private fun SettingsMenuRow(
    title: String,
    subtitle: String,
    icon: ImageVector,
    showChevron: Boolean = true,
    onClick: (() -> Unit)? = null,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 14.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        SettingsPlainIcon(icon = icon, tint = CodevokeColor.Ink.copy(alpha = 0.72f))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, color = CodevokeColor.Ink, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(subtitle, color = CodevokeColor.Muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (showChevron) {
            Icon(
                imageVector = Icons.Rounded.ChevronRight,
                contentDescription = null,
                tint = CodevokeColor.Muted.copy(alpha = 0.55f),
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun SettingsPlainIcon(
    icon: ImageVector,
    tint: Color = CodevokeColor.Ink.copy(alpha = 0.58f),
    size: androidx.compose.ui.unit.Dp = 16.dp,
    frame: androidx.compose.ui.unit.Dp = 31.dp,
) {
    Box(modifier = Modifier.size(frame), contentAlignment = Alignment.Center) {
        Icon(imageVector = icon, contentDescription = null, tint = tint, modifier = Modifier.size(size))
    }
}

@Composable
private fun SettingsDivider(modifier: Modifier = Modifier) {
    HorizontalDivider(
        modifier = modifier
            .padding(start = 57.dp)
            .fillMaxWidth(),
        color = Color.Black.copy(alpha = 0.08f),
        thickness = 1.dp,
    )
}
