// QuickLookPreviewView.swift — le Coup d'œil DANS la fenêtre (lot PV1).
// Propriété : A-App.
//
// DEUX COUPS D'ŒIL, ET ILS NE FONT PAS LA MÊME CHOSE. `QuickLook.swift` pilote
// `QLPreviewPanel` : le panneau flottant qu'Espace ouvre par-dessus tout, celui
// du Finder. Il reste tel quel. Ici, c'est `QLPreviewView` : la même mécanique
// de rendu, mais posée DANS le panneau d'aperçu, à côté du texte de la page et
// des boutons de citation — on lit le document sans quitter la liste des
// résultats.
//
// CE QU'IL FAUT LUI DIRE, ET POURQUOI :
//   · `autostarts` : sans lui, la vue reste vide jusqu'à ce qu'on lui demande
//     de commencer — il n'y a personne pour le faire dans une vue SwiftUI ;
//   · `shouldCloseWithWindow = false` : la vue vit et meurt avec le panneau
//     d'aperçu, qui n'est pas une fenêtre à lui ; laisser AppKit la refermer
//     avec la fenêtre la fermerait aussi quand on passe d'un onglet à l'autre ;
//   · `close()` au démontage : un aperçu qui n'est plus à l'écran tient sinon
//     son processus de rendu et le fichier ouvert.

import SwiftUI
import QuickLookUI

struct QuickLookPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        // L'initialiseur à style est faillible (il rend `nil` si le style est
        // refusé) : le repli reste écrit plutôt que forcé — un `!` dans un
        // chemin d'aperçu ne se justifie pas.
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // Ne réassigner QUE sur un changement de fichier : reposer le même
        // élément relance tout le rendu, et `body` est réévalué pour un simple
        // survol de bouton.
        guard (view.previewItem as? NSURL) as URL? != url else { return }
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
