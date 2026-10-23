#!/bin/bash
# ビルドして ~/Applications/WindowCapture.app にインストールし、起動し直す。
#
# 画面収録・アクセシビリティの許可は「バンドル ID + 署名の designated requirement」に紐づく。
# 毎回同じ場所・同じ証明書で署名すれば、ビルドし直しても一度の許可が有効なまま残る。
# そのため次を守る:
#   - インストール先は常に 1 か所 (INSTALL_DIR)。同じバンドル ID のコピーを他に置かない
#   - 署名は固定の証明書だけ。アドホック署名 (ビルドごとに要件が変わり、許可が外れる) にはしない
#   - designated requirement が前回から変わったら警告する
#
# 使い方:
#   scripts/build-app.sh               ビルド → インストール → 起動
#   scripts/build-app.sh --no-launch   起動しない
# 環境変数:
#   CODESIGN_IDENTITY  署名に使う証明書 (名前または SHA-1)。省略時は Apple Development 証明書を自動選択
#   INSTALL_DIR        インストール先 (既定: ~/Applications)
#   CONFIG             debug / release (既定: release)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="WindowCapture"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Support/Info.plist)"
CONFIG="${CONFIG:-release}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
STAGING_APP=".build/app/$APP_NAME.app"
REQUIREMENT_FILE=".build/app/designated-requirement.txt"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

launch=true
for arg in "$@"; do
  case "$arg" in
    --no-launch) launch=false ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# --- 署名に使う証明書を決める (アドホック署名は許可が毎回外れるので使わない) ---
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  IDENTITY="$CODESIGN_IDENTITY"
else
  identities="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2 }' | sort -u)"
  count="$(printf '%s' "$identities" | grep -c . || true)"
  if [ "$count" -eq 0 ]; then
    echo "error: Apple Development 証明書が見つかりません。Xcode の Settings > Accounts で作成するか、CODESIGN_IDENTITY を指定してください。" >&2
    exit 1
  elif [ "$count" -gt 1 ]; then
    echo "error: Apple Development 証明書が複数あります。どれを使うか CODESIGN_IDENTITY で固定してください:" >&2
    printf '  %s\n' "$identities" >&2
    exit 1
  fi
  IDENTITY="$identities"
fi
if [ "$IDENTITY" = "-" ]; then
  echo "error: アドホック署名ではビルドのたびに権限の再許可が必要になるため使えません。" >&2
  exit 1
fi

# --- ビルドしてステージング用のバンドルを組み立てる ---
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$STAGING_APP"
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$STAGING_APP/Contents/MacOS/$APP_NAME"
cp Support/Info.plist "$STAGING_APP/Contents/Info.plist"
cp Support/Icon/AppIcon.icns "$STAGING_APP/Contents/Resources/AppIcon.icns"
codesign --force --options runtime --sign "$IDENTITY" "$STAGING_APP"

# --- 権限の紐づき先 (designated requirement) が前回から変わっていないか確認する ---
requirement="$(codesign -d -r- "$STAGING_APP" 2>&1 | sed -n 's/^designated => //p')"
if [ -f "$REQUIREMENT_FILE" ] && [ "$(cat "$REQUIREMENT_FILE")" != "$requirement" ]; then
  echo "warning: 署名の要件が前回から変わりました。画面収録・アクセシビリティの再許可が必要になります。" >&2
  echo "  前回: $(cat "$REQUIREMENT_FILE")" >&2
  echo "  今回: $requirement" >&2
fi
printf '%s' "$requirement" > "$REQUIREMENT_FILE"

# --- 動いているアプリを終了してから、固定の場所へ上書きインストールする ---
if pgrep -xq "$APP_NAME"; then
  pkill -TERM -x "$APP_NAME" || true
  for _ in $(seq 1 50); do pgrep -xq "$APP_NAME" || break; sleep 0.1; done
  pkill -KILL -x "$APP_NAME" 2>/dev/null || true
fi
mkdir -p "$INSTALLED_APP"
rsync -a --delete "$STAGING_APP/" "$INSTALLED_APP/"

# 古い場所 (以前の build/) やステージングのコピーを Launch Services から外し、同じバンドル ID が 1 か所だけになるようにする
"$LSREGISTER" -u "$STAGING_APP" >/dev/null 2>&1 || true
if [ -d "build/$APP_NAME.app" ]; then
  "$LSREGISTER" -u "build/$APP_NAME.app" >/dev/null 2>&1 || true
  rm -rf "build/$APP_NAME.app"
fi
"$LSREGISTER" -f "$INSTALLED_APP"

echo "installed: $INSTALLED_APP"
echo "signed by: $IDENTITY"

if $launch; then
  open "$INSTALLED_APP"
fi
