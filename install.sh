#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_NAME="missioncontrol-fix"
INSTALL_DIR="${HOME}/.local/bin"
PLIST_LABEL="com.user.missioncontrol-fix"
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs"

echo "======================================================="
echo "   macOS 27 Mission Control Multi-Monitor Fix Installer"
echo "======================================================="

# 1. Check requirements
if ! command -v swiftc >/dev/null 2>&1; then
    echo "❌ Error: Xcode Command Line Tools or swiftc not found."
    echo "Please run: xcode-select --install"
    exit 1
fi

# 2. Build if not in --service-only mode
if [ "$1" != "--service-only" ]; then
    echo "🔨 Compiling native Swift binary..."
    mkdir -p "${SCRIPT_DIR}/bin"
    swiftc -O "${SCRIPT_DIR}/src/main.swift" \
        -F/System/Library/PrivateFrameworks \
        -framework SkyLight \
        -o "${SCRIPT_DIR}/bin/${BIN_NAME}"

    mkdir -p "${INSTALL_DIR}"
    cp "${SCRIPT_DIR}/bin/${BIN_NAME}" "${INSTALL_DIR}/${BIN_NAME}"
    chmod +x "${INSTALL_DIR}/${BIN_NAME}"
    echo "✓ Installed ${BIN_NAME} to ${INSTALL_DIR}/${BIN_NAME}"
fi

# Ensure bin is in PATH hint
if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
    echo "ℹ️  Tip: Make sure ${INSTALL_DIR} is in your PATH."
fi

# 3. Perform initial repair
echo "🩺 Running initial health check and repair..."
"${INSTALL_DIR}/${BIN_NAME}" repair

# 4. Install LaunchAgent background daemon
echo "⚙️ Setting up background LaunchAgent daemon..."
mkdir -p "${HOME}/Library/LaunchAgents"
mkdir -p "${LOG_DIR}"

# Unload previous service if exists
launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true
launchctl unload "${PLIST_PATH}" 2>/dev/null || true

cat << EOF > "${PLIST_PATH}"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/${BIN_NAME}</string>
        <string>daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/missioncontrol-fix.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/missioncontrol-fix.err.log</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

# 5. Load and start LaunchAgent
if launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}" 2>/dev/null; then
    echo "✓ LaunchAgent loaded via bootstrap."
else
    launchctl load "${PLIST_PATH}"
    echo "✓ LaunchAgent loaded via load."
fi

echo ""
echo "======================================================="
echo "✅ Installation Complete & Background Watcher Active!"
echo "======================================================="
echo ""
echo "What this does for you:"
echo " 1. Monitors Space movements across monitors in real-time."
echo " 2. Prevents the macOS 27 Mission Control black-screen bug."
echo " 3. Automatically un-blanks and heals display layers in <20ms."
echo ""
echo "CLI Commands available:"
echo " • missioncontrol-fix status   - Check health of displays & spaces"
echo " • missioncontrol-fix repair   - Instantly trigger manual refresh"
echo " • View logs: tail -f ~/Library/Logs/missioncontrol-fix.log"
echo "======================================================="
