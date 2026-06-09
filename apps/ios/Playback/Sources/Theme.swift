import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Playback — v3 design tokens for iOS.
/// Warm-dark studio palette + the Teenage Engineering type system
/// (Univers TE display, Lettera Mono labels, Ndot sparingly).
enum PB {
    // Palette
    static let black   = Color(hex: 0x0C0907)
    static let panel   = Color(hex: 0x16110C)
    static let cream   = Color(hex: 0xF3ECDE)
    static let pencil  = Color(hex: 0x9B9285)
    static let faint   = Color.white.opacity(0.30)
    static let redline = Color(hex: 0xFF4A22) // needs-attention / in-review
    static let cobalt  = Color(hex: 0x4663E8) // current / structure
    static let green   = Color(hex: 0x5FD08A) // approved

    // Pale transport tints — soft hardware-button colors.
    static let paleCobalt = Color(hex: 0xBAC3EC)
    static let paleCoral  = Color(hex: 0xEDB29B)
    static let paleGreen  = Color(hex: 0xAFDBC3)

    // Type — PostScript names of the bundled faces.
    static func display(_ size: CGFloat) -> Font { .custom("UniversTE40-Light", size: size) }
    static func text(_ size: CGFloat)    -> Font { .custom("UniversTE20", size: size) }
    static func thin(_ size: CGFloat)    -> Font { .custom("UniversTE20-Thin", size: size) }
    static func mono(_ size: CGFloat)    -> Font { .custom("LetteraMonoLL-Regular", size: size) }
    static func dot(_ size: CGFloat)     -> Font { .custom("Ndot-55", size: size) }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// A small uppercase mono label — the catalog/eyebrow voice.
struct MonoLabel: View {
    let text: String
    var color: Color = PB.pencil
    var size: CGFloat = 10
    var tracking: CGFloat = 1.6
    init(_ text: String, color: Color = PB.pencil, size: CGFloat = 10, tracking: CGFloat = 1.6) {
        self.text = text; self.color = color; self.size = size; self.tracking = tracking
    }
    var body: some View {
        Text(text.uppercased())
            .font(PB.mono(size))
            .tracking(tracking)
            .foregroundStyle(color)
    }
}

struct AppScreenHeader<Trailing: View>: View {
    var title: String
    var isPlaying: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, isPlaying: Bool = false, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.isPlaying = isPlaying
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                PlaybackWordmark(capSize: 22, fontSize: 24, isPlaying: isPlaying)
                    .frame(width: 156, height: 26, alignment: .leading)
                if let num = PlaybackAuthSession.shared.profile?.user.member_number {
                    MonoLabel(String(format: "PB · %03d", num), color: PB.pencil.opacity(0.55), size: 9, tracking: 1.8)
                }
                Spacer(minLength: 0)
                trailing()
            }
            .frame(height: 44, alignment: .center)

            Text(title).font(PB.display(40)).foregroundStyle(PB.cream)
        }
    }
}

extension AppScreenHeader where Trailing == EmptyView {
    init(title: String, isPlaying: Bool = false) {
        self.init(title: title, isPlaying: isPlaying) { EmptyView() }
    }
}

struct TopScrollFade: View {
    var height: CGFloat = 92

    var body: some View {
        LinearGradient(
            colors: [PB.black, PB.black.opacity(0.92), PB.black.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .allowsHitTesting(false)
        .ignoresSafeArea(edges: .top)
    }
}

enum ScrollTopAnchor: Hashable {
    case top
}

struct TopTapScrollHotspot: View {
    var action: () -> Void

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: max(proxy.safeAreaInsets.top, 36))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: action)
                    .ignoresSafeArea(edges: .top)
                Spacer(minLength: 0)
            }
        }
        .allowsHitTesting(true)
    }
}

func scrollToTopMarker() -> some View {
    Color.clear
        .frame(height: 0)
        .id(ScrollTopAnchor.top)
}

func scrollToTop(_ proxy: ScrollViewProxy) {
    withAnimation(.easeInOut(duration: 0.28)) {
        proxy.scrollTo(ScrollTopAnchor.top, anchor: .top)
    }
}

struct HeaderCircleIcon: View {
    var systemName: String
    var color: Color = PB.cream

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 44, height: 44)
            .background(Circle().fill(PB.panel))
            .overlay(Circle().strokeBorder(PB.cream.opacity(0.1), lineWidth: 1))
    }
}

struct SelectionDragTarget: Equatable, Identifiable {
    let id: String
    let frame: CGRect
}

struct SelectionDragTargetKey: PreferenceKey {
    static var defaultValue: [SelectionDragTarget] = []

    static func reduce(value: inout [SelectionDragTarget], nextValue: () -> [SelectionDragTarget]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Presents the system share sheet when `item` becomes non-nil,
    /// clears it after dismissal. `items` closure returns the array
    /// to share (strings, URLs, etc.).
    func shareSheet<T: Identifiable>(
        item: Binding<T?>,
        @ViewBuilder items: @escaping (T) -> [Any]
    ) -> some View {
        #if canImport(UIKit)
        self.background(
            ShareSheetPresenter(item: item, items: items)
        )
        #else
        self
        #endif
    }

    func selectionDragTarget(id: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SelectionDragTargetKey.self,
                    value: [SelectionDragTarget(id: id, frame: proxy.frame(in: .global))]
                )
            }
        }
    }

    func twoFingerSelection(
        enabled: Bool,
        targets: [SelectionDragTarget],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        #if canImport(UIKit)
        background(TwoFingerSelectionBridge(enabled: enabled, targets: targets, onSelect: onSelect))
        #else
        self
        #endif
    }

    func restoresSwipeBack() -> some View {
        #if canImport(UIKit)
        background(SwipeBackRestorer())
        #else
        self
        #endif
    }
}

#if canImport(UIKit)
private struct TwoFingerSelectionBridge: UIViewRepresentable {
    var enabled: Bool
    var targets: [SelectionDragTarget]
    var onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.targets = targets
        context.coordinator.onSelect = onSelect
        DispatchQueue.main.async {
            context.coordinator.install(from: uiView)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled = false {
            didSet { recognizer?.isEnabled = enabled }
        }
        var targets: [SelectionDragTarget] = []
        var onSelect: ((String) -> Void)?
        private weak var hostView: UIView?
        private var recognizer: UIPanGestureRecognizer?
        private var selectedDuringGesture: Set<String> = []

        func install(from view: UIView) {
            guard let host = view.nearestSelectionGestureHost else { return }
            if hostView === host {
                recognizer?.isEnabled = enabled
                return
            }

            uninstall()
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
            pan.delegate = self
            pan.isEnabled = enabled
            host.addGestureRecognizer(pan)
            hostView = host
            recognizer = pan
        }

        func uninstall() {
            if let recognizer, let hostView {
                hostView.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            hostView = nil
            selectedDuringGesture.removeAll()
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard enabled, let view = recognizer.view else { return }

            switch recognizer.state {
            case .began:
                selectedDuringGesture.removeAll()
                selectTarget(at: recognizer.location(in: view), in: view)
            case .changed:
                selectTarget(at: recognizer.location(in: view), in: view)
            case .ended, .cancelled, .failed:
                selectedDuringGesture.removeAll()
            default:
                break
            }
        }

        private func selectTarget(at point: CGPoint, in view: UIView) {
            let globalPoint = view.convert(point, to: nil)
            guard let target = targets.first(where: { $0.frame.insetBy(dx: -24, dy: -4).contains(globalPoint) }) else { return }
            guard selectedDuringGesture.insert(target.id).inserted else { return }
            onSelect?(target.id)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            enabled && !targets.isEmpty
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

private extension UIView {
    var nearestSelectionGestureHost: UIView? {
        var candidate = superview
        while let current = candidate {
            if current is UIScrollView { return current }
            candidate = current.superview
        }
        return window
    }
}

private struct SwipeBackRestorer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.restore()
    }

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            restore()
        }

        func restore() {
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
            navigationController?.interactivePopGestureRecognizer?.delegate = nil
        }
    }
}

private struct ShareSheetPresenter<T: Identifiable>: UIViewControllerRepresentable {
    @Binding var item: T?
    var items: (T) -> [Any]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ parent: UIViewController, context: Context) {
        guard let item, context.coordinator.presented == nil else {
            if item == nil { context.coordinator.presented?.dismiss(animated: true) }
            return
        }
        let vc = UIActivityViewController(activityItems: items(item), applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in
            context.coordinator.presented = nil
            self.item = nil
        }
        vc.popoverPresentationController?.sourceView = parent.view
        parent.present(vc, animated: true)
        context.coordinator.presented = vc
    }

    final class Coordinator: NSObject {
        let parent: ShareSheetPresenter
        weak var presented: UIActivityViewController?
        init(_ parent: ShareSheetPresenter) { self.parent = parent }
    }
}
#endif
