# Android Compose 设计基准

用途：这个目录用于 Android 原生 Kotlin + Compose 还原 iOS acode 的视觉和交互，不作为方案文档。Android 端稳定设计规范沉淀在 `安卓版本/DESIGN.md`。

## 截图

- `screenshots/01-chat-sidebar-overlay.png`：聊天页 + 左侧项目/模型/会话/文件抽屉。
- `screenshots/03-chat-thread.png`：聊天消息流。

## 已落地到 Android 的页面

- 聊天主屏：顶部玻璃栏、消息列表、黑色用户气泡、底部输入栏、左侧抽屉。
- 远程设备页：标题栏、局域网自动扫描、设备卡片、手动输入 IP:端口 卡片。
- 设置页：三组玻璃卡片、菜单行、图标、分隔线。

## iOS 证据

- 色彩、玻璃、圆角、阴影：`iOS版本/Codevoke/Views/VisualStyle.swift`
- 聊天顶部栏、消息列表、空态、底部输入栏：`iOS版本/Codevoke/Views/ChatView.swift`
- 输入框、附件按钮、发送按钮：`iOS版本/Codevoke/Views/InputBarView.swift`
- 左侧抽屉：`iOS版本/Codevoke/Views/SidebarView.swift`
- 侧栏遮罩、宽度、边缘手势：`iOS版本/Codevoke/Views/RootView.swift`
- 远程设备：`iOS版本/Codevoke/Views/DeviceListView.swift`
- 设置页：`iOS版本/Codevoke/Views/SettingsView.swift`

## 还原硬规则

- 主色只用黑白灰，成功态用绿色点。
- 页面背景是浅白玻璃感，不做彩色渐变。
- 大卡片圆角 28-30dp，输入/列表行圆角 18-22dp，52dp 圆形按钮使用 26dp。
- 图标按钮固定 44-52dp，圆形玻璃底。
- 主操作用黑色胶囊按钮。
- 文本层级：标题粗黑，说明灰色，消息正文保持高可读。
- 抽屉宽度按 iOS：`min(max(width * 0.70, 272dp), 312dp)`，背后黑色遮罩 24%。
- 按压反馈按 iOS：scale 0.94、opacity 0.82、duration 160ms。

## Compose Token 落点

- 颜色：`安卓版本/app/src/main/java/com/codevoke/android/ui/theme/CodevokeTheme.kt` 的 `CodevokeColor`。
- 圆角/间距/尺寸/字号/透明度/阴影/动效：`安卓版本/app/src/main/java/com/codevoke/android/ui/theme/CodevokeTokens.kt`。
- 背景、玻璃卡片、圆形按钮：`安卓版本/app/src/main/java/com/codevoke/android/ui/components/CodevokeSurfaces.kt`。
- 设置行、主按钮、状态点、分段控件：`安卓版本/app/src/main/java/com/codevoke/android/ui/components/CodevokeRows.kt`。

## iOS -> Android Token 对照

- `Color.codevokeInk` -> `CodevokeColor.Ink`：`#141414`。
- `Color.codevokeMuted` -> `CodevokeColor.Muted`：`#6B6B6B`。
- `Color.codevokeGlassFill` -> `CodevokeColor.GlassFill`：white 52%。
- `Color.codevokeGlassStroke` -> `CodevokeColor.GlassStroke`：white 74%。
- `codevokeGlass(cornerRadius: 28)` -> `CodevokeGlassCard(corner = CodevokeRadius.Chrome)`。
- `.buttonStyle(.codevokePress)` -> `CodevokeMotion.PressScale` / `CodevokeAlpha.PressedOpacity` / `CodevokeMotion.PressMillis`。

## 后续页面实现要求

- 写 screen 前先读 `安卓版本/DESIGN.md`。
- screen 里不要继续散写全局 magic number；优先用 `CodevokeColor`、`CodevokeRadius`、`CodevokeSpace`、`CodevokeSize`、`CodevokeType`、`CodevokeAlpha`。
- 新增公共视觉值必须先沉淀到 token，再在组件或 screen 使用。
- 截图负责视觉位置感，iOS 源码负责精确透明度、圆角、字号和交互值。
