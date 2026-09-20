# macOS Developer ID 公证流程

## 当前状态

- 目标产物：`build/releases/acode-macos.dmg`
- App bundle：`Codevoke.app`
- Bundle ID：`com.codevoke.mac`
- Apple ID：`99400504@qq.com`
- Team ID：`$CODEVOKE_TEAM_ID`
- Developer ID 证书：`$CODEVOKE_SIGNING_AUTHORITY`
- notarytool Keychain profile：`acode-notary`
- 默认架构：Universal（`arm64 x86_64`）
- WebRTC framework：已验证包含 `x86_64 arm64`

`acode-notary` 已通过 App 专用密码验证并保存到本机 Keychain。不要把 App 专用密码明文写入仓库、脚本或命令历史；需要更新密码时重新执行 `store-credentials` 覆盖同名 profile。

> 安全提醒：如果 App 专用密码曾经出现在仓库、聊天记录、截图或命令历史里，先到 Apple ID 后台撤销旧密码并重新生成，再用下面的 `store-credentials` 覆盖本机 Keychain profile。
## 一次性凭据配置

如果本机 Keychain 已存在 `acode-notary`，不用重复配置。缺失或密码轮换后执行：

```bash
xcrun notarytool store-credentials "acode-notary" \
  --apple-id "99400504@qq.com" \
  --team-id "$CODEVOKE_TEAM_ID"
```

命令会提示输入 App 专用密码。输入后 `notarytool` 会向 Apple 验证凭据，成功时输出：

```text
Success. Credentials validated.
Credentials saved to Keychain.
To use them, specify `--keychain-profile "acode-notary"`
```

## 标准打包

```bash
脚本/package-macos-app.sh
```

脚本会执行：

1. 检查本机 Developer ID 签名证书。
2. 使用 `Mac版本/Codevoke.xcodeproj` / `acode` scheme 构建 Release。
3. 强制 Universal 构建：`ARCHS="arm64 x86_64"`、`ONLY_ACTIVE_ARCH=NO`。
4. 用 `lipo` 校验主程序和内嵌 Mach-O framework 架构。
5. 对内嵌 `.framework` 使用 Developer ID、Hardened Runtime、secure timestamp 重签。
6. 对 `Codevoke.app` 使用 `Mac版本/Codevoke/Codevoke.entitlements`、Developer ID、Hardened Runtime、secure timestamp 重签。
7. 校验 `codesign --verify --deep --strict`、签名 Authority 和 Team ID。
8. strip 发布包符号、校验无 debug entitlement，生成并签名 `build/releases/acode-macos.dmg`。

如果要一键提交 Apple 公证并 staple 票据：

```bash
NOTARIZE=1 脚本/package-macos-app.sh
```

## 提交 Apple 公证

```bash
xcrun notarytool submit build/releases/acode-macos.dmg \
  --keychain-profile "acode-notary" \
  --wait \
  --timeout 30m
```

成功时状态应为：

```text
status: Accepted
```

如果状态是 `Invalid`，先拉日志：

```bash
xcrun notarytool log <submission-id> \
  --keychain-profile "acode-notary" \
  notarization-log.json
```

常见失败：

- `The signature does not include a secure timestamp.`  
  说明 App 或内嵌 framework 没有带 secure timestamp 重签。当前 `脚本/package-macos-app.sh` 已处理。
- `The binary is not signed with a valid Developer ID certificate.`  
  检查 `$CODEVOKE_SIGNING_AUTHORITY` 是否仍在 Keychain。
- `The executable does not have the hardened runtime enabled.`  
  检查签名命令是否包含 `--options runtime`。

## Staple 票据

公证 `Accepted` 后，把 Apple 公证票据 stapled 到 DMG：

```bash
xcrun stapler staple build/releases/acode-macos.dmg
xcrun stapler validate build/releases/acode-macos.dmg
```

成功输出应包含：

```text
The staple and validate action worked!
The validate action worked!
```

## Gatekeeper 验证

验证 DMG：

```bash
spctl -a -vv -t open --context context:primary-signature build/releases/acode-macos.dmg
```

期望：

```text
accepted
source=Notarized Developer ID
origin=<Developer ID Application identity>
```

验证 App bundle：

```bash
spctl -a -vv ~/Desktop/Codevoke.app
```

期望：

```text
accepted
source=Notarized Developer ID
origin=<Developer ID Application identity>
```

验证 DMG 文件完整性：

```bash
hdiutil verify build/releases/acode-macos.dmg
```

期望：

```text
checksum of "build/releases/acode-macos.dmg" is VALID
```

## 已跑通过的本机证据

临时测试产物：

- App：`/tmp/CodevokeIntelCheck.app`
- DMG：`/tmp/acode-macos-intel-check.dmg`

第一次提交结果：

- Submission ID：`8c7ac025-f86d-4478-a2df-d9e05ad9a519`
- 状态：`Invalid`
- 原因：主程序和 WebRTC framework 的签名缺少 secure timestamp。

修复后提交结果：

- Submission ID：`260ee028-d3d0-4059-9a19-2e31b18763c2`
- 状态：`Accepted`
- `xcrun stapler staple /tmp/acode-macos-intel-check.dmg`：通过
- `xcrun stapler validate /tmp/acode-macos-intel-check.dmg`：通过
- `spctl -a -vv /tmp/CodevokeIntelCheck.app`：`accepted / Notarized Developer ID`
- `spctl -a -vv -t open --context context:primary-signature /tmp/acode-macos-intel-check.dmg`：`accepted / Notarized Developer ID`
- `hdiutil verify /tmp/acode-macos-intel-check.dmg`：checksum valid

## 正式发布顺序

```bash
NOTARIZE=1 脚本/package-macos-app.sh
```

脚本会自动执行以下公证、staple 和 DMG 校验；如需手工排障，可单独运行：

```bash
xcrun notarytool submit build/releases/acode-macos.dmg \
  --keychain-profile "acode-notary" \
  --wait \
  --timeout 30m

xcrun stapler staple build/releases/acode-macos.dmg
xcrun stapler validate build/releases/acode-macos.dmg
spctl -a -vv -t open --context context:primary-signature build/releases/acode-macos.dmg
hdiutil verify build/releases/acode-macos.dmg
```

全部通过后，`build/releases/acode-macos.dmg` 才是可上传到 `/downloads/acode-macos.dmg` 的正式 macOS 安装包。
