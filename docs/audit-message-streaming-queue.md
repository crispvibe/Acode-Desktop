# 域 B 审计 —— 消息流 / streaming / queue / 工具·权限·附件

审计时间:2026-05-16  
仓库:`/Users/oreo/Desktop/acode` (HEAD = `cf10bef`)  
端点:`127.0.0.1:18765`,Mac App = 已加载到 acode 进程  
方式:静态读码 + 三轮活体 WS 验证(`/tmp/qa_*.py`)。**未修改任何代码、未 commit。**

---

## TL;DR

整体设计是合理的:`ChatPanelController` 是单一权威 actor、`ChatRuntimeStore` 按 session 隔离 controller、streaming/queue/权限走同一条 `apply(event:)` 状态机。已修的 11 项 bug 大都验证通过(stdin EOF、200ms throttle、订阅 sub-store、resume 协议判定、终态 latch、Bridge 镜像 guard 等),活体测试也证明 500 ms `composerSet/Send` 乱序补偿确实会触发并补发 user message。

但本域**仍残留约 12 个新问题**,影响范围从"队列语义反直觉"到"附件根本没传给 backend",其中:

- **P0(必修)2 个**:附件未注入 backend prompt;`stop` 不能清理 `permissionRequest` 的 `"waiting"` 状态。
- **P1(强烈建议)6 个**:rejected ack 导致 lastError 噪声、Codex error 路径漏掉 `ChatProcessTerminator`、`flushQueue` 语义与命名相反、stdin 写入无 hang 保护、stop 与 send 在 iOS 同一 chain 但权限/交互不入 chain、附件没大小校验。
- **P2(可选)4 个**。

下文按场景矩阵 + 分级清单 + 设计妥协 + 未覆盖项展开。

---

## 1. 场景矩阵(45 个用例 ✓ / ⚠ / ✗)

> ✓ 设计正确并验证通过;⚠ 有死角或边界问题;✗ 明确 broken。

### 新对话 / 第一条消息
| # | 场景 | 结论 | 关键位置 |
|---|---|---|---|
| 1 | iOS 新对话 + focus + 首条 send 完整 trace | ✓ | `ChatViewModel.swift:191-201` → `newDraftSession` → ack 携 sessionId → `:679-683` 自动 focus → `:243-258` 链式 attach/Set/Send |
| 2 | 没选 project 时按发送 | ⚠ | iOS 端 `ChatViewModel.swift:192` 直接 `appendDebug` 静默返回,**用户看不到任何反馈**;Mac 端 `ChatPanelState.swift:432-434` 会 `appendError`,iOS 没有等价的 toast/error UI 路径 |
| 3 | iOS 在 Mac 没启动 chat 面板时强行 send | ⚠ | `PanelStateBroadcasterAdapter.swift:211` 用 `panelControllerContextProvider?.defaultProject(for:)` 兜底,逻辑在 `:472-479` 取 `appState.selectedProjectID` 或 `projects.first`。但如果 `appState` 没初始化或为 `nil`,直接 `return false`,iOS 看到 rejected ack 且不知道原因 |

### 连发竞态
| # | 场景 | 结论 | 关键位置 |
|---|---|---|---|
| 4 | iOS 连发 3 条 attach+Set+Send,sendChain 串行 | ✓ | `ChatViewModel.swift:653-672` Task chain 串行,**已修 bug F4 验证通过** |
| 5 | iOS 连发后立刻 stop | ⚠ | `stopGeneration()` (`:268-270`) 走的是同一 `sendCommand`,**所以串到 send chain 后**才发。意味着用户按"停止"会等当前未完成的 send 命令链跑完才生效。这条 chain 没有"插队"机制 |
| 6 | server 端 `remoteComposerSend` 500ms 重试,如 composerSet 永不到 | ✓ | `PanelStateBroadcasterAdapter.swift:246-256` 一次性 500 ms 重试,500 ms 后还是空就丢弃。活体验证(`/tmp/qa_race3.py`)在 50 ms 乱序场景下成功补发了 user message |
| 7 | 同一 session 同时跑两条 send | ✓ | `:454-461` `shouldQueueNewRequest` 在 running 时直接入 `queuedRequests`,不会并发起 backend |

### Streaming
| # | 场景 | 结论 | 关键位置 |
|---|---|---|---|
| 8 | claude stdout → JSONLStreamReader → appendDelta → store → publisher → broadcaster → patch | ✓ | `JSONLStreamReader.swift:7-26` → `ClaudeCodeProcessBackend.swift:154-184` → `ChatPanelState.swift:809-959` → `PanelStateBroadcasterAdapter.swift:317-339` |
| 9 | streaming 中按 stop → SIGINT/TERM/EOF | ✓ | `ChatPanelState.swift:706` `interrupt()` → `ClaudeCodeProcessBackend.swift:261-267` 先 EOF stdin 再 `ChatProcessTerminator.stop` (`.ms(800)` / `.s(2)`);**已修 bug F1 验证** |
| 10 | streaming 中网络抖动 → patch 丢一两个 → iOS 重建 | ✓ | `ChatViewModel.swift:790-797` 收到 patch base mismatch → `Command(op: .requestSnapshot)` |
| 11 | streaming 完成后 result event → stdin close → process exit | ✓ | `ClaudeCodeProcessBackend.swift:176-178` + `:324-331` — 命中 `"type":"result"` 主动 EOF stdin |
| 12 | 切 session 时旧 session streamingText 泄漏到新 session | ✓ | `ChatRuntimeStore.swift:89-97` 是按 session 分配独立 controller;单 controller 切 session 时 `:387-405` 调 `resetTransientRunState()` 清除 |
| 13 | `--include-partial-messages` fallback | ⚠ | `ClaudeCodeProcessBackend.swift:71-82` retry 路径正常,但 fallback notification 用 `kind: .system` + `title: "Claude Code"`,正好命中 `ChatPanelState.swift:1088` `isMCPPayload` 的"title==mac tools"判断 - 不会触发,但**临近**,后续如果改 title 就会被远程通道误吞 |
| 14 | Codex JSON-RPC 长会话生命周期 | ⚠ | `CodexAppServerBackend.swift:319-322` 仅 `process?.terminate()`,**没有走 `ChatProcessTerminator.stop`** 的 SIGINT→SIGTERM→SIGKILL 序列,孩子进程可能被孤儿;见 P1-3 |

### Queue
| # | 场景 | 结论 | 关键位置 |
|---|---|---|---|
| 15 | running 时发送 → queuedRequests + patch + iOS"队列中"渲染 | ✓ | `ChatPanelState.swift:454-461` 入队;`ChatViewModel.swift:509-520` 把 `PanelQueuedRequestDTO` 转 ChatMessage |
| 16 | iOS 取消队列项 | ✓ | `ChatViewModel.swift:278-281` `cancelQueued` → router → `cancelQueuedRequest(_:)` |
| 17 | iOS 编辑队列项 | ✓ | `editQueued` 路径完整 (`ChatPanelState.swift:1821-1846`) |
| 18 | iOS flush queue 实际语义 | ✗ | **`flushQueue` ≠ 清空队列**。`PanelStateBroadcasterAdapter.swift:263-267` 调 `interrupt(startQueuedAfterStop: true)`,实际是"中断当前 + 跑下一条排队"。如果用户期望"删掉所有队列消息",这里完全没做;见 P1-2 |
| 19 | 自动跑下一条 | ✓ | `ChatPanelState.swift:1381-1404` 300 ms 延迟启动,有 `canStartQueuedRequest` 兜底 |
| 20 | queue 中某条 failed,后续是否继续 | ⚠ | `:953` `.failed` 路径明确把 `shouldStartQueuedRequestAfterBackendEnds = false`。**整条 queue 都不会继续跑**。如果用户期望"跳过失败继续",这是设计妥协;UI 没明示 |

### 权限请求(Claude `control_request`)
| # | 场景 | 结论 | 关键位置 |
|---|---|---|---|
| 21 | tool → permission_request event → patch 含 interactive | ✓ | `ClaudeCodeProcessBackend.swift:561-567` 白名单只接受 `control_request`,`isPermissionRequestType` 收窄(已修 bug);`ChatPanelState.swift:862-876` |
| 22 | iOS allow/deny → respondPermission → backend.control_response | ✓ | `ChatPanelState.swift:716-750` + `ClaudeCodeProcessBackend.swift:269-280` |
| 23 | 同时多个 permission 请求 | ⚠ | Claude 串行调用工具,逻辑上不会真同时,但代码上 `apply(.permissionRequest)` 每次都覆盖 `status = .waitingPermission` 不入栈,**第二条会盖掉第一条的 statusText**。无 UI 队列概念 |
| 24 | allow-for-session 一致性 | ⚠ | `ClaudeCodeProcessBackend.swift:271-273` 写 `scope: "session"`;Codex `CodexAppServerBackend.swift:188` 写 `scope: "session"` (permissions/requestApproval) 或者 `decision: "acceptForSession"`(execCommandApproval)。两侧字段语义对的上,但**没有把 session-scope 决策本地缓存**,iOS 重连后 Mac 端 backend 该不该再问 claude 一次完全取决于 claude/codex 自己的状态 |
| 25 | permission ask 模式被禁用 | ✓ | `ChatPanelState.swift:502-509` 启动前 guard,UI 抛错说明 |

### 交互请求(AskUserQuestion)
| # | 场景 | 结论 | 关键位置 |
|---|---|---|---|
| 26 | 工具弹问题 → interactive_request | ✓ | `ClaudeCodeProcessBackend.swift:676-717` 识别 questions[] / options[] / askUserQuestion |
| 27 | iOS 单选/多选/customText → respondInteractive | ✓ | `ChatPanelState.swift:752-774` + backend `:282-298` 把答案再 `writeStreamUserMessage` 携 `parent_tool_use_id` 写回 |
| 28 | iOS 取消回答 | ⚠ | 协议无显式 cancel — 用户只能按 stop。stop → interrupt → backend 终止,但 `interactiveRequest` 这条 message 的 status 一直停在 `"waiting"`,**和 P0-2 同根** |

### 工具调用
| # | 场景 | 结论 | 关键位置 |
|---|---|---|---|
| 29 | tool_use start → tool_result update | ⚠ | `ClaudeCodeProcessBackend.swift:476-524` 用 `content_block_start/stop` 配对,但**新建/收尾分别在两条路径,如果中间 process 崩溃 `content_block_stop` 不会到,`activeStreamingMessageIDs` 里的 entry 永久残留**。`finishStreamingMessages` 在 `.failed` 路径会兜底清理(`:945-947`),但若 backend 直接 stream cancel 则**只走 `finishActiveStreamingMessageIfPossible` 部分匹配**,有少量泄漏 |
| 30 | tool kind 在 iOS MessageRowView 渲染 | (域外)未审 |
| 31 | tool_use 嵌套(sub-agent) | ⚠ | claude 协议的 sub-agent 通过 `parent_tool_use_id` 关联,backend 在 `writeStreamUserMessage` 里支持 `parentToolUseID`,但 `events(fromClaudeLine:)` 解析路径**没有把 sub-agent 的 message 单独 group 起来**,会全部串到顶层 assistant text。后果:嵌套工具调用的中间产物全部铺平显示 |

### Thinking
| # | 场景 | 结论 | 关键位置 |
|---|---|---|---|
| 32 | thinking_delta → reasoning kind | ✓ | `ClaudeCodeProcessBackend.swift:509-511` 走 `.reasoning` kind |

### Error message
| # | 场景 | 结论 | 关键位置 |
|---|---|---|---|
| 33 | `.failed(message)` → error MessageRow | ✓ | `ChatPanelState.swift:946` `appendError(message)` |
| 34 | exit code != 0 + stderr | ✓ | `ClaudeCodeProcessBackend.swift:253-258` 把 stderr 拼进失败消息 |

### 特殊输入
| # | 场景 | 结论 | 关键位置 |
|---|---|---|---|
| 35 | 全空白消息 | ✓ | `ChatPanelState.swift:426` guard;**但 iOS `ChatViewModel.swift:240` 也 guard 过一次**,前后一致 |
| 36 | 超长消息(>50KB)stdin hang | ⚠ | `ChatPipeWriter.writeJSONObject` (`ChatProcessBackend.swift:38-51`)调 `fileHandleForWriting.write(contentsOf: data)` 是**同步阻塞** API,在 main thread 之外的 detached task 里执行还好,但**没有写超时**。极端场景:claude 进程卡住不读 stdin,acode 这边 `Task.detached` 永远卡在 write;见 P1-4 |
| 37 | emoji/中文/JSON 注入 | ✓ | `ChatPipeWriter` 用 `JSONSerialization.data(withJSONObject:)` 会自动转义,引号/反斜杠不会注入 |
| 38 | 换行 / markdown / code block | ✓ | 同上,JSON 序列化保证安全 |

### 附件
| # | 场景 | 结论 | 关键位置 |
|---|---|---|---|
| 39 | iOS upload → composerAttach → 发消息携带 | ✗ | **附件 path 没有任何路径把它注入到 claude/codex 的 stdin prompt 里**。`ChatPanelState.send` 把 attachments 挂在用户 `ChatMessage` 上仅供 UI 显示;`writeStreamUserMessage(text: prompt, ...)` 只传 `prompt` 字符串。`ClaudeCodeProcessBackend.swift` 全文 `grep -i attachment` 0 match;`CodexAppServerBackend.swift` 同。**user 上传的图/文件实际不会被 LLM 看到**;见 P0-1 |
| 40 | 上传中按发送 | ⚠ | iOS `ChatViewModel.swift:243-251` 顺序遍历 `self.attachments` 一条条发 composerAttach 然后 composerSet→Send。若 upload 还在跑(`isUploadingAttachment=true`),`attachments` 里就是空的或不完整,**用户拿不到任何提示** |
| 41 | composerRemoveAttach | ✓ | `ChatViewModel.swift:388-391` + router `:116-124` |
| 42 | 附件超大 / 类型不支持 | ⚠ | `/attachments` HTTP 端点 `RemoteChatRouter.swift:157-177` 接受任何 base64 内容,**没有 size/type 限制**。WS 端 `composerAttach.attachment.thumbnailData` 也是 `Data?` 直接走 JSON,无上限。HTTP 总线限 64 MB(`RemoteChatHTTP.swift:68`)但单 WS message 没硬上限 |

### Session 切换
| # | 场景 | 结论 | 关键位置 |
|---|---|---|---|
| 43 | iOS focusSession → server 切焦点 + push snapshot | ✓ | `RemoteChatCommandRouter.swift:28-40` + `RemoteChatServer.swift:479-490` |
| 44 | A 在 streaming,切到 B | ✓ | Server 端 controller 是 `ChatRuntimeStore.controller(for:)` 按 sessionId 分配,**A 和 B 是不同的 ChatPanelController 实例**,A 会继续在后台跑。**已修 bug 验证**:`ChatRuntimeStore.swift:89-97` |
| 45 | 切回 A 看到进度 | ✓ | A 的 controller 一直 attach 在 broadcaster 上,patch 一直在流,B 切回 A 时 `requestSnapshot` 把 A 当前快照拉过来 |

---

## 2. P0(必修)

### P0-1 附件未实际传给 backend(数据完整性事故)
**位置**:`ChatPanelState.swift:436-449`(QueuedChatRequest 构造仅把 attachments 作为 UI metadata);`ClaudeCodeProcessBackend.swift:146`(`writeStreamUserMessage(text: prompt, ...)` 只携字符串);`CodexAppServerBackend.swift:259-273`(`turn/start` 的 input 数组只装 `type:text`)。  
**症状**:用户在 iOS 上传图片或贴文件,UI 显示成功,Mac 端 `ChatMessage.attachments` 也保存了,但模型**完全看不到这些内容**,会按"用户没附任何东西"回答。  
**预期**:至少要把 attachment 的 `path` 拼到 prompt 文本里(Claude 在 stdin 是 stream-json,可以加 `content` array 含 `image_url`/`document_path`),或者在 send 前做"附件→Markdown 引用"前处理。  
**最小修复**:在 `startRun` 构造 `prompt` 时,若 `request.attachments` 非空,prepend `"附件:\n- /path/to/file1\n- /path/to/file2\n\n"` 字符串到 backendText。

### P0-2 stop 不清理 permissionRequest / interactiveRequest 的"waiting"状态
**位置**:`ChatPanelState.swift:690-714` `interrupt()` 调 `finishStreamingMessages(status: "stopped")`,该函数(`:1240-1259`)只遍历 `messages where isStreaming == true`。`permissionRequest` 和 `interactiveRequest` 创建时 `isStreaming` 默认 false (`:864-872`, `:879-888`)。  
**症状**:用户在权限/交互请求弹出时按"停止",backend 被 SIGINT 杀掉了,但 UI 上的权限按钮**还活着、status 还是 "waiting"**;再次点击 allow/deny 走到 `respondToPermission` 时 `activeBackend` 已是 nil,会进入 `:733-739` 错误分支翻成 `.failed`。  
**最小修复**:`interrupt()` 里追加一段:对 `messages` 中所有 `status == "waiting"` 且 kind 为 `.permissionRequest`/`.interactiveRequest` 的项,改为 `status = "cancelled"`,并 `bumpStructureRevision()`。

---

## 3. P1(强烈建议)

### P1-1 send race 的 rejected ack 污染 iOS lastError
**位置**:`PanelStateBroadcasterAdapter.swift:256` 首次 ack 返回 `false` → router `:139` 包成 `rejected(message: "send rejected (composer empty or capability check failed)")` → iOS `ChatViewModel.swift:684-688` 把它写进 `lastError`。  
**症状**:即便 500 ms 后重试成功,用户屏幕上仍出现一行红色错误"send rejected (composer empty…)"。  
**修复方案**:服务器侧:`remoteComposerSend` 在选择"延迟重试"路径时返回一个不算失败的 ack 状态(比如新增 `status: "deferred"`),或者在 router 直接返回 ok-with-warning。

### P1-2 `flushQueue` 语义反直觉
**位置**:`PanelStateBroadcasterAdapter.swift:263-267`、`ChatPanelState.swift:2024-2026`、`RemoteChatBridge.swift:273-278`。三处都把 flushQueue 实现为 `interrupt(startQueuedAfterStop: true)`,实际行为是"中断当前 turn,然后跑下一条排队"。  
**症状**:iOS UI 文案"flush queue"读起来像"清空队列",但实际只是切到下一条。如果队列里有 5 条,flushQueue 之后只跑了第 2 条,3-5 还在等。  
**修复方案**:要么改名(`runNextQueuedNow`),要么真改成清空+中断(`queuedRequests.removeAll()` then interrupt)。

### P1-3 Codex error 路径仅 `process.terminate()`,缺 `ChatProcessTerminator`
**位置**:`CodexAppServerBackend.swift:319-322`、`:339-341`。  
**症状**:Codex `app-server` 内部 fork 出子进程时,只 `terminate()` 父进程不级联到子进程,可能留孤儿。  
**修复方案**:统一走 `ChatProcessTerminator.stop(process, terminateAfter: .seconds(1), killAfter: .milliseconds(2200))`,和 `interrupt()` (`:160-170`)保持一致。

### P1-4 stdin 写入无超时
**位置**:`ChatProcessBackend.swift:38-51` `ChatPipeWriter.writeJSONObject` → `pipe.fileHandleForWriting.write(contentsOf: data)`。  
**症状**:`FileHandle.write` 是阻塞 API。若 claude 进程不读 stdin(死锁、CPU pinned),acode 这边 detached task 永远卡在 write,该 session 的 `currentTask` 也不会 cancel。  
**修复方案**:`DispatchQueue.global().async + DispatchSemaphore.wait(timeout: .now() + 2)` 包一层 watchdog;超时 → 杀进程 + 上报 `.failed`。

### P1-5 stop 在 iOS 进同一 send chain,无法插队
**位置**:`ChatViewModel.swift:268-270` `stopGeneration` 走 `sendCommand`,被 `sendChain` 串到尾巴。  
**症状**:用户连发 3 条消息后立刻按"停止",停止命令要等前面 3 个 send 都发完才被发出 ~ 几百 ms 的延迟。  
**修复方案**:`stop`、`respondPermission`、`respondInteractive`、`cancelQueued`、`flushQueue` 这几条**应该是控制平面**,从 `sendChain` 旁路出去走独立 Task,直接 `webSocketClient?.sendCommand`。

### P1-6 附件 HTTP 上传无大小/类型限制
**位置**:`RemoteChatRouter.swift:157-177`,只 base64 解码后写盘,不验证 MIME / 尺寸。  
**症状**:恶意 iOS 客户端可推任意大小、任意类型(可执行)文件到 Mac 临时目录。  
**修复方案**:加 size cap(10 MB?),允许的扩展名白名单(`.png/.jpg/.pdf/.txt/.md/.json/.swift…`)。

---

## 4. P2(可选)

### P2-1 嵌套 tool_use 在 UI 中铺平
`ClaudeCodeProcessBackend.swift:589-610` `assistantEvents` 把 sub-agent 工具调用和顶层 assistant text 串到同一条 message。`parent_tool_use_id` 在解析阶段完全没用。建议把 sub-agent 的 message 用 `parentUserMessageID` 链接成树以便 UI 折叠。

### P2-2 同时多个 permission 请求时 statusText 互相覆盖
`ChatPanelState.swift:874` 每次都覆盖 `statusText = "等待权限"`。理论上 Claude 只串行调一个工具,但保险起见可以叠加 "等待 N 个权限"。

### P2-3 `:1077-1093` `isMCPRemoteEvent` 用 title 字面量匹配
`ClaudeCodeProcessBackend.swift:412` system message 的 title 是 `"Mac tools"`(2 个空格、大小写)。`ChatPanelState.swift:1088` 匹配 `"mac tools"`。如果未来 backend 改 title,远程通道又会出现旧的"Mac 端看不到 MCP 工具列表"问题。建议加一个 `isMCPSystemMessage` 标志位走 ChatMessageKind/subKind。

### P2-4 stream stderr 限 600 行 / 500 行 截断,但 stderr 长输出没限速
`ClaudeCodeProcessBackend.swift:202-222` flush 间隔 1s/50 行,但单行可任意长。理论上单行 100 MB 的 stderr 也会被 yield。建议每行 cap 16 KB。

---

## 5. 设计妥协(已知 trade-off,**非 bug**)

1. `remoteComposerSend` 500 ms 一次性重试 — 客户端如果在 500 ms 后还没把 `composerSet` 送到就放弃。够用,但极慢网络下可能丢消息。
2. broadcaster 在 200 ms 内做两层 throttle(adapter `:332` + broadcaster `:292`),streaming 高峰时每秒最多 5 帧。**这是性能保护,不要去掉**,但确实会让 UI 看起来不那么"丝滑"。
3. `messages` 数组在 controller 内一直保留全量,没有分页/裁剪。长 session 切换时 copy-on-write 开销大。已有 throttle 兜底但若用户在 streaming 中切 session/CLI 仍可能短暂卡 100~200 ms。
4. claude `--include-partial-messages` fallback 是 best-effort 的盲重试,没有 caps probe;如果一直失败会留一条 system 消息但还是 retry 一次。
5. `RemoteSessionMirrorBus` 用 NotificationCenter post + per-session 订阅,事件**没有 ordering 保证**(GCD `.main` queue 入队顺序对的上,但跨 actor 边界可能)。当前 use case 单订阅者,问题不大。

---

## 6. 未覆盖项(本次没验证到)

- attachment 上传断点续传(目前无)
- 大文件(>5 MB)的 thumbnailData 是否会撑爆 patch JSON 编码
- `subagent_transcript` 落盘是否与镜像模式互斥(`SubagentTranscriptStore.swift` 未读)
- `sendCompact()` 在 codex 上的真实行为 — `:210-213` `sendRequest(method: "compact")` 但没有等 response,UI 上"上下文接近上限"是否真触发了压缩
- 多个并发 WS 连接(2 个 iPad 同时连同一个 Mac)的命令竞态 — 当前 `connectionStates` 是 per-connection,但 controller 是共享的,两端的 composer 状态会互相覆盖

---

## 7. 已修 bug 复核(11 项,**不重复报告**)

| # | 已修内容 | 复核结论 |
|---|---|---|
| 1 | claude result → close stdin | ✓ `ClaudeCodeProcessBackend.swift:324-339` |
| 2 | broadcaster attach 200 ms throttle | ✓ `PanelStateBroadcaster.swift:292` |
| 3 | adapter 订阅 streamingTextStore + statusStore | ✓ `PanelStateBroadcasterAdapter.swift:305-339` |
| 4 | iOS sendCommand 串行 | ✓ `ChatViewModel.swift:653-672` 活体验证 |
| 5 | server `remoteComposerSend` 500 ms 重试 | ✓ `PanelStateBroadcasterAdapter.swift:246-256` 活体验证(`qa_race3.py`) |
| 6 | broadcaster.snapshot(for:) 内 attach controller | ✓ `PanelStateBroadcaster.swift:329-346` |
| 7 | PanelStateBroadcaster.lookup 动态 resolver | ✓ `PanelStateBroadcaster.swift:263-270` |
| 8 | resume 协议判定改用 cursor==nil | ✓ `RemoteChatServer.swift:512` |
| 9 | VNC resume 不再回 legacy command_ack | ✓ `RemoteChatServer.swift:517-522` 活体验证(`qa_debug.py`) |
| 10 | iOS 模型卡 fallback 链 | ✓ `ChatViewModel.swift:537-555` |
| 11 | iOS 文件树自动加载 + placeholder | ✓ `ChatViewModel.swift:347-361` |

---

## 8. 实测命令清单(留作回归)

```bash
# Mac App 启动:
killall acode 2>/dev/null; sleep 1; open /Users/oreo/Desktop/Codevoke.app; sleep 9

# Race(send 早于 set 50 ms,验证 500 ms 重试):
python3 /tmp/qa_race3.py

# Command ack 路径:
python3 /tmp/qa_cmd_ack.py

# Resume → panel_state(不会回 command_ack):
python3 /tmp/qa_debug.py
```

落盘路径:`~/Library/Application Support/Codevoke/chat-messages/<session-id>.jsonl`

---

## 9. 总结

本域核心架构稳定,11 项历史 bug 都修得彻底。**剩下的隐患集中在两类**:

1. **数据完整性**:附件未传给 backend(P0-1);
2. **状态机角落**:stop 不清理 waiting 状态(P0-2)、rejected ack 噪声(P1-1)、Codex 终止信号不彻底(P1-3)、stdin 无 hang 保护(P1-4)、stop 控制平面进 sendChain(P1-5)。

P0 两条**强烈建议本次发版前修掉**——附件不工作是产品级问题;P1 五条本周内排进迭代。
