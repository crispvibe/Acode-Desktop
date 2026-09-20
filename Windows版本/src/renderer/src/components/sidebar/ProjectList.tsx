import { Folder, Plus, Trash2 } from "lucide-react";
import type { Project } from "@shared/project";

interface ProjectListProps {
  projects: Project[];
  selectedProjectId: string | null;
  isLoading: boolean;
  onAddProject?: () => void;
  onSelectProject: (projectId: string) => void;
  onRemoveProject: (projectId: string) => void;
}

export function ProjectList({
  projects,
  selectedProjectId,
  isLoading,
  onAddProject,
  onSelectProject,
  onRemoveProject
}: ProjectListProps) {
  return (
    <div className="sidebar-section project-block">
      <div className="section-header">
        <span>项目</span>
        <button className="round-button project-add" type="button" onClick={onAddProject} aria-label="添加项目">
          <Plus size={12} strokeWidth={2.6} />
        </button>
      </div>
      <div className="project-list">
        {isLoading ? <div className="sidebar-empty">加载中...</div> : null}
        {!isLoading && projects.length === 0 ? <div className="sidebar-empty">暂无项目</div> : null}
        {projects.map((project) => (
          <button
            className={`project-row ${project.id === selectedProjectId ? "selected" : ""}`}
            key={project.id}
            type="button"
            onClick={() => onSelectProject(project.id)}
            title={project.path}
          >
            <Folder className="project-folder-icon" size={13} />
            <span>{project.name}</span>
            <span className="project-activity-slot" />
            <span className="project-remove-slot">
	              <Trash2
	                className="row-trash"
	                size={10}
	                onClick={(event) => {
	                  event.stopPropagation();
	                  if (window.confirm(`从项目列表移除“${project.name}”？`)) {
	                    onRemoveProject(project.id);
	                  }
	                }}
	              />
            </span>
          </button>
        ))}
      </div>
    </div>
  );
}
