import SwiftUI

struct AppRootView: View {
    var body: some View {
        DeviceListView()
            // 启动静默检查更新一次：失败不打扰，有新版在设置页显示横幅。
            .task { await AppUpdateChecker.shared.check(manual: false) }
    }
}
