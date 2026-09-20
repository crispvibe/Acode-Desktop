# macOS 打包与签名说明

## 当前本地测试策略

- 交付物：`Codevoke.app`
- 默认输出：`~/Desktop/Codevoke.app`
- 默认 DMG：`build/releases/codevoke-macos.dmg`
- 构建配置：`Release`
- 默认架构：Universal（`arm64 x86_64`）
- 签名身份：`$CODEVOKE_SIGNING_AUTHORITY`（环境变量传入）
- Team ID：`$CODEVOKE_TEAM_ID`
- 公证：已接入 `notarytool` + `stapler` 流程，详见 `docs/macos-notarization.md`。

## 标准打包命令

```bash
scripts/package-macos-app.sh
```

脚本会：

1. 检查本机是否存在 `<Developer ID Application identity>` 证书。
2. 使用 `Codevoke.xcodeproj` / `Codevoke` scheme 构建 Universal Release。
3. 校验构建产物主程序和内嵌 framework 的 `arm64 x86_64` 架构。
4. 校验构建产物的 `codesign` 签名和 `TeamIdentifier=<TEAM_ID>`。
5. 替换桌面 `~/Desktop/Codevoke.app`。
6. 再次校验桌面产物架构和签名。
7. 生成并签名 `build/releases/codevoke-macos.dmg`。
8. 正式发布前按 `docs/macos-notarization.md` 提交 Apple 公证并 staple 票据。

## 验证口径

必须通过：

- `xcodebuild` Release build 成功。
- `lipo -archs Codevoke.app/Contents/MacOS/Codevoke` 同时包含 `arm64` 和 `x86_64`。
- 内嵌 Mach-O framework 至少包含 `x86_64`，默认应为 `arm64 x86_64`。
- `codesign --verify --deep --strict` 通过。
- `codesign -dv --verbose=4` 里出现：
  - `Authority=<Developer ID Application identity>`
  - `TeamIdentifier=<TEAM_ID>`

正式发布必须通过：

- `xcrun notarytool submit build/releases/codevoke-macos.dmg --keychain-profile "codevoke-notary" --wait` 返回 `Accepted`。
- `xcrun stapler validate build/releases/codevoke-macos.dmg` 通过。
- `spctl -a -vv -t open --context context:primary-signature build/releases/codevoke-macos.dmg` 返回 `accepted / Notarized Developer ID`。

## 后续正式发布补项

正式对外分发前仍需确认：

- Gatekeeper 首启验证。
- 可回滚的历史版本归档。
- 下载入口或自动更新源的一致性校验。
