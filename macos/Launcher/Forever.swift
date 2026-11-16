import AppKit
import CryptoKit
import Foundation
import Security

/// Forever: Blizzard's WoW Forever client against a TrinityCore server with bots (Karrz1's
/// forever-bots) on the home server (`macos/Server/Forever`).
///
/// The server lives beside the Classic and Pandaria ones, in `hearthside-forever`, reached
/// over the same SSH connection (`HomeServer`). It has its own ports (1119 and 8081 for the login,
/// a world port from 8105), so it runs beside them. Setup copies the recipe and starts `home-setup`
/// there, which builds the server from source; meanwhile the game data is read from the client on
/// this Mac, in Docker, and copied over (`mac-extract`), since the client's folder is too big to send.
@MainActor
final class ForeverServer: ObservableObject {
    enum Phase: Equatable {
        case notConnected
        case checking
        case unreachable(String)
        case noDocker
        case notSetUp
        /// The setup runs on the server, at this step.
        case settingUp(String)
        /// The server waits for the game data read on this Mac.
        case needsData
        /// A step the launcher waits for: copying, reading the data, start, stop.
        case busy(String)
        case starting
        case stopped
        case running
        case failed(String)
    }

    @Published private(set) var phase: Phase = .notConnected
    /// The players' Battle.net accounts (emails), kept across launches so Play knows of them while
    /// the server is stopped.
    @Published private(set) var accounts: [String] = UserDefaults.standard.stringArray(forKey: "foreverAccounts") ?? [] {
        didSet { UserDefaults.standard.set(accounts, forKey: "foreverAccounts") }
    }
    @Published private(set) var admins: Set<String> = []
    @Published private(set) var bots: Int?
    /// The bots' settings in the server's `.env`, as `forever-start` reads them: most in the world
    /// at once (BOTS), and most around each player (BOTS_PER_PLAYER).
    @Published private(set) var botLimit = ForeverServer.defaultBots
    @Published private(set) var botsPerPlayer = ForeverServer.defaultBotsPerPlayer
    nonisolated static let defaultBots = 220
    nonisolated static let defaultBotsPerPlayer = 160
    /// Play is preparing the client or signing in.
    @Published private(set) var preparing: String?
    /// Why the client could not be prepared or launched, until the next Play.
    @Published var clientError: String?

    static let shared = ForeverServer()
    nonisolated static let project = "hearthside-forever"
    /// The playerbot module's own Battle.net accounts.
    nonisolated static let botDomain = "@PLAYERBOT-V2.LOCAL"
    let adminLevel = 3
    /// The recipe's files the server needs; the Mac-side scripts run from the app.
    private static let scripts = ["Dockerfile", "compose.yaml", "forever-start", "forever-install", "forever-extract",
                                  "home-compose", "home-setup"]

    private var home: HomeServer { .shared }
    private var setUpDone = false

    private init() {}

    nonisolated static func folder(beside cmangos: String) -> String {
        (cmangos as NSString).deletingLastPathComponent + "/" + project
    }

    var folder: String { Self.folder(beside: home.folder) }

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
    var canPlay: Bool { isSetUp && !isBusy && preparing == nil && !accounts.isEmpty }

    /// The account Play signs in with: the one chosen in Settings, else the first.
    var playAccount: String? {
        let chosen = UserDefaults.standard.string(forKey: Prefs.foreverAccountKey) ?? ""
        return accounts.contains(chosen) ? chosen : accounts.first
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
        botLimit = status["BOTS"].flatMap { Int($0) } ?? Self.defaultBots
        botsPerPlayer = status["BOTS_PER_PLAYER"].flatMap { Int($0) } ?? Self.defaultBotsPerPlayer
        let step = status["step"].map { $0.isEmpty ? "Starting…" : $0 } ?? "Starting…"
        switch status["state"] {
        case "nodocker":
            phase = .noDocker
        case "running":
            phase = status["data"] == "yes" ? .settingUp(step) : .needsData
        case "failed":
            phase = .failed("The setup stopped at: \(step) Show Log has its output.")
        case "done":
            await syncScripts()
            if status["data"] != "yes" {
                phase = .needsData
            } else if status["world"] == "up" {
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
            if [ -f storage/data/vmaps/GameObjectModels.dtree ] && ls storage/data/mmaps 2>/dev/null | grep -q mmtile; then echo data=yes; fi
            for s in database bnetserver worldserver; do
              echo "$s=$(docker inspect -f '{{.State.Status}}' \(p)-$s-1 2>/dev/null)"
            done
            ip=$(sed -n 's/^LAN_IP=//p' .env 2>/dev/null)
            port=$(sed -n 's/^WORLD_PORT=//p' .env 2>/dev/null)
            echo "BOTS=$(sed -n 's/^BOTS=//p' .env 2>/dev/null)"
            echo "BOTS_PER_PLAYER=$(sed -n 's/^BOTS_PER_PLAYER=//p' .env 2>/dev/null)"
            if [ "$(docker inspect -f '{{.State.Status}}' \(p)-worldserver-1 2>/dev/null)" = running ] && [ -n "$ip" ] \\
              && timeout 2 bash -c "</dev/tcp/$ip/${port:-8105}" 2>/dev/null \\
              && timeout 2 bash -c "</dev/tcp/$ip/1119" 2>/dev/null; then echo world=up; fi
            """
        var out: [String: String] = [:]
        for line in try await home.ssh(script, quiet: true).split(whereSeparator: \.isNewline) {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] } else if kv.count == 1 { out[kv[0]] = "" }
        }
        return out
    }

    nonisolated static var recipe: URL? {
        let url = Bundle.main.url(forResource: "Server", withExtension: nil)?.appendingPathComponent("Forever")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    private func syncScripts() async {
        guard let recipe = Self.recipe else { return }
        let files = Self.scripts.map { recipe.appendingPathComponent($0).path }
        guard files.allSatisfy(FileManager.default.fileExists(atPath:)) else { return }
        try? await home.rsync(files, to: folder, named: Self.project)
    }

    /// A script of the recipe run on this Mac, with the launcher's SSH key and the server's folder.
    @discardableResult
    func script(_ name: String, _ args: [String], stdin: String? = nil, quiet: Bool = false) async throws -> String {
        guard let path = Self.recipe?.appendingPathComponent(name).path, FileManager.default.fileExists(atPath: path) else {
            throw ServerError("The app is missing its Forever files. Reinstall it.")
        }
        return try await Docker.run(URL(fileURLWithPath: "/usr/bin/env"),
                                    ["HEARTHSIDE_SSH_KEY=\(home.key.path)", "FOREVER_REMOTE=\(folder)", "/bin/bash", path] + args,
                                    stdin: stdin, quiet: quiet)
    }

    // MARK: - Setup

    /// Copy the recipe, start the build on the server, then read the game data here meanwhile.
    func setUp() async {
        guard !isBusy, home.problem == nil else { return }
        do {
            if let problem = ForeverClient.problem { throw ServerError(problem) }
            guard let recipe = Self.recipe else { throw ServerError("The app is missing its Forever files. Reinstall it.") }
            try await home.findFolder()
            phase = .busy("Copying the server's recipe…")
            try await home.ssh("mkdir -p \(folder)")
            try await home.rsync(Self.scripts.map { recipe.appendingPathComponent($0).path }, to: folder, named: Self.project)
            try await home.ssh("""
                cd \(folder) && touch .env && { grep -q '^LAN_IP=' .env || echo 'LAN_IP=\(home.address)' >> .env; } \
                && rm -f .setup-done .setup-failed .setup-step && (nohup ./home-setup > setup.log 2>&1 < /dev/null &)
                """)
            try await readData()
            await look()
        } catch {
            phase = .failed(LocalServer.message(error))
        }
    }

    /// The game data read from the client in this Mac's Docker and copied to the server
    /// (`mac-extract`): an hour or more the first time, then kept in Caches for a new copy.
    func copyData() async {
        guard !isBusy else { return }
        do {
            try await readData()
            await look()
        } catch {
            phase = .failed(LocalServer.message(error))
        }
    }

    private func readData() async throws {
        guard let folder = ForeverClient.folder, ForeverClient.problem == nil else {
            throw ServerError(ForeverClient.problem ?? "Choose your World of Warcraft folder.")
        }
        guard await Docker.engineUp() else {
            throw ServerError("Reading the game data from your client needs \(Docker.engineName) running on this Mac.")
        }
        phase = .busy("Reading the game data from your client: an hour or more the first time…")
        try await script("mac-extract", [folder.path, home.host])
    }

    // MARK: - Start and stop

    func start() async {
        guard isSetUp, !isBusy, phase != .running else { return }
        await run("Starting Forever…") {
            try await self.compose("up -d database worldserver bnetserver")
            try await self.waitReady(minutes: 20)
        }
    }

    func stop() async {
        guard isSetUp, !isBusy else { return }
        await run("Stopping Forever…") { try await self.compose("stop bnetserver worldserver database") }
    }

    func restart() async {
        guard isSetUp, !isBusy else { return }
        await run("Restarting Forever…") {
            try await self.compose("up -d database")
            try await self.compose("up -d --force-recreate worldserver bnetserver")
            try await self.waitReady(minutes: 20)
        }
    }

    /// New bot settings into the server's `.env`; a running world restarts with them (a few
    /// minutes, everyone playing disconnected), a stopped one takes them at its next start.
    func setBots(total: Int, perPlayer: Int) async {
        guard isSetUp, !isBusy else { return }
        let total = max(0, min(total, 2000)), perPlayer = max(0, min(perPlayer, 500))
        let running = phase == .running || phase == .starting
        await run(running ? "Restarting Forever with the new bot settings…" : "Saving the bot settings…") {
            try await self.home.ssh("""
                cd \(self.folder) && sed -i -e '/^BOTS=/d' -e '/^BOTS_PER_PLAYER=/d' .env \
                && printf 'BOTS=%d\\nBOTS_PER_PLAYER=%d\\n' \(total) \(perPlayer) >> .env
                """)
            guard running else { return }
            try await self.compose("up -d --force-recreate worldserver")
            try await self.waitReady(minutes: 20)
        }
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

    private func waitReady(minutes: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(5))
            let s = try await probe()
            if s["world"] == "up" { return }
            for name in ["bnetserver", "worldserver"] where s[name] == "exited" || s[name] == "dead" {
                throw ServerError("Forever's \(name) stopped while starting. Show Log has its output.")
            }
        }
        throw ServerError("Forever did not start in \(minutes) minutes.")
    }

    private func compose(_ args: String) async throws {
        try await home.ssh("\(folder)/home-compose \(args)")
    }

    // MARK: - Accounts

    nonisolated static func validEmail(_ email: String) -> Bool {
        email.range(of: #"^[^@\s'"]+@[^@\s'"]+$"#, options: .regularExpression) != nil
    }

    nonisolated static func validPassword(_ password: String) -> Bool {
        (4...16).contains(password.count) && password.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    /// A new Battle.net account, or a new password for one (`forever-account`, over SOAP on the
    /// server). The password is kept in the Keychain for Play.
    func account(_ email: String, password: String, changePassword: Bool = false, admin: Bool = false) async -> String? {
        guard phase == .running else { return "The server is not running." }
        let email = email.trimmingCharacters(in: .whitespaces)
        guard Self.validEmail(email) else { return "Enter an email address: you sign in with it." }
        guard Self.validPassword(password) else { return "A password of 4 to 16 characters, without spaces." }
        var args: [String] = []
        if changePassword { args.append("--password") } else if admin { args.append("--gm") }
        do {
            try await script("forever-account", args + [home.host], stdin: "\(email)\n\(password)\n")
        } catch {
            let why = LocalServer.message(error)
            return why.contains("already") ? "An account with that email already exists." : why
        }
        ForeverKeychain.save(password, for: email.uppercased())
        await loadAccounts()
        return nil
    }

    func setAdmin(_ email: String, _ on: Bool) async -> String? {
        guard Self.validEmail(email) else { return "That email is not allowed." }
        let match = "a.battlenet_account = (SELECT id FROM battlenet_accounts WHERE email = '\(email.uppercased())')"
        var sql = "DELETE x FROM account_access x JOIN account a ON a.id = x.AccountID WHERE \(match);"
        if on {
            sql += "INSERT INTO account_access (AccountID, SecurityLevel, RealmID) SELECT a.id, \(adminLevel), -1 FROM account a WHERE \(match);"
        }
        do {
            try await mysql("auth", stdin: sql)
        } catch {
            return LocalServer.message(error)
        }
        await loadAccounts()
        return nil
    }

    private func loadAccounts() async {
        let d = Self.botDomain
        let query = """
            SELECT b.email, COALESCE(MAX(x.SecurityLevel), 0) FROM battlenet_accounts b \
            LEFT JOIN account a ON a.battlenet_account = b.id LEFT JOIN account_access x ON x.AccountID = a.id \
            WHERE b.email NOT LIKE '%\(d)' GROUP BY b.id, b.email ORDER BY b.email;
            SELECT CONCAT('bots=', COUNT(*)) FROM characters.characters c JOIN account a ON a.id = c.account \
            JOIN battlenet_accounts b ON b.id = a.battlenet_account WHERE c.online = 1 AND b.email LIKE '%\(d)';
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
        try await home.ssh("docker exec -i \(Self.project)-database-1 mysql -uroot -ppassword -N -B \(database)",
                           stdin: stdin, quiet: quiet)
    }

    // MARK: - Logs

    func log(_ source: LogSource, lines: Int) async throws -> String {
        if let problem = home.problem { throw ServerError(problem) }
        try await home.findFolder()
        let file: String
        switch source {
        case .foreverWorld: file = "\(folder)/storage/logs/Server.log"
        case .foreverLogin: file = "\(folder)/storage/logs/Bnet.log"
        case .foreverDatabase: file = "\(folder)/storage/logs/DBErrors.log"
        case .foreverSetup: file = "\(folder)/setup.log"
        default: return ""
        }
        return try await home.ssh("tail -n \(lines) \(file) 2>/dev/null; true", quiet: true)
    }

    // MARK: - The client

    /// Ready the client and its login for Play: the first time, or after Battle.net updated the game
    /// or this app its patch, `mac-client-setup`; every time, a new login ticket.
    func prepareClient() async -> Bool {
        clientError = nil
        defer { preparing = nil }
        do {
            guard let email = playAccount else { throw ServerError("Create an account first.") }
            guard let password = ForeverKeychain.password(for: email) else {
                throw ServerError("Hearthside doesn't know the password of \(email.lowercased()). Enter it in Settings › Forever.")
            }
            if !ForeverClient.isCurrent {
                preparing = "Preparing the client: a copy that signs in to your server…"
                try await ForeverClient.prepare()
            }
            preparing = "Signing in…"
            try await script("forever-login", [email], stdin: password + "\n")
            return true
        } catch {
            clientError = LocalServer.message(error)
            return false
        }
    }

    func prepareAgain() async {
        clientError = nil
        preparing = "Preparing the client again…"
        defer { preparing = nil }
        do {
            try await ForeverClient.prepare(force: true)
        } catch {
            clientError = LocalServer.message(error)
        }
    }
}

/// The player's World of Warcraft folder, the one Battle.net installs, with WoW Forever in
/// `_forever_`. Hearthside plays its own copy of the app there, `Hearthside Forever.app`.
@MainActor
enum ForeverClient {
    /// TrinityCore's public key for the encrypted mode, from the private key in AuthenticationPackets.cpp.
    static let serverKey = "02596F0D0C061A8B30745988FD72C59E29EC367FB0F341F28E0F08D037BAFC69"

    static var folder: URL? {
        let path = UserDefaults.standard.string(forKey: Prefs.foreverFolderKey) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }
    static var dir: URL? { folder?.appendingPathComponent("_forever_", isDirectory: true) }
    static var original: URL? { dir?.appendingPathComponent("World of Warcraft.app", isDirectory: true) }
    static var copy: URL? { dir?.appendingPathComponent("Hearthside Forever.app", isDirectory: true) }
    static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Hearthside/Forever")
    }

    static var executable: URL? {
        guard let copy, let name = Bundle(url: copy)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String else { return nil }
        return copy.appendingPathComponent("Contents/MacOS/\(name)")
    }

    static var problem: String? {
        guard let folder, let original else { return "Choose your World of Warcraft folder." }
        guard FileManager.default.fileExists(atPath: original.path) else {
            return "\(folder.lastPathComponent) has no WoW Forever: install it with Battle.net first (_forever_/World of Warcraft.app)."
        }
        return nil
    }

    static func build(_ app: URL) -> String? {
        Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    static var isPrepared: Bool {
        guard let copy else { return false }
        return FileManager.default.fileExists(atPath: copy.appendingPathComponent("Contents/Frameworks/keyswap.dylib").path)
    }

    /// The copy was made from the client Battle.net has now, with this app's keyswap and badge
    /// (`mac-client-setup` leaves both in its Resources), and the login's certificate is here.
    static var isCurrent: Bool {
        guard let copy, let original, isPrepared, let recipe = ForeverServer.recipe,
              FileManager.default.fileExists(atPath: support.appendingPathComponent("ca.der").path)
        else { return false }
        let resources = copy.appendingPathComponent("Contents/Resources")
        func read(_ name: String) -> String {
            ((try? String(contentsOf: resources.appendingPathComponent(name), encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard read("hearthside.source") == build(original) ?? "?" else { return false }
        var hash = SHA256()
        for name in ["client/keyswap.c", "client/badge.swift"] {
            guard let data = try? Data(contentsOf: recipe.appendingPathComponent(name)) else { return false }
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        // As `shasum -a 256` prints it, from standard input.
        return read("keyswap.sources") == "\(digest)  -"
    }

    /// Our addons for this client (`macos/Server/Forever/addons`): AzerothAdmin.
    static let addonNames = ["AzerothAdmin"]

    /// Our addons, there only while Hearthside's client runs: copied in just before it starts
    /// (unless the shared "Install AzerothPlus and AzerothAdmin" of Settings › General is off),
    /// taken out when it quits. Battle.net's client reads the same `Interface/AddOns`, and never
    /// sees them.
    static func installAddons() {
        removeAddons()
        guard UserDefaults.standard.object(forKey: Prefs.installAddonsKey) as? Bool ?? true,
              let dir,
              let bundled = Bundle.main.url(forResource: "Server", withExtension: nil)?.appendingPathComponent("Forever/addons")
        else { return }
        let fm = FileManager.default
        let addons = dir.appendingPathComponent("Interface/AddOns", isDirectory: true)
        try? fm.createDirectory(at: addons, withIntermediateDirectories: true)
        for name in addonNames {
            try? fm.copyItem(at: bundled.appendingPathComponent(name), to: addons.appendingPathComponent(name, isDirectory: true))
        }
    }

    static func removeAddons() {
        guard let dir else { return }
        for name in addonNames {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("Interface/AddOns/\(name)", isDirectory: true))
        }
    }

    /// Hearthside's client is running (`mac-client-setup` gives it this identifier).
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.hearthside.forever").isEmpty
    }

    /// Our addons left behind, should the launcher have quit before the game: out, unless our
    /// client still runs.
    static func removeLeftoverAddons() {
        if !isRunning { removeAddons() }
    }

    /// `mac-client-setup`: the copy, the login name in /etc/hosts and the login's certificate
    /// authority trusted (macOS asks for an administrator's password, then to trust it).
    static func prepare(force: Bool = false) async throws {
        if let problem { throw ServerError(problem) }
        guard let folder else { return }
        guard (try? await Docker.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"], quiet: true)) != nil else {
            throw ServerError("Preparing the client needs Apple's command line developer tools. Install them (Terminal: xcode-select --install), then press Play again.")
        }
        if force, let copy { try? FileManager.default.removeItem(at: copy) }
        try await ForeverServer.shared.script("mac-client-setup", [folder.path, HomeServer.shared.host])
    }

    /// What the copy starts with: keyswap, the server's key, and the login sent to localhost, where
    /// the relay forwards it (the game won't connect to a private address for the login).
    static func environment(address: String) -> [String: String] {
        guard let copy else { return [:] }
        return [
            "DYLD_INSERT_LIBRARIES": copy.appendingPathComponent("Contents/Frameworks/keyswap.dylib").path,
            "KEYSWAP_KEY": serverKey,
            "KEYSWAP_GROUP": "8",
            "KEYSWAP_LOG": support.appendingPathComponent("keyswap.log").path,
            "KEYSWAP_LOGIN": address,
            "KEYSWAP_LOGIN_NAME": "localhost",
            "KEYSWAP_CA": support.appendingPathComponent("ca.der").path,
        ]
    }

    static let arguments = ["-launcherlogin", "-config", "Hearthside.wtf"]

    /// The relay for the login, started beside the game; it quits after it (`client/relay.py`).
    static func startRelay(address: String) throws {
        guard let executable, let relay = ForeverServer.recipe?.appendingPathComponent("client/relay.py") else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", relay.path, address, executable.path, "1119"]
        let log = support.appendingPathComponent("relay.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) {
            p.standardOutput = h
            p.standardError = h
        }
        try p.run()
        // Listening before the game dials it: a moment, at most a few seconds.
        for _ in 0..<20 {
            if let text = try? String(contentsOf: log, encoding: .utf8), text.contains("listening") { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ServerError("The login relay didn't start: \((try? String(contentsOf: log, encoding: .utf8)) ?? "")")
    }
}

/// The Forever accounts' passwords, for Play's login: in the login Keychain, one item per email.
enum ForeverKeychain {
    private static let service = "Hearthside Forever"

    private static func query(_ email: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: email.uppercased()]
    }

    static func save(_ password: String, for email: String) {
        SecItemDelete(query(email) as CFDictionary)
        var item = query(email)
        item[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func password(for email: String) -> String? {
        var q = query(email)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func has(_ email: String) -> Bool { password(for: email) != nil }
}
