import AppKit
import SwiftUI

/// The launcher window: key art, the data status, and Play.
struct LauncherView: View {
    @EnvironmentObject private var data: GameData
    @EnvironmentObject private var game: GameProcess
    @EnvironmentObject private var config: GameConfig
    @EnvironmentObject private var server: LocalServer
    @EnvironmentObject private var home: HomeServer
    @EnvironmentObject private var pandaria: PandariaServer
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.skipLauncherKey) private var skipLauncher = false
    @AppStorage(Prefs.modeKey) private var mode: GameMode = .survivors
    @AppStorage(Prefs.classicServerKey) private var classicServer: ClassicServer = .local
    @AppStorage(Prefs.remoteServerKey) private var remoteServer = ""
    @AppStorage(Prefs.keepServerKey) private var keepServer = false
    @State private var autoPlayed = false

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "Version \(v)"
    }

    var body: some View {
        ZStack {
            background
            // Dark at the top for the title, darker at the bottom for the panel and Play.
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                   .init(color: .clear, location: 0.28),
                                   .init(color: .black.opacity(0.5), location: 0.55),
                                   .init(color: .black.opacity(0.92), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            // The same frame in every mode: title and modes at the top, Play and the version at
            // the bottom, the mode's panel growing upward from Play.
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    Text(Paths.appName)
                        .font(.system(size: 34, weight: .heavy, design: .serif))
                        .shadow(radius: 6)
                    Spacer()
                    if data.state == .ready {
                        Picker("Mode", selection: $mode) {
                            ForEach(GameMode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 300)
                        .disabled(game.running)
                    }
                }
                Spacer(minLength: 16)
                status
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .center, spacing: 16) {
                    if data.state == .ready { playButton }
                    Spacer()
                    Text(version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 18)
                .frame(minHeight: 34)
            }
            .padding(28)
            .foregroundStyle(.white)
        }
        .frame(width: 820, height: 480)
        .environment(\.colorScheme, .dark)
        .onAppear(perform: appeared)
        .onChange(of: game.running) { _, running in
            if !running {
                config.reload()
                data.quickCheck()
                gameQuit()
            }
        }
        .onChange(of: mode) { _, _ in prewarm() }
        .onChange(of: classicServer) { _, _ in prewarm() }
        .onChange(of: game.stuck) { _, stuck in
            if stuck { Launcher.surface() } else if game.running { Launcher.resubmerge() }
        }
        .background {
            Color.clear.alert("The game isn't starting", isPresented: .constant(game.stuck)) {
                Button("Keep Waiting", role: .cancel) { game.keepWaiting() }
                Button("Force Quit", role: .destructive) { game.forceQuit() }
            } message: {
                Text("It has been running for \(Int(GameProcess.stuckAfter)) seconds without opening its window. This usually means the sound output device isn't answering, for example a remote-desktop audio driver. Switching the sound output in System Settings, then trying again, usually fixes it.")
            }
        }
        .alert(item: $game.crash) { crash in
            Alert(title: Text("The game stopped unexpectedly"),
                  message: Text(crash.message + (crash.logTail.isEmpty ? "" : "\n\nThe log is in ~/Library/Logs/\(Paths.appName).")),
                  primaryButton: .default(Text("Show Log")) { showLogs(.game, openWindow) },
                  secondaryButton: .cancel(Text("OK")))
        }
    }

    /// Each mode's key art, crossfading as the mode changes.
    @ViewBuilder private var background: some View {
        ZStack {
            Color(red: 0.08, green: 0.07, blue: 0.1)
            if let image = KeyArt.image(for: mode) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 820, height: 480)
                    .clipped()
                    .id(mode)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: mode)
    }

    @ViewBuilder private var status: some View {
        switch data.state {
        case .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking game files…")
            }

        case .ready:
            switch mode {
            case .survivors:
                Text("Pick a race, a class and a zone, then survive the waves. Your picks are remembered between runs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 560, alignment: .leading)
            case .classic: classic
            case .pandaria: PandariaPanel().frame(maxWidth: 560, alignment: .leading)
            }

        case .missing(let files):
            let size = files.reduce(Int64(0)) { $0 + $1.size }
            VStack(alignment: .leading, spacing: 10) {
                Text(files.count == data.manifest.count
                     ? "The game needs the World of Warcraft 1.12.1 client's data (\(bytes(size)))."
                     : "\(files.count) game file\(files.count == 1 ? " is" : "s are") missing or damaged (\(bytes(size))).")
                    .font(.headline)
                Text("It's downloaded once from archive.org into \(Paths.data.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~")). No Blizzard files ship with this app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button(files.count == data.manifest.count ? "Download" : "Download Missing Files") {
                        data.download(files)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    Button("Use an Existing Folder…", action: chooseFolder)
                }
            }

        case .working(let p):
            VStack(alignment: .leading, spacing: 8) {
                Text(p.title).font(.headline)
                ProgressView(value: p.fraction)
                    .frame(maxWidth: 520)
                HStack {
                    Text(p.detail)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer().frame(width: 16)
                    Button("Pause") { data.cancel() }
                        .controlSize(.small)
                }
                .frame(maxWidth: 520, alignment: .leading)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Try Again") { data.quickCheck() }
                        .buttonStyle(.borderedProminent)
                    Text("Finished files are kept.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var playButton: some View {
        HStack(spacing: 16) {
            Button(action: play) {
                Text(game.running ? "Playing" : "Play")
                    .font(.title2.weight(.bold))
                    .frame(width: 180, height: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.75, green: 0.45, blue: 0.1))
            .keyboardShortcut(.defaultAction)
            .disabled(game.running || !Launcher.canPlay(server: server, home: home))
            SettingsLink()
        }
    }

    /// Classic: the server on this Mac, the home server, or one at an address.
    @ViewBuilder private var classic: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Server", selection: $classicServer) {
                ForEach(ClassicServer.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()
            .disabled(game.running)
            switch classicServer {
            case .local: LocalServerPanel()
            case .home: HomeServerPanel()
            case .remote: remote
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder private var remote: some View {
        HStack(spacing: 8) {
            Text("Address")
            TextField(Realm.fallback, text: $remoteServer)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .disabled(game.running)
        }
        Text("A WoW 1.12.1 server without the Warden anticheat, which this client does not have. You sign in on the game's login screen.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Start the local server ahead of Play: it takes about a minute. The home server is only
    /// looked at.
    private func prewarm() {
        Task {
            if mode == .pandaria { await pandaria.refresh(); return }
            if mode == .classic, classicServer == .home { await home.refresh(); return }
            await server.refresh()
            guard mode == .classic, classicServer == .local, !game.running, server.phase == .stopped else { return }
            await server.start()
        }
    }

    /// After a game: the address the login screen may have changed comes back to the launcher,
    /// and the local server stops unless Settings keeps it. The home server keeps running.
    private func gameQuit() {
        guard mode == .classic else { return }
        switch classicServer {
        case .remote:
            let now = config.value(Realm.cvar, default: Realm.fallback)
            if now != Realm.fallback, now != LocalServer.address, now != home.address { remoteServer = now }
        case .home:
            break
        case .local:
            if !keepServer { Task { await server.stop() } }
        }
    }

    private func appeared() {
        game.onExit = { Launcher.gameEnded(crashed: $0) }
        Launcher.openLauncher = { [openWindow] in openWindow(id: "launcher") }
        data.quickCheck()
        if remoteServer.isEmpty {
            let saved = config.value(Realm.cvar, default: Realm.fallback)
            if saved != Realm.fallback, saved != LocalServer.address, saved != home.address { remoteServer = saved }
        }
        prewarm()
        // "Start the game directly", unless ⌥ is held to reach the launcher.
        if skipLauncher, !autoPlayed, data.state == .ready, !NSEvent.modifierFlags.contains(.option) {
            autoPlayed = true
            play()
        }
    }

    private func play() {
        Launcher.play(game: game, config: config)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose a World of Warcraft 1.12.1 Data folder (the one holding patch.MPQ)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: Prefs.dataPathKey)
        data.quickCheck()
    }
}

extension GameProcess.Crash: Equatable {
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// The launcher's key art per mode: `survivors.heic` from the README's screenshot, and Classic's and
/// Pandaria's when the app was built with them (`macos/art/`), else Survivors'.
@MainActor
enum KeyArt {
    private static var cache: [GameMode: NSImage] = [:]

    static func image(for mode: GameMode) -> NSImage? {
        if let image = cache[mode] { return image }
        let name = switch mode {
        case .survivors: "survivors"
        case .classic: "classic"
        case .pandaria: "pandaria"
        }
        let url = Bundle.main.url(forResource: name, withExtension: "heic")
            ?? Bundle.main.url(forResource: "survivors", withExtension: "heic")
        let image = url.flatMap(NSImage.init(contentsOf:))
        cache[mode] = image
        return image
    }
}
