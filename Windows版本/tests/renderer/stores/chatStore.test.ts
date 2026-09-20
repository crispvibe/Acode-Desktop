import { beforeEach, describe, expect, it } from "vitest";
import { FakeChatBackend } from "../../../src/main/chat/fakeBackend";
import { DEFAULT_APP_SETTINGS } from "../../../src/shared/settings";
import { useChatStore } from "../../../src/renderer/src/stores/chatStore";
import { useSettingsStore } from "../../../src/renderer/src/stores/settingsStore";
import type { ChatMessage, ChatSessionRecord, ProjectSnapshot, QueuedChatRequest } from "../../../src/shared/chat";

const project: ProjectSnapshot = {
  id: "project-1",
  name: "Project One",
  path: "/tmp/project-one"
};

beforeEach(() => {
  useChatStore.setState(useChatStore.getInitialState(), true);
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

describe("chat store with fake backend", () => {
  it("reduces a streaming backend run into visible chat messages", async () => {
    const didSend = useChatStore.getState().send({
      text: "hello",
      project,
      cli: "claude",
      sessionMode: "newSession"
    });

    expect(didSend).toBe(true);
    await waitForStore(() => useChatStore.getState().status === "completed");

    const messages = useChatStore.getState().messages;
    expect(messages.map((message) => message.kind)).toContain("user");
    expect(messages.map((message) => message.kind)).toContain("reasoning");
    // A streaming toolCall finalizes in place when its toolResult arrives (same requestID),
    // so the transcript has exactly one row for the invocation — no duplicate cards.
    const toolMessages = messages.filter((message) => message.kind === "toolCall" || message.kind === "toolResult");
    expect(toolMessages).toHaveLength(1);
    expect(toolMessages[0]?.text).toContain("fake backend ready");
    expect(messages.map((message) => message.kind)).toContain("assistant");
    expect(messages.find((message) => message.kind === "assistant")?.text).toContain("Fake claude stream");
    expect(useChatStore.getState().tokensUsed).toBeGreaterThan(0);
  });

  it("queues a second request while the active run is waiting for input", async () => {
    useChatStore.getState().send({
      text: "choose a path",
      project,
      cli: "claude",
      sessionMode: "newSession"
    });

    await waitForStore(() => useChatStore.getState().status === "waitingInput");

    const didQueue = useChatStore.getState().send({
      text: "run after this",
      project,
      cli: "claude",
      sessionMode: "continueLast"
    });

    expect(didQueue).toBe(true);
    expect(useChatStore.getState().queuedRequests).toHaveLength(1);
    expect(useChatStore.getState().queuedRequests[0]?.displayText).toBe("run after this");
  });

  it("keeps permission requests interactive until a decision is sent", async () => {
    useChatStore.getState().send({
      text: "permission please",
      project,
      cli: "claude",
      sessionMode: "newSession"
    });

    await waitForStore(() => useChatStore.getState().status === "waitingPermission");
    const permissionMessage = useChatStore.getState().messages.find((message) => message.kind === "permissionRequest");

    expect(permissionMessage?.status).toBe("waiting");
    expect(permissionMessage?.requestID).toBeTruthy();

    const didRespond = await useChatStore.getState().respondToPermission(permissionMessage?.requestID ?? "", "allow");

    expect(didRespond).toBe(true);
    await waitForStore(() => useChatStore.getState().status === "completed");
    expect(useChatStore.getState().messages.find((message) => message.id === permissionMessage?.id)?.status).toBe("allowed");
  });

  it("marks the permission card failed when the backend rejects the response", async () => {
    // 模拟不支持的 CLI / stdin 写失败：backend 对真实 requestID 也回 false。
    const failingBackend = new FakeChatBackend({ chunkDelayMs: 1 });
    failingBackend.respondToPermission = () => false;
    useChatStore.getState().setBackend(failingBackend);
    useChatStore.getState().send({
      text: "permission please",
      project,
      cli: "claude",
      sessionMode: "newSession"
    });

    await waitForStore(() => useChatStore.getState().status === "waitingPermission");
    const permissionMessage = useChatStore.getState().messages.find((message) => message.kind === "permissionRequest");
    expect(permissionMessage?.status).toBe("waiting");

    const didRespond = await useChatStore.getState().respondToPermission(permissionMessage?.requestID ?? "", "allow");

    expect(didRespond).toBe(false);
    const failed = useChatStore.getState().messages.find((message) => message.id === permissionMessage?.id);
    expect(failed?.status).toBe("failed");
    expect(useChatStore.getState().messages.some((message) => message.kind === "error")).toBe(true);
    expect(useChatStore.getState().status).toBe("failed");
  });

  it("coalesces rapid appendDelta events and flushes them in order", async () => {
    const createdAt = new Date().toISOString();
    const session: ChatSessionRecord = {
      id: "session-delta",
      cli: "claude",
      projectName: project.name,
      projectPath: project.path,
      title: "Delta session",
      modelID: "default",
      permissionMode: "ask",
      reasoningEffort: "medium",
      externalSessionID: null,
      createdAt,
      updatedAt: createdAt,
      runStatus: "running",
      statusText: "streaming",
      queuedRequests: [],
      lastCompletedAt: null,
      activeRunStartedAt: createdAt,
      activeRunRequest: null
    };
    useChatStore.getState().hydrateSessions({
      sessions: [session],
      sessionMessages: { [session.id]: [] },
      currentSessionId: session.id
    });

    const applyEvent = useChatStore.getState().applyEvent;
    applyEvent({ type: "appendDelta", kind: "assistant", text: "alpha" });
    applyEvent({ type: "appendDelta", kind: "assistant", text: " beta" });
    applyEvent({ type: "appendDelta", kind: "assistant", text: " gamma" });

    // 第一块即时落地，其余进 90ms 合帧 buffer——此刻文本还不是完整值。
    const streaming = useChatStore.getState().messages.find((message) => message.kind === "assistant");
    expect(streaming?.text).toBe("alpha");
    expect(streaming?.isStreaming).toBe(true);

    await waitForStore(() => useChatStore.getState().messages.find((message) => message.kind === "assistant")?.text === "alpha beta gamma");

    // 终态事件前必须 flush：finish 之后文本完整、流式标记清除。
    applyEvent({ type: "finished" });
    const finished = useChatStore.getState().messages.find((message) => message.kind === "assistant");
    expect(finished?.text).toBe("alpha beta gamma");
    expect(finished?.isStreaming).toBe(false);
  });

  it("marks restored running sessions as interrupted failures", () => {
    const createdAt = new Date().toISOString();
    const activeRunRequest: QueuedChatRequest = {
      id: "request-stale",
      text: "choose a path",
      displayText: "choose a path",
      attachments: [],
      project,
      cli: "claude",
      modelID: "default",
      permissionMode: "ask",
      reasoningEffort: "medium",
      sessionMode: "newSession",
      createdAt
    };
    const session: ChatSessionRecord = {
      id: "session-stale",
      cli: "claude",
      projectName: project.name,
      projectPath: project.path,
      title: "Stale session",
      modelID: "default",
      permissionMode: "ask",
      reasoningEffort: "medium",
      externalSessionID: null,
      createdAt,
      updatedAt: createdAt,
      runStatus: "waitingInput",
      statusText: "等待输入",
      queuedRequests: [activeRunRequest],
      lastCompletedAt: null,
      activeRunStartedAt: createdAt,
      activeRunRequest
    };
    const messages: ChatMessage[] = [
      {
        id: "message-streaming",
        sessionID: session.id,
        kind: "assistant",
        text: "partial",
        status: "streaming",
        createdAt,
        isStreaming: true
      },
      {
        id: "message-interactive",
        sessionID: session.id,
        kind: "interactiveRequest",
        title: "Choose",
        text: "Choose one",
        status: "waiting",
        createdAt,
        requestID: "interactive-1",
        interactiveRequest: {
          id: "interactive-1",
          title: "Choose",
          prompt: "Choose one",
          mode: "singleChoice",
          options: [],
          allowCustomInput: false,
          placeholder: "",
          status: "waiting"
        }
      }
    ];

    useChatStore.getState().hydrateSessions({
      sessions: [session],
      sessionMessages: { [session.id]: messages },
      currentSessionId: session.id
    });

    const state = useChatStore.getState();
    expect(state.status).toBe("failed");
    expect(state.statusText).toBe("已中断（应用已重启）");
    expect(state.currentSession?.runStatus).toBe("failed");
    expect(state.currentSession?.queuedRequests).toEqual([]);
    expect(state.currentSession?.activeRunRequest).toBeNull();
    expect(state.messages[0]).toMatchObject({ isStreaming: false, status: "interrupted" });
    expect(state.messages[1]?.interactiveRequest?.status).toBe("cancelled");
  });
});

async function waitForStore(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (predicate()) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error(`Timed out waiting for store condition. Last status: ${useChatStore.getState().status}`);
}
