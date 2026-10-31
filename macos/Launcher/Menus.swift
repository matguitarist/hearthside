import AppKit
import SwiftUI

/// The launcher's menu bar: Game (play, mode, server), Server (both servers' everyday actions),
/// the Window menu's Launcher and Logs, and Help.
struct LauncherCommands: Commands {
    @ObservedObject var data: GameData
    @ObservedObject var game: GameProcess
    @ObservedObject var config: GameConfig
    @ObservedObject var updater: Updater
    @ObservedObject var server: LocalServer
    @ObservedObject var home: HomeServer
    @ObservedObject var pandaria: PandariaServer
    @AppStorage(Prefs.modeKey) private var mode: GameMode = .survivors
    @AppStorage(Prefs.classicServerKey) private var classicServer: ClassicServer = .local
    @AppStorage("settingsPane") private var settingsPane = SettingsPane.general
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheck)
        }
        CommandGroup(replacing: .newItem) {}

        CommandMenu("Game") {
            Button("Play") { Launcher.play(game: game, config: config) }
                .keyboardShortcut("p")
                .disabled(data.state != .ready || game.running || !Launcher.canPlay(server: server, home: home))
            Divider()
            Picker("Mode", selection: $mode) {
                ForEach(GameMode.allCases) { Text($0.label).tag($0) }
            }
            .disabled(game.running)
            Picker("Classic Server", selection: $classicServer) {
                ForEach(ClassicServer.allCases) { Text($0.label).tag($0) }
            }
            .disabled(game.running || mode != .classic)
            Divider()
            Button("Verify Game Files") { data.verify() }
                .disabled(data.isBusy || game.running)
            Button("Show Game Data in Finder") { reveal(Paths.data) }
            Button("Show AddOns Folder") { reveal(Addons.folder) }
            Divider()
            Button("Graphics Settings…") { settings(.graphics) }
            Button("Sound Settings…") { settings(.sound) }
        }

        CommandMenu("Server") {
            Section("On This Mac") {
                if server.phase == .running {
                    Button("Stop Server on This Mac") { Task { await server.stop() } }
                        .disabled(server.isBusy || game.running)
                } else {
                    Button("Start Server on This Mac") { Task { await server.start() } }
                        .disabled(!server.isSetUp || server.isBusy)
                }
                Button("Server on This Mac Settings…") { settings(.server) }
            }
            Section("Home Server") {
                if home.phase == .running {
                    Button("Stop Home Server") { Task { await home.stop() } }
                        .disabled(home.isBusy || game.running)
                    Button("Restart Home Server") { Task { await home.restart() } }
                        .disabled(home.isBusy || game.running)
                } else {
                    Button("Start Home Server") { Task { await home.start() } }
                        .disabled(!home.isSetUp || home.isBusy)
                }
                Button("Open Home Server Dashboard") { if let url = home.dashboard { NSWorkspace.shared.open(url) } }
                    .disabled(!home.isSetUp || home.dashboard == nil)
                Button("Back Up Home Server Now") { Task { await home.backUpNow() } }
                    .disabled(!home.isSetUp || home.isBusy || game.running)
                Button("Home Server Settings…") { settings(.homeServer) }
                Button("Bots & Rates…") { settings(.homeGame) }
                Button("Backups & Updates…") { settings(.homeMaintenance) }
            }
            Section("Pandaria") {
                if pandaria.phase == .running {
                    Button("Stop Pandaria") { Task { await pandaria.stop() } }
                        .disabled(pandaria.isBusy || game.running)
                    Button("Restart Pandaria") { Task { await pandaria.restart() } }
                        .disabled(pandaria.isBusy || game.running)
                } else {
                    Button("Start Pandaria") { Task { await pandaria.start() } }
                        .disabled(!pandaria.isSetUp || pandaria.isBusy)
                }
                Button("Pandaria Settings…") { settings(.pandaria) }
            }
            Divider()
            Button("Server Logs…") { showLogs(serverLog, openWindow) }
        }

        CommandGroup(before: .windowList) {
            Button("Launcher") { openWindow(id: "launcher") }
                .keyboardShortcut("0")
            Button("Logs") { openWindow(id: "logs") }
                .keyboardShortcut("l")
            Divider()
        }

        CommandGroup(replacing: .help) {
            Button("\(Paths.appName) Help") { help(.start) }
                .keyboardShortcut("?")
            Button("Survivors Controls") { help(.controls) }
            Button("Troubleshooting") { help(.troubleshooting) }
            Divider()
            Button("Release Notes") { NSWorkspace.shared.open(Links.releases) }
            Button("Report a Problem…") { NSWorkspace.shared.open(Links.newIssue) }
            Button("Project Page") { NSWorkspace.shared.open(Links.project) }
            Divider()
            Button("Play the Original in a Browser") { NSWorkspace.shared.open(Links.original) }
        }
    }

    /// The log of the server the current mode plays on.
    private var serverLog: LogSource {
        switch mode {
        case .pandaria: .pandariaWorld
        case .classic where classicServer == .home: .homeServer
        default: .localServer
        }
    }

    private func settings(_ pane: SettingsPane) {
        settingsPane = pane
        openSettings()
    }

    private func help(_ topic: HelpTopic) {
        HelpNavigator.shared.topic = topic
        openWindow(id: "help")
    }
}

/// Where the app's pages live: its GitHub repository, read from the update feed it was built with.
enum Links {
    static let project: URL = {
        let feed = Bundle.main.infoDictionary?["SUFeedURL"] as? String ?? ""
        let repo = feed.components(separatedBy: "/releases/").first ?? ""
        return URL(string: repo.hasPrefix("https://github.com/") ? repo : "https://github.com/matguitarist/hearthside")!
    }()
    static var releases: URL { project.appendingPathComponent("releases") }
    static var newIssue: URL { project.appendingPathComponent("issues/new") }
    static let original = URL(string: "https://wow.aethus.pl/")!
}
