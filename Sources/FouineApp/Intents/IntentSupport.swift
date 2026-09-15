// IntentSupport.swift — la logique des actions Raccourcis (lot INT-R1).
// Propriété : A-App. SPEC §5.6, amendement « Fouine dans Raccourcis ».
//
// POURQUOI UN TYPE PUR À CÔTÉ DES INTENTIONS. Une `AppIntent` ne se teste pas
// en XCTest : elle n'existe pour le système que par les métadonnées que
// `appintentsmetadataprocessor` extrait du bundle, et la faire tourner hors de
// Raccourcis n'apprend rien. Tout ce qui peut être faux — la requête construite
// depuis un texte tapé dans Raccourcis, l'identifiant d'un résultat, la
// troncature d'un extrait, le plafond du texte d'une page — vit donc ICI, dans
// des fonctions sans base ni système, et c'est ce fichier que les tests
// interrogent. Le corps de chaque intention n'est plus qu'un aiguillage.
//
// LE MÊME CHEMIN QUE LA CLI, DÉLIBÉRÉMENT. `QueryParser.searchPlan` est ce que
// `fouine search` appelle : guillemets, `dossier:`, `ext:`, `-terme`, flou
// `auto`. Une action Raccourcis qui construirait sa propre requête donnerait
// d'autres résultats que la ligne de commande pour la même phrase, et personne
// ne saurait laquelle croire.

import Foundation
import FouineCore

/// Ce qu'une action Raccourcis peut refuser de faire, dit à qui n'a pas ouvert
/// Fouine depuis six mois.
///
/// `CustomLocalizedStringResourceConvertible` : c'est ce que Raccourcis affiche
/// dans son bandeau rouge quand l'action échoue. Sans cette conformité, la
/// personne lit « The operation couldn’t be completed. (FouineApp.… error 0.) ».
enum FouineIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    /// Aucun index sur cette machine : Fouine n'a jamais tourné, ou sa base a
    /// été supprimée.
    case nothingIndexed
    /// Le résultat désigné n'existe plus (index refait, document retiré).
    case resultUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingIndexed:
            return "Fouine has not indexed anything yet. Open Fouine and add a folder."
        case .resultUnavailable:
            return "This result is no longer in Fouine. Search again."
        }
    }
}

/// Tout ce que les trois actions savent faire sans toucher ni à la base ni au
/// système.
enum IntentSupport {

    // MARK: - Bornes

    /// Nombre de résultats par défaut d'une recherche Raccourcis.
    ///
    /// Dix et non cinquante : le résultat d'une action est une LISTE que la
    /// personne fait défiler dans « Choisir dans la liste », ou qu'elle enchaîne
    /// dans un « Répéter chaque élément ». Cinquante pages rendraient l'une
    /// illisible et l'autre interminable.
    static let defaultLimit = 10

    /// Ce que le paramètre « Nombre de résultats » accepte. Raccourcis fait
    /// respecter ces bornes dans son interface (`IntentParameter` les porte),
    /// mais un raccourci construit par script peut passer n'importe quoi :
    /// on borne aussi ici.
    static let limitRange: ClosedRange<Int> = 1...50

    /// Longueur de l'extrait porté par un résultat.
    ///
    /// 240 et non 90 comme le panneau de la barre des menus (INT-M1) : là-bas
    /// l'extrait tient sur une ligne de 360 points, ici il part dans un courriel,
    /// une note ou un `Text` de Raccourcis, qui l'enroulent. Deux phrases
    /// entières valent mieux qu'une demi-phrase.
    static let snippetCharacters = 240

    /// Plafond du texte d'une page rendu par « Obtenir le texte d'une page ».
    ///
    /// Une page de manuel océrisée fait deux à six mille caractères ; vingt
    /// mille couvrent donc largement le cas normal, et bornent le cas pathologique
    /// (un DjVu de mille pages fusionnées en une seule, vu sur ce corpus) que
    /// Raccourcis recopierait dans une note.
    static let pageTextCharacters = 20_000

    /// Le nombre de résultats effectivement demandé au moteur.
    static func clamp(limit: Int) -> Int {
        min(max(limit, limitRange.lowerBound), limitRange.upperBound)
    }

    // MARK: - Requête

    /// La requête et l'expression des exclusions, exactement comme
    /// `fouine search` les construit (voir l'en-tête).
    ///
    /// `groupByDoc: true` : Raccourcis reçoit des PAGES, mais on ne veut pas
    /// que les dix résultats soient dix pages du même ouvrage.
    static func plan(query: String, limit: Int) throws
        -> (query: SearchQuery, negative: String?) {
        try QueryParser.searchPlan(
            query.trimmingCharacters(in: .whitespacesAndNewlines),
            limit: clamp(limit: limit), offset: 0, groupByDoc: true)
    }

    // MARK: - Identifiant d'un résultat

    /// L'identifiant stable d'un résultat : `<docID>:<page>`.
    ///
    /// Raccourcis GARDE cet identifiant entre deux exécutions — un raccourci
    /// enregistré avec « Ouvrir dans Fouine » sur un résultat précis le rejoue
    /// des semaines plus tard. Il est donc relu par `entities(for:)`, et le
    /// résultat qui n'existe plus se refuse (`resultUnavailable`) plutôt que
    /// d'ouvrir un autre document : `docs.id` est un rowid SQLite, réattribué
    /// après une réindexation complète (voir l'en-tête de `DeepLink`).
    static func entityID(docID: Int64, page: Int) -> String { "\(docID):\(page)" }

    /// L'inverse. `nil` sur tout ce qui n'est pas de nous : Raccourcis peut
    /// rejouer un identifiant écrit par une version antérieure, ou trafiqué.
    static func key(fromEntityID id: String) -> HitKey? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let docID = Int64(parts[0]), docID >= 1,
              let page = Int(parts[1]), page >= 0
        else { return nil }
        return HitKey(docID: docID, page: page)
    }

    // MARK: - Textes

    /// L'extrait FTS5 rendu lisible : marqueurs « » retirés, blancs aplatis,
    /// troncature sur une frontière de mot.
    ///
    /// Les marqueurs partent parce que rien, dans Raccourcis, ne les colore :
    /// ils arriveraient tels quels dans la note ou le courriel où l'extrait est
    /// recopié. Le découpage sur un espace évite « …la thermodynamiq », qu'on
    /// relit deux fois avant de comprendre que le document, lui, ne coupe rien.
    static func snippet(_ raw: String, limit: Int = snippetCharacters) -> String {
        let flat = SnippetParser.segments(raw)
            .map(\.text)
            .joined()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let collapsed = flat.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let cut = collapsed.prefix(limit)
        // Pas d'espace dans la tranche : une page mal océrisée produit des
        // « mots » de trois cents caractères. On coupe net plutôt que de rendre
        // une chaîne vide.
        let head = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Le texte d'une page, borné, avec la NOTE de troncature quand il l'a été.
    ///
    /// La note est passée par l'appelant, traduite : ce type ne connaît pas les
    /// catalogues, et un test qui vérifierait une phrase française échouerait
    /// sur une machine anglaise.
    ///
    /// La coupe est sur une frontière de LIGNE quand il y en a une dans le
    /// dernier dixième : couper un paragraphe au milieu d'un mot fabrique un
    /// mot qui n'existe pas, et c'est ce texte-là qui part dans une note.
    static func truncate(pageText text: String, limit: Int = pageTextCharacters,
                         note: String) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let floor = cut.index(cut.startIndex, offsetBy: (limit * 9) / 10)
        let head: Substring
        if let newline = cut.range(of: "\n", options: .backwards,
                                   range: floor..<cut.endIndex) {
            head = cut[cut.startIndex..<newline.lowerBound]
        } else if let space = cut.lastIndex(of: " ") {
            head = cut[cut.startIndex..<space]
        } else {
            head = cut
        }
        return String(head).trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n" + note
    }

    /// Le nom du fichier seul. C'est par lui que la personne reconnaît son
    /// document ; le chemin complet reste disponible dans une propriété à part,
    /// pour qui enchaîne sur une action « Fichier ».
    ///
    /// Une note ou un paquet Anki recopié par Fouine porte le nom qu'il a dans
    /// son application, pas celui du fichier (lot AN2).
    static func fileName(relPath: String) -> String {
        DocumentDisplay.name(relPath)
    }

    // MARK: - Garde

    /// Rien n'est indexé : l'action doit le DIRE, pas rendre zéro résultat.
    ///
    /// Une liste vide se lit comme « ce mot n'est pas dans mes documents », ce
    /// qui est faux et envoie chercher ailleurs. Le fichier de base absent est
    /// le seul cas que l'on sache distinguer sans l'ouvrir — les autres pannes
    /// (schéma, volume) remontent avec la phrase du cœur.
    static func checkIndex(at url: URL,
                           fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw FouineIntentError.nothingIndexed
        }
    }
}
