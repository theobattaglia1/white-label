import AVFoundation
import Combine
import Foundation
import MediaPlayer

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
    // Swift 6: deinit is nonisolated even on @MainActor types. These
    // observers are touched only at init/deinit, and both AVPlayer's
    // removeTimeObserver and NotificationCenter.removeObserver are
    // thread-safe, so marking the storage nonisolated(unsafe) is fine.
    private nonisolated(unsafe) var timeObserver: Any?
    private nonisolated(unsafe) var endObserver: NSObjectProtocol?

    init() {
        configureSession()
        installTimeObserver()
        installEndObserver()
        registerRemoteCommands()
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
        updateNowPlayingMetadata()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingPlaybackState()
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
                self?.updateNowPlayingPlaybackState()
            }
        }
    }

    // MARK: - Now Playing + remote commands ----------------------------

    private func registerRemoteCommands() {
        #if os(iOS)
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.player.play()
            self.isPlaying = true
            self.updateNowPlayingPlaybackState()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.player.pause()
            self.isPlaying = false
            self.updateNowPlayingPlaybackState()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.isPlaying { self.player.pause(); self.isPlaying = false }
            else { self.player.play(); self.isPlaying = true }
            self.updateNowPlayingPlaybackState()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            let ms = Int(positionEvent.positionTime * 1000)
            self.seek(to: ms)
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        #endif
    }

    private func updateNowPlayingMetadata() {
        #if os(iOS)
        guard let song, let version, let asset else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artistName,
            MPMediaItemPropertyAlbumTitle: "\(song.catalogId) · \(version.label)",
            MPMediaItemPropertyPlaybackDuration: Double(asset.durationMS) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMS) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let key = song.songKey as String?, !key.isEmpty {
            info[MPMediaItemPropertyComments] = "\(song.bpm) BPM · \(key)"
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    private func updateNowPlayingPlaybackState() {
        #if os(iOS)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(positionMS) / 1000
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }
}
