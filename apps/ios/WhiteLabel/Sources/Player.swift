import SwiftUI
import Observation
import AVFoundation

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
        if let a = audio {
            a.play()
            isPlaying = true
            startTicker()
        } else {
            // virtual fallback
            isPlaying = true
            startTicker()
        }
    }

    func pause() {
        audio?.pause()
        isPlaying = false
        stopTicker()
    }

    func next() {
        index = (index + 1) % queue.count
        positionMs = 0
        load()
        if isPlaying { play() }
    }

    func prev() {
        if positionMs > 3000 { seek(to: 0); return }
        index = (index - 1 + queue.count) % queue.count
        positionMs = 0
        load()
        if isPlaying { play() }
    }

    func seek(to fraction: Double) {
        let f = min(1, max(0, fraction))
        positionMs = Int(f * Double(durationMs))
        audio?.currentTime = f * (audio?.duration ?? 0)
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
