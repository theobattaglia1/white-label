import { Fragment, useEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";
import {
  Bell,
  Bookmark,
  BookmarkCheck,
  CheckCircle2,
  CircleDashed,
  GitCompare,
  History,
  Home,
  Inbox,
  Menu,
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
  SkipBack,
  SkipForward,
  Upload,
  UserRound,
  Users,
  X,
} from "lucide-react";
import { formatTimestamp, type FileAsset, type ShareLink, type Song, type Version, type VersionType, type VisibleNote } from "@pmw/shared";
import { api, assetForVersion, uploadAudio, type MyPinsPayload, type RecentItem, type RoomPayload, type SharedPayload, type SongPayload, versionsForSong } from "./api";
import { catalogIdFor, catalogNumber, computeVersionDelta, coverGradient, formatHeardDisplay, formatVersionDelta, hashHue, heardByCount, humanizeVersionType, matchesSmart } from "./utils";
import { usePlayer } from "./player";
import { LivingCover, coverHue, hueAt, seedLabel, hexToHue, MOTION_MODES, TONE_MODES } from "./LivingCover";
import { onAuthChange, signOut, getSession } from "./auth";
import { SignIn } from "./SignIn";
import { PlaybackWordmark, PlaybackMark } from "./PlaybackWordmark";
import { FirstListenPage, ListeningRoomPage } from "./ListeningFlows";
import type { Session } from "@supabase/supabase-js";

type ViewMode = "home" | "library" | "room" | "compare" | "inbox" | "links" | "assistant" | "playlist" | "team";

export function App() {
  const firstListenToken = window.location.pathname.match(/^\/listen\/([^/]+)/)?.[1];
  if (firstListenToken) return <FirstListenPage token={firstListenToken} />;
  const listeningRoomToken = window.location.pathname.match(/^\/room\/([^/]+)/)?.[1];
  if (listeningRoomToken) return <ListeningRoomPage token={listeningRoomToken} />;
  const sharedToken = window.location.pathname.match(/^\/shared\/([^/]+)/)?.[1];
  if (sharedToken) return <SharedListeningPage token={sharedToken} />;
  const joinToken = window.location.pathname.match(/^\/join\/([^/]+)/)?.[1];
  if (joinToken) return <JoinPage token={joinToken} />;
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
      <div style={{ display: "grid", placeItems: "center", minHeight: "100vh", background: "#0c0907" }}>
        <PlaybackWordmark size="md" />
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
  const [mode, setMode] = useState<ViewMode>("home");
  const [selectedSongID, setSelectedSongID] = useState("song-midnight");
  const [activeRoomID, setActiveRoomID] = useState("room-hudson-ingram-lp");
  const [overlayOpen, setOverlayOpen] = useState(false);
  const [overlayTab, setOverlayTab] = useState<"player" | "workspace">("player");
  const [memberNumber, setMemberNumber] = useState<number | null>(null);
  const [paletteOpen, setPaletteOpen] = useState(false);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPaletteOpen((o) => !o);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
  const [activePlaylistID, setActivePlaylistID] = useState<string | null>(null);
  const [inboxItems, setInboxItems] = useState<Awaited<ReturnType<typeof api.inbox>>>([]);
  const [roomsSummary, setRoomsSummary] = useState<Awaited<ReturnType<typeof api.roomsSummary>>>([]);
  const [playlists, setPlaylists] = useState<Awaited<ReturnType<typeof api.playlists>>>([]);
  const [savedViews, setSavedViews] = useState<Awaited<ReturnType<typeof api.savedViews>>>([]);
  const [activeSmartViewID, setActiveSmartViewID] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  // === Pin state — global so all surfaces stay in sync =================
  const [pinnedSongIDs, setPinnedSongIDs] = useState<Set<string>>(new Set());
  const [pinnedPlaylistIDs, setPinnedPlaylistIDs] = useState<Set<string>>(new Set());
  const [pinnedProjectIDs, setPinnedProjectIDs] = useState<Set<string>>(new Set());

  async function refreshPins() {
    try {
      const p = await api.getMyPins();
      setPinnedSongIDs(new Set(p.songs.map((s) => s.song_id)));
      setPinnedPlaylistIDs(new Set(p.playlists.map((pl) => pl.playlist_id)));
      setPinnedProjectIDs(new Set(p.projects.map((pr) => pr.project_id)));
    } catch {
      // Pin endpoint not yet deployed — ignore gracefully
    }
  }

  async function toggleSongPin(songID: string) {
    const wasPinned = pinnedSongIDs.has(songID);
    // Optimistic update
    setPinnedSongIDs((prev) => {
      const next = new Set(prev);
      if (wasPinned) next.delete(songID); else next.add(songID);
      return next;
    });
    try {
      if (wasPinned) {
        await api.unpinSong("wsp-amf-private", songID);
      } else {
        await api.pinSong("wsp-amf-private", songID);
      }
      void refreshPins();
    } catch {
      // Revert optimistic update on failure
      setPinnedSongIDs((prev) => {
        const next = new Set(prev);
        if (wasPinned) next.add(songID); else next.delete(songID);
        return next;
      });
    }
  }

  async function togglePlaylistPin(playlistID: string) {
    const wasPinned = pinnedPlaylistIDs.has(playlistID);
    setPinnedPlaylistIDs((prev) => {
      const next = new Set(prev);
      if (wasPinned) next.delete(playlistID); else next.add(playlistID);
      return next;
    });
    try {
      if (wasPinned) {
        await api.unpinPlaylist("wsp-amf-private", playlistID);
      } else {
        await api.pinPlaylist("wsp-amf-private", playlistID);
      }
      void refreshPins();
    } catch {
      setPinnedPlaylistIDs((prev) => {
        const next = new Set(prev);
        if (wasPinned) next.add(playlistID); else next.delete(playlistID);
        return next;
      });
    }
  }

  async function toggleProjectPin(projectID: string) {
    const wasPinned = pinnedProjectIDs.has(projectID);
    setPinnedProjectIDs((prev) => {
      const next = new Set(prev);
      if (wasPinned) next.delete(projectID); else next.add(projectID);
      return next;
    });
    try {
      if (wasPinned) {
        await api.unpinProject("wsp-amf-private", projectID);
      } else {
        await api.pinProject("wsp-amf-private", projectID);
      }
      void refreshPins();
    } catch {
      setPinnedProjectIDs((prev) => {
        const next = new Set(prev);
        if (wasPinned) next.add(projectID); else next.delete(projectID);
        return next;
      });
    }
  }

  async function refresh(nextSongID = selectedSongID, nextRoomID = activeRoomID) {
    try {
      const [room, summary, allPlaylists, allSavedViews] = await Promise.all([
        api.room(nextRoomID),
        api.roomsSummary(),
        api.playlists(),
        api.savedViews(),
      ]);
      setRoomPayload(room);
      setRoomsSummary(summary);
      setPlaylists(allPlaylists);
      setSavedViews(allSavedViews);
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
    void refresh(selectedSongID, activeRoomID);
    void refreshPins();
    // Fetch the current user's member number once on mount
    api.me()
      .then((res) => { if (res.user?.member_number != null) setMemberNumber(res.user.member_number); })
      .catch(() => {});
  }, []);

  // Poll for note/approval updates while the overlay is open (15s interval).
  // Keeps collaborator activity visible without a full websocket setup.
  useEffect(() => {
    if (!overlayOpen || !selectedSongID) return;
    const id = setInterval(() => {
      api.song(selectedSongID).then(setSongPayload).catch(() => {});
    }, 15_000);
    return () => clearInterval(id);
  }, [overlayOpen, selectedSongID]);

  const selectedSong = roomPayload?.songs.find((song) => song.song_id === selectedSongID) ?? songPayload?.song;

  function openSong(songID: string) {
    setSelectedSongID(songID);
    void refresh(songID, activeRoomID);
    setOverlayTab("workspace");
    setOverlayOpen(true);
  }

  // The immersive "now playing" surface — what the mini-player opens.
  function openNowPlaying(songID: string) {
    setSelectedSongID(songID);
    void refresh(songID, activeRoomID);
    setOverlayTab("player");
    setOverlayOpen(true);
  }

  function openRoom(roomID: string) {
    setActiveRoomID(roomID);
    setMode("room");
    setActivePlaylistID(null);
    void refresh(selectedSongID, roomID);
  }

  function openPlaylist(playlistID: string) {
    setActivePlaylistID(playlistID);
    setActiveSmartViewID(null);
    setMode("playlist");
  }

  function openSmartView(viewID: string) {
    setActiveSmartViewID(viewID);
    setActivePlaylistID(null);
    setMode("library");
  }

  return (
    <div className="app-shell">
      <TopBar
        roomTitle={roomPayload?.room.title ?? "Private Workspace"}
        error={error}
        onSignOut={onSignOut}
        onOpenSearch={() => setPaletteOpen(true)}
        mode={mode}
        setMode={setMode}
        rooms={roomsSummary}
        memberNumber={memberNumber}
      />
      <main className="workspace-grid">
        <Sidebar
          mode={mode}
          setMode={setMode}
          room={roomPayload}
          rooms={roomsSummary}
          activeRoomID={activeRoomID}
          onSelectRoom={openRoom}
          playlists={playlists}
          activePlaylistID={activePlaylistID}
          onSelectPlaylist={openPlaylist}
          savedViews={savedViews}
          activeSmartViewID={activeSmartViewID}
          onSelectSmartView={openSmartView}
          selectedSongID={selectedSongID}
          onSelectSong={openSong}
          pinnedPlaylistIDs={pinnedPlaylistIDs}
          onTogglePlaylistPin={togglePlaylistPin}
        />
        <section className="workspace-main">
          {mode === "home" && (
            <HomeView
              onOpenSong={openSong}
              onOpenRoom={openRoom}
              onOpenProject={(id) => openSong(id)}
              onOpenPlaylist={openPlaylist}
              onRefreshPlaylists={() => api.playlists().then(setPlaylists)}
              pinnedSongIDs={pinnedSongIDs}
              pinnedPlaylistIDs={pinnedPlaylistIDs}
              pinnedProjectIDs={pinnedProjectIDs}
              onToggleSongPin={toggleSongPin}
              onTogglePlaylistPin={togglePlaylistPin}
              onToggleProjectPin={toggleProjectPin}
            />
          )}
          {mode === "library" && (
            <LibraryView
              onOpenSong={openSong}
              playlists={playlists}
              onRefreshPlaylists={() => api.playlists().then(setPlaylists)}
              smartView={savedViews.find((v) => v.view_id === activeSmartViewID) ?? null}
              onClearSmart={() => setActiveSmartViewID(null)}
              pinnedSongIDs={pinnedSongIDs}
              onToggleSongPin={toggleSongPin}
            />
          )}
          {mode === "room" && roomPayload && (
            <RoomView payload={roomPayload} onOpenSong={openSong} />
          )}
          {mode === "compare" && songPayload && <ComparisonMode payload={songPayload} onRefresh={() => refresh(songPayload.song.song_id)} />}
          {mode === "inbox" && <InboxView items={inboxItems} onOpenSong={openSong} />}
          {mode === "links" && roomPayload && selectedSong && (
            <LinkManager room={roomPayload} song={selectedSong} onRefresh={() => refresh(selectedSong.song_id)} />
          )}
          {mode === "assistant" && (
            <AssistantPanel
              songID={selectedSongID}
              songTitle={selectedSong?.title}
              versionID={songPayload?.currentVersion?.version_id}
              versionLabel={songPayload?.currentVersion?.version_label}
            />
          )}
          {mode === "playlist" && activePlaylistID && (
            <PlaylistView
              playlistID={activePlaylistID}
              onOpenSong={openSong}
              onRefreshPlaylists={() => api.playlists().then(setPlaylists)}
            />
          )}
          {mode === "team" && <TeamView />}
        </section>
      </main>
      {!overlayOpen && <MiniPlayer onOpenSong={openNowPlaying} />}
      <SongOverlay
        open={overlayOpen}
        payload={songPayload}
        tab={overlayTab}
        onTabChange={setOverlayTab}
        onClose={() => setOverlayOpen(false)}
        playlists={playlists}
        onRefresh={() => songPayload && refresh(songPayload.song.song_id)}
        onRefreshPlaylists={() => api.playlists().then(setPlaylists)}
        onOpenSong={openSong}
      />
      <CommandPalette
        open={paletteOpen}
        onClose={() => setPaletteOpen(false)}
        rooms={roomsSummary}
        playlists={playlists}
        savedViews={savedViews}
        onOpenSong={openSong}
        onOpenRoom={openRoom}
        onOpenPlaylist={openPlaylist}
        onSetMode={setMode}
      />
    </div>
  );
}

type CmdItem = { id: string; label: string; sub?: string; kind: string; run: () => void };

function CommandPalette({
  open,
  onClose,
  rooms,
  playlists,
  savedViews,
  onOpenSong,
  onOpenRoom,
  onOpenPlaylist,
  onSetMode,
}: {
  open: boolean;
  onClose: () => void;
  rooms: Awaited<ReturnType<typeof api.roomsSummary>>;
  playlists: Awaited<ReturnType<typeof api.playlists>>;
  savedViews: Awaited<ReturnType<typeof api.savedViews>>;
  onOpenSong: (id: string) => void;
  onOpenRoom: (id: string) => void;
  onOpenPlaylist: (id: string) => void;
  onSetMode: (m: ViewMode) => void;
}) {
  const [q, setQ] = useState("");
  const [sel, setSel] = useState(0);
  const [library, setLibrary] = useState<Awaited<ReturnType<typeof api.workspaceLibrary>>>([]);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!open) return;
    setQ("");
    setSel(0);
    api.workspaceLibrary().then(setLibrary).catch(() => {});
    const t = setTimeout(() => inputRef.current?.focus(), 20);
    return () => clearTimeout(t);
  }, [open]);

  const nav: CmdItem[] = [
    { id: "go-home", label: "Home", kind: "Go to", run: () => onSetMode("home") },
    { id: "go-library", label: "All Songs", kind: "Go to", run: () => onSetMode("library") },
    { id: "go-inbox", label: "Inbox", kind: "Go to", run: () => onSetMode("inbox") },
    { id: "go-compare", label: "Compare", kind: "Go to", run: () => onSetMode("compare") },
    { id: "go-links", label: "Links", kind: "Go to", run: () => onSetMode("links") },
    { id: "go-ask", label: "Ask", kind: "Go to", run: () => onSetMode("assistant") },
    { id: "go-team", label: "Team", kind: "Go to", run: () => onSetMode("team") },
  ];
  const roomItems: CmdItem[] = rooms.map((r) => ({ id: `room-${r.room_id}`, label: r.title, sub: `${r.song_count} song${r.song_count === 1 ? "" : "s"}`, kind: "Room", run: () => onOpenRoom(r.room_id) }));
  const songItems: CmdItem[] = library.map((it) => ({ id: `song-${it.song.song_id}`, label: it.song.title, sub: it.song.artist_display_name, kind: "Song", run: () => onOpenSong(it.song.song_id) }));
  const plItems: CmdItem[] = playlists.map((p) => ({ id: `pl-${p.playlist_id}`, label: p.title, sub: `${p.item_count} track${p.item_count === 1 ? "" : "s"}`, kind: "Playlist", run: () => onOpenPlaylist(p.playlist_id) }));
  const svItems: CmdItem[] = savedViews.map((v) => ({ id: `sv-${v.view_id}`, label: v.name, sub: "Smart view", kind: "View", run: () => onSetMode("library") }));

  const ql = q.trim().toLowerCase();
  const all = [...nav, ...roomItems, ...songItems, ...plItems, ...svItems];
  const results = ql
    ? all.filter((it) => it.label.toLowerCase().includes(ql) || (it.sub ?? "").toLowerCase().includes(ql) || it.kind.toLowerCase().includes(ql)).slice(0, 40)
    : all.slice(0, 24);

  if (!open) return null;

  const choose = (it?: CmdItem) => { if (it) it.run(); onClose(); };

  return (
    <div className="cmdk-overlay" onClick={onClose}>
      <div className="cmdk" onClick={(e) => e.stopPropagation()} role="dialog" aria-modal="true" aria-label="Command palette">
        <div className="cmdk-input">
          <Search size={16} />
          <input
            ref={inputRef}
            value={q}
            onChange={(e) => { setQ(e.target.value); setSel(0); }}
            placeholder="Search rooms, songs, playlists…"
            onKeyDown={(e) => {
              if (e.key === "Escape") onClose();
              else if (e.key === "ArrowDown") { e.preventDefault(); setSel((s) => Math.min(s + 1, results.length - 1)); }
              else if (e.key === "ArrowUp") { e.preventDefault(); setSel((s) => Math.max(s - 1, 0)); }
              else if (e.key === "Enter") { e.preventDefault(); choose(results[sel]); }
            }}
          />
          <kbd>esc</kbd>
        </div>
        <div className="cmdk-results">
          {results.length === 0 && <div className="cmdk-empty">No matches</div>}
          {results.map((it, i) => (
            <button key={it.id} className={`cmdk-item ${i === sel ? "on" : ""}`} onMouseEnter={() => setSel(i)} onClick={() => choose(it)}>
              <span className="cmdk-kind">{it.kind}</span>
              <span className="cmdk-label">{it.label}</span>
              {it.sub && <span className="cmdk-sub">{it.sub}</span>}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

function TopBar({
  error,
  onSignOut,
  onOpenSearch,
  mode,
  setMode,
  rooms = [],
  memberNumber = null,
}: {
  roomTitle: string;
  error: string | null;
  onSignOut?: () => void;
  onOpenSearch?: () => void;
  mode?: ViewMode;
  setMode?: (m: ViewMode) => void;
  rooms?: Awaited<ReturnType<typeof api.roomsSummary>>;
  memberNumber?: number | null;
}) {
  const player = usePlayer();
  const [menuOpen, setMenuOpen] = useState(false);
  const nav: Array<[ViewMode, string, typeof Home]> = [
    ["home", "Home", Home],
    ["library", "All Songs", ListMusic],
    ["inbox", "Inbox", Inbox],
    ["compare", "Compare", GitCompare],
    ["links", "Links", Link2],
    ["assistant", "Ask", MessageSquare],
    ["team", "Team", Users],
  ];
  const openRooms = rooms.reduce((a, r) => a + (r.open_note_count > 0 ? 1 : 0), 0);
  return (
    <header className="top-bar v3-bar">
      <div className="tb-left">
        <button className={`tb-burger ${menuOpen ? "on" : ""}`} onClick={() => setMenuOpen((o) => !o)} aria-label="Menu" aria-expanded={menuOpen}>
          <Menu size={18} />
        </button>
        <span className="tb-wm">
          <Wordmark size="sm" isPlaying={player.isPlaying} />
          {memberNumber != null && (
            <span className="tb-cat">PB·{String(memberNumber).padStart(3, "0")}</span>
          )}
        </span>
        {menuOpen && (
          <>
            <div className="tb-menu-scrim" onClick={() => setMenuOpen(false)} />
            <nav className="tb-menu">
              {nav.map(([id, label, Icon]) => (
                <button key={id} className={`tb-menu-item ${mode === id ? "on" : ""}`} onClick={() => { setMode?.(id); setMenuOpen(false); }}>
                  <Icon size={15} /><span>{label}</span>
                </button>
              ))}
              <div className="tb-menu-rule" />
              <button className="tb-menu-item dim" onClick={() => { setMenuOpen(false); onOpenSearch?.(); }}>
                <Search size={15} /><span>Search</span><kbd>⌘K</kbd>
              </button>
            </nav>
          </>
        )}
      </div>
      <button className="tb-search" onClick={onOpenSearch} aria-label="Search rooms, songs, links">
        <Search size={15} />
        <span>Search rooms, songs, links</span>
        <kbd>⌘K</kbd>
      </button>
      <div className="tb-right">
        {error && <span className="error-pill">{error}</span>}
        <span className="tb-status">{String(rooms.length).padStart(2, "0")} Rooms{openRooms > 0 && <> · <span className="tb-on">{openRooms} in review</span></>}</span>
        <button className="avatar-button" title="Account" aria-label="Theo Battaglia — account">TB</button>
        {onSignOut && (<button className="signout-chip" title="Sign out" onClick={onSignOut}>Sign out</button>)}
      </div>
    </header>
  );
}

function Sidebar({
  mode,
  setMode,
  room,
  rooms = [],
  activeRoomID,
  onSelectRoom,
  playlists = [],
  activePlaylistID,
  onSelectPlaylist,
  savedViews = [],
  activeSmartViewID,
  onSelectSmartView,
  selectedSongID,
  onSelectSong,
  pinnedPlaylistIDs = new Set(),
  onTogglePlaylistPin,
}: {
  mode: ViewMode;
  setMode: (mode: ViewMode) => void;
  room: RoomPayload | null;
  rooms?: Awaited<ReturnType<typeof api.roomsSummary>>;
  activeRoomID?: string;
  onSelectRoom?: (id: string) => void;
  playlists?: Awaited<ReturnType<typeof api.playlists>>;
  activePlaylistID?: string | null;
  onSelectPlaylist?: (id: string) => void;
  savedViews?: Awaited<ReturnType<typeof api.savedViews>>;
  activeSmartViewID?: string | null;
  onSelectSmartView?: (viewID: string) => void;
  selectedSongID: string;
  onSelectSong: (songID: string) => void;
  pinnedPlaylistIDs?: Set<string>;
  onTogglePlaylistPin?: (id: string) => void;
}) {
  const nav = [
    ["home", "Home", Home],
    ["library", "All Songs", ListMusic],
    ["inbox", "Inbox", Inbox],
    ["compare", "Compare", GitCompare],
    ["links", "Links", Link2],
    ["assistant", "Ask", MessageSquare],
    ["team", "Team", Users],
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

      {rooms.length > 0 && onSelectRoom && (
        <>
          <div className="side-rule" />
          <div className="side-label">Rooms</div>
          <div className="side-list">
            {rooms.map((r) => (
              <button
                key={r.room_id}
                className={`side-list-item ${mode === "room" && activeRoomID === r.room_id ? "selected" : ""}`}
                onClick={() => onSelectRoom(r.room_id)}
              >
                <span className="side-title">{r.title}</span>
                <span className="side-meta">{r.song_count} {r.song_count === 1 ? "song" : "songs"}</span>
              </button>
            ))}
          </div>
        </>
      )}

      {playlists.length > 0 && onSelectPlaylist && (
        <>
          <div className="side-rule" />
          <div className="side-label">Playlists</div>
          <div className="side-list">
            {playlists.map((p) => {
              const isPinned = pinnedPlaylistIDs.has(p.playlist_id);
              return (
                <button
                  key={p.playlist_id}
                  className={`side-list-item ${mode === "playlist" && activePlaylistID === p.playlist_id ? "selected" : ""}`}
                  onClick={() => onSelectPlaylist(p.playlist_id)}
                >
                  <span className="side-info">
                    <span className="side-title">{p.title}</span>
                    <span className="side-meta">{p.item_count} {p.item_count === 1 ? "song" : "songs"}</span>
                  </span>
                  {onTogglePlaylistPin && (
                    <span
                      className={`pin-button ${isPinned ? "pinned" : ""}`}
                      role="button"
                      tabIndex={0}
                      aria-label={isPinned ? `Unpin ${p.title}` : `Pin ${p.title}`}
                      aria-pressed={isPinned}
                      onClick={(e) => { e.stopPropagation(); onTogglePlaylistPin(p.playlist_id); }}
                      onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); e.stopPropagation(); onTogglePlaylistPin(p.playlist_id); } }}
                    >
                      {isPinned ? <BookmarkCheck size={13} /> : <Bookmark size={13} />}
                    </span>
                  )}
                </button>
              );
            })}
          </div>
        </>
      )}

      {savedViews.length > 0 && onSelectSmartView && (
        <>
          <div className="side-rule" />
          <div className="side-label smart">Smart views</div>
          <div className="side-list">
            {savedViews.map((v) => (
              <button
                key={v.view_id}
                className={`side-list-item smart ${activeSmartViewID === v.view_id ? "selected" : ""}`}
                onClick={() => onSelectSmartView(v.view_id)}
              >
                <span className="side-title">{v.name}</span>
                <span className="side-meta">saved query</span>
              </button>
            ))}
          </div>
        </>
      )}

      {mode === "room" && room && room.songs.length > 0 && (
        <>
          <div className="side-rule" />
          <div className="side-label">In this room</div>
          <div className="song-rail">
            {room.songs.map((song) => {
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
        </>
      )}
    </aside>
  );
}

// =====================================================================
//  HomeView — default landing: Pinned + Recent
// =====================================================================

// =====================================================================
//  TeamView — members, pending invites, and invite form
// =====================================================================

const ROLES = ["owner", "admin", "manager", "producer", "engineer", "artist", "anr", "viewer"] as const;
type WorkspaceRole = (typeof ROLES)[number];

function TeamView() {
  const [members, setMembers] = useState<Awaited<ReturnType<typeof api.workspaceMembersRich>>>([]);
  const [invites, setInvites] = useState<Awaited<ReturnType<typeof api.listInvites>>>([]);
  const [loading, setLoading] = useState(true);
  const [inviteOpen, setInviteOpen] = useState(false);
  const [inviteEmail, setInviteEmail] = useState("");
  const [inviteRole, setInviteRole] = useState<WorkspaceRole>("viewer");
  const [inviteName, setInviteName] = useState("");
  const [inviteSending, setInviteSending] = useState(false);
  const [inviteError, setInviteError] = useState<string | null>(null);
  const [inviteSent, setInviteSent] = useState<string | null>(null);
  const [revoking, setRevoking] = useState<string | null>(null);

  async function load() {
    setLoading(true);
    try {
      const [m, i] = await Promise.all([
        api.workspaceMembersRich().catch(() => [] as Awaited<ReturnType<typeof api.workspaceMembersRich>>),
        api.listInvites().catch(() => [] as Awaited<ReturnType<typeof api.listInvites>>),
      ]);
      setMembers(m);
      setInvites(i);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { void load(); }, []);

  async function sendInvite(e: React.FormEvent) {
    e.preventDefault();
    if (!inviteEmail.trim()) return;
    setInviteSending(true);
    setInviteError(null);
    try {
      await api.sendInvite("wsp-amf-private", {
        email: inviteEmail.trim(),
        role: inviteRole,
        display_name: inviteName.trim() || undefined,
      });
      setInviteSent(inviteEmail.trim());
      setInviteEmail("");
      setInviteName("");
      setInviteRole("viewer");
      setInviteOpen(false);
      void load();
    } catch (err) {
      setInviteError(err instanceof Error ? err.message : "Could not send invite");
    } finally {
      setInviteSending(false);
    }
  }

  async function revoke(inviteId: string) {
    setRevoking(inviteId);
    try {
      await api.revokeInvite("wsp-amf-private", inviteId);
      void load();
    } finally {
      setRevoking(null);
    }
  }

  function initials(name: string) {
    return name.split(/\s+/).map((s) => s[0]).join("").slice(0, 2).toUpperCase();
  }

  return (
    <div className="view-stack team-page">
      <div className="section-head">
        <div>
          <p className="eyebrow">WORKSPACE</p>
          <h1>Team</h1>
        </div>
        <div className="metric-strip">
          <Metric label="members" value={members.length} />
          <Metric label="pending" value={invites.length} />
        </div>
      </div>

      {/* Invite sent banner */}
      {inviteSent && (
        <div className="team-banner" role="status">
          Invite sent to <b>{inviteSent}</b>. They'll get an email with a sign-in link.
          <button className="text-button" onClick={() => setInviteSent(null)}>Dismiss</button>
        </div>
      )}

      {/* Invite form */}
      <div className="team-invite-bar">
        {!inviteOpen ? (
          <button className="accent-button" onClick={() => setInviteOpen(true)}>
            <Plus size={15} /> Invite someone
          </button>
        ) : (
          <form className="team-invite-form" onSubmit={sendInvite}>
            <p className="eyebrow">SEND INVITE</p>
            <div className="team-invite-fields">
              <input
                type="email"
                placeholder="email@studio.com"
                value={inviteEmail}
                onChange={(e) => setInviteEmail(e.target.value)}
                required
                autoFocus
                disabled={inviteSending}
              />
              <input
                type="text"
                placeholder="Name (optional)"
                value={inviteName}
                onChange={(e) => setInviteName(e.target.value)}
                disabled={inviteSending}
              />
              <select value={inviteRole} onChange={(e) => setInviteRole(e.target.value as WorkspaceRole)} disabled={inviteSending}>
                {ROLES.filter((r) => r !== "owner").map((r) => (
                  <option key={r} value={r}>{r.charAt(0).toUpperCase() + r.slice(1)}</option>
                ))}
              </select>
            </div>
            {inviteError && <p className="team-invite-error">{inviteError}</p>}
            <div className="team-invite-actions">
              <button type="submit" className="accent-button" disabled={inviteSending || !inviteEmail.trim()}>
                {inviteSending ? "Sending…" : "Send invite"}
              </button>
              <button type="button" className="chrome-button" onClick={() => { setInviteOpen(false); setInviteError(null); }} disabled={inviteSending}>
                Cancel
              </button>
            </div>
            <p className="muted" style={{ fontSize: 11, marginTop: 6 }}>
              They'll receive a Playback invite email with a one-click sign-in link. Sign-up is invite-only.
            </p>
          </form>
        )}
      </div>

      {/* Current members */}
      <div className="team-section">
        <h2 className="team-section-head">Members</h2>
        {loading ? (
          <p className="muted">Loading…</p>
        ) : members.length === 0 ? (
          <p className="muted">No members yet.</p>
        ) : (
          <div className="team-list">
            {members.map((m) => (
              <div key={m.user_id} className="team-row">
                <span className="team-avatar" aria-hidden="true">{initials(m.display_name ?? "?")}</span>
                <div className="team-row-text">
                  <span className="team-row-name">{m.display_name}</span>
                  <span className="team-row-meta">
                    {m.role}
                    {m.member_number != null && <> · PB·{String(m.member_number).padStart(3, "0")}</>}
                  </span>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Pending invites */}
      {invites.length > 0 && (
        <div className="team-section">
          <h2 className="team-section-head">Pending invites</h2>
          <div className="team-list">
            {invites.map((inv) => (
              <div key={inv.invite_id} className="team-row">
                <span className="team-avatar pending" aria-hidden="true">
                  {inv.email.slice(0, 2).toUpperCase()}
                </span>
                <div className="team-row-text">
                  <span className="team-row-name">{inv.display_name ?? inv.email}</span>
                  <span className="team-row-meta">{inv.email} · {inv.role} · invited {formatRelative(inv.invited_at)}</span>
                </div>
                <button
                  className="team-revoke"
                  onClick={() => void revoke(inv.invite_id)}
                  disabled={revoking === inv.invite_id}
                  title="Revoke invite"
                >
                  {revoking === inv.invite_id ? "…" : <X size={13} />}
                </button>
              </div>
            ))}
          </div>
        </div>
      )}

      <div className="team-note">
        <Shield size={13} />
        Sign-ups are invite-only. Anyone without a valid invite who tries to create an account won't see workspace content.
      </div>
    </div>
  );
}

function LibEmptyState({ label, hint }: { label: string; hint: string }) {
  return (
    <div className="lib-empty">
      <span className="lib-empty-label">{label}</span>
      <p className="lib-empty-hint">{hint}</p>
    </div>
  );
}

function HomeView({
  onOpenSong,
  onOpenRoom,
  onOpenPlaylist,
  onToggleSongPin,
  onTogglePlaylistPin,
  onToggleProjectPin,
  pinnedSongIDs,
  pinnedPlaylistIDs,
  pinnedProjectIDs,
}: {
  onOpenSong: (id: string) => void;
  onOpenRoom: (id: string) => void;
  onOpenProject: (id: string) => void;
  onOpenPlaylist: (id: string) => void;
  onRefreshPlaylists: () => void;
  pinnedSongIDs: Set<string>;
  pinnedPlaylistIDs: Set<string>;
  pinnedProjectIDs: Set<string>;
  onToggleSongPin: (id: string) => void;
  onTogglePlaylistPin: (id: string) => void;
  onToggleProjectPin: (id: string) => void;
}) {
  const player = usePlayer();
  const [pins, setPins] = useState<MyPinsPayload | null>(null);
  const [recentItems, setRecentItems] = useState<RecentItem[]>([]);
  const [rooms, setRooms] = useState<Awaited<ReturnType<typeof api.roomsSummary>>>([]);
  const [library, setLibrary] = useState<Awaited<ReturnType<typeof api.workspaceLibrary>>>([]);
  const [playlists, setPlaylists] = useState<Awaited<ReturnType<typeof api.playlists>>>([]);
  const [savedViews, setSavedViews] = useState<Awaited<ReturnType<typeof api.savedViews>>>([]);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    Promise.all([
      api.getMyPins().catch((): MyPinsPayload => ({ songs: [], playlists: [], projects: [] })),
      api.recent("wsp-amf-private", 20).catch((): RecentItem[] => []),
      api.roomsSummary().catch(() => [] as Awaited<ReturnType<typeof api.roomsSummary>>),
      api.workspaceLibrary().catch(() => [] as Awaited<ReturnType<typeof api.workspaceLibrary>>),
      api.playlists().catch(() => [] as Awaited<ReturnType<typeof api.playlists>>),
      api.savedViews().catch(() => [] as Awaited<ReturnType<typeof api.savedViews>>),
    ]).then(([p, r, rm, lib, pls, svs]) => {
      setPins(p);
      setRecentItems(r);
      setRooms(rm);
      setLibrary(lib);
      setPlaylists(pls);
      setSavedViews(svs);
    }).finally(() => setIsLoading(false));
  }, []);

  const totalPinned = pins ? pins.songs.length + pins.playlists.length : 0;

  // Resume target: the most recently touched playable song, else the first one.
  // Leads the page with the music instead of a giant meaningless headline.
  const playable = library.filter((it) => it.current_version && it.asset);
  const recentSongID = recentItems.find((it) => it.entity_type === "song")?.entity_id;
  const continueItem =
    (recentSongID ? playable.find((it) => it.song.song_id === recentSongID) : undefined) ?? playable[0];
  // Only promise "where you left off" when it's genuinely the last-touched song.
  const isResume = !!recentSongID && continueItem?.song.song_id === recentSongID;

  // Songs waiting on the manager — still in review or sent back for changes.
  const needsAttention = library.filter(
    (it) => it.song.status === "in_review" || it.song.status === "revision_requested",
  );

  const greeting = (() => {
    const h = new Date().getHours();
    if (h < 12) return "Good morning";
    if (h < 18) return "Good afternoon";
    return "Good evening";
  })();

  // Cold-load: show a skeleton that mirrors the real layout so the page reads as
  // "loading" instead of flashing the empty-state before data arrives.
  if (isLoading) {
    return (
      <div className="home-canvas">
        <header className="home-hero">
          <span className="home-skel home-skel--kicker" />
          <div className="home-continue home-continue--empty">
            <div className="home-skel home-skel--cover" />
            <div className="home-continue-text" style={{ flex: 1 }}>
              <span className="home-skel home-skel--line" style={{ width: 90 }} />
              <span className="home-skel home-skel--title" />
              <span className="home-skel home-skel--line" style={{ width: 150 }} />
            </div>
          </div>
        </header>
        <section className="home-section">
          <span className="home-skel home-skel--head" />
          <div className="home-room-grid">
            {[0, 1, 2].map((i) => (
              <div key={i} className="home-room-card" style={{ pointerEvents: "none" }}>
                <div className="home-room-cover home-skel" />
                <div className="home-room-body">
                  <span className="home-skel home-skel--line" style={{ width: "70%" }} />
                  <span className="home-skel home-skel--line" style={{ width: "40%" }} />
                </div>
              </div>
            ))}
          </div>
        </section>
      </div>
    );
  }

  return (
    <div className="cw-home">
      {/* FEATURED — the latest mix as a living-cover banner */}
      {continueItem && (
        <div className="cw-featured">
          <LivingCover hue={coverHue(continueItem.song.artist_display_name)} style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }} />
          <div className="cw-feat-scrim" />
          <div className="cw-feat-corner"><span className="cw-micro">{isResume ? "Resume" : "Latest mix"} · Generative cover</span></div>
          <div className="cw-feat-body">
            <span className="cw-feat-eyebrow">{isResume ? "Resume" : "Latest mix"}{continueItem.current_version ? ` · ${continueItem.current_version.version_label}` : ""}</span>
            <h1 className="cw-feat-title">{continueItem.song.title}</h1>
            <div className="cw-feat-meta">
              {continueItem.song.artist_display_name}
              {typeof continueItem.song.bpm === "number" && <> · {continueItem.song.bpm} BPM</>}
              {continueItem.song.song_key && <> · {continueItem.song.song_key}</>}
              {typeof continueItem.asset?.duration_ms === "number" && <> · {formatTimestamp(continueItem.asset.duration_ms)}</>}
            </div>
            <div className="cw-feat-row">
              <button
                className="cw-btn play"
                onClick={() => {
                  if (continueItem.current_version && continueItem.asset) {
                    player.play(continueItem.song, continueItem.current_version, continueItem.asset);
                  }
                }}
              >
                {player.song?.song_id === continueItem.song.song_id && player.isPlaying ? <Pause size={14} /> : <Play size={14} />} Play
              </button>
              <button className="cw-btn ghost" onClick={() => onOpenSong(continueItem.song.song_id)}>Open Song</button>
              {needsAttention.length > 0 && (
                <span className="cw-flag"><span className="ed-dot" aria-hidden="true" />{needsAttention.length} in review</span>
              )}
            </div>
          </div>
        </div>
      )}

      {/* ROOMS — catalog wall of living-cover cards, one per artist world */}
      {rooms.length > 0 && (
        <>
          <div className="cw-shead"><h2>Rooms</h2><span className="cw-ln" /><span className="cw-ct">{String(rooms.length).padStart(2, "0")} Active</span></div>
          <div className="cw-grid">
            {rooms.map((r, i) => (
              <button key={r.room_id} className="cw-card" onClick={() => onOpenRoom(r.room_id)}>
                <div className="cw-cover">
                  <LivingCover hue={hueAt(i)} style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }} />
                  <div className="cw-clab"><span className="cw-micro">{String(i + 1).padStart(2, "0")}</span><span className="cw-micro">Generative</span></div>
                </div>
                <div className="cw-cbody">
                  <div className="cw-ctitle">{r.title}</div>
                  <div className="cw-cmeta">
                    {r.song_count} {r.song_count === 1 ? "Song" : "Songs"}
                    {r.open_note_count > 0 && (<> · <span className="cw-unres">{r.open_note_count} Open</span></>)}
                  </div>
                </div>
              </button>
            ))}
          </div>
        </>
      )}

      {/* COLUMNS — playlists, smart views, and the review queue */}
      <div className="cw-cols">
        <div>
          <div className="cw-shead"><h2>Playlists</h2><span className="cw-ln" /><span className="cw-ct">{String(playlists.length).padStart(2, "0")}</span></div>
          <div className="cw-clist">
            {playlists.map((pl) => (
              <button key={pl.playlist_id} className="cw-row" onClick={() => onOpenPlaylist(pl.playlist_id)}>
                <span className="cw-rt">{pl.title}</span>
                <span className="cw-rm">{pl.item_count} {pl.item_count === 1 ? "Track" : "Tracks"}</span>
                <span className="cw-ar">→</span>
              </button>
            ))}
            {playlists.length === 0 && <div className="cw-empty">No playlists yet</div>}
          </div>
        </div>
        <div>
          <div className="cw-shead"><h2>{needsAttention.length > 0 ? "Needs Your Ear" : "Smart Views"}</h2><span className="cw-ln" /><span className="cw-ct">{String(needsAttention.length > 0 ? needsAttention.length : savedViews.length).padStart(2, "0")}</span></div>
          <div className="cw-clist">
            {needsAttention.length > 0
              ? needsAttention.map((it) => (
                  <button key={it.song.song_id} className="cw-row" onClick={() => onOpenSong(it.song.song_id)}>
                    <span className="cw-rt">{it.song.title}</span>
                    <span className="cw-rm">
                      <span className={it.song.status === "revision_requested" ? "cw-unres" : ""}>
                        {it.song.status === "revision_requested" ? "Sent back" : "Awaiting"}
                      </span>
                    </span>
                    <span className="cw-ar">→</span>
                  </button>
                ))
              : savedViews.map((sv) => (
                  <div key={sv.view_id} className="cw-row static">
                    <span className="cw-rt">{sv.name}</span>
                    <span className="cw-rm">Saved query</span>
                    <span className="cw-ar">→</span>
                  </div>
                ))}
            {needsAttention.length === 0 && savedViews.length === 0 && <div className="cw-empty">All clear</div>}
          </div>
        </div>
      </div>

      {/* PINNED — only when you've actually pinned something */}
      {totalPinned > 0 && pins && (
        <section className="home-section">
          <h2 className="home-section-head">Pinned</h2>
          <>
            {pins && pins.songs.length > 0 && (
              <div className="home-pin-group">
                <p className="home-pin-sublabel">Songs</p>
                <div className="lib-grid">
                  {pins.songs.map((s) => {
                    const isPinned = pinnedSongIDs.has(s.song_id);
                    return (
                      <article key={s.song_id} className="lib-row">
                        <button
                          className="lib-row-main"
                          onClick={() => onOpenSong(s.song_id)}
                        >
                          <div className="cover-art" aria-hidden="true" style={{ backgroundImage: coverGradient(s.song_id) }} />
                          <div className="lib-row-text">
                            <span className="lib-title">{s.title}</span>
                            <span className="lib-meta">
                              {s.artist_display_name}
                              {s.project_name && <> · {s.project_name}</>}
                            </span>
                          </div>
                        </button>
                        <span className={`status-pill ${s.status === "approved" ? "saved" : ""}`}>
                          {s.status.replace(/_/g, " ")}
                        </span>
                        <button
                          className={`pin-button ${isPinned ? "pinned" : ""}`}
                          onClick={() => onToggleSongPin(s.song_id)}
                          title="Unpin from Home"
                          aria-label={`Unpin ${s.title}`}
                          aria-pressed={isPinned}
                        >
                          <BookmarkCheck size={14} />
                        </button>
                      </article>
                    );
                  })}
                </div>
              </div>
            )}

            {pins && pins.playlists.length > 0 && (
              <div className="home-pin-group">
                <p className="home-pin-sublabel">Playlists</p>
                <div className="lib-grid">
                  {pins.playlists.map((pl) => {
                    const isPinned = pinnedPlaylistIDs.has(pl.playlist_id);
                    return (
                      <article key={pl.playlist_id} className="lib-row">
                        <button
                          className="lib-row-main"
                          onClick={() => onOpenPlaylist(pl.playlist_id)}
                        >
                          <div
                            className="cover-art"
                            aria-hidden="true"
                            style={{ backgroundImage: coverGradient(pl.cover_seed), borderRadius: 2, width: 48, height: 48 }}
                          />
                          <div className="lib-row-text">
                            <span className="lib-title">{pl.title}</span>
                            <span className="lib-meta">{pl.item_count} {pl.item_count === 1 ? "song" : "songs"}</span>
                          </div>
                        </button>
                        <button
                          className={`pin-button ${isPinned ? "pinned" : ""}`}
                          onClick={() => onTogglePlaylistPin(pl.playlist_id)}
                          title="Unpin from Home"
                          aria-label={`Unpin ${pl.title}`}
                          aria-pressed={isPinned}
                        >
                          <BookmarkCheck size={14} />
                        </button>
                      </article>
                    );
                  })}
                </div>
              </div>
            )}

            {pins && pins.projects.length > 0 && (
              <div className="home-pin-group">
                <p className="home-pin-sublabel">Projects</p>
                <div className="lib-grid">
                  {pins.projects.map((pr) => {
                    const isPinned = pinnedProjectIDs.has(pr.project_id);
                    return (
                      <article key={pr.project_id} className="lib-row">
                        <div className="lib-row-main" style={{ cursor: "default" }}>
                          <div className="cover-art" aria-hidden="true" style={{ backgroundImage: coverGradient(pr.project_id) }} />
                          <div className="lib-row-text">
                            <span className="lib-title">{pr.title}</span>
                            <span className="lib-meta">{pr.project_type} · {pr.song_count} {pr.song_count === 1 ? "song" : "songs"}</span>
                          </div>
                        </div>
                        <button
                          className={`pin-button ${isPinned ? "pinned" : ""}`}
                          onClick={() => onToggleProjectPin(pr.project_id)}
                          title="Unpin from Home"
                          aria-label={`Unpin ${pr.title}`}
                          aria-pressed={isPinned}
                        >
                          <BookmarkCheck size={14} />
                        </button>
                      </article>
                    );
                  })}
                </div>
              </div>
            )}
          </>
        </section>
      )}

      {/* RECENT — only when there's history */}
      {recentItems.length > 0 && (
        <section className="home-section">
          <h2 className="home-section-head">Recent</h2>
          <div className="lib-grid">
            {recentItems.slice(0, 8).map((item) => (
              <article key={`${item.entity_type}-${item.entity_id}`} className="lib-row">
                <button
                  className="lib-row-main"
                  onClick={() => {
                    if (item.entity_type === "song") onOpenSong(item.entity_id);
                    else if (item.entity_type === "playlist") onOpenPlaylist(item.entity_id);
                  }}
                >
                  <div className="cover-art" aria-hidden="true" style={{ backgroundImage: coverGradient(item.entity_id) }} />
                  <div className="lib-row-text">
                    <span className="lib-title">{item.title}</span>
                    <span className="lib-meta">
                      {item.artist_display_name}
                      {item.project_name && <> · {item.project_name}</>}
                      {item.version_label && <> · {item.version_label}</>}
                    </span>
                  </div>
                </button>
                <span className="lib-when">{formatRelative(item.last_activity_at)}</span>
                {item.status && (
                  <span className={`status-pill ${item.status === "approved" ? "saved" : ""}`}>
                    {item.status.replace(/_/g, " ")}
                  </span>
                )}
                {item.entity_type === "song" && (
                  <button
                    className={`pin-button ${pinnedSongIDs.has(item.entity_id) ? "pinned" : ""}`}
                    onClick={() => onToggleSongPin(item.entity_id)}
                    title={pinnedSongIDs.has(item.entity_id) ? "Unpin" : "Pin to Home"}
                    aria-label={pinnedSongIDs.has(item.entity_id) ? `Unpin ${item.title}` : `Pin ${item.title} to Home`}
                    aria-pressed={pinnedSongIDs.has(item.entity_id)}
                  >
                    {pinnedSongIDs.has(item.entity_id) ? <BookmarkCheck size={14} /> : <Bookmark size={14} />}
                  </button>
                )}
              </article>
            ))}
          </div>
        </section>
      )}

    </div>
  );
}

function LibraryView({
  onOpenSong,
  playlists,
  onRefreshPlaylists,
  smartView = null,
  onClearSmart,
  pinnedSongIDs = new Set(),
  onToggleSongPin,
}: {
  onOpenSong: (songID: string) => void;
  playlists: Awaited<ReturnType<typeof api.playlists>>;
  onRefreshPlaylists: () => void;
  smartView?: { view_id: string; name: string; filter: Record<string, unknown> } | null;
  onClearSmart?: () => void;
  pinnedSongIDs?: Set<string>;
  onToggleSongPin?: (songID: string) => void;
}) {
  const [library, setLibrary] = useState<Awaited<ReturnType<typeof api.workspaceLibrary>>>([]);
  const [filter, setFilter] = useState<"all" | "approved" | "in-review" | "ready">("all");
  const [search, setSearch] = useState("");
  const [addingFor, setAddingFor] = useState<string | null>(null);
  const [creatingPlaylist, setCreatingPlaylist] = useState(false);
  const [newPlaylistTitle, setNewPlaylistTitle] = useState("");
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  async function loadLibrary() {
    setIsLoading(true);
    setLoadError(null);
    try {
      setLibrary(await api.workspaceLibrary());
    } catch {
      setLoadError("Couldn't load the library. Check your connection and try again.");
    } finally {
      setIsLoading(false);
    }
  }

  useEffect(() => { void loadLibrary(); }, []);

  const lowerSearch = search.trim().toLowerCase();
  const filtered = library
    .filter((item) => !smartView || matchesSmart(item, smartView.filter))
    .filter((item) => {
      if (filter === "approved") return item.song.status === "approved";
      if (filter === "in-review") return item.song.status === "in_review" || item.song.status === "revision_requested";
      if (filter === "ready") return item.song.release_readiness_status === "ready";
      return true;
    })
    .filter((item) => {
      if (!lowerSearch) return true;
      const hay = `${item.song.title} ${item.song.artist_display_name} ${item.room?.title ?? ""}`.toLowerCase();
      return hay.includes(lowerSearch);
    });

  async function addToExisting(playlistID: string, songID: string) {
    await api.addToPlaylist(playlistID, { song_id: songID });
    onRefreshPlaylists();
    setAddingFor(null);
  }

  async function createPlaylistWithSong(songID: string) {
    if (!newPlaylistTitle.trim()) return;
    const playlist = await api.createPlaylist({
      workspace_id: "wsp-amf-private",
      title: newPlaylistTitle.trim(),
    });
    await api.addToPlaylist(playlist.playlist_id, { song_id: songID });
    setNewPlaylistTitle("");
    setCreatingPlaylist(false);
    setAddingFor(null);
    onRefreshPlaylists();
  }

  return (
    <div className="view-stack">
      <div className="section-head">
        <div>
          <p className="eyebrow">{smartView ? "SMART VIEW" : "LIBRARY"}</p>
          <h1>{smartView ? smartView.name : "All work in this workspace."}</h1>
        </div>
        <div className="metric-strip">
          <Metric label={smartView ? "match" : "songs"} value={filtered.length} />
          <Metric label="approved" value={library.filter((i) => i.song.status === "approved").length} />
          <Metric label="rooms" value={new Set(library.map((i) => i.room?.room_id).filter(Boolean)).size} />
        </div>
      </div>

      {smartView && onClearSmart && (
        <div className="smart-banner">
          <div>
            <p className="eyebrow">SAVED QUERY</p>
            <code className="smart-filter">{JSON.stringify(smartView.filter)}</code>
          </div>
          <button className="text-button" onClick={onClearSmart}>
            Clear smart filter
          </button>
        </div>
      )}

      <div className="library-toolbar">
        <input
          className="library-search"
          placeholder="Search songs, artists, rooms…"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          aria-label="Search library"
        />
        <div className="library-filters">
          {([
            ["all", "All"],
            ["approved", "Approved"],
            ["in-review", "In review"],
            ["ready", "Ready"],
          ] as const).map(([id, label]) => (
            <button
              key={id}
              className={`pill-button ${filter === id ? "on" : ""}`}
              onClick={() => setFilter(id)}
              aria-pressed={filter === id}
            >
              {label}
            </button>
          ))}
        </div>
      </div>

      <div className="library-grid" aria-busy={isLoading}>
        {isLoading ? (
          <div className="library-empty">Loading library…</div>
        ) : loadError ? (
          <div className="state-panel inline" role="status">
            <p>{loadError}</p>
            <button className="chrome-button" onClick={() => void loadLibrary()}>Retry</button>
          </div>
        ) : filtered.length === 0 ? (
          <div className="library-empty">Nothing matches.</div>
        ) : (
          filtered.map(({ song, room, current_version }) => (
            <article key={song.song_id} className="library-row">
              <button
                className="library-row-main"
                onClick={() => onOpenSong(song.song_id)}
              >
                <div className="cover-art" aria-hidden="true" style={{ backgroundImage: coverGradient(song.song_id) }} />
                <div className="library-row-text">
                  <span className="library-title">{song.title}</span>
                  <span className="library-meta">
                    {song.artist_display_name}
                    {room && <> · <span className="library-room">{room.title}</span></>}
                    {current_version && <> · {current_version.version_label}</>}
                  </span>
                </div>
              </button>
              <div className="library-row-meta">
                <span className="library-catalog">{catalogIdFor(song.song_id)}</span>
                <span className={`status-pill ${song.status === "approved" ? "saved" : ""}`}>
                  {song.status.replace(/_/g, " ")}
                </span>
              </div>
              <button
                className="library-add"
                onClick={() => setAddingFor(addingFor === song.song_id ? null : song.song_id)}
                title="Add to a playlist"
              >
                <Plus size={16} />
              </button>
              {onToggleSongPin && (() => {
                const isPinned = pinnedSongIDs.has(song.song_id);
                return (
                  <button
                    className={`pin-button ${isPinned ? "pinned" : ""}`}
                    onClick={() => onToggleSongPin(song.song_id)}
                    title={isPinned ? "Unpin" : "Pin to Home"}
                    aria-label={isPinned ? `Unpin ${song.title}` : `Pin ${song.title} to Home`}
                    aria-pressed={isPinned}
                  >
                    {isPinned ? <BookmarkCheck size={14} /> : <Bookmark size={14} />}
                  </button>
                );
              })()}
              {addingFor === song.song_id && (
                <div className="library-add-menu" role="menu">
                  <p className="eyebrow">ADD TO PLAYLIST</p>
                  {playlists.map((p) => (
                    <button
                      key={p.playlist_id}
                      className="add-menu-item"
                      onClick={() => void addToExisting(p.playlist_id, song.song_id)}
                    >
                      <span className="title">{p.title}</span>
                      <span className="count">{p.item_count} songs</span>
                    </button>
                  ))}
                  {creatingPlaylist ? (
                    <div className="add-menu-create">
                      <input
                        value={newPlaylistTitle}
                        onChange={(e) => setNewPlaylistTitle(e.target.value)}
                        onKeyDown={(e) => { if (e.key === "Enter") void createPlaylistWithSong(song.song_id); }}
                        placeholder="Playlist name…"
                        autoFocus
                      />
                      <button className="text-button" onClick={() => void createPlaylistWithSong(song.song_id)}>Create</button>
                    </div>
                  ) : (
                    <button className="add-menu-item create" onClick={() => setCreatingPlaylist(true)}>
                      <Plus size={14} />
                      <span className="title">New playlist…</span>
                    </button>
                  )}
                </div>
              )}
            </article>
          ))
        )}
      </div>
    </div>
  );
}

/**
 * Living gradient — the default cover when there's no artwork. Four blobs morph
 * continuously (form in motion, noticeable) while the whole field hue-rotates
 * slowly (colour drifts). Seeded off an id so each playlist/song gets its own
 * melange. Respects prefers-reduced-motion.
 */
function LivingGradient({ seed, className = "" }: { seed: string; className?: string }) {
  const hue = hashHue(seed);
  return (
    <div className={`living-grad ${className}`} style={{ "--lg-h": hue, position: "relative" } as CSSProperties} aria-hidden="true">
      <LivingCover style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }} />
    </div>
  );
}

function PlaylistView({
  playlistID,
  onOpenSong,
  onRefreshPlaylists,
}: {
  playlistID: string;
  onOpenSong: (songID: string) => void;
  onRefreshPlaylists: () => void;
}) {
  const player = usePlayer();
  const [data, setData] = useState<Awaited<ReturnType<typeof api.playlist>> | null>(null);
  const [removing, setRemoving] = useState<string | null>(null);
  const [shareToken, setShareToken] = useState<string | null>(null);
  const [sharing, setSharing] = useState(false);
  const [draggingID, setDraggingID] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  // Cover field controls — persisted per playlist so the look sticks.
  const coverKey = `wl-pls-cover-${playlistID}`;
  const [coverMode, setCoverMode] = useState<number>(5);
  const [coverTone, setCoverTone] = useState<number>(0);
  const [coverHex, setCoverHex] = useState<string>("#4663E8");

  useEffect(() => {
    void loadPlaylist();
    setShareToken(null);
    let mode = 5, tone = 0, hex = "#4663E8";
    try {
      const raw = localStorage.getItem(coverKey);
      if (raw) { const s = JSON.parse(raw); if (typeof s.mode === "number") mode = s.mode; if (typeof s.tone === "number") tone = s.tone; if (typeof s.hex === "string") hex = s.hex; }
    } catch { /* ignore */ }
    setCoverMode(mode); setCoverTone(tone); setCoverHex(hex);
  }, [playlistID]);

  async function loadPlaylist() {
    setData(null);
    setLoadError(null);
    try {
      setData(await api.playlist(playlistID));
    } catch {
      setLoadError("Couldn't load this playlist. Check your connection and try again.");
    }
  }

  function persistCover(next: { mode?: number; tone?: number; hex?: string }) {
    const merged = { mode: next.mode ?? coverMode, tone: next.tone ?? coverTone, hex: next.hex ?? coverHex };
    try { localStorage.setItem(coverKey, JSON.stringify(merged)); } catch { /* ignore */ }
  }
  function chooseMotion(id: number) { setCoverMode(id); persistCover({ mode: id }); }
  function chooseTone(id: number) { setCoverTone(id); persistCover({ tone: id }); }
  function chooseHue(hex: string) { setCoverHex(hex); setCoverTone(3); persistCover({ tone: 3, hex }); }

  async function remove(itemID: string) {
    setRemoving(itemID);
    try {
      await api.removeFromPlaylist(playlistID, itemID);
      const fresh = await api.playlist(playlistID);
      setData(fresh);
      onRefreshPlaylists();
    } finally {
      setRemoving(null);
    }
  }

  async function sharePlaylist() {
    if (!data) return;
    setSharing(true);
    try {
      const result = await api.createLink({
        workspace_id: data.playlist.workspace_id,
        target_type: "playlist",
        target_id: data.playlist.playlist_id,
        link_name: `${data.playlist.title} — share`,
        access_mode: "identity_required",
        version_policy: "latest_only",
        download_policy: "none",
        watermark_enabled: true,
        allow_comments: true,
        allow_approval: true,
        allow_forwarding: false,
      });
      setShareToken(result.token);
    } finally {
      setSharing(false);
    }
  }

  async function reorderTo(targetItemID: string) {
    if (!data || !draggingID || draggingID === targetItemID) return;
    const ordered = data.items.map((it) => it.item.playlist_item_id);
    const fromIdx = ordered.indexOf(draggingID);
    const toIdx = ordered.indexOf(targetItemID);
    if (fromIdx < 0 || toIdx < 0) return;
    const next = [...ordered];
    const [moved] = next.splice(fromIdx, 1);
    next.splice(toIdx, 0, moved);
    setDraggingID(null);
    await api.reorderPlaylistItems(playlistID, next);
    setData(await api.playlist(playlistID));
  }

  if (!data) {
    return (
      <div className="view-stack">
        {loadError ? (
          <div className="state-panel" role="status">
            <p>{loadError}</p>
            <button className="chrome-button" onClick={() => void loadPlaylist()}>Retry</button>
          </div>
        ) : (
          <p className="muted" aria-busy="true">Loading playlist…</p>
        )}
      </div>
    );
  }

  const totalDuration = data.items.reduce((sum, it) => sum + (it.asset?.duration_ms ?? 0), 0);
  const shareUrl = shareToken ? `${window.location.origin}/shared/${shareToken}` : null;

  const firstPlayable = data.items.find((it) => it.song && it.current_version && it.asset);

  return (
    <div className="pls-page">
      <div className="pls-left">
        <div className="pls-head">
          <span className="pls-eyebrow">Playlist</span>
          <h1 className="pls-title">{data.playlist.title}</h1>
          {data.playlist.description && <p className="pls-desc">{data.playlist.description}</p>}
          <div className="pls-meta">{data.items.length} {data.items.length === 1 ? "Track" : "Tracks"} · {formatTimestamp(totalDuration)}</div>
          <div className="pls-actions">
            <button
              className="pls-btn play"
              disabled={!firstPlayable}
              onClick={() => { if (firstPlayable?.song && firstPlayable.current_version && firstPlayable.asset) player.play(firstPlayable.song, firstPlayable.current_version, firstPlayable.asset); }}
            >
              <Play size={14} /> Play All
            </button>
            <button
              className="pls-btn ghost"
              disabled={data.items.length === 0}
              onClick={() => {
                const ps = data.items.filter((it) => it.song && it.current_version && it.asset);
                const r = ps[Math.floor(Math.random() * ps.length)];
                if (r?.song && r.current_version && r.asset) player.play(r.song, r.current_version, r.asset);
              }}
            >
              Shuffle
            </button>
            <button className="pls-btn ghost" onClick={() => void sharePlaylist()} disabled={sharing || data.items.length === 0}>
              <Link2 size={14} /> {sharing ? "Creating…" : shareToken ? "Link created" : "Share"}
            </button>
          </div>
          {shareUrl && (
            <div className="pls-share">
              <code>{shareUrl}</code>
              <button className="text-button" onClick={() => void navigator.clipboard.writeText(shareUrl)}>Copy</button>
            </div>
          )}
        </div>
        <ol className="pls-list">
          {data.items.length === 0 ? (
            <li className="pls-empty">Nothing here yet. Add songs from your library.</li>
          ) : (
            data.items.map(({ item, song, current_version, asset }, idx) => {
              const isPlaying = !!(player.song?.song_id && song && player.song.song_id === song.song_id);
              // Side dividers — split a longer order into Side A / Side B at the midpoint.
              const splitAt = data.items.length >= 6 ? Math.ceil(data.items.length / 2) : 0;
              const side = idx === 0
                ? { label: "Side A", count: splitAt > 0 ? splitAt : data.items.length }
                : (splitAt > 0 && idx === splitAt)
                  ? { label: "Side B", count: data.items.length - splitAt }
                  : null;
              return (
                <Fragment key={item.playlist_item_id}>
                  {side && (
                    <li className="pls-side" aria-hidden="true">
                      <span className="pls-side-lbl">{side.label}</span>
                      <span className="pls-side-ln" />
                      <span className="pls-side-ct">{String(side.count).padStart(2, "0")} Tracks</span>
                    </li>
                  )}
                  <li
                    draggable
                    className={`pls-row${isPlaying ? " now" : ""}${draggingID === item.playlist_item_id ? " dragging" : ""}`}
                    onDragStart={(e) => { setDraggingID(item.playlist_item_id); e.dataTransfer.effectAllowed = "move"; }}
                    onDragOver={(e) => { e.preventDefault(); e.dataTransfer.dropEffect = "move"; }}
                    onDrop={(e) => { e.preventDefault(); void reorderTo(item.playlist_item_id); }}
                    onDragEnd={() => setDraggingID(null)}
                  >
                    <button className="pls-row-main" onClick={() => { if (song && current_version && asset) player.play(song, current_version, asset); }} aria-label={song ? `Play ${song.title}` : undefined} disabled={!song}>
                      <span className="pls-idx">{isPlaying ? <span className="pls-eq" aria-hidden="true"><i /><i /><i /></span> : String(idx + 1).padStart(2, "0")}</span>
                      <span className="pls-rtitle">{song ? song.title : "Song removed"}</span>
                      <span className="pls-rartist">{song?.artist_display_name}{current_version && <> · {current_version.version_label}</>}</span>
                    </button>
                    <span className="pls-rdur">{formatTimestamp(asset?.duration_ms ?? 0)}</span>
                    <div className="pls-ractions">
                      <button className="pls-icon" title="Open notes & versions" onClick={() => song && onOpenSong(song.song_id)} disabled={!song}><MessageSquare size={14} /></button>
                      <button className="pls-icon" title="Remove from playlist" onClick={() => void remove(item.playlist_item_id)} disabled={removing === item.playlist_item_id}><X size={14} /></button>
                    </div>
                  </li>
                </Fragment>
              );
            })
          )}
        </ol>
      </div>
      <div className="pls-right">
        <LivingCover
          mode={coverMode}
          tone={coverTone}
          hue={coverTone === 3 ? hexToHue(coverHex) : undefined}
          style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }}
        />
        <div className="pls-cover-scrim" />
        <div className="pls-cover-lab tp">
          <span className="cw-micro">Generative Cover</span>
          <div className="pls-pickers">
            <div className="pls-pick">
              <span className="pls-pick-lab">Motion</span>
              {MOTION_MODES.map((m) => (
                <button key={m.id} className={`pls-pk${coverMode === m.id ? " active" : ""}`} onClick={() => chooseMotion(m.id)}>{m.label}</button>
              ))}
            </div>
            <div className="pls-pick">
              <span className="pls-pick-lab">Tone</span>
              {TONE_MODES.map((t) => (
                <button key={t.id} className={`pls-pk${coverTone === t.id ? " active" : ""}`} onClick={() => chooseTone(t.id)}>{t.label}</button>
              ))}
              <label className={`pls-swatch${coverTone === 3 ? " active" : ""}`} title="Pick a main color" style={{ ["--sw" as string]: coverHex }}>
                <input type="color" value={coverHex} onChange={(e) => chooseHue(e.target.value)} />
              </label>
            </div>
          </div>
        </div>
        <div className="pls-cover-lab bt">
          <span className="cw-micro">Playlist № {String((parseInt(catalogNumber(data.playlist.playlist_id), 10) % 90) + 10).padStart(2, "0")} · Generative</span>
          <span className="cw-micro pls-seed">Seed {seedLabel(data.playlist.playlist_id)}</span>
        </div>
      </div>
    </div>
  );
}

/* The immersive now-playing surface — matches the Playback now-playing concept:
   a dark editorial field (huge title, credits, integrated transport) beside a
   full-bleed generative cover with the motion/tone pickers. */
function NowPlayingView({ payload, onClose, onNote }: { payload: SongPayload; onClose?: () => void; onNote?: () => void }) {
  const player = usePlayer();
  const song = payload.song;
  const isThis = player.song?.song_id === song.song_id;
  const version = (isThis && player.version) ? player.version : (payload.currentVersion ?? payload.versions.at(-1));
  const asset = (isThis && player.asset) ? player.asset : assetForVersion(payload.assets, version);
  const durationMs = asset?.duration_ms ?? 0;
  const positionMs = isThis ? player.positionMs : 0;
  const progress = durationMs > 0 ? Math.max(0, Math.min(1, positionMs / durationMs)) : 0;
  const playing = isThis && player.isPlaying;

  // Cover field controls — persisted per song.
  const coverKey = `wl-np-cover-${song.song_id}`;
  const [coverMode, setCoverMode] = useState<number>(5);
  const [coverTone, setCoverTone] = useState<number>(0);
  const [coverHex, setCoverHex] = useState<string>("#4663E8");
  useEffect(() => {
    let mode = 5, tone = 0, hex = "#4663E8";
    try {
      const raw = localStorage.getItem(coverKey);
      if (raw) { const s = JSON.parse(raw); if (typeof s.mode === "number") mode = s.mode; if (typeof s.tone === "number") tone = s.tone; if (typeof s.hex === "string") hex = s.hex; }
    } catch { /* ignore */ }
    setCoverMode(mode); setCoverTone(tone); setCoverHex(hex);
  }, [song.song_id]);
  function persistCover(next: { mode?: number; tone?: number; hex?: string }) {
    const merged = { mode: next.mode ?? coverMode, tone: next.tone ?? coverTone, hex: next.hex ?? coverHex };
    try { localStorage.setItem(coverKey, JSON.stringify(merged)); } catch { /* ignore */ }
  }

  function togglePlay() {
    if (isThis) player.toggle();
    else if (version && asset) player.play(song, version, asset);
  }

  return (
    <div className="np-stage">
      <div className="np-left">
        <header className="np-top">
          <span className="np-wm"><Wordmark size="sm" /><span className="np-cat">{catalogIdFor(song.song_id)}</span></span>
          {onClose && (
            <button className="np-close" onClick={onClose} aria-label="Close">
              <X size={18} />
            </button>
          )}
        </header>
        <div className="np-hero">
          <span className="np-eyebrow">Now Playing{version?.version_label ? ` · ${version.version_label}` : ""}{song.project_name ? ` · ${song.project_name}` : ""}</span>
          <h1 className="np-title">{song.title}</h1>
          <div className="np-artist">{song.artist_display_name}</div>
          {version && (
            <div className="np-flag"><span className="np-dot" />{version.version_label}{version.is_approved ? " · Approved" : version.is_current ? " · Current" : ""}</div>
          )}
        </div>
        <footer className="np-foot">
          <div className="np-credits">
            {song.bpm != null && <div className="np-c"><span className="k">Tempo</span><span className="v">{song.bpm} BPM</span></div>}
            {song.song_key && <div className="np-c"><span className="k">Key</span><span className="v">{song.song_key}</span></div>}
            {asset?.loudness_lufs != null && <div className="np-c"><span className="k">Loudness</span><span className="v">{asset.loudness_lufs} LUFS</span></div>}
            {durationMs > 0 && <div className="np-c"><span className="k">Length</span><span className="v">{formatTimestamp(durationMs)}</span></div>}
            {asset?.mime_type && <div className="np-c"><span className="k">Format</span><span className="v">{asset.mime_type.replace("audio/", "").toUpperCase()}</span></div>}
          </div>
          <div className="np-transport">
            <TransportKeys
              playing={playing}
              canPlay={!!(version && asset)}
              canSeek={isThis}
              canForward={payload.versions.length > 1}
              onBack={() => player.seek(0)}
              onPlay={togglePlay}
              onForward={() => {
                // Cycle to the next version in the stack
                const idx = payload.versions.findIndex(v => v.version_id === version?.version_id);
                const next = payload.versions[(idx + 1) % payload.versions.length];
                const nextAsset = assetForVersion(payload.assets, next);
                if (next && nextAsset) player.play(payload.song, next, nextAsset);
              }}
              onNote={onNote}
            />
            <div className="np-scrub">
              <span className="np-time">{formatTimestamp(positionMs)}</span>
              <button
                className="np-bar"
                aria-label="Seek"
                disabled={!isThis || durationMs === 0}
                onClick={(e) => { const r = e.currentTarget.getBoundingClientRect(); player.seek(((e.clientX - r.left) / r.width) * durationMs); }}
              >
                <i style={{ width: `${progress * 100}%` }} />
              </button>
              <span className="np-time">{formatTimestamp(durationMs)}</span>
            </div>
          </div>
        </footer>
      </div>
      <div className="np-right">
        <LivingCover
          mode={coverMode}
          tone={coverTone}
          hue={coverTone === 3 ? hexToHue(coverHex) : undefined}
          style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }}
        />
        <div className="np-seam" />
        <div className="np-lab tp">
          <span className="cw-micro">Generative Cover</span>
          <div className="pls-pickers">
            <div className="pls-pick">
              <span className="pls-pick-lab">Motion</span>
              {MOTION_MODES.map((m) => (
                <button key={m.id} className={`pls-pk${coverMode === m.id ? " active" : ""}`} onClick={() => { setCoverMode(m.id); persistCover({ mode: m.id }); }}>{m.label}</button>
              ))}
            </div>
            <div className="pls-pick">
              <span className="pls-pick-lab">Tone</span>
              {TONE_MODES.map((t) => (
                <button key={t.id} className={`pls-pk${coverTone === t.id ? " active" : ""}`} onClick={() => { setCoverTone(t.id); persistCover({ tone: t.id }); }}>{t.label}</button>
              ))}
              <label className={`pls-swatch${coverTone === 3 ? " active" : ""}`} title="Pick a main color" style={{ ["--sw" as string]: coverHex }}>
                <input type="color" value={coverHex} onChange={(e) => { setCoverHex(e.target.value); setCoverTone(3); persistCover({ tone: 3, hex: e.target.value }); }} />
              </label>
            </div>
          </div>
        </div>
        <div className="np-lab bt">
          <span className="cw-micro">Generative cover</span>
        </div>
      </div>
    </div>
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
          <Metric label="open notes" value={payload.notes.filter((note) => note.status === "open").length} />
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

function SongWorkspace({
  payload,
  onRefresh,
  playlists = [],
  onRefreshPlaylists,
  onOpenSong,
}: {
  payload: SongPayload;
  onRefresh: () => void;
  playlists?: Awaited<ReturnType<typeof api.playlists>>;
  onRefreshPlaylists?: () => void;
  onOpenSong?: (id: string) => void;
}) {
  const [activeVersionID, setActiveVersionID] = useState(payload.currentVersion?.version_id ?? payload.versions[0]?.version_id);
  const [noteDraftOpen, setNoteDraftOpen] = useState(false);
  const [noteTimestamp, setNoteTimestamp] = useState<number | undefined>(undefined);
  const [uploadingPct, setUploadingPct] = useState<number | null>(null);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [pendingPromote, setPendingPromote] = useState<Version | null>(null);
  const [pendingUploadFile, setPendingUploadFile] = useState<File | null>(null);
  // Moment 1: track the ID of the first-ever version after upload so VersionStack
  // can briefly flash that row. Cleared after ~2 s.
  const [firstUploadFlashID, setFirstUploadFlashID] = useState<string | null>(null);
  const firstUploadTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
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
    // Reset input so re-selecting the same file fires onChange next time
    if (fileInputRef.current) fileInputRef.current.value = "";
    // Show the type picker before committing the upload
    setPendingUploadFile(file);
  }

  async function commitUpload(file: File, label: string, type: VersionType) {
    const wasFirst = payload.versions.length === 0;
    setUploadingPct(0);
    setUploadError(null);
    try {
      await uploadAudio(
        file,
        { songExternalId: payload.song.song_id, versionLabel: label, versionType: type },
        (pct) => setUploadingPct(pct)
      );
      setUploadingPct(null);
      // Moment 1: if this was the very first version, schedule a flash on that row
      // after the refresh brings back the new version list.
      if (wasFirst) {
        // Set the sentinel; the effect watching resolvedFlashID will start the
        // 2.2 s timer only once the real version id resolves (C2).
        setFirstUploadFlashID("__pending_first__");
      }
      onRefresh();
    } catch (err) {
      setUploadingPct(null);
      const raw = err instanceof Error ? err.message : String(err);
      console.error("Upload failed:", raw);
      setUploadError("Couldn't upload that file. Check the format and try again.");
    }
  }

  const openNotes = payload.notes.filter((n) => n.status === "open");
  const hasNotesDue = openNotes.length > 0;
  const approvedVersion = payload.versions.find((v) => v.version_id === payload.song.approved_version_id);
  const catalogId = catalogIdFor(payload.song.song_id);
  const versionLabel = activeVersion?.version_label ?? "v1";

  // Moment 1: resolve sentinel to actual first-version ID once it's available.
  // C2: only start the 2.2s flash window AFTER the real id resolves from the
  // effect that watches payload.versions — not immediately after the upload call.
  const resolvedFlashID = firstUploadFlashID === "__pending_first__"
    ? (payload.versions.length === 1 ? payload.versions[0].version_id : null)
    : firstUploadFlashID;

  // C2: drive the timer off the resolved ID, not the sentinel.
  useEffect(() => {
    if (!resolvedFlashID || resolvedFlashID === "__pending_first__") return;
    if (firstUploadTimerRef.current) clearTimeout(firstUploadTimerRef.current);
    firstUploadTimerRef.current = setTimeout(() => setFirstUploadFlashID(null), 2200);
    return () => {
      if (firstUploadTimerRef.current) clearTimeout(firstUploadTimerRef.current);
    };
  }, [resolvedFlashID]);

  return (
    <div className="view-stack">
      <div className="song-card-hero">
        <div className="breadcrumb">
          {payload.song.project_name ?? "Room"} / <b>{payload.song.title}</b> / {versionLabel}
        </div>
        <div className="song-card-frame">
          <div className="stamp-row">
            {approvedVersion && (
              <Stamp kind="approved" straight>{approvedVersion.version_label}</Stamp>
            )}
            {hasNotesDue && (
              <Stamp kind="notes-due">{openNotes.length} open</Stamp>
            )}
          </div>
          <div className="song-card-body">
            <div className="song-card-cover">
              <LivingCover style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }} />
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
              <div className="versions" role="group" aria-label="Version stack">
                <h6>Stack</h6>
                {payload.versions.map((v) => {
                  const isCur = v.version_id === activeVersion?.version_id;
                  return (
                    <button
                      key={v.version_id}
                      className={`v ${isCur ? "cur" : ""}`}
                      aria-current={isCur ? "true" : undefined}
                      onClick={() => {
                        setActiveVersionID(v.version_id);
                        const a = assetForVersion(payload.assets, v);
                        if (a) player.play(payload.song, v, a);
                      }}
                    >
                      {v.version_label ?? `v${v.version_number}`}
                      {v.is_current ? " · current" : ""}
                    </button>
                  );
                })}
              </div>
              <div className="actions">
                <button
                  className="btn red primary"
                  onClick={() => activeVersion && activeAsset?.playback_url && player.play(payload.song, activeVersion, activeAsset)}
                  disabled={!activeAsset?.playback_url}
                  title={!activeAsset?.playback_url ? "Upload a revision to add audio" : undefined}
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
                {playlists.length > 0 && onRefreshPlaylists && (
                  <AddToPlaylistMenu
                    playlists={playlists}
                    songID={payload.song.song_id}
                    onAdded={onRefreshPlaylists}
                  />
                )}
                {uploadError && (
                  <span className="upload-error">{uploadError}</span>
                )}
              </div>
            </div>
          </div>
          <div className="song-card-waveband">
            {activeAsset?.playback_url ? (
              <>
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
              </>
            ) : (
              <>
                <button className="play" disabled aria-label="No audio yet" style={{ opacity: 0.3 }}>
                  <Play size={16} />
                </button>
                <div className="wave-host no-audio">
                  <span className="no-audio-label">No audio — upload a revision to add it</span>
                </div>
                <div className="times" style={{ opacity: 0.3 }}>--:--</div>
              </>
            )}
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
          flashVersionID={resolvedFlashID ?? undefined}
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
        {pendingUploadFile && (
          <UploadTypePicker
            file={pendingUploadFile}
            defaultLabel={`${humanizeVersionType(payload.versions.at(-1)?.type ?? "mix")} v${payload.versions.length + 1}`}
            defaultType={payload.versions.at(-1)?.type ?? "mix"}
            onConfirm={(label, type) => {
              setPendingUploadFile(null);
              void commitUpload(pendingUploadFile, label, type);
            }}
            onCancel={() => setPendingUploadFile(null)}
          />
        )}
        <NotesPanel notes={payload.notes} onRefresh={onRefresh} />
        <DeliverablesPanel payload={payload} />
      </div>
      {onOpenSong && (
        <FindSimilarPanel song={payload.song} onOpenSong={onOpenSong} />
      )}
    </div>
  );
}

function AddToPlaylistMenu({
  playlists,
  songID,
  onAdded,
}: {
  playlists: Awaited<ReturnType<typeof api.playlists>>;
  songID: string;
  onAdded: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [creating, setCreating] = useState(false);
  const [title, setTitle] = useState("");

  async function add(playlistID: string) {
    await api.addToPlaylist(playlistID, { song_id: songID });
    setOpen(false);
    onAdded();
  }

  async function createWith() {
    if (!title.trim()) return;
    const p = await api.createPlaylist({ workspace_id: "wsp-amf-private", title: title.trim() });
    await api.addToPlaylist(p.playlist_id, { song_id: songID });
    setTitle("");
    setCreating(false);
    setOpen(false);
    onAdded();
  }

  return (
    <div className="add-to-playlist">
      <button
        className="text-button with-icon"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
      >
        <Plus size={14} /> Playlist
      </button>
      {open && (
        <div className="add-menu" role="menu">
          <p className="eyebrow">ADD TO PLAYLIST</p>
          {playlists.map((p) => (
            <button key={p.playlist_id} className="add-menu-item" onClick={() => void add(p.playlist_id)}>
              <span className="title">{p.title}</span>
              <span className="count">{p.item_count} songs</span>
            </button>
          ))}
          {creating ? (
            <div className="add-menu-create">
              <input
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                onKeyDown={(e) => { if (e.key === "Enter") void createWith(); }}
                placeholder="Playlist name…"
                autoFocus
              />
              <button className="text-button" onClick={() => void createWith()}>Create</button>
            </div>
          ) : (
            <button className="add-menu-item create" onClick={() => setCreating(true)}>
              <Plus size={14} />
              <span className="title">New playlist…</span>
            </button>
          )}
        </div>
      )}
    </div>
  );
}

const VERSION_TYPES: VersionType[] = [
  "mix", "master", "demo", "rough", "clean", "explicit", "instrumental",
  "acapella", "tv_track", "sped_up", "slowed", "alt_arrangement", "reference", "stem_derived",
];

function filenameStem(name: string): string {
  return name.replace(/\.[^.]+$/, "").replace(/[_-]+/g, " ").trim();
}

function UploadTypePicker({
  file,
  defaultLabel,
  defaultType = "mix",
  onConfirm,
  onCancel,
}: {
  file: File;
  defaultLabel: string;
  /** P2: default type = most-recent existing version's type, caller supplies it. */
  defaultType?: VersionType;
  onConfirm: (label: string, type: VersionType) => void;
  onCancel: () => void;
}) {
  const [label, setLabel] = useState(defaultLabel);
  const [type, setType] = useState<VersionType>(defaultType);
  // A2: show inline feedback on cancel
  const [cancelled, setCancelled] = useState(false);

  // A1: focus trap + Escape handler
  const firstFieldRef = useRef<HTMLInputElement>(null);
  const cancelBtnRef = useRef<HTMLButtonElement>(null);
  const triggerRef = useRef<HTMLElement | null>(null);

  useEffect(() => {
    // Remember what had focus before the dialog opened so we can restore it.
    triggerRef.current = document.activeElement as HTMLElement | null;
    firstFieldRef.current?.focus();
    return () => { triggerRef.current?.focus(); };
  }, []);

  function handleBackdropKeyDown(e: React.KeyboardEvent) {
    if (e.key === "Escape") { e.preventDefault(); handleCancel(); }
    // Tab trap
    if (e.key === "Tab") {
      const focusable = (e.currentTarget as HTMLElement).querySelectorAll<HTMLElement>(
        'input, select, button:not([disabled])'
      );
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (e.shiftKey && document.activeElement === first) {
        e.preventDefault(); last?.focus();
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault(); first?.focus();
      }
    }
  }

  function handleCancel() {
    // A2: show the cancel message briefly before unmounting.
    // We call onCancel() immediately but setCancelled so if the component
    // isn't unmounted synchronously the message appears. Parent controls timing.
    setCancelled(true);
    // Give React one paint to show the cancelled state before the parent
    // removes this component. If the parent unmounts immediately this is
    // a no-op (React handles it safely).
    setTimeout(onCancel, 40);
  }

  return (
    <div
      className="carry-triage-backdrop"
      role="dialog"
      aria-modal="true"
      aria-labelledby="upload-picker-title"
      onKeyDown={handleBackdropKeyDown}
      onClick={(e) => { if (e.target === e.currentTarget) handleCancel(); }}
    >
      <div className="carry-triage upload-picker">
        <header>
          <p className="eyebrow">NEW REVISION</p>
          <h2 id="upload-picker-title">{filenameStem(file.name)}</h2>
          {/* Copy: updated instruction text */}
          <p className="muted">Name this version and choose its type.</p>
        </header>
        <div className="upload-picker-fields">
          <label className="upload-picker-field">
            <span className="upload-picker-field-label">Label</span>
            <input
              ref={firstFieldRef}
              value={label}
              onChange={(e) => setLabel(e.target.value)}
              onKeyDown={(e) => { if (e.key === "Enter" && label.trim()) onConfirm(label.trim(), type); }}
              placeholder="e.g. Mix v3"
              autoFocus
            />
          </label>
          <label className="upload-picker-field">
            <span className="upload-picker-field-label">Type</span>
            <select value={type} onChange={(e) => setType(e.target.value as VersionType)}>
              {/* Copy: use humanizeVersionType */}
              {VERSION_TYPES.map((t) => (
                <option key={t} value={t}>{humanizeVersionType(t)}</option>
              ))}
            </select>
          </label>
        </div>
        <footer>
          <div className="footer-meta">{file.name}</div>
          <div className="footer-actions">
            {/* A2: inline note on cancel — visible for the brief 40ms before unmount */}
            {cancelled && (
              <span className="muted" style={{ fontSize: 11 }}>
                Upload cancelled — choose a file to try again.
              </span>
            )}
            <button ref={cancelBtnRef} type="button" className="chrome-button" onClick={handleCancel}>
              Cancel
            </button>
            <button
              type="button"
              className="accent-button"
              onClick={() => { if (label.trim()) onConfirm(label.trim(), type); }}
              disabled={!label.trim()}
            >
              Upload
            </button>
          </div>
        </footer>
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

  // A1: Escape + focus trap for CarryForwardTriage
  const triageRef = useRef<HTMLDivElement>(null);
  const triageTriggerRef = useRef<HTMLElement | null>(null);
  useEffect(() => {
    triageTriggerRef.current = document.activeElement as HTMLElement | null;
    const firstBtn = triageRef.current?.querySelector<HTMLElement>("button:not([disabled])");
    firstBtn?.focus();
    return () => { triageTriggerRef.current?.focus(); };
  }, []);

  function handleTriageKeyDown(e: React.KeyboardEvent) {
    if (e.key === "Escape" && !submitting) { e.preventDefault(); onCancel(); }
    if (e.key === "Tab") {
      const focusable = triageRef.current?.querySelectorAll<HTMLElement>(
        'button:not([disabled])'
      ) ?? [];
      const arr = Array.from(focusable);
      const first = arr[0];
      const last = arr[arr.length - 1];
      if (e.shiftKey && document.activeElement === first) {
        e.preventDefault(); last?.focus();
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault(); first?.focus();
      }
    }
  }

  return (
    <div
      className="carry-triage-backdrop"
      role="dialog"
      aria-modal="true"
      aria-labelledby="carry-triage-title"
      onKeyDown={handleTriageKeyDown}
      onClick={(e) => { if (e.target === e.currentTarget && !submitting) onCancel(); }}
    >
      <div className="carry-triage" ref={triageRef}>
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
  flashVersionID,
  onSelect,
  onSetCurrent,
}: {
  payload: SongPayload;
  activeVersionID?: string;
  flashVersionID?: string;
  onSelect: (version: Version) => void;
  onSetCurrent: (versionID: string) => void;
}) {
  // PF1: sort once and build the asset Map once — not per row.
  const sortedVersions = useMemo(
    () => [...payload.versions].sort((a, b) => a.version_number - b.version_number),
    [payload.versions]
  );
  const assetMap = useMemo(
    () => new Map(payload.assets.map((a) => [a.asset_id, a])),
    [payload.assets]
  );

  return (
    <section className="rail-panel">
      <div className="panel-topline">
        <div>
          <p className="eyebrow">VERSION STACK</p>
          <h2>History</h2>
        </div>
        <History size={18} />
      </div>
      {/* Copy: empty state */}
      {payload.versions.length === 0 && (
        <p className="muted" style={{ padding: "12px 0" }}>No versions yet.</p>
      )}
      {sortedVersions.map((version) => {
        const asset = assetMap.get(version.file_asset_id);
        // PF1: pass pre-sorted list + pre-built Map
        const delta = computeVersionDelta(version, sortedVersions, assetMap);
        const deltaStr = formatVersionDelta(delta);
        const isFlashing = version.version_id === flashVersionID;
        // A11Y A3: flash cue needs aria-live
        return (
          <div
            key={version.version_id}
            role="button"
            tabIndex={0}
            className={`version-row ${version.version_id === activeVersionID ? "selected" : ""} ${isFlashing ? "version-row--first-flash" : ""}`}
            onClick={() => onSelect(version)}
            onKeyDown={(event) => {
              if (event.key === "Enter" || event.key === " ") onSelect(version);
            }}
          >
            <div className="ver-num">{String(version.version_number).padStart(2, "0")}</div>
            <div className="version-body">
              <span>{version.version_label}</span>
              {/* Copy: humanizeVersionType; null-guard loudness (no "undefined LUFS") */}
              <small>
                {humanizeVersionType(version.type)}
                {asset?.loudness_lufs != null ? ` · ${asset.loudness_lufs} LUFS` : ""}
                {asset?.duration_ms != null ? ` · ${formatTimestamp(asset.duration_ms)}` : ""}
              </small>
              {deltaStr && <span className="version-delta">{deltaStr}</span>}
              {isFlashing && (
                <span className="version-first-cue" role="status" aria-live="polite">
                  v1 is in the stack.
                </span>
              )}
            </div>
            <div className="version-state">
              {version.version_id === payload.song.approved_version_id && (
                <Stamp kind="approved" tight straight />
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
  const openCurrent = notes.filter((n) => n.status === "open" && !n.is_carried);
  const openCarried = notes.filter((n) => n.status === "open" && n.is_carried);
  const resolved = notes.filter((n) => n.status === "resolved");

  function renderNote(note: VisibleNote) {
    return (
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
    );
  }

  return (
    <section className="rail-panel">
      <div className="panel-topline">
        <div>
          <p className="eyebrow">NOTES</p>
          <h2>{openCurrent.length + openCarried.length} Open</h2>
        </div>
        <MessageSquare size={18} />
      </div>
      {openCurrent.length > 0 && (
        <div className="note-section">
          <p className="note-section-label">Open on this version</p>
          <div className="note-list">{openCurrent.map(renderNote)}</div>
        </div>
      )}
      {openCarried.length > 0 && (
        <div className="note-section note-section--carried">
          <p className="note-section-label">Carried from earlier</p>
          <div className="note-list">{openCarried.map(renderNote)}</div>
        </div>
      )}
      {resolved.length > 0 && (
        <div className="note-section">
          <p className="note-section-label">Resolved</p>
          <div className="note-list">{resolved.map(renderNote)}</div>
        </div>
      )}
      {notes.length === 0 && (
        <p className="muted" style={{ padding: "12px 0" }}>No notes yet.</p>
      )}
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
    <div className="view-stack cmp-page">
      <div className="section-head">
        <div>
          <p className="eyebrow">{payload.song.title}</p>
          <h1>Compare</h1>
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
      <div className="deck-version-pills" role="group" aria-label={`Deck ${title} versions`}>
        {versions.map((item) => {
          const isCur = item.version_id === selectedID;
          return (
            <button
              key={item.version_id}
              className={`v ${isCur ? "cur" : ""}`}
              aria-current={isCur ? "true" : undefined}
              onClick={() => { onActivate(); onSelect(item.version_id); }}
            >
              {item.version_label}
            </button>
          );
        })}
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

type RoutedLink = { songID: string; memberName: string; token: string };

const INBOX_STORAGE_KEY = "pmw-inbox-triage-wsp-amf-private";

function readInboxStorage(): { saved: string[]; passed: string[] } {
  try {
    if (typeof window === "undefined" || !window.localStorage) return { saved: [], passed: [] };
    const raw = localStorage.getItem(INBOX_STORAGE_KEY);
    if (!raw) return { saved: [], passed: [] };
    const parsed = JSON.parse(raw) as unknown;
    if (typeof parsed !== "object" || parsed === null) return { saved: [], passed: [] };
    const p = parsed as Record<string, unknown>;
    const saved = Array.isArray(p.saved) ? (p.saved as unknown[]).filter((v) => typeof v === "string") as string[] : [];
    const passed = Array.isArray(p.passed) ? (p.passed as unknown[]).filter((v) => typeof v === "string") as string[] : [];
    return { saved, passed };
  } catch {
    return { saved: [], passed: [] };
  }
}

function writeInboxStorage(saved: Set<string>, passed: Set<string>) {
  try {
    if (typeof window === "undefined" || !window.localStorage) return;
    localStorage.setItem(INBOX_STORAGE_KEY, JSON.stringify({
      saved: Array.from(saved),
      passed: Array.from(passed),
    }));
  } catch {
    // Storage full or unavailable — fail silently
  }
}

function InboxView({
  items,
  onOpenSong,
}: {
  items: Awaited<ReturnType<typeof api.inbox>>;
  onOpenSong: (songID: string) => void;
}) {
  const [savedIDs, setSavedIDs] = useState<Set<string>>(() => new Set(readInboxStorage().saved));
  const [passedIDs, setPassedIDs] = useState<Set<string>>(() => new Set(readInboxStorage().passed));
  const [filter, setFilter] = useState<InboxFilter>("open");
  const [routingSong, setRoutingSong] = useState<Awaited<ReturnType<typeof api.inbox>>[number] | null>(null);
  const [routedLinks, setRoutedLinks] = useState<RoutedLink[]>([]);
  const [members, setMembers] = useState<Awaited<ReturnType<typeof api.workspaceMembers>>>([]);

  useEffect(() => {
    void api.workspaceMembers().then(setMembers).catch(() => setMembers([]));
  }, []);

  // Sync triage decisions to localStorage whenever either set changes
  useEffect(() => {
    writeInboxStorage(savedIDs, passedIDs);
  }, [savedIDs, passedIDs]);

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
    <div className="view-stack ibx-page">
      <div className="ibx-head">
        <h1>Inbox</h1>
        <div className="ibx-sub"><b>{items.filter((item) => item.new_since_last_listen).length} new</b> · routed to you</div>
      </div>
      <div className="inbox-filter">
        {(["open", "saved", "passed"] as const).map((f) => (
          <button
            key={f}
            className={`pill-button compact ${filter === f ? "on" : ""}`}
            onClick={() => setFilter(f)}
            aria-pressed={filter === f}
          >
            {f.charAt(0).toUpperCase() + f.slice(1)} <span className="count">{counts[f]}</span>
          </button>
        ))}
      </div>
      <div className="song-table">
        {filteredItems.length === 0 ? (
          <div className="inbox-empty">
            {filter === "open" && "Inbox zero. Everything's been triaged."}
            {filter === "saved" && "Nothing saved. Mark a row to keep it for later."}
            {filter === "passed" && "Nothing passed. Dismiss a submission to move it here."}
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
                      <button
                        className="icon-button"
                        title="Route to a collaborator"
                        onClick={() => setRoutingSong(item)}
                      >
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
      {routedLinks.length > 0 && (
        <div className="routed-banner" role="status" aria-live="polite">
          <div>
            <p className="eyebrow">ROUTED</p>
            <h3>{routedLinks.length} link{routedLinks.length === 1 ? "" : "s"} created</h3>
          </div>
          <ul>
            {routedLinks.slice(-3).reverse().map((link) => {
              const songTitle = items.find((i) => i.song.song_id === link.songID)?.song.title ?? "Song";
              const url = `${window.location.origin}/shared/${link.token}`;
              return (
                <li key={link.token}>
                  <span className="muted">to <b>{link.memberName}</b> · {songTitle}</span>
                  <button
                    className="text-button"
                    onClick={() => void navigator.clipboard.writeText(url)}
                    title={url}
                  >
                    Copy link
                  </button>
                </li>
              );
            })}
          </ul>
        </div>
      )}
      {routingSong && (
        <RouteMemberPicker
          song={routingSong.song}
          members={members}
          onCancel={() => setRoutingSong(null)}
          onRoute={async (member) => {
            const result = await api.createLink({
              workspace_id: "wsp-amf-private",
              target_type: "song",
              target_id: routingSong.song.song_id,
              link_name: `${routingSong.song.title} → ${member.display_name}`,
              access_mode: "identity_required",
              version_policy: "latest_only",
              download_policy: "none",
              watermark_enabled: true,
              allow_comments: true,
              allow_approval: true,
              allow_forwarding: false,
            });
            setRoutedLinks((prev) => [...prev, {
              songID: routingSong.song.song_id,
              memberName: member.display_name,
              token: result.token,
            }]);
            // Move the routed item to "saved" so it leaves the OPEN bucket
            save(routingSong.song.song_id);
            setRoutingSong(null);
          }}
        />
      )}
    </div>
  );
}

function RouteMemberPicker({
  song,
  members,
  onCancel,
  onRoute,
}: {
  song: Song;
  members: Array<{ user_id: string; display_name: string; role: string }>;
  onCancel: () => void;
  onRoute: (member: { user_id: string; display_name: string; role: string }) => Promise<void>;
}) {
  const [sending, setSending] = useState<string | null>(null);
  async function route(member: { user_id: string; display_name: string; role: string }) {
    if (sending) return;
    setSending(member.user_id);
    try {
      await onRoute(member);
    } finally {
      setSending(null);
    }
  }
  return (
    <div className="carry-triage-backdrop" role="dialog" aria-modal="true" aria-labelledby="route-title">
      <div className="carry-triage route-picker">
        <header>
          <p className="eyebrow">ROUTE TO COLLABORATOR</p>
          <h2 id="route-title">{song.title}</h2>
          <p className="muted">
            Creates an identity-required, latest-only, watermarked link for the chosen collaborator.
            They get notified; you keep the receipt.
          </p>
        </header>
        <ul className="triage-list route-list">
          {members.length === 0 ? (
            <li className="route-empty">Couldn't load collaborators. Check your connection and try again.</li>
          ) : members.map((m) => (
            <li key={m.user_id}>
              <button
                type="button"
                className="route-member"
                onClick={() => void route(m)}
                disabled={sending !== null}
              >
                <span className="avatar" aria-hidden="true">
                  {m.display_name.split(/\s+/).map((s) => s[0]).join("").slice(0, 2).toUpperCase()}
                </span>
                <span className="who">
                  <span className="name">{m.display_name}</span>
                  <span className="role">{m.role}</span>
                </span>
                <span className="send-cue">
                  {sending === m.user_id ? "Routing…" : "Send →"}
                </span>
              </button>
            </li>
          ))}
        </ul>
        <footer>
          <div className="footer-meta">{members.length} collaborator{members.length === 1 ? "" : "s"}</div>
          <div className="footer-actions">
            <button type="button" className="chrome-button" onClick={onCancel} disabled={sending !== null}>
              Cancel
            </button>
          </div>
        </footer>
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

  // PF2: build analytics Map once, not per link
  const analyticsByLink = useMemo(() => {
    type AnalyticsEvent = (typeof analytics)[number];
    const map = new Map<string, AnalyticsEvent[]>();
    for (const ev of analytics) {
      if (!ev.link_id) continue;
      const bucket = map.get(ev.link_id) ?? [];
      bucket.push(ev);
      map.set(ev.link_id, bucket);
    }
    return map;
  }, [analytics]);

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

  // PF2: memoize overall heard count across all links
  const overallHeard = useMemo(() => heardByCount(analytics), [analytics]);

  return (
    <div className="view-stack share-page">
      <div className="section-head">
        <div>
          <p className="eyebrow">Share · {song.title}</p>
          <h1>Share links</h1>
        </div>
        <button className="accent-button" onClick={createRoomLink}>
          <Plus size={16} />
          Create Link
        </button>
      </div>
      {overallHeard.heard > 0 && (
        <p className="heard-summary">
          {overallHeard.heard} of {overallHeard.total} {overallHeard.total === 1 ? "recipient" : "recipients"} listened
        </p>
      )}
      {latestToken && (
        <ForeverLinkCard token={latestToken} song={song} onClose={() => setLatestToken(null)} />
      )}
      <div className="link-list">
        {links.map((link) => {
          // PF2: use pre-built Map instead of filtering analytics per link
          const linkEvents = analyticsByLink.get(link.link_id) ?? [];
          const heard = heardByCount(linkEvents);
          // T2: honest display — identity-required gets ratio, public gets play count
          const heardDisplay = formatHeardDisplay(heard, link.requires_identity);
          return (
            <article key={link.link_id} className="link-row">
              <div className="link-body">
                <div className="link-title-row">
                  <p className="eyebrow">{link.target_type.toUpperCase()}</p>
                  {/* T2: use honest display form, never a false denominator on public links */}
                  {heardDisplay && (
                    <span className="heard-badge" title={heardDisplay}>
                      {heardDisplay}
                    </span>
                  )}
                </div>
                <h2>{link.link_name ?? link.link_id}</h2>
                <div className="hero-meta">
                  <span>{link.access_mode.replace("_", " ")}</span>
                  <span>{link.version_policy.replace("_", " ")}</span>
                  <span>{link.download_policy}</span>
                  <span>{link.watermark_enabled ? "watermark tracing" : "watermark off"}</span>
                </div>
                <LinkActivity events={linkEvents} versions={room.versions} songs={room.songs} />
              </div>
              <div className="row-actions">
                <a className="chrome-button" href={`/shared/${link.demo_token ?? ""}`}>
                  <Link2 size={15} />
                  Open
                </a>
                <button className="icon-button" title="Revoke access" onClick={async () => {
                  // Destructive and immediate: revoking cuts the recipient's
                  // audio the moment it lands. Confirm before doing it.
                  const ok = window.confirm(
                    `Revoke ${link.link_name ?? "this link"}? Anyone holding it loses access to the audio right away. You can't undo this.`,
                  );
                  if (!ok) return;
                  await api.revokeLink(link.link_id);
                  onRefresh();
                }}>
                  <LockKeyhole size={16} />
                </button>
              </div>
            </article>
          );
        })}
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

// hashHue, catalogNumber, catalogIdFor, coverGradient imported from ./utils

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

// T1: Generic queries only — the backend is a stub keyword-matcher that ignores
// song_id/version_id, so song-specific queries would mislead the user.
// "v2" replaced with "the latest version" per copy spec.
const GENERIC_SUGGESTED_QUERIES = [
  "Who hasn't heard the latest version?",
  "What notes are still open?",
  "Who has approved what?",
  "What's blocking release readiness?",
] as const;

function AssistantPanel({
  songID,
  songTitle,
  versionID,
  versionLabel: _versionLabel,
}: {
  songID?: string;
  songTitle?: string;
  versionID?: string;
  versionLabel?: string;
} = {}) {
  // T1: always use generic queries — no interpolated song/version
  const suggestedQueries = [...GENERIC_SUGGESTED_QUERIES];
  const [question, setQuestion] = useState<string>(suggestedQueries[0]);
  const [answer, setAnswer] = useState<Awaited<ReturnType<typeof api.ask>> | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  // C3: error state
  const [askError, setAskError] = useState<string | null>(null);
  // Whether the server has the Claude-backed Ask live (vs the keyword fallback),
  // so the disclaimer below tells the truth. null = not yet known → assume the
  // conservative (whole-workspace) wording until we hear back.
  const [llmEnabled, setLlmEnabled] = useState<boolean | null>(null);

  useEffect(() => {
    let active = true;
    api.assistantStatus()
      .then((s) => { if (active) setLlmEnabled(s.llm_enabled); })
      .catch(() => { /* leave conservative wording on failure */ });
    return () => { active = false; };
  }, []);

  async function submit(text = question) {
    setIsLoading(true);
    setAskError(null);
    setQuestion(text);
    // Keep sending song_id/version_id — harmless, forward-compat (T1).
    try {
      const result = await api.ask(text, { song_id: songID, version_id: versionID });
      setAnswer(result);
    } catch {
      // C3: catch network/server failures
      setAskError("Couldn't reach the workspace. Check your connection and try again.");
    } finally {
      setIsLoading(false);
    }
  }

  useEffect(() => {
    void submit(suggestedQueries[0]);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [songID, versionID]);

  return (
    <div className="view-stack ask-page">
      <div className="section-head">
        <div>
          <p className="eyebrow ask-tag">◇ Read-only</p>
          <h1>Ask the workspace</h1>
        </div>
        <Shield size={22} aria-label="Read-only — Ask cannot modify workspace state" />
      </div>
      {/* Honest disclaimer, calibrated to whether the AI backend is live. When
          live, name the third party and what leaves the workspace — the data is
          unreleased, so the disclosure has to be explicit, not buried. */}
      <p className="ask-context-line" style={{ color: "var(--pencil-warm)", fontStyle: "italic" }}>
        {llmEnabled
          ? `Answers come from Claude (Anthropic). Your question and a read-only summary of this workspace — song titles, notes, member and link names — are sent to generate them.${songTitle ? ` Focused on ${songTitle}.` : ""}`
          : `Answers search your workspace records directly. No AI, nothing leaves the workspace.${songTitle ? ` (Viewing: ${songTitle})` : ""}`}
      </p>
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
        {suggestedQueries.map((q) => (
          <button key={q} className="pill-button compact" onClick={() => void submit(q)}>{q}</button>
        ))}
      </div>
      <section className="answer-panel">
        {/* C3: error state */}
        {askError ? (
          <p style={{ color: "var(--redline)", fontSize: 13 }}>{askError}</p>
        ) : (
          <p>
            {isLoading
              ? "Checking…"
              : (answer?.answer || (!isLoading && answer !== null ? "No matching data found." : ""))}
          </p>
        )}
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

// =====================================================================
//  ForeverLinkCard — branded presentation of a share link token
// =====================================================================

function ForeverLinkCard({ token, song, onClose }: { token: string; song: Song; onClose: () => void }) {
  const [copied, setCopied] = useState(false);
  const url = `${window.location.origin}/shared/${token}`;

  function copy() {
    void navigator.clipboard.writeText(url);
    setCopied(true);
    setTimeout(() => setCopied(false), 2200);
  }

  return (
    <div className="forever-card">
      <div className="forever-card-header">
        <PlaybackWordmark size="sm" />
        <button className="forever-card-close" onClick={onClose} aria-label="Dismiss link card">
          <X size={14} />
        </button>
      </div>
      <div className="forever-card-body">
        <span className="forever-card-eyebrow">Private Link</span>
        <h3 className="forever-card-title">{song.title}</h3>
        {song.artist_display_name && (
          <div className="forever-card-artist">{song.artist_display_name}</div>
        )}
      </div>
      <div className="forever-card-url-row">
        <code>/shared/{token}</code>
      </div>
      <div className="forever-card-foot">
        <span className="forever-card-meta">identity required · watermarked · no download</span>
        <button className={`forever-card-copy${copied ? " copied" : ""}`} onClick={copy}>
          {copied ? "Copied" : "Copy link"}
        </button>
      </div>
    </div>
  );
}

// =====================================================================
//  FindSimilarPanel — related songs based on BPM, key, and tag overlap
// =====================================================================

function FindSimilarPanel({ song, onOpenSong }: { song: Song; onOpenSong: (id: string) => void }) {
  const [items, setItems] = useState<Awaited<ReturnType<typeof api.workspaceLibrary>>>([]);

  useEffect(() => {
    api.workspaceLibrary().then(setItems).catch(() => {});
  }, []);

  function score(candidate: (typeof items)[number]): number {
    const s = candidate.song;
    if (s.song_id === song.song_id) return -1;
    let n = 0;
    if (song.bpm && s.bpm && Math.abs(song.bpm - s.bpm) <= 12) n += 2;
    if (song.song_key && s.song_key && song.song_key === s.song_key) n += 3;
    n += song.genre_tags.filter((t) => s.genre_tags.includes(t)).length * 2;
    n += song.mood_tags.filter((t) => s.mood_tags.includes(t)).length;
    if (s.primary_room_id && s.primary_room_id === song.primary_room_id) n += 1;
    return n;
  }

  const similar = items
    .map((item) => ({ item, s: score(item) }))
    .filter((x) => x.s > 0)
    .sort((a, b) => b.s - a.s)
    .slice(0, 5)
    .map((x) => x.item);

  if (similar.length === 0) return null;

  return (
    <section className="rail-panel">
      <div className="panel-topline">
        <div>
          <p className="eyebrow">SIMILAR</p>
          <h2>Related Work</h2>
        </div>
        <Radio size={18} />
      </div>
      <div className="find-similar-list">
        {similar.map(({ song: s, current_version }) => (
          <button key={s.song_id} className="find-similar-row" onClick={() => onOpenSong(s.song_id)}>
            <div className="cover-art" aria-hidden="true" style={{ backgroundImage: coverGradient(s.song_id) }} />
            <div className="find-similar-text">
              <span className="find-similar-title">{s.title}</span>
              <span className="find-similar-meta">
                {s.artist_display_name}{current_version && ` · ${current_version.version_label}`}
              </span>
            </div>
          </button>
        ))}
      </div>
    </section>
  );
}

// ─── Join page ──────────────────────────────────────────────────────────────
// Rendered when someone opens a /join/:token link. No auth required.

const JOIN_API = import.meta.env.DEV ? "http://localhost:4317" : "https://white-label-api-6mnt.onrender.com";

function JoinPage({ token }: { token: string }) {
  const [workspaceName, setWorkspaceName] = useState<string | null>(null);
  const [linkError, setLinkError] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [phone, setPhone] = useState("");
  const [busy, setBusy] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);
  const [done, setDone] = useState<{ email: string; testflightUrl: string | null; smsSent: boolean } | null>(null);

  useEffect(() => {
    fetch(`${JOIN_API}/join/${token}`)
      .then((r) => r.json())
      .then((j: { data?: { workspace_name?: string }; error?: string }) => {
        if (j.error) setLinkError(j.error);
        else setWorkspaceName(j.data?.workspace_name ?? "Playback");
      })
      .catch(() => setLinkError("Could not load this invite. Check your connection."));
  }, [token]);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!name.trim() || !email.trim() || !password) { setFormError("All fields are required."); return; }
    setBusy(true);
    setFormError(null);
    try {
      const res = await fetch(`${JOIN_API}/join/${token}/claim`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ display_name: name.trim(), email: email.trim(), password, phone: phone.trim() || undefined }),
      });
      const j = await res.json() as { data?: { email: string; testflight_url: string | null; sms_sent: boolean }; error?: string };
      if (!res.ok || j.error) { setFormError(j.error ?? "Something went wrong. Try again."); return; }
      setDone({ email: j.data!.email, testflightUrl: j.data!.testflight_url, smsSent: j.data!.sms_sent });
    } catch { setFormError("Network error. Check your connection and try again."); }
    finally { setBusy(false); }
  }

  const s = {
    page: { minHeight: "100vh", background: "#0c0907", display: "flex", flexDirection: "column" as const, alignItems: "center", justifyContent: "center", padding: "32px 20px", fontFamily: "'HelveticaNeue', sans-serif" },
    card: { width: "100%", maxWidth: 420, color: "#f3ecde" },
    kicker: { fontFamily: "monospace", fontSize: 10, letterSpacing: "0.18em", color: "#9b9285", textTransform: "uppercase" as const, margin: "0 0 8px" },
    title: { fontSize: 36, fontWeight: 700, margin: "0 0 6px", letterSpacing: "-0.5px" },
    sub: { fontSize: 14, color: "#9b9285", margin: "0 0 28px" },
    label: { fontFamily: "monospace", fontSize: 10, letterSpacing: "0.14em", color: "#9b9285", textTransform: "uppercase" as const, display: "block", marginBottom: 6 },
    input: { width: "100%", background: "#16110c", border: "1px solid rgba(243,236,222,0.12)", borderRadius: 10, padding: "13px 14px", color: "#f3ecde", fontSize: 16, outline: "none", boxSizing: "border-box" as const, marginBottom: 14 },
    btn: { width: "100%", background: "#f3ecde", color: "#0c0907", border: "none", borderRadius: 24, padding: "15px", fontSize: 13, fontFamily: "monospace", letterSpacing: "0.14em", cursor: "pointer", fontWeight: 700, marginTop: 6 },
    btnDisabled: { opacity: 0.45, cursor: "not-allowed" },
    err: { color: "#ff4a22", fontFamily: "monospace", fontSize: 11, letterSpacing: "0.1em", marginTop: 12 },
    success_title: { fontSize: 40, fontWeight: 700, margin: "0 0 8px" },
    success_email: { background: "#16110c", border: "1px solid rgba(243,236,222,0.1)", borderRadius: 10, padding: "12px 14px", fontFamily: "monospace", fontSize: 13, color: "#4663e8", letterSpacing: "0.06em", margin: "16px 0" },
    tfBtn: { display: "block", textAlign: "center" as const, background: "#4663e8", color: "#f3ecde", borderRadius: 24, padding: "15px", fontSize: 13, fontFamily: "monospace", letterSpacing: "0.14em", fontWeight: 700, textDecoration: "none", marginTop: 20 },
  };

  if (linkError) {
    return (
      <div style={s.page}>
        <div style={s.card}>
          <p style={s.kicker}>Playback</p>
          <h1 style={s.title}>Invalid link</h1>
          <p style={{ ...s.sub, color: "#ff4a22" }}>{linkError}</p>
        </div>
      </div>
    );
  }

  if (done) {
    return (
      <div style={s.page}>
        <div style={s.card}>
          <p style={s.kicker}>Playback · {workspaceName}</p>
          <h1 style={s.success_title}>You're in.</h1>
          <p style={s.sub}>Open Playback on your iPhone and sign in with:</p>
          <div style={s.success_email}>{done.email}</div>
          {done.testflightUrl && (
            <a href={done.testflightUrl} style={s.tfBtn}>Download on TestFlight →</a>
          )}
          {!done.testflightUrl && (
            <p style={{ ...s.sub, marginTop: 16 }}>Ask the workspace owner for the TestFlight link to download the app.</p>
          )}
          {done.smsSent && (
            <p style={{ ...s.kicker, marginTop: 18 }}>We also texted you the download link.</p>
          )}
        </div>
      </div>
    );
  }

  return (
    <div style={s.page}>
      <div style={s.card}>
        <p style={s.kicker}>You've been invited to</p>
        <h1 style={s.title}>{workspaceName ?? "…"}</h1>
        <p style={s.sub}>Create your account to join.</p>
        <form onSubmit={handleSubmit}>
          <label style={s.label}>Your name</label>
          <input style={s.input} placeholder="Alex Rivera" value={name} onChange={(e) => setName(e.target.value)} autoComplete="name" required />
          <label style={s.label}>Email</label>
          <input style={s.input} type="email" placeholder="alex@studio.com" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" required />
          <label style={s.label}>Password</label>
          <input style={s.input} type="password" placeholder="at least 8 characters" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="new-password" required />
          <label style={s.label}>Phone <span style={{ color: "#9b9285", fontWeight: 400 }}>(optional — we'll text you the download link)</span></label>
          <input style={s.input} type="tel" placeholder="+1 555 000 0000" value={phone} onChange={(e) => setPhone(e.target.value)} autoComplete="tel" />
          <button type="submit" style={{ ...s.btn, ...(busy ? s.btnDisabled : {}) }} disabled={busy}>
            {busy ? "Creating account…" : "CREATE ACCOUNT"}
          </button>
          {formError && <p style={s.err}>{formError}</p>}
        </form>
      </div>
    </div>
  );
}

function SharedListeningPage({ token }: { token: string }) {
  const [payload, setPayload] = useState<SharedPayload | null>(null);
  const [selectedSongID, setSelectedSongID] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);

  async function loadShared() {
    setLoadError(null);
    try {
      const nextPayload = await api.shared(token);
      setPayload(nextPayload);
      setSelectedSongID(nextPayload.songs[0]?.song_id ?? null);
    } catch {
      setPayload(null);
      setSelectedSongID(null);
      setLoadError("This private link couldn't be opened. It may have expired, been revoked, or lost connection.");
    }
  }

  useEffect(() => {
    void loadShared();
  }, [token]);

  if (loadError) {
    return (
      <div className="shared-page">
        <TopBar roomTitle="Private link" error={null} />
        <div className="sleeve-state" role="status">
          <p className="eyebrow">PRIVATE LINK</p>
          <h1>Link unavailable</h1>
          <p>{loadError}</p>
          <button className="accent-button" onClick={() => void loadShared()}>Try again</button>
        </div>
      </div>
    );
  }

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
        void loadShared();
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

  // C1: key approveState by version_id so approval survives song switching and
  // returning to the same song without looking like it didn't happen.
  const [approveStates, setApproveStates] = useState<Record<string, "idle" | "pending" | "done">>({});

  useEffect(() => {
    setActiveVersionID(current?.version_id ?? null);
    // T3(b): reset noteBody when active song changes so a pending note can't
    // accidentally post against the wrong song after auto-advance.
    setNoteBody("");
    // Note: we do NOT reset approveState here (C1 fix).
  }, [current?.version_id]);

  const activeVersion = versions.find((v) => v.version_id === activeVersionID) ?? current;
  const activeAsset = payload && activeVersion ? assetForVersion(payload.assets, activeVersion) : asset;
  const allowApproval = payload?.link.allow_approval ?? false;
  const alreadyApproved = !!activeVersion?.is_approved;

  // C1: look up approve state for the current version (defaults to "idle")
  const approveState = activeVersion ? (approveStates[activeVersion.version_id] ?? "idle") : "idle";
  function setApproveState(versionID: string, state: "idle" | "pending" | "done") {
    setApproveStates((prev) => ({ ...prev, [versionID]: state }));
  }

  // Moment 4: auto-advance / up-next for multi-song playlists.
  // PF3: read positionMs via a ref to avoid stale closure without adding it to deps.
  const positionMsRef = useRef(player.positionMs);
  positionMsRef.current = player.positionMs;

  const prevIsPlayingRef = useRef(false);
  const isMultiSong = (payload?.songs.length ?? 0) > 1;

  const currentSongIndex = isMultiSong && payload
    ? payload.songs.findIndex((s) => s.song_id === selectedSongID)
    : -1;
  const nextSong = isMultiSong && payload && currentSongIndex >= 0 && currentSongIndex < payload.songs.length - 1
    ? payload.songs[currentSongIndex + 1]
    : null;

  useEffect(() => {
    const wasPlaying = prevIsPlayingRef.current;
    prevIsPlayingRef.current = player.isPlaying;

    if (!isMultiSong || !nextSong) return;
    if (!payload || !activeAsset) return;
    // Only trigger when transitioning from playing → not playing
    if (!wasPlaying || player.isPlaying) return;
    // T3(a): do NOT auto-advance when there is a note being composed —
    // let the user finish posting before moving to the next song.
    if (noteBody.trim()) return;
    // T3(c): respect reduced motion / autoplay sensitivity
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    // Only auto-advance when position is near end (within 400 ms of duration)
    const durationMs = activeAsset.duration_ms ?? 0;
    // PF3: read via ref, not from closure
    if (durationMs > 0 && positionMsRef.current >= durationMs - 400) {
      onSelectSong(nextSong.song_id);
    }
  }, [player.isPlaying]); // eslint-disable-line react-hooks/exhaustive-deps

  async function approve() {
    if (!activeVersion || approveState !== "idle") return;
    setApproveState(activeVersion.version_id, "pending");
    try {
      await api.sharedApprove(token, activeVersion.version_id);
      setApproveState(activeVersion.version_id, "done");
      onNotePosted();
    } catch {
      setApproveState(activeVersion.version_id, "idle");
    }
  }

  const songNotes = payload && song ? payload.notes.filter((n) => n.song_id === song.song_id) : [];

  async function submitNote() {
    if (!song || !activeVersion || !noteBody.trim()) return;
    setPosting(true);
    try {
      await api.sharedNote(token, {
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
        <TopBar roomTitle="Private link" error={null} />
        {/* C4: skeleton order matches loaded layout — crumb→title→artist→cover→waveform */}
        <div className="sleeve-skeleton" aria-busy="true" aria-label="Loading private link…">
          {/* crumb placeholder */}
          <div className="sleeve-skeleton-line" style={{ height: 14, width: "55%", animationDelay: "0s" }} />
          {/* title block — sized to match h1 clamp */}
          <div className="sleeve-skeleton-line sleeve-skeleton-line--title" />
          {/* artist line */}
          <div className="sleeve-skeleton-line sleeve-skeleton-line--artist" />
          {/* cover art placeholder */}
          <div className="sleeve-skeleton-cover" />
          {/* waveform */}
          <div className="sleeve-skeleton-waveform" />
        </div>
      </div>
    );
  }

  const catalogId = catalogIdFor(song.song_id);

  return (
    <div className="shared-page">
      <TopBar roomTitle="Private link" error={null} />
      <div className="recipient-layout">
        <section className="recipient-listen">
          {payload.playlist && (
            <div className="recipient-playlist-strip">
              <div
                className="playlist-cover small"
                aria-hidden="true"
                style={{ backgroundImage: coverGradient(payload.playlist.cover_seed) }}
              />
              <div className="playlist-strip-info">
                <p className="eyebrow">PLAYLIST</p>
                <h2>{payload.playlist.title}</h2>
                {payload.playlist.description && (
                  <p className="muted">{payload.playlist.description}</p>
                )}
                <div className="playlist-strip-meta">
                  <span>{payload.songs.length} {payload.songs.length === 1 ? "song" : "songs"}</span>
                  <span>Currently playing: {song.title}</span>
                </div>
              </div>
            </div>
          )}

          <div className="recipient-crumb">
            <div className="left">
              <b>{catalogId} · {song.title}</b><br />
              {song.artist_display_name} · sent via private link · {payload.link.watermark_enabled ? "watermarked" : "open playback"}
              <br />
              <span className="muted" style={{ fontSize: "0.78em" }}>
                The sender can see when you open this and what you play.
              </span>
            </div>
            <div className="stamps">
              {payload.link.version_policy === "latest_only" && (
                <Stamp kind="latest" tight straight>v{current.version_number}</Stamp>
              )}
              {!current.is_approved && <Stamp kind="notes-due" tight />}
              {current.is_approved && <Stamp kind="approved" tight straight />}
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
                <Stamp kind="approved" straight>{activeVersion?.version_label}</Stamp>
              ) : approveState === "done" ? (
                /* A3: aria-live so AT announces the confirmation */
                <div className="recipient-approve-ceremony" role="status" aria-live="polite">
                  <span className="stamp-arrive-wrap">
                    <Stamp kind="approved" straight>just now</Stamp>
                  </span>
                  {/* Copy: "Approval sent." */}
                  <p className="recipient-approve-confirm">Approval sent.</p>
                </div>
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
            <div className="recipient-versions" role="group" aria-label="Available versions">
              {versions.map((v) => {
                const isCur = v.version_id === activeVersion?.version_id;
                return (
                  <button
                    type="button"
                    key={v.version_id}
                    className={isCur ? "cur" : ""}
                    aria-current={isCur ? "true" : undefined}
                    onClick={() => {
                      setActiveVersionID(v.version_id);
                      const a = assetForVersion(payload.assets, v);
                      if (a) player.play(song, v, a);
                    }}
                  >
                    {v.version_label ?? `v${v.version_number}`}
                    {v.version_id === current.version_id ? " · current" : ""}
                  </button>
                );
              })}
            </div>
          )}

          {/* D4: show up-next whenever nextSong exists, not only when playing */}
          {nextSong && (
            <div className="recipient-up-next" aria-live="polite">
              <span className="recipient-up-next-label">Up next</span>
              <button
                className="recipient-up-next-title"
                onClick={() => onSelectSong(nextSong.song_id)}
              >
                {nextSong.title}
              </button>
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
                    <span>{catalogIdFor(item.song_id)}</span>
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
              <div className="who"><span>No notes yet.</span></div>
              <div className="what" style={{ color: "var(--pencil-cool)", marginTop: 8, fontSize: 13 }}>
                Scrub to a moment, type, press return.
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
        <button type="submit" className="send" disabled={posting || !noteBody.trim()}>
          {posting ? "…" : "Note"}
        </button>
      </form>

      <MiniPlayer />
    </div>
  );
}

function MiniPlayer({ onOpenSong }: { onOpenSong?: (songID: string) => void } = {}) {
  const player = usePlayer();
  if (!player.song || !player.version || !player.asset) return null;
  const songID = player.song.song_id;
  return (
    <aside className="mini-player">
      <button className="icon-button active" title={player.isPlaying ? "Pause" : "Play"} onClick={player.toggle}>
        {player.isPlaying ? <Pause size={16} /> : <Play size={16} />}
      </button>
      <button
        className={`mini-copy${onOpenSong ? " linked" : ""}`}
        onClick={onOpenSong ? () => onOpenSong(songID) : undefined}
        disabled={!onOpenSong}
        title={onOpenSong ? "Open song" : undefined}
      >
        <span>{player.song.title}</span>
        <small>{player.version.version_label} · {formatTimestamp(player.positionMs)}</small>
      </button>
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
   TransportKeys — hardware-style dot-matrix keys, ported from iOS Transport.swift.
   Circular keys: flat face, extruded wall, raised-then-recessed on press.
   Greyscale for back/play/forward; cobalt for the add-note key.
   ===================================================================== */

// Dot-matrix glyph definitions (match iOS DotGlyphKind row strings exactly)
const GLYPHS: Record<string, string[]> = {
  back:    ["X....X", "X...XX", "X..XXX", "X.XXXX", "X..XXX", "X...XX", "X....X"],
  play:    ["X...", "XX..", "XXX.", "XXXX", "XXX.", "XX..", "X..."],
  pause:   ["XX.XX", "XX.XX", "XX.XX", "XX.XX", "XX.XX", "XX.XX", "XX.XX"],
  forward: ["X....X", "XX...X", "XXX..X", "XXXX.X", "XXX..X", "XX...X", "X....X"],
  note:    ["XXXXX....", ".......X.", "XXXXX.XXX", ".......X.", "XXX......"],
};

function DotGlyph({ name, size = 14, color = "#33302B" }: { name: string; size?: number; color?: string }) {
  const rows = GLYPHS[name] ?? [];
  const cols = Math.max(...rows.map((r) => r.length));
  const pitch = size / Math.max(cols, rows.length);
  const r = pitch * 0.36;
  const w = cols * pitch;
  const h = rows.length * pitch;
  return (
    <svg width={w} height={h} viewBox={`0 0 ${w} ${h}`} aria-hidden="true" style={{ display: "block" }}>
      {rows.flatMap((row, ri) =>
        [...row].map((ch, ci) =>
          ch === "X" ? (
            <circle
              key={`${ri}-${ci}`}
              cx={(ci + 0.5) * pitch}
              cy={(ri + 0.5) * pitch}
              r={r}
              fill={color}
            />
          ) : null
        )
      )}
    </svg>
  );
}

function FlatKey({
  glyph,
  held = false,
  disabled = false,
  face = "#D3CFC5",
  ink = "#33302B",
  shadow = "#8C887D",
  onClick,
  title,
}: {
  glyph: string;
  held?: boolean;
  disabled?: boolean;
  face?: string;
  ink?: string;
  shadow?: string;
  onClick?: () => void;
  title?: string;
}) {
  const [pressed, setPressed] = useState(false);
  const down = held || pressed;
  return (
    <button
      className={`flat-key${down ? " down" : ""}${disabled ? " disabled" : ""}`}
      style={{
        "--fk-face": face,
        "--fk-shadow": shadow,
      } as React.CSSProperties}
      onMouseDown={() => !disabled && setPressed(true)}
      onMouseUp={() => setPressed(false)}
      onMouseLeave={() => setPressed(false)}
      onTouchStart={() => !disabled && setPressed(true)}
      onTouchEnd={() => setPressed(false)}
      onClick={disabled ? undefined : onClick}
      title={title}
      disabled={disabled}
      aria-pressed={held}
    >
      <DotGlyph name={glyph} color={disabled ? "#999" : ink} />
    </button>
  );
}

function TransportKeys({
  playing,
  canPlay,
  canSeek,
  canForward = false,
  onBack,
  onPlay,
  onForward,
  onNote,
}: {
  playing: boolean;
  canPlay: boolean;
  canSeek: boolean;
  canForward?: boolean;
  onBack: () => void;
  onPlay: () => void;
  onForward: () => void;
  onNote?: () => void;
}) {
  return (
    <div className="transport-keys">
      <FlatKey glyph="back"    disabled={!canSeek}    onClick={onBack}    title="Restart" />
      <FlatKey glyph={playing ? "pause" : "play"} held={playing} disabled={!canPlay} onClick={onPlay} title={playing ? "Pause" : "Play"} />
      <FlatKey glyph="forward" disabled={!canForward} onClick={onForward} title="Next version" />
      {onNote && (
        <FlatKey
          glyph="note"
          face="#6E86EC"
          ink="#fff"
          shadow="#3A52C4"
          onClick={onNote}
          title="Add note"
        />
      )}
    </div>
  );
}

/* =====================================================================
   SongOverlay — the iOS-style slide-up player + workspace panel.
   Replaces the old "nowplaying" and "song" page modes.
   On wide screens (≥960px): both panels side by side.
   On narrow: tabbed, tab bar at top.
   ===================================================================== */

function SongOverlay({
  open,
  payload,
  tab,
  onTabChange,
  onClose,
  playlists,
  onRefresh,
  onRefreshPlaylists,
  onOpenSong,
}: {
  open: boolean;
  payload: SongPayload | null;
  tab: "player" | "workspace";
  onTabChange: (t: "player" | "workspace") => void;
  onClose: () => void;
  playlists: Awaited<ReturnType<typeof api.playlists>>;
  onRefresh: () => void;
  onRefreshPlaylists: () => void;
  onOpenSong?: (id: string) => void;
}) {
  const overlayRef = useRef<HTMLDivElement>(null);

  // ESC to close
  useEffect(() => {
    if (!open) return;
    const handler = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [open, onClose]);

  // Focus trap: when overlay opens, focus it; Tab cycles within it
  useEffect(() => {
    if (!open) return;
    const el = overlayRef.current;
    if (!el) return;
    const prev = document.activeElement as HTMLElement | null;
    el.focus();
    const trap = (e: KeyboardEvent) => {
      if (e.key !== "Tab") return;
      const focusable = Array.from(el.querySelectorAll<HTMLElement>(
        'button:not([disabled]), [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
      ));
      if (!focusable.length) return;
      const first = focusable[0], last = focusable[focusable.length - 1];
      if (e.shiftKey) { if (document.activeElement === first) { e.preventDefault(); last.focus(); } }
      else            { if (document.activeElement === last)  { e.preventDefault(); first.focus(); } }
    };
    el.addEventListener("keydown", trap);
    return () => { el.removeEventListener("keydown", trap); prev?.focus(); };
  }, [open]);

  useEffect(() => {
    const el = overlayRef.current as (HTMLDivElement & { inert?: boolean }) | null;
    if (!el) return;
    el.inert = !open;
    el.toggleAttribute("inert", !open);
  }, [open]);

  return (
    <div
      ref={overlayRef}
      className={`song-overlay${open ? " open" : ""}`}
      aria-hidden={!open}
      aria-modal={open ? true : undefined}
      role={open ? "dialog" : undefined}
      aria-label="Song player and workspace"
      tabIndex={open ? -1 : undefined}
    >
      {/* Narrow: tab bar */}
      <div className="overlay-tabs">
        <button
          className={`overlay-tab${tab === "player" ? " active" : ""}`}
          onClick={() => onTabChange("player")}
        >
          Now Playing
        </button>
        <button
          className={`overlay-tab${tab === "workspace" ? " active" : ""}`}
          onClick={() => onTabChange("workspace")}
        >
          Workspace
        </button>
        <button className="overlay-close-tab" onClick={onClose} aria-label="Close">
          <X size={16} />
        </button>
      </div>

      {/* Player panel — left on wide, full on narrow when tab=player */}
      <div className={`overlay-panel overlay-player-panel${tab === "workspace" ? " narrow-hidden" : ""}`}>
        {payload
          ? <NowPlayingView payload={payload} onClose={onClose} onNote={() => onTabChange("workspace")} />
          : <div className="overlay-loading">Loading…</div>
        }
      </div>

      {/* Workspace panel — right on wide, full on narrow when tab=workspace */}
      <div className={`overlay-panel overlay-workspace-panel${tab === "player" ? " narrow-hidden" : ""}`}>
        {payload
          ? (
            <SongWorkspace
              payload={payload}
              playlists={playlists}
              onRefresh={onRefresh}
              onRefreshPlaylists={onRefreshPlaylists}
              onOpenSong={onOpenSong}
            />
          )
          : <div className="overlay-loading">Loading…</div>
        }
      </div>
    </div>
  );
}

/* =====================================================================
   Brand primitives — Wordmark, MonoMark, Stamp
   ===================================================================== */

function Wordmark({ size = "md", title, isPlaying = false }: { size?: "sm" | "md" | "lg"; title?: string; isPlaying?: boolean }) {
  return <PlaybackWordmark size={size} title={title} isPlaying={isPlaying} />;
}

function MonoMark({ size = 16 }: { size?: number }) {
  return <PlaybackMark size={size} />;
}

type StampKind = "private" | "notes-due" | "approved" | "latest";

const STAMP_SLUG: Record<StampKind, string> = {
  approved: "stamp_approved",
  "notes-due": "stamp_notes_due",
  private: "stamp_private",
  latest: "stamp_latest",
};

function Stamp({
  kind = "private",
  tight = false,
  straight = false,
  children,
}: {
  kind?: StampKind;
  tight?: boolean;
  straight?: boolean;
  children?: ReactNode;
}) {
  const cls = ["stamp-w", kind, tight ? "tight" : "", straight ? "straight" : ""].filter(Boolean).join(" ");
  return (
    <span className={cls}>
      <img src={`/brand/${STAMP_SLUG[kind]}.png`} alt={kind.replace("-", " ")} className="stamp-w-img" aria-hidden="true" />
      {children && <span className="stamp-w-detail">{children}</span>}
    </span>
  );
}
