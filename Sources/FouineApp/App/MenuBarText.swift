// MenuBarText.swift — les phrases de la barre des menus (UX-07/UX-08).
// Propriété : A-App.
//
// La ligne d'état du pied vient d'`IndexStatusText`, comme la phrase de la
// carte « Index » : le panneau ne réécrit rien de ce qui est déjà dit ailleurs.
// Ne restent ici que ses propres textes — les deux gestes du pied, l'aide de
// « Quitter Fouine », ce que VoiceOver annonce de l'icône, et la
// mini-recherche.

import Foundation

enum MenuBarText {

    static var openWindow: String {
        String(localized: "Open Fouine")
    }

    static var quit: String {
        String(localized: "Quit Fouine")
    }

    /// Dit ce que « Quitter » NE casse PAS. La mise à jour automatique est
    /// portée par un service du système, pas par cette fenêtre : le taire
    /// laisserait croire qu'il faut garder Fouine ouverte. Posée SEULEMENT
    /// quand elle est vraie — mise à jour automatique allumée
    /// (`MenuBarModel.quitHelp(automatic:)`, IX2).
    static var quitHelp: String {
        String(localized: "The index keeps updating by itself after Fouine is closed.")
    }

    /// Ce que VoiceOver annonce en atteignant l'icône : l'ÉTAT, pas « icône »
    /// ni « Fouine » (AP1, rendu après IX2). L'icône change de pictogramme
    /// selon ce que fait l'index ; qui ne la voit pas doit apprendre la même
    /// chose, et c'est la phrase de la carte, mot pour mot.
    static func iconLabel(_ status: IndexStatus) -> String {
        IndexStatusText.headline(status)
    }

    // MARK: - Mini-recherche (INT-M1)

    /// Ce qui est écrit dans le champ vide. Il dit ce qu'on cherche — le
    /// CONTENU des documents —, pas « Rechercher » : c'est la question que se
    /// pose quelqu'un qui n'a jamais ouvert la fenêtre.
    static var searchPrompt: String {
        String(localized: "Search your documents")
    }

    static var searchHint: String {
        String(localized: "Type a few words. Return opens Fouine on all the results.")
    }

    /// La ligne sous la liste quand il reste des pages à voir.
    /// « Show all the results in Fouine » se coupait en « Show all the results
    /// in Foui… » dans un panneau de 360 points, et le français est plus long
    /// encore (AP-11). Quatre mots suffisent : la ligne est déjà sous une
    /// liste de résultats, elle n'a pas à redire ce qu'ils sont.
    static var showAll: String {
        String(localized: "Show all in Fouine")
    }

    static var rowHint: String {
        String(localized: "Opens this page in its own window. Hold Command down to open the file in its usual application instead.")
    }

    /// Ce que VoiceOver lit d'une ligne : le fichier, la page, puis l'extrait.
    /// Le même ordre que la liste de la fenêtre (`AccessibilityText.hitLabel`) —
    /// on ne réapprend pas une annonce en changeant de surface.
    static func rowLabel(fileName: String, page: Int, snippet: String) -> String {
        let head = String(localized: "\(fileName), page \(page)")
        return snippet.isEmpty ? head : head + ", " + snippet
    }
}
