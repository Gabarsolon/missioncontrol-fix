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
    private var lastRunTime: Date = Date.distantPast
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    // Returns a mapping of hardware display ID to UUID string
    func getOnlineDisplayMap() -> [CGDirectDisplayID: String] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &displays, &count)

        var map = [CGDirectDisplayID: String]()
        for d in displays {
            if let uuidRef = CGDisplayCreateUUIDFromDisplayID(d)?.takeRetainedValue() {
                let uuidStr = CFUUIDCreateString(nil, uuidRef) as String
                map[d] = uuidStr
            }
        }
        return map
    }

    // Resolves "Main" identifier to the actual primary display UUID
    func getMainDisplayUUID() -> String? {
        let mainID = CGMainDisplayID()
        if let uuidRef = CGDisplayCreateUUIDFromDisplayID(mainID)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuidRef) as String
        }
        return nil
    }

    // MARK: - Health Check
    func checkHealth(verbose: Bool = true) -> Bool {
        var isHealthy = true
        if verbose {
            print("==================================================")
            print("   macOS Mission Control / Spaces Diagnostics")
            print("==================================================")
        }

        // 1. Check Live Display Spaces from SkyLight
        guard let rawSpaces = SLSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else {
            print("❌ Error: Unable to query SkyLight display spaces.")
            return false
        }

        let mainUUID = getMainDisplayUUID()

        for (idx, d) in rawSpaces.enumerated() {
            let uuidStr = d["Display Identifier"] as? String ?? "Unknown"
            let isMain = (uuidStr == mainUUID)
            let curSpaceDict = d["Current Space"] as? [String: Any]
            let curSpaceID = (curSpaceDict?["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? 0
            let spaces = d["Spaces"] as? [[String: Any]] ?? []

            var validIDs = Set<UInt64>()
            for s in spaces {
                if let sid = (s["ManagedSpaceID"] as? NSNumber)?.uint64Value {
                    validIDs.insert(sid)
                }
            }

            if verbose {
                print("\n[Display \(idx)] UUID: \(uuidStr)\(isMain ? " (Main Display)" : " (External)")")
                print("  • Active Space ID: \(curSpaceID)")
                print("  • Total Registered Spaces: \(spaces.count)")
            }

            if !validIDs.contains(curSpaceID) {
                print("  ⚠️  WARNING: Active Space \(curSpaceID) is NOT in this display's spaces list! (Ghost Space)")
                isHealthy = false
            } else {
                if verbose {
                    print("  ✓ Active Space is valid.")
                }
            }
        }

        // 2. Check com.apple.spaces Plist Preferences
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
                // Check ManagedSpaceAssignments
                if let assignments = sa["ManagedSpaceAssignments"] as? [[String: Any]] {
                    for a in assignments {
                        let sid = a["ManagedSpaceID"] as? String ?? ""
                        let dids = a["ManagedDisplayID"] as? [String] ?? []
                        if dids.count > 1 {
                            print("\n⚠️  CORRUPTION DETECTED: Space '\(sid)' is assigned to multiple displays simultaneously: \(dids)")
                            isHealthy = false
                        }
                    }
                }

                // Check ManagedSpaceOrdering
                if let ordering = sa["ManagedSpaceOrdering"] as? [[String: Any]] {
                    for entry in ordering {
                        let did = entry["ManagedDisplayID"] as? String ?? ""
                        let realDid = (did == "Main" && mainUUID != nil) ? mainUUID! : did
                        let sids = entry["ManagedSpaceIDs"] as? [String] ?? []
                        for sid in sids where !sid.isEmpty {
                            if let owner = spaceOwnerMap[sid], owner != realDid {
                                print("\n⚠️  CORRUPTION DETECTED: Space '\(sid)' in ordering for display '\(did)' actually belongs to '\(owner)'!")
                                isHealthy = false
                            }
                        }
                    }
                }
            }
        }

        // 3. Check mru-spaces
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
                print("\n❌ Desynchronization or corruption detected. Run 'missioncontrol-fix repair' to fix.")
            }
        }

        return isHealthy
    }

    // MARK: - Repair Corrupted Spaces Preferences
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

        // 1. Clean ManagedSpaceAssignments
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

        // 2. Clean ManagedSpaceOrdering
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
            print("[Doctor] Fixed corrupted duplicate entries in com.apple.spaces.")
        }

        return modified
    }

    // MARK: - Re-assert and Un-blank Displays
    @discardableResult
    func repairDisplays(silent: Bool = false) -> Int {
        guard let rawSpaces = SLSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else {
            return 0
        }

        var fixedCount = 0

        for d in rawSpaces {
            guard let uuidStr = d["Display Identifier"] as? String else { continue }
            let uuid = uuidStr as CFString
            let curSpaceDict = d["Current Space"] as? [String: Any]
            var curSpaceID = (curSpaceDict?["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? 0
            let spaces = d["Spaces"] as? [[String: Any]] ?? []

            var validIDs = [UInt64]()
            var desktopSpaceID: UInt64 = 0

            for s in spaces {
                if let sid = (s["ManagedSpaceID"] as? NSNumber)?.uint64Value {
                    validIDs.append(sid)
                    let stype = (s["type"] as? NSNumber)?.int32Value ?? 0
                    if stype == 0 && desktopSpaceID == 0 {
                        desktopSpaceID = sid
                    }
                }
            }

            var needsCorrection = false

            // If current space is orphaned (not in display's spaces)
            if !validIDs.contains(curSpaceID) {
                needsCorrection = true
                if desktopSpaceID != 0 {
                    curSpaceID = desktopSpaceID
                } else if let first = validIDs.first {
                    curSpaceID = first
                }
            }

            // Always re-assert space layer to ensure WindowServer de-occludes the desktop
            SLSManagedDisplaySetCurrentSpace(cid, uuid, curSpaceID)
            SLSShowSpaces(cid, [curSpaceID] as CFArray)

            if needsCorrection {
                fixedCount += 1
                if !silent {
                    print("[Doctor] Restored orphaned display '\(uuidStr)' to Space ID \(curSpaceID).")
                }
            }
        }

        return fixedCount
    }

    // MARK: - Full Repair Routine
    func fullRepair() {
        print("[Doctor] Starting Mission Control / Spaces repair...")
        let prefRepaired = repairPreferences()
        let displaysRepaired = repairDisplays(silent: false)

        // Ensure mru-spaces is disabled
        CFPreferencesSetAppValue("mru-spaces" as CFString, kCFBooleanFalse, "com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)

        print("[Doctor] Mission Control preferences optimized (mru-spaces = false).")
        print("[Doctor] Display compositing layers refreshed.")
        if prefRepaired || displaysRepaired > 0 {
            print("✅ Successfully repaired all orphaned spaces and display configurations!")
        } else {
            print("✅ All displays refreshed and verified healthy (no active corruptions).")
        }
    }

    // MARK: - Daemon Watcher Mode
    func startDaemon() {
        print("[Doctor Daemon] Starting background watcher for macOS 27 Mission Control bug...")

        // Initial sweep
        repairPreferences()
        repairDisplays(silent: true)

        let center = NSWorkspace.shared.notificationCenter

        // 1. Observe Active Space Changes (Mission Control exit / Space switch)
        center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleEvent(reason: "ActiveSpaceDidChange")
        }

        // 2. Observe Display Reconfigurations
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleEvent(reason: "ScreenParametersChanged")
        }

        // 3. Watch com.apple.spaces.plist modifications
        startPlistWatcher()

        print("[Doctor Daemon] Active and monitoring. Press Ctrl+C to stop.")
        RunLoop.current.run()
    }

    private func handleEvent(reason: String) {
        // Debounce within 200ms
        let now = Date()
        guard now.timeIntervalSince(lastRunTime) > 0.2 else { return }
        lastRunTime = now

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.repairPreferences()
            self.repairDisplays(silent: true)
        }
    }

    private func startPlistWatcher() {
        let plistPath = ("~/Library/Preferences/com.apple.spaces.plist" as NSString).expandingTildeInPath
        fileDescriptor = open(plistPath, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        fileWatcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .attrib],
            queue: .main
        )

        fileWatcher?.setEventHandler { [weak self] in
            self?.handleEvent(reason: "SpacesPlistModified")
        }

        fileWatcher?.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
            }
        }

        fileWatcher?.resume()
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
      missioncontrol-fix status     Check spaces and display health for corruptions
      missioncontrol-fix repair     Instantly un-blank displays and repair spaces
      missioncontrol-fix daemon     Run background watchdog (auto-fixes in real time)
      missioncontrol-fix help       Show this help message
    """)
    exit(0)

default:
    print("Unknown command: \(command)")
    print("Run 'missioncontrol-fix help' for usage.")
    exit(1)
}
