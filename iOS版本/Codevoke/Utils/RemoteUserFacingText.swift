import Foundation

enum RemoteUserFacingText {
    static func reason(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        switch normalize(rawValue) {
        case "manual_rejected", "user_rejected", "rejected":
            return L10n.string("电脑端已拒绝本次连接。")
        case "device_offline":
            return L10n.string("目标设备当前离线，请打开电脑端 acode 后重试。")
        case "device_disabled", "remote_disabled":
            return L10n.string("目标设备未开启远程连接。")
        case "lan_unavailable":
            return L10n.string("目标设备暂时无法建立直连，请确认电脑端在线且与手机在同一 Wi-Fi。")
        default:
            return nil
        }
    }

    static func apiError(_ rawMessage: String, fallback: String) -> String {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let localizedFallback = L10n.string(fallback)
        guard !message.isEmpty else { return localizedFallback }
        if let reasonMessage = reason(message) {
            return reasonMessage
        }
        switch normalize(message) {
        case "record not found":
            return localizedFallback
        case "network connection lost", "the network connection was lost.":
            return L10n.string("网络连接已中断，请稍后重试。")
        case "timed out", "the request timed out.":
            return L10n.string("请求超时，请检查网络后重试。")
        default:
            return containsLikelyEnglish(message) ? localizedFallback : L10n.string(message)
        }
    }

    private static func normalize(_ rawValue: String?) -> String {
        rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func containsLikelyEnglish(_ text: String) -> Bool {
        text.range(of: "[A-Za-z_]{3,}", options: .regularExpression) != nil
    }
}
