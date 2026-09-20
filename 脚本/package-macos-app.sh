#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/build/DerivedData"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-acode}"
DESTINATION="${DESTINATION:-$HOME/Desktop/$APP_NAME.app}"
ARCH_MODE="${ARCH_MODE:-universal}"
CREATE_DMG="${CREATE_DMG:-1}"
DMG_PATH="${DMG_PATH:-$ROOT/build/releases/acode-macos.dmg}"
STRIP_SYMBOLS="${STRIP_SYMBOLS:-1}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-codevoke-notary}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-30m}"
ENTITLEMENTS="$ROOT/Mac版本/Codevoke/Codevoke.entitlements"
SIGNING_AUTHORITY="${CODEVOKE_SIGNING_AUTHORITY:?set CODEVOKE_SIGNING_AUTHORITY to your signing identity, e.g. 'Developer ID Application: Your Name (TEAMID)'}"
TEAM_ID="${CODEVOKE_TEAM_ID:?set CODEVOKE_TEAM_ID to your Apple team ID}"

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

case "$DESTINATION" in
  /*.app) ;;
  *) die "DESTINATION must be an absolute .app path, got: $DESTINATION" ;;
esac

require_cmd xcodebuild
require_cmd security
require_cmd codesign
require_cmd ditto
require_cmd lipo
require_cmd strip
require_cmd spctl
require_cmd hdiutil

case "$ARCH_MODE" in
  universal)
    ARCHS_VALUE="arm64 x86_64"
    REQUIRED_ARCHS=("arm64" "x86_64")
    ;;
  intel|x86_64)
    ARCHS_VALUE="x86_64"
    REQUIRED_ARCHS=("x86_64")
    ;;
  apple-silicon|arm64)
    ARCHS_VALUE="arm64"
    REQUIRED_ARCHS=("arm64")
    ;;
  *)
    die "ARCH_MODE must be universal, intel, x86_64, apple-silicon, or arm64; got: $ARCH_MODE"
    ;;
esac

verify_archs() {
  local binary="$1"
  local label="$2"
  local archs
  archs="$(lipo -archs "$binary" 2>/dev/null)" || die "unable to inspect architecture for $label: $binary"
  log "$label architectures: $archs"
  for required in "${REQUIRED_ARCHS[@]}"; do
    case " $archs " in
      *" $required "*) ;;
      *) die "$label missing required architecture $required (found: $archs)" ;;
    esac
  done
}

verify_bundle_archs() {
  local app_path="$1"
  local main_binary="$app_path/Contents/MacOS/$APP_NAME"
  [[ -f "$main_binary" ]] || die "main executable missing: $main_binary"
  verify_archs "$main_binary" "$APP_NAME main executable"

  while IFS= read -r -d '' executable; do
    if file "$executable" | grep -Fq "Mach-O"; then
      verify_archs "$executable" "embedded executable ${executable#$app_path/}"
    fi
  done < <(find "$app_path/Contents/Frameworks" -type f -perm -111 -print0 2>/dev/null || true)
}

strip_release_symbols() {
  local app_path="$1"
  local main_binary="$app_path/Contents/MacOS/$APP_NAME"

  [[ "$STRIP_SYMBOLS" == "1" ]] || {
    log "skipping symbol stripping because STRIP_SYMBOLS=$STRIP_SYMBOLS"
    return
  }

  log "stripping release symbols from main executable"
  strip -u -r "$main_binary"

  while IFS= read -r -d '' executable; do
    if file "$executable" | grep -Fq "Mach-O"; then
      log "stripping local symbols from embedded executable ${executable#$app_path/}"
      strip -x "$executable"
    fi
  done < <(find "$app_path/Contents/Frameworks" -type f -perm -111 -print0 2>/dev/null || true)
}

sign_for_notarization() {
  local app_path="$1"
  [[ -f "$ENTITLEMENTS" ]] || die "entitlements file missing: $ENTITLEMENTS"

  while IFS= read -r -d '' framework; do
    log "signing embedded framework with secure timestamp: ${framework#$app_path/}"
    codesign --force --sign "$SIGNING_AUTHORITY" --timestamp --options runtime "$framework"
  done < <(find "$app_path/Contents/Frameworks" -type d -name '*.framework' -prune -print0 2>/dev/null || true)

  log "signing app bundle with secure timestamp"
  codesign --force --sign "$SIGNING_AUTHORITY" --timestamp --options runtime --entitlements "$ENTITLEMENTS" "$app_path"
}

verify_no_debug_entitlements() {
  local app_path="$1"
  local entitlements
  entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null || true)"
  if printf '%s\n' "$entitlements" | grep -Fq "com.apple.security.get-task-allow"; then
    die "release app still has get-task-allow entitlement"
  fi
}

cd "$ROOT"

log "checking local signing identity"
if ! security find-identity -v -p codesigning | grep -Fq "$SIGNING_AUTHORITY"; then
  die "signing identity not found: $SIGNING_AUTHORITY"
fi

log "building $CONFIGURATION with Developer ID signing ($ARCH_MODE: $ARCHS_VALUE)"
xcodebuild \
  -project "Mac版本/Codevoke.xcodeproj" \
  -scheme Codevoke \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="$ARCHS_VALUE" \
  ONLY_ACTIVE_ARCH=NO \
  ENABLE_CODE_COVERAGE=NO \
  CLANG_COVERAGE_MAPPING=NO \
  build

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || die "build product missing: $APP_PATH"

log "verifying build product architectures"
verify_bundle_archs "$APP_PATH"

strip_release_symbols "$APP_PATH"

log "applying notarization-ready signatures"
sign_for_notarization "$APP_PATH"

log "verifying build product signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
verify_no_debug_entitlements "$APP_PATH"
SIGNATURE_INFO="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
printf '%s\n' "$SIGNATURE_INFO" | grep -Fq "Authority=$SIGNING_AUTHORITY" || die "unexpected signing authority"
printf '%s\n' "$SIGNATURE_INFO" | grep -Fq "TeamIdentifier=$TEAM_ID" || die "unexpected TeamIdentifier"

log "replacing desktop app: $DESTINATION"
rm -rf "$DESTINATION"
ditto "$APP_PATH" "$DESTINATION"

log "verifying desktop app architectures"
verify_bundle_archs "$DESTINATION"

log "verifying desktop app signature"
codesign --verify --deep --strict --verbose=2 "$DESTINATION"
verify_no_debug_entitlements "$DESTINATION"
codesign -dv --verbose=4 "$DESTINATION" 2>&1 | grep -E 'Authority|TeamIdentifier|Identifier|Runtime|Signature|Timestamp'

if [[ "$CREATE_DMG" == "1" ]]; then
  log "creating DMG: $DMG_PATH"
  mkdir -p "$(dirname "$DMG_PATH")"
  rm -f "$DMG_PATH"
  DMG_STAGING="$(mktemp -d "${TMPDIR:-/tmp}/acode-dmg.XXXXXX")"
  trap 'rm -rf "${DMG_STAGING:-}"' EXIT
  ditto "$DESTINATION" "$DMG_STAGING/$APP_NAME.app"
  hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"
  codesign --force --sign "$SIGNING_AUTHORITY" --timestamp "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
  hdiutil verify "$DMG_PATH"
  rm -rf "$DMG_STAGING"
  trap - EXIT

  if [[ "$NOTARIZE" == "1" ]]; then
    require_cmd xcrun
    log "submitting DMG for notarization with keychain profile: $NOTARY_PROFILE"
    xcrun notarytool submit "$DMG_PATH" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait \
      --timeout "$NOTARY_TIMEOUT"

    log "stapling notarization ticket"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"

    log "verifying Gatekeeper status for notarized DMG"
    spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"
  fi
fi

log "checking Gatekeeper status; unnotarized rejection is expected for local test builds"
if ! spctl -a -vv "$DESTINATION"; then
  true
fi

log "done: $DESTINATION"
