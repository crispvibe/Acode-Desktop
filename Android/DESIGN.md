# Codevoke Android Design System

本文件是 Android Kotlin + Compose 端的设计系统基准。后续写页面前先读这里，再读 `ui/theme` 与 `ui/components`，不要在 screen 里重新发明颜色、圆角、字号、阴影和按压反馈。

## 证据来源

- iOS 设计 Token：`/Users/oreo/Desktop/Codevoke/CodevokeIOS/Codevoke/Views/VisualStyle.swift`
- iOS 登录/注册组件：`/Users/oreo/Desktop/Codevoke/CodevokeIOS/Codevoke/Views/Auth/AuthComponents.swift`
- iOS 聊天顶部栏与输入栏：`/Users/oreo/Desktop/Codevoke/CodevokeIOS/Codevoke/Views/ChatView.swift`、`/Users/oreo/Desktop/Codevoke/CodevokeIOS/Codevoke/Views/InputBarView.swift`
- iOS 侧栏：`/Users/oreo/Desktop/Codevoke/CodevokeIOS/Codevoke/Views/RootView.swift`、`/Users/oreo/Desktop/Codevoke/CodevokeIOS/Codevoke/Views/SidebarView.swift`
- iOS 远程设备与设置：`/Users/oreo/Desktop/Codevoke/CodevokeIOS/Codevoke/Views/DeviceListView.swift`、`/Users/oreo/Desktop/Codevoke/CodevokeIOS/Codevoke/Views/SettingsView.swift`
- 截图基准：`/Users/oreo/Desktop/Codevoke/设计图/Android-Compose-设计基准/screenshots`
- Android 当前落点：`/Users/oreo/Desktop/Codevoke/Android/app/src/main/java/com/codevoke/android/ui/theme`、`/Users/oreo/Desktop/Codevoke/Android/app/src/main/java/com/codevoke/android/ui/components`

## 产品气质

Codevoke Android 不是 Material 默认工具页，也不是营销页。它要还原 iOS 端的轻玻璃、浅色、低饱和、黑白灰、高留白和胶囊操作气质。

执行规则：
- 第一屏必须直接是可用工具界面，不做介绍型 landing。
- 主色只允许黑、白、灰；成功状态允许绿色点。
- 页面背景保持白色玻璃感，禁止彩色渐变、彩色装饰光斑、大面积品牌色。
- 控件层级靠透明度、阴影、圆角和留白建立，不靠强色块堆叠。

## 颜色

Compose 颜色入口是 `CodevokeColor`。

- `Ink`: `#141414`，等价 iOS `Color(red: 0.08, green: 0.08, blue: 0.08)`。
- `Muted`: `#6B6B6B`，等价 iOS `Color(red: 0.42, green: 0.42, blue: 0.42)`。
- `Soft`: `#F5F5F2`，用于图标底和轻背景。
- `GlassFill`: white 52%，用于圆形按钮、输入栏等轻玻璃控件。
- `GlassPanel`: white 72%，用于模型弹层、浮层、较亮玻璃面。
- `GlassCardFill`: white 82%，用于主卡片。
- `AuthGlassFill`: white 68%，用于登录/注册表单卡片和输入框。
- `Hairline`: black 5.5%，用于顶部栏细描边。
- `Line`: black 8%，用于设置分隔线。
- `GlassCardHairline`: black 4.5%，用于白卡片外层弱描边。
- `Scrim`: black 24%，用于侧栏打开后的遮罩。
- `Green`: `#5CCB63`，用于在线状态点。

禁止项：
- 禁止在 screen 中直接写 `Color(0x...)` 表达全局色。
- 禁止把灰色说明文字换成低对比浅灰导致不可读。
- 禁止新增蓝、紫、橙等功能色，除非有明确错误/危险状态。

## 背景与玻璃

背景统一使用 `WhiteGlassBackground`：
- 线性渐变：white -> `#FDFDFC` -> `#F9F9F8`。
- 左上角叠加 240dp 白色柔光，offset `x=-70dp, y=-80dp`，blur 34dp。

卡片统一使用 `CodevokeGlassCard`：
- 默认圆角 28dp。
- 填充 white 82%。
- 双描边：white 82% + black 4.5%。
- 阴影：black 6%，radius 18dp。

控件玻璃统一使用 `CodevokeSoftGlass`：
- 默认圆角 24dp。
- 默认填充 white 52%。
- 描边 white 74%。
- 阴影：black 8%，radius 18dp。

## 圆角

Compose 圆角入口是 `CodevokeRadius`。

- `Tile`: 14dp，附件缩略图、轻图标底。
- `Field`: 16dp，普通字段和小卡片。
- `Row`: 18dp，未选中列表行、输入框。
- `RowSelected`: 20dp，选中侧栏行。
- `Bubble`: 22dp，消息气泡和浮层局部。
- `Control`: 24dp，分段控件和普通胶囊。
- `CircleControl`: 26dp，52dp 圆形按钮和主按钮胶囊。
- `Chrome`: 28dp，顶部栏、主卡片、sheet。
- `Sheet`: 30dp，大型面板、侧栏、认证卡。

禁止项：
- 不要随手写 17dp、19dp、23dp 这类无证据圆角。
- 卡片内部不要再套一层完整卡片，避免“卡片套卡片”。

## 字号与字重

Compose 字号入口是 `CodevokeType`。

- `Hero`: 28sp，登录页标题、远程设备大标题。
- `NavTitle` / `Title`: 17sp，顶部标题、区块标题。
- `Body`: 15sp，输入框、主按钮、设置行标题。
- `BodySmall`: 14sp，聊天正文、侧栏行标题。
- `Label`: 13sp，菜单项和小按钮。
- `Caption`: 12sp，设置副标题、协议说明。
- `CaptionSmall`: 11sp，状态说明、文件副标题。
- `SidebarSubtitle`: 11.5sp，侧栏副标题。

字重：
- 主标题用 Bold 或 SemiBold。
- 正文默认 Medium/Regular，避免整页过粗。
- 主按钮使用 SemiBold。

禁止项：
- 不使用 viewport 动态缩放字号。
- 不使用负字距。
- 小面板里的标题不能用 hero 级字号。

## 间距与尺寸

Compose 间距入口是 `CodevokeSpace`，固定尺寸入口是 `CodevokeSize`。

- 页面水平边距：16dp，登录/远程设备可用 18dp。
- 页面顶部节奏：22dp。
- 区块间距：16dp，侧栏区块 18dp。
- 设置行内边距：14dp x 13dp。
- 侧栏行内边距：10dp x 10dp。
- 圆形工具按钮：44dp 或 48dp；聊天输入区按钮使用 52dp。
- 主按钮高度：52dp。
- 状态点：7dp 或 8dp。
- 设置图标：31dp。

禁止项：
- 图标按钮不能跟随文字撑开尺寸。
- 状态点、toolbar、输入栏按钮这类固定格式元素必须使用稳定尺寸。

## 组件

公共组件优先级：
1. `WhiteGlassBackground`
2. `CodevokeGlassCard`
3. `CodevokeSoftGlass`
4. `CodevokeIconButton`
5. `SettingsRow`
6. `BlackCapsuleButton`
7. `StatusDot`
8. `SelectionPill`

主按钮：
- 黑色胶囊。
- 高度 52dp。
- 圆角 26dp。
- disabled 背景 black 55%，文字 white 72%。

设置/菜单行：
- 图标 31dp，黑色 58%。
- 标题 15sp SemiBold。
- 副标题 12sp Muted。
- chevron 20dp，Muted 55%。
- 分隔线从 57dp 开始，black 8%。

侧栏：
- 宽度按 iOS：`min(max(width * 0.70, 272dp), 312dp)`。
- 左边距 10dp。
- 遮罩 black 24%。
- 边缘热区 32dp。
- 面板圆角 30dp。
- section 标题 12sp SemiBold Muted。
- 选中行黑底白字，未选中行 white 42%。

输入栏：
- 附件按钮、输入框、发送按钮都使用 52dp 视觉高度。
- 输入框圆角 26dp，white 52%，white 72% 描边，阴影 black 8%。
- 附件菜单：white 72%，圆角 22dp，阴影 black 12%。

认证页：
- Logo 66dp，圆角 18dp。
- 标题 28sp SemiBold rounded-like。
- 表单卡圆角 30dp，white 68%，描边 white 88%，阴影 black 6% radius 22dp。
- 输入框标题 12sp Medium，输入文字 15sp Medium。
- 输入框内边距 14dp x 13dp，圆角 18dp。

## 交互反馈

Compose 交互入口是 `CodevokeMotion` 与 `CodevokeAlpha`。

- 按压缩放：0.94。
- 按压时透明度：0.82。
- 按压动画：160ms。
- 小弹层动画：180ms。
- 键盘/输入栏动画：220ms。

所有可点击玻璃按钮必须有明确 disabled 态。禁用态不要完全隐藏，用 alpha 降低但保留布局稳定。

## 截图基准

当前截图均为 1290 x 2796：

- `01-chat-sidebar-overlay.png`：聊天页 + 左侧抽屉。
- `02-remote-device-list.png`：远程设备页。
- `03-chat-thread.png`：聊天消息流。
- `04-chat-thread-duplicate-reference.png`：聊天消息流补充参考。
- `05-login.png`：登录页。
- `06-register.png`：创建账号页。

实现页面时必须先对照对应截图，再读 iOS 源码确认细节。截图负责视觉位置感，源码负责精确 token。

## Android 编码规则

- screen 中优先消费 `CodevokeColor`、`CodevokeRadius`、`CodevokeSpace`、`CodevokeSize`、`CodevokeType`、`CodevokeAlpha`、`CodevokeShadow`、`CodevokeMotion`。
- 新增公共视觉值必须先放进 token，再在组件或 screen 使用。
- 组件里可以有局部参数默认值，但默认值必须来自 token。
- 不要为了还原 iOS 在 Composable 中做网络、文件、WebSocket 或其他 IO。
- 深色模式暂未建立证据，当前以浅色 iOS 设计为准；后续补深色必须单独沉淀。

## 待补证据

- Android 真机截图还未纳入本文档，当前规范基于 iOS 源码、iOS 截图和 Android 当前组件。
- 暗色模式暂无 iOS 设计图证据，不能擅自生成一套暗色主题。
- 横屏、平板、多窗口布局暂无截图证据，暂不写成全局规则。
