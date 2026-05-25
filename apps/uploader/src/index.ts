#!/usr/bin/env node
import chokidar from "chokidar";
import { createHash } from "node:crypto";
import { stat, readFile } from "node:fs/promises";
import path from "node:path";

const apiURL = process.env.PMW_API_URL ?? "http://localhost:4317";
const watchDir = process.env.PMW_WATCH_DIR ?? process.argv[2] ?? process.cwd();
const songID = process.env.PMW_SONG_ID ?? process.argv[3] ?? "song-midnight";
const workspaceID = process.env.PMW_WORKSPACE_ID ?? "wsp-amf-private";
const userID = process.env.PMW_USER_ID ?? "usr-alex";
const audioExtensions = new Set([".wav", ".aiff", ".aif", ".flac", ".mp3", ".m4a"]);
const seen = new Set<string>();

async function json<T>(route: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${apiURL}${route}`, {
    ...init,
    headers: {
      "content-type": "application/json",
      "x-user-id": userID,
      ...(init?.headers ?? {}),
    },
  });
  const payload = await response.json();
  if (!response.ok || payload.error) throw new Error(payload.error ?? "Request failed");
  return payload.data as T;
}

async function checksum(filePath: string): Promise<string> {
  const buffer = await readFile(filePath);
  return createHash("sha256").update(buffer).digest("hex");
}

async function uploadFile(filePath: string) {
  const ext = path.extname(filePath).toLowerCase();
  if (!audioExtensions.has(ext) || seen.has(filePath)) return;
  seen.add(filePath);

  const file = await stat(filePath);
  const filename = path.basename(filePath);
  const digest = await checksum(filePath);
  console.log(`Preparing ${filename}`);

  const upload = await json<{ upload_id: string }>("/uploads", {
    method: "POST",
    body: JSON.stringify({
      workspace_id: workspaceID,
      filename,
      size_bytes: file.size,
      checksum_sha256: digest,
    }),
  });

  await json(`/uploads/${upload.upload_id}`, {
    method: "PATCH",
    headers: { "upload-chunk-bytes": String(file.size), "Tus-Resumable": "1.0.0" },
    body: JSON.stringify({ chunk: "local-demo" }),
  });

  await json(`/uploads/${upload.upload_id}/finalize`, {
    method: "POST",
    body: JSON.stringify({}),
  });

  const version = await json(`/songs/${songID}/versions`, {
    method: "POST",
    body: JSON.stringify({
      filename,
      type: filename.toLowerCase().includes("master") ? "master" : "mix",
    }),
  });

  console.log(`Uploaded ${filename} as current version for ${(version as { song?: { title?: string } }).song?.title ?? songID}`);
}

console.log(`Private Music Workspace uploader watching ${watchDir}`);
console.log(`Target song: ${songID}`);

chokidar
  .watch(watchDir, { ignoreInitial: true, awaitWriteFinish: { stabilityThreshold: 1500, pollInterval: 250 } })
  .on("add", (filePath) => {
    uploadFile(filePath).catch((error) => {
      seen.delete(filePath);
      console.error(`Upload failed for ${filePath}: ${error instanceof Error ? error.message : String(error)}`);
    });
  });

