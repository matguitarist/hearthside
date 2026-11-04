import AppKit
import SwiftUI

/// The launcher's view of Pandaria: the client's folder, the server on the home server, and the
/// first account. Play does the rest.
struct PandariaPanel: View {
    @EnvironmentObject private var pandaria: PandariaServer
    @EnvironmentObject private var home: HomeServer
    @EnvironmentObject private var game: GameProcess
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsPane") private var settingsPane = SettingsPane.general
    @AppStorage(Prefs.pandariaFolderKey) private var folderPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = clientProblem {
                note("Mists of Pandaria 5.4.8 with bots, on your home server, played with your own World of Warcraft 5.4.8 for Mac.")
                if !folderPath.isEmpty {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                }
                Button("Choose Client Folder…") { PandariaFolderPicker.choose() }
                    .help("The folder that holds World of Warcraft-64.app and its Data folder")
            } else {
                server
                if pandaria.preparing {
                    busy("Preparing the client: its patches and graphics fixes…")
                } else if let why = pandaria.clientError {
                    Label(why, systemImage: "exclamationmark.triangle.fill")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .disabled(game.running)
        .pandariaPolling()
    }

    /// Read again as the folder changes.
    private var clientProblem: String? {
        _ = folderPath
        return PandariaClient.problem
    }

    @ViewBuilder private var server: some View {
        switch pandaria.phase {
        case .notConnected:
            note("Pandaria runs on your home server. Connect the launcher to it first.")
            Button("Home Server Settings…") { settings(.homeServer) }

        case .checking:
            busy("Looking at the home server…")

        case .unreachable(let why):
            Label("Can't sign in to \(home.host): \(why)", systemImage: "exclamationmark.triangle.fill")
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { Task { await pandaria.refresh() } }

        case .noDocker:
            note("\(home.address) has no Docker. Install it there (on Unraid: Settings › Docker), then try again.")
            Button("Try Again") { Task { await pandaria.refresh() } }

        case .notSetUp:
            note("Sets up Pandaria on \(home.address): your client's game files (about 23 GB) are copied there, then the server is built from source, a few hours on a small CPU. You can quit the launcher meanwhile.")
            Button("Set Up Pandaria") { Task { await pandaria.setUp() } }
                .buttonStyle(.borderedProminent)
                .help("Copy the client's game files to the home server and build Pandaria there")

        case .settingUp(let step):
            busy(step)
            note("The setup runs on the server: you can quit the launcher and come back.")

        case .busy(let what):
            busy(what)

        case .starting:
            busy("Starting: the world and its bots are loading…")

        case .stopped, .running:
            status
            if pandaria.accounts.isEmpty {
                if pandaria.phase == .running {
                    AccountForm(title: "Create your account", action: "Create Account", pandaria: true)
                } else {
                    Button("Start Server") { Task { await pandaria.start() } }
                }
            }

        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Try Again") { Task { await pandaria.refresh() } }
                Button("Show Log…") { showLogs(pandaria.isSetUp ? .pandariaWorld : .pandariaSetup, openWindow) }
            }
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            StatusDot(health: pandaria.health)
            Text(pandaria.phase == .running ? "Running at \(home.address)" : "Stopped · starts with Play")
            if let bots = pandaria.bots { Text("· \(bots) bots online").foregroundStyle(.secondary) }
            if !pandaria.accounts.isEmpty {
                Text("· \(pandaria.accounts.count == 1 ? "account \(pandaria.accounts[0])" : "\(pandaria.accounts.count) accounts")")
                    .foregroundStyle(.secondary)
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

/// Choosing the 5.4.8 folder: the one holding the app and its Data folder.
@MainActor
enum PandariaFolderPicker {
    static func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose your World of Warcraft 5.4.8 folder: the one holding World of Warcraft-64.app and Data."
        if let folder = PandariaClient.folder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: Prefs.pandariaFolderKey)
        PandariaServer.shared.clientError = nil
    }
}

/// Settings › Pandaria: the client, the server, its accounts.
struct PandariaSettings: View {
    @EnvironmentObject private var pandaria: PandariaServer
    @EnvironmentObject private var home: HomeServer
    @EnvironmentObject private var game: GameProcess
    @Environment(\.openWindow) private var openWindow
    @AppStorage("settingsPane") private var settingsPane = SettingsPane.general
    @AppStorage(Prefs.pandariaFolderKey) private var folderPath = ""
    @AppStorage(Prefs.pandariaOcclusionKey) private var occlusion = true
    @AppStorage(Prefs.pandariaMistKey) private var mist = true
    @State private var newAccount = false
    @State private var passwordFor: String?

    var body: some View {
        Form {
            client
            graphics
            server
            if pandaria.isSetUp { accounts }
        }
        .formStyle(.grouped)
        .task { await pandaria.refresh() }
        .pandariaPolling()
        .sheet(isPresented: $newAccount) {
            sheet { AccountForm(title: "New account", action: "Create", pandaria: true) { newAccount = false } }
        }
        .sheet(item: Binding(get: { passwordFor.map(Named.init) }, set: { passwordFor = $0?.name })) { item in
            sheet { AccountForm(title: "New password", action: "Change", name: item.name, pandaria: true) { passwordFor = nil } }
        }
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
            LabeledContent("Prepared for Pandaria") {
                if pandaria.preparing {
                    ProgressView().controlSize(.small)
                } else {
                    Text(clientProblem == nil && PandariaClient.isPrepared ? "Yes" : "Not yet, at the first Play")
                        .foregroundStyle(.secondary)
                }
            }
            if let why = pandaria.clientError {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Choose…") { PandariaFolderPicker.choose() }
                    .help("The folder that holds World of Warcraft-64.app and its Data folder")
                if let folder = PandariaClient.folder {
                    Button("Show in Finder") { reveal(folder) }
                }
                Spacer()
                Button("Prepare Again") { Task { await pandaria.prepareAgain() } }
                    .help(game.running ? "Quit the game first" : "Patch the client again from the app inside the folder, with this version's fixes")
                    .disabled(clientProblem != nil || pandaria.preparing || game.running || home.address.isEmpty)
            }
        } header: {
            Text("Client")
        } footer: {
            Text("Your own World of Warcraft 5.4.8 for Mac. The first Play prepares it: it is patched to sign in to your server and to run on Apple silicon, its graphics get fixes, AMD FSR sharpening, ambient occlusion and ground mist, and it gets AzerothPlus and AzerothAdmin for 5.4.8. Preparing needs Apple's command line developer tools.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var graphics: some View {
        Section {
            Toggle("Ambient occlusion", isOn: $occlusion)
            Toggle("Ground mist", isOn: $mist)
        } header: {
            Text("Graphics")
        } footer: {
            Text("Survivors' effects, added to the client. Ambient occlusion shades the corners and contact points of the world and replaces the client's own, which is turned off while it's on. Ground mist gathers in hollows and valleys and is lit by the sun through the trees. Both apply at the next Play; in the game, Control-Option-O and Control-Option-M switch them: on, off, then the effect alone.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(game.running)
    }

    /// Read again as the folder changes.
    private var clientProblem: String? {
        _ = folderPath
        return PandariaClient.problem
    }

    private var server: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    StatusDot(health: pandaria.health)
                    Text(pandaria.statusText(home)).multilineTextAlignment(.trailing)
                }
            }
            if let bots = pandaria.bots, pandaria.phase == .running {
                LabeledContent("Bots online") { Text("\(bots)").monospacedDigit() }
            }
            switch pandaria.phase {
            case .notConnected:
                Button("Home Server Settings…") { settingsPane = .homeServer }
            case .notSetUp:
                Button("Set Up Pandaria") { Task { await pandaria.setUp() } }
                    .disabled(clientProblem != nil)
                    .help("Copy the client's game files to the home server and build Pandaria there")
                if clientProblem != nil {
                    Text("Choose your 5.4.8 client folder above first: the setup copies its game files.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            default:
                if pandaria.isSetUp || pandaria.isBusy {
                    HStack {
                        if pandaria.phase == .running || pandaria.phase == .starting {
                            Button("Stop Server") { Task { await pandaria.stop() } }
                                .disabled(game.running)
                                .help(game.running ? "Quit the game first" : "Stop Pandaria's servers and its database")
                            Button("Restart") { Task { await pandaria.restart() } }
                                .disabled(game.running)
                                .help(game.running ? "Quit the game first" : "Stop and start Pandaria again")
                        } else {
                            Button("Start Server") { Task { await pandaria.start() } }
                                .help("Start Pandaria; Classic on the home server stops")
                        }
                        Spacer()
                        Button("Show Logs…") { showLogs(.pandariaWorld, openWindow) }
                    }
                    .disabled(pandaria.isBusy)
                }
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Pandaria runs on the home server beside Classic, one at a time: starting one stops the other. It keeps running when the game quits.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var accounts: some View {
        Section {
            ForEach(pandaria.accounts, id: \.self) { name in
                HStack {
                    Text(name)
                    Spacer()
                    Toggle("Administrator", isOn: Binding(
                        get: { pandaria.admins.contains(name) },
                        set: { on in Task { _ = await pandaria.setAdmin(name, on) } }))
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("\(name) is an administrator")
                    Button("Change Password…") { passwordFor = name }
                        .accessibilityLabel("Change \(name)'s password")
                }
                .disabled(pandaria.phase != .running)
            }
            Button("New Account…") { newAccount = true }
                .disabled(pandaria.phase != .running)
        } header: {
            Text("Accounts")
        } footer: {
            Text(pandaria.phase == .running
                 ? "An administrator uses AzerothAdmin (/aa in the game) for levels, gold, cheats, teleports and items. A change takes effect at the account's next login."
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
        var id: String { name }
    }
}

extension PandariaServer {
    var health: Health {
        switch phase {
        case .running: .up
        case .checking, .busy, .settingUp, .starting: .working
        case .stopped, .unreachable, .noDocker, .failed: .down
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
        case .busy(let what): what
        case .starting: "Starting: the world is loading"
        case .stopped: "Stopped"
        case .running: "Running at \(home.address)"
        case .failed(let why): why
        }
    }
}

private struct PandariaPolling: ViewModifier {
    @EnvironmentObject private var pandaria: PandariaServer

    private var following: Bool {
        switch pandaria.phase {
        case .settingUp, .starting: true
        default: false
        }
    }

    func body(content: Content) -> some View {
        content.task(id: following) {
            // Follow a setup on the server, or a world loading, while this view is open.
            while following {
                try? await Task.sleep(for: .seconds(15))
                await pandaria.refresh()
            }
        }
    }
}

extension View {
    func pandariaPolling() -> some View { modifier(PandariaPolling()) }
}
