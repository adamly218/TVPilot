import Foundation
import Observation

struct SavedTV: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var model: String?
    var mac: String?
    var token: String?
}

struct TVApp: Identifiable, Hashable {
    let id: String
    let name: String
    /// 2 = web/deep-link app, 4 = native app (as reported by the TV).
    var appType: Int = 2
    /// Where the TV keeps this app's icon; used to ask the TV for the image.
    var iconPath: String? = nil

    static let popular: [TVApp] = [
        TVApp(id: "3201907018807", name: "Netflix"),
        TVApp(id: "111299001912", name: "YouTube"),
        TVApp(id: "3201910019365", name: "Prime Video"),
        TVApp(id: "3201901017640", name: "Disney+"),
        TVApp(id: "3201807016597", name: "Apple TV"),
        TVApp(id: "3201606009684", name: "Spotify"),
    ]
}

/// The user's saved TVs, kept in UserDefaults.
@Observable
final class TVStore {
    private static let key = "savedTVs"
    private(set) var tvs: [SavedTV] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let tvs = try? JSONDecoder().decode([SavedTV].self, from: data) {
            self.tvs = tvs
        }
    }

    /// Adds the TV, or updates the saved one with the same host.
    @discardableResult
    func upsert(_ tv: SavedTV) -> SavedTV {
        if let i = tvs.firstIndex(where: { $0.id == tv.id || $0.host == tv.host }) {
            var merged = tv
            merged.id = tvs[i].id
            merged.token = tv.token ?? tvs[i].token
            merged.mac = tv.mac ?? tvs[i].mac
            merged.model = tv.model ?? tvs[i].model
            tvs[i] = merged
            save()
            return merged
        }
        tvs.append(tv)
        save()
        return tv
    }

    func setToken(_ token: String, for id: UUID) {
        guard let i = tvs.firstIndex(where: { $0.id == id }) else { return }
        tvs[i].token = token
        save()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) { tvs.remove(at: index) }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tvs) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
