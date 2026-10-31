import AppKit
import SwiftUI

/// The launcher's view of the home server: connect, set up, its state, the first account.
struct HomeServerPanel: View {
    @EnvironmentObject private var home: HomeServer
    @EnvironmentObject private var game: GameProcess
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch home.phase {
            case .notConfigured:
                note("Runs CMaNGOS with bots on an always-on machine at home with Docker (an Unraid box, say), managed from here over SSH. Every Mac at home plays on it.")
                HomeConnection(compact: true)

            case .checking:
                busy("Looking at the home server…")

            case .unreachable(let why):
                Label("Can't sign in to \(home.host): \(why)", systemImage: "exclamationmark.triangle.fill")
                    .fixedSize(horizontal: false, vertical: true)
                HomeConnection(compact: true)

            case .noDocker:
                note("\(home.address) has no Docker. Install it there (on Unraid: Settings › Docker), then check again.")
                Button("Check Again") { Task { await home.refresh() } }

            case .notSetUp:
                note("Sets up CMaNGOS with bots on \(home.address): about 4 GB of game files are copied there, then it builds the server and the maps its bots walk on, an hour or two on a small CPU. You can quit the launcher meanwhile.")
                Button("Set Up Home Server") { Task { await home.setUp() } }
                    .buttonStyle(.borderedProminent)

            case .settingUp(let step):
                busy(step)
                note("The setup runs on the server: you can quit the launcher and come back.")

            case .updating(let step):
                busy("Updating: \(step)")
                note("The update runs on the server: you can quit the launcher and come back. The game is down until it ends.")

            case .busy(let what):
                busy(what)

            case .stopped, .running:
                status
                if home.accounts.isEmpty {
                    if home.phase == .running {
                        AccountForm(title: "Create your account", action: "Create Account", home: true)
                    } else {
                        Button("Start Server") { Task { await home.start() } }
                    }
                }

            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Try Again") { Task { await home.refresh() } }
                    Button("Show Log…") { showLogs(home.isSetUp ? .homeServer : .homeSetup, openWindow) }
                }
            }
        }
        .disabled(game.running)
        .homeServerPolling()
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(home.phase == .running ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(home.phase == .running ? "Running at \(home.address)" : "Stopped · starts with Play")
            if let bots = home.bots { Text("· \(bots) bots").foregroundStyle(.secondary) }
            if !home.accounts.isEmpty {
                Text("· \(home.accounts.count == 1 ? "account \(home.accounts[0])" : "\(home.accounts.count) accounts")")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The server's login and address and the SSH key the launcher signs in with: one line in the
/// launcher, labeled rows in Settings.
struct HomeConnection: View {
    @EnvironmentObject private var home: HomeServer
    @AppStorage(Prefs.homeHostKey) private var host = ""
    @AppStorage(Prefs.homeKeyKey) private var keyPath = ""
    var compact = false
    @State private var copied = false
    @State private var error: String?
    @State private var hasKey = false

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        hostField.frame(width: 200)
                        connectButton
                    }
                    HStack(spacing: 8) {
                        keyButton
                        keyNote
                    }
                    errorText
                }
            } else {
                LabeledContent("Login and address") { hostField.frame(maxWidth: 240) }
                LabeledContent("SSH key") {
                    TextField("SSH key", text: $keyPath, prompt: Text(HomeServer.defaultKey))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        keyButton
                        Spacer()
                        connectButton
                    }
                    keyNote
                    errorText
                }
            }
        }
        .onAppear(perform: check)
        .onChange(of: host) { _, _ in home.settingsChanged() }
        .onChange(of: keyPath) { _, _ in home.settingsChanged(); check() }
    }

    private var hostField: some View {
        TextField("Login and address", text: $host, prompt: Text("root@192.168.1.10"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .onSubmit(connect)
    }

    private var connectButton: some View {
        Button("Connect", action: connect)
            .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || home.isBusy)
    }

    @ViewBuilder private var keyButton: some View {
        if hasKey {
            Button(copied ? "Copied" : "Copy Public Key") {
                guard let key = home.publicKey else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key, forType: .string)
                copied = true
            }
        } else {
            Button("Create Key") {
                Task {
                    error = await home.createKey()
                    check()
                }
            }
        }
    }

    private var keyNote: some View {
        Text("The server signs the launcher in with the key \(home.keyPath). Add its public half to the login's authorized keys; on Unraid, Users › root › SSH authorized keys.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var errorText: some View {
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }

    private func check() {
        hasKey = FileManager.default.fileExists(atPath: home.key.path)
        copied = false
    }

    private func connect() {
        Task { await home.refresh() }
    }
}

/// Settings › Home Server: the connection, the server's state, its accounts, removal.
struct HomeServerSettings: View {
    @EnvironmentObject private var home: HomeServer
    @EnvironmentObject private var game: GameProcess
    @Environment(\.openWindow) private var openWindow
    @State private var newAccount = false
    @State private var passwordFor: String?
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section("Connection") {
                HomeConnection()
            }

            Section("Server") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        StatusDot(health: home.health)
                        Text(home.statusText).multilineTextAlignment(.trailing)
                    }
                }
                if home.isSetUp {
                    HStack {
                        if home.phase == .running {
                            Button("Stop Server") { Task { await home.stop() } }
                                .disabled(game.running)
                            Button("Restart") { Task { await home.restart() } }
                                .disabled(game.running)
                        } else {
                            Button("Start Server") { Task { await home.start() } }
                        }
                        Spacer()
                        if let url = home.dashboard {
                            Button("Open Dashboard") { NSWorkspace.shared.open(url) }
                                .help("The server's page at \(url.absoluteString), for any browser at home")
                        }
                        Button("Show Logs…") { showLogs(.homeServer, openWindow) }
                    }
                    .disabled(home.isBusy)
                } else if home.phase == .notSetUp {
                    Button("Set Up Home Server") { Task { await home.setUp() } }
                }
            }

            if home.phase == .running, let stats = home.stats {
                Section("Right now") {
                    LabeledContent("Playing") {
                        Text(stats.players.isEmpty ? "Nobody"
                             : stats.players.map { "\($0.name) (\($0.level))" }.formatted(.list(type: .and)))
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Bots online") { Text("\(stats.bots)").monospacedDigit() }
                    LabeledContent("Game server") {
                        Text("\(stats.cores.formatted(.number.precision(.fractionLength(1)))) of \(stats.machineCores) cores · \(gb(stats.memory)) of memory")
                            .monospacedDigit()
                    }
                    LabeledContent("Memory free") {
                        Text("\(gb(stats.machineAvailable)) of \(gb(stats.machineMemory))")
                            .monospacedDigit()
                            .foregroundStyle(Double(stats.machineAvailable) < Double(stats.machineMemory) * 0.1 ? .red : .primary)
                    }
                    if let since = stats.since {
                        LabeledContent("Up since") { Text(since.formatted(.relative(presentation: .named))) }
                    }
                    if let last = home.backups.first {
                        LabeledContent("Last backup") { Text(last.date.formatted(.relative(presentation: .named))) }
                    }
                }
            }

            if home.isSetUp {
                Section("Accounts") {
                    ForEach(home.accounts, id: \.self) { name in
                        HStack {
                            Text(name)
                            Spacer()
                            Toggle("Administrator", isOn: Binding(
                                get: { home.admins.contains(name) },
                                set: { on in Task { _ = await home.setAdmin(name, on) } }))
                                .toggleStyle(.checkbox)
                            Button("Change Password…") { passwordFor = name }
                        }
                        .disabled(home.phase != .running)
                    }
                    Button("New Account…") { newAccount = true }
                        .disabled(home.phase != .running)
                    Text(home.phase == .running
                         ? "An administrator uses AzerothAdmin (/aa in the game) for levels, gold, teleports, items and bots. A change takes effect at the account's next login."
                         : "Start the server to manage accounts.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Button("Remove Home Server…", role: .destructive) { confirmRemove = true }
                        .disabled(home.isBusy || game.running)
                }
            }
        }
        .formStyle(.grouped)
        .task { await home.refresh() }
        .task(id: home.phase == .running) {
            // Live while this pane is open.
            while !Task.isCancelled, home.phase == .running {
                await home.loadStats()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .homeServerPolling()
        .sheet(isPresented: $newAccount) {
            sheet { AccountForm(title: "New account", action: "Create", home: true) { newAccount = false } }
        }
        .sheet(item: Binding(get: { passwordFor.map(Named.init) }, set: { passwordFor = $0?.name })) { item in
            sheet { AccountForm(title: "New password", action: "Change", name: item.name, home: true) { passwordFor = nil } }
        }
        .confirmationDialog("Remove the home server, its accounts and every character on it?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await home.remove() } }
        } message: {
            Text("Its containers, databases, image and folder on \(home.address) are deleted. This cannot be undone.")
        }
    }

    private func gb(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    private func sheet<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .trailing, spacing: 12) {
            content()
            Button("Close") { newAccount = false; passwordFor = nil }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private struct Named: Identifiable {
        let name: String
        var id: String { name }
    }
}

/// What a home-server pane shows before the server is set up.
private struct NotSetUpYet: View {
    @EnvironmentObject private var home: HomeServer

    var body: some View {
        ContentUnavailableView {
            Label("No Home Server Yet", systemImage: "house")
        } description: {
            Text(home.phase == .checking ? "Looking at the home server…" : "Connect and set up the home server in Settings › Home Server first. \(home.statusText).")
        }
    }
}

/// Settings › Bots & Rates: the server's bots and the world's rates, applied with one restart.
struct HomeGameSettings: View {
    @EnvironmentObject private var home: HomeServer
    @EnvironmentObject private var game: GameProcess
    @State private var draft = HomeServer.Settings()

    var body: some View {
        Group {
            if home.isSetUp {
                form
            } else {
                NotSetUpYet()
            }
        }
        .task { await home.refresh() }
        .homeServerPolling()
        .onChange(of: home.settings, initial: true) { _, now in if let now { draft = now } }
    }

    private var form: some View {
        Form {
            Section("Bots") {
                Stepper("\(draft.bots) random bots", value: $draft.bots, in: 0...1000, step: 50)
                Text("They level, quest and trade across the world, at every level from 1 to 60. Each 100 bots take about 1 GB of memory.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(isOn: $draft.botsNearPlayers) {
                    Text("Bring bots to where players are")
                    Text("Bots of a fitting level come to the zones around anyone playing, rather than roaming where nobody is.")
                }
                Toggle(isOn: $draft.botsSyncLevel) {
                    Text("Keep bots near the players' level")
                    Text("No bot is more than five levels above the highest player online. Bots above that are made again at a lower level, losing their progress.")
                }
            }

            Section {
                rate("Experience", $draft.xp)
                rate("Loot", $draft.loot)
                rate("Gold", $draft.gold)
                rate("Reputation", $draft.reputation)
                rate("Rested experience", $draft.rest)
            } header: {
                Text("Rates")
            } footer: {
                Text("×1 is the original game. Loot raises the chance of every item drop; quest items are left alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Bot sells and buys at the auction house", isOn: $draft.ahEnabled)
                step("Prices", $draft.ahPrices, HomeServer.Settings.ahPriceSteps)
                    .disabled(!draft.ahEnabled)
                step("Stock", $draft.ahStock, HomeServer.Settings.ahStockSteps)
                    .disabled(!draft.ahEnabled)
            } header: {
                Text("Auction house")
            } footer: {
                Text("Prices are times each item's vendor value; ×0.35 is the server's default. Stock ×1 is about 5,000 auctions across every category. The bot checks the auction house every 15 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text(draft == home.settings
                         ? "These are the server's settings."
                         : "Applying restarts the game server: everyone is signed out for a minute, longer while new bots are made.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Revert") { if let now = home.settings { draft = now } }
                        .disabled(draft == home.settings)
                    Button("Apply") { Task { await home.apply(draft) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == home.settings)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(home.isBusy || game.running || home.settings == nil)
    }

    private func rate(_ title: String, _ value: Binding<Double>) -> some View {
        step(title, value, HomeServer.Settings.rates)
    }

    private func step(_ title: String, _ value: Binding<Double>, _ steps: [Double]) -> some View {
        Picker(title, selection: value) {
            // A value set by hand on the server stays selectable.
            ForEach(Array(Set(steps + [value.wrappedValue])).sorted(), id: \.self) { r in
                Text("×\(r.formatted(.number.precision(.fractionLength(0...2))))").tag(r)
            }
        }
    }
}

/// Settings › Backups & Updates: the server's backups and its software.
struct HomeMaintenanceSettings: View {
    @EnvironmentObject private var home: HomeServer
    @EnvironmentObject private var game: GameProcess
    @Environment(\.openWindow) private var openWindow
    @State private var restoring: HomeServer.Backup?
    @State private var confirmUpdate = false

    var body: some View {
        Group {
            if home.isSetUp || isUpdating {
                form
            } else {
                NotSetUpYet()
            }
        }
        .task { await home.refresh() }
        .homeServerPolling()
        .confirmationDialog("Update the server to the newest CMaNGOS?", isPresented: $confirmUpdate) {
            Button("Update") { Task { await home.update() } }
        } message: {
            Text("The server builds the new version first, then stops the game for the rest: \(home.software?.mmaps == true ? "an hour or two, as the bots' movement maps are built again" : "about twenty minutes"). Accounts and characters are kept, and backed up first; if anything fails, the old server is put back.")
        }
        .confirmationDialog("Restore the backup of \(restoring?.date.formatted(date: .abbreviated, time: .shortened) ?? "")?",
                            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                            presenting: restoring) { backup in
            Button("Restore") { Task { await home.restore(backup) } }
        } message: { _ in
            Text("Every account and character goes back to that moment: what was played since is lost. Everyone is signed out while the server restarts, and the current state is backed up first, so this can be undone.")
        }
    }

    private var isUpdating: Bool { if case .updating = home.phase { true } else { false } }

    private var form: some View {
        Form {
            Section {
                ForEach(home.backups.prefix(5)) { backup in
                    HStack {
                        Text(backup.date.formatted(date: .abbreviated, time: .shortened))
                        if backup.beforeRestore {
                            Text("before a restore").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(backup.bytes), countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button("Restore…") { restoring = backup }
                    }
                }
                if home.backups.isEmpty {
                    Text("No backups yet.").foregroundStyle(.secondary)
                }
                Button("Back Up Now") { Task { await home.backUpNow() } }
            } header: {
                Text("Backups")
            } footer: {
                Text("Every night at 4:30 the server saves its accounts and characters\(onUnraid ? " to the array's backups share, a different disk from the server itself" : ""); the last 14 nights are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(home.isBusy || game.running || !home.isSetUp)

            Section {
                if case .updating(let step) = home.phase {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Updating: \(step)")
                    }
                }
                if let software = home.software {
                    ForEach(software.repos, id: \.name) { repo in
                        LabeledContent(repo.name) {
                            Text(repo.current ? "\(repo.built.prefix(7)), the newest"
                                              : "\(repo.built.prefix(7)) → \(repo.newest.prefix(7))")
                                .monospacedDigit()
                                .foregroundStyle(repo.current ? .secondary : .primary)
                        }
                    }
                }
                if let failed = home.updateFailed {
                    Label(failed, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Check for Updates") { Task { await home.checkForUpdates() } }
                    if let software = home.software, !software.current, !software.blocked {
                        Button("Update Server…") { confirmUpdate = true }
                    }
                    Spacer()
                    Button("Update Log") { showLogs(.homeUpdate, openWindow) }
                }
                .disabled(home.isBusy || game.running || !home.isSetUp)
            } header: {
                Text("Server software")
            } footer: {
                Text(softwareNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// Unraid's backups share, where `home-backup` keeps them there.
    private var onUnraid: Bool {
        UserDefaults.standard.string(forKey: Prefs.homeDirKey)?.hasPrefix("/mnt/user/") == true
    }

    private var softwareNote: String {
        guard let software = home.software else {
            return "CMaNGOS, its playerbots and its world database, built from source on the server. Check for Updates compares them with the newest on GitHub."
        }
        let since = software.updated.map { " Last updated \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
        if software.blocked {
            return "The newest CMaNGOS reads maps in a format this server's map tools do not write yet, so it cannot update for now.\(since)"
        }
        return (software.current ? "Everything is at its newest." : "An update keeps every account and character.") + since
    }
}

extension HomeServer {
    var statusText: String {
        switch phase {
        case .notConfigured: "Not connected"
        case .checking: "Checking…"
        case .unreachable(let why): "Can't sign in: \(why)"
        case .noDocker: "No Docker on the server"
        case .notSetUp: "Not set up"
        case .settingUp(let step): "Setting up: \(step)"
        case .updating(let step): "Updating: \(step)"
        case .busy(let what): what
        case .stopped: "Stopped"
        case .running: "Running at \(address)"
        case .failed(let why): why
        }
    }
}

private struct HomeServerPolling: ViewModifier {
    @EnvironmentObject private var home: HomeServer

    private var following: Bool {
        switch home.phase {
        case .settingUp, .updating: true
        default: false
        }
    }

    func body(content: Content) -> some View {
        content.task(id: following) {
            // Follow a setup or an update running on the server while this view is open.
            while following {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await home.refresh()
            }
        }
    }
}

extension View {
    func homeServerPolling() -> some View { modifier(HomeServerPolling()) }
}
