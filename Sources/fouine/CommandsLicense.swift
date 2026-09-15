// CommandsLicense.swift — `fouine license` (SPEC §4.3, lot L1C).
// Propriété : A-Core.
//
// AJOUT au contrat gelé du §4.3, pas modification : on ajoute une
// sous-commande, on n'en renomme aucune, aucune sortie existante ne change.
//
// NE PAS CONFONDRE AVEC `fouine licenses`, au pluriel, qui rend les notices des
// composants redistribués (GRDB, Sparkle, argument-parser, le modèle e5). Les
// deux résumés d'aide se distinguent en une ligne, exprès : « Your Fouine
// licence » contre « Licence of Fouine and notices of the redistributed
// components ».
//
// TROIS CODES DE SORTIE NOUVEAUX, pris dans les valeurs libres du §4.3 (0 à 5
// et 64 étaient prises) : **6** essai terminé, **7** clé refusée, **8** service
// de licence injoignable. Le 7 et le 8 se distinguent parce que le geste
// diffère : corriger la clé d'un côté, réessayer plus tard de l'autre.
//
// LA GARDE D'ESSAI EST ICI AUSSI (`LicenseGate`), et elle ne couvre QUE les
// commandes qui écrivent dans l'index : `crawl`, `extract`, `index`, `ocr`,
// `embed`. `search`, `list`, `status`, `doctor`, `mcp`, `backup`, `config`,
// `root` et `maintain` marchent dans tous les états — la fin d'essai arrête la
// mise à jour de l'index, elle ne prend pas en otage ce qui est déjà dedans.

import Foundation
import ArgumentParser
import FouineCore
import FouineLicense

// MARK: - La garde d'essai des commandes d'indexation

enum LicenseGate {

    /// Code de sortie de « l'essai est fini » (§4.3, amendement du 13/09/2026).
    static let trialOverExitCode: Int32 = 6
    /// Code de sortie de « cette clé est refusée ».
    static let keyRefusedExitCode: Int32 = 7
    /// Code de sortie de « le service de licence est injoignable ».
    static let serviceExitCode: Int32 = 8

    static func fileURL() -> URL {
        LicenseStore.fileURL(databaseURL: CLI.databaseURL())
    }

    /// L'état courant, l'essai étant démarré si c'est le premier passage.
    ///
    /// C'est ici que `trial_started` se pose quand `fouine crawl` précède le
    /// premier lancement de l'application — le cas de qui installe la ligne de
    /// commande seule.
    static func currentState(startingTrial: Bool = true) -> LicenseState {
        let url = fileURL()
        let file = startingTrial
            ? LicenseStore.ensureTrialStarted(at: url)
            : LicenseStore.load(at: url)
        return LicenseState.compute(file: file)
    }

    /// Refuse, en nommant les deux gestes, quand l'index n'a plus le droit de
    /// se mettre à jour. Ne rend la main que si tout va bien.
    static func requireIndexing() {
        guard !currentState().allowsIndexing else { return }
        CLI.fail("fouine: Trial over: enter a licence key "
                 + "(fouine license activate <key>) or buy one at "
                 + "\(LicenseTerms.purchaseURL.absoluteString). Search still works.")
        Foundation.exit(trialOverExitCode)
    }
}

// MARK: - fouine license

struct LicenseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "license",
        abstract: "Your Fouine licence: trial, activation, deactivation.",
        discussion: """
            Fouine is free to try for \(LicenseTerms.trialDays) days, with \
            nothing held back. After that, searching, previewing and exporting \
            keep working; only the index stops being updated until a licence \
            key is entered.

            A key costs \(LicenseTerms.priceDisplay), once, and covers \
            \(LicenseTerms.activationLimit) Macs: \
            \(LicenseTerms.purchaseURL.absoluteString)

            Activating, checking and deactivating a key are the only three \
            moments when this command contacts anything. What is sent: the key, \
            and the name of this Mac (so you can tell your Macs apart in the \
            seller's portal). Nothing about your documents. See \
            docs/privacy.md.

            Not to be confused with `fouine licenses` (plural), which prints \
            the notices of the redistributed third-party components.
            """,
        subcommands: [LicenseStatus.self, LicenseActivate.self,
                      LicenseDeactivate.self],
        defaultSubcommand: LicenseStatus.self)
}

// MARK: - fouine license status

struct LicenseStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the state of the trial or of the licence key.")

    @Flag(name: .long, help: "JSON output.")
    var json = false

    func run() {
        let url = LicenseGate.fileURL()
        // La lecture d'un état ne DÉMARRE pas l'essai : demander « où en
        // suis-je ? » ne doit pas consommer le premier jour de quelqu'un qui
        // n'a encore rien indexé.
        var file = LicenseStore.load(at: url)
        // LA VÉRIFICATION MENSUELLE, AUSSI ICI (LC2). Sans elle, qui n'utilise
        // que la ligne de commande n'était jamais vérifié : un Mac libéré
        // depuis le portail y restait sous licence pour toujours. Même règle
        // que l'application — une clé posée, pas vue depuis 30 jours — et même
        // décision (`LicenseCheck`). `status` est un geste explicite sur la
        // licence ; `crawl` et les autres commandes d'indexation ne sortent
        // jamais sur le réseau.
        if let current = file, LicenseCheck.isDue(current) {
            file = LicenseAsync.check(current, savingTo: url)
        }
        let state = LicenseState.compute(file: file)

        if json {
            var out: [String: Any] = ["state": state.jsonName]
            // `days_left` tant que l'essai court, libéré ou non.
            switch state {
            case .trial(let left):
                out["days_left"] = JSONNumber.rounded(Double(left), places: 0)
            case .released(let left) where left > 0:
                out["days_left"] = JSONNumber.rounded(Double(left), places: 0)
            default:
                break
            }
            if let key = file?.key, !key.isEmpty {
                out["key_suffix"] = LicenseState.suffix(key)
            }
            if let checked = file?.lastChecked {
                out["last_checked"] = ISO8601DateFormatter().string(from: checked)
            }
            if let limit = file?.activationLimit {
                out["activation_limit"] = JSONNumber.rounded(Double(limit), places: 0)
            }
            CLI.guarded { try CLI.printJSON(out) }
            return
        }

        switch state {
        case .trial(let left):
            print("Trial: \(left) day\(left == 1 ? "" : "s") left "
                  + "(\(LicenseTerms.trialDays) in total).")
            print("Buy a key for \(LicenseTerms.priceDisplay): "
                  + LicenseTerms.purchaseURL.absoluteString)
        case .trialOver:
            print("Trial over. Searching still works; the index is no longer updated.")
            print("Enter a key with `fouine license activate <key>`, or buy one "
                  + "for \(LicenseTerms.priceDisplay): "
                  + LicenseTerms.purchaseURL.absoluteString)
        case .licensed(let masked, let checked):
            print("Licensed — key ending in \(masked).")
            if let checked {
                print("Last checked: "
                      + ISO8601DateFormatter().string(from: checked))
            }
            if let limit = file?.activationLimit {
                print("This key covers \(limit) Mac\(limit == 1 ? "" : "s").")
            }
        case .revoked:
            print("This key was disabled by the seller.")
            print("Enter another key with `fouine license activate <key>`.")
        case .released(let left):
            print("This Mac was released from your customer portal.")
            print("Enter your key again with `fouine license activate <key>` to use it here.")
            if left > 0 {
                print("Trial: \(left) day\(left == 1 ? "" : "s") left.")
            } else {
                print("Searching still works; the index is no longer updated.")
            }
        }
    }
}

// MARK: - fouine license activate

struct LicenseActivate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activate",
        abstract: "Activate this Mac with a licence key.")

    @Argument(help: "The key, as it appears in the e-mail from the seller.")
    var key: String

    @Option(name: .customLong("instance-name"),
            help: "Name shown in the seller's portal (default: this Mac's name).")
    var instanceName: String?

    func run() {
        let cleaned = LicenseState.normalize(key)
        guard !cleaned.isEmpty else {
            CLI.fail("fouine: the key is empty.")
            Foundation.exit(64)
        }
        let name = instanceName ?? LicenseClient.thisMacName()
        let client = LicenseAsync.client()
        let response = LicenseAsync.result {
            try await client.activate(key: cleaned, instanceName: name)
        }
        switch response {
        case .failure(let error):
            LicenseAsync.die(error)
        case .success(let ok):
            guard ok.instanceIsActive, let instance = ok.instance else {
                // La clé ET l'instance (LC2) : le statut qui refuse est celui
                // de la clé s'il n'est pas `active`, sinon celui de l'instance.
                let refusing = ok.isActive ? (ok.instance?.status ?? "no instance") : ok.status
                CLI.fail("fouine: this key is not usable (\(refusing)).")
                Foundation.exit(LicenseGate.keyRefusedExitCode)
            }
            let url = LicenseGate.fileURL()
            var file = LicenseStore.ensureTrialStarted(at: url)
            file.key = cleaned
            file.instanceID = instance.id
            file.instanceName = instance.name ?? name
            file.activatedAt = Date()
            file.lastChecked = Date()
            file.activationLimit = ok.activationLimit ?? LicenseTerms.activationLimit
            file.state = .active
            do { try LicenseStore.save(file, to: url) } catch {
                CLI.fail("fouine: the key was accepted but could not be saved: "
                         + (error as NSError).localizedDescription)
                Foundation.exit(1)
            }
            let limit = file.activationLimit ?? LicenseTerms.activationLimit
            print("Activated on “\(file.instanceName ?? name)”. "
                  + "This key covers \(limit) Mac\(limit == 1 ? "" : "s").")
        }
    }
}

// MARK: - fouine license deactivate

struct LicenseDeactivate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deactivate",
        abstract: "Release this Mac's activation, so the key can be used elsewhere.")

    func run() {
        let url = LicenseGate.fileURL()
        guard let file = LicenseStore.load(at: url), file.hasKey,
              let key = file.key, let instance = file.instanceID else {
            CLI.fail("fouine: no licence key is active on this Mac.")
            Foundation.exit(64)
        }
        let client = LicenseAsync.client()
        let response = LicenseAsync.result {
            try await client.deactivate(key: key, instanceID: instance)
        }
        var alreadyReleased = false
        if case .failure(let error) = response {
            // Un Mac DÉJÀ libéré — depuis le portail, ou par une désactivation
            // précédente — n'a plus rien à libérer : on nettoie ce Mac plutôt
            // que de laisser quelqu'un coincé avec une clé morte qu'il ne sait
            // pas effacer. Mesuré le 14/09/2026 : Creem répond 400 « already
            // deactivated », ou 404 pour une instance qu'il ne connaît plus.
            // Toute autre erreur (hors ligne, clé refusée) garde le fichier.
            guard let refusal = error as? LicenseClientError,
                  refusal.meansAlreadyReleased else {
                LicenseAsync.die(error)
            }
            alreadyReleased = true
        }
        do { try LicenseStore.save(file.withoutKey(), to: url) } catch {
            CLI.fail("fouine: this Mac was released but the licence file could "
                     + "not be updated: \((error as NSError).localizedDescription)")
            Foundation.exit(1)
        }
        if alreadyReleased {
            print("This Mac was already released.")
        } else {
            print("This Mac no longer counts towards your activations. "
                  + "You can activate it again later.")
        }
    }
}

// MARK: - Le pont vers les appels asynchrones

/// `ParsableCommand.run()` est synchrone et le client est `async` : un
/// sémaphore les relie.
///
/// Pas d'`AsyncParsableCommand` : la racine `FouineCLI` est synchrone, et la
/// rendre asynchrone changerait le point d'entrée de TOUTES les commandes pour
/// les trois seules qui en ont besoin. Le fil principal attend ici pendant que
/// `URLSession` travaille sur ses propres files — c'est exactement ce que fait
/// déjà `ModelDownload` pour son sous-processus.
enum LicenseAsync {

    /// Le client, et un avertissement quand `FOUINE_LICENSE_RELAY` est posée
    /// mais refusée : sans lui, une adresse de recette mal tapée enverrait la
    /// clé d'essai au vrai relais, sans un mot.
    static func client() -> LicenseClient {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment[LicenseTerms.relayVariable], !raw.isEmpty,
           LicenseTerms.acceptedRelayURL(raw) == nil {
            CLI.warn("\(LicenseTerms.relayVariable) ignored: only https:// "
                     + "or http://127.0.0.1:<port> is accepted. Using "
                     + LicenseTerms.defaultRelayURL.absoluteString)
        }
        return LicenseClient(version: FouineVersion.string)
    }

    /// La vérification mensuelle de `license status`, jouée comme au lancement
    /// de l'application : le fichier suivant est écrit et rendu ; hors ligne
    /// ou service en panne, rien ne change et une ligne le dit sur stderr —
    /// stdout, et donc le JSON, reste intact.
    static func check(_ file: LicenseFile, savingTo url: URL) -> LicenseFile {
        guard let key = file.key, let instance = file.instanceID else { return file }
        let relay = Self.client()
        let result = LicenseAsync.result {
            try await relay.validate(key: key, instanceID: instance)
        }
        guard let next = LicenseCheck.file(after: result, of: file) else {
            if case .failure(let error) = result {
                CLI.warn("the licence could not be checked (\(error)); "
                         + "nothing changed, it will be checked next time.")
            }
            return file
        }
        do { try LicenseStore.save(next, to: url) } catch {
            // Non écrit, l'état reste celui d'avant au prochain appel, qui
            // revérifiera : le sens le plus favorable à la personne.
            CLI.warn("the licence was checked but the file could not be "
                     + "updated: \((error as NSError).localizedDescription)")
        }
        return next
    }

    static func result<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
        let box = Box<Result<T, Error>>()
        let done = DispatchSemaphore(value: 0)
        Task {
            do { box.value = .success(try await body()) }
            catch { box.value = .failure(error) }
            done.signal()
        }
        done.wait()
        return box.value ?? .failure(LicenseClientError.serviceUnavailable)
    }

    /// La phrase publique de chaque refus, et son code de sortie.
    static func die(_ error: Error) -> Never {
        guard let client = error as? LicenseClientError else {
            CLI.fail("fouine: " + CLI.describe(error))
            Foundation.exit(1)
        }
        switch client {
        case .offline:
            CLI.fail("fouine: no connection — connect to the Internet and try again.")
            Foundation.exit(LicenseGate.serviceExitCode)
        case .unknownKey:
            CLI.fail("fouine: this key is not recognised. Check for typos, or "
                     + "look for it in the e-mail the seller sent you.")
            Foundation.exit(LicenseGate.keyRefusedExitCode)
        case .keyRefused(let detail):
            // La phrase suit le détail (LC2) : seule la limite d'activation
            // envoie la personne libérer un Mac.
            if client.isActivationLimit {
                CLI.fail("fouine: this key is already in use on "
                         + "\(LicenseTerms.activationLimit) Macs. Deactivate one of "
                         + "them (fouine license deactivate on that Mac), or from "
                         + "your customer portal.")
            } else {
                CLI.fail("fouine: this key was refused. Contact the seller with "
                         + "the e-mail you used to buy it.")
            }
            // Le texte brut de Creem n'est pas documenté et peut changer : il
            // reste sur stderr en avertissement, pour un dépanneur.
            CLI.warn("licence service said: \(detail)")
            Foundation.exit(LicenseGate.keyRefusedExitCode)
        case .instanceNotFound:
            CLI.fail("fouine: this Mac was released from your customer portal. "
                     + "Enter your key again with `fouine license activate <key>`.")
            Foundation.exit(LicenseGate.keyRefusedExitCode)
        case .serviceUnavailable, .malformed:
            CLI.fail("fouine: the licence service is unavailable right now. "
                     + "Your trial continues; try again later.")
            Foundation.exit(LicenseGate.serviceExitCode)
        }
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }
}
