// ExternalTool.swift — les outils externes NON SYSTÈME, et le motif de saut
// qu'on écrit quand ils manquent. Propriété : A-Core. Lot K6 (constat A3-05).
//
// POURQUOI DANS FouineCore. Deux modules qui ne se connaissent pas ont besoin
// de la même réponse : FouineExtract, qui refuse d'extraire un `.djvu` sans
// djvulibre, et FouineCrawl, qui doit REVENIR sur ce refus dès que l'outil
// apparaît. `Package.swift` est gelé et FouineCrawl n'a pas FouineExtract dans
// ses dépendances ; la table de recherche vit donc ici, en un seul exemplaire,
// et `Subprocess.tool` l'appelle.
//
// LE MOTIF EST UN JETON, ET C'EST TOUT L'OBJET. Avant ce lot, `docs.err`
// portait une phrase — « djvu: djvulibre is missing » — que personne ne pouvait
// interpréter : un document sauté faute d'outil restait sauté à vie, parce que
// l'installation de l'outil ne change ni la taille ni le mtime du fichier et
// que le crawl delta ne regarde que ces deux-là. La phrase porte désormais
// `missing-tool:<exécutable>`, que le crawl sait relire et confronter au disque.

import Foundation

public enum ExternalTool {

    /// Répertoires où chercher un outil externe NON SYSTÈME, dans cet ordre
    /// (audit D8). `PATH` n'est PAS consulté : sous launchd et sous le Finder
    /// il est minimal ou absent — `djvused` y était introuvable et les 5 `.djvu`
    /// du corpus passaient `skipped` depuis l'app comme depuis l'agent, tout en
    /// s'extrayant depuis le Terminal.
    public static let searchPaths = [
        "/opt/homebrew/bin",        // Homebrew Apple Silicon
        "/usr/local/bin",           // Homebrew Intel
        "/opt/local/bin",           // MacPorts
    ]

    /// Variable d'environnement d'override d'un outil : `FOUINE_<NOM>`, chemin
    /// COMPLET de l'exécutable. Dérivée du nom, et non déclarée à côté, pour
    /// qu'un jeton `missing-tool:<nom>` suffise à retrouver l'override sans
    /// table de correspondance à tenir à jour.
    public static func overrideVariable(for name: String) -> String {
        "FOUINE_" + name.uppercased()
    }

    /// Chemin de l'outil s'il est installé, `nil` sinon.
    ///
    /// Ordre : les répertoires ci-dessus, PUIS seulement l'override. L'override
    /// vient EN DERNIER à dessein : il dépanne une installation hors norme sans
    /// jamais permettre à une variable d'environnement de détourner un outil
    /// correctement installé.
    ///
    /// `environment` et `fileManager` ne sont paramétrables que pour les tests.
    public static func path(_ name: String,
                            overrideVariable: String? = nil,
                            directories: [String] = searchPaths,
                            environment: [String: String]
                                = ProcessInfo.processInfo.environment,
                            fileManager: FileManager = .default) -> String? {
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if isRunnable(candidate, fileManager) { return candidate }
        }
        if let variable = overrideVariable,
           let override = environment[variable],
           !override.isEmpty,
           isRunnable(override, fileManager) {
            return override
        }
        return nil
    }

    /// L'outil est-il là MAINTENANT ? Le nom d'exécutable suffit : l'override se
    /// déduit du nom (`overrideVariable(for:)`).
    public static func isInstalled(_ name: String) -> Bool {
        path(name, overrideVariable: overrideVariable(for: name)) != nil
    }

    static func isRunnable(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return fileManager.isExecutableFile(atPath: path)
    }

    // MARK: - Le motif de saut « outil absent » (constat A3-05)

    /// Préfixe du jeton. Anglais, comme tout ce qui s'écrit dans `docs.err`.
    public static let missingToolPrefix = "missing-tool:"

    /// Le jeton à faire figurer dans `docs.err`, entre parenthèses, à la suite
    /// de la phrase lisible : « djvu: djvulibre is missing (missing-tool:djvused) ».
    public static func missingToolToken(_ name: String) -> String {
        missingToolPrefix + name
    }

    /// L'exécutable réclamé par un motif de saut, ou `nil` si le motif n'est pas
    /// de cette famille. Le jeton se termine au premier caractère qui ne peut
    /// pas appartenir à un nom d'exécutable — parenthèse fermante, espace.
    public static func missingTool(inSkipReason reason: String?) -> String? {
        guard let reason,
              let start = reason.range(of: missingToolPrefix) else { return nil }
        let rest = reason[start.upperBound...]
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }
}
