import Foundation

/// A zip on an HTTP server that answers Range requests, read without downloading it: the central
/// directory is fetched from the tail, and each entry's compressed bytes are a byte range of the
/// file. That makes every entry resumable on its own, and a broken file re-downloadable alone.
struct RemoteZip {
    struct Entry {
        let name: String
        /// 0 stored, 8 deflate; nothing else is supported.
        let method: UInt16
        let compressedSize: Int64
        let size: Int64
        /// Where the entry's compressed bytes start in the zip.
        let dataOffset: Int64
    }

    let url: URL
    let length: Int64
    /// Entries by their name inside the zip (`Data/patch.MPQ`).
    let entries: [String: Entry]

    enum Failure: LocalizedError {
        case noRanges(URL)
        case rateLimited(URL, until: Date?)
        case notAZip(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .noRanges(let url): "\(url.host ?? "The server") doesn't support resumable downloads."
            case .rateLimited(let url, let until):
                if let until, until > .now {
                    "\(url.host ?? "The server") asks to wait until \(until.formatted(date: .omitted, time: .shortened)); try again then."
                } else {
                    "\(url.host ?? "The server") asks to wait before downloading more; try again later."
                }
            case .notAZip(let why): "The download isn't a readable zip (\(why))."
            case .unsupported(let why): "The zip uses an unsupported layout (\(why))."
            }
        }
    }

    /// Fetch `bytes=lo-hi` (inclusive), refusing a server that ignores the range.
    static func range(_ url: URL, _ lo: Int64, _ hi: Int64) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(lo)-\(hi)", forHTTPHeaderField: "Range")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 206 else {
            throw Failure.noRanges(url)
        }
        return (data, http)
    }

    static func open(_ url: URL) async throws -> RemoteZip {
        // The total size, from a one-byte range's `Content-Range: bytes 0-0/<total>`.
        let (_, head) = try await range(url, 0, 0)
        guard let cr = head.value(forHTTPHeaderField: "Content-Range"),
              let total = cr.split(separator: "/").last.flatMap({ Int64($0) }) else {
            throw Failure.noRanges(url)
        }

        // The end-of-central-directory record sits in the last 64 KiB (a comment is at most that).
        let tailLen = min(total, 65_557)
        let (tail, _) = try await range(url, total - tailLen, total - 1)
        guard let eocd = tail.lastIndex(of: [0x50, 0x4b, 0x05, 0x06]) else {
            throw Failure.notAZip("no end-of-directory record")
        }
        var cdSize = Int64(tail.le32(eocd + 12))
        var cdOffset = Int64(tail.le32(eocd + 16))
        // ZIP64: the classic fields are saturated and a locator 20 bytes earlier points at the
        // ZIP64 record holding the real ones.
        if cdOffset == 0xFFFF_FFFF || cdSize == 0xFFFF_FFFF {
            let loc = eocd - 20
            guard loc >= 0, tail.le32(loc) == 0x0706_4b50 else {
                throw Failure.notAZip("no ZIP64 locator")
            }
            let recOffset = Int64(tail.le64(loc + 8))
            let (rec, _) = try await range(url, recOffset, recOffset + 55)
            guard rec.le32(0) == 0x0606_4b50 else { throw Failure.notAZip("no ZIP64 record") }
            cdSize = Int64(rec.le64(40))
            cdOffset = Int64(rec.le64(48))
        }

        let (cd, _) = try await range(url, cdOffset, cdOffset + cdSize - 1)
        var entries: [String: Entry] = [:]
        var p = 0
        while p + 46 <= cd.count, cd.le32(p) == 0x0201_4b50 {
            let method = cd.le16(p + 10)
            var comp = Int64(cd.le32(p + 20))
            var size = Int64(cd.le32(p + 24))
            let nameLen = Int(cd.le16(p + 28))
            let extraLen = Int(cd.le16(p + 30))
            let commentLen = Int(cd.le16(p + 32))
            var local = Int64(cd.le32(p + 42))
            let name = String(decoding: cd[cd.startIndex + p + 46 ..< cd.startIndex + p + 46 + nameLen], as: UTF8.self)
            // The ZIP64 extra field carries, in order, only the values saturated above.
            var x = p + 46 + nameLen
            let xEnd = x + extraLen
            while x + 4 <= xEnd {
                let id = cd.le16(x), len = Int(cd.le16(x + 2))
                if id == 0x0001 {
                    var q = x + 4
                    if size == 0xFFFF_FFFF { size = Int64(cd.le64(q)); q += 8 }
                    if comp == 0xFFFF_FFFF { comp = Int64(cd.le64(q)); q += 8 }
                    if local == 0xFFFF_FFFF { local = Int64(cd.le64(q)) }
                }
                x += 4 + len
            }
            entries[name] = Entry(name: name, method: method, compressedSize: comp, size: size, dataOffset: local)
            p = xEnd + commentLen
        }
        guard !entries.isEmpty else { throw Failure.notAZip("empty directory") }
        return RemoteZip(url: url, length: total, entries: entries)
    }

    /// The entry for an MPQ, matched by file name in any folder, case-insensitively.
    func entry(forFile file: String) -> Entry? {
        entries.values.first { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare(file) == .orderedSame }
    }

    /// Resolve where an entry's data starts: its local header's name and extra lengths can differ
    /// from the central directory's, so the 30-byte header is read.
    func dataStart(of entry: Entry) async throws -> Int64 {
        let (h, _) = try await RemoteZip.range(url, entry.dataOffset, entry.dataOffset + 29)
        guard h.le32(0) == 0x0403_4b50 else { throw Failure.notAZip("bad local header for \(entry.name)") }
        guard entry.method == 0 || entry.method == 8 else {
            throw Failure.unsupported("compression method \(entry.method) for \(entry.name)")
        }
        return entry.dataOffset + 30 + Int64(h.le16(26)) + Int64(h.le16(28))
    }
}

extension Data {
    func le16(_ i: Int) -> UInt16 {
        let b = startIndex + i
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }

    func le32(_ i: Int) -> UInt32 {
        UInt32(le16(i)) | UInt32(le16(i + 2)) << 16
    }

    func le64(_ i: Int) -> UInt64 {
        UInt64(le32(i)) | UInt64(le32(i + 4)) << 32
    }

    /// The offset (from `startIndex`) of the last occurrence of `pattern`.
    func lastIndex(of pattern: [UInt8]) -> Int? {
        guard count >= pattern.count else { return nil }
        var i = count - pattern.count
        while i >= 0 {
            if pattern.enumerated().allSatisfy({ self[startIndex + i + $0.offset] == $0.element }) {
                return i
            }
            i -= 1
        }
        return nil
    }
}
