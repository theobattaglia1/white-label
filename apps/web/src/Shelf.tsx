import { useEffect, useRef, useState } from "react";
import { coverGradient } from "./utils";
import { SHELF_MAX_SLOTS, type ShelfItem } from "./shelf";

/* THE SHELF — pins + recents as a record crate on Home.
   A row of square 12" covers standing on a floor, receding in 3D perspective; the
   focused card faces the viewer most, far cards sit nearly edge-on. Pure
   CSS 3D — transforms + opacity only, transitions do the travel, no rAF.

   Hit model: each card <button> is a FLAT 2D-positioned strip (translateX +
   zIndex in painter's order); the 3D pose is applied to an inner, inert
   .shelf-card-face via a per-card conjugated perspective() — visually
   identical to a shared stage perspective, but clicks resolve through
   ordinary 2D stacking, never the browser's 3D depth hit-testing.

   Three-click state machine (focus → pull → open):
     1. click an unfocused card  → it eases into focus
     2. click the focused card   → PULL-OUT (slides up + toward viewer)
     3. click the pulled card    → onOpen(item) navigates
   Esc / click anywhere else while pulled → slips back into the crate.
   ←/→ move focus, Enter advances the same progression (cards are buttons). */

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

type Pose = { x: number; z: number; ry: number; hidden: boolean };

/** Crate pose for a card `d` slots away from focus. Focused card leans a
 *  gentle −18°; cards fall back toward −58° (near edge-on) as they recede. */
function cardPose(d: number, spacing: number, focusGap: number, maxVisible: number): Pose {
  const abs = Math.abs(d);
  if (d === 0) return { x: 0, z: 90, ry: -18, hidden: false };
  const dir = d < 0 ? -1 : 1;
  const ry = -18 - Math.min(8 + abs * 11, 40); // −37, −48, −58, −58 …
  const x = dir * (focusGap + (abs - 1) * spacing);
  const z = -26 * Math.min(abs, 4);
  return { x, z, ry, hidden: abs > maxVisible };
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
  const reduced = useMediaQuery("(prefers-reduced-motion: reduce)");
  const narrow = useMediaQuery("(max-width: 720px)");
  const rootRef = useRef<HTMLElement | null>(null);
  const cardRefs = useRef<Array<HTMLButtonElement | null>>([]);

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

  if (slots.length === 0) return null;

  function moveFocus(next: number) {
    const clamped = Math.min(slots.length - 1, Math.max(0, next));
    if (clamped === focus) return;
    setPulled(false);
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

  // The three-click progression.
  function handleCardClick(i: number) {
    if (i !== focus) {
      setPulled(false);
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
  const spacing = narrow ? 40 : 56;
  const focusGap = narrow ? 100 : 148;
  const maxVisible = narrow ? 2 : 6;
  const cardHalf = narrow ? 80 : 132;
  const persp = narrow ? 900 : 1400;
  // Vertical offset from a card's center up to the stage vanishing point
  // (38% of stage height) — keeps the projection identical to the old
  // stage-level `perspective` (see poseTransform3D below).
  const vanishY = narrow ? -66 : -78;

  // Compose the band around the *visible* group so there's never a dead
  // half-band: shift the whole crate by half the difference between the
  // occupied extents left and right of focus. With focus on card 0 this
  // lands the focused sleeve ~31% from the left edge, crate receding right.
  const sideExtent = (n: number) => (n === 0 ? cardHalf : focusGap + (n - 1) * spacing + cardHalf);
  const crateShift = Math.round(
    (sideExtent(Math.min(focus, maxVisible)) -
      sideExtent(Math.min(Math.max(slots.length - 1 - focus, 0), maxVisible))) / 2,
  );

  /** The 3D face transform for a card whose flat hit-rect sits at `x`.
   *  `perspective()` is conjugated by the offset from this card's center to
   *  the shared vanishing point (stage center, 38% up) — matrix-identical to
   *  the old stage-level `perspective: 1400px`, but each card now flattens
   *  into its own 2D layer, so sibling stacking AND hit-testing are plain
   *  z-index instead of browser 3D depth-sorting (which is what broke
   *  click-to-focus: pointer hits never followed the 3D-transformed quads). */
  function poseTransform3D(x: number, z: number, ry: number): string {
    return `translate(${-x}px, ${vanishY}px) perspective(${persp}px) translate(${x}px, ${-vanishY}px) translateZ(${z}px) rotateY(${ry}deg)`;
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
      <div className="shelf-stage">
        <div className="shelf-labels">
          {slots.map((item, i) => {
            const d = i - focus;
            const pose = cardPose(d, spacing, focusGap, maxVisible);
            // Each label anchors to ITS card: the card's composed x plus a
            // small outward nudge for neighbors so the focused label never
            // collides. Focused + 1 neighbor each side only (neighbors
            // dimmed); hover whispers the label in for other visible cards;
            // everything hides during pull-out (the pulled sleeve rises into
            // the label band — no ghost stubs over the artwork).
            const dir = d < 0 ? -1 : d > 0 ? 1 : 0;
            const labelX = pose.x + crateShift + dir * (narrow ? 38 : 52);
            const visible = !pose.hidden && !pulled && (Math.abs(d) <= 1 || hovered === i);
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
            const pose = cardPose(d, spacing, focusGap, maxVisible);
            const x = pose.x + crateShift;
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
                ? poseTransform3D(x, 230, 0)
                : poseTransform3D(x, pose.z - (dimmed ? 40 : 0), pose.ry);
            return (
              <button
                key={item.key}
                ref={(el) => { cardRefs.current[i] = el; }}
                type="button"
                className={`shelf-card${isFocused ? " is-focused" : ""}${isPulled ? " is-pulled" : ""}${dimmed ? " is-dimmed" : ""}`}
                style={{
                  transform: hitTransform,
                  zIndex: isPulled ? 60 : 40 - Math.abs(d),
                  opacity: pose.hidden ? 0 : dimmed ? 0.45 : 1,
                  pointerEvents: pose.hidden ? "none" : undefined,
                }}
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
