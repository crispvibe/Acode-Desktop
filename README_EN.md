# acode

[中文](README.md) · **English**

> Mobile AI coding — put Claude Code / Codex in your pocket.

An open-source AI coding workbench with LAN + cross-network direct connect: run Claude Code / Codex conversations on your computer, then drive them from your phone — auto-discovery on the same Wi-Fi, QR pairing across networks. **No accounts, no backend, no cloud** — just open it and go.

Repo: <https://github.com/crispvibe/Acode-Desktop> · License: [PolyForm Noncommercial 1.0.0](LICENSE) (free for personal use, no commercial use)

<p align="center">
  <img src="文档/images/desktop-chat.png" alt="acode desktop" width="64%" />
  <img src="文档/images/mobile-thread.png" alt="acode mobile" width="31%" />
</p>

## Download

| Platform | Package (direct link to the latest GitHub Release) |
|----------|----------------------------------------------------|
| macOS | [acode-macos-universal.dmg](https://github.com/crispvibe/Acode-Desktop/releases/latest/download/acode-macos-universal.dmg) |
| Windows | [Installer / Portable](https://github.com/crispvibe/Acode-Desktop/releases/latest) (`acode-Setup-*-x64.exe` installer / `acode-Portable-*-x64.exe` portable) |
| Android | [acode-android-debug.apk](https://github.com/crispvibe/Acode-Desktop/releases/latest/download/acode-android-debug.apk) |
| iOS | [acode-ios-unsigned.ipa](https://github.com/crispvibe/Acode-Desktop/releases/latest/download/acode-ios-unsigned.ipa) (unsigned IPA — install via TrollStore or sideload with your own certificate) |

All builds are on the [latest Releases page](https://github.com/crispvibe/Acode-Desktop/releases/latest); Windows filenames carry a version number — if a direct link stops working, grab the package there.

## What it does

- 📱 **Drive desktop AI from your phone**: send tasks, watch progress, approve permissions, answer the agent's questions — keep AI coding while you're away from the desk
- 🔌 **Zero-config connect**: auto-discovers the host on the same Wi-Fi; or enter `IP:18765` manually — cross-network direct connect (IPv6 / port mapping + QR pairing) is supported
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

**Connect**: join the same Wi-Fi as the computer — the app auto-scans the LAN for acode hosts. If discovery fails, enter the computer's `IP:18765` manually. On a different network, scan the QR code (or paste the connection string) shown in the host's settings to pair and connect directly.

## Security notice

> ⚠️ Connections use **wss (self-signed TLS + certificate pinning) with paired-token auth** — the same scheme on LAN and WAN. Pairing codes/QR are only shown on the host, and paired tokens can be revoked from settings. Still use it in environments you trust, and turn remote access off in settings when you don't need it.

## Cross-network direct connect

Beyond your Wi-Fi, the phone still connects **directly to the computer — no third-party servers**: the host publishes a global IPv6 address or asks the router for a port mapping (NAT-PMP / UPnP); the phone pairs by scanning the QR code in host settings (or pasting the connection string). On the same LAN, a 6-digit pairing code works too.

If neither side has IPv6 nor a public IPv4, direct connect is impossible and the app says so. Design details: `文档/remote-chat-wan-direct.md`.

## Repository layout

- `Mac版本/` — macOS host (SwiftUI + direct-connect server)
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
