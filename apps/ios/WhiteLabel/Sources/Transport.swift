import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Old-school hardware transport: a row of square buttons, each its own color.
/// PLAY carries the Ndot dot-matrix label (the desktop home button); pause,
/// skip-back and skip-forward sit beside it.
struct TransportBar: View {
    var isPlaying: Bool
    var onBack: () -> Void
    var onPlay: () -> Void
    var onPause: () -> Void
    var onForward: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            SquareButton(fill: WL.panel, fg: WL.cream, bordered: true, action: onBack) {
                Image(systemName: "backward.end.fill").font(.system(size: 17, weight: .medium))
            }
            SquareButton(fill: WL.cream, fg: WL.black, action: onPlay) {
                Text("PLAY").font(WL.dot(15)).tracking(1.5)
            }
            .opacity(isPlaying ? 0.6 : 1)
            SquareButton(fill: WL.redline, fg: WL.cream, action: onPause) {
                Image(systemName: "pause.fill").font(.system(size: 17, weight: .medium))
            }
            .opacity(isPlaying ? 1 : 0.6)
            SquareButton(fill: WL.cobalt, fg: WL.cream, action: onForward) {
                Image(systemName: "forward.end.fill").font(.system(size: 17, weight: .medium))
            }
        }
    }
}

private struct SquareButton<Label: View>: View {
    var fill: Color
    var fg: Color
    var bordered: Bool = false
    var action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button {
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            #endif
            action()
        } label: {
            label
                .foregroundStyle(fg)
                .frame(maxWidth: .infinity)
                .frame(height: 68)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous).fill(fill)
                )
                .overlay {
                    if bordered {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(WL.cream.opacity(0.14), lineWidth: 1)
                    }
                }
                .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
        }
        .buttonStyle(PressStyle())
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
