import { computeDeliverables } from "./deliverables";
import type { ActivityEvent, FileAsset, Note, Project, Song, User, Version, WorkspaceSnapshot } from "./models";

export interface AssistantAnswer {
  answer: string;
  citations: Array<{ type: "song" | "version" | "activity" | "note" | "project"; id: string; label: string }>;
}

function labelUser(users: User[], userID?: string): string {
  return users.find((user) => user.user_id === userID)?.display_name ?? "Unknown";
}

function latestListenEvents(events: ActivityEvent[], versionID: string): ActivityEvent[] {
  return events.filter((event) => event.event_type === "played_track" && event.version_id === versionID);
}

export function answerWorkspaceQuestion(snapshot: WorkspaceSnapshot, rawQuestion: string): AssistantAnswer {
  const question = rawQuestion.toLowerCase();
  const currentVersions = snapshot.songs
    .map((song) => snapshot.versions.find((version) => version.version_id === song.current_version_id))
    .filter((version): version is Version => Boolean(version));

  if (question.includes("hasn't heard") || question.includes("has not heard") || question.includes("who hasnt heard")) {
    const targetVersion =
      currentVersions.find((version) => question.includes(`v${version.version_number}`)) ?? currentVersions[0];
    const song = snapshot.songs.find((item) => item.song_id === targetVersion?.song_id);
    if (!targetVersion || !song) {
      return { answer: "I could not find a current version to check.", citations: [] };
    }
    const listeners = new Set(latestListenEvents(snapshot.activityEvents, targetVersion.version_id).map((event) => event.actor_user_id));
    const expected = snapshot.memberships.filter((membership) =>
      ["artist", "manager", "producer", "engineer", "anr"].includes(membership.role)
    );
    const missing = expected
      .filter((membership) => !listeners.has(membership.user_id))
      .map((membership) => labelUser(snapshot.users, membership.user_id));
    return {
      answer:
        missing.length > 0
          ? `${missing.join(", ")} ${missing.length === 1 ? "has" : "have"} not heard ${song.title} ${targetVersion.version_label}.`
          : `Everyone expected has heard ${song.title} ${targetVersion.version_label}.`,
      citations: [
        { type: "song", id: song.song_id, label: song.title },
        { type: "version", id: targetVersion.version_id, label: targetVersion.version_label },
      ],
    };
  }

  if (question.includes("missing") || question.includes("deliverable") || question.includes("instrumental")) {
    const rows = snapshot.songs.map((song) => ({
      song,
      status: computeDeliverables(song, snapshot.versions, snapshot.assets),
    }));
    const incomplete = rows.filter((row) => !row.status.ready);
    return {
      answer: incomplete
        .map((row) => `${row.song.title}: missing ${row.status.missing.join(", ")}`)
        .join("\n"),
      citations: incomplete.map((row) => ({ type: "song", id: row.song.song_id, label: row.song.title })),
    };
  }

  if (question.includes("changed between") || question.includes("mix v")) {
    const song = snapshot.songs[0];
    const versions = snapshot.versions.filter((version) => version.song_id === song.song_id);
    const [first, second] = versions.slice(-2);
    const assetByID = new Map(snapshot.assets.map((asset) => [asset.asset_id, asset]));
    const firstAsset = first ? assetByID.get(first.file_asset_id) : undefined;
    const secondAsset = second ? assetByID.get(second.file_asset_id) : undefined;
    const resolved = snapshot.notes.filter((note: Note) => note.resolved_on_version_id === second?.version_id);
    const lufsDelta =
      firstAsset && secondAsset ? `${(secondAsset.loudness_lufs - firstAsset.loudness_lufs).toFixed(1)} LUFS` : "unknown";
    const durationDelta =
      firstAsset && secondAsset ? `${Math.round((secondAsset.duration_ms - firstAsset.duration_ms) / 1000)} seconds` : "unknown";
    return {
      answer: `${song.title}: ${second?.version_label ?? "latest"} is ${lufsDelta} from the prior mix, duration changed by ${durationDelta}, and ${resolved.length} note was resolved on that version.`,
      citations: [
        { type: "song", id: song.song_id, label: song.title },
        ...(first ? [{ type: "version" as const, id: first.version_id, label: first.version_label }] : []),
        ...(second ? [{ type: "version" as const, id: second.version_id, label: second.version_label }] : []),
      ],
    };
  }

  if (question.includes("public") || question.includes("expiring")) {
    const activeLinks = snapshot.shareLinks.filter((link) => !link.revoked_at && link.access_mode === "public");
    return {
      answer: `${activeLinks.length} active public link${activeLinks.length === 1 ? "" : "s"} need review. ${activeLinks
        .map((link) => link.link_name ?? link.link_id)
        .join(", ")}.`,
      citations: activeLinks.map((link) => ({
        type: link.target_type === "project" ? "project" : "song",
        id: link.target_id,
        label: link.link_name ?? "Share link",
      })),
    };
  }

  const project: Project | undefined = snapshot.projects[0];
  const openNotes = snapshot.notes.filter((note) => note.status === "open");
  const assets: FileAsset[] = snapshot.assets;
  return {
    answer: `${project?.title ?? "This workspace"} has ${snapshot.songs.length} songs, ${snapshot.versions.length} versions, ${openNotes.length} open notes, and ${Math.round(
      assets.reduce((sum, asset) => sum + asset.file_size_bytes, 0) / 1_000_000
    )} MB of seeded audio assets. I can answer from records only and will not mutate anything.`,
    citations: project ? [{ type: "project", id: project.project_id, label: project.title }] : [],
  };
}

