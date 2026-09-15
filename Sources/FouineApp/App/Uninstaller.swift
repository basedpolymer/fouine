// Uninstaller.swift — « Désinstaller Fouine… » (audit D13). Propriété : A-App.
//
// « Aucune procédure de désinstallation. L'agent reste enregistré auprès de
//   launchd, l'index occupe des gigaoctets dans Application Support, et rien
//   dans l'application ne le dit. »
//
// CE FICHIER NE SUPPRIME RIEN TOUT SEUL. Il calcule un PLAN — quels chemins,
// quelle taille, ce qui est refusé et pourquoi —, la feuille l'affiche, et
// `perform` ne s'exécute qu'après un clic sur un bouton destructif. Le plan
// est une fonction PURE de chemins injectés : c'est ce qui le rend testable
// sur des répertoires temporaires, sans jamais toucher à l'installation réelle.
//
// TROIS GARDE-FOUS, ET AUCUN N'EST DÉCORATIF :
//
//   1. RIEN HORS DE ~/Library. `FOUINE_DB` et `FOUINE_AGENT_LOG` déplacent la
//      base et le journal où l'on veut — sur un volume externe, dans un dossier
//      de recette, dans le corpus lui-même. La désinstallation vise les
//      emplacements RÉSOLUS (sinon elle laisserait derrière elle exactement ce
//      qu'on lui demande d'effacer), mais elle REFUSE de supprimer un dossier
//      qui n'est pas sous `~/Library` : elle l'affiche, dit pourquoi, et laisse
//      l'utilisateur s'en charger. Un `rm -rf` sur un chemin venu d'une variable
//      d'environnement est le genre de geste qu'on ne rattrape pas.
//
//   2. RIEN QUI NE SOIT À NOUS dans `/usr/local/bin`. Le lien `fouine` n'est
//      retiré que s'il pointe DANS CETTE COPIE de l'application. Un binaire
//      installé là par Homebrew ou compilé à la main reste en place — mêmes
//      règles que `CLIInstaller`, et jamais de `sudo` : si le dossier n'est pas
//      inscriptible, la commande est affichée et copiée.
//
//   3. AUCUN DOSSIER INDEXÉ N'EST TOUCHÉ, jamais, sous aucune option. Fouine
//      n'a jamais écrit dedans (docs/privacy.md) et n'a rien à y défaire.
//      La feuille le dit, parce que c'est la première question qu'on se pose en
//      cliquant sur « Désinstaller ».
//
// L'AGENT D'ABORD. `SMAppService.unregister` demande à launchd de ne plus le
// lancer, mais un agent en train d'écrire ne s'arrête pas à l'instant : il tient
// `fouine.lock` jusqu'à son point de repos. Supprimer la base sous ses pieds
// laisserait un `-wal` orphelin et, pire, un processus qui recrée le dossier
// une seconde après qu'on l'a effacé. `perform` attend donc que le verrou ne
// nomme plus personne de vivant, avec une échéance courte.

import Foundation
import AppKit
import ServiceManagement
import FouineCore
import FouineIndex
import FouineLicense

enum Uninstaller {

    // MARK: - Le plan

    /// Un emplacement candidat à la suppression.
    struct Target: Equatable, Sendable {
        let url: URL
        /// Taille cumulée, 0 si l'emplacement n'existe pas.
        let bytes: Int64
        let exists: Bool
        /// `false` quand le chemin RÉSOLU sort de `~/Library` : il est affiché,
        /// jamais supprimé (garde-fou 1).
        let removable: Bool
    }

    /// L'état du lien `/usr/local/bin/fouine`.
    enum CLILink: Equatable, Sendable {
        /// Rien à cet emplacement : il n'y a rien à défaire.
        case absent
        /// Un lien symbolique vers CETTE copie de Fouine : on le retire.
        case ours(link: URL, target: String)
        /// Un lien vers une AUTRE copie de Fouine, ou vers autre chose : on n'y
        /// touche pas, et on dit où il pointe.
        case foreign(link: URL, target: String)
        /// Un vrai fichier (Homebrew, compilation manuelle) : jamais à nous.
        case notALink(URL)
        /// Le nôtre, mais le dossier n'est pas inscriptible : la commande est
        /// affichée et copiée, l'app ne demande jamais de mot de passe.
        case manual(link: URL, command: String)
    }

    /// Les 7 chemins du bloc `zap trash:` dans Packaging/homebrew/fouine.rb.
    /// Source de vérité partagée entre le cask et le plan de désinstallation (audit H4, U1).
    public static let zapPaths = [
        "~/Library/Application Support/Fouine",
        "~/Library/Caches/fouine",
        "~/Library/Caches/io.github.basedpolymer.fouine",
        "~/Library/HTTPStorages/io.github.basedpolymer.fouine",
        "~/Library/Logs/Fouine",
        "~/Library/Preferences/io.github.basedpolymer.fouine.plist",
        "~/Library/Saved Application State/io.github.basedpolymer.fouine.savedState",
    ]

    struct Plan: Equatable, Sendable {
        /// Ce que « supprimer l'index » vise.
        ///
        /// UNE LISTE, ET NON UN DOSSIER (constat BU-32). C'était le dossier
        /// PARENT de la base, quel qu'il soit : avec `FOUINE_DB` posé dans un
        /// dossier de sauvegardes, la feuille proposait « Supprimer l'index et
        /// les réglages — 6,26 Go » en nommant tout le dossier, copies des
        /// autres audits comprises. Le garde-fou « hors ~/Library » sauvait ce
        /// cas-là ; un `FOUINE_DB` posé DANS `~/Library` — parfaitement
        /// légitime — emportait tout ce qui s'y trouvait.
        ///
        /// Le dossier n'est donc visé que s'il s'appelle `Fouine`, c'est-à-dire
        /// s'il est à nous. Sinon : le fichier de base et ses deux compagnons
        /// de travail, et rien d'autre du dossier.
        let support: [Target]
        /// Le dossier de la base — pour ATTENDRE que l'agent lâche
        /// `fouine.lock`, jamais pour supprimer quoi que ce soit.
        let supportDirectory: URL
        /// `~/Library/Logs/Fouine/`.
        let logs: Target
        /// `~/Library/Preferences/io.github.basedpolymer.fouine.plist`.
        let preferences: Target
        /// Domaine `UserDefaults` à effacer avec le plist.
        let preferencesDomain: String
        /// Les 7 cibles du bloc zap Homebrew
        let zapTargets: [Target]
        let cli: CLILink
        /// L'application à mettre à la corbeille. `nil` hors bundle
        /// (`swift run FouineApp`), où il n'y a pas d'app à jeter.
        let bundle: URL?
    }

    /// Vrai quand la désinstallation a un sens : il faut une `.app` à jeter.
    /// Hors bundle, l'élément de menu est présent mais désactivé — le faire
    /// disparaître laisserait croire que Fouine ne sait pas se désinstaller.
    static var isAvailable: Bool { bundleToTrash() != nil }

    /// Le bundle courant, s'il y en a un. `Bundle.main.bundleURL` désigne le
    /// répertoire de l'exécutable quand l'app tourne sans bundle : seule
    /// l'extension `.app` distingue les deux.
    static func bundleToTrash(_ bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    static func resolvePath(_ tildePath: String, home: URL) -> URL {
        let trimmed = tildePath.hasPrefix("~/") ? String(tildePath.dropFirst(2)) : tildePath
        return home.appendingPathComponent(trimmed)
    }

    /// Le plan, calculé depuis des chemins INJECTÉS — aucune lecture d'un
    /// emplacement par défaut ici, c'est ce qui le rend testable.
    static func plan(databaseURL: URL,
                     agentLogURL: URL,
                     preferencesURL: URL,
                     preferencesDomain: String = Prefs.suite,
                     cliLink: URL = AppPaths.cliLinkURL,
                     bundledCLIParent: URL?,
                     bundle: URL?,
                     home: URL,
                     fileManager: FileManager = .default) -> Plan {
        let zapTargets = zapPaths.map {
            target(resolvePath($0, home: home), home: home, fileManager: fileManager)
        }
        return Plan(support: supportTargets(databaseURL: databaseURL, home: home,
                                            fileManager: fileManager),
                    supportDirectory: databaseURL.deletingLastPathComponent()
                        .standardizedFileURL,
                    logs: target(agentLogURL.deletingLastPathComponent(),
                                 home: home, fileManager: fileManager),
                    preferences: target(preferencesURL,
                                        home: home, fileManager: fileManager),
                    preferencesDomain: preferencesDomain,
                    zapTargets: zapTargets,
                    cli: cliState(link: cliLink, within: bundledCLIParent,
                                  fileManager: fileManager),
                    bundle: bundle)
    }

    /// Le plan de CETTE installation : chemins résolus (`FOUINE_DB`,
    /// `FOUINE_AGENT_LOG` compris), bundle courant.
    static func currentPlan(fileManager: FileManager = .default) -> Plan {
        let home = fileManager.homeDirectoryForCurrentUser
        let bundle = bundleToTrash()
        return plan(databaseURL: FouinePaths.databaseURL(),
                    agentLogURL: FouinePaths.agentLogURL(),
                    preferencesURL: home.appendingPathComponent(
                        "Library/Preferences/\(Prefs.suite).plist"),
                    bundledCLIParent: bundle,
                    bundle: bundle,
                    home: home,
                    fileManager: fileManager)
    }

    // MARK: - Les pièces du plan

    /// Le nom du dossier de Fouine. Un dossier qui ne s'appelle pas ainsi n'est
    /// pas à nous, et ne se supprime donc pas en entier (BU-32).
    static let supportDirectoryName = "Fouine"

    /// Les cibles de « supprimer l'index et les réglages ».
    static func supportTargets(databaseURL: URL, home: URL,
                               fileManager: FileManager = .default) -> [Target] {
        let directory = databaseURL.deletingLastPathComponent()
        if directory.lastPathComponent == supportDirectoryName {
            return [target(directory, home: home, fileManager: fileManager)]
        }
        // Le fichier de base, ses deux fichiers de travail SQLite, et le
        // fichier de licence. Rien d'autre du dossier : ce qui s'y trouve
        // n'appartient pas à Fouine.
        //
        // `license.json` est ici et pas ailleurs (lot L1C) : dans le cas
        // ordinaire — le dossier s'appelle « Fouine » — il part avec le dossier
        // entier, à la ligne du dessus. Base déplacée par `FOUINE_DB`, il la
        // suit, et il faut donc le nommer.
        //
        // Il n'est nommé QUE s'il existe, contrairement aux trois fichiers
        // SQLite : ceux-là se montrent même absents (`-wal` disparaît à chaque
        // fermeture propre, et une ligne qui clignote d'une ouverture à
        // l'autre serait pire qu'une ligne toujours là). Une licence, elle,
        // n'existe pas tant que rien n'a été acheté, et annoncer son effacement
        // à quelqu'un qui n'en a pas ne lui apprendrait rien.
        let licence = target(databaseURL.deletingLastPathComponent()
                                .appendingPathComponent(LicenseStore.fileName),
                             home: home, fileManager: fileManager)
        return ["", "-wal", "-shm"].map { suffix in
            target(URL(fileURLWithPath: databaseURL.path + suffix),
                   home: home, fileManager: fileManager)
        } + (licence.exists ? [licence] : [])
    }

    static func target(_ url: URL, home: URL,
                       fileManager: FileManager = .default) -> Target {
        let standardized = url.standardizedFileURL
        let exists = fileManager.fileExists(atPath: standardized.path)
        return Target(url: standardized,
                      bytes: exists ? size(of: standardized,
                                           fileManager: fileManager) : 0,
                      exists: exists,
                      removable: isUnderLibrary(standardized, home: home))
    }

    /// Le chemin est-il sous `~/Library`, ASSEZ PROFOND pour être un dossier à
    /// nous ?
    ///
    /// Deux composants au moins après `Library` : `Application Support/Fouine`,
    /// `Logs/Fouine`, `Preferences/io.github.basedpolymer.fouine.plist` en ont deux.
    /// `~/Library/Application Support` — ce que donnerait
    /// `FOUINE_DB=~/Library/Application Support/x.db` — n'en a qu'un, et sa
    /// suppression emporterait les données de toutes les applications du Mac.
    /// C'est exactement le genre d'accident que cette borne interdit.
    static func isUnderLibrary(_ url: URL, home: URL) -> Bool {
        let base = home.standardizedFileURL
            .appendingPathComponent("Library").path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return false }
        let rest = path.dropFirst(base.count + 1)
            .split(separator: "/", omittingEmptySubsequences: true)
        return rest.count >= 2
    }

    /// Taille cumulée d'un fichier ou d'un répertoire.
    static func size(of url: URL, fileManager: FileManager = .default) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path,
                                     isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let walker = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey],
            options: []) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// L'état du lien de ligne de commande. Mêmes règles que `CLIInstaller`,
    /// dans l'autre sens.
    static func cliState(link: URL, within bundle: URL?,
                         fileManager: FileManager = .default) -> CLILink {
        // `attributesOfItem` ne SUIT PAS les liens (lstat) : un lien mort est
        // donc vu comme un lien, et non comme une absence.
        guard let attributes = try? fileManager
            .attributesOfItem(atPath: link.path) else { return .absent }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
              let destination = try? fileManager
                .destinationOfSymbolicLink(atPath: link.path) else {
            return .notALink(link)
        }
        guard let bundle,
              destination.hasPrefix(bundle.standardizedFileURL.path + "/") else {
            return .foreign(link: link, target: destination)
        }
        let directory = link.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: directory.path) else {
            return .manual(link: link, command: "sudo rm '\(link.path)'")
        }
        return .ours(link: link, target: destination)
    }

    // MARK: - Exécution

    /// Ce que l'utilisateur a coché. L'agent et le lien ne sont pas des options :
    /// ils défont ce que l'installation a fait AILLEURS que dans le dossier de
    /// l'app, et les laisser derrière soi n'a aucun sens.
    struct Options: Equatable, Sendable {
        var deleteIndex = true
        var deleteLogs = true
        var deletePreferences = true
    }

    /// Ce qui a été fait, et ce qui a échoué.
    struct Outcome: Sendable {
        var failures: [String] = []
        /// Commande à coller quand `/usr/local/bin` n'est pas inscriptible.
        /// C'est l'APPELANT qui la met dans le presse-papiers : `perform` ne
        /// tourne pas sur le fil principal, et le presse-papiers est d'AppKit.
        var command: String?
    }

    /// **N'EST PAS TESTÉ AUTOMATIQUEMENT, ET NE DOIT PAS L'ÊTRE** : cette
    /// fonction désenregistre l'agent d'arrière-plan de la machine où elle
    /// tourne. C'est `plan` qui porte la logique, et c'est `plan` qui est testé.
    ///
    /// À APPELER HORS DU FIL PRINCIPAL : elle attend le verrou puis la fin de la
    /// mise à la corbeille, sur des sémaphores.
    @discardableResult
    static func perform(_ plan: Plan, options: Options,
                        fileManager: FileManager = .default) -> Outcome {
        var outcome = Outcome()

        // 0. Ce que Fouine a donné à Spotlight (lot INT-S1). AVANT tout le
        //    reste : c'est le seul moment où l'application tourne encore, avec
        //    son identité de bundle, et une désinstallation qui laisserait des
        //    documents de Fouine dans Spotlight tiendrait de la promesse non
        //    tenue — des résultats qui ouvrent une application effacée.
        //    L'échec ne fait pas échouer la désinstallation : les éléments
        //    d'une application disparue s'éteignent d'eux-mêmes.
        try? SpotlightDonor().deleteAll()

        // 0 bis. LIBÉRER L'ACTIVATION DE CE MAC, AU MIEUX (lot L1C).
        //
        //     Une clé couvre trois Mac. Désinstaller sans rien dire au vendeur
        //     laisserait une activation prise par une application qui n'existe
        //     plus — et la personne se retrouverait, deux Mac plus tard,
        //     devant un refus qu'elle ne comprendrait pas.
        //
        //     AU MIEUX, ET PAS PLUS : 5 s, aucune attente visible au-delà,
        //     aucun échec remonté. Une désinstallation ne se met pas en travers
        //     d'un réseau absent, et le portail Creem permet de libérer un Mac
        //     à la main. Elle n'a lieu QUE si l'index part : garder l'index
        //     tout en libérant l'activation n'aurait aucun sens.
        if options.deleteIndex { releaseLicenceActivation() }

        // 1. L'agent, d'abord — et on attend qu'il lâche le verrou.
        //
        // Le statut est consulté AVANT : `unregister` sur un agent qui n'a
        // jamais été enregistré jette, et ce n'est pas un échec de
        // désinstallation. Le distinguer par le code d'erreur demanderait une
        // constante de ServiceManagement ; une question suffit.
        let agent = SMAppService.agent(plistName: AppPaths.agentPlistName)
        if agent.status != .notRegistered {
            do { try agent.unregister() } catch {
                outcome.failures.append(
                    String(localized: "background indexing could not be turned off: \((error as NSError).localizedDescription)"))
            }
        }
        waitForLockRelease(for: FouinePaths.databaseURL())

        // 2. Le lien de ligne de commande.
        switch plan.cli {
        case .ours(let link, _):
            do { try fileManager.removeItem(at: link) } catch {
                outcome.failures.append(
                    String(localized: "\(link.path) could not be removed: \((error as NSError).localizedDescription)"))
            }
        case .manual(_, let command):
            outcome.command = command
        case .absent, .foreign, .notALink:
            break
        }

        // 3. Les emplacements cochés, et seulement ceux qui sont supprimables.
        if options.deleteIndex {
            for target in plan.support {
                remove(target, into: &outcome, fileManager: fileManager)
            }
        }
        if options.deleteLogs {
            remove(plan.logs, into: &outcome, fileManager: fileManager)
        }
        if options.deletePreferences {
            // Le domaine AVANT le fichier : `UserDefaults` réécrit son plist à
            // la synchronisation, et l'ordre inverse ferait réapparaître un
            // fichier qu'on vient d'effacer.
            Prefs.defaults.removePersistentDomain(forName: plan.preferencesDomain)
            UserDefaults.standard.removePersistentDomain(
                forName: plan.preferencesDomain)
            remove(plan.preferences, into: &outcome, fileManager: fileManager)
            let already = Set(plan.support.map(\.url) + [plan.logs.url])
            for t in plan.zapTargets where !already.contains(t.url) {
                remove(t, into: &outcome, fileManager: fileManager)
            }
        }

        // 4. L'application à la corbeille — la sienne, où qu'elle soit.
        if let bundle = plan.bundle {
            let box = FailureBox()
            let waiter = DispatchSemaphore(value: 0)
            NSWorkspace.shared.recycle([bundle]) { _, error in
                box.set(error)
                waiter.signal()
            }
            _ = waiter.wait(timeout: .now() + 30)
            if let error = box.value {
                outcome.failures.append(
                    String(localized: "\(bundle.path) could not be moved to the Trash: \((error as NSError).localizedDescription)"))
            }
        }
        return outcome
    }

    /// Dit au vendeur que ce Mac ne compte plus (lot L1C). Silencieuse, bornée
    /// à 5 s, et sans conséquence : le fichier part de toute façon juste après.
    ///
    /// **N'EST PAS TESTÉE AUTOMATIQUEMENT** : elle sort sur le réseau, comme le
    /// reste de `perform`, qui désenregistre un agent launchd.
    private static func releaseLicenceActivation() {
        let url = LicenseStore.fileURL(databaseURL: FouinePaths.databaseURL())
        guard let file = LicenseStore.load(at: url), file.hasKey,
              let key = file.key, let instance = file.instanceID else { return }
        let client = LicenseClient(version: FouineVersionString)
        let done = DispatchSemaphore(value: 0)
        Task {
            _ = try? await client.deactivate(key: key, instanceID: instance)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
    }

    /// Le rappel de `recycle` arrive d'une file qui n'est pas la nôtre : la
    /// variable de sortie passe par un objet verrouillé, pas par une capture
    /// mutable.
    private final class FailureBox: @unchecked Sendable {
        private let mutex = NSLock()
        private var stored: Error?
        func set(_ error: Error?) { mutex.lock(); stored = error; mutex.unlock() }
        var value: Error? { mutex.lock(); defer { mutex.unlock() }; return stored }
    }

    private static func remove(_ target: Target, into outcome: inout Outcome,
                               fileManager: FileManager) {
        guard target.exists, target.removable else { return }
        do { try fileManager.removeItem(at: target.url) } catch {
            outcome.failures.append(
                String(localized: "\(target.url.path) could not be deleted: \((error as NSError).localizedDescription)"))
        }
    }

    /// Attend que le verrou de la base ne nomme plus un processus vivant.
    ///
    /// L'agent que launchd vient de lâcher termine sa page en cours ; c'est une
    /// poignée de secondes au pire. Passé l'échéance on continue quand même :
    /// mieux vaut une désinstallation qui laisse un `-wal` derrière elle qu'une
    /// fenêtre bloquée sur un processus qui ne rendra jamais la main.
    /// Le verrou porte le nom de sa base depuis BU-30 (lot CL1) : on le
    /// demande à `FouinePaths`, jamais recomposé ici.
    private static func waitForLockRelease(for databaseURL: URL,
                                           timeout: TimeInterval = 8) {
        let lock = FouinePaths.lockURL(for: databaseURL)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let text = try? String(contentsOf: lock, encoding: .utf8),
                  let holder = LockHolder.parse(text),
                  holder.pid != getpid(), holder.isAlive else { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}
