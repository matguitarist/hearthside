import AppKit
import SwiftUI

/// The launcher's view of the server on this Mac: install Docker, set up, its state, the first
/// account.
struct LocalServerPanel: View {
    @EnvironmentObject private var server: LocalServer
    @EnvironmentObject private var game: GameProcess
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ServerKindPicker()
            switch server.phase {
            case .checking:
                busy("Checking the server…")

            case .noDocker:
                note("Playing on this Mac runs a WoW 1.12.1 server in Docker. Install OrbStack or Docker Desktop, then check again.")
                HStack(spacing: 10) {
                    Link("Get OrbStack", destination: URL(string: "https://orbstack.dev")!)
                    Link("Get Docker Desktop", destination: URL(string: "https://www.docker.com/products/docker-desktop/")!)
                    Button("Check Again") { Task { await server.refresh() } }
                }

            case .notSetUp:
                switch server.kind {
                case .vmangos:
                    note("Sets up a WoW 1.12.1 server (vmangos) on this Mac, in \(Docker.engineName): about 1 GB to download and a few minutes, once. Your characters stay on this Mac.")
                case .cmangos:
                    note("Sets up CMaNGOS on this Mac, in \(Docker.engineName), with 100 bots that level, quest and group across the world. It is built from source, with the maps its bots walk on: about 25 minutes and 8 GB of space, once. Your characters stay on this Mac.")
                }
                Button("Set Up Server") { Task { await server.setUp() } }
                    .buttonStyle(.borderedProminent)

            case .busy(let what):
                busy(what)

            case .stopped, .running:
                status
                if server.accounts.isEmpty {
                    if server.phase == .running {
                        AccountForm(title: "Create your account", action: "Create Account")
                    } else {
                        note("Start the server to create an account.")
                        Button("Start Server") { Task { await server.start() } }
                    }
                }

            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Try Again") { Task { await server.refresh() } }
                    Button("Show Log…") { showLogs(.localCommands, openWindow) }
                }
            }
        }
        .disabled(game.running)
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(server.phase == .running ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(server.phase == .running ? "Server running" : "Server stopped · starts with Play")
            if !server.accounts.isEmpty {
                Text("· \(server.accounts.count == 1 ? "account \(server.accounts[0])" : "\(server.accounts.count) accounts")")
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

/// Which server runs on this Mac. Each has its own characters; switching leaves the other set up.
struct ServerKindPicker: View {
    @EnvironmentObject private var server: LocalServer
    @EnvironmentObject private var game: GameProcess

    var body: some View {
        Picker("Server", selection: Binding(get: { server.kind }, set: { kind in Task { await server.select(kind) } })) {
            ForEach(ServerKind.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(server.isBusy || game.running)
    }
}

/// An account name and a password for the local or the home server: a new account, or a new
/// password.
struct AccountForm: View {
    @EnvironmentObject private var server: LocalServer
    @EnvironmentObject private var homeServer: HomeServer
    let title: String
    let action: String
    var name: String? = nil
    var home = false
    var pandaria = false
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
                if let name {
                    Text(name).frame(width: 150, alignment: .leading)
                } else {
                    TextField("Account name", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                }
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit(submit)
                Button(action, action: submit)
                    .disabled(working || (name ?? typed).isEmpty || password.isEmpty)
            }
            if name == nil {
                Toggle("Administrator: game master commands and the AzerothAdmin window", isOn: $admin)
                    .font(.caption)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                Text("Letters and digits, up to 16. You sign in with these on the game's login screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func submit() {
        let account = (name ?? typed).trimmingCharacters(in: .whitespaces)
        guard !account.isEmpty, !password.isEmpty, !working else { return }
        working = true
        Task {
            let change = name != nil
            error = pandaria
                ? await PandariaServer.shared.account(account, password: password, changePassword: change, admin: admin)
                : home
                ? await homeServer.account(account, password: password, changePassword: change, admin: admin)
                : await server.account(account, password: password, changePassword: change, admin: admin)
            working = false
            if error == nil {
                password = ""
                typed = ""
                done?()
            }
        }
    }
}

/// Settings › Server: the local server's state, accounts, maps and removal.
struct ServerSettings: View {
    @EnvironmentObject private var server: LocalServer
    @EnvironmentObject private var game: GameProcess
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.keepServerKey) private var keepServer = false
    @State private var newAccount = false
    @State private var passwordFor: String?
    @State private var confirmRemove = false
    @State private var confirmFull = false

    var body: some View {
        Form {
            Section("Server on this Mac") {
                LabeledContent("Server") { ServerKindPicker() }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        StatusDot(health: server.health)
                        Text(statusText)
                    }
                }
                if server.isSetUp {
                    HStack {
                        if server.phase == .running {
                            Button("Stop Server") { Task { await server.stop() } }
                                .disabled(game.running)
                        } else {
                            Button("Start Server") { Task { await server.start() } }
                        }
                        Spacer()
                        Button("Show Server Folder") { reveal(LocalServer.dir) }
                        Button("Show Logs…") { showLogs(.localServer, openWindow) }
                    }
                    .disabled(server.isBusy)
                    Toggle(isOn: $keepServer) {
                        Text("Keep the server running")
                        Text("Otherwise it stops when the game or the launcher quits.")
                    }
                }
            }

            if server.isSetUp {
                Section("Accounts") {
                    ForEach(server.accounts, id: \.self) { name in
                        HStack {
                            Text(name)
                            Spacer()
                            Toggle("Administrator", isOn: Binding(
                                get: { server.admins.contains(name) },
                                set: { on in Task { _ = await server.setAdmin(name, on) } }))
                                .toggleStyle(.checkbox)
                            Button("Change Password…") { passwordFor = name }
                        }
                        .disabled(server.phase != .running)
                    }
                    Button("New Account…") { newAccount = true }
                        .disabled(server.phase != .running)
                    if server.phase != .running {
                        Text("Start the server to manage accounts.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("An administrator uses AzerothAdmin (/aa in the game) for levels, gold, cheats, teleports, items and bots. A change takes effect at the account's next login.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if server.hasFullExtraction {
                    Section("World Data") {
                        LabeledContent("Maps") {
                            Text(server.fullMaps ? "Full: line of sight and pathing" : "Quick: no line of sight or pathing")
                        }
                        if let since = server.extractingSince {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Extracting, started \(since.formatted(.relative(presentation: .named)))")
                                Spacer()
                                Button("Cancel") { Task { await server.cancelExtraction() } }
                            }
                        } else if !server.fullMaps {
                            Button("Extract Full Maps…") { confirmFull = true }
                                .disabled(server.isBusy)
                        }
                        Text("Without the full maps, creatures walk and cast through walls. The full extraction takes hours; you can keep playing meanwhile, and it is used from the next server start.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Remove Server…", role: .destructive) { confirmRemove = true }
                        .disabled(server.isBusy || game.running)
                }
            }
        }
        .formStyle(.grouped)
        .task { await server.refresh() }
        .task(id: server.extractingSince) {
            // Follow an extraction while this tab is open.
            while server.extractingSince != nil {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await server.refresh()
            }
        }
        .sheet(isPresented: $newAccount) {
            sheet { AccountForm(title: "New account", action: "Create") { newAccount = false } }
        }
        .sheet(item: Binding(get: { passwordFor.map(Named.init) }, set: { passwordFor = $0?.name })) { item in
            sheet { AccountForm(title: "New password", action: "Change", name: item.name) { passwordFor = nil } }
        }
        .confirmationDialog("Extract the full maps? It takes hours and a few GB.", isPresented: $confirmFull) {
            Button("Extract") { Task { await server.extractFull() } }
        }
        .confirmationDialog("Remove the server, its accounts and every character on it?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await server.remove() } }
        } message: {
            Text("The Docker images and the databases are deleted. This cannot be undone.")
        }
    }

    private var statusText: String {
        switch server.phase {
        case .checking: "Checking…"
        case .noDocker: "Needs OrbStack or Docker Desktop"
        case .notSetUp: "Not set up (choose Classic › On this Mac in the launcher)"
        case .busy(let what): what
        case .stopped: "Stopped"
        case .running: "Running at \(LocalServer.address)"
        case .failed(let why): why
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
