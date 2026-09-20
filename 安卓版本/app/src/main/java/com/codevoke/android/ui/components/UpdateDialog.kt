package com.codevoke.android.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import com.codevoke.android.ui.state.UpdateUiState
import com.codevoke.android.ui.theme.CodevokeColor
import com.codevoke.android.ui.theme.CodevokeRadius
import java.util.Locale

/**
 * 应用内更新弹窗（GitHub Releases）：版本号 + release notes 摘要 + 「下载安装」。
 * 下载中显示进度条；release 未附 APK 时退化为「前往下载页」。
 */
@Composable
fun UpdateDialog(
    state: UpdateUiState,
    currentVersion: String,
    onDismiss: () -> Unit,
    onDownloadInstall: () -> Unit,
    onOpenReleasePage: () -> Unit,
) {
    val info = state.update ?: return
    Dialog(onDismissRequest = { if (!state.downloading) onDismiss() }) {
        CodevokeGlassCard(corner = CodevokeRadius.Control, modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                SectionTitle("发现新版本", "v${info.version} · 当前版本 v$currentVersion")
                if (info.notes.isNotBlank()) {
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .heightIn(max = 180.dp)
                            .verticalScroll(rememberScrollState()),
                    ) {
                        Text(
                            info.notes.trim(),
                            color = CodevokeColor.Muted,
                            fontSize = 13.sp,
                            lineHeight = 19.sp,
                        )
                    }
                }
                if (state.downloading) {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        LinearProgressIndicator(
                            progress = { state.downloadProgress },
                            modifier = Modifier.fillMaxWidth(),
                            color = CodevokeColor.Ink,
                            trackColor = CodevokeColor.Line,
                        )
                        Text(
                            downloadProgressText(state),
                            color = CodevokeColor.Muted,
                            fontSize = 12.sp,
                        )
                    }
                }
                if (!state.error.isNullOrBlank()) {
                    Text(state.error, color = Color(0xFFC62828), fontSize = 12.sp, lineHeight = 17.sp)
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text(
                        "稍后",
                        modifier = Modifier
                            .clip(RoundedCornerShape(18.dp))
                            .clickable(enabled = !state.downloading, onClick = onDismiss)
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                        color = CodevokeColor.Muted,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    BlackCapsuleButton(
                        text = updateButtonText(state),
                        modifier = Modifier
                            .weight(1f)
                            .height(48.dp),
                        enabled = !state.downloading,
                        onClick = if (info.apkUrl != null) onDownloadInstall else onOpenReleasePage,
                    )
                }
            }
        }
    }
}

private fun updateButtonText(state: UpdateUiState): String {
    val info = state.update
    val downloaded = state.downloadedApk != null && state.downloadedVersion == info?.version
    return when {
        state.downloading -> "下载中…"
        downloaded -> "安装"
        info?.apkUrl == null -> "前往下载页"
        else -> "下载安装"
    }
}

private fun downloadProgressText(state: UpdateUiState): String {
    val soFarMb = state.downloadedBytes / 1024f / 1024f
    return if (state.downloadTotal > 0) {
        val totalMb = state.downloadTotal / 1024f / 1024f
        val percent = (state.downloadProgress * 100).toInt()
        String.format(Locale.ROOT, "已下载 %d%%（%.1f / %.1f MB）", percent, soFarMb, totalMb)
    } else {
        String.format(Locale.ROOT, "已下载 %.1f MB", soFarMb)
    }
}
