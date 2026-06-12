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
   per card-spacing of travel, rubber-banding past the ends); a horizontal
   two-finger trackpad scroll does the same. A real drag (>6px) suppresses
   the click that fires on release, so it never doubles as focus/pull. */

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
  // band flip focus, one slot per ~80px, clamped at the ends. Vertical-
  // dominant wheels pass through untouched so the page keeps scrolling;
  // horizontal ones are consumed (no page pan / history swipe), which needs
  // a native non-passive listener — React's synthetic onWheel is passive.
  useEffect(() => {
    const el = stageRef.current;
    if (!el) return;
    const count = slots.length;
    const onWheel = (e: WheelEvent) => {
      if (Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return;
      e.preventDefault();
      wheelAcc.current += e.deltaX;
      const steps = Math.trunc(wheelAcc.current / 80);
      if (steps === 0) return;
      wheelAcc.current -= steps * 80;
      setPulled(false);
      setHovered(null); // cards slide under a stationary cursor — pointerover won't refire
      setFocus((f) => Math.min(count - 1, Math.max(0, f + steps)));
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, [slots.length]);

  if (slots.length === 0) return null;

  function moveFocus(next: number) {
    const clamped = Math.min(slots.length - 1, Math.max(0, next));
    if (clamped === focus) return;
    setPulled(false);
    setHovered(null); // stale under-cursor hover — the crate is about to slide
    setFocus(clamped);
    cardRefs.current[clamped]?.focus();
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
  // stack — but the TOTAL stays ~constant at every focus index: when one
  // side runs out of items (focus at/near an end), the other side inherits
  // its unused budget, so the band never collapses to a sliver at the ends
  // (at the last slot the behind-run extends to 10; at slot 0 the ahead-run
  // does). Both sides then shrink further if the measured band can't hold
  // the composed span, so the outermost sleeve is always fully inside the
  // band instead of a clipped sliver at its edge.
  const aheadExtent = (n: number) => (n === 0 ? cardHalf : focusGap + (n - 1) * spacing + cardHalf);
  const behindExtent = (n: number) => (n === 0 ? cardHalf : backGap + (n - 1) * backSpacing + cardHalf);
  const aheadBudget = narrow ? 2 : 6;
  const behindBudget = narrow ? 2 : 4;
  const availAhead = slots.length - 1 - focus;
  const availBehind = focus;
  let visAhead = Math.min(availAhead, aheadBudget + Math.max(0, behindBudget - availBehind));
  let visBehind = Math.min(availBehind, behindBudget + Math.max(0, aheadBudget - availAhead));
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
    const clamped = Math.min(slots.length - 1, Math.max(0, target));
    setPulled(false);
    setHovered(null); // cards travel under the captured pointer — no enter/leave fires
    setFocus(clamped);
    if (target !== clamped && !reduced) {
      // Past either end the crate follows the pointer at 0.18× — rubber-band.
      const overshoot = -dx - (clamped - st.anchor) * spacing;
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
            const d = i - focus;
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
                style={{ transform: `translateX(${labelX}px)`, opacity: visible ? (d === 0 ? 1 : 0.55) : 0 }}
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
            const d = i - focus;
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
                  ["--shelf-tuck" as string]: pose.tuck,
                } as React.CSSProperties}
                tabIndex={isFocused ? 0 : -1}
                aria-label={`Open ${item.title}, ${item.type}${item.pinned ? ", pinned" : ""}`}
                onClick={() => handleCardClick(i)}
                onMouseEnter={() => setHovered(i)}
                onMouseLeave={() => setHovered((h) => (h === i ? null : h))}
              >
                <span className="shelf-card-face" style={{ transform: faceTransform }}>
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
