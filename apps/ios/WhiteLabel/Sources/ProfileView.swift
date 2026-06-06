import SwiftUI

/// Profile / You — identity and the customizations a music app usually carries.
struct ProfileView: View {
    @AppStorage("wl.reduceMotion") private var reduceMotion = false
    @AppStorage("wl.loudnessMatch") private var loudnessMatch = true
    @AppStorage("wl.autoplayNext") private var autoplayNext = true
    @AppStorage("wl.notifications") private var notifications = true
    @AppStorage("wl.defaultAccess") private var defaultAccess = "Restricted"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    MonoLabel("White Label", color: WL.pencil, size: 11, tracking: 2.5)
                    Text("Profile").font(WL.display(40)).foregroundStyle(WL.cream)
                }

                identityCard

                section("Playback") {
                    toggleRow("Loudness match", $loudnessMatch)
                    toggleRow("Autoplay next", $autoplayNext)
                }
                section("Appearance") {
                    toggleRow("Reduce motion", $reduceMotion)
                }
                section("Sharing") {
                    menuRow("Default link access", $defaultAccess, ["Restricted", "Anyone with the link"])
                }
                section("Notifications") {
                    toggleRow("Push notifications", $notifications)
                }

                Button { } label: {
                    Text("Sign out").font(WL.text(15)).foregroundStyle(WL.redline)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WL.panel))
                }
                .buttonStyle(.plain)

                MonoLabel("White Label · v0.1", color: WL.pencil, size: 9, tracking: 1.4)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 150)
        }
        .scrollIndicators(.hidden)
        .background(WL.black.ignoresSafeArea())
        .foregroundStyle(WL.cream)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var identityCard: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(LinearGradient(colors: [WL.cobalt, Color(hex: 0x8597EE)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 56, height: 56)
                .overlay(Text("TB").font(WL.display(20)).foregroundStyle(WL.cream))
            VStack(alignment: .leading, spacing: 4) {
                Text("Theo Battaglia").font(WL.display(20)).foregroundStyle(WL.cream)
                MonoLabel("All My Friends Inc · Owner", color: WL.pencil, size: 10, tracking: 1.2)
            }
            Spacer()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WL.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WL.cream.opacity(0.07), lineWidth: 1))
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(title, color: WL.pencil, size: 10, tracking: 2)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WL.panel))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WL.cream.opacity(0.07), lineWidth: 1))
        }
    }

    private func toggleRow(_ label: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Text(label).font(WL.text(15)).foregroundStyle(WL.cream)
        }
        .tint(WL.cobalt)
        .padding(.horizontal, 15).padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(WL.cream.opacity(0.06)).frame(height: 1).padding(.leading, 15) }
    }

    private func menuRow(_ label: String, _ binding: Binding<String>, _ options: [String]) -> some View {
        HStack {
            Text(label).font(WL.text(15)).foregroundStyle(WL.cream)
            Spacer()
            Menu {
                ForEach(options, id: \.self) { o in Button(o) { binding.wrappedValue = o } }
            } label: {
                HStack(spacing: 5) {
                    MonoLabel(binding.wrappedValue, color: WL.pencil, size: 10, tracking: 0.8)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(WL.pencil)
                }
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 14)
    }
}
