import AppKit
import SwiftUI

/// The Logs window: the game's log, the servers' on this Mac and on the home server, with levels,
/// search, the most frequent problems, and live following.

enum LogLevel: String, CaseIterable, Comparable, Sendable {
    case trace, debug, info, warn, error

    var title: String {
        switch self {
        case .trace: "Trace"
        case .debug: "Debug"
        case .info: "Info"
        case .warn: "Warning"
        case .error: "Error"
        }
    }

    var code: String { rawValue.uppercased() }

    var color: Color {
        switch self {
        case .trace: .gray
        case .debug: .secondary
        case .info: .primary
        case .warn: .orange
        case .error: .red
        }
    }

    var symbol: String {
        switch self {
        case .trace: "ellipsis.circle"
        case .debug: "ladybug"
        case .info: "info.circle"
        case .warn: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var isProblem: Bool { self >= .warn }

    static func < (a: LogLevel, b: LogLevel) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

struct LogEntry: Identifiable, Sendable {
    let id: Int
    let time: String
    let level: LogLevel
    let source: String
    let message: String
}

/// Each log the window shows, and how its lines read.
enum LogSource: String, CaseIterable, Identifiable, Hashable {
    case game, gamePrevious, localServer, localCommands
    case homeServer, homeRealm, homeDatabase, homeSetup, homeUpdate
    case pandariaWorld, pandariaLogin, pandariaDatabase, pandariaSetup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .game: "Game"
        case .gamePrevious: "Game, previous session"
        case .localServer: "Game server"
        case .localCommands: "Launcher's commands"
        case .homeServer: "Game server"
        case .homeRealm: "Login server"
        case .homeDatabase: "World database errors"
        case .homeSetup: "Setup"
        case .homeUpdate: "Updates"
        case .pandariaWorld: "Game server"
        case .pandariaLogin: "Login server"
        case .pandariaDatabase: "Database errors"
        case .pandariaSetup: "Setup"
        }
    }

    var symbol: String {
        switch self {
        case .game, .gamePrevious: "gamecontroller"
        case .localServer, .homeServer, .pandariaWorld: "server.rack"
        case .localCommands: "terminal"
        case .homeRealm, .pandariaLogin: "person.badge.key"
        case .homeDatabase, .pandariaDatabase: "cylinder.split.1x2"
        case .homeSetup, .pandariaSetup: "hammer"
        case .homeUpdate: "arrow.triangle.2.circlepath"
        }
    }

    var group: String {
        switch self {
        case .game, .gamePrevious: "Game"
        case .localServer, .localCommands: "Server on this Mac"
        case .pandariaWorld, .pandariaLogin, .pandariaDatabase, .pandariaSetup: "Pandaria"
        default: "Home server"
        }
    }

    var isHome: Bool { group == "Home server" || group == "Pandaria" }

    /// What reading it is about, under its title.
    var subtitle: String {
        switch self {
        case .game: Paths.gameLog.lastPathComponent
        case .gamePrevious: "game.previous.log"
        case .localServer: "docker logs of mangosd"
        case .localCommands: LocalServer.log.lastPathComponent
        case .homeServer: "Server.log"
        case .homeRealm: "docker logs of realmd"
        case .homeDatabase: "DBErrors.log"
        case .homeSetup: "setup.log"
        case .homeUpdate: "update.log"
        case .pandariaWorld: "Server.log"
        case .pandariaLogin: "Auth.log"
        case .pandariaDatabase: "DBErrors.log"
        case .pandariaSetup: "setup.log"
        }
    }

    /// A word on reading it, if one helps.
    var note: String? {
        switch self {
        case .homeServer, .localServer:
            "CMaNGOS logs the bots' pathing, cooldown and spell hiccups as errors; they are shown here as debug lines from \"bots\", so Error counts the real problems."
        case .homeDatabase:
            "Rows of the world database the server could not use, written at each start. They come with the world data, not from your setup."
        default: nil
        }
    }

    /// How often it is read again while following.
    var interval: Duration { isHome || self == .localServer ? .seconds(10) : .seconds(2) }

    var localFile: URL? {
        switch self {
        case .game: Paths.gameLog
        case .gamePrevious: Paths.logs.appendingPathComponent("game.previous.log")
        case .localCommands: LocalServer.log
        default: nil
        }
    }

    static let groups = ["Game", "Server on this Mac", "Home server", "Pandaria"]
}

/// Which log the window shows; set before opening it to go straight to one.
@MainActor
final class LogsNavigator: ObservableObject {
    static let shared = LogsNavigator()
    @Published var source: LogSource = .game
}

/// The lines kept: enough for a session, little enough to scroll smoothly.
private let maxLines = 4000

enum LogReader {
    /// The end of a local file.
    nonisolated static func tail(_ url: URL, bytes: Int = 2_000_000) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let size = try h.seekToEnd()
        try h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let data = try h.readToEnd() ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The local server's mangosd container, either kind.
    @MainActor
    static func localServer() async throws -> String {
        guard let docker = Docker.binary else { throw ServerError("\(Docker.engineName) is not installed.") }
        let container = LocalServer.shared.kind == .vmangos ? "azeroth-survivors-mangosd-1" : "azeroth-survivors-cmangos-mangosd-1"
        return try await Docker.run(URL(fileURLWithPath: "/bin/sh"),
                                    ["-c", "'\(docker.path)' logs --timestamps --tail \(maxLines) \(container) 2>&1"], quiet: true)
    }

    @MainActor
    static func read(_ source: LogSource) async throws -> String {
        if let file = source.localFile {
            guard FileManager.default.fileExists(atPath: file.path) else { return "" }
            return try await Task.detached { try tail(file) }.value
        }
        if source == .localServer { return try await localServer() }
        if source.group == "Pandaria" { return try await PandariaServer.shared.log(source, lines: maxLines) }
        return try await HomeServer.shared.log(source, lines: maxLines)
    }

    // MARK: - Parsing

    private static let ansi = try! NSRegularExpression(pattern: "\u{1b}\\[[0-9;]*m")
    /// `2026-10-29T19:23:08.757800Z  INFO benilla_app::net::io: message`
    private static let tracing = try! NSRegularExpression(
        pattern: #"^\d{4}-\d\d-\d\dT(\d\d:\d\d:\d\d)\.\d+Z\s+(TRACE|DEBUG|INFO|WARN|ERROR)\s+([^\s:]+(?:::[^\s:]+)*): ?(.*)$"#)
    /// `2026-10-29 23:38:49 ERROR:message` (CMaNGOS's own files)
    private static let mangos = try! NSRegularExpression(pattern: #"^\d{4}-\d\d-\d\d (\d\d:\d\d:\d\d) (ERROR:|WARNING:|DEBUG:)?(.*)$"#)
    /// `2026-10-29T23:38:49.123456789Z message` (`docker logs --timestamps`)
    private static let docker = try! NSRegularExpression(pattern: #"^\d{4}-\d\d-\d\dT(\d\d:\d\d:\d\d)\.\d+Z ?(.*)$"#)
    /// `[2026-10-28T20:45:26Z] $ docker compose …` (the launcher's `server.log`)
    private static let launcher = try! NSRegularExpression(pattern: #"^\[\d{4}-\d\d-\d\dT(\d\d:\d\d:\d\d)Z\] (.*)$"#)
    /// `== 2026-10-29 22:59:02 Backing up…` (`home-setup`, `home-update`)
    private static let step = try! NSRegularExpression(pattern: #"^== \d{4}-\d\d-\d\d (\d\d:\d\d:\d\d) (.*)$"#)

    private static func match(_ re: NSRegularExpression, _ line: String) -> [String]? {
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    /// What CMaNGOS logs as errors about its bots, which is not a problem: a bot that cannot path
    /// to a spot picks another, a stale movement flag clears itself, a repeated cooldown or a spell
    /// without an id is ignored; a bot with nowhere near the players to go stays put. Shown as debug
    /// lines from "bots", so errors are the real ones.
    nonisolated static let botNoise = [
        "AbstractPathMovementGenerator::Initialize Path empty",
        "is not moving but have spline movement enabled",
        "try to add and already existing cooldown",
        "CastSpell: unknown spell id 0 ",
        // Bots with no spot for their level in a zone someone plays in stay where they are.
        "- no locations available",
    ]

    nonisolated static func isBotNoise(_ message: String) -> Bool {
        botNoise.contains { message.contains($0) }
    }

    /// A level from the words of a line that has none of its own.
    nonisolated static func guess(_ message: String) -> LogLevel {
        let m = message.lowercased()
        if m.contains("error") || m.contains("fatal") || m.contains("failed") || m.contains("panic") { return .error }
        if m.contains("warn") { return .warn }
        return .info
    }

    /// `benilla_app::net::io` → `net::io`, `bevy_render::renderer` → `bevy_render`.
    private static func shortTarget(_ target: String) -> String {
        let parts = target.components(separatedBy: "::")
        if parts.first?.hasPrefix("benilla_") == true {
            return parts.count > 1 ? parts.dropFirst().joined(separator: "::") : String(parts[0].dropFirst(8))
        }
        return parts.first ?? target
    }

    nonisolated static func parse(_ text: String, as source: LogSource) -> [LogEntry] {
        var lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).map(String.init)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        var out: [LogEntry] = []
        out.reserveCapacity(lines.count)
        var last: (level: LogLevel, source: String)?
        for raw in lines {
            let line = raw.contains("\u{1b}")
                ? ansi.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: (raw as NSString).length), withTemplate: "")
                : raw
            var time = "", level = LogLevel.info, from = "", message = line
            switch source {
            case .game, .gamePrevious:
                if let m = match(tracing, line) {
                    time = m[0]; level = LogLevel(rawValue: m[1].lowercased()) ?? .info
                    from = shortTarget(m[2]); message = m[3]
                } else if let last {
                    // A message's later lines: a backtrace, a pretty-printed value.
                    level = last.level; from = last.source
                } else {
                    from = "game"
                }
            case .homeServer, .homeDatabase:
                from = "mangosd"
                if let m = match(mangos, line) {
                    time = m[0]; message = m[2]
                    level = m[1] == "ERROR:" ? .error : m[1] == "WARNING:" ? .warn : m[1] == "DEBUG:" ? .debug : .info
                } else {
                    level = source == .homeDatabase ? .error : guess(line)
                }
                if level == .error, isBotNoise(message) { level = .debug; from = "bots" }
            case .localServer, .homeRealm:
                from = source == .homeRealm ? "realmd" : "mangosd"
                if let m = match(docker, line) {
                    time = m[0]; message = m[1]
                }
                if message.hasPrefix("ERROR:") {
                    level = .error; message = String(message.dropFirst(6))
                } else {
                    level = guess(message)
                }
                if level == .error, isBotNoise(message) { level = .debug; from = "bots" }
            case .localCommands:
                if let m = match(launcher, line) {
                    time = m[0]; message = m[1]
                }
                if message.hasPrefix("$ ") {
                    from = "command"; level = .info; message = String(message.dropFirst(2))
                } else if message.hasPrefix("exit ") {
                    from = "command"; level = message == "exit 0" ? .info : .error
                } else {
                    from = "output"; level = guess(message)
                }
            case .pandariaWorld, .pandariaLogin, .pandariaDatabase:
                // TrinityCore writes its files without a time or a level.
                from = source == .pandariaLogin ? "authserver" : "worldserver"
                level = source == .pandariaDatabase ? .error : guess(line)
            case .homeSetup, .homeUpdate, .pandariaSetup:
                if let m = match(step, line) {
                    time = m[0]; from = "step"; message = m[1]; level = guess(m[1]) == .error ? .error : .info
                } else {
                    from = "output"; level = guess(line)
                }
            }
            last = (level, from)
            out.append(LogEntry(id: out.count, time: time, level: level, source: from, message: message))
        }
        return out
    }

    /// The warnings and errors that come back most, numbers and quoted names set aside: what a
    /// log is mostly telling you.
    nonisolated static func frequent(_ entries: [LogEntry], top: Int = 6) -> [(text: String, search: String, level: LogLevel, count: Int)] {
        var groups: [String: (search: String, level: LogLevel, count: Int)] = [:]
        for e in entries where e.level.isProblem {
            // CMaNGOS names the bot or creature after these words.
            let key = e.message
                .replacingOccurrences(of: #"'[^']*'|"[^"]*""#, with: "'…'", options: .regularExpression)
                .replacingOccurrences(of: #"\b(Player|name|caster:) [^\s(]+"#, with: "$1 …", options: .regularExpression)
                .replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
            if var g = groups[key] {
                g.count += 1
                g.level = max(g.level, e.level)
                groups[key] = g
            } else {
                // What to search for: the longest stretch every message of the group shares.
                let search = key.components(separatedBy: CharacterSet(charactersIn: "#…'"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .max { $0.count < $1.count } ?? e.message
                groups[key] = (search, e.level, 1)
            }
        }
        return groups.filter { $0.value.count > 1 }
            .sorted { $0.value.count > $1.value.count }
            .prefix(top)
            .map { (text: $0.key, search: $0.value.search, level: $0.value.level, count: $0.value.count) }
    }
}

// MARK: - Window

struct LogsWindow: View {
    @EnvironmentObject private var home: HomeServer
    @ObservedObject private var nav = LogsNavigator.shared

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { nav.source }, set: { if let s = $0 { nav.source = s } })) {
                ForEach(LogSource.groups, id: \.self) { group in
                    Section(group) {
                        ForEach(LogSource.allCases.filter { $0.group == group }) { source in
                            Label(source.title, systemImage: source.symbol).tag(source)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            LogView(source: nav.source).id(nav.source)
        }
        .frame(minWidth: 860, minHeight: 480)
    }
}

private struct LogView: View {
    let source: LogSource
    @State private var entries: [LogEntry]?
    @State private var frequent: [(text: String, search: String, level: LogLevel, count: Int)] = []
    @State private var error: String?
    @State private var updated: Date?
    @State private var levels: Set<LogLevel> = [.debug, .info, .warn, .error]
    @State private var sourceFilter: String?
    @State private var search = ""
    @State private var follow = true
    /// Entries before this one are hidden by Clear.
    @State private var clearedAt = 0
    @State private var lastText = ""

    var body: some View {
        VStack(spacing: 0) {
            if let entries {
                header(entries)
                Divider()
                list(entries)
            } else if let error {
                ContentUnavailableView {
                    Label("Can't Read This Log", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await reload() } }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(source.title)
        .navigationSubtitle(source.subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Search log")
        .toolbar { toolbar }
        .task(id: source) {
            await reload()
            while !Task.isCancelled {
                try? await Task.sleep(for: source.interval)
                if follow { await reload() }
            }
        }
    }

    // MARK: Header

    private func header(_ all: [LogEntry]) -> some View {
        let shown = Array(all.dropFirst(clearedAt))
        var counts: [LogLevel: Int] = [:]
        for e in shown { counts[e.level, default: 0] += 1 }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    chip(level, count: counts[level, default: 0])
                }
                Spacer()
                if let sourceFilter {
                    Button { self.sourceFilter = nil } label: {
                        Label("Source: \(sourceFilter)", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if clearedAt > 0 {
                    Text("\(clearedAt) earlier lines hidden").foregroundStyle(.secondary)
                    Button("Show All") { clearedAt = 0 }.controlSize(.small)
                } else if let updated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            if !frequent.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Most frequent:").font(.callout.bold()).foregroundStyle(.secondary)
                        ForEach(frequent, id: \.text) { item in
                            Button {
                                search = search == item.search ? "" : item.search
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: item.level.symbol)
                                    Text("\(item.text.prefix(60))\(item.text.count > 60 ? "…" : "") ×\(item.count)")
                                }
                                .font(.callout)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(item.level.color.opacity(search == item.search ? 0.35 : 0.15), in: Capsule())
                                .foregroundStyle(item.level.color)
                            }
                            .buttonStyle(.plain)
                            .help(item.text)
                        }
                    }
                }
            }
            if let note = source.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func chip(_ level: LogLevel, count: Int) -> some View {
        let on = levels.contains(level)
        return Button {
            if on { levels.remove(level) } else { levels.insert(level) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: level.symbol)
                Text("\(level.title) \(count)").monospacedDigit()
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(on ? level.color.opacity(0.2) : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(level.color.opacity(on ? 0.6 : 0.25)))
            .foregroundStyle(on ? level.color : .secondary)
        }
        .buttonStyle(.plain)
        .help(on ? "Hide \(level.title.lowercased()) lines" : "Show \(level.title.lowercased()) lines")
    }

    // MARK: Lines

    private func filtered(_ all: [LogEntry]) -> [LogEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return all.dropFirst(clearedAt).filter { e in
            levels.contains(e.level)
                && (sourceFilter == nil || e.source == sourceFilter)
                && (q.isEmpty || e.message.localizedCaseInsensitiveContains(q) || e.source.localizedCaseInsensitiveContains(q))
        }
    }

    private func list(_ all: [LogEntry]) -> some View {
        let rows = filtered(all)
        return ScrollViewReader { proxy in
            List(rows) { e in
                LogRow(entry: e) { sourceFilter = $0 }
                    .listRowBackground(e.level.isProblem ? e.level.color.opacity(0.08) : Color.clear)
                    .id(e.id)
            }
            .listStyle(.plain)
            .overlay {
                if rows.isEmpty {
                    if all.isEmpty {
                        ContentUnavailableView("Nothing Logged Yet", systemImage: "doc.text",
                                               description: Text(emptyText))
                    } else {
                        ContentUnavailableView("No Matching Lines", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .onChange(of: all.count, initial: true) {
                if follow, let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var emptyText: String {
        switch source {
        case .game, .gamePrevious: "The game writes here while it runs."
        case .localServer: "Start the server on this Mac (Classic › On this Mac) to see its log."
        case .homeUpdate: "No update has run on the home server yet."
        case .homeSetup: "The home server has no setup log."
        case .pandariaSetup: "Pandaria has no setup log on the home server."
        case .pandariaWorld, .pandariaLogin: "Start Pandaria (Settings › Pandaria) to see its log."
        default: "Nothing in this log yet."
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $follow) {
                Label("Follow Live", systemImage: "dot.radiowaves.left.and.right")
            }
            .help("Read the log again every few seconds and scroll to new lines")

            Button {
                clearedAt = entries?.count ?? 0
            } label: {
                Label("Clear", systemImage: "clear")
            }
            .keyboardShortcut("k")
            .help("Hide every line so far and show only new ones (⌘K). The log itself is not changed.")
            .disabled(entries?.isEmpty ?? true)

            Button {
                Task { await reload() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Read the log again (⌘R)")

            Menu {
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lastText, forType: .string)
                }
                Button("Save As…", action: save)
                if let file = source.localFile {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(lastText.isEmpty)
            .help("Copy or save the log")
        }
    }

    // MARK: Loading

    private func reload() async {
        do {
            let text = try await LogReader.read(source)
            updated = .now
            error = nil
            guard text != lastText || entries == nil else { return }
            lastText = text
            let src = source
            let (parsed, top) = await Task.detached {
                let p = LogReader.parse(text, as: src)
                return (p, LogReader.frequent(p))
            }.value
            // A log that started over (a new session, a restarted container) shows whole again.
            if parsed.count < clearedAt { clearedAt = 0 }
            entries = parsed
            frequent = top
        } catch {
            if entries == nil { self.error = LocalServer.message(error) }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(source.title).log".replacingOccurrences(of: ",", with: "")
        panel.allowedContentTypes = [.log, .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? lastText.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry
    let onSource: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.time)
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .leading)
            Text(verbatim: entry.level.code)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(entry.level == .info ? Color.secondary : entry.level.color)
                .frame(width: 46, alignment: .leading)
            Button(entry.source) { onSource(entry.source) }
                .buttonStyle(.plain)
                .foregroundStyle(.teal)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 130, alignment: .leading)
                .help("Show only \(entry.source)")
            Text(entry.message)
                .foregroundStyle(entry.level == .info ? Color.primary : entry.level.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.vertical, 1)
    }
}

/// Opens the Logs window at one log.
@MainActor
func showLogs(_ source: LogSource, _ open: OpenWindowAction) {
    LogsNavigator.shared.source = source
    open(id: "logs")
}
