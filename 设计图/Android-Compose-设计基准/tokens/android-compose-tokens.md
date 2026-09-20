# Android Compose Tokens

已写入 `安卓版本/app/src/main/java/com/codevoke/android/ui/theme`。

## Color

- `Ink`: `#141414`
- `Muted`: `#6B6B6B`
- `Hairline`: black 5.5%
- `Line`: black 8%
- `Soft`: `#F5F5F2`
- `GlassFill`: white 52%
- `GlassPanel`: white 72%
- `GlassStroke`: white 74%
- `Green`: `#5CCB63`

## Radius

- `Small`: 14dp
- `Field`: 16dp
- `Bubble`: 22dp
- `Control`: 24dp
- `Chrome`: 28dp
- `Sheet`: 30dp

## Components

- `CodevokeGlassCard`: 白色实体玻璃卡片，1dp 黑色 8% 边线，轻阴影。
- `CodevokeSoftGlass`: 半透明控件底，用于输入框、圆形按钮。
- `CodevokeIconButton`: 40-48dp 圆形玻璃按钮，按下缩放到 0.94。
- `BlackCapsuleButton`: 黑色主操作按钮。
- `SettingsRow`: 设置/列表菜单行，图标 31dp，标题 15sp semibold，副标题 12sp。

## Compose 注意

- 不在 Composable 正文发网络/IO。
- 页面先用静态状态还原视觉，再接 ViewModel/Repository/WebSocket。
- 后续接入真实远程能力时，网络、WebSocket、后台任务必须进入 Android 原生层。
