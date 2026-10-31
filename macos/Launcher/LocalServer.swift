import Foundation

/// Classic on this Mac: a 1.12.1 server in Docker, one of two kinds ([`ServerKind`]).
///
/// vmangos comes from vmangos-deploy's prebuilt images. Its files live in
/// `Application Support/Hearthside/Server`: `compose.yaml` (rewritten from the app's copy at
/// every start), `config/` (copied once, then the player's), `storage/` (the extracted maps, logs)
/// and a Docker volume with the databases. Setup reads the terrain from the game's own Data folder
/// in seconds and plays without line of sight or pathing; the full extraction adds them later, in
/// the background, into `storage/extract-full`, swapped in at the next start.
///
/// CMaNGOS with random playerbots is built at setup from the app's recipe (`Server/CMaNGOS`), in
/// `Server-CMaNGOS`, its configs inside the image. Its bots need line of sight and movement maps,
/// so its setup builds them all at once, and it has no quick data and no later extraction.
@MainActor
final class LocalServer: ObservableObject {
    enum Phase: Equatable {
        case checking
        /// No Docker command line found; the launcher links to OrbStack and Docker Desktop.
        case noDocker
        case notSetUp
        /// A step in progress: setup, start, stop, an account.
        case busy(String)
        case stopped
        case running
        case failed(String)
    }

    @Published private(set) var phase: Phase = .checking
    /// The server this Mac plays on; [`select`] changes it.
    @Published private(set) var kind: ServerKind = .current
    /// The full extraction is in place: line of sight and pathing are on.
    @Published private(set) var fullMaps = false
    /// The full extraction is running, since this date.
    @Published private(set) var extractingSince: Date?
    /// The server's accounts, kept across launches so Play knows of them before the server is up.
    @Published private(set) var accounts: [String] = LocalServer.savedAccounts(.current) {
        didSet { UserDefaults.standard.set(accounts, forKey: Self.accountsKey(kind)) }
    }
    /// The accounts with administrator rights: every GM command, bots included.
    @Published private(set) var admins: Set<String> = []
    /// The administrator level: `SEC_ADMINISTRATOR` in each core's `src/shared/Common.h`.
    var adminLevel: Int { kind == .vmangos ? 6 : 3 }

    nonisolated static func folder(_ kind: ServerKind) -> URL {
        Paths.support.appendingPathComponent(kind == .vmangos ? "Server" : "Server-CMaNGOS", isDirectory: true)
    }
    nonisolated static var dir: URL { folder(.current) }
    nonisolated static var log: URL { Paths.logs.appendingPathComponent("server.log") }
    static let shared = LocalServer()
    static let address = "127.0.0.1"
    private static let extractContainer = "azeroth-survivors-extract"

    private var dir: URL { Self.folder(kind) }
    private var marker: URL { dir.appendingPathComponent(".setup-done") }
    private var fullMarker: URL { dir.appendingPathComponent("storage/.full-maps") }
    private var staging: URL { dir.appendingPathComponent("storage/extract-full") }
    private var live: URL { dir.appendingPathComponent("storage/mangosd/extracted-data") }
    /// The quick data, kept beside the full data in case it fails to start.
    private var quick: URL { dir.appendingPathComponent("storage/extract-quick") }
    private var mangosConf: URL { dir.appendingPathComponent("config/mangosd.conf") }
    /// The realm database: accounts and the realm list.
    private var realmDB: String { kind == .vmangos ? "realmd" : "classicrealmd" }

    private static func accountsKey(_ kind: ServerKind) -> String {
        kind == .vmangos ? "localAccounts" : "localAccounts-\(kind.rawValue)"
    }
    private static func savedAccounts(_ kind: ServerKind) -> [String] {
        UserDefaults.standard.stringArray(forKey: accountsKey(kind)) ?? []
    }

    var isSetUp: Bool { FileManager.default.fileExists(atPath: marker.path) }
    /// Whether this kind has the background full extraction (vmangos only).
    var hasFullExtraction: Bool { kind == .vmangos }

    /// Play on the other kind of server from now on; the running one keeps running until a start
    /// of this one stops it.
    func select(_ new: ServerKind) async {
        guard new != kind, !isBusy else { return }
        UserDefaults.standard.set(new.rawValue, forKey: Prefs.serverKindKey)
        kind = new
        accounts = Self.savedAccounts(new)
        admins = []
        extractingSince = nil
        phase = .checking
        await refresh()
    }

    private init() {
        // A helper that quits before reading its stdin must not take the launcher down with it.
        signal(SIGPIPE, SIG_IGN)
    }
    var isBusy: Bool { if case .busy = phase { true } else { false } }

    // MARK: - State

    /// Look again: Docker, the setup, whether the server answers, the full extraction.
    func refresh() async {
        guard !isBusy else { return }
        fullMaps = FileManager.default.fileExists(atPath: fullMarker.path)
        guard Docker.binary != nil else { phase = .noDocker; return }
        guard isSetUp else { phase = .notSetUp; return }
        guard await Docker.engineUp() else { phase = .stopped; return }
        if hasFullExtraction { await checkExtraction() }
        phase = await healthy() ? .running : .stopped
        if phase == .running { await loadAccounts() }
    }

    // MARK: - Setup

    /// Everything once: images, the quick map extraction, the first start (which builds the world
    /// database), then `running`.
    func setUp() async {
        guard !isBusy else { return }
        do {
            try await startEngine()
            try writeFiles(fresh: true)
            switch kind {
            case .vmangos:
                phase = .busy("Downloading the server (about 1 GB)…")
                try await compose(["pull", "database", "realmd", "mangosd"])
                phase = .busy("Reading the maps from the game files…")
                try await compose(["--profile", "tools", "run", "--rm", "-T", "extract-maps"])
                try await stopOther()
                phase = .busy("Building the world (a few minutes, the first time only)…")
            case .cmangos:
                phase = .busy("Downloading the database and the map reader (about 800 MB)…")
                try await compose(["--profile", "tools", "pull", "database", "extract-maps"])
                phase = .busy("Building the server from source (about 15 minutes, once)…")
                try await compose(["build", "realmd"])
                phase = .busy("Reading the maps from the game files…")
                try await compose(["--profile", "tools", "run", "--rm", "-T", "extract-maps"])
                phase = .busy("Building the movement maps the bots walk on (about 10 minutes, once)…")
                try await compose(["--profile", "tools", "run", "--rm", "-T", "build-mmaps"])
                phase = .busy("Building the world database…")
                try await compose(["--profile", "tools", "run", "--rm", "-T", "install"])
                try await stopOther()
                phase = .busy("Creating the bots (a few minutes, the first time only)…")
            }
            try await compose(["up", "-d", "database", "realmd", "mangosd"])
            try await waitHealthy(minutes: 30)
            FileManager.default.createFile(atPath: marker.path, contents: nil)
            phase = .running
            await loadAccounts()
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    // MARK: - Start and stop

    /// Start the server and wait until it takes logins (about a minute: the database checks its
    /// migrations at every start).
    func start() async {
        guard isSetUp, !isBusy, phase != .running else { return }
        do {
            try await startEngine()
            try writeFiles(fresh: false)
            var swapped = false
            if hasFullExtraction {
                await checkExtraction()
                swapped = try swapInFullMaps()
            }
            try await stopOther()
            phase = .busy("Starting the server…")
            do {
                try await compose(["up", "-d", "database", "realmd", "mangosd"])
                try await waitHealthy(minutes: 10)
            } catch where swapped {
                // The new data does not run: back to the quick data, which did.
                Self.append("the full maps failed to start: back to the quick maps")
                _ = try? await compose(["stop"])
                try revertToQuickMaps()
                try await compose(["up", "-d", "database", "realmd", "mangosd"])
                try await waitHealthy(minutes: 10)
                phase = .running
                await loadAccounts()
                phase = .failed("The full maps did not work, so the server went back to the quick maps. The log is in ~/Library/Logs/\(Paths.appName)/server.log.")
                return
            }
            phase = .running
            await loadAccounts()
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    func stop() async {
        guard isSetUp, !isBusy, await Docker.engineUp() else { return }
        phase = .busy("Stopping the server…")
        do {
            try await compose(["stop"])
            phase = .stopped
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    /// For the launcher quitting: stop without waiting (the containers save as they stop).
    func stopDetached() {
        guard isSetUp, let docker = Docker.binary else { return }
        let p = Docker.process(docker, ["compose", "--project-directory", dir.path, "stop"])
        try? p.run()
    }

    /// The other kind takes the same ports: stop it if it runs.
    private func stopOther() async throws {
        guard let other = ServerKind.allCases.first(where: { $0 != kind }) else { return }
        let otherDir = Self.folder(other)
        guard FileManager.default.fileExists(atPath: otherDir.appendingPathComponent("compose.yaml").path),
              let running = try? await compose(["ps", "-q"], quiet: true, directory: otherDir),
              !running.isEmpty
        else { return }
        phase = .busy("Stopping the \(other.label) server…")
        try await compose(["stop"], directory: otherDir)
    }

    // MARK: - Accounts

    /// Create an account, or with `changePassword` give one a new password. `nil` when done, else
    /// why not.
    func account(_ name: String, password: String, changePassword: Bool = false, admin: Bool = false) async -> String? {
        guard phase == .running else { return "The server is not running." }
        let sql: String
        do {
            sql = try await Self.accountSQL(name, password: password, changePassword: changePassword)
        } catch {
            return Self.message(error)
        }
        do {
            try await compose(["exec", "-T", "database", "mariadb", "-umangos", "-pmangos", realmDB], stdin: sql)
        } catch {
            if Self.message(error).contains("Duplicate entry") { return "An account named \(name) already exists." }
            return Self.message(error)
        }
        if !changePassword {
            remember(name)
            if admin, let why = await setAdmin(name, true) { return why }
        }
        await loadAccounts()
        return nil
    }

    /// Give an account administrator rights, or take them; it takes effect at its next login.
    func setAdmin(_ name: String, _ on: Bool) async -> String? {
        guard let sql = Self.adminSQL(name, on, vmangos: kind == .vmangos) else { return "That account name is not allowed." }
        do {
            try await compose(["exec", "-T", "database", "mariadb", "-umangos", "-pmangos", realmDB], stdin: sql)
        } catch {
            return Self.message(error)
        }
        await loadAccounts()
        return nil
    }

    private func loadAccounts() async {
        guard let out = try? await compose(
            ["exec", "-T", "database", "mariadb", "-umangos", "-pmangos", "-N", "-B", realmDB, "-e",
             Self.accountsQuery(vmangos: kind == .vmangos)],
            quiet: true) else { return }
        (accounts, admins) = Self.parseAccounts(out, adminLevel: adminLevel)
    }

    // MARK: - Account SQL, shared with the home server

    /// The game's own account SQL (`--account-sql`): it hashes the password the way the servers do.
    nonisolated static func accountSQL(_ name: String, password: String, changePassword: Bool) async throws -> String {
        var args = ["--account-sql"]
        if changePassword { args.append("password") }
        return try await Docker.run(Paths.gameBinary, args, stdin: "\(name)\n\(password)\n")
    }

    /// Administrator rights on or off; `nil` for a name `--account-sql` would refuse, as it is
    /// spliced into the SQL.
    nonisolated static func adminSQL(_ name: String, _ on: Bool, vmangos: Bool) -> String? {
        guard !name.isEmpty, name.count <= 16, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        let user = name.uppercased()
        let level = on ? (vmangos ? 6 : 3) : 0
        var sql = "UPDATE account SET gmlevel = \(level) WHERE username = '\(user)';"
        if vmangos {
            // vmangos takes an account's level from `account_access` (`WorldSocket.cpp`), one row per
            // realm, `-1` for all; `account.gmlevel` only mirrors it. CMaNGOS reads `gmlevel`.
            sql += """

                DELETE aa FROM account_access aa JOIN account a ON a.id = aa.id WHERE a.username = '\(user)';
                \(on ? "INSERT INTO account_access (id, gmlevel, RealmID) SELECT id, \(level), -1 FROM account WHERE username = '\(user)';" : "")
                """
        }
        return sql
    }

    /// Each account and its level. CMaNGOS: the random bots' own accounts
    /// (`AiPlayerbot.RandomBotAccountPrefix`) stay out.
    nonisolated static func accountsQuery(vmangos: Bool) -> String {
        vmangos
            ? "SELECT a.username, COALESCE(MAX(aa.gmlevel), 0) FROM account a LEFT JOIN account_access aa ON aa.id = a.id GROUP BY a.id, a.username ORDER BY a.id"
            : "SELECT username, gmlevel FROM account WHERE username NOT LIKE 'RNDBOT%' ORDER BY id"
    }

    nonisolated static func parseAccounts(_ out: String, adminLevel: Int) -> ([String], Set<String>) {
        let rows = out.split(whereSeparator: \.isNewline).map { $0.split(separator: "\t").map(String.init) }
        return (rows.compactMap(\.first), Set(rows.filter { $0.count == 2 && (Int($0[1]) ?? 0) >= adminLevel }.map { $0[0] }))
    }

    /// The login screen offers the first account's name, as if it had been remembered there.
    private func remember(_ name: String) {
        let file = Paths.gameConfig.appendingPathComponent("account")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try? FileManager.default.createDirectory(at: Paths.gameConfig, withIntermediateDirectories: true)
        try? name.uppercased().write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - Full extraction

    /// Extract line of sight and pathing in the background, into a staging folder; the server
    /// keeps running on the quick data meanwhile.
    func extractFull() async {
        guard isSetUp, extractingSince == nil, !isBusy else { return }
        do {
            try await startEngine()
            try writeFiles(fresh: false)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            _ = try? await Docker.run(Docker.binary!, ["rm", "-f", Self.extractContainer], quiet: true)
            try await compose(["--profile", "tools", "run", "-d", "--name", Self.extractContainer, "extract-client-data"],
                              project: "azeroth-survivors-tools")
            extractingSince = Date()
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    func cancelExtraction() async {
        _ = try? await Docker.run(Docker.binary!, ["rm", "-f", Self.extractContainer], quiet: true)
        try? FileManager.default.removeItem(at: staging)
        extractingSince = nil
    }

    /// Follow the extraction container: still running, finished (staged for the next start), or
    /// failed.
    private func checkExtraction() async {
        guard let docker = Docker.binary,
              let out = try? await Docker.run(docker, ["inspect", "-f", "{{.State.Status}} {{.State.ExitCode}} {{.State.StartedAt}}",
                                                       Self.extractContainer], quiet: true)
        else { extractingSince = nil; return }
        let parts = out.split(separator: " ").map(String.init)
        guard parts.count >= 3 else { return }
        if parts[0] == "running" {
            extractingSince = ISO8601DateFormatter.fractional.date(from: parts[2]) ?? extractingSince ?? Date()
            return
        }
        extractingSince = nil
        let ok = parts[1] == "0"
        if !ok {
            let tail = (try? await Docker.run(docker, ["logs", "--tail", "15", Self.extractContainer], quiet: true)) ?? ""
            Self.append("full extraction failed:\n\(tail)")
            try? FileManager.default.removeItem(at: staging)
        } else {
            FileManager.default.createFile(atPath: staging.appendingPathComponent(".complete").path, contents: nil)
        }
        _ = try? await Docker.run(docker, ["rm", Self.extractContainer], quiet: true)
        if !ok { phase = .failed("The full map extraction failed. Its log is in ~/Library/Logs/\(Paths.appName)/server.log.") }
    }

    /// With the server stopped, a completed full extraction replaces the quick data, which is kept
    /// aside, and turns line of sight and pathing on. `true` when it did.
    private func swapInFullMaps() throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: staging.appendingPathComponent(".complete").path) else { return false }
        try? fm.removeItem(at: staging.appendingPathComponent(".complete"))
        try? fm.removeItem(at: quick)
        try fm.moveItem(at: live, to: quick)
        try fm.moveItem(at: staging, to: live)
        try setFullMaps(true)
        fm.createFile(atPath: fullMarker.path, contents: nil)
        fullMaps = true
        return true
    }

    /// The full data failed to start: the quick data comes back, line of sight and pathing off.
    private func revertToQuickMaps() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: quick.path) else { return }
        try? fm.removeItem(at: live)
        try fm.moveItem(at: quick, to: live)
        try setFullMaps(false)
        try? fm.removeItem(at: fullMarker)
        fullMaps = false
    }

    /// `vmap.*` and `mmap.enabled` in `mangosd.conf`, on with the full data, off without.
    private func setFullMaps(_ on: Bool) throws {
        let v = on ? "1" : "0"
        try setConf(["vmap.enableLOS": v, "vmap.enableHeight": v, "vmap.enableIndoorCheck": v, "mmap.enabled": v])
    }

    /// Set `key = value` lines of `mangosd.conf`, where they stand.
    private func setConf(_ values: [String: String]) throws {
        var text = try String(contentsOf: mangosConf, encoding: .utf8)
        for (key, value) in values {
            text = text.replacingOccurrences(of: "(?m)^\(NSRegularExpression.escapedPattern(for: key)) = .*$",
                                             with: "\(key) = \(value)", options: .regularExpression)
        }
        try text.write(to: mangosConf, atomically: true, encoding: .utf8)
    }

    /// Settings later versions of the app changed in the shipped `mangosd.conf`, applied once to a
    /// config copied before them: `config/.version` counts which are in.
    private func migrateConf() throws {
        let marker = dir.appendingPathComponent("config/.version")
        let done = Int((try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 1
        // 2: an administrator plays as a player until they switch a cheat on (AzerothAdmin).
        if done < 2 { try setConf(["GM.LoginState": "0", "GM.Visible": "1", "GM.CheatGod": "0"]) }
        try "2".write(to: marker, atomically: true, encoding: .utf8)
    }

    // MARK: - Removal

    /// The server, its databases (every local character) and its images go.
    func remove() async {
        guard !isBusy else { return }
        phase = .busy("Removing the server…")
        if await Docker.engineUp() {
            if hasFullExtraction { await cancelExtraction() }
            _ = try? await compose(["down", "-v", "--rmi", "all"])
        }
        try? FileManager.default.removeItem(at: dir)
        fullMaps = false
        accounts = []
        admins = []
        phase = Docker.binary == nil ? .noDocker : .notSetUp
    }

    // MARK: - Docker plumbing

    private func startEngine() async throws {
        if await Docker.engineUp() { return }
        phase = .busy("Starting \(Docker.engineName)…")
        Docker.launchEngine()
        for _ in 0..<90 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if await Docker.engineUp() { return }
        }
        throw ServerError("\(Docker.engineName) did not start. Open it once, then try again.")
    }

    /// The app's compose file always; the configs and folders only when missing (or `fresh`).
    /// CMaNGOS: its whole recipe, every time (its configs live in the image).
    private func writeFiles(fresh: Bool) throws {
        let fm = FileManager.default
        guard let bundled = Bundle.main.url(forResource: "Server", withExtension: nil) else {
            throw ServerError("The app is missing its server files. Reinstall it.")
        }
        if kind == .cmangos {
            for sub in ["storage/data", "storage/client-data", "storage/mangosd/logs", "storage/realmd/logs"] {
                try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
            }
            let recipe = bundled.appendingPathComponent("CMaNGOS")
            for name in try fm.contentsOfDirectory(atPath: recipe.path) {
                let dest = dir.appendingPathComponent(name)
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: recipe.appendingPathComponent(name), to: dest)
            }
            return
        }
        for sub in ["config", "storage/mangosd/client-data", "storage/mangosd/extracted-data", "storage/mangosd/logs",
                    "storage/mangosd/honor", "storage/realmd/logs", "storage/database/custom-sql"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let compose = dir.appendingPathComponent("compose.yaml")
        try? fm.removeItem(at: compose)
        try fm.copyItem(at: bundled.appendingPathComponent("compose.yaml"), to: compose)
        for name in ["mangosd.conf", "realmd.conf"] {
            let dest = dir.appendingPathComponent("config/\(name)")
            if fresh { try? fm.removeItem(at: dest) }
            if !fm.fileExists(atPath: dest.path) {
                try fm.copyItem(at: bundled.appendingPathComponent(name), to: dest)
            }
        }
        if fresh {
            try? fm.removeItem(at: fullMarker)
            // A fresh copy already holds every migration.
            try "2".write(to: dir.appendingPathComponent("config/.version"), atomically: true, encoding: .utf8)
        }
        try migrateConf()
    }

    @discardableResult
    private func compose(_ args: [String], stdin: String? = nil, quiet: Bool = false,
                         project: String? = nil, directory: URL? = nil) async throws -> String {
        guard let docker = Docker.binary else { throw ServerError("Docker is not installed.") }
        let name = project.map { ["-p", $0] } ?? []
        return try await Docker.run(docker, ["compose", "--project-directory", (directory ?? dir).path] + name + args,
                                    stdin: stdin, quiet: quiet)
    }

    private func healthy() async -> Bool {
        guard let out = try? await compose(["ps", "--format", "{{.Service}} {{.Health}}"], quiet: true) else { return false }
        let healthy = Set(out.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let p = line.split(separator: " ")
            return p.count == 2 && p[1] == "healthy" ? String(p[0]) : nil
        })
        return healthy.isSuperset(of: ["realmd", "mangosd"])
    }

    /// Until realmd and mangosd answer; a container that stops on the way ends the wait with the
    /// end of its log.
    private func waitHealthy(minutes: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if await healthy() { return }
            let out = (try? await compose(["ps", "-a", "--format", "{{.Service}} {{.State}}"], quiet: true)) ?? ""
            for line in out.split(whereSeparator: \.isNewline) {
                let p = line.split(separator: " ").map(String.init)
                guard p.count == 2, p[1] == "exited" || p[1] == "dead" else { continue }
                let tail = (try? await compose(["logs", "--no-color", "--tail", "12", p[0]], quiet: true)) ?? ""
                Self.append("\(p[0]) stopped:\n\(tail)")
                throw ServerError("The server's \(p[0]) stopped while starting. Its log is in ~/Library/Logs/\(Paths.appName)/server.log.")
            }
        }
        throw ServerError("The server did not start in \(minutes) minutes.")
    }

    nonisolated static func append(_ text: String) {
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(text)\n"
        if let h = try? FileHandle(forWritingTo: log) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: log, atomically: true, encoding: .utf8)
        }
    }

    nonisolated static func message(_ error: Error) -> String {
        (error as? ServerError)?.message ?? error.localizedDescription
    }
}

struct ServerError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// The Docker command line, wherever OrbStack or Docker Desktop put it.
enum Docker {
    static var binary: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "\(home)/.orbstack/bin/docker",
                "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
                "/Applications/Docker.app/Contents/Resources/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private static var orbStack: Bool { FileManager.default.fileExists(atPath: "/Applications/OrbStack.app") }
    static var engineName: String { orbStack ? "OrbStack" : "Docker" }

    static func engineUp() async -> Bool {
        guard let docker = binary else { return false }
        return (try? await run(docker, ["info", "--format", "{{.ServerVersion}}"], quiet: true)) != nil
    }

    /// Start the engine's app in the background, OrbStack first.
    static func launchEngine() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-a", orbStack ? "OrbStack" : "Docker"]
        try? p.run()
    }

    static func process(_ exe: URL, _ args: [String]) -> Process {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        // A missing working directory would fail the launch itself; compose is given the folder.
        if FileManager.default.fileExists(atPath: LocalServer.dir.path) { p.currentDirectoryURL = LocalServer.dir }
        var env = ProcessInfo.processInfo.environment
        // An app started from Finder has a bare PATH; compose and the credential helpers live
        // beside the docker binary.
        let dirs: [String?] = [binary?.deletingLastPathComponent().path, "/usr/local/bin", "/opt/homebrew/bin",
                    "\(FileManager.default.homeDirectoryForCurrentUser.path)/.orbstack/bin", env["PATH"]]
        env["PATH"] = dirs.compactMap { $0 }.joined(separator: ":")
        env["CLIENT_DATA"] = Paths.data.path
        p.environment = env
        return p
    }

    /// Run to the end; stdout on success, else a `ServerError` with the end of the output. Every
    /// run but the `quiet` ones (status polls) goes to `server.log`.
    @discardableResult
    static func run(_ exe: URL, _ args: [String], stdin: String? = nil, quiet: Bool = false) async throws -> String {
        let p = process(exe, args)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let input = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : input
        let collected = Collected()
        out.fileHandleForReading.readabilityHandler = { h in collected.add(h.availableData, err: false) }
        err.fileHandleForReading.readabilityHandler = { h in collected.add(h.availableData, err: true) }
        // Logged without stdin: it carries the account password.
        let shown = ([exe.lastPathComponent] + args).joined(separator: " ")
        if !quiet { LocalServer.append("$ \(shown)") }
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do {
                try p.run()
            } catch {
                p.terminationHandler = nil
                cont.resume(throwing: error)
                return
            }
            if let stdin {
                input.fileHandleForWriting.write(Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
            }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        collected.add(out.fileHandleForReading.readDataToEndOfFile(), err: false)
        collected.add(err.fileHandleForReading.readDataToEndOfFile(), err: true)
        let (stdout, stderr) = collected.text()
        if !quiet {
            let tail = (stdout + stderr).split(whereSeparator: \.isNewline).suffix(20).joined(separator: "\n")
            LocalServer.append("exit \(status)\(tail.isEmpty ? "" : "\n" + tail)")
        }
        guard status == 0 else {
            let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init)
                ?? stdout.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit code \(status)"
            throw ServerError(last)
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Output gathered from the pipes' handlers, which run on their own queues.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        func add(_ d: Data, err isErr: Bool) {
            guard !d.isEmpty else { return }
            lock.lock()
            if isErr { err.append(d) } else { out.append(d) }
            lock.unlock()
        }
        func text() -> (String, String) {
            lock.lock()
            defer { lock.unlock() }
            return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
        }
    }
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
