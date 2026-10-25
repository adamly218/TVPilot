import Foundation
import Network

/// A tiny HTTP server that serves one local file to the TV, with Range support so
/// videos can seek. The TV pulls the file from http://<phone-ip>:<port>/media/<name>.
final class MediaServer: @unchecked Sendable {
    static let shared = MediaServer()

    private let queue = DispatchQueue(label: "MediaServer")
    private var listener: NWListener?
    private var file: (url: URL, mime: String, path: String)?

    /// Starts serving `url` and returns the address the TV should load.
    func serve(_ url: URL, mime: String) async throws -> URL {
        guard let ip = LocalNetwork.wifiIPv4() else { throw CastError.noWiFi }
        let port = try await startIfNeeded()
        let path = "/media/\(UUID().uuidString).\(url.pathExtension.lowercased())"
        queue.sync { file = (url, mime, path) }
        guard let served = URL(string: "http://\(ip):\(port)\(path)") else { throw CastError.noWiFi }
        return served
    }

    private func startIfNeeded() async throws -> UInt16 {
        if let port = listener?.port?.rawValue, listener?.state == .ready { return port }
        listener?.cancel()
        let listener = try NWListener(using: .tcp)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .main)
            self?.readRequest(connection, buffer: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, header: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if done || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let file, String(parts[1]) == file.path,
              let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.int64Value,
              let handle = try? FileHandle(forReadingFrom: file.url) else {
            send(connection, head: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", then: nil)
            return
        }
        let isHead = parts[0] == "HEAD"

        var start: Int64 = 0
        var end = size - 1
        var partial = false
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let spec = range.split(separator: "=").last {
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            if bounds.count == 2 {
                if let s = Int64(bounds[0].trimmingCharacters(in: .whitespaces)) {
                    start = s
                    if let e = Int64(bounds[1].trimmingCharacters(in: .whitespaces)) { end = min(e, size - 1) }
                } else if let suffix = Int64(bounds[1].trimmingCharacters(in: .whitespaces)) {
                    start = max(0, size - suffix)
                }
                partial = start < size
            }
        }
        let length = max(0, end - start + 1)
        let isImage = file.mime.hasPrefix("image/")

        var head = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(file.mime)\r\n"
        head += "Content-Length: \(length)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        if partial { head += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        head += "transferMode.dlna.org: \(isImage ? "Interactive" : "Streaming")\r\n"
        head += "contentFeatures.dlna.org: \(DLNACaster.contentFeatures(isImage: isImage))\r\n"
        head += "Connection: close\r\n\r\n"

        if isHead {
            try? handle.close()
            send(connection, head: head, then: nil)
            return
        }
        try? handle.seek(toOffset: UInt64(start))
        send(connection, head: head) { [weak self] in
            self?.stream(connection, handle: handle, remaining: length)
        }
    }

    private func send(_ connection: NWConnection, head: String, then next: (() -> Void)?) {
        connection.send(content: Data(head.utf8), completion: .contentProcessed { error in
            if error == nil, let next { next() } else { connection.cancel() }
        })
    }

    private func stream(_ connection: NWConnection, handle: FileHandle, remaining: Int64) {
        guard remaining > 0,
              let chunk = try? handle.read(upToCount: Int(min(remaining, 256 * 1024))), !chunk.isEmpty else {
            try? handle.close()
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                try? handle.close()
                connection.cancel()
                return
            }
            self?.stream(connection, handle: handle, remaining: remaining - Int64(chunk.count))
        })
    }
}

enum CastError: LocalizedError {
    case noWiFi
    case noRenderer
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .noWiFi: "Connect your phone to Wi-Fi to cast."
        case .noRenderer: "This TV didn't accept media casting. Make sure it's on (not in standby)."
        case .rejected(let detail): "The TV wouldn't play this file. \(detail)"
        }
    }
}
