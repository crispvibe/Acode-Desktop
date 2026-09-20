# Codevoke

Codevoke 是一个开源的 AI CLI 工作台：管理项目、浏览/编辑文件，并在内嵌面板中与 Claude Code / Codex 对话；也可以把桌面面板镜像到同一局域网的手机或平板上，随时随地远程操作。

**纯局域网直连，无账号、无后端、无云端依赖。**

## 平台

| 平台 | 角色 | 目录 |
| --- | --- | --- |
| macOS（SwiftUI 原生） | 工作台 + 局域网 host | `Codevoke/` |
| iOS | 移动端客户端（镜像桌面聊天面板） | `CodevokeIOS/` |
| Android | 移动端客户端 | `Android/` |
| Windows（Electron + React） | 工作台 + 局域网 host | `Windows/` |

host 端（macOS / Windows）内置 HTTP + WebSocket 服务，默认监听 **18765** 端口；客户端通过子网扫描发现 host，或直接输入 `host:port` 手动连接。

> ⚠️ 连接不做任何鉴权——同一局域网内的任何设备都能连入 host 并操作 CLI。请在可信网络下使用，不要对公网暴露端口。

## 连接模型

- `GET /health` —— 存活探测 / 子网扫描发现。
- `WS /chat` —— 面板镜像通道：host 推送 `PanelStateEnvelope`（snapshot/patch），客户端回发 `command`，host 回 `command_ack`。协议见 `docs/remote-chat-vnc-refactor.md`、`docs/remote-chat-v2-protocol.md`。
- `POST /attachments` —— 聊天附件直传。

## 构建

### macOS（工作台 + host）

要求：macOS 14+，Xcode 15/16。

```bash
xcodebuild -project Codevoke.xcodeproj -scheme Codevoke -configuration Debug build
# 或直接 open Codevoke.xcodeproj
```

在设置里开启「允许远程连接」后，同 Wi-Fi 的手机即可发现并连接。

打包签名（可选，需本机有 Developer ID 证书）：

```bash
CODEVOKE_SIGNING_AUTHORITY="Developer ID Application: Your Name (TEAMID)" \
CODEVOKE_TEAM_ID="TEAMID" \
scripts/package-macos-app.sh
```

`NOTARIZE=1` 可触发公证流程（需要先配置 `codevoke-notary` keychain profile，见 `docs/macos-notarization.md`）。

### iOS

```bash
open CodevokeIOS/Codevoke.xcodeproj
```

### Android

```bash
cd Android && ./gradlew assembleDebug
```

### Windows（工作台 + host）

```bash
cd Windows
npm install
npm run dev        # 开发
npm run typecheck  # 类型检查
npm run test       # vitest
npm run dist:win   # 打包
```

「设置 → 设备连接」里开启 host 开关即可接受局域网连接。

## 功能（macOS 工作台）

### 工作台

- macOS 原生 SwiftUI 三栏界面（左侧项目/文件、中间编辑器、右侧 CLI 对话）。
- 左侧栏使用 `NSVisualEffectView` 毛玻璃效果（`GlassPanel`）。
- 编辑器和聊天面板之间可拖拽调整宽度。

### 项目管理

- 添加 / 删除项目目录，security-scoped bookmark 持久化访问权限。
- 项目列表持久化到 Application Support，启动时自动恢复。

### 文件树与编辑器

- 懒加载目录树，默认忽略 `.git`、`node_modules`、`dist`、`build` 等目录。
- 多标签编辑 + 行号 + 八种语言的 regex 级语法高亮；`⌘S` 保存。
- 文件节点支持拖拽到聊天输入框。

### 内嵌 CLI 对话

- 右侧面板可切换 Claude Code / Codex。
- Claude Code 通过 `claude -p <prompt> --output-format stream-json --verbose` 真实启动；Codex 通过 `codex app-server --listen stdio://` 对接（JSON-RPC）。
- 模型、权限模式、思考强度可选；权限请求支持拒绝 / 允许 / 本会话允许。
- 会话本地持久化（`chat-sessions.json` + `chat-messages/<uuid>.jsonl` + `chat-drafts.json`），支持新建 / `--continue` / `--resume`。
- 外部 Terminal / iTerm2 启动作为 fallback。

### 局域网远程

- host（macOS / Windows）在设置里开启后监听 `0.0.0.0:18765`。
- 手机/平板客户端扫描子网 `/health` 发现 host，或手动输入 `host:port`。
- 面板镜像协议（snapshot/patch + command/ack）使移动端可远程查看与操作桌面会话。

### 未实现 / 待完善

- LSP / tree-sitter 级语法高亮、Git 集成、内嵌终端（PTY）、插件系统。
- Codex 完整模型 turn 端到端验证。

## 仓库结构

```text
Codevoke/        macOS 工作台 + host
CodevokeIOS/     iOS 客户端
Android/         Android 客户端
Windows/         Windows 工作台 + host（Electron）
Shared/          跨平台共享 Swift 代码（协议、模型、过滤）
scripts/         macOS 打包/校验脚本
docs/            协议与架构文档
设计图/           设计稿与截图参考
```

## License

[MIT](LICENSE)
