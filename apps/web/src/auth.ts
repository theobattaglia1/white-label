import { createClient, type Session, type SupabaseClient, type User } from "@supabase/supabase-js";

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL ?? "https://pojhfkamzteleogxxfqj.supabase.co";
// Publishable / anon key — safe to ship in the browser.
const SUPABASE_ANON_KEY =
  (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined) ??
  "sb_publishable_L0oZ8X6VDEfmR8WJg7Oifg_gdkmvEiT";

export const supabase: SupabaseClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { autoRefreshToken: true, persistSession: true, detectSessionInUrl: true },
});

export type AuthState = {
  session: Session | null;
  user: User | null;
  loading: boolean;
};

export type SignInResult =
  | { ok: true; session: Session }
  | { ok: false; error: string };

export async function signInWithPassword(email: string, password: string): Promise<SignInResult> {
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error || !data.session) return { ok: false, error: error?.message ?? "Sign-in failed" };
  return { ok: true, session: data.session };
}

export async function signUpWithPassword(
  email: string,
  password: string,
  displayName?: string
): Promise<SignInResult> {
  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: { data: { display_name: displayName } },
  });
  if (error) return { ok: false, error: error.message };
  if (!data.session) {
    // Email confirmation required path
    return { ok: false, error: "Check your email to confirm your account, then sign in." };
  }
  return { ok: true, session: data.session };
}

export async function sendMagicLink(email: string): Promise<{ ok: boolean; error?: string }> {
  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: { emailRedirectTo: window.location.origin },
  });
  if (error) return { ok: false, error: error.message };
  return { ok: true };
}

export async function signOut(): Promise<void> {
  await supabase.auth.signOut();
}

export async function getSession(): Promise<Session | null> {
  const { data } = await supabase.auth.getSession();
  return data.session ?? null;
}

export function onAuthChange(cb: (session: Session | null) => void): () => void {
  const { data } = supabase.auth.onAuthStateChange((_event, session) => cb(session));
  return () => data.subscription.unsubscribe();
}
