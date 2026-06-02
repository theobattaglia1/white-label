import Foundation

enum PMWSampleData {
    static let users = [
        PMWUser(id: "usr-theo",  displayName: "Theo Battaglia", role: "Owner"),
        PMWUser(id: "usr-alex",  displayName: "Alex Rivera",    role: "Engineer"),
        PMWUser(id: "usr-river", displayName: "Hudson Ingram",  role: "Artist"),
        PMWUser(id: "usr-maya",  displayName: "Maya Chen",      role: "Manager"),
        PMWUser(id: "usr-dana",  displayName: "Dana Kim",       role: "A&R")
    ]

    static let project = PMWProject(
        id: "room-secret-album",
        title: "Hudson Ingram LP · Approval run",
        detail: "Private review project — four songs on the approval path before label submission.",
        versionPolicy: "full history",
        downloadPolicy: "none"
    )

    static let assets = [
        // The First Night — Hudson Ingram x PomPom (v1 pitch from Aug 2023, v2 working)
        asset("asset-midnight-v1", "the-first-night_v1_pitch_pompom.mp3", 191000, -10.8, seed: 1,
              url: "seed-audio/the-first-night-v1-pitch.mp3"),
        asset("asset-midnight-v2", "the-first-night_v2_pompom.mp3",       214000, -14.1, seed: 2,
              url: "seed-audio/the-first-night-v2.mp3"),
        asset("asset-midnight-v3", "austin-again_v4_pre-mix.mp3",         277000,  -9.2, seed: 3,
              url: "seed-audio/austin-again-v4.mp3"),

        // Lighting The Fuse — Hudson Ingram x Liz Rose
        asset("asset-neon-v1", "prom-queen_v1.2_with-strings.mp3",         241000, -16.1, seed: 4,
              url: "seed-audio/prom-queen-v1.mp3"),
        asset("asset-neon-v2", "lighting-the-fuse_v2_liz-rose-cowrite.mp3", 231000, -13.6, seed: 5,
              url: "seed-audio/lighting-the-fuse-v2.mp3"),
        asset("asset-neon-v3", "just-like-you_v2_jensen-mcrae.mp3",         256000, -11.9, seed: 6,
              url: "seed-audio/just-like-you-v2.mp3"),

        // Duel — Ruby Plume (v5)
        asset("asset-witness-v1",    "duel_v5_ruby-plume.m4a",       182000, -15.4, seed: 7,
              url: "seed-audio/duel-v5.m4a"),
        asset("asset-witness-v2",    "duel_v5_master-print.m4a",     182000, -12.8, seed: 8,
              url: "seed-audio/duel-v5.m4a"),
        asset("asset-witness-clean", "best-of-me_demo-v2_117bpm.mp3", 499000, -12.7, seed: 9,
              url: "seed-audio/best-of-me-v2.mp3"),

        // Best Of Me — Daniel Price · Olmo · Mills (v2 demo, 117 bpm)
        asset("asset-lowlight-v1",   "best-of-me_demo-v2.mp3",       499000, -15.9, seed: 10,
              url: "seed-audio/best-of-me-v2.mp3"),
        asset("asset-lowlight-v2",   "best-of-me_demo-v2_alt.mp3",   499000, -13.2, seed: 11,
              url: "seed-audio/best-of-me-v2.mp3"),
        asset("asset-lowlight-inst", "best-of-me_inst-v1.mp3",       499000, -13.4, seed: 12,
              stems: true, url: "seed-audio/best-of-me-v2.mp3")
    ]

    static let songs = [
        PMWSong(id: "song-midnight",
                projectID: project.id,
                title: "The First Night",
                artistName: "Hudson Ingram",
                projectName: "Hudson Ingram LP",
                status: "Revision",
                currentVersionID: "ver-midnight-v2",
                approvedVersionID: nil,
                bpm: 92, songKey: "F minor",
                explicit: true),

        PMWSong(id: "song-neon",
                projectID: project.id,
                title: "Lighting The Fuse",
                artistName: "Hudson Ingram",
                projectName: "Hudson Ingram LP",
                status: "Review",
                currentVersionID: "ver-neon-v3",
                approvedVersionID: nil,
                bpm: 118, songKey: "A major",
                explicit: false),

        PMWSong(id: "song-witness",
                projectID: project.id,
                title: "Duel",
                artistName: "Ruby Plume",
                projectName: "Ruby Plume single",
                status: "Approved",
                currentVersionID: "ver-witness-clean",
                approvedVersionID: "ver-witness-clean",
                bpm: 76, songKey: "D minor",
                explicit: true),

        PMWSong(id: "song-lowlight",
                projectID: project.id,
                title: "Best Of Me",
                artistName: "Daniel Price · Olmo · Mills",
                projectName: "Daniel Price · EP",
                status: "Progress",
                currentVersionID: "ver-lowlight-inst",
                approvedVersionID: nil,
                bpm: 117, songKey: "C# minor",
                explicit: false)
    ]

    static let versions = [
        version("ver-midnight-v1", "song-midnight", 1, "Pitch v1",  .demo,  false, false, "asset-midnight-v1"),
        version("ver-midnight-v2", "song-midnight", 2, "Mix v2",    .mix,   true,  false, "asset-midnight-v2", parent: "ver-midnight-v1"),
        version("ver-midnight-v3", "song-midnight", 3, "Master v3", .master, false, false, "asset-midnight-v3", parent: "ver-midnight-v2"),

        version("ver-neon-v1", "song-neon", 1, "Demo v1",    .demo,  false, false, "asset-neon-v1"),
        version("ver-neon-v2", "song-neon", 2, "Co-write v2", .rough, false, false, "asset-neon-v2", parent: "ver-neon-v1"),
        version("ver-neon-v3", "song-neon", 3, "Mix v3",      .mix,   true,  false, "asset-neon-v3", parent: "ver-neon-v2"),

        version("ver-witness-v1",    "song-witness", 1, "Demo v1",  .demo,  false, false, "asset-witness-v1"),
        version("ver-witness-v2",    "song-witness", 2, "Mix v2",   .mix,   false, false, "asset-witness-v2", parent: "ver-witness-v1"),
        version("ver-witness-clean", "song-witness", 3, "Master v3", .master, true,  true,  "asset-witness-clean", parent: "ver-witness-v2"),

        version("ver-lowlight-v1",   "song-lowlight", 1, "Day-1 v1",   .demo,  false, false, "asset-lowlight-v1"),
        version("ver-lowlight-v2",   "song-lowlight", 2, "Demo v2",    .demo,  false, false, "asset-lowlight-v2", parent: "ver-lowlight-v1"),
        version("ver-lowlight-inst", "song-lowlight", 3, "Stem-derived v3", .instrumental, true, false, "asset-lowlight-inst", parent: "ver-lowlight-v2")
    ]

    static let notes = [
        PMWNote(id: "note-vocal-delay",  songID: "song-midnight", anchorVersionID: "ver-midnight-v1",
                author: "Hudson Ingram",
                body: "Vocal delay too loud here @Alex.",
                scope: .song, timestampStartMS: 72000, timestampEndMS: nil,
                assignedTo: "Alex Rivera", priority: "high", status: .open),
        PMWNote(id: "note-kick-fixed",   songID: "song-midnight", anchorVersionID: "ver-midnight-v1",
                author: "Maya Chen",
                body: "Kick pokes too hard entering the second hook.",
                scope: .song, timestampStartMS: 132000, timestampEndMS: nil,
                assignedTo: "Alex Rivera", priority: "normal", status: .resolved,
                resolvedBy: "Alex Rivera", resolvedAt: Date(), resolvedOnVersionID: "ver-midnight-v2"),
        PMWNote(id: "note-neon-private", songID: "song-neon", anchorVersionID: "ver-neon-v3",
                author: "Dana Kim",
                body: "Private: strong hook, needs shorter intro for pitch.",
                scope: .version, timestampStartMS: 34000, timestampEndMS: nil,
                assignedTo: nil, priority: "normal", status: .open)
    ]

    static func asset(_ id: String, _ filename: String, _ duration: Int, _ lufs: Double,
                      seed: Int, stems: Bool = false, url: String? = nil) -> PMWAsset {
        PMWAsset(
            id: id,
            filename: filename,
            durationMS: duration,
            loudnessLUFS: lufs,
            waveform: (0..<72).map { index in
                let value = sin(Double(index + seed) * 0.42) * 0.36
                          + sin(Double(index + seed) * 0.11) * 0.24
                          + 0.48
                return max(0.08, min(0.98, value))
            },
            hasStems: stems,
            assetURLPath: url
        )
    }

    static func version(_ id: String, _ songID: String, _ number: Int, _ label: String,
                        _ type: PMWVersionType,
                        _ current: Bool, _ approved: Bool,
                        _ assetID: String, parent: String? = nil) -> PMWVersion {
        PMWVersion(id: id, songID: songID, number: number, label: label, type: type,
                   parentVersionID: parent, isCurrent: current, isApproved: approved,
                   assetID: assetID, createdAt: Date())
    }
}
