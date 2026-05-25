import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import type { FileAsset, Song, Version } from "@pmw/shared";

type PlayerState = {
  song?: Song;
  version?: Version;
  asset?: FileAsset;
  isPlaying: boolean;
  positionMs: number;
  loudnessMatched: boolean;
  play: (song: Song, version: Version, asset: FileAsset) => void;
  pause: () => void;
  toggle: () => void;
  seek: (positionMs: number) => void;
  setLoudnessMatched: (enabled: boolean) => void;
};

const PlayerContext = createContext<PlayerState | undefined>(undefined);

/**
 * Real HTML5 audio playback. Seed assets carry an optional `playback_url`
 * pointing at /seed-audio/foo.mp3 (Vite serves /public from root).
 * Assets without a URL fall back to silent virtual playback so the rest
 * of the UI (waveform, scrub, timestamped notes) still works.
 */
export function PlayerProvider({ children }: { children: ReactNode }) {
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const rafRef = useRef<number | null>(null);

  const [song, setSong] = useState<Song | undefined>();
  const [version, setVersion] = useState<Version | undefined>();
  const [asset, setAsset] = useState<FileAsset | undefined>();
  const [isPlaying, setIsPlaying] = useState(false);
  const [positionMs, setPositionMs] = useState(0);
  const [loudnessMatched, setLoudnessMatched] = useState(false);

  // Lazy-create a global <audio> element on mount
  useEffect(() => {
    if (typeof window === "undefined") return;
    if (!audioRef.current) {
      const el = document.createElement("audio");
      el.preload = "auto";
      document.body.appendChild(el);
      audioRef.current = el;
    }
  }, []);

  // Track position via rAF
  useEffect(() => {
    const tick = () => {
      const el = audioRef.current;
      if (el && !el.paused) {
        setPositionMs(el.currentTime * 1000);
      }
      rafRef.current = requestAnimationFrame(tick);
    };
    rafRef.current = requestAnimationFrame(tick);
    return () => {
      if (rafRef.current != null) cancelAnimationFrame(rafRef.current);
    };
  }, []);

  // Keep isPlaying in sync with native audio events
  useEffect(() => {
    const el = audioRef.current;
    if (!el) return;
    const onPlay = () => setIsPlaying(true);
    const onPause = () => setIsPlaying(false);
    const onEnded = () => setIsPlaying(false);
    el.addEventListener("play", onPlay);
    el.addEventListener("pause", onPause);
    el.addEventListener("ended", onEnded);
    return () => {
      el.removeEventListener("play", onPlay);
      el.removeEventListener("pause", onPause);
      el.removeEventListener("ended", onEnded);
    };
  });

  const play = useCallback(
    (nextSong: Song, nextVersion: Version, nextAsset: FileAsset) => {
      setSong(nextSong);
      setVersion(nextVersion);
      setAsset(nextAsset);
      const el = audioRef.current;
      if (!el) return;
      const sameAsset = el.dataset.assetId === nextAsset.asset_id;
      if (!sameAsset) {
        const url = nextAsset.playback_url;
        if (url) {
          el.src = url;
          el.dataset.assetId = nextAsset.asset_id;
          el.load();
        } else {
          el.removeAttribute("src");
          el.dataset.assetId = "";
        }
        setPositionMs(0);
      }
      if (nextAsset.playback_url) {
        el.play().catch((err) => {
          // eslint-disable-next-line no-console
          console.warn("Audio play() blocked or failed:", err);
          setIsPlaying(false);
        });
      } else {
        setIsPlaying(true); // virtual playback
      }
    },
    []
  );

  const pause = useCallback(() => {
    const el = audioRef.current;
    if (el && !el.paused) el.pause();
    else setIsPlaying(false);
  }, []);

  const toggle = useCallback(() => {
    const el = audioRef.current;
    if (!el) {
      setIsPlaying((v) => !v);
      return;
    }
    if (el.paused) {
      if (el.src) {
        el.play().catch(() => setIsPlaying(false));
      } else {
        setIsPlaying((v) => !v);
      }
    } else {
      el.pause();
    }
  }, []);

  const seek = useCallback((nextPositionMs: number) => {
    const next = Math.max(0, nextPositionMs);
    const el = audioRef.current;
    if (el && el.duration && Number.isFinite(el.duration)) {
      el.currentTime = Math.min(next / 1000, el.duration);
    }
    setPositionMs(next);
  }, []);

  const value = useMemo<PlayerState>(
    () => ({
      song,
      version,
      asset,
      isPlaying,
      positionMs,
      loudnessMatched,
      play,
      pause,
      toggle,
      seek,
      setLoudnessMatched,
    }),
    [song, version, asset, isPlaying, positionMs, loudnessMatched, play, pause, toggle, seek]
  );

  return <PlayerContext.Provider value={value}>{children}</PlayerContext.Provider>;
}

export function usePlayer() {
  const context = useContext(PlayerContext);
  if (!context) throw new Error("usePlayer must be used inside PlayerProvider");
  return context;
}
