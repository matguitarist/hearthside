import Foundation

/// Where the launcher and the game keep things. Nothing is written inside the app bundle: an
/// update replaces the bundle, and writing into a signed bundle breaks its signature.
enum Paths {
    static let appName = "Hearthside"

    /// ~/Library/Application Support/Hearthside: the game's working directory.
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }

    /// The game's settings folder (`$BENILLA_HOME`): `config.toml`, the last pick, diagnostics.
    static var gameConfig: URL { support.appendingPathComponent("benilla-config", isDirectory: true) }

    static var defaultData: URL { support.appendingPathComponent("Data", isDirectory: true) }

    /// The MPQ folder in use: the player's choice in Settings, else the default.
    static var data: URL {
        let custom = Prefs.dataPath
        return custom.isEmpty ? defaultData : URL(fileURLWithPath: custom, isDirectory: true)
    }

    static var logs: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/\(appName)", isDirectory: true)
    }

    static var gameLog: URL { logs.appendingPathComponent("game.log") }

    /// The game binary, beside the launcher in Contents/MacOS.
    static var gameBinary: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/warcraft-survivors")
    }
}

/// The launcher's own preferences (UserDefaults). The game's settings live in its config.toml.
enum Prefs {
    static let dataPathKey = "dataPath"
    static let dataURLKey = "dataURL"
    static let afterQuitKey = "afterQuit"
    static let skipLauncherKey = "skipLauncher"
    static let modeKey = "mode"
    static let classicServerKey = "classicServer"
    static let remoteServerKey = "remoteServer"
    static let keepServerKey = "keepServerRunning"
    static let installAddonsKey = "installAddons"
    static let serverKindKey = "localServerKind"
    static let homeHostKey = "homeServerHost"
    static let homeKeyKey = "homeServerKey"
    static let homeDirKey = "homeServerFolder"
    static let pandariaFolderKey = "pandariaFolder"

    static let defaultDataURL = "https://archive.org/download/WoW_1.12.1-5875/1.12.1-5875_enUS.zip"

    static var dataPath: String { UserDefaults.standard.string(forKey: dataPathKey) ?? "" }

    static var dataURL: URL {
        let s = UserDefaults.standard.string(forKey: dataURLKey) ?? ""
        return URL(string: s.isEmpty ? defaultDataURL : s) ?? URL(string: defaultDataURL)!
    }
}

/// Which game Play starts: the survivors mode, the original game on a 1.12 server, or Mists of
/// Pandaria with the player's own 5.4.8 client on the home server (`Pandaria.swift`).
enum GameMode: String, CaseIterable, Identifiable {
    case survivors, classic, pandaria
    var id: String { rawValue }
    var label: String {
        switch self {
        case .survivors: "Survivors"
        case .classic: "Classic"
        case .pandaria: "Pandaria"
        }
    }
    static var current: GameMode {
        GameMode(rawValue: UserDefaults.standard.string(forKey: Prefs.modeKey) ?? "") ?? .survivors
    }
}

/// Where Classic plays: the launcher's own server on this Mac, the one it manages on a home
/// server, or one at an address.
enum ClassicServer: String, CaseIterable, Identifiable {
    case local, home, remote
    var id: String { rawValue }
    var label: String {
        switch self {
        case .local: "On this Mac"
        case .home: "Home server"
        case .remote: "Another server"
        }
    }
    static var current: ClassicServer {
        ClassicServer(rawValue: UserDefaults.standard.string(forKey: Prefs.classicServerKey) ?? "") ?? .local
    }
}

/// Which server runs on this Mac: vmangos from prebuilt images, or CMaNGOS with random playerbots,
/// built here. Each keeps its own folder, databases and accounts; they share the ports, so one runs
/// at a time.
enum ServerKind: String, CaseIterable, Identifiable {
    case vmangos, cmangos
    var id: String { rawValue }
    var label: String {
        switch self {
        case .vmangos: "vmangos"
        case .cmangos: "CMaNGOS with bots"
        }
    }
    static var current: ServerKind {
        ServerKind(rawValue: UserDefaults.standard.string(forKey: Prefs.serverKindKey) ?? "") ?? .vmangos
    }
}

/// The game's `realmList` cvar: the logon server Classic dials.
enum Realm {
    static let cvar = "realmList"
    static let fallback = "localhost"
}

/// What the launcher does when the game quits.
enum AfterQuit: String, CaseIterable, Identifiable {
    case showLauncher, quitLauncher
    var id: String { rawValue }
    var label: String {
        switch self {
        case .showLauncher: "Show the launcher"
        case .quitLauncher: "Quit"
        }
    }
}
