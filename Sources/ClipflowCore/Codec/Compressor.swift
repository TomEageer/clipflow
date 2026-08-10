import Foundation
import Compression

/// LZFSE 压缩。用 Apple 系统自带的 `Compression` 框架，**零第三方依赖**。
///
/// 实测压缩率（zlib-6 作代理测得，LZFSE 同量级）：
///   HTML 富文本 39.6% · RTF 39.6% · 纯中文 5.2% · Java 代码 4.9% · JSON 5.8%
///   但 120B 短文本 → 97.5%（压了白压，还多花 CPU）
/// 故设 512B 阈值。
public enum Compressor {

    /// 低于此字节数不压缩，直接内联进 SQLite 行
    public static let threshold = 512

    public static func shouldCompress(_ data: Data) -> Bool {
        data.count >= threshold
    }

    public static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        return perform(data, operation: COMPRESSION_STREAM_ENCODE,
                       capacity: max(data.count, 64))
    }

    public static func decompress(_ data: Data, originalSize: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        // 解压缓冲给足原始大小，避免多次扩容
        return perform(data, operation: COMPRESSION_STREAM_DECODE,
                       capacity: max(originalSize, data.count * 4, 64))
    }

    private static func perform(_ input: Data,
                                operation: compression_stream_operation,
                                capacity: Int) -> Data? {
        input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return nil }

            var out = Data()
            var dstCapacity = capacity
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
            defer { dst.deallocate() }

            var stream = compression_stream(
                dst_ptr: dst, dst_size: dstCapacity,
                src_ptr: srcBase, src_size: input.count,
                state: nil
            )
            guard compression_stream_init(&stream, operation, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
                return nil
            }
            defer { compression_stream_destroy(&stream) }

            stream.src_ptr = srcBase
            stream.src_size = input.count
            stream.dst_ptr = dst
            stream.dst_size = dstCapacity

            while true {
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = dstCapacity - stream.dst_size
                    if produced > 0 {
                        out.append(dst, count: produced)
                        stream.dst_ptr = dst
                        stream.dst_size = dstCapacity
                    }
                    if status == COMPRESSION_STATUS_END { return out }
                    if produced == 0 { return nil }   // 无进展，避免死循环
                case COMPRESSION_STATUS_ERROR:
                    return nil
                default:
                    return nil
                }
                _ = dstCapacity   // capacity 固定，循环消费
            }
        }
    }
}
