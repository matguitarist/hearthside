import AppKit
import SwiftUI

/// The panes of Settings, in its sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, graphics, sound, survivors, server, homeServer, homeGame, homeMaintenance, pandaria, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .graphics: "Graphics"
        case .sound: "Sound"
        case .survivors: "Survivors"
        case .server: "Server on This Mac"
        case .homeServer: "Home Server"
        case .homeGame: "Bots & Rates"
        case .homeMaintenance: "Backups & Updates"
        case .pandaria: "Pandaria"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .graphics: "display"
        case .sound: "speaker.wave.2"
        case .survivors: "flame"
        case .server: "desktopcomputer"
        case .homeServer: "house"
        case .homeGame: "person.2"
        case .homeMaintenance: "clock.arrow.circlepath"
        case .pandaria: "mountain.2"
        case .advanced: "wrench.and.screwdriver"
        }
    }

    static let sections: [(String?, [SettingsPane])] = [
        (nil, [.general, .graphics, .sound]),
        ("Azeroth Survivors", [.survivors]),
        ("Classic servers", [.server, .homeServer, .homeGame, .homeMaintenance]),
        ("Mists of Pandaria", [.pandaria]),
        (nil, [.advanced]),
    ]
}

/// A sidebar like System Settings', each pane scrolling within a window of a fixed size.
struct SettingsView: View {
    @AppStorage("settingsPane") private var pane = SettingsPane.general
    @EnvironmentObject private var server: LocalServer
    @EnvironmentObject private var home: HomeServer
    @EnvironmentObject private var pandaria: PandariaServer

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { pane }, set: { if let p = $0 { pane = p } })) {
                ForEach(SettingsPane.sections.indices, id: \.self) { i in
                    let (title, panes) = SettingsPane.sections[i]
                    Section {
                        ForEach(panes) { p in
                            HStack {
                                Label {
                                    Text(p.title)
                                } icon: {
                                    // Every symbol in the same box, wide ones scaled down to it.
                                    Image(systemName: p.symbol)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 20, height: 17)
                                }
                                Spacer()
                                if p == .server { StatusDot(health: server.health) }
                                if p == .homeServer { StatusDot(health: home.health) }
                                if p == .pandaria { StatusDot(health: pandaria.health) }
                            }
                            .tag(p)
                        }
                    } header: {
                        if let title { Text(title) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationTitle(pane.title)
        }
        // Opens on all of General at once; smaller still works, the panes scroll.
        .frame(minWidth: 760, idealWidth: 900, maxWidth: .infinity, minHeight: 520, idealHeight: 720, maxHeight: .infinity)
        .background(ResizableWindow())
    }

    @ViewBuilder private var detail: some View {
        switch pane {
        case .general: GeneralSettings()
        case .graphics: GraphicsSettings()
        case .sound: SoundSettings()
        case .survivors: SurvivorsSettings()
        case .server: ServerSettings()
        case .homeServer: HomeServerSettings()
        case .homeGame: HomeGameSettings()
        case .homeMaintenance: HomeMaintenanceSettings()
        case .pandaria: PandariaSettings()
        case .advanced: AdvancedSettings()
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @EnvironmentObject private var data: GameData
    @EnvironmentObject private var game: GameProcess
    @EnvironmentObject private var updater: Updater
    @AppStorage(Prefs.dataPathKey) private var dataPath = ""
    @AppStorage(Prefs.afterQuitKey) private var afterQuit = AfterQuit.showLauncher.rawValue
    @AppStorage(Prefs.skipLauncherKey) private var skipLauncher = false
    @AppStorage(Prefs.installAddonsKey) private var installAddons = true

    var body: some View {
        Form {
            Section("Game Data") {
                LabeledContent("Folder") {
                    Text(Paths.data.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Change…", action: choose)
                    if !dataPath.isEmpty {
                        Button("Use Default") {
                            dataPath = ""
                            data.quickCheck()
                        }
                    }
                    Button("Show in Finder") { reveal(Paths.data) }
                    Spacer()
                    Button("Verify Game Files") { data.verify() }
                        .disabled(data.isBusy || game.running)
                }
            }

            Section("Classic Addons") {
                Toggle(isOn: $installAddons) {
                    Text("Install AzerothPlus and AzerothAdmin")
                    Text("AzerothPlus: a cooldown manager, a damage meter, a swing timer, a personal resource display, centered unit frames, an objectives tracker, a windowed map with its quests, quest markers on the map and minimap, and minimap coordinates (/ap or its minimap button). AzerothAdmin: game master tools for an administrator on your own server (/aa). Pandaria gets its own 5.4.8 versions of both, under the same setting.")
                }
                Button("Show AddOns Folder") { reveal(Addons.folder) }
            }

            Section("Launching") {
                Picker("When the game quits", selection: $afterQuit) {
                    ForEach(AfterQuit.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle(isOn: $skipLauncher) {
                    Text("Start the game directly")
                    Text("Hold ⌥ Option while opening the app to see the launcher.")
                }
            }

            Section("Updates") {
                if updater.enabled {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                    Toggle("Download updates in the background", isOn: Binding(
                        get: { updater.automaticallyDownloads }, set: { updater.automaticallyDownloads = $0 }))
                        .disabled(!updater.automaticallyChecks)
                    HStack {
                        if let last = updater.lastCheck {
                            Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Check Now") { updater.checkForUpdates() }
                            .disabled(!updater.canCheck)
                    }
                } else {
                    Text("This is a local build, so updates are off. Releases update themselves.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where the game data lives. An existing WoW 1.12.1 Data folder works too."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dataPath = url.path
        data.quickCheck()
    }
}

// MARK: - Game settings (config.toml)

/// A cvar as a SwiftUI binding; numbers are written the way the game reads them.
@MainActor
private struct Cvar {
    let config: GameConfig
    let name: String
    let def: String

    var string: Binding<String> {
        Binding(get: { config.value(name, default: def) },
                set: { config.set(name, $0, default: def) })
    }

    var bool: Binding<Bool> {
        Binding(get: { config.value(name, default: def) != "0" },
                set: { config.set(name, $0 ? "1" : "0", default: def) })
    }

    /// `format` must reproduce `def` at the default, or the default would be saved as a change.
    func number(format: @escaping (Double) -> String = Cvar.short) -> Binding<Double> {
        Binding(get: { Double(config.value(name, default: def)) ?? Double(def) ?? 0 },
                set: { config.set(name, format($0), default: def) })
    }

    /// One of the game's own steps for this cvar, `(value, label)`: reads the nearest step, as the
    /// game's Settings arrows do, so a value set elsewhere still shows.
    func stop(_ stops: [(String, String)]) -> Binding<String> {
        Binding(get: {
            let now = Double(config.value(name, default: def)) ?? 0
            return stops.min { abs((Double($0.0) ?? 0) - now) < abs((Double($1.0) ?? 0) - now) }?.0 ?? def
        }, set: { config.set(name, $0, default: def) })
    }

    /// Up to two decimals, no trailing zeros: 1 → "1", 0.4 → "0.4".
    nonisolated static func short(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// Greys the game's settings out while it runs: it saves its own copy at exit, over the launcher's.
private struct GameSettingsForm<Content: View>: View {
    @EnvironmentObject private var game: GameProcess
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            if game.running {
                Label("Close the game to change these.", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
            content.disabled(game.running)
        }
        .formStyle(.grouped)
    }
}

/// The game's own Settings steps (`survivors/panels.rs`, `CHOICES`), so both panels offer the same.
private enum Stops {
    static let offOn = [("0", "Off"), ("1", "On")]
    static let maxFPS = [("0", "No limit"), ("30", "30 fps"), ("60", "60 fps"), ("120", "120 fps")]
    static let maxFPSBk = [("0", "No limit"), ("10", "10 fps"), ("30", "30 fps"), ("60", "60 fps")]
    static let lowHigh = [("0", "Low"), ("1", "Medium"), ("2", "High")]
    static let multisample = [("1", "Off"), ("2", "2×"), ("4", "4×"), ("8", "8×")]
    static let renderScale = [("0.5", "50%"), ("0.75", "75%"), ("1", "100%"), ("1.5", "150%"), ("2", "200%")]
    static let farclip = ["177", "277", "350", "477", "577", "677", "777"].map { ($0, "\($0) yd") }
    static let weather = [("0", "Low"), ("1", "Medium"), ("2", "High"), ("3", "Ultra")]
    static let anisotropic = [("1", "Bilinear"), ("2", "2× anisotropic"), ("4", "4× anisotropic"),
                              ("8", "8× anisotropic"), ("16", "16× anisotropic")]
}

/// One-click graphics levels: each sets the same eight cvars. Balanced is the game's defaults.
private enum QualityPreset: String, CaseIterable, Identifiable {
    case performance = "Performance", balanced = "Balanced", quality = "Quality"
    var id: String { rawValue }

    /// The cvars a preset owns, with each one's default: render scale, MSAA, anisotropy, view
    /// distance, ground clutter, weather, spell detail, SMAA. Every value is one of [`Stops`].
    static let keys: [(name: String, def: String)] = [
        ("renderScale", "1"), ("gxMultisample", "1"), ("anisotropic", "1"),
        ("farclip", "350"), ("WorldDetail", "1"), ("weatherDensity", "3"), ("spellEffectLevel", "2"),
        ("smaa", "1"),
    ]

    var values: [String] {
        switch self {
        case .performance: ["0.75", "1", "1", "277", "0", "1", "1", "0"]
        case .balanced: ["1", "1", "1", "350", "1", "3", "2", "1"]
        case .quality: ["1", "1", "16", "577", "2", "3", "2", "1"]
        }
    }

    var summary: String {
        switch self {
        case .performance: "75% render scale, shorter view distance, no ground clutter, lighter weather and spells, no edge smoothing. For older Macs or long battery play."
        case .balanced: "Native resolution and the game's standard view distance."
        case .quality: "16× texture filtering, long view distance, dense ground clutter. Edge smoothing (SMAA) is on in Balanced and Quality; multisampled anti-aliasing stays separate: at Retina resolutions it costs about as much as everything else together."
        }
    }

    /// The preset the current settings match, if any.
    @MainActor static func current(in config: GameConfig) -> QualityPreset? {
        allCases.first { p in
            zip(keys, p.values).allSatisfy { key, v in
                Double(config.value(key.name, default: key.def)) == Double(v)
            }
        }
    }

    @MainActor func apply(to config: GameConfig) {
        config.set(zip(Self.keys, values).map { ($0.name, $1, $0.def) })
    }
}

private struct GraphicsSettings: View {
    @EnvironmentObject private var config: GameConfig

    private static let sizes = ["1280x720", "1440x900", "1600x900", "1920x1080", "2560x1440"]

    var body: some View {
        let c = { (name: String, def: String) in Cvar(config: config, name: name, def: def) }
        let preset = QualityPreset.current(in: config)

        GameSettingsForm {
            Section("Preset") {
                Picker("Graphics", selection: Binding(
                    get: { preset?.rawValue ?? "custom" },
                    set: { QualityPreset(rawValue: $0)?.apply(to: config) })) {
                    ForEach(QualityPreset.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    if preset == nil { Text("Custom").tag("custom") }
                }
                .pickerStyle(.segmented)
                Text(preset?.summary ?? "Your own mix of the settings below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The rows of the game's own Settings > Video, in its order.
            Section("Video") {
                Picker("Display", selection: display) {
                    Text("Fullscreen").tag(0)
                    Text("Windowed").tag(1)
                    Text("Maximized").tag(2)
                }
                .pickerStyle(.segmented)
                if display.wrappedValue == 1 {
                    Picker("Window size", selection: c("gxResolution", "1600x900").string) {
                        ForEach(Self.sizes, id: \.self) { Text($0.replacingOccurrences(of: "x", with: " × ")).tag($0) }
                    }
                }
                Toggle("Vertical sync", isOn: c("gxVSync", "1").bool)
                stops("Max frame rate", c("maxFPS", "0"), Stops.maxFPS)
                stops("In the background", c("maxFPSBk", "30"), Stops.maxFPSBk)
                Toggle("Edge smoothing (SMAA)", isOn: c("smaa", "1").bool)
                stops("Anti-aliasing", c("gxMultisample", "1"), Stops.multisample)
                stops("Render scale", c("renderScale", "1"), Stops.renderScale)
                Toggle("Dynamic resolution", isOn: c("dynamicResolution", "1").bool)
                stops("View distance", c("farclip", "350"), Stops.farclip)
                stops("Ground clutter", c("WorldDetail", "1"), Stops.lowHigh)
                stops("Spell detail", c("spellEffectLevel", "2"), Stops.lowHigh)
                stops("Weather", c("weatherDensity", "3"), Stops.weather)
                Toggle("Full-screen glow", isOn: c("ffxGlow", "1").bool)
                stops("Texture filtering", c("anisotropic", "1"), Stops.anisotropic)
                Text("Render scale below 100% draws the 3D world at a lower resolution for speed, and MetalFX scales it back up; the interface stays sharp. At 100%, the game keeps the 3D near 2560×1600 pixels on larger screens, such as a 5K display, and dynamic resolution lowers it during heavy fights when the graphics chip falls behind. A frame-rate limit saves battery and heat, most of all with vertical sync off; in the background the game draws slower still.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Gamma") {
                    Slider(value: c("gamma", "1.000000").number { String(format: "%.6f", $0) }, in: 0.5...1.5)
                }
            }
        }
    }

    /// Fullscreen, windowed or maximized: `gxWindow` and `gxMaximize` together, as in the game.
    private var display: Binding<Int> {
        Binding(get: {
            guard config.value("gxWindow", default: "0") != "0" else { return 0 }
            return config.value("gxMaximize", default: "0") != "0" ? 2 : 1
        }, set: { at in
            config.set([("gxWindow", at == 0 ? "0" : "1", "0"), ("gxMaximize", at == 2 ? "1" : "0", "0")])
        })
    }

    private func stops(_ label: String, _ cvar: Cvar, _ stops: [(String, String)]) -> some View {
        Picker(label, selection: cvar.stop(stops)) {
            ForEach(stops, id: \.0) { Text($0.1).tag($0.0) }
        }
    }
}

private struct SoundSettings: View {
    @EnvironmentObject private var config: GameConfig

    var body: some View {
        let c = { (name: String, def: String) in Cvar(config: config, name: name, def: def) }

        GameSettingsForm {
            Section("Volume") {
                volume("Master volume", c("MasterVolume", "1"))
                volume("Sound effects", c("SoundVolume", "1"))
                volume("Music", c("MusicVolume", "0.4"))
                volume("Ambience", c("AmbienceVolume", "0.6"))
            }
            Section {
                Toggle("Play sound effects", isOn: c("MasterSoundEffects", "1").bool)
                Toggle("Play music", isOn: c("EnableMusic", "1").bool)
                Toggle("Play ambient sounds", isOn: c("EnableAmbience", "1").bool)
                Toggle("Play sound when the game is in the background", isOn: c("Sound_EnableSoundWhenGameIsInBG", "0").bool)
            }
        }
    }

    private func volume(_ label: String, _ cvar: Cvar) -> some View {
        let value = cvar.number()
        return LabeledContent(label) {
            HStack {
                Slider(value: value, in: 0...1, step: 0.1)
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @EnvironmentObject private var config: GameConfig
    @EnvironmentObject private var game: GameProcess
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.dataURLKey) private var dataURL = ""
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                TextField("Download from", text: $dataURL, prompt: Text(Prefs.defaultDataURL))
                    .textFieldStyle(.roundedBorder)
                Text("A direct link to a zip of a WoW 1.12.1 client holding Data/*.MPQ. Its server must support resumable (Range) downloads. Files are checked against the known checksums either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Data Source")
            }

            Section("Troubleshooting") {
                HStack {
                    Button("Show Logs…") { showLogs(.game, openWindow) }
                    Button("Show Game Settings Folder") { reveal(Paths.gameConfig) }
                }
                Button("Reset Game Settings…") { confirmReset = true }
                    .disabled(game.running)
                    .confirmationDialog("Reset every graphics and sound setting to its default?",
                                        isPresented: $confirmReset) {
                        Button("Reset", role: .destructive) { config.reset() }
                    }
            }
        }
        .formStyle(.grouped)
    }
}
