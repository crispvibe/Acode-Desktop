import { ChevronRight, FileText, Folder, RefreshCw } from "lucide-react";
import type { CSSProperties } from "react";
import type { FileTreeEntry } from "@shared/fileTree";
import { useEditorStore } from "../../stores/editorStore";
import { projectDirectoryKey, useProjectStore } from "../../stores/projectStore";

interface FileTreeViewProps {
  projectId: string | null;
  onOpenFile?: (entry: FileTreeEntry) => void;
}

function rowIndent(level: number): CSSProperties {
  return { paddingLeft: `${8 + level * 14}px` };
}

function normalizedPath(value: string): string {
  return value.replaceAll("\\", "/");
}

export function FileTreeView({ projectId, onOpenFile }: FileTreeViewProps) {
  const directories = useProjectStore((state) => state.directories);
  const expandedDirectoryKeys = useProjectStore((state) => state.expandedDirectoryKeys);
  const refreshDirectory = useProjectStore((state) => state.refreshDirectory);
  const toggleDirectory = useProjectStore((state) => state.toggleDirectory);
  const selectedTab = useEditorStore((state) => state.selectedTab());

  if (!projectId) {
    return <div className="sidebar-empty">选择项目后查看文件</div>;
  }

  const rootKey = projectDirectoryKey(projectId, "");
  const root = directories[rootKey];

  async function handleRefresh() {
    await refreshDirectory({ projectId: projectId ?? undefined, path: "" });
  }

  function renderEntry(entry: FileTreeEntry, level: number) {
    const key = projectDirectoryKey(entry.projectId, entry.relativePath);
    const isExpanded = Boolean(expandedDirectoryKeys[key]);
    const childState = directories[key];
    const isDirectory = entry.kind === "directory";
    const isSelected = !isDirectory && normalizedPath(entry.path) === normalizedPath(selectedTab?.path ?? "");

    return (
      <div className="file-tree-group" key={entry.id}>
        <button
          className={`file-row ${isDirectory ? "directory" : "file"} ${isSelected ? "selected" : ""}`}
          type="button"
          style={rowIndent(level)}
          aria-expanded={isDirectory ? isExpanded : undefined}
          aria-pressed={isSelected || undefined}
          onClick={() => {
            if (isDirectory) {
              void toggleDirectory(entry);
              return;
            }
            onOpenFile?.(entry);
          }}
          title={entry.path}
        >
          <span className="chevron-slot" aria-hidden="true">
            {isDirectory ? <ChevronRight className={isExpanded ? "chevron expanded" : "chevron"} size={13} /> : null}
          </span>
          {isDirectory ? <Folder className="tree-icon folder-icon" size={14} /> : <FileText className="tree-icon file-icon" size={14} />}
          <span className="tree-label">{entry.name}</span>
        </button>
        {isDirectory && isExpanded ? (
          <div className="file-tree-children">
            {childState?.isLoading ? <div className="file-row placeholder" style={rowIndent(level + 1)}>加载中...</div> : null}
            {childState?.error ? <div className="file-row error" style={rowIndent(level + 1)}>{childState.error}</div> : null}
            {childState && !childState.isLoading && !childState.error && childState.entries.length === 0 ? (
              <div className="file-row placeholder" style={rowIndent(level + 1)}>空文件夹</div>
            ) : null}
            {childState?.entries.map((child) => renderEntry(child, level + 1))}
            {childState?.truncated ? <div className="file-row placeholder" style={rowIndent(level + 1)}>已截断</div> : null}
          </div>
        ) : null}
      </div>
    );
  }

  return (
    <div className="file-tree">
      <div className="section-header small">
        <span>文件</span>
        <button className="round-button small" type="button" onClick={() => void handleRefresh()} aria-label="刷新文件">
          <RefreshCw size={14} />
        </button>
      </div>
      {!root || root.isLoading ? <div className="sidebar-empty">加载中...</div> : null}
      {root?.error ? <div className="sidebar-error">{root.error}</div> : null}
      {root && !root.isLoading && !root.error && root.entries.length === 0 ? <div className="sidebar-empty">暂无文件</div> : null}
      <div className="file-list">{root?.entries.map((entry) => renderEntry(entry, 0))}</div>
      {root?.truncated ? <div className="sidebar-empty">当前目录文件较多，已截断显示</div> : null}
    </div>
  );
}
