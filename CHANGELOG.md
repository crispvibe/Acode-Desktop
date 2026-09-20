# CHANGELOG

## 未发布

- **新 CLI**：接入 DeepSeek Harness（`dsh`，第 10 家）——走官方 ACP profile（JSON-RPC stdio），流式增量、权限请求回写、会话 resume/list 全支持；initialize 前崩溃自动降级 headless 一次性模式；全局规则对应 `~/.dsh/AGENTS.md`。实测协议握手/会话/配置通道全通（对话回合需用户自配 DEEPSEEK_API_KEY）。
- **全局规则**：macOS/Windows 全局提示词从 Claude/Codex 两家扩到全部 10 家 CLI——按各家真实指令文件写入（Claude `~/.claude/CLAUDE.md`、Codex `~/.codex/AGENTS.md`、Cursor `~/.cursor/rules/acode.mdc`（自动补 alwaysApply frontmatter）、Gemini/Antigravity `~/.gemini/GEMINI.md`、Qwen `~/.qwen/QWEN.md`、Copilot `~/.copilot/copilot-instructions.md`、Kimi `~/.kimi-code/AGENTS.md`、Kiro `~/.kiro/steering/AGENTS.md`、DeepSeek `~/.dsh/AGENTS.md`）；UI 改下拉选择器、按目标单独保存、原子写盘，旧设置向后兼容。
- **移动端稳定性审计修复**：iOS/Android 连接代际防护（旧 transport/listener 回调不再污染新连接）、iOS pong 心跳看门狗判半死连接、patch 增加 sessionId 归属校验、per-session 快照缓存、pending focus 门禁防迟到快照闪回旧会话、Android ON_STOP 后台断连+回前台恢复、附件上传前置大小拦截+有界读取（防 OOM）、pendingCommands 上限保护。
- **文档**：README / README_EN 排版与文案重设计——截图改为桌面大图在上、两张手机截图并排在下；文案精简，突出免费开源；下载区改为按架构分包（macOS arm64/x64 DMG，Windows x64/arm64 安装包与便携版）；QQ 群补充群号 1076321843。
- **文档**：README / README_EN 新增「下载」区块——macOS / Windows（安装包 + 便携版）/ Android / iOS 四端 GitHub Releases 最新版直达链接（iOS 标注未签名 IPA 需 TrollStore/自签）；「纯局域网」表述更新为「局域网 + 跨网直连（IPv6 / 端口映射 + 扫码配对）」，安全提示改为 wss + 配对 token 鉴权说明，原「已知缺口：跨网远程」章节替换为「跨网直连」能力说明。

## 0.4.0 · acode 收尾整理

发布日期：2026-09-20

- **目录中文化**：`Mac版本/`（macOS host）、`Windows版本/`（Electron host）、`iOS版本/`、`安卓版本/`、`共享代码/`（SwiftPM ChatCore/ChatUI）、`文档/`、`脚本/`、`设计图/`。
- **品牌统一**：补齐遗漏的用户可见 Codevoke 文案为 acode（iOS/Android 关于页、macOS 权限弹窗与提示、/health 服务名）。
- **许可变更**：MIT → PolyForm Noncommercial 1.0.0，仅限个人非商业使用，禁止商用；四端"关于"页加入版权与许可说明。
- **清理**：删除旧账号体系相关文档与设计图（登录/注册设计图、三份旧体系审计报告、Windows 交接文档、progress.txt）；删除官网设计稿与账号时代设备列表设计图；清理 iOS 本地化表中 130+ 条登录/注册/账号/设备码/信令/TURN 死文案，移除 `RemoteUserFacingText` 中已死的连接审批/权益映射方法与 `codevokeAuthGlass*` 死代码、Android `AuthGlass*` 死 token；脚本残留旧名统一为 acode。
- **仓库**：更名为 `crispvibe/Acode-Desktop`，远端仅保留 `main` 单一分支。
- **聊天体验修复**：流式卡顿（macOS 结构指纹误含文本长度→每 flush 全量重建；Windows 逐 token set+全量序列化→90ms 合帧；移动端 WS 解码占主线程+每 patch 重组→外观字段合并发布）；滚动抖动（程序化回波吞用户滚动/动画互打→近底阈值即时吸附）；工具卡片假按钮（stale waiting 卡无人清理、IPC ack 被 void 恒真→真实 ack 翻转+不支持交互的 CLI 禁用按钮）。
- **跨网直连（WAN）**：四端实现零第三方直连——自签 ECDSA TLS（wss）+ 配对 token（Bearer 鉴权+限流封禁）+ SPKI-SHA256 证书指纹绑定；host 端 NAT-PMP/UPnP 端口映射 + 全球 IPv6 枚举 + CGNAT 自检 + 诊断页；移动端扫码/连接串/局域网 6 位码三种配对 + Happy Eyeballs 竞速 + 同 LAN 静默刷新地址；LAN/WAN 统一加密通道。
- **应用内更新**：四端接入 GitHub Releases 版本检测——macOS 下载 DMG 自动替换安装并重启；Windows 走 electron-updater（github provider）；Android 下载 APK 跳系统安装；iOS 检测后跳发布页（未签名 IPA 无法自装）。四端版本号统一为 0.5.0。
- **多 CLI 支持**：host 端从 2 家扩到 9 家——新增 Cursor Agent、Gemini、Qwen Code、Copilot、Kimi、Antigravity、Kiro 适配（stream-json/JSONL 事件统一映射到面板卡片；不支持交互式权限回执的 CLI 走启动 flag 降级；resume 能力按各 CLI 实际支持接入）；iOS/Android CLI 选择器扩为 9 项目录，未收录值兜底显示。
- **文档**：README 明确当前支持 Claude Code / Codex 两个 CLI，更多 CLI（cursor-agent、Gemini CLI 等）规划中，欢迎贡献适配。

## 0.3.0 · 开源化 + 纯局域网

发布日期：2026-09-20

### 架构变更

- **删除后端**：`后端/`（Go API + 信令 + 管理后台）整体移除，仓库不再依赖任何云端服务。
- **去认证**：账号登录、设备码、连接审批、transient token、Bearer 鉴权全部移除；同局域网任何设备可直接连入 host（`ws://host:18765/chat`）。
- **纯局域网直连**：隧道（tunnel）/ WebRTC / 信令中转链路全部删除；客户端通过子网 `/health` 扫描发现 host，支持手动输入 `host:port` 并记住上次连接。
- **开源化**：PolyForm Noncommercial 1.0.0（仅限个人非商业使用，禁止商用）；清理已提交的 `node_modules`/`dist` 产物与个人标识（bundle id、签名证书、域名引用）。

### 各端

- macOS：`RemoteChatServer` 不再校验 token；移除账号/信令/LAN token 发布/隧道/WebRTC。
- iOS：移除登录门与云端 transport；`LanSubnetProbe.discoverHealthHosts` + 手动连接；`remote.*` 旧 UserDefaults 键自动清理。
- Android：同上；`RemoteChatConfig` 简化为 `host + port`；去掉 stream-webrtc-android / security-crypto 依赖。
- Windows：移除 `account/`、`signaling/`、`device/`、`remoteChat/` 与隧道/WebRTC responder；`RemoteHostServer` 无鉴权；设置页仅保留 LAN host 开关；`appId` → `com.acode.windows`。

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

### macOS（acode 宿主）

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
