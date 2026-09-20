import Foundation

/// GitHub Releases 上发现的可更新版本（iOS 端只提示并跳转发布页，
/// 未签名 IPA 无法在应用内自动安装）。
struct AppUpdateInfo: Equatable {
    /// 原始 tag，如 "v0.4.0"。
    let tag: String
    /// 归一化后的版本号（去 v 前缀），用于展示。
    let version: String
    /// release notes 原文（markdown）。
    let notes: String
    /// release 页面地址（Safari 打开）。
    let releasePageURL: URL
}

/// 语义化版本比较（纯函数）：去 v/V 前缀、忽略 +build 元数据、
/// 数字段逐段比较、缺段补 0；core 相同则带 prerelease 的版本更小，
/// prerelease 之间按 semver 规则（数字<字母串、段多者大）比较。
enum AppVersionCompare {
    static func compare(_ a: String, _ b: String) -> Int {
        let pa = parse(a)
        let pb = parse(b)
        let size = max(pa.core.count, pb.core.count)
        for i in 0..<size {
            let x = i < pa.core.count ? pa.core[i] : 0
            let y = i < pb.core.count ? pb.core[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return comparePrerelease(pa.prerelease, pb.prerelease)
    }

    /// remote 版本是否比 local 新。
    static func isNewer(remote: String, local: String) -> Bool {
        compare(remote, local) > 0
    }

    private static func parse(_ version: String) -> (core: [Int], prerelease: String?) {
        var s = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        var prerelease: String? = nil
        if let dash = s.firstIndex(of: "-") {
            prerelease = String(s[s.index(after: dash)...])
            s = String(s[..<dash])
        }
        let core = s.split(separator: ".", omittingEmptySubsequences: false).map { segment -> Int in
            let digits = segment.prefix(while: { $0.isNumber })
            return Int(digits) ?? 0
        }
        return (core, prerelease?.isEmpty == true ? nil : prerelease)
    }

    private static func comparePrerelease(_ a: String?, _ b: String?) -> Int {
        switch (a, b) {
        case (nil, nil): return 0
        case (nil, _): return 1 // 正式版 > 预发布版
        case (_, nil): return -1
        case (let a?, let b?):
            let ai = a.split(separator: ".", omittingEmptySubsequences: false)
            let bi = b.split(separator: ".", omittingEmptySubsequences: false)
            let size = max(ai.count, bi.count)
            for i in 0..<size {
                guard i < ai.count else { return -1 }
                guard i < bi.count else { return 1 }
                let x = String(ai[i])
                let y = String(bi[i])
                let xn = Int(x)
                let yn = Int(y)
                let c: Int
                if let xn, let yn {
                    c = xn == yn ? 0 : (xn < yn ? -1 : 1)
                } else if xn != nil {
                    c = -1 // semver：数字标识符 < 字母数字标识符
                } else if yn != nil {
                    c = 1
                } else {
                    c = x == y ? 0 : (x < y ? -1 : 1)
                }
                if c != 0 { return c }
            }
            return 0
        }
    }
}

/**
 * GitHub Releases 版本检查（无服务器，纯 GitHub）。
 * 网络失败一律静默返回，不打扰用户；手动检查通过 statusText 给设置页反馈。
 */
@MainActor
final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()

    /// 发现的新版本；nil = 无更新或未检查。
    @Published private(set) var availableUpdate: AppUpdateInfo?
    @Published private(set) var isChecking = false
    /// 手动检查的结果提示（"已是最新版本"/"检查失败"），显示在设置页行副标题。
    @Published private(set) var statusText: String?

    private static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/crispvibe/Acode-Desktop/releases/latest")!
    static let releasePageURL =
        URL(string: "https://github.com/crispvibe/Acode-Desktop/releases/latest")!

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    private init() {}

    private var currentVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return version?.isEmpty == false ? version! : "0.0.0"
    }

    /// manual=false 为启动静默检查：失败/无新版都不产生 UI；manual=true 结果写 statusText。
    func check(manual: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        statusText = nil
        defer { isChecking = false }
        do {
            guard let latest = try await fetchLatestRelease() else {
                if manual { statusText = L10n.string("暂无可用更新。") }
                return
            }
            if AppVersionCompare.isNewer(remote: latest.tag, local: currentVersion) {
                availableUpdate = latest
                statusText = nil
            } else if manual {
                statusText = L10n.string("已是最新版本。")
            }
        } catch {
            if manual { statusText = L10n.string("检查更新失败，请稍后重试。") }
        }
    }

    /// GET releases/latest；draft/prerelease 不算可更新版本，无 release 返回 nil。
    private func fetchLatestRelease() async throws -> AppUpdateInfo? {
        var request = URLRequest(url: Self.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("acode-ios", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            return nil
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if (json["draft"] as? Bool) == true || (json["prerelease"] as? Bool) == true {
            return nil
        }
        guard let tag = (json["tag_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tag.isEmpty else {
            return nil
        }
        let page = (json["html_url"] as? String).flatMap { URL(string: $0) } ?? Self.releasePageURL
        var version = tag
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        return AppUpdateInfo(
            tag: tag,
            version: version,
            notes: (json["body"] as? String) ?? "",
            releasePageURL: page
        )
    }
}
