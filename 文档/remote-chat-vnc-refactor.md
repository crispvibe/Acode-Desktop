# Remote Chat VNC Refactor — Implementation Spec

Goal: Replace the current "两端各自维护状态、靠事件对账" remote chat with a **VNC-style** model where Mac's `ChatPanelController` is the single source of truth and iOS is a pure thin client that:

- Mirrors UI from server snapshots + patches.
- Sends user intent as commands (drawn from the same surface Mac UI uses).

This document is a self-contained, copy-from spec for three independent worktree agents:

- **agent-protocol-server** — defines DTOs and rewrites server transport.
- **agent-mac-controller** — extracts `ChatPanelController` and rewires Mac UI/Bridge.
- **agent-ios-thin-client** — guts the iOS state machine, becomes pure renderer.

Each agent's allowed/forbidden file set is in §6. Merge order: protocol-server → mac-controller → ios-thin-client.

---

## 0. Acceptance grep checklist

After all three agents merge, the following greps MUST yield **zero** hits.

### 0.1 iOS — `iOS版本/Codevoke/**/*.swift`

```
queuedMessagesBySession
sessionStreamingMessageIDs
runtimeStatusBySession
pendingPromptBySession
activeRequestID
draftConversationID
trackAsActive
```

(Variant names `visibleActiveRequestID`, `pendingDraftConversationID`, `sessionOperationalStreamingMessageIDs`, `runningRequestIDsBySession`, `queuedMessageCountBySession`, `queuedMessageOrderByRequestID`, `pendingUserPrompt`, `pendingPromptBySession`, `pendingCursorEvents`, `lastAppliedCursor`, `lastAckedCursor`, `scheduleAuthoritativeHistoryRestore`, `restoreGlobalStreamEvents` must also be removed when their parent field disappears — they only exist to maintain the bug-prone derived state we are deleting.)

### 0.2 Mac Bridge — `Mac版本/Codevoke/Services/RemoteChat/RemoteChatBridge.swift`

```
pendingRequests
activeBackend
processQueue
livePersist
```

(`RemoteChatBridge` ends up as a thin command-decoder + ack emitter. All queue/run/persist responsibilities move into `ChatPanelController`.)

### 0.3 Mac — `Mac版本/Codevoke/ViewModels/ChatPanelState.swift`

The bypass-Bridge local enqueue path at lines 422–429 (see §1.3) must be gone. `ChatPanelState` either becomes `ChatPanelController` or is replaced by it.

---

## 1. Mac end — `ChatPanelState` current surface

### 1.1 Published properties (must survive on `ChatPanelController`)

From `Mac版本/Codevoke/ViewModels/ChatPanelState.swift`:

| Field | Type | Source |
|-------|------|--------|
| `messages` | `[ChatMessage]` | `ChatPanelState.swift:90` |
| `queuedRequests` | `[QueuedChatRequest]` | `ChatPanelState.swift:91` |
| `status` | `ChatRunStatus` | `ChatPanelState.swift:92` |
| `capabilities` | `[CLIType: ChatCLICapability]` | `ChatPanelState.swift:93` |
| `isAwaitingFirstModelOutput` | `Bool` | `ChatPanelState.swift:94` |
| `isLoadingHistory` | `Bool` | `ChatPanelState.swift:95` |
| `structureRevision` | `Int` | `ChatPanelState.swift:96` |
| `streamingTextStore.entries` | `[UUID: StreamingTextEntry]` | `ChatPanelState.swift:14` |
| `statusStore.statusText` | `String` | `ChatPanelState.swift:69` |
| `statusStore.tokensUsed` / `tokensTotal` | `Int` | `ChatPanelState.swift:70-71` |
| `isMirroringRemoteSession` | `Bool` | `ChatPanelState.swift:155` |
| derived `statusText` (var) | `String` | `ChatPanelState.swift:99` |
| derived `tokensUsed` / `tokensTotal` | `Int` | `ChatPanelState.swift:102-105` |
| `activeRunStartedAt` (private) | `Date?` | `ChatPanelState.swift:146` |
| derived `activity` | `ChatSessionActivity?` | `ChatPanelState.swift:163` |
| derived `currentSessionID` | `UUID?` | `ChatPanelState.swift:160` |

> **NOTE for `agent-mac-controller`**: Keep `ChatPanelController`'s public `@Published` surface drop-in compatible with the above so Mac views can keep their existing bindings (only the **mutation** API changes). The class can be renamed (`ChatPanelController`) and live in a new file `Mac版本/Codevoke/ViewModels/ChatPanelController.swift`; the old `ChatPanelState.swift` should be deleted or shrunk to a thin alias if needed for transition.

### 1.2 Mutate API (signatures and call-sites)

| Method | Signature | Called from |
|--------|-----------|-------------|
| `setRuntimeVisible` | `(Bool) -> Void` | `ChatRuntimeStore.swift` (visibility) |
| `refreshCapabilities` | `(force: Bool = false) -> Void` | `ChatPanelState.swift:220` (init), settings UI |
| `syncContextWindow` | `(modelID: String) -> Void` | `ClaudeSessionPanelComposer.swift:996` |
| `resetToNewSession` | `() -> Void` | New-chat button (Mac) |
| `discardCurrentSessionWithoutPersisting` | `() -> Void` | session switch race-fix path |
| `loadFromAppState` | `(AppState, modelID:String, permissionMode:ChatPermissionMode, reasoningEffort:ChatReasoningEffort) -> Void` | history switch |
| `send` | `(text:String, backendText:String? = nil, appendRuleText:String? = nil, attachments:[ChatMessageAttachment] = [], project:ProjectItem?, cli:CLIType, modelID:String, contextModelID:String? = nil, permissionMode:ChatPermissionMode, reasoningEffort:ChatReasoningEffort, sessionMode:SessionMode, resumeSessionID:String?) -> Bool` | `ClaudeSessionPanelComposer.swift:524`, `ClaudeSessionPanelView.swift:2494`, `2518` |
| `cancelQueuedRequest` | `(UUID) -> Void` | `ClaudeSessionPanelComposer.swift:56,874` |
| `discardQueuedRequestsForNewChat` | `() -> Void` | new-chat path |
| `removeMessageThread` | `(UUID) -> Void` | `ClaudeSessionPanelComposer.swift:517` |
| `interrupt` | `(startQueuedAfterStop:Bool = false) -> Void` | `ClaudeSessionPanelComposer.swift:411,547`, `ClaudeSessionPanelView.swift:2511` |
| `respondToPermission` | `(requestID:String, allowed:Bool)` and `(requestID:String, decision:ChatPermissionDecision)` | `ClaudeSessionPanelView.swift:2308,2314,2320` |
| `respondToInteractiveRequest` | `(ChatInteractiveResponse) -> Void` | `ClaudeSessionPanelSupport.swift:1994` |

> **All of these methods become the canonical command surface.** Remote commands from iOS (§4) must hit the same code-paths. There are no separate iOS-only state mutators on Mac.

### 1.3 Bypass-Bridge local enqueue (delete)

`ChatPanelState.swift:422-429` (inside `send`):

```swift
if shouldQueueNewRequest {
    queuedRequests.append(request)
    statusText = "已加入队列"
    bumpStructureRevision()
    persistCurrentSession(saveMessages: false)
    publishActivity()
    return true
}
return startRun(request)
```

The whole `if shouldQueueNewRequest { ... }` branch is one of two queue paths in the system (the other being `RemoteChatBridge.pendingRequests`). After the refactor there must be a **single** queue surface on `ChatPanelController`. Either:

- Keep this branch as the only path (recommended), and **delete `RemoteChatBridge`'s `pendingRequests` / `processQueue` / `activeBackend` entirely**, OR
- Move queue ownership to `ChatRuntimeStore`/controller as a per-session FIFO.

Spec choice: **keep the local enqueue inside the controller; delete the Bridge queue.** All `controller.send(...)` calls (from Mac UI or from a remote command) funnel into the same `if shouldQueueNewRequest` / `startRun` machinery.

### 1.4 Bridge livePersist node (delete)

`RemoteChatBridge.swift:812-915` — variables `lastLivePersistAt`, `livePersistInterval`, function `persistLiveSnapshot`, and its calls inside the `for try await event` loop.

Reason: with the controller as single source of truth, persistence is done exactly once (by the controller) at the same points it persists for local Mac runs (`actuallyPersist`). The Bridge no longer writes session/message JSON.

### 1.5 Mac views directly mutating `ChatPanelState`

After refactor every site in this table must call **`controller.send(...)` / `controller.interrupt(...)` / `controller.respondToPermission(...)` / etc.** instead of `chatState.<method>(...)`. The mapping is 1:1 — only the receiver name changes.

| Path:line | Current call | New call |
|-----------|--------------|----------|
| `ClaudeSessionPanelComposer.swift:56` | `chatState.cancelQueuedRequest(request.id)` | `controller.cancelQueuedRequest(request.id)` |
| `ClaudeSessionPanelComposer.swift:411` | `chatState.interrupt()` | `controller.interrupt()` |
| `ClaudeSessionPanelComposer.swift:517` | `chatState.removeMessageThread(editingMessageID)` | `controller.removeMessageThread(editingMessageID)` |
| `ClaudeSessionPanelComposer.swift:524` | `chatState.send(...)` | `controller.send(...)` |
| `ClaudeSessionPanelComposer.swift:547` | `chatState.interrupt(startQueuedAfterStop: true)` | `controller.interrupt(startQueuedAfterStop: true)` |
| `ClaudeSessionPanelComposer.swift:874` | `chatState.cancelQueuedRequest(request.id)` | same |
| `ClaudeSessionPanelComposer.swift:996` | `chatState.syncContextWindow(...)` | same |
| `ClaudeSessionPanelView.swift:2494,2518` | `chatState.send(...)` | `controller.send(...)` |
| `ClaudeSessionPanelView.swift:2511` | `chatState.interrupt()` | `controller.interrupt()` |
| `ClaudeSessionPanelView.swift:2308,2314,2320` | `chatState.respondToPermission(...)` | `controller.respondToPermission(...)` |
| `ClaudeSessionPanelSupport.swift:1994` | `chatState.respondToInteractiveRequest(...)` | same |

> If the agent renames `ChatPanelState` → `ChatPanelController`, a single project-wide find-and-replace covers most sites.

### 1.6 Code reference

- `Mac版本/Codevoke/ViewModels/ChatPanelState.swift:6-1735` — controller's current full surface.
- `Mac版本/Codevoke/Services/Chat/ChatRuntimeStore.swift:6-275` — owns `ChatPanelState` per history key; will own `ChatPanelController`.
- `Mac版本/Codevoke/Services/RemoteChat/RemoteChatBridge.swift:218-1252` — to be amputated.
- `Mac版本/Codevoke/Services/RemoteChat/RemoteSessionMirrorBus.swift:17-118` — to be repurposed (see §3.3, §5).

---

## 2. iOS state machine — fields and entry points to delete

All fields below live on `iOS版本/Codevoke/ViewModels/ChatViewModel.swift`. After refactor the class is a renderer with only **rendering** state (`config`, `selectedSession`, derived UI flags driven from snapshot). Anything in this list must be deleted.

### 2.1 Fields to delete

| Field | Path:line | Current responsibility |
|-------|-----------|------------------------|
| `messages` (owned by VM) | `ChatViewModel.swift:16` | Will be replaced by `panel.messages` from snapshot. |
| `sessions` / `projects` / `models` | `ChatViewModel.swift:15-27` | Now come from snapshot's `sessions[]`, `projects[]`, `models[]` (see §4 PanelStateSnapshot). |
| `selectedModelID` / `selectedCLI` / `selectedPermissionMode` / `selectedReasoningEffort` | `ChatViewModel.swift:27-30` | Move to snapshot's `composer.cli` / `composer.modelID` / `composer.permissionMode` / `composer.reasoningEffort`. iOS just sends `composerSet*` commands. |
| `fileEntries` / `currentFilePath` / `parentFilePath` / `isLoadingFiles` / `fileError` | `ChatViewModel.swift:31-35` | Move to snapshot (project file tree). Loading lives on the server. |
| `isSending` | `ChatViewModel.swift:41` | Derived from `panel.status.isRunning`. |
| `isVisibleRunActive` | `ChatViewModel.swift:42` | Same as above. |
| `connectionStatus` (publish) | `ChatViewModel.swift:49` | Local-only; stays. |
| `runtimeStatus` / `visibleRuntimeStatus` | `ChatViewModel.swift:50`, `190` | Derived from `panel.statusText` in snapshot. |
| `queuedMessageCount` / `queuedMessages` | `ChatViewModel.swift:53,55` | Derived from `panel.queuedRequests` in snapshot. |
| `editingQueuedRequestID` | `ChatViewModel.swift:67` | Local UI editing state; **stays** (purely local; user is typing). |
| `streamingMessageIDs` | `ChatViewModel.swift:176` | DELETE. Streaming text is part of snapshot/patch. |
| `operationalStreamingMessageIDs` | `ChatViewModel.swift:177` | DELETE. |
| `sessionMessageCache` | `ChatViewModel.swift:179` | DELETE. iOS no longer caches per-session; current session's `messages` come from snapshot. |
| `sessionStreamingMessageIDs` | `ChatViewModel.swift:180` | DELETE. |
| `sessionOperationalStreamingMessageIDs` | `ChatViewModel.swift:181` | DELETE. |
| `runningRequestIDsBySession` | `ChatViewModel.swift:182` | DELETE. |
| `runtimeStatusBySession` | `ChatViewModel.swift:183` | DELETE. |
| `pendingPromptBySession` | `ChatViewModel.swift:184` | DELETE. |
| `queuedMessageCountBySession` | `ChatViewModel.swift:185` | DELETE. |
| `queuedMessagesBySession` | `ChatViewModel.swift:186` | DELETE. |
| `queuedMessageOrderByRequestID` | `ChatViewModel.swift:187` | DELETE. |
| `activeRequestID` | `ChatViewModel.swift:188` | DELETE. |
| `visibleActiveRequestID` | `ChatViewModel.swift:189` | DELETE. |
| `pendingUserPrompt` | `ChatViewModel.swift:191` | DELETE. |
| `lastAppliedCursor` / `lastAckedCursor` / `pendingCursorEvents` / `seenEventIDs` / `seenEventIDOrder` / `currentServerEpoch` / `isRecoveringCursorGap` / `pendingCursorEventLimit` / `isRestoringGlobalEvents` | `ChatViewModel.swift:165-174` | DELETE. Snapshot+patch protocol replaces global cursor reconciliation. |
| `messageListRevision` / `messageListUpdateSignal` | `ChatViewModel.swift:54,175` | Local UI signal — **stays**, recomputed from snapshot `panel.messages` whenever it changes. |
| `pendingStreamDeltas` / `pendingOperationalStreamDeltas` / `streamFlushTask` | `ChatViewModel.swift:198-201` | DELETE. Patches arrive coalesced; no client-side flushing. |
| `draftConversationID` | `ChatViewModel.swift:202` | DELETE. `newDraftSession` command returns a real sessionId in the ack. |
| `webSocketGeneration` | `ChatViewModel.swift:164` | Keep (needed for reconnect bookkeeping). |
| `webSocketClient` | `ChatViewModel.swift:163` | Keep (thinner — only resume + commands). |
| `scheduleAuthoritativeHistoryRestore` | `ChatViewModel.swift:1934` | DELETE the method entirely. Truncated replay is handled by server returning a snapshot. |
| `restoreGlobalStreamEvents` / `fetchStreamEvents` / HTTP `/events` poller | `ChatViewModel.swift:1995-2040`, `RemoteHTTPClient.swift:54-62` | DELETE. iOS never replays via HTTP. |
| `migrateDraftStateIfNeeded` | `ChatViewModel.swift:911-950` | DELETE. No draft state to migrate. |
| `recordRunningRequest`, `clearTransientRunState`, `promoteQueuedMessageToConversation`, `syncVisibleRunState`, `appendStreamingBubble`, `appendOperationalStreamingBubble`, `enqueueStreamingBubble`, `enqueueOperationalStreamingBubble`, `appendStreamEvent`, `markOutputFinished`, `finishStreaming`, `mergeTransientMessages`, `isTransientMessage`, `setStreamIDs`, `setOperationalStreamIDs`, `streamIDs(for:)`, `operationalStreamIDs(for:)`, `streamKey`, `operationalStreamKey`, `isStreamingStatus`, `cachePendingCursorEvent`, `requestCursorRecovery`, `drainPendingCursorEvents`, `ackAppliedCursor`, `consumeCursorEvent`, `consumeEventIdentity`, `applyCursorIfContiguous`, `resetStreamCursorState`, `isProtocolControlEvent`, `handleProtocolEvent`, `handleBackgroundSessionEvent`, `handleQueueAccepted`, `appendUserMessage`, `applyRemoteEvent`, `syncQueuedMessageFromMac`, `removeQueuedMessage`, `clearQueuedMessages`, `updateQueuedMessageText`, `appendQueuedMessage`, `syncVisibleQueuedMessages`, `eventBelongsToVisibleConversation`, `resolvedSessionID`, `shouldIgnoreQueueRaceError`, `isRequestAlreadyVisibleOrRunning`, `queueOrder` | `ChatViewModel.swift:1342-2545` | DELETE. All replaced by trivial `apply(snapshot:)` / `apply(patch:)`. |

### 2.2 WS frames sent today (from iOS)

| Frame `type` | Carries | Path |
|--------------|---------|------|
| `send_message` | requestId, clientConversationId, projectId, sessionId, content, cli, modelID, permissionMode, reasoningEffort | `RemoteWebSocketClient.swift:65-69`; constructed in `ChatViewModel.swift:1245-1259` |
| `interrupt` | clientConversationId | `RemoteWebSocketClient.swift:74-93`; `ChatViewModel.swift:1019-1023` |
| `flush_queue` | clientConversationId | `ChatViewModel.swift:1049-1053` |
| `update_queue_message` | requestId, content, sessionId, clientConversationId | `RemoteWebSocketClient.swift:132-144`; `ChatViewModel.swift:1133-1138` |
| `delete_queue_message` | requestId, sessionId, clientConversationId | `RemoteWebSocketClient.swift:150-152`; `ChatViewModel.swift:1100-1104` |
| `queue_snapshot` | sessionId, clientConversationId | `ChatViewModel.swift:1066-1073` |
| `resume` | cursor, sessionId, clientConversationId | `RemoteWebSocketClient.swift:107-113`; `ChatViewModel.swift:1331-1333` |
| `cursor_ack` | cursor | `RemoteWebSocketClient.swift:115-117`; `ChatViewModel.swift:1463` |

All of these are replaced by the new `Command` frames in §4.5. The legacy frames continue to be **accepted** by the server during Phase B (see §5) for back-compat, but iOS stops sending them after the refactor.

### 2.3 WS frames consumed today (by iOS)

Each `RemoteStreamEvent.type`: `hello`, `command_ack`, `replay_truncated`, `sessions_changed`, `assistant_delta`, `assistant_message`, `assistant_done`, `assistant_error`, `output_finished`, `stream_status`, `permission_request`, `interactive_request`, `token_usage`, `session_id`, `user_message_saved`, `queue_accepted`, `queue_status`. Decoded in `RemoteWebSocketClient.swift:212`, dispatched in `ChatViewModel.swift:1467-1605`.

After refactor iOS consumes only the new envelopes (`snapshot`, `patch`, `command_ack`). Server may still emit legacy events for Phase B; iOS ignores them.

### 2.4 HTTP endpoints used today (by iOS)

`RemoteHTTPClient.swift`:

- `GET /health` (keep — pre-WS reachability check)
- `GET /projects` (DELETE — projects come from snapshot)
- `GET /models?cli=X` (DELETE — models come from snapshot)
- `GET /projects/{id}/files?path=Y` (DELETE — file tree comes from snapshot if exposed; otherwise iOS sends a `fetchProjectFiles` command and renders the result from a snapshot patch.)
- `GET /sessions?projectId=&cli=` (DELETE — sessions come from snapshot)
- `GET /sessions/{id}` (DELETE)
- `GET /sessions/{id}/messages?...` (DELETE — messages come from snapshot for current session)
- `GET /events?afterCursor=&...` (DELETE — replaced by `resume` -> snapshot/patch)
- `GET /config/profiles`, `POST /config/claude-profile`, `POST /config/claude-profile/activate`, `POST /config/claude-models` (KEEP — pure configuration that doesn't go through the chat panel state)
- `POST /attachments` (KEEP — binary upload, never belonged in the panel state)

### 2.5 iOS persistence today

`iOS版本/Codevoke/ViewModels/ChatViewModel.swift:204-216`:

- `UserDefaults.standard` `remote.macHost` / `remote.port` / `remote.token` — **KEEP** (connection config)
- `remote.selectedModelID` / `remote.selectedCLI` / `remote.selectedPermissionMode` / `remote.selectedReasoningEffort` — **DELETE writes**. Read once on first launch only as "last known preference" hint for the first `composerSet*` command. After Phase C they live solely in the snapshot.
- Keychain (auth client) — **KEEP**.

iOS writes **zero business state** to disk after the refactor.

### 2.6 Code reference

- `iOS版本/Codevoke/ViewModels/ChatViewModel.swift:1-2680` — the file to gut.
- `iOS版本/Codevoke/Networking/RemoteWebSocketClient.swift:65-152` — frame send helpers; replace with one generic `sendCommand`.
- `iOS版本/Codevoke/Networking/RemoteHTTPClient.swift:17-83` — methods to delete (see §2.4).
- `iOS版本/Codevoke/Models/RemoteModels.swift:195-245` — `RemoteSendMessageRequest`, `RemoteStreamEvent` deleted; replaced by new types from ChatCore.

---

## 3. Server (`RemoteChatServer`) current state

### 3.1 Replay cache

`Mac版本/Codevoke/Services/RemoteChat/RemoteChatServer.swift:21-23`:

```swift
private let serverEpoch = UUID().uuidString
private var nextStreamCursor = 0
private var replayCache: [RemoteChatStreamEvent] = []
private let replayCacheLimit = 2048
private var lastAckCursorByConnection: [UUID: Int] = [:]
```

Each event gets `cursor = nextStreamCursor` and is appended to `replayCache`. On `resume` (`RemoteChatServer.swift:347-387`) the server filters the cache by cursor + sessionID and re-sends. On gap, `replay_truncated` triggers iOS HTTP backfill.

**After refactor**: replace with **per-session snapshot + patch ring buffer**. See §4.6.

### 3.2 `RemoteChatStreamEvent` cases (legacy event types)

From producers in `RemoteChatBridge.swift` and `ChatPanelState.swift:933-1027`:

`hello`, `assistant_message`, `assistant_delta`, `output_finished`, `stream_status`, `session_id`, `permission_request`, `interactive_request`, `token_usage`, `assistant_done`, `assistant_error`, `user_message_saved`, `queue_accepted`, `queue_status`, `sessions_changed`, `command_ack`, `replay_truncated`.

These remain produceable for **Phase B back-compat broadcast** only (§5). New iOS clients ignore them. Phase C deletes them.

### 3.3 `RemoteSessionMirrorBus`

`Mac版本/Codevoke/Services/RemoteChat/RemoteSessionMirrorBus.swift:17-118`:

- `Event` cases: `.queue`, `.beginRun`, `.backend`, `.endRun`.
- Mac `ChatPanelState` subscribes to mirror events to render iOS-triggered sessions.
- Bridge publishes `.beginRun`/`.backend`/`.endRun` from inside `run(_:)`.

**After refactor**: the bus is **deleted**. There is no "iOS-triggered" vs "Mac-triggered" distinction — every request goes through `ChatPanelController` so its `@Published` properties already reflect both. The server **subscribes directly** to the controller (via `stateSnapshotPublisher` and `statePatchPublisher`, see §4.7) and broadcasts to clients.

### 3.4 WS entry / command dispatch (current)

`RemoteChatServer.swift:196-253` decodes WS frames, `handleWebSocketControl` (line 333-387) handles control frames (`cursor_ack`, `resume`), everything else goes through `bridge.handle(text:)` which decodes either `RemoteChatControlEnvelope` (`flush_queue`, `interrupt`, `update_queue_message`, `delete_queue_message`, `queue_snapshot`) or `RemoteChatSendMessageRequest` (`send_message`).

**After refactor**: text frames decode to `Command` (§4.5); server hands them to `RemoteChatCommandRouter` which translates to controller calls. Snapshots/patches are pushed from a single broadcast pipeline (§4.7).

### 3.5 Code reference

- `RemoteChatServer.swift:14-451`
- `RemoteChatBridge.swift:218-1252` (controller path replaces all of `run(_:)` from line 707 onward)
- `RemoteChatRouter.swift:39-450` (HTTP routes stay for `/health`, `/attachments`, `/config/...`; rest deleted)
- `RemoteChatDTOs.swift:1-226` (project/session/message/event DTOs deleted with the legacy events; keep `RemoteHealthDTO`, `RemoteAttachmentUpload*`, `RemoteConfigProfilesDTO` and friends)

---

## 4. New DTO contract — `共享代码/ChatCore/Sources/ChatCore/RemoteVNCProtocol.swift`

This file is authoritative; **agent-protocol-server creates it**, the other two agents `import ChatCore` and use the types as-is.

The protocol-server agent must also add the file to ChatCore's package by updating `共享代码/ChatCore/Package.swift` only if the build needs it (the Sources/ChatCore directory is auto-globbed, so usually no edit needed — verify with `swift build` from `共享代码/ChatCore`).

### 4.1 Strategy decisions (fixed; do not deviate)

- **Patches are field-level optional diffs**, not operation lists. Each optional field on `PanelStatePatch`, if non-nil, replaces the corresponding field in the client's local snapshot. Patches are coarse — server may always send a full snapshot if it's cheaper. Patches are an **optimization**; clients MUST be able to render purely from `snapshot`s.
- **Messages are not field-level optional inside a patch.** When `messages` (or `queuedRequests`, `streamingTexts`) is non-nil, it is the **complete new array**. (This avoids index-based reconciliation. For very-long histories the protocol-server agent may add `messageAppendDelta` later; out of scope for v1.)
- **Per-session revision** is monotonic on the server; each snapshot/patch envelope carries `revision`. Client tracks `lastRevision` per session and resumes with it.
- **Patch retention window** = 64 patches per session. If the client's `lastRevision` is older than the oldest retained patch, server sends a **fresh snapshot** instead.
- **Command op-list** uses a flat `args: [String: AnyCodable]` schema for forward compatibility. Helper static initializers below.
- **Encoding strategy**: JSONEncoder with `.iso8601` date, default keys (no `.convertToSnakeCase`). Matches existing wire format.

### 4.2 `PanelStateSnapshot` (server → client)

```swift
import Foundation

public struct PanelStateSnapshot: Codable, Equatable {
    /// Monotonic per-session revision number. Always >= 1.
    public let revision: Int

    /// Identifier of the panel this snapshot describes. Server's
    /// `ChatPanelController` is per-session; `sessionId == nil` means
    /// "the not-yet-persisted draft session for this connection's selected project".
    public let sessionId: UUID?

    // ---- Catalog (small, push as part of every snapshot) ----
    public let projects: [PanelProjectDTO]
    public let models: [PanelModelDTO]
    public let sessions: [PanelSessionDTO]

    // ---- Current session view ----
    public let currentSessionId: UUID?
    public let messages: [ChatMessage]
    public let queuedRequests: [PanelQueuedRequestDTO]
    public let streamingTexts: [PanelStreamingTextDTO]

    // ---- Runtime/run flags ----
    public let status: String           // ChatRunStatus.rawValue
    public let statusText: String
    public let isAwaitingFirstModelOutput: Bool
    public let isLoadingHistory: Bool
    public let tokensUsed: Int
    public let tokensTotal: Int
    public let activeRunStartedAt: Date?
    public let isMirroringRemoteSession: Bool

    // ---- Composer (server-authoritative) ----
    public let composer: PanelComposerDTO

    // ---- Capability map (per CLI) ----
    public let capabilities: [PanelCapabilityDTO]

    public init(
        revision: Int,
        sessionId: UUID?,
        projects: [PanelProjectDTO],
        models: [PanelModelDTO],
        sessions: [PanelSessionDTO],
        currentSessionId: UUID?,
        messages: [ChatMessage],
        queuedRequests: [PanelQueuedRequestDTO],
        streamingTexts: [PanelStreamingTextDTO],
        status: String,
        statusText: String,
        isAwaitingFirstModelOutput: Bool,
        isLoadingHistory: Bool,
        tokensUsed: Int,
        tokensTotal: Int,
        activeRunStartedAt: Date?,
        isMirroringRemoteSession: Bool,
        composer: PanelComposerDTO,
        capabilities: [PanelCapabilityDTO]
    ) {
        self.revision = revision
        self.sessionId = sessionId
        self.projects = projects
        self.models = models
        self.sessions = sessions
        self.currentSessionId = currentSessionId
        self.messages = messages
        self.queuedRequests = queuedRequests
        self.streamingTexts = streamingTexts
        self.status = status
        self.statusText = statusText
        self.isAwaitingFirstModelOutput = isAwaitingFirstModelOutput
        self.isLoadingHistory = isLoadingHistory
        self.tokensUsed = tokensUsed
        self.tokensTotal = tokensTotal
        self.activeRunStartedAt = activeRunStartedAt
        self.isMirroringRemoteSession = isMirroringRemoteSession
        self.composer = composer
        self.capabilities = capabilities
    }
}

public struct PanelProjectDTO: Codable, Equatable {
    public let id: UUID
    public let name: String
    public let path: String
    public let defaultCLI: String
    public let createdAt: Date
    public let updatedAt: Date
    public let lastOpenedAt: Date?
}

public struct PanelModelDTO: Codable, Equatable {
    public let id: String
    public let title: String
    public let cli: String
    public let isDefault: Bool
}

public struct PanelSessionDTO: Codable, Equatable {
    public let id: UUID
    public let cli: String
    public let projectId: UUID?
    public let projectName: String
    public let projectPath: String
    public let title: String
    public let modelID: String
    public let runStatus: String
    public let statusText: String
    public let createdAt: Date
    public let updatedAt: Date
    public let lastCompletedAt: Date?
    public let queuedCount: Int
}

public struct PanelQueuedRequestDTO: Codable, Equatable {
    public let id: UUID
    public let text: String
    public let displayText: String
    public let cli: String
    public let modelID: String
    public let permissionMode: String
    public let reasoningEffort: String
    public let projectId: UUID
    public let attachments: [ChatMessageAttachment]
}

public struct PanelStreamingTextDTO: Codable, Equatable {
    /// Message id this streaming text belongs to.
    public let messageId: UUID
    public let text: String
    public let status: String
    public let requestId: String?
}

public struct PanelComposerDTO: Codable, Equatable {
    public let text: String
    public let cli: String
    public let modelID: String
    public let contextModelID: String?
    public let permissionMode: String
    public let reasoningEffort: String
    public let attachments: [ChatMessageAttachment]
    public let isEnabled: Bool      // false when capabilities check failed
    public let placeholder: String  // server-rendered hint
}

public struct PanelCapabilityDTO: Codable, Equatable {
    public let cli: String
    public let executableAvailable: Bool
    public let supportsStreamJSONInput: Bool
    public let supportsAppServer: Bool
    public let errorMessage: String?
}
```

### 4.3 `PanelStatePatch` (server → client)

```swift
public struct PanelStatePatch: Codable, Equatable {
    public let revision: Int
    public let baseRevision: Int       // patch is applicable iff client.lastRevision == baseRevision
    public let sessionId: UUID?

    // Each non-nil field replaces the corresponding snapshot field wholesale.
    public let projects: [PanelProjectDTO]?
    public let models: [PanelModelDTO]?
    public let sessions: [PanelSessionDTO]?
    public let currentSessionId: NullableUUIDWrapper?
    public let messages: [ChatMessage]?
    public let queuedRequests: [PanelQueuedRequestDTO]?
    public let streamingTexts: [PanelStreamingTextDTO]?
    public let status: String?
    public let statusText: String?
    public let isAwaitingFirstModelOutput: Bool?
    public let isLoadingHistory: Bool?
    public let tokensUsed: Int?
    public let tokensTotal: Int?
    public let activeRunStartedAt: NullableDateWrapper?
    public let isMirroringRemoteSession: Bool?
    public let composer: PanelComposerDTO?
    public let capabilities: [PanelCapabilityDTO]?
}

/// Wrapper to distinguish "field absent (don't touch)" from "field present and explicitly nil".
public struct NullableUUIDWrapper: Codable, Equatable {
    public let value: UUID?
    public init(_ value: UUID?) { self.value = value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        value = c.decodeNil() ? nil : try? c.decode(UUID.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let value { try c.encode(value) } else { try c.encodeNil() }
    }
}

public struct NullableDateWrapper: Codable, Equatable {
    public let value: Date?
    public init(_ value: Date?) { self.value = value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        value = c.decodeNil() ? nil : try? c.decode(Date.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let value { try c.encode(value) } else { try c.encodeNil() }
    }
}
```

> The `NullableXxxWrapper` distinction matters for `currentSessionId` and `activeRunStartedAt` where transitioning to `nil` is a meaningful state change. Other optionals (e.g. `messages`) use plain `nil` for "field unchanged" because they have no semantic `nil`.

### 4.4 `PanelStateEnvelope` (server → client)

```swift
public struct PanelStateEnvelope: Codable, Equatable {
    public enum Kind: String, Codable, Equatable {
        case snapshot
        case patch
    }

    public let type: String           // always "panel_state"
    public let kind: Kind
    public let sessionId: UUID?
    public let revision: Int

    /// Exactly one of these is non-nil based on `kind`.
    public let snapshot: PanelStateSnapshot?
    public let patch: PanelStatePatch?

    public init(snapshot: PanelStateSnapshot) {
        self.type = "panel_state"
        self.kind = .snapshot
        self.sessionId = snapshot.sessionId
        self.revision = snapshot.revision
        self.snapshot = snapshot
        self.patch = nil
    }
    public init(patch: PanelStatePatch) {
        self.type = "panel_state"
        self.kind = .patch
        self.sessionId = patch.sessionId
        self.revision = patch.revision
        self.snapshot = nil
        self.patch = patch
    }
}
```

Wire shape:

```json
{ "type": "panel_state", "kind": "snapshot", "sessionId": "…", "revision": 42, "snapshot": { … } }
{ "type": "panel_state", "kind": "patch",    "sessionId": "…", "revision": 43, "patch":    { "baseRevision": 42, "messages": [ … ] } }
```

### 4.5 `Command` (client → server)

```swift
public struct Command: Codable, Equatable {
    public let type: String           // always "command"
    public let commandId: UUID
    public let op: Op
    public let sessionId: UUID?       // panel scope, when applicable
    public let args: CommandArgs

    public enum Op: String, Codable, Equatable {
        case focusSession           // args.sessionId
        case newDraftSession        // args.projectId
        case composerSet            // args.text
        case composerSetCLI         // args.cli
        case composerSetModel       // args.modelID
        case composerSetPermissionMode // args.permissionMode
        case composerSetReasoningEffort // args.reasoningEffort
        case composerAttach         // args.attachment
        case composerRemoveAttach   // args.attachmentId
        case composerSend           // args.sessionMode, args.resumeSessionID, args.appendRuleText (all optional)
        case stop                   // args.startQueuedAfterStop optional bool
        case flushQueue
        case cancelQueued           // args.requestId
        case editQueued             // args.requestId, args.text
        case respondPermission      // args.permissionRequestId, args.decision ("allow"|"deny"|"allowForSession")
        case respondInteractive     // args.interactiveRequestId, args.interactiveResponse (JSON-encoded)
        case requestSnapshot        // force server to re-broadcast snapshot
        case refreshCapabilities
    }
}

/// Flat dictionary of args. Each op uses a subset; unrecognized keys must be ignored.
/// Encoded as a JSON object with string-keyed primitives. Helper accessors below.
public struct CommandArgs: Codable, Equatable {
    public var text: String?
    public var cli: String?
    public var modelID: String?
    public var contextModelID: String?
    public var permissionMode: String?
    public var reasoningEffort: String?
    public var projectId: UUID?
    public var sessionId: UUID?
    public var requestId: String?            // for cancelQueued/editQueued
    public var permissionRequestId: String?
    public var decision: String?
    public var interactiveRequestId: String?
    public var interactiveResponse: ChatInteractiveResponse?
    public var attachment: ChatMessageAttachment?
    public var attachmentId: UUID?
    public var sessionMode: String?
    public var resumeSessionID: String?
    public var appendRuleText: String?
    public var startQueuedAfterStop: Bool?

    public init(
        text: String? = nil,
        cli: String? = nil,
        modelID: String? = nil,
        contextModelID: String? = nil,
        permissionMode: String? = nil,
        reasoningEffort: String? = nil,
        projectId: UUID? = nil,
        sessionId: UUID? = nil,
        requestId: String? = nil,
        permissionRequestId: String? = nil,
        decision: String? = nil,
        interactiveRequestId: String? = nil,
        interactiveResponse: ChatInteractiveResponse? = nil,
        attachment: ChatMessageAttachment? = nil,
        attachmentId: UUID? = nil,
        sessionMode: String? = nil,
        resumeSessionID: String? = nil,
        appendRuleText: String? = nil,
        startQueuedAfterStop: Bool? = nil
    ) {
        self.text = text
        self.cli = cli
        self.modelID = modelID
        self.contextModelID = contextModelID
        self.permissionMode = permissionMode
        self.reasoningEffort = reasoningEffort
        self.projectId = projectId
        self.sessionId = sessionId
        self.requestId = requestId
        self.permissionRequestId = permissionRequestId
        self.decision = decision
        self.interactiveRequestId = interactiveRequestId
        self.interactiveResponse = interactiveResponse
        self.attachment = attachment
        self.attachmentId = attachmentId
        self.sessionMode = sessionMode
        self.resumeSessionID = resumeSessionID
        self.appendRuleText = appendRuleText
        self.startQueuedAfterStop = startQueuedAfterStop
    }
}
```

Per-op argument expectations (consumed by `RemoteChatCommandRouter`):

| Op | Required args | Notes |
|----|---------------|-------|
| `focusSession` | `sessionId` (on envelope OR args) | Server makes that session the panel's current session for this connection. |
| `newDraftSession` | `args.projectId` | Server allocates a new draft `ChatSessionRecord`, returns its `id` in the ack. |
| `composerSet` | `args.text` | Updates composer text. |
| `composerSetCLI` | `args.cli` | One of `claude` / `codex`. |
| `composerSetModel` | `args.modelID` | |
| `composerSetPermissionMode` | `args.permissionMode` | One of `ask` / `autoEdit` / `fullAccess`. |
| `composerSetReasoningEffort` | `args.reasoningEffort` | One of `low` / `medium` / `high` / `xhigh` / `max`. |
| `composerAttach` | `args.attachment` | Use the response from `POST /attachments` to construct the `ChatMessageAttachment`. |
| `composerRemoveAttach` | `args.attachmentId` | |
| `composerSend` | (none required; composer state is server-side) | Optionally `args.sessionMode`, `args.resumeSessionID`, `args.appendRuleText` override composer defaults for this send. |
| `stop` | optional `args.startQueuedAfterStop` | |
| `flushQueue` | — | Interrupts active turn so next queued runs. |
| `cancelQueued` | `args.requestId` | |
| `editQueued` | `args.requestId`, `args.text` | |
| `respondPermission` | `args.permissionRequestId`, `args.decision` | |
| `respondInteractive` | `args.interactiveRequestId`, `args.interactiveResponse` | |
| `requestSnapshot` | — | Server replies with fresh snapshot for the panel currently focused on this connection. |
| `refreshCapabilities` | — | |

### 4.6 `CommandAck` (server → client)

```swift
public struct CommandAck: Codable, Equatable {
    public let type: String          // always "command_ack"
    public let commandId: UUID
    public let status: Status
    public let message: String?
    public let sessionId: UUID?      // populated for newDraftSession & ops that resolve to a session

    public enum Status: String, Codable, Equatable {
        case ok
        case rejected     // command valid but server refuses (e.g. CLI unsupported)
        case error        // command malformed or threw
    }
}
```

Server MUST emit `command_ack` for every command it receives. For `newDraftSession`, `sessionId` carries the newly-allocated session UUID; iOS uses it as the focus target.

### 4.7 `ResumeRequest` (client → server, on connect)

```swift
public struct ResumeRequest: Codable, Equatable {
    public let type: String           // always "resume"
    public let sessionId: UUID?       // panel scope; nil = "currently focused"
    public let lastRevision: Int?     // nil = client has no state, server should send a full snapshot
}
```

Server response semantics:

- If `lastRevision == nil` OR `lastRevision < oldestRetainedPatch.baseRevision` → **send full snapshot** for that session.
- Else send the chain of patches from `lastRevision + 1` through `currentRevision`.
- If `sessionId` is unknown (e.g. session deleted) → send a snapshot for "no session" (empty messages, sessions list refreshed).

### 4.8 Per-session revision strategy

Server's `ChatPanelController` (one per session record, owned by `ChatRuntimeStore`) increments `revision` on every observable change. To bridge SwiftUI `@Published` storms into a single revision bump, agent-mac-controller MUST coalesce all property changes within one main-actor turn:

- Use a Combine `objectWillChange.debounce(for: .milliseconds(16))` or a similar microtask-coalescing scheme on the controller side.
- The protocol-server agent subscribes to a `var snapshotPublisher: AnyPublisher<PanelStateSnapshot, Never>` exposed by the controller (see §4.9 — required interface). This publisher fires at most once per coalesced turn, producing snapshot N+1.

### 4.9 Controller ↔ server contract (binding interface)

`ChatPanelController` MUST expose (the protocol-server agent depends on these — agent-mac-controller MUST implement them):

```swift
@MainActor
public protocol PanelStateBroadcasting: AnyObject {
    /// Stable identifier for this panel (matches sessionId in PanelStateSnapshot).
    var sessionId: UUID? { get }

    /// Current snapshot (synchronous read). Used for `resume` and `requestSnapshot`.
    func currentSnapshot() -> PanelStateSnapshot

    /// Stream of revision-incremented snapshots. Fires after a coalesced state change.
    /// Server forwards each emission as a `panel_state` envelope (snapshot or patch).
    var snapshotPublisher: AnyPublisher<PanelStateSnapshot, Never> { get }

    /// Optional: a finer-grained patch stream when the controller can compute deltas
    /// itself. If absent, server diffs snapshots and decides snapshot-vs-patch on the fly.
    var patchPublisher: AnyPublisher<PanelStatePatch, Never>? { get }

    // ---- Imperative command surface (one method per Command.Op) ----
    func remoteFocusSession(_ id: UUID)
    func remoteNewDraftSession(projectId: UUID) -> UUID  // returns new sessionId
    func remoteComposerSet(text: String)
    func remoteComposerSetCLI(_ cli: CLIType)
    func remoteComposerSetModel(_ modelID: String)
    func remoteComposerSetPermissionMode(_ mode: ChatPermissionMode)
    func remoteComposerSetReasoningEffort(_ effort: ChatReasoningEffort)
    func remoteComposerAttach(_ attachment: ChatMessageAttachment)
    func remoteComposerRemoveAttach(id: UUID)
    func remoteComposerSend(sessionMode: SessionMode?, resumeSessionID: String?, appendRuleText: String?) -> Bool
    func remoteStop(startQueuedAfterStop: Bool)
    func remoteFlushQueue()
    func remoteCancelQueued(requestId: UUID)
    func remoteEditQueued(requestId: UUID, text: String)
    func remoteRespondPermission(requestId: String, decision: ChatPermissionDecision)
    func remoteRespondInteractive(response: ChatInteractiveResponse)
    func remoteRequestSnapshot()
    func remoteRefreshCapabilities()
}
```

All `remote*` methods internally route to the existing public mutation methods in §1.2 — they are a stable adapter so the server doesn't need to know about renames/refactors inside the controller.

The protocol-server agent assumes this interface exists. The mac-controller agent MUST implement it on `ChatPanelController` and have `ChatRuntimeStore` vend the per-session controllers via a new method `func controller(for sessionId: UUID?) -> ChatPanelController` (existing key-based getter is fine; just expose it publicly to the server).

### 4.10 Code reference

- New file: `共享代码/ChatCore/Sources/ChatCore/RemoteVNCProtocol.swift`
- New file (Mac, by agent-mac-controller): `Mac版本/Codevoke/ViewModels/ChatPanelController.swift` (or rename `ChatPanelState.swift`)
- New file (Mac, by agent-protocol-server): `Mac版本/Codevoke/Services/RemoteChat/PanelStateBroadcaster.swift` — owns the per-session `snapshotPublisher` subscriptions and the patch-or-snapshot heuristic.
- New file (Mac, by agent-protocol-server): `Mac版本/Codevoke/Services/RemoteChat/RemoteChatCommandRouter.swift` — `func dispatch(_ command: Command, on connection: WSConnection)`.

---

## 5. Compatibility strategy (Phase B dual-broadcast)

After agent-mac-controller and agent-protocol-server merge but before agent-ios-thin-client ships, an in-the-wild older iOS will still connect and expect legacy frames. Server therefore:

### 5.1 Dual broadcast in `RemoteChatServer.broadcastWebSocketEvent`

The legacy producer paths (`ChatPanelState.publishRemoteStreamEventIfNeeded`, `RemoteChatBridge.eventHandler`) and the new `PanelStateBroadcaster` BOTH push frames into the same connection's send queue. New clients (identified by the presence of `resume` with `lastRevision` instead of `cursor`) get only `panel_state` envelopes; old clients (identified by `resume` with `cursor`) get only legacy events. Track this per-connection via a `protocolMode: legacy|vnc` flag set on first `resume` frame.

### 5.2 Server emits both envelopes during Phase B

For each controller state change:

1. `PanelStateBroadcaster` computes snapshot/patch → enqueue for VNC clients.
2. Legacy event producers continue to fire `assistant_delta`, `queue_status`, etc. → enqueue for legacy clients.

This means the legacy mirror plumbing (`NotificationCenter.default.post(.remoteChatStreamEvent)`, `RemoteSessionMirrorBus.publish`) stays alive throughout Phase B. Agent-protocol-server MUST NOT delete them yet.

### 5.3 Phase boundary

- **Phase A (this refactor)**: protocol-server + mac-controller land; server speaks both protocols. iOS unchanged.
- **Phase B**: iOS thin-client lands; only VNC protocol used in the wild.
- **Phase C** (future, not part of this work item): delete `RemoteChatBridge`, `RemoteSessionMirrorBus`, `RemoteChatStreamEvent` legacy producer, HTTP `/events`, HTTP messages/sessions/projects/models endpoints. (Listed here for future reference; not in scope.)

---

## 6. Worktree boundaries (must not conflict on merge)

### 6.1 agent-protocol-server

**Allowed to modify**:

- `Mac版本/Codevoke/Services/RemoteChat/RemoteChatServer.swift`
- `Mac版本/Codevoke/Services/RemoteChat/RemoteChatRouter.swift`
- `Mac版本/Codevoke/Services/RemoteChat/RemoteChatWebSocket.swift` (only if frame size needs increase or new opcodes — likely untouched)
- `Mac版本/Codevoke/Services/RemoteChat/RemoteChatDTOs.swift` (delete legacy DTOs no longer used by iOS routes)
- `Mac版本/Codevoke/Services/RemoteChat/RemoteChatServerController.swift`
- `Mac版本/Codevoke/Services/RemoteChat/RemoteSessionMirrorBus.swift` (Phase B keeps it; the legacy `RemoteChatBridge.swift` keeps producing for it. Agent must not delete it.)
- `Mac版本/Codevoke/Services/RemoteChat/RemoteChatBridge.swift` — **only** to remove its private queue/backend/livePersist and convert it into a thin legacy-protocol shim that forwards `send_message` etc. to the controller. The controller-facing surface goes through `PanelStateBroadcaster`/`RemoteChatCommandRouter`, not Bridge.

**Allowed to create**:

- `共享代码/ChatCore/Sources/ChatCore/RemoteVNCProtocol.swift` (authoritative DTO file)
- `Mac版本/Codevoke/Services/RemoteChat/PanelStateBroadcaster.swift`
- `Mac版本/Codevoke/Services/RemoteChat/RemoteChatCommandRouter.swift`

**Forbidden to modify**:

- `Mac版本/Codevoke/ViewModels/ChatPanelState.swift` / `ChatPanelController.swift`
- Any Mac view (`Mac版本/Codevoke/Views/**`)
- Any iOS file (`iOS版本/**`)
- Shared types other than the new `RemoteVNCProtocol.swift`

**Contract dependency on mac-controller**: relies on `ChatPanelController: PanelStateBroadcasting` (§4.9). Stubs an empty no-op `PanelStateBroadcasting` test double for unit tests in this worktree.

### 6.2 agent-mac-controller

**Allowed to modify**:

- `Mac版本/Codevoke/ViewModels/ChatPanelState.swift` (rename to `ChatPanelController.swift` or refactor in place)
- `Mac版本/Codevoke/ViewModels/AppState.swift` (only if controller lifecycle requires it)
- `Mac版本/Codevoke/Services/Chat/ChatRuntimeStore.swift` (vending controllers; add a public accessor)
- `Mac版本/Codevoke/Views/ClaudeSessionPanelView.swift`
- `Mac版本/Codevoke/Views/ClaudeSessionPanelComposer.swift`
- `Mac版本/Codevoke/Views/ClaudeSessionPanelSupport.swift`
- Other Mac views that call `chatState.<mutate>` (per §1.5 table) — receiver rename only.

**Allowed to create**:

- `Mac版本/Codevoke/ViewModels/ChatPanelController.swift` (new home for the renamed/extracted controller)

**Forbidden to modify**:

- `共享代码/ChatCore/**` — DTOs are owned by agent-protocol-server.
- `Mac版本/Codevoke/Services/RemoteChat/RemoteChatServer.swift` / `RemoteChatRouter.swift` / `RemoteChatWebSocket.swift` / `RemoteChatDTOs.swift` / `RemoteChatServerController.swift` / `RemoteChatBridge.swift` / `RemoteSessionMirrorBus.swift`
- Any iOS file (`iOS版本/**`)

**Contract dependency on protocol-server**: relies on the `PanelStateBroadcasting` protocol declared in `共享代码/ChatCore/Sources/ChatCore/RemoteVNCProtocol.swift`. Until that file lands in main, this agent stubs the protocol locally and imports the real one after rebase. Conform `ChatPanelController` to `PanelStateBroadcasting`.

### 6.3 agent-ios-thin-client

**Allowed to modify**:

- All files under `iOS版本/Codevoke/` (Swift sources).

**Allowed to create**:

- `iOS版本/Codevoke/ViewModels/PanelStateMirror.swift` (the new thin-client renderer state object — replaces `ChatViewModel`'s deleted bits).
- Any new view/networking helper file inside `iOS版本/Codevoke/`.

**Forbidden to modify**:

- Any Mac file (`Mac版本/Codevoke/**`)
- `共享代码/**` — depend on whatever `agent-protocol-server` shipped to ChatCore.

**Contract dependency on protocol-server**: imports `ChatCore.PanelStateSnapshot`, `PanelStatePatch`, `PanelStateEnvelope`, `Command`, `CommandAck`, `ResumeRequest` and assumes the wire format in §4.

### 6.4 Merge order

**protocol-server → mac-controller → ios-thin-client.** Three agents work in parallel inside their worktrees; merging in this order avoids touching the same file twice and lets each subsequent agent rebase on top of the previous.

---

## 7. Bug scenarios — how the new architecture eliminates them

### 7.1 S1: queue and "already sent" coexistence

**Today**: `RemoteChatBridge.pendingRequests` and `ChatPanelState.queuedRequests` are two independent queues. When iOS sends, only `pendingRequests` grows; the Mac UI's `queuedRequests` is populated indirectly via `queue_status` mirroring (`ChatPanelState.applyRemoteQueueEvent` at line 1633). A race during turn-end can leave both queues with the same request, or with neither (S1 manifests as a request appearing both in queue and as a sent user message).

**After**: There is only `ChatPanelController.queuedRequests`. Any new message goes through `controller.send(...)` which atomically either runs immediately or appends to `queuedRequests`. The Bridge's `pendingRequests` is **deleted**. The server's command router calls `controller.send` directly — there is no second queue to drift from.

### 7.2 S2: stop ineffective / stale queue lingers

**Today**: `stop(clientConversationId:)` in `RemoteChatBridge.swift:403-432` clears `pendingRequests` for that conversation but not the corresponding entries in `ChatPanelState.queuedRequests`. Conversely the local `interrupt()` clears `queuedRequests` but doesn't talk to the Bridge. Result: depending on which side initiates stop, the other side keeps a ghost queue.

**After**: `controller.interrupt()` clears the single queue. iOS's `stop` command becomes `controller.remoteStop(...)` → `controller.interrupt(...)`. There is no second queue to forget about.

### 7.3 S3: cross-session queue invisibility

**Today**: iOS keeps queue state in `queuedMessagesBySession[UUID]`. When Mac processes a Mac-side queue change, it doesn't notify the right iOS session unless `clientConversationId` happens to match — non-mirrored sessions diverge silently.

**After**: iOS doesn't track per-session queues. The snapshot for whichever session is focused on Mac carries `queuedRequests` as part of its payload. iOS's `focusSession` command pulls a fresh snapshot for the new session — what Mac thinks the queue is **is** what iOS shows.

### 7.4 S4: streaming "stuck" indicator

**Today**: `sessionStreamingMessageIDs`, `sessionOperationalStreamingMessageIDs`, `pendingStreamDeltas` etc. on iOS each accumulate keys when a stream begins and rely on `output_finished` / `assistant_done` / `assistant_error` to clear them. If any of those events is dropped (cursor gap → HTTP backfill misses, server epoch changes, or an unrecognised event type during a CLI upgrade) the ID stays in the map and iOS shows a permanent "thinking" indicator.

**After**: streaming state is part of the snapshot (`streamingTexts` array + `status` field + `isAwaitingFirstModelOutput` flag). Mac controller manages it in one place (already does — via `StreamingTextStore` and `activeStreamingMessageIDs`). When the controller finishes the message, the next patch sets `streamingTexts = []` and the iOS UI immediately reflects it. No per-client cleanup logic needed.

### 7.5 S5: bidirectional draft invisibility

**Today**: when Mac is on a "no session yet" draft and iOS sends `send_message` with `clientConversationId == draftConversationID`, the Mac side has its own draft state (no session yet) that doesn't know about iOS's draft. After the Mac CLI starts, both sides create a new session record but reconciling the two draft IDs requires `clientConversationId`-based plumbing throughout the protocol (see `RemoteSessionMirrorBus.subscribeToBegins`, `subscribeRemoteMirrorBeginsIfNeeded`, `handleRemoteMirrorBeginEvent`).

**After**: there are no client-owned drafts. iOS's "new chat" button sends a `newDraftSession` command and gets back the canonical `sessionId` in the ack. From that moment on both sides talk about the same session. The snapshot for that session is the single source of truth. The entire `RemoteSessionMirrorBus.subscribeToBegins` mechanism becomes unnecessary (Phase C deletes it).

---

## 8. Open questions / decision points for human review

These are points where the source code allows multiple plausible interpretations and the implementing agents will need a steer if my default choice is wrong:

1. **Controller scope**: Currently `ChatRuntimeStore` keeps a `ChatPanelState` per `(projectID, sessionID)` history key, and the Mac UI shows only one at a time (`isRuntimeVisible`). The spec assumes "one snapshot stream per session, server vends snapshots for whichever session a connection is currently focused on". The alternative is "one connection = one focused panel; server multiplexes nothing". I picked single-focus per connection. **Confirm?**

2. **Catalog (projects/models/sessions) in every snapshot**: I included them in `PanelStateSnapshot` for simplicity, even though they're orthogonal to the per-session state. This bloats every snapshot but eliminates a second protocol surface. Alternative: a separate `CatalogSnapshot` envelope (`type: "catalog_state"`). **Confirm bloat tradeoff is acceptable?**

3. **Composer attachments**: Should `composerAttach` upload the file as base64 inside the command (latency-cheap, blocks 1 MB max frame), or should iOS pre-upload via `POST /attachments` and then send the resulting `ChatMessageAttachment` reference? Spec assumes the latter (matches current behavior). **Confirm.**

4. **`appendRuleText`**: today's `controller.send` accepts `appendRuleText:`, but the Mac UI sources it from project settings while iOS never sends one. In the new protocol I made `args.appendRuleText` optional on `composerSend` — if absent, server's `loadOrCreateSession`/`ProjectStore.loadSettings().appendRuleText` path supplies the default. **Confirm iOS doesn't need to override?**

5. **Patch retention 64**: chosen because the highest-volume sequences (assistant deltas at ~10/s) burn ~6 s of runway. If iOS is backgrounded for >6 s during a generation it'll resume with a full snapshot. **Bump to 256 if you want longer offline windows.**

6. **`composer.text` server-authoritative**: this means typing on iOS sends `composerSet` for every keystroke. That's fine over LAN but bandwidth-hungry. Alternative: keep `composer.text` local on each client (last writer wins, no echo). Spec currently treats it as authoritative for VNC parity, with an explicit "echo back" via patch. **Confirm? — if you'd rather treat it as client-local, the spec change is small: remove `composer.text` from snapshot, treat `composerSet` as a no-op for state but used only at `composerSend` time.**

7. **`isMirroringRemoteSession` flag**: in the new world it's always `false` because there's only one source of truth. I kept the field in `PanelStateSnapshot` for symmetry but it's effectively dead. **OK to delete it after Phase B?**

8. **HTTP `/projects/{id}/files`**: I list it as DELETE under §2.4 but the new protocol has no replacement op. If iOS still needs file tree browsing, add a `fetchProjectFiles` op + a `projectFiles` field to snapshot/patch. **Decision needed.** (Spec currently leaves it deleted — file tree is not part of the chat panel state.)

9. **Per-connection focus state vs per-controller**: when iOS switches between two sessions quickly, server has two controllers each emitting snapshots. The connection-routing code in `RemoteChatServer` needs to know which session the connection is currently focused on so it only forwards relevant envelopes. I assumed the connection state holds `currentSessionId` and switches it on `focusSession`. **Confirm wire-level behavior: server pushes envelopes for all sessions to all connections, or only the focused one?** (Spec says: only focused, to keep traffic bounded.)

---

## 9. Out-of-scope

- Multi-user concurrent editing on Mac.
- File-tree browsing protocol (see Q8).
- Authentication beyond the existing bearer token.
- Phase C cleanup of legacy producer code.
