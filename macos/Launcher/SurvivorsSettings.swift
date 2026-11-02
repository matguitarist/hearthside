import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The survivors mode's save, `benilla-config/survivors-profile.txt`, as the launcher reads it:
/// the format is `survivors/profile.rs`'s, one tab-separated record per line.
struct SurvivorsProfile {
    struct Hero: Identifiable {
        let name: String
        let race: Int
        let classIndex: Int
        var wins = 0
        var runs = 0
        var pieces = 0
        /// One past the hardest difficulty won in any zone: 0 none, 1 Normal, 2 Heroic, n+1 Mythic +n.
        var cleared = 0
        var id: String { name }

        /// The hardest difficulty won, from Heroic up; `difficulty.rs`' names.
        var best: String? {
            switch cleared {
            case ..<2: nil
            case 2: "Heroic"
            default: "Mythic +\(cleared - 1)"
            }
        }

        /// `data::CLASSES`' order.
        private static let classes = ["Warrior", "Paladin", "Hunter", "Rogue", "Priest", "Shaman", "Mage", "Warlock", "Druid"]
        private static let races = [1: "Human", 2: "Orc", 3: "Dwarf", 4: "Night Elf", 5: "Undead", 6: "Tauren", 7: "Gnome", 8: "Troll"]

        var title: String {
            [Self.races[race], Self.classes.indices.contains(classIndex) ? Self.classes[classIndex] : nil]
                .compactMap { $0 }.joined(separator: " ")
        }
    }

    var heroes: [Hero] = []
    var current: String?
    var copper: UInt64 = 0
    var ranks = 0

    static var url: URL { Paths.gameConfig.appendingPathComponent("survivors-profile.txt") }

    static func load() -> SurvivorsProfile? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return SurvivorsProfile(text: text)
    }

    init(text: String) {
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let num = { (i: Int) in f.indices.contains(i) ? Int(f[i]) ?? 0 : 0 }
            switch f[0] {
            case "copper": copper = UInt64(f.count > 1 ? f[1] : "") ?? 0
            case "upgrade": ranks += num(2)
            case "current": current = f.count > 1 ? f[1] : nil
            case "char" where f.count > 3: heroes.append(Hero(name: f[1], race: num(3), classIndex: num(2)))
            case "gear" where !heroes.isEmpty: heroes[heroes.count - 1].pieces += 1
            // A zone: `name wins runs best_secs best_kills cleared pick`, the last two missing from
            // a save before difficulties. A save from before characters has them above any `char`
            // line; the game makes those the first character's.
            case _ where (5...7).contains(f.count) && !heroes.isEmpty:
                heroes[heroes.count - 1].wins += num(1) > 0 ? 1 : 0
                heroes[heroes.count - 1].runs += num(2)
                heroes[heroes.count - 1].cleared = max(heroes[heroes.count - 1].cleared, num(5))
            default: break
            }
        }
    }

    /// The purse as the game shows it: 12g 34s 56c, the empty denominations left out.
    var purse: String {
        let parts = [(copper / 10_000, "g"), (copper / 100 % 100, "s"), (copper % 100, "c")]
            .filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " ")
    }
}

/// Settings > Survivors: the characters and purse the mode has saved, its save backed up,
/// restored or reset, and the shared panes it uses.
struct SurvivorsSettings: View {
    @EnvironmentObject private var game: GameProcess
    @Environment(\.openWindow) private var openWindow
    @AppStorage("settingsPane") private var settingsPane = SettingsPane.general
    @State private var profile = SurvivorsProfile.load()
    @State private var confirmReset = false
    @State private var confirmRestore: URL?
    @State private var failure: String?
    /// Bumped when the camera is written, so the picker reads the file again.
    @State private var cameraVersion = 0

    var body: some View {
        Form {
            if game.running {
                Label("Close the game to change these.", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
            characters
            save
            Section("Playing") {
                Picker("Camera", selection: camera) {
                    Text("Locked").tag(false)
                    Text("Free").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(game.running)
                Text("Locked looks straight down from above, as the mode was made; free swings around the hero with a right-drag. C switches in the game. Alt-Z hides the interface for a screenshot. Survivors shares the Graphics and Sound settings with Classic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Graphics…") { settingsPane = .graphics }
                    Button("Sound…") { settingsPane = .sound }
                    Button("Controls…") {
                        HelpNavigator.shared.topic = .controls
                        openWindow(id: "help")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: game.running) { _, running in if !running { reload() } }
        .onAppear(perform: reload)
        .confirmationDialog("Delete every Survivors character, the purse and the merchant's upgrades?",
                            isPresented: $confirmReset) {
            Button("Move to Trash", role: .destructive, action: reset)
        } message: {
            Text("The save goes to the Trash, so it can still be put back.")
        }
        .confirmationDialog("Replace your Survivors progress with this backup?",
                            isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })) {
            Button("Replace", role: .destructive) { if let url = confirmRestore { restore(url) } }
        } message: {
            Text("The current save goes to the Trash first.")
        }
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {}
    }

    private var characters: some View {
        Section {
            if let profile, !profile.heroes.isEmpty {
                ForEach(profile.heroes) { hero in
                    LabeledContent {
                        Text(summary(hero)).foregroundStyle(.secondary)
                    } label: {
                        HStack(spacing: 6) {
                            Text(hero.name).fontWeight(.medium)
                            if hero.name.caseInsensitiveCompare(profile.current ?? "") == .orderedSame {
                                Text("Playing").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(hero.title)
                    }
                }
                LabeledContent("Purse", value: profile.purse)
                LabeledContent("Merchant upgrades", value: profile.ranks == 0 ? "None" : "\(profile.ranks) ranks")
            } else {
                Text("No characters yet. Make one from the game's menu.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Characters")
        } footer: {
            Text("Each character keeps its own zones and armor; the purse and the merchant's upgrades are the account's.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var save: some View {
        Section("Progress") {
            HStack {
                Button("Back Up…", action: backUp).disabled(profile == nil)
                Button("Restore…", action: chooseBackup)
                Button("Show in Finder") { reveal(profile == nil ? Paths.gameConfig : SurvivorsProfile.url) }
                Spacer()
                Button("Reset Progress…") { confirmReset = true }.disabled(profile == nil)
            }
            .disabled(game.running)
        }
    }

    private func summary(_ hero: SurvivorsProfile.Hero) -> String {
        var parts = ["\(hero.wins) \(hero.wins == 1 ? "zone" : "zones") won", "\(hero.runs) \(hero.runs == 1 ? "run" : "runs")"]
        if let best = hero.best { parts.append("best \(best)") }
        if hero.pieces > 0 { parts.append("\(hero.pieces) armor") }
        return parts.joined(separator: " · ")
    }

    private func reload() {
        profile = SurvivorsProfile.load()
        cameraVersion += 1
    }

    /// The game's camera lock, `survivors-settings.txt` (`survivors/panels.rs`, `keep_camera`).
    private static var settingsURL: URL { Paths.gameConfig.appendingPathComponent("survivors-settings.txt") }

    private var camera: Binding<Bool> {
        Binding(get: {
            _ = cameraVersion
            let text = (try? String(contentsOf: Self.settingsURL, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "camera free" }
        }, set: { free in
            try? FileManager.default.createDirectory(at: Paths.gameConfig, withIntermediateDirectories: true)
            try? "camera \(free ? "free" : "locked")\n".write(to: Self.settingsURL, atomically: true, encoding: .utf8)
            cameraVersion += 1
        })
    }

    private func backUp() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Survivors \(Date().formatted(.iso8601.year().month().day())).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: SurvivorsProfile.url, to: url)
        } catch {
            failure = "Could not back up: \(error.localizedDescription)"
        }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.message = "Choose a Survivors backup."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              text.split(separator: "\n").contains(where: { $0.hasPrefix("char\t") || $0.hasPrefix("copper\t") }) else {
            failure = "That file is not a Survivors save."
            return
        }
        confirmRestore = url
    }

    private func restore(_ url: URL) {
        do {
            try trashSave()
            try FileManager.default.createDirectory(at: Paths.gameConfig, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: SurvivorsProfile.url)
        } catch {
            failure = "Could not restore: \(error.localizedDescription)"
        }
        reload()
    }

    private func reset() {
        do { try trashSave() } catch { failure = "Could not reset: \(error.localizedDescription)" }
        reload()
    }

    private func trashSave() throws {
        guard FileManager.default.fileExists(atPath: SurvivorsProfile.url.path) else { return }
        try FileManager.default.trashItem(at: SurvivorsProfile.url, resultingItemURL: nil)
    }
}
