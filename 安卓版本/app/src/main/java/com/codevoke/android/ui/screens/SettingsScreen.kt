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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowCircleUp
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Cloud
import androidx.compose.material.icons.rounded.Code
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.ElectricBolt
import androidx.compose.material.icons.rounded.Flight
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.NearMe
import androidx.compose.material.icons.rounded.Nightlight
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.SystemUpdate
import androidx.compose.material.icons.rounded.Terminal
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalContext
import com.codevoke.android.data.RemoteCapability
import com.codevoke.android.ui.components.SectionTitle
import com.codevoke.android.ui.components.WhiteGlassBackground
import com.codevoke.android.ui.state.UpdateUiState
import com.codevoke.android.ui.theme.CodevokeColor
import java.util.Locale

internal data class CliOption(
    val id: String,
    val title: String,
    val subtitle: String,
    val icon: ImageVector,
)

// host 端 `cli` 字段是 String 透传；这里放已知 CLI 的展示元数据，
// host 新增 CLI 后补一行即可。
internal val cliCatalog = listOf(
    CliOption("claude", "Claude Code", "Anthropic Claude CLI", Icons.Rounded.AutoAwesome),
    CliOption("codex", "Codex", "OpenAI Codex CLI", Icons.Rounded.Terminal),
    CliOption("cursor", "Cursor Agent", "Cursor 编辑器内置 Agent CLI", Icons.Rounded.NearMe),
    CliOption("gemini", "Gemini", "Google Gemini CLI", Icons.Rounded.Star),
    CliOption("qwen", "Qwen Code", "阿里通义 Qwen Code CLI", Icons.Rounded.Cloud),
    CliOption("copilot", "Copilot", "GitHub Copilot CLI", Icons.Rounded.Flight),
    CliOption("kimi", "Kimi", "Moonshot Kimi CLI", Icons.Rounded.Nightlight),
    CliOption("agy", "Antigravity", "Google Antigravity CLI", Icons.Rounded.ArrowCircleUp),
    CliOption("kiro", "Kiro", "AWS Kiro CLI", Icons.Rounded.ElectricBolt),
)

// CLI id → 展示名；host 新增未收录的 cli 时兜底为首字母大写的原始值，避免空白。
internal fun cliDisplayName(cli: String): String {
    val normalized = cli.trim()
    return cliCatalog.firstOrNull { it.id == normalized }?.title
        ?: normalized.replaceFirstChar { if (it.isLowerCase()) it.titlecase(Locale.ROOT) else it.toString() }
}

@Composable
fun SettingsScreen(
    connectionStatus: String,
    selectedCLI: String,
    update: UpdateUiState,
    goBack: () -> Unit,
    openDevices: () -> Unit,
    openCLI: () -> Unit,
    checkUpdates: () -> Unit,
    showUpdateDialog: () -> Unit,
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
                    SettingsMenuRow("CLI", cliDisplayName(selectedCLI), Icons.Rounded.Code, onClick = openCLI)
                }
            }
            SettingsSectionCard {
                Column {
                    if (update.update != null) {
                        UpdateBannerRow(
                            version = update.update.version,
                            onClick = showUpdateDialog,
                        )
                        SettingsDivider()
                    }
                    SettingsMenuRow(
                        title = "检查更新",
                        subtitle = when {
                            update.checking -> "正在检查更新…"
                            update.update != null -> "发现新版本 v${update.update.version}"
                            !update.notice.isNullOrBlank() -> update.notice
                            else -> "当前版本 $versionName"
                        },
                        icon = Icons.Rounded.SystemUpdate,
                        onClick = checkUpdates,
                    )
                    SettingsDivider()
                    SettingsMenuRow("关于 acode", versionText, Icons.Rounded.Info, showChevron = false)
                    SettingsDivider()
                    Column(
                        Modifier.padding(horizontal = 14.dp).padding(bottom = 13.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text("© 2026 crispvibe · 仅限个人非商业使用，禁止商用", color = CodevokeColor.Muted, fontSize = 12.sp)
                        Text("许可：PolyForm Noncommercial 1.0.0", color = CodevokeColor.Muted, fontSize = 12.sp)
                        Text("QQ 群：1076321843（Code 开源技术交流群）", color = CodevokeColor.Muted, fontSize = 12.sp)
                        Text("仓库：github.com/crispvibe/Acode-Desktop", color = CodevokeColor.Muted, fontSize = 12.sp)
                    }
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

/// 设置页顶部「有新版本」横幅：点击重新打开更新弹窗。
@Composable
private fun UpdateBannerRow(version: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        SettingsPlainIcon(icon = Icons.Rounded.ArrowCircleUp, tint = Color(0xFF2E7D32))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("发现新版本", color = CodevokeColor.Ink, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text("v$version · 点击查看更新内容", color = CodevokeColor.Muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text(
            "更新",
            modifier = Modifier
                .clip(RoundedCornerShape(18.dp))
                .clickable(onClick = onClick)
                .padding(horizontal = 14.dp, vertical = 9.dp),
            color = Color(0xFF2E7D32),
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
        )
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

@Composable
fun CliScreen(
    selectedCLI: String,
    capabilities: List<RemoteCapability>,
    goBack: () -> Unit,
    selectCLI: (String) -> Unit,
) {
    Box(Modifier.fillMaxSize()) {
        WhiteGlassBackground(Modifier.fillMaxSize())
        Column(
            Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 22.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            TopTitleBar(title = "CLI", goBack = goBack)
            SettingsSectionCard {
                Column(
                    Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    SectionTitle("命令行后端", "选择消息使用的 CLI")
                    cliCatalog.forEach { option ->
                        // 与 iOS SettingsCLIPage 对齐：host 下发的 capability
                        // 标记不可用时禁用行并展示 errorMessage。
                        val cap = capabilities.firstOrNull { it.cli == option.id }
                        val unavailable = cap?.executableAvailable == false
                        CliOptionRow(
                            title = option.title,
                            subtitle = if (unavailable) cap?.errorMessage ?: "${option.title} 不可用" else option.subtitle,
                            icon = option.icon,
                            selected = selectedCLI == option.id,
                            enabled = !unavailable,
                            onClick = { selectCLI(option.id) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun CliOptionRow(
    title: String,
    subtitle: String,
    icon: ImageVector,
    selected: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(if (selected) Color.White.copy(alpha = 0.85f) else Color.White.copy(alpha = 0.45f))
            .border(
                BorderStroke(1.dp, if (selected) Color.Black.copy(alpha = 0.18f) else Color.White.copy(alpha = 0.6f)),
                RoundedCornerShape(14.dp),
            )
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp)
            .alpha(if (enabled) 1f else 0.5f),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        SettingsPlainIcon(
            icon = icon,
            tint = CodevokeColor.Ink.copy(alpha = if (selected) 0.78f else 0.5f),
            size = 13.dp,
            frame = 24.dp,
        )
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(title, color = CodevokeColor.Ink, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(subtitle, color = CodevokeColor.Muted, fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (selected) {
            Icon(
                imageVector = Icons.Rounded.Check,
                contentDescription = null,
                tint = CodevokeColor.Ink,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}
