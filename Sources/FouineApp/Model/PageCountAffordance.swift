// PageCountAffordance.swift — ce que dit, et ce que FAIT, le compte de pages
// d'un document dans la liste des résultats (PERSP-Q4).
// Propriété : A-App.
//
// Depuis la diversité par document (lot R1, § D-R5), au-delà de trois pages
// les autres pages d'un même document sont rétrogradées : presque toute la
// liste affiche « 3 / 300 p. ». Le compte était honnête (audit A12) mais muet
// — il ne disait ni pourquoi trois, ni comment voir les 297 autres (AUDIT-R1
// M5). Il devient donc un GESTE : un clic restreint la recherche à ce
// document, ce que l'application savait déjà faire
// (`SearchModel.scope = .document`), et toutes les pages appariées reviennent.
//
// La décision — compte seul / geste / compte sous portée — et ses libellés
// vivent ici, hors de la vue : c'est la seule partie testable, une vue SwiftUI
// ne se vérifiant qu'à l'œil.

import Foundation

/// L'état du compte de pages d'un document, et le texte qui va avec.
enum PageCountAffordance: Equatable {

    /// Le comptage différé n'a pas encore répondu (il arrive avec les
    /// facettes) : on ne peut parler que des pages reçues, et on le dit.
    case loadedOnly(loaded: Int)

    /// Tout ce que la requête a trouvé dans ce document est déjà à l'écran :
    /// un seul nombre, aucun geste à proposer.
    case complete(count: Int)

    /// Il reste des pages trouvées que la liste ne montre pas : le compte
    /// devient le geste qui les montre.
    case gesture(loaded: Int, matched: Int)

    /// La recherche est DÉJÀ restreinte à ce document : le geste n'aurait nulle
    /// part où mener — les pages manquantes s'obtiennent alors par « charger
    /// plus » —, le compte redevient un compte.
    case counts(loaded: Int, matched: Int)

    /// - Parameters:
    ///   - loaded: pages de ce document présentes dans le jeu reçu.
    ///   - matched: pages touchées par la requête dans TOUT le document,
    ///     `nil` tant que le comptage différé n'a pas répondu.
    ///   - scopedToThisDocument: la recherche est déjà bornée à ce document.
    static func decide(loaded: Int, matched: Int?,
                       scopedToThisDocument: Bool) -> PageCountAffordance {
        guard let matched else { return .loadedOnly(loaded: loaded) }
        // `matched < loaded` n'arrive pas en théorie ; s'il arrive (comptage
        // d'une génération précédente, encore affiché), le geste n'aurait rien
        // à montrer de plus : on retombe sur le compte simple.
        guard matched > loaded else { return .complete(count: loaded) }
        return scopedToThisDocument
            ? .counts(loaded: loaded, matched: matched)
            : .gesture(loaded: loaded, matched: matched)
    }

    /// Le compte est-il cliquable ? La vue en tire un bouton, ou du texte.
    var isGesture: Bool {
        if case .gesture = self { return true }
        return false
    }

    /// Ce qui s'écrit dans l'en-tête du document.
    var label: String { label(unit: .page) }

    /// Le même compte, en cartes pour un paquet Anki (lot AN2) : « 74 p. »
    /// sous un paquet parlait de fichier, pas de ce qu'on révise.
    func label(unit: PageUnit) -> String {
        if unit == .card {
            switch self {
            case .loadedOnly(let loaded):
                return String(localized: "\(loaded) card(s) loaded")
            case .complete(let count):
                return String(localized: "\(count) card(s)")
            case .counts(let loaded, let matched):
                return String(localized: "\(Format.integer(loaded)) / \(Format.integer(matched)) cards")
            case .gesture(let loaded, let matched):
                return String(localized: "\(Format.integer(loaded)) of \(Format.integer(matched)) cards · See them all")
            }
        }
        switch self {
        case .loadedOnly(let loaded):
            return String(localized: "\(Format.integer(loaded)) p. loaded")
        case .complete(let count):
            return String(localized: "\(Format.integer(count)) p.")
        case .counts(let loaded, let matched):
            return String(localized: "\(Format.integer(loaded)) / \(Format.integer(matched)) p.")
        case .gesture(let loaded, let matched):
            return String(localized: "\(Format.integer(loaded)) of \(Format.integer(matched)) pages · See them all")
        }
    }

    /// L'info-bulle. Celle du geste explique la chose en langage simple : ni
    /// « diversité », ni « rétrogradé », ni « portée » — pourquoi il n'y a que
    /// quelques pages, et que les autres sont à un clic.
    var help: String { help(unit: .page) }

    func help(unit: PageUnit) -> String {
        if unit == .card {
            switch self {
            case .loadedOnly:
                return String(localized: "Cards loaded for this deck. The count of matched cards arrives with the facets.")
            case .complete:
                return String(localized: "Cards of this deck matched by the query.")
            case .counts(let loaded, let matched):
                return String(localized: "Cards of this deck matched by the query: \(Format.integer(matched)). Loaded in the list: \(Format.integer(loaded)).")
            case .gesture:
                return String(localized: "Fouine first shows the best cards of each deck, so that a single one does not fill the whole list. Click to see every card found in this deck.")
            }
        }
        switch self {
        case .loadedOnly:
            return String(localized: "Pages loaded for this document. The count of matched pages arrives with the facets.")
        case .complete:
            return String(localized: "Pages of this document matched by the query.")
        case .counts(let loaded, let matched):
            return String(localized: "\(loaded) page(s) loaded out of \(matched) matched by the query in this document.")
        case .gesture:
            return String(localized: "Fouine first shows the best pages of each document, so that a single one does not fill the whole list. Click to see every page found in this document.")
        }
    }

    /// Ce que VoiceOver annonce. Le compte parlé est celui de l'en-tête de
    /// groupe (`AccessibilityText.groupValue`) : la même information, dite de
    /// la même façon, qu'elle soit un bouton ou non.
    ///
    /// SAUF POUR LE GESTE (BU-17). Le bouton du document annonce déjà « 9 pages
    /// chargées sur 229 pages touchées » ; le lien voisin portait la MÊME
    /// phrase, si bien qu'un groupe faisait lire deux fois le même compte sans
    /// jamais dire que le second est un geste. Le lien porte donc son nom, et
    /// le compte reste au document.
    var accessibilityLabel: String { accessibilityLabel(unit: .page) }

    func accessibilityLabel(unit: PageUnit) -> String {
        switch self {
        case .loadedOnly(let loaded):
            return AccessibilityText.groupValue(loaded: loaded, matched: nil, unit: unit)
        case .complete(let count):
            return AccessibilityText.groupValue(loaded: count, matched: count, unit: unit)
        case .counts(let loaded, let matched):
            return AccessibilityText.groupValue(loaded: loaded, matched: matched, unit: unit)
        case .gesture:
            return String(localized: "See them all")
        }
    }

    /// Où mène le geste — `nil` quand le compte n'est qu'un compte : une
    /// indication sur un texte non cliquable ferait promettre une action.
    var accessibilityHint: String? {
        isGesture ? AccessibilityText.seeAllPagesHint : nil
    }
}
