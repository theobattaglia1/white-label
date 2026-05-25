import AVFoundation
import Combine
import Foundation

/// Real AVPlayer-backed audio. Resolves each PMWAsset's `assetURLPath`
/// against `PMWConfig.apiBaseURL`. Assets without a URL fall back to a
/// virtual mode (waveform/scrub keep working, just no sound).
@MainActor
final class PMWAudioEngine: ObservableObject {
    @Published private(set) var song: PMWSong?
    @Published private(set) var version: PMWVersion?
    @Published private(set) var asset: PMWAsset?
    @Published private(set) var isPlaying = false
    @Published var positionMS = 0
    @Published var loudnessMatched = false

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init() {
        configureSession()
        installTimeObserver()
        installEndObserver()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func play(song nextSong: PMWSong, version nextVersion: PMWVersion, asset nextAsset: PMWAsset) {
        let sameAsset = self.asset?.id == nextAsset.id
        self.song = nextSong
        self.version = nextVersion
        self.asset = nextAsset

        if !sameAsset {
            positionMS = 0
            if let path = nextAsset.assetURLPath,
               let url = URL(string: path, relativeTo: PMWConfig.apiBaseURL) {
                player.replaceCurrentItem(with: AVPlayerItem(url: url.absoluteURL))
            } else {
                player.replaceCurrentItem(with: nil)
            }
        }

        if player.currentItem != nil {
            player.play()
            isPlaying = true
        } else {
            // virtual playback: no audio file, but UI states still tick
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func toggle() {
        if isPlaying { pause() } else if player.currentItem != nil {
            player.play()
            isPlaying = true
        } else {
            isPlaying.toggle()
        }
    }

    func seek(to milliseconds: Int) {
        let clamped = max(0, milliseconds)
        positionMS = clamped
        if player.currentItem != nil {
            let target = CMTime(seconds: Double(clamped) / 1000, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func gainOffset(for asset: PMWAsset?) -> Double {
        guard let asset else { return 0 }
        return -14 - asset.loudnessLUFS
    }

    // MARK: - private

    private func configureSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.allowAirPlay])
        try? session.setActive(true)
        #endif
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                if self.player.timeControlStatus == .playing {
                    self.positionMS = Int(time.seconds * 1000)
                    self.isPlaying = true
                } else if self.player.currentItem != nil {
                    self.isPlaying = false
                }
            }
        }
    }

    private func installEndObserver() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
            }
        }
    }
}
