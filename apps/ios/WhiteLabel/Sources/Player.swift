import SwiftUI
import Observation

/// Virtual transport for the v1 prototype — advances position on a timer so the
/// wheel and scrubber animate. AVPlayer + the real API come next; the surface
/// (toggle / next / prev / seek / position) stays the same when that lands.
@Observable
final class Player {
    var queue: [Track]
    var index: Int
    var isPlaying: Bool = false
    var positionMs: Int = 0

    @ObservationIgnored private var timer: Timer?

    init(queue: [Track], index: Int = 0) {
        self.queue = queue
        self.index = index
    }

    var track: Track { queue[index] }
    var progress: Double {
        guard track.durationMs > 0 else { return 0 }
        return min(1, max(0, Double(positionMs) / Double(track.durationMs)))
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.positionMs += 50
            if self.positionMs >= self.track.durationMs { self.next() }
        }
    }

    func pause() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func next() {
        index = (index + 1) % queue.count
        positionMs = 0
        if isPlaying { play() }
    }

    func prev() {
        if positionMs > 3000 { positionMs = 0; return } // restart if past intro
        index = (index - 1 + queue.count) % queue.count
        positionMs = 0
        if isPlaying { play() }
    }

    /// Seek to a 0…1 fraction of the track.
    func seek(to fraction: Double) {
        positionMs = Int(min(1, max(0, fraction)) * Double(track.durationMs))
    }
}
