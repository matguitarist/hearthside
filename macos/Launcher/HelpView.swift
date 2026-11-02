import AppKit
import SwiftUI

/// The Help window: a few topics, searchable, opened from the Help menu at the one asked for.

enum HelpTopic: String, CaseIterable, Identifiable {
    case start, survivors, controls, classic, addons, homeServer, pandaria, graphics, troubleshooting, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: "Getting Started"
        case .survivors: "Survivors"
        case .controls: "Survivors Controls"
        case .classic: "Classic"
        case .addons: "Classic Addons"
        case .homeServer: "Home Server"
        case .pandaria: "Pandaria"
        case .graphics: "Graphics & Performance"
        case .troubleshooting: "Troubleshooting"
        case .shortcuts: "Keyboard Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .start: "play.circle"
        case .survivors: "flame"
        case .controls: "keyboard"
        case .classic: "globe.europe.africa"
        case .addons: "puzzlepiece.extension"
        case .homeServer: "house"
        case .pandaria: "mountain.2"
        case .graphics: "display"
        case .troubleshooting: "stethoscope"
        case .shortcuts: "command"
        }
    }

    var blocks: [HelpBlock] {
        switch self {
        case .start:
            [.p("Hearthside plays **Survivors**, Azeroth Survivors: a free, fan-made WoW roguelike by Aethus, running on a from-scratch WoW 1.12.1 client. It also plays **Classic**, the original 1.12.1 game, on a server of your own, and **Pandaria**, Mists of Pandaria 5.4.8 on your home server with your own 5.4.8 client."),
             .h("The game data"),
             .p("On first launch the launcher downloads the WoW 1.12.1 game data (about 5.4 GB). The download resumes where it stopped and every file is checked. If you already have a 1.12.1 **Data** folder, choose it in **Settings › General › Folder** instead."),
             .h("Playing"),
             .bullets(["Pick **Survivors**, **Classic** or **Pandaria** in the launcher, or in **Game › Mode**.",
                       "Press **Play** (⌘P). The launcher steps aside while the game runs.",
                       "When the game quits the launcher comes back, or quits: **Settings › General › When the game quits**.",
                       "Hold ⌥ Option while opening the app to see the launcher when **Start the game directly** is on."]),
             .h("Updates"),
             .p("The app updates itself: it checks on its own, or use **Hearthside › Check for Updates…**. **Help › Release Notes** lists what changed.")]
        case .survivors:
            [.p("Pick a race, gender, class and zone, then survive: you move, your abilities cast themselves, enemies come in waves, and a boss shows up every couple of minutes."),
             .bullets(["**Level up:** three cards are dealt. Their colour, as WoW's item quality, says how strong a pick is, and each lists exactly what changes. Press **1**, **2** or **3**, or click one.",
                       "**From level 5:** your class's movement spell on **F**, aimed at the cursor: Blink, Charge, Sprint, Dash, Fade, Ghost Wolf, Aspect of the Cheetah, Blessing of Freedom, Howl of Terror.",
                       "**Sixteen zones,** from the starting zones to Naxxramas and the Gates of Ahn'Qiraj, each with its own creatures and bosses.",
                       "**Difficulty,** the button under the zones: Normal, then Heroic, then Mythic +2 to +20, each opened by winning the one before in that zone. Harder runs bring home more coin, and their bosses drop armor more often and from stronger sets. From +2 the week's affixes join in, as in Mythic+: Fortified or Tyrannical, a second at +4 and a third at +7, new every Tuesday.",
                       "**The camera** is locked top-down, the hero facing the cursor. **C** frees it to swing and tilt; the wheel zooms."]),
             .p("Your picks are remembered between runs. See **Survivors Controls** for every key.")]
        case .controls:
            [.keys([("W A S D or arrow keys", "Move (the hero faces the cursor, backpedals and strafes)"),
                    ("Space", "Jump"),
                    ("F", "Your class's movement spell, from level 5, aimed at the cursor"),
                    ("C", "Unlock or lock the camera"),
                    ("Mouse wheel", "Zoom, from over the shoulder out to 70 yards"),
                    ("Drag", "Swing and tilt the camera, while it is unlocked"),
                    ("G", "Picture polish on or off"),
                    ("⌥ Option-Z", "Hide or show the interface, for a clean screenshot"),
                    ("1, 2, 3", "Pick an upgrade at a level up (or click a card)"),
                    ("Esc", "Pause and resume"),
                    ("Enter", "Start the run from the menu; back to the menu after a game over")]),
             .p("In the menu, click a race, gender, class and zone (**Randomize** rolls one), then **Enter World**. Abilities need no aiming: they cast themselves.")]
        case .classic:
            [.p("Classic is the original 1.12.1 game. It needs a server, and the launcher offers three:"),
             .bullets(["**On this Mac:** the launcher sets one up in Docker (install OrbStack or Docker Desktop first): vmangos, or CMaNGOS with bots playing the world. Its ports are open to this Mac only, and it stops when the launcher quits unless **Settings › Server on This Mac** keeps it running.",
                       "**Home server:** the same CMaNGOS with bots on an always-on machine at home, so every Mac in the house plays on it. See **Home Server**.",
                       "**Another server:** any 1.12.1 server, by its address."]),
             .h("Accounts"),
             .p("Create your account from the launcher once the server runs. Administrators (a checkbox per account in Settings) can use AzerothAdmin's game master tools; a change takes effect at the account's next login.")]
        case .addons:
            [.p("Unless you turn it off in **Settings › General**, the launcher installs two addons before each Classic launch. Your other addons in the AddOns folder are left alone, and their settings are kept."),
             .h("AzerothPlus"),
             .p("Open its options with **/ap** or its minimap button: a tab per kind of feature, a box per feature. **/ap lock** locks the frames after you drag them."),
             .bullets(["**Combat:** a cooldown manager, a damage meter, a swing timer and a personal resource display.",
                       "**Interface:** centered unit frames, health in numbers on the target frame and in tooltips, minimap coordinates, and a windowed map with the zone's quests.",
                       "**Quests:** an objectives tracker, quest markers on the map and minimap, quest levels in the log, quest progress in tooltips, and quests accepted and handed in for you (hold Shift to do it yourself).",
                       "**Items:** grey items sold and gear repaired at vendors (hold Shift as you open one to skip it), a search box on your bags, and vendor prices in tooltips.",
                       "**Bots:** a party panel (**/ap bots**) that finds bots of your level nearby, invites them, and tells your party to follow, stay, attack your target and more."]),
             .h("AzerothAdmin"),
             .p("**/aa** opens game master tools for an administrator on your own server: levels, gold, teleports, items, and the bots on CMaNGOS."),
             .h("In Pandaria"),
             .p("Pandaria gets versions of both written for the 5.4.8 client, installed at each launch under the same setting. Their bot panel makes bots of any class with the server's **.playerbots** commands.")]
        case .homeServer:
            [.p("Runs CMaNGOS with bots on an always-on Linux machine with Docker (an Unraid box, say), managed from the launcher over SSH. Keep it on your home network: forward nothing to it from the internet."),
             .h("Setting it up"),
             .bullets(["In **Settings › Home Server**, enter the login and address (root@192.168.1.10).",
                       "**Create Key**, then **Copy Public Key** and add it to the login's authorized keys. On Unraid: Users › root › SSH authorized keys.",
                       "**Connect**, then **Set Up Home Server**. It copies about 4 GB of game files and builds the server and its maps: an hour or two on a small CPU. You can quit the launcher meanwhile."]),
             .h("Bots & Rates"),
             .p("The number of bots (each 100 take about 1 GB of memory), whether they come to the zones where people play, whether they stay near the players' level, and the experience, loot, gold, reputation and rested rates, and the auction house bot: whether it trades, its prices and how much it stocks. **Apply** restarts the game server once for all of them."),
             .h("Dashboard"),
             .p("**Open Dashboard** (Server menu) shows the server in any browser at home: who is playing, the bots by level and on a world map, memory and CPU over the last day, backups and settings."),
             .h("Backups & Updates"),
             .p("Every night at 4:30 the server saves its accounts and characters and keeps the last 14. **Back Up Now** and **Restore…** are in **Settings › Backups & Updates**; a restore saves the current state first. **Check for Updates** compares the server with the newest CMaNGOS; **Update Server…** rebuilds it, keeps everyone's characters, and puts the old server back if anything fails.")]
        case .pandaria:
            [.p("Plays Mists of Pandaria 5.4.8 with bots, on a TrinityCore server built on your home server beside Classic. It needs a home server (see **Home Server**) and your own World of Warcraft 5.4.8 for Mac: no Blizzard files ship with this app."),
             .h("Setting it up"),
             .bullets(["Pick **Pandaria** in the launcher, then **Choose Client Folder…**: the folder holding World of Warcraft-64.app and Data.",
                       "**Set Up Pandaria** copies the client's game files (about 23 GB) to the home server, then builds the server from source and reads its maps: a few hours on a small CPU. You can quit the launcher meanwhile.",
                       "When it runs, create your account in the launcher, then press **Play**."]),
             .h("The client"),
             .p("The first Play prepares your client: it is patched to sign in to your server, its graphics get fixes for current macOS and AMD FSR sharpening, and it is signed for this Mac. It runs under Rosetta 2 and needs Apple's command line developer tools (xcode-select --install). **Settings › Pandaria › Prepare Again** redoes it."),
             .h("One server at a time"),
             .p("Pandaria and Classic on the home server use the same ports, so starting one stops the other. Pandaria keeps running when the game quits; stop it in the **Server** menu.")]
        case .graphics:
            [.p("Graphics and sound are in **Settings › Graphics** and **Sound**, or in the game's own Settings. They are locked while the game runs, which saves its own copy when it quits."),
             .bullets(["**Presets:** Performance, Balanced and Quality set several options at once.",
                       "**Render scale:** at 100% the game keeps the 3D near 2560×1600 pixels on large screens and lets Apple's MetalFX scale it up; the interface stays sharp.",
                       "**Max frame rate:** a cap of 30, 60 or 120 fps, and 30 in the background, saves battery and heat with vertical sync off.",
                       "**Edge smoothing (SMAA):** smooths jagged edges, leaves and grass for almost no cost.",
                       "**Dynamic resolution:** lowers the 3D's resolution a little when the graphics can't keep up, and steps aside when that doesn't help.",
                       "**Multisampling** costs a lot at high resolutions; SMAA does most of its work for a fraction of it."])]
        case .troubleshooting:
            [.h("The game doesn't open"),
             .p("After 25 seconds the launcher offers **Keep Waiting** or **Force Quit**. This usually means the sound output device isn't answering, such as a remote-desktop audio driver: switch the output in System Settings and try again."),
             .h("The game crashed"),
             .p("Open **Window › Logs** (⌘L): **Game, previous session** holds what happened. **Share › Copy Log** puts it on the clipboard for a report."),
             .h("Missing or damaged game files"),
             .p("**Game › Verify Game Files** checks every file against its checksum; any that fail show up as missing, and the launcher offers **Download Missing Files**."),
             .h("A server won't start"),
             .p("Docker (OrbStack or Docker Desktop) must be running for the server on this Mac. **Server › Server Logs** shows what the server said. CMaNGOS logs its bots' pathing and spell hiccups as errors; the Logs window shows those as debug lines from \"bots\"."),
             .h("The home server can't be reached"),
             .p("Check that the machine is on, that the address is right, and that its authorized keys hold the launcher's public key (**Settings › Home Server**)."),
             .h("The settings went wrong"),
             .p("**Settings › Advanced › Reset Game Settings…** puts every graphics and sound setting back to its default."),
             .h("Still stuck"),
             .p("**Help › Report a Problem…** opens an issue on the project's page. Include what you did and the log.")]
        case .shortcuts:
            [.h("Launcher"),
             .keys([("⌘P", "Play"), ("⌘,", "Settings"), ("⌘L", "Logs"), ("⌘0", "Launcher window"), ("⌘?", "Help")]),
             .h("Logs window"),
             .keys([("⌘F", "Search"), ("⌘K", "Clear: hide what was logged so far"), ("⌘R", "Read the log again")]),
             .p("The game's own keys are in **Survivors Controls**.")]
        }
    }

    /// Every word of the topic, for search.
    var text: String {
        ([title] + blocks.map(\.text)).joined(separator: " ")
    }
}

enum HelpBlock {
    case p(String)
    case h(String)
    case bullets([String])
    case keys([(String, String)])

    var text: String {
        switch self {
        case .p(let s), .h(let s): s
        case .bullets(let items): items.joined(separator: " ")
        case .keys(let rows): rows.map { "\($0.0) \($0.1)" }.joined(separator: " ")
        }
    }
}

/// Which topic the window shows; the Help menu sets it before opening the window.
@MainActor
final class HelpNavigator: ObservableObject {
    static let shared = HelpNavigator()
    @Published var topic: HelpTopic = .start
}

struct HelpWindow: View {
    @ObservedObject private var nav = HelpNavigator.shared
    @State private var search = ""

    private var topics: [HelpTopic] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? HelpTopic.allCases : HelpTopic.allCases.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { nav.topic }, set: { if let t = $0 { nav.topic = t } })) {
                ForEach(topics) { topic in
                    Label(topic.title, systemImage: topic.symbol).tag(topic)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .overlay {
                if topics.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(nav.topic.title, systemImage: nav.topic.symbol)
                        .font(.largeTitle.weight(.semibold))
                        .padding(.bottom, 4)
                    ForEach(nav.topic.blocks.indices, id: \.self) { i in
                        block(nav.topic.blocks[i])
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Help")
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search Help")
        .onChange(of: search) { _, _ in
            if let first = topics.first, !topics.contains(nav.topic) { nav.topic = first }
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    @ViewBuilder private func block(_ b: HelpBlock) -> some View {
        switch b {
        case .p(let s):
            Text(LocalizedStringKey(s))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .h(let s):
            Text(s).font(.title3.weight(.semibold)).padding(.top, 6)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(LocalizedStringKey(items[i]))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        case .keys(let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(rows.indices, id: \.self) { i in
                    GridRow {
                        Text(rows[i].0)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                        Text(rows[i].1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
