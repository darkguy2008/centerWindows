#!/usr/bin/env bash
set -euo pipefail

APP_NAME="centerWindows"
BUNDLE_ID="com.comet.centerwindows"
APP_DEST="/Applications/${APP_NAME}.app"

# Match Package.swift tools version to the installed Swift toolchain
INSTALLED_TOOLS=$(swift --version 2>&1 | grep -oE 'Swift version [0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+')
CURRENT_TOOLS=$(head -1 Package.swift | grep -oE '[0-9]+\.[0-9]+')
if [[ "${INSTALLED_TOOLS}" != "${CURRENT_TOOLS}"* ]]; then
    echo "Adjusting swift-tools-version from ${CURRENT_TOOLS} to ${INSTALLED_TOOLS}"
    cp Package.swift Package.swift.bak
    sed -i '' "s/swift-tools-version: ${CURRENT_TOOLS}/swift-tools-version: ${INSTALLED_TOOLS}/" Package.swift
    trap 'mv Package.swift.bak Package.swift' EXIT
fi

echo "[1/6] Stopping running instance"
killall "${APP_NAME}" 2>/dev/null && sleep 0.5 || true

echo "[2/6] Building ${APP_NAME}.app"
scripts/build_app.sh

echo "[3/6] Installing to /Applications"
rm -rf "${APP_DEST}"
cp -R "dist/${APP_NAME}.app" "${APP_DEST}"

echo "[4/6] Code signing (ad-hoc)"
codesign --force --deep --sign - "${APP_DEST}"

echo "[5/6] Removing quarantine attribute"
xattr -cr "${APP_DEST}"

echo "[6/6] Resetting TCC permissions and launching"
tccutil reset ScreenCapture "${BUNDLE_ID}" 2>/dev/null || true
tccutil reset Accessibility "${BUNDLE_ID}" 2>/dev/null || true
open "${APP_DEST}"

echo "Installed and running: ${APP_DEST}"
echo "Note: You may need to grant Accessibility & Screen Recording permissions on first install."
