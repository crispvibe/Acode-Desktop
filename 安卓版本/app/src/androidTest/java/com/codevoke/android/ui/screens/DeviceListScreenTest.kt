package com.codevoke.android.ui.screens

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import com.codevoke.android.data.LanDiscoveredHost
import com.codevoke.android.ui.theme.CodevokeTheme
import org.junit.Rule
import org.junit.Test

class DeviceListScreenTest {
    @get:Rule
    val composeRule = createComposeRule()

    private fun launchScreen(
        hosts: List<LanDiscoveredHost> = emptyList(),
        message: String? = null,
    ) {
        composeRule.setContent {
            CodevokeTheme {
                DeviceListScreen(
                    hosts = hosts,
                    pairedHosts = emptyList(),
                    scanning = false,
                    connecting = false,
                    pairing = false,
                    pairTarget = null,
                    pairError = null,
                    manualHost = "",
                    manualPort = "18765",
                    connectionString = "",
                    message = message,
                    connectedHostId = null,
                    goBack = {},
                    rescan = {},
                    onManualHostChange = {},
                    onManualPortChange = {},
                    onConnectionStringChange = {},
                    connectManual = {},
                    connectHost = {},
                    connectPaired = {},
                    forgetPaired = {},
                    openScanner = {},
                    submitConnectionString = {},
                    dismissPairDialog = {},
                    submitPairCode = {},
                    openChat = {},
                )
            }
        }
    }

    @Test
    fun discoveredHostShowsPairAction() {
        launchScreen(hosts = listOf(LanDiscoveredHost(address = "192.168.1.20", name = "", port = 18765)))

        composeRule.onNodeWithText("192.168.1.20 · 可配对").assertExists()
        composeRule.onNodeWithText("配对").assertExists()
    }

    @Test
    fun emptyScanShowsRetryHint() {
        launchScreen(message = "没有发现设备，请确认电脑端已开启连接服务。")

        composeRule.onNodeWithText("没有发现设备").assertExists()
    }
}
