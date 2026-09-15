// AnkiText.swift — ce qu'on cherche dans une carte Anki (lot AN1).
// Propriété : A-Ingest. PUR : une chaîne en entrée, une chaîne en sortie.
//
// Une note Anki range ses champs dans `notes.flds`, séparés par U+001F, et
// chaque champ est du HTML écrit par l'éditeur d'Anki. Mesuré sur la collection
// du propriétaire le 14/09/2026 (3 359 notes) : 2 990 portent un texte à trous,
// 2 937 une image, 50 un son. Ce qui en sort, et pourquoi :
//
//   · `{{c1::réponse::indice}}` → « réponse ». La réponse est ce qu'on cherche ;
//     l'indice n'est qu'une aide à la révision. La séparation se fait au
//     PREMIER `::`, comme le fait Anki lui-même. Les trous imbriqués (Anki
//     23.10) se résolvent de l'intérieur vers l'extérieur.
//   · Un trou d'occlusion d'image (`image-occlusion:rect:left=…`) n'est pas du
//     texte : ce sont les coordonnées d'un rectangle. Il disparaît.
//   · `[sound:x.mp3]` disparaît : c'est un nom de fichier, pas une parole.
//   · `[latex]…[/latex]`, `[$]…[/$]` : les balises partent, la formule reste —
//     on cherche `\ce{H2O}` par ses mots.
//   · Le HTML passe par le dépouilleur de l'extracteur (`HTMLPlainText`) : les
//     `<img>` disparaissent du texte, les `<br>` et `<div>` font des lignes.
//     Leurs NOMS de fichier sont gardés à part (`imageNames`) : l'aperçu montre
//     l'image de la carte, l'index n'en voit rien.
//
// LES NOMS DE CHAMPS NE SONT PAS RECOPIÉS. « Recto », « Verso », « Texte »,
// « Extra » reviendraient sur chaque page d'un paquet : chercher « texte »
// rendrait les trois mille cartes à trous. Les ÉTIQUETTES non plus : elles
// servent à ranger dans Anki, et celles d'un paquet fabriqué par un outil
// (`lot::2026-09-14-822`, `verif::opus5`) ne sont que du bruit dans un index.

import Foundation
import FouineExtract

public enum AnkiText {

    /// Le séparateur des champs dans `notes.flds`.
    public static let fieldSeparator: Character = "\u{1F}"

    /// Le texte cherchable d'une note : ses champs non vides, dans l'ordre du
    /// type de note, séparés par une ligne vide.
    public static func noteText(fields: String) -> String {
        fields.split(separator: fieldSeparator, omittingEmptySubsequences: false)
            .map { fieldText(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Le texte d'un champ.
    public static func fieldText(_ html: String) -> String {
        var text = resolvingCloze(html)
        if text.contains("[") {
            text = replacing(soundTag, in: text, with: "")
            text = replacing(mathTag, in: text, with: " ")
        }
        return HTMLPlainText.text(from: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Les images d'une note, dans l'ordre des champs, sans doublon : la valeur
    /// `src` de chaque `<img>`, entités décodées. Seuls les noms d'un dossier
    /// de médias d'Anki sont gardés — ni chemin, ni adresse (`http:`,
    /// `data:`), ni nom caché : c'est un nom que l'aperçu cherchera dans
    /// `collection.media`, et rien d'autre.
    public static func imageNames(fields: String) -> [String] {
        guard fields.range(of: "<img", options: .caseInsensitive) != nil,
              let imageSource else { return [] }
        var seen: Set<String> = []
        var out: [String] = []
        let range = NSRange(fields.startIndex..., in: fields)
        for match in imageSource.matches(in: fields, range: range) {
            let raw = (1...3).lazy
                .compactMap { Range(match.range(at: $0), in: fields) }
                .map { String(fields[$0]) }
                .first ?? ""
            let name = HTMLPlainText.text(from: raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard isMediaName(name), seen.insert(name).inserted else { continue }
            out.append(name)
        }
        return out
    }

    /// Un nom de fichier du dossier de médias d'Anki, et rien de plus.
    public static func isMediaName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/")
            && !name.contains(":") && !name.contains("-->")
            && !name.contains(where: { $0.isNewline || $0 == "\0" })
    }

    /// Les trous remplacés par leur réponse.
    static func resolvingCloze(_ text: String) -> String {
        guard text.contains("{{c"), let innermostCloze else { return text }
        var current = text
        // Chaque tour retire au moins un trou : le nombre d'ouvertures borne la
        // boucle, et un texte malformé (`{{c1::` sans fin) sort au premier tour.
        for _ in 0...current.utf16.count {
            let range = NSRange(current.startIndex..., in: current)
            let matches = innermostCloze.matches(in: current, range: range)
            guard !matches.isEmpty else { break }
            let mutable = NSMutableString(string: current)
            for match in matches.reversed() {
                let content = mutable.substring(with: match.range(at: 1))
                mutable.replaceCharacters(in: match.range,
                                          with: clozeAnswer(content))
            }
            current = mutable as String
        }
        return current
    }

    /// La réponse d'un trou : avant le premier `::`, et rien pour un rectangle
    /// d'occlusion d'image.
    static func clozeAnswer(_ content: String) -> String {
        let answer = content.range(of: "::").map { String(content[..<$0.lowerBound]) }
            ?? content
        return answer.hasPrefix("image-occlusion:") ? "" : answer
    }

    // `try?` et non `try!` : ce code tourne dans la passe d'indexation de
    // l'agent, où un piège tue le processus sans un mot. Les motifs sont
    // constants et le test les exerce ; un `nil` laisserait le texte intact.

    /// Un trou qui ne contient AUCUN autre trou : le plus intérieur.
    private static let innermostCloze = try? NSRegularExpression(
        pattern: #"\{\{c\d+::((?:(?!\{\{c\d+::).)*?)\}\}"#,
        options: [.dotMatchesLineSeparators])

    private static let imageSource = try? NSRegularExpression(
        pattern: #"<img\b[^>]*?\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
        options: [.caseInsensitive])

    private static let soundTag = try? NSRegularExpression(
        pattern: #"\[sound:[^\]]*\]"#)

    private static let mathTag = try? NSRegularExpression(
        pattern: #"\[/?(?:latex|\$\$|\$)\]"#, options: [.caseInsensitive])

    private static func replacing(_ expression: NSRegularExpression?,
                                  in text: String, with template: String) -> String {
        guard let expression else { return text }
        return expression.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: template)
    }
}
