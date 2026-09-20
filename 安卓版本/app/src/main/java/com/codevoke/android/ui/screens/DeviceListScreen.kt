package com.codevoke.android.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ChevronLeft
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.codevoke.android.ui.components.CodevokeGlassCard
import com.codevoke.android.ui.components.CodevokeIconButton
import com.codevoke.android.ui.components.BlackCapsuleButton
import com.codevoke.android.ui.components.SectionTitle
import com.codevoke.android.ui.components.WhiteGlassBackground
import com.codevoke.android.ui.theme.CodevokeColor
import com.codevoke.android.ui.theme.CodevokeRadius

@Composable
fun DeviceListScreen(
    hosts: List<String>,
    scanning: Boolean,
    connecting: Boolean,
    manualHost: String,
    manualPort: String,
    message: String?,
    connectedHost: String?,
    goBack: () -> Unit,
    rescan: () -> Unit,
    onManualHostChange: (String) -> Unit,
    onManualPortChange: (String) -> Unit,
    connectManual: () -> Unit,
    connectHost: (String) -> Unit,
    openChat: () -> Unit,
) {
    Box(Modifier.fillMaxSize()) {
        WhiteGlassBackground(Modifier.fillMaxSize())
        Column(
            Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp, vertical = 22.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            TopTitleBar(title = "远程设备", goBack = goBack)
            DevicePageHeader()
            ManualConnectCard(
                manualHost = manualHost,
                manualPort = manualPort,
                connecting = connecting,
                onManualHostChange = onManualHostChange,
                onManualPortChange = onManualPortChange,
                connectManual = connectManual,
            )
            DiscoveredSection(
                hosts = hosts,
                scanning = scanning,
                connecting = connecting,
                message = message,
                connectedHost = connectedHost,
                rescan = rescan,
                connectHost = connectHost,
                openChat = openChat,
            )
        }
    }
}

@Composable
fun TopTitleBar(title: String, goBack: () -> Unit, trailing: (@Composable () -> Unit)? = null) {
    Box(
        Modifier
            .fillMaxWidth()
            .height(64.dp)
    ) {
        CodevokeIconButton(
            imageVector = Icons.Rounded.ChevronLeft,
            contentDescription = "返回",
            modifier = Modifier.align(Alignment.CenterStart),
            onClick = goBack,
        )
        Text(
            title,
            color = CodevokeColor.Ink,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.align(Alignment.Center),
        )
        if (trailing != null) {
            Box(modifier = Modifier.align(Alignment.CenterEnd)) {
                trailing()
            }
        }
    }
}

@Composable
private fun DevicePageHeader() {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            "连接电脑",
            color = CodevokeColor.Ink,
            fontSize = 28.sp,
            fontWeight = FontWeight.Bold,
        )
        Text(
            "同一 Wi-Fi 下的局域网直连，无需账号。",
            color = CodevokeColor.Muted,
            fontSize = 14.sp,
            lineHeight = 20.sp,
        )
    }
}

@Composable
private fun ManualConnectCard(
    manualHost: String,
    manualPort: String,
    connecting: Boolean,
    onManualHostChange: (String) -> Unit,
    onManualPortChange: (String) -> Unit,
    connectManual: () -> Unit,
) {
    CodevokeGlassCard(corner = CodevokeRadius.Control, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            SectionTitle("连接地址", "电脑的局域网 IP 与端口")
            LanTextField(value = manualHost, onValueChange = onManualHostChange, placeholder = "192.168.1.10")
            LanTextField(value = manualPort, onValueChange = onManualPortChange, placeholder = "18765")
            BlackCapsuleButton(
                text = if (connecting) "连接中..." else "连接",
                modifier = Modifier
                    .fillMaxWidth()
                    .height(54.dp),
                enabled = manualHost.isNotBlank() && !connecting,
                onClick = connectManual,
            )
        }
    }
}

@Composable
private fun LanTextField(value: String, onValueChange: (String) -> Unit, placeholder: String) {
    TextField(
        value = value,
        onValueChange = onValueChange,
        placeholder = { Text(placeholder, color = CodevokeColor.Muted.copy(alpha = 0.44f)) },
        colors = TextFieldDefaults.colors(
            focusedContainerColor = Color.White.copy(alpha = 0.68f),
            unfocusedContainerColor = Color.White.copy(alpha = 0.68f),
            disabledContainerColor = Color.White.copy(alpha = 0.42f),
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            disabledIndicatorColor = Color.Transparent,
        ),
        shape = RoundedCornerShape(18.dp),
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun DiscoveredSection(
    hosts: List<String>,
    scanning: Boolean,
    connecting: Boolean,
    message: String?,
    connectedHost: String?,
    rescan: () -> Unit,
    connectHost: (String) -> Unit,
    openChat: () -> Unit,
) {
    CodevokeGlassCard(corner = CodevokeRadius.Control, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SectionTitle("局域网设备", "自动扫描当前 Wi-Fi 网段", modifier = Modifier.weight(1f))
                RefreshChip(loading = scanning, refresh = rescan)
            }
            when {
                scanning && hosts.isEmpty() -> ScanningState()
                hosts.isEmpty() -> EmptyScanState(message = message, rescan = rescan)
                else -> {
                    hosts.forEach { host ->
                        LanHostRow(
                            host = host,
                            isConnected = host == connectedHost,
                            connecting = connecting,
                            onClick = { if (host == connectedHost) openChat() else connectHost(host) },
                        )
                    }
                    if (!message.isNullOrBlank()) {
                        Text(message, color = CodevokeColor.Muted, fontSize = 12.sp, lineHeight = 17.sp)
                    }
                }
            }
        }
    }
}

@Composable
private fun LanHostRow(host: String, isConnected: Boolean, connecting: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(Color.White.copy(alpha = if (isConnected) 0.72f else 0.54f))
            .then(if (isConnected) Modifier.border(1.5.dp, CodevokeColor.Ink.copy(alpha = 0.18f), RoundedCornerShape(22.dp)) else Modifier)
            .padding(horizontal = 14.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(Color.White.copy(alpha = 0.72f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Rounded.Computer,
                contentDescription = null,
                tint = CodevokeColor.Ink,
                modifier = Modifier.size(27.dp),
            )
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                host,
                color = CodevokeColor.Ink,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                if (isConnected) "已连接" else "局域网可连接",
                color = CodevokeColor.Muted,
                fontSize = 13.sp,
            )
        }
        if (isConnected) {
            Text(
                "进入",
                modifier = Modifier
                    .clip(RoundedCornerShape(18.dp))
                    .clickable(onClick = onClick)
                    .padding(horizontal = 14.dp, vertical = 9.dp),
                color = Color(0xFF2E7D32),
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
            )
        } else {
            BlackCapsuleButton(
                text = if (connecting) "连接中..." else "连接",
                modifier = Modifier.height(44.dp),
                enabled = !connecting,
                onClick = onClick,
            )
        }
    }
}

@Composable
private fun ScanningState() {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(Color.White.copy(alpha = 0.54f))
            .padding(horizontal = 16.dp, vertical = 18.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CircularProgressIndicator(
            modifier = Modifier.size(20.dp),
            strokeWidth = 2.5.dp,
            color = CodevokeColor.Ink,
            trackColor = CodevokeColor.Line,
        )
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text("正在扫描局域网", color = CodevokeColor.Ink, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Text("在 Wi-Fi 网段内探测电脑端连接服务。", color = CodevokeColor.Muted, fontSize = 12.sp)
        }
    }
}

@Composable
private fun EmptyScanState(message: String?, rescan: () -> Unit) {
    val hasMessage = !message.isNullOrBlank()
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(Color.White.copy(alpha = 0.54f))
            .padding(horizontal = 16.dp, vertical = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(Color.White.copy(alpha = 0.72f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (hasMessage) Icons.Rounded.ErrorOutline else Icons.Rounded.Computer,
                contentDescription = null,
                tint = CodevokeColor.Ink.copy(alpha = 0.72f),
                modifier = Modifier.size(25.dp),
            )
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("没有发现设备", color = CodevokeColor.Ink, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Text(
                message?.takeIf { it.isNotBlank() } ?: "请确认电脑端已开启连接服务，且手机与电脑在同一 Wi-Fi。",
                color = CodevokeColor.Muted,
                fontSize = 12.sp,
                lineHeight = 17.sp,
            )
        }
        Text(
            "重试",
            modifier = Modifier
                .clip(RoundedCornerShape(18.dp))
                .clickable(onClick = rescan)
                .padding(horizontal = 12.dp, vertical = 9.dp),
            color = CodevokeColor.Ink,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun RefreshChip(loading: Boolean, refresh: () -> Unit) {
    CodevokeGlassCard(corner = 18.dp, shadowAlpha = 0.02f) {
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(18.dp))
                .clickable(enabled = !loading, onClick = refresh)
                .padding(horizontal = 14.dp, vertical = 9.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (loading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(14.dp),
                    strokeWidth = 2.dp,
                    color = CodevokeColor.Ink,
                    trackColor = CodevokeColor.Line,
                )
            } else {
                Icon(Icons.Rounded.Refresh, contentDescription = null, tint = CodevokeColor.Ink, modifier = Modifier.size(16.dp))
            }
            Text(
                if (loading) "扫描中" else "重新扫描",
                color = CodevokeColor.Ink.copy(alpha = if (loading) 0.68f else 1f),
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}
