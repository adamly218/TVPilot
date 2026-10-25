import SwiftUI

struct ConnectView: View {
    @Environment(TVStore.self) private var store
    @Environment(SamsungRemote.self) private var remote
    @State private var scanner = TVScanner()
    @State private var path: [SavedTV] = []
    @State private var showingAdd = false
    @State private var manualHost = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !store.tvs.isEmpty {
                    Section("My TVs") {
                        ForEach(store.tvs) { tv in
                            TVRow(tv: tv, saved: true) { open(tv) } wake: {
                                if let mac = tv.mac { WakeOnLAN.wake(mac: mac, host: tv.host) }
                                Haptics.tap()
                            }
                        }
                        .onDelete { store.remove(at: $0) }
                    }
                }

                Section {
                    ForEach(scanner.found.filter { tv in !store.tvs.contains { $0.host == tv.host } }) { tv in
                        TVRow(tv: tv, saved: false) { open(tv) }
                    }
                    if scanner.isScanning {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for TVs…").foregroundStyle(.secondary)
                        }
                    } else if let message = scanner.message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await scanner.scan() }
                    } label: {
                        Label("Scan Wi-Fi again", systemImage: "arrow.clockwise")
                    }
                    .disabled(scanner.isScanning)
                    Button {
                        manualHost = ""
                        showingAdd = true
                    } label: {
                        Label("Add TV by IP address", systemImage: "plus")
                    }
                } header: {
                    Text("On this Wi-Fi")
                } footer: {
                    Text("Works with Samsung Smart TVs from 2016 onward. The first time you connect, press Allow on the TV.")
                }

                Section {
                } footer: {
                    Text("Developed by Adam")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .navigationTitle("TV Pilot")
            .navigationDestination(for: SavedTV.self) { _ in RemoteView() }
            .refreshable { await scanner.scan() }
            .task {
                #if DEBUG
                // Layout check in the simulator: launch with -openRemote to jump straight to the remote.
                if ProcessInfo.processInfo.arguments.contains("-openRemote") {
                    path = [SavedTV(name: "Living Room TV", host: "192.0.2.1")]
                    return
                }
                #endif
                await scanner.scan()
            }
            .alert("Add TV", isPresented: $showingAdd) {
                TextField("192.168.1.20", text: $manualHost)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Button("Cancel", role: .cancel) {}
                Button("Connect") { addManual() }
            } message: {
                Text("On the TV: Settings › General › Network › Network Status › IP Settings.")
            }
        }
    }

    private func open(_ tv: SavedTV) {
        let saved = store.upsert(tv)
        remote.connect(to: saved)
        path = [saved]
    }

    private func addManual() {
        let host = manualHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        Task {
            let found = await TVScanner.probe(host)
            open(found ?? SavedTV(name: "Samsung TV", host: host))
        }
    }
}

private struct TVRow: View {
    let tv: SavedTV
    let saved: Bool
    let connect: () -> Void
    var wake: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "tv")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(tv.name).font(.headline)
                Text([tv.model, tv.host].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let wake, tv.mac != nil {
                Button(action: wake) {
                    Image(systemName: "power")
                        .padding(8)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Turn on \(tv.name)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: connect)
    }
}
