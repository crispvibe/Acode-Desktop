import {
  ChevronDown,
  Minus,
  Plus,
  Square,
  X
} from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import type { CSSProperties, KeyboardEvent, PointerEvent } from "react";
import type { ChatSessionRecord } from "@shared/chat";
import type { FileTreeEntry as ProjectFileTreeEntry } from "@shared/fileTree";
import type { WindowControlAction } from "@shared/ipc";
import { ChatRuntimePanel } from "@renderer/src/components/chat";
import { EditorArea } from "@renderer/src/components/editor";
import { ProjectSidebar } from "@renderer/src/components/sidebar";
import { SettingsPage as FunctionalSettingsPage } from "@renderer/src/components/settings";
import { AppLogo } from "@renderer/src/components/AppLogo";
import { useChatStore } from "@renderer/src/stores/chatStore";
import { useEditorStore } from "@renderer/src/stores/editorStore";
import { useProjectStore } from "@renderer/src/stores/projectStore";
import { installRemoteHostBridge } from "@renderer/src/remoteHost/RemoteHostBridge";
import "./styles.css";

type AppMode = "workbench" | "settings";

const CHAT_PANE_WIDTH_STORAGE_KEY = "codevoke.windows.chatPaneWidth";
const DEFAULT_CHAT_PANE_WIDTH = 420;
const MIN_CHAT_PANE_WIDTH = 260;
const MIN_EDITOR_PANE_WIDTH = 320;
const RESIZE_HANDLE_WIDTH = 12;
const KEYBOARD_RESIZE_STEP = 24;

function readStoredChatPaneWidth(): number {
  try {
    const value = window.localStorage.getItem(CHAT_PANE_WIDTH_STORAGE_KEY);
    const parsed = value ? Number.parseFloat(value) : Number.NaN;
    return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_CHAT_PANE_WIDTH;
  } catch {
    return DEFAULT_CHAT_PANE_WIDTH;
  }
}

function clampChatPaneWidth(width: number, availableWidth: number): number {
  const lowerBound = MIN_CHAT_PANE_WIDTH;
  if (availableWidth <= 0) {
    return Math.max(width, lowerBound);
  }

  const upperBound = Math.max(lowerBound, availableWidth - MIN_EDITOR_PANE_WIDTH - RESIZE_HANDLE_WIDTH);
  return Math.min(Math.max(width, lowerBound), upperBound);
}

function App() {
  const [mode, setMode] = useState<AppMode>("workbench");
  const [historyOpen, setHistoryOpen] = useState(false);

  useEffect(() => installRemoteHostBridge(), []);

  useEffect(() => {
    function handleBeforeUnload(event: BeforeUnloadEvent) {
      if (useEditorStore.getState().tabs.some((tab) => tab.dirty)) {
        event.preventDefault();
        event.returnValue = "";
      }
    }

    window.addEventListener("beforeunload", handleBeforeUnload);
    return () => window.removeEventListener("beforeunload", handleBeforeUnload);
  }, []);

  async function chooseProject(): Promise<string | null> {
    if (!window.codevoke) {
      return null;
    }

    const result = await window.codevoke.selectProjectDirectory();
    if (!result.canceled) {
      return result.path;
    }
    return null;
  }

  async function handleWindowControl(action: WindowControlAction) {
    if (action === "close") {
      const editorState = useEditorStore.getState();
      const dirtyTab = editorState.tabs.find((tab) => tab.dirty);
      if (dirtyTab) {
        editorState.selectTab(dirtyTab.id);
        editorState.requestCloseTab(dirtyTab.id);
        return;
      }
    }
    await window.codevoke?.windowControl(action);
  }

  return (
    <main className="app-window">
      <div className="windows-titlebar window-drag" aria-hidden="true" />
      <div className="windows-window-controls" aria-label="窗口控制">
        <button type="button" onClick={() => void handleWindowControl("minimize")} aria-label="最小化">
          <Minus size={14} />
        </button>
        <button type="button" onClick={() => void handleWindowControl("toggleMaximize")} aria-label="最大化">
          <Square size={12} />
        </button>
        <button className="close" type="button" onClick={() => void handleWindowControl("close")} aria-label="关闭">
          <X size={14} />
        </button>
      </div>
      {mode === "workbench" ? (
        <Workbench
          chooseProject={chooseProject}
          historyOpen={historyOpen}
          setHistoryOpen={setHistoryOpen}
          setMode={setMode}
        />
      ) : (
        <SettingsHost setMode={setMode} />
      )}
    </main>
  );
}

interface WorkbenchProps {
  chooseProject: () => Promise<string | null>;
  historyOpen: boolean;
  setHistoryOpen: (value: boolean) => void;
  setMode: (mode: AppMode) => void;
}

function Workbench({
  chooseProject,
  historyOpen,
  setHistoryOpen,
  setMode
}: WorkbenchProps) {
  const openFile = useEditorStore((state) => state.openFile);
  const newConversation = useChatStore((state) => state.newConversation);
  const storedProjects = useProjectStore((state) => state.projects);
  const selectedProjectId = useProjectStore((state) => state.selectedProjectId);
  const selectedProject = storedProjects.find((project) => project.id === selectedProjectId) ?? null;
  const projectTitle = selectedProject?.name ?? "选择项目";
  const workbenchCardRef = useRef<HTMLElement | null>(null);
  const chatPaneWidthRef = useRef(DEFAULT_CHAT_PANE_WIDTH);
  const [chatPaneWidth, setChatPaneWidth] = useState(readStoredChatPaneWidth);
  const [isResizingChatPane, setIsResizingChatPane] = useState(false);
  const isNarrowChatPane = chatPaneWidth < 360;

  useEffect(() => {
    chatPaneWidthRef.current = chatPaneWidth;
  }, [chatPaneWidth]);

  const persistChatPaneWidth = useCallback((width: number) => {
    try {
      window.localStorage.setItem(CHAT_PANE_WIDTH_STORAGE_KEY, String(Math.round(width)));
    } catch {
      // localStorage can be unavailable in restricted render contexts.
    }
  }, []);

  const setClampedChatPaneWidth = useCallback(
    (nextWidth: number, shouldPersist: boolean) => {
      const availableWidth = workbenchCardRef.current?.getBoundingClientRect().width ?? 0;
      const clampedWidth = clampChatPaneWidth(nextWidth, availableWidth);
      chatPaneWidthRef.current = clampedWidth;
      setChatPaneWidth(clampedWidth);
      if (shouldPersist) {
        persistChatPaneWidth(clampedWidth);
      }
      return clampedWidth;
    },
    [persistChatPaneWidth]
  );

  useEffect(() => {
    const element = workbenchCardRef.current;
    if (!element || typeof ResizeObserver === "undefined") {
      return;
    }

    const observer = new ResizeObserver(([entry]) => {
      const clampedWidth = clampChatPaneWidth(chatPaneWidthRef.current, entry.contentRect.width);
      if (Math.abs(clampedWidth - chatPaneWidthRef.current) >= 0.5) {
        chatPaneWidthRef.current = clampedWidth;
        setChatPaneWidth(clampedWidth);
        persistChatPaneWidth(clampedWidth);
      }
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, [persistChatPaneWidth]);

  function handleOpenFile(entry: ProjectFileTreeEntry) {
    if (entry.kind === "file") {
      void openFile(entry.path);
    }
  }

  async function handleOpenFileFromDialog() {
    const selection = await window.codevoke?.selectEditorFile();
    if (selection?.path) {
      await openFile(selection.path);
    }
  }

  function handleResizePointerDown(event: PointerEvent<HTMLDivElement>) {
    if (event.button !== 0) {
      return;
    }

    event.preventDefault();
    const startX = event.clientX;
    const startWidth = chatPaneWidthRef.current;
    setIsResizingChatPane(true);

    const handlePointerMove = (moveEvent: globalThis.PointerEvent) => {
      setClampedChatPaneWidth(startWidth - (moveEvent.clientX - startX), false);
    };

    const stopResize = () => {
      window.removeEventListener("pointermove", handlePointerMove);
      window.removeEventListener("pointerup", stopResize);
      window.removeEventListener("pointercancel", stopResize);
      window.removeEventListener("blur", stopResize);
      setIsResizingChatPane(false);
      persistChatPaneWidth(chatPaneWidthRef.current);
    };

    window.addEventListener("pointermove", handlePointerMove);
    window.addEventListener("pointerup", stopResize);
    window.addEventListener("pointercancel", stopResize);
    window.addEventListener("blur", stopResize);
  }

  function handleResizeKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key === "ArrowLeft") {
      event.preventDefault();
      setClampedChatPaneWidth(chatPaneWidthRef.current + KEYBOARD_RESIZE_STEP, true);
      return;
    }

    if (event.key === "ArrowRight") {
      event.preventDefault();
      setClampedChatPaneWidth(chatPaneWidthRef.current - KEYBOARD_RESIZE_STEP, true);
      return;
    }

    if (event.key === "Home") {
      event.preventDefault();
      setClampedChatPaneWidth(MIN_CHAT_PANE_WIDTH, true);
      return;
    }

    if (event.key === "End") {
      event.preventDefault();
      setClampedChatPaneWidth(Number.POSITIVE_INFINITY, true);
    }
  }

  const workbenchCardStyle = {
    "--chat-pane-width": `${Math.round(chatPaneWidth)}px`
  } as CSSProperties;

  return (
    <section className="workbench-shell">
      <ProjectSidebar
        chooseProjectPath={chooseProject}
        onOpenFile={handleOpenFile}
        onOpenSettings={() => setMode("settings")}
      />

      <section
        ref={workbenchCardRef}
        className={`workbench-card${isResizingChatPane ? " resizing" : ""}`}
        style={workbenchCardStyle}
      >
        <section className="editor-pane">
          <EditorArea onOpenFilePath={() => void handleOpenFileFromDialog()} />
        </section>

        <div
          className="pane-resize-handle window-no-drag"
          role="separator"
          aria-label="拖动调整编辑器和对话卡片宽度"
          aria-orientation="vertical"
          aria-valuemin={MIN_CHAT_PANE_WIDTH}
          aria-valuenow={Math.round(chatPaneWidth)}
          tabIndex={0}
          title="拖动调整编辑器和对话卡片宽度"
          onPointerDown={handleResizePointerDown}
          onKeyDown={handleResizeKeyDown}
        />

        <section className={`chat-pane${isNarrowChatPane ? " chat-pane-narrow" : ""}`}>
          <div className="chat-card">
            <header className="chat-topbar window-drag">
              <div className="brand-lockup">
                <div className="app-logo" aria-hidden="true">
                  <AppLogo />
                </div>
                <span className="brand-title">Codevoke</span>
                <span className="brand-divider" aria-hidden="true" />
                <button className="project-switch window-no-drag" type="button" onClick={() => setHistoryOpen(!historyOpen)}>
                  <span className="project-switch-title">{projectTitle}</span>
                  <ChevronDown size={16} />
                </button>
              </div>
              <div className="chat-actions">
                <button
                  className="new-chat"
                  type="button"
                  disabled={!selectedProject}
                  onClick={() => {
                  newConversation(selectedProject);
                  setHistoryOpen(false);
                }}
              >
                <Plus size={18} />
                  <span className="new-chat-label">新对话</span>
                </button>
              </div>
              {historyOpen ? <HistoryPopover onClose={() => setHistoryOpen(false)} selectedProject={selectedProject} /> : null}
            </header>

            <ChatRuntimePanel />
          </div>
        </section>
      </section>
    </section>
  );
}

function SettingsHost({ setMode }: { setMode: (mode: AppMode) => void }) {
  return (
    <section className="settings-host">
      <FunctionalSettingsPage onBack={() => setMode("workbench")} />
    </section>
  );
}

function HistoryPopover({
  onClose,
  selectedProject
}: {
  onClose: () => void;
  selectedProject: { id: string; name: string; path: string } | null;
}) {
  const sessions = useChatStore((state) => state.sessions);
  const currentSession = useChatStore((state) => state.currentSession);
  const loadSession = useChatStore((state) => state.loadSession);
  const deleteSession = useChatStore((state) => state.deleteSession);
  const projectSessions = selectedProject
    ? sessions.filter((session) => session.projectPath === selectedProject.path)
    : [];

  function openSession(session: ChatSessionRecord) {
    if (loadSession(session.id)) {
      onClose();
    }
  }

  return (
    <div className="history-popover">
      <div className="popover-notch" />
      <button type="button" className="popover-close" onClick={onClose} aria-label="关闭">
        <X size={17} />
      </button>
      <h3>会话历史记录</h3>
      <strong>{selectedProject?.name ?? "未选择项目"}</strong>
      <p>{selectedProject ? selectedProject.path : "选择项目后查看会话历史。"}</p>
      {projectSessions.length === 0 ? (
        <div className="history-empty">当前项目暂无可显示的历史记录。</div>
      ) : (
        <div className="history-list">
          {projectSessions.map((session) => (
            <div key={session.id} className={`history-item ${currentSession?.id === session.id ? "active" : ""}`}>
              <button type="button" className="history-main" onClick={() => openSession(session)}>
                <span className={`history-status ${session.runStatus}`} />
                <span>
                  <b>{session.title}</b>
                  <small>
                    {session.cli} · {formatHistoryTime(session.updatedAt)}
                  </small>
                </span>
              </button>
              <button
                type="button"
                className="history-delete"
                aria-label={`删除 ${session.title}`}
                onClick={(event) => {
                  event.stopPropagation();
                  deleteSession(session.id);
                }}
              >
                <X size={12} />
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function formatHistoryTime(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }
  return new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false
  }).format(date);
}

export default App;
