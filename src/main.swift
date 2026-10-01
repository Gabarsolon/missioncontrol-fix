import Cocoa
import Foundation
import CoreGraphics

// MARK: - SkyLight Framework Private Declarations
typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("SLSCopyManagedDisplaySpaces")
func SLSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?

@_silgen_name("SLSManagedDisplayGetCurrentSpace")
func SLSManagedDisplayGetCurrentSpace(_ cid: CGSConnectionID, _ displayUUID: CFString) -> UInt64

@_silgen_name("SLSManagedDisplaySetCurrentSpace")
func SLSManagedDisplaySetCurrentSpace(_ cid: CGSConnectionID, _ displayUUID: CFString, _ spaceID: UInt64) -> Void

@_silgen_name("SLSShowSpaces")
func SLSShowSpaces(_ cid: CGSConnectionID, _ spaces: CFArray) -> Void

// MARK: - MissionControlDoctor Core Engine
class MissionControlDoctor {
    static let shared = MissionControlDoctor()
    private let cid = CGSMainConnectionID()
    private let spacesApp = "com.apple.spaces" as CFString
    private let configKey = "SpacesDisplayConfiguration" as CFString
    private var lastRestartTime: Date = Date.distantPast
    private var isRepairing = false

    init() {
        setlinebuf(stdout)
        setlinebuf(stderr)
    }

    // Resolves "Main" identifier to the actual primary display UUID
    func getMainDisplayUUID() -> String? {
        let mainID = CGMainDisplayID()
        if let uuidRef = CGDisplayCreateUUIDFromDisplayID(mainID)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuidRef) as String
        }
        return nil
    }

    // Returns a list of display UUIDs whose desktop backing layer is unrendered / pitch black
    func detectBlackDisplays() -> [(id: CGDirectDisplayID, uuid: String, bounds: CGRect)] {
        guard let rawSpaces = SLSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }

        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &displays, &count)

        var displayInfo = [String: (id: CGDirectDisplayID, bounds: CGRect)]()
        for d in displays {
            if let uuidRef = CGDisplayCreateUUIDFromDisplayID(d)?.takeRetainedValue() {
                let uuidStr = CFUUIDCreateString(nil, uuidRef) as String
                displayInfo[uuidStr] = (d, CGDisplayBounds(d))
            }
        }

        let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []

        var blackDisplays = [(id: CGDirectDisplayID, uuid: String, bounds: CGRect)]()

        for d in rawSpaces {
            guard let uuid = d["Display Identifier"] as? String,
                  let info = displayInfo[uuid] else { continue }

            let cur = d["Current Space"] as? [String: Any]
            let spaceType = (cur?["type"] as? NSNumber)?.int32Value ?? 0

            // If the active space is a Desktop space (type 0)
            if spaceType == 0 {
                var foundOnScreen = false
                for w in windowList {
                    guard let owner = w[kCGWindowOwnerName as String] as? String, owner == "Finder",
                          let layer = w[kCGWindowLayer as String] as? Int, layer == -2147483603,
                          let bDict = w[kCGWindowBounds as String] as? [String: Any],
                          let wBounds = CGRect(dictionaryRepresentation: bDict as CFDictionary) else { continue }

                    if wBounds.equalTo(info.bounds) {
                        if let onScreen = w[kCGWindowIsOnscreen as String] as? Bool, onScreen {
                            foundOnScreen = true
                        }
                        break
                    }
                }

                if !foundOnScreen {
                    blackDisplays.append((id: info.id, uuid: uuid, bounds: info.bounds))
                }
            }
        }
        return blackDisplays
    }

    // MARK: - Health Check
    func checkHealth(verbose: Bool = true) -> Bool {
        var isHealthy = true
        if verbose {
            print("==================================================")
            print("   macOS Mission Control / Spaces Diagnostics")
            print("==================================================")
        }

        guard let rawSpaces = SLSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else {
            print("❌ Error: Unable to query SkyLight display spaces.")
            return false
        }

        let mainUUID = getMainDisplayUUID()
        let blackDisplays = detectBlackDisplays()
        let blackUUIDs = Set(blackDisplays.map { $0.uuid })

        for (idx, d) in rawSpaces.enumerated() {
            let uuidStr = d["Display Identifier"] as? String ?? "Unknown"
            let isMain = (uuidStr == mainUUID)
            let curSpaceDict = d["Current Space"] as? [String: Any]
            let curSpaceID = (curSpaceDict?["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? 0
            let spaceType = (curSpaceDict?["type"] as? NSNumber)?.int32Value ?? 0
            let spaces = d["Spaces"] as? [[String: Any]] ?? []

            var validIDs = Set<UInt64>()
            for s in spaces {
                if let sid = (s["ManagedSpaceID"] as? NSNumber)?.uint64Value {
                    validIDs.insert(sid)
                }
            }

            if verbose {
                print("\n[Display \(idx)] UUID: \(uuidStr)\(isMain ? " (Main Display)" : " (External)")")
                print("  • Active Space ID: \(curSpaceID) (\(spaceType == 0 ? "Desktop" : "Full-Screen App"))")
                print("  • Total Registered Spaces: \(spaces.count)")
            }

            if !validIDs.contains(curSpaceID) {
                print("  ⚠️  WARNING: Active Space \(curSpaceID) is NOT in this display's spaces list!")
                isHealthy = false
            }

            if blackUUIDs.contains(uuidStr) {
                print("  ❌ STATUS: SCREEN IS BLACK! Desktop backing layer is unrendered (onScreen = false).")
                isHealthy = false
            } else if verbose {
                print("  ✓ Desktop compositor layer is visible and active.")
            }
        }

        // Check com.apple.spaces Plist Preferences
        if let dict = CFPreferencesCopyAppValue(configKey, spacesApp) as? [String: Any],
           let mgmt = dict["Management Data"] as? [String: Any] {

            var spaceOwnerMap = [String: String]()
            if let monitors = mgmt["Monitors"] as? [[String: Any]] {
                for m in monitors {
                    let did = m["Display Identifier"] as? String ?? ""
                    let realDid = (did == "Main" && mainUUID != nil) ? mainUUID! : did
                    if let spaces = m["Spaces"] as? [[String: Any]] {
                        for s in spaces {
                            if let uuid = s["uuid"] as? String, !uuid.isEmpty {
                                spaceOwnerMap[uuid] = realDid
                            }
                        }
                    }
                }
            }

            if let sa = mgmt["SpaceAssignments"] as? [String: Any] {
                if let assignments = sa["ManagedSpaceAssignments"] as? [[String: Any]] {
                    for a in assignments {
                        let sid = a["ManagedSpaceID"] as? String ?? ""
                        let dids = a["ManagedDisplayID"] as? [String] ?? []
                        if dids.count > 1 {
                            print("\n⚠️  CORRUPTION: Space '\(sid)' assigned to multiple displays: \(dids)")
                            isHealthy = false
                        }
                    }
                }

                if let ordering = sa["ManagedSpaceOrdering"] as? [[String: Any]] {
                    for entry in ordering {
                        let did = entry["ManagedDisplayID"] as? String ?? ""
                        let realDid = (did == "Main" && mainUUID != nil) ? mainUUID! : did
                        let sids = entry["ManagedSpaceIDs"] as? [String] ?? []
                        for sid in sids where !sid.isEmpty {
                            if let owner = spaceOwnerMap[sid], owner != realDid {
                                print("\n⚠️  CORRUPTION: Space '\(sid)' in ordering for display '\(did)' actually belongs to '\(owner)'!")
                                isHealthy = false
                            }
                        }
                    }
                }
            }
        }

        // Check mru-spaces
        let mru = CFPreferencesCopyAppValue("mru-spaces" as CFString, "com.apple.dock" as CFString) as? Bool
        if verbose {
            print("\n--------------------------------------------------")
            print("Mission Control Settings:")
            print("  • Automatically rearrange Spaces (mru-spaces): \(mru == true ? "ON (Recommended: OFF)" : "OFF (Optimal)")")
            print("--------------------------------------------------")
        }

        if isHealthy {
            if verbose {
                print("\n✅ All displays and Spaces structures are clean and synchronized.")
            }
        } else {
            if verbose {
                print("\n❌ Issues detected. Run 'missioncontrol-fix repair' to restore.")
            }
        }

        return isHealthy
    }

    // MARK: - Preferences Cleanup
    @discardableResult
    func repairPreferences() -> Bool {
        guard var dict = CFPreferencesCopyAppValue(configKey, spacesApp) as? [String: Any],
              var mgmt = dict["Management Data"] as? [String: Any],
              let monitors = mgmt["Monitors"] as? [[String: Any]],
              var sa = mgmt["SpaceAssignments"] as? [String: Any] else {
            return false
        }

        let mainUUID = getMainDisplayUUID()
        var spaceOwnerMap = [String: String]()
        for m in monitors {
            let did = m["Display Identifier"] as? String ?? ""
            let realDid = (did == "Main" && mainUUID != nil) ? mainUUID! : did
            if let spaces = m["Spaces"] as? [[String: Any]] {
                for s in spaces {
                    if let uuid = s["uuid"] as? String, !uuid.isEmpty {
                        spaceOwnerMap[uuid] = realDid
                    }
                }
            }
        }

        var modified = false

        if let assignments = sa["ManagedSpaceAssignments"] as? [[String: Any]] {
            var cleanedAssignments = [[String: Any]]()
            for a in assignments {
                let sid = a["ManagedSpaceID"] as? String ?? ""
                let dids = a["ManagedDisplayID"] as? [String] ?? []
                if dids.count > 1 {
                    modified = true
                    let realDid = spaceOwnerMap[sid] ?? dids.first!
                    cleanedAssignments.append(["ManagedDisplayID": [realDid], "ManagedSpaceID": sid])
                } else {
                    cleanedAssignments.append(a)
                }
            }
            if modified {
                sa["ManagedSpaceAssignments"] = cleanedAssignments
            }
        }

        if let ordering = sa["ManagedSpaceOrdering"] as? [[String: Any]] {
            var cleanedOrdering = [[String: Any]]()
            for entry in ordering {
                let did = entry["ManagedDisplayID"] as? String ?? ""
                let realDid = (did == "Main" && mainUUID != nil) ? mainUUID! : did
                let sids = entry["ManagedSpaceIDs"] as? [String] ?? []
                var validSids = [String]()
                for sid in sids {
                    if sid.isEmpty {
                        validSids.append(sid)
                        continue
                    }
                    if let owner = spaceOwnerMap[sid] {
                        if owner == realDid {
                            validSids.append(sid)
                        } else {
                            modified = true
                        }
                    } else {
                        validSids.append(sid)
                    }
                }
                cleanedOrdering.append(["ManagedDisplayID": did, "ManagedSpaceIDs": validSids])
            }
            if modified {
                sa["ManagedSpaceOrdering"] = cleanedOrdering
            }
        }

        if modified {
            mgmt["SpaceAssignments"] = sa
            dict["Management Data"] = mgmt
            CFPreferencesSetAppValue(configKey, dict as CFDictionary, spacesApp)
            CFPreferencesAppSynchronize(spacesApp)
            print("[Doctor] Purged corrupted duplicate entries in com.apple.spaces.")
        }

        return modified
    }

    // MARK: - Reload Dock Compositor
    func reloadDock(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastRestartTime) > 2.0 else { return }
        lastRestartTime = now

        print("[Doctor] 🔄 \(reason) -> Reloading Dock compositor...")
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock") {
            kill(app.processIdentifier, SIGTERM)
        }
    }

    // MARK: - Check and Auto-Unblank
    @discardableResult
    func checkAndUnblank(silent: Bool = false) -> Bool {
        guard !isRepairing else { return false }
        isRepairing = true
        defer { isRepairing = false }

        // 1. Clean preferences if corrupted
        repairPreferences()

        // 2. Check for black displays
        let blackDisplays = detectBlackDisplays()
        if !blackDisplays.isEmpty {
            let desc = blackDisplays.map { "\($0.uuid)" }.joined(separator: ", ")
            if !silent {
                print("[Doctor] ⚠️ Detected BLACK SCREEN on display(s): \(desc)")
            }

            // Reload Dock to immediately re-bind the wallpaper and Finder desktop windows
            reloadDock(reason: "Black screen detected on [\(desc)]")
            return true
        }

        return false
    }

    // MARK: - Full Manual Repair Routine
    func fullRepair() {
        print("[Doctor] Starting manual Mission Control / Spaces repair...")
        repairPreferences()

        // Ensure mru-spaces is disabled
        CFPreferencesSetAppValue("mru-spaces" as CFString, kCFBooleanFalse, "com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)

        let blackDisplays = detectBlackDisplays()
        if !blackDisplays.isEmpty {
            let desc = blackDisplays.map { "\($0.uuid)" }.joined(separator: ", ")
            print("[Doctor] Detected black display(s): \(desc)")
            reloadDock(reason: "Manual repair request")
            print("✅ Dock restarted. Displays restored!")
        } else {
            // Re-assert spaces via SkyLight
            guard let rawSpaces = SLSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return }
            for d in rawSpaces {
                guard let uuidStr = d["Display Identifier"] as? String else { continue }
                let cur = d["Current Space"] as? [String: Any]
                if let sid = (cur?["ManagedSpaceID"] as? NSNumber)?.uint64Value {
                    SLSManagedDisplaySetCurrentSpace(cid, uuidStr as CFString, sid)
                    SLSShowSpaces(cid, [sid] as CFArray)
                }
            }
            print("✅ All displays verified healthy (no black screens detected).")
        }
    }

    // MARK: - Daemon Watcher Mode
    func startDaemon() {
        print("[Doctor Daemon] Starting background watchdog for macOS 27 Mission Control bug...")
        print("[Doctor Daemon] Monitoring display layers and space changes...")

        // Initial sweep
        checkAndUnblank(silent: true)

        let center = NSWorkspace.shared.notificationCenter

        // 1. Observe Active Space Changes (Mission Control exit / Space switch)
        center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.checkAndUnblank(silent: false)
            }
        }

        // 2. Observe Display Reconfigurations
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.checkAndUnblank(silent: false)
            }
        }

        // 3. Periodic liveness timer (checks every 1.5 seconds with ~0% CPU)
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.checkAndUnblank(silent: true)
        }

        print("[Doctor Daemon] Active and monitoring. Press Ctrl+C to stop.")
        RunLoop.current.run()
    }
}

// MARK: - CLI Argument Handling
let args = CommandLine.arguments
let command = args.count > 1 ? args[1].lowercased() : "help"

switch command {
case "status", "check":
    let healthy = MissionControlDoctor.shared.checkHealth(verbose: true)
    exit(healthy ? 0 : 1)

case "repair", "fix":
    MissionControlDoctor.shared.fullRepair()
    exit(0)

case "daemon", "watch":
    MissionControlDoctor.shared.startDaemon()

case "help", "--help", "-h":
    print("""
    missioncontrol-fix: macOS 27 Mission Control Multi-Monitor Black Screen Fix
    
    Usage:
      missioncontrol-fix status     Check displays and detect unrendered/black screens
      missioncontrol-fix repair     Instantly restore black screens and heal spaces
      missioncontrol-fix daemon     Run background watchdog (auto-fixes in real time)
      missioncontrol-fix help       Show this help message
    """)
    exit(0)

default:
    print("Unknown command: \(command)")
    print("Run 'missioncontrol-fix help' for usage.")
    exit(1)
}
