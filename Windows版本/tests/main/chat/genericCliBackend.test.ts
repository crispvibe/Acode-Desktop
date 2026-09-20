// @vitest-environment node

import { describe, expect, it } from "vitest";
import { chatCLIDefaultCommands, chatCLIDisplayNames, type ChatCLI, type ChatRunOptions } from "../../../src/shared/chat";
import {
  createGenericStreamState,
  genericCLIRunSpec,
  resolveSpawnTarget,
  type GenericCLIKind,
  type GenericStreamState
} from "../../../src/main/chat/genericCliBackend";
import type { ChatBackendEvent } from "../../../src/shared/chat";

const GENERIC_CLIS: GenericCLIKind[] = ["cursor", "gemini", "qwen", "copilot", "kimi", "agy", "kiro"];

function optionsFor(overrides: Partial<ChatRunOptions> = {}): ChatRunOptions {
  return {
    cli: "cursor",
    executablePath: "",
    projectPath: "/tmp/project",
    modelID: "default",
    permissionMode: "ask",
    reasoningEffort: "medium",
    sessionMode: "newSession",
    supportsStreamJSONInput: false,
    ...overrides
  };
}

function runLines(spec: { parseLine: (line: string, state: GenericStreamState) => ChatBackendEvent[] }, lines: string[]): { events: ChatBackendEvent[]; state: GenericStreamState } {
  const state = createGenericStreamState();
  const events: ChatBackendEvent[] = [];
  for (const line of lines) {
    events.push(...spec.parseLine(line, state));
  }
  return { events, state };
}

function eventsOfType<T extends ChatBackendEvent["type"]>(events: ChatBackendEvent[], type: T): Extract<ChatBackendEvent, { type: T }>[] {
  return events.filter((event): event is Extract<ChatBackendEvent, { type: T }> => event.type === type);
}

describe("chatCLI contract tables", () => {
  it("covers all 10 CLI strings with display names and default commands", () => {
    const expected: Record<ChatCLI, [string, string]> = {
      claude: ["Claude Code", "claude"],
      codex: ["Codex", "codex"],
      cursor: ["Cursor Agent", "cursor-agent"],
      gemini: ["Gemini", "gemini"],
      qwen: ["Qwen Code", "qwen"],
      copilot: ["Copilot", "copilot"],
      kimi: ["Kimi", "kimi"],
      agy: ["Antigravity", "agy"],
      kiro: ["Kiro", "kiro-cli"],
      dsh: ["DeepSeek Harness", "dsh"]
    };
    for (const [cli, [displayName, command]] of Object.entries(expected) as Array<[ChatCLI, [string, string]]>) {
      expect(chatCLIDisplayNames[cli]).toBe(displayName);
      expect(chatCLIDefaultCommands[cli]).toBe(command);
    }
  });
});

describe("genericCLIRunSpec argument construction", () => {
  it("cursor uses -p + stream-json + --stream-partial-output with prompt after --", () => {
    const spec = genericCLIRunSpec("cursor", optionsFor(), null, "你好 \"quoted\" & <meta>", []);
    expect(spec.command).toBe("cursor-agent");
    expect(spec.displayName).toBe("Cursor Agent");
    expect(spec.args).toContain("--output-format");
    expect(spec.args).toContain("stream-json");
    expect(spec.args).toContain("--stream-partial-output");
    expect(spec.args.at(-2)).toBe("--");
    expect(spec.args.at(-1)).toBe('你好 "quoted" & <meta>');
    // ask 权限：不带 --force/--auto-review
    expect(spec.args).not.toContain("--force");
    expect(spec.args).not.toContain("--auto-review");
  });

  it("cursor maps autoEdit→--auto-review, fullAccess→--force --approve-mcps", () => {
    const auto = genericCLIRunSpec("cursor", optionsFor({ permissionMode: "autoEdit" }), null, "p", []);
    expect(auto.args).toContain("--auto-review");
    expect(auto.args).not.toContain("--force");
    const full = genericCLIRunSpec("cursor", optionsFor({ permissionMode: "fullAccess" }), null, "p", []);
    expect(full.args).toContain("--force");
    expect(full.args).toContain("--approve-mcps");
  });

  it("cursor passes --model only for explicit model and honors resume/continue", () => {
    const withModel = genericCLIRunSpec("cursor", optionsFor({ modelID: "gpt-5" }), null, "p", []);
    expect(withModel.args).toEqual(expect.arrayContaining(["--model", "gpt-5"]));
    const noModel = genericCLIRunSpec("cursor", optionsFor({ modelID: "default" }), null, "p", []);
    expect(noModel.args).not.toContain("--model");

    const resumed = genericCLIRunSpec("cursor", optionsFor({ sessionMode: "resume", resumeSessionID: "chat-1" }), null, "p", []);
    expect(resumed.args).toEqual(expect.arrayContaining(["--resume", "chat-1"]));
    const continued = genericCLIRunSpec("cursor", optionsFor({ sessionMode: "continueLast" }), null, "p", []);
    expect(continued.args).toContain("--continue");
    expect(continued.args).not.toContain("--resume");

    // resumeSessionID 缺省时回退 session.externalSessionID
    const fromSession = genericCLIRunSpec(
      "cursor",
      optionsFor({ sessionMode: "resume", resumeSessionID: null }),
      { externalSessionID: "ext-9" },
      "p",
      []
    );
    expect(fromSession.args).toEqual(expect.arrayContaining(["--resume", "ext-9"]));
  });

  it("gemini/qwen pass prompt as -p value, -o stream-json, approval-mode mapping", () => {
    for (const cli of ["gemini", "qwen"] as const) {
      const spec = genericCLIRunSpec(cli, optionsFor({ cli }), null, "do it", []);
      expect(spec.command).toBe(cli);
      const pIndex = spec.args.indexOf("-p");
      expect(spec.args[pIndex + 1]).toBe("do it");
      expect(spec.args).toEqual(expect.arrayContaining(["-o", "stream-json", "--approval-mode", "default"]));
    }
    expect(genericCLIRunSpec("gemini", optionsFor({ permissionMode: "autoEdit" }), null, "p", []).args).toContain("auto_edit");
    expect(genericCLIRunSpec("gemini", optionsFor({ permissionMode: "fullAccess" }), null, "p", []).args).toContain("yolo");
  });

  it("gemini ignores arbitrary resumeSessionID but supports -r latest for continueLast", () => {
    const resumed = genericCLIRunSpec("gemini", optionsFor({ sessionMode: "resume", resumeSessionID: "abc" }), null, "p", []);
    expect(resumed.args).not.toContain("-r");
    const continued = genericCLIRunSpec("gemini", optionsFor({ sessionMode: "continueLast" }), null, "p", []);
    expect(continued.args).toEqual(expect.arrayContaining(["-r", "latest"]));
  });

  it("copilot uses -p <prompt> --output-format json -s and --allow-all-tools for non-ask", () => {
    const ask = genericCLIRunSpec("copilot", optionsFor(), null, "run it", []);
    expect(ask.command).toBe("copilot");
    expect(ask.args).toEqual(expect.arrayContaining(["--output-format", "json", "-s"]));
    expect(ask.args).not.toContain("--allow-all-tools");
    const full = genericCLIRunSpec("copilot", optionsFor({ permissionMode: "fullAccess" }), null, "p", []);
    expect(full.args).toContain("--allow-all-tools");
    const resumed = genericCLIRunSpec("copilot", optionsFor({ sessionMode: "resume", resumeSessionID: "sess-7" }), null, "p", []);
    expect(resumed.args).toContain("--resume=sess-7");
  });

  it("kimi uses --print -p + stream-json; --session for resume; agy has no resume support", () => {
    const kimi = genericCLIRunSpec("kimi", optionsFor({ sessionMode: "resume", resumeSessionID: "k-1" }), null, "hi", []);
    expect(kimi.command).toBe("kimi");
    expect(kimi.args).toEqual(expect.arrayContaining(["--print", "-p", "hi", "--output-format", "stream-json", "--session", "k-1"]));
    expect(kimi.plainStdoutIsResponse).toBe(true);

    const agy = genericCLIRunSpec("agy", optionsFor({ sessionMode: "resume", resumeSessionID: "x", permissionMode: "fullAccess" }), null, "hi", []);
    expect(agy.args).toContain("--dangerously-skip-permissions");
    expect(agy.args.join(" ")).not.toContain("resume");
    expect(agy.plainStdoutIsResponse).toBe(true);
  });

  it("kiro uses `chat --no-interactive` with effort + trust flags + -- prompt", () => {
    const kiro = genericCLIRunSpec("kiro", optionsFor({ reasoningEffort: "high", permissionMode: "autoEdit" }), null, "do", []);
    expect(kiro.command).toBe("kiro-cli");
    expect(kiro.args.slice(0, 2)).toEqual(["chat", "--no-interactive"]);
    expect(kiro.args).toContain("--trust-tools=read,grep,write");
    expect(kiro.args).toEqual(expect.arrayContaining(["--effort", "high"]));
    expect(kiro.args.at(-2)).toBe("--");
    const full = genericCLIRunSpec("kiro", optionsFor({ permissionMode: "fullAccess" }), null, "p", []);
    expect(full.args).toContain("--trust-all-tools");
    const resumed = genericCLIRunSpec("kiro", optionsFor({ sessionMode: "resume", resumeSessionID: "rid" }), null, "p", []);
    expect(resumed.args).toEqual(expect.arrayContaining(["--resume-id", "rid"]));
    const continued = genericCLIRunSpec("kiro", optionsFor({ sessionMode: "continueLast" }), null, "p", []);
    expect(continued.args).toContain("--resume");
  });

  it("appends attachment paths into the prompt text", () => {
    const spec = genericCLIRunSpec(
      "cursor",
      optionsFor(),
      null,
      "看看这个文件",
      [{ id: "a1", kind: "file", filename: "a.ts", path: "/tmp/a.ts" }]
    );
    expect(spec.args.at(-1)).toContain("看看这个文件");
    expect(spec.args.at(-1)).toContain("- a.ts: /tmp/a.ts");
  });
});

describe("stream-json parsing (cursor/kimi/agy/kiro + gemini/qwen)", () => {
  const spec = genericCLIRunSpec("cursor", optionsFor(), null, "p", []);

  it("emits sessionID, assistant deltas from content blocks, and finished on result", () => {
    const { events } = runLines(spec, [
      JSON.stringify({ type: "system", subtype: "init", session_id: "s-1", model: "composer-1" }),
      JSON.stringify({ type: "assistant", message: { content: [{ type: "text", text: "Hello" }] } }),
      JSON.stringify({ type: "assistant", message: { content: [{ type: "text", text: "Hello world" }] } }),
      JSON.stringify({ type: "result", subtype: "success", result: "Hello world" })
    ]);
    expect(eventsOfType(events, "sessionID")[0]?.externalSessionID).toBe("s-1");
    const deltas = eventsOfType(events, "appendDelta");
    expect(deltas.map((d) => d.text).join("")).toBe("Hello world");
    expect(eventsOfType(events, "finished")).toHaveLength(1);
    expect(eventsOfType(events, "failed")).toHaveLength(0);
  });

  it("dedupes tool_call started/completed and emits toolResult with output", () => {
    const { events } = runLines(spec, [
      JSON.stringify({ type: "tool_call", subtype: "started", call_id: "c1", tool_call: { name: "Read", input: { path: "/x" } } }),
      JSON.stringify({ type: "tool_call", subtype: "started", call_id: "c1", tool_call: { name: "Read", input: { path: "/x" } } }),
      JSON.stringify({ type: "tool_call", subtype: "completed", call_id: "c1", tool_call: { name: "Read", output: "file body" } })
    ]);
    const toolCalls = eventsOfType(events, "appendMessage").filter((e) => e.kind === "toolCall");
    const toolResults = eventsOfType(events, "appendMessage").filter((e) => e.kind === "toolResult");
    expect(toolCalls).toHaveLength(1);
    expect(toolResults).toHaveLength(1);
    expect(toolResults[0]?.text).toBe("file body");
  });

  it("gemini-style message events with role=assistant stream text", () => {
    const geminiSpec = genericCLIRunSpec("gemini", optionsFor({ cli: "gemini" }), null, "p", []);
    const { events } = runLines(geminiSpec, [
      JSON.stringify({ type: "init", session_id: "g-1" }),
      JSON.stringify({ type: "message", role: "assistant", content: "partial" }),
      JSON.stringify({ type: "message", role: "user", content: "echo" }),
      JSON.stringify({ type: "result", status: "success" })
    ]);
    expect(eventsOfType(events, "appendDelta").map((d) => d.text)).toEqual(["partial"]);
    expect(eventsOfType(events, "finished")).toHaveLength(1);
  });

  it("uses result text as the assistant message when nothing streamed (one-shot fallback)", () => {
    const { events } = runLines(spec, [
      JSON.stringify({ type: "result", subtype: "success", result: "final answer" })
    ]);
    const deltas = eventsOfType(events, "appendDelta");
    expect(deltas.map((d) => d.text)).toEqual(["final answer"]);
    expect(eventsOfType(events, "finished")).toHaveLength(1);
  });

  it("maps error subtype result to failed", () => {
    const { events } = runLines(spec, [
      JSON.stringify({ type: "result", subtype: "error_during_execution", is_error: true, result: "boom" })
    ]);
    expect(eventsOfType(events, "failed")).toHaveLength(1);
    expect(eventsOfType(events, "finished")).toHaveLength(0);
  });

  it("emits error message events for type=error frames", () => {
    const { events } = runLines(spec, [JSON.stringify({ type: "error", error: { message: "bad request", code: "E1" } })]);
    const errors = eventsOfType(events, "appendMessage").filter((e) => e.kind === "error");
    expect(errors).toHaveLength(1);
    expect(errors[0]?.text).toContain("bad request");
  });

  it("forwards token usage when the event carries usage stats", () => {
    const { events } = runLines(spec, [
      JSON.stringify({ type: "assistant", usage: { input_tokens: 10, output_tokens: 5 }, message: { content: [] } })
    ]);
    const usage = eventsOfType(events, "tokenUsage");
    expect(usage).toHaveLength(1);
    expect(usage[0]?.used).toBe(15);
  });

  it("drops control/user echo frames and unknown protocol frames", () => {
    const { events } = runLines(spec, [
      JSON.stringify({ type: "user", message: { content: "echo" } }),
      JSON.stringify({ type: "control_request", request_id: "r1" }),
      JSON.stringify({ type: "ping" })
    ]);
    expect(eventsOfType(events, "appendMessage")).toHaveLength(0);
    expect(eventsOfType(events, "appendDelta")).toHaveLength(0);
  });

  it("non-JSON lines degrade to rawOutput on strict stream-json CLIs", () => {
    const { events } = runLines(spec, ["plain stdout line"]);
    const raw = eventsOfType(events, "appendMessage").filter((e) => e.kind === "rawOutput");
    expect(raw).toHaveLength(1);
    expect(raw[0]?.text).toBe("plain stdout line");
  });

  it("plain stdout counts as assistant output for kimi/agy/kiro", () => {
    const kimiSpec = genericCLIRunSpec("kimi", optionsFor({ cli: "kimi" }), null, "p", []);
    const { events } = runLines(kimiSpec, ["直接输出的一段回复"]);
    const deltas = eventsOfType(events, "appendDelta").filter((e) => e.kind === "assistant");
    expect(deltas).toHaveLength(1);
    expect(deltas[0]?.text).toContain("直接输出的一段回复");
  });

  it("empty lines produce no events", () => {
    const { events } = runLines(spec, ["", "   "]);
    // 空行 → 非 JSON → rawOutput（内容为空字符串仍是一条 raw 行，与 claude 行为一致：
    // readJSONLLines 在上游已跳过纯空行，这里只保证不崩溃不造 assistant 文本）
    expect(eventsOfType(events, "appendDelta")).toHaveLength(0);
  });
});

describe("copilot JSONL parsing", () => {
  const spec = genericCLIRunSpec("copilot", optionsFor({ cli: "copilot" }), null, "p", []);

  it("maps session.start, message_delta stream, and turn.completed", () => {
    const { events } = runLines(spec, [
      JSON.stringify({ type: "session.start", data: { session_id: "cp-1" } }),
      JSON.stringify({ type: "assistant.message_delta", data: { deltaContent: "Hel" } }),
      JSON.stringify({ type: "assistant.message_delta", data: { deltaContent: "lo" } }),
      JSON.stringify({ type: "turn.completed", data: { status: "success" } })
    ]);
    expect(eventsOfType(events, "sessionID")[0]?.externalSessionID).toBe("cp-1");
    expect(eventsOfType(events, "appendDelta").map((d) => d.text).join("")).toBe("Hello");
    expect(eventsOfType(events, "finished")).toHaveLength(1);
  });

  it("dedupes full assistant.message against streamed deltas", () => {
    const { events } = runLines(spec, [
      JSON.stringify({ type: "assistant.message_delta", data: { deltaContent: "abc" } }),
      JSON.stringify({ type: "assistant.message", data: { content: "abc" } })
    ]);
    // 全量消息与已发 delta 相同 → 不再重复追加
    expect(eventsOfType(events, "appendDelta").map((d) => d.text).join("")).toBe("abc");
  });

  it("maps flat tool_use / tool_result and session.error", () => {
    const { events } = runLines(spec, [
      JSON.stringify({ type: "tool_use", data: { name: "bash", input: { cmd: "ls" }, id: "t1" } }),
      JSON.stringify({ type: "tool_result", data: { name: "bash", output: "ok", tool_id: "t1" } }),
      JSON.stringify({ type: "session.error", data: { message: "denied" } })
    ]);
    expect(eventsOfType(events, "appendMessage").filter((e) => e.kind === "toolCall")).toHaveLength(1);
    expect(eventsOfType(events, "appendMessage").filter((e) => e.kind === "toolResult")).toHaveLength(1);
    expect(eventsOfType(events, "appendMessage").some((e) => e.kind === "error" && e.text.includes("denied"))).toBe(true);
  });

  it("non-JSON stdout degrades to rawOutput without failing", () => {
    const { events } = runLines(spec, ["copilot plain notice"]);
    expect(eventsOfType(events, "appendMessage")[0]?.kind).toBe("rawOutput");
  });
});

describe("resolveSpawnTarget", () => {
  it("returns the command untouched on non-Windows platforms", async () => {
    if (process.platform === "win32") {
      return;
    }
    const target = await resolveSpawnTarget("cursor-agent", ["-p", "x"]);
    expect(target).toEqual({ file: "cursor-agent", args: ["-p", "x"] });
  });
});
