#!/usr/bin/env bash
set -e

BIN_NAME="missioncontrol-fix"
INSTALL_DIR="${HOME}/.local/bin"
PLIST_LABEL="com.user.missioncontrol-fix"
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"

echo "Uninstalling ${BIN_NAME}..."

# Stop and remove LaunchAgent
launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true
launchctl unload "${PLIST_PATH}" 2>/dev/null || true
rm -f "${PLIST_PATH}"
echo "✓ Removed LaunchAgent"

# Remove binary
rm -f "${INSTALL_DIR}/${BIN_NAME}"
echo "✓ Removed binary from ${INSTALL_DIR}/${BIN_NAME}"

echo "✅ Uninstallation complete."
