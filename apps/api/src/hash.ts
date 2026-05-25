import { createHash, randomBytes } from "node:crypto";

export function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

export function makeShareToken(): string {
  return randomBytes(24).toString("base64url");
}

