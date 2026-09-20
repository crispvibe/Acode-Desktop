// PanelStateBroadcaster.swift
//
// Server-side glue between `ChatPanelController` (Mac state, owned by
// `ChatRuntimeStore`) and the VNC-style WS clients. Per spec §4.7-§4.9.
//
// Responsibilities (this file):
//   1. Declare `PanelStateBroadcasting` — the protocol `ChatPanelController`
//      must conform to. We declare it here (Mac-side) because only the server
//      needs it; ChatCore stays platform-neutral.
//   2. Maintain a per-session monotonic revision counter and a bounded ring
//      buffer of recent patches for `resume` replays (window = 128).
//   3. Diff consecutive snapshots into `PanelStatePatch` envelopes. Snapshot
//      pushes are used when the patch would be larger than the snapshot or the
//      client requested a fresh sync.
//   4. Expose a per-connection focus state — each WS connection only receives
//      envelopes for its currently focused session.
//
// Performance guardrails (per user long-term preference):
//   - Patch retention via a fixed-capacity ring (no unbounded `append`).
//   - Snapshot diffing is O(field count), not O(messages.count²).
//   - Patches emitted at most once per coalesced controller turn (controller
//     debounces its `objectWillChange` to ≤30 ms before vending a snapshot).

import Combine
import Foundation
import ChatCore

// MARK: - Controller-facing protocol

/// Interface `ChatPanelController` (mac-controller agent) must adopt so the
/// server can subscribe and command-route without seeing Mac-internal types.
@MainActor
protocol PanelStateBroadcasting: AnyObject {
    /// Stable identifier for this panel (matches `sessionId` on snapshots).
    /// `nil` ⇒ "the not-yet-persisted draft" for some project.
    var sessionId: UUID? { get }

    /// Synchronous read of the current snapshot. Used for `resume` and
    /// `requestSnapshot`.
    func currentSnapshot() -> PanelStateSnapshot

    /// Stream of revision-incremented snapshots. Fires after a coalesced state
    /// change (controller responsibility — keep emission rate sane).
    var snapshotPublisher: AnyPublisher<PanelStateSnapshot, Never> { get }

    /// Optional fine-grained patch stream. If absent the server diffs
    /// snapshots itself.
    var patchPublisher: AnyPublisher<PanelStatePatch, Never>? { get }

    // ---- Imperative command surface (one method per Command.Op) ----
    func remoteFocusSession(_ id: UUID)
    /// Returns the newly-allocated session id (carried back in the ack).
    func remoteNewDraftSession(projectId: UUID) -> UUID
    func remoteComposerSet(text: String)
    func remoteComposerSetCLI(_ cli: CLIType)
    func remoteComposerSetModel(_ modelID: String)
    func remoteComposerSetPermissionMode(_ mode: ChatPermissionMode)
    func remoteComposerSetReasoningEffort(_ effort: ChatReasoningEffort)
    func remoteComposerAttach(_ attachment: ChatMessageAttachment)
    func remoteComposerRemoveAttach(id: UUID)
    /// Returns the project currently resolved for a remote send, used to catch cwd regressions before dispatch.
    func remoteResolvedProjectForSend() -> ProjectItem?
    /// Returns `true` if the send was accepted (queued or started).
    func remoteComposerSend(sessionMode: SessionMode?, resumeSessionID: String?, appendRuleText: String?) -> Bool
    func remoteStop(startQueuedAfterStop: Bool)
    /// Audit B-P1-2: drop every queued request. The previous semantics were
    /// "interrupt active + start next queued"; that's now `remoteInterruptAndStartNext`.
    func remoteFlushQueue()
    /// Audit B-P1-2: legacy `flushQueue` behavior — interrupts the active
    /// turn and starts the next queued request, without dropping the queue.
    func remoteInterruptAndStartNext()
    func remoteCancelQueued(requestId: UUID)
    func remoteEditQueued(requestId: UUID, text: String)
    func remoteRespondPermission(requestId: String, decision: ChatPermissionDecision)
    func remoteRespondInteractive(response: ChatInteractiveResponse)
    func remoteRequestSnapshot()
    func remoteRefreshCapabilities()
}

// MARK: - Controller vending

/// Lookup contract: `ChatRuntimeStore` (and friends) supply a controller for a
/// given session id. Returns `nil` if no controller is available yet.
/// mac-controller agent will replace this with the real implementation.
@MainActor
protocol PanelControllerLookup: AnyObject {
    func controller(for sessionId: UUID?) -> PanelStateBroadcasting?
    /// All currently available controllers (used to publish global session
    /// list updates when a connection focuses without a specific id yet).
    func allControllers() -> [PanelStateBroadcasting]
}

@MainActor
protocol RemoteFocusResolving: AnyObject {
    func focusSession(_ sessionId: UUID) -> PanelStateBroadcasting?
    func focusProject(_ projectId: UUID) -> (controller: PanelStateBroadcasting, sessionId: UUID?)?
    func createDraft(projectId: UUID) -> (controller: PanelStateBroadcasting, sessionId: UUID?)?
}

// MARK: - Patch retention window

/// Per spec §4.8 default 64, overridden to 128 by main-agent decision.
let PanelStatePatchRetention = 128

// MARK: - Per-session revision/patch ring buffer

@MainActor
final class PanelSessionRevisionLog {
    /// Sentinel session id used when the controller's panel has no persisted
    /// session yet (draft). Stable so all draft pushes share the same log.
    static let draftSessionKey = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private(set) var currentRevision: Int
    private(set) var lastSnapshot: PanelStateSnapshot?
    /// Ring buffer storing the *N most recent patches*, newest at the end.
    private var patches: [PanelStatePatch] = []
    private let capacity: Int

    init(capacity: Int = PanelStatePatchRetention) {
        self.capacity = max(8, capacity)
        self.currentRevision = 0
    }

    var oldestRetainedBaseRevision: Int? {
        patches.first?.baseRevision
    }

    /// Record a brand new snapshot. Returns the snapshot stamped with the
    /// next revision. If the previous snapshot is non-nil, also computes a
    /// patch covering the diff and stores it in the ring.
    func record(_ snapshot: PanelStateSnapshot) -> PanelStateSnapshot {
        let nextRevision = currentRevision + 1
        let stamped = PanelStateSnapshot(
            revision: nextRevision,
            sessionId: snapshot.sessionId,
            projects: snapshot.projects,
            models: snapshot.models,
            sessions: snapshot.sessions,
            currentSessionId: snapshot.currentSessionId,
            messages: snapshot.messages,
            queuedRequests: snapshot.queuedRequests,
            streamingTexts: snapshot.streamingTexts,
            status: snapshot.status,
            statusText: snapshot.statusText,
            isAwaitingFirstModelOutput: snapshot.isAwaitingFirstModelOutput,
            isLoadingHistory: snapshot.isLoadingHistory,
            tokensUsed: snapshot.tokensUsed,
            tokensTotal: snapshot.tokensTotal,
            activeRunStartedAt: snapshot.activeRunStartedAt,
            isMirroringRemoteSession: snapshot.isMirroringRemoteSession,
            composer: snapshot.composer,
            capabilities: snapshot.capabilities
        )
        if let previous = lastSnapshot {
            let patch = PanelStateDiff.diff(previous: previous, current: stamped, baseRevision: currentRevision)
            patches.append(patch)
            if patches.count > capacity {
                patches.removeFirst(patches.count - capacity)
            }
        }
        lastSnapshot = stamped
        currentRevision = nextRevision
        return stamped
    }

    /// Record an externally-computed patch (e.g. controller-supplied via
    /// `patchPublisher`). The patch is re-stamped onto our revision sequence
    /// and its `baseRevision` is rewritten to match.
    func record(externalPatch patch: PanelStatePatch) -> PanelStatePatch {
        // External patches can't share revision numbers with snapshots that
        // they don't follow, so we always treat them as one revision after
        // current.
        let nextRevision = currentRevision + 1
        let stamped = PanelStatePatch(
            revision: nextRevision,
            baseRevision: currentRevision,
            sessionId: patch.sessionId,
            projects: patch.projects,
            models: patch.models,
            sessions: patch.sessions,
            currentSessionId: patch.currentSessionId,
            messages: patch.messages,
            queuedRequests: patch.queuedRequests,
            streamingTexts: patch.streamingTexts,
            status: patch.status,
            statusText: patch.statusText,
            isAwaitingFirstModelOutput: patch.isAwaitingFirstModelOutput,
            isLoadingHistory: patch.isLoadingHistory,
            tokensUsed: patch.tokensUsed,
            tokensTotal: patch.tokensTotal,
            activeRunStartedAt: patch.activeRunStartedAt,
            isMirroringRemoteSession: patch.isMirroringRemoteSession,
            composer: patch.composer,
            capabilities: patch.capabilities
        )
        patches.append(stamped)
        if patches.count > capacity {
            patches.removeFirst(patches.count - capacity)
        }
        currentRevision = nextRevision
        return stamped
    }

    /// Returns the chain of patches with `baseRevision >= lastRevision` and
    /// `revision <= currentRevision`. If the chain is incomplete (oldest
    /// retained patch's baseRevision is greater than `lastRevision`) returns
    /// `nil` — caller must send a fresh snapshot instead.
    func patchesSince(lastRevision: Int) -> [PanelStatePatch]? {
        guard lastRevision <= currentRevision else { return [] }
        if lastRevision == currentRevision { return [] }
        guard let oldestBase = oldestRetainedBaseRevision else { return nil }
        if oldestBase > lastRevision { return nil }
        return patches.filter { $0.baseRevision >= lastRevision }
    }
}

// MARK: - Snapshot diff

enum PanelStateDiff {
    /// Field-by-field diff. O(K) where K is the field count (~20). Array
    /// fields are compared with `Equatable.==` (O(N) per array, single pass),
    /// no quadratic compares.
    static func diff(previous: PanelStateSnapshot, current: PanelStateSnapshot, baseRevision: Int) -> PanelStatePatch {
        PanelStatePatch(
            revision: current.revision,
            baseRevision: baseRevision,
            sessionId: current.sessionId,
            projects: previous.projects == current.projects ? nil : current.projects,
            models: previous.models == current.models ? nil : current.models,
            sessions: previous.sessions == current.sessions ? nil : current.sessions,
            currentSessionId: previous.currentSessionId == current.currentSessionId
                ? nil
                : NullableUUIDWrapper(current.currentSessionId),
            messages: previous.messages == current.messages ? nil : current.messages,
            queuedRequests: previous.queuedRequests == current.queuedRequests ? nil : current.queuedRequests,
            streamingTexts: previous.streamingTexts == current.streamingTexts ? nil : current.streamingTexts,
            status: previous.status == current.status ? nil : current.status,
            statusText: previous.statusText == current.statusText ? nil : current.statusText,
            isAwaitingFirstModelOutput: previous.isAwaitingFirstModelOutput == current.isAwaitingFirstModelOutput
                ? nil
                : current.isAwaitingFirstModelOutput,
            isLoadingHistory: previous.isLoadingHistory == current.isLoadingHistory ? nil : current.isLoadingHistory,
            tokensUsed: previous.tokensUsed == current.tokensUsed ? nil : current.tokensUsed,
            tokensTotal: previous.tokensTotal == current.tokensTotal ? nil : current.tokensTotal,
            activeRunStartedAt: previous.activeRunStartedAt == current.activeRunStartedAt
                ? nil
                : NullableDateWrapper(current.activeRunStartedAt),
            isMirroringRemoteSession: previous.isMirroringRemoteSession == current.isMirroringRemoteSession
                ? nil
                : current.isMirroringRemoteSession,
            composer: previous.composer == current.composer ? nil : current.composer,
            capabilities: previous.capabilities == current.capabilities ? nil : current.capabilities
        )
    }
}

// MARK: - Broadcaster

/// Hub that owns per-session revision logs, subscribes to controller publishers
/// and pushes envelopes to a registered sink (`RemoteChatServer`). One instance
/// lives in `RemoteChatServer`.
@MainActor
final class PanelStateBroadcaster {
    /// Emitted whenever a controller produces a new revision. The server
    /// subscribes and fans the envelope out to focused connections.
    let envelopePublisher: AnyPublisher<PanelStateEnvelope, Never>

    private let envelopeSubject = PassthroughSubject<PanelStateEnvelope, Never>()
    private var logs: [UUID: PanelSessionRevisionLog] = [:]
    private var snapshotSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var patchSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var draftAliasControllers: [UUID: PanelStateBroadcasting] = [:]
    private var draftAliasByController: [ObjectIdentifier: UUID] = [:]
    private var draftAliasOrder: [UUID] = []
    private weak var boundLookup: PanelControllerLookup?
    /// Fallback resolver consulted when no lookup has been bound yet. The VNC
    /// pipeline is created during `RemoteChatServer.init` — before the App's
    /// `RemoteVNCWiring.install` runs — so a one-time `bindLookup` would latch
    /// onto a transient stub forever. The resolver re-reads the live wiring on
    /// every access instead.
    var lookupResolver: (() -> PanelControllerLookup?)?

    /// Effective lookup: an explicitly bound instance wins, otherwise the
    /// resolver is consulted so late-installed wiring takes effect.
    private var lookup: PanelControllerLookup? {
        boundLookup ?? lookupResolver?()
    }

    init() {
        envelopePublisher = envelopeSubject.eraseToAnyPublisher()
    }

    func bindLookup(_ lookup: PanelControllerLookup) {
        self.boundLookup = lookup
    }

    /// Begin observing a controller. Safe to call repeatedly; duplicate
    /// subscriptions are ignored.
    func attach(controller: PanelStateBroadcasting) {
        let key = ObjectIdentifier(controller)
        if snapshotSubscriptions[key] == nil {
            let cancellable = controller.snapshotPublisher
                // Hard server-side rate limit. The adapter's own throttle
                // upstream isn't enough in practice — under streaming churn
                // hundreds of `objectWillChange` events per second slip
                // through, each producing a wire patch the client can't keep
                // up with. 200 ms here = max 5 patches/sec/session, plenty
                // for human-perceived realtime and well within WS budget.
                .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak controller] snapshot in
                    guard let self, let controller else { return }
                    let effectiveSessionId = controller.sessionId ?? self.draftAlias(for: controller)
                    let scopedSnapshot = self.snapshot(snapshot, scopedTo: effectiveSessionId)
                    let log = self.log(for: effectiveSessionId)
                    let stamped = log.record(scopedSnapshot)
                    if let _ = log.lastSnapshot, log.currentRevision > 1,
                       let patch = log.patchesSince(lastRevision: log.currentRevision - 1)?.last {
                        self.envelopeSubject.send(PanelStateEnvelope(patch: patch))
                    } else {
                        self.envelopeSubject.send(PanelStateEnvelope(snapshot: stamped))
                    }
                }
            snapshotSubscriptions[key] = cancellable
        }
        if let patchPublisher = controller.patchPublisher, patchSubscriptions[key] == nil {
            let cancellable = patchPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak controller] patch in
                    guard let self, let controller else { return }
                    let effectiveSessionId = controller.sessionId ?? self.draftAlias(for: controller)
                    let scopedPatch = self.patch(patch, scopedTo: effectiveSessionId)
                    let log = self.log(for: effectiveSessionId)
                    let stamped = log.record(externalPatch: scopedPatch)
                    self.envelopeSubject.send(PanelStateEnvelope(patch: stamped))
                }
            patchSubscriptions[key] = cancellable
        }
    }

    func detach(controller: PanelStateBroadcasting) {
        let key = ObjectIdentifier(controller)
        snapshotSubscriptions.removeValue(forKey: key)
        patchSubscriptions.removeValue(forKey: key)
    }

    func registerDraftAlias(_ id: UUID, controller: PanelStateBroadcasting) {
        if draftAliasControllers[id] == nil {
            draftAliasOrder.append(id)
        }
        draftAliasControllers[id] = controller
        draftAliasByController[ObjectIdentifier(controller)] = id
        while draftAliasOrder.count > 128 {
            let evicted = draftAliasOrder.removeFirst()
            if let evictedController = draftAliasControllers.removeValue(forKey: evicted) {
                draftAliasByController.removeValue(forKey: ObjectIdentifier(evictedController))
            }
        }
    }

    /// Resolve a controller via the lookup and return its current snapshot
    /// stamped against this broadcaster's revision counter. Used for `resume`
    /// and `requestSnapshot`.
    func snapshot(for sessionId: UUID?) -> PanelStateSnapshot? {
        guard let lookup else { return nil }
        let controller: PanelStateBroadcasting
        if let sessionId {
            if let direct = lookup.controller(for: sessionId) {
                controller = direct
            } else if let draft = draftAliasControllers[sessionId] {
                controller = draft
            } else {
                return nil
            }
        } else if let current = lookup.controller(for: nil) {
            controller = current
        } else {
            return nil
        }
        // Subscribe to this controller's live updates so subsequent mutations
        // (new messages, streaming deltas, queue churn) are broadcast as
        // patches/snapshots. `attach` is idempotent — `resume` is the single
        // funnel through which every connection's controller is registered,
        // so without this the client only ever sees the resume-time snapshot.
        attach(controller: controller)
        let raw = controller.currentSnapshot()
        let requestedDraftAlias = sessionId.flatMap { requestedId -> UUID? in
            guard let draft = draftAliasControllers[requestedId], draft === controller else {
                return nil
            }
            return requestedId
        }
        let effectiveSessionId = raw.sessionId ?? requestedDraftAlias ?? controller.sessionId ?? draftAlias(for: controller)
        let scoped = snapshot(raw, scopedTo: effectiveSessionId)
        let log = log(for: effectiveSessionId)
        // If we've never recorded one, record now so a follow-up patch chain
        // can be served. Otherwise return the most recent stamped snapshot.
        if let last = log.lastSnapshot, last == scoped {
            return last
        }
        return log.record(scoped)
    }

    /// Resume path. Given a (sessionId, lastRevision), returns either a chain
    /// of patches to apply or a fresh snapshot. Caller is responsible for
    /// wrapping each into `PanelStateEnvelope` and sending in order.
    func replayPayload(sessionId: UUID?, lastRevision: Int?) -> ReplayPayload {
        let log = log(for: sessionId)
        guard let lastRevision, let chain = log.patchesSince(lastRevision: lastRevision), !chain.isEmpty || lastRevision == log.currentRevision else {
            if let snapshot = snapshot(for: sessionId) {
                return .snapshot(snapshot)
            }
            return .empty
        }
        if chain.isEmpty {
            return .empty
        }
        return .patches(chain)
    }

    enum ReplayPayload {
        case snapshot(PanelStateSnapshot)
        case patches([PanelStatePatch])
        case empty
    }

    func log(for sessionId: UUID?) -> PanelSessionRevisionLog {
        let key = sessionId ?? PanelSessionRevisionLog.draftSessionKey
        if let existing = logs[key] {
            return existing
        }
        let log = PanelSessionRevisionLog()
        logs[key] = log
        return log
    }

    func lookupController(for sessionId: UUID?) -> PanelStateBroadcasting? {
        if let sessionId {
            return lookup?.controller(for: sessionId) ?? draftAliasControllers[sessionId]
        }
        return lookup?.controller(for: nil)
    }

    func focusController(for sessionId: UUID) -> PanelStateBroadcasting? {
        if let draft = draftAliasControllers[sessionId] {
            return draft
        }
        if let resolver = lookup as? RemoteFocusResolving {
            return resolver.focusSession(sessionId)
        }
        return lookup?.controller(for: sessionId)
    }

    func focusProject(_ projectId: UUID) -> (controller: PanelStateBroadcasting, sessionId: UUID?)? {
        guard let resolver = lookup as? RemoteFocusResolving else { return nil }
        return resolver.focusProject(projectId)
    }

    func createDraft(projectId: UUID) -> (controller: PanelStateBroadcasting, sessionId: UUID?)? {
        guard let resolver = lookup as? RemoteFocusResolving else { return nil }
        return resolver.createDraft(projectId: projectId)
    }

    func allControllers() -> [PanelStateBroadcasting] {
        lookup?.allControllers() ?? []
    }

    private func draftAlias(for controller: PanelStateBroadcasting) -> UUID? {
        draftAliasByController[ObjectIdentifier(controller)]
    }

    private func snapshot(_ snapshot: PanelStateSnapshot, scopedTo sessionId: UUID?) -> PanelStateSnapshot {
        guard let sessionId, snapshot.sessionId == nil, snapshot.currentSessionId == nil else {
            return snapshot
        }
        return PanelStateSnapshot(
            revision: snapshot.revision,
            sessionId: sessionId,
            projects: snapshot.projects,
            models: snapshot.models,
            sessions: snapshot.sessions,
            currentSessionId: sessionId,
            messages: snapshot.messages,
            queuedRequests: snapshot.queuedRequests,
            streamingTexts: snapshot.streamingTexts,
            status: snapshot.status,
            statusText: snapshot.statusText,
            isAwaitingFirstModelOutput: snapshot.isAwaitingFirstModelOutput,
            isLoadingHistory: snapshot.isLoadingHistory,
            tokensUsed: snapshot.tokensUsed,
            tokensTotal: snapshot.tokensTotal,
            activeRunStartedAt: snapshot.activeRunStartedAt,
            isMirroringRemoteSession: snapshot.isMirroringRemoteSession,
            composer: snapshot.composer,
            capabilities: snapshot.capabilities
        )
    }

    private func patch(_ patch: PanelStatePatch, scopedTo sessionId: UUID?) -> PanelStatePatch {
        guard let sessionId, patch.sessionId == nil else {
            return patch
        }
        return PanelStatePatch(
            revision: patch.revision,
            baseRevision: patch.baseRevision,
            sessionId: sessionId,
            projects: patch.projects,
            models: patch.models,
            sessions: patch.sessions,
            currentSessionId: patch.currentSessionId ?? NullableUUIDWrapper(sessionId),
            messages: patch.messages,
            queuedRequests: patch.queuedRequests,
            streamingTexts: patch.streamingTexts,
            status: patch.status,
            statusText: patch.statusText,
            isAwaitingFirstModelOutput: patch.isAwaitingFirstModelOutput,
            isLoadingHistory: patch.isLoadingHistory,
            tokensUsed: patch.tokensUsed,
            tokensTotal: patch.tokensTotal,
            activeRunStartedAt: patch.activeRunStartedAt,
            isMirroringRemoteSession: patch.isMirroringRemoteSession,
            composer: patch.composer,
            capabilities: patch.capabilities
        )
    }
}

// MARK: - Stub controller (until mac-controller agent lands)

/// Minimal no-op conformance so this worktree compiles. mac-controller agent
/// replaces this with `ChatPanelController` conforming on the real class. The
/// stub is intentionally inert: methods are no-ops, snapshot is an empty draft.
@MainActor
final class StubPanelStateBroadcaster: PanelStateBroadcasting {
    let sessionId: UUID?
    private let snapshotSubject = PassthroughSubject<PanelStateSnapshot, Never>()
    private(set) var lastSnapshot: PanelStateSnapshot

    init(sessionId: UUID? = nil) {
        self.sessionId = sessionId
        self.lastSnapshot = Self.makeEmptySnapshot(sessionId: sessionId)
    }

    func currentSnapshot() -> PanelStateSnapshot { lastSnapshot }

    var snapshotPublisher: AnyPublisher<PanelStateSnapshot, Never> {
        snapshotSubject.eraseToAnyPublisher()
    }

    var patchPublisher: AnyPublisher<PanelStatePatch, Never>? { nil }

    func remoteFocusSession(_ id: UUID) {}
    func remoteNewDraftSession(projectId: UUID) -> UUID { UUID() }
    func remoteComposerSet(text: String) {}
    func remoteComposerSetCLI(_ cli: CLIType) {}
    func remoteComposerSetModel(_ modelID: String) {}
    func remoteComposerSetPermissionMode(_ mode: ChatPermissionMode) {}
    func remoteComposerSetReasoningEffort(_ effort: ChatReasoningEffort) {}
    func remoteComposerAttach(_ attachment: ChatMessageAttachment) {}
    func remoteComposerRemoveAttach(id: UUID) {}
    func remoteResolvedProjectForSend() -> ProjectItem? { nil }
    func remoteComposerSend(sessionMode: SessionMode?, resumeSessionID: String?, appendRuleText: String?) -> Bool { false }
    func remoteStop(startQueuedAfterStop: Bool) {}
    func remoteFlushQueue() {}
    func remoteInterruptAndStartNext() {}
    func remoteCancelQueued(requestId: UUID) {}
    func remoteEditQueued(requestId: UUID, text: String) {}
    func remoteRespondPermission(requestId: String, decision: ChatPermissionDecision) {}
    func remoteRespondInteractive(response: ChatInteractiveResponse) {}
    func remoteRequestSnapshot() {}
    func remoteRefreshCapabilities() {}

    static func makeEmptySnapshot(sessionId: UUID?) -> PanelStateSnapshot {
        PanelStateSnapshot(
            revision: 1,
            sessionId: sessionId,
            projects: [],
            models: [],
            sessions: [],
            currentSessionId: nil,
            messages: [],
            queuedRequests: [],
            streamingTexts: [],
            status: ChatRunStatus.idle.rawValue,
            statusText: "",
            isAwaitingFirstModelOutput: false,
            isLoadingHistory: false,
            tokensUsed: 0,
            tokensTotal: 0,
            activeRunStartedAt: nil,
            isMirroringRemoteSession: false,
            composer: PanelComposerDTO(
                text: "",
                cli: CLIType.claude.rawValue,
                modelID: "",
                contextModelID: nil,
                permissionMode: ChatPermissionMode.autoEdit.rawValue,
                reasoningEffort: ChatReasoningEffort.high.rawValue,
                attachments: [],
                isEnabled: false,
                placeholder: ""
            ),
            capabilities: []
        )
    }
}

/// Stub lookup used until mac-controller agent provides a real one via
/// `ChatRuntimeStore`. Vends a single shared `StubPanelStateBroadcaster`.
@MainActor
final class StubPanelControllerLookup: PanelControllerLookup {
    private let stub = StubPanelStateBroadcaster()

    func controller(for sessionId: UUID?) -> PanelStateBroadcasting? { stub }
    func allControllers() -> [PanelStateBroadcasting] { [stub] }
}
