import DownloadKit
import Foundation

/// One MPQ the game needs, from data-manifest.tsv.
struct DataFile: Hashable {
    let name: String
    let size: Int64
    let sha256: String
}

/// The game data folder: whether it is complete, and fetching what is missing.
@MainActor
final class GameData: ObservableObject {
    enum State: Equatable {
        case checking
        case ready
        /// Files absent, the wrong size, or failing their hash.
        case missing([DataFile])
        case working(Progress)
        case failed(String)
    }

    struct Progress: Equatable {
        var title: String
        var detail: String
        var fraction: Double
    }

    @Published private(set) var state: State = .checking
    let manifest: [DataFile]
    private var job: Task<Void, Never>?
    /// The running verify or download; progress from any other (a finished one's last queued
    /// update) is dropped.
    private var jobID: UUID?

    init() {
        manifest = GameData.loadManifest()
    }

    var totalSize: Int64 { manifest.reduce(0) { $0 + $1.size } }

    var isBusy: Bool { jobID != nil }

    private func begin() -> UUID {
        let id = UUID()
        jobID = id
        return id
    }

    /// End the job, then show where things stand.
    private func end(_ final: State? = nil) {
        jobID = nil
        DockProgress.show(nil)
        if let final { state = final } else { quickCheck() }
    }

    private func report(_ id: UUID, _ p: Progress) {
        guard jobID == id else { return }
        state = .working(p)
        DockProgress.show(p.fraction)
    }

    static func loadManifest() -> [DataFile] {
        guard let url = Bundle.main.url(forResource: "data-manifest", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            if line.hasPrefix("#") { return nil }
            let f = line.split(separator: "\t")
            guard f.count == 3, let size = Int64(f[1]) else { return nil }
            return DataFile(name: String(f[0]), size: size, sha256: String(f[2]))
        }
    }

    /// The fast check, run at every launch: each file present at its exact size. Hashes are left to
    /// a download (always verified) and to "Verify Game Files".
    func quickCheck() {
        guard !isBusy else { return }
        let dir = Paths.data
        let missing = manifest.filter { FileOps.size(dir.appendingPathComponent($0.name)) != $0.size }
        state = missing.isEmpty ? .ready : .missing(missing)
    }

    /// Hash every file; the ones that fail are dropped and reported missing.
    func verify() {
        guard !isBusy else { return }
        let files = manifest
        let dir = Paths.data
        let total = Double(totalSize)
        let id = begin()
        job = Task {
            var bad: [DataFile] = []
            var done: Int64 = 0
            do {
                for f in files {
                    let url = dir.appendingPathComponent(f.name)
                    guard FileOps.size(url) == f.size else { bad.append(f); done += f.size; continue }
                    let base = done
                    let tick = Throttle()
                    let sum = try await Task.detached {
                        try SHA256Hex.ofFile(url) { read in
                            guard tick.ready() else { return }
                            Task { @MainActor in
                                self.report(id, Progress(
                                    title: "Verifying game files…",
                                    detail: f.name,
                                    fraction: Double(base + read) / total))
                            }
                        }
                    }.value
                    if sum != f.sha256 { bad.append(f) }
                    done += f.size
                }
                end(bad.isEmpty ? .ready : .missing(bad))
            } catch {
                end()
            }
        }
    }

    func cancel() {
        job?.cancel()
    }

    /// Files fetched at once: archive.org paces each connection, not the total, so a few side by
    /// side multiply the speed.
    static let parallel = 3

    /// Download, unpack and verify the missing files, a few at a time. Partial downloads survive
    /// a pause or a quit and resume next time.
    func download(_ files: [DataFile]) {
        guard !isBusy else { return }
        let dir = Paths.data
        let work = dir.appendingPathComponent(".download", isDirectory: true)
        let source = Prefs.dataURL
        let id = begin()
        state = .working(Progress(title: "Connecting…", detail: source.host ?? "", fraction: 0))
        Notifier.requestPermission()
        // Largest first: the long file starts at once and the small ones fill in beside it.
        var queue = files.sorted { $0.size > $1.size }[...]
        let tally = Tally(files: files)

        job = Task {
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                try checkSpace(for: files, in: dir)
                let zip = try await RemoteZip.open(source)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<Self.parallel {
                        guard let f = queue.popFirst() else { break }
                        group.addTask { try await self.fetch(f, from: zip, into: dir, work: work, job: id, tally: tally) }
                    }
                    while try await group.next() != nil {
                        if let f = queue.popFirst() {
                            group.addTask { try await self.fetch(f, from: zip, into: dir, work: work, job: id, tally: tally) }
                        }
                    }
                }
                try? FileManager.default.removeItem(at: work)
                end()
                if state == .ready { Notifier.post("The game is ready to play.", detail: "\(bytes(tally.total)) downloaded.") }
            } catch is CancellationError {
                end()
            } catch let e as URLError where e.code == .cancelled {
                end()
            } catch {
                end(.failed(error.localizedDescription))
                Notifier.post("The game data download stopped.", detail: error.localizedDescription)
            }
        }
    }

    /// One file: its byte range of the zip, unpacked, hash-checked, moved into place.
    private func fetch(_ f: DataFile, from zip: RemoteZip, into dir: URL, work: URL, job id: UUID, tally: Tally) async throws {
        guard let entry = zip.entry(forFile: f.name) else {
            throw RemoteZip.Failure.notAZip("\(f.name) isn't in the download")
        }
        let start = try await zip.dataStart(of: entry)
        let packed = work.appendingPathComponent(f.name + ".packed")
        // Progress counts unpacked bytes; the packed size is within a percent or two.
        let scale = Double(f.size) / Double(max(entry.compressedSize, 1))
        let tick = Throttle()

        // A dropped connection keeps what arrived and resumes after 2, 4, 8, 16, then 30 s, nine tries in all.
        // The system's User-Agent, as the launcher's own downloader sent before.
        let options = DownloadOptions(retry: .patient, timeout: 60, usesSystemUserAgent: true)
        do {
            try await Download.range(zip.url, offset: start, length: entry.compressedSize, appendingTo: packed, options: options) { got in
                guard tick.ready() else { return }
                Task { @MainActor in
                    tally.set(f.name, Int64(Double(got.received) * scale))
                    self.report(id, tally.progress())
                }
            }
        } catch DownloadError.rateLimited(let until, _) {
            // The server asked for a longer wait than DownloadKit waits out; the bytes on disk are kept.
            throw RemoteZip.Failure.rateLimited(zip.url, until: until)
        } catch is DownloadError {
            // Anything but the bytes asked for (a whole file, an error page) would append the wrong bytes.
            throw RemoteZip.Failure.noRanges(zip.url)
        }

        tally.unpacking(f.name)
        report(id, tally.progress())
        let target = dir.appendingPathComponent(f.name)
        let unpacking = work.appendingPathComponent(f.name + ".part")
        let sum = try await Task.detached {
            try FileOps.inflate(packed, method: entry.method, to: unpacking) { _ in }
        }.value
        try? FileManager.default.removeItem(at: packed)
        guard sum == f.sha256 else {
            try? FileManager.default.removeItem(at: unpacking)
            throw RemoteZip.Failure.notAZip("\(f.name) failed its checksum; try again")
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: unpacking, to: target)
        tally.finished(f.name)
        report(id, tally.progress())
    }

    /// Refuse to start when the disk can't hold the unpacked files plus the packed ones in flight.
    private func checkSpace(for files: [DataFile], in dir: URL) throws {
        let inFlight = files.map(\.size).sorted(by: >).prefix(Self.parallel).reduce(0, +)
        let need = files.reduce(0) { $0 + $1.size } + inFlight
        let values = try dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values.volumeAvailableCapacityForImportantUsage, free < need {
            throw SpaceError(need: need, free: free)
        }
    }

    struct SpaceError: LocalizedError {
        let need: Int64, free: Int64
        var errorDescription: String? {
            "Not enough disk space: the game data needs \(bytes(need)) and \(bytes(free)) is free."
        }
    }
}

/// Lets one progress update through per tenth of a second, from any thread.
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func ready() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.1 else { return false }
        last = now
        return true
    }
}

/// Bytes per file across the parallel downloads, summed into one progress line.
@MainActor
final class Tally {
    let total: Int64
    private let count: Int
    private var got: [String: Int64] = [:]
    private var sizes: [String: Int64] = [:]
    private var unpackingNow: Set<String> = []
    private var done = 0
    private let meter = SpeedMeter()

    init(files: [DataFile]) {
        total = files.reduce(0) { $0 + $1.size }
        count = files.count
        for f in files { sizes[f.name] = f.size }
    }

    func set(_ name: String, _ bytes: Int64) { got[name] = min(bytes, sizes[name] ?? bytes) }

    func unpacking(_ name: String) {
        got[name] = sizes[name]
        unpackingNow.insert(name)
    }

    func finished(_ name: String) {
        unpackingNow.remove(name)
        done += 1
    }

    func progress() -> GameData.Progress {
        let shown = got.values.reduce(0, +)
        let rate = meter.sample(shown)
        var detail = "\(bytes(shown)) of \(bytes(total))"
        if let rate, rate > 0 {
            detail += " · \(bytes(Int64(rate)))/s · \(duration(Double(total - shown) / rate)) left"
        }
        if !unpackingNow.isEmpty {
            detail += " · unpacking \(unpackingNow.sorted().joined(separator: ", "))"
        }
        let title = count == 1 ? "Downloading game data…" : "Downloading game data… (\(done) of \(count) files)"
        return GameData.Progress(title: title, detail: detail, fraction: total > 0 ? Double(shown) / Double(total) : 0)
    }
}

/// Download speed over the last few seconds.
@MainActor
final class SpeedMeter {
    private var samples: [(Date, Int64)] = []

    func sample(_ total: Int64) -> Double? {
        let now = Date()
        samples.append((now, total))
        samples.removeAll { now.timeIntervalSince($0.0) > 5 }
        guard let first = samples.first, now.timeIntervalSince(first.0) > 0.5 else { return nil }
        return Double(total - first.1) / now.timeIntervalSince(first.0)
    }

    func reset() { samples.removeAll() }
}

func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

func duration(_ seconds: Double) -> String {
    let f = DateComponentsFormatter()
    f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
    f.unitsStyle = .abbreviated
    f.maximumUnitCount = 2
    return f.string(from: max(seconds, 1)) ?? ""
}
