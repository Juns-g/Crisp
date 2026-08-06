import AppKit
import SwiftUI
import os.log

// The split-canvas panel resize engine. Architecture and the failure map that
// forced every rule here: docs/panel-resize.md. In short: the window frame is
// the ONLY animator; SwiftUI never animates geometry; blocks are stacked by
// explicit integral frames each tick, so content below a toggling section
// rides the window edge atomically.

/// Top-left origin so blocks stack downward from the pinned top edge and a
/// clip's height change reveals its content top-first, curtain style.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        // The canvas sets every frame explicitly; skip AppKit's per-resize
        // autoresize pass and frame-change notifications (measurable per-tick
        // cost with a dozen containers resizing at 120Hz).
        autoresizesSubviews = false
        postsFrameChangedNotifications = false
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The scrollable region (everything above the footer). Manual offset scroll:
/// no elastic, no indicators, matching how the panel's ScrollView behaved.
/// ponytail: raw wheel deltas only; add momentum if it ever feels off.
final class PanelViewport: FlippedView {
    var onScroll: ((CGFloat) -> Void)?
    var isScrollable: () -> Bool = { false }
    override func scrollWheel(with event: NSEvent) {
        guard isScrollable() else { return }
        onScroll?(event.scrollingDeltaY)
    }
}

/// Vsync-locked critically damped spring on a scalar (the blocks' total
/// height). Every rule is load-bearing (docs/panel-resize.md):
/// frame-paced time (one refresh period per tick, never wall time), a link
/// created once and never invalidated, velocity carry across retargets.
final class FrameSpring: NSObject {
    private var link: CADisplayLink?
    private var active = false
    private var lastTick: CFTimeInterval = 0
    private var t: Double = 0
    private var from: Double = 0
    private var target: Double = 0
    private var v0: Double = 0
    private(set) var velocity: Double = 0
    private let omega = 2 * Double.pi / Animation.panelResizeDuration
    var onTick: ((Double) -> Void)?
    var onSettle: (() -> Void)?

    func warm(view: NSView) {
        guard link == nil else { return }
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func animate(from f: CGFloat, to tg: CGFloat) {
        from = Double(f)
        target = Double(tg)
        v0 = velocity
        t = 0
        active = true
    }

    func cancel() {
        active = false
        velocity = 0
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        let gap = (now - lastTick) * 1000
        lastTick = now
        guard active else { return }
        // Wall-clock time clamped to a short catch-up window. A single missed
        // vsync advances full wall time (temporally correct, no speed error);
        // a genuine stall cannot teleport (clamp). Pure frame-pacing ran at
        // HALF speed through sustained 60Hz stretches (tall panel, per-tick
        // cost near the budget) and snapped to full speed when ticks
        // recovered, which read as a jump.
        t += min(gap / 1000, 0.021)
        let e = exp(-omega * t)
        let d0 = from - target
        let a = v0 + omega * d0
        let x = target + (d0 + a * t) * e
        if abs(x - target) < 0.25 {
            active = false
            velocity = 0
            onTick?(target)
            PanelCanvas.log.log("settle gap=\(gap, format: .fixed(precision: 1))ms")
            onSettle?()
        } else {
            velocity = (a - omega * (d0 + a * t)) * e
            let start = CACurrentMediaTime()
            onTick?(x)
            let cost = (CACurrentMediaTime() - start) * 1000
            PanelCanvas.log.log("tick gap=\(gap, format: .fixed(precision: 1))ms x=\(x, format: .fixed(precision: 1)) cost=\(cost, format: .fixed(precision: 1))ms")
        }
    }
}

/// One block of panel content: a SwiftUI hosting view at its natural size
/// inside a clip whose height animates between 0 and the content height.
/// Fixed (always visible) blocks are just clips whose isOpen is always true;
/// their height still animates when their CONTENT height changes (a preset
/// added, a nested reveal inside Settings).
@MainActor
final class PanelBlock {
    let id: String
    let clip: FlippedView
    let host: NSView
    var contentHeight: CGFloat = 0
    let isOpen: () -> Bool
    /// Displayed clip height right now (animates toward `target`).
    var current: CGFloat = 0
    var target: CGFloat { isOpen() ? contentHeight : 0 }

    init(id: String, host: NSView, isOpen: @escaping () -> Bool) {
        self.id = id
        self.host = host
        self.isOpen = isOpen
        clip = FlippedView(frame: .zero)
        clip.addSubview(host)
    }
}

/// Owns the block stack, the scroll viewport, the footer, and the spring, and
/// keeps window frame + block frames consistent every tick.
@MainActor
final class PanelCanvas {
    static let log = Logger(subsystem: "com.crisp.app", category: "panelcanvas")
    /// For the spring's tick log sub-timings (single instance in practice).
    static weak var shared: PanelCanvas?

    let width: CGFloat = 308
    private let topInset: CGFloat = 8
    private let docTopInset: CGFloat = 4
    private let docBottomInset: CGFloat = 4

    private(set) var blocks: [PanelBlock] = []
    private var footer: PanelBlock?
    let viewport = PanelViewport(frame: .zero)
    let doc = FlippedView(frame: .zero)
    private let spring = FrameSpring()
    private weak var panel: NSPanel?
    var isShown: () -> Bool = { false }

    /// Screen-space anchor of the pinned top edge, set by positionPanel.
    private var anchorTopY: CGFloat = 0
    private var anchorX: CGFloat = 0

    private var animFrom: [CGFloat] = []
    /// Targets CAPTURED at animate start. Per-tick math must never read the
    /// live block targets: a mid-flight toggle flips them synchronously, and
    /// interpolating toward a new target with the old progress teleports the
    /// block in one frame. Mid-flight changes re-anchor via requestApply
    /// (velocity carry) instead.
    private var animTarget: [CGFloat] = []
    private var animTargetSum: CGFloat = 0
    private var animFromSum: CGFloat = 0
    private var scrollOffset: CGFloat = 0
    private var animatePending = false
    /// Window height last handed to setFrame; a mismatch at the next layout
    /// means someone else resized the window (EXT in the log).
    private var lastSetWindowH: CGFloat = -1
    /// Sub-timings of the last layoutNow, for the tick log.
    private(set) var lastLoopMs: Double = 0
    private(set) var lastWinMs: Double = 0
    /// True only during the warm-up pre-paint, so every block lies inside the
    /// viewport and genuinely draws once (a capped viewport would leave the
    /// lower blocks unpainted, defeating the pre-paint).
    private var ignoreCap = false

    func install(shell: NSView, panel: NSPanel) {
        PanelCanvas.shared = self
        self.panel = panel
        viewport.addSubview(doc)
        shell.addSubview(viewport)
        viewport.onScroll = { [weak self] delta in
            guard let self else { return }
            self.scrollOffset -= delta
            self.layoutNow()
        }
        viewport.isScrollable = { [weak self] in
            guard let self else { return false }
            return self.doc.frame.height > self.viewport.frame.height + 0.5
        }
        spring.warm(view: shell)
        spring.onTick = { [weak self] x in self?.applyScalar(CGFloat(x)) }
        spring.onSettle = { [weak self] in
            guard let self, self.animTarget.count == self.blocks.count else { return }
            for (i, b) in self.blocks.enumerated() { b.current = self.animTarget[i] }
            self.layoutNow()
        }
    }

    func setBlocks(_ newBlocks: [PanelBlock], footer newFooter: PanelBlock) {
        for b in blocks { b.clip.removeFromSuperview() }
        footer?.clip.removeFromSuperview()
        blocks = newBlocks
        footer = newFooter
        for b in blocks { doc.addSubview(b.clip) }
        if let shell = viewport.superview { shell.addSubview(newFooter.clip) }
        measureAll()
        for b in blocks { b.current = b.target }
        footer?.current = footer?.target ?? 0
    }

    /// fittingSize straight after init is nondeterministic; force a layout
    /// pass first (failure map item 5). SwiftUI's geometry reporting keeps
    /// heights fresh from then on.
    func measureAll() {
        for b in blocks + [footer].compactMap({ $0 }) {
            b.host.layoutSubtreeIfNeeded()
            b.contentHeight = b.host.fittingSize.height
        }
    }

    /// SwiftUI reported a block's natural height (initial layout, a nested
    /// reveal mid-animation, presets changing). Fires per frame during nested
    /// SwiftUI animations; the spring retargets each time with velocity carry.
    func contentChanged(_ id: String, height: CGFloat) {
        // height 0 is legitimate (the update row while no update is known).
        if let f = footer, f.id == id {
            guard abs(f.contentHeight - height) > 0.5 else { return }
            f.contentHeight = height
            f.current = height
            requestApply()
            return
        }
        guard let b = blocks.first(where: { $0.id == id }),
              abs(b.contentHeight - height) > 0.5 else { return }
        b.contentHeight = height
        requestApply()
    }

    /// Section state changed (or content resized): animate to targets when the
    /// panel is visible, snap silently when hidden. Coalesces bursts (one
    /// user action can flip several published properties).
    func requestApply() {
        guard !animatePending else { return }
        animatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.animatePending = false
            self.isShown() ? self.animateToTargets() : self.snapToTargets()
        }
    }

    func snapToTargets() {
        spring.cancel()
        for b in blocks { b.current = b.target }
        if let f = footer { f.current = f.target }
        layoutNow()
    }

    private func animateToTargets() {
        let fromSum = blocks.reduce(0) { $0 + $1.current }
        let targetSum = blocks.reduce(0) { $0 + $1.target }
        if let f = footer { f.current = f.target }
        guard abs(targetSum - fromSum) > 0.5 else {
            // No net height change (or nothing moved): settle exactly.
            for b in blocks { b.current = b.target }
            layoutNow()
            return
        }
        animFrom = blocks.map { $0.current }
        animTarget = blocks.map { $0.target }
        animFromSum = fromSum
        animTargetSum = targetSum
        PanelCanvas.log.log("animate from=\(fromSum, format: .fixed(precision: 1)) to=\(targetSum, format: .fixed(precision: 1)) v0=\(self.spring.velocity, format: .fixed(precision: 1))")
        spring.animate(from: fromSum, to: targetSum)
    }

    private func applyScalar(_ x: CGFloat) {
        let denom = animTargetSum - animFromSum
        guard abs(denom) > 0.001, animFrom.count == blocks.count,
              animTarget.count == blocks.count else { return }
        let s = (x - animFromSum) / denom
        for (i, b) in blocks.enumerated() {
            let exact = animFrom[i] + s * (animTarget[i] - animFrom[i])
            b.current = min(max(exact, 0), b.contentHeight)
        }
        layoutNow()
    }

    /// The one layout function: stacks blocks with cumulative integral
    /// rounding (sums stay exact, no per-block jitter), then derives the
    /// window frame. Only integral frames reach AppKit (failure map item 4).
    func layoutNow() {
        guard let panel else { return }
        let t0 = CACurrentMediaTime()
        var cursor = docTopInset
        var exact = docTopInset
        for b in blocks {
            exact += b.current
            let y = exact.rounded()
            let h = y - cursor
            let clipR = NSRect(x: 0, y: cursor, width: width, height: h)
            if b.clip.frame != clipR { b.clip.frame = clipR }
            let hostR = NSRect(x: 0, y: 0, width: width, height: b.contentHeight.rounded(.up))
            if b.host.frame != hostR { b.host.frame = hostR }
            cursor = y
        }
        let docH = cursor + docBottomInset
        let footerH = (footer?.current ?? 0).rounded()
        let cap = ignoreCap ? CGFloat.greatestFiniteMagnitude : PanelMetrics.maxContentHeight.rounded()
        let viewportH = min(docH, cap)
        let windowH = topInset + viewportH + footerH

        if lastSetWindowH >= 0, abs(panel.frame.height - lastSetWindowH) > 0.01 {
            PanelCanvas.log.log("EXT frame=\(panel.frame.height, format: .fixed(precision: 1)) expected=\(self.lastSetWindowH, format: .fixed(precision: 1))")
        }
        scrollOffset = min(max(scrollOffset, 0), max(0, docH - viewportH))
        let docR = NSRect(x: 0, y: -scrollOffset, width: width, height: docH)
        if doc.frame != docR { doc.frame = docR }
        // Shell is non-flipped: footer hugs the bottom, viewport spans from
        // 8pt below the top edge down to the footer.
        let vpR = NSRect(x: 0, y: footerH, width: width, height: viewportH)
        if viewport.frame != vpR { viewport.frame = vpR }
        if let f = footer {
            let fR = NSRect(x: 0, y: 0, width: width, height: footerH)
            if f.clip.frame != fR { f.clip.frame = fR }
            let fhR = NSRect(x: 0, y: 0, width: width, height: f.contentHeight.rounded(.up))
            if f.host.frame != fhR { f.host.frame = fhR }
        }
        let t1 = CACurrentMediaTime()
        let prevH = panel.frame.height
        // display: false. A synchronous redraw per tick (display: true) cost
        // ~6ms on a tall panel, blowing the 8.3ms budget and dropping the
        // link to 60Hz (half-speed motion, doubled per-frame steps). Core
        // Animation commits the window frame and every moved layer in the
        // same transaction, so the resize stays atomic.
        panel.setFrame(NSRect(x: anchorX, y: anchorTopY - windowH,
                              width: width, height: windowH),
                       display: false)
        lastSetWindowH = windowH
        lastLoopMs = (t1 - t0) * 1000
        lastWinMs = (CACurrentMediaTime() - t1) * 1000
        if lastLoopMs + lastWinMs > 3 {
            PanelCanvas.log.log("slowlayout loop=\(self.lastLoopMs, format: .fixed(precision: 1))ms win=\(self.lastWinMs, format: .fixed(precision: 1))ms")
        }
        if abs(windowH - prevH) > 0.5 {
            PanelCanvas.log.log("frame h=\(windowH, format: .fixed(precision: 1)) dh=\(windowH - prevH, format: .fixed(precision: 1))")
        }
    }

    func setAnchor(topY: CGFloat, x: CGFloat) {
        anchorTopY = topY.rounded()
        anchorX = x.rounded()
    }

    /// Warm-up pre-paint: draw every block once while the panel is invisible
    /// so no first reveal is ever a first paint (failure map item 6).
    func prePaint() {
        ignoreCap = true
        for b in blocks { b.current = b.contentHeight }
        footer?.current = footer?.contentHeight ?? 0
        layoutNow()
        panel?.display()
        ignoreCap = false
        snapToTargets()
    }
}
