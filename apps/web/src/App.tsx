import { memo, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
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
import { api, assetForVersion, uploadAudio, type MyPinsPayload, type RecentItem, type ProjectPayload, type SharedPayload, type SongPayload, versionsForSong } from "./api";
import { usePlayer } from "./player";
import { onAuthChange, signOut, getSession } from "./auth";
import { SignIn } from "./SignIn";
import type { Session } from "@supabase/supabase-js";

const STATUS_MAP: Record<string, string> = {
  approved: "Approved",
  in_review: "In review",
  revision_requested: "Revision",
  in_progress: "In progress",
  draft: "Draft",
  ready: "Ready",
};

const PROJECT_TYPE_MAP: Record<string, string> = {
  project: "Project",
  producer_delivery: "Delivery",
  album_ep: "Album / EP",
  anr: "A&R",
  pitch: "Pitch",
  submission_portal: "Submissions",
  release: "Release",
  inner_circle: "Inner circle",
  archive: "Archive",
};

type ViewMode = "home" | "library" | "project" | "song" | "compare" | "inbox" | "links" | "assistant" | "playlist";

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
  const [projectPayload, setProjectPayload] = useState<ProjectPayload | null>(null);
  const [songPayload, setSongPayload] = useState<SongPayload | null>(null);
  const [mode, setMode] = useState<ViewMode>("home");
  const [selectedSongID, setSelectedSongID] = useState("song-midnight");
  const [activeProjectID, setActiveProjectID] = useState("room-hudson-ingram-lp");
  const [activePlaylistID, setActivePlaylistID] = useState<string | null>(null);
  const [inboxItems, setInboxItems] = useState<Awaited<ReturnType<typeof api.inbox>>>([]);
  const [projectsSummary, setProjectsSummary] = useState<Awaited<ReturnType<typeof api.projectsSummary>>>([]);
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

  async function refresh(nextSongID = selectedSongID, nextProjectID = activeProjectID) {
    try {
      const [room, summary, allPlaylists, allSavedViews] = await Promise.all([
        api.project(nextProjectID),
        api.projectsSummary(),
        api.playlists(),
        api.savedViews(),
      ]);
      setProjectPayload(room);
      setProjectsSummary(summary);
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
    void refresh(selectedSongID, activeProjectID);
    void refreshPins();
  }, []);

  const selectedSong = projectPayload?.songs.find((song) => song.song_id === selectedSongID) ?? songPayload?.song;

  function openSong(songID: string) {
    setSelectedSongID(songID);
    setMode("song");
    void refresh(songID, activeProjectID);
  }

  function openProject(projectID: string) {
    setActiveProjectID(projectID);
    setMode("project");
    setActivePlaylistID(null);
    void refresh(selectedSongID, projectID);
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
        roomTitle={projectPayload?.project.title ?? "Private Workspace"}
        error={error}
        onSignOut={onSignOut}
        projects={projectsSummary}
        activeProjectID={activeProjectID}
        onPickProject={openProject}
      />
      <main className="workspace-grid">
        <Sidebar
          mode={mode}
          setMode={setMode}
          project={projectPayload}
          projects={projectsSummary}
          activeProjectID={activeProjectID}
          onSelectProject={openProject}
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
              onOpenProject={(id) => { setSelectedSongID(id); setMode("song"); }}
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
          {mode === "project" && projectPayload && (
            <ProjectView payload={projectPayload} onOpenSong={openSong} />
          )}
          {mode === "song" && songPayload && <SongWorkspace payload={songPayload} playlists={playlists} onRefresh={() => refresh(songPayload.song.song_id)} onRefreshPlaylists={() => api.playlists().then(setPlaylists)} />}
          {mode === "compare" && songPayload && <ComparisonMode payload={songPayload} onRefresh={() => refresh(songPayload.song.song_id)} />}
          {mode === "inbox" && <InboxView items={inboxItems} onOpenSong={openSong} />}
          {mode === "links" && projectPayload && selectedSong && (
            <LinkManager project={projectPayload} song={selectedSong} onRefresh={() => refresh(selectedSong.song_id)} />
          )}
          {mode === "assistant" && <AssistantPanel />}
          {mode === "playlist" && activePlaylistID && (
            <PlaylistView
              playlistID={activePlaylistID}
              onOpenSong={openSong}
              onRefreshPlaylists={() => api.playlists().then(setPlaylists)}
            />
          )}
        </section>
      </main>
      <MiniPlayer />
    </div>
  );
}

function TopBar({
  roomTitle,
  error,
  onSignOut,
  projects = [],
  activeProjectID,
  onPickProject,
}: {
  roomTitle: string;
  error: string | null;
  onSignOut?: () => void;
  projects?: Awaited<ReturnType<typeof api.projectsSummary>>;
  activeProjectID?: string;
  onPickProject?: (id: string) => void;
}) {
  const [pickerOpen, setPickerOpen] = useState(false);
  const activeProject = projects.find((r) => r.project_id === activeProjectID);
  return (
    <header className="top-bar">
      <div className="icon-run">
        <button className="icon-button active" title="Notifications" aria-label="Notifications, unread">
          <Bell size={17} />
          <span className="notify-dot" />
        </button>
        <button className="icon-button" title="Search" aria-label="Search workspace">
          <Search size={17} />
        </button>
        {projects.length > 0 && onPickProject && (
          <div className="project-picker">
            <button
              className="project-picker-trigger"
              onClick={() => setPickerOpen((o) => !o)}
              aria-expanded={pickerOpen}
              aria-haspopup="listbox"
            >
              <span className="dot" />
              <span className="label">{activeProject?.title ?? roomTitle}</span>
              <span className="chev">▾</span>
            </button>
            {pickerOpen && (
              <ul className="project-picker-menu" role="listbox">
                {projects.map((r) => (
                  <li key={r.project_id}>
                    <button
                      type="button"
                      className={`project-picker-item ${r.project_id === activeProjectID ? "on" : ""}`}
                      onClick={() => { onPickProject(r.project_id); setPickerOpen(false); }}
                      role="option"
                      aria-selected={r.project_id === activeProjectID}
                    >
                      <span className="who">
                        <span className="title">{r.title}</span>
                        <span className="meta">{PROJECT_TYPE_MAP[r.type] ?? r.type} · {r.song_count} song{r.song_count === 1 ? "" : "s"}</span>
                      </span>
                      {r.open_note_count > 0 && (
                        <span className="cue">{r.open_note_count} open</span>
                      )}
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}
      </div>
      <Wordmark size="sm" title={roomTitle} />
      <div className="top-right">
        {error && <span className="error-pill">{error}</span>}
        <button className="avatar-button" title="Account" aria-label="Theo Battaglia — account">
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
  project,
  projects = [],
  activeProjectID,
  onSelectProject,
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
  project: ProjectPayload | null;
  projects?: Awaited<ReturnType<typeof api.projectsSummary>>;
  activeProjectID?: string;
  onSelectProject?: (id: string) => void;
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

      {projects.length > 0 && onSelectProject && (
        <>
          <div className="side-rule" />
          <div className="side-label">Rooms</div>
          <div className="side-list">
            {projects.map((r) => (
              <button
                key={r.project_id}
                className={`side-list-item ${mode === "project" && activeProjectID === r.project_id ? "selected" : ""}`}
                onClick={() => onSelectProject(r.project_id)}
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
                <span className="side-meta">Saved query</span>
              </button>
            ))}
          </div>
        </>
      )}

      {mode === "project" && project && project.songs.length > 0 && (
        <>
          <div className="side-rule" />
          <div className="side-label">In this project</div>
          <div className="song-rail">
            {project.songs.map((song) => {
              const versions = versionsForSong(project.versions, song.song_id);
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
  onOpenProject,
  onOpenPlaylist,
  onToggleSongPin,
  onTogglePlaylistPin,
  onToggleProjectPin,
  pinnedSongIDs,
  pinnedPlaylistIDs,
  pinnedProjectIDs,
}: {
  onOpenSong: (id: string) => void;
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
  const [pins, setPins] = useState<MyPinsPayload | null>(null);
  const [recentItems, setRecentItems] = useState<RecentItem[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    Promise.all([
      api.getMyPins().catch((): MyPinsPayload => ({ songs: [], playlists: [], projects: [] })),
      api.recent("wsp-amf-private", 20).catch((): RecentItem[] => []),
    ]).then(([p, r]) => {
      setPins(p);
      setRecentItems(r);
    }).finally(() => setIsLoading(false));
  }, []);

  const totalPinned = pins ? pins.songs.length + pins.playlists.length + pins.projects.length : 0;

  const galleryItems = useMemo<GalleryItem[]>(() => {
    if (!pins) return [];
    return [
      ...pins.songs.map((s) => ({
        id: `song-${s.song_id}`,
        title: s.title,
        subtitle: s.artist_display_name,
        coverGradient: coverGradient(s.song_id),
        onClick: () => onOpenSong(s.song_id),
        aspect: 1.4,
      })),
      ...pins.playlists.map((p) => ({
        id: `playlist-${p.playlist_id}`,
        title: p.title,
        subtitle: `${p.item_count} ${p.item_count === 1 ? "song" : "songs"}`,
        coverGradient: coverGradient(p.cover_seed),
        onClick: () => onOpenPlaylist(p.playlist_id),
        aspect: 1.0,
      })),
      ...pins.projects.map((p) => ({
        id: `project-${p.project_id}`,
        title: p.title,
        subtitle: PROJECT_TYPE_MAP[p.project_type] ?? p.project_type,
        coverGradient: coverGradient(p.project_id),
        onClick: () => onOpenProject(p.project_id),
        aspect: 1.6,
      })),
    ];
  }, [pins, onOpenSong, onOpenPlaylist, onOpenProject]);

  return (
    <div className="home-canvas">
      <header className="lib-hero">
        <span className="lib-kicker">HOME</span>
        <h1 className="lib-headline">Workspace</h1>
        <HomeGallery items={galleryItems} />
      </header>

      {/* PINNED section */}
      <section className="home-section">
        <h2 className="home-section-head">Pinned</h2>
        {isLoading ? (
          <LibEmptyState label="Loading" hint="Checking what you've pinned…" />
        ) : totalPinned === 0 ? (
          <LibEmptyState
            label="Nothing pinned yet"
            hint="Pin a song, playlist, or project to keep it within reach."
          />
        ) : (
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
                          {STATUS_MAP[s.status] ?? s.status}
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
                            <span className="lib-meta">{PROJECT_TYPE_MAP[pr.project_type] ?? pr.project_type} · {pr.song_count} {pr.song_count === 1 ? "song" : "songs"}</span>
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
        )}
      </section>

      {/* RECENT section */}
      <section className="home-section">
        <h2 className="home-section-head">Recent</h2>
        {isLoading ? (
          <LibEmptyState label="Loading" hint="Fetching recent activity…" />
        ) : recentItems.length === 0 ? (
          <LibEmptyState label="Nothing recent" hint="Open a song, playlist, or project and it will appear here." />
        ) : (
          <div className="lib-grid">
            {recentItems.slice(0, 12).map((item) => (
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
                    {STATUS_MAP[item.status] ?? item.status}
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
        )}
      </section>

      <footer className="lib-footer-metrics">
        {totalPinned} Pinned · {recentItems.length} Recent
      </footer>
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

  useEffect(() => { void api.workspaceLibrary().then(setLibrary); }, []);

  function matchesSmart(item: Awaited<ReturnType<typeof api.workspaceLibrary>>[number]): boolean {
    if (!smartView) return true;
    const f = smartView.filter;
    if (typeof f.status === "string" && item.song.status !== f.status) return false;
    if (typeof f.release_readiness === "string" && item.song.release_readiness_status !== f.release_readiness) return false;
    // For now, "missing": ["instrumental", "stems"] is interpreted as
    // "show me songs whose release_readiness_status is not 'ready'" since
    // we don't have a deliverables computation here in the client.
    // Sufficient signal for the demo of the SavedView surfacing.
    if (Array.isArray(f.missing) && item.song.release_readiness_status === "ready") return false;
    return true;
  }

  const lowerSearch = search.trim().toLowerCase();
  const filtered = library
    .filter(matchesSmart)
    .filter((item) => {
      if (filter === "approved") return item.song.status === "approved";
      if (filter === "in-review") return item.song.status === "in_review" || item.song.status === "revision_requested";
      if (filter === "ready") return item.song.release_readiness_status === "ready";
      return true;
    })
    .filter((item) => {
      if (!lowerSearch) return true;
      const hay = `${item.song.title} ${item.song.artist_display_name} ${item.project?.title ?? ""}`.toLowerCase();
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
          <Metric label={smartView ? "Match" : "Songs"} value={filtered.length} />
          <Metric label="Approved" value={library.filter((i) => i.song.status === "approved").length} />
          <Metric label="Rooms" value={new Set(library.map((i) => i.project?.project_id).filter(Boolean)).size} />
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
              className={`library-filter ${filter === id ? "on" : ""}`}
              onClick={() => setFilter(id)}
              aria-pressed={filter === id}
            >
              {label}
            </button>
          ))}
        </div>
      </div>

      <div className="library-grid">
        {filtered.length === 0 ? (
          <div className="library-empty">Nothing matches.</div>
        ) : (
          filtered.map(({ song, project, current_version }) => (
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
                    {project && <> · <span className="library-project">{project.title}</span></>}
                    {current_version && <> · {current_version.version_label}</>}
                  </span>
                </div>
              </button>
              <div className="library-row-meta">
                <span className="library-catalog">{catalogIdFor(song.song_id)}</span>
                <span className={`status-pill ${song.status === "approved" ? "saved" : ""}`}>
                  {STATUS_MAP[song.status] ?? song.status}
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

function PlaylistView({
  playlistID,
  onOpenSong,
  onRefreshPlaylists,
}: {
  playlistID: string;
  onOpenSong: (songID: string) => void;
  onRefreshPlaylists: () => void;
}) {
  const [data, setData] = useState<Awaited<ReturnType<typeof api.playlist>> | null>(null);
  const [removing, setRemoving] = useState<string | null>(null);
  const [shareToken, setShareToken] = useState<string | null>(null);
  const [sharing, setSharing] = useState(false);
  const [draggingID, setDraggingID] = useState<string | null>(null);

  useEffect(() => {
    void api.playlist(playlistID).then(setData);
    setShareToken(null);
  }, [playlistID]);

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
    return <div className="view-stack"><p className="muted">Loading playlist…</p></div>;
  }

  const totalDuration = data.items.reduce((sum, it) => sum + (it.asset?.duration_ms ?? 0), 0);
  const cover = coverGradient(data.playlist.cover_seed);

  const shareUrl = shareToken ? `${window.location.origin}/shared/${shareToken}` : null;

  return (
    <div className="view-stack">
      <div className="playlist-hero">
        <div className="playlist-cover" style={{ backgroundImage: cover }} aria-hidden="true" />
        <div className="playlist-info">
          <p className="eyebrow">PLAYLIST</p>
          <h1>{data.playlist.title}</h1>
          {data.playlist.description && <p className="playlist-desc">{data.playlist.description}</p>}
          <div className="playlist-meta">
            <span>{data.items.length} {data.items.length === 1 ? "song" : "songs"}</span>
            <span>{formatTimestamp(totalDuration)}</span>
          </div>
          <div className="playlist-actions">
            <button
              className="accent-button"
              onClick={() => void sharePlaylist()}
              disabled={sharing || data.items.length === 0}
            >
              <Link2 size={15} />
              {sharing ? "Minting link…" : shareToken ? "Share again" : "Share as one link"}
            </button>
            {shareUrl && (
              <div className="playlist-share-cue">
                <code>{shareUrl}</code>
                <button
                  className="text-button"
                  onClick={() => void navigator.clipboard.writeText(shareUrl)}
                >
                  Copy
                </button>
              </div>
            )}
          </div>
        </div>
      </div>
      <ol className="playlist-list">
        {data.items.length === 0 ? (
          <li className="playlist-empty">Nothing here yet. Add songs from Library.</li>
        ) : (
          data.items.map(({ item, song, current_version, asset }) => (
            <li
              key={item.playlist_item_id}
              draggable
              className={draggingID === item.playlist_item_id ? "dragging" : ""}
              onDragStart={(e) => {
                setDraggingID(item.playlist_item_id);
                e.dataTransfer.effectAllowed = "move";
              }}
              onDragOver={(e) => { e.preventDefault(); e.dataTransfer.dropEffect = "move"; }}
              onDrop={(e) => { e.preventDefault(); void reorderTo(item.playlist_item_id); }}
              onDragEnd={() => setDraggingID(null)}
            >
              <span className="playlist-handle" aria-hidden="true" title="Drag to reorder">⋮⋮</span>
              <span className="playlist-index">{String(item.position).padStart(2, "0")}</span>
              <button
                className="playlist-song"
                onClick={() => song && onOpenSong(song.song_id)}
              >
                {song ? (
                  <>
                    <div className="cover-art" aria-hidden="true" style={{ backgroundImage: coverGradient(song.song_id) }} />
                    <div className="who">
                      <span className="title">{song.title}</span>
                      <span className="meta">
                        {song.artist_display_name}
                        {current_version && <> · {current_version.version_label}</>}
                      </span>
                    </div>
                  </>
                ) : (
                  <span className="muted">Song removed</span>
                )}
              </button>
              <span className="playlist-duration">{formatTimestamp(asset?.duration_ms ?? 0)}</span>
              <button
                className="icon-button"
                title="Remove from playlist"
                onClick={() => void remove(item.playlist_item_id)}
                disabled={removing === item.playlist_item_id}
              >
                <X size={14} />
              </button>
            </li>
          ))
        )}
      </ol>
    </div>
  );
}

function ProjectView({ payload, onOpenSong }: { payload: ProjectPayload; onOpenSong: (songID: string) => void }) {
  return (
    <div className="view-stack">
      <div className="section-head">
        <div>
          <p className="eyebrow">ROOM</p>
          <h1>{payload.project.title}</h1>
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

function SongWorkspace({
  payload,
  onRefresh,
  playlists = [],
  onRefreshPlaylists,
}: {
  payload: SongPayload;
  onRefresh: () => void;
  playlists?: Awaited<ReturnType<typeof api.playlists>>;
  onRefreshPlaylists?: () => void;
}) {
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
  const catalogId = catalogIdFor(payload.song.song_id);
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

type RoutedLink = { songID: string; memberName: string; token: string };

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
  const [routingSong, setRoutingSong] = useState<Awaited<ReturnType<typeof api.inbox>>[number] | null>(null);
  const [routedLinks, setRoutedLinks] = useState<RoutedLink[]>([]);
  const [members, setMembers] = useState<Awaited<ReturnType<typeof api.workspaceMembers>>>([]);

  useEffect(() => {
    void api.workspaceMembers().then(setMembers).catch(() => setMembers([]));
  }, []);

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
                  <span className="row-subtitle">Shared by {item.shared_by} · {item.project.title}</span>
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
            <li className="route-empty">No workspace members loaded.</li>
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

function LinkManager({ project, song, onRefresh }: { project: ProjectPayload; song: Song; onRefresh: () => void }) {
  const [latestToken, setLatestToken] = useState<string | null>(null);
  const [analytics, setAnalytics] = useState<Awaited<ReturnType<typeof api.projectAnalytics>>>([]);
  const links = [...project.links, ...projectPayloadSongLinks(project, song.song_id)];

  useEffect(() => {
    void api.projectAnalytics(project.project.project_id).then(setAnalytics).catch(() => setAnalytics([]));
  }, [project.project.project_id]);

  async function createProjectLink() {
    const result = await api.createLink({
      workspace_id: project.project.workspace_id,
      target_type: "project",
      target_id: project.project.project_id,
      link_name: "Latest project playback",
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
        <button className="accent-button" onClick={createProjectLink}>
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
              <LinkActivity events={analytics.filter((e) => e.link_id === link.link_id)} versions={project.versions} songs={project.songs} />
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

/** Derive a stable hue (0–360) from a string id so every song has a distinct face.
 *  Defensive against undefined / null callers — a stray bad id should not
 *  blank-screen the whole app. */
function hashHue(id: string | undefined | null): number {
  if (!id) return 0;
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) >>> 0;
  return h % 360;
}

/** Derive a stable 4-digit catalog number from a song id. FNV-1a 64-bit,
 *  bit-for-bit matching iOS's `PMWSong.catalogNumber` so the same song
 *  reads as the same catalog number on both surfaces. Uses BigInt to
 *  avoid JS's 53-bit precision limit. */
function catalogNumber(id: string): string {
  let hash = 0xcbf29ce484222325n; // FNV-1a 64-bit offset basis
  const prime = 0x100000001b3n; // FNV-1a 64-bit prime
  const mask = 0xffffffffffffffffn; // 64-bit unsigned wrap
  const bytes = new TextEncoder().encode(id);
  for (const byte of bytes) {
    hash = ((hash ^ BigInt(byte)) * prime) & mask;
  }
  const n = Number(hash % 9000n) + 1000;
  return String(n);
}

function catalogIdFor(songId: string): string {
  return `WL · ${catalogNumber(songId)}`;
}

/** Build a sleeve-mode gradient string keyed off the song id. */
function coverGradient(id: string | undefined | null): string {
  const hue = hashHue(id);
  const angle = 130 + (hashHue((id ?? "") + "a") % 40);
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

function projectPayloadSongLinks(project: ProjectPayload, songID: string): ShareLink[] {
  return project.links.filter((link) => link.target_type === "song" && link.target_id === songID);
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
                <p className="eyebrow">PLAYLIST · QUEUED FOR YOU</p>
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

// =====================================================================
//  HomeGallery — AMF-style asymmetric cover-flow grid
//  Ported from coverflow_amf/.../index.js layout algorithm
// =====================================================================

export type GalleryItem = {
  id: string;
  title: string;
  subtitle?: string;
  coverGradient: string;
  aspect?: number;
  onClick?: () => void;
};

type TileLayout = {
  id: string;
  title: string;
  subtitle?: string;
  coverGradient: string;
  onClick?: () => void;
  width: number;
  height: number;
  left: number;
  top: number;
};

/** Deterministic pseudo-random — matches AMF index.js exactly. */
function seededRand(seed: number, min: number, max: number): number {
  const x = Math.sin(seed * 9973) * 43758.5453;
  const t = x - Math.floor(x);
  return min + t * (max - min);
}

function computeGalleryLayout(items: GalleryItem[]): { tiles: TileLayout[]; canvasW: number; canvasH: number } {
  if (items.length === 0) return { tiles: [], canvasW: 0, canvasH: 0 };

  const isMobile = window.innerWidth <= 768;

  const sW = window.innerWidth / 1440;
  const sH = window.innerHeight / 900;
  const s = Math.min(sW, sH);
  const scaleMin = isMobile ? 0.8 : 0.6;
  const scale = Math.max(scaleMin, Math.min(1.25, s));

  const baseHeight = isMobile ? 280 : 420;
  const tileHeightPx = baseHeight * scale;

  // Row patterns: lengths only matter, matching AMF
  const rowPatterns = isMobile
    ? [[3], [2], [3]]
    : [[3], [2], [4]];

  const startXBase = 80 * scale;
  let rowY = 0;
  let rowIndex = 0;
  let i = 0;
  let maxRight = 0;

  const tiles: TileLayout[] = [];

  while (i < items.length) {
    const patternRow = rowPatterns[rowIndex % rowPatterns.length];
    const count = patternRow[0];
    let cursorX = startXBase + (rowIndex % 2 === 1 ? 140 * scale : 0);

    for (let k = 0; k < count && i < items.length; k++, i++) {
      const item = items[i];
      const aspect = Math.max(0.3, Math.min(3.0, item.aspect ?? 1.5));
      const heightPx = tileHeightPx;
      const widthPx = heightPx * aspect;
      const jitterY = seededRand(i, -12, 12) * scale;
      const gapX = (120 * scale) + seededRand(i * 3, 20 * scale, 100 * scale);

      tiles.push({
        id: item.id,
        title: item.title,
        subtitle: item.subtitle,
        coverGradient: item.coverGradient,
        onClick: item.onClick,
        width: widthPx,
        height: heightPx,
        left: cursorX,
        top: rowY + jitterY,
      });

      cursorX += widthPx + gapX;
      maxRight = Math.max(maxRight, cursorX);
    }

    rowIndex++;
    const gapY = 80 * scale + seededRand(rowIndex, 8 * scale, 40 * scale);
    rowY += tileHeightPx + gapY;
  }

  return {
    tiles,
    canvasW: Math.ceil(maxRight + startXBase),
    canvasH: Math.ceil(rowY + startXBase),
  };
}

const HomeGallery = memo(function HomeGallery({ items }: { items: GalleryItem[] }) {
  const [layout, setLayout] = useState<{ tiles: TileLayout[]; canvasW: number; canvasH: number }>({
    tiles: [],
    canvasW: 0,
    canvasH: 0,
  });

  // Sentinel ref so we only recompute when items actually change identity
  const itemsRef = useRef(items);
  useLayoutEffect(() => {
    itemsRef.current = items;
    setLayout(computeGalleryLayout(items));
  }, [items]);

  if (items.length === 0) return null;

  return (
    <div
      className="amfg-wrap"
      style={{ height: Math.min(layout.canvasH, window.innerHeight * 0.6) || undefined }}
      aria-label="Pinned items gallery"
    >
      <div
        className="amfg-canvas"
        style={{ width: layout.canvasW, height: layout.canvasH }}
      >
        {layout.tiles.map((tile) => (
          <button
            key={tile.id}
            className="amfg-item"
            style={{
              width: tile.width,
              height: tile.height,
              left: tile.left,
              top: tile.top,
            }}
            onClick={tile.onClick}
            aria-label={tile.subtitle ? `${tile.title} — ${tile.subtitle}` : tile.title}
          >
            <div
              className="amfg-img"
              style={{ backgroundImage: tile.coverGradient }}
              aria-hidden="true"
            />
            <div className="amfg-meta">
              <p className="amfg-title">{tile.title.toUpperCase()}</p>
              {tile.subtitle && <p className="amfg-sub">{tile.subtitle}</p>}
            </div>
          </button>
        ))}
      </div>
    </div>
  );
});

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

