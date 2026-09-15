// ZlibBlob.swift — compression zlib des dispositions OCR (SPEC §4.1, ocr_layout).
// Propriété : A-Core.
//
// « Un enregistrement par page : JSON compressé zlib, [{t,x,y,w,h,c}, …] »
// Implémenté sur la libcompression Apple (COMPRESSION_ZLIB), sans dépendance
// supplémentaire (SPEC §2.2 : deux dépendances, pas une de plus).

import Foundation
import Compression

/// Ligne telle qu'elle est sérialisée dans `ocr_layout` et dans le JSONL de
/// l'annexe B : coordonnées normalisées 0..1, origine en bas à gauche.
public struct LayoutLine: Codable, Sendable, Equatable {
    public let t: String
    public let x: Double, y: Double, w: Double, h: Double
    public let c: Double
    public init(t: String, x: Double, y: Double, w: Double, h: Double, c: Double) {
        self.t = t; self.x = x; self.y = y; self.w = w; self.h = h; self.c = c
    }
    public init(_ line: OCRLine) {
        self.init(t: line.text, x: line.x, y: line.y, w: line.w, h: line.h,
                  c: line.confidence)
    }
    /// Variante ARRONDIE, réservée à l'écriture en base (voir `OCRLayoutCodec`).
    public init(rounded line: OCRLine) {
        self.init(t: line.text,
                  x: OCRLayoutCodec.round4(line.x), y: OCRLayoutCodec.round4(line.y),
                  w: OCRLayoutCodec.round4(line.w), h: OCRLayoutCodec.round4(line.h),
                  c: OCRLayoutCodec.round4(line.confidence))
    }
    public var ocrLine: OCRLine {
        OCRLine(text: t, x: x, y: y, w: w, h: h, confidence: c)
    }
}

public enum OCRLayoutCodec {
    /// Décimales conservées à l'encodage (audit A4/point 3 du 01/09/2026).
    ///
    /// Vision rend des flottants doubles bruts (`0.8235294117647058`) que
    /// `JSONEncoder` écrit en 17 chiffres significatifs. À 150 dpi sur une page
    /// A4, la 5e décimale d'une coordonnée normalisée vaut ~0,02 pixel : elle ne
    /// décrit rien. Mesuré sur 400 blobs réels : −40,4 % (2 458 -> 1 464 o), et
    /// le décodeur est INCHANGÉ, donc compatible avec les blobs déjà écrits.
    public static let decimals = 4
    private static let scale = 10_000.0

    static func round4(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        return (value * scale).rounded() / scale
    }

    /// [{t,x,y,w,h,c}, …] -> JSON -> zlib. Les flottants sont arrondis ICI, à
    /// l'écriture : le texte des lignes, lui, est recopié tel quel.
    public static func encode(_ lines: [OCRLine]) throws -> Data {
        let json = try JSONEncoder().encode(lines.map(LayoutLine.init(rounded:)))
        return try ZlibBlob.compress(json)
    }

    /// zlib -> JSON -> [{t,x,y,w,h,c}, …].
    public static func decode(_ blob: Data) throws -> [OCRLine] {
        let json = try ZlibBlob.decompress(blob)
        return try JSONDecoder().decode([LayoutLine].self, from: json).map(\.ocrLine)
    }
}

enum ZlibBlob {
    static func compress(_ data: Data) throws -> Data {
        try stream(data, operation: COMPRESSION_STREAM_ENCODE)
    }

    static func decompress(_ data: Data) throws -> Data {
        try stream(data, operation: COMPRESSION_STREAM_DECODE)
    }

    private static func stream(_ input: Data,
                               operation: compression_stream_operation) throws -> Data {
        if input.isEmpty { return Data() }
        let bufferSize = 64 * 1024
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        var status = compression_stream_init(streamPtr, operation, COMPRESSION_ZLIB)
        guard status == COMPRESSION_STATUS_OK else {
            throw FouineError.databaseFailure("ocr_layout: zlib initialization failed")
        }
        defer { compression_stream_destroy(streamPtr) }

        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dst.deallocate() }
        var output = Data()

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            streamPtr.pointee.src_ptr = base
            streamPtr.pointee.src_size = raw.count
            streamPtr.pointee.dst_ptr = dst
            streamPtr.pointee.dst_size = bufferSize

            repeat {
                status = compression_stream_process(
                    streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = bufferSize - streamPtr.pointee.dst_size
                    if produced > 0 { output.append(dst, count: produced) }
                    streamPtr.pointee.dst_ptr = dst
                    streamPtr.pointee.dst_size = bufferSize
                default:
                    throw FouineError.databaseFailure("ocr_layout: invalid zlib stream")
                }
            } while status != COMPRESSION_STATUS_END
        }
        return output
    }
}
