import { useEffect } from "react";
import { Settings } from "lucide-react";
import type { FileTreeEntry } from "@shared/fileTree";
import { useProjectStore } from "../../stores/projectStore";
import { FileTreeView } from "./FileTreeView";
import { ProjectList } from "./ProjectList";

interface ProjectSidebarProps {
  chooseProjectPath?: () => Promise<string | null>;
  onOpenFile?: (entry: FileTreeEntry) => void;
  onOpenSettings?: () => void;
}

export function ProjectSidebar({ chooseProjectPath, onOpenFile, onOpenSettings }: ProjectSidebarProps) {
  const projects = useProjectStore((state) => state.projects);
  const selectedProjectId = useProjectStore((state) => state.selectedProjectId);
  const isLoadingProjects = useProjectStore((state) => state.isLoadingProjects);
  const projectError = useProjectStore((state) => state.projectError);
  const refreshProjects = useProjectStore((state) => state.refreshProjects);
  const addProject = useProjectStore((state) => state.addProject);
  const removeProject = useProjectStore((state) => state.removeProject);
  const selectProject = useProjectStore((state) => state.selectProject);
  const refreshDirectory = useProjectStore((state) => state.refreshDirectory);

  useEffect(() => {
    void refreshProjects();
  }, [refreshProjects]);

  useEffect(() => {
    if (selectedProjectId) {
      void refreshDirectory({ projectId: selectedProjectId, path: "" });
    }
  }, [refreshDirectory, selectedProjectId]);

  async function handleAddProject() {
    if (!chooseProjectPath) {
      return;
    }

    const path = await chooseProjectPath();
    if (path) {
      await addProject({ path });
    }
  }

  return (
    <aside className="mac-sidebar glass-panel">
      <ProjectList
        projects={projects}
        selectedProjectId={selectedProjectId}
        isLoading={isLoadingProjects}
        onAddProject={() => void handleAddProject()}
        onSelectProject={(projectId) => void selectProject({ projectId })}
        onRemoveProject={(projectId) => void removeProject({ projectId })}
      />
      {projectError ? <div className="sidebar-error">{projectError}</div> : null}
      <div className="sidebar-section file-block">
        <FileTreeView projectId={selectedProjectId} onOpenFile={onOpenFile} />
      </div>
      <button className="settings-entry" type="button" onClick={onOpenSettings}>
        <Settings size={17} />
        <span>acode 设置</span>
      </button>
    </aside>
  );
}
