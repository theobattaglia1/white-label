import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Old-school hardware transport: a row of small square buttons, all in the
/// Ndot dot-matrix face with pale, color-differentiated fills.
struct TransportBar: View {
    var isPlaying: Bool
    var onBack: () -> Void
    var onPlay: () -> Void
    var onPause: () -> Void
    var onForward: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            SquareButton(fill: WL.paleCobalt, action: onBack) {
                Text("<<").font(WL.dot(19)).tracking(0.5)
            }
            SquareButton(fill: WL.cream, action: onPlay) {
                Text("PLAY").font(WL.dot(12)).tracking(1).minimumScaleFactor(0.6).lineLimit(1)
            }
            .opacity(isPlaying ? 0.55 : 1)
            SquareButton(fill: WL.paleCoral, action: onPause) {
                Text("II").font(WL.dot(19)).tracking(2.5)
            }
            .opacity(isPlaying ? 1 : 0.55)
            SquareButton(fill: WL.paleGreen, action: onForward) {
                Text(">>").font(WL.dot(19)).tracking(0.5)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SquareButton<Label: View>: View {
    var fill: Color
    var side: CGFloat = 58
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
                .foregroundStyle(WL.black)
                .frame(width: side, height: side)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill)
                )
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        }
        .buttonStyle(PressStyle())
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
