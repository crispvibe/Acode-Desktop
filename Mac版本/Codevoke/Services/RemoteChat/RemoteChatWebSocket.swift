import CryptoKit
import Foundation
import ChatCore
import Network

struct RemoteChatWebSocketFrame {
    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    let opcode: Opcode
    let payload: Data
}

enum RemoteChatWebSocket {
    private static let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func isUpgradeRequest(_ request: RemoteChatHTTPRequest) -> Bool {
        request.headers["upgrade"]?.lowercased() == "websocket"
    }

    static func handshakeResponse(for request: RemoteChatHTTPRequest) -> RemoteChatHTTPResponse? {
        guard let key = request.headers["sec-websocket-key"] else { return nil }
        let accept = acceptKey(for: key)
        return RemoteChatHTTPResponse(
            statusCode: 101,
            reasonPhrase: "Switching Protocols",
            headers: [
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Accept": accept
            ],
            body: Data()
        )
    }

    static func encodeText(_ text: String) -> Data {
        encode(opcode: .text, payload: Data(text.utf8))
    }

    static func encodeClose() -> Data {
        encode(opcode: .close, payload: Data())
    }

    /// Audit A-P1: emit a Close frame carrying an RFC 6455 status code +
    /// reason so the iOS client can surface why the connection was dropped
    /// (e.g. `1009 Message Too Big`). RFC 6455 §5.5.1 specifies the payload
    /// as a 2-byte status code followed by optional UTF-8 reason.
    static func encodeClose(code: UInt16, reason: String) -> Data {
        var payload = Data()
        payload.append(UInt8((code >> 8) & 0xFF))
        payload.append(UInt8(code & 0xFF))
        if !reason.isEmpty, let reasonData = reason.data(using: .utf8) {
            payload.append(reasonData.prefix(123)) // RFC 6455 control frame body cap
        }
        return encode(opcode: .close, payload: payload)
    }

    static func encodePong(payload: Data) -> Data {
        encode(opcode: .pong, payload: payload)
    }

    static func decodeFrames(from buffer: inout Data) throws -> [RemoteChatWebSocketFrame] {
        var frames: [RemoteChatWebSocketFrame] = []
        while true {
            guard buffer.count >= 2 else { break }
            let first = buffer[buffer.startIndex]
            let second = buffer[buffer.index(after: buffer.startIndex)]
            let opcodeValue = first & 0x0F
            guard let opcode = RemoteChatWebSocketFrame.Opcode(rawValue: opcodeValue) else {
                throw RemoteChatWebSocketError.unsupportedFrame
            }
            let masked = (second & 0x80) != 0
            var length = Int(second & 0x7F)
            var headerLength = 2

            if length == 126 {
                guard buffer.count >= 4 else { break }
                let b2 = Int(buffer[buffer.index(buffer.startIndex, offsetBy: 2)])
                let b3 = Int(buffer[buffer.index(buffer.startIndex, offsetBy: 3)])
                length = (b2 << 8) | b3
                headerLength = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { break }
                var value: UInt64 = 0
                for offset in 2..<10 {
                    value = (value << 8) | UInt64(buffer[buffer.index(buffer.startIndex, offsetBy: offset)])
                }
                guard value <= UInt64(Int.max) else { throw RemoteChatWebSocketError.payloadTooLarge }
                length = Int(value)
                headerLength = 10
            }

            guard length <= RemoteRecoveryLimits.maximumTextFrameUTF8Bytes else { throw RemoteChatWebSocketError.payloadTooLarge }
            let maskLength = masked ? 4 : 0
            let frameLength = headerLength + maskLength + length
            guard buffer.count >= frameLength else { break }

            var payload = Data(buffer[buffer.index(buffer.startIndex, offsetBy: headerLength + maskLength)..<buffer.index(buffer.startIndex, offsetBy: frameLength)])
            if masked {
                let maskStart = buffer.index(buffer.startIndex, offsetBy: headerLength)
                let mask = (0..<4).map { buffer[buffer.index(maskStart, offsetBy: $0)] }
                for index in 0..<payload.count {
                    payload[index] ^= mask[index % 4]
                }
            }
            frames.append(RemoteChatWebSocketFrame(opcode: opcode, payload: payload))
            buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: frameLength))
        }
        return frames
    }

    private static func encode(opcode: RemoteChatWebSocketFrame.Opcode, payload: Data) -> Data {
        var data = Data()
        data.append(0x80 | opcode.rawValue)
        if payload.count < 126 {
            data.append(UInt8(payload.count))
        } else if payload.count <= UInt16.max {
            data.append(126)
            data.append(UInt8((payload.count >> 8) & 0xFF))
            data.append(UInt8(payload.count & 0xFF))
        } else {
            data.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }
        data.append(payload)
        return data
    }

    private static func acceptKey(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + magicGUID).utf8))
        return Data(digest).base64EncodedString()
    }
}

enum RemoteChatWebSocketError: Error {
    case unsupportedFrame
    case payloadTooLarge
}
