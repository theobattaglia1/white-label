import { beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../server.js";
import { store } from "../store.js";

let app: Awaited<ReturnType<typeof buildApp>>;

beforeEach(async () => {
  if (!app) app = await buildApp();
  store.reset();
});

describe("First Listen MVP", () => {
  it("creates a protected link, records completion, captures a decision, and grants one replay", async () => {
    const created = await app.inject({
      method: "POST",
      url: "/first-listens",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        song_id: "song-midnight",
        decision_request_type: "single_candidate",
        recipient_email: "dana@example.com",
        context_note: "Single gut check.",
      }),
    });
    expect(created.statusCode).toBe(200);
    const createBody = created.json<{
      data: {
        token: string;
        session: { share_session_id: string; token_hash: string };
        recipient: { recipient_id: string };
      };
    }>().data;
    expect(createBody.session.token_hash).not.toBe(createBody.token);

    const opened = await app.inject({ method: "GET", url: `/listen/${createBody.token}` });
    expect(opened.statusCode).toBe(200);
    expect(opened.json<{ data: { can_play: boolean; song: { song_id: string } } }>().data.can_play).toBe(true);

    const started = await app.inject({
      method: "POST",
      url: `/listen/${createBody.token}/events`,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ event_type: "started", playback_position_ms: 0, percent_complete: 0 }),
    });
    expect(started.statusCode).toBe(200);

    const completed = await app.inject({
      method: "POST",
      url: `/listen/${createBody.token}/events`,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ event_type: "completed", playback_position_ms: 190000, percent_complete: 94 }),
    });
    expect(completed.statusCode).toBe(200);
    expect(completed.json<{ data: { recipient: { access_state: string } } }>().data.recipient.access_state).toBe("completed");

    const decision = await app.inject({
      method: "POST",
      url: `/listen/${createBody.token}/decision`,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ response_value: "love", text_note: "Feels like the one." }),
    });
    expect(decision.statusCode).toBe(200);
    expect(decision.json<{ data: { report: { decision_counts: Record<string, number> } } }>().data.report.decision_counts.love).toBe(1);

    const replay = await app.inject({ method: "POST", url: `/listen/${createBody.token}/replay-request` });
    expect(replay.statusCode).toBe(200);

    const grant = await app.inject({
      method: "POST",
      url: `/first-listens/${createBody.session.share_session_id}/recipients/${createBody.recipient.recipient_id}/grant-replay`,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });
    expect(grant.statusCode).toBe(200);
    const recipient = grant.json<{ data: { recipients: Array<{ access_state: string }> } }>().data.recipients[0];
    expect(recipient.access_state).toBe("replay_granted");
  });

  it("rejects expired First Listen links before playback", async () => {
    const created = await app.inject({
      method: "POST",
      url: "/first-listens",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        song_id: "song-midnight",
        expires_at: "2020-01-01T00:00:00.000Z",
      }),
    });
    const token = created.json<{ data: { token: string } }>().data.token;
    const opened = await app.inject({ method: "GET", url: `/listen/${token}` });
    expect(opened.statusCode).toBe(400);
    expect(opened.json<{ error: string }>().error).toMatch(/expired/i);
  });
});

describe("Listening Room MVP", () => {
  it("creates a room, joins a listener, syncs host state, captures pulse/First Take, and generates a report", async () => {
    const created = await app.inject({
      method: "POST",
      url: "/listening-rooms",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        song_id: "song-midnight",
        room_type: "first_listen_room",
        decision_request_type: "general_reaction",
        retention_policy: "save_to_project",
        context_note: "A&R room.",
      }),
    });
    expect(created.statusCode).toBe(200);
    const createdBody = created.json<{ data: { token: string; room: { listening_room_id: string } } }>().data;

    const lobby = await app.inject({ method: "GET", url: `/room/${createdBody.token}` });
    expect(lobby.statusCode).toBe(200);
    expect(lobby.json<{ data: { state: { playback_state: string } } }>().data.state.playback_state).toBe("lobby");

    const joined = await app.inject({
      method: "POST",
      url: `/room/${createdBody.token}/join`,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ display_name: "Dana", email: "dana@example.com" }),
    });
    expect(joined.statusCode).toBe(200);
    const participantID = joined.json<{ data: { participant: { participant_id: string } } }>().data.participant.participant_id;

    const started = await app.inject({
      method: "POST",
      url: `/listening-rooms/${createdBody.room.listening_room_id}/start`,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });
    expect(started.statusCode).toBe(200);
    expect(started.json<{ data: { state: { playback_state: string } } }>().data.state.playback_state).toBe("playing");

    const pulse = await app.inject({
      method: "POST",
      url: `/room/${createdBody.token}/events`,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ participant_id: participantID, event_type: "pulse", playback_position_ms: 42000, intensity: 3 }),
    });
    expect(pulse.statusCode).toBe(200);

    const firstTake = await app.inject({
      method: "POST",
      url: `/room/${createdBody.token}/first-take`,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ participant_id: participantID, response_value: "need_context", text_note: "Hook is strong." }),
    });
    expect(firstTake.statusCode).toBe(200);

    const report = await app.inject({
      method: "POST",
      url: `/listening-rooms/${createdBody.room.listening_room_id}/end`,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });
    expect(report.statusCode).toBe(200);
    const summary = report.json<{ data: { summary_json: { decision_counts: Record<string, number>; top_pulse_moments: unknown[] } } }>().data.summary_json;
    expect(summary.decision_counts.need_context).toBe(1);
    expect(summary.top_pulse_moments.length).toBe(1);
  });
});
