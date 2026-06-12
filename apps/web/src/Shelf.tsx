import { useEffect, useRef, useState } from "react";
import { coverGradient } from "./utils";
import { SHELF_MAX_SLOTS, type ShelfItem } from "./shelf";

/* THE SHELF — pins + recents as a record crate on Home.
   A row of square 12" covers standing on a floor, receding in 3D. Every
   sleeve leans the SAME way — one continuous direction, like records in a
   crate viewed from one side. The focused card faces the viewer most; cards
   ahead of it (right) recede slot by slot; cards behind it (left) are the
   flipped-past end of the stack — packed tighter, pushed deeper, faded
   quieter. Pure CSS 3D — transforms + opacity only, transitions do the
   travel, no rAF.

   Hit model: each card <button> is a FLAT 2D-positioned strip (translateX +
   zIndex in painter's order); the 3D pose is applied to an inner, inert
   .shelf-card-face with its own local perspective() — visually one crate,
   but clicks resolve through ordinary 2D stacking, never the browser's 3D
   depth hit-testing.

   Three-click state machine (focus → pull → open):
     1. click an unfocused card  → it eases into focus
     2. click the focused card   → PULL-OUT (slides up + toward viewer)
     3. click the pulled card    → onOpen(item) navigates
   Esc / click anywhere else while pulled → slips back into the crate.
   ←/→ move focus, Enter advances the same progression (cards are buttons).
   Dragging horizontally across the band flips through the crate (one slot
   per card-spacing of travel); a horizontal two-finger trackpad scroll does
   the same. With more records than one visible window holds, the crate
   LOOPS — flipping past the last record wraps to the first in both
   directions, so the band is consistently filled at every position (poses
   come from the shortest wrap distance, not raw index distance). With few
   records the ends stay real and drags rubber-band past them. A real drag
   (>6px) suppresses the click that fires on release, so it never doubles
   as focus/pull. */

function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(
    () => typeof window !== "undefined" && "matchMedia" in window && window.matchMedia(query).matches,
  );
  useEffect(() => {
    const mq = window.matchMedia(query);
    const onChange = () => setMatches(mq.matches);
    mq.addEventListener?.("change", onChange);
    return () => mq.removeEventListener?.("change", onChange);
  }, [query]);
  return matches;
}

type Pose = { x: number; z: number; ry: number; fade: number; tuck: number };

type CrateGeometry = { spacing: number; focusGap: number; backSpacing: number; backGap: number };

/** Crate pose for a card `d` slots from focus — ONE continuous lean.
 *  Focused: a gentle −18°. Ahead (d > 0): falls back toward a −66° cap as it
 *  recedes. Behind (d < 0): the SAME lean direction, but these are the
 *  already-flipped records — pushed deeper (z −60… vs −26…), packed tighter,
 *  and faded, so the left side reads as the back of the same run, never a
 *  mirrored book-end. Both sides extrapolate past slot 4 (the adaptive window
 *  can extend either run when the other side has no items): z keeps sinking,
 *  the lean eases toward −66°, opacity keeps falling to a 0.3 floor — never
 *  a flat run of identical slivers. `fade` is the at-rest card opacity;
 *  `tuck` (0…1) quiets sleeve initials/type on strongly receded cards. */
function cardPose(d: number, g: CrateGeometry): Pose {
  if (d === 0) return { x: 0, z: 90, ry: -18, fade: 1, tuck: 0 };
  const abs = Math.abs(d);
  if (d > 0) {
    return {
      x: g.focusGap + (abs - 1) * g.spacing,
      z: -26 * Math.min(abs, 4) - Math.max(0, abs - 4) * 9, // keeps sinking past slot 4
      ry: -18 - Math.min(8 + abs * 11, 40) - Math.min(Math.max(0, abs - 3) * 2, 8), // −37, −48, −58 … −66 cap
      fade: Math.max(0.3, 1 - (abs - 1) * 0.08), // 1, 0.92 … falls to a 0.3 floor
      tuck: Math.min(1, (abs - 1) * 0.3),
    };
  }
  return {
    x: -(g.backGap + (abs - 1) * g.backSpacing),
    z: -60 - (Math.min(abs, 4) - 1) * 22 - Math.max(0, abs - 4) * 9, // −60, −82, −104, −126, then −9/slot
    ry: -50 - Math.min((abs - 1) * 6, 14) - Math.min(Math.max(0, abs - 4), 2), // −50, −56, −62, −64 … −66 cap
    fade: Math.max(0.3, 0.8 - (abs - 1) * 0.15), // 0.8, 0.65 … falls to a 0.3 floor
    tuck: Math.min(1, 0.45 + (abs - 1) * 0.3),
  };
}

/** Display offset of card `i` from `focus` on a LOOPING crate: the wrap-
 *  forward (ahead) distance while it fits the ahead budget, else negative —
 *  the card sits behind focus via the wrap. Every card gets a distinct
 *  offset, biased to match the asymmetric visible window (more ahead than
 *  behind), so both sides of focus are always populated and flipping past
 *  either end just keeps going. */
function loopDelta(i: number, focus: number, n: number, aheadBudget: number): number {
  const ahead = (((i - focus) % n) + n) % n;
  return ahead <= aheadBudget ? ahead : ahead - n;
}

/** 1–2 quiet initials for the sleeve face — never an identical blank. */
function sleeveInitials(title: string): string {
  const words = title.trim().split(/\s+/).filter(Boolean);
  if (words.length === 0) return "·";
  if (words.length === 1) return words[0].slice(0, 2).toUpperCase();
  return (words[0][0] + words[1][0]).toUpperCase();
}

export function Shelf({ items, onOpen }: { items: ShelfItem[]; onOpen: (item: ShelfItem) => void }) {
  const slots = items.slice(0, SHELF_MAX_SLOTS);
  const [focus, setFocus] = useState(0);
  const [pulled, setPulled] = useState(false);
  const [hovered, setHovered] = useState<number | null>(null);
  const [rubber, setRubber] = useState(0); // px of give past the crate ends mid-drag
  const [bandW, setBandW] = useState(0); // measured band width — clip guard
  const reduced = useMediaQuery("(prefers-reduced-motion: reduce)");
  const narrow = useMediaQuery("(max-width: 720px)");
  const rootRef = useRef<HTMLElement | null>(null);
  const stageRef = useRef<HTMLDivElement | null>(null);
  const cardRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const dragRef = useRef<{ id: number; startX: number; anchor: number; active: boolean } | null>(null);
  const suppressClick = useRef(false);
  const wheelAcc = useRef(0);
  // Previous focus, committed AFTER every render — seam detection compares
  // each card's wrap distance under the old vs. new focus. A card whose
  // distance jumps by more than half the crate crossed the loop seam (e.g.
  // d −8 → +6 when focus wraps 14 → 0); its transform/opacity transition is
  // gated off for that render so it relocates instantly at the dim band
  // edge instead of streaking across the whole crate.
  const prevFocus = useRef(0);
  useEffect(() => {
    prevFocus.current = focus;
  });

  // Keep focus valid when the slot list shrinks (e.g. data refresh).
  useEffect(() => {
    if (focus > slots.length - 1) {
      setFocus(Math.max(0, slots.length - 1));
      setPulled(false);
    }
  }, [slots.length, focus]);

  // While pulled out: Esc or a press anywhere outside the pulled card slips
  // it back into the crate. The pulled card's own click is step 3 (open).
  useEffect(() => {
    if (!pulled) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setPulled(false);
    };
    const onPress = (e: MouseEvent) => {
      const pulledCard = cardRefs.current[focus];
      if (pulledCard && e.target instanceof Node && pulledCard.contains(e.target)) return;
      setPulled(false);
    };
    window.addEventListener("keydown", onKey);
    window.addEventListener("mousedown", onPress);
    return () => {
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("mousedown", onPress);
    };
  }, [pulled, focus]);

  // Measure the band: .shelf clips overflow, so any sleeve poking past the
  // edge renders as a cut-off sliver. The visible window below shrinks to
  // fit this width and crateShift centers it — nothing clips at any focus
  // index, including 0 and the last slot.
  useEffect(() => {
    const el = rootRef.current;
    if (!el || typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver((entries) => setBandW(entries[0].contentRect.width));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Two-finger trackpad scroll: horizontal-dominant wheel deltas over the
  // band flip focus, one slot per ~80px — wrapping mod n on a looping
  // crate, clamped at the ends on a small (non-looping) one. Vertical-
  // dominant wheels pass through untouched so the page keeps scrolling;
  // horizontal ones are consumed (no page pan / history swipe), which needs
  // a native non-passive listener — React's synthetic onWheel is passive.
  useEffect(() => {
    const el = stageRef.current;
    if (!el) return;
    const count = slots.length;
    const loop = count > (narrow ? 2 : 6) + (narrow ? 2 : 4) + 1; // mirrors `looping` below
    const onWheel = (e: WheelEvent) => {
      if (Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return;
      e.preventDefault();
      wheelAcc.current += e.deltaX;
      const steps = Math.trunc(wheelAcc.current / 80);
      if (steps === 0) return;
      wheelAcc.current -= steps * 80;
      setPulled(false);
      setHovered(null); // cards slide under a stationary cursor — pointerover won't refire
      setFocus((f) =>
        loop ? (((f + steps) % count) + count) % count : Math.min(count - 1, Math.max(0, f + steps)),
      );
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, [slots.length, narrow]);

  if (slots.length === 0) return null;

  const n = slots.length;
  const aheadBudget = narrow ? 2 : 6;
  const behindBudget = narrow ? 2 : 4;
  // The crate loops only when it holds more records than one visible window
  // (n > behind + ahead + 1) — wrapping with fewer would ask the same sleeve
  // to appear on both sides of focus in a single frame. Below that, the ends
  // stay real and the clamped (non-looping) behavior holds.
  const looping = n > aheadBudget + behindBudget + 1;
  const deltaFor = (i: number, f: number) => (looping ? loopDelta(i, f, n, aheadBudget) : i - f);

  function moveFocus(next: number) {
    // Looping: ←/→ and programmatic moves wrap mod n — no ends. The roving
    // tabindex follows (the wrapped target is the next focused card).
    const target = looping ? ((next % n) + n) % n : Math.min(n - 1, Math.max(0, next));
    if (target === focus) return;
    setPulled(false);
    setHovered(null); // stale under-cursor hover — the crate is about to slide
    setFocus(target);
    cardRefs.current[target]?.focus();
  }

  function onKeyDown(e: React.KeyboardEvent) {
    if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
      e.preventDefault();
      moveFocus(focus + (e.key === "ArrowRight" ? 1 : -1));
    }
    // Enter/Space hit the focused card button natively → handleCardClick.
  }

  // The three-click progression. A real drag sets suppressClick — its
  // release click must not double as a focus/pull.
  function handleCardClick(i: number) {
    if (suppressClick.current) return;
    if (i !== focus) {
      setPulled(false);
      setHovered(null); // the clicked card slides into focus — hover is stale once it moves
      setFocus(i);
      return;
    }
    if (!pulled) {
      setPulled(true);
      return;
    }
    onOpen(slots[i]);
  }

  // Narrow screens: shallower travel, fewer visible cards (edges still
  // clickable, so all 15 remain reachable by flipping through).
  const spacing = narrow ? 40 : 56; // slot pitch ahead of focus (also drag px/slot)
  const focusGap = narrow ? 100 : 148; // focused card → first card ahead
  const backSpacing = narrow ? 26 : 34; // tighter pitch behind focus
  const backGap = narrow ? 76 : 112; // focused card → first card behind
  const cardHalf = narrow ? 80 : 132;
  const persp = narrow ? 900 : 1400;
  const geom: CrateGeometry = { spacing, focusGap, backSpacing, backGap };

  // Visible window per side. Behind shows fewer — it's the quiet end of the
  // stack. On a LOOPING crate both sides are always populated (wrap distance
  // fills them), so each side simply takes its base budget and the window is
  // the same at every focus index. On a small (non-looping) crate the old
  // end-extension logic still applies: when one side runs out of items the
  // other inherits its unused budget, so the band never collapses to a
  // sliver at a real end. Both sides then shrink further if the measured
  // band can't hold the composed span, so the outermost sleeve is always
  // fully inside the band instead of a clipped sliver at its edge.
  const aheadExtent = (k: number) => (k === 0 ? cardHalf : focusGap + (k - 1) * spacing + cardHalf);
  const behindExtent = (k: number) => (k === 0 ? cardHalf : backGap + (k - 1) * backSpacing + cardHalf);
  let visAhead: number;
  let visBehind: number;
  if (looping) {
    visAhead = aheadBudget;
    visBehind = behindBudget;
  } else {
    const availAhead = n - 1 - focus;
    const availBehind = focus;
    visAhead = Math.min(availAhead, aheadBudget + Math.max(0, behindBudget - availBehind));
    visBehind = Math.min(availBehind, behindBudget + Math.max(0, aheadBudget - availAhead));
  }
  while (
    bandW > 0 &&
    visAhead + visBehind > 2 &&
    behindExtent(visBehind) + aheadExtent(visAhead) > bandW - 16
  ) {
    if (visAhead >= visBehind && visAhead > 1) visAhead -= 1;
    else visBehind -= 1;
  }

  // Compose the band around the *visible* group so there's never a dead
  // half-band: shift the whole crate by half the difference between the
  // occupied extents behind and ahead of focus. Sized-to-fit (above) +
  // centered (here) ⇒ no clipping at any focus index.
  const crateShift = Math.round((behindExtent(visBehind) - aheadExtent(visAhead)) / 2);

  /** The 3D face transform. Each card carries its own local perspective()
   *  (origin at its own center), so every sleeve projects identically and
   *  the bin reads as one continuous run of records leaning the same way —
   *  a shared off-axis vanishing point is what flared the left side into a
   *  mirrored book-end. The face still flattens into its own 2D layer, so
   *  sibling stacking AND hit-testing stay plain z-index (which is what
   *  fixed click-to-focus: pointer hits never follow 3D-transformed quads). */
  function poseTransform3D(z: number, ry: number): string {
    return `perspective(${persp}px) translateZ(${z}px) rotateY(${ry}deg)`;
  }

  // Click-drag across the band flips through the crate. The drag becomes
  // real only after 6px of horizontal travel — below that it stays a plain
  // click (focus → pull → open). Pointer capture starts at that same moment,
  // never on pointerdown, so plain clicks are never retargeted off the cards.
  function onPointerDown(e: React.PointerEvent) {
    if (e.button !== 0 || pulled) return;
    dragRef.current = { id: e.pointerId, startX: e.clientX, anchor: focus, active: false };
  }

  function onPointerMove(e: React.PointerEvent) {
    const st = dragRef.current;
    if (!st || e.pointerId !== st.id) return;
    const dx = e.clientX - st.startX;
    if (!st.active) {
      if (Math.abs(dx) <= 6) return;
      st.active = true;
      suppressClick.current = true;
      stageRef.current?.setPointerCapture(e.pointerId);
    }
    const target = st.anchor + Math.round(-dx / spacing); // one slot per spacing px
    // Looping crate: no ends, so no rubber-band — the drag just keeps
    // flipping, wrapping mod n in either direction. Small (non-looping)
    // crates keep the clamp + rubber give past their real ends.
    const next = looping ? ((target % n) + n) % n : Math.min(n - 1, Math.max(0, target));
    setPulled(false);
    setHovered(null); // cards travel under the captured pointer — no enter/leave fires
    setFocus(next);
    if (!looping && target !== next && !reduced) {
      // Past either end the crate follows the pointer at 0.18× — rubber-band.
      const overshoot = -dx - (next - st.anchor) * spacing;
      setRubber(-overshoot * 0.18);
    } else {
      setRubber(0);
    }
  }

  function onPointerEnd(e: React.PointerEvent) {
    const st = dragRef.current;
    if (!st || e.pointerId !== st.id) return;
    dragRef.current = null;
    setRubber(0);
    if (st.active) {
      stageRef.current?.releasePointerCapture(e.pointerId);
      // The release click (if any) lands right after pointerup.
      setTimeout(() => {
        suppressClick.current = false;
      }, 0);
    }
  }

  return (
    <section
      className={`shelf${reduced ? " shelf--reduced" : ""}${pulled ? " shelf--pulled" : ""}`}
      ref={rootRef}
      aria-label="The shelf — pinned and recent"
      onKeyDown={onKeyDown}
    >
      <div className="shelf-head">
        <span className="shelf-eyebrow">The Shelf</span>
        <span className="shelf-rule" aria-hidden="true" />
        <span className="shelf-count">{String(slots.length).padStart(2, "0")} Records</span>
      </div>
      <div
        className="shelf-stage"
        ref={stageRef}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerEnd}
        onPointerCancel={onPointerEnd}
      >
        <div className="shelf-labels">
          {slots.map((item, i) => {
            const d = deltaFor(i, focus);
            const seam = looping && Math.abs(d - deltaFor(i, prevFocus.current)) > n / 2;
            const pose = cardPose(d, geom);
            const hidden = d > visAhead || -d > visBehind;
            // Exactly ONE label at rest: the focused card's. Hovering any
            // other visible card whispers its label in (dimmed) under the
            // cursor. Everything hides during pull-out (the pulled sleeve
            // rises into the label band — no ghost stubs over the artwork).
            const dir = d < 0 ? -1 : d > 0 ? 1 : 0;
            const labelX = pose.x + crateShift + rubber + dir * (narrow ? 38 : 52);
            const visible = !hidden && !pulled && (d === 0 || hovered === i);
            return (
              <div
                key={item.key}
                className={`shelf-label${d === 0 ? " is-focused" : ""}`}
                style={{
                  transform: `translateX(${labelX}px)`,
                  opacity: visible ? (d === 0 ? 1 : 0.55) : 0,
                  transition: seam ? "none" : undefined, // seam-crossers jump, never streak
                }}
                aria-hidden="true"
              >
                <span className="shelf-label-title">{item.title}</span>
                <span className="shelf-label-sub">
                  {item.subtitle}
                  {item.pinned && <span className="shelf-pin-tag">Pinned</span>}
                </span>
              </div>
            );
          })}
        </div>
        <div className="shelf-crate">
          {slots.map((item, i) => {
            const d = deltaFor(i, focus);
            // Crossing the loop seam (d jumping e.g. −8 → +6) must not
            // interpolate — gate this card's transitions off for the render
            // so it relocates instantly at the faded band edge.
            const seam = looping && Math.abs(d - deltaFor(i, prevFocus.current)) > n / 2;
            const pose = cardPose(d, geom);
            const hidden = d > visAhead || -d > visBehind;
            const x = pose.x + crateShift + rubber;
            const isFocused = d === 0;
            const isPulled = isFocused && pulled;
            const dimmed = pulled && !isFocused;
            // The BUTTON only ever gets a flat 2D transform — its hit-rect is
            // an ordinary 264px-wide strip at the card's composed position,
            // stacked by explicit zIndex in painter's order (closer to focus
            // = on top), exactly like records in a bin: each sleeve is
            // clickable on its visible outer sliver, the overlap belongs to
            // the sleeve in front. The 3D pose lives on the inner
            // .shelf-card-face (pointer-events: none), so hit-testing never
            // depends on browser 3D quad mapping.
            const hitTransform =
              isPulled && !reduced
                ? `translateX(${x}px) translateY(-46px) scale(1.12)`
                : `translateX(${x}px)`;
            const faceTransform = reduced
              ? "none"
              : isPulled
                ? poseTransform3D(230, 0)
                : poseTransform3D(pose.z - (dimmed ? 40 : 0), pose.ry);
            return (
              <button
                key={item.key}
                ref={(el) => { cardRefs.current[i] = el; }}
                type="button"
                className={`shelf-card${isFocused ? " is-focused" : ""}${isPulled ? " is-pulled" : ""}${dimmed ? " is-dimmed" : ""}`}
                style={{
                  transform: hitTransform,
                  zIndex: isPulled ? 60 : 40 - Math.abs(d),
                  opacity: hidden ? 0 : dimmed ? 0.45 : pose.fade,
                  pointerEvents: hidden ? "none" : undefined,
                  transition: seam ? "none" : undefined, // seam-crossers jump, never streak
                  ["--shelf-tuck" as string]: pose.tuck,
                } as React.CSSProperties}
                tabIndex={isFocused ? 0 : -1}
                aria-label={`Open ${item.title}, ${item.type}${item.pinned ? ", pinned" : ""}`}
                onClick={() => handleCardClick(i)}
                onMouseEnter={() => setHovered(i)}
                onMouseLeave={() => setHovered((h) => (h === i ? null : h))}
              >
                <span
                  className="shelf-card-face"
                  style={{ transform: faceTransform, transition: seam ? "none" : undefined }}
                >
                  <span className="shelf-card-lift">
                    <span className="shelf-cover" style={{ backgroundImage: coverGradient(item.seed) }}>
                      <span className="shelf-cover-initials">{sleeveInitials(item.title)}</span>
                      <span className="shelf-cover-type">{item.type}</span>
                    </span>
                  </span>
                </span>
              </button>
            );
          })}
        </div>
      </div>
    </section>
  );
}
