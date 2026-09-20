package com.codevoke.android.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import com.codevoke.android.ui.state.CodevokeViewModel

private enum class CodevokeScreen {
    Devices,
    Chat,
    Settings,
    CLI,
}

@Composable
fun CodevokeApp() {
    val vm: CodevokeViewModel = viewModel()
    val lifecycleOwner = LocalLifecycleOwner.current
    var screen by remember { mutableStateOf(CodevokeScreen.Devices) }
    val backStack = remember { mutableStateListOf<CodevokeScreen>() }

    fun replaceScreen(next: CodevokeScreen) {
        backStack.clear()
        screen = next
    }

    fun navigateTo(next: CodevokeScreen) {
        if (next == screen) return
        backStack.add(screen)
        screen = next
    }

    fun navigateBack(fallback: CodevokeScreen) {
        screen = if (backStack.isNotEmpty()) {
            backStack.removeAt(backStack.lastIndex)
        } else {
            fallback
        }
    }

    fun handleBack() {
        when (screen) {
            CodevokeScreen.Devices,
            CodevokeScreen.Chat -> Unit
            CodevokeScreen.Settings -> navigateBack(if (vm.chat.config.isComplete) CodevokeScreen.Chat else CodevokeScreen.Devices)
            CodevokeScreen.CLI -> navigateBack(CodevokeScreen.Settings)
        }
    }

    LaunchedEffect(Unit) {
        vm.scanLanDevices()
        vm.savedLanTarget()?.let { (host, port) ->
            vm.connectLanHost(host, port) { replaceScreen(CodevokeScreen.Chat) }
        }
    }

    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) vm.resumeFromForeground()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    BackHandler(enabled = screen == CodevokeScreen.Settings || screen == CodevokeScreen.CLI, onBack = ::handleBack)

    when (screen) {
        CodevokeScreen.Devices -> DeviceListScreen(
            hosts = vm.devices.hosts,
            scanning = vm.devices.scanning,
            connecting = vm.devices.connecting,
            manualHost = vm.devices.manualHost,
            manualPort = vm.devices.manualPort,
            message = vm.devices.message,
            connectedHost = vm.devices.connectedHost,
            goBack = {
                if (vm.chat.config.isComplete) navigateBack(CodevokeScreen.Chat)
            },
            rescan = vm::scanLanDevices,
            onManualHostChange = vm::updateManualHost,
            onManualPortChange = vm::updateManualPort,
            connectManual = { vm.connectManualHost { replaceScreen(CodevokeScreen.Chat) } },
            connectHost = { host ->
                vm.connectLanHost(host, vm.devices.manualPort.trim().toIntOrNull() ?: 18765) { replaceScreen(CodevokeScreen.Chat) }
            },
            openChat = { replaceScreen(CodevokeScreen.Chat) },
        )
        CodevokeScreen.Chat -> ChatScreen(
            connectionStatus = vm.chat.connectionStatus,
            runtimeStatus = vm.chat.runtimeStatus,
            transportLabel = vm.transportLabel,
            topTitle = vm.chat.selectedProject?.name ?: "acode",
            messages = vm.chat.messages,
            streamingTexts = vm.chat.streamingTexts,
            projects = vm.chat.projects,
            models = vm.chat.models,
            sessions = vm.chat.filteredSessions,
            files = vm.chat.files,
            lastError = vm.chat.lastError,
            fileError = vm.chat.fileError,
            isRefreshing = vm.chat.isRefreshing,
            isLoadingHistory = vm.chat.isLoadingHistory,
            isAwaitingFirstModelOutput = vm.chat.isAwaitingFirstModelOutput,
            isLoadingFiles = vm.chat.isLoadingFiles,
            attachments = vm.chat.attachments,
            isUploadingAttachment = vm.chat.isUploadingAttachment,
            currentFilePath = vm.chat.currentFilePath,
            parentFilePath = vm.chat.parentFilePath,
            selectedProjectId = vm.chat.selectedProjectId,
            selectedSessionId = vm.chat.selectedSessionId,
            selectedModelId = vm.chat.selectedModelId,
            composer = vm.chat.composer,
            queuedRequests = vm.chat.queuedRequests,
            openSettings = { navigateTo(CodevokeScreen.Settings) },
            refresh = vm::refreshChat,
            selectProject = vm::selectProject,
            selectModel = vm::selectModel,
            selectSession = vm::selectSession,
            newChat = vm::startNewChat,
            inputText = vm.chat.inputText,
            updateInput = vm::updateInput,
            sendMessage = vm::sendCurrentMessage,
            stopGeneration = vm::stopGeneration,
            uploadAttachment = vm::uploadAttachment,
            removeAttachment = vm::removeAttachment,
            setCLI = vm::setCLI,
            setPermissionMode = vm::setPermissionMode,
            setReasoningEffort = vm::setReasoningEffort,
            cancelQueued = vm::cancelQueued,
            flushQueue = vm::flushQueue,
            editQueued = vm::editQueued,
            respondPermission = vm::respondPermission,
            respondInteractive = vm::respondInteractive,
            requestSnapshot = { vm.requestSnapshot() },
            insertPath = vm::insertPath,
            openFile = vm::openFile,
            openParentDirectory = vm::openParentDirectory,
        )
        CodevokeScreen.Settings -> SettingsScreen(
            connectionStatus = vm.chat.connectionStatus,
            selectedCLI = vm.chat.composer.cli,
            goBack = { navigateBack(if (vm.chat.config.isComplete) CodevokeScreen.Chat else CodevokeScreen.Devices) },
            openDevices = { navigateTo(CodevokeScreen.Devices) },
            openCLI = { navigateTo(CodevokeScreen.CLI) },
        )
        CodevokeScreen.CLI -> CliScreen(
            selectedCLI = vm.chat.composer.cli,
            capabilities = vm.chat.capabilities,
            goBack = { navigateBack(CodevokeScreen.Settings) },
            selectCLI = vm::setCLI,
        )
    }
}
