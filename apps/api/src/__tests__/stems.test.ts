import { describe, expect, it } from "vitest";
import {
  STEM_NAMES,
  isLiveStemJobState,
  mapDemucsProgress,
  parseDemucsProgress,
  stemsZipKey,
  type StemJobState,
} from "../stems";

describe("parseDemucsProgress", () => {
  it("reads a single tqdm line", () => {
    expect(parseDemucsProgress("  5%|▌         | 3.6/70.2 [00:02<00:39,  1.70seconds/s]")).toBeCloseTo(0.05);
  });

  it("takes the LAST percentage when \\r-separated updates arrive in one chunk", () => {
    const chunk =
      " 14%|█▍        | 9.9/70.2 [00:05<00:31,  1.9seconds/s]\r" +
      " 43%|████▎     | 30.2/70.2 [00:15<00:20,  1.9seconds/s]\r" +
      " 57%|█████▋    | 40.0/70.2 [00:20<00:15,  1.9seconds/s]";
    expect(parseDemucsProgress(chunk)).toBeCloseTo(0.57);
  });

  it("handles 100% completion lines", () => {
    expect(parseDemucsProgress("100%|██████████| 70.2/70.2 [00:35<00:00,  2.0seconds/s]")).toBe(1);
  });

  it("returns null for non-progress stderr", () => {
    expect(parseDemucsProgress("Selected model is a bag of 1 models. You will see that many progress bars per track.")).toBeNull();
    expect(parseDemucsProgress("Separating track /tmp/stems-x/input.mp3")).toBeNull();
    expect(parseDemucsProgress("")).toBeNull();
  });

  it("ignores out-of-range or malformed percents", () => {
    expect(parseDemucsProgress("999%| weird")).toBeNull();
    expect(parseDemucsProgress("12% without a bar")).toBeNull();
  });
});

describe("mapDemucsProgress", () => {
  it("maps the model pass into the 0.05–0.85 window", () => {
    expect(mapDemucsProgress(0)).toBe(0.05);
    expect(mapDemucsProgress(0.5)).toBeCloseTo(0.45);
    expect(mapDemucsProgress(1)).toBeCloseTo(0.85);
  });

  it("clamps out-of-range fractions", () => {
    expect(mapDemucsProgress(-1)).toBe(0.05);
    expect(mapDemucsProgress(2)).toBeCloseTo(0.85);
  });
});

describe("stemsZipKey", () => {
  it("follows the stems/<song_external_id>/<version_id>.zip convention", () => {
    expect(stemsZipKey("song-midnight", "ver-midnight-v2")).toBe("stems/song-midnight/ver-midnight-v2.zip");
  });

  it("sanitizes path-hostile characters", () => {
    expect(stemsZipKey("song/../etc", "ver one")).toBe("stems/song_etc/ver_one.zip");
  });
});

describe("job state transitions", () => {
  it("queued/processing/uploading are live; done/failed are terminal", () => {
    const live: StemJobState[] = ["queued", "processing", "uploading"];
    const terminal: StemJobState[] = ["done", "failed"];
    for (const s of live) expect(isLiveStemJobState(s)).toBe(true);
    for (const s of terminal) expect(isLiveStemJobState(s)).toBe(false);
  });
});

describe("stem names", () => {
  it("is the htdemucs 4-stem set", () => {
    expect([...STEM_NAMES]).toEqual(["vocals", "drums", "bass", "other"]);
  });
});
