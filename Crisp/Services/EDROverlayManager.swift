// Crisp/Services/EDROverlayManager.swift
import AppKit
import Metal
import QuartzCore

/// Fullscreen invisible EDR overlay per display that multiplies all content
/// beneath it into the HDR headroom, brightening the whole desktop beyond the
/// SDR maximum. Lifecycle mirrors NotchOverlayManager: one borderless
/// click-through window per CGDirectDisplayID, torn down when the screen goes
/// away. Content is a uniform EDR color (value > 1.0) in a CAMetalLayer with a
/// multiply compositing filter; it re-renders only when the factor changes, so
/// idle GPU cost is zero.
@MainActor
final class EDROverlayManager {
    static let shared = EDROverlayManager()

    private struct Overlay {
        let window: NSWindow
        let layer: CAMetalLayer
        var factor: Double
    }

    private var overlays: [CGDirectDisplayID: Overlay] = [:]
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var commandQueue = device?.makeCommandQueue()

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Apply a multiplier to a display. Once a window exists it stays alive
    /// even at factor 1.0 (identity): closing and reopening the EDR surface
    /// exits and re-enters EDR mode, which can visibly flash the display, so
    /// crossing the 100% boundary must not churn windows. Explicit teardown
    /// goes through removeOverlay. Returns false when an overlay was needed
    /// but could not be created (no Metal device, no screen), so callers can
    /// revert the toggle.
    @discardableResult
    func setFactor(_ factor: Double, for displayID: CGDirectDisplayID) -> Bool {
        let clamped = max(1.0, factor)
        if overlays[displayID] == nil {
            // Nothing to show and nothing to keep alive.
            guard clamped > 1.001 else { return true }
            guard makeOverlay(for: displayID) else { return false }
        }
        guard var overlay = overlays[displayID] else { return false }
        // Skip sub-0.5% changes to avoid pointless re-renders during fades.
        guard abs(overlay.factor - clamped) > 0.005 else { return true }
        overlay.factor = clamped
        overlays[displayID] = overlay
        render(overlay)
        return true
    }

    func removeOverlay(for displayID: CGDirectDisplayID) {
        overlays[displayID]?.window.close()
        overlays.removeValue(forKey: displayID)
    }

    func removeAll() {
        for id in Array(overlays.keys) { removeOverlay(for: id) }
    }

    /// Re-render every overlay (Metal drawables can be lost across sleep).
    func rerenderAll() {
        for overlay in overlays.values { render(overlay) }
    }

    private func makeOverlay(for displayID: CGDirectDisplayID) -> Bool {
        guard let screen = NSScreen.screen(for: displayID),
              let device else { return false }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        // One notch above the notch cover so multiply applies to everything;
        // multiplying the notch cover's black stays black, so order is safe
        // either way, but a deterministic z-order beats an ambient one.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.hasShadow = false

        let metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.isOpaque = false
        metalLayer.frame = CGRect(origin: .zero, size: screen.frame.size)
        // Uniform color: an 8x8 drawable scaled to fullscreen costs nothing.
        metalLayer.drawableSize = CGSize(width: 8, height: 8)
        metalLayer.compositingFilter = "multiplyBlendMode"

        let host = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        host.layer = metalLayer
        window.contentView = host
        window.orderFrontRegardless()

        overlays[displayID] = Overlay(window: window, layer: metalLayer, factor: 1.0)
        return true
    }

    private func render(_ overlay: Overlay) {
        guard let commandQueue,
              let drawable = overlay.layer.nextDrawable() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let f = overlay.factor
        pass.colorAttachments[0].clearColor = MTLClearColor(red: f, green: f, blue: f, alpha: 1.0)
        guard let cmd = commandQueue.makeCommandBuffer(),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    @objc private func screenParametersChanged() {
        var toRemove: [CGDirectDisplayID] = []
        for (displayID, overlay) in overlays {
            guard let screen = NSScreen.screen(for: displayID) else {
                overlay.window.close()
                toRemove.append(displayID)
                continue
            }
            overlay.window.setFrame(screen.frame, display: true)
            overlay.layer.frame = CGRect(origin: .zero, size: screen.frame.size)
        }
        for id in toRemove { overlays.removeValue(forKey: id) }
    }
}
