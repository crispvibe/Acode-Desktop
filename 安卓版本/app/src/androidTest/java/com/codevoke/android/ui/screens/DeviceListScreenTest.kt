package com.codevoke.android.ui.screens

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import com.codevoke.android.ui.theme.CodevokeTheme
import org.junit.Rule
import org.junit.Test

class DeviceListScreenTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun discoveredHostShowsConnectAction() {
        composeRule.setContent {
            CodevokeTheme {
                DeviceListScreen(
                    hosts = listOf("192.168.1.20"),
                    scanning = false,
                    connecting = false,
                    manualHost = "",
                    manualPort = "18765",
                    message = null,
                    connectedHost = null,
                    goBack = {},
                    rescan = {},
                    onManualHostChange = {},
                    onManualPortChange = {},
                    connectManual = {},
                    connectHost = {},
                    openChat = {},
                )
            }
        }

        composeRule.onNodeWithText("192.168.1.20").assertExists()
        composeRule.onNodeWithText("局域网可连接").assertExists()
    }

    @Test
    fun emptyScanShowsRetryHint() {
        composeRule.setContent {
            CodevokeTheme {
                DeviceListScreen(
                    hosts = emptyList(),
                    scanning = false,
                    connecting = false,
                    manualHost = "",
                    manualPort = "18765",
                    message = "没有发现设备，请确认电脑端已开启连接服务。",
                    connectedHost = null,
                    goBack = {},
                    rescan = {},
                    onManualHostChange = {},
                    onManualPortChange = {},
                    connectManual = {},
                    connectHost = {},
                    openChat = {},
                )
            }
        }

        composeRule.onNodeWithText("没有发现设备").assertExists()
    }
}
