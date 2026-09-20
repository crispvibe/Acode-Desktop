# Audit — Domain C: UI Switching · Projects · Files · Settings

审计员: QA agent C (read-only)
日期: 2026-05-16
范围: iOS `acode` + Mac `Codevoke.app` UI / 项目 / 文件树 / 设置面板。仅做静态 code trace，未跑 simulator。
互不重叠的两个 agent 负责"连接+协议"和"消息流+streaming"。

---

## 1. 摘要 (severity 排序)

| ID | Sev | 一句话 |
|----|-----|--------|
| C-01 | **Blocker** | iOS `handleAck` 顺序错误，导致 `newDraftSession` 自动 `focusSession` 永不触发 — 新对话按钮无效 |
| C-02 | High | iOS 缺少权限模式 (`permissionMode`) 与推理强度 (`reasoningEffort`) 的全部 UI；server 字段是只读暴露。场景 10–14 全部失败 |
| C-03 | High | iOS 完全不显示 `capability.errorMessage`；Codex 缺失/Claude 启动失败时 UI 没有任何反馈。场景 4 失败 |
| C-04 | High | iOS 选会话不同步项目：选择跨项目 session 后 `selectedProject` 仍跟随 `_localSelectedProjectId` 而非 session.projectId，导致顶栏标题/文件树跟实际会话不一致 |
| C-05 | High | iOS startup race：未存在 controller 时 `composerSetCLI` / `composerSetModel` 全被 server 拒绝 (`session not focused`)，但 UI 不展示 ack error，用户感知"切换没反应" |
| C-06 | Med | iOS 文件树查询字符串编码不完整：含 `+` / `&` / `=` / `?` 的目录名会被 server 解析错误（query 参数被截断或 `+`→空格） |
| C-07 | Med | iOS `selectProject` 切到无任何 session 的项目时，没有自动建草稿；用户必须再点"新对话"才能发消息。状态不直观 |
| C-08 | Med | iOS Settings → CLI 页：`Claude ask` 模式被 README 标记"当前禁用"，但 router 仍然允许通过 `composerSetPermissionMode` 设为 `ask`；权限 UI 又没暴露这个开关，所以 UI 看不见，但若来自外部命令仍会落入未实现的状态 |
| C-09 | Med | iOS Sidebar：`isLoadingMessages` 用 server `composer` 字段判断，期间整段 session 列表被禁用 (line 188 `guard !isLoadingMessages \|\| session.id != state.selectedSessionID else { return }`)；如果 server 一直 `isLoadingHistory=true`（异常情况）侧栏永久卡住，没有重试 |
| C-10 | Med | iOS Sidebar 项目区硬上限只显示前 5 个 (`projects.prefix(5)`)、聊天记录前 8 条 (`sessions.prefix(8)`)；多项目用户没有"展开更多"入口 |
| C-11 | Low | `openParentDirectory` 不重置 `autoLoadedProjectId`，正常无副作用，但若中途切回根目录有缓存空文件夹场景会重复触发 auto load |
| C-12 | Low | `RegisterView` 没有验证码字段：`AuthViewModel.requestRegister` 调用 `authClient.register(phone:password:)` 时不传 code，而 `requestRegisterCode` 又能发短信 — 注册码功能形同虚设 |
| C-13 | Low | `ForgotPasswordView` 实际只显示 QQ 客服号，根本没用 `AuthViewModel` 里的 `forgotPhone/forgotCode/...` 字段；那批字段是死代码，但仍占用 token 校验逻辑 |
| C-14 | Low | iOS `savePreferences` 文档说"no-op"，但 SettingsModelsPage 仍在每次点击模型时调用一次 — 残留代码混淆维护 |
| C-15 | Low | iOS 文件树最大 200 条 (server side `prefix(200)`)；超过的目录无任何"还有更多"提示，用户以为没了 |
| C-16 | Low | Mac `RuntimeStorePanelControllerLookup.allControllers()` 只返回当前 controller；多会话场景下 router fallback 在 newDraftSession 找不到 controller 时会失败 |
| C-17 | Info | 性能：iOS sidebar `LazyVStack` 包 4 段 + 文件区另一层 `LazyVStack`，再加 `ScrollView`，目前文件项 ≤200 条所以可控；超大目录场景仍需关注 |
| C-18 | Info | 性能：`autoLoadFilesForCurrentProjectIfNeeded` 在每次 snapshot/patch 都跑判断，但 guards 充分；目前无 CPU 风险 |

---

## 2. CLI / 模型 / 权限 / 推理强度 切换

### 2.1 CLI 切换 (claude ↔ codex)

**路径** (`CodevokeIOS/Codevoke/Views/SettingsView.swift:251-279` → `ChatViewModel.swift:226-229`)
```swift
viewModel.selectCLI("claude" | "codex")  // → composerSetCLI 命令
```

- `RemoteChatCommandRouter.swift:66-74` 校验 `cli` 必须是合法 `CLIType`，然后 `controller.remoteComposerSetCLI`。
- Mac `PanelStateBroadcasterAdapter.swift:183-185` → `setCLI(cli.visibleValue)` → `ChatPanelState.swift:1891-1895`，只在不同才赋值。

**场景 1 - 普通切换**: OK。

**场景 2 - 切换 CLI 时本来 streaming**: `setCLI` 只改 `composerCLI`，不打断当前 turn (`ChatPanelState.swift:1891`)。当前活跃 turn 仍按旧 CLI 继续。下一条消息会用新 CLI，符合预期。但 iOS 无任何提示告诉用户"切换将在下一条生效"。建议在 SettingsCLIPage 加 hint。

**场景 3 - 切换后 model 列表自动切换**: 切换后 `composer.modelID` 仍是旧值；UI 上 `selectedModelTitle` 的 fallback 链 (`ChatViewModel.swift:537-555`) 已经修过、会落到新 CLI 的默认模型 title。但 server 端 `composerModelID` 没变，下一次发送会沿用旧 modelID（可能跨 CLI），不一定可用。Mac 端 send 时大概率被 `ChatModelCatalog.defaultClaudeModelID` 兜底 (`ChatPanelState.swift:1861`)，但这是隐式 fallback，没人提示用户。

**场景 4 - Codex 不可用时禁用切换**: ❌ **Bug C-03**。
- `PanelComposerDTO.isEnabled` 只反映"当前选定 CLI"是否可用，不暴露另一边的 capability 状态。
- `state.capabilities` (`PanelStateSnapshot`) 里包含 `errorMessage`，但 iOS UI **完全没读取**。`SettingsView.swift:251-279` 的 cliOptions 是两个写死的卡片，永远 enabled。
- 用户点 Codex 卡 → `composerSetCLI` → Mac 接受 → snapshot 更新 `composer.cli=codex` 但 `composer.isEnabled=false`。`canSend` 因此变 false，但顶栏 / Settings 都不显示原因。

### 2.2 模型切换

**路径**: SidebarView 模型卡 (`SidebarView.swift:142-158`，Menu) 或 Settings → 模型 (`SettingsView.swift:281-330`)。

- iOS 发 `composerSetModel`；Mac `ChatPanelState.setModel` 只改 composerModelID (`ChatPanelState.swift:1897-1901`)。
- **场景 6**: 跑中切换 → 下一条消息生效。当前 turn 不变。OK。
- **场景 7 - 跨 CLI 选 model**: ⚠️。`composerSetModel` 不校验 model 是否属于当前 CLI；server `models` 列表里 claude 和 codex 模型都有，但 UI Menu (`SidebarView.swift:143`) 也没按 CLI 过滤。用户可能选到错 CLI 的 model，下次发送时按 `composerCLI` 走仍会用错误 modelID。
- **场景 8**: fallback 链已修，确认 (`ChatViewModel.swift:537-555`)。
- **场景 9**: Mac 启动 `ChatModelService.options(for:)` + relay profile 影响：`PanelStateBroadcasterAdapter.swift:421-433` 把两个 CLI 的所有 option 合并扔进 snapshot 的 `models[]`，未携带 cli 划分提示——iOS UI 也没分组展示。

### 2.3 权限模式切换 ❌ Bug C-02

`ChatViewModel.swift:531` 暴露了只读 `selectedPermissionMode`，但所有 iOS 视图都没有 `permissionMode` 写入 UI。`grep` 全仓库无任何调用 `composerSetPermissionMode`。
- 场景 10–11 - 用户无法切换权限模式，server 永远停在 `autoEdit`。
- 场景 12 - Codex 三态映射代码存在 (`ChatModels.swift:82-95`)，但 iOS 没有入口触达。

### 2.4 ReasoningEffort 切换 ❌ Bug C-02 同源

`ChatViewModel.swift:532` 同样只读暴露 `selectedReasoningEffort`。无任何 UI。场景 13–14 全部失败。

---

## 3. 项目 (Project) 相关

### 3.1 iOS 项目切换 (`SidebarView.swift:112-134`)

`ChatViewModel.selectProject` (`ChatViewModel.swift:205-218`):
1. 设 `_localSelectedProjectId = project.id` ；
2. 清 file tree 缓存 ；
3. `loadFilesIfPossible(projectId, "")` 拉根目录；
4. 在新项目下默认 `focusSession` 到该项目的第一个 session（若存在）。

**场景 15 - auto load**: OK。

**场景 16 - streaming 中切项目**:
- 当前 controller 仍在跑旧 session；`focusSession` 命令送到 server，server 改 `connectionStates[id].focusedSessionID`。
- 但 streaming 还是基于旧 controller 的 snapshot；server 推 patch 仅给当前 focused session — 切到新 session 后，旧 session 的进度看不到了（符合 VNC 模型，但 UI 没给"还在后台跑"的提示）。

**场景 17 - 项目列表来源**: 通过 `PanelStateSnapshot.projects[]` (`RemoteVNCProtocol.swift:32`)，由 `RuntimeStorePanelControllerLookup.catalogSnapshot()` 构造 (`PanelStateBroadcasterAdapter.swift:408-419`)，每次发 snapshot 都重建。OK。

**场景 18 - Mac 增/删项目实时同步**:
- Mac `AppState.addProject` (`AppState.swift:280-293`) / `removeProject` (`AppState.swift:295-310`) 改 `projects` → `ChatPanelController` 的 `objectWillChange` 不会触发，因为 `appState.projects` 不在 controller 的发布链里。
- 实际触发 snapshot 重广播的是 `controller.objectWillChange` 等（`PanelStateBroadcasterAdapter.swift:310-339`）。**Mac 增删项目不会立即让 iOS 看到更新**，得等下次 controller 因别的原因发 snapshot。
- ⚠️ **潜在 Bug**：iOS 主动 `addProject`/删除时需要刷新；目前依赖偶然事件。

**场景 19 - 路径含中文/空格/特殊字符**:
- `RemoteHTTPClient.swift:30` 用 `.urlQueryAllowed` 对 `path` 编码。中文、空格 OK。
- ❌ Bug C-06: 含 `+`、`&`、`=` 的目录会在 server `parseQuery` 被截断或转空格。
  - server `RemoteChatHTTP.swift:119-120`: `replacingOccurrences(of: "+", with: " ").removingPercentEncoding`。
  - 比如目录 `a+b` 会被请求成 `path=a%2Bb` (`+` 在 urlQueryAllowed 里不会被编码 → 实际 `path=a+b`) → server 解析后变成 `path=a b` → 404。
  - 修复: iOS 端应用更严格的 percent encoding（`CharacterSet.urlPathAllowed` 的反集），或用 URLComponents 拼装。

### 3.2 Mac 项目侧栏 (`ProjectSidebarView.swift`)

**场景 42 - toggleProjectExpansion 旧 bug**: 已修。代码 (`ProjectSidebarView.swift:137-152`) 显式处理"重复点击已选项目只展开历史"分支，避免覆盖未保存草稿。OK。

**场景 43 - 切换历史会话保留草稿**: `selectProjectOpeningLatestChat` (`AppState.swift:322-353`) 检查 `wasInNewChatState = selectedMode == .newSession && selectedCLIHistoryID == nil`；如果用户在草稿状态切项目，**不会**自动 resume 历史。OK。

**场景 44 - 删除项目高亮跟随**:
- `removeProject` (`AppState.swift:295-310`) 在 `selectedProjectID == project.id` 时立即重置为 `projects.first?.id`。OK。
- 但 `confirmDiscardUnsavedChangesIfNeeded()` 只在当前选中的项目被删时检查；删非选中的项目时不弹确认。这是设计选择不算 bug。

**场景 45 - EditorAreaView 文件打开**: `AppState.handleFileTreeActivation` (`AppState.swift:617`) → `openFile`；未受本轮 chat 重构影响。OK。

---

## 4. 文件树

### 4.1 iOS 文件树 (`SidebarView.swift:204-276`)

**场景 20 - 自动加载首次**:
- `autoLoadFilesForCurrentProjectIfNeeded` (`ChatViewModel.swift:351-361`) 节流条件齐全:
  - `!isLoadingFiles`
  - `selectedProject != nil`
  - `autoLoadedProjectId != project.id || fileEntries.isEmpty`
  - `fileEntries.isEmpty && fileError == nil`
- 触发点是 `adoptSnapshotIfFocused` (`ChatViewModel.swift:801-811`)。OK。

**场景 21 - 进入子目录**: `openFileEntry` (`ChatViewModel.swift:300-303`)。OK。
**返回上一级**: `openParentDirectory` (`ChatViewModel.swift:324-327`)。OK。

**场景 22-23 - 大目录 / 深嵌套**:
- 服务端 `RemoteChatRouter.swift:291` 强制 `prefix(200)`。
- iOS 用 `LazyVStack` 渲染，渲染本身没问题；但**Bug C-15**: 用户看到的 200 条之后被截断且无任何提示。

**场景 24 - 边界情况**:
- 空目录：server 返回 `entries=[]`，iOS `fileRows` 显示 "空文件夹" placeholder (`SidebarView.swift:241`)。OK。
- 不可读目录：server `FileManager.default.contentsOfDirectory` 抛错 → 500 → iOS 落到 `fileError` 分支 → 显示 "文件读取失败" (`SidebarView.swift:227-229`)。OK。
- 符号链接：server `isURL(_:inside:)` 用 `resolvingSymlinksInPath` 检查 (`RemoteChatRouter.swift:443-449`)，已修穿越漏洞。OK。
- 二进制文件名（非 UTF-8 字节）：`FileManager.contentsOfDirectory` 会返回带 replacementCharacter 的 name；通过 JSON encode 应该 OK，但 round-trip 时 `relativePath` 可能与磁盘真实 path 不匹配。Edge case。

**场景 25 - 目录穿越**:
- `sanitizedRelativePath` (`RemoteChatRouter.swift:352-357`) 过滤 `..` 和 `.`；
- `isURL` 二次校验 `resolvingSymlinksInPath` 后的 path 必须在 root 之内 (`RemoteChatRouter.swift:443-449`)。
- 看上去安全。✅

**场景 26 - 长按复制路径**:
- iOS `SidebarView.swift:259-272` 提供 contextMenu "复制绝对路径"。
- `RootView.swift:164-168` 调 `viewModel.absolutePath(for:)` → 设到剪贴板并 `insertPathIntoInput`（自动塞到输入框）。
- 但 `absolutePath` 用 `project.path` (`ChatViewModel.swift:307`)。如果 Mac 项目 `path` 不是绝对路径（应该是因 bookmark resolve 后总是绝对，但代码无强制保证），可能产生错误路径。

**场景 27 - 项目切换状态重置**: `selectProject` (`ChatViewModel.swift:205-218`) 主动重置 `autoLoadedProjectId`、`fileEntries`、`fileError`、`currentFilePath`、`parentFilePath`。OK。

### 4.2 Mac 文件树 (`FileTreeView.swift`, `ProjectSidebarView.swift:172-256`)

未受本轮 chat 重构影响；之前 `FileTreeKeyboardBridge`、`pendingFileTreeScrollTargetID`、`expandedFileTreePaths` 等都保留。OK。

---

## 5. Sidebar

### 5.1 iOS Sidebar (`SidebarView.swift`)

**场景 28 - 顶部模型卡 (空白问题已修)**: `selectedModelTitle` fallback 链 (`ChatViewModel.swift:537-555`) 已修。空 models 列表显示 "默认模型"。OK。

**场景 29 - 聊天记录列表**:
- 显示前 8 条 (`SidebarView.swift:186` `sessions.prefix(8)`)。⚠️ **Bug C-10**: 多于 8 条会被隐藏，无展开入口。
- queuedCount 没在 sidebar 显示；只在 ChatView 队列卡显示。规格里就没要求 — OK。
- 加载中 placeholder `加载中...` (line 193)。OK。

**场景 30 - 项目列表高亮**:
- `state.selectedProjectID` 比较项目 id，匹配则 `selected=true` (`SidebarView.swift:127`)，背景变黑、字白 (`SidebarView.swift:321`)。OK。
- ⚠️ Bug C-10: 只显示前 5 个 `projects.prefix(5)`。

**场景 31 - 文件区状态**:
- `先选择项目` / `空文件夹` / `加载中` / 错误 都已实现 (`SidebarView.swift:225-275`)。✅

### 5.2 Mac Sidebar (`ProjectSidebarView.swift`)

各种状态: empty、loading、normal。OK。
`ScrollView .frame(maxHeight: 210)` 在 4 个以上项目时会变内部滚动 (`ProjectSidebarView.swift:132`)。OK。

---

## 6. 设置页 (Settings)

### 6.1 iOS `SettingsView.swift`

**场景 32 - 远程连接**:
- 表单字段 host/port/token 三连存在 (`SettingsView.swift:210-215`)。
- `saveConnectionConfig` 后调 `savePreferences(refetchModels: true)` (`SettingsView.swift:233`) — 但 `savePreferences` 是 no-op (`ChatViewModel.swift:141-143`)。Bug C-14 残留代码。
- 保存后 `close()` → 关闭 settings overlay。OK。

**场景 33 - 账号登录信息**:
- 当前账号显示在 `SettingsAccountPage` (`SettingsView.swift:127-171`)：手机号 + "状态正常"；点击进入修改密码、退出登录。
- "退出登录"按钮调 `authViewModel.clearSession()` → `tokenStore.clear()` → `gateState = .unauthenticated`，UI 自动跳回 AuthRoot (`AppRootView.swift:18-19`)。OK。

**场景 34 - 中转站 (relay) profile 管理**:
- `SettingsRelayPage` (`SettingsView.swift:332-467`) 完整：列出 profiles、激活、编辑、新建、拉取模型。
- 注意：拉取模型用的是 `chatViewModel.fetchClaudeRelayModels` (`ChatViewModel.swift:454-473`)；它需要 `relayDraft.baseURL` 已填写。若用户只点 "拉取模型" 但没填 baseURL，会显示 "请先填写 ANTHROPIC_BASE_URL"。OK。
- 已拉取模型只显示前 12 条 (`SettingsView.swift:401` `prefix(12)`)。Edge case。

**场景 35 - 默认 CLI / 模型 / 偏好 no-op**:
- 字段确认: `savePreferences` 是 no-op (`ChatViewModel.swift:141-143`)。
- 但 `SettingsModelsPage` 仍然在选模型后调一次 (`SettingsView.swift:321`)，`SettingsConnectionPage` 也调一次 (`SettingsView.swift:233`)。**Bug C-14**：建议移除残留调用，否则将来谁加回非 no-op 实现时会产生意外副作用。

**场景 36 - 调试日志**:
- `debugLogText` 在 `ChatView` 的 `debugLogCard` 显示 (`ChatView.swift:687-707`)，但**这个 debugLogCard 没被任何视图调用**！`grep` `debugLogCard` 全文件只在定义处出现一次。
- `viewModel.shouldShowDebugLog` (`ChatViewModel.swift:628-630`) 也是孤儿。
- 用户实际看不到调试日志（虽然 `appendDebug` 还在累加）。算 dead UI code，但每次写日志都开销 += `debugLogs.append`。

### 6.2 Mac Settings

未审；规模外。`AppState.showSettings` 字段在 Mac 也有但 UI 在 `SettingsPageView.swift`，本次范围外。

---

## 7. 认证流 (Auth)

### 7.1 `AuthRootView.swift`

- 单一 `@State screen` 在 login/register/forgot 之间切换 (`AuthRootView.swift:5-30`)。OK。
- `legalDocumentBinding` 没处理 `set` 写入 — 总是 dismiss (`AuthRootView.swift:44-49`)。无影响。
- iOS 进入 `AppRootView` 时 `bootstrap` 一次 (`AppRootView.swift:24-28`)，按 `gateState` 三态切换。

### 7.2 `LoginView.swift`

- 手机号 + 密码 + 用户协议复选 + 登录按钮。
- `AuthViewModel.requestLogin` (`AuthViewModel.swift:122-146`) 校验非空 + 协议勾选；不做手机号格式校验（11 位数字等）。⚠️ **场景 37 - 校验弱**：纯空字符串挡住了，其他都靠服务器校验。
- 失败提示统一覆盖到 `loginMessage`。OK。

### 7.3 `RegisterView.swift`

- **场景 38 - 验证码请求**: ❌ **Bug C-12**。RegisterView UI 里**没有验证码 TextField**！但 `AuthViewModel` 完整实现 `requestRegisterCode` / `registerCooldown`。`AuthCodeField` 组件存在 (`AuthComponents.swift:139-189`) 也未被使用。
- 实际 `requestRegister` 调 `authClient.register(phone:password:)` 不传 code (`AuthViewModel.swift:188`)，所以注册根本不需要短信验证 — 但 ViewModel 里那一整套 cooldown / sending 状态都是死代码。
- 跟后端实际接口是否一致需进一步验证（如果后端不要 code 则只是死代码，如果要则注册必失败）。

### 7.4 `ForgotPasswordView.swift`

- **场景 39 - 忘记密码**: ❌ **Bug C-13**。UI 只是显示一行 "联系管理员 QQ: 99400504"，根本没用 `forgot*` 字段。这部分客户端逻辑（`requestForgotPasswordCode` / `requestPasswordReset`）是死代码。
- 体验上是"占位实现"，但代码混淆维护人。

### 7.5 token 过期

- **场景 40 - 自动跳回登录**: `AuthViewModel.bootstrap` (`AuthViewModel.swift:65-87`) 启动时检查 `session.isExpired` → 用 refreshToken 续期；失败 `clear` → unauthenticated。
- 运行期间任意 401 不会触发 `clearSession`（没在 HTTP client 里 hook 401）。如果服务器中途返回 401，iOS 仍在 `authenticated` 状态展示空数据。
- `refreshSessionIfNeeded` (`AuthViewModel.swift:277-288`) 存在但没有定时调用入口。死代码。

### 7.6 `gateState` 切换时机

- `.checking` 初始 → bootstrap 后变 `.authenticated` 或 `.unauthenticated` (`AuthViewModel.swift:78-86`)。
- `persistSession` 成功后立即变 `.authenticated` (line 299)。
- `clearSession` 立即变 `.unauthenticated` (line 293)。
- 中间过渡用 `.smooth(duration: 0.2)` 动画 (`AuthRootView.swift:34`)。OK。

---

## 8. 空 / Loading / Error 状态

**场景 46 - 首次启动未连接**:
- `init` 设 `isSettingsPresented = !config.isComplete` (`ChatViewModel.swift:116`)，强制把 Settings 推到前面。OK。
- 但若用户登录后又把 config 清空，下次启动会进入 settings overlay；体验上没问题。

**场景 47 - WS 连接状态**:
- `connectionStatus` 字符串："未连接" / "正在连接" / "已连接" / "连接失败" / "连接中"。
- ChatView 顶栏用绿色/灰色圆点 (`ChatView.swift:666-674`) 表示。OK。
- Sidebar 顶部"刷新"按钮在 `isRefreshing` 时 disabled (`SidebarView.swift:108`)。OK。
- 但 `canSend` (`ChatViewModel.swift:587-588`) 在 streaming 中仍允许发送（因为只看 composer.isEnabled 或 messages 非空或有项目），这一逻辑由消息流 agent 审。

**场景 48 - 切 session 时 isLoadingHistory**:
- Sidebar `state.isLoadingMessages` 显示 ProgressView (`SidebarView.swift:168-171`)。
- Session row 加载中 subtitle 改成 "加载中..." (`SidebarView.swift:193`)。
- ChatView `loadingMessagesCard` (`ChatView.swift:620-632`) 在消息列表里显示。OK。
- ⚠️ Bug C-09: `guard !state.isLoadingMessages || session.id != state.selectedSessionID else { return }` (`SidebarView.swift:188`) — 加载中时其他 session 仍可点；但若 server 永远没把 `isLoadingHistory` 翻回 false（异常情况），当前 selected session 永远不能重新点击。无超时机制。

**场景 49 - ack 失败的 UI 反馈**:
- `handleAck` 将 ack.message 写到 `lastError` (`ChatViewModel.swift:684-688`)。
- `lastError` 在顶栏不显示，只在 ChatView 消息列表里以 error MessageRow 形式渲染一行 (`ChatView.swift:482-484`)。
- 但 SettingsConnectionPage 也读了 `lastError` (`SettingsView.swift:222-228`)。
- 切 CLI / 切模型 / 切权限失败时，错误是被记到 `lastError`，但用户在 Settings 里看不到（因为 SettingsConnectionPage 关掉后再切其他设置，错误来了不在视野内）。需要给每个 SettingsPage 加 error banner。

---

## 9. 关键 Bug 详解

### C-01 (Blocker) — newDraftSession 自动 focus 永不触发

**文件**: `CodevokeIOS/Codevoke/ViewModels/ChatViewModel.swift:674-689`

```swift
private func handleAck(_ ack: CommandAck) {
    if let idx = pendingCommands.firstIndex(where: { $0.id == ack.commandId }) {
        pendingCommands.remove(at: idx)        // ← 先移除
    }
    if let sessionId = ack.sessionId, ack.status == .ok,
       let entry = pendingCommandsByIdLookup(id: ack.commandId),   // ← 然后查找，永远是 nil
       entry.command.op == .newDraftSession {
        sendCommand(Command(op: .focusSession, ...))
    }
    ...
}
```

`pendingCommandsByIdLookup` 在 `pendingCommands` 数组里查，但上面刚把该 id 移除。第二个 `if` 永远进不去。结果：
- iOS 点"新对话" → `startNewChat()` (`ChatViewModel.swift:191-201`) 发 `newDraftSession`，ack 回来带 sessionId。
- 但 iOS 没自动发 `focusSession` 切到新 session。用户点"新对话"之后侧栏会高亮新 session？不会 — 因为 server 没收到 `focusSession`，iOS `focusedSessionId` 还是旧的，下一个 snapshot 还是旧 session 的。

**修复方向**: 把 op 类型 / sessionId 在 remove 前缓存。

### C-02 (High) — 缺权限/推理强度 UI

iOS 用户在多 CLI 场景下被锁定在 server 默认 (`autoEdit`/`high`)；任何需要切到 ask 模式或调低推理强度的场景全部无解。

**修复方向**: 在 Settings 里加两个 SettingsOptionRow 列表（参考 SettingsCLIPage 结构）。

### C-03 (High) — capability.errorMessage 不展示

snapshot.capabilities 携带的 errorMessage（如"未找到 codex"）从未被读取。Codex 不可用时切到 codex，client 仍执行命令，server 仍接受、修改 composerCLI，但 composer.isEnabled 变 false，没有解释。

**修复方向**: SettingsCLIPage 每个 CLI 卡片下方显示 `capabilities[cli].errorMessage`，并 disable 该卡。

### C-04 (High) — 选会话不联动项目

`selectedProject` (`ChatViewModel.swift:568-580`) 优先用 `_localSelectedProjectId`。用户在 sidebar 选 session（不是 project）时，`selectSession` 只发 `focusSession`，不触发 `_localSelectedProjectId` 变化。即使 session 来自项目 P1，`_localSelectedProjectId` 仍是用户之前点的 P2 → 顶栏标题、文件树都是 P2 的。

**修复方向**: `selectSession` 时同步更新 `_localSelectedProjectId = session.projectId`，并触发 file tree reload。

### C-05 (High) — startup race，无 controller 时设置失败

首次启动、未点 "新对话" 时：
- Mac `runtimeStore.controller(for: nil)` 返回 `lastKnownState`，初始可能是 nil。
- iOS 在 Settings 切 CLI/模型 → router `lookupController(for: scope=nil)` 拿不到 controller → 返回 `rejected: "session not focused"` (`RemoteChatCommandRouter.swift:71`)。
- ack 写到 `lastError`，但 Settings 页面看不到。用户感知"切换无反应"。

**修复方向**:
1. iOS 端在没有 currentSnapshot 时禁用 CLI/Model/Permission/ReasoningEffort 切换，提示先 "新对话"；或
2. Mac 端 router 在 scope=nil 时主动 `allControllers().first` fallback（部分 op 已经这么做，比如 newDraftSession）；
3. ack.message 接力到 SettingsPage 的 SettingsMessageView。

### C-06 (Med) — query 编码不完整

iOS `RemoteHTTPClient.swift:30` 应改用 `URLComponents` 或更严格的 charset:
```swift
let allowed = CharacterSet(charactersIn: "/-._~").union(.alphanumerics)
path.addingPercentEncoding(withAllowedCharacters: allowed)
```

### C-07 — 选空项目不建草稿

用户加一个新项目 → 没有 session → iOS UI 显示项目高亮、文件树加载，但 ChatView 处于"无 session"状态 (`navigationSubtitle` 显示"新对话"，但 composer.isEnabled = false 因为没 controller)。
点 "新对话" 才会发 newDraftSession。**期望**: `selectProject` 在该项目无 session 时自动发 `newDraftSession`。

### C-16 — allControllers 只返一个

`RuntimeStorePanelControllerLookup.allControllers()` (`PanelStateBroadcasterAdapter.swift:392-403`) 只返 `runtimeStore.controller(for: nil)`，这是"最后激活的 controller"。
- router 在 `newDraftSession` 找不到 lookupController(for: nil) 时 fallback `allControllers().first` (`RemoteChatCommandRouter.swift:46`)，但这只是同一个 controller。
- 真正没 controller（fresh install）就直接 reject。

---

## 10. 性能 / 内存 关注点（仅 UI 域）

| 项 | 当前 | 风险 |
|----|------|------|
| iOS sidebar | 项目/会话/模型都有 prefix() 上限 | 低 |
| iOS 文件树 | server 限 200，iOS LazyVStack | 低 |
| iOS `autoLoadFilesForCurrentProjectIfNeeded` | 每次 snapshot/patch 都跑判断，但 guard 严格 | 低 |
| iOS `debugLogs` 数组 | 上限 200 (`ChatViewModel.swift:849-851`) | 低，但 UI 不显示也无人 drain |
| iOS `pendingCommands` | 上限 200 | 低 |
| Mac ProjectSidebar `sessionsByProjectKeyCache` | 接 `appState.$cliHistory` 重建 | OK |
| Mac FileTreeKeyboardBridge | 装一个 NSEvent local monitor，移除时正确 deinit | OK |

整体 UI 域无明显 CPU 卡顿/内存泄漏风险。`debugLogs` 累加但不显示是浪费一点点内存（≤200 行 \* 平均 80 字符 ≈ 16KB），可忽略。

---

## 11. 端到端最小复现脚本（建议）

由于 iOS 端测试需要真机/simulator + 账号，下列复现仅写文字步骤：

| Bug | 步骤 |
|-----|------|
| C-01 | 1) iOS 已连接 Mac；2) Sidebar 点"新对话"；3) 观察右边消息列表 — 应当切到新空白会话，但实际仍是旧 session 的消息。 |
| C-02 | 1) 在 iOS Settings 找权限模式选项 — 不存在。 |
| C-03 | 1) Mac 上卸载 codex CLI；2) iOS Settings → CLI 选 Codex；3) ChatView 顶栏不显示原因，输入框被 disable。 |
| C-04 | 1) iOS 项目 P1 选中；2) 点项目 P2 — 高亮变 P2；3) 点 P1 的某个历史 session — `selectedProject` 仍是 P2 但 ChatView 顶栏显示该 session 的 title。 |
| C-05 | 1) 全新启动 Mac，iOS 立刻打开 Settings 切 model；2) 注意没有任何反馈；3) `lastError` 累加但看不见。 |
| C-12 | 1) 进入 RegisterView；2) 找验证码输入框 — 没有。 |

---

## 12. 不在范围内 (交由其他域)

- WS / HTTP 鉴权细节（域 A）
- 消息 streaming、queue、permissionResponse、interactiveResponse 的 UI 反馈（域 B）
- 工具卡片、Tool result 渲染（域 B）
- ChatView 滚动行为细节（域 B）

---

## 13. 不重复已修 bug

按本仓库提示及 commit log：
- IME 输入 (`73a296a`): 不重审。
- 工具可视化 (`b66c547`): 不重审。
- ChatRuntime continuity (`14cc1fa`): 不重审。
- 项目切换 `toggleProjectExpansion`：已修，本审计验证仍可用 (`ProjectSidebarView.swift:137-152`)。
- iOS 模型卡空白：fallback 已加 (`ChatViewModel.swift:537-555`)。
- 文件树符号链接穿越：服务端已加 `resolvingSymlinksInPath` (`RemoteChatRouter.swift:443-449`)。

以上不再列入新 bug。

---

## 14. 建议优先级

1. **C-01 修复** — 一行代码改顺序，但用户感知"新对话按钮坏了"，影响极大。
2. **C-02 + C-03 + C-05 一起做** — 加 PermissionMode / ReasoningEffort UI、显示 capability error、空状态禁用切换。是一组体验闭环。
3. **C-04** — 选会话联动项目。
4. **C-06** — 文件树 query 编码加强。
5. **C-12 / C-13** — 决定要不要保留验证码流程，移除死代码或补 UI。
6. 其余 Low / Info 项纳入清理 backlog。
