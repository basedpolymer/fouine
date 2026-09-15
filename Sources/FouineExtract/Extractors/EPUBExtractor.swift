// EPUBExtractor.swift — epub (SPEC §5.3).
// Propriété : A-Ingest.
//
// « zip -> XHTML dans l'ordre de l'spine, PUIS pageSplitChars À L'INTÉRIEUR de
// chaque fichier du spine : un seul XHTML peut porter un livre entier, et
// "une page = un fichier XHTML" ferait alors exploser NEAR et snippet(). »

import Foundation
import FouineCore

public struct EPUBExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> = ["epub"]

    public init() {}

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)
        let entries = try Bsdtar.list(archive: url)

        var meta: [String: String] = [:]
        let spine = try Self.spineEntries(url: url, entries: entries, meta: &meta)
        guard !spine.isEmpty else {
            throw FouineError.extraction(
                "epub with no readable document (\(url.lastPathComponent))")
        }

        var budget = TextBudget(maxBytes: limits.maxTextBytes)
        var slots: [String] = []
        // UNE seule invocation de bsdtar pour tout le spine (A11.6) : une par
        // fichier coûtait 3,44 s sur un EPUB de 45 Ko / 300 entrées, chaque appel
        // re-balayant l'archive entière.
        let bodies = try Bsdtar.extract(archive: url, entries: spine)
        for entry in spine {
            guard let data = bodies[entry] else { continue }
            // SANS URL, à la différence de HTML et XML (lot MN1) : ces octets
            // sont une entrée de l'archive, pas le fichier. L'attribut
            // `com.apple.TextEncoding` de l'`.epub` décrit le conteneur, et
            // l'appliquer à un XHTML intérieur ferait entrer le mojibake que
            // l'attribut sert justement à éviter ailleurs.
            guard let source = PlainTextExtractor.decode(data) else { continue }
            let text = budget.take(HTMLText.plainText(from: source))
            // Découpage À L'INTÉRIEUR de chaque fichier du spine.
            slots += TextPagination.paginate(text, limit: limits.pageSplitChars)
            if budget.isExhausted { break }
        }
        return Assembler.result(slots: slots, meta: meta)
    }

    /// Entrées XHTML dans l'ordre du spine : container.xml -> OPF -> spine.
    /// Repli, dans l'ordre : n'importe quel .opf de l'archive, puis tous les
    /// (x)html triés naturellement.
    static func spineEntries(url: URL, entries: [String],
                             meta: inout [String: String]) throws -> [String] {
        // container.xml ET tous les .opf en UNE invocation (A11.6) : quelques
        // kilo-octets, et l'un des deux au plus sera lu.
        var wanted = entries.filter { $0.lowercased().hasSuffix(".opf") }
        if entries.contains("META-INF/container.xml") {
            wanted.insert("META-INF/container.xml", at: 0)
        }
        let header = wanted.isEmpty
            ? [:] : try Bsdtar.extract(archive: url, entries: wanted)

        var opfPath: String?
        if let data = header["META-INF/container.xml"] {
            opfPath = try ContainerParser().parse(data)
        }
        if opfPath == nil || !entries.contains(opfPath!) {
            opfPath = entries.first(where: { $0.lowercased().hasSuffix(".opf") })
        }
        guard let opf = opfPath, entries.contains(opf) else {
            return EntrySort.sortedNaturally(entries.filter {
                let ext = EntrySort.ext(of: $0)
                return ext == "xhtml" || ext == "html" || ext == "htm"
            })
        }

        // Le chemin rendu par container.xml ne finit pas forcément par « .opf ».
        let opfData = try header[opf] ?? Bsdtar.extract(archive: url, entry: opf)
        let parsed = try OPFParser().parse(opfData, what: opf)
        for (key, value) in parsed.meta where !value.isEmpty { meta[key] = value }

        let base = (opf as NSString).deletingLastPathComponent
        var ordered: [String] = []
        for idref in parsed.spine {
            guard let href = parsed.manifest[idref] else { continue }
            let resolved = resolve(href: href, relativeTo: base)
            if entries.contains(resolved) { ordered.append(resolved) }
        }
        if ordered.isEmpty {
            return EntrySort.sortedNaturally(entries.filter {
                let ext = EntrySort.ext(of: $0)
                return ext == "xhtml" || ext == "html" || ext == "htm"
            })
        }
        return ordered
    }

    /// Chemin d'entrée d'archive à partir d'un href OPF (relatif, éventuellement
    /// pourcent-encodé, éventuellement avec des « ../ »).
    static func resolve(href: String, relativeTo base: String) -> String {
        var path = href
        if let fragment = path.firstIndex(of: "#") { path = String(path[..<fragment]) }
        path = path.removingPercentEncoding ?? path
        let joined = base.isEmpty ? path : (base as NSString).appendingPathComponent(path)
        // Normalisation des « . » et « .. » SANS jamais toucher au disque.
        var stack: [String] = []
        for component in joined.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(String(component))
            }
        }
        return stack.joined(separator: "/")
    }
}

/// META-INF/container.xml : chemin de l'OPF (`<rootfile full-path="…">`).
final class ContainerParser: NSObject, XMLParserDelegate {
    private var fullPath: String?

    func parse(_ data: Data) throws -> String? {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse() else {
            throw FouineError.extraction("unreadable META-INF/container.xml")
        }
        return fullPath
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if xmlLocalName(elementName) == "rootfile", fullPath == nil {
            fullPath = attributeDict["full-path"]
        }
    }
}

/// OPF : manifeste (id -> href), spine (suite d'idref) et métadonnées Dublin Core.
final class OPFParser: NSObject, XMLParserDelegate {
    struct Result {
        var manifest: [String: String] = [:]
        var spine: [String] = []
        var meta: [String: String] = [:]
    }

    private var result = Result()
    private var capturing: String?
    private var buffer = String()

    func parse(_ data: Data, what: String) throws -> Result {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse() else {
            throw FouineError.extraction("unreadable \(what) (OPF)")
        }
        return result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch xmlLocalName(elementName) {
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                result.manifest[id] = href
            }
        case "itemref":
            if let idref = attributeDict["idref"] { result.spine.append(idref) }
        case "title": capturing = "title"; buffer = ""
        case "creator": capturing = "author"; buffer = ""
        case "language": capturing = "lang"; buffer = ""
        // `<dc:date>` : la date de PUBLICATION de l'ouvrage (schéma v9,
        // constat PR-07). Le PREMIER seulement — un OPF peut en porter
        // plusieurs, événements `opf:event` compris, et le premier est celui
        // que les fabricants écrivent pour la publication.
        case "date": capturing = "date"; buffer = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if let key = capturing {
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.meta[key] == nil, !value.isEmpty { result.meta[key] = value }
            capturing = nil
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing != nil { buffer += string }
    }
}
