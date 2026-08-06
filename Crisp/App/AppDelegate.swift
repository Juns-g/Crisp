import AppKit
import SwiftUI
import CoreGraphics
import ApplicationServices
import Combine
import os.log

/// Borderless key-capable panel for the menu bar UI.
/// Owning the panel (instead of MenuBarExtra's window) removes the WindowServer
/// zoom-in materialization and gives us native-menu open behavior.
final class MenuPanel: NSPanel {
    var onCancel: (() -> Void)?
    /// While set, every frame change re-anchors to this top edge (screen Y of
    /// the panel top). AppKit windows anchor bottom-left, so the auto-resize
    /// from the hosting view would otherwise grow the panel upward.
    var pinnedTopY: CGFloat?

    /// The SwiftUI hosting view inside the container content view.
    weak var hostingView: NSView?
    /// Last content size reported by SwiftUI layout (source of truth for
    /// the panel's natural size when showing).
    var lastContentSize: NSSize?
    private var resizeLink: CADisplayLink?
    private var resizeTarget: NSSize?
    private var resizeFrom: NSSize = .zero
    private var resizeStart: CFTimeInterval = 0
    private var resizeOmega: Double = 0
    /// Spring-start velocity (pt/s), carried over from the running spring on a
    /// retarget so an interrupted resize keeps its momentum instead of popping
    /// to a fresh zero-velocity curve (SwiftUI's springs preserve velocity on
    /// retarget; the window must match or the edges visibly disagree).
    private var resizeV0 = CGSize.zero
    /// Live velocity of the running spring, updated per tick. Zero when idle,
    /// so a spring started from rest still starts from rest.
    private var resizeVelocity = CGSize.zero

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var r = frameRect
        if let top = pinnedTopY { r.origin.y = top - r.height }
        super.setFrame(r, display: flag)
    }

    func applyContentSize(_ size: NSSize) {
        lastContentSize = size
        // Already animating toward this exact size: let the spring finish.
        if let t = resizeTarget, resizeLink != nil,
           abs(t.height - size.height) < 0.5, abs(t.width - size.width) < 0.5 { return }
        guard abs(frame.height - size.height) > 0.5 || abs(frame.width - size.width) > 0.5 else { return }
        resizeLink?.invalidate()
        resizeLink = nil
        resizeTarget = nil

        // Hidden (alpha 0) means warm-up layout: snap so the panel opens at
        // full size instantly.
        if alphaValue == 0 {
            resizeVelocity = .zero
            var f = frame
            f.size = size
            setFrame(f, display: false)
            return
        }

        // SwiftUI's onGeometryChange reports only the final model height (one
        // callback per change, no animation frames), so the eased motion can't
        // be measured out of the layout. Instead the window runs the SAME
        // spring the content runs: Animation.smooth(duration:) is a critically
        // damped spring, x(t) = T + (x0-T)(1 + wt)e^(-wt) with w = 2*pi/d.
        // Same curve, same duration, started in the same runloop turn ->
        // window edge and curtain land on the same value every frame.
        // CADisplayLink, not a Timer: an unsynced timer beats against vsync,
        // and the tick that lands late forces its full layout pass past the
        // frame deadline (visible as a stutter). The link ticks once per
        // refresh of the display the panel is on, right after vsync.
        // Not animator(): NSWindow's frame animator runs on a background
        // thread and tears reads of pinnedTopY.
        guard let view = contentView ?? hostingView else {
            resizeVelocity = .zero
            var f = frame
            f.size = size
            setFrame(f, display: false)
            return
        }
        resizeOmega = 2 * Double.pi / Animation.panelResizeDuration
        resizeFrom = frame.size
        // Carry the on-screen momentum into the new spring. resizeVelocity is
        // zero when no spring ran (start from rest) and the last tick's true
        // velocity when one did, so bunched retargets (panel-open cascades, a
        // toggle interrupted mid-flight) stay continuous instead of popping.
        resizeV0 = resizeVelocity
        resizeStart = CACurrentMediaTime()
        resizeTarget = size
        let link = view.displayLink(target: self, selector: #selector(resizeTick(_:)))
        link.add(to: .main, forMode: .common)
        resizeLink = link
    }

    @objc private func resizeTick(_ link: CADisplayLink) {
        guard let target = resizeTarget else {
            link.invalidate()
            resizeLink = nil
            return
        }
        let dt = CACurrentMediaTime() - resizeStart
        let e = exp(-resizeOmega * dt)
        // Critically damped spring with initial velocity v0:
        // x(t) = T + (d0 + (v0 + w*d0) t) e^(-wt), d0 = x0 - T.
        func axis(_ from: Double, _ to: Double, _ v0: Double) -> (x: Double, v: Double) {
            let d0 = from - to
            let a = v0 + resizeOmega * d0
            return (x: to + (d0 + a * dt) * e,
                    v: (a - resizeOmega * (d0 + a * dt)) * e)
        }
        let h = axis(resizeFrom.height, target.height, resizeV0.height)
        let w = axis(resizeFrom.width, target.width, resizeV0.width)
        var f = frame
        if abs(h.x - target.height) < 0.25, abs(w.x - target.width) < 0.25 {
            link.invalidate()
            resizeLink = nil
            resizeTarget = nil
            resizeVelocity = .zero
            f.size = target
        } else {
            f.size = NSSize(width: w.x, height: h.x)
            resizeVelocity = CGSize(width: w.v, height: h.v)
        }
        setFrame(f, display: false)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var wakeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    /// Debounces panel re-anchoring across the storm of screen-param changes a
    /// display connect/disconnect fires (see screenObserver).
    private var repositionWorkItem: DispatchWorkItem?
    private var clickMonitor: Any?
    private var clickInterceptor: Any?
    // The NSMenu currently tracking (a SwiftUI Menu / context menu), captured so an
    // outside-panel click can cancel it the way native menus dismiss on click-away.
    private var trackingMenu: NSMenu?

    // One-time migration of legacy `fd.*` UserDefaults keys into the `crisp.*`
    // namespace. Declared above `displayManager` on purpose: stored-property
    // initializers run in declaration order, and DisplayManager() reads persisted
    // keys during init (reapplySavedModeIfNeeded etc.), so this must complete first.
    private let _defaultsMigrated = AppDelegate.migrateLegacyDefaultsNamespace()

    let displayManager = DisplayManager()
    private var statusItem: NSStatusItem?
    /// Drives the menu-bar Keep Awake indicator (keep-awake indicator).
    private var keepAwakeCancellable: AnyCancellable?
    private var keepAwakeBadge: NSView?
    private var panel: MenuPanel?
    /// The panel is NEVER ordered out once warmed: taking the backdrop surface
    /// off screen makes WindowServer replay its materialize bloom (the growing
    /// rectangle) on every reopen. Hidden = alpha 0 + click-through instead,
    /// so track shown-ness ourselves; isVisible stays true.
    private var isPanelShown = false

    /// Called after wake-from-sleep; wired in setupStartupBehavior.
    var onWake: (() -> Void)?

    /// One-time migration of legacy `fd.*` UserDefaults keys into the `crisp.*`
    /// namespace: copies each key to its `crisp.` counterpart (without clobbering an
    /// existing value) and drops the old one. Idempotent via a sentinel flag so
    /// existing installs keep their settings instead of resetting to defaults.
    @discardableResult
    static func migrateLegacyDefaultsNamespace() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "crisp.didMigrateLegacyDefaults") else { return false }
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("fd.") {
            let newKey = "crisp." + key.dropFirst(3)
            if defaults.object(forKey: newKey) == nil { defaults.set(value, forKey: newKey) }
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: "crisp.didMigrateLegacyDefaults")
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent duplicate launch via an exclusive file lock. Unlike consulting
        // NSWorkspace (whose entries linger during teardown and race with fast
        // relaunches), flock is released by the kernel the moment a process dies.
        let lockPath = NSTemporaryDirectory() + "crisp.lock"
        let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
        if lockFD == -1 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            exit(0)
        }
        // The descriptor stays open for the app's lifetime to hold the lock.

        // Start intercepting brightness keys to route them to the display under the cursor,
        // but only if Accessibility is already granted. Creating the tap (tapCreate) is what
        // surfaces the OS prompt, so gating on trust keeps launch prompt-free; new users opt
        // in via the toggle in the Brightness Keys section, which arms it in context. (jv1b)
        if AXIsProcessTrusted() {
            BrightnessKeyService.shared.start()
        } else {
            // AXIsProcessTrusted() is unreliable at the exact launch instant, especially right
            // after an upgrade while macOS re-validates the replaced bundle: a user who already
            // granted access in the prior version would otherwise have the tap silently never arm
            // (the launch check reads false, and nothing re-arms it since the opt-in toggle is
            // hidden once trust settles true). Re-check a couple of times as trust settles and arm
            // if it has; start() is idempotent, and this is bounded so users who never granted
            // don't poll forever. (upgrade zombie)
            for delay in [1.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if AXIsProcessTrusted() { BrightnessKeyService.shared.start() }
                }
            }
        }

        // Touch the singleton so auto-brightness polling starts at launch; otherwise
        // it only starts the first time the menu panel is opened (its only other ref).
        _ = AutoBrightnessService.shared

        // Re-establish Extra Brightness (EDR upscaling) for displays whose
        // toggle is persisted on. Deferred a beat so DisplayManager's initial
        // display list is populated.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            BrightnessBoostService.shared.reapplyAll()
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onWake?()
        }

        setupStartupBehavior()
        setupStatusItem()

        // Re-anchor the open panel when screens change: switching the main
        // display re-origins global coordinates, which would otherwise leave
        // the panel floating at a stale position.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPanelShown, self.panel != nil else { return }
                // A display connect/disconnect fires a storm of these, and the
                // geometry is garbage mid-flight: a just-connected virtual display
                // can transiently read as NSScreen.main, spiking maxContentHeight
                // (the panel balloons past its cap) and the x/anchor clamp (the
                // panel offsets). Debounce so we re-anchor ONCE, after the storm
                // settles, instead of sampling the volatile mid-reconfig state.
                self.repositionWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isPanelShown, let p = self.panel else { return }
                    self.positionPanel(p, preferOrigin: true)
                }
                self.repositionWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
        }

        // A SwiftUI `Menu` (row ⋯ buttons, context menus) opens an AppKit menu in
        // its own window outside the panel frame. Suppress the panel's outside-click
        // / resign-key dismissal while any menu tracks, so clicking a menu item that
        // spilled past the panel edge doesn't close the panel out from under it.
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] note in
            let menu = note.object as? NSMenu
            Task { @MainActor in
                PanelOpenGuard.isMenuTracking = true
                self?.trackingMenu = menu
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Outlast the outside-click monitor's own async main-actor hop
                // (which fired on the item's mouse-down) so it still sees tracking.
                try? await Task.sleep(nanoseconds: 150_000_000)
                PanelOpenGuard.isMenuTracking = false
                self?.trackingMenu = nil
            }
        }

        // Pre-warm the panel while hidden so the very first open, like every
        // reopen, appears at its final, settled size (fittingSize is only an
        // estimate; real layout can differ by a few points). Warm on the very
        // next runloop turn, not a 1s timer: a runloop turn is <16ms, but the
        // menu-bar icon isn't clickable until well after that, so the warm-up
        // (Liquid Glass materialize bloom + first layout) reliably finishes
        // hidden. On the 1s timer, a fast first click landed mid-warm and the
        // bloom + estimate reflow played on screen.
        DispatchQueue.main.async { [weak self] in
            self?.warmPanel()
        }

    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        BrightnessKeyService.shared.stop()
        // Drop EDR overlays and restore SDR on externals Crisp switched to HDR,
        // so no monitor is left bright with no boost and no DDC control.
        BrightnessBoostService.shared.prepareForTermination()
        // GammaService already handles CGDisplayRestoreColorSyncSettings via willTerminateNotification observer.
        VirtualDisplayService.shared.destroyAll()
    }

    // MARK: - Startup behavior (previously in CrispApp's task)

    private func setupStartupBehavior() {
        // Launching must never touch display state the user didn't ask for
        // (the inherited auto-arrange-external-above-builtin is gone).
        onWake = { [weak self] in
            guard let dm = self?.displayManager else { return }
            Task { @MainActor in
                // Give WindowServer 2 seconds to stabilize after wake before
                // touching display state.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                dm.refreshDisplays()
                // Re-disconnect any physical displays macOS re-enabled on wake.
                await PhysicalDisplayToggleService.shared.reapplyOnWake()
                dm.refreshDisplays()
                try? await Task.sleep(nanoseconds: 500_000_000)
                // WindowServer keeps settling for several seconds after wake: ICC
                // restore and link retraining can clobber a freshly applied transfer
                // table, which lost gamma adjustments until relaunch (issue #25).
                // Three passes with increasing delays so the last lands after the
                // churn; each is an idempotent no-op when state is already right.
                for delay: UInt64 in [0, 4_000_000_000, 8_000_000_000] {
                    try? await Task.sleep(nanoseconds: delay)
                    for display in dm.displays {
                        // Apply software brightness factor first so GammaService
                        // can read the up-to-date factor when it re-applies its formula.
                        BrightnessService.shared.reapplySoftwareBrightnessIfNeeded(for: display)
                        GammaService.shared.reapplyIfNeeded(for: display.displayID)
                        // Re-apply any custom resolution that macOS may have reset on wake
                        ResolutionService.shared.reapplySavedModeIfNeeded(for: display.displayID)
                    }
                }
                // Re-establish EDR boost overlays (Metal drawables and HDR
                // mode may not survive sleep).
                BrightnessBoostService.shared.reapplyAll()
            }
        }
    }

    // MARK: - Status item + panel

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Not "display": that's the native Displays module icon, two identical
        // icons in the menu bar is confusing. Screen-with-sparkles keeps the vibe.
        let icon = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: "Crisp")
        icon?.isTemplate = true
        item.button?.image = icon
        // Action stays wired for accessibility (AXPress); real clicks are
        // intercepted below and never reach the button.
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        // NSStatusBarButton's own click tracking force-clears its highlight at
        // mouse-up, which fights a persistent while-panel-open highlight
        // (flicker, or stuck off). Intercept clicks before the button sees
        // them: toggle directly, swallow the event so the button never tracks,
        // and showPanel/closePanel fully own the highlight. This also opens on
        // press with either button, like native menus. Cmd-clicks pass through
        // so the item can still be cmd-dragged.
        clickInterceptor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self,
                  let button = self.statusItem?.button,
                  event.window === button.window,
                  !event.modifierFlags.contains(.command) else { return event }
            self.togglePanel()
            return nil
        }
        statusItem = item

        // Overlay a small orange dot on the icon while Keep Awake is on, so it's visible at a
        // glance that sleep is being held. The base icon itself never changes. (keep-awake indicator)
        updateStatusIcon(active: KeepAwakeService.shared.isActive, animated: false)
        keepAwakeCancellable = KeepAwakeService.shared.$isActive
            .sink { [weak self] active in self?.updateStatusIcon(active: active, animated: true) }
    }

    /// Renders the status-bar icon for the given Keep Awake state. A hidden default
    /// (`crisp.debug.keepAwakeIconStyle` = "tint" | "badge") selects how "on" is shown, so
    /// the two can be compared live; default is tint. (keep-awake indicator)
    /// Fades a small orange dot in/out over the (unchanged) menu-bar icon to reflect Keep Awake.
    /// Only the dot animates; the base symbol stays put. (keep-awake indicator)
    private func updateStatusIcon(active: Bool, animated: Bool) {
        guard let button = statusItem?.button else { return }
        let badge = keepAwakeBadge ?? makeKeepAwakeBadge(on: button)
        keepAwakeBadge = badge
        let target: CGFloat = active ? 1 : 0
        guard animated else { badge.alphaValue = target; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            badge.animator().alphaValue = target
        }
    }

    /// A small orange dot pinned to the icon's bottom-right corner, layer-backed so its alpha can
    /// animate. Starts hidden (alpha 0); updateStatusIcon fades it in when Keep Awake turns on.
    /// (keep-awake indicator)
    private func makeKeepAwakeBadge(on button: NSStatusBarButton) -> NSView {
        let d: CGFloat = 6
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        dot.layer?.cornerRadius = d / 2
        dot.alphaValue = 0
        dot.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: d),
            dot.heightAnchor.constraint(equalToConstant: d),
            dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
            dot.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -2),
        ])
        return dot
    }

    private var isWarmed = false
    /// False until the panel has been shown once this launch. The first show fades
    /// in to mask one-time on-screen costs; later shows are instant.
    private var hasShownOnce = false

    private func warmPanel() {
        let p = panel ?? makePanel()
        panel = p
        guard !isWarmed else { return }
        isWarmed = true
        // The hosting view lives INSIDE a plain container, never as the
        // window contentView: as contentView, NSHostingView installs its own
        // window-sizing machinery that snaps the frame back to content size
        // on every layout pass, fighting the unfurl and any manual resize.
        let hosting = NSHostingView(rootView: PanelRootView(displayManager: displayManager))
        let size = hosting.fittingSize
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        // Clip the whole container to the panel shape: the glass view's
        // square bounds otherwise peek past the rounded corners (double edge).
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.masksToBounds = true
        // The menu backdrop fills the WINDOW (not the content), so while the
        // window height animates the glass always reaches the bottom edge.
        // macOS 26 Liquid Glass, the material Control Center panels actually
        // use (no NSVisualEffectView grade matches it). Its materialize bloom
        // plays only when the view first comes on screen, which happens once
        // during hidden warm-up; the panel never orders out afterwards.
        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: container.bounds)
            glass.cornerRadius = 16
            backdrop = glass
        } else {
            // Pre-Tahoe: .popover is the translucent grade native menus and
            // Control Center panels show on macOS 15.
            let material = NSVisualEffectView(frame: container.bounds)
            material.material = .popover
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 16
            material.layer?.masksToBounds = true
            backdrop = material
        }
        backdrop.autoresizingMask = [.width, .height]
        container.addSubview(backdrop)
        // The hosting view is a fixed, oversized canvas glued to the window
        // top and extending far past the bottom edge; the window edge simply
        // reveals or clips it. Because it NEVER resizes with the window,
        // animated height changes cause zero SwiftUI re-layout and no
        // transient content shifts at the top.
        let canvasHeight: CGFloat = 2400
        hosting.frame = NSRect(x: 0, y: container.bounds.height - canvasHeight,
                               width: size.width, height: canvasHeight)
        hosting.autoresizingMask = [.minYMargin]
        container.addSubview(hosting)
        p.hostingView = hosting
        p.lastContentSize = size
        p.setFrame(NSRect(origin: NSPoint(x: 0, y: -4000), size: size), display: false)
        p.contentView = container
        p.layoutIfNeeded()
        // Bring the surface on screen invisibly so the backdrop's one-time
        // materialize animation plays now, while nobody can see it.
        p.alphaValue = 0
        p.ignoresMouseEvents = true
        p.orderFrontRegardless()
    }

    @objc private func togglePanel() {
        if isPanelShown {
            closePanel()
        } else {
            showPanel()
        }
    }

    /// Anchors the panel under the status item on whatever screen it lives
    /// on. Called on open AND whenever screen parameters change (e.g. the
    /// main display switches, which re-origins global coordinates and would
    /// otherwise leave the panel at a stale position).
    /// Display the open panel was summoned on, by stable UUID (displayIDs are
    /// reassigned across a soft-reconnect). When that display blanks, the status
    /// item's window migrates to a surviving display and the post-storm reposition
    /// would drag the panel there for good; `preferOrigin` re-anchors to this
    /// display once it's back online.
    private var panelOriginDisplayUUID: String?

    private func displayUUID(for displayID: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) as String
    }

    private func positionPanel(_ p: MenuPanel, preferOrigin: Bool = false) {
        let size = p.lastContentSize ?? p.frame.size
        guard let btnWindow = statusItem?.button?.window else { return }
        let btnFrame = btnWindow.frame
        let btnScreen = btnWindow.screen ?? NSScreen.main
        var screen = btnScreen
        var anchorMidX = btnFrame.midX
        var topY = btnFrame.minY - 1
        // After a reconnect storm, prefer the display the panel was opened on if
        // it's online again. The menu bar mirrors across displays, so mirror the
        // status item's offset from the right edge onto the origin screen.
        if preferOrigin,
           let uuid = panelOriginDisplayUUID,
           let bs = btnScreen,
           let origin = NSScreen.screens.first(where: { displayUUID(for: $0.displayID) == uuid }),
           origin != bs {
            screen = origin
            anchorMidX = origin.frame.maxX - (bs.frame.maxX - btnFrame.midX)
            topY = origin.visibleFrame.maxY - 1
        }
        displayManager.activePanelDisplayID = screen?.displayID
        var x = anchorMidX - size.width / 2
        if let vis = screen?.visibleFrame {
            x = min(max(x, vis.minX + 8), vis.maxX - size.width - 8)
        }
        if let vis = screen?.visibleFrame {
            // Cap like the native Wi-Fi panel: grow to ~80% of the drop below
            // the status item, then scroll, leaving real breathing room at
            // the screen bottom instead of touching it.
            PanelMetrics.maxContentHeight = max(400, (topY - vis.minY) * 0.8)
        }
        p.pinnedTopY = nil
        p.setFrame(NSRect(x: x, y: topY - size.height, width: size.width, height: size.height),
                   display: false)
        p.pinnedTopY = topY
    }

    private func showPanel() {
        // Content stays alive across opens (warm is a no-op after the first
        // call) so nothing mounts or animates in at open time; per-open state
        // refresh happens below instead.
        warmPanel()
        guard let p = panel else { return }

        // Native menus appear at full size with all content visible at once;
        // only size changes AFTER opening animate.
        positionPanel(p)
        // Remember where this open happened (fresh each open; the menu bar the
        // user clicked is the anchor, not wherever a previous open ended up).
        panelOriginDisplayUUID = displayManager.activePanelDisplayID.flatMap { displayUUID(for: $0) }

        p.ignoresMouseEvents = false
        // First open only: fade in briefly so the panel's one-time on-screen costs
        // (Liquid Glass materialize bloom, first backdrop sample, first rasterization)
        // play under the fade instead of glitching in visibly, the way native menus'
        // appearance animation masks the same cost. The offscreen/alpha-0 warm-up can't
        // pre-play them (glass only materializes when genuinely on screen). The panel
        // sits at alpha 0 (warm-up / last close), so this is a clean 0 -> 1; every later
        // open stays instant (duration 0), replacing any in-flight close fade.
        let appearDuration: TimeInterval = hasShownOnce ? 0 : 0.12
        hasShownOnce = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = appearDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }
        p.orderFrontRegardless()
        p.makeKey()
        isPanelShown = true
        // Native items keep the menu bar button highlighted while their panel
        // is open. Safe to set synchronously: the click never starts the
        // button's own tracking (the interceptor swallowed it), so nothing
        // resets this behind our back.
        statusItem?.button?.highlight(true)

        // Re-sync views that mirror live external state (e.g. the system auto-brightness
        // toggle) on every open; the panel content mounts once, so their .onAppear
        // won't re-fire here.
        NotificationCenter.default.post(name: .crispPanelDidOpen, object: nil)

        PanelOpenGuard.openedAt = Date()
        // Re-check for updates on open so a long-running instance surfaces a new
        // release without a restart (the panel view mounts once, so its launch
        // .task can't). checkForUpdates() self-throttles to one network call per
        // hour, so opening the menu repeatedly costs nothing.
        Task { await UpdateService.shared.checkForUpdates() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isPanelShown else { return }
            CoreBrightnessService.shared.refresh()
            for display in self.displayManager.displays {
                Task { await BrightnessService.shared.refreshBrightness(for: display) }
            }
        }

        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let p = self.panel else { return }
                    // Don't dismiss while our own admin auth dialog is up: those
                    // clicks land in SecurityAgent (outside the panel). Same for a
                    // tracking menu whose items spill outside the panel frame, or an
                    // in-panel confirmation alert awaiting a choice.
                    // A menu is tracking: an outside-panel click should dismiss the
                    // MENU the way native menus do, but keep the panel open. Clicks
                    // on the menu itself go to our own menu window and never reach
                    // this global monitor, so selecting an item (even one spilled
                    // past the panel edge) is unaffected.
                    if PanelOpenGuard.isMenuTracking {
                        if !p.frame.contains(NSEvent.mouseLocation) {
                            self.trackingMenu?.cancelTracking()
                        }
                        return
                    }
                    if PanelOpenGuard.suppressAutoDismiss
                        || PanelOpenGuard.isConfirmationActive { return }
                    // Global monitors normally fire only for clicks landing in
                    // OTHER apps (= outside the panel). But during the dark
                    // mode crossfade the system's snapshot overlay intercepts
                    // every click, so an inside click arrives here too; close
                    // only when the cursor is genuinely outside the panel.
                    if p.frame.contains(NSEvent.mouseLocation) { return }
                    self.closePanel()
                }
            }
        }
    }

    private func closePanel() {
        guard let p = panel, isPanelShown else { return }
        isPanelShown = false
        statusItem?.button?.highlight(false)
        // Hide with a quick fade, like native menus; never order out (see
        // isPanelShown comment). Click-through is immediate.
        p.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Hidden now: tell the content to collapse its tool/nav sections so the
            // next open is fresh. Skip if the panel was reopened during the fade.
            guard let self, !self.isPanelShown else { return }
            NotificationCenter.default.post(name: .crispPanelDidClose, object: nil)
        })
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    private func makePanel() -> MenuPanel {
        let p = MenuPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.level = .popUpMenu
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.animationBehavior = .none
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.transient, .ignoresCycle]
        p.delegate = self
        p.onCancel = { [weak self] in self?.closePanel() }
        return p
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? MenuPanel) === panel {
            // Don't dismiss while our own admin auth dialog is up: it steals key
            // as it appears (the HiDPI override install prompt). Same for a
            // tracking menu or an in-panel confirmation alert, which take key.
            if PanelOpenGuard.suppressAutoDismiss || PanelOpenGuard.isMenuTracking
                || PanelOpenGuard.isConfirmationActive { return }
            // A soft-reconnect just settled: focus steals in its wake are system
            // noise, not the user clicking away (those still close via the global
            // click monitor, which ignores this grace).
            if Date() < PanelOpenGuard.resignKeyGraceUntil { return }
            // Same overlay caveat as the click monitor: during the crossfade
            // the snapshot window can steal key while the user is clicking
            // INSIDE the panel; don't treat that as clicking away.
            if let p = panel, p.frame.contains(NSEvent.mouseLocation) { return }
            closePanel()
        }
    }
}

/// Root SwiftUI view of the panel: menu content on the system glass backdrop.
struct PanelRootView: View {
    let displayManager: DisplayManager

    // Temporary probe: cadence of the root geometry callback vs the window's
    // actual height, to settle whether onGeometryChange delivers per-frame
    // eased values or one final value per change. Read with:
    //   log show --last 5m --predicate 'subsystem == "com.crisp.app" && category == "panelresize"'
    static let resizeLogger = Logger(subsystem: "com.crisp.app", category: "panelresize")

    var body: some View {
        // Top-aligned inside the window: if window and content ever disagree,
        // the excess window area is transparent below the glass instead of an
        // empty glass gap above the content.
        VStack(spacing: 0) {
            MenuBarView()
                .environmentObject(displayManager)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { size in
                    // Resize the window synchronously with content layout so the
                    // two can never disagree. MenuPanel re-anchors every frame
                    // change to its pinned top, so growth goes downward.
                    guard size.width > 0, size.height > 0,
                          let w = NSApp.windows.first(where: { $0 is MenuPanel }) as? MenuPanel else { return }
                    PanelRootView.resizeLogger.log("geo h=\(size.height, format: .fixed(precision: 1)) win=\(w.frame.height, format: .fixed(precision: 1))")
                    w.applyContentSize(size)
                }
        }
        // Top-glued: while the window is shorter than the content (the open
        // unfurl), the overflow extends below the window edge and is clipped,
        // instead of the content centering inside the short window.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
