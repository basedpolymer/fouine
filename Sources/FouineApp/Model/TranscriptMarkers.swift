// TranscriptMarkers.swift — les horodatages d'une page transcrite (lot PV1).
// Propriété : A-App.
//
// CE QUI EXISTAIT DÉJÀ, ET QUE PERSONNE NE LISAIT. Une page de son ou de vidéo
// est une fenêtre de dix minutes de parole mise par écrit, coupée en
// paragraphes réguliers dont chacun s'ouvre sur son moment :
//
//     [00:00] bonjour à tous, nous reprenons le cours sur les polymères
//
//     [00:41] la réticulation, elle, se mesure autrement
//
// Ces repères sont ABSOLUS — comptés depuis le début de l'enregistrement, pas
// depuis le début de la page (`SpeechTranscriber` ajoute l'origine de la
// fenêtre à chaque segment). C'est ce qui permet de les rendre cliquables sans
// rien savoir de la page où ils se trouvent.
//
// TOUT CE FICHIER EST PUR. Ni lecteur, ni fenêtre, ni base : trois entrées
// textuelles, des nombres en sortie. C'est ce que les tests interrogent — une
// vue SwiftUI ne se teste pas, la lecture d'un repère, si.

import Foundation

enum TranscriptMarkers {

    /// Une page de média vaut une fenêtre de dix minutes.
    ///
    /// RECOPIÉ, et c'est délibéré : la valeur vit dans `MediaDecoder`
    /// (`FouineExtract`), qui est `internal` — l'application ne peut pas la
    /// lire. La rendre publique pour une seule constante d'affichage ouvrirait
    /// le décodeur audio à tout le paquet. Si elle change un jour, c'est le
    /// test `startSeconds` qui le dira le premier.
    static let windowSeconds = 600

    /// Un repère lu dans le texte d'une page.
    struct Marker: Equatable {
        /// Secondes depuis le début de l'enregistrement.
        let seconds: Int
        /// La plage du repère LUI-MÊME, crochets compris.
        let range: Range<String.Index>
    }

    /// Un paragraphe de transcription : son moment, et ce qui se dit.
    struct Block: Identifiable, Equatable {
        /// Le rang du bloc dans la page — stable, et c'est tout ce qu'il faut
        /// à `ForEach` (deux blocs peuvent porter le même moment si la
        /// reconnaissance a rendu deux segments à la même seconde).
        let id: Int
        /// `nil` pour ce qui précède le premier repère : la page de balises
        /// d'un enregistrement, qui n'en porte aucun.
        let seconds: Int?
        let text: String
    }

    // MARK: - Lecture des repères

    /// Longueur maximale de ce qu'on accepte de lire entre deux crochets.
    /// « [999:59:59] » fait neuf caractères ; au-delà ce n'est pas un repère,
    /// et chercher plus loin ferait parcourir la page entière à chaque crochet
    /// ouvrant d'un texte qui en porte beaucoup (une transcription de notes
    /// de cours en est pleine).
    private static let maxBody = 12

    /// Les repères de ce texte, dans l'ordre.
    ///
    /// CE QUI N'EN EST PAS UN, et c'est le point : `[12]` (un renvoi de note),
    /// `[1990]` (une année), `[voir plus haut]`. Un repère porte deux ou trois
    /// nombres séparés par des deux-points, et les secondes s'y écrivent
    /// toujours sur deux chiffres — c'est le format que `MediaMetadata`
    /// produit, et le seul qu'on accepte de relire.
    static func parse(_ text: String) -> [Marker] {
        var markers: [Marker] = []
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let open = text[cursor...].firstIndex(of: "[") {
            let afterOpen = text.index(after: open)
            let limit = text.index(afterOpen, offsetBy: maxBody,
                                   limitedBy: text.endIndex) ?? text.endIndex
            if let close = text[afterOpen..<limit].firstIndex(of: "]"),
               let seconds = Self.seconds(ofTimestamp: text[afterOpen..<close]) {
                markers.append(Marker(seconds: seconds,
                                      range: open..<text.index(after: close)))
                cursor = text.index(after: close)
            } else {
                cursor = afterOpen
            }
        }
        return markers
    }

    /// « 12:40 » ou « 1:02:40 » en secondes, ou `nil` si ce n'en est pas.
    static func seconds(ofTimestamp body: Substring) -> Int? {
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII)
                                 && $0.allSatisfy(\.isNumber) }) else { return nil }
        // Les secondes, et les minutes d'une forme à trois nombres, s'écrivent
        // sur DEUX chiffres et restent sous soixante : sans cette exigence,
        // « [3:1] » ou « [12:99] » passeraient pour des moments.
        guard let last = parts.last, last.count == 2, let s = Int(last), s < 60,
              let minutes = Int(parts[parts.count - 2]), minutes < 60 else { return nil }
        if parts.count == 2 {
            guard parts[0].count <= 2 else { return nil }
            return minutes * 60 + s
        }
        guard parts[0].count <= 3, parts[1].count == 2,
              let hours = Int(parts[0]) else { return nil }
        return hours * 3_600 + minutes * 60 + s
    }

    /// La page découpée en paragraphes horodatés, prête à l'affichage.
    ///
    /// Le repère lui-même SORT du texte : il devient le bouton qui porte le
    /// moment, et le laisser en tête du paragraphe le ferait lire deux fois.
    static func blocks(_ text: String) -> [Block] {
        let markers = parse(text)
        guard !markers.isEmpty else {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? [] : [Block(id: 0, seconds: nil, text: body)]
        }
        var blocks: [Block] = []
        let head = text[text.startIndex..<markers[0].range.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !head.isEmpty { blocks.append(Block(id: 0, seconds: nil, text: head)) }
        for (index, marker) in markers.enumerated() {
            let end = index + 1 < markers.count ? markers[index + 1].range.lowerBound
                                                : text.endIndex
            let body = text[marker.range.upperBound..<end]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            blocks.append(Block(id: blocks.count, seconds: marker.seconds, text: body))
        }
        return blocks
    }

    // MARK: - Où commence une page, où poser la tête de lecture

    /// Le début d'une page dans l'enregistrement.
    ///
    /// La numérotation est COMPACTE (`MediaExtractor`) : la première fenêtre
    /// transcrite est la page 1 quand l'enregistrement ne porte aucune balise,
    /// et la page 2 quand il en porte — la page 1 est alors celle des balises,
    /// qui ouvre le document et commence donc à zéro.
    static func startSeconds(page: Int, firstWindowPage: Int) -> Int {
        max(0, (page - firstWindowPage) * windowSeconds)
    }

    /// Où poser la tête de lecture à l'ouverture d'une page.
    ///
    /// LE PASSAGE, ET NON LE DÉBUT DE LA PAGE : ce qu'on vient lire est
    /// l'occurrence trouvée, qui peut être à neuf minutes du début de la
    /// fenêtre. On remonte donc au repère qui OUVRE le paragraphe où elle se
    /// trouve — pas plus loin, pour ne pas faire écouter une phrase coupée en
    /// deux.
    static func playhead(text: String, terms: [HighlightTerm],
                         pageStart: Int) -> Int {
        let markers = parse(text)
        guard let first = markers.first else { return pageStart }
        guard let hit = firstOccurrence(of: terms, in: text) else {
            return first.seconds
        }
        return markers.last { $0.range.lowerBound <= hit }?.seconds ?? first.seconds
    }

    /// Le moment qu'annonce une LIGNE DE RÉSULTAT : celui de l'extrait quand il
    /// porte un repère, le début de la page sinon.
    static func extractStart(snippet: String, pageStart: Int) -> Int {
        parse(snippet).first?.seconds ?? pageStart
    }

    /// Ce moment tombe-t-il DANS cette page ?
    ///
    /// POURQUOI CETTE QUESTION SE POSE. Une ligne de résultat ne sait pas si
    /// l'enregistrement s'ouvre sur une page de balises : quand son extrait ne
    /// porte aucun repère, le moment qu'elle annonce est une estimation, et
    /// elle peut être d'une fenêtre trop tard. La page affichée, elle, porte
    /// ses repères : si le moment demandé n'y est pas, c'est que l'estimation
    /// était fausse, et l'aperçu se replace sur le passage trouvé.
    static func covers(text: String, seconds: Int) -> Bool {
        guard let first = parse(text).first else { return false }
        return seconds >= first.seconds && seconds < first.seconds + windowSeconds
    }

    /// La première occurrence d'un terme de la requête, aux frontières de jeton.
    ///
    /// Écrit ici plutôt qu'emprunté à `TextHighlighter` : celui-ci calcule
    /// TOUTES les occurrences de tous les termes pour en faire un
    /// `AttributedString`, et le prix d'une page dense se paierait pour une
    /// seule position. La règle des frontières, elle, est partagée
    /// (`TokenBoundary`) — deux définitions du mot entier divergeraient.
    private static func firstOccurrence(of terms: [HighlightTerm],
                                        in text: String) -> String.Index? {
        var best: String.Index?
        for term in terms where term.text.count >= 2 {
            var from = text.startIndex
            while from < text.endIndex,
                  let found = text.range(of: term.text,
                                         options: [.caseInsensitive,
                                                   .diacriticInsensitive],
                                         range: from..<text.endIndex) {
                if TokenBoundary.startsToken(text, at: found.lowerBound),
                   term.kind == .prefix
                     || TokenBoundary.endsToken(text, at: found.upperBound) {
                    if best == nil || found.lowerBound < best! { best = found.lowerBound }
                    break
                }
                from = text.index(after: found.lowerBound)
            }
        }
        return best
    }

    // MARK: - Affichage

    /// « 12:40 », « 1:02:40 ». La MÊME écriture que les repères du texte
    /// (`MediaMetadata.timestamp`) : une pastille qui dirait « 760 s » ou
    /// « 0:12:40 » à côté d'un texte qui dit « [12:40] » se lirait comme deux
    /// moments différents.
    static func timestamp(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let (h, m, s) = (total / 3_600, (total % 3_600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }
}
