// DjvuExtractor.swift — djvu (SPEC §5.3, §2.2).
// Propriété : A-Ingest.
//
// « ddjvu absent -> .skipped, err = "djvu: djvulibre absent". 5 fichiers.
// Détecter ddjvu/djvutxt dans le PATH et s'en servir s'il apparaît un jour :
// 6 lignes, aucune dépendance embarquée. »
//
// djvulibre 3.5.30 est installé depuis le 01/09/2026. La couche texte se lit
// PAGE PAR PAGE avec djvused, et non d'un bloc avec djvutxt : voir `tool()`.
// Aucun rendu d'image : un djvu sans couche texte n'a pas d'OCR de secours
// (décision de recette C4.3), il est signalé comme tel.

import Foundation
import FouineCore

public struct DjvuExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> = ["djvu"]

    /// Nom de l'exécutable qui prouve la présence de djvulibre.
    public static let executable = "djvused"

    /// Message écrit dans `docs.err` quand djvulibre est absent.
    ///
    /// La phrase dit la CAUSE à l'humain ; le jeton entre parenthèses la dit au
    /// crawl (lot K6, constat A3-05). Sans lui, un `.djvu` sauté avant
    /// `brew install djvulibre` restait sauté à vie : l'installation de l'outil
    /// ne change ni la taille ni le mtime du fichier, et le crawl delta ne
    /// regarde que ces deux-là. `docs.err` n'est jamais montré tel quel dans
    /// l'application (elle recompose ses phrases depuis les cas d'erreur) : le
    /// jeton ne coûte donc rien à personne.
    public static let reason =
        "djvu: djvulibre is missing (\(ExternalTool.missingToolToken(executable)))"

    public init() {}

    /// Variable d'environnement d'override, chemin COMPLET de l'exécutable
    /// djvused. Dépannage d'une installation hors des trois répertoires
    /// standard ; consultée EN DERNIER (voir `Subprocess.tool`).
    public static let overrideVariable = ExternalTool.overrideVariable(for: executable)

    /// Chemin de djvused s'il est installé, nil sinon.
    ///
    /// Cherché par CHEMINS EXPLICITES et non dans `PATH` (audit D8) : sous
    /// launchd et sous le Finder, `PATH` est minimal ou absent, et djvused y
    /// était introuvable — les 5 `.djvu` du corpus passaient `skipped` depuis
    /// l'app et l'agent alors qu'ils s'extrayaient depuis le Terminal.
    ///
    /// djvused et NON djvutxt : djvutxt omet purement et simplement les pages
    /// dépourvues de chunk `TXTz` — sans même émettre leur saut de page — et
    /// décale donc toute la numérotation qui suit. Mesuré sur le corpus :
    /// Atkins (1998) 510 pages dont 503 avec texte, djvutxt n'en rend que 503 ;
    /// Huheey (1997) 1 049 / 1 048 ; de Gennes (1979) 326 / 320. Les deux outils
    /// viennent du même paquet djvulibre : sa présence se teste indifféremment
    /// sur l'un ou l'autre.
    public static func tool() -> String? {
        Subprocess.tool(executable, overrideVariable: overrideVariable)
    }

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)
        guard let djvused = Self.tool() else {
            throw FouineError.unsupported(ext: "djvu")
        }
        let name = url.lastPathComponent
        let pageCount = try Self.pageCount(djvused: djvused, url: url, name: name)
        guard pageCount > 0 else {
            throw FouineError.extraction("djvu with no page (\(name))")
        }
        // Même refus qu'en PDF (audit S2), et pour la même raison de coût : le
        // script djvused ci-dessous fait DEUX commandes par page, il pèserait
        // plusieurs mégaoctets d'arguments pour un document qui sera refusé au
        // moment de l'écriture.
        guard pageCount <= Schema.maxPage else {
            throw FouineError.extraction(
                "document too long: \(pageCount) pages, limit \(Schema.maxPage) "
                + "per document (\(name))")
        }

        // Un `print-pure-txt` PAR PAGE : djvused rend alors un saut de page pour
        // chaque page, y compris celles sans couche texte, et la numérotation est
        // exacte. « -n » : rien n'est jamais réécrit dans le corpus (§3).
        // « -u » : sortie UTF-8, sans échappement des accents.
        let script = (1...pageCount)
            .map { "select \($0); print-pure-txt" }
            .joined(separator: "; ")
        let out = try Subprocess.capture(djvused,
                                         ["-n", "-u", url.path, "-e", script],
                                         what: name)
        let data = out.stdout
        // djvused pose un octet NUL DEVANT chaque saut de page (mesuré : 1 048 NUL
        // pour les 1 049 pages de Huheey 1997). Un NUL n'a rien à faire dans
        // page_fts, et c'est justement la signature sur laquelle `decode` refuse
        // désormais un binaire renommé (A11.4) : on le retire à la source, seul
        // endroit où l'on sait que c'est un artefact d'outil et non du binaire.
        let cleaned = data.contains(0) ? Data(data.filter { $0 != 0 }) : data
        guard let text = PlainTextExtractor.decode(cleaned) else {
            throw FouineError.extraction("djvused : encodage non reconnu (\(name))")
        }

        // UN morceau = UNE page, JAMAIS re-paginée : à pageSplitChars, une page
        // dense produirait plusieurs emplacements et décalerait la numérotation de
        // toutes les suivantes (recette C4.1). PDFExtractor, seul autre format
        // nativement paginé, n'appelle pas paginate non plus.
        var raw = text.components(separatedBy: "\u{0C}")
        if raw.last?.isEmpty == true { raw.removeLast() }  // saut final, pas une page
        var budget = TextBudget(maxBytes: limits.maxTextBytes)
        var slots: [String] = []
        for page in raw {
            // Comme en PDF (ST1). Le gros du travail est ici DERRIÈRE nous —
            // djvused rend tout le document d'un coup —, mais le recollage des
            // césures sur un millier de pages se compte encore en secondes.
            if limits.shouldStop() { throw FouineError.cancelled }
            // Césures recollées (constat C2-10) : un djvu est une numérisation
            // d'ouvrage, donc justifié comme un livre.
            slots.append(budget.take(Dehyphenation.rejoin(page)))
            if budget.isExhausted { break }
        }
        // Sans couche texte, `slots` serait entièrement blanc : le document
        // entrerait `.extracted` à zéro page, en silence, et rien ne le
        // rattraperait — il n'existe pas de rendu djvu pour l'OCR (C4.3).
        guard slots.contains(where: { !TextPagination.isBlank($0) }) else {
            // Le stderr d'un djvused SORTI 0 dit souvent pourquoi (chunk illisible,
            // page abîmée) : il était jeté jusqu'ici (A11.11).
            throw FouineError.extraction(
                "djvu: no text layer (\(name))"
                + (out.stderr.isEmpty ? "" : " — \(out.stderr)"))
        }
        // `pageCount` reste celui du document même si le budget a coupé court.
        let assembled = Assembler.result(slots: slots, meta: [:])
        return ExtractionResult(pages: assembled.pages, pageCount: pageCount,
                                ocrCandidates: [], meta: [:])
    }

    /// Nombre de pages réelles. Indispensable pour ne demander le texte que des
    /// PAGES : sur le document entier, djvused parcourt aussi les fichiers de
    /// formes partagées (`FORM:DJVI`) — 561 morceaux pour les 510 pages d'Atkins.
    static func pageCount(djvused: String, url: URL, name: String) throws -> Int {
        let out = try Subprocess.capture(djvused, ["-n", url.path, "-e", "n"],
                                         what: name)
        let line = String(decoding: out.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int(line) else {
            // djvused sait avertir sur stderr PUIS sortir 0 : sans ce report, le
            // motif de `docs.err` se réduisait à une ligne vide (A11.11).
            throw FouineError.extraction(
                "djvused: unreadable page count “\(line)” (\(name))"
                + (out.stderr.isEmpty ? "" : " — \(out.stderr)"))
        }
        return count
    }
}
