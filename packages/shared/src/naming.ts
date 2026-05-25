const versionTokens = new Set([
  "v",
  "ver",
  "version",
  "final",
  "finalfinal",
  "master",
  "mix",
  "rough",
  "demo",
  "bounce",
  "rev",
  "revision",
]);

export interface UploadCandidate {
  filename: string;
  sizeBytes?: number;
}

export interface UploadGroupingProposal {
  normalizedStem: string;
  files: UploadCandidate[];
  confidence: "high" | "medium";
  proposedSongTitle: string;
}

export function normalizeFilenameStem(filename: string): string {
  return filename
    .replace(/\.[^.]+$/, "")
    .toLowerCase()
    .replace(/[_-]+/g, " ")
    .replace(/\b(20\d{2}[.-]?\d{2}[.-]?\d{2}|\d{1,2}[.-]\d{1,2}[.-]\d{2,4})\b/g, " ")
    .split(/\s+/)
    .filter(Boolean)
    .filter((token) => !versionTokens.has(token.replace(/\d+$/, "")))
    .filter((token) => !/^v?\d+$/.test(token))
    .join(" ")
    .trim();
}

export function titleFromStem(stem: string): string {
  return stem
    .split(/\s+/)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

export function proposeUploadGroupings(files: UploadCandidate[]): UploadGroupingProposal[] {
  const buckets = new Map<string, UploadCandidate[]>();
  for (const file of files) {
    const normalizedStem = normalizeFilenameStem(file.filename);
    if (!normalizedStem) continue;
    buckets.set(normalizedStem, [...(buckets.get(normalizedStem) ?? []), file]);
  }

  return [...buckets.entries()]
    .filter(([, bucket]) => bucket.length > 1)
    .map(([normalizedStem, bucket]) => ({
      normalizedStem,
      files: bucket,
      confidence: bucket.length > 2 ? "high" : "medium",
      proposedSongTitle: titleFromStem(normalizedStem),
    }));
}

