# iOS 16/17/18/26 UI 兼容改造方案

## 目标

- 最低支持 iOS 16。
- 保持当前 iOS UI 排版、层级、尺寸和整体视觉不变。
- 不依赖高版本系统视觉 API 来决定主 UI 风格。
- 对 iOS 16、iOS 17、iOS 18、iOS 26 做条件适配或自定义还原。
- 将聊天输出中的思考态统一纳入兼容设计：发送后、实际输出前显示三个灰色圆点动画，收到输出后立即消失。

## 审计结论

当前 iOS 工程的 deployment target 仍为 `26.0`，不能直接降到 iOS 16。需要先处理高版本 API 和视觉差异，再调整 `IPHONEOS_DEPLOYMENT_TARGET`。

### 当前阻塞点

| 项目 | 位置 | 风险 | 处理建议 |
| --- | --- | --- | --- |
| `IPHONEOS_DEPLOYMENT_TARGET = 26.0` | `Mac版本/Codevoke.xcodeproj/project.pbxproj` | 无法验证 iOS 16 编译 | 最后降到 `16.0` |
| `glassEffect` | `VisualStyle.swift` | iOS 26+ API，视觉跨版本不一致 | 改为自定义 glass 视觉，iOS 26 也默认走统一实现 |
| 双参数 `onChange` | `ChatView.swift`、`InputBarView.swift` | iOS 17+ API | 替换为 iOS 16 兼容封装或旧签名 |
| `presentationCornerRadius` | `RootView.swift` | iOS 16.4+ API | 封装 availability，iOS 16.0-16.3 内容层兜底 |
| `TextField(axis: .vertical)` | `InputBarView.swift` | iOS 16 可用，但多行行为跨版本可能不一致 | P1 改为自定义 `UITextViewRepresentable` |
| 系统 `Menu` | `InputBarView.swift`、`SidebarView.swift` | iOS 16 可用，但弹出位置/样式跨版本略有差异 | 若要求完全一致，改自定义浮层 |

## API 兼容矩阵

| API/能力 | iOS 16 | iOS 17 | iOS 18 | iOS 26 | 结论 |
| --- | --- | --- | --- | --- | --- |
| `NavigationStack` | 可用 | 可用 | 可用 | 可用 | 保留 |
| `PhotosPicker` | 可用 | 可用 | 可用 | 可用 | 保留 |
| `fileImporter` | 可用 | 可用 | 可用 | 可用 | 保留 |
| `Menu` | 可用 | 可用 | 可用 | 可用 | 可先保留，后续可自定义 |
| `TextField(axis: .vertical)` | 可用 | 可用 | 可用 | 可用 | 可先保留，推荐后续自定义输入框 |
| `scrollDismissesKeyboard` | 可用 | 可用 | 可用 | 可用 | 保留 |
| `presentationDetents` | 可用 | 可用 | 可用 | 可用 | 保留 |
| `presentationCornerRadius` | 16.4+ | 可用 | 可用 | 可用 | 必须封装 |
| 双参数 `onChange` | 不可用 | 可用 | 可用 | 可用 | 必须替换 |
| `glassEffect` | 不可用 | 不可用 | 不可用 | 可用 | 不作为主视觉实现 |

## 设计原则

1. UI 调用层尽量不变。
2. 高版本 API 不直接散落在业务视图里。
3. 所有跨版本差异放到 `CodevokeCompatibility`、`VisualStyle` 或独立组件里。
4. 视觉优先使用自定义实现，而不是系统默认材质差异。
5. 动画遵守 reduced motion：如果系统减少动态效果，思考动画降级为静态三个点。

## 分阶段实施方案

### 阶段 1：兼容层准备

新增或改造：

- `CodevokeCompatibility.swift`
- `VisualStyle.swift`

处理：

- 替换双参数 `onChange`。
- 包装 `presentationCornerRadius`。
- 封装 sheet 样式。
- 保留现有 UI 排版。

验收：

- 当前 SDK 构建通过。
- 将 deployment target 改为 iOS 16 后编译通过。

### 阶段 2：自定义 glass 视觉系统

改造 `VisualStyle.swift`：

- `codevokeGlass(cornerRadius:)` 不再默认使用 `glassEffect`。
- 使用白色半透明背景、material、顶部高光、描边、阴影组合。
- `acodeCircleGlass()` 使用相同风格还原圆形按钮。
- `GlassCard` 保持现有调用方式。

覆盖对象：

- Chat 主卡片。
- 输入栏外层。
- Sidebar。
- Settings 卡片。
- 右上角圆形/胶囊按钮。
- 附件 chip。

### 阶段 3：自定义输入框

新增：

- `CodevokeGrowingTextInput.swift`

目标：

- 替换 `TextField(axis: .vertical)`。
- 保持现有输入栏排版。
- 统一 iOS 16/17/18 的高度、换行、Return 行为和光标行为。
- 支持最小高度、最大高度、placeholder、Return 发送。

验收：

- 空输入。
- 长文本。
- 多行输入。
- Return 发送。
- 附件-only 发送。
- 键盘打开/关闭。
- 点击左上角菜单先收键盘。

### 阶段 4：自定义附件浮层

如果系统 `Menu` 在 iOS 16/17/18 的位置体验不一致，新增：

- `CodevokeAttachmentMenu.swift`

目标：

- 点击 paperclip 后，在输入框左侧上方显示自定义 glass 浮层。
- 两项操作：选择图片、选择文件。
- 点击外部关闭。
- 键盘打开时位置不折叠、不遮挡输入框。

### 阶段 5：输出思考动画

新增或改造：

- `MessageRowView.swift`
- `ChatView.swift`
- `ChatViewModel.swift`

行为：

- 用户发送消息后，`isSending == true` 且还没有 assistant/reasoning 正文输出时，显示一个临时思考气泡。
- 思考气泡显示三个灰色圆点，按顺序缩放/透明度变化。
- 一旦收到实际 assistant/reasoning 输出内容，思考气泡立即消失。
- 请求结束、报错、断开连接时也必须消失。

兼容策略：

- 不使用 iOS 17+ 动画 API。
- 使用 iOS 16 可用的 `withAnimation`、`repeatForever`、`opacity`、`scaleEffect`。
- reduced motion 开启时，不做循环动效，显示静态三个点。

状态矩阵：

| 状态 | UI |
| --- | --- |
| 发送后，未收到输出 | 三个灰色圆点思考气泡 |
| 收到 assistant 正文 | 思考气泡消失，显示正文 |
| 收到 reasoning 正文 | 思考气泡消失，显示 reasoning |
| 请求失败 | 思考气泡消失，显示错误 |
| 请求完成 | 思考气泡消失 |
| 队列发送下一条 | 下一条重新进入思考态 |

### 阶段 6：正式降 target

最后修改：

- `IPHONEOS_DEPLOYMENT_TARGET = 16.0`

构建验证：

- iOS 16 simulator build。
- iOS 17 simulator build。
- iOS 18 simulator build。
- 当前 SDK build。

## 手工验收矩阵

### 页面

- Chat 主界面。
- Sidebar。
- Settings。
- 输入栏。
- 附件浮层。
- 思考动画。
- 输出正文。
- reasoning 输出。

### 设备

- iPhone 320/375 宽度。
- 大屏 iPhone。
- iPad。
- 横屏。

### 状态

- 空会话。
- 发送中。
- 流式输出中。
- 错误。
- 断线。
- 重连。
- 键盘打开。
- 键盘关闭。
- 图片权限弹窗。
- 文件选择取消。

## 审计结果

方案当前无阻塞项。风险主要集中在：

- iOS 16.0-16.3 sheet 外框圆角无法完全由 SwiftUI 官方 API 控制。
- 系统 `Menu` 的弹出位置跨版本不保证完全一致。
- SwiftUI 多行 `TextField` 在 iOS 16/17/18 的 Return 与高度行为可能存在细微差异。
- `glassEffect` 不应作为主视觉，否则 iOS 26 与 iOS 16/17/18 会出现视觉漂移。

建议后续按阶段实施，不一次性大改所有 UI。
