import Compression
import CryptoKit
import DownloadKit
import Foundation

enum FileOps {
    private static let chunk = 1 << 20

    struct InflateError: LocalizedError {
        let why: String
        var errorDescription: String? { "Unpacking failed: \(why)" }
    }

    /// Unpack a zip entry's raw bytes (`method` 8 deflate, 0 stored) from `src` into `dst`,
    /// returning the output's SHA-256 in hex. `progress` gets the input bytes consumed.
    static func inflate(_ src: URL, method: UInt16, to dst: URL, progress: (Int64) -> Void) throws -> String {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }
        var hash = SHA256()
        var consumed: Int64 = 0

        if method == 0 {
            while let data = try input.read(upToCount: chunk), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
                try output.write(contentsOf: data)
                consumed += Int64(data.count)
                progress(consumed)
            }
            return SHA256Hex.string(hash.finalize())
        }

        // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), exactly what a zip entry holds.
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw InflateError(why: "no decoder")
        }
        defer { compression_stream_destroy(stream) }
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { outBuf.deallocate() }

        var finished = false
        while !finished {
            try Task.checkCancellation()
            let data = try input.read(upToCount: chunk) ?? Data()
            let last = data.isEmpty
            consumed += Int64(data.count)
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(outBuf)
                stream.pointee.src_size = data.count
                repeat {
                    stream.pointee.dst_ptr = outBuf
                    stream.pointee.dst_size = chunk
                    let status = compression_stream_process(stream, last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    let produced = chunk - stream.pointee.dst_size
                    if produced > 0 {
                        let out = Data(bytesNoCopy: outBuf, count: produced, deallocator: .none)
                        hash.update(data: out)
                        try output.write(contentsOf: out)
                    }
                    switch status {
                    case COMPRESSION_STATUS_END: finished = true
                    case COMPRESSION_STATUS_OK: break
                    default: throw InflateError(why: "corrupt data")
                    }
                } while !finished && (stream.pointee.src_size > 0 || stream.pointee.dst_size == 0)
            }
            progress(consumed)
            if last && !finished { throw InflateError(why: "the data ended early") }
        }
        return SHA256Hex.string(hash.finalize())
    }

    static func size(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }
}
