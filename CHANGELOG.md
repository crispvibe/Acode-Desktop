# CHANGELOG

## 0.3.0 · 开源化 + 纯局域网

发布日期：2026-09-20

### 架构变更

- **删除后端**：`后端/`（Go API + 信令 + 管理后台）整体移除，仓库不再依赖任何云端服务。
- **去认证**：账号登录、设备码、连接审批、transient token、Bearer 鉴权全部移除；同局域网任何设备可直接连入 host（`ws://host:18765/chat`）。
- **纯局域网直连**：隧道（tunnel）/ WebRTC / 信令中转链路全部删除；客户端通过子网 `/health` 扫描发现 host，支持手动输入 `host:port` 并记住上次连接。
- **开源化**：MIT License；清理已提交的 `node_modules`/`dist` 产物与个人标识（bundle id、签名证书、域名引用）。

### 各端

- macOS：`RemoteChatServer` 不再校验 token；移除账号/信令/LAN token 发布/隧道/WebRTC。
- iOS：移除登录门与云端 transport；`LanSubnetProbe.discoverHealthHosts` + 手动连接；`remote.*` 旧 UserDefaults 键自动清理。
- Android：同上；`RemoteChatConfig` 简化为 `host + port`；去掉 stream-webrtc-android / security-crypto 依赖。
- Windows：移除 `account/`、`signaling/`、`device/`、`remoteChat/` 与隧道/WebRTC responder；`RemoteHostServer` 无鉴权；设置页仅保留 LAN host 开关；`appId` → `com.codevoke.windows`。

## 0.2.0 · 局域网多端

**多端远程局域网优先连接与 Windows 客户端界面完善**

发布日期：2026-06-13

### 后端

- 新增 `POST /remote/devices/:deviceId/lan-token` 与 LAN 地址发布链路
- 同网判定增加 IPv4/IPv6 客户端 IP 归一化（`normalizeClientIPForLanMatch`）
- 连接接受时优先返回 `transport=lan` 与 `lan_endpoint` / `transient_token`
- 设备列表接口返回局域网端点信息
- 补充 `remote_test.go` 单测与 `003_remote_device_lan.sql` 迁移
- 新增 `scripts/deploy-acode-api.sh` 部署脚本

### macOS（Codevoke 宿主）

- 新增 `LanTokenPublisher` 周期性发布局域网地址与 transient token
- 新增 `LanNetworkAddress` 本机局域网 IP 探测
- `RemoteChatServerController` 支持多 token 校验（未过期均有效）
- `RemoteTunnelClient` 对齐 `lan_offer` 发送条件与 `bindLAN` 设置
- 设置页展示局域网发布状态与设备连接服务控制

### Android

- 连接顺序：刷新 device → WiFi 预 LAN → connect 等待审批 → 信令 LAN → attempt/device LAN → Tunnel → P2P
- 新增 `LanNetworkSelector`（WiFi 绑定与多 client 重试）
- 新增 `LanSubnetProbe`（子网 `/health` 扫描）
- 新增 `LanSignalingResolver`（15s 信令 `lan_request`/`lan_offer` 超时）
- 新增 `RemoteTunnelTransport` 跨网通道传输
- 设备列表显示「局域网可连接」与连接/请求连接按钮
- 局域网降级时展示 `lanFallbackNote` 提示

### iOS

- 新增 `LanNetworkSelector` / `LanSubnetProbe` 局域网探测
- `DeviceConnectViewModel` 对齐 Android 连接状态机（Tunnel 优先于 P2P）
- 连接前刷新 device、信令 LAN 解析、子网探测与 `lanFallbackNote`
- `DeviceListView` 副标题显示「局域网可连接」/「信令可请求」
- 本地化文案与 `RemoteUserFacingText` 传输方式标签更新

### Windows

- 新增 `DeviceConnectService` 出站连接状态机（LAN → 信令 → Tunnel 降级）
- `AccountClient` 扩展 `device` / `connect` / `connection` API
- IPC 与 preload 接入 `account-remote:connect-device`
- 新增 `AccountStatusCard` / `RemoteDeviceList` / `accountRemoteShared` 组件
- 设置页「设备连接」对齐 Mac 三节点流程图与 metric chips
- 登录后自动启动信令；启动时恢复会话并同步设备名
- 设备名跟随本机主机名（Windows `COMPUTERNAME` / 去除 `.local` 后缀）不再写死
- 顶栏 Logo 与项目选择分隔优化；窄屏隐藏重复文案
- 设备列表按平台显示图标（Android / Windows / macOS）
- 信令行、配置行、探测 CLI 按钮横向对齐与图标修复
- `activeConnection` 连接成功状态横幅

### 验收要点

- Mac 设置显示「局域网地址已发布：192.168.x.x:18765」
- 同 WiFi 连接后显示「已连接 · 局域网」
- 设备列表显示「局域网可连接」
- `POST .../lan-token` 返回 401（非 404）表示鉴权生效
