# 对话系统改造与 Windows 开发交接文档

生成日期：2026-05-09  
适用范围：Codevoke/acode 内嵌 Claude Code 与 Codex 对话面板、工具调用 UI、交互请求、队列消息、循序渐进 transcript、后续 Windows 端复刻。

## 1. 文档目标

本文档用于把本轮会话相关改造完整沉淀为可交接资料，方便后续 Windows 开发直接按同一语义复刻，而不是重新从 macOS SwiftUI 代码里反推。

核心目标：

1. 解释 Claude Code 与 Codex 两条 backend 如何接入同一聊天模型。
2. 解释命令、工具、MCP、diff、权限、选择题如何统一映射到 UI。
3. 解释 queued messages、停止按钮、FIFO 出队、backend 生命周期之间的边界。
4. 解释“循序渐进” transcript 的合并策略：什么时候追加同一行，什么时候新增下一行。
5. 解释极简 IDE chat UI 的状态矩阵：user、assistant、thinking、tool、permission、interactive、loading、error。
6. 给 Windows 端列出必须重新实现或验证的进程、管道、路径、编码、shell、环境变量和 UI 抽象。
7. 列出已验证项、未验证项、风险和后续验收清单。

非目标：

1. 本文不定义 Windows 端具体技术栈，如 WPF、WinUI、Avalonia、Electron 或 React。
2. 本文不承诺 Claude/Codex CLI 的未来协议稳定；真实协议仍需以运行样本校准。
3. 本文不替代测试计划，但提供必须覆盖的测试与手测入口。

## 2. 当前架构总览

对话系统被拆成四层：

| 层级 | macOS 当前实现 | 职责 | Windows 复刻建议 |
| --- | --- | --- | --- |
| 领域模型 | `ChatModels.swift` | 定义 message、event、run status、permission、interactive request | 保持语言无关 DTO，作为前后端/UI 共享契约 |
| Backend 协议 | `ChatProcessBackend.swift` | 统一 Claude/Codex start、interrupt、permission、interactive、compact | Windows 用同接口语义封装 Process/pipe/JSONL |
| 状态机 | `ChatPanelState.swift` | 会话、队列、流式合并、状态切换、持久化 | ViewModel/Store 单线程派发事件到 UI 线程 |
| UI | `ClaudeSessionPanelView.swift` | transcript、工具折叠、thinking、队列、composer、按钮 | 抽成组件：MessageRow、ThinkingRow、ToolRow、QueueBar、Composer |

关键证据：

- 后端统一协议：`Codevoke/Services/Chat/ChatProcessBackend.swift:4`
- 后端进程环境：`Codevoke/Services/Chat/ChatProcessBackend.swift:54`
- message 类型：`Codevoke/Models/ChatModels.swift:174`
- interactive request：`Codevoke/Models/ChatModels.swift:210`
- run status：`Codevoke/Models/ChatModels.swift:227`
- backend event：`Codevoke/Models/ChatModels.swift:394`
- 队列请求模型：`Codevoke/ViewModels/ChatPanelState.swift:3`
- transcript 渲染入口：`Codevoke/Views/ClaudeSessionPanelView.swift:140`

### 2.1 2026-05-10 对话页面审计快照

本轮用 10 个只读子代理从架构、transcript UI、composer/queue、历史侧栏、backend 事件、性能、持久化、Agent process、Windows 文档和设计系统十个方向审计当前本地对话页面。Windows 端应优先复刻语义和状态机，而不是照搬 SwiftUI/AppKit 实现。

| 方向 | macOS 当前事实 | Windows 必须落地 |
| --- | --- | --- |
| 多会话运行态 | `ChatRuntimeStore` 按 session/history/draft key 复用多个 `ChatPanelState`，切换会话不销毁旧 run | 独立 runtime store；后台会话继续接收输出；状态更新不能触发全局 UI 重绘 |
| 队列与恢复 | `QueuedChatRequest` 保存 prompt、project、CLI、model、权限和 resume 上下文；active run 重启后标 failed，不自动重放 | FIFO 语义、崩溃后不重复执行危险 active run、队列持久化 |
| Transcript | 主线只展示 user/assistant/reasoning/tool/permission/interactive/error；raw/system/result 隐藏 | 虚拟化列表、折叠工具行、Markdown/code/table 轻量渲染、底部跟随判定 |
| Composer | 自动高度 42–160；IME marked text 时不回写、不发送；建议命令支持整块删除 | Windows IME composition/Enter 必测；草稿保存要 debounce |
| 历史侧栏 | 当前只显示 acode 本地会话，并按 CLI 过滤：Claude 只显示 Claude，Codex 只显示 Codex；不再扫描外部 Claude/Codex 历史 | 本地 session store 按 CLI 分流；删除同步清 index/transcript；过期异步刷新不得覆盖新状态 |
| Backend | Claude 是 stream-json JSONL；Codex 是 app-server stdio JSON-RPC | Process/pipe/JSONL/JSON-RPC 分层；stdout/stderr 并发读；stdin JSONL 可写 |
| Agent process | Agent tool 行提供 process 入口，详情 sheet 读取 `subagents/agent-*.jsonl` 和 meta | 复刻 process 入口、2.5s 刷新、pause/resume、subagent block 映射 |
| 性能 | delta 150ms flush、scroll 0.25s 节流、parse/cache、侧栏轻量化、关键状态才落盘 | 流式批量刷新、Markdown/文件引用/工具摘要缓存、持久化节流、侧栏虚拟化 |
| 视觉 | 20/18/14/13/12 圆角层级、白色半透明面、弱描边、紧凑列表密度；工具详情走 acode 风格可视化卡片，thinking 行不做边框卡片 | 抽设计 token；用 WinUI/Mica/Acrylic 等效替换 AppKit 毛玻璃 |
| 文档缺口 | 旧文档未覆盖最新多 runtime、Agent process、CLI 过滤历史和性能约束 | 本文以本节和后续章节作为 Windows 复刻最新基线 |

关键证据：

- 多 runtime store：`Codevoke/Services/Chat/ChatRuntimeStore.swift:6`
- per-session state：`Codevoke/ViewModels/ChatPanelState.swift:4`
- 本地 JSON/JSONL store：`Codevoke/Services/Chat/ChatSessionStore.swift:4`
- transcript 入口：`Codevoke/Views/ClaudeSessionPanelView.swift:174`
- 本地历史加载：`Codevoke/ViewModels/AppState.swift`
- 当前 CLI 过滤：`Codevoke/Views/ProjectSidebarView.swift:119`
- 外部历史扫描源文件 `Codevoke/Services/ClaudeHistoryScanner.swift` 已删除
- Agent process sheet：`Codevoke/Views/ClaudeSessionPanelView.swift:2444`
- 子代理 transcript：`Codevoke/Services/Chat/SubagentTranscriptStore.swift:76`

### 2.2 2026-05-10 最新实现基线

本轮后 macOS 端的最新基线如下，Windows 端复刻时以这些行为为准：

1. 历史来源：侧栏只展示 acode 自建 `ChatSessionStore` 会话，并按当前 CLI 分流；外部 Claude/Codex 历史扫描不再属于主路径。
2. 工具展示：Read/Edit/Write、Grep/Glob、Bash/终端、Todo、Agent、diff 和泛工具都进入结构化可视化卡片；主 UI 默认不展示 raw JSON envelope。
3. 终端输出：命令卡片展开后显示 `$ command`，并分区展示 stdout、stderr 和 output。
4. 文件跳转：工具卡片或文件引用可打开当前项目内文件，并支持 line/column 跳转。
5. 队列：运行中发送进入队列；队列消息可删除、点击/拖入输入框编辑，也可拖拽调整顺序。
6. Composer：输入框下方显示 CLI、权限、模型和思考强度选择器；当前默认权限为自动编辑，切换完全访问会二次确认。
7. Thinking：显示英文 `thinking`，运行中展开，完成后可收缩；当前不使用边框或卡片背景。
8. 布局：编辑器/聊天横向拖拽时用内存宽度即时刷新，拖拽结束后再持久化，避免卡顿。
9. 打包：已验证 Release build 和 App-only `.app` 复制到桌面；DMG 不再是当前交付目标。

## 3. 领域模型设计

### 3.1 ChatMessageKind

`ChatMessageKind` 是 UI 分发的核心，当前至少包含：

- `user`：用户消息，右侧气泡。
- `assistant`：模型回复，普通正文。
- `reasoning`：思考内容，UI 标题显示为 `thinking`。
- `toolCall`：工具调用或 MCP 调用。
- `toolResult`：工具结果。
- `command`：命令调用。
- `commandOutput`：命令输出。
- `diff`：文件变更或补丁。
- `permissionRequest`：权限请求。
- `interactiveRequest`：选择题、ABCD、多选、文本输入。
- `error`：错误卡片。
- `system/result/rawOutput`：保留给持久化或诊断，默认不进入主 transcript。

证据：`Codevoke/Models/ChatModels.swift:174`

Windows 复刻建议：

1. 不要把 CLI 原始事件直接暴露给 UI。
2. 先统一映射到 `ChatMessageKind`，UI 只认识这些领域类型。
3. `system/result/rawOutput` 可以存储或诊断，但主聊天不显示。

### 3.2 Interactive Request 模型

用于 AskUserQuestion、Codex choice/input/question/options 等请求：

- `ChatInteractiveRequest`：id、title、prompt、mode、options、allowCustomInput、placeholder、status。
- `ChatInteractiveOption`：id、label、detail。
- `ChatInteractiveMode`：singleChoice、multipleChoice、text。
- `ChatInteractiveStatus`：waiting、answered、cancelled、failed。
- `ChatInteractiveResponse`：requestID、selectedOptionIDs、customText。

证据：

- `Codevoke/Models/ChatModels.swift:210`
- `Codevoke/Models/ChatModels.swift:221`

Windows 复刻建议：

1. 不要把选择题做成普通文本；必须有原生按钮或输入框。
2. response 要保留 selected ids 与 custom text，方便 Claude/Codex 分别转换协议。
3. UI 提交失败时要把 request 状态标为 failed，并显示可理解错误。

### 3.3 ChatRunStatus

当前 run 状态用于控制按钮、loading、队列和卡片：

- `idle`：空闲。
- `starting`：进程启动中。
- `streaming`：模型/工具输出中。
- `waitingPermission`：等待权限按钮。
- `waitingInput`：等待选择题/文本输入。
- `stopping`：用户正在停止当前 run。
- `completed`：已完成。
- `failed`：失败。
- `unsupportedVersion`：CLI 或协议能力不支持。

证据：`Codevoke/Models/ChatModels.swift:227`

Windows 复刻建议：

1. `isRunning` 必须覆盖 starting、streaming、waitingPermission、waitingInput、stopping。
2. waitingPermission/waitingInput 仍属于“运行中”，此时用户继续发送应该进入队列，不应该启动第二个进程。
3. macOS 当前 action button 在运行中切换为停止语义；Windows 目标建议拆成 Send/Queue 与 Stop 两个独立控件，避免运行态按钮语义跳变。

## 4. Backend 协议统一层

`ChatProcessBackend` 是 Claude 与 Codex 统一入口：

- `start(prompt, options, session)`：返回 `AsyncThrowingStream<ChatBackendEvent, Error>`。
- `interrupt()`：停止当前 run。
- `respondToPermission(requestID, decision)`：权限回写。
- `respondToInteractiveRequest(requestID, response)`：选择题/文本输入回写。
- `sendCompact()`：上下文压缩。

证据：`Codevoke/Services/Chat/ChatProcessBackend.swift:4`

统一层价值：

1. UI 和状态机不关心 Claude/Codex 的真实协议。
2. 所有 backend 都必须输出同一组 `ChatBackendEvent`。
3. Windows 端可以先复刻协议层，再分别实现 ClaudeBackend/CodexBackend。

## 5. Claude Code 对接链路

### 5.1 启动与通信方式

Claude backend 当前以非 PTY 的 `Process + Pipe` 启动 CLI，输出走 stdout/stderr JSONL 读取。关键参数包括：

- `-p <prompt>`
- `--output-format stream-json`
- `--verbose`
- `--include-partial-messages`
- `--permission-mode ...`
- `--effort ...`
- `--resume` / `--continue`

参数兼容策略：

- 如果 `--include-partial-messages` 不被当前 CLI 支持，且启动后没有任何可见输出，会自动重试移除该参数。
- 如果 `--effort` 不被当前 CLI 支持，且启动后没有任何可见输出，会自动重试移除该参数。

证据：

- `Codevoke/Services/Chat/ClaudeCodeProcessBackend.swift:43`
- `Codevoke/Services/Chat/ClaudeCodeProcessBackend.swift:48`
- `Codevoke/Services/Chat/ClaudeCodeProcessBackend.swift:89`
- `Codevoke/Services/Chat/ClaudeCodeProcessBackend.swift:119`
- `Codevoke/Services/Chat/ClaudeCodeProcessBackend.swift:208`
- `Codevoke/Services/Chat/ClaudeCodeProcessBackend.swift:221`

重要限制：

1. 当前 Claude backend 未给 Claude 进程设置可用 stdin 控制通道，`inputPipe` 为空；`respondToPermission` / `respondToInteractiveRequest` 即使存在，写入也会失败。
2. 因此上层对 Claude `.ask` 权限模式做了禁用，避免展示“看似可点但无法回写”的假权限按钮。
3. AskUserQuestion/选择题做了宽松识别，但真实 CLI 回写协议仍需要真实样本验证。
4. Windows 端在取得真实 Claude stdin/control response 样本前，不应开启可点击权限或交互回写 UI，只能展示诊断/unsupported 状态。

### 5.2 事件解析

Claude 事件最终统一映射为：

- assistant delta → `.appendDelta(.assistant, ...)`
- reasoning/thinking delta → `.appendDelta(.reasoning, ...)`
- tool use / input json delta → `.toolCall`
- tool result → `.toolResult`
- permission control request → `.permissionRequest`
- AskUserQuestion / choices / options → `.interactiveRequest`
- token usage → `.tokenUsage`
- result/finished → `.finished`
- failed/error → `.failed`

证据：

- `Codevoke/Services/Chat/ClaudeCodeProcessBackend.swift:325`
- `Codevoke/Services/Chat/ClaudeCodeProcessBackend.swift:436`
- `Codevoke/Services/Chat/ClaudeCodeProcessBackend.swift:488`

Windows 复刻建议：

1. 先保持 stream-json 非 PTY 模式；只有 CLI 强依赖 TTY 时再引入 ConPTY。
2. stdout/stderr 必须并发读取，避免进程因管道阻塞卡死。
3. JSONL 读取必须支持 UTF-8、CRLF、半包和长行。
4. Claude 权限/AskUserQuestion 回写不要假设可用，必须用实际 CLI 样本验证后再打开 UI 入口。

## 6. Codex 对接链路

### 6.1 启动与 JSON-RPC

Codex 使用 `app-server --listen stdio://`，通过 stdin/stdout JSONL 承载 JSON-RPC。

启动流程：

1. 启动 `codex app-server --listen stdio://`。
2. 发送 `initialize`。
3. 收到 initialize response 后发送 `initialized`。
4. 发送 `thread/start` 或 `thread/resume`。
5. 发送 `turn/start` 开始本轮 prompt。

证据：

- `Codevoke/Services/Chat/CodexAppServerBackend.swift:33`
- `Codevoke/Services/Chat/CodexAppServerBackend.swift:208`
- `Codevoke/Services/Chat/CodexAppServerBackend.swift:239`
- `Codevoke/Services/Chat/CodexAppServerBackend.swift:255`
- `Codevoke/Services/Chat/CodexAppServerBackend.swift:459`

### 6.2 JSON-RPC 映射

Codex backend 处理三类消息：

1. response：根据 pending request id 判断 initialize/thread/turn/interrupt 结果。
2. server request：有 method 和 id，需要客户端回写 response，例如 approval、interactive、readFile。
3. notification：无 id，作为状态、delta、输出、diff 等事件处理。

证据：

- `Codevoke/Services/Chat/CodexAppServerBackend.swift:364`
- `Codevoke/Services/Chat/CodexAppServerBackend.swift:434`
- `Codevoke/Services/Chat/CodexAppServerBackend.swift:436`

### 6.3 requestID / itemID 合并策略

Codex command output 和 diff 容易出现缺少稳定 item id 的情况。当前策略：

1. 优先读取 `itemId/item_id/callId/call_id/commandId/command_id/outputId/output_id/id`。
2. 递归读取 `item` 子对象。
3. 如果仍没有 id，使用 `activeTurnID-method-counter` 生成 fallback id。
4. 这样避免多个 command output 全部落入 nil requestID，导致 UI 合并成一条。

证据：`Codevoke/Services/Chat/CodexAppServerBackend.swift:521`

Windows 复刻建议：

1. 必须保留 output id 归一化逻辑。
2. fallback id 必须包含 turn/method/sequence，不能只用 activeTurnID。
3. JSON-RPC response id 要保留原始 id 类型语义，回写时不能随意变形。

### 6.4 权限、选择题、readFile

Codex backend 支持：

- `respondToPermission`：approval/permissions 请求回写。
- `respondToInteractiveRequest`：选择题/文本输入回写。
- `readFile`：server request 读项目内 UTF-8 文本文件；越界、目录或非 UTF-8 文本会返回 JSON-RPC error。

证据：

- `Codevoke/Services/Chat/CodexAppServerBackend.swift:156`
- `Codevoke/Services/Chat/CodexAppServerBackend.swift:179`
- `Codevoke/Services/Chat/CodexAppServerBackend.swift:377`
- `Codevoke/Services/Chat/CodexAppServerBackend.swift:606`
- `Codevoke/Services/Chat/CodexAppServerBackend.swift:610`

Windows 风险：

1. `readFile` 的项目内路径校验在 Windows 上要重新处理盘符、UNC、大小写、符号链接和路径规范化。
2. Codex 的 sandbox/approvalPolicy 在 Windows shell 下语义需实测。
3. app-server JSON-RPC method 可能随版本变化，启发式 interactive 判断可能误判或漏判。

## 7. 进程环境与自定义 API

`ChatCLIEnvironment` 统一生成 CLI 子进程环境：

1. 获取真实 HOME。
2. 生成默认 PATH。
3. 清理父进程中 Codex runtime 相关变量。
4. 合并 `~/.claude/settings.json` 中支持的 env。
5. 规范化 HTTP/HTTPS/ALL/NO_PROXY。
6. 镜像大小写代理变量。
7. 移除 `CLAUDE_CONFIG_DIR`。

当前从 `~/.claude/settings.json` 合并到 CLI 子进程的 env 只允许以下范围：

- proxy 相关变量：HTTP/HTTPS/ALL/NO_PROXY 及小写形式。
- `ANTHROPIC_*`。
- `CLAUDE_CODE_*`。

未见 Codex/OpenAI 专属 env 的持久配置合并逻辑；Windows 端不要把 AppSettings、模型列表请求和 CLI 子进程环境混为一谈。

证据：

- `Codevoke/Services/Chat/ChatProcessBackend.swift:54`
- `Codevoke/Services/Chat/ChatProcessBackend.swift:94`
- `Codevoke/Services/Chat/ChatProcessBackend.swift:138`
- `Codevoke/Services/Chat/ChatProcessBackend.swift:189`
- `Codevoke/Services/Chat/ChatProcessBackend.swift:210`

Windows 复刻建议：

| macOS 逻辑 | Windows 需要处理 |
| --- | --- |
| HOME / getpwuid | USERPROFILE、HOMEDRIVE/HOMEPATH |
| PATH 冒号分隔 | PATH 分号分隔 |
| `/opt/homebrew/bin` 等默认路径 | where.exe、Program Files、用户 npm/bun/cargo 路径 |
| `~/.claude/settings.json` | `%USERPROFILE%\.claude\settings.json` |
| 代理变量大小写镜像 | Windows 环境变量大小写不敏感但 CLI 可能按大小写读取，仍建议同时设置 |
| Process terminate/interrupt | Kill 进程树、Job Object、Ctrl+C/GenerateConsoleCtrlEvent 视情况选择 |

注意：自定义 API 对 Claude Code 的实际生效依赖 CLI 是否读取这些 env。文档和 UI 不应承诺“写入 AppSettings 就一定影响 CLI”，必须用进程环境验证。

## 8. ChatPanelState 状态机

### 8.1 发送入口

`send(...)` 做以下事情：

1. trim 用户输入。
2. 无项目时报错。
3. 构造 `QueuedChatRequest`，保存提交瞬间的 project、cli、modelID、contextModelID、permissionMode、reasoningEffort、sessionMode、resumeSessionID。
4. 如果当前 `status.isRunning`，只追加到 `queuedRequests`。
5. 如果不在运行中，调用 `startRun(...)`。

证据：

- `Codevoke/ViewModels/ChatPanelState.swift:3`
- `Codevoke/ViewModels/ChatPanelState.swift:173`
- `Codevoke/ViewModels/ChatPanelState.swift:217`

设计原因：

1. 队列必须保存提交瞬间的完整上下文快照，不能只保存文本。
2. 用户运行中切模型/项目/权限不应该改变已排队消息的语义。
3. 运行中发送不能 interrupt 当前 run。

### 8.2 启动 run

`startRun(...)` 负责：

1. 检查 CLI capability。
2. 禁止不支持的模式，例如 Claude ask 回写不可靠。
3. ensure session。
4. append user message。
5. 设置 awaiting first model output。
6. 创建 Claude 或 Codex backend。
7. 启动 async stream 并逐个 `apply(event)`。

证据：`Codevoke/ViewModels/ChatPanelState.swift:217`

### 8.3 Backend 事件落地

`apply(...)` 将 backend event 写入 ViewModel：

- append message / delta。
- permission request → append permission card，状态 waitingPermission。
- interactive request → append interactive card，状态 waitingInput。
- token usage → 更新 context usage。
- finished → 标记可在 backend stream 结束后出队。
- failed → 停止当前 run，不自动出队。

证据：`Codevoke/ViewModels/ChatPanelState.swift:433`

### 8.4 Backend 结束后才出队

最新设计把“收到 finished event”和“backend stream 真正结束”拆开：

1. `.finished` 只设置 `shouldStartQueuedRequestAfterBackendEnds`。
2. `backendStreamDidEnd()` 统一收尾。
3. 只有非用户 stop 且 backend stream 已结束，才 `startNextQueuedRequestIfNeeded()`。

证据：

- `Codevoke/ViewModels/ChatPanelState.swift:541`
- `Codevoke/ViewModels/ChatPanelState.swift:620`

设计原因：

1. 避免 CLI 还在输出工具尾部事件时下一条队列提前启动。
2. 避免用户 stop 后队列自动续跑，造成“学习项目没完成就被下一条打断”的体验。
3. 避免 failed 后连续刷队列，造成错误放大。

## 9. 循序渐进 transcript 设计

### 9.1 基本原则

主 transcript 只展示用户可理解的聊天内容：

- user
- assistant
- thinking
- tool row
- permission card
- interactive card
- loading
- error

隐藏：

- raw JSON
- system lifecycle
- message_start/message_stop
- done/status/raw/internal JSON
- CLI 启动命令

证据：

- `Codevoke/Views/ClaudeSessionPanelView.swift:140`
- `Codevoke/Views/ClaudeSessionPanelView.swift:172`

### 9.2 Delta 合并规则

`appendDelta(...)` 使用 `(kind, requestID)` 作为合并 key，但对 assistant/reasoning 加了额外约束：

- 如果当前 active message 仍是最后一个可见消息，继续追加。
- 如果中间已经出现 tool/command/diff/permission/interactive/user 等可见消息，则新建下一行。

证据：

- `Codevoke/ViewModels/ChatPanelState.swift:558`
- `Codevoke/ViewModels/ChatPanelState.swift:627`

设计效果：

1. thinking 不会一直卡在顶部旧行。
2. 工具调用、命令输出、后续 thinking 会按真实事件顺序向下推进。
3. assistant 回复也不会跨工具事件错误合并。

### 9.3 Assistant output

assistant 回复不再只按纯文本渲染，输出层要识别常见 Markdown 结构：

- 普通段落：保留选择和整条复制，行内 Markdown/inline code 允许轻量解析，解析失败回退纯文本。
- fenced code block：独立代码卡片、等宽字体、横向滚动、显示语言标签、提供单块 `copy`。
- Markdown table：独立表格卡片，等宽显示并支持横向滚动，避免列被压碎。
- 长文本仍按流式追加，不改变 backend event 和 `ChatMessage` 模型。

证据：

- `Codevoke/Views/ClaudeSessionPanelView.swift:286`
- `Codevoke/Views/ClaudeSessionPanelView.swift:1219`
- `Codevoke/Views/ClaudeSessionPanelView.swift:1271`

Windows 复刻建议：

1. Assistant renderer 先做轻量 parser，不要引入会阻塞流式渲染的大型 Markdown 引擎。
2. 代码块复制必须复制原始 code，不包含语言 fence。
3. 表格优先保证可读和可横向滚动，不要求第一版做复杂 grid。
4. renderer 必须能处理未闭合代码 fence，避免流式过程中闪烁或崩溃。

### 9.4 Tool row

工具行现在是 IDE 风格折叠卡片：

- 不显示大图标，主线保持轻量。
- 标题优先显示工具名，例如 `Read`、`Edit`、`Write`、`Bash`，不显示 `tool_use/tool_result/input_json_delta` 等协议名。
- 文件工具必须显示工具名 + 文件名；文件名以 chip 展示，点击后在编辑器打开目标文件。
- `Read/Edit/Write` 等文件操作可从 JSON/text/diff 中提取 path/file/filePath/file_path，无法提取时降级为普通工具行。
- `Bash`、`command`、`commandOutput` 等终端类工具折叠态必须显示执行命令摘要，长命令单行截断并保留完整 tooltip。
- 展开后用 acode 风格的浅色可视化详情卡片显示参数、输出或 diff，避免裸露整块 JSON/code；终端类工具使用 `$ command` + stdout/stderr/output 的终端式卡片。
- 详情卡片保留复制入口，复制终端详情时应包含命令和输出；长命令、长 JSON、diff 支持横向滚动。
- 工具详情展示层过滤 `id/type/index/session/timestamp/message_start/message_stop/done` 等内部噪音，只保留 command/path/input/output/result/error/message/text/diff 等可理解字段，不能丢失错误原因。
- 最新运行中的工具行只用静态字体/颜色强调，不做闪烁或 repeat 动画。
- 执行完成后工具行自动恢复普通静态样式。

证据：

- `Codevoke/Views/ClaudeSessionPanelView.swift:327`
- `Codevoke/Views/ClaudeSessionPanelView.swift:431`

Windows 复刻建议：

1. ToolRow 必须有 collapsed/expanded 两态。
2. 文件工具卡片必须提供 click-to-open 文件 chip，打开逻辑要限制在当前项目内。
3. 终端命令卡片必须在 collapsed 态显示命令，在 expanded 态显示命令与输出回馈。
4. active 状态只给最后可见且 streaming 的工具行。
5. 展开区必须是卡片，不直接裸露大段文字。
6. 运行态只做静态 font/color 差异，避免闪烁动画和布局抖动。
7. 原始事件仍可进诊断日志，但主 UI 和详情卡片默认不显示内部 envelope。

### 9.5 Thinking row

thinking 行设计：

- 标题固定显示英文 `thinking`。
- thinking 时自动展开。
- thinking 完成或后续工具/回复出现后自动收缩。
- 标题和正文使用接近普通回复的字号，不做过小二级日志样式。
- 不加边框、卡片背景或强容器感，避免把 thinking 看成工具结果。

证据：`Codevoke/Views/ClaudeSessionPanelView.swift:391`

Windows 复刻建议：

1. ThinkingRow 永远保留标题。
2. `isThinking = message.isStreaming && lastVisibleTranscriptMessageID == message.id`。
3. 用户可以手动展开历史 thinking。
4. thinking 正文字号应与 assistant 正文接近。

### 9.6 Agent process 与子代理过程

Agent 工具调用不是普通工具日志：主 transcript 中仍按轻量 ToolRow 展示，但 Agent 行提供 `process` 入口打开子代理过程面板。面板标题为 `Agent process`，支持 pause/resume/refresh/close，运行时约 2.5 秒自动刷新；详情从 `.claude/projects/<storageKey>/subagents/agent-*.jsonl` 和对应 meta 读取，找不到 agentID 时按 agentType/description 匹配最近修改的记录。

子代理 JSONL 映射规则：

- text → assistant
- thinking → reasoning
- tool_use → toolCall
- tool_result → toolResult，`is_error` 标为失败态

Windows 复刻建议：

1. 不要把 Agent 过程做成彩色大卡片；主线只保留轻量折叠行和 `process` 入口。
2. 子代理详情读取应与普通历史读取分离；普通历史必须继续排除 `subagents`。
3. 读取过程要支持 pause/resume，避免大 JSONL 高频轮询拖慢主页面。
4. 截断策略要保留：主线展示摘要，详情区限制长文本，复制仍尽量保留完整可诊断内容。

证据：

- Agent process 入口：`Codevoke/Views/ClaudeSessionPanelView.swift:429`
- process sheet：`Codevoke/Views/ClaudeSessionPanelView.swift:2444`
- 子代理读取：`Codevoke/Services/Chat/SubagentTranscriptStore.swift:76`
- 子代理 block 映射：`Codevoke/Services/Chat/SubagentTranscriptStore.swift:187`

## 10. 队列消息设计

### 10.1 FIFO 语义

运行中发送消息：

1. 不 interrupt。
2. 不启动新 backend。
3. append 到 `queuedRequests`。
4. 输入框清空。
5. 队列区域展示在输入框上方。
6. 当前 run 正常完成后 FIFO 出队。

证据：

- `Codevoke/ViewModels/ChatPanelState.swift:173`
- `Codevoke/ViewModels/ChatPanelState.swift:620`
- `Codevoke/Views/ClaudeSessionPanelView.swift:598`

### 10.2 停止与失败

停止当前 run：

- 只停止当前 backend。
- 不清空队列。
- 不自动启动下一条。

失败：

- 标记 failed。
- 不自动出队。
- 保留队列，等待用户下一步。

证据：`Codevoke/ViewModels/ChatPanelState.swift:541`

设计原因：

1. 用户 stop 通常表示当前任务不想继续，不能自动接下一条制造新副作用。
2. CLI 失败时如果继续出队，会把同类失败快速放大。
3. 队列可取消，用户可决定是否继续。

### 10.3 UI 位置与密度

队列消息显示在 composer 上方，紧贴输入框：

- 少于 3 条时按实际行数占高，不预留空白。
- 超过 3 条时固定 3 行高度，内部可滚动。
- 每行显示序号、首行摘要、编辑按钮、删除按钮。
- 删除直接移除队列项；编辑会把队列文本回填到输入框并从队列中移除。
- 队列消息也支持拖入输入框编辑，拖拽排序可直接调整未开始请求的执行顺序。

证据：`Codevoke/Views/ClaudeSessionPanelView.swift:598`

Windows 复刻建议：

1. QueueBar 放在 Composer 内部或紧贴 Composer 上沿。
2. 不要占据 transcript 大块空间，也不要用最大高度预留空白。
3. 队列删除必须只移除未开始请求，不能影响当前 run。
4. 队列编辑必须先删除队列项，再把文本放回 composer 草稿。

## 11. UI 组件矩阵

| UI 组件 | 触发数据 | 默认状态 | 交互 | Windows 复刻 |
| --- | --- | --- | --- | --- |
| UserMessageRow | `.user` | 右侧气泡 | 复制、编辑、撤销 | Bubble + action bar |
| AssistantMessageRow | `.assistant` | Markdown 段落、代码块、表格 | 整条复制、代码块复制 | Lightweight Markdown renderer + code/table cards |
| ThinkingRow | `.reasoning` | 标题 thinking；运行时展开，结束后收缩 | 手动展开/收起 | Expander/Disclosure |
| ToolInvocationRow | tool/command/diff | 折叠；运行中静态强调 | 展开详情卡片、复制详情 | Expander + static active style + detail card |
| FileToolCard | Read/Edit/Write/path 工具 | 显示工具名 + 文件名 chip | 点击文件名打开编辑器文件 | Tool row variant + current-project open-file guard |
| TerminalCommandCard | Bash/command/commandOutput | 折叠态显示执行命令 | 展开 `$ command` + 输出/错误，复制详情 | Terminal-style card with command/output feedback |
| PermissionCard | `.permissionRequest` | waiting | deny/allow/session allow | Card + buttons |
| InteractiveCard | `.interactiveRequest` | waiting | 单选/多选/文本提交 | Card + inputs |
| LoadingRow | awaiting first output | spinner + “正在生成” | 无 | Progress indicator |
| QueueBar | queuedRequests | 实际行数，最多 3 行 | 编辑、删除、拖入输入框、拖拽排序 | Scrollable compact list + reorder/drop-to-edit |
| WorkbenchSplit | editor/chat layout | chat 宽度可拖拽，按可用空间 clamp | 左拖扩大对话，右拖扩大编辑器 | 持久化 split width，不要固定 420/840 卡片宽度 |
| ActionButton | status + draft | macOS 当前非运行时发送/入队，运行时停止 | send / interrupt | Windows 建议拆分为 SendButton + StopButton |
| StopButton | status.isRunning | Windows 目标控件 | interrupt | 独立于 send，避免运行态按钮语义跳变 |
| Composer | draft text | 占位文案“输入你的需求” | IME 候选确认、Shift+Enter 换行 | marked text 时隐藏 placeholder，避免叠字 |
| PickerOverlay | activePicker | 根级浮层，不参与 composer 布局 | 点击 CLI/权限/模型按钮打开，点击空白关闭；模型与图标保持紧凑间距 | 用 Window/Popup/Adorner/Portal 顶层承载，不能挤占输入框或 transcript 空间 |
| SendButton | draft nonempty | Windows 目标控件 | send / enqueue | 不承担 stop 语义 |
| AgentProcessSheet | Agent tool row | process 入口，默认自动刷新 | pause/resume/refresh/close | 读取 subagents JSONL，展示子代理真实过程 |

证据：

- UI row 分发：`Codevoke/Views/ClaudeSessionPanelView.swift:253`
- interactive card：`Codevoke/Views/ClaudeSessionPanelView.swift:1186`
- selector buttons：`Codevoke/Views/ClaudeSessionPanelView.swift:1032`
- root picker layer：`Codevoke/Views/ClaudeSessionPanelView.swift:68`
- picker layer implementation：`Codevoke/Views/ClaudeSessionPanelView.swift:1117`
- send button：`Codevoke/Views/ClaudeSessionPanelView.swift:925`
- workbench split：`Codevoke/Views/RootView.swift:59`

### 11.1 全局浮层层级规则

CLI、权限、模型等选择弹层属于页面级 overlay，而不是 composer 内部内容。macOS 当前通过根 `ZStack` 的 `globalPickerLayer` 承载，`composer` 只保留输入框、附件、队列和按钮本体；弹层打开后不改变 composer 高度、不推挤 transcript、不导致页面重新分配空间。

Windows 复刻要求：

1. 使用窗口级或页面级 `Popup` / `Flyout` / `AdornerLayer` / `Portal` 承载选择弹层，z-index 高于 chat card、composer、toast 和滚动内容。
2. 弹层定位锚定触发按钮附近，但布局计算不能把弹层计入 composer measure/arrange。
3. 点击弹层外部关闭；关闭不应清空草稿、不应触发发送、不应改变队列。
4. 模型弹层包含自定义 model id 输入框时，输入焦点仍在浮层内，Esc/外部点击需要明确关闭策略。
5. 多窗口或分屏场景下，浮层只能覆盖当前 chat panel，不能漂到其他项目/窗口。

## 12. 自动滚动与 loading

当前 transcript 使用 `ScrollViewReader`，监听：

- `chatState.transcriptRevision`
- `chatState.isAwaitingFirstModelOutput`
- `chatState.queuedRequests.count`

触发自动滚到底。

证据：`Codevoke/Views/ClaudeSessionPanelView.swift:140`

状态机中：

- 用户消息 append 后 `isAwaitingFirstModelOutput = true`。
- 收到第一个可见输出后置 false。
- system/raw/result/token/session/status update 不关闭 loading。

Windows 复刻建议：

1. 使用 observable revision 或消息集合版本号触发滚动。
2. 流式文本高度变化也要触发滚动，而不只是 message count 变化。
3. 只在用户位于底部附近或明确 force 时自动滚动；用户上滑阅读历史时不能被流式输出抢回底部。

### 12.1 长对话性能约束

当前 macOS 已做过一轮对话页性能收敛，Windows 端第一版不能回退到“每个 token 全量刷新”的模型。

必须保留的约束：

1. 流式 delta 先聚合，约 100–200ms 批量 flush；macOS 当前约 150ms。
2. 自动滚动节流，macOS 当前约 0.25s；只在贴底时跟随。
3. transcript items 用 revision/project key 缓存，不在每次 body/render 里全量重算。
4. assistant Markdown/code/table parse 对完成消息缓存；流式和超长消息走轻量纯文本/预览。
5. 文件引用、AttributedString、工具摘要和详情过滤做缓存。
6. 队列变更等元数据保存不应每次重写全部 messages JSONL。
7. 侧栏只展开当前项目历史，并按当前 CLI 过滤；历史状态不要把每个 streaming delta 广播到全局 sidebar。
8. composer 草稿保存建议 debounce 或脏标记；不要逐字同步落盘。

证据：

- runtime store 活动发布：`Codevoke/Services/Chat/ChatRuntimeStore.swift:51`
- delta flush：`Codevoke/ViewModels/ChatPanelState.swift:672`
- 消息持久化节流：`Codevoke/ViewModels/ChatPanelState.swift:789`
- transcript 缓存：`Codevoke/Views/ClaudeSessionPanelView.swift:213`
- 自动滚动节流：`Codevoke/Views/ClaudeSessionPanelView.swift:239`
- assistant parse cache：`Codevoke/Views/ClaudeSessionPanelView.swift:2038`
- 当前 CLI 过滤历史：`Codevoke/Views/ProjectSidebarView.swift:119`

## 13. 历史会话与持久化

### 13.1 本地 acode 会话

本地聊天数据当前放在 Application Support 的 `acode` 目录，旧 `acode` 和 sandbox 目录会被迁移复制。聊天数据拆为三类：

- `chat-sessions.json`：会话索引数组，保存 title、projectPath、CLI、externalSessionID、runStatus、queuedRequests、activeRunRequest 等。
- `chat-messages/<uuid>.jsonl`：每行一条 `ChatMessage`，便于排障和增量恢复。
- `chat-drafts.json`：按 session/draft key 保存输入草稿。

恢复策略必须保守：如果解码发现 `runStatus.isRunning` 或 `activeRunRequest`，启动后标记为 failed/上次运行已中断，并清空 active run；不能自动重放已经开始的请求，避免重复执行工具写文件、命令或权限操作。未开始的 `queuedRequests` 保留，等待用户继续。

证据：

- acode Application Support：`Codevoke/Services/ProjectStore.swift:30`
- 存储文件名：`Codevoke/Services/Chat/ChatSessionStore.swift:4`
- JSONL 消息保存：`Codevoke/Services/Chat/ChatSessionStore.swift:36`
- draft 保存：`Codevoke/Services/Chat/ChatSessionStore.swift:70`
- 会话运行态字段：`Codevoke/Models/ChatModels.swift:347`
- active run 中断恢复：`Codevoke/Models/ChatModels.swift:443`

### 13.2 历史列表当前边界

当前侧栏历史只显示 acode 本地 session store，不再扫描或管理外部 Claude/Codex 历史。历史列表仍需满足两层过滤：

1. 按项目路径/storageKey 分组。
2. 按当前 `selectedCLI` 过滤：Claude 模式只显示 Claude 会话，Codex 模式只显示 Codex 会话。

子代理过程不是普通历史来源；Agent process 详情仍从 `subagents/agent-*.jsonl` 和 meta 读取，但这条链路与历史侧栏分离。

证据：

- 本地 session store：`Codevoke/Services/Chat/ChatSessionStore.swift`
- 侧栏当前 CLI 过滤：`Codevoke/Views/ProjectSidebarView.swift`
- 本地历史加载：`Codevoke/ViewModels/AppState.swift`
- 外部扫描源文件 `Codevoke/Services/ClaudeHistoryScanner.swift` 已删除

Windows 复刻建议：

1. 本地历史建议使用 `%APPDATA%\\acode\\chat-sessions.json`、`%APPDATA%\\acode\\chat-messages\\<uuid>.jsonl`、`%APPDATA%\\acode\\chat-drafts.json`。
2. 需要定义旧目录迁移策略，至少覆盖未来 Windows 早期版本可能使用的临时目录。
3. 第一版不要把外部 `.claude` / `.codex` 历史混入侧栏；如后续要做外部恢复，应作为独立入口重新设计和验证。
4. `storageKey` 和路径归一化要重写，覆盖盘符、UNC、大小写、junction/symlink；禁止沿用 POSIX “把 `/` 转成 `-`”的规则。
5. 删除要处理 CRLF、文件占用、长路径和大小写路径；失败时要给可理解错误，并避免 stale index 让已删历史重新出现。
6. 普通历史与 Agent subagents 必须是两条读取链路，不能为了展示 Agent process 把 subagents 混进历史列表。

## 14. Windows 迁移重点

### 14.1 进程与管道

必须抽象的能力：

1. 启动可执行文件，设置工作目录。
2. 传参数时优先使用 argv 数组，不经 shell 拼接。
3. 并发读取 stdout/stderr。
4. 写 stdin JSONL。
5. 终止当前进程或进程树。
6. 获取 exit code。
7. 处理启动失败、可执行文件不存在、权限不足。

Windows 风险：

- `Process` 行为与 Foundation 不同。
- stdout/stderr 任一管道不读都可能死锁。
- EOF、半包、CRLF、长行需要测试。
- Ctrl+C、TerminateProcess、Job Object 对 CLI 清理效果不同。
- 如果 CLI 需要 TTY，可能需要 ConPTY；但优先验证纯 stdio。

### 14.2 Shell 与 quoting

当前 macOS capability probe 部分依赖 `/bin/zsh`、`/usr/bin/env` 和 POSIX PATH。Windows 需要：

1. `where.exe claude` / `where.exe codex` 或显式路径。
2. PowerShell/cmd 只用于探测时要严格 quoting。
3. 真正启动 CLI 时不要拼 shell command string。
4. 命令输出 UI 不应展示启动命令。

### 14.3 路径与编码

Windows 必须验证：

- `C:\...` 盘符路径。
- UNC 路径。
- 反斜杠与正斜杠混用。
- symlink/junction。
- 项目内路径判断。
- UTF-8 中文输出。
- CRLF JSONL。
- 控制台默认编码不是 UTF-8 的情况。

### 14.4 环境变量和代理

需要保留：

- HTTP_PROXY / http_proxy
- HTTPS_PROXY / https_proxy
- ALL_PROXY / all_proxy
- NO_PROXY / no_proxy
- ANTHROPIC_* / CLAUDE_CODE_*

Windows 注意：环境变量大小写不敏感，但不同 CLI/子进程库读取行为可能不同；仍建议同时设置大小写代理。

### 14.5 安全与目录授权

macOS 当前会解析项目目录并启动 security scoped resource。Windows 需要定义等价策略：

1. 用户选择目录后的授权保存。
2. CLI 工作目录限制。
3. Codex readFile 请求不得越过项目根目录。
4. ACL/权限失败要转换成用户可理解错误。

### 14.6 视觉与布局 token

Windows 端不要直接复制 SwiftUI 修饰符，应先抽设计 token，再映射到 WinUI/WPF/Avalonia/Electron 组件。

当前 macOS token 基线：

- 面板：白色半透明、弱发丝线、20 圆角、轻阴影。
- 项目行：14 圆角、8 垂直内距；历史行：12 圆角、7 垂直内距。
- 对话面板：18 圆角；header 约 37 高；transcript 横向 14、纵向 12、行距 10。
- 用户气泡：12 字号、11x8 内距、13 圆角。
- Composer：输入卡 20 圆角；队列行 28 高、9 圆角；action 按钮 20 圆形 accent。
- Settings：大卡 24 圆角、22 内距，控件高度 34/40/44。

Windows 缺口：

1. `NSVisualEffectView` / `NSViewRepresentable` 要替换为 Mica/Acrylic 或普通半透明 surface。
2. `NSApp.applicationIconImage`、AppKit pasteboard、NSTextView/NSScrollView 行为都要替换。
3. 字体、禁用态、阴影、列表密度必须集中配置，避免散落硬编码。

证据：

- Theme token：`Codevoke/Views/GlassPanel.swift:4`
- GlassPanel：`Codevoke/Views/GlassPanel.swift:16`
- Sidebar 密度：`Codevoke/Views/ProjectSidebarView.swift:14`
- Chat panel 布局：`Codevoke/Views/ClaudeSessionPanelView.swift:67`
- Composer 密度：`Codevoke/Views/ClaudeSessionPanelView.swift:830`
- VisualEffectView：`Codevoke/AppKit/VisualEffectView.swift:4`

## 15. 调试与验证建议

### 15.1 CLI 能力探测

- `claude --version`
- `claude --help`
- `codex --version`
- `codex --help`
- `codex app-server --help`

验收：

1. 能找到可执行文件。
2. 版本输出可解析。
3. Codex app-server 能力可识别。
4. PATH 与用户配置路径一致。

### 15.2 Claude 最小流

目标：验证非 PTY stream-json 是否可用。

步骤：

1. 设置项目目录为 cwd。
2. 启动 Claude stream-json。
3. 输入普通 prompt。
4. 验证 assistant delta、reasoning、tool、failed、finished。
5. 验证代理环境和自定义 API 是否进入子进程。

必须记录：CLI 版本、启动 argv、cwd、env diff、stdout 原始 JSONL 样本、stderr 样本、exit code、是否需要 stdin、失败截图或录屏。记录结果要保存成 Windows fixture，后续协议解析变更必须用这些样本回归。

### 15.3 Codex 最小流

目标：验证 app-server JSON-RPC。

步骤：

1. 启动 `codex app-server --listen stdio://`。
2. 写入 initialize。
3. 写入 initialized。
4. 写入 thread/start 或 thread/resume。
5. 写入 turn/start。
6. 验证 notification/request/response。
7. 验证 approval 与 interactive 回写。

必须记录：CLI 版本、启动 argv、cwd、env diff、JSON-RPC method、id 类型、params 样本、stdout/stderr 原始 JSONL、exit code、diff/command output 是否有 itemID。记录结果要保存成 Windows fixture。

### 15.4 UI 手测矩阵

| 场景 | 期望 |
| --- | --- |
| 普通问候 | user 立即出现，loading 出现，assistant 首字后 loading 消失 |
| assistant 代码块 | 独立代码卡片、等宽字体、横向滚动、单块 copy 只复制代码 |
| assistant 表格 | 表格卡片可横向滚动，不被压成乱文本 |
| 未闭合代码 fence | 流式过程中按代码块展示，不崩溃、不吞后续文本 |
| thinking | 标题 thinking 常显，运行时展开，结束后收缩；无边框/卡片背景 |
| 多个工具 | 每个工具按顺序下推，不合并成大组 |
| 工具运行中 | 最新工具行只有静态字体/颜色强调，不闪烁 |
| 展开工具 | 只展开当前行详情卡片，不污染主线 |
| 工具噪音过滤 | 展开卡片不显示 id/type/index/session/timestamp/done 等内部 envelope，但必须保留 error/message/text |
| Read 工具 | 折叠行显示 `Read` + 文件名 chip；点击文件名打开编辑器文件 |
| Edit 工具 | 折叠行显示 `Edit` + 文件名 chip；展开仍能看到改动参数或 diff 摘要 |
| Write 工具 | 折叠行显示 `Write` + 文件名 chip；新文件写入后点击文件名可打开 |
| Bash/终端命令 | 折叠行显示执行命令；展开显示 `$ command` 和 stdout/stderr/output 回馈 |
| diff | 默认折叠，展开看 diff |
| permission | 卡片显示 deny/allow/session allow |
| interactive | 单选、多选、文本输入可提交 |
| 运行中继续发送 | 进入队列，不 interrupt 当前 run；队列紧贴输入框且无预留空白 |
| 队列编辑/删除/拖拽 | 删除直接移除队列项；点击或拖入输入框会回填并移除队列项；拖拽排序改变未开始请求顺序 |
| IME 回车 | 有 marked text 时 placeholder 隐藏且 Enter 只确认候选，不发送；普通 Enter 发送，Shift+Enter 换行 |
| 普通消息发送 | 打开编辑器文件时不自动追加 Current file/Cursor，只有显式附加路径才进入 prompt |
| stop | 只停止当前 run，不自动启动队列下一条 |
| failed | 显示错误，不继续刷队列 |
| auto-scroll | 流式高度增长时滚到底 |
| 工具运行态 | 只做静态字体/颜色强调，执行完恢复普通样式 |

## 16. 已验证项

基于本轮实际执行，已验证：

1. Debug build 通过。
2. Release build 通过。
3. App-only `.app` 已复制到桌面并通过 codesign 校验；当前不再生成 DMG。
4. 工具行旧中文前缀与状态标签已从当前 UI 路径移除。
5. 工具详情已改为 acode 风格可视化卡片，覆盖文件、搜索、终端、Todo、Agent、diff 和泛工具。
6. `thinking` 文案替代中文思考文案，且 thinking 行无边框/卡片背景。
7. 队列出队逻辑改为 backend stream end 后触发。
8. stop/failed 不自动出队。
9. 最新工具行运行态已改为静态字体/颜色强调，无闪烁动画。
10. 多会话 runtime 已拆到 `ChatRuntimeStore`，切换会话不应中断旧 run。
11. 队列、runStatus、activeRunRequest 已进入本地 session index，重启后 active run 只标中断不重放。
12. 队列消息支持拖入输入框编辑和拖拽排序。
13. 输入框已支持自动高度和中文 IME marked text 保护。
14. 输入框下方 CLI / 权限 / 模型选择器可见，当前默认权限为自动编辑。
15. 子代理 Agent process 已有读取和详情 UI 链路。
16. 历史侧栏只显示 acode 本地会话，并按当前 CLI 过滤；不再扫描外部 Claude/Codex 历史。
17. 对话性能已做流式 flush、滚动节流、parse/cache 和侧栏轻量化收敛。

## 17. 未验证项与风险

| 风险 | 状态 | 后续动作 |
| --- | --- | --- |
| Claude stdin 权限回写协议 | 未验证 | 获取真实 CLI 样本，确认是否支持稳定 control response；未验证前 Windows 不得开启可点击回写 |
| Claude AskUserQuestion 回写 | 未验证 | 不要默认开启；先用真实 AskUserQuestion 样本校准；未验证前只显示诊断/unsupported |
| Codex app-server Windows 可用性 | 未验证 | Windows 实机运行 JSON-RPC 最小流 |
| Codex method/schema 演进 | 风险存在 | 保留 raw 样本日志和 unsupported response |
| ConPTY 是否必要 | 未验证 | 先跑纯 stdio；失败再引入 ConPTY |
| Windows UTF-8/CRLF/长行 JSONL | 未验证 | 构造中文、emoji、长输出和 CRLF 样本 |
| Windows 路径越界校验 | 未验证 | 覆盖盘符、UNC、junction、symlink、大小写 |
| Windows IME composition | 未验证 | 覆盖中文拼音候选、Enter 确认、Shift+Enter 换行、整块建议命令删除 |
| Windows 历史路径 | 未验证 | 实机确认 `.claude`、`.codex`、subagents、sessions、archived_sessions、session_index.jsonl 位置 |
| Agent process Windows 读取链路 | 未验证 | 用真实 Claude 子代理 JSONL/meta 样本验证匹配、刷新、截断和错误态 |
| UI 动效实际观感 | 构建通过但需手测 | 安装新版应用手测工具运行态 |
| 完整历史还原 | 当前非目标 | 如需要，另做历史 transcript parser |

## 18. Windows 端开发落地顺序建议

第一阶段：领域模型与 ViewModel

1. 复制 ChatMessageKind、ChatRunStatus、ChatBackendEvent、InteractiveRequest、QueuedChatRequest、ChatSessionRecord 等 DTO 语义。
2. 实现 ChatProcessBackend interface。
3. 实现 ChatPanelState 等价 store：send、queue、apply、appendDelta、backendStreamDidEnd。
4. 实现 ChatRuntimeStore 等价运行态容器：按 session/history/draft key 复用 runtime，支持多会话后台运行。
5. 用 fake backend 写 UI 状态测试。

完成条件：fake backend 能覆盖 assistant/reasoning/tool/permission/interactive/loading/error；running send 只入队；stop/failed 不自动出队；backend stream end 后 FIFO 出队；切换会话不 interrupt；active run 重启后只标中断不重放。

第二阶段：进程通信

1. 实现 ProcessRunner：argv、cwd、env、stdout/stderr/stdin、kill tree。
2. 实现 JSONL reader：UTF-8、CRLF、半包、长行。
3. 接 Claude stream-json 最小流。
4. 接 Codex app-server JSON-RPC 最小流。

完成条件：stdout/stderr 并发读取无死锁；stdin JSONL 可写；kill tree 能清理子进程；保存 Claude/Codex 最小流 fixture；JSONL reader 单测覆盖 UTF-8、CRLF、半包、长行。

第三阶段：UI 组件

1. Transcript + auto scroll，必须保留贴底判定和滚动节流。
2. User/Assistant/Thinking rows。
3. ToolRow 折叠、展开、静态运行态。
4. FileToolCard：Read/Edit/Write 显示工具名 + 文件名 chip，并支持点击打开项目内文件。
5. TerminalCommandCard：Bash/command 折叠态显示命令，展开显示 `$ command` + 输出/错误回馈。
6. Agent process：Agent 工具行 process 入口、子代理详情 sheet、pause/resume/refresh。
7. PermissionCard 与 InteractiveCard。
8. QueueBar 与 Composer，覆盖自动高度、IME marked text、建议命令整块删除。
9. Stop/Send 语义拆分。
10. 设计 token 映射：surface、border、radius、shadow、list density、disabled/accent state。

完成条件：用 fake backend 手测 UI 矩阵全部通过；主 transcript 不出现 raw/system/result/internal JSON；工具行默认折叠且逐条下推；文件工具可点击打开；终端命令能看到命令和输出；thinking 运行中展开、结束后收缩；Agent process 能读取子代理过程；长输出不造成全局卡顿。

第四阶段：真实 CLI 验证

1. Claude 普通对话。
2. Claude 工具调用。
3. Claude 权限/AskUserQuestion 样本验证。
4. Codex 普通对话。
5. Codex command/diff/approval/interactive。
6. 代理、自定义 API、OAuth 失效、CLI 版本不支持场景。

完成条件：每个真实 CLI 场景都有 fixture、截图或录屏、exit code 和 env diff；Claude 权限/AskUserQuestion 未验证前保持 blocked，不开启可点击回写。

第五阶段：发布前闭环

1. 构建 Windows 安装包。
2. 最小 smoke：普通对话、工具、队列、stop、error。
3. 保存原始 JSONL 样本作为 fixture。
4. 把未知 method 和 parse fallback 打到诊断日志，不显示在主 transcript。

完成条件：安装包 smoke 通过；诊断日志能定位未知 schema；所有未验证项在发布说明中明确标注或关闭入口。

## 19. 最终验收清单

文档与实现都应满足：

- [ ] Claude 与 Codex 都走统一 ChatBackendEvent。
- [ ] 主 transcript 不显示 raw/system/result/internal JSON。
- [ ] tool/command/diff 每次调用按顺序独立向下推进。
- [ ] Read/Edit/Write 等文件工具显示工具名和文件名。
- [ ] 文件名 chip 可点击并打开当前项目内目标文件。
- [ ] Bash/终端命令折叠态显示执行命令。
- [ ] Bash/终端命令展开态显示 `$ command` 与输出/错误回馈。
- [ ] thinking 标题常显，运行时展开，结束后收缩。
- [ ] 工具运行态能看出“正在使用中”。
- [ ] running send 入队，不 interrupt。
- [ ] stop 独立于 send。
- [ ] stop/failed 不自动出队。
- [ ] backend stream 完整结束后才 FIFO 出队。
- [ ] permission 和 interactive request 有原生 UI。
- [ ] Windows 进程层 stdout/stderr/stdin 不死锁。
- [ ] Windows JSONL 支持 UTF-8/CRLF/长行/半包。
- [ ] Windows 路径、代理、HOME、CLI 探测都有专门适配。
- [ ] 未知 CLI schema 不破坏主 UI，只进入诊断或 unsupported。

## 20. 关键源码索引

| 主题 | 文件与行号 |
| --- | --- |
| backend 协议 | `Codevoke/Services/Chat/ChatProcessBackend.swift:4` |
| CLI 环境 | `Codevoke/Services/Chat/ChatProcessBackend.swift:54` |
| process environment | `Codevoke/Services/Chat/ChatProcessBackend.swift:94` |
| 代理镜像 | `Codevoke/Services/Chat/ChatProcessBackend.swift:189` |
| message kind | `Codevoke/Models/ChatModels.swift:174` |
| interactive request | `Codevoke/Models/ChatModels.swift:210` |
| run status | `Codevoke/Models/ChatModels.swift:227` |
| backend event | `Codevoke/Models/ChatModels.swift:394` |
| queued request | `Codevoke/ViewModels/ChatPanelState.swift:3` |
| send | `Codevoke/ViewModels/ChatPanelState.swift:173` |
| startRun | `Codevoke/ViewModels/ChatPanelState.swift:217` |
| apply event | `Codevoke/ViewModels/ChatPanelState.swift:433` |
| backendStreamDidEnd | `Codevoke/ViewModels/ChatPanelState.swift:541` |
| appendDelta | `Codevoke/ViewModels/ChatPanelState.swift:558` |
| startNextQueuedRequestIfNeeded | `Codevoke/ViewModels/ChatPanelState.swift:620` |
| assistant/reasoning 合并约束 | `Codevoke/ViewModels/ChatPanelState.swift:627` |
| transcript | `Codevoke/Views/ClaudeSessionPanelView.swift:140` |
| transcriptItems | `Codevoke/Views/ClaudeSessionPanelView.swift:172` |
| tool row | `Codevoke/Views/ClaudeSessionPanelView.swift:337` |
| file tool chip/open | `Codevoke/Views/ClaudeSessionPanelView.swift:386` / `Codevoke/ViewModels/AppState.swift:226` |
| terminal detail card | `Codevoke/Views/ClaudeSessionPanelView.swift:467` |
| tool display helpers | `Codevoke/Views/ClaudeSessionPanelView.swift:1955` |
| thinking row | `Codevoke/Views/ClaudeSessionPanelView.swift:484` |
| last visible row | `Codevoke/Views/ClaudeSessionPanelView.swift:431` |
| queue view | `Codevoke/Views/ClaudeSessionPanelView.swift:598` |
| send button | `Codevoke/Views/ClaudeSessionPanelView.swift:925` |
| interactive card | `Codevoke/Views/ClaudeSessionPanelView.swift:1186` |
| Claude backend start | `Codevoke/Services/Chat/ClaudeCodeProcessBackend.swift:43` |
| Claude permission response | `Codevoke/Services/Chat/ClaudeCodeProcessBackend.swift:208` |
| Claude interactive response | `Codevoke/Services/Chat/ClaudeCodeProcessBackend.swift:221` |
| Claude interactive parsing | `Codevoke/Services/Chat/ClaudeCodeProcessBackend.swift:488` |
| Codex backend start | `Codevoke/Services/Chat/CodexAppServerBackend.swift:33` |
| Codex permission response | `Codevoke/Services/Chat/CodexAppServerBackend.swift:156` |
| Codex interactive response | `Codevoke/Services/Chat/CodexAppServerBackend.swift:179` |
| Codex initialize | `Codevoke/Services/Chat/CodexAppServerBackend.swift:208` |
| Codex turn/start | `Codevoke/Services/Chat/CodexAppServerBackend.swift:255` |
| Codex output id | `Codevoke/Services/Chat/CodexAppServerBackend.swift:521` |
| Codex interactive parsing | `Codevoke/Services/Chat/CodexAppServerBackend.swift:543` |

## 21. 结论

当前对话系统已经从“CLI 日志面板”改造成“IDE 风格 Agent Chat”：

1. 主线只呈现用户、assistant、thinking、工具折叠、权限、选择题、loading 和 error。
2. Claude Code 与 Codex 通过统一 backend event 接入同一状态机。
3. 工具、命令、diff、MCP 类事件按时间顺序下推，默认折叠。
4. Read/Edit/Write 等文件工具按 IDE 卡片显示工具名与文件名，文件名可点击打开。
5. Bash/终端命令按终端卡片显示执行命令与输出回馈。
6. thinking 与 assistant 不再错误合并到旧行。
7. 运行中继续发送进入 FIFO 队列，不打断当前 run。
8. 停止/失败不会自动启动队列下一条。
9. Windows 端复刻时最大风险不在 UI，而在进程通信、stdin/stdout/stderr、JSONL、路径、编码、CLI 协议和权限回写验证。

后续 Windows 开发应以本文的 DTO、状态机和 UI 状态矩阵为契约，先用 fake backend 验证 UI，再接真实 Claude/Codex CLI，最后用真实 JSONL 样本修正协议兼容。