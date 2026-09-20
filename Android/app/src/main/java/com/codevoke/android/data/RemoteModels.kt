package com.codevoke.android.data

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

data class RemoteChatConfig(
    val macHost: String = "",
    val port: Int = 18765,
) {
    val supportsDirectHttp: Boolean get() = macHost.isNotBlank() && port in 1..65535
    val isComplete: Boolean get() = supportsDirectHttp
    val baseUrl: String get() = "http://${macHost.trim()}:$port"
    val webSocketUrl: String get() = "ws://${macHost.trim()}:$port/chat"
}

data class RemoteProject(
    val id: String,
    val name: String,
    val path: String,
    val defaultCLI: String = "claude",
    val createdAt: String? = null,
    val updatedAt: String? = null,
    val lastOpenedAt: String? = null,
)

data class RemoteModel(
    val id: String,
    val title: String,
    val cli: String = "claude",
    val isDefault: Boolean = false,
)

data class RemoteSession(
    val id: String,
    val cli: String,
    val projectId: String?,
    val title: String,
    val modelID: String,
    val runStatus: String,
    val statusText: String,
    val queuedCount: Int,
    val projectName: String = "",
    val projectPath: String = "",
    val createdAt: String? = null,
    val updatedAt: String? = null,
    val lastCompletedAt: String? = null,
)

data class RemoteFileEntry(
    val name: String,
    val relativePath: String,
    val isDirectory: Boolean,
)

data class RemotePanelField<out T>(
    val isPresent: Boolean,
    val value: T?,
)

data class RemoteChatAttachment(
    val id: String = UUID.randomUUID().toString(),
    val kind: String = "file",
    val filename: String = "",
    val path: String = "",
    val thumbnailData: String? = null,
    val sizeBytes: Int = 0,
)

data class RemoteAttachmentUploadResponse(
    val filename: String,
    val path: String,
)

data class RemoteInteractiveOption(
    val id: String,
    val label: String,
    val detail: String = "",
)

data class RemoteInteractiveRequest(
    val id: String,
    val title: String = "",
    val prompt: String = "",
    val mode: String = "singleChoice",
    val options: List<RemoteInteractiveOption> = emptyList(),
    val allowCustomInput: Boolean = false,
    val placeholder: String = "",
    val status: String = "waiting",
)

data class RemoteInteractiveResponse(
    val requestID: String,
    val selectedOptionIDs: List<String> = emptyList(),
    val customText: String? = null,
)

data class RemoteQueuedRequest(
    val id: String,
    val text: String,
    val displayText: String = text,
    val cli: String = "claude",
    val modelID: String = "",
    val permissionMode: String = "autoEdit",
    val reasoningEffort: String = "high",
    val projectId: String = "",
    val attachments: List<RemoteChatAttachment> = emptyList(),
)

data class RemoteStreamingText(
    val messageId: String,
    val text: String,
    val status: String = "",
    val requestId: String? = null,
)

data class RemoteCapability(
    val cli: String,
    val executableAvailable: Boolean = false,
    val supportsStreamJSONInput: Boolean = false,
    val supportsAppServer: Boolean = false,
    val errorMessage: String? = null,
)

data class RemoteComposer(
    val text: String = "",
    val cli: String = "claude",
    val modelID: String = "",
    val permissionMode: String = "autoEdit",
    val reasoningEffort: String = "high",
    val isEnabled: Boolean = true,
    val placeholder: String = "输入消息...",
    val contextModelID: String? = null,
    val attachments: List<RemoteChatAttachment> = emptyList(),
)

data class RemoteChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val kind: String,
    val text: String,
    val status: String = "",
    val sessionID: String? = null,
    val title: String = "",
    val subtitle: String = "",
    val createdAt: String? = null,
    val parentUserMessageID: String? = null,
    val requestID: String? = null,
    val isStreaming: Boolean = false,
    val interactiveRequest: RemoteInteractiveRequest? = null,
    val interactive: RemoteInteractiveRequest? = interactiveRequest,
    val appendRuleText: String? = null,
    val outputTokenCount: Int? = null,
    val token: Int? = outputTokenCount,
    val attachments: List<RemoteChatAttachment> = emptyList(),
) {
    val fromUser: Boolean get() = kind == "user"
}

data class RemotePanelSnapshot(
    val revision: Int,
    val sessionId: String?,
    val projects: List<RemoteProject>,
    val models: List<RemoteModel>,
    val sessions: List<RemoteSession>,
    val currentSessionId: String?,
    val messages: List<RemoteChatMessage>,
    val status: String,
    val statusText: String,
    val isAwaitingFirstModelOutput: Boolean,
    val isLoadingHistory: Boolean,
    val composer: RemoteComposer,
    val queuedRequests: List<RemoteQueuedRequest> = emptyList(),
    val streamingTexts: List<RemoteStreamingText> = emptyList(),
    val tokensUsed: Int = 0,
    val tokensTotal: Int = 0,
    val activeRunStartedAt: String? = null,
    val isMirroringRemoteSession: Boolean = false,
    val capabilities: List<RemoteCapability> = emptyList(),
)

data class RemotePanelPatch(
    val revision: Int,
    val baseRevision: Int,
    val sessionId: String?,
    val projects: List<RemoteProject>?,
    val models: List<RemoteModel>?,
    val sessions: List<RemoteSession>?,
    val currentSessionId: String?,
    val messages: List<RemoteChatMessage>?,
    val status: String?,
    val statusText: String?,
    val isAwaitingFirstModelOutput: Boolean?,
    val isLoadingHistory: Boolean?,
    val composer: RemoteComposer?,
    val baseRevisionField: RemotePanelField<Int>? = null,
    val currentSessionIdField: RemotePanelField<String>? = null,
    val queuedRequests: List<RemoteQueuedRequest>? = null,
    val streamingTexts: List<RemoteStreamingText>? = null,
    val tokensUsed: Int? = null,
    val tokensTotal: Int? = null,
    val activeRunStartedAt: String? = null,
    val activeRunStartedAtField: RemotePanelField<String>? = null,
    val isMirroringRemoteSession: Boolean? = null,
    val capabilities: List<RemoteCapability>? = null,
)

data class RemoteProjectFiles(
    val projectId: String,
    val path: String,
    val parentPath: String?,
    val entries: List<RemoteFileEntry>,
)

internal fun JSONObject.stringOrNull(vararg keys: String): String? {
    for (key in keys) {
        if (has(key) && !isNull(key)) return optString(key)
    }
    return null
}

internal fun JSONObject.intOrNull(vararg keys: String): Int? {
    for (key in keys) {
        if (has(key) && !isNull(key)) return optInt(key)
    }
    return null
}

internal fun JSONObject.boolOrDefault(default: Boolean, vararg keys: String): Boolean {
    for (key in keys) {
        if (has(key) && !isNull(key)) return optBoolean(key)
    }
    return default
}

internal fun JSONObject.booleanOrNull(vararg keys: String): Boolean? {
    for (key in keys) {
        if (has(key) && !isNull(key)) return optBoolean(key)
    }
    return null
}

// Windows host 把可空的 patch 标量编码为 {"value":...} 包装对象；macOS 直接给裸值。
internal fun JSONObject.stringField(key: String): RemotePanelField<String>? {
    if (!has(key)) return null
    if (isNull(key)) return RemotePanelField(isPresent = true, value = null)
    val wrapped = optJSONObject(key)
    if (wrapped != null && wrapped.has("value")) {
        return RemotePanelField(isPresent = true, value = if (wrapped.isNull("value")) null else wrapped.optString("value"))
    }
    return RemotePanelField(isPresent = true, value = optString(key))
}

internal fun JSONObject.intField(key: String): RemotePanelField<Int>? {
    if (!has(key)) return null
    if (isNull(key)) return RemotePanelField(isPresent = true, value = null)
    val wrapped = optJSONObject(key)
    if (wrapped != null && wrapped.has("value")) {
        return RemotePanelField(isPresent = true, value = if (wrapped.isNull("value")) null else wrapped.optInt("value"))
    }
    return RemotePanelField(isPresent = true, value = optInt(key))
}

internal fun JSONArray.objects(): List<JSONObject> = List(length()) { index -> optJSONObject(index) ?: JSONObject() }

fun JSONObject.toPanelSnapshot(): RemotePanelSnapshot = RemotePanelSnapshot(
    revision = optInt("revision", 1),
    sessionId = stringOrNull("sessionId"),
    projects = optJSONArray("projects")?.objects()?.map { it.toRemoteProject() }.orEmpty(),
    models = optJSONArray("models")?.objects()?.map { it.toRemoteModel() }.orEmpty(),
    sessions = optJSONArray("sessions")?.objects()?.map { it.toRemoteSession() }.orEmpty(),
    currentSessionId = stringOrNull("currentSessionId"),
    messages = optJSONArray("messages")?.objects()?.map { it.toRemoteMessage() }.orEmpty(),
    queuedRequests = optJSONArray("queuedRequests")?.objects()?.map { it.toRemoteQueuedRequest() }.orEmpty(),
    streamingTexts = optJSONArray("streamingTexts")?.objects()?.map { it.toRemoteStreamingText() }.orEmpty(),
    status = optString("status"),
    statusText = optString("statusText"),
    isAwaitingFirstModelOutput = optBoolean("isAwaitingFirstModelOutput", false),
    isLoadingHistory = optBoolean("isLoadingHistory", false),
    tokensUsed = optInt("tokensUsed", 0),
    tokensTotal = optInt("tokensTotal", 0),
    activeRunStartedAt = stringOrNull("activeRunStartedAt"),
    isMirroringRemoteSession = optBoolean("isMirroringRemoteSession", false),
    composer = optJSONObject("composer")?.toRemoteComposer() ?: RemoteComposer(),
    capabilities = optJSONArray("capabilities")?.objects()?.map { it.toRemoteCapability() }.orEmpty(),
)

fun JSONObject.toPanelPatch(): RemotePanelPatch = RemotePanelPatch(
    revision = optInt("revision", 1),
    baseRevision = intOrNull("baseRevision") ?: 0,
    baseRevisionField = intField("baseRevision"),
    sessionId = stringOrNull("sessionId"),
    projects = optJSONArray("projects")?.objects()?.map { it.toRemoteProject() },
    models = optJSONArray("models")?.objects()?.map { it.toRemoteModel() },
    sessions = optJSONArray("sessions")?.objects()?.map { it.toRemoteSession() },
    currentSessionId = stringOrNull("currentSessionId"),
    currentSessionIdField = stringField("currentSessionId"),
    messages = optJSONArray("messages")?.objects()?.map { it.toRemoteMessage() },
    queuedRequests = optJSONArray("queuedRequests")?.objects()?.map { it.toRemoteQueuedRequest() },
    streamingTexts = optJSONArray("streamingTexts")?.objects()?.map { it.toRemoteStreamingText() },
    status = stringOrNull("status"),
    statusText = stringOrNull("statusText"),
    isAwaitingFirstModelOutput = if (has("isAwaitingFirstModelOutput")) optBoolean("isAwaitingFirstModelOutput") else null,
    isLoadingHistory = if (has("isLoadingHistory")) optBoolean("isLoadingHistory") else null,
    tokensUsed = intOrNull("tokensUsed"),
    tokensTotal = intOrNull("tokensTotal"),
    activeRunStartedAt = stringOrNull("activeRunStartedAt"),
    activeRunStartedAtField = stringField("activeRunStartedAt"),
    isMirroringRemoteSession = booleanOrNull("isMirroringRemoteSession"),
    composer = optJSONObject("composer")?.toRemoteComposer(),
    capabilities = optJSONArray("capabilities")?.objects()?.map { it.toRemoteCapability() },
)

fun RemotePanelSnapshot.applyPatch(patch: RemotePanelPatch): RemotePanelSnapshot? {
    if (patch.baseRevision != revision) return null
    return copy(
        revision = patch.revision,
        sessionId = patch.sessionId ?: sessionId,
        projects = patch.projects ?: projects,
        models = patch.models ?: models,
        sessions = patch.sessions ?: sessions,
        currentSessionId = when {
            patch.currentSessionIdField?.isPresent == true -> patch.currentSessionIdField.value
            patch.currentSessionId != null -> patch.currentSessionId
            else -> currentSessionId
        },
        messages = patch.messages ?: messages,
        queuedRequests = patch.queuedRequests ?: queuedRequests,
        streamingTexts = patch.streamingTexts ?: streamingTexts,
        status = patch.status ?: status,
        statusText = patch.statusText ?: statusText,
        isAwaitingFirstModelOutput = patch.isAwaitingFirstModelOutput ?: isAwaitingFirstModelOutput,
        isLoadingHistory = patch.isLoadingHistory ?: isLoadingHistory,
        tokensUsed = patch.tokensUsed ?: tokensUsed,
        tokensTotal = patch.tokensTotal ?: tokensTotal,
        activeRunStartedAt = when {
            patch.activeRunStartedAtField?.isPresent == true -> patch.activeRunStartedAtField.value
            patch.activeRunStartedAt != null -> patch.activeRunStartedAt
            else -> activeRunStartedAt
        },
        isMirroringRemoteSession = patch.isMirroringRemoteSession ?: isMirroringRemoteSession,
        composer = patch.composer ?: composer,
        capabilities = patch.capabilities ?: capabilities,
    )
}

private fun JSONObject.toRemoteProject(): RemoteProject = RemoteProject(
    id = optString("id"),
    name = optString("name"),
    path = optString("path"),
    defaultCLI = optString("defaultCLI", "claude"),
    createdAt = stringOrNull("createdAt"),
    updatedAt = stringOrNull("updatedAt"),
    lastOpenedAt = stringOrNull("lastOpenedAt"),
)

private fun JSONObject.toRemoteModel(): RemoteModel = RemoteModel(
    id = optString("id"),
    title = optString("title", optString("id")),
    cli = optString("cli", "claude"),
    isDefault = optBoolean("isDefault", false),
)

private fun JSONObject.toRemoteSession(): RemoteSession = RemoteSession(
    id = optString("id"),
    cli = optString("cli", "claude"),
    projectId = stringOrNull("projectId"),
    projectName = optString("projectName"),
    projectPath = optString("projectPath"),
    title = optString("title", "新对话"),
    modelID = optString("modelID"),
    runStatus = optString("runStatus"),
    statusText = optString("statusText"),
    createdAt = stringOrNull("createdAt"),
    updatedAt = stringOrNull("updatedAt"),
    lastCompletedAt = stringOrNull("lastCompletedAt"),
    queuedCount = optInt("queuedCount", 0),
)

private fun JSONObject.toRemoteMessage(): RemoteChatMessage = RemoteChatMessage(
    id = optString("id", UUID.randomUUID().toString()),
    sessionID = stringOrNull("sessionID", "sessionId"),
    kind = optString("kind", optString("role", "assistant")),
    title = optString("title"),
    subtitle = optString("subtitle"),
    text = optString("text", optString("content")),
    status = optString("status"),
    createdAt = stringOrNull("createdAt"),
    parentUserMessageID = stringOrNull("parentUserMessageID", "parentUserMessageId"),
    requestID = stringOrNull("requestID", "requestId"),
    isStreaming = optBoolean("isStreaming", false),
    interactiveRequest = (optJSONObject("interactiveRequest") ?: optJSONObject("interactive"))?.toRemoteInteractiveRequest(),
    appendRuleText = stringOrNull("appendRuleText"),
    outputTokenCount = intOrNull("outputTokenCount", "token", "tokenCount"),
    attachments = optJSONArray("attachments")?.objects()?.map { it.toRemoteChatAttachment() }.orEmpty(),
)

private fun JSONObject.toRemoteComposer(): RemoteComposer = RemoteComposer(
    text = optString("text"),
    cli = optString("cli", "claude"),
    modelID = optString("modelID"),
    contextModelID = stringOrNull("contextModelID", "contextModelId"),
    permissionMode = optString("permissionMode", "autoEdit"),
    reasoningEffort = optString("reasoningEffort", "high"),
    attachments = optJSONArray("attachments")?.objects()?.map { it.toRemoteChatAttachment() }.orEmpty(),
    isEnabled = optBoolean("isEnabled", true),
    placeholder = optString("placeholder", "输入消息..."),
)

private fun JSONObject.toRemoteChatAttachment(): RemoteChatAttachment = RemoteChatAttachment(
    id = optString("id", UUID.randomUUID().toString()),
    kind = optString("kind", "file"),
    filename = optString("filename"),
    path = optString("path"),
    thumbnailData = stringOrNull("thumbnailData"),
    sizeBytes = optInt("sizeBytes", 0),
)

fun JSONObject.toAttachmentUploadResponse(): RemoteAttachmentUploadResponse = RemoteAttachmentUploadResponse(
    filename = optString("filename"),
    path = optString("path"),
)

fun RemoteChatAttachment.toJson(): JSONObject = JSONObject().apply {
    put("id", id)
    put("kind", kind)
    put("filename", filename)
    put("path", path)
    thumbnailData?.let { put("thumbnailData", it) }
    if (sizeBytes > 0) put("sizeBytes", sizeBytes)
}

private fun JSONObject.toRemoteInteractiveOption(): RemoteInteractiveOption = RemoteInteractiveOption(
    id = optString("id"),
    label = optString("label"),
    detail = optString("detail"),
)

private fun JSONObject.toRemoteInteractiveRequest(): RemoteInteractiveRequest = RemoteInteractiveRequest(
    id = optString("id"),
    title = optString("title"),
    prompt = optString("prompt"),
    mode = optString("mode", "singleChoice"),
    options = optJSONArray("options")?.objects()?.map { it.toRemoteInteractiveOption() }.orEmpty(),
    allowCustomInput = optBoolean("allowCustomInput", false),
    placeholder = optString("placeholder"),
    status = optString("status", "waiting"),
)

private fun JSONObject.toRemoteQueuedRequest(): RemoteQueuedRequest = RemoteQueuedRequest(
    id = optString("id"),
    text = optString("text"),
    displayText = optString("displayText", optString("text")),
    cli = optString("cli", "claude"),
    modelID = optString("modelID"),
    permissionMode = optString("permissionMode", "autoEdit"),
    reasoningEffort = optString("reasoningEffort", "high"),
    projectId = optString("projectId"),
    attachments = optJSONArray("attachments")?.objects()?.map { it.toRemoteChatAttachment() }.orEmpty(),
)

private fun JSONObject.toRemoteStreamingText(): RemoteStreamingText = RemoteStreamingText(
    messageId = optString("messageId"),
    text = optString("text"),
    status = optString("status"),
    requestId = stringOrNull("requestId"),
)

private fun JSONObject.toRemoteCapability(): RemoteCapability = RemoteCapability(
    cli = optString("cli"),
    executableAvailable = optBoolean("executableAvailable", false),
    supportsStreamJSONInput = optBoolean("supportsStreamJSONInput", false),
    supportsAppServer = optBoolean("supportsAppServer", false),
    errorMessage = stringOrNull("errorMessage"),
)
