import { AlertTriangle, FileText, Loader2, Plus, Save, X } from "lucide-react";
import { useMemo, useRef } from "react";
import type { ChangeEvent, ReactNode, UIEvent } from "react";
import type { EditorCursorPosition, EditorTab } from "@shared/editor";
import { useEditorStore } from "@renderer/src/stores/editorStore";

interface EditorAreaProps {
  onOpenFilePath?: () => void;
}

export function EditorArea({ onOpenFilePath }: EditorAreaProps) {
  const tabs = useEditorStore((state) => state.tabs);
  const selectedTabId = useEditorStore((state) => state.selectedTabId);
  const closeConfirmation = useEditorStore((state) => state.closeConfirmation);
  const selectedTab = tabs.find((tab) => tab.id === selectedTabId) ?? null;

  return (
    <section className="editor-shell" aria-label="编辑器">
      <EditorTabStrip tabs={tabs} selectedTabId={selectedTabId} onOpenFilePath={onOpenFilePath} />
      <div className="editor-body">
        {selectedTab ? <EditorTabContent tab={selectedTab} /> : <EmptyEditor onOpenFilePath={onOpenFilePath} />}
      </div>
      <EditorStatusBar tab={selectedTab} />
      {closeConfirmation ? <DirtyCloseDialog title={closeConfirmation.title} /> : null}
    </section>
  );
}

interface EditorTabStripProps {
  tabs: EditorTab[];
  selectedTabId: string | null;
  onOpenFilePath?: () => void;
}

export function EditorTabStrip({ tabs, selectedTabId, onOpenFilePath }: EditorTabStripProps) {
  const selectTab = useEditorStore((state) => state.selectTab);
  const requestCloseTab = useEditorStore((state) => state.requestCloseTab);

  return (
    <div className="editor-tab-strip window-drag">
      <div className="editor-tab-scroller">
        {tabs.map((tab) => {
          const selected = tab.id === selectedTabId;
          return (
            <button
              key={tab.id}
              type="button"
              onClick={() => selectTab(tab.id)}
              className={`editor-tab window-no-drag ${selected ? "selected" : ""}`}
              title={tab.path}
            >
              <span className="editor-tab-title">{tab.title}</span>
              {tab.dirty ? <span className="editor-tab-dirty" aria-label="未保存" /> : null}
              <span
                role="button"
                tabIndex={0}
                aria-label={`关闭 ${tab.title}`}
                className="editor-tab-close"
                onClick={(event) => {
                  event.stopPropagation();
                  requestCloseTab(tab.id);
                }}
                onKeyDown={(event) => {
                  if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    event.stopPropagation();
                    requestCloseTab(tab.id);
                  }
                }}
              >
                <X size={12} />
              </span>
            </button>
          );
        })}
        <button
          type="button"
          aria-label="打开文件"
          onClick={onOpenFilePath}
          className="editor-tab-add window-no-drag"
        >
          <Plus size={15} />
        </button>
      </div>
    </div>
  );
}

function EditorTabContent({ tab }: { tab: EditorTab }) {
  if (tab.loading) {
    return (
      <EditorMessage
        icon={<Loader2 size={24} />}
        title={`正在加载 ${tab.title}`}
        message="文件内容会在读取完成后显示。"
      />
    );
  }

  if (tab.error) {
    return <EditorMessage icon={<AlertTriangle size={24} />} title={`无法打开 ${tab.title}`} message={tab.error} />;
  }

  return <EditorTextArea tab={tab} />;
}

function EditorTextArea({ tab }: { tab: EditorTab }) {
  const gutterRef = useRef<HTMLDivElement | null>(null);
  const updateText = useEditorStore((state) => state.updateText);
  const updateCursor = useEditorStore((state) => state.updateCursor);

  const lineNumbers = useMemo(() => {
    const count = Math.max(1, tab.text.split("\n").length);
    return Array.from({ length: count }, (_, index) => index + 1);
  }, [tab.text]);

  function updateCursorFromTarget(target: HTMLTextAreaElement) {
    updateCursor(tab.id, cursorForOffset(target.value, target.selectionStart));
  }

  function handleChange(event: ChangeEvent<HTMLTextAreaElement>) {
    updateText(tab.id, event.target.value);
    updateCursorFromTarget(event.target);
  }

  function handleScroll(event: UIEvent<HTMLTextAreaElement>) {
    if (gutterRef.current) {
      gutterRef.current.scrollTop = event.currentTarget.scrollTop;
    }
  }

  return (
    <div className="editor-frame">
      <div ref={gutterRef} className="editor-gutter" aria-hidden="true">
        {lineNumbers.map((line) => (
          <div key={line} className="editor-gutter-line">
            {line}
          </div>
        ))}
      </div>
      <textarea
        spellCheck={false}
        value={tab.text}
        onChange={handleChange}
        onClick={(event) => updateCursorFromTarget(event.currentTarget)}
        onKeyUp={(event) => updateCursorFromTarget(event.currentTarget)}
        onSelect={(event) => updateCursorFromTarget(event.currentTarget)}
        onScroll={handleScroll}
        className="editor-textarea"
        aria-label={tab.title}
      />
    </div>
  );
}

function EmptyEditor({ onOpenFilePath }: EditorAreaProps) {
  return (
    <div className="editor-empty">
      <FileText size={28} />
      <div className="editor-empty-title">从左侧文件树打开文件</div>
      <button type="button" onClick={onOpenFilePath} className="editor-open-button">
        打开文件
      </button>
    </div>
  );
}

function EditorMessage({ icon, title, message }: { icon: ReactNode; title: string; message: string }) {
  return (
    <div className="editor-empty">
      {icon}
      <div className="editor-empty-title">{title}</div>
      <div className="editor-empty-message">{message}</div>
    </div>
  );
}

function EditorStatusBar({ tab }: { tab: EditorTab | null }) {
  if (!tab) {
    return <footer className="editor-status-bar">未打开文件</footer>;
  }

  return (
    <footer className="editor-status-bar">
      <span className="editor-status-file">{tab.title}</span>
      <span>{formatBytes(tab.byteCount)}</span>
      <span>
        第 {tab.cursor.line} 行，第 {tab.cursor.column} 列
      </span>
      <span className="editor-status-spacer" />
      <span>{tab.modifiedAt ? `修改于 ${formatRelativeTime(tab.modifiedAt)}` : tab.loading ? "加载中" : ""}</span>
    </footer>
  );
}

function DirtyCloseDialog({ title }: { title: string }) {
  const resolveCloseConfirmation = useEditorStore((state) => state.resolveCloseConfirmation);

  return (
    <div className="editor-dialog-backdrop">
      <div className="editor-dialog" role="dialog" aria-modal="true" aria-label="未保存修改">
        <div className="editor-dialog-title">{`保存对“${title}”的修改？`}</div>
        <div className="editor-dialog-body">不保存会丢失当前编辑内容。</div>
        <div className="editor-dialog-actions">
          <button type="button" className="editor-secondary-button" onClick={() => void resolveCloseConfirmation("cancel")}>
            取消
          </button>
          <button type="button" className="editor-secondary-button" onClick={() => void resolveCloseConfirmation("discard")}>
            放弃
          </button>
          <button type="button" className="editor-primary-button" onClick={() => void resolveCloseConfirmation("save")}>
            <Save size={13} />
            保存
          </button>
        </div>
      </div>
    </div>
  );
}

function cursorForOffset(text: string, offset: number): EditorCursorPosition {
  const boundedOffset = Math.min(Math.max(offset, 0), text.length);
  let line = 1;
  let columnStart = 0;
  for (let index = 0; index < boundedOffset; index += 1) {
    if (text.charCodeAt(index) === 10) {
      line += 1;
      columnStart = index + 1;
    }
  }
  return { line, column: boundedOffset - columnStart + 1 };
}

function formatBytes(value: number): string {
  if (value < 1024) {
    return `${value} B`;
  }
  if (value < 1024 * 1024) {
    return `${(value / 1024).toFixed(1)} KB`;
  }
  return `${(value / 1024 / 1024).toFixed(1)} MB`;
}

function formatRelativeTime(timestamp: number): string {
  const formatter = new Intl.RelativeTimeFormat("zh-CN", { numeric: "auto" });
  const seconds = Math.round((timestamp - Date.now()) / 1000);
  const absSeconds = Math.abs(seconds);
  if (absSeconds < 60) {
    return formatter.format(seconds, "second");
  }
  const minutes = Math.round(seconds / 60);
  if (Math.abs(minutes) < 60) {
    return formatter.format(minutes, "minute");
  }
  const hours = Math.round(minutes / 60);
  if (Math.abs(hours) < 24) {
    return formatter.format(hours, "hour");
  }
  return formatter.format(Math.round(hours / 24), "day");
}
