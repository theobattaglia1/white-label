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
import { api, assetForVersion, type RoomPayload, type SharedPayload, type SongPayload, versionsForSong } from "./api";
import { usePlayer } from "./player";

type ViewMode = "room" | "song" | "compare" | "inbox" | "links" | "assistant";

export function App() {
  const sharedToken = window.location.pathname.match(/^\/shared\/([^/]+)/)?.[1];
  if (sharedToken) return <SharedListeningPage token={sharedToken} />;
  return <WorkspaceApp />;
}

function WorkspaceApp() {
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
      <TopBar roomTitle={roomPayload?.room.title ?? "Private Workspace"} error={error} />
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
          {mode === "compare" && songPayload && <ComparisonMode payload={songPayload} />}
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

function TopBar({ roomTitle, error }: { roomTitle: string; error: string | null }) {
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
              <div className="cover-art" aria-hidden="true">
                <span>{song.title.slice(0, 2).toUpperCase()}</span>
              </div>
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
  const [noteTimestamp, setNoteTimestamp] = useState<number | undefined>(72000);
  const [noteBody, setNoteBody] = useState("");
  const player = usePlayer();

  const activeVersion = payload.versions.find((version) => version.version_id === activeVersionID) ?? payload.currentVersion;
  const activeAsset = assetForVersion(payload.assets, activeVersion);
  const currentAsset = assetForVersion(payload.assets, payload.currentVersion);

  useEffect(() => {
    setActiveVersionID(payload.currentVersion?.version_id ?? payload.versions[0]?.version_id);
  }, [payload.song.song_id, payload.currentVersion?.version_id]);

  async function submitNote() {
    if (!activeVersion || !noteBody.trim()) return;
    await api.createNote({
      song_id: payload.song.song_id,
      anchor_version_id: activeVersion.version_id,
      body: noteBody.trim(),
      timestamp_start_ms: noteTimestamp,
      scope: "song",
      visibility: "everyone",
    });
    setNoteBody("");
    setNoteDraftOpen(false);
    onRefresh();
  }

  async function addDemoVersion() {
    await api.addVersion(payload.song.song_id, {
      filename: `${payload.song.title} mix v${payload.versions.length + 1}.wav`,
      label: `Mix v${payload.versions.length + 1}`,
      type: "mix",
      duration_ms: (currentAsset?.duration_ms ?? 190000) + 4000,
      loudness_lufs: -13.4,
    });
    onRefresh();
  }

  const openNotes = payload.notes.filter((n) => n.status === "open");
  const hasNotesDue = openNotes.length > 0;
  const catalogId = `WL · ${payload.song.song_id.slice(-4).toUpperCase()}`;
  const versionLabel = activeVersion?.version_label ?? "v1";

  return (
    <div className="view-stack">
      <div className="song-card-hero">
        <div className="breadcrumb">
          {payload.song.project_name ?? "Room"} / <b>{payload.song.title}</b> / {versionLabel}
        </div>
        <div className="song-card-frame">
          {hasNotesDue && (
            <span className="nd-stamp">
              <Stamp kind="notes-due">Notes Due · {openNotes.length}</Stamp>
            </span>
          )}
          <div className="song-card-body">
            <div className="song-card-cover">
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
                  className="btn red"
                  onClick={() => activeVersion && activeAsset && player.play(payload.song, activeVersion, activeAsset)}
                >
                  <Play size={14} /> Play
                </button>
                <button className="btn" onClick={addDemoVersion}>
                  <Upload size={14} /> Upload revision
                </button>
                <button
                  className="btn ghost"
                  onClick={() => {
                    setNoteTimestamp(player.positionMs);
                    setNoteDraftOpen(true);
                  }}
                >
                  <MessageSquare size={14} /> Add note
                </button>
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

      {noteDraftOpen && (
        <div className="note-composer">
          <div>
            <p className="eyebrow">NOTE AT {formatTimestamp(noteTimestamp)}</p>
            <input value={noteBody} onChange={(event) => setNoteBody(event.target.value)} placeholder="Pull the snare 1dB at the bridge…" autoFocus />
          </div>
          <div className="composer-actions">
            <button className="icon-button" title="Dismiss" onClick={() => setNoteDraftOpen(false)}>
              <X size={16} />
            </button>
            <button className="accent-button" onClick={submitNote}>
              <Send size={15} />
              Send
            </button>
          </div>
        </div>
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
          onSetCurrent={async (versionID) => {
            await api.setCurrent(versionID);
            onRefresh();
          }}
        />
        <NotesPanel notes={payload.notes} onRefresh={onRefresh} />
        <DeliverablesPanel payload={payload} />
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
            <div className="version-number">{String(version.version_number).padStart(2, "0")}</div>
            <div className="version-body">
              <span>{version.version_label}</span>
              <small>{version.type} · {asset?.loudness_lufs} LUFS · {formatTimestamp(asset?.duration_ms)}</small>
            </div>
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

function ComparisonMode({ payload }: { payload: SongPayload }) {
  const [leftID, setLeftID] = useState(payload.versions[0]?.version_id);
  const [rightID, setRightID] = useState(payload.currentVersion?.version_id);
  const player = usePlayer();
  const left = payload.versions.find((version) => version.version_id === leftID) ?? payload.versions[0];
  const right = payload.versions.find((version) => version.version_id === rightID) ?? payload.versions.at(-1);
  const leftAsset = assetForVersion(payload.assets, left);
  const rightAsset = assetForVersion(payload.assets, right);
  const gainFor = (asset?: FileAsset) => (asset ? (-14 - asset.loudness_lufs).toFixed(1) : "0.0");

  return (
    <div className="view-stack">
      <div className="section-head">
        <div>
          <p className="eyebrow">COMPARISON MODE</p>
          <h1>{payload.song.title}</h1>
        </div>
        <label className="toggle">
          <input type="checkbox" checked={player.loudnessMatched} onChange={(event) => player.setLoudnessMatched(event.target.checked)} />
          <span>Loudness Match</span>
        </label>
      </div>
      <div className="compare-grid">
        <CompareDeck title="A" song={payload.song} version={left} asset={leftAsset} selectedID={leftID} versions={payload.versions} onSelect={setLeftID} gain={gainFor(leftAsset)} />
        <CompareDeck title="B" song={payload.song} version={right} asset={rightAsset} selectedID={rightID} versions={payload.versions} onSelect={setRightID} gain={gainFor(rightAsset)} />
      </div>
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
  gain,
}: {
  title: string;
  song: Song;
  version?: Version;
  asset?: FileAsset;
  selectedID?: string;
  versions: Version[];
  onSelect: (id: string) => void;
  gain: string;
}) {
  const player = usePlayer();
  return (
    <section className="compare-deck">
      <div className="panel-topline">
        <div>
          <p className="eyebrow">DECK {title}</p>
          <h2>{version?.version_label}</h2>
        </div>
        <button className="icon-button" title="Play deck" onClick={() => version && asset && player.play(song, version, asset)}>
          {player.isPlaying && player.version?.version_id === version?.version_id ? <Pause size={17} /> : <Play size={17} />}
        </button>
      </div>
      <select value={selectedID} onChange={(event) => onSelect(event.target.value)}>
        {versions.map((item) => (
          <option key={item.version_id} value={item.version_id}>
            {item.version_label}
          </option>
        ))}
      </select>
      <Waveform peaks={asset?.waveform_peaks ?? []} positionMs={player.positionMs} durationMs={asset?.duration_ms ?? 1} onSeek={player.seek} />
      <div className="time-row">
        <span>{formatTimestamp(player.positionMs)}</span>
        <span>{asset?.loudness_lufs} LUFS · gain {gain} dB</span>
      </div>
    </section>
  );
}

function InboxView({
  items,
  onOpenSong,
}: {
  items: Awaited<ReturnType<typeof api.inbox>>;
  onOpenSong: (songID: string) => void;
}) {
  return (
    <div className="view-stack">
      <div className="section-head">
        <div>
          <p className="eyebrow">EXECUTIVE INBOX</p>
          <h1>Received Music</h1>
        </div>
        <div className="metric-strip">
          <Metric label="New" value={items.filter((item) => item.new_since_last_listen).length} />
          <Metric label="Offline" value={2} />
        </div>
      </div>
      <div className="song-table">
        {items.map((item) => (
          <article key={item.song.song_id} className="song-row">
            <div className="cover-art" aria-hidden="true">
              <span>{item.song.title.slice(0, 2).toUpperCase()}</span>
            </div>
            <button className="row-main row-open" onClick={() => onOpenSong(item.song.song_id)}>
              <span className="row-title">{item.song.title}</span>
              <span className="row-subtitle">Shared by {item.shared_by} · {item.room.title}</span>
            </button>
            <span className={`status-pill ${item.new_since_last_listen ? "red" : ""}`}>{item.new_since_last_listen ? "New" : "Heard"}</span>
            <div className="row-actions">
              <button className="icon-button" title="Save">
                <CheckCircle2 size={16} />
              </button>
              <button className="icon-button" title="Pass">
                <X size={16} />
              </button>
              <button className="icon-button" title="Route">
                <Send size={16} />
              </button>
            </div>
          </article>
        ))}
      </div>
    </div>
  );
}

function LinkManager({ room, song, onRefresh }: { room: RoomPayload; song: Song; onRefresh: () => void }) {
  const [latestToken, setLatestToken] = useState<string | null>(null);
  const links = [...room.links, ...roomPayloadSongLinks(room, song.song_id)];

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
            <div>
              <p className="eyebrow">{link.target_type.toUpperCase()}</p>
              <h2>{link.link_name ?? link.link_id}</h2>
              <div className="hero-meta">
                <span>{link.access_mode.replace("_", " ")}</span>
                <span>{link.version_policy.replace("_", " ")}</span>
                <span>{link.download_policy}</span>
                <span>{link.watermark_enabled ? "watermark tracing" : "watermark off"}</span>
              </div>
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

function roomPayloadSongLinks(room: RoomPayload, songID: string): ShareLink[] {
  return room.links.filter((link) => link.target_type === "song" && link.target_id === songID);
}

function AssistantPanel() {
  const [question, setQuestion] = useState("Who hasn't heard v2?");
  const [answer, setAnswer] = useState<Awaited<ReturnType<typeof api.ask>> | null>(null);
  const [isLoading, setIsLoading] = useState(false);

  async function submit() {
    setIsLoading(true);
    setAnswer(await api.ask(question));
    setIsLoading(false);
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
        <Shield size={22} />
      </div>
      <div className="ask-box">
        <input value={question} onChange={(event) => setQuestion(event.target.value)} />
        <button className="accent-button" onClick={submit}>
          <Send size={16} />
          Ask
        </button>
      </div>
      <section className="answer-panel">
        <p>{isLoading ? "Reading records..." : answer?.answer}</p>
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

  useEffect(() => {
    setActiveVersionID(current?.version_id ?? null);
  }, [current?.version_id]);

  const activeVersion = versions.find((v) => v.version_id === activeVersionID) ?? current;
  const activeAsset = payload && activeVersion ? assetForVersion(payload.assets, activeVersion) : asset;

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

          <div className="recipient-cover">
            <div className="mono-corner"><MonoMark size={22} /></div>
          </div>

          <h1 className="recipient-title">{song.title}</h1>
          <div className="recipient-artist">
            {song.artist_display_name}{activeVersion?.version_label ? ` · ${activeVersion.version_label}` : ""}
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
                  <div className="cover-art no-art" aria-hidden="true">
                    <span>{item.title.slice(0, 2).toUpperCase()}</span>
                  </div>
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

