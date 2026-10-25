import Foundation
import Observation

/// Talks to a Samsung Smart TV (2016+) over its local WebSocket remote API.
///
/// Newer TVs listen on wss://<tv>:8002 with a self-signed certificate and hand out a
/// token the first time the user allows the connection on the TV. Older ones only
/// offer ws://<tv>:8001, so we fall back to that.
@MainActor
@Observable
final class SamsungRemote {
    enum State: Equatable {
        case disconnected
        case connecting
        case waitingForApproval
        case connected
        case failed(String)
    }

    static let clientName = "TV Pilot"

    private(set) var state: State = .disconnected
    private(set) var tv: SavedTV?
    private(set) var installedApps: [TVApp] = []
    /// App icons sent by the TV, keyed by app ID.
    private(set) var appIcons: [String: Data] = [:]

    /// Called when the TV issues a new pairing token, so it can be saved.
    var onToken: ((String, UUID) -> Void)?

    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var secure = true
    @ObservationIgnored private var approvalTimer: Task<Void, Never>?
    @ObservationIgnored private let session = URLSession(
        configuration: .ephemeral, delegate: LocalTrustDelegate(), delegateQueue: nil)

    var isConnected: Bool { state == .connected }

    func connect(to tv: SavedTV) {
        disconnect()
        self.tv = tv
        secure = true
        open()
    }

    func reconnect() {
        guard let tv else { return }
        connect(to: tv)
    }

    func disconnect() {
        approvalTimer?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        installedApps = []
        state = .disconnected
    }

    private func open() {
        guard let tv else { return }
        var comps = URLComponents()
        comps.scheme = secure ? "wss" : "ws"
        comps.host = tv.host
        comps.port = secure ? 8002 : 8001
        comps.path = "/api/v2/channels/samsung.remote.control"
        var items = [URLQueryItem(name: "name", value: Data(Self.clientName.utf8).base64EncodedString())]
        if secure, let token = tv.token {
            items.append(URLQueryItem(name: "token", value: token))
        }
        comps.queryItems = items
        guard let url = comps.url else {
            state = .failed("That TV address isn't valid.")
            return
        }

        state = .connecting
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive(on: task)

        // The TV only answers once the user accepts the prompt on screen.
        approvalTimer?.cancel()
        approvalTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled, self.state == .connecting else { return }
            self.state = .waitingForApproval
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .failure(let error):
                    self.handleFailure(error)
                case .success(let message):
                    switch message {
                    case .string(let text): self.handle(text)
                    case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                    self.receive(on: task)
                }
            }
        }
    }

    private func handleFailure(_ error: Error) {
        let wasConnected = state == .connected
        task = nil
        approvalTimer?.cancel()
        if secure && !wasConnected && state != .waitingForApproval {
            secure = false
            open()
            return
        }
        state = .failed(wasConnected
            ? "Lost the connection to the TV."
            : "Couldn't reach the TV. Make sure it's on and on the same Wi-Fi as your phone.")
    }

    private func handle(_ text: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let event = json["event"] as? String else { return }
        let data = json["data"] as? [String: Any]

        switch event {
        case "ms.channel.connect":
            approvalTimer?.cancel()
            state = .connected
            if let token = (data?["token"] as? String) ?? (data?["token"] as? Int).map(String.init),
               let id = tv?.id {
                tv?.token = token
                onToken?(token, id)
            }
            requestInstalledApps()
        case "ms.channel.unauthorized":
            approvalTimer?.cancel()
            state = .failed("The TV refused the connection. On the TV, open Settings › General › External Device Manager › Device Connection Manager and allow TV Pilot.")
        case "ms.channel.timeOut":
            approvalTimer?.cancel()
            state = .failed("Timed out waiting for you to press Allow on the TV.")
        case "ed.installedApp.get":
            let list = (data?["data"] as? [[String: Any]]) ?? []
            installedApps = list.compactMap { item in
                guard let id = item["appId"] as? String, let name = item["name"] as? String else { return nil }
                return TVApp(id: id, name: name, appType: (item["app_type"] as? Int) ?? 2,
                             iconPath: item["icon"] as? String)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            for app in installedApps where appIcons[app.id] == nil {
                if let path = app.iconPath, !path.isEmpty {
                    send(["method": "ms.channel.emit",
                          "params": ["event": "ed.apps.icon", "to": "host", "data": ["iconPath": path]]])
                }
            }
        case "ed.apps.icon":
            guard let path = data?["iconPath"] as? String,
                  let base64 = data?["imageBase64"] as? String,
                  let image = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
                  let app = installedApps.first(where: { $0.iconPath == path }) else { break }
            appIcons[app.id] = image
        default:
            break
        }
    }

    // MARK: Commands

    func press(_ key: TVKey) {
        send(["method": "ms.remote.control",
              "params": ["Cmd": "Click", "DataOfCmd": key.rawValue, "Option": "false", "TypeOfRemote": "SendRemoteKey"]])
    }

    /// Types text into whatever input field is open on the TV.
    func type(_ text: String) {
        send(["method": "ms.remote.control",
              "params": ["Cmd": Data(text.utf8).base64EncodedString(), "DataOfCmd": "base64", "TypeOfRemote": "SendInputString"]])
    }

    func endTyping() {
        send(["method": "ms.remote.control", "params": ["TypeOfRemote": "SendInputEnd"]])
    }

    func requestInstalledApps() {
        send(["method": "ms.channel.emit", "params": ["event": "ed.installedApp.get", "to": "host"]])
    }

    func launch(_ app: TVApp) {
        if installedApps.contains(where: { $0.id == app.id }) {
            send(["method": "ms.channel.emit",
                  "params": ["event": "ed.apps.launch", "to": "host",
                             "data": ["appId": app.id, "action_type": app.appType == 4 ? "NATIVE_LAUNCH" : "DEEP_LINK"]]])
        } else if let host = tv?.host, let url = URL(string: "http://\(host):8001/api/v2/applications/\(app.id)") {
            // Not in the TV's list (or the list hasn't loaded): try the REST endpoint.
            var request = URLRequest(url: url, timeoutInterval: 4)
            request.httpMethod = "POST"
            session.dataTask(with: request).resume()
        }
    }

    private func send(_ object: [String: Any]) {
        guard let task, state == .connected,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }
}

/// Accepts the TV's self-signed certificate. Only ever used for hosts on the local network.
final class LocalTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
