// MaterializedText.swift — les fichiers qu'une source applicative fabrique, et
// comment ils se découpent en pages (lot AN1). Propriété : A-Ingest.
//
// POURQUOI ICI ET PAS DANS `FouineIndex/AppSources`. La source écrit le fichier
// (FouineIndex), l'extracteur de texte le relit (FouineExtract), et FouineIndex
// dépend de FouineExtract, pas l'inverse. Le marqueur et le saut de page sont
// donc déclarés du côté de celui qui LIT ; `SourceLinks` les reprend tels quels.
//
// LE SAUT DE PAGE. Un paquet Anki devient UN fichier, et chaque carte doit y
// être UNE page : c'est ce qui fait qu'un résultat désigne une carte, que la
// liste montre « 3 cartes sur 42 · Tout voir » au lieu de 42 documents d'une
// ligne, et que la règle de diversité (trois meilleures pages par document)
// tient les paquets à leur place face aux cours. La pagination ordinaire coupe
// à 4 000 caractères : elle mettrait quinze cartes par page.
//
// Le caractère retenu est le saut de page ASCII (U+000C), qui veut dire
// exactement cela depuis l'imprimante ligne. Il n'est honoré QUE dans un
// fichier qui s'annonce comme recopié par Fouine (première ligne
// `<!-- fouine-source: … -->`) : un `.txt` ordinaire qui en porterait — une
// RFC, un source GNU découpé par ^L — garde la pagination qu'il a aujourd'hui,
// et ses citations de page ne bougent pas.
//
// LES IMAGES D'UNE CARTE sont nommées dans le fichier, une ligne
// `<!-- fouine-image: nom.png -->` chacune, à la fin du segment de la carte.
// Elles ne sont PAS dans le texte des pages : un nom comme
// `m2su-822-courssimprocedes2627part1-p139.png` ferait entrer cinq faux mots
// dans l'index et dans l'expansion floue, à chaque carte. L'aperçu les relit
// dans le fichier, par la MÊME fonction (`pages`) que l'extracteur — c'est ce
// qui garantit que l'image montrée est celle de la carte affichée, même quand
// une carte longue occupe plusieurs pages.

import Foundation

public enum MaterializedText {

    /// Le commentaire qui nomme la source en tête d'un fichier recopié.
    public static let sourceMarker = "fouine-source:"

    /// Le commentaire qui porte le lien de réouverture (Notes, Bear).
    public static let openMarker = "fouine-open:"

    /// Le séparateur de pages d'un fichier recopié.
    public static let pageBreak = "\u{0C}"

    /// Le commentaire qui nomme une image de la carte.
    public static let imageMarker = "fouine-image:"

    /// La ligne qui nomme une image, telle que la source l'écrit.
    public static func imageLine(_ name: String) -> String {
        "<!-- \(imageMarker) \(name) -->"
    }

    /// Une page d'un fichier recopié : son texte, et les images de la carte
    /// qu'elle ouvre (vide sur les pages suivantes d'une carte longue).
    public struct Page: Equatable, Sendable {
        public let text: String
        public let images: [String]
    }

    /// Le texte vient-il d'un fichier recopié par une source applicative ?
    /// Seule la PREMIÈRE ligne compte : un document quelconque qui citerait le
    /// marqueur plus bas reste un document quelconque.
    public static func isMaterialized(_ text: String) -> Bool {
        let firstLine = text.prefix { !$0.isNewline }
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("<!--") && trimmed.contains(sourceMarker)
    }

    /// Les emplacements de page d'un fichier recopié : un par segment entre deux
    /// sauts de page, chaque segment repaginé à `limit` s'il est plus long (une
    /// carte de 9 000 caractères fait trois pages, pas une page géante que
    /// `snippet()` et `NEAR` ne sauraient plus servir).
    ///
    /// Le saut de page lui-même n'est dans aucune page : il ne s'affiche pas et
    /// n'apprend rien à l'index.
    static func slots(_ text: String, limit: Int) -> [String] {
        pages(text, limit: limit).map(\.text)
    }

    /// Les pages d'un fichier recopié, images mises à part. Page `n` = élément
    /// `n - 1`, pour l'extracteur comme pour l'aperçu.
    public static func pages(_ text: String, limit: Int) -> [Page] {
        withoutHeader(text).components(separatedBy: pageBreak).flatMap { segment -> [Page] in
            var images: [String] = []
            var body = segment
            if segment.contains(imageMarker) {
                var kept: [Substring] = []
                for line in segment.split(separator: "\n", omittingEmptySubsequences: false) {
                    if let name = imageName(inLine: line) {
                        images.append(name)
                    } else {
                        kept.append(line)
                    }
                }
                body = kept.joined(separator: "\n")
            }
            let texts = TextPagination.paginate(body, limit: limit)
            // Un segment vide garde son emplacement : la numérotation des pages
            // suivantes ne doit pas dépendre d'une carte sans texte.
            guard !texts.isEmpty else { return [Page(text: "", images: images)] }
            return texts.enumerated().map {
                Page(text: $0.element, images: $0.offset == 0 ? images : [])
            }
        }
    }

    /// Le texte sans ses lignes d'en-tête (`fouine-source:`, `fouine-open:`).
    ///
    /// ELLES NE SONT PAS DU TEXTE (lot AN2). Indexées, elles faisaient de
    /// « fouine », « source » et « anki » des mots de la PREMIÈRE page de chaque
    /// paquet — chercher « anki » rendait la carte 1 de tous les paquets — et
    /// l'extrait de cette carte s'ouvrait sur « …anki --> » (relevé à l'écran le
    /// 14/09/2026). Le fichier les garde : c'est lui que l'aperçu relit pour le
    /// lien de réouverture, et `isMaterialized` pour le saut de page.
    static func withoutHeader(_ text: String) -> String {
        var rest = Substring(text)
        var removed = false
        while !rest.isEmpty {
            let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
            guard isHeaderLine(rest[..<end]) else { break }
            rest = end < rest.endIndex ? rest[rest.index(after: end)...] : ""
            removed = true
        }
        return removed ? String(rest) : text
    }

    private static func isHeaderLine(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->")
            && (trimmed.contains(sourceMarker) || trimmed.contains(openMarker))
    }

    /// Le nom d'image d'une ligne `<!-- fouine-image: … -->`, ou `nil`.
    static func imageName(inLine line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->"),
              let marker = trimmed.range(of: imageMarker) else { return nil }
        let name = trimmed[marker.upperBound...].dropLast(3)
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

/// Le dépouillement HTML de Fouine, pour qui n'est pas un extracteur (lot AN1 :
/// les champs d'une carte Anki sont du HTML).
///
/// Une porte plutôt que `HTMLText` rendu public : ses autres fonctions
/// (entités, cibles de liens) sont des détails de l'extracteur, et les exposer
/// en ferait un contrat.
public enum HTMLPlainText {
    public static func text(from html: String) -> String {
        HTMLText.plainText(from: html)
    }
}
