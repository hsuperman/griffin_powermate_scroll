#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="io.github.byronhsu.powermate-scroll"
BIN_DIR="${HOME}/.local/bin"
AGENT_DIR="${HOME}/Library/LaunchAgents"
LOG_DIR="${HOME}/Library/Logs"
BIN_PATH="${BIN_DIR}/powermate-scroll"
APP_DIR="${HOME}/Applications/PowerMateScroll.app"
APP_CONTENTS="${APP_DIR}/Contents"
APP_MACOS="${APP_CONTENTS}/MacOS"
APP_BIN_PATH="${APP_MACOS}/powermate-scroll"
APP_INFO_PLIST="${APP_CONTENTS}/Info.plist"
AGENT_PATH="${AGENT_DIR}/${LABEL}.plist"

mkdir -p "${BIN_DIR}" "${AGENT_DIR}" "${LOG_DIR}" "${APP_MACOS}"

"${ROOT_DIR}/scripts/build.sh"
cp "${ROOT_DIR}/build/powermate-scroll" "${BIN_PATH}"
chmod +x "${BIN_PATH}"
cp "${ROOT_DIR}/build/powermate-scroll" "${APP_BIN_PATH}"
chmod +x "${APP_BIN_PATH}"

cat > "${APP_INFO_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleName</key>
  <string>PowerMateScroll</string>
  <key>CFBundleDisplayName</key>
  <string>PowerMateScroll</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.byronhsu.powermatescroll</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleExecutable</key>
  <string>powermate-scroll</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || true

sed "s|__HOME__|${HOME}|g" "${ROOT_DIR}/launchd/${LABEL}.plist" > "${AGENT_PATH}"

launchctl bootout "gui/${UID}/${LABEL}" >/dev/null 2>&1 || true
launchctl bootout "gui/${UID}" "${AGENT_PATH}" >/dev/null 2>&1 || true

if ! launchctl bootstrap "gui/${UID}" "${AGENT_PATH}"; then
  sleep 0.2
  launchctl bootout "gui/${UID}/${LABEL}" >/dev/null 2>&1 || true
  launchctl bootout "gui/${UID}" "${AGENT_PATH}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/${UID}" "${AGENT_PATH}"
fi

launchctl kickstart -k "gui/${UID}/${LABEL}"

echo "Installed: ${BIN_PATH}"
echo "Installed app wrapper: ${APP_DIR}"
echo "Loaded launch agent: ${AGENT_PATH}"
echo "Grant Accessibility permission to: ${APP_DIR}"
open -R "${APP_DIR}" >/dev/null 2>&1 || true
echo "Opening System Settings to Accessibility..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true
echo "If needed, request the prompt manually:"
echo "  open -na \"${APP_DIR}\" --args --request-accessibility"
