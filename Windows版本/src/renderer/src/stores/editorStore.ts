import { create } from "zustand";
import {
  createEditorTabId,
  type EditorCloseConfirmation,
  type EditorCursorPosition,
  type EditorFileStat,
  type EditorOpenFileResult,
  type EditorSaveFileResult,
  type EditorTab
} from "@shared/editor";

interface CodevokeEditorApi {
  openEditorFile?: (path: string) => Promise<EditorOpenFileResult>;
  saveEditorFile?: (path: string, text: string, expectedText: string) => Promise<EditorSaveFileResult>;
  statEditorFile?: (path: string) => Promise<EditorFileStat>;
}

type CloseAction = "cancel" | "discard" | "save";

interface EditorStoreState {
  tabs: EditorTab[];
  selectedTabId: string | null;
  closeConfirmation: EditorCloseConfirmation | null;
  openFile: (path: string) => Promise<void>;
  selectTab: (tabId: string) => void;
  requestCloseTab: (tabId: string) => EditorCloseConfirmation | null;
  resolveCloseConfirmation: (action: CloseAction) => Promise<void>;
  closeTabImmediately: (tabId: string) => void;
  updateText: (tabId: string, text: string) => void;
  updateCursor: (tabId: string, cursor: EditorCursorPosition) => void;
  saveTab: (tabId: string) => Promise<boolean>;
  saveSelectedTab: () => Promise<boolean>;
  selectedTab: () => EditorTab | null;
}

const now = () => Date.now();

function makeLoadingTab(filePath: string): EditorTab {
  const timestamp = now();
  return {
    id: createEditorTabId(filePath),
    path: filePath,
    title: titleFromPath(filePath),
    text: "",
    savedText: "",
    cursor: { line: 1, column: 1 },
    dirty: false,
    loading: true,
    error: null,
    byteCount: 0,
    modifiedAt: null,
    openedAt: timestamp,
    lastActiveAt: timestamp
  };
}

function titleFromPath(filePath: string): string {
  const normalized = filePath.replaceAll("\\", "/");
  return normalized.split("/").filter(Boolean).at(-1) ?? filePath;
}

function toLoadedTab(existing: EditorTab, result: EditorOpenFileResult): EditorTab {
  return {
    ...existing,
    id: createEditorTabId(result.path),
    path: result.path,
    title: result.title,
    text: result.text,
    savedText: result.text,
    dirty: false,
    loading: false,
    error: null,
    byteCount: result.byteCount,
    modifiedAt: result.modifiedAt,
    lastActiveAt: now()
  };
}

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.message) {
    return error.message;
  }
  return "编辑器操作失败。";
}

function selectedTabFromState(state: Pick<EditorStoreState, "tabs" | "selectedTabId">): EditorTab | null {
  return state.tabs.find((tab) => tab.id === state.selectedTabId) ?? null;
}

function editorApi(): CodevokeEditorApi | undefined {
  return window.codevoke as (typeof window.codevoke & CodevokeEditorApi) | undefined;
}

export const useEditorStore = create<EditorStoreState>((set, get) => ({
  tabs: [],
  selectedTabId: null,
  closeConfirmation: null,

  async openFile(path: string) {
    const trimmedPath = path.trim();
    if (!trimmedPath) {
      return;
    }

    const existing = get().tabs.find((tab) => tab.path === trimmedPath || tab.id === createEditorTabId(trimmedPath));
    if (existing) {
      get().selectTab(existing.id);
      return;
    }

    const loadingTab = makeLoadingTab(trimmedPath);
    set((state) => ({
      tabs: [...state.tabs, loadingTab],
      selectedTabId: loadingTab.id
    }));

    const api = editorApi()?.openEditorFile;
    if (!api) {
      set((state) => ({
        tabs: state.tabs.map((tab) =>
          tab.id === loadingTab.id
            ? { ...tab, loading: false, error: "编辑器 IPC 尚未接线。", lastActiveAt: now() }
            : tab
        )
      }));
      return;
    }

    try {
      const result = await api(trimmedPath);
      set((state) => {
        const resultId = createEditorTabId(result.path);
        const duplicate = state.tabs.find((tab) => tab.id === resultId && tab.id !== loadingTab.id);
        if (duplicate) {
          return {
            tabs: state.tabs.filter((tab) => tab.id !== loadingTab.id),
            selectedTabId: duplicate.id
          };
        }

        return {
          tabs: state.tabs.map((tab) => (tab.id === loadingTab.id ? toLoadedTab(tab, result) : tab)),
          selectedTabId: resultId
        };
      });
    } catch (error) {
      set((state) => ({
        tabs: state.tabs.map((tab) =>
          tab.id === loadingTab.id
            ? { ...tab, loading: false, error: errorMessage(error), lastActiveAt: now() }
            : tab
        )
      }));
    }
  },

  selectTab(tabId: string) {
    set((state) => ({
      selectedTabId: tabId,
      tabs: state.tabs.map((tab) => (tab.id === tabId ? { ...tab, lastActiveAt: now() } : tab))
    }));
  },

  requestCloseTab(tabId: string) {
    const tab = get().tabs.find((candidate) => candidate.id === tabId);
    if (!tab) {
      return null;
    }
    if (tab.dirty) {
      const confirmation = { tabId: tab.id, title: tab.title };
      set({ closeConfirmation: confirmation });
      return confirmation;
    }
    get().closeTabImmediately(tabId);
    return null;
  },

  async resolveCloseConfirmation(action: CloseAction) {
    const confirmation = get().closeConfirmation;
    if (!confirmation) {
      return;
    }

    if (action === "cancel") {
      set({ closeConfirmation: null });
      return;
    }

    if (action === "save") {
      const saved = await get().saveTab(confirmation.tabId);
      if (!saved) {
        return;
      }
    }

    set({ closeConfirmation: null });
    get().closeTabImmediately(confirmation.tabId);
  },

  closeTabImmediately(tabId: string) {
    set((state) => {
      const closingIndex = state.tabs.findIndex((tab) => tab.id === tabId);
      if (closingIndex < 0) {
        return state;
      }
      const tabs = state.tabs.filter((tab) => tab.id !== tabId);
      const selectedTabId =
        state.selectedTabId === tabId
          ? tabs[closingIndex]?.id ?? tabs[closingIndex - 1]?.id ?? tabs.at(-1)?.id ?? null
          : state.selectedTabId;
      return { tabs, selectedTabId };
    });
  },

  updateText(tabId: string, text: string) {
    set((state) => ({
      tabs: state.tabs.map((tab) =>
        tab.id === tabId
          ? { ...tab, text, dirty: text !== tab.savedText, byteCount: new TextEncoder().encode(text).byteLength }
          : tab
      )
    }));
  },

  updateCursor(tabId: string, cursor: EditorCursorPosition) {
    set((state) => ({
      tabs: state.tabs.map((tab) => (tab.id === tabId ? { ...tab, cursor } : tab))
    }));
  },

  async saveTab(tabId: string) {
    const tab = get().tabs.find((candidate) => candidate.id === tabId);
    if (!tab || tab.loading || tab.error || !tab.dirty) {
      return Boolean(tab && !tab.loading && !tab.error);
    }

    const api = editorApi()?.saveEditorFile;
    if (!api) {
      set((state) => ({
        tabs: state.tabs.map((candidate) =>
          candidate.id === tabId ? { ...candidate, error: "编辑器保存 IPC 尚未接线。" } : candidate
        )
      }));
      return false;
    }

    try {
      const result = await api(tab.path, tab.text, tab.savedText);
      set((state) => ({
        tabs: state.tabs.map((candidate) =>
          candidate.id === tabId
            ? {
                ...candidate,
                title: result.title,
                savedText: candidate.text,
                dirty: false,
                error: null,
                byteCount: result.byteCount,
                modifiedAt: result.modifiedAt
              }
            : candidate
        )
      }));
      return true;
    } catch (error) {
      set((state) => ({
        tabs: state.tabs.map((candidate) =>
          candidate.id === tabId ? { ...candidate, error: errorMessage(error) } : candidate
        )
      }));
      return false;
    }
  },

  async saveSelectedTab() {
    const tab = selectedTabFromState(get());
    if (!tab) {
      return false;
    }
    return get().saveTab(tab.id);
  },

  selectedTab() {
    return selectedTabFromState(get());
  }
}));
