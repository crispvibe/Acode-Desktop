// @vitest-environment node

import { describe, expect, it } from "vitest";
import { dshRunArgs } from "../../../src/main/chat/genericCliBackend";
import {
  dshConfigSelections,
  dshPermissionOptions,
  dshPermissionOutcome,
  dshUpdateEvents
} from "../../../src/main/chat/processChatBackend";
import type { ChatBackendEvent } from "../../../src/shared/chat";

const DISPLAY = "DeepSeek Harness";

function eventsOfType<T extends ChatBackendEvent["type"]>(events: ChatBackendEvent[], type: T): Extract<ChatBackendEvent, { type: T }>[] {
  return events.filter((event): event is Extract<ChatBackendEvent, { type: T }> => event.type === type);
}

/// 与 @deepseek-ai/dsh-acp 0.1.5-rc.2 实际返回一致的 configOptions 形状：
/// model 的 value 是 JSON.stringify([provider, model])，分组挂在 provider 下；
/// reasoning_effort 是扁平选项，"" 代表 Provider default。
const dshConfigOptions = [
  {
    id: "model",
    name: "Model",
    category: "model",
    type: "select",
    currentValue: JSON.stringify(["deepseek-official", "deepseek-v4-flash"]),
    options: [
      {
        group: "deepseek-official",
        name: "DeepSeek",
        options: [
          { value: JSON.stringify(["deepseek-official", "deepseek-v4-flash"]), name: "DeepSeek V4 Flash" },
          { value: JSON.stringify(["deepseek-official", "deepseek-v4-pro"]), name: "DeepSeek V4 Pro" }
        ]
      }
    ]
  },
  {
    id: "reasoning_effort",
    name: "Reasoning effort",
    category: "thought_level",
    type: "select",
    currentValue: "high",
    options: [
      { value: "", name: "Provider default" },
      { value: "low", name: "Low" },
      { value: "high", name: "High" },
      { value: "max", name: "Max" }
    ]
  }
];

describe("dshRunArgs npx fallback", () => {
  it("bare dsh passes args through untouched", () => {
    expect(dshRunArgs("dsh", ["--profile", "acp"])).toEqual(["--profile", "acp"]);
  });

  it("npx commands get the -y @deepseek-ai/dsh prefix", () => {
    expect(dshRunArgs("npx", ["--profile", "acp"])).toEqual(["-y", "@deepseek-ai/dsh", "--profile", "acp"]);
    expect(dshRunArgs("C:\\tools\\npx.cmd", ["--profile", "headless", "t"])).toEqual([
      "-y",
      "@deepseek-ai/dsh",
      "--profile",
      "headless",
      "t"
    ]);
    expect(dshRunArgs("/usr/local/bin/npx", ["--version"])).toEqual(["-y", "@deepseek-ai/dsh", "--version"]);
  });
});

describe("dshUpdateEvents ACP session/update 映射", () => {
  it("agent_message_chunk → assistant appendDelta；agent_thought_chunk → reasoning", () => {
    const events = dshUpdateEvents({
      sessionId: "s1",
      update: {
        sessionUpdate: "agent_message_chunk",
        messageId: "m1",
        content: { type: "text", text: "你好" }
      }
    }, DISPLAY);
    const deltas = eventsOfType(events, "appendDelta");
    expect(deltas).toHaveLength(1);
    expect(deltas[0]?.kind).toBe("assistant");
    expect(deltas[0]?.text).toBe("你好");
    expect(deltas[0]?.requestID).toBe("m1");

    const thoughts = dshUpdateEvents({
      sessionId: "s1",
      update: {
        sessionUpdate: "agent_thought_chunk",
        messageId: "m2",
        content: { type: "text", text: "推理中" }
      }
    }, DISPLAY);
    expect(eventsOfType(thoughts, "appendDelta")[0]?.kind).toBe("reasoning");
    expect(eventsOfType(thoughts, "appendDelta")[0]?.title).toBe("thinking");
  });

  it("tool_call in_progress → streaming toolCall；tool_call_update completed → toolResult", () => {
    const started = dshUpdateEvents({
      sessionId: "s1",
      update: {
        sessionUpdate: "tool_call",
        toolCallId: "call-1",
        title: "bash",
        kind: "other",
        status: "in_progress",
        rawInput: { cmd: "ls" }
      }
    }, DISPLAY);
    const calls = eventsOfType(started, "appendMessage");
    expect(calls).toHaveLength(1);
    expect(calls[0]?.kind).toBe("toolCall");
    expect(calls[0]?.title).toBe("bash");
    expect(calls[0]?.status).toBe("streaming");
    expect(calls[0]?.requestID).toBe("call-1");
    expect(calls[0]?.text).toContain("ls");

    const finished = dshUpdateEvents({
      sessionId: "s1",
      update: {
        sessionUpdate: "tool_call_update",
        toolCallId: "call-1",
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: "file.txt" } }]
      }
    }, DISPLAY);
    const results = eventsOfType(finished, "appendMessage");
    expect(results).toHaveLength(1);
    expect(results[0]?.kind).toBe("toolResult");
    expect(results[0]?.status).toBe("done");
    expect(results[0]?.text).toBe("file.txt");

    const failed = dshUpdateEvents({
      sessionId: "s1",
      update: { sessionUpdate: "tool_call_update", toolCallId: "call-2", status: "failed", content: [] }
    }, DISPLAY);
    expect(eventsOfType(failed, "appendMessage")[0]?.status).toBe("failed");
  });

  it("usage_update {used,size} → tokenUsage", () => {
    const events = dshUpdateEvents({
      sessionId: "s1",
      update: { sessionUpdate: "usage_update", used: 1234, size: 1_000_000 }
    }, DISPLAY);
    const usage = eventsOfType(events, "tokenUsage");
    expect(usage).toHaveLength(1);
    expect(usage[0]?.used).toBe(1234);
    expect(usage[0]?.total).toBe(1_000_000);
  });

  it("user_message_chunk / config_option_update / 未知 update 全部静默", () => {
    for (const update of [
      { sessionUpdate: "user_message_chunk", content: { type: "text", text: "echo" } },
      { sessionUpdate: "config_option_update", configOptions: [] },
      { sessionUpdate: "plan", entries: [] },
      { sessionUpdate: "something_new", text: "?" }
    ]) {
      expect(dshUpdateEvents({ sessionId: "s1", update }, DISPLAY)).toHaveLength(0);
    }
    expect(dshUpdateEvents(null, DISPLAY)).toHaveLength(0);
  });
});

describe("dshPermissionOutcome 权限回执", () => {
  const options = dshPermissionOptions([
    { optionId: "allow-once", name: "Allow once", kind: "allow_once" },
    { optionId: "reject-once", name: "Reject", kind: "reject_once" }
  ]);

  it("allow 与 allowForSession 都映射到 allow-once（dsh 无会话级选项）", () => {
    expect(dshPermissionOutcome("allow", options)).toEqual({
      outcome: { outcome: "selected", optionId: "allow-once" }
    });
    expect(dshPermissionOutcome("allowForSession", options)).toEqual({
      outcome: { outcome: "selected", optionId: "allow-once" }
    });
  });

  it("deny 映射到 reject-once；无 reject 选项时回 cancelled", () => {
    expect(dshPermissionOutcome("deny", options)).toEqual({
      outcome: { outcome: "selected", optionId: "reject-once" }
    });
    expect(dshPermissionOutcome("deny", [])).toEqual({ outcome: { outcome: "cancelled" } });
    expect(dshPermissionOutcome("allow", [])).toEqual({ outcome: { outcome: "cancelled" } });
  });

  it("dshPermissionOptions 容忍缺字段/非数组", () => {
    expect(dshPermissionOptions(undefined)).toEqual([]);
    expect(dshPermissionOptions([{ name: "x" }, { optionId: "a", kind: "allow_once" }])).toEqual([
      { optionId: "a", name: "", kind: "allow_once" }
    ]);
  });
});

describe("dshConfigSelections 模型/思考强度选项", () => {
  it("按解码后的 model id 匹配并回传完整 [provider, model] value", () => {
    const plan = dshConfigSelections("deepseek-v4-pro", "medium", dshConfigOptions);
    expect(plan.modelRequested).toBe(true);
    expect(plan.modelMatched).toBe(true);
    // medium 在 deepseek 档位里没有精确值 → 落到已广播的 ""（Provider default），
    // 与 currentValue "high" 不同所以照常发送。
    expect(plan.selections).toEqual([
      { configId: "model", value: JSON.stringify(["deepseek-official", "deepseek-v4-pro"]) },
      { configId: "reasoning_effort", value: "" }
    ]);
  });

  it("支持 provider/model 组合与选项 name 匹配", () => {
    const byRoute = dshConfigSelections("deepseek-official/deepseek-v4-pro", "medium", dshConfigOptions);
    expect(byRoute.selections[0]?.value).toBe(JSON.stringify(["deepseek-official", "deepseek-v4-pro"]));
    const byName = dshConfigSelections("DeepSeek V4 Pro", "medium", dshConfigOptions);
    expect(byName.modelMatched).toBe(true);
  });

  it("未广播的模型不臆造 value：modelMatched=false 且不产生 set_config_option", () => {
    const plan = dshConfigSelections("deepseek-chat", "medium", dshConfigOptions);
    expect(plan.modelRequested).toBe(true);
    expect(plan.modelMatched).toBe(false);
    expect(plan.selections.find((s) => s.configId === "model")).toBeUndefined();
  });

  it("reasoning_effort 按已广播档位取最近档：xhigh→max；与 currentValue 相同则跳过", () => {
    const xhigh = dshConfigSelections("default", "xhigh", dshConfigOptions);
    expect(xhigh.selections).toEqual([{ configId: "reasoning_effort", value: "max" }]);
    // currentValue 已是 high → high 不再重复发送
    const same = dshConfigSelections("default", "high", dshConfigOptions);
    expect(same.selections).toEqual([]);
  });

  it("configOptions 缺失/畸形时不产生任何选择", () => {
    expect(dshConfigSelections("deepseek-v4-pro", "low", undefined).selections).toEqual([]);
    expect(dshConfigSelections("deepseek-v4-pro", "low", { bad: true }).selections).toEqual([]);
    const noEffort = dshConfigSelections("default", "low", [dshConfigOptions[0]]);
    expect(noEffort.selections).toEqual([]);
  });
});
