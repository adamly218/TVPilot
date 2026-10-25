import SwiftUI

struct RemoteView: View {
    @Environment(SamsungRemote.self) private var remote
    @State private var mode = Mode.remote
    @State private var sheet: Sheet?

    enum Mode: String, CaseIterable { case remote = "Remote", touchpad = "Touchpad", numbers = "Numbers" }
    static let padHeight: CGFloat = 270

    enum Sheet: String, Identifiable { case keyboard, apps, cast; var id: String { rawValue } }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                KeyButton(.power, symbol: "power", tint: .red, size: 48)
                Spacer()
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 250)
                Spacer()
                KeyButton(.source, symbol: "rectangle.on.rectangle", size: 48)
            }

            // App shortcuts on the four colour bars.
            HStack(spacing: 8) {
                shortcut("YouTube", color: .red) { openApp("YouTube") }
                shortcut("Spotify", color: .green) { openApp("Spotify") }
                shortcut("Netflix", color: .yellow) { openApp("Netflix") }
                shortcut("All apps", color: .blue) { sheet = .apps }
            }

            HStack(spacing: 14) {
                KeyButton(.rewind, symbol: "backward.fill", size: 48)
                KeyButton(.play, symbol: "play.fill", size: 48)
                KeyButton(.pause, symbol: "pause.fill", size: 48)
                KeyButton(.fastForward, symbol: "forward.fill", size: 48)
            }

            HStack(alignment: .top) {
                Rocker(up: .volumeUp, down: .volumeDown, label: "VOL")
                Spacer()
                VStack(spacing: 8) {
                    KeyButton(.mute, symbol: "speaker.slash", size: 42)
                    KeyButton(.chList, symbol: "list.bullet", size: 42)
                    KeyButton(.guide, symbol: "calendar", size: 42)
                }
                Spacer()
                Rocker(up: .channelUp, down: .channelDown, label: "CH")
            }

            HStack(spacing: 14) {
                KeyButton(.back, symbol: "arrow.uturn.backward", size: 48)
                KeyButton(.home, symbol: "house", size: 48)
                KeyButton(.exit, symbol: "xmark", size: 48)
                KeyButton(.menu, symbol: "gearshape", size: 48)
            }

            Spacer(minLength: 0)

            // Arrows and OK sit at the bottom, within easy thumb reach.
            Group {
                switch mode {
                case .remote: DPad()
                case .touchpad: Touchpad()
                case .numbers: NumberPad()
                }
            }
            // Same fixed height for every mode, so switching never pushes the buttons above.
            .frame(height: Self.padHeight)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .disabled(!remote.isConnected)
        .overlay { StatusOverlay() }
        .navigationTitle(remote.tv?.name ?? "Remote")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .bottomBarIfAvailable) {
                Button { sheet = .keyboard } label: { Label("Keyboard", systemImage: "keyboard") }
                Spacer()
                Button { sheet = .apps } label: { Label("Apps", systemImage: "square.grid.2x2") }
                Spacer()
                Button { sheet = .cast } label: { Label("Cast", systemImage: "photo.on.rectangle") }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .keyboard: KeyboardSheet()
            case .apps: AppsSheet()
            case .cast: CastSheet()
            }
        }
        .onDisappear { remote.disconnect() }
    }

    private func shortcut(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(color == .yellow ? .black : .white)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(color.gradient, in: Capsule())
        }
        .buttonStyle(PressStyle())
    }

    /// Opens an app by name, using the TV's own app ID when the TV has listed it.
    private func openApp(_ name: String) {
        let match = remote.installedApps.first { $0.name.localizedCaseInsensitiveContains(name) }
            ?? TVApp.popular.first { $0.name == name }
        if let match { remote.launch(match) }
    }
}

extension ToolbarItemPlacement {
    static var bottomBarIfAvailable: ToolbarItemPlacement {
        #if os(iOS)
        .bottomBar
        #else
        .automatic
        #endif
    }
}

/// A round remote button that sends one key.
struct KeyButton: View {
    @Environment(SamsungRemote.self) private var remote
    let key: TVKey
    let symbol: String
    var tint: Color = .primary
    var size: CGFloat = 56

    init(_ key: TVKey, symbol: String, tint: Color = .primary, size: CGFloat = 56) {
        self.key = key
        self.symbol = symbol
        self.tint = tint
        self.size = size
    }

    var body: some View {
        Button {
            Haptics.tap()
            remote.press(key)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(key.rawValue.replacingOccurrences(of: "KEY_", with: "").capitalized)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Vertical up/down pill for volume and channel. Holding repeats.
private struct Rocker: View {
    @Environment(SamsungRemote.self) private var remote
    let up: TVKey
    let down: TVKey
    let label: String

    var body: some View {
        VStack(spacing: 0) {
            RepeatButton(symbol: "plus") { remote.press(up) }
            Text(label).font(.caption.bold()).foregroundStyle(.secondary).padding(.vertical, 6)
            RepeatButton(symbol: "minus") { remote.press(down) }
        }
        .frame(width: 60)
        .background(Color.white.opacity(0.08), in: Capsule())
    }
}

private struct RepeatButton: View {
    let symbol: String
    let action: () -> Void
    @State private var timer: Timer?

    var body: some View {
        Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .frame(width: 60, height: 50)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 60, maximumDistance: 30) {
            } onPressingChanged: { pressing in
                timer?.invalidate()
                timer = nil
                if pressing {
                    Haptics.tap()
                    action()
                    timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { _ in
                        Task { @MainActor in action() }
                    }
                    timer?.fireDate = Date().addingTimeInterval(0.5)
                }
            }
    }
}

private struct DPad: View {
    @Environment(SamsungRemote.self) private var remote

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.06))
            arrow(.up, "chevron.up").frame(maxHeight: .infinity, alignment: .top)
            arrow(.down, "chevron.down").frame(maxHeight: .infinity, alignment: .bottom)
            arrow(.left, "chevron.left").frame(maxWidth: .infinity, alignment: .leading)
            arrow(.right, "chevron.right").frame(maxWidth: .infinity, alignment: .trailing)
            Button {
                Haptics.tap()
                remote.press(.enter)
            } label: {
                Text("OK")
                    .font(.title3.bold())
                    .frame(width: 88, height: 88)
                    .background(Color.blue.gradient, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(PressStyle())
        }
        .frame(width: RemoteView.padHeight, height: RemoteView.padHeight)
    }

    // Each arrow gets a big tap area reaching from the ring's edge toward OK.
    private func arrow(_ key: TVKey, _ symbol: String) -> some View {
        Button {
            Haptics.tap()
            remote.press(key)
        } label: {
            Image(systemName: symbol)
                .font(.title.weight(.bold))
                .frame(width: 84, height: 84)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

/// Swipe to move, tap to select.
private struct Touchpad: View {
    @Environment(SamsungRemote.self) private var remote

    var body: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(Color.white.opacity(0.06))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "hand.draw").font(.largeTitle)
                    Text("Swipe to move · Tap to select")
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 24).onEnded { value in
                    let dx = value.translation.width, dy = value.translation.height
                    let key: TVKey = abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
                    Haptics.tap()
                    remote.press(key)
                }
            )
            .simultaneousGesture(TapGesture().onEnded {
                Haptics.tap()
                remote.press(.enter)
            })
    }
}

private struct NumberPad: View {
    @Environment(SamsungRemote.self) private var remote

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(64), spacing: 28), count: 3)
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(1...9, id: \.self) { digit($0) }
            KeyButton(.previousChannel, symbol: "arrow.left.arrow.right", size: 58)
            digit(0)
            KeyButton(.info, symbol: "info", size: 58)
        }
    }

    private func digit(_ n: Int) -> some View {
        Button {
            Haptics.tap()
            remote.press(.digit(n))
        } label: {
            Text("\(n)")
                .font(.title.weight(.semibold))
                .frame(width: 58, height: 58)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(PressStyle())
    }
}

private struct StatusOverlay: View {
    @Environment(SamsungRemote.self) private var remote

    var body: some View {
        if let content {
            VStack(spacing: 14) {
                content.icon
                Text(content.title).font(.headline)
                Text(content.detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if content.retry {
                    HStack {
                        if let tv = remote.tv, let mac = tv.mac {
                            Button("Turn on TV") {
                                WakeOnLAN.wake(mac: mac, host: tv.host)
                                Task {
                                    try? await Task.sleep(for: .seconds(4))
                                    remote.reconnect()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        Button("Try again") { remote.reconnect() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .padding()
        }
    }

    private var content: (icon: AnyView, title: String, detail: String, retry: Bool)? {
        switch remote.state {
        case .connected:
            return nil
        case .connecting:
            return (AnyView(ProgressView()), "Connecting…", "Talking to \(remote.tv?.name ?? "your TV").", false)
        case .waitingForApproval:
            return (AnyView(Image(systemName: "tv.badge.wifi").font(.largeTitle)), "Check your TV",
                    "Select Allow on the TV screen to let TV Pilot control it.", false)
        case .disconnected:
            return (AnyView(Image(systemName: "wifi.slash").font(.largeTitle)), "Not connected", "", true)
        case .failed(let message):
            return (AnyView(Image(systemName: "exclamationmark.triangle").font(.largeTitle)), "Couldn't connect", message, true)
        }
    }
}
