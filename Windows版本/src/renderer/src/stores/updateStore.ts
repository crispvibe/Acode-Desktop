import { create } from "zustand";
import type { UpdateStatus } from "@shared/ipc";

interface UpdateState {
  status: UpdateStatus | null;
  load: () => Promise<void>;
  check: () => Promise<void>;
  quitAndInstall: () => Promise<void>;
  openReleases: () => Promise<void>;
}

let subscribed = false;

export const useUpdateStore = create<UpdateState>((set) => {
  function ensureSubscribed(): void {
    if (subscribed) {
      return;
    }
    const bridge = window.codevoke?.updates;
    if (!bridge) {
      return;
    }
    subscribed = true;
    bridge.onStatus((status) => set({ status }));
  }

  return {
    status: null,

    async load() {
      const bridge = window.codevoke?.updates;
      if (!bridge) {
        return;
      }
      ensureSubscribed();
      try {
        const status = await bridge.getStatus();
        set({ status });
      } catch {
        // bridge 不可用时保持 null，设置页显示「不可用」。
      }
    },

    async check() {
      const bridge = window.codevoke?.updates;
      if (!bridge) {
        return;
      }
      ensureSubscribed();
      try {
        const status = await bridge.check();
        set({ status });
      } catch {
        // 失败细节经 onStatus 推送 error 阶段。
      }
    },

    async quitAndInstall() {
      await window.codevoke?.updates?.quitAndInstall();
    },

    async openReleases() {
      await window.codevoke?.updates?.openReleases();
    }
  };
});
