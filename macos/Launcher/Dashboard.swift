import Foundation

/// The home server's dashboard (`server/Dashboard`): one page at `http://<address>:8095` for
/// the Classic, Pandaria and Forever servers, in a stack of its own, `hearthside-dashboard`, beside
/// theirs. The launcher keeps its files current whenever it reaches the server, whichever servers
/// are set up, and `home-status schedule` there keeps its container up and its cron job in place.
@MainActor
final class HomeDashboard {
    static let shared = HomeDashboard()
    nonisolated static let project = "hearthside-dashboard"
    /// The files the launcher keeps current on the server.
    private static let files = ["home-status", "home-compose", "compose.yaml", "dashboard.py", "dashboard.html"]

    private var home: HomeServer { .shared }
    private init() {}

    /// The dashboard's folder, beside the Classic server's.
    nonisolated static func folder(beside cmangos: String) -> String {
        (cmangos as NSString).deletingLastPathComponent + "/" + project
    }

    private var folder: String { Self.folder(beside: home.folder) }

    private var recipe: URL? {
        let url = Bundle.main.url(forResource: "Server", withExtension: nil)?.appendingPathComponent("Dashboard")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Its files, its address, then `home-status schedule`, which also moves a dashboard that lived
    /// in the Classic server's folder over here once. The Classic world maps when they are missing.
    func sync() async {
        guard let recipe, !home.folder.isEmpty else { return }
        let files = Self.files.map { recipe.appendingPathComponent($0).path }
        guard files.allSatisfy(FileManager.default.fileExists(atPath:)) else { return }
        do {
            try await home.ssh("mkdir -p \(folder)/storage && cd \(folder) && touch .env && "
                               + "{ grep -q '^LAN_IP=' .env || echo 'LAN_IP=\(home.address)' >> .env; }", quiet: true)
            try await home.rsync(files, to: folder, named: Self.project)
            let out = try await home.ssh("\(folder)/home-status schedule; "
                                         + "test -s \(folder)/storage/site/azeroth.png -a -s \(folder)/storage/site/kalimdor.png && echo maps",
                                         quiet: true)
            if !out.contains("maps") { await sendWorldMaps() }
        } catch {}
    }

    /// The password (`home-status password`, on standard input), asked for before the dashboard
    /// starts, stops or changes a server; a new one signs everyone out.
    func setPassword(_ password: String) async -> String? {
        do {
            await sync()
            _ = try await home.ssh("\(folder)/home-status password", stdin: password)
            return nil
        } catch {
            return LocalServer.message(error)
        }
    }

    /// The Classic world map's two pictures, drawn by the game binary from this Mac's game files,
    /// as no map art ships with the app. Without them the page says where they come from; the next
    /// look tries again.
    private func sendWorldMaps() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("world-maps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        guard (try? await Docker.run(Paths.gameBinary, ["--world-maps", dir.path, Paths.data.path], quiet: true)) != nil,
              (try? await home.rsync(["azeroth.png", "kalimdor.png"].map { dir.appendingPathComponent($0).path },
                                     to: folder, named: Self.project, into: "storage/site/")) != nil
        else { return }
        _ = try? await home.ssh("chmod a+r \(folder)/storage/site/*.png", quiet: true)
    }
}
