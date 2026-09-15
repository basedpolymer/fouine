// MenuBarModel.swift — le pied du panneau de la barre des menus (UX-07, IX2,
// AP1). Propriété : A-App. SPEC §5.6, amendements UX-07, INT-M1, IX2 et AP1.
//
// CE QUE CE PIED ÉTAIT, ET CE QU'IL EST. Jusqu'au 12/09/2026, le menu de la
// barre des menus était le DOUBLE de la carte « Index » : l'état, la
// progression, les gestes, l'interrupteur. IX2 a tout retiré — on ouvre ce
// panneau pour chercher. Le 13/09/2026, le propriétaire a constaté que l'icône
// ne montrait plus rien de l'indexation et a demandé de la faire à nouveau
// changer d'état ; une icône qui change sans que le panneau l'explique est
// exactement ce qu'IX2 reprochait au triangle orange. D'où UNE ligne, et une
// seule : la phrase d'état, grisée, sans geste. Ni détail, ni progression, ni
// bouton, ni interrupteur — tout cela vit dans la carte « Index » et dans la
// fenêtre « Votre index ».
//
// La phrase vient d'`IndexStatusText`, comme celle de la carte : le panneau ne
// réécrit rien. Les textes qui n'appartiennent qu'à lui sont dans
// `App/MenuBarText.swift`.

import Foundation

/// Une ligne du pied du panneau.
enum MenuBarItem: Equatable {
    /// La phrase d'état de l'index (« À jour », « Lecture des pages
    /// scannées… », « Un dossier n'est plus accessible »). Grisée, sans geste :
    /// elle est là pour EXPLIQUER l'icône, pas pour faire agir (AP1).
    case status(String)
    /// « Ouvrir Fouine » (⌘0) : ramène la fenêtre, et l'icône du Dock avec elle.
    case openWindow
    /// « Quitter Fouine » (⌘Q).
    case quit

    /// Un identifiant stable, pour les tests et pour `ForEach`.
    var identifier: String {
        switch self {
        case .status:     return "status"
        case .openWindow: return "openWindow"
        case .quit:       return "quit"
        }
    }
}

enum MenuBarModel {

    /// Le pied, dans l'ordre où il s'affiche : ce qu'il se passe, puis les deux
    /// gestes. L'état d'abord parce qu'il répond à la question qu'on se pose en
    /// voyant l'icône changer, et qu'on ne clique pas dessus.
    static func items(status: IndexStatus) -> [MenuBarItem] {
        [.status(IndexStatusText.headline(status)), .openWindow, .quit]
    }

    /// Le pictogramme de l'icône, par famille d'état (AP1, rendu après IX2).
    /// Trois symboles : la loupe au repos, la flèche circulaire quand l'index
    /// travaille, le triangle quand il attend un geste.
    static func symbolName(for glyph: IndexStatus.Glyph) -> String {
        switch glyph {
        case .quiet:     return "text.magnifyingglass"
        case .working:   return "arrow.triangle.2.circlepath"
        case .attention: return "exclamationmark.triangle"
        }
    }

    /// L'aide de « Quitter Fouine », ou `nil`.
    ///
    /// Elle dit que l'index continue de se mettre à jour après la fermeture :
    /// c'est VRAI seulement quand la mise à jour automatique est allumée.
    /// Éteinte, plus rien ne tourne une fois Fouine quittée, et la phrase
    /// mentirait.
    static func quitHelp(automatic: Bool) -> String? {
        automatic ? MenuBarText.quitHelp : nil
    }
}
