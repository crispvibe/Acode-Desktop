# acode Windows Architecture

## Goal

The Windows client mirrors the macOS acode chat semantics rather than the SwiftUI implementation. The first milestone is a stable Electron shell that can host the project tree, editor surface, and chat panel without mixing process responsibilities.

## Process Boundary

| Layer | Directory | Responsibility |
| --- | --- | --- |
| Main | `src/main` | Windows, app lifecycle, filesystem, CLI processes, logging, update/signing hooks |
| Preload | `src/preload` | Minimal typed bridge exposed through `window.acode` |
| Renderer | `src/renderer` | React UI, layout, visual tokens, local view state |
| Shared | `src/shared` | Chat DTOs, IPC schemas, channel names, platform constants |

## Security Baseline

- `nodeIntegration: false`
- `contextIsolation: true`
- `sandbox: true`
- `webSecurity: true`
- Renderer calls only typed preload APIs.
- Main process validates every IPC payload with shared schemas.

## UI Baseline

- Three-pane desktop layout: project/files, editor, chat.
- Windows material target: Mica for the main backdrop, translucent in-app surfaces for panels.
- Chat transcript is designed for virtualization, streaming batch updates, and stable scroll anchoring.
- The first implementation is a framework shell; Claude/Codex process adapters will be added behind `src/main/chat`.

## Packaging Baseline

- Local macOS can create Windows test artifacts via `npm run dist:win`.
- Production Windows builds should run on a Windows CI runner for signing, installer smoke tests, and SmartScreen/certificate validation.
