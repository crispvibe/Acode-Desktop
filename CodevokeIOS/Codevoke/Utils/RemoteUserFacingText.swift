import Foundation

enum RemoteUserFacingText {
    static func reason(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        switch normalize(rawValue) {
        case "trial_daily_limit_exceeded":
            return L10n.string("今日远程连接体验时长已用完，请明天再试或确认电脑端服务状态。")
        case "entitlement_required":
            return L10n.string("当前账号没有远程连接权限，请确认电脑端服务状态后再试。")
        case "remote_transport_required":
            return L10n.string("当前网络需要远程连接，但连接通道还没准备好，请稍后重试。")
        case "manual_rejected", "user_rejected", "rejected":
            return L10n.string("电脑端已拒绝本次连接。")
        case "device_offline":
            return L10n.string("目标设备当前离线，请打开电脑端 acode 后重试。")
        case "device_disabled":
            return L10n.string("目标设备已关闭远程连接。")
        case "grant_required":
            return L10n.string("当前账号还没有这台设备的连接授权。")
        case "remote_disabled":
            return L10n.string("目标设备未开启远程连接。")
        case "lan_unavailable":
            return L10n.string("目标设备暂时无法建立直连，请确认电脑端已开启局域网或公网端口映射。")
        case "token_expired":
            return L10n.string("连接凭证已过期，请刷新设备后重试。")
        default:
            return nil
        }
    }

    static func status(_ rawValue: String?) -> String {
        switch normalize(rawValue) {
        case "pending":
            return L10n.string("等待电脑端确认。")
        case "accepted":
            return L10n.string("连接已允许。")
        case "rejected":
            return L10n.string("连接已被拒绝。")
        case "canceled":
            return L10n.string("连接已取消。")
        case "expired":
            return L10n.string("连接请求已过期。")
        default:
            return L10n.string("连接状态未知。")
        }
    }

    static func transport(_ rawValue: String?) -> String {
        switch normalize(rawValue) {
        case "lan":
            return L10n.string("局域网直连")
        case "p2p":
            return L10n.string("远程直连")
        case "public", "port_forward":
            return L10n.string("公网端口直连")
        case "turn", "tunnel":
            return L10n.string("跨网通道")
        case "":
            return L10n.string("未建立")
        default:
            return L10n.string("未知连接方式")
        }
    }

    static func diagnostics(connectionId: Int?, transport: String?, reason: String?) -> String? {
        guard connectionId != nil || transport != nil || reason != nil else { return nil }
        var parts: [String] = []
        if let connectionId {
            parts.append(L10n.format("连接编号：%d", connectionId))
        }
        parts.append(L10n.format("连接方式：%@", Self.transport(transport)))
        if let reasonMessage = Self.reason(reason) {
            parts.append(L10n.format("原因：%@", reasonMessage))
        }
        return parts.joined(separator: "\n")
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
        case "unauthorized", "token is expired", "invalid token":
            return L10n.string("登录状态已失效，请重新登录。")
        case "forbidden":
            return L10n.string("当前账号没有权限执行此操作。")
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
