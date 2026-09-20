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
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import com.codevoke.android.data.LanDiscoveredHost
import com.codevoke.android.data.PairedHost
import com.codevoke.android.ui.components.CodevokeGlassCard
import com.codevoke.android.ui.components.CodevokeIconButton
import com.codevoke.android.ui.components.BlackCapsuleButton
import com.codevoke.android.ui.components.SectionTitle
import com.codevoke.android.ui.components.WhiteGlassBackground
import com.codevoke.android.ui.state.PairTarget
import com.codevoke.android.ui.theme.CodevokeColor
import com.codevoke.android.ui.theme.CodevokeRadius

@Composable
fun DeviceListScreen(
    hosts: List<LanDiscoveredHost>,
    pairedHosts: List<PairedHost>,
    scanning: Boolean,
    connecting: Boolean,
    pairing: Boolean,
    pairTarget: PairTarget?,
    pairError: String?,
    manualHost: String,
    manualPort: String,
    connectionString: String,
    message: String?,
    connectedHostId: String?,
    goBack: () -> Unit,
    rescan: () -> Unit,
    onManualHostChange: (String) -> Unit,
    onManualPortChange: (String) -> Unit,
    onConnectionStringChange: (String) -> Unit,
    connectManual: () -> Unit,
    connectHost: (LanDiscoveredHost) -> Unit,
    connectPaired: (PairedHost) -> Unit,
    forgetPaired: (PairedHost) -> Unit,
    openScanner: () -> Unit,
    submitConnectionString: () -> Unit,
    dismissPairDialog: () -> Unit,
    submitPairCode: (String) -> Unit,
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
            if (pairedHosts.isNotEmpty()) {
                PairedDevicesSection(
                    pairedHosts = pairedHosts,
                    connecting = connecting,
                    connectedHostId = connectedHostId,
                    connectPaired = connectPaired,
                    forgetPaired = forgetPaired,
                    openChat = openChat,
                )
            }
            PairEntryCard(
                connectionString = connectionString,
                connecting = connecting,
                onConnectionStringChange = onConnectionStringChange,
                openScanner = openScanner,
                submitConnectionString = submitConnectionString,
            )
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
                connectedHostId = connectedHostId,
                rescan = rescan,
                connectHost = connectHost,
                openChat = openChat,
            )
        }
        if (pairTarget != null) {
            PairCodeDialog(
                target = pairTarget,
                pairing = pairing,
                error = pairError,
                onDismiss = dismissPairDialog,
                onSubmit = submitPairCode,
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
            "配对一次后，同一 Wi-Fi 或跨网均可加密直连，无需账号。",
            color = CodevokeColor.Muted,
            fontSize = 14.sp,
            lineHeight = 20.sp,
        )
    }
}

@Composable
private fun PairedDevicesSection(
    pairedHosts: List<PairedHost>,
    connecting: Boolean,
    connectedHostId: String?,
    connectPaired: (PairedHost) -> Unit,
    forgetPaired: (PairedHost) -> Unit,
    openChat: () -> Unit,
) {
    CodevokeGlassCard(corner = CodevokeRadius.Control, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            SectionTitle("我的设备", "已配对的电脑，点击直连")
            pairedHosts.forEach { device ->
                PairedHostRow(
                    device = device,
                    isConnected = device.hostId == connectedHostId,
                    connecting = connecting,
                    onClick = { if (device.hostId == connectedHostId) openChat() else connectPaired(device) },
                    onDelete = { forgetPaired(device) },
                )
            }
        }
    }
}

@Composable
private fun PairedHostRow(
    device: PairedHost,
    isConnected: Boolean,
    connecting: Boolean,
    onClick: () -> Unit,
    onDelete: () -> Unit,
) {
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
                device.name,
                color = CodevokeColor.Ink,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                when {
                    isConnected -> "已连接"
                    else -> pairedHostSubtitle(device)
                },
                color = CodevokeColor.Muted,
                fontSize = 13.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            "删除",
            modifier = Modifier
                .clip(RoundedCornerShape(18.dp))
                .clickable(onClick = onDelete)
                .padding(horizontal = 10.dp, vertical = 9.dp),
            color = CodevokeColor.Muted,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
        )
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

private fun pairedHostSubtitle(device: PairedHost): String {
    val lastGood = device.lastGood
    return when {
        lastGood != null -> "最近可用 ${lastGood.address}:${lastGood.port}"
        device.eps.isNotEmpty() -> "${device.eps.size} 个可用地址"
        else -> "暂无地址，回局域网刷新"
    }
}

@Composable
private fun PairEntryCard(
    connectionString: String,
    connecting: Boolean,
    onConnectionStringChange: (String) -> Unit,
    openScanner: () -> Unit,
    submitConnectionString: () -> Unit,
) {
    CodevokeGlassCard(corner = CodevokeRadius.Control, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            SectionTitle("添加设备", "扫码或粘贴连接串完成配对")
            BlackCapsuleButton(
                text = "扫码配对",
                modifier = Modifier
                    .fillMaxWidth()
                    .height(54.dp),
                enabled = !connecting,
                onClick = openScanner,
            )
            LanTextField(
                value = connectionString,
                onValueChange = onConnectionStringChange,
                placeholder = "acode://pair?d=…",
            )
            BlackCapsuleButton(
                text = "粘贴连接串配对",
                modifier = Modifier
                    .fillMaxWidth()
                    .height(54.dp),
                enabled = connectionString.isNotBlank() && !connecting,
                onClick = submitConnectionString,
            )
        }
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
            SectionTitle("局域网配对", "输入电脑的局域网 IP，再填屏幕上的 6 位配对码")
            LanTextField(value = manualHost, onValueChange = onManualHostChange, placeholder = "192.168.1.10")
            LanTextField(value = manualPort, onValueChange = onManualPortChange, placeholder = "18765")
            BlackCapsuleButton(
                text = if (connecting) "连接中..." else "输入配对码",
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
private fun PairCodeDialog(
    target: PairTarget,
    pairing: Boolean,
    error: String?,
    onDismiss: () -> Unit,
    onSubmit: (String) -> Unit,
) {
    var code by remember(target) { mutableStateOf("") }
    Dialog(onDismissRequest = { if (!pairing) onDismiss() }) {
        CodevokeGlassCard(corner = CodevokeRadius.Control, modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                SectionTitle("输入配对码", "在电脑端设置页查看 6 位数字配对码")
                Text(
                    target.label,
                    color = CodevokeColor.Muted,
                    fontSize = 13.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                TextField(
                    value = code,
                    onValueChange = { next -> code = next.filter { it.isDigit() }.take(6) },
                    placeholder = { Text("6 位数字", color = CodevokeColor.Muted.copy(alpha = 0.44f)) },
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = Color.White.copy(alpha = 0.68f),
                        unfocusedContainerColor = Color.White.copy(alpha = 0.68f),
                        disabledContainerColor = Color.White.copy(alpha = 0.42f),
                        focusedIndicatorColor = Color.Transparent,
                        unfocusedIndicatorColor = Color.Transparent,
                        disabledIndicatorColor = Color.Transparent,
                    ),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                    shape = RoundedCornerShape(18.dp),
                    singleLine = true,
                    enabled = !pairing,
                    modifier = Modifier.fillMaxWidth(),
                )
                if (!error.isNullOrBlank()) {
                    Text(error, color = Color(0xFFC62828), fontSize = 12.sp, lineHeight = 17.sp)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        "取消",
                        modifier = Modifier
                            .clip(RoundedCornerShape(18.dp))
                            .clickable(enabled = !pairing, onClick = onDismiss)
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                        color = CodevokeColor.Muted,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    BlackCapsuleButton(
                        text = if (pairing) "配对中..." else "配对并连接",
                        modifier = Modifier
                            .weight(1f)
                            .height(48.dp),
                        enabled = code.length == 6 && !pairing,
                        onClick = { onSubmit(code) },
                    )
                }
            }
        }
    }
}

@Composable
private fun DiscoveredSection(
    hosts: List<LanDiscoveredHost>,
    scanning: Boolean,
    connecting: Boolean,
    message: String?,
    connectedHostId: String?,
    rescan: () -> Unit,
    connectHost: (LanDiscoveredHost) -> Unit,
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
                            isConnected = host.pairedHostId != null && host.pairedHostId == connectedHostId,
                            connecting = connecting,
                            onClick = {
                                if (host.pairedHostId != null && host.pairedHostId == connectedHostId) {
                                    openChat()
                                } else {
                                    connectHost(host)
                                }
                            },
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
private fun LanHostRow(host: LanDiscoveredHost, isConnected: Boolean, connecting: Boolean, onClick: () -> Unit) {
    val paired = host.pairedHostId != null
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
                host.name.ifBlank { host.address },
                color = CodevokeColor.Ink,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                when {
                    isConnected -> "已连接"
                    paired -> "已配对 · ${host.address}"
                    else -> "${host.address} · 可配对"
                },
                color = CodevokeColor.Muted,
                fontSize = 13.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
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
                text = when {
                    connecting -> "连接中..."
                    paired -> "连接"
                    else -> "配对"
                },
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
