import Foundation
import ChatCore

/// JSON codec for the Remote VNC control frames carried by any transport.
///
/// Keeping encode/decode here prevents subtle wire-format drift between
/// transport implementations. It also keeps ChatViewModel transport-
/// agnostic: transports emit already-decoded envelopes/acks and accept typed
/// resume/command frames.
enum RemoteDateFormatters {
    /// ISO8601DateFormatter(.withInternetDateTime) 不接受毫秒小数（`.SSS`），
    /// Windows host 以 `Date.toISOString()` 输出毫秒，这里两种格式都容忍。
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

extension JSONDecoder.DateDecodingStrategy {
    static let iso8601Tolerant = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        if let date = RemoteDateFormatters.fractional.date(from: string)
            ?? RemoteDateFormatters.plain.date(from: string) {
            return date
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(string)")
    }
}

struct RemoteTransportFrameCodec {
    enum DecodedFrame: Equatable {
        case panelState(PanelStateEnvelope)
        case commandAck(CommandAck)
        case recoveryResponse(RemoteRecoveryResponse)
        case hello
        case ignored(type: String)
    }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601Tolerant
        self.decoder = decoder
    }

    func encodeResume(sessionId: UUID?, lastRevision: Int?) throws -> String {
        try encode(ResumeRequest(sessionId: sessionId, lastRevision: lastRevision))
    }

    func encodeCommand(_ command: Command) throws -> String {
        try encode(command)
    }

    func encodeRecoveryRequest(_ request: RemoteRecoveryRequest) throws -> String {
        try encode(request)
    }

    func decode(text: String) throws -> DecodedFrame {
        let payload = Data(text.utf8)
        guard
            let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let type = json["type"] as? String
        else {
            throw RemoteTransportFrameCodecError.missingType(preview: String(text.prefix(200)))
        }

        switch type {
        case RemoteVNCFrameType.panelState:
            return .panelState(try decoder.decode(PanelStateEnvelope.self, from: payload))
        case RemoteVNCFrameType.commandAck:
            return .commandAck(try decoder.decode(CommandAck.self, from: payload))
        case RemoteVNCFrameType.recoveryResponse:
            return .recoveryResponse(try decoder.decode(RemoteRecoveryResponse.self, from: payload))
        case "hello":
            return .hello
        default:
            return .ignored(type: type)
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RemoteTransportFrameCodecError.nonUTF8EncodedFrame
        }
        return text
    }
}

enum RemoteTransportFrameCodecError: LocalizedError {
    case missingType(preview: String)
    case nonUTF8EncodedFrame

    var errorDescription: String? {
        switch self {
        case .missingType(let preview):
            "Remote frame missing type: \(preview)"
        case .nonUTF8EncodedFrame:
            "Remote frame could not be encoded as UTF-8."
        }
    }
}
