// FouinePaths.swift — les deux chemins que les trois exécutables partagent.
// Propriété : A-Core, SPEC §10 (audit U2).
//
// La base était résolue par TROIS copies identiques du même code —
// `CLI.databaseURL`, `AppPaths.databaseURL`, `AgentPaths.databaseURL` — dont
// l'en-tête de chacune répétait « les trois outils DOIVENT regarder la même
// base : c'est la seule chose qui les relie ». Une invariante affirmée trois
// fois et vérifiée nulle part.
//
// Le journal de l'agent, lui, n'existait QUE dans `AgentPaths` : la fenêtre de
// réglages du palier 2.3 doit pouvoir l'ouvrir (« Ouvrir le journal »), et une
// quatrième copie du chemin dans l'app aurait été la copie de trop.

import Foundation

public enum FouinePaths {

    /// `~/Library/Application Support/Fouine/fouine.db`, ou `FOUINE_DB`
    /// (chemin complet du fichier `.db`) — indispensable aux tests et à la
    /// recette, qui n'écrivent JAMAIS dans la base de production.
    public static func databaseURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["FOUINE_DB"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Fouine",
                                    isDirectory: true)
            .appendingPathComponent("fouine.db")
    }

    /// Le verrou d'écriture de CETTE base : `<nom sans extension>.lock`, à côté
    /// d'elle. `fouine.db` → `fouine.lock`, `c2.db` → `c2.lock`.
    ///
    /// POURQUOI LE NOM SUIT LA BASE (constat BU-30). Le verrou s'appelait
    /// `fouine.lock` quelle que soit la base : deux copies dans un même dossier
    /// — le régime documenté du travail sur copie, `FOUINE_DB=<copie>` — se
    /// bloquaient l'une l'autre. Mesuré le 09/09/2026 : une application ouverte
    /// sur `sauvegardes/fouine-copie-…-bu.db` a affiché « Un autre programme
    /// écrit dans l'index » pendant plusieurs minutes parce qu'un audit
    /// écrivait dans `sauvegardes/c2.db`.
    public static func lockURL(for databaseURL: URL = databaseURL()) -> URL {
        lockURL(for: databaseURL, suffix: ".lock")
    }

    /// Le verrou de campagne de vectorisation (`fouine embed`) : `<nom sans
    /// extension>-embed.lock`. Même règle et même raison que `lockURL`.
    public static func embedLockURL(for databaseURL: URL = databaseURL()) -> URL {
        lockURL(for: databaseURL, suffix: "-embed.lock")
    }

    /// Un nom de base VIDE (chemin qui finit par `/`) retomberait sur un
    /// fichier caché `.lock` partagé par tout le dossier : le défaut qu'on
    /// répare. On garde alors le nom historique.
    private static func lockURL(for databaseURL: URL, suffix: String) -> URL {
        let stem = databaseURL.deletingPathExtension().lastPathComponent
        let name = stem.isEmpty ? "fouine" : stem
        return databaseURL.deletingLastPathComponent()
            .appendingPathComponent(name + suffix)
    }

    /// `~/Library/Application Support/Fouine/Sources/` — où Fouine RECOPIE le
    /// texte des notes des applications (lot INT-F4).
    ///
    /// Dérivé de `databaseURL()` et non écrit en dur, pour une raison de
    /// sûreté : `FOUINE_DB` pointe une copie jetable dans les tests et la
    /// recette, et le dossier des sources suit alors la copie. Il n'existe donc
    /// aucun chemin de code capable d'écrire dans le dossier RÉEL de
    /// l'utilisateur depuis un test.
    ///
    /// Le dossier est une RACINE indexée ordinaire (une par application). Il
    /// vit sous `~/Library`, que le crawl exclut — mais par CHEMIN, et
    /// seulement `~/Library` lui-même (`CrawlExclusions.isHomeLibrary`) : un
    /// dossier situé DESSOUS et désigné comme racine se parcourt normalement.
    public static func sourcesDirectory(for databaseURL: URL = databaseURL()) -> URL {
        databaseURL.deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    /// `~/Library/Logs/Fouine/fouine.log`, ou `FOUINE_AGENT_LOG`.
    ///
    /// C'est le SEUL canal de diagnostic d'un agent lancé par launchd. L'app
    /// s'en sert pour le bouton « Ouvrir le journal » de la fenêtre de réglages :
    /// depuis F7 elle affiche la progression de l'agent, mais un incident
    /// (racine illisible, OCR en échec) ne se lit toujours que là.
    public static func agentLogURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["FOUINE_AGENT_LOG"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Fouine", isDirectory: true)
            .appendingPathComponent("fouine.log")
    }

    /// Identifiant du bundle de l'application (CFBundleIdentifier de
    /// Packaging/Info.plist). Sert à demander à LaunchServices quelles copies
    /// de Fouine.app il connaît (lot J2, `AppCopiesProbe`).
    public static let appBundleIdentifier = "io.github.basedpolymer.fouine"

    /// Identifiant du LaunchAgent enregistré auprès de launchd / SMAppService.
    /// Sera renommé par un lot ultérieur : toute référence doit passer par cette constante.
    public static let agentServiceLabel = "\(appBundleIdentifier).agent"

    /// Nom du fichier plist correspondant dans Contents/Library/LaunchAgents/.
    public static let agentPlistName = "\(agentServiceLabel).plist"
}
