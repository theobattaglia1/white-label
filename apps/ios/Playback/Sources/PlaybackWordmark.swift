import SwiftUI

/// PLAYBACK — the animated wordmark.
///
/// The P is the playhead: it loops continuously so the brand mark is stable
/// across app surfaces instead of changing posture with transport state.
struct PlaybackWordmark: View {
    var capSize: CGFloat = 22
    var fontSize: CGFloat = 24
    var capFill: Color = PB.cream
    var letterColor: Color = PB.black
    var wordColor: Color = PB.cream
    var isPlaying: Bool = false

    @AppStorage("wl.reduceMotion") private var reduceMotion = false
    private var travel: CGFloat { capSize * 0.38 }
    private let period: Double = 4.4

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let x: CGFloat = reduceMotion ? travel : slidingOffset(timeline.date)
            HStack(spacing: 0) {
                ZStack {
                    Circle().fill(capFill)
                    Text("P")
                        .font(.custom("HelveticaNeue-Bold", fixedSize: capSize * 0.52))
                        .foregroundStyle(letterColor)
                }
                .frame(width: capSize, height: capSize)
                .offset(x: x)
                .zIndex(1)
                .accessibilityHidden(true)

                Text("LAYBACK")
                    .font(.custom("HelveticaNeue-Bold", fixedSize: fontSize))
                    .tracking(-1)
                    .foregroundStyle(wordColor)
                    .padding(.leading, capSize * 0.16)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(isPlaying ? "Playback — playing" : "Playback — stopped")
    }

    private func slidingOffset(_ date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        let phase = t.truncatingRemainder(dividingBy: period) / period
        return travel * CGFloat(1 + cos(2 * .pi * phase)) / 2
    }
}

#Preview("Playing") {
    ZStack {
        PB.black.ignoresSafeArea()
        PlaybackWordmark(capSize: 30, fontSize: 34, isPlaying: true)
    }
}

#Preview("Stopped") {
    ZStack {
        PB.black.ignoresSafeArea()
        PlaybackWordmark(capSize: 30, fontSize: 34, isPlaying: false)
    }
}
