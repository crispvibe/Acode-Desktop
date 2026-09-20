import type {
  ChatBackendEvent,
  ChatPanelBackend,
  ChatRunOptions,
  ChatSessionRecord,
  InteractiveResponse,
  PermissionDecision
} from "../../shared/chat.js";

interface PendingPermission {
  resolve: (decision: PermissionDecision) => void;
}

interface PendingInteractive {
  resolve: (response: InteractiveResponse) => void;
}

export interface FakeChatBackendOptions {
  chunkDelayMs?: number;
  sessionPrefix?: string;
}

function createID(prefix: string): string {
  return `${prefix}-${crypto.randomUUID()}`;
}

function wait(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(signal.reason ?? new DOMException("Interrupted", "AbortError"));
      return;
    }

    const timer = setTimeout(resolve, ms);
    signal.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        reject(signal.reason ?? new DOMException("Interrupted", "AbortError"));
      },
      { once: true }
    );
  });
}

function splitForStreaming(text: string): string[] {
  const chunks = text.match(/.{1,18}(\s|$)|.{1,18}/g);
  return chunks?.filter((chunk) => chunk.length > 0) ?? [text];
}

export class FakeChatBackend implements ChatPanelBackend {
  private readonly chunkDelayMs: number;
  private readonly sessionPrefix: string;
  private abortController: AbortController | null = null;
  private pendingPermissions = new Map<string, PendingPermission>();
  private pendingInteractive = new Map<string, PendingInteractive>();

  constructor(options: FakeChatBackendOptions = {}) {
    this.chunkDelayMs = options.chunkDelayMs ?? 24;
    this.sessionPrefix = options.sessionPrefix ?? "fake";
  }

  async *start(
    prompt: string,
    options: ChatRunOptions,
    session: ChatSessionRecord | null
  ): AsyncIterable<ChatBackendEvent> {
    this.interrupt();
    const abortController = new AbortController();
    this.abortController = abortController;
    const signal = abortController.signal;
    const externalSessionID = session?.externalSessionID ?? createID(this.sessionPrefix);
    const requestID = createID("fake-run");

    try {
      yield { type: "sessionID", externalSessionID };
      yield { type: "updateStreamingStatus", status: `启动 ${options.cli}` };
      await wait(this.chunkDelayMs, signal);

      yield {
        type: "appendDelta",
        kind: "reasoning",
        title: "thinking",
        text: "Reading request and preparing a fake streaming response...\n",
        status: "streaming",
        requestID
      };
      await wait(this.chunkDelayMs, signal);
      yield { type: "finishStreamingMessage", kind: "reasoning", requestID, status: "done" };

      if (prompt.toLowerCase().includes("permission")) {
        const permissionID = createID("permission");
        yield {
          type: "permissionRequest",
          id: permissionID,
          title: "Fake permission request",
          text: "Allow the fake backend to continue this simulated tool call?"
        };
        const decision = await this.waitForPermission(permissionID, signal);
        if (decision === "deny") {
          yield { type: "failed", message: "Fake backend permission denied." };
          return;
        }
      }

      if (prompt.toLowerCase().includes("choose")) {
        const interactiveID = createID("interactive");
        yield {
          type: "interactiveRequest",
          request: {
            id: interactiveID,
            title: "Fake choice",
            prompt: "Pick one fake path before the stream continues.",
            mode: "singleChoice",
            options: [
              { id: "fast", label: "Fast", detail: "Short fake response" },
              { id: "detailed", label: "Detailed", detail: "Longer fake response" }
            ],
            allowCustomInput: true,
            placeholder: "Custom fake choice",
            status: "waiting"
          }
        };
        await this.waitForInteractive(interactiveID, signal);
      }

      yield {
        type: "appendMessage",
        kind: "toolCall",
        title: "FakeBackend",
        subtitle: options.projectPath,
        text: "Simulating backend stream",
        status: "running",
        requestID
      };
      await wait(this.chunkDelayMs, signal);
      yield {
        type: "appendMessage",
        kind: "toolResult",
        title: "FakeBackend",
        text: "fake backend ready",
        status: "done",
        requestID
      };

      const response = [
        `Fake ${options.cli} stream for "${prompt.trim()}".`,
        "This exercises assistant deltas, tool rows, token usage, and queue handoff without touching real Claude/Codex.",
        `Model=${options.modelID}; permission=${options.permissionMode}; effort=${options.reasoningEffort}.`
      ].join("\n\n");

      for (const chunk of splitForStreaming(response)) {
        await wait(this.chunkDelayMs, signal);
        yield {
          type: "appendDelta",
          kind: "assistant",
          title: "assistant",
          text: chunk,
          status: "streaming",
          requestID
        };
      }

      yield { type: "finishStreamingMessage", kind: "assistant", requestID, status: "done" };
      yield { type: "tokenUsage", used: Math.min(200_000, prompt.length * 3 + response.length), total: 200_000, output: response.length };
      yield { type: "finished" };
    } catch (error) {
      if (signal.aborted) {
        yield { type: "failed", message: "Fake backend interrupted." };
        return;
      }
      yield { type: "failed", message: error instanceof Error ? error.message : String(error) };
    } finally {
      if (this.abortController === abortController) {
        this.abortController = null;
      }
      this.pendingPermissions.clear();
      this.pendingInteractive.clear();
    }
  }

  interrupt(): void {
    this.abortController?.abort(new DOMException("Interrupted", "AbortError"));
    this.abortController = null;
    this.pendingPermissions.clear();
    this.pendingInteractive.clear();
  }

  respondToPermission(requestID: string, decision: PermissionDecision): boolean {
    const pending = this.pendingPermissions.get(requestID);
    if (!pending) {
      return false;
    }
    this.pendingPermissions.delete(requestID);
    pending.resolve(decision);
    return true;
  }

  respondToInteractiveRequest(requestID: string, response: InteractiveResponse): boolean {
    const pending = this.pendingInteractive.get(requestID);
    if (!pending) {
      return false;
    }
    this.pendingInteractive.delete(requestID);
    pending.resolve(response);
    return true;
  }

  sendCompact(): boolean {
    return false;
  }

  private waitForPermission(requestID: string, signal: AbortSignal): Promise<PermissionDecision> {
    return new Promise((resolve, reject) => {
      this.pendingPermissions.set(requestID, { resolve });
      signal.addEventListener(
        "abort",
        () => {
          this.pendingPermissions.delete(requestID);
          reject(signal.reason ?? new DOMException("Interrupted", "AbortError"));
        },
        { once: true }
      );
    });
  }

  private waitForInteractive(requestID: string, signal: AbortSignal): Promise<InteractiveResponse> {
    return new Promise((resolve, reject) => {
      this.pendingInteractive.set(requestID, { resolve });
      signal.addEventListener(
        "abort",
        () => {
          this.pendingInteractive.delete(requestID);
          reject(signal.reason ?? new DOMException("Interrupted", "AbortError"));
        },
        { once: true }
      );
    });
  }
}

export function createFakeChatBackend(options?: FakeChatBackendOptions): ChatPanelBackend {
  return new FakeChatBackend(options);
}
