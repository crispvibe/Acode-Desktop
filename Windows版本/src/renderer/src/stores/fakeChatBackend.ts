import type {
  ChatBackendEvent,
  ChatPanelBackend,
  ChatRunOptions,
  ChatSessionRecord,
  InteractiveResponse,
  PermissionDecision
} from "@shared/chat";

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, milliseconds));
}

async function* streamText(kind: "assistant" | "reasoning", text: string, delay: number, isInterrupted: () => boolean) {
  for (const chunk of text.match(/.{1,10}/gu) ?? []) {
    if (isInterrupted()) {
      return;
    }
    await sleep(delay);
    if (isInterrupted()) {
      return;
    }
    yield {
      type: "appendDelta",
      kind,
      text: chunk,
      status: "streaming"
    } satisfies ChatBackendEvent;
  }
}

export function createRendererFakeChatBackend(): ChatPanelBackend {
  let interrupted = false;

  return {
    async *start(prompt: string, options: ChatRunOptions, session: ChatSessionRecord | null) {
      interrupted = false;
      const sessionID = session?.externalSessionID ?? `local-${crypto.randomUUID()}`;
      yield { type: "sessionID", externalSessionID: sessionID };
      yield { type: "updateStreamingStatus", status: `连接 ${options.cli}` };

      await sleep(130);
      if (interrupted) {
        yield { type: "finished" };
        return;
      }

      yield* streamText("reasoning", "正在读取当前项目上下文，并准备按 Windows 端框架继续实现。", 28, () => interrupted);
      yield { type: "finishStreamingMessage", kind: "reasoning", status: "done" };

      if (interrupted) {
        yield { type: "finished" };
        return;
      }

      yield {
        type: "appendMessage",
        kind: "toolCall",
        title: "project",
        text: options.projectPath || "未选择项目",
        status: "done"
      };
      yield { type: "tokenUsage", used: 1280, total: 200_000, output: 0 };

      const answer =
        `收到：${prompt}\n\n` +
        "当前 Windows 对话链路已经接到同一套 chat store：用户输入会进入队列，运行中会流式输出，停止按钮会中断当前 run。下一步可以把这个 fake backend 换成真实 Claude Code / Codex 进程桥接。";

      yield* streamText("assistant", answer, 24, () => interrupted);
      yield { type: "tokenUsage", used: 1640, total: 200_000, output: answer.length };
      yield { type: "finished" };
    },

    interrupt() {
      interrupted = true;
    },

    respondToPermission(_requestID: string, _decision: PermissionDecision) {
      return false;
    },

    respondToInteractiveRequest(_requestID: string, _response: InteractiveResponse) {
      return false;
    },

    sendCompact() {
      return false;
    }
  };
}
