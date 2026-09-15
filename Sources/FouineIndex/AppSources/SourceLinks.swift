// SourceLinks.swift — rouvrir une note dans SON application (lot INT-F4).
// Propriété : A-Ingest. Tout ce fichier est PUR : des chaînes en entrée, une
// URL en sortie, aucun accès disque — c'est ce qui le rend testable et c'est
// pourquoi l'application n'en tient aucune copie.
//
// DEUX MÉCANIQUES, ET ELLES N'ONT RIEN À VOIR :
//
//   1. Les notes MATÉRIALISÉES par Fouine (Apple Notes, Bear) portent leur
//      lien dans un commentaire HTML en tête du fichier Markdown. L'aperçu le
//      lit et propose « Ouvrir dans Notes ». Deux commentaires HTML plutôt
//      qu'un front-matter YAML : les extracteurs de Fouine indexent le fichier
//      comme du texte brut, et un front-matter aurait été indexé pareil — sans
//      l'avantage d'être invisible dans un rendu Markdown.
//
//   2. Les EXPORTS de Notion ne portent rien du tout : Notion nomme ses
//      fichiers « Titre de la page 1a2b3c…  .md », où les 32 hexadécimaux de
//      fin sont l'identifiant de la page. On le retrouve donc dans le NOM du
//      fichier, et c'est la seule information disponible. Craft, lui, exporte
//      des noms sans identifiant : il n'y a rien à rouvrir, et c'est écrit
//      dans la documentation plutôt que deviné.

import Foundation
import FouineExtract

public enum SourceLinks {

    /// Le commentaire qui nomme la source (`notes`, `bear`, `anki`). Déclaré
    /// par l'extracteur, qui s'en sert pour paginer un paquet Anki carte par
    /// carte (`MaterializedText`).
    public static let sourceMarker = MaterializedText.sourceMarker
    /// Le commentaire qui porte le lien de réouverture.
    public static let openMarker = MaterializedText.openMarker

    /// L'en-tête des fichiers matérialisés : le nom de la source, puis le lien
    /// de réouverture quand l'application en a un (Anki n'en a pas).
    public static func header(sourceID: String, openURL: URL?) -> String {
        "<!-- \(sourceMarker) \(sourceID) -->\n"
        + (openURL.map { "<!-- \(openMarker) \($0.absoluteString) -->\n" } ?? "")
    }

    /// L'identifiant de source déclaré par un fichier matérialisé, ou `nil`.
    public static func sourceID(inMarkdown text: String) -> String? {
        value(of: sourceMarker, in: text)
    }

    /// Le lien de réouverture déclaré par un fichier matérialisé, ou `nil`.
    public static func openURL(inMarkdown text: String) -> URL? {
        guard let raw = value(of: openMarker, in: text) else { return nil }
        return URL(string: raw)
    }

    /// Le texte SANS son en-tête technique.
    ///
    /// L'aperçu montre le texte tel qu'il est en base, et deux commentaires
    /// HTML en tête d'une note ne veulent rien dire pour qui l'a écrite. On les
    /// retire à l'AFFICHAGE seulement : en base ils restent, et c'est eux qui
    /// permettent de retrouver l'application d'origine.
    public static func strippingHeader(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var removed = false
        while let first = lines.first, isMarkerLine(first) {
            lines.removeFirst()
            removed = true
        }
        guard removed else { return text }
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    private static func isMarkerLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("<!--")
            && (trimmed.contains(sourceMarker) || trimmed.contains(openMarker))
    }

    /// La valeur d'un marqueur, cherchée dans les PREMIÈRES lignes seulement :
    /// un fichier quelconque qui citerait `fouine-open:` au milieu de sa prose
    /// ne doit pas se faire passer pour une note.
    private static func value(of marker: String, in text: String) -> String? {
        for line in text.components(separatedBy: "\n").prefix(4) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->"),
                  let range = trimmed.range(of: marker) else { continue }
            let body = trimmed[range.upperBound...]
                .replacingOccurrences(of: "-->", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { return body }
        }
        return nil
    }

    // MARK: - Notion (exports)

    /// L'identifiant d'une page Notion, depuis le NOM de son fichier d'export.
    ///
    /// Notion écrit « Ma page de notes 1a2b3c4d5e6f7890abcdef1234567890.md » :
    /// 32 hexadécimaux collés au titre, séparés par une espace. Un nom qui n'a
    /// pas cette forme n'est pas un export Notion — et c'est justement ce que
    /// cette fonction doit dire, plutôt que de proposer un bouton qui ouvre une
    /// page inexistante.
    public static func notionPageID(forFileName name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        guard let last = base.split(separator: " ").last, last.count == 32,
              last.allSatisfy({ $0.isHexDigit }) else { return nil }
        // Un titre entièrement hexadécimal ET seul (« deadbeef… ») reste un
        // identifiant plausible : Notion nomme ainsi les pages sans titre.
        return String(last).lowercased()
    }

    /// Le lien qui rouvre une page Notion dans l'application.
    public static func notionURL(forFileName name: String) -> URL? {
        guard let id = notionPageID(forFileName: name) else { return nil }
        return URL(string: "notion://www.notion.so/\(id)")
    }
}
