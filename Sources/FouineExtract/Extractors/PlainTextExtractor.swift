// PlainTextExtractor.swift — txt md csv tsv tex json log, et les fichiers
// TECHNIQUES (code source, scripts, configuration) du lot INT-F1 (SPEC §5.3).
// Propriété : A-Ingest.
//
// « lecture directe ; UTF-8, repli ISO-8859-1 puis String.Encoding.macOSRoman »,
// amendé le 13/09/2026 (EX2) : attribut `com.apple.TextEncoding` d'abord,
// Windows-1252 avant ISO-8859-1.
// Pagination à limits.pageSplitChars sur la frontière de paragraphe (§5.3).

import Foundation
import FouineCore

public struct PlainTextExtractor: TextExtractor {
    /// Les sept formats « document » du §5.3 d'origine.
    public static let documentExtensions: Set<String> = [
        "txt", "md", "csv", "tsv", "tex", "json", "log",
    ]

    /// Fichiers TECHNIQUES (lot INT-F1) : code source, scripts, configuration,
    /// documentation légère. Ce sont des fichiers texte, ils se lisent par le
    /// même chemin — la seule chose qui change est le garde-fou « source
    /// minifiée » ci-dessous, qui ne s'applique QU'À EUX (un `.log` ou un
    /// `.tex` peuvent légitimement tenir sur une seule ligne de 100 000
    /// caractères, un `.js` de 100 000 caractères sur une ligne est une
    /// bibliothèque compilée que personne ne cherche en toutes lettres).
    ///
    /// `ipynb` n'y est pas : il a son extracteur (`NotebookExtractor`), qui sait
    /// écarter les sorties de cellules.
    public static let sourceExtensions: Set<String> = [
        // JavaScript / TypeScript et cousins
        "js", "mjs", "cjs", "jsx", "ts", "tsx", "vue", "svelte",
        // JVM
        "java", "kt", "kts", "scala", "groovy", "gradle",
        // C et famille
        "c", "cc", "cpp", "cxx", "h", "hh", "hpp", "m", "mm", "cmake",
        // Autres langages
        "swift", "py", "pyi", "rb", "rs", "go", "php", "pl", "pm", "lua", "r",
        "cs", "fs", "vb", "sql", "graphql", "proto",
        // Scripts
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "dockerfile",
        // Feuilles de style
        "css", "scss", "sass", "less",
        // Configuration
        "yaml", "yml", "toml", "ini", "cfg", "conf", "properties",
        // Documentation légère
        "rst", "adoc", "asciidoc", "org", "textile", "mdx", "markdown", "mkd",
    ]

    public static let supportedExtensions: Set<String> =
        documentExtensions.union(sourceExtensions)

    /// Motif de refus d'une source MINIFIÉE, classé `.skipped` par
    /// `ExtractOutcome` : un `.min.js` est du texte, mais c'est du texte que
    /// personne ne lit et dont chaque « mot » pollue `fts5vocab`, donc
    /// l'expansion floue (§5.5.2).
    public static let minifiedReason = "minified source"

    /// Longueur moyenne de ligne au-delà de laquelle une source est tenue pour
    /// minifiée. Une source écrite à la main dépasse rarement 120 caractères
    /// par ligne ; un facteur 8 laisse passer les fichiers générés lisibles
    /// (tableaux de données, longues chaînes traduites).
    public static let maxAverageLineLength = 1_000

    public init() {}

    /// Décision PURE : ce fichier est-il une source minifiée ? Le nom tranche
    /// d'abord (`jquery.min.js`), la forme du texte ensuite.
    public static func isMinified(name: String, text: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasSuffix(".min.js") || lower.hasSuffix(".min.css") { return true }
        // Échantillon de tête : une source minifiée l'est dès sa première ligne,
        // et parcourir 50 Mio pour s'en convaincre ne dit rien de plus.
        let sample = text.prefix(Plausibility.sampleCharacters)
        guard !sample.isEmpty else { return false }
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)
        // La dernière ligne de l'échantillon est probablement TRONQUÉE : on ne
        // la compte pas quand il y en a d'autres.
        let counted = lines.count > 1 ? lines.dropLast() : lines[...]
        guard !counted.isEmpty else { return false }
        let total = counted.reduce(0) { $0 + $1.count }
        return total / counted.count > maxAverageLineLength
    }

    /// Motif de refus d'un texte qui porte une suite interminable sans aucun
    /// blanc (EX2) : un export de données, une colonne de base 64, un JSON
    /// compacté. Il porte la LONGUEUR mesurée, donc `ExtractOutcome` le
    /// reconnaît par ce préfixe et non par un ensemble exact.
    public static let dataDumpPrefix = "no readable text: "

    /// Longueur de suite sans blanc à partir de laquelle un « document » est
    /// refusé. Aucun mot, aucune URL ordinaire n'approche 2 000 caractères ;
    /// la page de 4 000 caractères qui en porte une fait calculer à CoreText
    /// une césure pathologique et entre dans `vocab_tri` comme un mot géant.
    public static let maxRunWithoutWhitespace = 2_000

    public static func dataDumpReason(run: Int) -> String {
        dataDumpPrefix + "\(run)-character run without a space — data dump?"
    }

    public static func isDataDump(_ message: String) -> Bool {
        message.hasPrefix(dataDumpPrefix)
    }

    /// Ces octets se parsent-ils comme du JSON (lot MN1, faux refus d'EX2) ?
    ///
    /// UN JSON COMPACTÉ N'EST PAS UN VIDAGE DE DONNÉES. Un export d'API rendu
    /// sans blanc — `{"commandes":[{"id":0,"sku":"REF-00000-XY"…` — porte une
    /// suite de plusieurs dizaines de milliers de caractères sans espace :
    /// mesuré le 14/09/2026, un export de 36 417 caractères était refusé en
    /// entier. Or il a une syntaxe, elle se vérifie, et ses valeurs sont
    /// exactement ce que l'on cherchera dedans (une référence, un nom, un
    /// montant).
    ///
    /// SUR LE CHEMIN DU REFUS SEULEMENT : la sonde ne tourne que si la suite
    /// dépasse le plafond, donc jamais sur un fichier ordinaire. Et sous un
    /// plafond de taille : au-delà, `JSONSerialization` construirait en
    /// mémoire un arbre de plusieurs fois le poids du fichier pour apprendre
    /// qu'un dump de dix mégaoctets est bien formé — un dump reste un dump.
    static let jsonProbeMaxBytes = 4 << 20

    static func parsesAsJSON(_ data: Data) -> Bool {
        guard data.count <= jsonProbeMaxBytes else { return false }
        return (try? JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed])) != nil
    }

    /// Décodage dans l'ordre du §5.3 amendé (EX2), ASSORTI d'un contrôle de
    /// plausibilité sur tous les replis (§5.3, piège §7.2 n°3) : BOM, puis
    /// l'encodage que TextEdit, Mail ou le Finder ont inscrit dans l'attribut
    /// étendu `com.apple.TextEncoding`, puis UTF-8, Windows-1252, ISO-8859-1,
    /// MacRoman.
    ///
    /// Sans ce contrôle, `decode` ne rendait JAMAIS nil (A11.4) : ISO-8859-1
    /// réussit sur les 256 valeurs d'octet possibles, `.macOSRoman` était donc
    /// inatteignable et tous les `throw`/`continue` des appelants étaient morts.
    /// Conséquence : n'importe quel binaire renommé .txt/.log/.json entrait en
    /// mojibake dans page_fts. Un décodage UTF-8 réussi reste, lui, une preuve de
    /// plausibilité suffisante — c'est un code à redondance, il ne réussit pas par
    /// hasard sur du binaire.
    ///
    /// WINDOWS-1252 AVANT ISO-8859-1. Les deux ne diffèrent que sur 0x80–0x9F :
    /// des commandes C1 invisibles en Latin-1, € — “ ” ’ œ en CP1252. Le
    /// contrôle de plausibilité ne départageait pas : une poignée de commandes
    /// C1 dans une page de texte reste loin des 30 % de suspects, et le texte
    /// entrait avec ses guillemets changés en caractères de contrôle. Un
    /// fichier Latin-1 sans octet 0x80–0x9F se décode à l'identique par les
    /// deux ; et CP1252 laisse cinq octets sans caractère (0x81, 0x8D, 0x8F,
    /// 0x90, 0x9D), sur lesquels Foundation échoue — un bruit binaire retombe
    /// donc sur Latin-1 et son contrôle, comme avant.
    public static func decode(_ data: Data, url: URL? = nil) -> String? {
        // Le BOM passe devant l'attribut : il est DANS les octets, l'attribut
        // n'est qu'une étiquette qu'une copie ou un éditeur peut laisser fausse.
        if !data.starts(with: [0xEF, 0xBB, 0xBF]),
           !data.starts(with: [0xFF, 0xFE]), !data.starts(with: [0xFE, 0xFF]),
           let url, let declared = declaredEncoding(of: url),
           let text = decode(data, as: declared) {
            return text
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            if Plausibility.looksBinary(data) { return nil }
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16),
               Plausibility.isPlausible(text) {
                return text
            }
            return nil
        }
        if Plausibility.looksBinary(data) { return nil }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        for fallback: String.Encoding in [.windowsCP1252, .isoLatin1, .macOSRoman] {
            if let text = String(data: data, encoding: fallback),
               Plausibility.isPlausible(text) { return text }
        }
        return nil
    }

    static let textEncodingAttribute = "com.apple.TextEncoding"

    /// L'encodage inscrit dans `com.apple.TextEncoding`, ou nil. La valeur a la
    /// forme `utf-8;134217984`, `macintosh;0` : seul le nom IANA avant le `;`
    /// compte — le nombre est un `CFStringEncoding` qu'un nom inconnu ne doit
    /// pas faire honorer par la bande.
    static func declaredEncoding(of url: URL) -> String.Encoding? {
        guard url.isFileURL else { return nil }
        // 128 octets : la valeur la plus longue qu'écrit TextEdit tient en une
        // trentaine ; un attribut plus gros n'est pas celui-là (ERANGE → nil).
        var buffer = [UInt8](repeating: 0, count: 128)
        let size = url.withUnsafeFileSystemRepresentation { path -> Int in
            guard let path else { return -1 }
            return getxattr(path, textEncodingAttribute, &buffer, buffer.count, 0, 0)
        }
        guard size > 0, size <= buffer.count,
              let value = String(bytes: buffer[0..<size], encoding: .ascii)
        else { return nil }
        let name = value.split(separator: ";", maxSplits: 1,
                               omittingEmptySubsequences: false).first ?? ""
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let cf = CFStringConvertIANACharSetNameToEncoding(trimmed as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// Décodage sous l'encodage DÉCLARÉ, tenu au même contrôle que les replis :
    /// un attribut resté faux après une conversion ne fait pas entrer de
    /// mojibake. L'octet NUL reste un refus, sauf pour les encodages larges
    /// qui en portent un sur deux.
    private static func decode(_ data: Data, as encoding: String.Encoding) -> String? {
        let wide: Set<String.Encoding> = [
            .utf16, .utf16BigEndian, .utf16LittleEndian,
            .utf32, .utf32BigEndian, .utf32LittleEndian,
        ]
        if !wide.contains(encoding), Plausibility.looksBinary(data) { return nil }
        guard let text = String(data: data, encoding: encoding),
              Plausibility.isPlausible(text) else { return nil }
        return text
    }

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw FouineError.extraction(
                "cannot read (\(url.lastPathComponent)): "
                + (error as NSError).localizedDescription)
        }
        guard let decoded = Self.decode(data, url: url) else {
            throw FouineError.extraction(
                "non-text content (\(url.lastPathComponent)): neither UTF-8, nor "
                + "Windows-1252, nor ISO-8859-1, nor plausible macOSRoman — binary file?")
        }
        let ext = url.pathExtension.lowercased()
        // Sources minifiées : refusées NOMMÉMENT (lot INT-F1), et seulement
        // pour les extensions techniques (voir `sourceExtensions`).
        if Self.sourceExtensions.contains(ext),
           Self.isMinified(name: url.lastPathComponent, text: decoded) {
            throw FouineError.extraction(Self.minifiedReason)
        }
        // Documents : une LIGNE longue reste permise (un journal, un LaTeX sur
        // une ligne), une suite sans AUCUN blanc ne l'est pas (EX2) — sauf si
        // le fichier se parse en JSON (lot MN1), qui est une forme et non un
        // vidage. Les images embarquées (`data:image/…;base64,…`) ne comptent
        // pas dans la suite mesurée : `Plausibility.withoutDataURIs`.
        if Self.documentExtensions.contains(ext) {
            let run = Plausibility.longestRunWithoutWhitespace(in: decoded)
            if run >= Self.maxRunWithoutWhitespace, !Self.parsesAsJSON(data) {
                throw FouineError.extraction(Self.dataDumpReason(run: run))
            }
        }

        var budget = TextBudget(maxBytes: limits.maxTextBytes)
        let text = budget.take(decoded)
        // Un paquet Anki recopié : une carte par page (lot AN1).
        if MaterializedText.isMaterialized(text) {
            return Assembler.result(
                slots: MaterializedText.slots(text, limit: limits.pageSplitChars),
                meta: [:])
        }
        return Assembler.paginatedResult(text: text, limits: limits, meta: [:])
    }
}

/// Assemblage commun aux formats non paginés : découpage à pageSplitChars, une
/// PageText par page NON VIDE, `pageCount` = nombre d'emplacements (la
/// numérotation reste stable même si une page est blanche).
enum Assembler {
    static func paginatedResult(text: String, limits: ExtractLimits,
                                meta: [String: String]) -> ExtractionResult {
        let slots = TextPagination.paginate(text, limit: limits.pageSplitChars)
        return result(slots: slots, meta: meta)
    }

    static func result(slots: [String], meta: [String: String]) -> ExtractionResult {
        var pages: [PageText] = []
        for (index, slot) in slots.enumerated() where !TextPagination.isBlank(slot) {
            pages.append(PageText(page: index + 1, text: slot, source: .native))
        }
        // ocrCandidates vide : sur un format non paginé il n'y a RIEN à rendre en
        // image, donc rien à OCRiser (§6.1 — ne jamais mettre en file une page
        // qu'aucun moteur de rendu ne saura produire).
        return ExtractionResult(pages: pages, pageCount: slots.count,
                                ocrCandidates: [], meta: meta)
    }
}
