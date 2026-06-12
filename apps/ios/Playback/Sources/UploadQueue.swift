import Foundation
import Network
import SwiftUI

/// One pending upload — the only way an imported song enters the library.
/// The job IS the optimistic row: visible instantly, clearly in the
/// uploading register, never a normal-looking device-local track. It is
/// persisted (survives app kills), retried automatically with backoff, and
/// on success the row swaps to the real cloud track via
/// `adoptUploadedTrack` — seamless, no duplicate.
struct UploadJob: Identifiable, Codable, Hashable {
    enum State: String, Codable {
        case queued
        case uploading
        case failed
        case done
    }

    let id: String
    /// Identity of the optimistic row until the cloud id replaces it.
    let localTrackID: String
    var title: String
    var artist: String
    var project: String
    var versionLabel: String
    var durationMs: Int
    /// Documents-relative audio path — already retained by the import.
    var audioPath: String
    var sourceFileName: String?
    var artworkPath: String?
    var meshHexes: [UInt]
    var state: State
    var attempts: Int
    var lastErrorMessage: String?
    /// Seconds until the next automatic retry — a static display value set
    /// when an attempt fails (no ticking timers in screen bodies).
    var retryDelaySeconds: Int?
    let createdAt: Date

    /// The optimistic pending row — playable from the local file; share /
    /// link actions stay gated by `isLocalOnlyTrack` until adoption.
    var track: Track {
        Track(
            id: localTrackID,
            importedAudioPath: audioPath,
            importedArtworkPath: artworkPath,
            title: title,
            artist: artist,
            label: project,
            versionLabel: versionLabel,
            catalog: String(format: "PB ·%04d", abs(localTrackID.hashValue % 9000) + 1000),
            durationMs: max(15_000, durationMs),
            credits: [
                Credit(key: "Key · Tempo", value: "Unknown"),
                Credit(key: "Source", value: sourceFileName ?? "Imported audio"),
            ],
            mesh: meshHexes.map { Color(hex: $0) }
        )
    }

    /// Row state label (MonoLabel uppercases it). Honest, quiet.
    var stateLabel: String {
        switch state {
        case .queued: return "Upload queued"
        case .uploading: return "Uploading"
        case .failed:
            if let retryDelaySeconds {
                return "Upload failed — retrying in \(Self.shortDelay(retryDelaySeconds))"
            }
            return "Upload failed — will retry"
        case .done: return "Uploaded"
        }
    }

    static func shortDelay(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}

/// Fires when connectivity returns — one of the queue's automatic retry
/// triggers (the others: app launch, app foreground, manual retry).
final class NetworkRegainObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private var wasSatisfied = true

    init(onRegain: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            if satisfied, !self.wasSatisfied { onRegain() }
            self.wasSatisfied = satisfied
        }
        monitor.start(queue: DispatchQueue(label: "playback.upload.network"))
    }

    deinit { monitor.cancel() }
}

// MARK: - Upload queue engine (server-authoritative library)

extension WorkspaceStore {
    /// Pending rows synthesized from jobs that aren't backed by a legacy
    /// customTrack (migrated legacy tracks keep their StoredTrack row —
    /// same id — until adoption, so nothing duplicates).
    var pendingUploadTracks: [Track] {
        uploadJobs
            .filter { job in !customTracks.contains { $0.id == job.localTrackID } }
            .map(\.track)
    }

    func uploadJob(forTrack id: String) -> UploadJob? {
        uploadJobs.first { $0.localTrackID == id }
    }

    func isPendingUpload(_ id: String) -> Bool {
        uploadJob(forTrack: id) != nil
    }

    /// Import = enqueue, never fork. The job is persisted before this
    /// returns, so a kill right after import still uploads on next launch.
    @MainActor
    @discardableResult
    func enqueueUpload(
        title: String,
        artist: String,
        project: String,
        versionLabel: String,
        durationMs: Int,
        audioPath: String,
        sourceFileName: String?,
        artworkPath: String?,
        artworkPalette: [UInt]?,
        localTrackID: String? = nil
    ) -> Track {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVersion = versionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let rowID = localTrackID ?? "pending-\(UUID().uuidString.lowercased().prefix(8))"
        let job = UploadJob(
            id: "upl-\(UUID().uuidString.lowercased().prefix(8))",
            localTrackID: rowID,
            title: trimmedTitle.isEmpty ? "Untitled Song" : trimmedTitle,
            artist: trimmedArtist.isEmpty ? "Unknown Artist" : trimmedArtist,
            project: trimmedProject.isEmpty ? "Unfiled" : trimmedProject,
            versionLabel: trimmedVersion.isEmpty ? "Demo v1" : trimmedVersion,
            durationMs: max(15_000, durationMs),
            audioPath: audioPath,
            sourceFileName: sourceFileName,
            artworkPath: artworkPath,
            meshHexes: Self.normalizedPalette(artworkPalette) ?? MeshPalette.hexes(for: rowID),
            state: .queued,
            attempts: 0,
            lastErrorMessage: nil,
            retryDelaySeconds: nil,
            createdAt: Date()
        )
        uploadJobs.append(job)
        persistUploadJobs()
        kickUploadQueue()
        return job.track
    }

    /// Launch-time start: reset any job the last process died holding,
    /// migrate legacy local tracks into the queue, watch the network, and
    /// resume work.
    @MainActor
    func startUploadQueue() {
        guard Config.useRemoteAPI else { return }
        var changed = false
        for i in uploadJobs.indices where uploadJobs[i].state == .uploading {
            uploadJobs[i].state = .queued   // app died mid-transfer
            changed = true
        }
        if changed { persistUploadJobs() }
        migrateLegacyLocalTracks()
        if networkObserver == nil {
            networkObserver = NetworkRegainObserver { [weak self] in
                Task { @MainActor [weak self] in self?.kickUploadQueue() }
            }
        }
        kickUploadQueue()
    }

    /// Migration / self-heal: every legacy device-local track whose source
    /// file is still retained gets quietly enqueued. Tracks without a file
    /// keep the honest "saved on this device only — re-import to share"
    /// treatment — user data is never deleted.
    private func migrateLegacyLocalTracks() {
        var changed = false
        for stored in customTracks {
            guard uploadJob(forTrack: stored.id) == nil,
                  let path = stored.importedAudioPath,
                  importedFileURL(path) != nil
            else { continue }
            uploadJobs.append(UploadJob(
                id: "upl-\(UUID().uuidString.lowercased().prefix(8))",
                localTrackID: stored.id,
                title: stored.title,
                artist: stored.artist,
                project: stored.label,
                versionLabel: stored.versionLabel,
                durationMs: stored.durationMs,
                audioPath: path,
                sourceFileName: stored.sourceFileName,
                artworkPath: stored.importedArtworkPath,
                meshHexes: stored.meshHexes,
                state: .queued,
                attempts: 0,
                lastErrorMessage: nil,
                retryDelaySeconds: nil,
                createdAt: Date()
            ))
            changed = true
        }
        if changed { persistUploadJobs() }
    }

    /// Wakes the FIFO worker. Cancels a backoff sleep so foreground /
    /// network-regain / manual retries attempt immediately; never cancels
    /// an in-flight transfer.
    @MainActor
    func kickUploadQueue() {
        guard Config.useRemoteAPI, !uploadJobs.isEmpty else { return }
        if isUploadTransferInFlight { return }
        uploadWorker?.cancel()
        uploadWorker = Task { @MainActor [weak self] in
            await self?.runUploadWorker()
        }
    }

    /// Manual "retry now" on a failed row — skips the remaining backoff.
    @MainActor
    func retryUploadNow(_ trackID: String) {
        if let i = uploadJobs.firstIndex(where: { $0.localTrackID == trackID }),
           uploadJobs[i].state == .failed {
            uploadJobs[i].state = .queued
            persistUploadJobs()
        }
        kickUploadQueue()
    }

    /// Removes a job (e.g. deleting a pending row). Caller owns file cleanup.
    @discardableResult
    func removeUploadJob(forTrack trackID: String) -> UploadJob? {
        guard let i = uploadJobs.firstIndex(where: { $0.localTrackID == trackID }) else { return nil }
        let job = uploadJobs.remove(at: i)
        uploadProgressByJob[job.id] = nil
        persistUploadJobs()
        return job
    }

    func persistUploadJobs() {
        if let data = try? JSONEncoder().encode(uploadJobs) {
            UserDefaults.standard.set(data, forKey: uploadJobsKey)
        }
    }

    func loadUploadJobs() {
        guard let data = UserDefaults.standard.data(forKey: uploadJobsKey),
              let jobs = try? JSONDecoder().decode([UploadJob].self, from: data)
        else { return }
        uploadJobs = jobs
    }

    /// Exponential backoff: 5s → 30s → 2m, then hourly. Computed per
    /// failure; foreground / network-regain / manual retry skip the wait.
    static func uploadBackoffDelay(forAttempt attempt: Int) -> Int {
        switch attempt {
        case ..<1: return 5
        case 1: return 30
        case 2: return 120
        default: return 3600
        }
    }

    /// Sequential FIFO worker — one upload at a time, oldest job first.
    /// A failed head job sleeps its backoff, then retries; success adopts
    /// the cloud identity and the loop moves to the next job.
    @MainActor
    private func runUploadWorker() async {
        while !Task.isCancelled {
            guard Config.useRemoteAPI,
                  let job = uploadJobs.sorted(by: { $0.createdAt < $1.createdAt }).first
            else { return }

            guard let audioURL = importedFileURL(job.audioPath) else {
                // Source file vanished — upload is impossible. Drop the job;
                // a legacy StoredTrack backing it falls back to the honest
                // "re-import to share" treatment.
                removeUploadJob(forTrack: job.localTrackID)
                continue
            }

            setJobState(job.id, .uploading)
            uploadProgressByJob[job.id] = 0
            syncState = .syncing
            syncMessage = "Uploading song"
            isUploadTransferInFlight = true
            do {
                let jobID = job.id
                let result = try await ServiceClient.shared.uploadNewSong(
                    audioURL: audioURL,
                    title: job.title,
                    artist: job.artist,
                    project: job.project,
                    versionLabel: job.versionLabel,
                    durationMs: job.durationMs,
                    artworkPath: job.artworkPath,
                    progress: { [weak self] fraction in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            let previous = self.uploadProgressByJob[jobID] ?? 0
                            if fraction - previous >= 0.01 || fraction >= 1 {
                                self.uploadProgressByJob[jobID] = fraction
                            }
                        }
                    }
                )
                isUploadTransferInFlight = false
                let stillQueued = removeUploadJob(forTrack: job.localTrackID) != nil
                if stillQueued {
                    adoptUploadedTrack(localID: job.localTrackID, cloudID: result.songExternalId)
                    await refreshFromService()
                    syncState = .synced
                    syncMessage = "Uploaded"
                    lastSavedAt = Date()
                } else {
                    // The row was deleted mid-upload — honor the delete.
                    try? await ServiceClient.shared.deleteSong(result.songExternalId)
                }
            } catch {
                isUploadTransferInFlight = false
                let delay = Self.uploadBackoffDelay(forAttempt: job.attempts)
                markJobFailed(job.id, message: error.localizedDescription, retryDelay: delay)
                syncState = .offline
                syncMessage = "Upload failed — retrying automatically"
                try? await Task.sleep(for: .seconds(Double(delay)))
                if Task.isCancelled { return }
            }
        }
    }

    private func setJobState(_ jobID: String, _ state: UploadJob.State) {
        guard let i = uploadJobs.firstIndex(where: { $0.id == jobID }) else { return }
        uploadJobs[i].state = state
        persistUploadJobs()
    }

    private func markJobFailed(_ jobID: String, message: String, retryDelay: Int) {
        guard let i = uploadJobs.firstIndex(where: { $0.id == jobID }) else { return }
        uploadJobs[i].state = .failed
        uploadJobs[i].attempts += 1
        uploadJobs[i].lastErrorMessage = message
        uploadJobs[i].retryDelaySeconds = retryDelay
        persistUploadJobs()
    }
}

// MARK: - Pending row badge

/// Trailing badge for a pending row: quiet mono state + thin progress
/// hairline. No ticking timers — progress arrives via the upload task
/// delegate; the retry countdown is a static value set at failure time.
/// Tapping a failed badge retries immediately.
struct UploadStateBadge: View {
    var job: UploadJob
    var progress: Double
    var onRetry: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            MonoLabel(label, color: color, size: 8, tracking: 1.4)
            if job.state == .uploading {
                ZStack(alignment: .leading) {
                    Rectangle().fill(PB.cream.opacity(0.14))
                    Rectangle().fill(PB.cobalt)
                        .frame(width: 56 * min(1, max(0, progress)))
                }
                .frame(width: 56, height: 1)
                .animation(reduceMotion ? nil : .linear(duration: 0.2), value: progress)
                .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if job.state == .failed { onRetry?() }
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(job.state == .failed ? .isButton : [])
    }

    private var label: String {
        if job.state == .uploading {
            let pct = Int((min(1, max(0, progress)) * 100).rounded())
            return "Uploading · \(pct)%"
        }
        return job.stateLabel
    }

    private var color: Color {
        switch job.state {
        case .failed: return PB.redline
        case .uploading: return PB.cream.opacity(0.7)
        default: return PB.cream.opacity(0.55)
        }
    }
}
