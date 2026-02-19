#!/usr/bin/env bash
set -euo pipefail

LABEL="io.github.byronhsu.powermate-scroll"
BIN_PATH="${HOME}/.local/bin/powermate-scroll"
AGENT_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
APP_DIR="${HOME}/Applications/PowerMateScroll.app"

launchctl bootout "gui/${UID}/${LABEL}" >/dev/null 2>&1 || true
launchctl bootout "gui/${UID}" "${AGENT_PATH}" >/dev/null 2>&1 || true
rm -f "${AGENT_PATH}" "${BIN_PATH}"
rm -rf "${APP_DIR}"

echo "Uninstalled ${LABEL}"
