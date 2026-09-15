// AppCopiesLookup.swift — la seule ligne de ce dépôt qui interroge
// LaunchServices (lot J2). Propriété : A-Core.
//
// Le JUGEMENT est dans `FouineCore.AppCopiesProbe`, sans AppKit ni base de
// services : c'est lui qui est testé. Ici il n'y a que l'appel système, qu'on
// ne peut pas simuler, et qu'on garde donc réduit à deux lignes.
//
// AppKit est déjà lié par le binaire `fouine` (FouineExtract l'importe pour
// le RTF) : cet import n'ajoute aucune dépendance. `NSWorkspace.shared`
// fonctionne dans un outil en ligne de commande — il n'exige ni NSApplication
// ni serveur de fenêtres.

import AppKit
import Foundation
import FouineCore

enum AppCopiesLookup {

    /// Ce que macOS sait des copies de Fouine.app, jugé par `AppCopiesProbe`.
    ///
    /// Deux sources, et la seconde n'est pas un luxe : LaunchServices ne répond
    /// que pour l'identifiant COURANT, donc une Fouine.app d'un ancien
    /// identifiant posée dans /Applications lui est invisible (A2-03). On va
    /// donc aussi lire l'`Info.plist` de l'emplacement canonique.
    static func report(identifier: String = FouinePaths.appBundleIdentifier) -> AppCopiesReport {
        let workspace = NSWorkspace.shared
        let copies = workspace.urlsForApplications(withBundleIdentifier: identifier)
        let defaultCopy = workspace.urlForApplication(withBundleIdentifier: identifier)
        return AppCopiesProbe.evaluate(copies: copies, defaultCopy: defaultCopy,
                                       canonical: AppCopiesProbe.stampAtCanonicalPath())
    }
}
