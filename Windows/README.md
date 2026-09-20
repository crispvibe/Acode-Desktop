# acode Windows

Electron + React + TypeScript Windows client shell for the acode desktop experience.

## Commands

```bash
npm install
npm run dev
npm run build
npm run dist:win
```

## Boundaries

- `src/main`: Electron main process, system capabilities, windows, file/process access.
- `src/preload`: contextBridge-only API surface.
- `src/renderer`: React UI and client-side state.
- `src/shared`: DTOs, IPC schemas, constants shared by all processes.

The renderer must never import Electron, Node system modules, or CLI process code directly.
