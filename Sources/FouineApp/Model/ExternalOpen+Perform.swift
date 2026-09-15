// ExternalOpen+Perform.swift — l'exécution du plan d'`ExternalOpen` (lot OP1,
// partagé après fusion). Propriété : A-App.
//
// `ExternalOpen.swift` décide sans toucher ni le disque ni LaunchServices ;
// ici vit tout ce qui les touche, en un seul endroit pour les DEUX gestes qui
// ouvrent un document hors de Fouine : le bouton de l'aperçu
// (`PreviewModel.openExternally`) et le clic droit « Ouvrir » de la liste des
// résultats (`ResultsView.openSelection`), qui, avant ce partage, ouvrait le
// fichier sans la page qu'il tenait pourtant.

import AppKit
import Foundation

extension ExternalOpen {

    /// Ouvre `fileURL` dans son application par défaut, à `page` quand cette
    /// application sait y aller. Tout échec rouvre le fichier comme avant,
    /// sans un mot ; le document ne s'ouvre jamais deux fois.
    @MainActor
    static func perform(fileURL: URL, page: Int?) {
        let handler = NSWorkspace.shared.urlForApplication(toOpen: fileURL)
        let plan = ExternalOpen.plan(
            fileURL: fileURL, page: page,
            handlerBundleID: handler.flatMap { Bundle(url: $0)?.bundleIdentifier })
        switch plan {
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .arguments(let arguments, let file):
            launch(reader: handler, arguments: arguments, fallback: file)
        }
    }

    /// Lance le lecteur avec l'URL et son `#page=`.
    ///
    /// REPLI IMMÉDIAT : tout ce qui rate ici rouvre le fichier comme avant,
    /// sans un mot. Les deux voies s'excluent — le document ne s'ouvre jamais
    /// deux fois.
    private static func launch(reader: URL?, arguments: [String], fallback: URL) {
        guard let reader, let bundle = Bundle(url: reader),
              let executable = bundle.executableURL else {
            NSWorkspace.shared.open(fallback); return
        }
        // LECTEUR DÉJÀ LANCÉ. LaunchServices ne transmet pas de ligne de
        // commande à une instance en cours — `OpenConfiguration.arguments`
        // n'agit qu'au démarrage, mesuré le 13/09 : la fenêtre revenait devant
        // sur sa page 1. On appelle donc l'exécutable, qui passe la main à
        // l'instance en cours et rend la main aussitôt.
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundle.bundleIdentifier ?? "")
        if !running.isEmpty {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            do { try process.run() } catch { NSWorkspace.shared.open(fallback) }
            return
        }
        // LECTEUR ÉTEINT : par LaunchServices, qui transmet la ligne de
        // commande au démarrage. Le lancer nous-mêmes en ferait un processus
        // FILS de Fouine, et macOS attribuerait alors à Fouine les demandes
        // d'accès aux dossiers que le navigateur poserait à son premier
        // lancement.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.arguments = arguments
        NSWorkspace.shared.openApplication(at: reader, configuration: configuration) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { NSWorkspace.shared.open(fallback) }
        }
    }
}
