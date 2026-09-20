# acode 项目工作区规则

> 给 AI 看的操作手册。白话写的，照着做就行，别自由发挥。

## 这个项目是什么

- `acode`：手机 AI 编程工作台。电脑跑 CLI，手机当远程终端。
- 个人免费，禁止商用（PolyForm Noncommercial 1.0.0）。
- 仓库：`https://github.com/crispvibe/Acode-Desktop`，只保留 `main` 一个分支。

## 目录分工（改东西别越界）

| 目录 | 是什么 |
|---|---|
| `Mac版本/` | macOS 桌面端，同时是远程 host（SwiftUI） |
| `Windows版本/` | Windows 桌面端，同是 host（Electron+React） |
| `iOS版本/` | iOS 远程客户端（SwiftUI） |
| `安卓版本/` | Android 远程客户端（Kotlin Compose） |
| `共享代码/ChatCore` | Swift 共享 DTO/协议代码 |
| `文档/` | 所有文档 |
| `脚本/` | 打包等脚本 |

跨平台改动要四端同步，线上 `cli` 值必须四端一致。当前支持 10 家 CLI：`claude/codex/cursor/gemini/qwen/copilot/kimi/agy/kiro/dsh`。

## 验证命令（改完必须跑对应平台的）

- macOS：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Mac版本/Codevoke.xcodeproj -scheme Codevoke -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- iOS：同上，工程换 `iOS版本/Codevoke.xcodeproj`，destination 换 `'generic/platform=iOS'`
- Windows：`cd Windows版本 && npm run typecheck && npm run test`
- Android：`cd 安卓版本 && JAVA_HOME=/opt/homebrew/opt/openjdk@21 ANDROID_HOME=/Users/oreo/.yingshi-toolchain/android-sdk ./gradlew :app:assembleDebug`

## 发版打包（重点，别记错）

### 1. 先升版本号，四端对齐

- `Mac版本/Codevoke.xcodeproj/project.pbxproj`：`MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`（整数+1）
- `iOS版本/Codevoke.xcodeproj/project.pbxproj`：同上
- `安卓版本/app/build.gradle.kts`：`versionName` + `versionCode`（整数+1）
- `Windows版本/package.json`：`"version"`

**版本号不齐的话自动更新永远判不了新版，必须四端同步。**

### 2. 要打这几个包（产物放 `build/release-<版本号>/`）

| 文件 | 怎么打 |
|---|---|
| `acode-macos-arm64.dmg` | `CODEVOKE_SIGNING_AUTHORITY="Developer ID Application: Zhang XueFeng (XY6Z92AMPS)" CODEVOKE_TEAM_ID=XY6Z92AMPS ARCH_MODE=arm64 DESTINATION="$PWD/build/out-arm64/acode.app" DMG_PATH="$PWD/build/release-X/acode-macos-arm64.dmg" NOTARIZE=0 bash 脚本/package-macos-app.sh`（前面要加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`） |
| `acode-macos-x64.dmg` | 同上，`ARCH_MODE=x86_64`、路径里 arm64 全换 x64 |
| Windows 6 个 exe + `latest.yml` + 3 个 `.blockmap` | `cd Windows版本 && npx electron-builder --win nsis portable --x64 --arm64`，产物在 `release/` 里，把 `acode-*-X.Y.Z*` 和 `latest.yml` 拷过来 |
| `acode-android-debug.apk` | 跑上面的 Android 构建命令，产物在 `app/build/outputs/apk/debug/app-debug.apk`，改名拷贝 |
| `acode-ios-unsigned.ipa` | iOS Release build 后：`mkdir Payload && cp -R <Release-iphoneos>/acode.app Payload/ && zip -qr acode-ios-unsigned.ipa Payload` |

macOS 包是 Developer ID 签名但未公证，用户右键打开即可，这是已知状态不用修。

### 3. 发 GitHub Release

- tag 用 `v<版本号>`，`git tag -a vX.Y.Z` 后 `git push origin main vX.Y.Z`
- GitHub token 在 `~/.config/github/token`（也是 env `GITHUB_TOKEN`），curl REST API 建 release + 传 asset
- **`latest.yml` 和 3 个 `.blockmap` 必须传**，不传 Windows 自动更新就废了
- Release 说明里写清各平台下哪个包

### 4. 传完必须删本地产物（这条别忘）

`build/` 目录（DerivedData、release-X.Y.Z、dd-ios、out-arm64、out-x64）和 `Windows版本/release/` 都是本地临时产物，**确认 GitHub 上全部 asset `uploaded` 后删掉**。已进 `.gitignore`，别提交。

```bash
rm -rf build/ Windows版本/release/
```

### 5. 收尾

- `CHANGELOG.md` 把「未发布」段落改成 `## X.Y.Z` + 日期
- README 里的下载链接用 `releases/latest/download/<文件名>` 固定名，不用改；带版本号的 Windows 包链 `releases/latest` 页面

## 其他规矩

- 协议字段（snapshot/patch/command/command_ack）不能改含义，两端共用
- 密匙/token 永不进仓库
- 全局规则提示词要支持全部 10 家 CLI，各家指令文件路径写在 `文档/` 和两端 settings 里，别只写 Claude/Codex
