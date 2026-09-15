// ResultExport.swift — « Exporter les résultats… » en CSV, JSON et Markdown (audit U4, PR-19).
// Propriété : A-App.
//
// Ce qui est exporté : LE JEU CHARGÉ, c'est-à-dire ce que la fenêtre montre,
// filtres d'affichage compris — jamais un total que l'utilisateur n'a pas vu.
// Le panneau d'enregistrement le dit noir sur blanc : un export silencieusement
// tronqué à 200 lignes sur 5 000 est pire qu'une absence d'export.
//
// Trois formats, et pas un de plus :
//   · CSV pour un tableur — RFC 4180 (guillemets doublés, CRLF), avec un BOM
//     UTF-8 parce qu'Excel sur macOS lit sinon les accents en latin-1 ;
//   · JSON pour un script — mêmes champs, `JSONSerialization` avec clés triées
//     pour que deux exports du même jeu soient identiques octet pour octet ;
//   · Markdown pour un CARNET (PR-19). Le public de Fouine ne dépouille pas ses
//     recherches dans un tableur : il les recopie dans ses notes, dans Word ou
//     dans Zotero. Une liste à puces, une ligne par page, la référence
//     cliquable et l'extrait — rien d'autre : ni tableau (illisible dès qu'un
//     nom de fichier est long), ni en-tête YAML, que la moitié des carnets
//     affichent tel quel.
//
// Aucune dépendance nouvelle : ni CSV, ni Codable maison.

import Foundation
import FouineCore

enum ResultExport {

    enum Format: String, CaseIterable, Identifiable {
        case csv, json, markdown
        var id: String { rawValue }
        /// `markdown` s'écrit `.md` : c'est l'extension que reconnaissent les
        /// carnets (Obsidian, Bear, Notion, Typora) et l'aperçu de macOS.
        var fileExtension: String { self == .markdown ? "md" : rawValue }
        /// Libellé du menu de format du panneau d'enregistrement.
        var label: String {
            switch self {
            case .csv:      return String(localized: "CSV (spreadsheet)")
            case .json:     return String(localized: "JSON (script)")
            case .markdown: return String(localized: "Markdown (notes)")
            }
        }
    }

    /// Une ligne d'export : une PAGE trouvée, comme une ligne de résultat.
    struct Row {
        let path: String
        let page: Int
        let score: Double
        let snippet: String
        /// Étiquette de racine = `docs.top_folder`, la même que la facette
        /// « Dossiers » et que `dossier:` dans la requête.
        let rootLabel: String
        /// Date de modification du DOCUMENT (ISO 8601, fuseau local) : c'est
        /// celle que l'index tient ; il n'y a pas de date par page.
        let modified: Date?
        /// Le lien `fouine://` qui rouvre Fouine sur CETTE page (lot INT-L1).
        /// Un export sert à citer : sans lui, la ligne dit où regarder mais
        /// n'y ramène pas.
        let link: String
    }

    /// En-têtes CSV, en ANGLAIS et STABLES — délibérément hors du catalogue.
    ///
    /// Un export est de la DONNÉE, pas de l'interface : un script, une macro de
    /// tableur ou un carnet Python qui lit la colonne « chemin » cesserait de
    /// fonctionner du jour où l'utilisateur passe son système en anglais, et le
    /// même fichier ne se relirait pas d'une machine à l'autre. Les clés du JSON
    /// (`path`, `page`, `score`, `snippet`, `root`, `modified`) sont un contrat
    /// public depuis U4 : le CSV s'aligne dessus, colonne pour colonne.
    /// `link` est arrivé EN DERNIER (lot INT-L1), et c'est la seule place
    /// possible : une colonne insérée au milieu décalerait toutes celles qui
    /// suivent, et un script qui lit la sixième cesserait de fonctionner sans
    /// un mot. Le contrat s'étend, il ne casse pas.
    static let columns = ["path", "page", "score", "snippet", "root", "modified",
                          "link"]

    /// Construit les lignes dans l'ORDRE AFFICHÉ (groupes triés, pages dans
    /// leur ordre de groupe) : un export qui ne ressemble pas à l'écran oblige
    /// à re-trier ailleurs.
    static func rows(groups: [DocGroup], docRows: [Int64: DocRow]) -> [Row] {
        groups.flatMap { group in
            group.hits.map { hit in
                let record = docRows[hit.docID]?.record
                // Le chemin ABSOLU passe par le volume : `hit.path` lui est
                // relatif. Volume débranché, on n'a que la forme `doc` — et
                // c'est `DeepLink.link` qui tranche, à un seul endroit.
                let absolute = record.flatMap { r -> String? in
                    try? VolumeResolver.absolutePath(volUUID: r.volUUID,
                                                     relPath: r.relPath).path
                }
                return Row(path: hit.path, page: hit.page, score: hit.score,
                           snippet: plainSnippet(hit.snippet),
                           rootLabel: record?.topFolder ?? "",
                           modified: record.map {
                               Date(timeIntervalSince1970: $0.mtime)
                           },
                           link: DeepLink.link(absolutePath: absolute,
                                               docID: hit.docID,
                                               page: hit.page).absoluteString)
            }
        }
    }

    /// L'extrait débarrassé des marqueurs « » du `snippet()` FTS5 et replié sur
    /// une ligne : un tableur n'a que faire de nos guillemets de surlignage, et
    /// un retour à la ligne dans une cellule CSV se lit mal partout.
    ///
    /// Par `SnippetParser`, pas par deux `replacingOccurrences` (A2-16) : « et »
    /// sont aussi la ponctuation courante du français, et `Il dit « bonjour »`
    /// ressortait `Il dit  bonjour `. Sur un corpus francophone, c'était
    /// systématique — et à l'export, contrairement à l'affichage, rien ne
    /// remplace les guillemets retirés.
    static func plainSnippet(_ snippet: String) -> String {
        SnippetParser.segments(snippet).map(\.text).joined()
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func data(_ rows: [Row], format: Format,
                     query: String) throws -> Data {
        switch format {
        case .csv:      return csv(rows)
        case .json:     return try json(rows, query: query)
        case .markdown: return markdown(rows, query: query)
        }
    }

    // MARK: - CSV (RFC 4180)

    private static func csv(_ rows: [Row]) -> Data {
        var out = columns.joined(separator: ",") + "\r\n"
        for row in rows {
            out += [
                field(row.path),
                String(row.page),
                // Point décimal, pas virgule : la virgule est le séparateur, et
                // un tableur en français relit très bien un point.
                String(format: "%.6f", row.score),
                field(row.snippet),
                field(row.rootLabel),
                field(row.modified.map(iso.string(from:)) ?? ""),
                field(row.link),
            ].joined(separator: ",") + "\r\n"
        }
        // BOM UTF-8 : sans lui, Excel pour Mac ouvre le fichier en latin-1 et
        // « polymère » devient « polymÃ¨re ».
        return Data([0xEF, 0xBB, 0xBF]) + Data(out.utf8)
    }

    /// Guillemets systématiques sur les champs textuels : le chemin d'un
    /// document peut contenir une virgule, un guillemet ou un accent, et
    /// deviner au cas par cas est la source d'erreur classique du CSV.
    private static func field(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - JSON

    private static func json(_ rows: [Row], query: String) throws -> Data {
        let payload: [String: Any] = [
            "query": query,
            "exported_at": iso.string(from: Date()),
            "count": rows.count,
            "results": rows.map { row -> [String: Any] in
                var item: [String: Any] = [
                    "path": row.path,
                    "page": row.page,
                    "score": row.score,
                    "snippet": row.snippet,
                    "root": row.rootLabel,
                    "link": row.link,
                ]
                if let modified = row.modified {
                    item["modified"] = iso.string(from: modified)
                }
                return item
            },
        ]
        return try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - Markdown (PR-19)

    /// Une ligne par PAGE trouvée, dans l'ordre affiché :
    ///
    ///     # Fouine — chlorure (3 résultats)
    ///
    ///     - [notes.md, page 2](fouine://open?…) — … l'extrait sur une ligne …
    ///
    /// La référence affichée est celle de « Copier la référence » à la virgule
    /// près (`Citation.label`) : un carnet et un presse-papiers qui nommeraient
    /// la même page autrement obligeraient à vérifier lequel a raison.
    ///
    /// Le TITRE suit la langue de l'application, contrairement aux en-têtes du
    /// CSV : ce fichier-là n'est pas de la donnée à relire par un script, c'est
    /// une note que son auteur va lire et éditer.
    private static func markdown(_ rows: [Row], query: String) -> Data {
        // Le compte est une clé À PART, avec sa variation de pluriel : glissé
        // dans le titre il aurait fallu l'y accorder, et `xcstringstool` refuse
        // un `%@` — la requête — dans une chaîne à pluriel.
        let count = String(localized: "\(rows.count) results")
        var out = String(localized: "# Fouine — \(query) (\(count))")
        out += "\n\n"
        for row in rows {
            let name = DocumentDisplay.name(row.path)
            let reference = Citation.label(fileName: name, page: row.page,
                                           unit: DocumentDisplay.unit(row.path))
            // Les crochets d'un nom de fichier casseraient le libellé du lien.
            let safe = reference
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            out += "- [\(safe)](\(Citation.linkOnly(row.link)))"
            let extrait = truncated(row.snippet)
            if !extrait.isEmpty { out += " — " + extrait }
            out += "\n"
        }
        return Data(out.utf8)
    }

    /// L'extrait d'une ligne de carnet : 200 caractères au plus, coupés par une
    /// ellipse. Au-delà, la liste à puces devient un mur de texte où l'on ne
    /// distingue plus les références les unes des autres.
    static let snippetLimit = 200

    private static func truncated(_ snippet: String) -> String {
        guard snippet.count > snippetLimit else { return snippet }
        return String(snippet.prefix(snippetLimit)) + "…"
    }

    /// ISO 8601 avec le fuseau local : la même convention que la facette
    /// « Année », qui dérive `docs.mtime` en heure locale.
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f
    }()

    /// Nom proposé dans le panneau d'enregistrement : la requête, réduite à ce
    /// qu'un système de fichiers accepte.
    ///
    /// Le repli — quand la requête ne laisse aucun caractère alphanumérique —
    /// suit la langue de l'application : il était écrit « resultats » en dur, et
    /// un anglophone se voyait proposer `fouine-resultats.csv` (audit B1-29 b).
    /// La valeur `fr` du catalogue est SANS accent, à dessein : c'est un nom de
    /// fichier, qui voyage vers des systèmes et des scripts qui n'aiment pas
    /// les accents.
    static func suggestedName(query: String, format: Format) -> String {
        let base = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(6)
            .joined(separator: "-")
        let fallback = String(localized: "results")
        return "fouine-\(base.isEmpty ? fallback : base).\(format.fileExtension)"
    }
}
