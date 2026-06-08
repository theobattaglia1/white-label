import { useState } from "react";
import { signInWithPassword, sendMagicLink } from "./auth";
import { PlaybackWordmark } from "./PlaybackWordmark";

type Mode = "producer-signin" | "listen";

/**
 * Sign-in page — invite-only beta.
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

  async function submitSignIn(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    const res = await signInWithPassword(email, password);
    setBusy(false);
    if (!res.ok) setError(res.error);
    else onSignedIn();
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
    <div className="signin-page">
      <header className="signin-chrome">
        <PlaybackWordmark size="sm" />
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
                onChange={(e) => setLinkPaste(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && openListenLink()}
              />
              <button className="accent-button" onClick={openListenLink} disabled={!linkPaste.trim()}>
                Open the link
              </button>
            </div>
          )}
          <div className="signin-footer">Recipients don't need accounts.</div>
        </section>

        <section className={`signin-door producer ${mode === "producer-signin" ? "active" : ""}`}>
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
              onChange={(e) => setEmail(e.target.value)}
              autoComplete="email"
              required
              onFocus={() => setMode("producer-signin")}
            />
            <input
              type="password"
              placeholder="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete="current-password"
            />
            <div className="signin-actions">
              <button className="accent-button" type="submit" disabled={busy}>
                {busy ? "…" : "Sign in"}
              </button>
              <button type="button" className="chrome-button" onClick={submitMagic} disabled={busy || !email}>
                Email me a link instead
              </button>
            </div>
          </form>
          <div className="signin-footer">
            <button className="linklike" onClick={(e) => { e.preventDefault(); submitMagic(); }}>
              Forgot password? Send a magic link.
            </button>
          </div>
        </section>
      </main>

      {(error || info) && (
        <div className={`signin-toast ${error ? "error" : "info"}`}>{error || info}</div>
      )}
    </div>
  );
}
