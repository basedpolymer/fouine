// AppCopiesProbe.swift — combien de Fouine.app macOS connaît-il, et laquelle
// ouvre-t-il ? (lot J2). Propriété : A-Core.
//
// POURQUOI CE FICHIER EXISTE. `SMAppService.register()` fige, au moment de
// l'enregistrement, DEUX choses dans le Background Task Management : le chemin
// du bundle enregistreur (le plist de l'agent emploie `BundleProgram`, un
// chemin RELATIF au bundle) et une exigence de code (LWCR) tirée de sa
// signature. Si une autre copie de Fouine.app traîne sur le disque avec un
// `CFBundleVersion` PLUS HAUT — c'est exactement ce que `make ci-bundle`
// laissait à la racine du dépôt, signée ad hoc, numéro de build = nombre de
// commits —, LaunchServices la préfère comme copie « par défaut » du bundle
// identifier, et l'agent armé depuis /Applications part en :
//
//     job state = spawn failed
//     last exit code = 78: EX_CONFIG
//     properties = … resolve program | has LWCR
//
// avec un réessai toutes les 60 s. Constaté le 03/09/2026 sur la machine du
// propriétaire (21 tentatives). Supprimer la copie parasite puis `lsregister
// -f /Applications/Fouine.app` NE SUFFIT PAS : l'exigence de code est figée
// dans BTM. Seul un désenregistrement suivi d'un réenregistrement depuis
// l'app répare — d'où le geste que porte `guidance`.
//
// Ce fichier ne lie NI AppKit NI LaunchServices : il ne fait que juger une
// liste d'URL. L'interrogation de LaunchServices vit chez l'appelant (la CLI
// dans `CommandsStatus.swift`, l'app dans `AppInstallation.swift`), ce qui
// rend le verdict testable sans base de données de services.

import Foundation

/// Ce que macOS sait des copies de Fouine.app installées.
public struct AppCopiesReport: Equatable, Sendable {

    /// Le verdict, sous forme de DONNÉES : la phrase se refait chez l'appelant
    /// (anglais pour la CLI, langue de l'utilisateur pour l'app).
    public enum Verdict: Equatable, Sendable {
        /// Une seule copie, à l'emplacement attendu, et c'est celle que macOS ouvre.
        case ok
        /// LaunchServices n'en connaît aucune : Fouine n'est pas installée
        /// (cas normal quand seule la CLI est bâtie depuis le dépôt).
        case notInstalled
        /// Plusieurs copies connues. `extras` liste celles qui ne sont pas
        /// l'emplacement attendu.
        case multipleCopies(extras: [String])
        /// Une seule copie, mais ailleurs que là où elle doit être.
        case outsideApplications(path: String)
    }

    /// Toutes les copies connues de macOS, chemins normalisés, dans l'ordre rendu.
    public let copies: [String]
    /// Celle que macOS ouvrirait ; `nil` si LaunchServices n'en désigne aucune.
    public let defaultCopy: String?
    public let verdict: Verdict
    /// Phrase anglaise pour `fouine doctor` (la CLI parle anglais).
    public let displayText: String
    /// Le geste à faire, en anglais ; `nil` quand il n'y a rien à faire.
    public let guidance: String?
    /// Ce qui est POSÉ à l'emplacement canonique, lu sur le disque — quel que
    /// soit son identifiant. `nil` = rien là-bas (A2-03).
    public let atExpectedPath: AppBundleStamp?
    public var isHealthy: Bool { verdict == .ok || verdict == .notInstalled }
}

/// Ce qu'un bundle posé à l'emplacement canonique dit de lui-même.
///
/// Lu dans son `Info.plist`, PAS dans LaunchServices : c'est tout l'intérêt.
/// Une copie que LaunchServices ne rend pas — parce qu'elle porte un autre
/// identifiant de bundle — n'existe pour lui d'aucune façon ; la seule manière
/// de la voir est d'aller regarder à l'endroit où elle doit être.
public struct AppBundleStamp: Equatable, Sendable {
    public let path: String
    public let identifier: String?
    public let version: String?

    public init(path: String, identifier: String?, version: String?) {
        self.path = path
        self.identifier = identifier
        self.version = version
    }
}

public enum AppCopiesProbe {

    /// Le dossier où Fouine doit être installée, et le nom de son bundle.
    public static let applicationsDirectory = "/Applications"
    public static let bundleName = "Fouine.app"

    /// Là où Fouine doit vivre, et le seul endroit d'où l'agent s'arme.
    public static let expectedPath = "/Applications/Fouine.app"

    /// Le geste : supprimer les autres copies NE SUFFIT PAS, il faut ensuite
    /// refaire l'enregistrement (l'exigence de code est figée dans BTM).
    public static let multipleCopiesGuidance =
        "delete the other copies of Fouine.app (keep only \(expectedPath)), then turn "
        + "“Keep the index up to date automatically” off and on again in Fouine.app — "
        + "deleting the copies alone does not repair an agent already registered against them"

    public static let outsideApplicationsGuidance =
        "move Fouine.app to /Applications, then turn “Keep the index up to date "
        + "automatically” off and on again in Fouine.app"

    /// Ce qui est POSÉ à l'emplacement canonique, lu dans son `Info.plist`.
    ///
    /// `nil` quand il n'y a rien, ou rien de lisible. Le chemin est paramétré
    /// pour les tests, qui posent un faux bundle dans un dossier temporaire.
    public static func stampAtCanonicalPath(
        applicationsDirectory: String = applicationsDirectory,
        fileManager: FileManager = .default
    ) -> AppBundleStamp? {
        let bundle = (applicationsDirectory as NSString)
            .appendingPathComponent(bundleName)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundle, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let plist = (bundle as NSString)
            .appendingPathComponent("Contents/Info.plist")
        guard let data = fileManager.contents(atPath: plist),
              let object = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil),
              let dict = object as? [String: Any] else {
            // Un bundle illisible n'est pas un bundle étranger : on ne juge que
            // ce qu'on a lu (le verdict retombe sur les copies de LaunchServices).
            return nil
        }
        return AppBundleStamp(
            path: bundle,
            identifier: dict["CFBundleIdentifier"] as? String,
            version: dict["CFBundleVersion"] as? String)
    }

    /// Normalise un chemin de bundle : LaunchServices rend des URL de
    /// répertoire, donc avec une barre oblique finale.
    public static func normalize(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// LE verdict. Fonction PURE : aucune interrogation du système, aucun
    /// accès disque — elle juge la liste qu'on lui donne.
    ///
    /// - Parameters:
    ///   - copies: les copies connues de LaunchServices, dans son ordre.
    ///   - defaultCopy: celle que macOS ouvrirait pour cet identifiant.
    ///   - expected: l'emplacement attendu (paramétré pour les tests).
    ///   - canonical: ce qui est posé à l'emplacement attendu, lu sur le disque
    ///     (`stampAtCanonicalPath`) — indépendant de LaunchServices, et donc de
    ///     l'identifiant. `nil` = rien là-bas. Le rapport le rend tel quel dans
    ///     `atExpectedPath` ; aucun verdict n'en dépend.
    public static func evaluate(
        copies: [URL],
        defaultCopy: URL?,
        expected: String = expectedPath,
        canonical: AppBundleStamp? = nil
    ) -> AppCopiesReport {
        // Dédoublonnage en gardant l'ordre : LaunchServices rend parfois deux
        // fois le même chemin (enregistrement disque + enregistrement volatil).
        var seen = Set<String>()
        var paths: [String] = []
        for url in copies {
            let p = normalize(url)
            if seen.insert(p).inserted { paths.append(p) }
        }
        // La copie par défaut compte comme une copie même si l'énumération ne
        // l'a pas rendue : les deux appels LaunchServices ne sont pas atomiques.
        let defaultPath = defaultCopy.map(normalize)
        if let defaultPath, seen.insert(defaultPath).inserted { paths.append(defaultPath) }

        // L'ordre du rapport est stable — la liste sert à un humain qui va
        // supprimer des fichiers, elle ne doit pas danser d'un appel à l'autre.
        paths.sort()

        if paths.isEmpty {
            return AppCopiesReport(
                copies: [],
                defaultCopy: nil,
                verdict: .notInstalled,
                displayText: "no copy known to macOS (the application is not installed)",
                guidance: nil,
                atExpectedPath: canonical)
        }

        if paths.count > 1 {
            let extras = paths.filter { $0 != expected }
            let effective = defaultPath ?? paths[0]
            let display = "\(paths.count) copies known to macOS — macOS opens \(effective); "
                + "others: \(extras.joined(separator: ", ")) — \(multipleCopiesGuidance)"
            return AppCopiesReport(
                copies: paths,
                defaultCopy: defaultPath,
                verdict: .multipleCopies(extras: extras),
                displayText: display,
                guidance: multipleCopiesGuidance,
                atExpectedPath: canonical)
        }

        let only = paths[0]
        if only != expected {
            return AppCopiesReport(
                copies: paths,
                defaultCopy: defaultPath,
                verdict: .outsideApplications(path: only),
                displayText: "1 copy, outside /Applications: \(only) — \(outsideApplicationsGuidance)",
                guidance: outsideApplicationsGuidance,
                atExpectedPath: canonical)
        }

        return AppCopiesReport(
            copies: paths,
            defaultCopy: defaultPath,
            verdict: .ok,
            displayText: only,
            guidance: nil,
            atExpectedPath: canonical)
    }
}
