import Foundation
import CoreGraphics
import IOKit

@MainActor
final class HiDPIService: @unchecked Sendable {
    static let shared = HiDPIService()
    private init() {}

    private var refreshTask: Task<Void, Never>?

    private let overridesBase = URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides")

    // MARK: - Public API

    /// Checks whether HiDPI is enabled for the given display via plist override.
    func isHiDPIEnabled(for displayID: CGDirectDisplayID, vendor: UInt32, product: UInt32) -> Bool {
        FileManager.default.fileExists(atPath: overridePlistURL(vendor: vendor, product: product).path)
    }

    /// Checks whether HiDPI is enabled for the given display via plist override only.
    func isHiDPIEnabled(vendor: UInt32, product: UInt32) -> Bool {
        let plistURL = overridePlistURL(vendor: vendor, product: product)
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Enables HiDPI for an external display via plist override.
    /// Requires display reconnect (or reboot) to apply.
    ///
    /// Returns nil on success, or an error string on failure.
    func enableHiDPI(for displayID: CGDirectDisplayID,
                     vendor: UInt32,
                     product: UInt32,
                     nativeWidth: Int,
                     nativeHeight: Int) async -> String? {
        return enableHiDPIPlist(vendor: vendor, product: product,
                                nativeWidth: nativeWidth, nativeHeight: nativeHeight)
    }

    /// Legacy single-path enable (plist only).
    func enableHiDPI(vendor: UInt32, product: UInt32, nativeWidth: Int, nativeHeight: Int) -> String? {
        enableHiDPIPlist(vendor: vendor, product: product,
                         nativeWidth: nativeWidth, nativeHeight: nativeHeight)
    }

    /// Disables HiDPI for an external display by removing the plist override.
    func disableHiDPI(for displayID: CGDirectDisplayID,
                      vendor: UInt32,
                      product: UInt32) -> String? {
        return disableHiDPIPlist(vendor: vendor, product: product)
    }

    /// Legacy single-path disable (plist only).
    func disableHiDPI(vendor: UInt32, product: UInt32) -> String? {
        disableHiDPIPlist(vendor: vendor, product: product)
    }

    /// Refreshes availableModes on the given DisplayInfo after enabling HiDPI.
    func refreshModes(for display: DisplayInfo) {
        refreshTask?.cancel()
        let physicalID = display.displayID

        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            async let modes = Task.detached(priority: .userInitiated) {
                DisplayMode.availableModes(for: physicalID)
            }.value
            async let current = Task.detached(priority: .userInitiated) {
                DisplayMode.currentMode(for: physicalID)
            }.value
            display.availableModes = await modes
            display.currentDisplayMode = await current
        }
    }

    // MARK: - Smooth Scaling

    /// Enables (or re-injects) smooth scaling for a display by injecting the dense HiDPI
    /// ladder into its override plist, then re-probing. The privileged write (admin prompt)
    /// is skipped when the on-disk plist already carries exactly these modes, so re-enabling
    /// after a toggle does not re-prompt; reading the plist for that check needs no admin.
    /// Overwrites in place, so it also upgrades a display already on the coarse plist.
    /// Returns nil on success (including the no-write case) or an error string.
    func enableSmoothScaling(vendor: UInt32, product: UInt32,
                             nativeWidth: Int, nativeHeight: Int) -> String? {
        let target = generateSmoothScaledModes(nativeWidth: nativeWidth, nativeHeight: nativeHeight)
        if overridePlistMatches(vendor: vendor, product: product, scaledModes: target) {
            // Already installed; re-probe (no admin) in case the modes need re-enumerating.
            triggerDisplayReenumeration(vendor: vendor, product: product)
            return nil
        }
        return writeScaledModesPlist(vendor: vendor, product: product, scaledModes: target)
    }

    /// True when enabling smooth scaling would need a privileged write (admin prompt),
    /// i.e. the on-disk override plist doesn't already carry the dense modes. Lets the UI
    /// show the "asks for administrator password" hint only when it's actually true.
    func smoothScalingWouldPrompt(vendor: UInt32, product: UInt32,
                                  nativeWidth: Int, nativeHeight: Int) -> Bool {
        !overridePlistMatches(vendor: vendor, product: product,
                              scaledModes: generateSmoothScaledModes(nativeWidth: nativeWidth,
                                                                     nativeHeight: nativeHeight))
    }

    // MARK: - Plist Override

    private func enableHiDPIPlist(vendor: UInt32, product: UInt32,
                                   nativeWidth: Int, nativeHeight: Int) -> String? {
        writeScaledModesPlist(vendor: vendor, product: product,
                              scaledModes: generateScaledModes(nativeWidth: nativeWidth,
                                                               nativeHeight: nativeHeight))
    }

    /// Writes the override plist with the given scale-resolutions entries via admin auth,
    /// then re-probes so macOS re-enumerates modes. Shared by normal HiDPI and smooth scaling.
    private func writeScaledModesPlist(vendor: UInt32, product: UInt32, scaledModes: [Data]) -> String? {
        let dirPath = overrideDir(vendor: vendor).path
        let plistPath = overridePlistURL(vendor: vendor, product: product).path

        let plist: [String: Any] = [
            "scale-resolutions": scaledModes
        ]

        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return "Failed to generate plist data"
        }

        // Write to a temp file first, then use privileged helper to move it
        let tmpPath = NSTemporaryDirectory() + "crisp_hidpi_override.plist"
        do {
            try data.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)
        } catch {
            return "Failed to write temp file: \(error.localizedDescription)"
        }

        // Use AppleScript to get admin privileges for writing to /Library/Displays/
        if let err = executePrivilegedCommand("mkdir -p '\(dirPath)' && cp '\(tmpPath)' '\(plistPath)'") {
            return err
        }

        // Clean up temp file
        try? FileManager.default.removeItem(atPath: tmpPath)

        // Attempt to trigger display mode re-enumeration via IOServiceRequestProbe
        triggerDisplayReenumeration(vendor: vendor, product: product)

        return nil
    }

    private func disableHiDPIPlist(vendor: UInt32, product: UInt32) -> String? {
        let plistPath = overridePlistURL(vendor: vendor, product: product).path
        guard FileManager.default.fileExists(atPath: plistPath) else { return nil }

        if let err = executePrivilegedCommand("rm -f '\(plistPath)'") {
            return err
        }
        return nil
    }

    // MARK: - Helpers

    /// Executes a shell command with administrator privileges via AppleScript.
    /// Returns nil on success, or an error message on failure.
    private func executePrivilegedCommand(_ command: String) -> String? {
        let script = """
            do shell script "\(command)" with administrator privileges
            """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            return "Failed to create AppleScript"
        }
        // The auth dialog steals key and swallows the user's clicks, which would
        // otherwise trip the panel's auto-dismiss. Suppress that here. The
        // dismiss events queue while the main thread is blocked below and only
        // fire once it unblocks, so keep suppression alive briefly afterward.
        PanelOpenGuard.suppressAutoDismiss = true
        defer {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                PanelOpenGuard.suppressAutoDismiss = false
            }
        }
        appleScript.executeAndReturnError(&error)
        if let error = error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            if msg.contains("canceled") || msg.contains("Cancel") {
                return "User canceled authorization"
            }
            return "Administrator authorization failed: \(msg)"
        }
        return nil
    }

    private func triggerDisplayReenumeration(vendor: UInt32, product: UInt32) {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            guard let cfDict = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() else {
                continue
            }
            let dict = cfDict as NSDictionary

            let serviceVendor: UInt32
            let serviceProduct: UInt32

            if let v = dict["DisplayVendorID"] as? UInt32 {
                serviceVendor = v
            } else if let v = dict["DisplayVendorID"] as? Int {
                serviceVendor = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
            } else { continue }

            if let p = dict["DisplayProductID"] as? UInt32 {
                serviceProduct = p
            } else if let p = dict["DisplayProductID"] as? Int {
                serviceProduct = UInt32(bitPattern: Int32(truncatingIfNeeded: p))
            } else { continue }

            guard serviceVendor == vendor && serviceProduct == product else { continue }

            IOServiceRequestProbe(service, 0)
            break
        }
    }

    private func overrideDir(vendor: UInt32) -> URL {
        overridesBase
            .appendingPathComponent(String(format: "DisplayVendorID-%x", vendor))
    }

    private func overridePlistURL(vendor: UInt32, product: UInt32) -> URL {
        overrideDir(vendor: vendor)
            .appendingPathComponent(String(format: "DisplayProductID-%x", product))
    }

    /// True when the on-disk override plist's scale-resolutions already equals `scaledModes`
    /// (order-independent). Lets callers skip the privileged rewrite, and its admin prompt,
    /// when nothing would change. Reading /Library/Displays needs no privileges.
    private func overridePlistMatches(vendor: UInt32, product: UInt32, scaledModes: [Data]) -> Bool {
        let url = overridePlistURL(vendor: vendor, product: product)
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any],
              let existing = dict["scale-resolutions"] as? [Data]
        else { return false }
        return Set(existing) == Set(scaledModes)
    }

    private func generateScaledModes(nativeWidth: Int, nativeHeight: Int) -> [Data] {
        // Coarse HiDPI ladder matching macOS's usual scaled set: native as HiDPI plus
        // a few standard steps. Used for normal HiDPI enablement. Each entry is the
        // backing (pixel) resolution = logical × 2.
        var logical: [(Int, Int)] = [(nativeWidth, nativeHeight)]
        for scale in [0.75, 0.625, 0.5] {
            let w = Int((Double(nativeWidth) * scale).rounded()) & ~1
            let h = Int((Double(nativeHeight) * scale).rounded()) & ~1
            guard w >= 800, h >= 600 else { continue }
            logical.append((w, h))
        }
        return logical.map { encodeScaledMode(backingW: $0.0 * 2, backingH: $0.1 * 2) }
    }

    /// Dense HiDPI "looks like" ladder for smooth scaling: native plus logical sizes from
    /// `minScale`×native up toward native, each injected as a 2×-backed HiDPI mode. Deduped
    /// (rounding can collide adjacent steps), even dimensions, floored at 800×600. This is
    /// what lets the smooth-scaling slider feel continuous: it snaps across these. Injecting
    /// many modes also lengthens the System Settings list, so this is only used for displays
    /// the user opts into smooth scaling for.
    ///
    /// The step count is derived from the panel, not fixed: one stop per ~`stepHeight`
    /// logical points across the 50%→100% range. A 1440p panel yields ~14 stops (matching
    /// BetterDisplay's flexible scaling); a 4K/5K panel gets proportionally more, since its
    /// usable range spans more pixels, so the slider stays equally smooth on any display.
    func generateSmoothScaledModes(nativeWidth: Int, nativeHeight: Int,
                                   minScale: Double = 0.5) -> [Data] {
        // One stop per ~55 logical points of height: fine enough to feel continuous when
        // dragging, coarse enough not to flood the System Settings resolution list.
        let stepHeight = 55.0
        let span = Double(nativeHeight) * (1.0 - minScale)
        let steps = max(1, Int((span / stepHeight).rounded()))
        var logical: [(Int, Int)] = [(nativeWidth, nativeHeight)]  // native as HiDPI
        for i in 0..<steps {
            let scale = minScale + (1.0 - minScale) * Double(i) / Double(steps)
            let w = Int((Double(nativeWidth) * scale).rounded()) & ~1
            let h = Int((Double(nativeHeight) * scale).rounded()) & ~1
            guard w >= 800, h >= 600 else { continue }
            logical.append((w, h))
        }
        var seen = Set<Int>()
        let unique = logical.filter { seen.insert(($0.0 << 16) | $0.1).inserted }
        return unique.map { encodeScaledMode(backingW: $0.0 * 2, backingH: $0.1 * 2) }
    }

    /// Encodes a backing (pixel) resolution as the 8-byte big-endian entry the
    /// `scale-resolutions` override plist expects: [backingW big-endian][backingH big-endian].
    private func encodeScaledMode(backingW: Int, backingH: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[0] = UInt8((backingW >> 24) & 0xFF)
        bytes[1] = UInt8((backingW >> 16) & 0xFF)
        bytes[2] = UInt8((backingW >> 8) & 0xFF)
        bytes[3] = UInt8(backingW & 0xFF)
        bytes[4] = UInt8((backingH >> 24) & 0xFF)
        bytes[5] = UInt8((backingH >> 16) & 0xFF)
        bytes[6] = UInt8((backingH >> 8) & 0xFF)
        bytes[7] = UInt8(backingH & 0xFF)
        return Data(bytes)
    }
}
