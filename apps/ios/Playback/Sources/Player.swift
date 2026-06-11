import SwiftUI
import Observation
import AVFoundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/// Real audio transport backed by AVAudioPlayer over imported and bundled files.
/// Falls back to a virtual timer for any track without an available file, so the
/// UI (wheel/scrubber/marker) behaves identically either way.
@Observable
final class Player {
    var queue: [Track]
    var index: Int
    var isPlaying: Bool = false
    var positionMs: Int = 0
    var started: Bool = false
    /// True when a real source (remote stream / imported file) failed or
    /// stalled — the UI surfaces this instead of pretending to play.
    var audioUnavailable: Bool = false

    @ObservationIgnored private var audio: AVAudioPlayer?
    @ObservationIgnored private var remoteAudio: AVPlayer?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var stallStartedAt: Date?
    @ObservationIgnored private let stallGraceSeconds: TimeInterval = 3

    init(queue: [Track], index: Int = 0) {
        self.queue = queue
        self.index = index
        configureSession()
        setupRemoteCommands()
    }

    var track: Track { queue[index] }

    /// Real duration when audio is loaded, otherwise the track's declared length.
    var durationMs: Int {
        if let a = audio, a.duration > 0 { return Int(a.duration * 1000) }
        if let item = remoteAudio?.currentItem {
            let seconds = item.duration.seconds
            if seconds.isFinite && seconds > 0 { return Int(seconds * 1000) }
        }
        return max(1, track.durationMs)
    }

    var progress: Double {
        min(1, max(0, Double(positionMs) / Double(durationMs)))
    }

    func replaceQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let currentID = track.id
        queue = tracks
        index = queue.firstIndex(where: { $0.id == currentID }) ?? min(index, queue.count - 1)
        updateNowPlaying()
    }

    func open(_ id: String) {
        if let i = queue.firstIndex(where: { $0.id == id }) { index = i }
        positionMs = 0
        started = true
        load()
        play()
    }

    func toggle() {
        started = true
        isPlaying ? pause() : play()
    }

    func play() {
        if audio == nil && remoteAudio == nil { load() }
        // Retry a stream that previously failed instead of replaying a dead item.
        if remoteAudio?.currentItem?.status == .failed { load() }
        stallStartedAt = nil
        audio?.play()
        remoteAudio?.play()
        isPlaying = true
        startTicker()
        updateNowPlaying()
    }

    func pause() {
        audio?.pause()
        remoteAudio?.pause()
        isPlaying = false
        stopTicker()
        updateNowPlaying()
    }

    func next() {
        index = (index + 1) % queue.count
        positionMs = 0
        load()
        if isPlaying { play() } else { updateNowPlaying() }
    }

    func prev() {
        if positionMs > 3000 { seek(to: 0); return }
        index = (index - 1 + queue.count) % queue.count
        positionMs = 0
        load()
        if isPlaying { play() } else { updateNowPlaying() }
    }

    func seek(to fraction: Double) {
        let f = min(1, max(0, fraction))
        positionMs = Int(f * Double(durationMs))
        audio?.currentTime = f * (audio?.duration ?? 0)
        if remoteAudio?.currentItem != nil {
            let target = CMTime(seconds: Double(positionMs) / 1000, preferredTimescale: 600)
            remoteAudio?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        updateNowPlaying()
    }

    // MARK: internals

    private func load() {
        audio = nil
        remoteAudio = nil
        itemStatusObservation = nil
        timeControlObservation = nil
        stallStartedAt = nil
        audioUnavailable = false
        if let path = track.importedAudioPath, let url = importedAudioURL(path) {
            audio = try? AVAudioPlayer(contentsOf: url)
            audio?.prepareToPlay()
            return
        }
        if let remote = track.remoteAudioURL, let url = remoteAudioURL(remote) {
            let item = AVPlayerItem(url: url)
            remoteAudio = AVPlayer(playerItem: item)
            observeRemote(item)
            return
        }
        guard let file = track.audio else { return }
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return }
        audio = try? AVAudioPlayer(contentsOf: url)
        audio?.prepareToPlay()
    }

    private func importedAudioURL(_ path: String) -> URL? {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(path)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Watch the stream's health: hard failures flip `audioUnavailable`
    /// immediately; buffering longer than the grace period counts as a stall.
    private func observeRemote(_ item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { self?.markAudioUnavailable() }
        }
        timeControlObservation = remoteAudio?.observe(\.timeControlStatus) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.stallStartedAt = nil
                    self.audioUnavailable = false
                case .waitingToPlayAtSpecifiedRate:
                    if self.stallStartedAt == nil { self.stallStartedAt = Date() }
                default:
                    break
                }
            }
        }
    }

    /// Stop pretending: surface the failure, un-latch the transport, pause.
    private func markAudioUnavailable() {
        guard !audioUnavailable else { return }
        audioUnavailable = true
        stallStartedAt = nil
        pause()
    }

    private func remoteAudioURL(_ value: String) -> URL? {
        if value.hasPrefix("/seed-audio/") {
            // Seed/demo audio is published by the web app's static site, not
            // the API — resolving it against the API base 404s and stalls
            // every demo track.
            return URL(string: Config.appURL + value)
        }
        if value.hasPrefix("/") {
            return URL(string: value, relativeTo: Config.apiBaseURL)?.absoluteURL
        }
        return URL(string: value)
    }

    private func configureSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: lock screen / control center

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.prev(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: e.positionTime / max(1, self.audio?.duration ?? Double(self.durationMs) / 1000))
            return .success
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.label,
            MPMediaItemPropertyPlaybackDuration: Double(durationMs) / 1000.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMs) / 1000.0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let art = artwork(for: track) { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func artwork(for t: Track) -> MPMediaItemArtwork? {
        #if canImport(UIKit)
        let size = CGSize(width: 512, height: 512)
        if let image = TrackArtworkLoader.uiImage(for: t) {
            return MPMediaItemArtwork(boundsSize: size) { _ in image }
        }
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(t.mesh[0]).cgColor, UIColor(t.mesh[4]).cgColor, UIColor(t.mesh[8]).cgColor]
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors as CFArray, locations: [0, 0.5, 1]) else { return }
            ctx.cgContext.drawLinearGradient(grad, start: .zero,
                                             end: CGPoint(x: size.width, y: size.height), options: [])
        }
        return MPMediaItemArtwork(boundsSize: size) { _ in img }
        #else
        return nil
        #endif
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let a = self.audio {
                self.positionMs = Int(a.currentTime * 1000)
                if !a.isPlaying && self.isPlaying {
                    // reached the end
                    if self.positionMs >= self.durationMs - 200 { self.next() } else { self.pause() }
                }
            } else if let player = self.remoteAudio {
                let seconds = player.currentTime().seconds
                if seconds.isFinite { self.positionMs = Int(seconds * 1000) }
                if player.rate == 0, self.isPlaying, self.positionMs >= self.durationMs - 250 {
                    self.next()
                } else if self.isPlaying, player.timeControlStatus != .playing {
                    // stream isn't actually moving — give it a grace period, then stop pretending
                    if self.stallStartedAt == nil { self.stallStartedAt = Date() }
                    if let start = self.stallStartedAt, Date().timeIntervalSince(start) > self.stallGraceSeconds {
                        self.markAudioUnavailable()
                    }
                } else {
                    self.stallStartedAt = nil
                }
            } else if self.track.remoteAudioURL != nil || self.track.importedAudioPath != nil {
                // a real source failed to load — never tick virtually for it
                self.markAudioUnavailable()
            } else {
                // virtual ticker is for bundled sample/demo tracks only
                self.positionMs += 50
                if self.positionMs >= self.durationMs { self.next() }
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
