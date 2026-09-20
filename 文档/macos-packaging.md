# macOS 打包与签名说明

## 当前分发策略

- 交付物：`acode.app` + 按架构分发的 DMG
- 发布产物命名：`acode-macos-arm64.dmg`（Apple Silicon）、`acode-macos-x64.dmg`（Intel）
- 构建配置：`Release`
- 架构模式：`ARCH_MODE=arm64` 或 `ARCH_MODE=x86_64`（也支持 `universal`，但发布产物按架构分包）
- 签名身份：`$CODEVOKE_SIGNING_AUTHORITY`（环境变量传入，如 `Developer ID Application: Name (TEAMID)`）
- Team ID：`$CODEVOKE_TEAM_ID`（同时作为 `DEVELOPMENT_TEAM` 传给 xcodebuild，工程内不硬编码）
- 公证：已接入 `notarytool` + `stapler` 流程，详见 `文档/macos-notarization.md`。

## 标准打包命令

```bash
# Apple Silicon
CODEVOKE_SIGNING_AUTHORITY="Developer ID Application: <Name> (<TEAMID>)" \
CODEVOKE_TEAM_ID=<TEAMID> \
ARCH_MODE=arm64 \
DESTINATION="$PWD/build/out-arm64/acode.app" \
DMG_PATH="$PWD/build/releases/acode-macos-arm64.dmg" \
脚本/package-macos-app.sh

# Intel
CODEVOKE_SIGNING_AUTHORITY="Developer ID Application: <Name> (<TEAMID>)" \
CODEVOKE_TEAM_ID=<TEAMID> \
ARCH_MODE=x86_64 \
DESTINATION="$PWD/build/out-x64/acode.app" \
DMG_PATH="$PWD/build/releases/acode-macos-x64.dmg" \
脚本/package-macos-app.sh
```

脚本会：

1. 检查本机是否存在 `<Developer ID Application identity>` 证书。
2. 使用 `Mac版本/Codevoke.xcodeproj` / `Codevoke` scheme 按 `ARCH_MODE` 构建 Release（`DEVELOPMENT_TEAM` 由 `CODEVOKE_TEAM_ID` 传入）。
3. 校验构建产物主程序和内嵌 framework 的目标架构。
4. 校验构建产物的 `codesign` 签名和 `TeamIdentifier=<TEAM_ID>`。
5. 拷贝产物到 `DESTINATION` 指定的 `.app` 路径（会覆盖同路径旧文件，勿指向在用的 App）。
6. 再次校验输出产物架构和签名。
7. 生成并签名指定的 DMG。
8. 正式发布前按 `文档/macos-notarization.md` 提交 Apple 公证并 staple 票据（`NOTARIZE=1`）。

## 验证口径

必须通过：

- `xcodebuild` Release build 成功。
- `lipo -archs acode.app/Contents/MacOS/acode` 与 `ARCH_MODE` 一致（arm64 包只有 `arm64`，x64 包只有 `x86_64`）。
- `codesign --verify --deep --strict` 通过。
- `codesign -dv --verbose=4` 里出现：
  - `Authority=<Developer ID Application identity>`
  - `TeamIdentifier=<TEAM_ID>`

正式发布必须通过：

- `xcrun notarytool submit <dmg> --keychain-profile "codevoke-notary" --wait` 返回 `Accepted`。
- `xcrun stapler validate <dmg>` 通过。
- `spctl -a -vv -t open --context context:primary-signature <dmg>` 返回 `accepted / Notarized Developer ID`。

## Windows 分架构打包

在 `Windows版本/` 下（macOS 上也可交叉构建 NSIS）：

```bash
npm run build && npx electron-builder --win nsis portable --x64 --arm64
```

产物：`acode-Setup-<ver>-x64.exe`、`acode-Setup-<ver>-arm64.exe`、`acode-Setup-<ver>.exe`（双架构合一，auto-update 默认 `path`）、对应 `.blockmap`、`latest.yml`（electron-updater 索引，发版时必须随包上传）、`acode-Portable-<ver>-*.exe`。

## 后续正式发布补项

正式对外分发前仍需确认：

- Gatekeeper 首启验证。
- 可回滚的历史版本归档。
- 下载入口或自动更新源的一致性校验。
