// AppInstallation.swift — « puis-je armer l'indexation en arrière-plan depuis
// CETTE copie de Fouine ? » (lot J2). Propriété : A-App.
//
// `SMAppService.register()` réussit même depuis une copie de Fouine.app posée
// n'importe où ; c'est PLUS TARD que launchd échoue, à chaque tentative de
// lancement, avec un code que personne ne lit (78, EX_CONFIG). Pire, il fige
// à l'enregistrement une exigence de code : supprimer ensuite la copie fautive
// ne répare rien, il faut désenregistrer puis réenregistrer. La seule
// prévention utile est donc de REFUSER l'enregistrement tant que la copie
// n'est pas la bonne — voir `FouineCore.AppCopiesProbe` pour le détail du
// piège, constaté le 03/09/2026.
//
// La décision est PURE (`AppInstallationCheck.decide`) : elle ne connaît que
// trois URL. L'interrogation de LaunchServices est à côté, en deux lignes.

import AppKit
import Foundation
import FouineCore

/// Ce que l'app décide avant d'appeler `register()`.
enum AppInstallationDecision: Equatable, Sendable {
    /// Rien ne s'oppose à l'enregistrement.
    case canRegister
    /// La copie qui tourne n'est pas dans le dossier Applications.
    case notInApplications
    /// macOS connaît plusieurs Fouine.app.
    case severalCopies(others: [String])
    /// Une seule copie, mais ce n'est pas celle qui tourne : macOS en ouvrirait
    /// une autre, et c'est elle que launchd irait chercher.
    case notTheDefaultCopy(defaultPath: String)

    var allowsRegistration: Bool { self == .canRegister }
}

enum AppInstallationCheck {

    /// Le dossier où Fouine doit être installée.
    static let applicationsDirectory = "/Applications"

    /// LA décision. Fonction PURE : aucun accès disque, aucun appel système.
    ///
    /// - Parameters:
    ///   - bundleURL: `Bundle.main.bundleURL` de la copie qui tourne.
    ///   - copies: les copies connues de LaunchServices.
    ///   - defaultCopy: celle que macOS ouvrirait pour cet identifiant.
    static func decide(
        bundleURL: URL,
        copies: [URL],
        defaultCopy: URL?,
        applicationsDirectory: String = applicationsDirectory
    ) -> AppInstallationDecision {
        let mine = AppCopiesProbe.normalize(bundleURL)

        // 1. Hors du dossier Applications : ni un build de travail, ni une copie
        //    encore dans Téléchargements ou montée depuis l'image disque ne
        //    donnent à launchd un chemin qui survivra.
        let prefix = applicationsDirectory.hasSuffix("/")
            ? applicationsDirectory : applicationsDirectory + "/"
        guard mine.hasPrefix(prefix) else { return .notInApplications }

        var seen = Set<String>()
        var paths: [String] = []
        for url in copies where seen.insert(AppCopiesProbe.normalize(url)).inserted {
            paths.append(AppCopiesProbe.normalize(url))
        }
        let defaultPath = defaultCopy.map(AppCopiesProbe.normalize)
        if let defaultPath, seen.insert(defaultPath).inserted { paths.append(defaultPath) }

        // 2. Plusieurs copies : celle de numéro de build le plus haut gagne, et
        //    ce n'est pas forcément celle-ci.
        if paths.count > 1 {
            return .severalCopies(others: paths.filter { $0 != mine }.sorted())
        }

        // 3. Une seule copie connue, mais ailleurs. Un LaunchServices qui ne
        //    connaît RIEN (liste vide, `defaultCopy` nil) n'est pas un motif de
        //    refus : l'app vient peut-être d'être copiée et n'est pas encore
        //    enregistrée. On ne bloque que sur une contradiction avérée.
        if let defaultPath, defaultPath != mine {
            return .notTheDefaultCopy(defaultPath: defaultPath)
        }

        return .canRegister
    }

    /// La décision pour la copie qui tourne, LaunchServices interrogé.
    static func current() -> AppInstallationDecision {
        let identifier = FouinePaths.appBundleIdentifier
        return decide(bundleURL: Bundle.main.bundleURL,
                      copies: NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier),
                      defaultCopy: NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier))
    }

    /// Le verdict de `AppCopiesProbe` pour la machine, tel que le bandeau de
    /// santé s'en sert pour nommer la cause d'un agent qui ne démarre pas.
    static func currentVerdict() -> AppCopiesReport.Verdict {
        let identifier = FouinePaths.appBundleIdentifier
        return AppCopiesProbe.evaluate(
            copies: NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier),
            defaultCopy: NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        ).verdict
    }
}
