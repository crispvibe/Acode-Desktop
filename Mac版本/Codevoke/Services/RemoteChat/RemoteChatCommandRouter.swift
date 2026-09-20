// RemoteChatCommandRouter.swift
//
// Translates `Command` frames (spec §4.5) into `PanelStateBroadcasting`
// method calls. The router is intentionally dumb: it validates required args,
// hands them to the controller, and emits a `CommandAck` for every command.
// All command-level state (`focusedSessionID`) lives on the WS connection (the
// server holds the per-connection focus map and calls `route` with it).
//
// Per spec §4.5 there are 18 ops; this file dispatches them all.

import Foundation
import ChatCore
import os

@MainActor
final class RemoteChatCommandRouter {
    private let broadcaster: PanelStateBroadcaster
    private let log = Logger(subsystem: RemoteChatLog.subsystem, category: "RemoteChatCommandRouter")

    /// Audit A-P0-1: server-side commandId idempotency cache.
    ///
    /// iOS `replayPendingCommands` re-sends every un-acked command with the
    /// same `commandId` after a reconnect. Without dedup the server would
    /// execute the op twice (creating a second `newDraftSession`, sending the
    /// same `composerSend` twice, etc). We keep a bounded LRU keyed by
    /// `commandId` with a short TTL so that:
    ///   - first occurrence -> route + cache the resulting `Dispatch`
    ///   - duplicate within TTL -> short-circuit and re-emit the cached ack
    ///
    /// 60s TTL is more than enough for replay-on-reconnect; 1024 cap bounds
    /// memory growth even under malicious flooding.
    private struct CachedDispatch {
        let dispatch: Dispatch
        let cachedAt: Date
    }
    private static let dedupTTL: TimeInterval = 60
    private static let dedupCapacity = 1024
    private var dedupCache: [UUID: CachedDispatch] = [:]
    private var dedupOrder: [UUID] = []

    init(broadcaster: PanelStateBroadcaster) {
        self.broadcaster = broadcaster
    }

    /// Dispatch a command on behalf of a connection focused at `focusedSessionID`.
    /// Returns the ack to send back to the client. `shouldUpdateFocusedSessionID`
    /// controls whether the connection focus mutates, including clearing to draft.
    func route(_ command: Command, focusedSessionID: UUID?) -> Dispatch {
        if let cached = cachedDispatchIfFresh(for: command.commandId, op: command.op) {
            return cached
        }
        let dispatch = dispatchUncached(command, focusedSessionID: focusedSessionID)
        rememberDispatch(commandId: command.commandId, dispatch: dispatch)
        return dispatch
    }

    private func cachedDispatchIfFresh(for commandId: UUID, op: Command.Op) -> Dispatch? {
        guard let entry = dedupCache[commandId] else { return nil }
        if Date().timeIntervalSince(entry.cachedAt) > Self.dedupTTL {
            dedupCache.removeValue(forKey: commandId)
            if let idx = dedupOrder.firstIndex(of: commandId) {
                dedupOrder.remove(at: idx)
            }
            return nil
        }
        // Replay 默认只回原始 ack,不重放副作用;但 focus 类 op 是幂等的"连接状态同步"
        // (server 端把这条连接的 focusedSessionID 设成 ack.sessionId),重连后新连接
        // 必须再次应用这一步,否则 server 看到的 focus 与 iOS 期望的 focus 错位,
        // 后续 envelope 过滤 / 上下文校验全错乱。同时也需要重新 push 一次 snapshot,
        // 让新连接拿到当前 focused session 的最新状态。
        let isFocusOp: Bool = {
            switch op {
            case .focusSession, .focusProject, .newDraftSession: return true
            default: return false
            }
        }()
        if isFocusOp, entry.dispatch.ack.status == .ok, let targetSessionId = entry.dispatch.ack.sessionId {
            return Dispatch(
                ack: entry.dispatch.ack,
                newFocusedSessionID: targetSessionId,
                shouldUpdateFocusedSessionID: true,
                shouldPushSnapshotForFocus: true
            )
        }
        return Dispatch(
            ack: entry.dispatch.ack,
            newFocusedSessionID: nil,
            shouldUpdateFocusedSessionID: false,
            shouldPushSnapshotForFocus: false
        )
    }

    private func rememberDispatch(commandId: UUID, dispatch: Dispatch) {
        if dedupCache[commandId] == nil {
            dedupOrder.append(commandId)
        }
        dedupCache[commandId] = CachedDispatch(dispatch: dispatch, cachedAt: Date())
        while dedupOrder.count > Self.dedupCapacity {
            let evicted = dedupOrder.removeFirst()
            dedupCache.removeValue(forKey: evicted)
        }
    }

    private func dispatchUncached(_ command: Command, focusedSessionID: UUID?) -> Dispatch {
        let scope = command.sessionId ?? focusedSessionID
        switch command.op {
        case .focusSession:
            guard let target = command.args.sessionId ?? command.sessionId else {
                log.warning("focusSession rejected reason=missingSessionId commandId=\(command.commandId.uuidString, privacy: .public)")
                return .ack(reject(command, reason: "focusSession requires sessionId"))
            }
            log.info("focusSession requested sessionId=\(target.uuidString, privacy: .public) commandId=\(command.commandId.uuidString, privacy: .public)")
            guard let _ = broadcaster.focusController(for: target) else {
                log.warning("focusSession rejected reason=sessionNotFound sessionId=\(target.uuidString, privacy: .public) commandId=\(command.commandId.uuidString, privacy: .public)")
                return .ack(reject(command, reason: "session not found"))
            }
            log.info("focusSession accepted sessionId=\(target.uuidString, privacy: .public) commandId=\(command.commandId.uuidString, privacy: .public)")
            return Dispatch(
                ack: ok(command, sessionId: target),
                newFocusedSessionID: target,
                shouldUpdateFocusedSessionID: true,
                shouldPushSnapshotForFocus: true
            )

        case .focusProject:
            guard let projectId = command.args.projectId else {
                log.warning("focusProject rejected reason=missingProjectId commandId=\(command.commandId.uuidString, privacy: .public)")
                return .ack(reject(command, reason: "focusProject requires projectId"))
            }
            log.info("focusProject requested projectId=\(projectId.uuidString, privacy: .public) commandId=\(command.commandId.uuidString, privacy: .public)")
            guard let result = broadcaster.focusProject(projectId) else {
                log.warning("focusProject rejected reason=projectNotFound projectId=\(projectId.uuidString, privacy: .public) commandId=\(command.commandId.uuidString, privacy: .public)")
                return .ack(reject(command, reason: "project not found"))
            }
            let resolvedProject = result.controller.remoteResolvedProjectForSend()
            log.info("focusProject accepted commandId=\(command.commandId.uuidString, privacy: .public) requestedProjectId=\(projectId.uuidString, privacy: .public) resolvedProjectPath=\(resolvedProject?.path ?? "nil", privacy: .public) controllerCWD=\(self.controllerCWD(result.controller) ?? "nil", privacy: .public) sessionId=\(result.sessionId?.uuidString ?? "draft", privacy: .public)")
            return Dispatch(
                ack: ok(command, sessionId: result.sessionId),
                newFocusedSessionID: result.sessionId,
                shouldUpdateFocusedSessionID: true,
                shouldPushSnapshotForFocus: true
            )

        case .newDraftSession:
            guard let projectId = command.args.projectId else {
                return .ack(reject(command, reason: "newDraftSession requires projectId"))
            }
            guard let result = broadcaster.createDraft(projectId: projectId) else {
                return .ack(reject(command, reason: "project not found"))
            }
            let controller = result.controller
            let newID = controller.remoteNewDraftSession(projectId: projectId)
            broadcaster.registerDraftAlias(newID, controller: controller)
            return Dispatch(
                ack: ok(command, sessionId: newID),
                newFocusedSessionID: newID,
                shouldUpdateFocusedSessionID: true,
                shouldPushSnapshotForFocus: true
            )

        case .composerSet:
            guard let text = command.args.text else {
                return .ack(reject(command, reason: "composerSet requires text"))
            }
            guard let controller = broadcaster.lookupController(for: scope) else {
                return .ack(reject(command, reason: "session not focused"))
            }
            if let dispatch = rejectIfExpectedContextChanged(command, scope: scope, controller: controller) { return dispatch }
            controller.remoteComposerSet(text: text)
            return .ack(ok(command, sessionId: scope))

        case .composerSetCLI:
            guard let raw = command.args.cli, let cli = CLIType(rawValue: raw) else {
                return .ack(reject(command, reason: "composerSetCLI requires valid cli"))
            }
            guard let controller = broadcaster.lookupController(for: scope) else {
                return .ack(reject(command, reason: "session not focused"))
            }
            if let dispatch = rejectIfExpectedContextChanged(command, scope: scope, controller: controller) { return dispatch }
            controller.remoteComposerSetCLI(cli.visibleValue)
            return .ack(ok(command, sessionId: scope))

        case .composerSetModel:
            guard let modelID = command.args.modelID else {
                return .ack(reject(command, reason: "composerSetModel requires modelID"))
            }
            let requestedCLI: CLIType?
            if let rawCLI = command.args.cli {
                guard let cli = CLIType(rawValue: rawCLI)?.visibleValue else {
                    return .ack(reject(command, reason: "composerSetModel requires valid cli when cli is provided"))
                }
                requestedCLI = cli
            } else {
                requestedCLI = nil
            }
            guard let controller = broadcaster.lookupController(for: scope) else {
                return .ack(reject(command, reason: "session not focused"))
            }
            if let dispatch = rejectIfExpectedContextChanged(command, scope: scope, controller: controller) { return dispatch }
            if let requestedCLI {
                controller.remoteComposerSetCLI(requestedCLI)
            }
            controller.remoteComposerSetModel(modelID)
            return .ack(ok(command, sessionId: scope))

        case .composerSetPermissionMode:
            guard let raw = command.args.permissionMode, let mode = ChatPermissionMode(rawValue: raw) else {
                return .ack(reject(command, reason: "composerSetPermissionMode requires valid permissionMode"))
            }
            guard let controller = broadcaster.lookupController(for: scope) else {
                return .ack(reject(command, reason: "session not focused"))
            }
            if let dispatch = rejectIfExpectedContextChanged(command, scope: scope, controller: controller) { return dispatch }
            controller.remoteComposerSetPermissionMode(mode)
            return .ack(ok(command, sessionId: scope))

        case .composerSetReasoningEffort:
            guard let raw = command.args.reasoningEffort, let effort = ChatReasoningEffort(rawValue: raw) else {
                return .ack(reject(command, reason: "composerSetReasoningEffort requires valid reasoningEffort"))
            }
            guard let controller = broadcaster.lookupController(for: scope) else {
                return .ack(reject(command, reason: "session not focused"))
            }
            if let dispatch = rejectIfExpectedContextChanged(command, scope: scope, controller: controller) { return dispatch }
            controller.remoteComposerSetReasoningEffort(effort)
            return .ack(ok(command, sessionId: scope))

        case .composerAttach:
            guard let attachment = command.args.attachment else {
                return .ack(reject(command, reason: "composerAttach requires attachment"))
            }
            guard let controller = broadcaster.lookupController(for: scope) else {
                return .ack(reject(command, reason: "session not focused"))
            }
            if let dispatch = rejectIfExpectedContextChanged(command, scope: scope, controller: controller) { return dispatch }
            controller.remoteComposerAttach(attachment)
            return .ack(ok(command, sessionId: scope))

        case .composerRemoveAttach:
            guard let attachmentId = command.args.attachmentId else {
                return .ack(reject(command, reason: "composerRemoveAttach requires attachmentId"))
            }
            guard let controller = broadcaster.lookupController(for: scope) else {
                return .ack(reject(command, reason: "session not focused"))
            }
            if let dispatch = rejectIfExpectedContextChanged(command, scope: scope, controller: controller) { return dispatch }
            controller.remoteComposerRemoveAttach(id: attachmentId)
            return .ack(ok(command, sessionId: scope))

        case .composerSend:
            guard let controller = broadcaster.lookupController(for: scope) else {
                return .ack(reject(command, reason: "session not focused"))
            }
            if let dispatch = rejectIfExpectedContextChanged(command, scope: scope, controller: controller) { return dispatch }
            let resolvedProject = controller.remoteResolvedProjectForSend()
            log.info("composerSend requested commandId=\(command.commandId.uuidString, privacy: .public) requestedProjectId=\(resolvedProject?.id.uuidString ?? "nil", privacy: .public) resolvedProjectPath=\(resolvedProject?.path ?? "nil", privacy: .public) controllerCWD=\(self.controllerCWD(controller) ?? "nil", privacy: .public)")
            let sessionMode = command.args.sessionMode.flatMap(SessionMode.init(rawValue:))
            let accepted = controller.remoteComposerSend(
                sessionMode: sessionMode,
                resumeSessionID: command.args.resumeSessionID,
                appendRuleText: command.args.appendRuleText
            )
            if accepted {
                let resolvedSessionId = controller.currentSnapshot().currentSessionId ?? scope
                log.info("composerSend accepted commandId=\(command.commandId.uuidString, privacy: .public) requestedProjectId=\(resolvedProject?.id.uuidString ?? "nil", privacy: .public) resolvedProjectPath=\(resolvedProject?.path ?? "nil", privacy: .public) controllerCWD=\(self.controllerCWD(controller) ?? "nil", privacy: .public) sessionId=\(resolvedSessionId?.uuidString ?? "draft", privacy: .public)")
                return Dispatch(
                    ack: ok(command, sessionId: resolvedSessionId),
                    newFocusedSessionID: resolvedSessionId,
                    shouldUpdateFocusedSessionID: resolvedSessionId != nil,
                    shouldPushSnapshotForFocus: resolvedSessionId != nil
                )
            }
            log.warning("composerSend rejected commandId=\(command.commandId.uuidString, privacy: .public) requestedProjectId=\(resolvedProject?.id.uuidString ?? "nil", privacy: .public) resolvedProjectPath=\(resolvedProject?.path ?? "nil", privacy: .public) controllerCWD=\(self.controllerCWD(controller) ?? "nil", privacy: .public)")
            return .ack(reject(command, reason: "send rejected (composer empty or capability check failed)"))

        case .stop:
            guard let controller = broadcaster.lookupController(for: scope) else {
                return .ack(reject(command, reason: "session not focused"))
            }
            if let dispatch = rejectIfExpectedContextChanged(command, scope: scope, controller: controller) { return dispatch }
            controller.remoteStop(startQueuedAfterStop: command.args.startQueuedAfterStop ?? false)
            return .ack(ok(command, sessionId: scope))

        case .flushQueue:
            guard let controller = broadcaster.lookupController(for: scope) else {
                return .ack(reject(command, reason: "session not focused"))
            }
            if let dispatch = rejectIfExpectedContextChanged(command, scope: scope, controller: controller) { return dispatch }
            controller.remoteFlushQueue()
            return .ack(ok(command, sessionId: scope))

        case .interruptAndStartNext:
            guard let controller = broadcaster.lookupController(for: scope) else {
                return .ack(reject(command, reason: "session not focused"))
            }
            if let dispatch = rejectIfExpectedContextChanged(command, scope: scope, controller: controller) { return dispatch }
            controller.remoteInterruptAndStartNext()
            return .ack(ok(command, sessionId: scope))

        case .cancelQueued:
            guard let rawRequestId = command.args.requestId,
                  let requestUUID = UUID(uuidString: rawRequestId) else {
                return .ack(reject(command, reason: "cancelQueued requires requestId"))
            }
            guard let controller = broadcaster.lookupController(for: scope) else {
                return .ack(reject(command, reason: "session not focused"))
            }
            if let dispatch = rejectIfExpectedContextChanged(command, scope: scope, controller: controller) { return dispatch }
            controller.remoteCancelQueued(requestId: requestUUID)
            return .ack(ok(command, sessionId: scope))

        case .editQueued:
            guard let rawRequestId = command.args.requestId,
                  let requestUUID = UUID(uuidString: rawRequestId),
                  let text = command.args.text else {
                return .ack(reject(command, reason: "editQueued requires requestId and text"))
            }
            guard let controller = broadcaster.lookupController(for: scope) else {
                return .ack(reject(command, reason: "session not focused"))
            }
            if let dispatch = rejectIfExpectedContextChanged(command, scope: scope, controller: controller) { return dispatch }
            controller.remoteEditQueued(requestId: requestUUID, text: text)
            return .ack(ok(command, sessionId: scope))

        case .respondPermission:
            guard let requestId = command.args.permissionRequestId,
                  let rawDecision = command.args.decision,
                  let decision = ChatPermissionDecision(rawValue: rawDecision) else {
                return .ack(reject(command, reason: "respondPermission requires permissionRequestId + decision"))
            }
            guard let controller = broadcaster.lookupController(for: scope) else {
                return .ack(reject(command, reason: "session not focused"))
            }
            if let dispatch = rejectIfExpectedContextChanged(command, scope: scope, controller: controller) { return dispatch }
            controller.remoteRespondPermission(requestId: requestId, decision: decision)
            return .ack(ok(command, sessionId: scope))

        case .respondInteractive:
            guard let response = command.args.interactiveResponse else {
                return .ack(reject(command, reason: "respondInteractive requires interactiveResponse"))
            }
            guard let controller = broadcaster.lookupController(for: scope) else {
                return .ack(reject(command, reason: "session not focused"))
            }
            if let dispatch = rejectIfExpectedContextChanged(command, scope: scope, controller: controller) { return dispatch }
            controller.remoteRespondInteractive(response: response)
            return .ack(ok(command, sessionId: scope))

        case .requestSnapshot:
            guard let controller = broadcaster.lookupController(for: scope) else {
                log.warning("requestSnapshot fallback reason=sessionNotFocused sessionId=\(scope?.uuidString ?? "nil", privacy: .public) commandId=\(command.commandId.uuidString, privacy: .public)")
                return Dispatch(
                    ack: ok(command, sessionId: nil),
                    newFocusedSessionID: nil,
                    shouldUpdateFocusedSessionID: true,
                    shouldPushSnapshotForFocus: true
                )
            }
            controller.remoteRequestSnapshot()
            return Dispatch(
                ack: ok(command, sessionId: scope),
                newFocusedSessionID: nil,
                shouldUpdateFocusedSessionID: false,
                shouldPushSnapshotForFocus: true
            )

        case .refreshCapabilities:
            guard let controller = broadcaster.lookupController(for: scope) else {
                return .ack(reject(command, reason: "session not focused"))
            }
            controller.remoteRefreshCapabilities()
            return .ack(ok(command, sessionId: scope))
        }
    }

    private func controllerCWD(_ controller: PanelStateBroadcasting) -> String? {
        let snapshot = controller.currentSnapshot()
        guard let currentSessionId = snapshot.currentSessionId else { return nil }
        return snapshot.sessions.first(where: { $0.id == currentSessionId })?.projectPath
    }

    private func rejectIfExpectedContextChanged(_ command: Command, scope: UUID?, controller: PanelStateBroadcasting) -> Dispatch? {
        if let expectedSessionId = command.args.expectedSessionId, expectedSessionId != scope {
            log.warning("command rejected reason=sessionMismatch op=\(command.op.rawValue, privacy: .public) expected=\(expectedSessionId.uuidString, privacy: .public) actual=\(scope?.uuidString ?? "draft", privacy: .public)")
            return contextMismatchDispatch(command, reason: "session focus changed")
        }
        guard let expectedProjectId = command.args.expectedProjectId else { return nil }
        let snapshot = controller.currentSnapshot()
        let scopedProjectId = scope.flatMap { sessionId in
            snapshot.sessions.first(where: { $0.id == sessionId })?.projectId
        }
        let actualProjectId = scopedProjectId ?? controller.remoteResolvedProjectForSend()?.id
        guard actualProjectId == expectedProjectId else {
            log.warning("command rejected reason=projectMismatch op=\(command.op.rawValue, privacy: .public) expected=\(expectedProjectId.uuidString, privacy: .public) actual=\(actualProjectId?.uuidString ?? "nil", privacy: .public)")
            return contextMismatchDispatch(command, reason: "project focus changed")
        }
        return nil
    }

    private func contextMismatchDispatch(_ command: Command, reason: String) -> Dispatch {
        Dispatch(
            ack: reject(command, reason: reason),
            newFocusedSessionID: nil,
            shouldUpdateFocusedSessionID: false,
            shouldPushSnapshotForFocus: true
        )
    }

    // MARK: - Result envelope

    struct Dispatch {
        let ack: CommandAck
        /// Value the WS connection should adopt as focused session id.
        let newFocusedSessionID: UUID?
        /// True when `newFocusedSessionID` should be applied, including clearing focus to nil.
        let shouldUpdateFocusedSessionID: Bool
        /// Server should send a fresh snapshot to the issuing connection once
        /// the focus change settles.
        let shouldPushSnapshotForFocus: Bool

        static func ack(_ ack: CommandAck) -> Dispatch {
            Dispatch(ack: ack, newFocusedSessionID: nil, shouldUpdateFocusedSessionID: false, shouldPushSnapshotForFocus: false)
        }
    }

    // MARK: - Ack helpers

    private func ok(_ command: Command, sessionId: UUID? = nil) -> CommandAck {
        CommandAck(commandId: command.commandId, status: .ok, message: nil, sessionId: sessionId)
    }

    private func reject(_ command: Command, reason: String) -> CommandAck {
        CommandAck(commandId: command.commandId, status: .rejected, message: reason, sessionId: command.sessionId)
    }
}
