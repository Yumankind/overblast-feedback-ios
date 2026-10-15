import Compression
import Foundation

/// `logFile` (contract §3.5): everything the buffer holds, as gzip-compressed NDJSON, oldest first,
/// at most 4 MB as sent. When the compressed file would be larger, the oldest lines are cut until it
/// fits, and the file's first line says so.
public enum LogFileBuilder {
  /// 4 MB as sent: 4,000,000 decoded (compressed) bytes, before base64.
  public static let maxBytes = 4_000_000

  /// The file for `entries` (oldest first), within `budget` compressed bytes. Nil when there are no
  /// entries or not even the cut marker fits.
  public static func build(_ entries: [FeedbackLogEntry], budget: Int = maxBytes, timeZone: TimeZone = .current) -> FeedbackLogFile? {
    let sorted = entries.sorted { $0.t < $1.t }
    guard !sorted.isEmpty, budget > 64 else { return nil }
    let encoder = FeedbackPayload.encoder()
    let lines: [Data] = sorted.map { (try? encoder.encode($0)) ?? Data() }

    var start = 0
    for _ in 0..<12 {
      let kept = lines[start...]
      var body = Data()
      var cut: FeedbackLogEntry?
      if start > 0 {
        cut = cutMarker(count: start, from: sorted[0].t, to: sorted[start - 1].t, at: sorted[start].t, timeZone: timeZone)
        body.append((try? encoder.encode(cut!)) ?? Data())
        body.append(0x0A)
      }
      for line in kept {
        body.append(line)
        body.append(0x0A)
      }
      let (encoding, data) = compress(body)
      if data.count <= budget {
        let first = cut ?? sorted[start]
        return FeedbackLogFile(
          encoding: encoding, base64: data.base64EncodedString(),
          lines: kept.count + (cut == nil ? 0 : 1), from: first.t, to: sorted[sorted.count - 1].t
        )
      }
      guard start < sorted.count - 1 else { return nil }
      // Cut in proportion to how far over the budget it is, with a margin, and at least a tenth.
      let remaining = sorted.count - start
      let keepFraction = Double(budget) / Double(data.count) * 0.9
      let keep = max(1, min(remaining - max(1, remaining / 10), Int(Double(remaining) * keepFraction)))
      start = sorted.count - keep
    }
    return nil
  }

  /// `older lines cut to fit: 12,000 lines from 13:40 to 13:52`, in the device's time zone.
  static func cutMarker(count: Int, from: Int64, to: Int64, at t: Int64, timeZone: TimeZone) -> FeedbackLogEntry {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm"
    let a = formatter.string(from: Date(timeIntervalSince1970: Double(from) / 1000))
    let b = formatter.string(from: Date(timeIntervalSince1970: Double(to) / 1000))
    let noun = count == 1 ? "line" : "lines"
    return FeedbackLogEntry(t: t, level: .warn, msg: "older lines cut to fit: \(FeedbackLogBuffer.grouped(count)) \(noun) from \(a) to \(b)", src: FeedbackLogBuffer.source)
  }

  /// gzip, or the bytes as they are (`identity`) if the system compressor fails.
  static func compress(_ data: Data) -> (encoding: String, data: Data) {
    if let gz = Gzip.compress(data) { return ("gzip", gz) }
    return ("identity", data)
  }
}

/// gzip (RFC 1952) around the Compression framework's raw deflate: `COMPRESSION_ZLIB` produces a
/// bare RFC 1951 stream, so the ten-byte header and the CRC-32 and length trailer are written here.
public enum Gzip {
  public static func compress(_ input: Data) -> Data? {
    var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
    guard let deflated = deflate(input) else { return nil }
    out.append(deflated)
    appendLE(&out, crc32(input))
    appendLE(&out, UInt32(truncatingIfNeeded: input.count))
    return out
  }

  /// The raw deflate stream inside a gzip member written by `compress`, or nil if it is not one.
  public static func decompress(_ gz: Data, expectedSize: Int? = nil) -> Data? {
    guard gz.count >= 18, gz[gz.startIndex] == 0x1F, gz[gz.startIndex + 1] == 0x8B, gz[gz.startIndex + 2] == 0x08 else { return nil }
    let body = gz.subdata(in: (gz.startIndex + 10)..<(gz.endIndex - 8))
    let size = gz.subdata(in: (gz.endIndex - 4)..<gz.endIndex).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    let capacity = expectedSize ?? Int(UInt32(littleEndian: size))
    guard capacity > 0 else { return Data() }
    var dst = Data(count: capacity)
    let n = dst.withUnsafeMutableBytes { d in
      body.withUnsafeBytes { s in
        compression_decode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, capacity, s.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_ZLIB)
      }
    }
    guard n == capacity else { return nil }
    let data = dst.prefix(n)
    let crc = gz.subdata(in: (gz.endIndex - 8)..<(gz.endIndex - 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    return crc32(data) == UInt32(littleEndian: crc) ? Data(data) : nil
  }

  static func deflate(_ input: Data) -> Data? {
    if input.isEmpty { return Data([0x03, 0x00]) }
    // Deflate's worst case is a few bytes per 64 KB stored block over the input.
    let capacity = input.count + input.count / 64 + 1024
    var dst = Data(count: capacity)
    let n = dst.withUnsafeMutableBytes { d in
      input.withUnsafeBytes { s in
        compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, capacity, s.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
      }
    }
    guard n > 0 else { return nil }
    return dst.prefix(n)
  }

  private static func appendLE(_ data: inout Data, _ value: UInt32) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }

  private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
  }

  public static func crc32(_ data: Data) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    data.withUnsafeBytes { raw in
      for byte in raw.bindMemory(to: UInt8.self) {
        c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
      }
    }
    return c ^ 0xFFFF_FFFF
  }
}
