# acode

[中文](README.md) · **English**

> AI coding remote control on your phone — Claude Code / Codex in your pocket.

acode is a **free and open-source** AI coding workbench: the AI runs on your computer, and your phone connects to drive it from anywhere. Auto-discovery on the same Wi-Fi, QR pairing across networks — data stays between your two devices.

Repo: <https://github.com/crispvibe/Acode-Desktop> · QQ group: [1076321843](https://qm.qq.com/q/yauE2vZ73y) · License: [PolyForm Noncommercial 1.0.0](LICENSE) (free for personal use, no commercial use)

<p align="center">
  <img src="文档/images/desktop-chat.png" alt="acode desktop" width="96%" />
</p>
<p align="center">
  <img src="文档/images/mobile-thread.png" alt="acode mobile · conversation" width="42%" />
  <img src="文档/images/mobile-drawer.png" alt="acode mobile · session list" width="42%" />
</p>

## Download

Pick the desktop build that matches your chip; all artifacts are on the [latest Releases page](https://github.com/crispvibe/Acode-Desktop/releases/latest).

| Platform | Download | Which one |
|----------|----------|-----------|
| macOS | [Apple Silicon](https://github.com/crispvibe/Acode-Desktop/releases/latest/download/acode-macos-arm64.dmg) · [Intel](https://github.com/crispvibe/Acode-Desktop/releases/latest/download/acode-macos-x64.dmg) | Apple Silicon for M-chip Macs (2020 and later); Intel for older Macs |
| Windows | [Installer / Portable](https://github.com/crispvibe/Acode-Desktop/releases/latest) | `Setup-*-x64.exe` for most PCs; `*-arm64.exe` for Snapdragon / ARM devices; `Portable-*` runs without installing |
| Android | [acode-android-debug.apk](https://github.com/crispvibe/Acode-Desktop/releases/latest/download/acode-android-debug.apk) | install directly |
| iOS | [acode-ios-unsigned.ipa](https://github.com/crispvibe/Acode-Desktop/releases/latest/download/acode-ios-unsigned.ipa) | unsigned IPA — install via TrollStore or sign it yourself |

## What it does

- 📱 **Drive desktop AI from your phone**: the AI runs on your computer — send tasks, watch progress, approve permissions, answer its questions, even while away from the desk
- 🔌 **Zero-config connect**: auto-discovers the host on the same Wi-Fi, one tap to connect; on the go, scan a QR code to pair — IPv6 / port-mapping direct connect, no third-party servers
- 🛠 **See every step**: task lists, file reads, search, diffs, terminal commands, sub-agents — each rendered as a card
- ⚡ **9 CLIs, switch freely**: Claude Code, Codex, Cursor Agent, Gemini, Qwen Code, Copilot, Kimi, Antigravity, Kiro — model and reasoning effort adjustable mid-conversation
- � **Free & open source**: free for personal use, all code public — want another CLI (Aider, OpenCode, Goose…)? PRs welcome
- 🖥 **Four platforms**: macOS / Windows as hosts, iOS / Android as clients

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

Away from your Wi-Fi it still connects **directly — no third-party servers**: the host publishes a global IPv6 address or asks the router for a port mapping (NAT-PMP / UPnP); the phone pairs by scanning the QR code in host settings (or pasting the connection string). On the same LAN, a 6-digit pairing code works too.

If neither side has IPv6 or a public IPv4, direct connect is impossible and the app says so. Details: `文档/remote-chat-wan-direct.md`.

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

If you find it useful, a star means a lot. Chinese-speaking users are welcome in QQ group [1076321843](https://qm.qq.com/q/yauE2vZ73y).

## License

[PolyForm Noncommercial 1.0.0](LICENSE): free for personal use, learning, research, and non-commercial forks; **all commercial use is prohibited**. Redistributions must include the LICENSE text and copyright notice.

© 2026 crispvibe · [Acode-Desktop](https://github.com/crispvibe/Acode-Desktop)
