import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it } from "vitest";
import { ChatRuntimePanel } from "../../../src/renderer/src/components/chat/ChatRuntimePanel";
import { FakeChatBackend } from "../../../src/main/chat/fakeBackend";
import { useChatStore } from "../../../src/renderer/src/stores/chatStore";
import { useProjectStore } from "../../../src/renderer/src/stores/projectStore";
import { useSettingsStore } from "../../../src/renderer/src/stores/settingsStore";
import { DEFAULT_APP_SETTINGS } from "../../../src/shared/settings";
import type { ChatMessage, ChatSessionRecord } from "../../../src/shared/chat";

const now = new Date("2026-05-28T00:00:00.000Z").toISOString();
const project = {
  id: "00000000-0000-4000-8000-000000000001",
  name: "Project One",
  path: "/tmp/project-one",
  createdAt: now,
  updatedAt: now,
  lastOpenedAt: null
};

beforeEach(() => {
  useChatStore.setState(useChatStore.getInitialState(), true);
  useProjectStore.setState({
    projects: [project],
    selectedProjectId: project.id,
    expandedDirectoryKeys: {},
    directories: {},
    isLoadingProjects: false,
    projectError: null
  });
  useSettingsStore.setState({
    settings: DEFAULT_APP_SETTINGS,
    loading: false,
    saving: false,
    error: null,
    appInfo: null,
    lastProbe: null
  });
  useChatStore.getState().setBackend(new FakeChatBackend({ chunkDelayMs: 1 }));
});

describe("ChatRuntimePanel", () => {
  it("hides raw protocol messages from the main transcript", () => {
    setVisibleMessages([message({ kind: "rawOutput", text: '{"internal":true}' })]);

    render(<ChatRuntimePanel />);

    expect(screen.getByText("内部事件已隐藏，避免把原始协议内容直接显示在主对话中。")).toBeInTheDocument();
    expect(screen.queryByText(/internal/u)).not.toBeInTheDocument();
  });

  it("renders assistant fenced code as a code block", () => {
    setVisibleMessages([message({ kind: "assistant", text: "Before\n\n```ts\nconst value = 1;\n```" })]);

    render(<ChatRuntimePanel />);

    expect(screen.getByText("Before")).toBeInTheDocument();
    expect(screen.getByText("const value = 1;")).toBeInTheDocument();
  });

  it("does not submit Enter while IME composition is active", () => {
    render(<ChatRuntimePanel />);

    const composer = screen.getByPlaceholderText("输入你的需求");
    fireEvent.compositionStart(composer);
    fireEvent.change(composer, { target: { value: "ni" } });
    fireEvent.keyDown(composer, { key: "Enter", shiftKey: false });

    expect(useChatStore.getState().messages).toHaveLength(0);
  });
});

function setVisibleMessages(messages: ChatMessage[]): void {
  const session: ChatSessionRecord = {
    id: "session-1",
    title: "Session",
    projectPath: project.path,
    projectName: project.name,
    cli: "claude",
    modelID: "default",
    permissionMode: "ask",
    reasoningEffort: "medium",
    externalSessionID: null,
    createdAt: now,
    updatedAt: now,
    runStatus: "completed",
    statusText: "完成",
    queuedRequests: [],
    lastCompletedAt: now,
    activeRunStartedAt: null,
    activeRunRequest: null
  };
  useChatStore.setState({
    messages,
    sessions: [session],
    sessionMessages: { [session.id]: messages },
    currentSession: session,
    status: "completed",
    statusText: "完成"
  });
}

function message(overrides: Partial<ChatMessage>): ChatMessage {
  return {
    id: `message-${overrides.kind ?? "assistant"}`,
    sessionID: "session-1",
    kind: "assistant",
    text: "",
    status: "done",
    createdAt: now,
    ...overrides
  } as ChatMessage;
}
