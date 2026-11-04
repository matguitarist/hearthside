import AppKit
import Foundation

/// Runs the game binary with its data and settings folders, or for Pandaria the player's 5.4.8
/// client in its own folder, and tracks it until it quits. Either writes to `game.log`.
@MainActor
final class GameProcess: ObservableObject {
    @Published private(set) var running = false
    /// Set when the game exits abnormally: a short message and the end of its log.
    @Published var crash: Crash?
    /// The game has run a while without opening its window: something it waits on at startup
    /// (in practice an audio driver) is not answering. Clears itself if the window appears.
    @Published private(set) var stuck = false

    struct Crash: Identifiable {
        let id = UUID()
        let message: String
        let logTail: String
    }

    private var process: Process?
    private var watchdog: Task<Void, Never>?
    private var killedByUser = false

    /// How long the game may take to open its window; the `stuckAfter` default overrides it.
    static var stuckAfter: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "stuckAfter")
        return v > 0 ? v : 25
    }
    /// Called on the main actor when the game quits; the flag is true for a crash.
    var onExit: ((Bool) -> Void)?

    func launch() {
        guard !running else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            try fm.createDirectory(at: Paths.gameConfig, withIntermediateDirectories: true)
            try fm.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
            // Keep the previous run's log beside the new one.
            let previous = Paths.logs.appendingPathComponent("game.previous.log")
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: Paths.gameLog, to: previous)
            fm.createFile(atPath: Paths.gameLog.path, contents: nil)
            let log = try FileHandle(forWritingTo: Paths.gameLog)

            let p = Process()
            let pandaria = GameMode.current == .pandaria
            if pandaria {
                guard let binary = PandariaClient.binary, let folder = PandariaClient.folder else {
                    throw ServerError(PandariaClient.problem ?? "Choose your World of Warcraft 5.4.8 folder.")
                }
                p.executableURL = binary
                p.currentDirectoryURL = folder
                var env = ProcessInfo.processInfo.environment
                env["GLHOOK_AO"] = PandariaClient.occlusion ? "1" : "0"
                let fog = PandariaClient.fog
                env["GLHOOK_ATMOS"] = fog > 0 ? "1" : "0"
                if fog > 0 { env["GLHOOK_FOG"] = String(fog) }
                p.environment = env
            } else {
                p.executableURL = Paths.gameBinary
                p.currentDirectoryURL = Paths.support
                if GameMode.current == .classic { p.arguments = ["--classic"] }
                var env = ProcessInfo.processInfo.environment
                env["WOW_DATA"] = Paths.data.path
                env["BENILLA_HOME"] = Paths.gameConfig.path
                env["NO_COLOR"] = "1" // a readable log file, not ANSI escapes
                p.environment = env
            }
            p.standardOutput = log
            p.standardError = log
            let started = Date()
            p.terminationHandler = { proc in
                let status = proc.terminationStatus
                let reason = proc.terminationReason
                Task { @MainActor in
                    try? log.close()
                    self.finished(status: status, reason: reason, after: Date().timeIntervalSince(started))
                }
            }
            try p.run()
            process = p
            running = true
            killedByUser = false
            // The 5.4.8 client logs nothing of its window to wait for.
            if !pandaria { watch(for: Self.stuckAfter) }
        } catch {
            crash = Crash(message: "The game could not start: \(LocalServer.message(error))", logTail: "")
        }
    }

    private func finished(status: Int32, reason: Process.TerminationReason, after seconds: TimeInterval) {
        running = false
        process = nil
        stuck = false
        watchdog?.cancel()
        if killedByUser {
            onExit?(true) // back to the launcher, without a crash report the player asked for
            return
        }
        if reason == .exit && status == 0 {
            onExit?(false)
            return
        }
        let how = reason == .uncaughtSignal ? "was stopped by signal \(status)" : "quit with code \(status)"
        crash = Crash(
            message: "The game \(how) after \(duration(seconds)).",
            logTail: Self.tail(of: Paths.gameLog, lines: 40))
        onExit?(true)
    }

    /// Check the log for the window every half second; flag `stuck` past the deadline.
    private func watch(for seconds: TimeInterval) {
        watchdog?.cancel()
        let deadline = Date().addingTimeInterval(seconds)
        watchdog = Task { [weak self] in
            while true {
                // A cancelled sleep throws: stop there, or this pass would run on with its old,
                // expired deadline and flag `stuck` again right after "Keep Waiting".
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard let self, self.running else { return }
                if Self.windowOpened() {
                    self.stuck = false
                    return
                }
                if Date() >= deadline { self.stuck = true }
            }
        }
    }

    /// The game logs this line as its window is created, after the audio device is open.
    private static func windowOpened() -> Bool {
        guard let data = try? Data(contentsOf: Paths.gameLog) else { return false }
        return data.range(of: Data("Creating new window".utf8)) != nil
    }

    func keepWaiting() {
        stuck = false
        watch(for: Self.stuckAfter)
    }

    /// Stop a game that is not responding: ask, then insist. A thread blocked in a driver call
    /// may never see the polite signal.
    func forceQuit() {
        guard let p = process else { return }
        killedByUser = true
        stuck = false
        let pid = p.processIdentifier
        p.terminate()
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.process?.processIdentifier == pid { kill(pid, SIGKILL) }
        }
    }

    /// Bring the running game forward (the launcher's Play button while it runs).
    func activate() {
        guard let pid = process?.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
    }

    static func tail(of url: URL, lines: Int) -> String {
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        text = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
