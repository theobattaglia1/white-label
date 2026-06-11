import { useEffect, useRef, useState } from "react";
import { signInWithPassword, sendMagicLink } from "./auth";
import { PlaybackWordmark } from "./PlaybackWordmark";
import { AmbientField, prefersReducedMotion } from "./ambientField";

type Mode = "producer-signin" | "listen";

// Typing ripples: max one per 120ms so fast typing never strobes the field.
const RIPPLE_THROTTLE_MS = 120;
// Door-opening pulse + panel fade before the workspace mounts (~700ms cap).
const ENTRY_MS = 680;

/**
 * Sign-in page — invite-only beta. The door into the dark Playback universe:
 * full-viewport #0c0907 with the shared ambient dot field idling at low
 * amplitude behind the two doors.
 *
 * Recipients: paste a shared link (no account needed).
 * Producers: sign in with email + password or magic link.
 * Sign-up is disabled here; accounts are created via the owner's Team invite flow.
 */
export function SignIn({ onSignedIn }: { onSignedIn: () => void }) {
  const [mode, setMode] = useState<Mode>("listen");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [linkPaste, setLinkPaste] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [shake, setShake] = useState(false);
  const [leaving, setLeaving] = useState(false);

  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const fieldRef = useRef<AmbientField | null>(null);
  const lastRippleRef = useRef(0);
  const signInButtonRef = useRef<HTMLButtonElement | null>(null);
  const shakeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const entryTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Ambient field — calmer than the drop overlay (this is ambient, not
  // anticipatory): excitement pinned low, ~13fps, dots dimmed. The module
  // renders a single static frame under prefers-reduced-motion.
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const field = new AmbientField({ fps: 13, opacityScale: 0.55, excitementTarget: 0.18 });
    fieldRef.current = field;
    field.attach(canvas);
    return () => {
      field.detach();
      fieldRef.current = null;
    };
  }, []);

  useEffect(() => () => {
    if (shakeTimerRef.current) clearTimeout(shakeTimerRef.current);
    if (entryTimerRef.current) clearTimeout(entryTimerRef.current);
  }, []);

  /** Keystroke → tiny throttled ripple in the dot field near that input. */
  function rippleFrom(el: HTMLElement) {
    const now = performance.now();
    if (now - lastRippleRef.current < RIPPLE_THROTTLE_MS) return;
    lastRippleRef.current = now;
    const r = el.getBoundingClientRect();
    fieldRef.current?.pulse(r.left + r.width / 2, r.top + r.height / 2, {
      speed: 240,
      seconds: 0.8,
      sigma: 26,
      strength: 0.45,
    });
  }

  /** Wrong password → one restrained horizontal shake of the member door. */
  function shakeMemberDoor() {
    setShake(false);
    if (shakeTimerRef.current) clearTimeout(shakeTimerRef.current);
    // Next frame so the animation restarts even on repeated failures.
    requestAnimationFrame(() => {
      setShake(true);
      shakeTimerRef.current = setTimeout(() => setShake(false), 300);
    });
  }

  async function submitSignIn(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    const res = await signInWithPassword(email, password);
    setBusy(false);
    if (!res.ok) {
      setError(res.error);
      shakeMemberDoor();
      return;
    }
    // The door opens: one full-screen pulse from the Sign in key, panels
    // fade, then the workspace mounts. Reduced motion goes straight in.
    if (prefersReducedMotion() || leaving) {
      onSignedIn();
      return;
    }
    const btn = signInButtonRef.current;
    if (btn) {
      const r = btn.getBoundingClientRect();
      fieldRef.current?.pulse(r.left + r.width / 2, r.top + r.height / 2);
    }
    setLeaving(true);
    entryTimerRef.current = setTimeout(onSignedIn, ENTRY_MS);
  }

  async function submitMagic() {
    if (!email) { setError("Enter your email first"); return; }
    setError(null);
    setBusy(true);
    const res = await sendMagicLink(email);
    setBusy(false);
    if (!res.ok) setError(res.error ?? "Could not send magic link");
    else setInfo(`Check ${email} for a sign-in link.`);
  }

  function openListenLink() {
    const trimmed = linkPaste.trim();
    if (!trimmed) return;
    let token = trimmed;
    const match = trimmed.match(/\/shared\/([^/?\s]+)/);
    if (match) token = match[1];
    window.location.href = `/shared/${token}`;
  }

  return (
    <div className={`signin-page ${leaving ? "leaving" : ""}`}>
      <canvas ref={canvasRef} className="signin-field-canvas" aria-hidden="true" />
      <header className="signin-chrome">
        <PlaybackWordmark size="lg" />
        <p className="signin-tagline">Private music. Before release.</p>
      </header>
      <main className="signin-doors">
        <section className={`signin-door listen ${mode === "listen" ? "active" : ""}`} onClick={() => setMode("listen")}>
          <p className="kicker">For recipients</p>
          <h2 className="signin-title">Just listening?</h2>
          <p className="signin-lede">Open the link they sent. No signup to listen, leave notes, or approve.</p>
          {mode === "listen" && (
            <div className="signin-form">
              <input
                placeholder="Paste the link they sent you"
                value={linkPaste}
                onChange={(e) => { setLinkPaste(e.target.value); rippleFrom(e.currentTarget); }}
                onKeyDown={(e) => e.key === "Enter" && openListenLink()}
              />
              <button className="chrome-button" onClick={openListenLink} disabled={!linkPaste.trim()}>
                Open the link
              </button>
            </div>
          )}
          <div className="signin-footer">Recipients don't need accounts.</div>
        </section>

        <section className={`signin-door producer ${mode === "producer-signin" ? "active" : ""} ${shake ? "shake" : ""}`}>
          <p className="kicker">For workspace members</p>
          <h2 className="signin-title">Sign in</h2>
          <p className="signin-lede">
            Access is by invitation only. If you received an invite, check your email for a sign-in link.
          </p>
          <form className="signin-form" onSubmit={submitSignIn}>
            <input
              type="email"
              placeholder="email@studio.com"
              value={email}
              onChange={(e) => { setEmail(e.target.value); rippleFrom(e.currentTarget); }}
              autoComplete="email"
              required
              onFocus={() => setMode("producer-signin")}
            />
            <input
              type="password"
              placeholder="password"
              value={password}
              onChange={(e) => { setPassword(e.target.value); rippleFrom(e.currentTarget); }}
              autoComplete="current-password"
            />
            <div className="signin-actions">
              <button ref={signInButtonRef} className="chrome-button" type="submit" disabled={busy}>
                {busy ? "…" : "Sign in"}
              </button>
              <button type="button" className="quiet-button" onClick={submitMagic} disabled={busy || !email}>
                Email me a link instead
              </button>
            </div>
            {error && <p className="signin-note error" role="alert">{error}</p>}
            {!error && info && <p className="signin-note info" role="status">{info}</p>}
          </form>
          <div className="signin-footer">
            <button className="linklike" onClick={(e) => { e.preventDefault(); submitMagic(); }}>
              Forgot password? Send a magic link.
            </button>
          </div>
        </section>
      </main>
    </div>
  );
}
