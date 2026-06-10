import { useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import { CheckCircle2, Clock3, MapPin, Pause, Play, Radio, RotateCcw, Send, Sparkles, Users } from "lucide-react";
import type { DecisionResponseValue } from "@pmw/shared";
import { api, assetForVersion, type FirstListenPayload, type ListeningRoomPayload } from "./api";
import { coverGradient } from "./utils";

const firstListenChoices: Array<[DecisionResponseValue, string]> = [
  ["love", "Love"],
  ["hold", "Hold"],
  ["pass", "Pass"],
  ["need_context", "Need Context"],
];

const roomChoices: Array<[DecisionResponseValue, string]> = [
  ["love", "Love"],
  ["hold", "Hold"],
  ["pass", "Pass"],
  ["need_context", "Need Context"],
  ["needs_revision", "Needs Revision"],
  ["would_forward", "Would Forward"],
];

export function FirstListenPage({ token }: { token: string }) {
  const [payload, setPayload] = useState<FirstListenPayload | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [isPlaying, setPlaying] = useState(false);
  const [completed, setCompleted] = useState(false);
  const [decisionSent, setDecisionSent] = useState(false);
  const [replayRequested, setReplayRequested] = useState(false);
  const [currentMs, setCurrentMs] = useState(0);
  const audioRef = useRef<HTMLAudioElement>(null);

  useEffect(() => {
    api.firstListen(token).then(setPayload).catch((err) => setError(err instanceof Error ? err.message : "Unable to open First Listen"));
  }, [token]);

  const asset = payload?.asset;
  const durationMs = asset?.duration_ms || 0;
  const canPlay = !!payload?.can_play && !!asset?.playback_url;
  const heardRatio = durationMs > 0 ? Math.min(1, currentMs / durationMs) : 0;

  async function record(event_type: "started" | "paused" | "resumed" | "completed" | "pulse" | "timestamp_marker", extra: Record<string, unknown> = {}) {
    try {
      const percent = durationMs > 0 ? Math.min(100, Math.round((currentMs / durationMs) * 100)) : undefined;
      const result = await api.firstListenEvent(token, {
        event_type,
        playback_position_ms: currentMs,
        percent_complete: event_type === "completed" ? 100 : percent,
        ...extra,
      });
      if (result.recipient?.access_state === "completed") setCompleted(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not record listening event");
    }
  }

  async function startPlayback() {
    if (!audioRef.current || !canPlay) return;
    setError(null);
    try {
      await audioRef.current.play();
      setPlaying(true);
      await record(payload?.recipient.started_at ? "resumed" : "started");
    } catch {
      setError("Audio is ready. Press Begin again.");
    }
  }

  async function requestReplay() {
    try {
      await api.requestFirstListenReplay(token);
      setReplayRequested(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Replay request unavailable");
    }
  }

  if (error && !payload) return <FlowError title="First Listen" error={error} />;
  if (!payload) return <FlowLoading label="Opening First Listen" />;

  return (
    <main className="event-page first-listen-page">
      <FirstListenStage
        payload={payload}
        canPlay={canPlay}
        isPlaying={isPlaying}
        completed={completed || payload.recipient.access_state === "completed" || payload.recipient.access_state === "replay_requested"}
        heardRatio={heardRatio}
        onPlay={startPlayback}
        onPause={() => {
          audioRef.current?.pause();
          setPlaying(false);
          void record("paused");
        }}
        onPulse={() => void record("pulse", { intensity: 1 })}
        onMarker={() => void record("timestamp_marker")}
      />

      <audio
        ref={audioRef}
        src={asset?.playback_url}
        preload="metadata"
        onTimeUpdate={(e) => setCurrentMs(Math.round(e.currentTarget.currentTime * 1000))}
        onPause={() => setPlaying(false)}
        onEnded={() => {
          setPlaying(false);
          setCompleted(true);
          void record("completed");
        }}
      />

      {(completed || payload.recipient.access_state === "completed" || payload.recipient.access_state === "replay_requested") && (
        <DecisionResponseForm
          title="Decision"
          choices={firstListenChoices}
          disabled={decisionSent}
          onSubmit={async (response_value, text_note) => {
            await api.firstListenDecision(token, { response_value, text_note });
            setDecisionSent(true);
          }}
        />
      )}

      {!canPlay && payload.can_request_replay && !replayRequested && payload.recipient.access_state !== "replay_requested" && (
        <button className="event-secondary" onClick={() => void requestReplay()}>
          <RotateCcw size={16} /> Request replay
        </button>
      )}
      {(replayRequested || payload.recipient.access_state === "replay_requested") && (
        <p className="event-state">Replay requested.</p>
      )}
      {error && <p className="event-error">{error}</p>}
    </main>
  );
}

export function ListeningRoomPage({ token }: { token: string }) {
  const [payload, setPayload] = useState<ListeningRoomPayload | null>(null);
  const [participantID, setParticipantID] = useState<string | null>(() => localStorage.getItem(`playback-room-${token}`));
  const [displayName, setDisplayName] = useState("");
  const [email, setEmail] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [isPlaying, setPlaying] = useState(false);
  const [completed, setCompleted] = useState(false);
  const [firstTakeSent, setFirstTakeSent] = useState(false);
  const [currentMs, setCurrentMs] = useState(0);
  const audioRef = useRef<HTMLAudioElement>(null);

  const activeVersion = payload?.versions[0];
  const activeAsset = useMemo(() => payload ? assetForVersion(payload.assets, activeVersion) : undefined, [payload, activeVersion]);

  useEffect(() => {
    let mounted = true;
    const load = () => api.recipientRoom(token).then((next) => mounted && setPayload(next)).catch((err) => mounted && setError(err instanceof Error ? err.message : "Unable to open room"));
    void load();
    const id = window.setInterval(load, 2500);
    return () => { mounted = false; window.clearInterval(id); };
  }, [token]);

  useEffect(() => {
    if (!payload || !audioRef.current) return;
    const state = payload.state;
    if (state.playback_state === "playing") {
      const serverStart = state.host_started_at_server_time ? new Date(state.host_started_at_server_time).getTime() : Date.now();
      const estimatedMs = state.host_position_ms + Math.max(0, Date.now() - serverStart);
      const estimatedSeconds = estimatedMs / 1000;
      if (Math.abs(audioRef.current.currentTime - estimatedSeconds) > 0.6) {
        audioRef.current.currentTime = estimatedSeconds;
      }
    }
    if (state.playback_state === "paused") audioRef.current.pause();
    if (state.playback_state === "ended") {
      audioRef.current.pause();
      setCompleted(true);
    }
  }, [payload?.state.updated_at]);

  async function join() {
    try {
      const result = await api.joinRoom(token, { display_name: displayName, email, participant_id: participantID ?? undefined });
      localStorage.setItem(`playback-room-${token}`, result.participant.participant_id);
      setParticipantID(result.participant.participant_id);
      setPayload(result.room);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not join room");
    }
  }

  async function enterPlayback() {
    if (!audioRef.current) return;
    try {
      await audioRef.current.play();
      setPlaying(true);
    } catch {
      setError("Audio is ready. Press Enter again.");
    }
  }

  async function roomPulse(kind: "pulse" | "timestamp_marker" | "run_it_back" = "pulse") {
    if (!participantID) return;
    await api.roomEvent(token, {
      participant_id: participantID,
      event_type: kind === "pulse" ? "pulse" : "timestamp_marker",
      reaction_type: kind,
      playback_position_ms: currentMs,
      intensity: kind === "pulse" ? 1 : undefined,
    });
  }

  if (error && !payload) return <FlowError title="Listening Room" error={error} />;
  if (!payload) return <FlowLoading label="Opening Listening Room" />;

  const joined = !!participantID && payload.participants.some((participant) => participant.participant_id === participantID);
  const live = payload.state.playback_state === "playing" || payload.room.lifecycle_state === "live";
  const roomCompleted = completed || payload.state.playback_state === "ended" || payload.room.lifecycle_state === "ended";
  const participantCount = payload.participants.filter((participant) => !!participant.joined_at).length;
  const pulseCount = payload.reactions.filter((reaction) => reaction.reaction_type === "pulse").length;

  return (
    <main className="event-page listening-room-page">
      <ListeningRoomStage
        payload={payload}
        activeVersionLabel={activeVersion?.version_label}
        joined={joined}
        live={live}
        canPlay={live && !!activeAsset?.playback_url}
        isPlaying={isPlaying}
        completed={roomCompleted}
        currentMs={currentMs}
        participantCount={participantCount}
        pulseCount={pulseCount}
        onPlay={enterPlayback}
        onPause={() => {
          audioRef.current?.pause();
          setPlaying(false);
        }}
        onPulse={() => void roomPulse("pulse")}
        onMarker={() => void roomPulse("timestamp_marker")}
      />

      {!joined && (
        <RoomLobby
          payload={payload}
          displayName={displayName}
          email={email}
          setDisplayName={setDisplayName}
          setEmail={setEmail}
          onJoin={() => void join()}
        />
      )}

      {joined && (
        <>
          <audio
            ref={audioRef}
            src={activeAsset?.playback_url}
            preload="metadata"
            onTimeUpdate={(e) => setCurrentMs(Math.round(e.currentTarget.currentTime * 1000))}
            onEnded={() => {
              setPlaying(false);
              setCompleted(true);
              if (participantID) {
                void api.roomEvent(token, {
                  participant_id: participantID,
                  event_type: "completed",
                  playback_position_ms: currentMs,
                  percent_complete: 100,
                });
              }
            }}
          />

          {roomCompleted && !firstTakeSent && (
            <DecisionResponseForm
              title="First Take"
              choices={roomChoices}
              onSubmit={async (response_value, text_note) => {
                await api.roomFirstTake(token, { participant_id: participantID ?? undefined, response_value, text_note });
                setFirstTakeSent(true);
              }}
            />
          )}

          {(firstTakeSent || payload.decisions.some((decision) => decision.participant_id === participantID)) && (
            <RoomPostListenDebrief
              onRunItBack={() => void roomPulse("run_it_back")}
              onNote={(note_text) => api.roomNote(token, { participant_id: participantID ?? undefined, playback_position_ms: currentMs, note_text })}
            />
          )}
        </>
      )}
      {error && <p className="event-error">{error}</p>}
    </main>
  );
}

function FirstListenStage({
  payload,
  canPlay,
  isPlaying,
  completed,
  heardRatio,
  onPlay,
  onPause,
  onPulse,
  onMarker,
}: {
  payload: FirstListenPayload;
  canPlay: boolean;
  isPlaying: boolean;
  completed: boolean;
  heardRatio: number;
  onPlay: () => void;
  onPause: () => void;
  onPulse: () => void;
  onMarker: () => void;
}) {
  const artist = payload.song.artist_display_name ?? payload.session.artist_name ?? "Unreleased";
  const stageStyle = { "--listen-ratio": heardRatio.toFixed(3) } as CSSProperties;
  const artStyle = {
    backgroundImage: payload.song.artwork_url ? `url(${payload.song.artwork_url})` : coverGradient(payload.song.song_id),
  };

  return (
    <section className={`event-stage first-stage ${isPlaying ? "is-playing" : ""} ${completed ? "is-complete" : ""}`} style={stageStyle}>
      <div className="first-stage__halo" aria-hidden="true" />
      <div className="event-badge event-mark" aria-label="First Listen"><Radio size={14} /><span className="sr-only">First Listen</span></div>

      <div className="first-stage__object" aria-hidden="true">
        <div className="first-stage__seal">
          <div className="first-stage__art" style={artStyle} />
          <span className="first-stage__aperture" />
        </div>
      </div>

      <div className="event-copy first-stage__copy">
        <h1>{payload.song.title}</h1>
        <p className="event-subtitle">{artist}{payload.version.version_label ? ` · ${payload.version.version_label}` : ""}</p>
      </div>

      <StageControls
        canPlay={canPlay}
        isPlaying={isPlaying}
        completed={completed}
        idleLabel="Play"
        waitingLabel="Waiting"
        iconOnly
        onPlay={onPlay}
        onPause={onPause}
        onPulse={onPulse}
        onMarker={onMarker}
      />
    </section>
  );
}

function ListeningRoomStage({
  payload,
  activeVersionLabel,
  joined,
  live,
  canPlay,
  isPlaying,
  completed,
  currentMs,
  participantCount,
  pulseCount,
  onPlay,
  onPause,
  onPulse,
  onMarker,
}: {
  payload: ListeningRoomPayload;
  activeVersionLabel?: string;
  joined: boolean;
  live: boolean;
  canPlay: boolean;
  isPlaying: boolean;
  completed: boolean;
  currentMs: number;
  participantCount: number;
  pulseCount: number;
  onPlay: () => void;
  onPause: () => void;
  onPulse: () => void;
  onMarker: () => void;
}) {
  const song = payload.songs[0];
  const artist = song?.artist_display_name ?? payload.room.artist_name ?? "Unreleased";
  const title = song?.title ?? payload.room.title;
  const displayCount = Math.max(5, Math.min(8, participantCount + 4));
  const stageStyle = {
    "--participant-count": participantCount,
    "--pulse-count": pulseCount,
    "--room-position": currentMs,
  } as CSSProperties;
  const artStyle = {
    backgroundImage: song?.artwork_url ? `url(${song.artwork_url})` : coverGradient(song?.song_id ?? payload.room.listening_room_id),
  };

  return (
    <section className={`event-stage room-stage ${joined ? "is-joined" : "is-guest"} ${live ? "is-live" : ""} ${isPlaying ? "is-playing" : ""} ${completed ? "is-complete" : ""}`} style={stageStyle}>
      <div className="event-badge event-mark" aria-label="Listening Room"><Users size={14} /><span className="sr-only">Listening Room</span></div>

      <div className="room-stage__field" aria-hidden="true">
        <div className="room-stage__orbit">
          <span className="room-stage__ring" />
          {Array.from({ length: displayCount }).map((_, index) => (
            <span
              key={index}
              className={`room-stage__node ${index < Math.max(1, participantCount) ? "is-present" : ""}`}
              style={{ "--node-angle": `${(360 / displayCount) * index}deg`, "--node-delay": `${index * 170}ms` } as CSSProperties}
            />
          ))}
        </div>
        <div className="room-stage__source">
          <div className="room-stage__art" style={artStyle} />
          <div className="room-stage__source-copy">
            <span>{completed ? "Ended" : live ? "Live" : payload.room.lifecycle_state}</span>
          </div>
        </div>
      </div>

      <div className="event-copy room-stage__copy">
        <h1>{payload.room.title}</h1>
        <p className="event-subtitle">{artist}{activeVersionLabel ? ` · ${activeVersionLabel}` : ""}</p>
      </div>

      <div className="room-energy">
        <span><Users size={14} /> {participantCount}</span>
        <span><Sparkles size={14} /> {pulseCount}</span>
      </div>

      {joined && (
        <StageControls
          canPlay={canPlay}
          isPlaying={isPlaying}
          completed={completed}
          idleLabel={live ? "Enter" : "Lobby"}
          waitingLabel={live ? "Enter" : "Lobby"}
          onPlay={onPlay}
          onPause={onPause}
          onPulse={onPulse}
          onMarker={onMarker}
        />
      )}
    </section>
  );
}

function StageControls({
  canPlay,
  isPlaying,
  completed,
  idleLabel,
  waitingLabel,
  onPlay,
  onPause,
  onPulse,
  onMarker,
  iconOnly = false,
}: {
  canPlay: boolean;
  isPlaying: boolean;
  completed: boolean;
  idleLabel: string;
  waitingLabel: string;
  onPlay: () => void;
  onPause: () => void;
  onPulse: () => void;
  onMarker: () => void;
  iconOnly?: boolean;
}) {
  const label = completed ? "Complete" : canPlay ? idleLabel : waitingLabel;
  const actionLabel = isPlaying ? "Pause" : label;
  return (
    <div className="event-controls">
      <button
        className={`event-primary ${iconOnly ? "event-primary--icon" : ""}`}
        onClick={isPlaying ? onPause : onPlay}
        disabled={completed || (!canPlay && !isPlaying)}
        aria-label={actionLabel}
      >
        {completed ? <CheckCircle2 size={18} /> : isPlaying ? <Pause size={18} /> : canPlay ? <Play size={18} /> : <Clock3 size={18} />}
        {iconOnly ? <span className="sr-only">{actionLabel}</span> : actionLabel}
      </button>
      <button className="event-circle" onClick={onPulse} disabled={!isPlaying} aria-label="Pulse"><Sparkles size={18} /></button>
      <button className="event-circle" onClick={onMarker} disabled={!isPlaying} aria-label="Mark timestamp"><MapPin size={18} /></button>
    </div>
  );
}

function DecisionResponseForm({
  title,
  choices,
  disabled = false,
  onSubmit,
}: {
  title: string;
  choices: Array<[DecisionResponseValue, string]>;
  disabled?: boolean;
  onSubmit: (value: DecisionResponseValue, note?: string) => Promise<void>;
}) {
  const [choice, setChoice] = useState<DecisionResponseValue | null>(null);
  const [note, setNote] = useState("");
  const [working, setWorking] = useState(false);
  const [sent, setSent] = useState(false);

  async function submit() {
    if (!choice) return;
    setWorking(true);
    await onSubmit(choice, note.trim() || undefined);
    setWorking(false);
    setSent(true);
  }

  return (
    <section className="decision-panel">
      <h2>{sent || disabled ? `${title} sent` : title}</h2>
      <div className="decision-grid">
        {choices.map(([value, label]) => (
          <button key={value} className={choice === value ? "selected" : ""} onClick={() => setChoice(value)} disabled={sent || disabled}>
            {label}
          </button>
        ))}
      </div>
      <textarea value={note} onChange={(e) => setNote(e.target.value)} placeholder="Optional note" disabled={sent || disabled} />
      <button className="event-primary" onClick={() => void submit()} disabled={!choice || working || sent || disabled}>
        <Send size={16} /> {working ? "Sending" : "Submit"}
      </button>
    </section>
  );
}

function RoomLobby({
  payload,
  displayName,
  email,
  setDisplayName,
  setEmail,
  onJoin,
}: {
  payload: ListeningRoomPayload;
  displayName: string;
  email: string;
  setDisplayName: (value: string) => void;
  setEmail: (value: string) => void;
  onJoin: () => void;
}) {
  return (
    <section className="room-lobby">
      <input value={displayName} onChange={(e) => setDisplayName(e.target.value)} placeholder="Name" />
      <input value={email} onChange={(e) => setEmail(e.target.value)} placeholder="Email optional" />
      <button className="event-primary" onClick={onJoin}>Join</button>
    </section>
  );
}

function RoomPostListenDebrief({ onRunItBack, onNote }: { onRunItBack: () => void; onNote: (note: string) => Promise<unknown> }) {
  const [note, setNote] = useState("");
  const [sent, setSent] = useState(false);
  return (
    <section className="room-debrief">
      <button className="event-secondary" onClick={onRunItBack}><RotateCcw size={16} /> Run it back</button>
      <div className="room-note-row">
        <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Timestamped note" />
        <button onClick={async () => { if (!note.trim()) return; await onNote(note.trim()); setNote(""); setSent(true); }}><Send size={16} /></button>
      </div>
      {sent && <p className="event-state">Note saved.</p>}
    </section>
  );
}

function FlowLoading({ label }: { label: string }) {
  return <main className="event-page"><p className="event-state">{label}</p></main>;
}

function FlowError({ title, error }: { title: string; error: string }) {
  return <main className="event-page"><section className="event-context"><div className="event-badge">{title}</div><p className="event-error">{error}</p></section></main>;
}

function formatDate(value: string) {
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }).format(new Date(value));
}
