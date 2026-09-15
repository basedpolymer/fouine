// RichTextExtractor.swift — doc rtf rtfd (SPEC §5.3).
// Propriété : A-Ingest.
//
// « NSAttributedString(url:options:documentAttributes:) — sûr et irremplaçable
// sur ces trois-là (vérifié : NSDocFormat 3 489 car., NSRTF accents corrects) ».
//
// ═══ LE TYPE EST TRANCHÉ SUR LES OCTETS DE TÊTE (audit A1-01, D2-01, D2-02) ══
//
// `options: [:]` laissait AppKit RENIFLER le type. Pour un `.doc` dont le
// contenu est en réalité du HTML, l'importateur choisi était celui de WebKit,
// qui RÉSOUT ET TÉLÉCHARGE les sous-ressources (`<img>`, `<link>`) : une balise
// de traçage posée dans un document suffisait à faire sortir Fouine sur le
// réseau à l'indexation, en `http:` comme en `https:` (mesuré trois fois par
// deux auditeurs, dont deux connexions TLS acceptées par un serveur témoin),
// et une adresse non routable gelait un worker 62 s. Le document était indexé,
// rien ne signalait l'incident.
//
// Le type est donc IMPOSÉ, et il est décidé sur les OCTETS, pas sur l'extension
// (D2-01) : imposer `.docFormat` à tout `.doc` fermait bien le trou, mais
// perdait les documents mal nommés — un `.docx` renommé `.doc` est ce que
// produisent une pièce jointe renommée, un export d'application métier ou un
// scanner réseau, et Word les ouvre sans broncher depuis vingt ans. Mesuré :
// avec le tri par extension, `faux-nom.doc` (un vrai OOXML, témoin
// « QUINQUENNAT » et ses accents) passait de `docs.state = extracted` à
// `failed`, sans que rien ne dise à l'utilisateur qu'il venait de perdre du
// contenu qui s'indexait la veille.
//
//   · `.rtfd` est un PAQUET (un répertoire) : il se tranche sur l'extension,
//     avant toute lecture — il n'y a pas d'octets de tête à lire ;
//   · `D0 CF 11 E0` (OLE Compound File)  → `.docFormat` ;
//   · `{\rtf`                            → `.rtf` ;
//   · `50 4B 03 04` (zip)                → délégué à OOXMLExtractor, qui
//     tranche à son tour sur les ENTRÉES de l'archive ;
//   · tout le reste                      → REFUS. C'est le comportement voulu
//     (§7.2 n°3) : la classe entière « un `.doc` qui est en réalité autre
//     chose » disparaît, pas seulement le cas HTML.
//
// CEINTURE (A1-02) : `options[.timeout] = 5` et un `Deadline.extraction` autour
// de l'appel, comme `PDFExtractor`. Aucun des deux ne doit plus jamais servir
// sur ce chemin — le type est connu avant l'appel —, et c'est bien pour cela
// qu'ils sont là.
//
// Et le CONTRÔLE DE PLAUSIBILITÉ est obligatoire (§5.3, §7.2 n°3) : sur un
// format riche, NSAttributedString n'échoue pas, il rend un FAUX SUCCÈS. Le
// mojibake ne doit jamais entrer dans page_fts, donc dans fts5vocab, donc dans
// l'expansion floue.

import Foundation
import AppKit
import FouineCore

public struct RichTextExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> = ["doc", "rtf", "rtfd"]

    public init() {}

    /// Ce que l'inspection des octets de tête décide.
    enum Shape: Equatable {
        /// Type documentaire à IMPOSER à AppKit.
        case attributed(NSAttributedString.DocumentType)
        /// Archive zip : c'est OOXML qui sait la lire.
        case ooxml
    }

    /// Nombre d'octets lus pour trancher. Le plus long des motifs
    /// (`{\rtf`, 5 octets) tient dans 8 ; on en lit 8 pour n'avoir qu'une
    /// lecture, quel que soit le motif ajouté plus tard.
    static let headBytes = 8

    /// Le type documentaire, tranché sur l'EXTENSION pour le seul paquet
    /// (`.rtfd`) et sur les OCTETS pour tout le reste. `nil` = refus.
    static func shape(of url: URL, ext: String) -> Shape? {
        // `.rtfd` est un RÉPERTOIRE : il n'a pas d'octets de tête, et AppKit ne
        // peut de toute façon pas le confondre avec autre chose.
        if ext == "rtfd" { return .attributed(.rtfd) }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()

        if head.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { return .attributed(.docFormat) }
        if head.starts(with: Array("{\\rtf".utf8)) { return .attributed(.rtf) }
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .ooxml }
        return nil
    }

    /// Le refus, avec le motif que `docs.err` portera. ANGLAIS, comme tout ce
    /// que le cœur écrit (palier 3.5).
    static func unrecognised(_ url: URL) -> FouineError {
        .extraction("unrecognised format (\(url.lastPathComponent)): "
                    + "neither OLE, RTF nor OOXML")
    }

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)
        let ext = url.pathExtension.lowercased()

        guard let shape = Self.shape(of: url, ext: ext) else {
            throw Self.unrecognised(url)
        }
        guard case .attributed(let forced) = shape else {
            // Un conteneur OOXML mal nommé reste INDEXÉ, avec ses accents
            // (D2-01). Le type OOXML exact se tranche sur les entrées.
            return try OOXMLCore.result(url: url, kind: nil, limits: limits)
        }

        var attributes: NSDictionary?
        let attributed: NSAttributedString
        do {
            // DÉLAI DE GARDE (A1-02). `NSAttributedString(url:)` était l'appel
            // AppKit nu du produit : aucune échéance, et 62 s mesurées sur un
            // seul document. `options[.timeout]` borne le chargement des
            // sous-ressources, le `Deadline` borne l'appel entier.
            let read = try Deadline.extraction(
                seconds: Deadline.renderSeconds,
                label: "reading \(url.lastPathComponent)",
                body: { () -> (NSAttributedString, NSDictionary?) in
                    var inner: NSDictionary?
                    let string = try NSAttributedString(
                        url: url,
                        options: [.documentType: forced, .timeout: 5.0],
                        documentAttributes: &inner)
                    return (string, inner)
                })
            attributed = read.0
            attributes = read.1
        } catch let error as FouineError {
            throw error                      // dépassement d'échéance, déjà traduit
        } catch {
            throw FouineError.extraction(
                "cannot read \(ext) (\(url.lastPathComponent)): "
                + (error as NSError).localizedDescription)
        }

        // Critère 1 : un format riche lu comme du texte brut est un faux succès.
        // Redondant depuis que le type est imposé — et gardé pour cela même :
        // c'est lui qui dira si l'importateur retombe un jour sur `plain`.
        let bridged = attributes as? [String: Any]
        let documentType = bridged?[
            NSAttributedString.DocumentAttributeKey.documentType.rawValue] as? String
        if documentType == NSAttributedString.DocumentType.plain.rawValue {
            throw FouineError.extraction(
                "implausible content (mojibake): .\(ext) read as NSPlainText "
                + "(\(url.lastPathComponent))")
        }

        // Critère 2 : proportion de caractères hors plages lisibles.
        let text = attributed.string
        try Plausibility.check(text, ext: ext)

        var budget = TextBudget(maxBytes: limits.maxTextBytes)
        let kept = budget.take(text)
        var meta: [String: String] = [:]
        if let title = bridged?[
            NSAttributedString.DocumentAttributeKey.title.rawValue] as? String {
            meta["title"] = title
        }
        if let author = bridged?[
            NSAttributedString.DocumentAttributeKey.author.rawValue] as? String {
            meta["author"] = author
        }
        return Assembler.paginatedResult(text: kept, limits: limits, meta: meta)
    }
}
