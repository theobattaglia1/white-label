import { useState } from "react";
import { signInWithPassword, signUpWithPassword, sendMagicLink } from "./auth";
import { PlaybackWordmark } from "./PlaybackWordmark";

type Mode = "producer-signin" | "producer-signup" | "listen";

/**
 * Two-door sign-in page from wireframes v2:
 *   - Just listening? (recipients paste a link, no auth needed)
 *   - Create a producer account / Sign in (full app)
 */
export function SignIn({ onSignedIn }: { onSignedIn: () => void }) {
  const [mode, setMode] = useState<Mode>("listen");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [displayName, setDisplayName] = useState("");
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

  async function submitSignUp(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    const res = await signUpWithPassword(email, password, displayName || undefined);
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
    // Accept full URL or just a token
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

        <section className={`signin-door producer ${mode !== "listen" ? "active" : ""}`}>
          <p className="kicker">For producers</p>
          <h2 className="signin-title">
            {mode === "producer-signup" ? "Create a producer account" : "Sign in"}
          </h2>
          <p className="signin-lede">
            Free for three rooms and 10 GB. Send your first link in 60 seconds.
          </p>
          <form className="signin-form" onSubmit={mode === "producer-signup" ? submitSignUp : submitSignIn}>
            {mode === "producer-signup" && (
              <input
                placeholder="Studio name (optional)"
                value={displayName}
                onChange={(e) => setDisplayName(e.target.value)}
                autoComplete="name"
              />
            )}
            <input
              type="email"
              placeholder="email@studio.com"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              autoComplete="email"
              required
              onFocus={() => mode === "listen" && setMode("producer-signin")}
            />
            <input
              type="password"
              placeholder="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete={mode === "producer-signup" ? "new-password" : "current-password"}
              required={mode === "producer-signup"}
              minLength={6}
            />
            <div className="signin-actions">
              <button className="accent-button" type="submit" disabled={busy}>
                {busy ? "…" : mode === "producer-signup" ? "Create account" : "Sign in"}
              </button>
              <button type="button" className="chrome-button" onClick={submitMagic} disabled={busy || !email}>
                Email me a link instead
              </button>
            </div>
          </form>
          <div className="signin-footer">
            {mode === "producer-signup" ? (
              <button className="linklike" onClick={(e) => { e.preventDefault(); setMode("producer-signin"); }}>
                Already have an account? Sign in
              </button>
            ) : (
              <span style={{ display: "flex", gap: "16px", flexWrap: "wrap", justifyContent: "center" }}>
                <button className="linklike" onClick={(e) => { e.preventDefault(); setMode("producer-signup"); }}>
                  No account yet? Create one
                </button>
                <button className="linklike" onClick={(e) => { e.preventDefault(); submitMagic(); }}>
                  Forgot password?
                </button>
              </span>
            )}
          </div>
        </section>
      </main>

      {(error || info) && (
        <div className={`signin-toast ${error ? "error" : "info"}`}>{error || info}</div>
      )}
    </div>
  );
}
