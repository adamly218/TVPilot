import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct KeyboardSheet: View {
    @Environment(SamsungRemote.self) private var remote
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Open a search or text box on the TV, then type here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Type on your TV", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .onChange(of: text) { _, new in remote.type(new) }
                    .onSubmit {
                        remote.endTyping()
                        remote.press(.enter)
                        dismiss()
                    }
                HStack {
                    Button("Clear") {
                        text = ""
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Send") {
                        remote.endTyping()
                        remote.press(.enter)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Keyboard")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { remote.endTyping(); dismiss() } }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}

struct AppsSheet: View {
    @Environment(SamsungRemote.self) private var remote
    @Environment(\.dismiss) private var dismiss

    private var apps: [TVApp] {
        remote.installedApps.isEmpty ? TVApp.popular : remote.installedApps
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 14)], spacing: 18) {
                    ForEach(apps) { app in
                        Button {
                            Haptics.tap()
                            remote.launch(app)
                            dismiss()
                        } label: {
                            VStack(spacing: 8) {
                                icon(for: app)
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 18))
                                Text(app.name)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                .padding()
            }
            .navigationTitle(remote.installedApps.isEmpty ? "Popular apps" : "Apps on TV")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { remote.requestInstalledApps() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }

    /// The app's real logo as sent by the TV, or its first letter until that arrives.
    @ViewBuilder
    private func icon(for app: TVApp) -> some View {
        let data = remote.appIcons[app.id]
            ?? remote.installedApps.first { $0.name.localizedCaseInsensitiveContains(app.name) }
                .flatMap { remote.appIcons[$0.id] }
        #if os(iOS)
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            letterIcon(app)
        }
        #else
        letterIcon(app)
        #endif
    }

    private func letterIcon(_ app: TVApp) -> some View {
        Text(String(app.name.prefix(1)).uppercased())
            .font(.title.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(color(for: app).gradient)
    }

    private func color(for app: TVApp) -> Color {
        let palette: [Color] = [.red, .orange, .pink, .purple, .indigo, .blue, .teal, .green]
        let hash = app.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }
}

struct CastSheet: View {
    @Environment(SamsungRemote.self) private var remote
    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var status: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 54))
                    .foregroundStyle(.blue)
                Text("Show a photo or video from your phone on the TV. Keep TV Pilot open while it plays.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                PhotosPicker(selection: $selection, matching: .any(of: [.images, .videos])) {
                    Label("Choose photo or video", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(working)

                Button("Stop casting") {
                    guard let host = remote.tv?.host else { return }
                    Task { await DLNACaster.stop(on: host); status = nil }
                }
                .disabled(working)

                if working { ProgressView() }
                if let status {
                    Text(status).font(.callout).multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("Cast")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: selection) { _, item in
                guard let item else { return }
                Task { await cast(item) }
            }
        }
    }

    private func cast(_ item: PhotosPickerItem) async {
        guard let host = remote.tv?.host else { return }
        working = true
        status = "Preparing…"
        defer { working = false; selection = nil }
        do {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            let file: URL
            let mime: String
            if isVideo {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw CastError.rejected("Couldn't read that video.") }
                file = movie.url
                mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "video/mp4"
            } else {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw CastError.rejected("Couldn't read that photo.") }
                file = try Self.jpegFile(from: data)
                mime = "image/jpeg"
            }
            let url = try await MediaServer.shared.serve(file, mime: mime)
            status = "Sending to TV…"
            try await DLNACaster.play(url, mime: mime, title: isVideo ? "Video" : "Photo", on: host)
            status = "Playing on \(remote.tv?.name ?? "TV")."
        } catch {
            status = error.localizedDescription
        }
    }

    /// TVs often can't show HEIC, so photos are re-encoded as JPEG.
    private static func jpegFile(from data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cast-\(UUID().uuidString).jpg")
        #if os(iOS)
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else {
            throw CastError.rejected("Couldn't read that photo.")
        }
        try jpeg.write(to: url)
        #else
        try data.write(to: url)
        #endif
        return url
    }
}

/// A video from the photo library, copied to a temporary file the server can stream.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("cast-\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
