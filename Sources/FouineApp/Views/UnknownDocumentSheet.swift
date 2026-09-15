// UnknownDocumentSheet.swift — « Fouine ne connaît pas ce document » (INT-L1).
// Propriété : A-App.
//
// Un lien `fouine://` cité l'an dernier peut désigner un document que Fouine
// n'a plus : le fichier a été déplacé hors des dossiers suivis, l'index a été
// reconstruit sans lui, ou le disque n'est pas branché. Ouvrir un aperçu vide
// serait muet ; ne rien faire du tout serait pire — la personne a cliqué, il
// doit se passer quelque chose.
//
// On DIT ce qui manque, avec le nom du fichier et rien d'autre : ni chemin
// complet (le §5.6 l'interdit hors demande), ni « doc_id », ni « index ». Et on
// propose le seul geste qui vaille encore : ouvrir le fichier lui-même, quand
// Fouine accepte de l'ouvrir.
//
// « QUAND FOUINE ACCEPTE » N'EST PAS « QUAND IL EXISTE » (constat BU-01). Ce
// bouton faisait `NSWorkspace.shared.open` sur le chemin porté par le lien, dès
// que quelque chose se trouvait là : `fouine://open?path=/System/Applications/
// Calculator.app` donnait un bouton bleu qui aurait lancé la Calculette, dans
// une fenêtre à l'aspect de Fouine, passée au premier plan par une page web.
// La décision — fichier ordinaire, sous un dossier suivi, non exécutable — est
// prise par `DeepLinkRouter`, qui est pur et testé ; cette vue ne fait
// qu'afficher son verdict.

import SwiftUI
import AppKit

struct UnknownDocumentSheet: View {
    @EnvironmentObject private var app: AppModel

    let path: String
    /// Vrai seulement pour un document que Fouine aurait pu indexer, sous un
    /// dossier suivi. Voir `DeepLinkRouter.canOpen`.
    let canOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // UN IDENTIFIANT PAR ÉLÉMENT (BU-16). Les cinq portaient
            // `sheet.unknownDocument` : sans conséquence pour VoiceOver, mais
            // aucun test d'interface ne pouvait viser un bouton précis.
            Text("Fouine does not know this document")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("sheet.unknownDocument.title")

            // Le nom du fichier, quand le lien en porte un. Un lien de la forme
            // « document » (volume débranché au moment de la citation) n'en
            // porte aucun : on ne fabrique pas un nom pour meubler.
            if !fileName.isEmpty {
                Text(verbatim: fileName)
                    .font(.callout)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("sheet.unknownDocument.file")
            }
            Text("It may have been moved or renamed, or it is no longer in one of the folders Fouine watches. Run an indexing pass to bring the list up to date.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("sheet.unknownDocument.body")

            // Quelque chose EST là, et Fouine ne l'ouvrira pas : le dire vaut
            // mieux que laisser croire à un fichier disparu — et bien mieux que
            // le bouton bleu d'avant (BU-01).
            if !canOpen, !fileName.isEmpty {
                Text("It is outside the folders Fouine watches, so Fouine will not open it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if canOpen {
                    Button("Open the file") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        app.sheet = nil
                    }
                    .accessibilityIdentifier("sheet.unknownDocument.open")
                }
                Button("Close") { app.sheet = nil }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("sheet.unknownDocument.close")
            }
        }
        .padding(20)
        .frame(width: 420)
        .accessibilityIdentifier("sheet.unknownDocument")
    }

    private var fileName: String {
        (path as NSString).lastPathComponent
    }
}
