# acode

[中文](README.md) · **English**

> Mobile AI coding — put Claude Code / Codex in your pocket.

An open-source, LAN-only AI coding workbench: run Claude Code / Codex conversations on your computer, then drive them from your phone over the same Wi-Fi. **No accounts, no backend, no cloud** — just open it and go.

Repo: <https://github.com/crispvibe/Acode-Desktop> · License: [PolyForm Noncommercial 1.0.0](LICENSE) (free for personal use, no commercial use)

<p align="center">
  <img src="文档/images/desktop-chat.png" alt="acode desktop" width="64%" />
  <img src="文档/images/mobile-thread.png" alt="acode mobile" width="31%" />
</p>

## What it does

- 📱 **Drive desktop AI from your phone**: send tasks, watch progress, approve permissions, answer the agent's questions — keep AI coding while you're away from the desk
- 🔌 **Zero-config connect**: auto-discovers the host on the same Wi-Fi; or enter `IP:18765` manually
- 🛠 **See every step**: task lists, file reads, search, diffs, terminal commands, sub-agents — each rendered as its own card
- ⚡ **All mainstream CLIs**: Claude Code, Codex, Cursor Agent, Gemini, Qwen Code, Copilot, Kimi, Antigravity, Kiro — switch freely; adjust model and reasoning effort mid-conversation
- 🔓 **No account system**: no sign-up, no login, nothing goes through the cloud
- 🖥 **Four platforms**: macOS / Windows as the host, iOS / Android as the client

9 mainstream CLIs are already wired in. Want another (Aider, OpenCode, Goose…)? A PR is one host-side adapter away.

## Quick start

**Prerequisite**: have any supported CLI installed and signed in on the host: `claude`, `codex`, `cursor-agent`, `gemini`, `qwen`, `copilot`, `kimi`, `agy`, `kiro-cli`.

**Desktop host** (pick one):

```bash
# macOS: open the project in Xcode and run
open "Mac版本/Codevoke.xcodeproj"

# Windows: Node.js 20+
cd Windows版本 && npm install && npm run dev
```

**Mobile client**:

```bash
# Android: build and install the apk
cd 安卓版本 && ./gradlew assembleDebug

# iOS: build to a real device in Xcode
open "iOS版本/Codevoke.xcodeproj"
```

**Connect**: join the same Wi-Fi as the computer — the app auto-scans the LAN for acode hosts. If discovery fails, enter the computer's `IP:18765` manually.

## Security notice

> ⚠️ **Connections have no authentication** — any device on the same LAN can connect and drive your CLI. Only use it on trusted networks, and **never expose port 18765 to the public internet**.

## Known gap: remote access over the internet (NAT traversal)

Only same-Wi-Fi LAN direct connection works today. Cross-network remote access (NAT traversal / intranet tunneling) was half-built and never finished — it's the biggest missing piece of this project.

If you know P2P / NAT traversal / tunneling, contributions are very welcome: the protocol layer and module layout are in place (`共享代码/`, the `RemoteChat` modules on each platform) — send a PR.

## Repository layout

- `Mac版本/` — macOS host (SwiftUI + LAN server)
- `Windows版本/` — Windows host (Electron + React + TS)
- `iOS版本/` — iOS client (SwiftUI)
- `安卓版本/` — Android client (Kotlin + Compose)
- `共享代码/` — shared protocol & UI for macOS/iOS (SwiftPM: ChatCore / ChatUI)
- `文档/` — protocol docs, macOS packaging & notarization
- `脚本/` — packaging / icon / verification / WS debug scripts
- `设计图/` — Android design baseline

Protocol: `GET /health` (discovery) · `WS /chat` (panel mirroring + commands) · `POST /attachments`. See `文档/remote-chat-vnc-refactor.md` and `文档/remote-chat-v2-protocol.md`.

## About this project

This started as a paid product. After a while it became clear the models of that time couldn't deliver what was envisioned, so commercialization was dropped — the project was almost sold, then shelved the idea entirely: rather than letting it rot, better to open-source it and let it belong to everyone.

The vast majority of the code was written by the author alone — thanks to contributor [@909693mr.zeng](https://github.com/909693) and everyone who sent in suggestions.

If you find it useful, a star means a lot. Chinese-speaking users are welcome in the QQ group: [Code 开源技术交流群](https://qm.qq.com/q/yauE2vZ73y).

## License

[PolyForm Noncommercial 1.0.0](LICENSE): free for personal use, learning, research, and non-commercial forks; **all commercial use is prohibited**. Redistributions must include the LICENSE text and copyright notice.

© 2026 crispvibe · [Acode-Desktop](https://github.com/crispvibe/Acode-Desktop)
