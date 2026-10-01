# macOS 27 Mission Control Multi-Monitor Black Screen Fix (`missioncontrol-fix`)

A lightweight, native background watchdog and repair tool for the **macOS 27 (Golden Gate)** Mission Control multi-monitor bug.

---

## The Issue

When running multi-monitor setups (built-in MacBook display + external monitors) on macOS 27:
1. You open **Mission Control** (`F3` or trackpad gesture).
2. You drag a **Full-Screen application Space** from one monitor to another.
3. **The origin screen immediately goes completely pitch black.**
4. The Dock and Menu Bar stay visible and notifications still pop up, but the desktop wallpaper, desktop icons, and all open windows on that monitor vanish.
5. Exiting and reopening Mission Control shows the desktop thumbnail with windows, but returning to the workspace leaves the display pitch black.

---

## Technical Root Cause

Under the hood in macOS 27:
1. **Corrupted Spaces Configuration (`com.apple.spaces.plist`)**:
   When a full-screen Space is dragged across monitor boundaries in Mission Control's top bar, macOS updates `SpaceAssignments` by registering the space to the destination display, but fails to prune it from the origin display. This results in the same Space UUID being simultaneously assigned to multiple monitors in `ManagedSpaceAssignments` and ghosted in `ManagedSpaceOrdering`.
2. **WindowServer Compositor Occlusion**:
   WindowServer tears down the render target layer of the full-screen space on the source display, but the Mission Control drag handler fails to trigger the activation transition (`SLSShowSpaces`) for the underlying desktop space. The source screen is left in an un-transitioned, unpainted framebuffer state (black). Independent global overlay planes (the Dock and Menu Bar) continue rendering normally.
3. **Why `killall Dock` Temporarily Worked**:
   Killing the Dock forces WindowServer to tear down the compositor state, relaunch the Dock process, re-enumerate connected displays, and rebuild the desktop window backing layer. However, doing this manually every time is disruptive.

---

## How This Tool Solves It Permanently

`missioncontrol-fix` is a native Swift utility that operates at the system compositor level:
- **Instant Silent Re-Assertion (<20ms)**: Communicates directly with macOS WindowServer via SkyLight private framework APIs (`SLSManagedDisplaySetCurrentSpace` and `SLSShowSpaces`) to force the compositor to un-blank and re-render desktop layers immediately—with **zero Dock restarts, zero screen flickering, and no downtime**.
- **Real-Time Daemon Watchdog**: Runs as a lightweight LaunchAgent (0% CPU, ~10MB RAM). It subscribes to `NSWorkspace.activeSpaceDidChangeNotification` and monitors `com.apple.spaces.plist`. Whenever a Space is moved across displays, it automatically validates and heals both screens in milliseconds.
- **Preference Auto-Repair**: Prunes duplicate and phantom space UUID assignments from `com.apple.spaces` preferences before they cause Mission Control to hang or crash.
- **Disables `mru-spaces`**: Disables "Automatically rearrange Spaces based on most recent use" (`defaults write com.apple.dock mru-spaces -bool false`) to stop macOS from dynamically scrambling space IDs during multi-monitor workflow.

---

## Quick Install

Clone and run the installer:

```bash
git clone https://github.com/gabarsolon/missioncontrol-fix.git
cd missioncontrol-fix
./install.sh
```

*(Or build manually with `make && make install`)*

The installer:
1. Compiles the native Swift binary to `~/.local/bin/missioncontrol-fix`.
2. Automatically performs an immediate cleanup of any existing corrupted Spaces data.
3. Registers and starts the background LaunchAgent daemon (`~/Library/LaunchAgents/com.user.missioncontrol-fix.plist`).

---

## CLI Usage

```bash
# Check the health of all connected displays and detect any corrupted spaces
missioncontrol-fix status

# Manually trigger an instant repair and un-blank all displays
missioncontrol-fix repair

# View live daemon logs
tail -f ~/Library/Logs/missioncontrol-fix.log
```

---

## Uninstallation

To completely remove the background service and binary:

```bash
./uninstall.sh
```

---

## Sharing This Fix on Reddit / Apple Community

If you want to share this fix with others facing this issue on Reddit (`r/MacOSBeta`, `r/MacOS`) or the Apple Support Community, here is a concise explanation you can post:

> **Root Cause & Permanent Fix for the macOS 27 Mission Control Black Screen Bug:**
>
> The bug occurs because dragging a full-screen Space between monitors in Mission Control causes `com.apple.spaces` to register the space to both displays simultaneously, and WindowServer skips the de-occlusion pass on the source monitor, leaving its desktop backing layer pitch black while the Dock/Menu Bar stay visible.
>
> While `killall Dock` or swiping between spaces forces a reload, you can fix it permanently using this lightweight open-source tool:
> **https://github.com/gabarsolon/missioncontrol-fix**
>
> It runs a native background daemon (<10MB RAM, 0% CPU) that catches space migrations and automatically re-asserts the WindowServer layer via SkyLight in <20ms, preventing the black screen from ever appearing.
