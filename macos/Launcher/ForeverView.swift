import AppKit
import SwiftUI

/// The launcher's view of Forever: the client's folder, the server on the home server, and the
/// first account. Play does the rest.
struct ForeverPanel: View {
    @EnvironmentObject private var forever: ForeverServer
    @EnvironmentObject private var home: HomeServer
    @EnvironmentObject private var game: GameProcess
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsPane") private var settingsPane = SettingsPane.general
    @AppStorage(Prefs.foreverFolderKey) private var folderPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = clientProblem {
                note("WoW Forever with bots, on your home server, played with your own Forever client from Battle.net.")
                if !folderPath.isEmpty {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                }
                Button("Choose World of Warcraft Folder…") { ForeverFolderPicker.choose() }
                    .help("The folder Battle.net installs World of Warcraft in, with WoW Forever in _forever_")
            } else {
                server
                if let what = forever.preparing {
                    busy(what)
                } else if let why = forever.clientError {
                    Label(why, systemImage: "exclamationmark.triangle.fill")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .disabled(game.running)
        .foreverPolling()
    }

    private var clientProblem: String? {
        _ = folderPath
        return ForeverClient.problem
    }

    @ViewBuilder private var server: some View {
        switch forever.phase {
        case .notConnected:
            note("Forever runs on your home server. Connect the launcher to it first.")
            Button("Home Server Settings…") { settings(.homeServer) }

        case .checking:
            busy("Looking at the home server…")

        case .unreachable(let why):
            Label("Can't sign in to \(home.host): \(why)", systemImage: "exclamationmark.triangle.fill")
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { Task { await forever.refresh() } }

        case .noDocker:
            note("\(home.address) has no Docker. Install it there (on Unraid: Settings › Docker), then try again.")
            Button("Try Again") { Task { await forever.refresh() } }

        case .notSetUp:
            note("Sets up Forever on \(home.address): the server is built there from source, an hour or more on a small CPU, while this Mac reads the game data from your client in \(Docker.engineName) and sends it over (a few GB).")
            Button("Set Up Forever") { Task { await forever.setUp() } }
                .buttonStyle(.borderedProminent)
                .help("Build the Forever server on the home server and send it the game data")

        case .settingUp(let step):
            busy(step)
            note("The setup runs on the server: you can quit the launcher and come back.")

        case .needsData:
            note("The server is waiting for the game data, read from your client on this Mac in \(Docker.engineName).")
            Button("Send the Game Data") { Task { await forever.copyData() } }
                .buttonStyle(.borderedProminent)

        case .busy(let what):
            busy(what)

        case .starting:
            busy("Starting: the world and its bots are loading…")

        case .stopped, .running:
            status
            if forever.accounts.isEmpty {
                if forever.phase == .running {
                    ForeverAccountForm(title: "Create your account", action: "Create Account")
                } else {
                    Button("Start Server") { Task { await forever.start() } }
                }
            } else if let email = forever.playAccount, !ForeverKeychain.has(email) {
                ForeverAccountForm(title: "Your password", action: "Save", email: email, mode: .remember)
            }

        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Try Again") { Task { await forever.refresh() } }
                Button("Show Log…") { showLogs(forever.isSetUp ? .foreverWorld : .foreverSetup, openWindow) }
            }
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            StatusDot(health: forever.health)
            Text(forever.phase == .running ? "Running at \(home.address)" : "Stopped · starts with Play")
            if let bots = forever.bots, bots > 0 { Text("· \(bots) bots online").foregroundStyle(.secondary) }
            if let email = forever.playAccount {
                Text("· \(email.lowercased())").foregroundStyle(.secondary)
            }
        }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func settings(_ pane: SettingsPane) {
        settingsPane = pane
        openSettings()
    }
}

/// An email and a password for a Forever account: a new account, a new password, or the password
/// of an account Hearthside doesn't know yet (kept in the Keychain for Play).
struct ForeverAccountForm: View {
    enum Mode { case create, change, remember }

    let title: String
    let action: String
    var email: String? = nil
    var mode: Mode = .create
    var done: (() -> Void)? = nil

    @State private var typed = ""
    @State private var password = ""
    @State private var admin = true
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack(spacing: 8) {
                if let email {
                    Text(email.lowercased()).frame(width: 200, alignment: .leading)
                } else {
                    TextField("Email", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                        .frame(width: 200)
                }
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit(submit)
                Button(action, action: submit)
                    .disabled(working || (email ?? typed).isEmpty || password.isEmpty)
            }
            if mode == .create {
                Toggle("Administrator: game master commands", isOn: $admin)
                    .font(.caption)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var caption: String {
        switch mode {
        case .create: "Any email: it is only the account's name on your server. 4 to 16 characters for the password. Hearthside keeps it in your Keychain and signs in for you at Play."
        case .change: "4 to 16 characters. Hearthside keeps it in your Keychain."
        case .remember: "The account's password on your server. Hearthside keeps it in your Keychain and signs in for you at Play."
        }
    }

    private func submit() {
        let account = (email ?? typed).trimmingCharacters(in: .whitespaces)
        guard !account.isEmpty, !password.isEmpty, !working else { return }
        if mode == .remember {
            ForeverKeychain.save(password, for: account)
            ForeverServer.shared.objectWillChange.send()
            password = ""
            done?()
            return
        }
        working = true
        Task {
            error = await ForeverServer.shared.account(account, password: password, changePassword: mode == .change, admin: admin)
            working = false
            if error == nil {
                password = ""
                typed = ""
                done?()
            }
        }
    }
}

/// Choosing the World of Warcraft folder: the one holding `_forever_`.
@MainActor
enum ForeverFolderPicker {
    static func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose your World of Warcraft folder: the one Battle.net installed, holding _forever_."
        if let folder = ForeverClient.folder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, var url = panel.url else { return }
        // _forever_ itself, chosen by mistake: its parent.
        if url.lastPathComponent == "_forever_" { url.deleteLastPathComponent() }
        UserDefaults.standard.set(url.path, forKey: Prefs.foreverFolderKey)
        ForeverServer.shared.clientError = nil
    }
}

/// Settings › Forever: the client, the server, its accounts.
struct ForeverSettings: View {
    @EnvironmentObject private var forever: ForeverServer
    @EnvironmentObject private var home: HomeServer
    @EnvironmentObject private var game: GameProcess
    @Environment(\.openWindow) private var openWindow
    @AppStorage("settingsPane") private var settingsPane = SettingsPane.general
    @AppStorage(Prefs.foreverFolderKey) private var folderPath = ""
    @AppStorage(Prefs.foreverAccountKey) private var playAs = ""
    @State private var newAccount = false
    @State private var passwordFor: Named?

    var body: some View {
        Form {
            client
            server
            if forever.isSetUp {
                ForeverBotSettings()
                accounts
            }
        }
        .formStyle(.grouped)
        .task { await forever.refresh() }
        .foreverPolling()
        .sheet(isPresented: $newAccount) {
            sheet { ForeverAccountForm(title: "New account", action: "Create") { newAccount = false } }
        }
        .sheet(item: $passwordFor) { item in
            sheet {
                ForeverAccountForm(title: item.change ? "New password" : "Password", action: item.change ? "Change" : "Save",
                                   email: item.name, mode: item.change ? .change : .remember) { passwordFor = nil }
            }
        }
    }

    private var clientProblem: String? {
        _ = folderPath
        return ForeverClient.problem
    }

    private var client: some View {
        Section {
            LabeledContent("Folder") {
                Text(folderPath.isEmpty ? "None chosen" : folderPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(folderPath.isEmpty ? .secondary : .primary)
            }
            if let problem = clientProblem, !folderPath.isEmpty {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
            }
            if clientProblem == nil, let original = ForeverClient.original, let build = ForeverClient.build(original) {
                LabeledContent("Client build") { Text(build).monospacedDigit() }
            }
            LabeledContent("Prepared for Forever") {
                if forever.preparing != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Text(clientProblem == nil && ForeverClient.isCurrent ? "Yes"
                         : ForeverClient.isPrepared ? "Again at the next Play" : "Not yet, at the first Play")
                        .foregroundStyle(.secondary)
                }
            }
            if let why = forever.clientError {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Choose…") { ForeverFolderPicker.choose() }
                    .help("The folder Battle.net installs World of Warcraft in, with WoW Forever in _forever_")
                if let dir = ForeverClient.dir {
                    Button("Show in Finder") { reveal(dir) }
                }
                Spacer()
                Button("Prepare Again") { Task { await forever.prepareAgain() } }
                    .help(game.running ? "Quit the game first" : "Make Hearthside's copy of the client again")
                    .disabled(clientProblem != nil || forever.preparing != nil || game.running || home.address.isEmpty)
            }
        } header: {
            Text("Client")
        } footer: {
            Text("Your own WoW Forever, installed by Battle.net, which stays as it is. The first Play makes a copy beside it, Hearthside Forever.app, that signs in to your server instead of Blizzard's: macOS asks once for an administrator's password, to send the login's name to your server, then to trust your server's login certificate. Battle.net's updates to the game make a new copy at the next Play. Preparing needs Apple's command line developer tools.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var server: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    StatusDot(health: forever.health)
                    Text(forever.statusText(home)).multilineTextAlignment(.trailing)
                }
            }
            if let bots = forever.bots, forever.phase == .running {
                LabeledContent("Bots online") { Text("\(bots)").monospacedDigit() }
            }
            switch forever.phase {
            case .notConnected:
                Button("Home Server Settings…") { settingsPane = .homeServer }
            case .notSetUp:
                Button("Set Up Forever") { Task { await forever.setUp() } }
                    .disabled(clientProblem != nil)
                    .help("Build the Forever server on the home server and send it the game data")
                if clientProblem != nil {
                    Text("Choose your World of Warcraft folder above first: the game data is read from it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .needsData:
                Button("Send the Game Data") { Task { await forever.copyData() } }
                    .disabled(clientProblem != nil)
            default:
                if forever.isSetUp || forever.isBusy {
                    HStack {
                        if forever.phase == .running || forever.phase == .starting {
                            Button("Stop Server") { Task { await forever.stop() } }
                                .disabled(game.running)
                                .help(game.running ? "Quit the game first" : "Stop Forever's servers and its database")
                            Button("Restart") { Task { await forever.restart() } }
                                .disabled(game.running)
                                .help(game.running ? "Quit the game first" : "Stop and start Forever again")
                        } else {
                            Button("Start Server") { Task { await forever.start() } }
                                .help("Start Forever on the home server")
                        }
                        Spacer()
                        Button("Send the Game Data Again") { Task { await forever.copyData() } }
                            .help("Read the game data from the client again, after Battle.net updated it, and send it to the server")
                            .disabled(clientProblem != nil)
                        Button("Show Logs…") { showLogs(.foreverWorld, openWindow) }
                    }
                    .disabled(forever.isBusy)
                }
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Forever runs on the home server beside Classic and Pandaria, on its own ports. It keeps running when the game quits.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var accounts: some View {
        Section {
            if forever.accounts.count > 1 {
                Picker("Play as", selection: Binding(get: { forever.playAccount ?? "" }, set: { playAs = $0 })) {
                    ForEach(forever.accounts, id: \.self) { Text($0.lowercased()).tag($0) }
                }
            }
            ForEach(forever.accounts, id: \.self) { email in
                HStack {
                    Text(email.lowercased())
                    if !ForeverKeychain.has(email) {
                        Button("Enter Password…") { passwordFor = Named(name: email, change: false) }
                            .help("Hearthside signs in with it at Play")
                    }
                    Spacer()
                    Toggle("Administrator", isOn: Binding(
                        get: { forever.admins.contains(email) },
                        set: { on in Task { _ = await forever.setAdmin(email, on) } }))
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("\(email.lowercased()) is an administrator")
                    Button("Change Password…") { passwordFor = Named(name: email, change: true) }
                        .accessibilityLabel("Change \(email.lowercased())'s password")
                }
                .disabled(forever.phase != .running)
            }
            Button("New Account…") { newAccount = true }
                .disabled(forever.phase != .running)
        } header: {
            Text("Accounts")
        } footer: {
            Text(forever.phase == .running
                 ? "Battle.net accounts on your server, named by an email that never leaves it. Hearthside signs in to the one you play as. A game master change takes effect at the account's next login."
                 : "Start the server to manage accounts.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
        let change: Bool
        var id: String { name + (change ? "/change" : "") }
    }
}

/// Settings › Forever › Bots: how many at most in the world, and around each player. Saved into the
/// server's settings; a running world restarts with them.
private struct ForeverBotSettings: View {
    @EnvironmentObject private var forever: ForeverServer
    @EnvironmentObject private var game: GameProcess
    @State private var total = ForeverServer.defaultBots
    @State private var perPlayer = ForeverServer.defaultBotsPerPlayer

    private var changed: Bool { total != forever.botLimit || perPlayer != forever.botsPerPlayer }
    private var running: Bool { forever.phase == .running || forever.phase == .starting }

    var body: some View {
        Section {
            LabeledContent("Bots in the world") {
                HStack(spacing: 6) {
                    TextField("Bots in the world", value: $total, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Stepper("Bots in the world", value: $total, in: 0...2000, step: 20).labelsHidden()
                }
            }
            LabeledContent("Around each player") {
                HStack(spacing: 6) {
                    TextField("Around each player", value: $perPlayer, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Stepper("Around each player", value: $perPlayer, in: 0...500, step: 10).labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button("Revert") { load() }
                    .disabled(!changed)
                Button(running ? "Save & Restart" : "Save") {
                    Task { await forever.setBots(total: total, perPlayer: perPlayer) }
                }
                .disabled(!changed || forever.isBusy || game.running)
                .help(game.running ? "Quit the game first" : running ? "Restart Forever with these settings" : "Used at the next start")
            }
        } header: {
            Text("Bots")
        } footer: {
            Text("The bots wake in the world around the players: up to \"Around each player\" near each one, never more than \"Bots in the world\" in all, and they sleep again when nobody is near. More bots take more of the server's memory and CPU. Saving restarts a running server, disconnecting anyone playing for a few minutes. The dashboard changes them too.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: load)
        .onChange(of: forever.botLimit) { _, _ in load() }
        .onChange(of: forever.botsPerPlayer) { _, _ in load() }
    }

    private func load() {
        total = forever.botLimit
        perPlayer = forever.botsPerPlayer
    }
}

extension ForeverServer {
    var health: Health {
        switch phase {
        case .running: .up
        case .checking, .busy, .settingUp, .starting: .working
        case .stopped, .unreachable, .noDocker, .failed, .needsData: .down
        case .notConnected, .notSetUp: .off
        }
    }

    func statusText(_ home: HomeServer) -> String {
        switch phase {
        case .notConnected: "The home server is not connected"
        case .checking: "Checking…"
        case .unreachable(let why): "Can't sign in: \(why)"
        case .noDocker: "No Docker on the server"
        case .notSetUp: "Not set up"
        case .settingUp(let step): "Setting up: \(step)"
        case .needsData: "Waiting for the game data"
        case .busy(let what): what
        case .starting: "Starting: the world is loading"
        case .stopped: "Stopped"
        case .running: "Running at \(home.address)"
        case .failed(let why): why
        }
    }
}

private struct ForeverPolling: ViewModifier {
    @EnvironmentObject private var forever: ForeverServer

    private var following: Bool {
        switch forever.phase {
        case .settingUp, .starting: true
        default: false
        }
    }

    func body(content: Content) -> some View {
        content.task(id: following) {
            while following {
                try? await Task.sleep(for: .seconds(15))
                await forever.refresh()
            }
        }
    }
}

extension View {
    func foreverPolling() -> some View { modifier(ForeverPolling()) }
}
