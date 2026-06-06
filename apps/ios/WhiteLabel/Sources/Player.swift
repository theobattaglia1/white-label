import SwiftUI
import Observation
import AVFoundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/// Real audio transport backed by AVAudioPlayer over the bundled sample files.
/// Falls back to a virtual timer for any track without a bundled file, so the
/// UI (wheel/scrubber/marker) behaves identically either way.
@Observable
final class Player {
    var queue: [Track]
    var index: Int
    var isPlaying: Bool = false
    var positionMs: Int = 0
    var started: Bool = false

    @ObservationIgnored private var audio: AVAudioPlayer?
    @ObservationIgnored private var ticker: Timer?

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
        return max(1, track.durationMs)
    }

    var progress: Double {
        min(1, max(0, Double(positionMs) / Double(durationMs)))
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
        if audio == nil { load() }
        audio?.play()
        isPlaying = true
        startTicker()
        updateNowPlaying()
    }

    func pause() {
        audio?.pause()
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
        updateNowPlaying()
    }

    // MARK: internals

    private func load() {
        audio = nil
        guard let file = track.audio else { return }
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return }
        audio = try? AVAudioPlayer(contentsOf: url)
        audio?.prepareToPlay()
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
            } else {
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
