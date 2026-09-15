// EmptyStateAdvice.swift — ce qu'on propose quand rien n'est trouvé (AP-07).
// Propriété : A-App. SPEC §5.6.
//
// « Aucun résultat pour “…” » était une phrase SEULE : pas d'orthographe à
// vérifier, pas « essayez moins de mots », pas le geste qui, neuf fois sur dix,
// ramène quelque chose — tolérer les fautes de frappe, chercher aussi par le
// sens, retirer les filtres. L'application sait conseiller partout ailleurs
// (« ce mot est très courant — ajoutez un second mot », les refus de
// `RootPolicy`) ; c'est ici qu'il manquait.
//
// LES GESTES DÉPENDENT DE L'ÉTAT, et c'est tout l'objet de ce type : proposer
// « tolérer les fautes de frappe » à quelqu'un qui les tolère déjà, ou
// « chercher aussi par le sens » sans modèle installé, ce serait rendre un
// écran vide bavard sans le rendre utile. La décision est PURE : quatre
// entrées, une liste en sortie, testée.
//
// LE REPLI FLOU EXISTE DEPUIS LE LOT MP1 (C2-08) : quand les fautes ne sont pas
// refusées (« jamais »), le moteur a DÉJÀ rejoué la requête en les tolérant sur
// tous les documents avant que cet écran ne s'affiche — et il le dit sous le
// champ quand cela a rendu quelque chose. Proposer « tolérer les fautes de
// frappe » ici serait alors proposer un geste déjà fait : le bouton ne paraît
// plus que dans le seul cas où il change quelque chose, celui où l'utilisateur
// a mis le réglage sur « jamais ».

import Foundation
import FouineCore

/// Un geste cliquable de l'état vide.
enum EmptyStateGesture: String, Hashable, Identifiable, CaseIterable {
    /// Passe « Fautes de frappe » à « toujours » et relance.
    case tolerateTypos
    /// Allume « Chercher aussi par le sens » et relance.
    case searchByMeaning
    /// Retire filtres, facettes et portée.
    case removeFilters

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tolerateTypos:   return String(localized: "Tolerate typos")
        case .searchByMeaning: return String(localized: "Search by meaning too")
        case .removeFilters:   return String(localized: "Remove the filters")
        }
    }

    var identifier: String { "results.empty.\(rawValue)" }
}

enum EmptyStateAdvice {

    /// Les gestes à proposer, dans l'ordre où ils s'affichent.
    ///
    /// L'ordre n'est pas indifférent : la faute de frappe est la cause la plus
    /// fréquente d'une liste vide, le filtre oublié la plus facile à défaire,
    /// et le sens la plus lente — il charge un modèle.
    static func gestures(fuzzy: FuzzyMode, semanticReady: Bool,
                         semanticOn: Bool, filtersActive: Bool)
        -> [EmptyStateGesture] {
        var out: [EmptyStateGesture] = []
        if fuzzy == .off { out.append(.tolerateTypos) }
        if filtersActive { out.append(.removeFilters) }
        if semanticReady, !semanticOn { out.append(.searchByMeaning) }
        return out
    }

    /// La phrase qui suit les gestes. Elle vaut dans tous les cas — y compris
    /// quand il n'y a aucun geste à proposer, et c'est alors la seule chose
    /// honnête qui reste à dire.
    static var sentence: String {
        String(localized: "Try fewer words, or check the spelling.")
    }
}
