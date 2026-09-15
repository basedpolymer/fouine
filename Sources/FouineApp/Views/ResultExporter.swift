// ResultExporter.swift — panneau « Exporter les résultats… » (audit U4).
// Propriété : A-App.
//
// `NSSavePanel` et non un `.fileExporter` SwiftUI : il faut un accessoire —
// le choix du format ET la phrase qui dit exactement ce qui part — et
// `fileExporter` n'en accepte pas. Le panneau est le seul endroit où
// l'utilisateur peut encore renoncer en apprenant que l'export ne portera que
// sur les résultats chargés.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
enum ResultExporter {

    static func present(_ search: SearchModel) {
        guard search.canExport else { return }
        let rows = search.exportRows
        let query = search.executedText

        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        for format in ResultExport.Format.allCases {
            picker.addItem(withTitle: format.label)
        }
        picker.selectItem(at: 0)

        let panel = NSSavePanel()
        panel.title = String(localized: "Export results")
        panel.prompt = String(localized: "Export")
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ResultExport.suggestedName(query: query,
                                                                format: .csv)
        panel.allowedContentTypes = [PickerRelay.contentType(.csv)]
        // La phrase que l'audit réclame : ce qui part, et rien de plus.
        panel.message = String(localized: "Exporting: \(search.exportSummary)")

        picker.target = PickerRelay.shared
        picker.action = #selector(PickerRelay.formatChanged(_:))
        PickerRelay.shared.bind(panel: panel, query: query)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 34))
        let label = NSTextField(labelWithString: String(localized: "Format:"))
        label.frame = NSRect(x: 12, y: 7, width: 60, height: 20)
        picker.frame = NSRect(x: 74, y: 4, width: 220, height: 26)
        accessory.addSubview(label)
        accessory.addSubview(picker)
        panel.accessoryView = accessory

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let format = ResultExport.Format.allCases[picker.indexOfSelectedItem]
            do {
                let data = try ResultExport.data(rows, format: format, query: query)
                try data.write(to: url, options: .atomic)
            } catch {
                // Jamais d'échec muet : un disque plein ou un dossier en
                // lecture seule doit se lire, pas se deviner à l'absence de
                // fichier (§5.6).
                let alert = NSAlert()
                alert.messageText = String(localized: "Export failed")
                alert.informativeText = ErrorText.describe(error)
                alert.addButton(withTitle: String(localized: "OK"))
                alert.runModal()
            }
        }
    }

    /// Cible Objective-C du menu de format : `NSPopUpButton` veut un
    /// `target`/`action`, ce qu'une fermeture Swift ne peut pas être. La classe
    /// tient juste de quoi renommer le fichier proposé quand le format change.
    @MainActor
    private final class PickerRelay: NSObject {
        static let shared = PickerRelay()
        private weak var panel: NSSavePanel?
        private var query = ""

        func bind(panel: NSSavePanel, query: String) {
            self.panel = panel
            self.query = query
        }

        @objc func formatChanged(_ sender: NSPopUpButton) {
            let format = ResultExport.Format.allCases[sender.indexOfSelectedItem]
            panel?.allowedContentTypes = [Self.contentType(format)]
            panel?.nameFieldStringValue =
                ResultExport.suggestedName(query: query, format: format)
        }

        /// Le type d'un format, pour que le panneau propose la bonne
        /// extension. Markdown n'a pas de `UTType` déclaré par le système sur
        /// toutes les versions de macOS : on le construit depuis l'extension,
        /// et on retombe sur le texte brut si le système ne le connaît pas —
        /// un `.md` reste un fichier texte, jamais un enregistrement refusé.
        static func contentType(_ format: ResultExport.Format) -> UTType {
            switch format {
            case .csv:  return .commaSeparatedText
            case .json: return .json
            case .markdown:
                return UTType(filenameExtension: "md") ?? .plainText
            }
        }
    }
}
