# acode

**中文** · [English](README_EN.md)

> 手机 AI 编程——把 Claude Code / Codex 装进口袋。

开源的局域网 + 跨网直连 AI 编程工作台：在电脑上跑 Claude Code / Codex 对话，用手机直接连上去指挥它干活——同一 Wi-Fi 自动发现，跨网扫码配对。**无账号、无后端、无云端**，打开就能用。

仓库：<https://github.com/crispvibe/Acode-Desktop> · QQ 群：[Code 开源技术交流群](https://qm.qq.com/q/yauE2vZ73y) · License：[PolyForm Noncommercial 1.0.0](LICENSE)（个人免费，禁止商用）

<p align="center">
  <img src="文档/images/desktop-chat.png" alt="acode 电脑端" width="64%" />
  <img src="文档/images/mobile-thread.png" alt="acode 手机端" width="31%" />
</p>

## 下载

| 平台 | 安装包（GitHub Releases 最新版直达） |
|------|-----------------------------------|
| macOS | [acode-macos-universal.dmg](https://github.com/crispvibe/Acode-Desktop/releases/latest/download/acode-macos-universal.dmg) |
| Windows | [安装包 / 便携版](https://github.com/crispvibe/Acode-Desktop/releases/latest)（`acode-Setup-*-x64.exe` 安装包 / `acode-Portable-*-x64.exe` 免安装） |
| Android | [acode-android-debug.apk](https://github.com/crispvibe/Acode-Desktop/releases/latest/download/acode-android-debug.apk) |
| iOS | [acode-ios-unsigned.ipa](https://github.com/crispvibe/Acode-Desktop/releases/latest/download/acode-ios-unsigned.ipa)（未签名 IPA，需 TrollStore 或自签安装） |

全部产物见 [Releases 最新页](https://github.com/crispvibe/Acode-Desktop/releases/latest)；Windows 包文件名带版本号，直达链接失效时到该页下载。

## 它能干什么

- 📱 **手机指挥电脑里的 AI**：发任务、看进度、批权限、回答 AI 的提问，人不在电脑前也能让 AI 继续写代码
- 🔌 **零配置连接**：同一 Wi-Fi 下自动发现电脑，点击即连；也可以手动输入 `IP:18765`；跨网直连（IPv6 / 端口映射 + 扫码配对）已支持
- 🛠 **每一步都看得见**：任务清单、读文件、搜索、diff、终端命令、子代理，全部渲染成对应的卡片
- ⚡ **主流 CLI 全接入**：Claude Code、Codex、Cursor Agent、Gemini、Qwen Code、Copilot、Kimi、Antigravity、Kiro——想用哪个切哪个，模型和推理强度在对话里随手调
- 🔓 **没有账号体系**：不注册、不登录、不过云，打开就完事
- 🖥 **四端**：macOS / Windows 当电脑端，iOS / Android 当手机端

已内置 9 家主流 CLI 适配；还想接别的（Aider、OpenCode、Goose 等）欢迎 PR——host 端加一个适配器即可。

## 快速开始

**前置要求**：电脑端装好任意一家 CLI 并登录过：`claude`、`codex`、`cursor-agent`、`gemini`、`qwen`、`copilot`、`kimi`、`agy`、`kiro-cli`。

**电脑端**（任选一个当 host）：

```bash
# macOS：Xcode 打开工程运行
open "Mac版本/Codevoke.xcodeproj"

# Windows：Node.js 20+
cd Windows版本 && npm install && npm run dev
```

**手机端**：

```bash
# Android：生成 apk 安装
cd 安卓版本 && ./gradlew assembleDebug

# iOS：Xcode 构建到真机
open "iOS版本/Codevoke.xcodeproj"
```

**连接**：手机和电脑连同一个 Wi-Fi，App 会自动扫描局域网里的 acode；扫不到就在连接页手动输入电脑的 `IP:18765`。不在同一网络时，在电脑端设置页调出二维码/连接串，手机扫码或粘贴配对即可跨网直连。

## 安全提示

> ⚠️ 连接走 **wss（自签 TLS + 证书指纹校验）+ 配对 token 鉴权**，局域网与跨网同一套机制；配对码/二维码只在电脑端出示，已配对的 token 可在设置页吊销。仍建议只在可信环境使用，不用远程连接时在设置里关掉即可。

## 跨网直连

同一 Wi-Fi 之外也能直连，**不经过任何第三方服务器**：电脑端枚举全球 IPv6、或用 NAT-PMP / UPnP 让路由器自动映射端口；手机扫电脑端设置页的二维码（或粘贴连接串）完成配对，局域网内也可以输入 6 位数字码配对。

两端都没有 IPv6 且没有公网 IPv4 时无法直连，App 会明确提示。方案细节见 `文档/remote-chat-wan-direct.md`。

## 目录结构

- `Mac版本/` —— macOS 电脑端（SwiftUI + 直连服务）
- `Windows版本/` —— Windows 电脑端（Electron + React + TS）
- `iOS版本/` —— iOS 客户端（SwiftUI）
- `安卓版本/` —— Android 客户端（Kotlin + Compose）
- `共享代码/` —— macOS/iOS 共用的协议与 UI（SwiftPM：ChatCore / ChatUI）
- `文档/` —— 协议说明、macOS 打包/公证
- `脚本/` —— 打包 / 图标 / 验证 / WS 调试
- `设计图/` —— Android 端设计基准

协议：`GET /health`（发现）· `WS /chat`（面板镜像 + 命令通道）· `POST /attachments`（附件），细节见 `文档/remote-chat-vnc-refactor.md`、`文档/remote-chat-v2-protocol.md`。

## 关于这个项目

这个项目最初是想做成付费产品的。做了一阵发现当时的模型能力达不到设想的要求，商业化这条路走不通，本来打算卖掉；后来想想还是算了——与其放着吃灰，不如开源出来，让它成为大家的东西。

目前绝大部分代码是作者一个人写的，也感谢参与过的贡献者 [@909693mr.zeng](https://github.com/909693)，以及每一位提过建议的朋友。

觉得有用就点个 Star，想一起玩就加 QQ 群：[Code 开源技术交流群](https://qm.qq.com/q/yauE2vZ73y)。

## License

[PolyForm Noncommercial 1.0.0](LICENSE)：个人使用、学习研究、二次开发、非营利用途随意；**禁止一切商业用途**。分发或修改后再发布需附带 LICENSE 全文与版权声明。

© 2026 crispvibe · [Acode-Desktop](https://github.com/crispvibe/Acode-Desktop)
