# Remote Chat WAN Direct — 零第三方跨网直连方案

> 状态：方案已定稿待实现。目标：手机端在局域网外直连电脑端，**不使用任何第三方服务**（无 DDNS/STUN/协调器/隧道/VPN App)，本地电脑即服务器。
>
> 约束（用户拍板）:①完全零第三方；②不装额外 App;③Mac/Windows/iOS/Android 四端全链路。

## 1. 关键定性

这是**服务器可达性问题**，不是 P2P 打洞问题：只有电脑需要被找到，手机永远是发起方，TCP 连上即双向。因此不需要打洞、不需要 rendezvous 服务器，只需：

1. 电脑有一个公网可达地址（IPv6 全球地址 / 路由器 NAT-PMP·PCP·UPnP 映射出的 IPv4 端口——路由器是用户自己的设备，不算第三方）;
2. 手机知道这个地址（扫码/手动输入/同局域网时静默刷新）。

硬性边界：两端都无 IPv6 且电脑无公网 IPv4 → 无法直连，App 明确报"当前网络无法直连"，不静默失败。

## 2. 现状接缝（已核实）

| 端 | 现状 | 接缝 |
|---|---|---|
| Mac host | `RemoteChatServer`(NWListener TCP:18765，明文，零鉴权）,`bindLAN` 控 loopback/全接口 | `RemoteChatServer.swift`、`RemoteChatRouter.swift`、`SettingsPageView.swift` |
| Windows host | `RemoteHostServer.ts`(http+ws 明文，零鉴权），**已预留虚拟连接接缝** | `attachVirtualConnection`/`deliverFrame`(L348-368)、`RemoteHostController.ts` |
| iOS client | `RemoteTransport` 协议，仅 LAN WS 实现；/24 子网扫 `/health` 发现 | `RemoteTransport.swift`、`RemoteWebSocketClient.swift`、`LanSubnetProbe.swift` |
| Android client | OkHttp + 同款子网扫描 | `RemoteLanClient.kt`、`RemoteChatClient.kt`、`LanSubnetProbe.kt` |

线缆协议（snapshot/patch/command/command_ack/recovery RPC）是传输无关 JSON 帧，**加传输不动协议**。

## 3. 四层架构

```
L0 安全底座  配对token + wss(TLS自签+SPKI pinning) + /pair 仅允许私网来源
L1 可达性    host 枚举全球IPv6 + NAT-PMP/PCP/UPnP 映射IPv4 + CGNAT自检 + 映射续期
L2 地址发现  QR(地址+token+指纹) / 局域网6位数字码配对 / 同LAN静默刷新
L3 传输      同一套 JSON 帧走 wss；客户端多 endpoint 并行尝试(Happy Eyeballs)
```

## 4. 线缆契约（四端必须一致）

### 4.1 端口与协议

- 端口沿用 `18765`(可配）。启用 WAN 后统一 `wss://`+鉴权，**LAN 也走同一套**（不再保留明文路径；旧版客户端连不上属预期，全端同版本发布）。
- `bindLAN=false` 时仍只绑 loopback，拒绝一切非回环连接（现有 `isLoopbackEndpoint` 防线保留）。

### 4.2 HTTP 端点

| 端点 | 鉴权 | 说明 |
|---|---|---|
| `GET /health` | 否 | 发现用。响应加字段：`proto:2`、`pair:true`、`name:<主机名>`。`proto:2` 表示"鉴权服务器"。 |
| `POST /pair` | 6位码 | **仅接受私网/回环来源**(RFC1918+link-local+loopback;WAN 来源直接 403)。body `{code, deviceName}` → 200 `{token, fp, name, eps}`。码 6 位数字、5 分钟有效、一次性、每 IP 每分钟 ≤5 次尝试。 |
| `GET /connect_info` | Bearer | 返回 `{name, eps}` 当前 endpoint 列表，客户端同 LAN 时静默刷新地址用。 |
| 其余所有 HTTP | Bearer | `Authorization: Bearer <token>`，缺失/错误 → 401 `{error:"unauthorized"}`。 |
| `GET /chat`(WS upgrade) | Bearer | upgrade 请求头带 `Authorization`;鉴权失败在 101 之前回 401。 |

- token:32 字节随机，base64url；服务端只存 `SHA-256(token)` 哈希 + `{deviceId, deviceName, createdAt, lastSeen}`，支持设置页列表与吊销。
- auth 失败限流：每连接 5 次失败后关连接；每 IP 每分钟失败 >10 次临时封禁 60s。

### 4.3 TLS 与 pinning

- 服务端自签 **ECDSA P-256** 证书（CN=`acode-host`，有效期 10 年），私钥+证书持久化：Mac→Keychain(SecIdentity);Windows→加密存储于 userData(仅本机可读文件权限即可）。
- 客户端校验**只认 SPKI-SHA256 pin**：忽略 CN/SAN/有效期/链。pin 不匹配 = 连接失败。
- 证书轮换/重装系统 → 指纹变 → 必须重新配对（UI 明确提示）。

### 4.4 配对载荷（QR / 手动输入串）

格式：`acode://pair?d=<base64url(JSON)>`,JSON:

```json
{
  "v": 1,
  "n": "Oreo 的 MacBook",
  "eps": [{"a": "2409:8a55::1234", "p": 18765}, {"a": "203.0.113.5", "p": 50443}],
  "t": "<token base64url>",
  "fp": "<SPKI-SHA256 hex>"
}
```

- `eps` 按优先级排序：全球 IPv6 在前，映射 IPv4 在后；客户端顺序+并行尝试。
- 二维码只是载体之一；同时提供"复制连接串"供手动粘贴（无摄像头/远程协助场景）。

## 5. Host 端"对外发布"模块（新增，Mac/Windows 同构）

职责：周期性产出 `eps` 候选列表 + 诊断状态。

1. **IPv6 枚举**:`getifaddrs` 取全球单播地址，排除 link-local(fe80::)/ULA(fc00::/7)/temporary(优先选 stable,macOS 注意 `IFA_F_TEMPORARY` 标志——实现时核实）;EUI-64 形式（中间 ff:fe）排前。
2. **IPv4 映射**:
   - 拿默认网关：Mac 用 `SCDynamicStoreCopyValue("State:/Network/Global/IPv4")` 的 `Router` 字段；Windows 用 `default-gateway` npm 包或解析 `route print`。
   - **NAT-PMP**(RFC 6886，首选）：网关 UDP:5351，先 external-address 请求拿 WAN IP，再 TCP mapping 请求（内部 18765 → 外部随机高位，lifetime 3600s，每 lifetime/2 续期）。
   - **UPnP IGD**（兜底）:SSDP `M-SEARCH` → `InternetGatewayDevice` → SOAP `AddPortMapping`/`GetExternalIPAddress`。
   - **PCP**(RFC 6887):NAT-PMP 的超集且能打 IPv6 防火墙孔，可选实现（v2 可后置）。
   - **CGNAT 自检**：拿到的外部 IPv4 落在 100.64/10、10/8、172.16/12、192.168/16 → 判定上游还有 NAT,IPv4 候选不可用。
3. **诊断输出**：设置页显示每个候选 endpoint + 状态（`直连可用` / `CGNAT` / `路由器不支持自动映射，需手动端口转发` / `无全球IPv6`)，附手动操作指引文案。
4. **防火墙提示**:macOS Application Firewall 弹窗/Windows 防火墙放行——发布模块检测入站被拦时提示用户放行（🔴检测能力因平台而异，实现时核实，做不到就只给文案）。

## 6. 客户端（iOS/Android 同构）

- **EndpointStore**:`[{hostId, name, token, certFP, eps[], lastGood, updatedAt}]` 持久化（iOS→Keychain+UserDefaults;Android→EncryptedSharedPreferences/DataStore——实现时按现有存储惯例）。
- **RemoteWanTransport**：实现现有 `RemoteTransport` 协议（Android 对应 `RemoteChatClient` 接缝）,`URLSessionWebSocketTask`/OkHttp WS + 自定义 trust evaluator（只认 pin)。
- **连接策略**:lastGood 先行，其余 eps 并行，单条 3s 超时未握手即换下一条；全部失败 → "地址可能已变化"提示 + 引导重新配对/回局域网刷新。
- **静默刷新**：子网扫描发现已配对 host（扫到 `/health` 且能完成 wss+token 握手）→ 调 `/connect_info` 更新 eps。
- **配对入口**：设备列表页加"扫码配对"（相机扫 QR)与"输入连接串";LAN 内也可走"发现到的设备 → 输入电脑屏上 6 位码 → `/pair`"。

## 7. 四端实现要点

| 端 | 新增 | 建议依赖（均须核实版本/成熟度） |
|---|---|---|
| Mac | TLS identity(apple/swift-certificates 生成自签，Keychain 持久化）、auth 中间层、PairingService、WanEndpointPublisher(NAT-PMP 可用 DNS-SD `DNSServiceNATPortMappingCreate` 或手写 UDP)、设置页 QR(CIFilter `CIQRCodeGenerator` 内置）+诊断 | swift-certificates |
| Windows | `selfsigned` 生成证书存 userData、https/wss 鉴权、NAT-PMP(dgram)+UPnP(SSDP+SOAP)、设置页 QR 渲染 +诊断 | selfsigned、qrcode、default-gateway |
| iOS | RemoteWanTransport(pinning trust)、AVFoundation 扫码（内置）、EndpointStore、连接页 UI、/connect_info 刷新 | 无新依赖 |
| Android | RemoteWanClient（自定义 X509TrustManager 只认 pin)、扫码（CameraX+MLKit 或 zxing-android-embedded，选轻量成熟者）、EndpointStore、连接页 UI | zxing/camerax 视现状选 |

## 8. 验收

- 构建：Mac/iOS `xcodebuild`（各自 scheme 先 `xcodebuild -list` 核实）;Windows `npm run typecheck && npm run test`;Android `./gradlew assembleDebug`。
- 安全 grep：全仓 `ws://` 与无鉴权 HTTP 客户端调用清零（除 `/health`、`/pair`);`Authorization` 校验覆盖所有业务端点。
- 手测矩阵：同 LAN 配对→断 LAN 走蜂窝直连（IPv6）成功；token 错误 → 401;`/pair` 从公网来源 → 403；指纹不匹配 → 拒绝。
- 文档：README/CHANGELOG 的"局域网直连"表述更新为"局域网直连 + 跨网直连（自签加密）"。

## 9. 已排除方案（附理由）

| 方案 | 排除理由 |
|---|---|
| DDNS/STUN/协调器 | 违反"完全零第三方" |
| Tailscale/ZeroTier/NetBird | 用户不装额外 App |
| WebRTC+手动信令 | 成功率 ~70%、SDP 随网络变化失效、工程量大 |
| 自研打洞+公告板 | rendezvous 绕不开第三方；手机侧在 CGNAT 下也无需被打 |
| cloudflared/frp/ngrok | 流量过第三方中继 |

## 10. 风险与硬失败

- IPv6 前缀随拨号轮换（家宽通常按周/月变，🔴因运营商而异）→ 地址失效需重扫/同 LAN 自动刷新兜底。
- 路由器 IPv6 防火墙拦入站且无 PCP → 需用户手动放通端口，给指引文案。
- 全无 IPv6 且无公网 IPv4 → 明确失败提示（零第三方的固有代价）。
- 运营商封常用端口 → 用 18765 非标端口，一般不受影响。
