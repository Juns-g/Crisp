# Panel resize: the split-canvas architecture

Why Crisp's menu panel animates height the way it does. Every claim here was
established by instrumented experiment (os.log traces, spike apps) on macOS 26,
120Hz display, August 2026. Do not "simplify" this code without rereading the
failure map below; each rule exists because its absence produced a visible jump.

## The problem

Expanding or collapsing a section must animate the panel's height with the top
edge pinned under the status item, the content below the toggling section riding
the bottom edge, and zero visible jumps, at native look (real WindowServer
shadow, Liquid Glass, click-outside close). Apple's own Control Center does this
perfectly; every public API path we tried did not.

## Why the public paths fail

- **MenuBarExtra(.window)**: jumps on single unspammed clicks at any animation
  duration (tested 0.16s / 0.25s / 0.35s in an isolated spike). Also carries a
  WindowServer materialize animation that cannot be disabled.
- **NSAnimationContext window animator**: an unsynced timer. Dropped steps
  render as visible skips, worse at shorter durations.
- **NSHostingView.sizingOptions = .preferredContentSize**: resizes via
  setContentSize (origin fixed, so the panel grows upward) and fights any
  attempt to re-pin the top edge, producing shake.
- **Hand-driven per-frame SwiftUI layout**: SwiftUI animates renders, not
  layouts; driving layout per frame makes icons and text shimmer.
- Control Center is immune because its animations run out of process. In-process
  apps inherit the busy main runloop, and that is the root cause of everything
  below.

## The architecture

Two independent halves, connected only by block heights measured once.

**Canvas (SwiftUI, static).** Every block (section headers, section row groups,
footer) is its own NSHostingView, rendered ONCE at full size. SwiftUI never
animates geometry; nothing re-renders during a resize.

**Frame (AppKit, the only animator).** The window frame is the single animated
property. Blocks are positioned by autoresizing masks against the content view:

- Blocks above the active section: `[.width, .minYMargin]` (ride the top edge).
- The active section's rows sit inside a clip view with `[.width, .height]`,
  the one flexible region; the rows inside are `[.width, .minYMargin]`, glued
  to the clip's top so they reveal top-first, curtain style.
- Blocks below: `[.width]` (ride the bottom edge atomically via WindowServer).

"Moving the split" between sections is a mask flip only; no view moves, no
render happens. Cross-section toggles arriving mid-flight are queued until
settle. At rest, `restack()` sets exact integral frames for every block.

**FrameSpring (the driver).** A critically damped spring, closed form
`x(t) = T + (d0 + (v0 + w*d0) t) e^(-w t)` with `w = 2*pi/duration`
(0.18s), stepped by a CADisplayLink and applied via
`setFrame(x, topY - h, w, h)` so the top edge never moves. Retargets carry
velocity, so mid-flight direction changes are C1-continuous.

## The failure map

Every rule in FrameSpring, with the log line that forced it:

1. **Never anchor animation to wall time at start.** The first display-link
   tick after a click arrived 74.2ms late (runloop busy processing the click);
   a wall-time spring then teleported 82pt in the first painted frame.
2. **Never create the display link on demand.** A freshly created link's first
   callback arrived 65.9ms late, rendering as freeze-then-24pt-step even with
   gap clamping. The link is created once at panel warm-up and never
   invalidated; idle ticks are no-ops.
3. **Advance the spring by exactly one refresh period per tick, never by
   elapsed wall time.** A single missed vsync (main thread in SwiftUI tap
   handling) doubled the painted step: dh went 12, 34, 17 across a 16.6ms gap.
   Frame-paced time makes a doubled step impossible; a missed vsync costs one
   frame of duration instead. Verified live: a 15.1ms gap under spam produced
   an on-curve dh=6.
4. **Set only integral frames.** AppKit re-rounds fractional window frames
   asynchronously (we set 280.3, the frame read back 281.0), so sub-point sets
   fight the rounder near the settle tail. The spring computes continuously
   and rounds at setFrame; the anchor topY and x are rounded once at animate.
5. **Measure block heights only after a forced layout pass.**
   `NSHostingView.fittingSize` straight after init is nondeterministic; one
   launch measured section A's rows at section B's height, creating a 56pt
   debt collected as a visible jump two toggles later. `layoutSubtreeIfNeeded`
   before `fittingSize`, and re-measure on every panel open.
6. **Pre-paint every block during warm-up.** Rows that have never been drawn
   paint their first reveal a frame late (a flash of empty glass). The
   invisible warm-up opens all sections off screen, forces one display pass,
   then closes them.
7. **Never swap the hosting view's rootView to move the split.** The async
   SwiftUI re-render lands one frame behind the AppKit framing, which is a
   jump. Masks flip; views never rebuild.

## Validation

Spike app (`Spike2`, scratchpad, not in repo) with full per-tick logging:
135 animations / 3032 ticks of adversarial spamming produced zero painted
steps off-curve, zero external frame writes, and the user could no longer
provoke a jump by hand. The MenuBarExtra control spike (`Spike`) documents
that the standard path jumps on this hardware, closing the question of
migrating onto MenuBarExtra.
