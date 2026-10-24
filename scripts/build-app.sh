#!/usr/bin/env bash
# Builds QuickInstall.app as a universal binary (Apple Silicon + Intel).
#
#   ./scripts/build-app.sh            -> build/QuickInstall.app
#   ./scripts/build-app.sh --install  -> additionally copies it to /Applications
#
# Environment:
#   ARCHS="arm64"          build only for Apple Silicon (default: "arm64 x86_64")
#   SIGN_IDENTITY="..."    codesign identity (default: "-" = ad-hoc signature)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="QuickInstall"
ARCHS="${ARCHS:-arm64 x86_64}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/${APP_NAME}.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

binaries=()
for arch in $ARCHS; do
    echo "==> swift build (${arch})"
    swift build -c release --arch "$arch"
    bin_dir="$(swift build -c release --arch "$arch" --show-bin-path)"
    binaries+=("${bin_dir}/${APP_NAME}")
done

echo "==> Erzeuge ${APP}"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
lipo -create "${binaries[@]}" -output "${APP}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

echo "==> Signiere (${SIGN_IDENTITY})"
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"

lipo -info "${APP}/Contents/MacOS/${APP_NAME}"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installiere nach /Applications"
    rm -rf "/Applications/${APP_NAME}.app"
    ditto "$APP" "/Applications/${APP_NAME}.app"
    "$LSREGISTER" -f "/Applications/${APP_NAME}.app"
    echo "Fertig: /Applications/${APP_NAME}.app"
else
    "$LSREGISTER" -f "$APP" || true
    echo "Fertig: ${APP}"
fi
