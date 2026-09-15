// HTMLExtractor.swift — html htm webarchive (SPEC §5.3).
// Propriété : A-Ingest.
//
// Parsing à la main (voir HTMLText.swift) : PAS de NSAttributedString NSHTML
// hors thread principal. Un .webarchive est une plist binaire d'Apple : le HTML
// se lit dans WebMainResource/WebResourceData, puis c'est le même chemin.

import Foundation
import FouineCore

public struct HTMLExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> = ["html", "htm", "webarchive"]

    public init() {}

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)
        let ext = url.pathExtension.lowercased()
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw FouineError.extraction(
                "cannot read (\(url.lastPathComponent)): "
                + (error as NSError).localizedDescription)
        }

        let source: String
        if ext == "webarchive" {
            source = try Self.htmlFromWebArchive(data, name: url.lastPathComponent)
        } else {
            // L'URL EST PASSÉE (lot MN1, reste d'EX2) : ces octets SONT ceux du
            // fichier, donc l'encodage que TextEdit, Mail ou le Finder ont
            // inscrit dans `com.apple.TextEncoding` les décrit. Le message
            // suit la chaîne réelle du §5.3 amendé — il annonçait encore celle
            // d'avant Windows-1252.
            guard let decoded = PlainTextExtractor.decode(data, url: url) else {
                throw FouineError.extraction(
                    "non-text content (\(url.lastPathComponent)): neither UTF-8, "
                    + "nor Windows-1252, nor ISO-8859-1, nor plausible "
                    + "macOSRoman — binary file?")
            }
            source = decoded
        }

        let text = HTMLText.plainText(from: source)
        var budget = TextBudget(maxBytes: limits.maxTextBytes)
        let kept = budget.take(text)
        var meta: [String: String] = [:]
        if let title = Self.title(in: source) { meta["title"] = title }
        return Assembler.paginatedResult(text: kept, limits: limits, meta: meta)
    }

    /// HTML de la ressource principale d'un .webarchive (plist binaire Apple).
    static func htmlFromWebArchive(_ data: Data, name: String) throws -> String {
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
        } catch {
            throw FouineError.extraction(
                "unreadable webarchive (\(name)): \((error as NSError).localizedDescription)")
        }
        guard let root = plist as? [String: Any],
              let main = root["WebMainResource"] as? [String: Any],
              let body = main["WebResourceData"] as? Data
        else {
            throw FouineError.extraction(
                "webarchive without WebMainResource/WebResourceData (\(name))")
        }
        if let encodingName = main["WebResourceTextEncodingName"] as? String {
            let cf = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if cf != kCFStringEncodingInvalidId {
                let ns = CFStringConvertEncodingToNSStringEncoding(cf)
                if let text = String(data: body, encoding: String.Encoding(rawValue: ns)) {
                    return text
                }
            }
        }
        guard let text = PlainTextExtractor.decode(body) else {
            throw FouineError.extraction("webarchive: unrecognized encoding (\(name))")
        }
        return text
    }

    static func title(in html: String) -> String? {
        guard let open = html.range(of: "<title", options: [.caseInsensitive]),
              let gt = html[open.upperBound...].firstIndex(of: ">"),
              let close = html.range(of: "</title", options: [.caseInsensitive],
                                     range: gt..<html.endIndex)
        else { return nil }
        let raw = String(html[html.index(after: gt)..<close.lowerBound])
        let text = HTMLText.decodeEntities(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
