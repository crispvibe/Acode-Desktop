import Foundation
import ChatCore

/// Common client transport used by ChatViewModel for VNC JSON frames.
///
/// The LAN WebSocket path is the only transport today. The callbacks
/// intentionally mirror RemoteWebSocketClient so UI, reconnect, resume/replay,
/// ack handling and FIFO send behavior stay unchanged if transports evolve.
@MainActor
protocol RemoteTransport: AnyObject {
    var isConnected: Bool { get }
    var canSendFrames: Bool { get }

    var onConnect: (() -> Void)? { get set }
    var onEnvelope: ((PanelStateEnvelope) -> Void)? { get set }
    var onAck: ((CommandAck) -> Void)? { get set }
    var onRecoveryResponse: ((RemoteRecoveryResponse) -> Void)? { get set }
    var onDecodeFailure: ((String) -> Void)? { get set }
    var onDisconnect: ((Error?) -> Void)? { get set }

    func connect() throws
    func disconnect()
    func sendResume(sessionId: UUID?, lastRevision: Int?) async throws
    func sendCommand(_ command: Command) async throws
    func sendRecoveryRequest(_ request: RemoteRecoveryRequest) async throws
}
