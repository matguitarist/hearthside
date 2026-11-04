import AppKit
import Foundation

/// Classic on a home server: CMaNGOS with bots in Docker on an always-on machine on the network
/// (an Unraid box, say), set up and run from here over SSH.
///
/// The launcher copies the CMaNGOS recipe and the game files the map tools read into a folder
/// there (`/mnt/user/appdata/azeroth-survivors-cmangos` on Unraid, else in the login's home), with
/// an `.env` that publishes the realm at the server's address. `home-setup` then runs there on its
/// own, an hour or two on a small CPU, so the launcher can quit meanwhile; everything after goes
/// through `home-compose` and `docker exec`. The server restarts with the machine and keeps
/// running when the game quits. Nothing here opens it to the internet.
@MainActor
final class HomeServer: ObservableObject {
    enum Phase: Equatable {
        /// No host or key yet.
        case notConfigured
        case checking
        /// SSH failed: the server is off, the address is wrong, or it does not hold the key.
        case unreachable(String)
        case noDocker
        case notSetUp
        /// The setup runs on the server, at this step.
        case settingUp(String)
        /// An update of the server's software runs on the server, at this step.
        case updating(String)
        /// A step the launcher waits for: copying, start, stop.
        case busy(String)
        case stopped
        case running
        case failed(String)
    }

    @Published private(set) var phase: Phase = .notConfigured
    /// Kept across launches, so Play knows of them while the server is stopped.
    @Published private(set) var accounts: [String] = UserDefaults.standard.stringArray(forKey: "homeAccounts") ?? [] {
        didSet { UserDefaults.standard.set(accounts, forKey: "homeAccounts") }
    }
    @Published private(set) var admins: Set<String> = []
    /// The bots and the world's rates, as the server's `.env` holds them.
    @Published private(set) var settings: Settings?
    /// The random bots the server keeps (`BOTS` in its `.env`).
    var bots: Int? { settings?.bots }

    /// What Settings › Home Server sets on the game server, each a key of its `.env` that
    /// `compose.yaml` passes on as a CMaNGOS or playerbots setting.
    struct Settings: Equatable {
        var bots = 100
        /// Bots of a fitting level come to the zones around real players.
        var botsNearPlayers = false
        /// Bots stay within five levels above the highest player online.
        var botsSyncLevel = false
        var xp = 1.0
        var loot = 1.0
        var gold = 1.0
        var reputation = 1.0
        var rest = 1.0
        /// The auction house's bot posts and buys auctions.
        var ahEnabled = true
        /// Its prices, times each item's value (`AhBot.PriceMultiplier`).
        var ahPrices = 0.35
        /// Its stock, times the auctions each category holds in `ahbot.conf`.
        var ahStock = 1.0

        static let rates: [Double] = [1, 1.5, 2, 3, 5]
        static let ahPriceSteps: [Double] = [0.2, 0.35, 0.5, 0.75, 1, 1.5]
        static let ahStockSteps: [Double] = [0.25, 0.5, 1, 1.5, 2, 3]

        init() {}

        init(env: [String: String]) {
            func rate(_ key: String) -> Double { env[key].flatMap(Double.init).map { max(0.1, min($0, 10)) } ?? 1 }
            bots = env["BOTS"].flatMap(Int.init) ?? 100
            botsNearPlayers = env["BOTS_NEAR_PLAYERS"] == "1"
            botsSyncLevel = env["BOTS_SYNC_LEVEL"] == "1"
            xp = rate("RATE_XP")
            loot = rate("RATE_LOOT")
            gold = rate("RATE_GOLD")
            reputation = rate("RATE_REPUTATION")
            rest = rate("RATE_REST")
            ahEnabled = env["AH_ENABLED"] != "0"
            ahPrices = env["AH_PRICES"].flatMap(Double.init).map { max(0.05, min($0, 10)) } ?? 0.35
            ahStock = env["AH_STOCK"].flatMap(Double.init).map { max(0, min($0, 10)) } ?? 1
        }

        var env: [(String, String)] {
            func r(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
            return [("BOTS", String(bots)), ("BOT_ACCOUNTS", String(HomeServer.accounts(for: bots))),
                    ("BOTS_NEAR_PLAYERS", botsNearPlayers ? "1" : "0"), ("BOTS_SYNC_LEVEL", botsSyncLevel ? "1" : "0"),
                    // Bots move on every half hour to two hours rather than two to 48, so they
                    // find the players within a session.
                    ("BOTS_MOVE_MIN", botsNearPlayers ? "1800" : "7200"), ("BOTS_MOVE_MAX", botsNearPlayers ? "7200" : "172800"),
                    ("RATE_XP", r(xp)), ("RATE_LOOT", r(loot)), ("RATE_GOLD", r(gold)),
                    ("RATE_REPUTATION", r(reputation)), ("RATE_REST", r(rest)),
                    ("AH_ENABLED", ahEnabled ? "1" : "0"), ("AH_PRICES", r(ahPrices)), ("AH_STOCK", r(ahStock))]
        }
    }
    /// The server's backups of its accounts and characters, newest first (`home-backup list`).
    @Published private(set) var backups: [Backup] = []
    /// What the server runs and the newest of each, after Check for Updates (`home-update check`).
    @Published private(set) var software: Software?
    /// Why the last update did not finish, if it did not; the old server was put back.
    @Published private(set) var updateFailed: String?
    /// The server right now, while it runs (`loadStats`).
    @Published private(set) var stats: Stats?

    struct Stats: Equatable {
        struct Player: Equatable, Hashable {
            let name: String
            let level: Int
        }
        /// The people playing: every character online that is not a random bot's.
        let players: [Player]
        let bots: Int
        /// The game server's CPU, in cores (docker's percentage is per core).
        let cores: Double
        let machineCores: Int
        let memory: Int64
        let machineMemory: Int64
        let machineAvailable: Int64
        let since: Date?
    }

    struct Software: Equatable {
        struct Repo: Equatable {
            let name: String
            let built: String
            let newest: String
            var current: Bool { built == newest }
        }
        let repos: [Repo]
        /// The movement maps are built again on the way: another hour or two.
        let mmaps: Bool
        /// The newest core reads maps this server cannot make yet.
        let blocked: Bool
        let updated: Date?
        var current: Bool { repos.allSatisfy(\.current) }
    }

    struct Backup: Identifiable, Equatable {
        let name: String
        let bytes: Int
        let date: Date
        var id: String { name }
        /// Taken by a restore, of the state it replaced.
        var beforeRestore: Bool { name.contains("-before-restore") }
    }

    static let shared = HomeServer()
    static let defaultKey = "~/.ssh/id_ed25519"
    /// The CMaNGOS level of an administrator (`SEC_ADMINISTRATOR`).
    let adminLevel = 3
    private static let project = "azeroth-survivors-cmangos"
    private static let realmDB = "classicrealmd"
    /// The game files the map tools read, of the client's Data folder.
    /// The recipe's scripts and compose files the launcher keeps current on the server; the
    /// compose files take effect at the next start or Apply.
    private static let scripts = ["home-compose", "home-backup", "home-setup", "home-update", "home-status",
                                  "dashboard.html", "dashboard.py", "compose.yaml", "compose.lan.yaml"]
    private static let mpqs = ["dbc.MPQ", "terrain.MPQ", "model.MPQ", "texture.MPQ", "wmo.MPQ", "patch.MPQ", "patch-2.MPQ"]

    private init() {}

    // MARK: - Settings

    /// `user@address`, as for `ssh`.
    var host: String { UserDefaults.standard.string(forKey: Prefs.homeHostKey)?.trimmingCharacters(in: .whitespaces) ?? "" }
    var keyPath: String {
        let k = UserDefaults.standard.string(forKey: Prefs.homeKeyKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return k.isEmpty ? Self.defaultKey : k
    }
    var key: URL { URL(fileURLWithPath: (keyPath as NSString).expandingTildeInPath) }
    /// The server's folder; found at the first connection when not set.
    var folder: String { UserDefaults.standard.string(forKey: Prefs.homeDirKey) ?? "" }

    /// Another server or login: its folder is looked for again, its accounts are its own.
    func settingsChanged() {
        UserDefaults.standard.removeObject(forKey: Prefs.homeDirKey)
        accounts = []
        admins = []
        settings = nil
        setUpDone = false
        if !isBusy { phase = .notConfigured }
    }

    /// The dashboard `home-status` keeps, for any browser on the network.
    var dashboard: URL? { address.isEmpty ? nil : URL(string: "http://\(address):8095/") }

    /// The address the game dials and the ports bind to.
    var address: String { host.split(separator: "@").last.map(String.init) ?? host }

    var isSetUp: Bool {
        switch phase {
        case .stopped, .running: true
        case .busy, .failed: setUpDone
        default: false
        }
    }
    var isBusy: Bool {
        switch phase {
        case .busy, .checking: true
        default: false
        }
    }
    var canPlay: Bool { isSetUp && !isBusy && !accounts.isEmpty }
    private var setUpDone = false

    /// What is wrong with the settings, if anything. They end up in shell commands: only the
    /// characters an address, a login and a path need.
    var problem: String? {
        if host.isEmpty { return "Enter the server's login and address." }
        guard host.range(of: #"^([A-Za-z0-9._-]+@)?[0-9]{1,3}(\.[0-9]{1,3}){3}$"#, options: .regularExpression) != nil else {
            return "Enter the login and the server's IP address, as root@192.168.1.10."
        }
        guard key.path.range(of: #"^[A-Za-z0-9/._-]+$"#, options: .regularExpression) != nil else {
            return "The key's path can hold letters, digits, dots, dashes and slashes only."
        }
        guard FileManager.default.fileExists(atPath: key.path) else { return "There is no SSH key at \(keyPath)." }
        return nil
    }

    // MARK: - State

    /// Look again: the connection, the setup, whether the server answers, its accounts.
    func refresh() async {
        guard !isBusy else { return }
        await look()
    }

    private func look() async {
        if let problem {
            phase = host.isEmpty ? .notConfigured : .failed(problem)
            return
        }
        if case .settingUp = phase {} else { phase = .checking }
        let status: [String: String]
        do {
            try await findFolder()
            status = try await probe()
        } catch {
            phase = .unreachable(LocalServer.message(error))
            return
        }
        settings = status["env"] == "yes"
            ? Settings(env: status.filter { $0.key.hasPrefix("env.") }.reduce(into: [:]) { $0[String($1.key.dropFirst(4))] = $1.value })
            : nil
        setUpDone = status["state"] == "done"
        switch status["state"] {
        case "nodocker":
            phase = .noDocker
        case "running":
            phase = .settingUp(status["step"].map { $0.isEmpty ? "Starting…" : $0 } ?? "Starting…")
        case "failed":
            phase = .failed("The setup stopped at: \(status["step"] ?? "?") Show Log has its output.")
        case "done" where status["update"] == "running":
            phase = .updating(status["updatestep"].map { $0.isEmpty ? "Starting…" : $0 } ?? "Starting…")
        case "done":
            updateFailed = status["update"] == "failed"
                ? "The last update stopped at: \(status["updatestep"] ?? "?") The old server was put back. Show Log has its output."
                : nil
            let up = status["realmd"] == "healthy" && status["mangosd"] == "healthy"
            phase = up ? .running : .stopped
            await syncScripts()
            await loadBackups()
            if up { await loadAccounts() }
        default:
            phase = .notSetUp
        }
    }

    /// One look at everything, as `key=value` lines.
    private func probe() async throws -> [String: String] {
        let script = """
            command -v docker >/dev/null || { echo state=nodocker; exit 0; }
            cd \(folder) 2>/dev/null || { echo state=none; exit 0; }
            if [ -f .setup-done ]; then echo state=done
            elif [ -f .setup-pid ] && kill -0 "$(cat .setup-pid)" 2>/dev/null; then echo state=running
            elif [ -f .setup-failed ]; then echo state=failed
            else echo state=none; fi
            echo "step=$(cat .setup-step 2>/dev/null)"
            if [ -f .update-pid ] && kill -0 "$(cat .update-pid)" 2>/dev/null; then echo update=running
            elif [ -f .update-failed ]; then echo update=failed; fi
            echo "updatestep=$(cat .update-step 2>/dev/null)"
            [ -f .env ] && { echo env=yes; sed -n 's/^[A-Z_][A-Z_]*=/env.&/p' .env; }
            for s in realmd mangosd; do
              echo "$s=$(docker inspect -f '{{.State.Health.Status}}' \(Self.project)-$s-1 2>/dev/null)"
            done
            """
        var out: [String: String] = [:]
        for line in try await ssh(script, quiet: true).split(whereSeparator: \.isNewline) {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] } else if kv.count == 1 { out[kv[0]] = "" }
        }
        return out
    }

    /// The folder on the server, once: Unraid's appdata share if there is one, else the login's home.
    func findFolder() async throws {
        guard folder.isEmpty else { return }
        let found = try await ssh(#"if [ -d /mnt/user/appdata ]; then echo /mnt/user/appdata/azeroth-survivors-cmangos; else echo "$HOME/azeroth-survivors-cmangos"; fi"#,
                                  quiet: true)
        guard found.range(of: #"^/[A-Za-z0-9/._-]+/azeroth-survivors-cmangos$"#, options: .regularExpression) != nil else {
            throw ServerError("The server's home folder has an unusual path: \(found)")
        }
        UserDefaults.standard.set(found, forKey: Prefs.homeDirKey)
    }

    // MARK: - Setup

    /// Copy the recipe and the game files, then start the setup on the server and return; it
    /// carries on there.
    func setUp() async {
        guard !isBusy, problem == nil else { return }
        do {
            try await findFolder()
            let data = Paths.data
            let files = Self.mpqs.map { data.appendingPathComponent($0) }
            if let missing = files.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
                throw ServerError("The game files are missing \(missing.lastPathComponent). Verify them in the Game menu.")
            }
            guard let recipe = Bundle.main.url(forResource: "Server", withExtension: nil)?.appendingPathComponent("CMaNGOS"),
                  FileManager.default.fileExists(atPath: recipe.path) else {
                throw ServerError("The app is missing its server files. Reinstall it.")
            }
            phase = .busy("Copying the server's recipe…")
            try await ssh("mkdir -p \(folder)/storage/client-data/Data")
            try await rsync([recipe.path + "/"])
            let bots = self.bots ?? 100
            try await ssh("cd \(folder) && printf 'LAN_IP=%s\\nBOTS=%s\\nBOT_ACCOUNTS=%s\\n' \(address) \(bots) \(Self.accounts(for: bots)) > .env")
            phase = .busy("Copying the game files the maps are read from (about 4 GB)…")
            try await rsync(files.map(\.path), into: "storage/client-data/Data/")
            try await ssh("cd \(folder) && rm -f .setup-done .setup-failed .setup-step && (nohup ./home-setup > setup.log 2>&1 < /dev/null &)")
            phase = .settingUp("Starting…")
        } catch {
            phase = .failed(LocalServer.message(error))
        }
    }

    // MARK: - Start and stop

    func start() async {
        guard isSetUp, !isBusy, phase != .running else { return }
        await run("Starting the server…") {
            try await self.stopOther()
            try await self.compose("up -d database realmd mangosd")
            try await self.waitHealthy(minutes: 15)
        }
    }

    func stop() async {
        guard isSetUp, !isBusy else { return }
        // The dashboard keeps running, to say the game is stopped.
        await run("Stopping the server…") { try await self.compose("stop realmd mangosd database") }
    }

    func restart() async {
        guard isSetUp, !isBusy else { return }
        await run("Restarting the server…") {
            try await self.stopOther()
            try await self.compose("up -d database realmd mangosd")
            try await self.compose("restart realmd mangosd")
            try await self.waitHealthy(minutes: 15)
        }
    }

    /// The bots and rates into the server's `.env`; the game server restarts with them (new bots
    /// are made on the way).
    func apply(_ new: Settings) async {
        guard isSetUp, !isBusy, (0...2000).contains(new.bots) else { return }
        await run("Restarting the server with the new settings…") {
            let env = "\(self.folder)/.env"
            let pairs = new.env
            // Every value is digits and dots, every key capitals: safe in the shell as they are.
            let delete = pairs.map { "-e '/^\($0.0)=/d'" }.joined(separator: " ")
            let lines = pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "\\n")
            try await self.ssh("sed -i \(delete) \(env) && printf '\(lines)\\n' >> \(env)")
            try await self.stopOther()
            try await self.compose("up -d database realmd mangosd")
            try await self.waitHealthy(minutes: 30)
        }
    }

    /// The Pandaria server beside this one takes the same ports: it stops first.
    private func stopOther() async throws {
        let other = PandariaServer.folder(beside: folder)
        try await ssh("[ ! -x \(other)/home-compose ] || \(other)/home-compose stop authserver worldserver database")
        PandariaServer.shared.otherStarted()
    }

    /// Each bot account holds nine characters, with room to spare.
    nonisolated fileprivate static func accounts(for bots: Int) -> Int { max(20, bots / 9 + 10) }

    /// A step that ends on a fresh look at the server, or on why it failed.
    private func run(_ what: String, _ body: @escaping () async throws -> Void) async {
        phase = .busy(what)
        do {
            try await body()
            await look()
        } catch {
            phase = .failed(LocalServer.message(error))
        }
    }

    private func waitHealthy(minutes: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let s = try await probe()
            if s["realmd"] == "healthy", s["mangosd"] == "healthy" { return }
            for name in ["realmd", "mangosd"] where s[name] == "unhealthy" || s[name] == "" {
                // Gone or stopped: the end of its log says why.
                let state = try? await ssh("docker inspect -f '{{.State.Status}}' \(Self.project)-\(name)-1", quiet: true)
                if state == "exited" || state == "dead" {
                    throw ServerError("The server's \(name) stopped while starting. Show Log has its output.")
                }
            }
        }
        throw ServerError("The server did not start in \(minutes) minutes.")
    }

    // MARK: - Accounts

    func account(_ name: String, password: String, changePassword: Bool = false, admin: Bool = false) async -> String? {
        guard phase == .running else { return "The server is not running." }
        do {
            let sql = try await LocalServer.accountSQL(name, password: password, changePassword: changePassword)
            try await mariadb(stdin: sql)
        } catch {
            let why = LocalServer.message(error)
            return why.contains("Duplicate entry") ? "An account named \(name) already exists." : why
        }
        if !changePassword, admin, let why = await setAdmin(name, true) { return why }
        await loadAccounts()
        return nil
    }

    func setAdmin(_ name: String, _ on: Bool) async -> String? {
        guard let sql = LocalServer.adminSQL(name, on, vmangos: false) else { return "That account name is not allowed." }
        do {
            try await mariadb(stdin: sql)
        } catch {
            return LocalServer.message(error)
        }
        await loadAccounts()
        return nil
    }

    private func loadAccounts() async {
        guard let out = try? await mariadb(["-N", "-B", "-e", "\"\(LocalServer.accountsQuery(vmangos: false))\""], quiet: true)
        else { return }
        (accounts, admins) = LocalServer.parseAccounts(out, adminLevel: adminLevel)
    }

    @discardableResult
    private func mariadb(_ args: [String] = [], stdin: String? = nil, quiet: Bool = false) async throws -> String {
        try await ssh((["docker exec -i \(Self.project)-database-1 mariadb -umangos -pmangos"] + args + [Self.realmDB])
                        .joined(separator: " "), stdin: stdin, quiet: quiet)
    }

    // MARK: - Backups

    /// The recipe's scripts, so a server set up by an older app runs this one's (the nightly
    /// backup among them), and the backup's schedule, which `schedule` leaves alone once there.
    private func syncScripts() async {
        guard let recipe = Bundle.main.url(forResource: "Server", withExtension: nil)?.appendingPathComponent("CMaNGOS")
        else { return }
        let scripts = Self.scripts.map { recipe.appendingPathComponent($0).path }
        guard scripts.allSatisfy(FileManager.default.fileExists(atPath:)) else { return }
        try? await rsync(scripts)
        let out = try? await ssh("\(folder)/home-backup schedule; \(folder)/home-status schedule; "
                                 + "test -s \(folder)/storage/dashboard/azeroth.png -a -s \(folder)/storage/dashboard/kalimdor.png && echo maps",
                                 quiet: true)
        if let out, !out.contains("maps") { await sendWorldMaps() }
    }

    /// The dashboard's password (`home-status password`, the password on standard input), asked
    /// for before it starts, stops or changes a server; a new one signs everyone out.
    func setDashboardPassword(_ password: String) async -> String? {
        do {
            _ = try await ssh("\(folder)/home-status password", stdin: password)
            return nil
        } catch {
            return LocalServer.message(error)
        }
    }

    /// The dashboard's two world maps, drawn by the game binary from this Mac's game files, as no
    /// map art ships with the app.
    private func sendWorldMaps() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("world-maps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Without them the page says where they come from; the next refresh tries again.
        guard (try? await Docker.run(Paths.gameBinary, ["--world-maps", dir.path, Paths.data.path], quiet: true)) != nil,
              (try? await rsync(["azeroth.png", "kalimdor.png"].map { dir.appendingPathComponent($0).path }, into: "storage/dashboard/")) != nil
        else { return }
        _ = try? await ssh("chmod a+r \(folder)/storage/dashboard/*.png", quiet: true)
    }

    private func loadBackups() async {
        guard let out = try? await ssh("\(folder)/home-backup list", quiet: true) else { return }
        backups = Self.parseBackups(out)
    }

    /// `name bytes epoch` lines, as `home-backup list` prints them.
    nonisolated static func parseBackups(_ out: String) -> [Backup] {
        out.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ")
            guard f.count == 3, let bytes = Int(f[1]), let epoch = Double(f[2]),
                  f[0].range(of: #"^[0-9-]+(-before-restore)?\.sql\.gz$"#, options: .regularExpression) != nil
            else { return nil }
            return Backup(name: String(f[0]), bytes: bytes, date: Date(timeIntervalSince1970: epoch))
        }
    }

    func backUpNow() async {
        guard isSetUp, !isBusy else { return }
        await run("Backing up the accounts and characters…") {
            try await self.ssh("\(self.folder)/home-backup now")
        }
    }

    /// The game server stops, the backup loads over the accounts and characters (a backup of the
    /// state it replaces is taken first), and the server starts again.
    func restore(_ backup: Backup) async {
        guard isSetUp, !isBusy, backups.contains(backup) else { return }
        await run("Restoring the backup of \(backup.date.formatted(date: .abbreviated, time: .shortened))…") {
            try await self.ssh("\(self.folder)/home-backup restore \(backup.name)")
            try await self.waitHealthy(minutes: 15)
        }
    }

    // MARK: - Stats

    /// One look at who is on and what the game server takes, for Settings › Home Server.
    func loadStats() async {
        guard phase == .running else { stats = nil; return }
        let p = Self.project
        let script = """
            echo "docker=$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' \(p)-mangosd-1)"
            echo "since=$(docker inspect -f '{{.State.StartedAt}}' \(p)-mangosd-1)"
            echo "machine=$(free -b | awk '/^Mem:/ {print $2"|"$7}')|$(nproc)"
            docker exec \(p)-database-1 mariadb -umangos -pmangos -N -e "SELECT CONCAT('player=', c.name, '|', c.level) FROM classiccharacters.characters c JOIN classicrealmd.account a ON a.id = c.account WHERE c.online = 1 AND a.username NOT LIKE 'RNDBOT%' ORDER BY c.name; SELECT CONCAT('bots=', COUNT(*)) FROM classiccharacters.characters c JOIN classicrealmd.account a ON a.id = c.account WHERE c.online = 1 AND a.username LIKE 'RNDBOT%'"
            """
        guard let out = try? await ssh(script, quiet: true) else { return }
        stats = Self.parseStats(out)
    }

    nonisolated static func parseStats(_ out: String) -> Stats? {
        var players: [Stats.Player] = []
        var kv: [String: String] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            if pair[0] == "player" {
                let f = pair[1].split(separator: "|")
                if f.count == 2, let level = Int(f[1]) { players.append(Stats.Player(name: String(f[0]), level: level)) }
            } else {
                kv[pair[0]] = pair[1]
            }
        }
        // `49.29%|5.419GiB / 22.92GiB`
        let docker = (kv["docker"] ?? "").split(separator: "|").map(String.init)
        let machine = (kv["machine"] ?? "").split(separator: "|").map(String.init)
        guard docker.count == 2, machine.count == 3,
              let percent = Double(docker[0].replacingOccurrences(of: "%", with: "")),
              let total = Int64(machine[0]), let available = Int64(machine[1]), let cores = Int(machine[2])
        else { return nil }
        let since = kv["since"].flatMap { s -> Date? in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            // Docker gives nanoseconds; the formatter reads up to milliseconds.
            let trimmed = s.replacingOccurrences(of: #"(\.\d{3})\d*Z$"#, with: "$1Z", options: .regularExpression)
            return f.date(from: trimmed)
        }
        return Stats(players: players, bots: Int(kv["bots"] ?? "") ?? 0, cores: percent / 100, machineCores: cores,
                     memory: bytes(docker[1].components(separatedBy: " / ").first ?? ""),
                     machineMemory: total, machineAvailable: available, since: since)
    }

    /// Docker's `5.419GiB`, `512MiB`, `900kB`.
    nonisolated static func bytes(_ s: String) -> Int64 {
        let units: [(String, Double)] = [("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1024), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1)]
        for (u, m) in units where s.hasSuffix(u) {
            return Int64((Double(s.dropLast(u.count)) ?? 0) * m)
        }
        return 0
    }

    // MARK: - Updates

    /// The commits the server was built from and the newest of each, read from GitHub there.
    func checkForUpdates() async {
        guard isSetUp, !isBusy else { return }
        await run("Checking for updates…") {
            await self.syncScripts()
            self.software = Self.parseSoftware(try await self.ssh("\(self.folder)/home-update check", quiet: true))
        }
    }

    /// `name built newest` lines, then `mmaps`, `blocked` and `updated`, as `home-update check`
    /// prints them.
    nonisolated static func parseSoftware(_ out: String) -> Software? {
        var repos: [Software.Repo] = []
        var flags: [String: String] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ").map(String.init)
            if f.count == 3 {
                repos.append(Software.Repo(name: f[0], built: f[1], newest: f[2]))
            } else if f.count == 2 {
                flags[f[0]] = f[1]
            } else if f.count == 1 {
                flags[f[0]] = ""
            }
        }
        guard !repos.isEmpty,
              repos.allSatisfy({ $0.newest.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil })
        else { return nil }
        return Software(repos: repos, mmaps: flags["mmaps"] == "yes", blocked: flags["blocked"] == "yes",
                        updated: flags["updated"].flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    /// Copy this app's recipe, then start the update on the server and return; it carries on there.
    /// It backs up first, and puts the old server back if anything fails.
    func update() async {
        guard isSetUp, !isBusy, software?.blocked != true else { return }
        do {
            guard let recipe = Bundle.main.url(forResource: "Server", withExtension: nil)?.appendingPathComponent("CMaNGOS"),
                  FileManager.default.fileExists(atPath: recipe.path) else {
                throw ServerError("The app is missing its server files. Reinstall it.")
            }
            phase = .busy("Copying the server's recipe…")
            try await rsync([recipe.path + "/"])
            try await ssh("cd \(folder) && rm -f .update-done .update-failed .update-step && (nohup ./home-update run > update.log 2>&1 < /dev/null &)")
            updateFailed = nil
            software = nil
            phase = .updating("Starting…")
        } catch {
            phase = .failed(LocalServer.message(error))
        }
    }

    // MARK: - Log and removal

    /// The end of one of the server's logs, for the Logs window.
    func log(_ source: LogSource, lines: Int) async throws -> String {
        guard problem == nil else { throw ServerError(problem ?? "") }
        try await findFolder()
        let logs = "\(folder)/storage/mangosd/logs"
        let script: String
        switch source {
        case .homeServer: script = "tail -n \(lines) \(logs)/Server.log 2>/dev/null"
        case .homeDatabase: script = "tail -n \(lines) \(logs)/DBErrors.log 2>/dev/null"
        case .homeRealm: script = "docker logs --timestamps --tail \(lines) \(Self.project)-realmd-1 2>&1"
        case .homeSetup: script = "tail -n \(lines) \(folder)/setup.log 2>/dev/null"
        case .homeUpdate: script = "tail -n \(lines) \(folder)/update.log 2>/dev/null"
        default: return ""
        }
        return try await ssh(script + "; true", quiet: true)
    }

    /// The server's containers, its databases (every character on it), its image and its folder go.
    func remove() async {
        guard !isBusy, !folder.isEmpty, folder.hasSuffix("/azeroth-survivors-cmangos") else { return }
        await run("Removing the server…") {
            try await self.ssh("""
                cd \(self.folder) && { for f in .setup-pid .update-pid; do [ ! -f $f ] || kill "$(cat $f)" 2>/dev/null; done; ./home-compose --profile tools down -v; }
                docker rmi azeroth-survivors-cmangos:1 2>/dev/null
                rm -rf \(self.folder)
                """)
            self.accounts = []
            self.admins = []
        }
    }

    // MARK: - SSH

    /// The private key's public half, to add to the server's authorized keys.
    var publicKey: String? {
        try? String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A new key without a passphrase at the key's path: the launcher signs in unattended.
    func createKey() async -> String? {
        guard !FileManager.default.fileExists(atPath: key.path) else { return nil }
        do {
            try FileManager.default.createDirectory(at: key.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await Docker.run(URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                                 ["-q", "-t", "ed25519", "-N", "", "-C", "azeroth-survivors", "-f", key.path], quiet: true)
            return nil
        } catch {
            return LocalServer.message(error)
        }
    }

    private var sshOptions: [String] {
        ["-i", key.path, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
         "-o", "StrictHostKeyChecking=accept-new", "-o", "ServerAliveInterval=15"]
    }

    @discardableResult
    func ssh(_ script: String, stdin: String? = nil, quiet: Bool = false) async throws -> String {
        try await Docker.run(URL(fileURLWithPath: "/usr/bin/ssh"), sshOptions + [host, script], stdin: stdin, quiet: quiet)
    }

    private func compose(_ args: String) async throws {
        try await ssh("\(folder)/home-compose \(args)")
    }

    /// Copies into the server's folder (`into` a path inside it), by its real path: rsync 3.5 will
    /// not write through a symlink another user owns, as Unraid's exclusive shares are
    /// (`/mnt/user/appdata` -> `../cache/appdata`, owned by nobody).
    private func rsync(_ sources: [String], into sub: String = "") async throws {
        try await rsync(sources, to: folder, named: "azeroth-survivors-cmangos", into: sub)
    }

    /// Copies into `remote`, a folder on the server whose name must be `named`.
    func rsync(_ sources: [String], to remote: String, named: String, into sub: String = "") async throws {
        let real = try await ssh("realpath -e \(remote)", quiet: true)
        guard real.range(of: "^/[A-Za-z0-9/._-]+/\(named)$", options: .regularExpression) != nil else {
            throw ServerError("The server's folder resolves to an unusual path: \(real)")
        }
        try await Docker.run(URL(fileURLWithPath: "/usr/bin/rsync"),
                             ["-a", "--partial", "-e", (["ssh"] + sshOptions).joined(separator: " ")] + sources
                                + ["\(host):\(real)/\(sub)"])
    }
}
