import { useEffect, useMemo, useState, type ReactNode } from "react";
import {
  Bell,
  CheckCircle2,
  CircleDashed,
  GitCompare,
  History,
  Inbox,
  Link2,
  ListMusic,
  LockKeyhole,
  MessageSquare,
  Pause,
  Play,
  Plus,
  Radio,
  RotateCcw,
  Search,
  Send,
  Shield,
  Upload,
  UserRound,
  X,
} from "lucide-react";
import { formatTimestamp, type FileAsset, type ShareLink, type Song, type Version, type VisibleNote } from "@pmw/shared";
import { api, assetForVersion, uploadAudio, type RoomPayload, type SharedPayload, type SongPayload, versionsForSong } from "./api";
import { usePlayer } from "./player";
import { onAuthChange, signOut, getSession } from "./auth";
import { SignIn } from "./SignIn";
import type { Session } from "@supabase/supabase-js";

type ViewMode = "room" | "song" | "compare" | "inbox" | "links" | "assistant";

export function App() {
  const sharedToken = window.location.pathname.match(/^\/shared\/([^/]+)/)?.[1];
  if (sharedToken) return <SharedListeningPage token={sharedToken} />;
  // Dev-only auth bypass — stripped in production builds so prod URLs cannot
  // be backdoored with ?dev=1.
  const devBypass =
    import.meta.env.DEV && new URLSearchParams(window.location.search).get("dev") === "1";
  if (devBypass) return <WorkspaceApp />;
  return <AuthenticatedApp />;
}

function AuthenticatedApp() {
  const [session, setSession] = useState<Session | null | "loading">("loading");

  useEffect(() => {
    let mounted = true;
    getSession().then((s) => mounted && setSession(s));
    const unsub = onAuthChange((s) => mounted && setSession(s));
    return () => { mounted = false; unsub(); };
  }, []);

  if (session === "loading") {
    return (
      <div className="app-shell" style={{ display: "grid", placeItems: "center", minHeight: "100vh" }}>
        <p className="muted">Loading…</p>
      </div>
    );
  }
  if (!session) {
    return <SignIn onSignedIn={() => getSession().then(setSession)} />;
  }
  return <WorkspaceApp onSignOut={() => { void signOut(); }} />;
}

function WorkspaceApp({ onSignOut }: { onSignOut?: () => void } = {}) {
  const [roomPayload, setRoomPayload] = useState<RoomPayload | null>(null);
  const [songPayload, setSongPayload] = useState<SongPayload | null>(null);
  const [mode, setMode] = useState<ViewMode>("song");
  const [selectedSongID, setSelectedSongID] = useState("song-midnight");
  const [inboxItems, setInboxItems] = useState<Awaited<ReturnType<typeof api.inbox>>>([]);
  const [error, setError] = useState<string | null>(null);

  async function refresh(nextSongID = selectedSongID) {
    try {
      const room = await api.room();
      setRoomPayload(room);
      const songID = nextSongID || room.songs[0]?.song_id;
      if (songID) {
        setSelectedSongID(songID);
        setSongPayload(await api.song(songID));
      }
      setInboxItems(await api.inbox());
      setError(null);
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "Unable to load workspace");
    }
  }

  useEffect(() => {
    void refresh(selectedSongID);
  }, []);

  const selectedSong = roomPayload?.songs.find((song) => song.song_id === selectedSongID) ?? songPayload?.song;

  return (
    <div className="app-shell">
      <TopBar roomTitle={roomPayload?.room.title ?? "Private Workspace"} error={error} onSignOut={onSignOut} />
      <main className="workspace-grid">
        <Sidebar
          mode={mode}
          setMode={setMode}
          room={roomPayload}
          selectedSongID={selectedSongID}
          onSelectSong={(id) => {
            setSelectedSongID(id);
            setMode("song");
            void refresh(id);
          }}
        />
        <section className="workspace-main">
          {mode === "room" && roomPayload && (
            <RoomView
              payload={roomPayload}
              onOpenSong={(songID) => {
                setSelectedSongID(songID);
                setMode("song");
                void refresh(songID);
              }}
            />
          )}
          {mode === "song" && songPayload && <SongWorkspace payload={songPayload} onRefresh={() => refresh(songPayload.song.song_id)} />}
          {mode === "compare" && songPayload && <ComparisonMode payload={songPayload} onRefresh={() => refresh(songPayload.song.song_id)} />}
          {mode === "inbox" && <InboxView items={inboxItems} onOpenSong={(id) => {
            setSelectedSongID(id);
            setMode("song");
            void refresh(id);
          }} />}
          {mode === "links" && roomPayload && selectedSong && (
            <LinkManager room={roomPayload} song={selectedSong} onRefresh={() => refresh(selectedSong.song_id)} />
          )}
          {mode === "assistant" && <AssistantPanel />}
        </section>
      </main>
      <MiniPlayer />
    </div>
  );
}

function TopBar({ roomTitle, error, onSignOut }: { roomTitle: string; error: string | null; onSignOut?: () => void }) {
  return (
    <header className="top-bar">
      <div className="icon-run">
        <button className="icon-button active" title="Notifications">
          <Bell size={17} />
          <span className="notify-dot" />
        </button>
        <button className="icon-button" title="Search">
          <Search size={17} />
        </button>
      </div>
      <Wordmark size="sm" title={roomTitle} />
      <div className="top-right">
        {error && <span className="error-pill">{error}</span>}
        <button className="avatar-button" title="Account">
          TB
        </button>
        {onSignOut && (
          <button className="signout-chip" title="Sign out" onClick={onSignOut}>
            Sign out
          </button>
        )}
      </div>
    </header>
  );
}

function Sidebar({
  mode,
  setMode,
  room,
  selectedSongID,
  onSelectSong,
}: {
  mode: ViewMode;
  setMode: (mode: ViewMode) => void;
  room: RoomPayload | null;
  selectedSongID: string;
  onSelectSong: (songID: string) => void;
}) {
  const nav = [
    ["room", "Room", ListMusic],
    ["song", "Song", Radio],
    ["compare", "Compare", GitCompare],
    ["inbox", "Inbox", Inbox],
    ["links", "Links", Link2],
    ["assistant", "Ask", MessageSquare],
  ] as const;

  return (
    <aside className="sidebar">
      <nav className="nav-list">
        {nav.map(([id, label, Icon]) => (
          <button key={id} className={`nav-item ${mode === id ? "selected" : ""}`} onClick={() => setMode(id)}>
            <Icon size={16} />
            <span>{label}</span>
          </button>
        ))}
      </nav>
      <div className="side-rule" />
      <div className="side-label">SONGS</div>
      <div className="song-rail">
        {room?.songs.map((song) => {
          const versions = versionsForSong(room.versions, song.song_id);
          const current = versions.find((version) => version.version_id === song.current_version_id);
          return (
            <button
              key={song.song_id}
              className={`song-rail-item ${selectedSongID === song.song_id ? "selected" : ""}`}
              onClick={() => onSelectSong(song.song_id)}
            >
              <span className="song-title">{song.title}</span>
              <span className="song-meta">{current?.version_label ?? "No version"}</span>
            </button>
          );
        })}
      </div>
    </aside>
  );
}

function RoomView({ payload, onOpenSong }: { payload: RoomPayload; onOpenSong: (songID: string) => void }) {
  return (
    <div className="view-stack">
      <div className="section-head">
        <div>
          <p className="eyebrow">ROOM</p>
          <h1>{payload.room.title}</h1>
        </div>
        <div className="metric-strip">
          <Metric label="Songs" value={payload.songs.length} />
          <Metric label="Versions" value={payload.versions.length} />
          <Metric label="Open Notes" value={payload.notes.filter((note) => note.status === "open").length} />
        </div>
      </div>
      <div className="song-table">
        {payload.songs.map((song) => {
          const versions = versionsForSong(payload.versions, song.song_id);
          const current = versions.find((version) => version.version_id === song.current_version_id);
          const asset = assetForVersion(payload.assets, current);
          return (
            <button key={song.song_id} className="song-row" onClick={() => onOpenSong(song.song_id)}>
              <div className="cover-art" aria-hidden="true" style={{ backgroundImage: coverGradient(song.song_id) }} />
              <div className="row-main">
                <span className="row-title">{song.title}</span>
                <span className="row-subtitle">{song.artist_display_name} · {song.project_name}</span>
              </div>
              <Waveform peaks={asset?.waveform_peaks ?? []} compact />
              <div className="row-current">
                <span>{current?.version_label}</span>
                <small>{asset ? `${Math.round(asset.duration_ms / 1000)}s · ${asset.loudness_lufs} LUFS` : ""}</small>
              </div>
            </button>
          );
        })}
      </div>
    </div>
  );
}

function SongWorkspace({ payload, onRefresh }: { payload: SongPayload; onRefresh: () => void }) {
  const [activeVersionID, setActiveVersionID] = useState(payload.currentVersion?.version_id ?? payload.versions[0]?.version_id);
  const [noteDraftOpen, setNoteDraftOpen] = useState(false);
  const [noteTimestamp, setNoteTimestamp] = useState<number | undefined>(undefined);
  const [uploadingPct, setUploadingPct] = useState<number | null>(null);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [pendingPromote, setPendingPromote] = useState<Version | null>(null);
  const fileInputRef = useMemo(() => ({ current: null as HTMLInputElement | null }), []);
  const player = usePlayer();

  const activeVersion = payload.versions.find((version) => version.version_id === activeVersionID) ?? payload.currentVersion;
  const activeAsset = assetForVersion(payload.assets, activeVersion);
  const currentAsset = assetForVersion(payload.assets, payload.currentVersion);

  useEffect(() => {
    setActiveVersionID(payload.currentVersion?.version_id ?? payload.versions[0]?.version_id);
  }, [payload.song.song_id, payload.currentVersion?.version_id]);

  function triggerUpload() {
    setUploadError(null);
    fileInputRef.current?.click();
  }

  async function onFileChosen(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    setUploadingPct(0);
    setUploadError(null);
    try {
      await uploadAudio(
        file,
        {
          songExternalId: payload.song.song_id,
          versionLabel: `Mix v${payload.versions.length + 1}`,
          versionType: "mix",
        },
        (pct) => setUploadingPct(pct)
      );
      setUploadingPct(null);
      onRefresh();
    } catch (err) {
      setUploadingPct(null);
      setUploadError(err instanceof Error ? err.message : String(err));
    } finally {
      // reset input so re-selecting the same file fires onChange
      if (fileInputRef.current) fileInputRef.current.value = "";
    }
  }

  const openNotes = payload.notes.filter((n) => n.status === "open");
  const hasNotesDue = openNotes.length > 0;
  const approvedVersion = payload.versions.find((v) => v.version_id === payload.song.approved_version_id);
  const catalogId = `WL · ${payload.song.song_id.slice(-4).toUpperCase()}`;
  const versionLabel = activeVersion?.version_label ?? "v1";

  return (
    <div className="view-stack">
      <div className="song-card-hero">
        <div className="breadcrumb">
          {payload.song.project_name ?? "Room"} / <b>{payload.song.title}</b> / {versionLabel}
        </div>
        <div className="song-card-frame">
          <div className="stamp-row">
            {approvedVersion && (
              <Stamp kind="approved" straight>Approved · {approvedVersion.version_label}</Stamp>
            )}
            {hasNotesDue && (
              <Stamp kind="notes-due">Notes Due · {openNotes.length}</Stamp>
            )}
          </div>
          <div className="song-card-body">
            <div className="song-card-cover" style={{ backgroundImage: coverGradient(payload.song.song_id) }}>
              <div className="grain" />
              <span className="cat-strip">{catalogId} · {versionLabel}</span>
              <div className="mono-corner">
                <MonoMark />
              </div>
            </div>
            <div className="song-card-info">
              <span className="cat">
                <span className="b">{payload.song.artist_display_name}</span>
                {payload.song.project_name ? ` / ${payload.song.project_name}` : ""}
              </span>
              <h2 className="title">{payload.song.title}</h2>
              <div className="artist">
                {payload.song.artist_display_name}
                {activeVersion?.version_label ? ` · ${activeVersion.version_label}` : ""}
              </div>
              <div className="meta-row">
                {activeAsset?.duration_ms && (
                  <span><span className="b">{formatTimestamp(activeAsset.duration_ms)}</span></span>
                )}
                {payload.song.bpm && <span><span className="b">{payload.song.bpm}</span> BPM</span>}
                {payload.song.song_key && <span><span className="b">{payload.song.song_key}</span></span>}
                {activeAsset?.loudness_lufs && <span>{activeAsset.loudness_lufs} LUFS</span>}
                {activeAsset?.mime_type && <span>{activeAsset.mime_type.replace("audio/", "").toUpperCase()}</span>}
              </div>
              <div className="versions">
                <h6>Stack</h6>
                {payload.versions.map((v) => (
                  <button
                    key={v.version_id}
                    className={`v ${v.version_id === activeVersion?.version_id ? "cur" : ""}`}
                    onClick={() => {
                      setActiveVersionID(v.version_id);
                      const a = assetForVersion(payload.assets, v);
                      if (a) player.play(payload.song, v, a);
                    }}
                  >
                    {v.version_label ?? `v${v.version_number}`}
                    {v.is_current ? " · current" : ""}
                  </button>
                ))}
              </div>
              <div className="actions">
                <button
                  className="btn red primary"
                  onClick={() => activeVersion && activeAsset && player.play(payload.song, activeVersion, activeAsset)}
                >
                  <Play size={14} /> Play
                </button>
                <button
                  className="chrome-button"
                  onClick={triggerUpload}
                  disabled={uploadingPct !== null}
                  title={uploadingPct !== null ? `Uploading… ${uploadingPct}%` : "Drop a new revision into the version stack"}
                >
                  <Upload size={14} />
                  {uploadingPct === null
                    ? "New revision"
                    : `Uploading ${uploadingPct}%`}
                </button>
                <input
                  ref={(el) => { fileInputRef.current = el; }}
                  type="file"
                  accept="audio/*,.wav,.mp3,.m4a,.flac,.aiff,.aif"
                  hidden
                  onChange={onFileChosen}
                />
                <button
                  className="text-button with-icon"
                  onClick={() => {
                    setNoteTimestamp(player.positionMs);
                    setNoteDraftOpen(true);
                  }}
                >
                  <MessageSquare size={14} /> Add note
                </button>
                {uploadError && (
                  <span className="upload-error">{uploadError}</span>
                )}
              </div>
            </div>
          </div>
          <div className="song-card-waveband">
            <button
              className="play"
              aria-label={player.isPlaying ? "Pause" : "Play"}
              onClick={() => {
                if (player.isPlaying) player.toggle();
                else if (activeVersion && activeAsset) player.play(payload.song, activeVersion, activeAsset);
              }}
            >
              {player.isPlaying ? <Pause size={16} /> : <Play size={16} />}
            </button>
            <div className="wave-host">
              <Waveform
                peaks={activeAsset?.waveform_peaks ?? []}
                positionMs={player.positionMs}
                durationMs={activeAsset?.duration_ms ?? 1}
                onSeek={(position) => {
                  player.seek(position);
                  setNoteTimestamp(position);
                }}
              />
            </div>
            <div className="times">
              {formatTimestamp(player.positionMs)} / {formatTimestamp(activeAsset?.duration_ms)}
            </div>
          </div>
        </div>
      </div>

      {noteDraftOpen && activeVersion && (
        <NoteComposer
          song={payload.song}
          version={activeVersion}
          timestampMs={noteTimestamp}
          onPosted={() => {
            setNoteDraftOpen(false);
            onRefresh();
          }}
          onDismiss={() => setNoteDraftOpen(false)}
        />
      )}

      <div className="content-columns">
        <VersionStack
          payload={payload}
          activeVersionID={activeVersion?.version_id}
          onSelect={(version) => {
            const asset = assetForVersion(payload.assets, version);
            setActiveVersionID(version.version_id);
            if (asset) player.play(payload.song, version, asset);
          }}
          onSetCurrent={(versionID) => {
            const v = payload.versions.find((x) => x.version_id === versionID);
            if (!v) return;
            const carriedOpenNotes = payload.notes.filter(
              (n) => n.status === "open" && n.is_carried,
            );
            if (carriedOpenNotes.length > 0) {
              setPendingPromote(v);
            } else {
              void (async () => {
                await api.setCurrent(versionID);
                onRefresh();
              })();
            }
          }}
        />
        {pendingPromote && (
          <CarryForwardTriage
            payload={payload}
            targetVersion={pendingPromote}
            onCancel={() => setPendingPromote(null)}
            onPromote={async (resolvedIDs) => {
              await api.setCurrent(pendingPromote.version_id);
              await Promise.all(
                resolvedIDs.map((noteID) => api.patchNote(noteID, { status: "resolved" })),
              );
              setPendingPromote(null);
              onRefresh();
            }}
          />
        )}
        <NotesPanel notes={payload.notes} onRefresh={onRefresh} />
        <DeliverablesPanel payload={payload} />
      </div>
    </div>
  );
}

function CarryForwardTriage({
  payload,
  targetVersion,
  onCancel,
  onPromote,
}: {
  payload: SongPayload;
  targetVersion: Version;
  onCancel: () => void;
  onPromote: (resolvedNoteIDs: string[]) => Promise<void>;
}) {
  const carriedOpenNotes = payload.notes.filter((n) => n.status === "open" && n.is_carried);
  const [resolved, setResolved] = useState<Set<string>>(new Set());
  const [submitting, setSubmitting] = useState(false);

  function toggle(id: string) {
    setResolved((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  async function submit() {
    setSubmitting(true);
    try {
      await onPromote(Array.from(resolved));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="carry-triage-backdrop" role="dialog" aria-modal="true" aria-labelledby="carry-triage-title">
      <div className="carry-triage">
        <header>
          <p className="eyebrow">PROMOTE TO CURRENT</p>
          <h2 id="carry-triage-title">{targetVersion.version_label}</h2>
          <p className="muted">
            {carriedOpenNotes.length} carry-forward {carriedOpenNotes.length === 1 ? "note is" : "notes are"} still open.
            Tick anything this revision addresses — those will be resolved on promote.
          </p>
        </header>
        <ul className="triage-list">
          {carriedOpenNotes.map((note) => {
            const checked = resolved.has(note.note_id);
            return (
              <li key={note.note_id}>
                <button
                  type="button"
                  className={`triage-toggle ${checked ? "on" : ""}`}
                  onClick={() => toggle(note.note_id)}
                  aria-pressed={checked}
                  aria-label={`Mark resolved: ${note.body}`}
                >
                  <span className="box">{checked ? <CheckCircle2 size={16} /> : null}</span>
                </button>
                <div className="triage-body">
                  <p className="note-line">{note.body}</p>
                  <div className="cue">
                    <span>{note.author_guest_label ?? "Workspace"}</span>
                    <span> · from {note.anchor_version_label}</span>
                    {note.approximate_timestamp && (
                      <span className="approx"> · ≈ {formatTimestamp(note.timestamp_start_ms)}, position may have shifted</span>
                    )}
                  </div>
                </div>
              </li>
            );
          })}
        </ul>
        <footer>
          <div className="footer-meta">
            {resolved.size === 0
              ? "No notes marked resolved"
              : `${resolved.size} of ${carriedOpenNotes.length} will be resolved`}
          </div>
          <div className="footer-actions">
            <button type="button" className="chrome-button" onClick={onCancel} disabled={submitting}>
              Cancel
            </button>
            <button type="button" className="accent-button" onClick={submit} disabled={submitting}>
              {submitting ? "Promoting…" : `Promote ${targetVersion.version_label}`}
            </button>
          </div>
        </footer>
      </div>
    </div>
  );
}

function VersionStack({
  payload,
  activeVersionID,
  onSelect,
  onSetCurrent,
}: {
  payload: SongPayload;
  activeVersionID?: string;
  onSelect: (version: Version) => void;
  onSetCurrent: (versionID: string) => void;
}) {
  return (
    <section className="rail-panel">
      <div className="panel-topline">
        <div>
          <p className="eyebrow">VERSION STACK</p>
          <h2>History</h2>
        </div>
        <History size={18} />
      </div>
      {payload.versions.map((version) => {
        const asset = assetForVersion(payload.assets, version);
        return (
          <div
            key={version.version_id}
            role="button"
            tabIndex={0}
            className={`version-row ${version.version_id === activeVersionID ? "selected" : ""}`}
            onClick={() => onSelect(version)}
            onKeyDown={(event) => {
              if (event.key === "Enter" || event.key === " ") onSelect(version);
            }}
          >
            <div className="ver-num">{String(version.version_number).padStart(2, "0")}</div>
            <div className="version-body">
              <span>{version.version_label}</span>
              <small>{version.type} · {asset?.loudness_lufs} LUFS · {formatTimestamp(asset?.duration_ms)}</small>
            </div>
            <div className="version-state">
              {version.version_id === payload.song.approved_version_id && (
                <Stamp kind="approved" tight straight>Approved</Stamp>
              )}
              {version.is_current ? (
                <span className="status-pill red">Current</span>
              ) : (
                <button className="text-button" onClick={(event) => {
                  event.stopPropagation();
                  onSetCurrent(version.version_id);
                }}>
                  Set current
                </button>
              )}
            </div>
          </div>
        );
      })}
    </section>
  );
}

function NotesPanel({ notes, onRefresh }: { notes: VisibleNote[]; onRefresh: () => void }) {
  return (
    <section className="rail-panel">
      <div className="panel-topline">
        <div>
          <p className="eyebrow">NOTES</p>
          <h2>{notes.filter((note) => note.status === "open").length} Open</h2>
        </div>
        <MessageSquare size={18} />
      </div>
      <div className="note-list">
        {notes.map((note) => (
          <article key={note.note_id} className={`note-item ${note.is_collapsed ? "collapsed" : ""}`}>
            <div className="note-head">
              <span>{note.author_guest_label ?? "Workspace"}</span>
              <span>{note.is_carried ? `carried from ${note.anchor_version_label}` : `from ${note.anchor_version_label}`}</span>
            </div>
            <p>{note.body}</p>
            <div className="note-foot">
              <span className={note.approximate_timestamp ? "approx" : ""}>
                {note.approximate_timestamp ? "≈ " : ""}
                {formatTimestamp(note.timestamp_start_ms)}
                {note.approximate_timestamp ? ", position may have shifted" : ""}
              </span>
              {note.status === "open" ? (
                <button className="text-button" onClick={async () => {
                  await api.patchNote(note.note_id, { status: "resolved" });
                  onRefresh();
                }}>
                  Resolve
                </button>
              ) : (
                <button className="text-button" onClick={async () => {
                  await api.patchNote(note.note_id, { status: "open" });
                  onRefresh();
                }}>
                  Reopen
                </button>
              )}
            </div>
          </article>
        ))}
      </div>
    </section>
  );
}

function DeliverablesPanel({ payload }: { payload: SongPayload }) {
  return (
    <section className="rail-panel">
      <div className="panel-topline">
        <div>
          <p className="eyebrow">RELEASE READINESS</p>
          <h2>{payload.deliverables.ready ? "Ready" : "Not Ready"}</h2>
        </div>
        {payload.deliverables.ready ? <CheckCircle2 size={18} /> : <CircleDashed size={18} />}
      </div>
      <div className="checklist">
        {payload.deliverables.present.map((item) => (
          <span key={item} className="check present">
            <CheckCircle2 size={14} />
            {item}
          </span>
        ))}
        {payload.deliverables.missing.map((item) => (
          <span key={item} className="check missing">
            <X size={14} />
            {item}
          </span>
        ))}
      </div>
    </section>
  );
}

function ComparisonMode({ payload, onRefresh }: { payload: SongPayload; onRefresh: () => void }) {
  const [leftID, setLeftID] = useState(payload.versions[0]?.version_id);
  const [rightID, setRightID] = useState(payload.currentVersion?.version_id);
  const [activeDeck, setActiveDeck] = useState<"A" | "B">("B");
  const player = usePlayer();
  const left = payload.versions.find((version) => version.version_id === leftID) ?? payload.versions[0];
  const right = payload.versions.find((version) => version.version_id === rightID) ?? payload.versions.at(-1);
  const leftAsset = assetForVersion(payload.assets, left);
  const rightAsset = assetForVersion(payload.assets, right);
  const gainFor = (asset?: FileAsset) => (asset ? (-14 - asset.loudness_lufs).toFixed(1) : "0.0");
  const activeVersion = activeDeck === "A" ? left : right;

  return (
    <div className="view-stack">
      <div className="section-head">
        <div>
          <p className="eyebrow">COMPARISON MODE</p>
          <h1>{payload.song.title}</h1>
        </div>
        <ToggleSwitch
          label="Loudness Match"
          checked={player.loudnessMatched}
          onChange={(next) => player.setLoudnessMatched(next)}
        />
      </div>
      <div className="compare-grid">
        <CompareDeck
          title="A"
          song={payload.song}
          version={left}
          asset={leftAsset}
          selectedID={leftID}
          versions={payload.versions}
          onSelect={(id) => { setLeftID(id); setActiveDeck("A"); }}
          onActivate={() => setActiveDeck("A")}
          isActive={activeDeck === "A"}
          gain={gainFor(leftAsset)}
        />
        <CompareDeck
          title="B"
          song={payload.song}
          version={right}
          asset={rightAsset}
          selectedID={rightID}
          versions={payload.versions}
          onSelect={(id) => { setRightID(id); setActiveDeck("B"); }}
          onActivate={() => setActiveDeck("B")}
          isActive={activeDeck === "B"}
          gain={gainFor(rightAsset)}
        />
      </div>
      {activeVersion && (
        <NoteComposer
          song={payload.song}
          version={activeVersion}
          timestampMs={player.positionMs || undefined}
          deckLabel={activeDeck}
          onPosted={onRefresh}
        />
      )}
    </div>
  );
}

function CompareDeck({
  title,
  song,
  version,
  asset,
  selectedID,
  versions,
  onSelect,
  onActivate,
  isActive,
  gain,
}: {
  title: string;
  song: Song;
  version?: Version;
  asset?: FileAsset;
  selectedID?: string;
  versions: Version[];
  onSelect: (id: string) => void;
  onActivate: () => void;
  isActive: boolean;
  gain: string;
}) {
  const player = usePlayer();
  const isPlayingThis = player.isPlaying && player.version?.version_id === version?.version_id;
  return (
    <section className={`compare-deck ${isActive ? "active" : ""}`}>
      <div className="panel-topline">
        <div>
          <p className="eyebrow">DECK {title}{isActive ? " · ACTIVE" : ""}</p>
          <h2>{version?.version_label}</h2>
        </div>
        <button className="icon-button" title="Play deck" onClick={() => {
          onActivate();
          if (version && asset) player.play(song, version, asset);
        }}>
          {isPlayingThis ? <Pause size={17} /> : <Play size={17} />}
        </button>
      </div>
      <div className="deck-version-pills">
        {versions.map((item) => (
          <button
            key={item.version_id}
            className={`v ${item.version_id === selectedID ? "cur" : ""}`}
            onClick={() => { onActivate(); onSelect(item.version_id); }}
          >
            {item.version_label}
          </button>
        ))}
      </div>
      <Waveform peaks={asset?.waveform_peaks ?? []} positionMs={player.positionMs} durationMs={asset?.duration_ms ?? 1} onSeek={player.seek} />
      <div className="time-row">
        <span>{formatTimestamp(player.positionMs)}</span>
        <span>{asset?.loudness_lufs} LUFS · gain {gain} dB</span>
      </div>
    </section>
  );
}

function NoteComposer({
  song,
  version,
  timestampMs,
  deckLabel,
  onPosted,
  onDismiss,
}: {
  song: Song;
  version: Version;
  timestampMs?: number;
  deckLabel?: string;
  onPosted: () => void;
  onDismiss?: () => void;
}) {
  const [body, setBody] = useState("");
  const [posting, setPosting] = useState(false);
  async function submit() {
    if (!body.trim()) return;
    setPosting(true);
    try {
      await api.createNote({
        song_id: song.song_id,
        anchor_version_id: version.version_id,
        body: body.trim(),
        timestamp_start_ms: timestampMs,
        scope: "song",
        visibility: "everyone",
      });
      setBody("");
      onPosted();
    } finally {
      setPosting(false);
    }
  }
  const cueLabel = timestampMs && timestampMs > 0 ? `@ ${formatTimestamp(timestampMs)}` : "@ start";
  const ariaLabel = `Leave a note on ${version.version_label}${deckLabel ? ` · Deck ${deckLabel}` : ""} ${cueLabel}`;
  return (
    <div className="note-composer">
      <div>
        <p className="eyebrow">
          NOTE ON {version.version_label}
          {deckLabel ? ` · DECK ${deckLabel}` : ""}
          {" · "}{cueLabel}
        </p>
        <input
          aria-label={ariaLabel}
          value={body}
          onChange={(event) => setBody(event.target.value)}
          onKeyDown={(event) => { if (event.key === "Enter" && body.trim()) submit(); }}
          placeholder="Pull the snare 1dB at the bridge…"
          autoFocus
          disabled={posting}
        />
      </div>
      <div className="composer-actions">
        {onDismiss && (
          <button className="icon-button" title="Dismiss" onClick={onDismiss}>
            <X size={16} />
          </button>
        )}
        <button className="accent-button" onClick={submit} disabled={posting || !body.trim()}>
          <Send size={15} />
          {posting ? "Sending…" : "Send"}
        </button>
      </div>
    </div>
  );
}

type InboxFilter = "open" | "saved" | "passed";

function InboxView({
  items,
  onOpenSong,
}: {
  items: Awaited<ReturnType<typeof api.inbox>>;
  onOpenSong: (songID: string) => void;
}) {
  const [savedIDs, setSavedIDs] = useState<Set<string>>(new Set());
  const [passedIDs, setPassedIDs] = useState<Set<string>>(new Set());
  const [filter, setFilter] = useState<InboxFilter>("open");

  function save(songID: string) {
    setSavedIDs((s) => { const n = new Set(s); n.add(songID); return n; });
    setPassedIDs((s) => { const n = new Set(s); n.delete(songID); return n; });
  }
  function pass(songID: string) {
    setPassedIDs((s) => { const n = new Set(s); n.add(songID); return n; });
    setSavedIDs((s) => { const n = new Set(s); n.delete(songID); return n; });
  }
  function reopen(songID: string) {
    setPassedIDs((s) => { const n = new Set(s); n.delete(songID); return n; });
    setSavedIDs((s) => { const n = new Set(s); n.delete(songID); return n; });
  }

  const filteredItems = items.filter((item) => {
    switch (filter) {
      case "saved": return savedIDs.has(item.song.song_id);
      case "passed": return passedIDs.has(item.song.song_id);
      case "open": return !savedIDs.has(item.song.song_id) && !passedIDs.has(item.song.song_id);
    }
  });

  const counts = {
    open: items.filter((i) => !savedIDs.has(i.song.song_id) && !passedIDs.has(i.song.song_id)).length,
    saved: savedIDs.size,
    passed: passedIDs.size,
  };

  return (
    <div className="view-stack">
      <div className="section-head">
        <div>
          <p className="eyebrow">EXECUTIVE INBOX</p>
          <h1>Submissions</h1>
        </div>
        <div className="metric-strip">
          <Metric label="New" value={items.filter((item) => item.new_since_last_listen).length} />
          <Metric label="Offline" value={2} />
        </div>
      </div>
      <div className="inbox-filter">
        {(["open", "saved", "passed"] as const).map((f) => (
          <button
            key={f}
            className={`inbox-filter-chip ${filter === f ? "on" : ""}`}
            onClick={() => setFilter(f)}
            aria-pressed={filter === f}
          >
            {f.toUpperCase()} <span className="count">{counts[f]}</span>
          </button>
        ))}
      </div>
      <div className="song-table">
        {filteredItems.length === 0 ? (
          <div className="inbox-empty">
            {filter === "open" && "Inbox zero. Everything's been triaged."}
            {filter === "saved" && "Nothing saved yet. Hit ✓ on a row to keep it for a listening session."}
            {filter === "passed" && "Nothing passed. Hit × to dismiss a submission."}
          </div>
        ) : (
          filteredItems.map((item) => {
            const isSaved = savedIDs.has(item.song.song_id);
            const isPassed = passedIDs.has(item.song.song_id);
            return (
              <article key={item.song.song_id} className="song-row">
                <div className="cover-art" aria-hidden="true" style={{ backgroundImage: coverGradient(item.song.song_id) }} />
                <button className="row-main row-open" onClick={() => onOpenSong(item.song.song_id)}>
                  <span className="row-title">{item.song.title}</span>
                  <span className="row-subtitle">Shared by {item.shared_by} · {item.room.title}</span>
                </button>
                <span className={`status-pill ${isSaved ? "saved" : isPassed ? "passed" : item.new_since_last_listen ? "red" : ""}`}>
                  {isSaved ? "Saved" : isPassed ? "Passed" : item.new_since_last_listen ? "New" : "Heard"}
                </span>
                <div className="row-actions">
                  {filter === "open" ? (
                    <>
                      <button className="icon-button" title="Save for a listening session" onClick={() => save(item.song.song_id)}>
                        <CheckCircle2 size={16} />
                      </button>
                      <button className="icon-button" title="Pass — dismiss without keeping" onClick={() => pass(item.song.song_id)}>
                        <X size={16} />
                      </button>
                      <button className="icon-button" title="Route to a collaborator (coming soon)" disabled>
                        <Send size={16} />
                      </button>
                    </>
                  ) : (
                    <button className="text-button" onClick={() => reopen(item.song.song_id)}>
                      Reopen
                    </button>
                  )}
                </div>
              </article>
            );
          })
        )}
      </div>
    </div>
  );
}

function LinkManager({ room, song, onRefresh }: { room: RoomPayload; song: Song; onRefresh: () => void }) {
  const [latestToken, setLatestToken] = useState<string | null>(null);
  const [analytics, setAnalytics] = useState<Awaited<ReturnType<typeof api.roomAnalytics>>>([]);
  const links = [...room.links, ...roomPayloadSongLinks(room, song.song_id)];

  useEffect(() => {
    void api.roomAnalytics(room.room.room_id).then(setAnalytics).catch(() => setAnalytics([]));
  }, [room.room.room_id]);

  async function createRoomLink() {
    const result = await api.createLink({
      workspace_id: room.room.workspace_id,
      target_type: "room",
      target_id: room.room.room_id,
      link_name: "Latest room playback",
      access_mode: "identity_required",
      version_policy: "latest_only",
      download_policy: "none",
      watermark_enabled: true,
      allow_comments: true,
      allow_approval: true,
      allow_forwarding: false,
    });
    setLatestToken(result.token);
    onRefresh();
  }

  return (
    <div className="view-stack">
      <div className="section-head">
        <div>
          <p className="eyebrow">SHARE LINKS</p>
          <h1>Policy Engine</h1>
        </div>
        <button className="accent-button" onClick={createRoomLink}>
          <Plus size={16} />
          Create Link
        </button>
      </div>
      {latestToken && <div className="notice-line">/shared/{latestToken}</div>}
      <div className="link-list">
        {links.map((link) => (
          <article key={link.link_id} className="link-row">
            <div className="link-body">
              <p className="eyebrow">{link.target_type.toUpperCase()}</p>
              <h2>{link.link_name ?? link.link_id}</h2>
              <div className="hero-meta">
                <span>{link.access_mode.replace("_", " ")}</span>
                <span>{link.version_policy.replace("_", " ")}</span>
                <span>{link.download_policy}</span>
                <span>{link.watermark_enabled ? "watermark tracing" : "watermark off"}</span>
              </div>
              <LinkActivity events={analytics.filter((e) => e.link_id === link.link_id)} versions={room.versions} songs={room.songs} />
            </div>
            <div className="row-actions">
              <a className="chrome-button" href={`/shared/${link.demo_token ?? ""}`}>
                <Link2 size={15} />
                Open
              </a>
              <button className="icon-button" title="Revoke" onClick={async () => {
                await api.revokeLink(link.link_id);
                onRefresh();
              }}>
                <LockKeyhole size={16} />
              </button>
            </div>
          </article>
        ))}
      </div>
    </div>
  );
}

function LinkActivity({
  events,
  versions,
  songs,
}: {
  events: Array<{
    event_id: string;
    event_type: string;
    actor_display_name: string;
    created_at: string;
    version_id?: string;
    song_id?: string;
    metadata: Record<string, unknown>;
  }>;
  versions: Version[];
  songs: Song[];
}) {
  if (events.length === 0) {
    return <p className="link-activity-empty">No plays yet.</p>;
  }
  const versionByID = new Map(versions.map((v) => [v.version_id, v]));
  const songByID = new Map(songs.map((s) => [s.song_id, s]));
  // Newest first
  const sorted = [...events].sort((a, b) => (a.created_at < b.created_at ? 1 : -1));
  return (
    <ul className="link-activity">
      {sorted.map((event) => {
        const version = event.version_id ? versionByID.get(event.version_id) : undefined;
        const song = event.song_id ? songByID.get(event.song_id) : undefined;
        const heardMs = typeof event.metadata?.heard_ms === "number" ? (event.metadata.heard_ms as number) : null;
        const verb = describeEvent(event.event_type);
        return (
          <li key={event.event_id}>
            <span className="who">{event.actor_display_name}</span>
            <span className="what">
              {verb}
              {song && <> · <b>{song.title}</b></>}
              {version && <> · {version.version_label}</>}
              {heardMs !== null && <> · heard {formatTimestamp(heardMs)}</>}
            </span>
            <span className="when">{formatRelative(event.created_at)}</span>
          </li>
        );
      })}
    </ul>
  );
}

function describeEvent(type: string): string {
  switch (type) {
    case "played_track": return "listened";
    case "opened_link": return "opened";
    case "downloaded_file": return "downloaded";
    case "approved_version": return "approved";
    case "requested_revision": return "asked for revisions";
    case "commented": return "left a note";
    case "mentioned_user": return "mentioned someone";
    default: return type.replace(/_/g, " ");
  }
}

function formatRelative(iso: string): string {
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return iso;
  const diffMs = Date.now() - then;
  const min = Math.max(0, Math.round(diffMs / 60000));
  if (min < 1) return "just now";
  if (min < 60) return `${min}m ago`;
  const hr = Math.round(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const days = Math.round(hr / 24);
  if (days < 7) return `${days}d ago`;
  const weeks = Math.round(days / 7);
  return `${weeks}w ago`;
}

/** Derive a stable hue (0–360) from a string id so every song has a distinct face. */
function hashHue(id: string): number {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) >>> 0;
  return h % 360;
}

/** Build a sleeve-mode gradient string keyed off the song id. */
function coverGradient(id: string): string {
  const hue = hashHue(id);
  const angle = 130 + (hashHue(id + "a") % 40);
  return `linear-gradient(${angle}deg,
    hsl(${(hue + 200) % 360} 8% 14%) 0%,
    hsl(${(hue + 30) % 360} 18% 32%) 32%,
    hsl(${hue} 28% 56%) 66%,
    hsl(${(hue + 25) % 360} 38% 78%) 100%)`;
}

/** Simple on-brand toggle switch — used in place of native checkboxes. */
function ToggleSwitch({
  label,
  checked,
  onChange,
}: {
  label: string;
  checked: boolean;
  onChange: (next: boolean) => void;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      className={`toggle-switch ${checked ? "on" : ""}`}
      onClick={() => onChange(!checked)}
    >
      <span className="track" aria-hidden="true">
        <span className="knob" />
      </span>
      <span className="toggle-label">{label}</span>
    </button>
  );
}

function roomPayloadSongLinks(room: RoomPayload, songID: string): ShareLink[] {
  return room.links.filter((link) => link.target_type === "song" && link.target_id === songID);
}

const SUGGESTED_QUERIES = [
  "Who hasn't heard v2?",
  "What notes are still open from v1?",
  "Who has approved what?",
  "What's blocking release readiness?",
] as const;

function AssistantPanel() {
  const [question, setQuestion] = useState<string>(SUGGESTED_QUERIES[0]);
  const [answer, setAnswer] = useState<Awaited<ReturnType<typeof api.ask>> | null>(null);
  const [isLoading, setIsLoading] = useState(false);

  async function submit(text = question) {
    setIsLoading(true);
    setQuestion(text);
    try {
      setAnswer(await api.ask(text));
    } finally {
      setIsLoading(false);
    }
  }

  useEffect(() => {
    void submit();
  }, []);

  return (
    <div className="view-stack">
      <div className="section-head">
        <div>
          <p className="eyebrow">READ-ONLY ASK</p>
          <h1>Workspace Questions</h1>
        </div>
        <Shield size={22} aria-label="Read-only — Ask cannot modify workspace state" />
      </div>
      <div className="ask-box">
        <input
          aria-label="Ask a question about the workspace"
          value={question}
          onChange={(event) => setQuestion(event.target.value)}
          onKeyDown={(event) => { if (event.key === "Enter") void submit(); }}
        />
        <button className="accent-button" onClick={() => void submit()}>
          <Send size={16} />
          Ask
        </button>
      </div>
      <div className="ask-chips">
        {SUGGESTED_QUERIES.map((q) => (
          <button key={q} className="ask-chip" onClick={() => void submit(q)}>{q}</button>
        ))}
      </div>
      <section className="answer-panel">
        <p>{isLoading ? "Checking the session…" : answer?.answer}</p>
        <div className="citation-row">
          {answer?.citations.map((citation) => (
            <span key={`${citation.type}-${citation.id}`} className="status-pill">
              {citation.type}: {citation.label}
            </span>
          ))}
        </div>
      </section>
    </div>
  );
}

function SharedListeningPage({ token }: { token: string }) {
  const [payload, setPayload] = useState<SharedPayload | null>(null);
  const [selectedSongID, setSelectedSongID] = useState<string | null>(null);
  const player = usePlayer();

  useEffect(() => {
    api.shared(token).then((nextPayload) => {
      setPayload(nextPayload);
      setSelectedSongID(nextPayload.songs[0]?.song_id ?? null);
    });
  }, [token]);

  const song = payload?.songs.find((item) => item.song_id === selectedSongID) ?? payload?.songs[0];
  const versions = payload && song ? versionsForSong(payload.versions, song.song_id) : [];
  const current = versions.find((version) => version.is_current) ?? versions.at(-1);
  const asset = payload ? assetForVersion(payload.assets, current) : undefined;

  return (
    <SharedListeningView
      payload={payload}
      song={song}
      versions={versions}
      current={current}
      asset={asset}
      selectedSongID={selectedSongID}
      onSelectSong={setSelectedSongID}
      onNotePosted={() => {
        if (payload) api.shared(token).then(setPayload);
      }}
      token={token}
    />
  );
}

function SharedListeningView({
  payload,
  song,
  versions,
  current,
  asset,
  selectedSongID,
  onSelectSong,
  onNotePosted,
  token,
}: {
  payload: SharedPayload | null;
  song: Song | undefined;
  versions: Version[];
  current: Version | undefined;
  asset: FileAsset | undefined;
  selectedSongID: string | null;
  onSelectSong: (id: string) => void;
  onNotePosted: () => void;
  token: string;
}) {
  const player = usePlayer();
  const [activeVersionID, setActiveVersionID] = useState<string | null>(current?.version_id ?? null);
  const [noteBody, setNoteBody] = useState("");
  const [posting, setPosting] = useState(false);
  const [approveState, setApproveState] = useState<"idle" | "pending" | "done">("idle");

  useEffect(() => {
    setActiveVersionID(current?.version_id ?? null);
    setApproveState("idle");
  }, [current?.version_id]);

  const activeVersion = versions.find((v) => v.version_id === activeVersionID) ?? current;
  const activeAsset = payload && activeVersion ? assetForVersion(payload.assets, activeVersion) : asset;
  const allowApproval = payload?.link.allow_approval ?? false;
  const alreadyApproved = !!activeVersion?.is_approved;

  async function approve() {
    if (!activeVersion || approveState !== "idle") return;
    setApproveState("pending");
    try {
      await api.sharedApprove(token, activeVersion.version_id);
      setApproveState("done");
      onNotePosted();
    } catch {
      setApproveState("idle");
    }
  }

  const songNotes = payload?.songs.length && song ? (payload as any).notes?.filter?.((n: VisibleNote) => n.song_id === song.song_id) ?? [] : [];

  async function submitNote() {
    if (!song || !activeVersion || !noteBody.trim()) return;
    setPosting(true);
    try {
      await api.createNote({
        song_id: song.song_id,
        anchor_version_id: activeVersion.version_id,
        body: noteBody.trim(),
        timestamp_start_ms: player.positionMs,
        scope: "song",
        visibility: "everyone",
      });
      setNoteBody("");
      onNotePosted();
    } finally {
      setPosting(false);
    }
  }

  if (!payload || !song || !current) {
    return (
      <div className="shared-page">
        <TopBar roomTitle="Loading…" error={null} />
        <main className="shared-main"><p className="muted">Opening private link…</p></main>
      </div>
    );
  }

  const catalogId = `WL · ${song.song_id.slice(-4).toUpperCase()}`;

  return (
    <div className="shared-page">
      <TopBar roomTitle="Private link" error={null} />
      <div className="recipient-layout">
        <section className="recipient-listen">
          <div className="recipient-crumb">
            <div className="left">
              <b>{catalogId} · {song.title}</b><br />
              {song.artist_display_name} · sent via private link · {payload.link.watermark_enabled ? "watermarked" : "open playback"}
            </div>
            <div className="stamps">
              {payload.link.version_policy === "latest_only" && (
                <Stamp kind="latest" tight straight>v{current.version_number} · Latest</Stamp>
              )}
              {!current.is_approved && <Stamp kind="notes-due" tight>Notes Welcome</Stamp>}
              {current.is_approved && <Stamp kind="approved" tight straight>Approved</Stamp>}
            </div>
          </div>

          <h1 className="recipient-title">{song.title}</h1>
          <div className="recipient-artist">
            {song.artist_display_name}{activeVersion?.version_label ? ` · ${activeVersion.version_label}` : ""}
          </div>

          <div className="recipient-cover" style={{ backgroundImage: coverGradient(song.song_id) }}>
            <div className="mono-corner"><MonoMark size={22} /></div>
          </div>

          <div className="recipient-meta-row">
            {activeAsset?.duration_ms && <span><span className="b">{formatTimestamp(activeAsset.duration_ms)}</span></span>}
            {song.bpm && <span><span className="b">{song.bpm}</span> BPM</span>}
            {song.song_key && <span><span className="b">{song.song_key}</span></span>}
            {activeAsset?.loudness_lufs && <span>{activeAsset.loudness_lufs} LUFS</span>}
            {activeAsset?.mime_type && <span>{activeAsset.mime_type.replace("audio/", "").toUpperCase()}</span>}
          </div>

          <div className="recipient-controls">
            <button
              className="play"
              aria-label={player.isPlaying ? "Pause" : "Play"}
              onClick={() => {
                if (player.isPlaying) player.toggle();
                else if (activeVersion && activeAsset) player.play(song, activeVersion, activeAsset);
              }}
            >
              {player.isPlaying ? <Pause size={18} /> : <Play size={18} />}
            </button>
            <div className="wave-host">
              <Waveform
                peaks={activeAsset?.waveform_peaks ?? []}
                positionMs={player.positionMs}
                durationMs={activeAsset?.duration_ms ?? 1}
                onSeek={player.seek}
              />
              <div className="time-row">
                <span>{formatTimestamp(player.positionMs)}</span>
                <span>{formatTimestamp(activeAsset?.duration_ms)}</span>
              </div>
            </div>
          </div>

          {allowApproval && (
            <div className="recipient-approve">
              {alreadyApproved ? (
                <Stamp kind="approved" straight>Approved · {activeVersion?.version_label}</Stamp>
              ) : approveState === "done" ? (
                <Stamp kind="approved" straight>Approved · just now</Stamp>
              ) : (
                <button
                  type="button"
                  className="accent-button approve"
                  onClick={approve}
                  disabled={approveState === "pending"}
                >
                  <CheckCircle2 size={16} />
                  {approveState === "pending" ? "Sending approval…" : `Approve ${activeVersion?.version_label ?? "version"}`}
                </button>
              )}
            </div>
          )}

          {payload.link.version_policy === "full_history" && versions.length > 1 && (
            <div className="recipient-versions">
              {versions.map((v) => (
                <span
                  key={v.version_id}
                  className={v.version_id === activeVersion?.version_id ? "cur" : ""}
                  onClick={() => {
                    setActiveVersionID(v.version_id);
                    const a = assetForVersion(payload.assets, v);
                    if (a) player.play(song, v, a);
                  }}
                  style={{ cursor: "pointer" }}
                >
                  {v.version_label ?? `v${v.version_number}`}
                  {v.version_id === current.version_id ? " · current" : ""}
                </span>
              ))}
            </div>
          )}

          {payload.songs.length > 1 && (
            <div className="song-table" style={{ marginTop: 32 }}>
              {payload.songs.map((item) => (
                <button
                  key={item.song_id}
                  className="song-row"
                  onClick={() => onSelectSong(item.song_id)}
                  style={item.song_id === selectedSongID ? { background: "rgba(0,0,0,.04)" } : undefined}
                >
                  <div className="cover-art" aria-hidden="true" style={{ backgroundImage: coverGradient(item.song_id) }} />
                  <div className="row-main">
                    <span className="row-title">{item.title}</span>
                    <span className="row-subtitle">{item.artist_display_name}</span>
                  </div>
                  <div className="row-current">
                    <span>WL · {item.song_id.slice(-4).toUpperCase()}</span>
                  </div>
                </button>
              ))}
            </div>
          )}
        </section>

        <aside className="recipient-notes">
          <h4>Notes · pinned to cue</h4>
          {songNotes.length === 0 ? (
            <div className="note" style={{ borderBottom: 0 }}>
              <div className="who"><span>Be the first.</span></div>
              <div className="what" style={{ color: "var(--pencil-cool)", marginTop: 8, fontSize: 13 }}>
                Tap a moment in the waveform, type a note, hit ↩.
              </div>
            </div>
          ) : (
            songNotes.map((note: VisibleNote) => (
              <div key={note.note_id} className="note">
                <div className="who">
                  <span>{note.author_guest_label ?? note.author_user_id ?? "Anonymous"}</span>
                  <small>{note.timestamp_start_ms != null ? formatTimestamp(note.timestamp_start_ms) : "general"}</small>
                </div>
                <div className="what">{note.body}</div>
                {note.timestamp_start_ms != null && (
                  <div className="pin">● pinned to {formatTimestamp(note.timestamp_start_ms)}</div>
                )}
              </div>
            ))
          )}
        </aside>
      </div>

      {/* STICKY COMPOSER */}
      <form
        className="sticky-composer"
        onSubmit={(e) => {
          e.preventDefault();
          void submitNote();
        }}
      >
        <span className="hint">↩ to send · <span className="pencue">@ {formatTimestamp(player.positionMs)}</span></span>
        <div className="field">
          <span className="pencue">@ {formatTimestamp(player.positionMs)}</span>
          <input
            value={noteBody}
            onChange={(e) => setNoteBody(e.target.value)}
            placeholder={`Note for ${song.artist_display_name ?? "the producer"}…`}
            disabled={posting}
          />
        </div>
        <button type="button" className="mic" title="Voice memo (coming soon)" aria-label="Record voice memo">●</button>
        <button type="submit" className="send" disabled={posting || !noteBody.trim()}>
          {posting ? "…" : "Note"}
        </button>
      </form>

      <MiniPlayer />
    </div>
  );
}

function MiniPlayer() {
  const player = usePlayer();
  if (!player.song || !player.version || !player.asset) return null;
  return (
    <aside className="mini-player">
      <button className="icon-button active" title={player.isPlaying ? "Pause" : "Play"} onClick={player.toggle}>
        {player.isPlaying ? <Pause size={16} /> : <Play size={16} />}
      </button>
      <div className="mini-copy">
        <span>{player.song.title}</span>
        <small>{player.version.version_label} · {formatTimestamp(player.positionMs)}</small>
      </div>
      <Waveform peaks={player.asset.waveform_peaks} compact positionMs={player.positionMs} durationMs={player.asset.duration_ms} onSeek={player.seek} />
    </aside>
  );
}

function Waveform({
  peaks,
  compact = false,
  positionMs = 0,
  durationMs = 1,
  onSeek,
}: {
  peaks: number[];
  compact?: boolean;
  positionMs?: number;
  durationMs?: number;
  onSeek?: (positionMs: number) => void;
}) {
  const progress = Math.max(0, Math.min(1, positionMs / durationMs));
  const bars = peaks.length > 0 ? peaks : Array.from({ length: compact ? 32 : 96 }, (_, index) => Math.abs(Math.sin(index)));
  return (
    <button
      className={`waveform ${compact ? "compact" : ""}`}
      onClick={(event) => {
        if (!onSeek) return;
        const rect = event.currentTarget.getBoundingClientRect();
        const x = event.clientX - rect.left;
        onSeek((x / rect.width) * durationMs);
      }}
      aria-label="Waveform"
    >
      <span className="playhead" style={{ left: `${progress * 100}%` }} />
      {bars.map((peak, index) => (
        <span
          key={index}
          className={index / bars.length <= progress ? "played" : ""}
          style={{ height: `${Math.max(8, peak * (compact ? 38 : 86))}px` }}
        />
      ))}
    </button>
  );
}

function Metric({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="metric">
      <span>{String(value).padStart(2, "0")}</span>
      <small>{label}</small>
    </div>
  );
}

/* =====================================================================
   Brand primitives — Wordmark, MonoMark, Stamp
   ===================================================================== */

function Wordmark({ size = "md", title }: { size?: "sm" | "md" | "lg"; title?: string }) {
  return (
    <span className={`wordmark wordmark-${size}`} title={title}>
      WHITE LABEL<span className="cur" />
    </span>
  );
}

function MonoMark({ size = 16 }: { size?: number }) {
  return (
    <span className="mono-mark" style={{ fontSize: size }}>
      WL<span className="u" />
    </span>
  );
}

type StampKind = "private" | "notes-due" | "approved" | "latest";

function Stamp({
  kind = "private",
  tight = false,
  straight = false,
  children,
}: {
  kind?: StampKind;
  tight?: boolean;
  straight?: boolean;
  children: ReactNode;
}) {
  const classes = ["stamp", kind, tight ? "tight" : "", straight ? "straight" : ""]
    .filter(Boolean)
    .join(" ");
  return <span className={classes}>{children}</span>;
}

