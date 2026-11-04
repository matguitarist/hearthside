import AppKit
import CryptoKit
import Foundation

/// Pandaria: Mists of Pandaria 5.4.8 with playerbots (LoA-Pandaria-Playerbots) on the home server,
/// played with the player's own 5.4.8 Mac client (`macos/Server/Pandaria`).
///
/// The server lives beside the Classic one, in `azeroth-survivors-pandaria` next to
/// `azeroth-survivors-cmangos`, reached over the same SSH connection (`HomeServer`). Setup copies
/// the recipe and the client's Data folder there and starts `home-setup`, which builds the server
/// from source, its databases and its maps on its own (a few hours on a small CPU), so the launcher
/// can quit meanwhile. Both servers take the same ports: starting one stops the other.
@MainActor
final class PandariaServer: ObservableObject {
    enum Phase: Equatable {
        /// The home server's connection is not set.
        case notConnected
        case checking
        /// SSH failed: the server is off, the address is wrong, or it does not hold the key.
        case unreachable(String)
        case noDocker
        case notSetUp
        /// The setup runs on the server, at this step.
        case settingUp(String)
        /// A step the launcher waits for: copying, start, stop.
        case busy(String)
        /// Its containers run, and the world is still loading: it takes logins once it listens.
        case starting
        case stopped
        case running
        case failed(String)
    }

    @Published private(set) var phase: Phase = .notConnected
    /// Kept across launches, so Play knows of them while the server is stopped.
    @Published private(set) var accounts: [String] = UserDefaults.standard.stringArray(forKey: "pandariaAccounts") ?? [] {
        didSet { UserDefaults.standard.set(accounts, forKey: "pandariaAccounts") }
    }
    @Published private(set) var admins: Set<String> = []
    /// The random bots online, while it runs.
    @Published private(set) var bots: Int?
    /// Play is preparing the client: patching it, building its OpenGL fixes.
    @Published private(set) var preparing = false
    /// Why the client could not be prepared or launched, until the next Play.
    @Published var clientError: String?

    static let shared = PandariaServer()
    nonisolated static let project = "azeroth-survivors-pandaria"
    /// The level of an administrator (`SEC_ADMINISTRATOR`), as `pandaria-account --gm` sets it.
    let adminLevel = 3
    /// The recipe's files the launcher keeps current on the server.
    private static let scripts = ["home-compose", "home-setup", "compose.yaml", "pandaria-install", "Dockerfile", ".dockerignore"]

    private var home: HomeServer { .shared }
    private var setUpDone = false

    private init() {}

    /// The server's folder, beside the Classic one's.
    nonisolated static func folder(beside cmangos: String) -> String {
        (cmangos as NSString).deletingLastPathComponent + "/" + project
    }

    private var folder: String { Self.folder(beside: home.folder) }

    var isSetUp: Bool {
        switch phase {
        case .stopped, .running, .starting: true
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
    var canPlay: Bool { isSetUp && !isBusy && !preparing && !accounts.isEmpty }

    /// The Classic server started on the same machine, which stops this one.
    func otherStarted() {
        if phase == .running || phase == .starting { phase = .stopped }
        bots = nil
    }

    // MARK: - State

    func refresh() async {
        guard !isBusy else { return }
        await look()
    }

    private func look() async {
        if home.host.isEmpty { phase = .notConnected; return }
        if let problem = home.problem { phase = .failed(problem); return }
        if case .settingUp = phase {} else { phase = .checking }
        let status: [String: String]
        do {
            try await home.findFolder()
            status = try await probe()
        } catch {
            phase = .unreachable(LocalServer.message(error))
            return
        }
        setUpDone = status["state"] == "done"
        let step = status["step"].map { $0.isEmpty ? "Starting…" : $0 } ?? "Starting…"
        switch status["state"] {
        case "nodocker":
            phase = .noDocker
        case "running":
            phase = .settingUp(step)
        case "failed":
            phase = .failed("The setup stopped at: \(step) Show Log has its output.")
        case "done":
            await syncScripts()
            if status["world"] == "up" {
                phase = .running
                await loadAccounts()
            } else {
                phase = status["worldserver"] == "running" ? .starting : .stopped
                bots = nil
            }
        default:
            phase = .notSetUp
        }
    }

    /// One look at everything, as `key=value` lines. A server set up by hand, before the launcher
    /// knew of Pandaria, has its containers but no `.setup-done`: it counts as set up. The world
    /// is up once its port takes connections, the game server running.
    private func probe() async throws -> [String: String] {
        let p = Self.project
        let script = """
            command -v docker >/dev/null || { echo state=nodocker; exit 0; }
            cd \(folder) 2>/dev/null || { echo state=none; exit 0; }
            if [ -f .setup-pid ] && kill -0 "$(cat .setup-pid)" 2>/dev/null; then echo state=running
            elif [ -f .setup-done ] || docker inspect \(p)-worldserver-1 >/dev/null 2>&1; then echo state=done
            elif [ -f .setup-failed ]; then echo state=failed
            else echo state=none; fi
            echo "step=$(cat .setup-step 2>/dev/null)"
            echo "maps=$(ls storage/data/maps 2>/dev/null | grep -c '[.]map$')"
            for s in database authserver worldserver; do
              echo "$s=$(docker inspect -f '{{.State.Status}}' \(p)-$s-1 2>/dev/null)"
            done
            ip=$(sed -n 's/^LAN_IP=//p' .env 2>/dev/null)
            if [ "$(docker inspect -f '{{.State.Status}}' \(p)-worldserver-1 2>/dev/null)" = running ] && [ -n "$ip" ] \\
              && timeout 2 bash -c "</dev/tcp/$ip/8085" 2>/dev/null; then echo world=up; fi
            """
        var out: [String: String] = [:]
        for line in try await home.ssh(script, quiet: true).split(whereSeparator: \.isNewline) {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] } else if kv.count == 1 { out[kv[0]] = "" }
        }
        return out
    }

    private var recipe: URL? {
        let url = Bundle.main.url(forResource: "Server", withExtension: nil)?.appendingPathComponent("Pandaria")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// The recipe's scripts, so a server set up by hand or by an older app runs this one's.
    private func syncScripts() async {
        guard let recipe else { return }
        let files = Self.scripts.map { recipe.appendingPathComponent($0).path }
        guard files.allSatisfy(FileManager.default.fileExists(atPath:)) else { return }
        try? await home.rsync(files, to: folder, named: Self.project)
    }

    // MARK: - Setup

    /// Copy the recipe and, unless the maps are read already, the client's Data folder, then start
    /// the setup on the server and return; it carries on there.
    func setUp() async {
        guard !isBusy, home.problem == nil else { return }
        do {
            guard let data = PandariaClient.data, PandariaClient.problem == nil else {
                throw ServerError(PandariaClient.problem ?? "Choose your World of Warcraft 5.4.8 folder first.")
            }
            guard let recipe else { throw ServerError("The app is missing its server files. Reinstall it.") }
            try await home.findFolder()
            phase = .busy("Copying the server's recipe…")
            try await home.ssh("mkdir -p \(folder)/client")
            try await home.rsync(Self.scripts.map { recipe.appendingPathComponent($0).path }, to: folder, named: Self.project)
            // The address, and where the client's files are: kept when set, as on a server set
            // up by hand that reads them elsewhere.
            try await home.ssh("""
                cd \(folder) && touch .env && { grep -q '^LAN_IP=' .env || echo 'LAN_IP=\(home.address)' >> .env; } \
                && { grep -q '^CLIENT_DATA=' .env || echo 'CLIENT_DATA=\(folder)/client/Data' >> .env; }
                """)
            let maps = try await probe()["maps"] ?? ""
            if (Int(maps) ?? 0) == 0 {
                phase = .busy("Copying the client's game files (about 23 GB)…")
                try await home.rsync([data.path], to: folder, named: Self.project, into: "client/")
            }
            try await home.ssh("cd \(folder) && rm -f .setup-done .setup-failed .setup-step && (nohup ./home-setup > setup.log 2>&1 < /dev/null &)")
            phase = .settingUp("Starting…")
        } catch {
            phase = .failed(LocalServer.message(error))
        }
    }

    // MARK: - Start and stop

    func start() async {
        guard isSetUp, !isBusy, phase != .running else { return }
        await run("Starting Pandaria…") {
            try await self.stopClassic()
            try await self.compose("up -d database authserver worldserver")
            try await self.waitReady(minutes: 20)
        }
    }

    func stop() async {
        guard isSetUp, !isBusy else { return }
        // The game server saves everyone on the way out: it may take a minute.
        await run("Stopping Pandaria…") { try await self.compose("stop worldserver authserver database") }
    }

    func restart() async {
        guard isSetUp, !isBusy else { return }
        await run("Restarting Pandaria…") {
            try await self.stopClassic()
            try await self.compose("up -d database authserver worldserver")
            try await self.compose("restart authserver worldserver")
            try await self.waitReady(minutes: 20)
        }
    }

    /// The Classic server on the same machine takes the same ports.
    private func stopClassic() async throws {
        try await home.ssh("[ ! -x \(home.folder)/home-compose ] || \(home.folder)/home-compose stop realmd mangosd database")
        Task { await home.refresh() }
    }

    private func run(_ what: String, _ body: @escaping () async throws -> Void) async {
        phase = .busy(what)
        do {
            try await body()
            await look()
        } catch {
            phase = .failed(LocalServer.message(error))
        }
    }

    /// Until the world takes connections: loading it and making its bots takes a few minutes.
    private func waitReady(minutes: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(5))
            let s = try await probe()
            if s["world"] == "up" { return }
            for name in ["authserver", "worldserver"] where s[name] == "exited" || s[name] == "dead" {
                throw ServerError("Pandaria's \(name) stopped while starting. Show Log has its output.")
            }
        }
        throw ServerError("Pandaria did not start in \(minutes) minutes.")
    }

    private func compose(_ args: String) async throws {
        try await home.ssh("\(folder)/home-compose \(args)")
    }

    // MARK: - Accounts

    /// The name, uppercased, and SHA1("NAME:PASSWORD") as the server's own `account create`
    /// stores it; nil for a name or password it would not take. Only the hash leaves the Mac.
    nonisolated static func credentials(_ name: String, _ password: String) -> (String, String)? {
        let user = name.uppercased()
        guard user.range(of: "^[A-Z0-9]{1,16}$", options: .regularExpression) != nil,
              (1...16).contains(password.count) else { return nil }
        let digest = Insecure.SHA1.hash(data: Data("\(user):\(password.uppercased())".utf8))
        return (user, digest.map { String(format: "%02X", $0) }.joined())
    }

    func account(_ name: String, password: String, changePassword: Bool = false, admin: Bool = false) async -> String? {
        guard phase == .running else { return "The server is not running." }
        guard let (user, hash) = Self.credentials(name, password) else {
            return "Letters and digits for the name, up to 16; a password of up to 16 characters."
        }
        // The server works out the rest of the login (`v`, `s`) from the hash at the next sign-in.
        let sql = changePassword
            ? "UPDATE account SET sha_pass_hash = '\(hash)', v = '', s = '', sessionkey = '' WHERE username = '\(user)';"
            : """
              INSERT INTO account (username, sha_pass_hash, email, reg_mail, joindate) VALUES ('\(user)', '\(hash)', '', '', NOW());
              INSERT INTO realmcharacters (realmid, acctid, numchars) SELECT id, LAST_INSERT_ID(), 0 FROM realmlist;
              """
        do {
            try await mysql("auth", stdin: sql)
        } catch {
            let why = LocalServer.message(error)
            return why.contains("Duplicate entry") ? "An account named \(user) already exists." : why
        }
        if !changePassword, admin, let why = await setAdmin(user, true) { return why }
        await loadAccounts()
        return nil
    }

    func setAdmin(_ name: String, _ on: Bool) async -> String? {
        let user = name.uppercased()
        guard user.range(of: "^[A-Z0-9]{1,16}$", options: .regularExpression) != nil else { return "That account name is not allowed." }
        var sql = "DELETE aa FROM account_access aa JOIN account a ON a.id = aa.id WHERE a.username = '\(user)';"
        if on { sql += "INSERT INTO account_access (id, gmlevel, RealmID) SELECT id, \(adminLevel), -1 FROM account WHERE username = '\(user)';" }
        do {
            try await mysql("auth", stdin: sql)
        } catch {
            return LocalServer.message(error)
        }
        await loadAccounts()
        return nil
    }

    /// The players' accounts and who among them is an administrator; the random bots' (`RNDBOT`)
    /// are left out, and counted online.
    private func loadAccounts() async {
        let query = """
            SELECT a.username, COALESCE(MAX(aa.gmlevel), 0) FROM account a LEFT JOIN account_access aa ON aa.id = a.id \
            WHERE a.username NOT LIKE 'RNDBOT%' GROUP BY a.id, a.username ORDER BY a.username;
            SELECT CONCAT('bots=', COUNT(*)) FROM characters.characters c JOIN account a ON a.id = c.account \
            WHERE c.online = 1 AND a.username LIKE 'RNDBOT%';
            """
        guard let out = try? await mysql("auth", stdin: query, quiet: true) else { return }
        var names: [String] = [], admins: Set<String> = []
        for line in out.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("bots=") { bots = Int(line.dropFirst(5)); continue }
            let f = line.split(separator: "\t").map(String.init)
            guard f.count == 2 else { continue }
            names.append(f[0])
            if (Int(f[1]) ?? 0) >= adminLevel { admins.insert(f[0]) }
        }
        accounts = names
        self.admins = admins
    }

    @discardableResult
    private func mysql(_ database: String, stdin: String, quiet: Bool = false) async throws -> String {
        // The root password stays inside the server's network: the database publishes no port.
        try await home.ssh("docker exec -i \(Self.project)-database-1 mysql -uroot -ppassword -N -B \(database)",
                           stdin: stdin, quiet: quiet)
    }

    // MARK: - Logs

    /// The end of one of the server's logs, for the Logs window.
    func log(_ source: LogSource, lines: Int) async throws -> String {
        if let problem = home.problem { throw ServerError(problem) }
        try await home.findFolder()
        let logs = "\(folder)/storage/logs"
        let file: String
        switch source {
        case .pandariaWorld: file = "\(logs)/Server.log"
        case .pandariaLogin: file = "\(logs)/Auth.log"
        case .pandariaDatabase: file = "\(logs)/DBErrors.log"
        case .pandariaSetup: file = "\(folder)/setup.log"
        default: return ""
        }
        return try await home.ssh("tail -n \(lines) \(file) 2>/dev/null; true", quiet: true)
    }

    // MARK: - The client

    /// Ready the client for this server, then the caller launches it: the first time, patch it
    /// (`mac-client-setup`); every time, the realm and the addons.
    func prepareClient() async -> Bool {
        clientError = nil
        preparing = true
        defer { preparing = false }
        do {
            try await PandariaClient.ready(realm: home.address)
            return true
        } catch {
            clientError = LocalServer.message(error)
            return false
        }
    }

    /// Patch it again from scratch, after an app update brought new fixes, say.
    func prepareAgain() async {
        clientError = nil
        preparing = true
        defer { preparing = false }
        do {
            try await PandariaClient.prepare(realm: home.address)
        } catch {
            clientError = LocalServer.message(error)
        }
    }
}

/// The player's World of Warcraft 5.4.8 folder: `World of Warcraft-64.app` beside its `Data`.
@MainActor
enum PandariaClient {
    static let appName = "World of Warcraft-64.app"

    static var folder: URL? {
        let path = UserDefaults.standard.string(forKey: Prefs.pandariaFolderKey) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }
    static var app: URL? { folder?.appendingPathComponent(appName, isDirectory: true) }
    static var binary: URL? { app?.appendingPathComponent("Contents/MacOS/World of Warcraft-64") }
    static var data: URL? { folder?.appendingPathComponent("Data", isDirectory: true) }

    /// What is wrong with the chosen folder, if anything.
    static var problem: String? {
        guard let folder, let data, let binary else { return "Choose your World of Warcraft 5.4.8 folder." }
        let fm = FileManager.default
        guard fm.fileExists(atPath: data.path) else { return "\(folder.lastPathComponent) has no Data folder." }
        guard fm.isExecutableFile(atPath: binary.path) else { return "\(folder.lastPathComponent) has no \(appName)." }
        return nil
    }

    /// Patched and signed by `mac-client-setup`, which puts our OpenGL fixes in its Frameworks.
    static var isPrepared: Bool {
        guard let app else { return false }
        return FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Frameworks/glhook.dylib").path)
    }

    /// Whether its fixes were built from this version's `glhook` sources: `mac-client-setup` leaves
    /// their digest in the app (`cat glhook/*.[ch] | shasum -a 256`).
    static var isCurrent: Bool {
        guard let app,
              let built = try? String(contentsOf: app.appendingPathComponent("Contents/Resources/glhook.sources"), encoding: .utf8),
              let dir = Bundle.main.url(forResource: "Server", withExtension: nil)?.appendingPathComponent("Pandaria/glhook"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return false }
        var hash = SHA256()
        for name in names.filter({ $0.hasSuffix(".c") || $0.hasSuffix(".h") }).sorted() {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return false }
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return built.trimmingCharacters(in: .whitespacesAndNewlines) == digest
    }

    /// Ambient occlusion and ground mist, glhook's own passes (Settings › Pandaria), on by default.
    static var occlusion: Bool { UserDefaults.standard.object(forKey: Prefs.pandariaOcclusionKey) as? Bool ?? true }
    static var mist: Bool { UserDefaults.standard.object(forKey: Prefs.pandariaMistKey) as? Bool ?? true }

    /// The first time, or after an update changed the fixes, `prepare`; else the realm, the
    /// settings and the addons only.
    static func ready(realm: String) async throws {
        if let problem { throw ServerError(problem) }
        if !isPrepared || !isCurrent {
            try await prepare(realm: realm)
            return
        }
        try writeRealm(realm)
        installAddons()
    }

    /// `mac-client-setup` from the app's resources: the connection and graphics patches, our
    /// OpenGL fixes and FSR built for it, an ad hoc signature, the realm and the addons.
    static func prepare(realm: String) async throws {
        if let problem { throw ServerError(problem) }
        guard let folder, let app,
              let script = Bundle.main.url(forResource: "Server", withExtension: nil)?.appendingPathComponent("Pandaria/mac-client-setup"),
              FileManager.default.fileExists(atPath: script.path)
        else { throw ServerError("The app is missing its Pandaria files. Reinstall it.") }
        // It compiles the fixes and rewrites the binary's imports.
        guard (try? await Docker.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"], quiet: true)) != nil else {
            throw ServerError("Preparing the client needs Apple's command line developer tools. Install them (Terminal: xcode-select --install), then press Play again.")
        }
        try await Docker.run(URL(fileURLWithPath: "/bin/bash"), [script.path, app.path, folder.path, realm])
        try writeRealm(realm)
        installAddons()
    }

    /// In `WTF/Config.wtf`: `realmlist` and `patchlist`, the logon server the client dials, and
    /// `SSAO`, the client's own ambient occlusion, off while ours replaces it.
    static func writeRealm(_ address: String) throws {
        guard let folder else { return }
        let wtf = folder.appendingPathComponent("WTF", isDirectory: true)
        try FileManager.default.createDirectory(at: wtf, withIntermediateDirectories: true)
        let config = wtf.appendingPathComponent("Config.wtf")
        let old = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        var lines = old.split(whereSeparator: \.isNewline).map(String.init).filter {
            let l = $0.lowercased()
            return !l.hasPrefix("set realmlist ") && !l.hasPrefix("set patchlist ") && !l.hasPrefix("set ssao ")
        }
        lines += ["SET realmlist \"\(address)\"", "SET patchlist \"\(address)\"", "SET SSAO \"\(occlusion ? 0 : 1)\""]
        try (lines.joined(separator: "\n") + "\n").write(to: config, atomically: true, encoding: .utf8)
    }

    /// This client's AzerothPlus and AzerothAdmin (`macos/Server/Pandaria/addons`), or with the
    /// setting off, none: the shared "Install AzerothPlus and AzerothAdmin" of Settings › General.
    static func installAddons() {
        guard let folder,
              let bundled = Bundle.main.url(forResource: "Server", withExtension: nil)?.appendingPathComponent("Pandaria/addons")
        else { return }
        let fm = FileManager.default
        let install = UserDefaults.standard.object(forKey: Prefs.installAddonsKey) as? Bool ?? true
        let addons = folder.appendingPathComponent("Interface/AddOns", isDirectory: true)
        try? fm.createDirectory(at: addons, withIntermediateDirectories: true)
        for name in Addons.shipped {
            let dest = addons.appendingPathComponent(name, isDirectory: true)
            try? fm.removeItem(at: dest)
            if install { try? fm.copyItem(at: bundled.appendingPathComponent(name), to: dest) }
        }
    }
}
