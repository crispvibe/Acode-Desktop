# Remote Chat V2 Protocol

## Boundary

Remote Chat keeps HTTP and WebSocket together.

- Recovery RPC is the authoritative read path for catalog, sessions, messages,
  files, and attachments. It can be carried by HTTP, WebSocket, or WebRTC
  DataChannel so relay/P2P clients have the same read semantics as LAN clients.
- WebSocket/DataChannel live frames are the control path: commands, command
  ack, queue updates, turn events, output deltas, snapshots, and heartbeats.

The iOS app is a remote controller and live viewer. Mac remains the execution owner.

## Event Envelope

Every live event keeps the V1 fields for compatibility and adds V2 envelope fields:

- `protocolVersion`: currently `2`
- `eventId`: unique event identity for idempotent application
- `envelopeKind`: `event`
- `serverEpoch`: Mac server boot/log epoch
- `cursor`: global stream cursor
- `snapshotCursor`: cursor that can be used for snapshot fallback
- `eventScopeId`: session or client conversation scope
- `eventScopeKind`: `session`, `client_conversation`, or `global`

Command payloads may add:

- `protocolVersion`
- `commandId`
- `requestId`
- `sessionId`
- `clientConversationId`

## Control Events

- `hello`: emitted by Mac immediately after WebSocket handshake. iOS must treat the socket as connected only after this event.
- `command_ack`: emitted for protocol controls such as `resume` and `cursor_ack`.
- `replay_truncated`: emitted when the requested cursor is older than the Mac replay cache. iOS must discard pending cursor gaps, fetch HTTP snapshots/history, then resume from the latest cursor it can apply.

## Recovery RPC

`recovery_request` / `recovery_response` frames are independent of the
currently focused panel. Clients should use them cache-first for sidebar and
history views, then let live `panel_state` frames refine the active session.

- `catalog`: returns `projects`, `models`, and filtered `sessions`.
- `sessions`: returns sessions for an optional `projectId` / `cli`.
- `messages`: returns messages or a paged `messagePage` for a `sessionId`.
- `projectFiles`: returns a bounded directory listing for a `projectId` + path.
- `uploadAttachment`: stores an attachment and returns a server-side path.

## Replay Rules

- V1 global cursor is still supported.
- V2 clients should keep per-stream cursor state when session/queue scoped streams are introduced.
- Applying events must be idempotent by `eventId`; output deltas should also be guarded by request/message sequence when available.
- A scoped HTTP replay must not assume that cursor values are contiguous after filtering. Contiguity only applies to the global stream.

## Migration Plan

1. Add V2 envelope fields while keeping V1 event bodies.
2. Gate iOS connected state on `hello`.
3. Add command ack and replay truncation handling.
4. Move Mac publication behind a committed event bus/store.
5. Move iOS from one global cursor to per-stream cursor state.
6. Persist the event log so disconnected iOS and late Mac UI panels can replay the same truth source.
