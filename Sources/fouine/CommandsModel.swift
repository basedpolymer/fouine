// CommandsModel.swift — `fouine model` : installation du modèle sémantique
// à la demande (audit D6). Propriété : A-Embed (palier 3, 02/09/2026).
//
// C'EST LA COMMANDE QUI OUVRE UNE CONNEXION. Le produit n'en a que deux
// (celle-ci et la vérification de mise à jour de l'app), et toutes deux
// exigent un geste. Conséquences tenues ici :
//   · AUCUNE QUESTION INTERACTIVE. Taper `fouine model download` EST le
//     consentement — une invite « voulez-vous vraiment ? » après une commande
//     explicite n'ajoute rien et casse les scripts. En revanche la commande
//     ANNONCE avant de partir : ce qu'elle va contacter, la taille, où elle
//     installe. C'est cette annonce qui rend le geste éclairé ;
//   · aucun appel implicite. Ni `fouine embed`, ni `fouine search --hybrid`, ni
//     `fouine doctor` ne téléchargent quoi que ce soit : ils DISENT quoi taper.
//
// TOUS LES TEXTES AFFICHÉS SONT REGROUPÉS DANS `ModelText`, en phrases
// entières, sans concaténation conditionnelle. C'est ce qui a rendu le passage
// à l'anglais du palier 3.5 mécanique ici : une phrase coupée en trois morceaux
// assemblés par des `if` ne se traduit pas.

import Foundation
import ArgumentParser
import FouineCore
import FouineEmbed

// MARK: - Textes

/// Tous les textes de `fouine model`, en un seul endroit.
enum ModelText {

    // Abrégés des sous-commandes
    static let abstract = "Install and manage the semantic search model."
    static let downloadAbstract = "Download and install the semantic model."
    static let statusAbstract = "Say whether the model is installed, and which one."
    static let removeAbstract = "Remove the installed model."

    static let discussion = """
    The model (multilingual-e5-small converted to CoreML, MIT licence) weighs
    220 MB and lives outside the binary, in ~/Library/Application Support/
    Fouine/models/e5-small. Without it, `fouine embed` and `fouine search
    --hybrid` do not work; full-text search needs none of it.

    `fouine model download` is, together with the application's update check,
    the only command of Fouine that opens a connection. It never starts on its
    own and announces what it contacts before doing so. FOUINE_MODEL_URL
    points at another source (a local file through file://, for instance);
    FOUINE_MODEL_SHA256 replaces the expected fingerprint, which amounts to
    trusting the archive in Fouine's stead.
    """

    // Options
    static let urlHelp = "Address of the archive (default: the release asset; FOUINE_MODEL_URL)."
    static let forceHelp = "Reinstall even if the model is already present."
    static let jsonHelp = "JSON output."

    // Annonce du téléchargement
    static func announceHeader(model: String, revision: Int) -> String {
        "downloading the semantic model \(model) (revision \(revision))"
    }
    static func announceSource(_ url: String) -> String {
        "  address      : \(url)"
    }
    static func announceHosts(_ hosts: String) -> String {
        "  hosts        : \(hosts)"
    }
    static let hostsGitHub =
        "github.com, then release-assets.githubusercontent.com (GitHub's redirect)"
    /// Adresse qui n'est PAS l'asset de release : on ne sait rien de ses
    /// redirections avant de les avoir suivies (audit A1-05).
    static func announceUnknownHosts(_ host: String) -> String {
        "  hosts        : \(host), plus any host it redirects to (https only)"
    }
    static func announceLocalSource(_ path: String) -> String {
        "  hosts        : none — local file \(path)"
    }
    static func announceSize(_ megabytes: String) -> String {
        "  size         : \(megabytes) (SHA-256 fingerprint checked on arrival)"
    }
    /// Taille inconnue : la constante ne vaut que pour l'asset de release.
    static let announceUnknownSize =
        "  size         : unknown until transfer (SHA-256 fingerprint checked "
        + "on arrival)"
    /// Ce qui a été contacté, une fois le transfert fini. C'est le seul énoncé
    /// du lot qui soit une CONSTATATION et non une prévision.
    static func contacted(_ hosts: [String]) -> String {
        hosts.isEmpty
            ? "contacted: no host (local source)"
            : "contacted: \(hosts.joined(separator: ", ")) (https)"
    }
    static func announceDestination(_ path: String) -> String {
        "  destination  : \(path)"
    }
    static let announceSent =
        "  sent         : one GET request and a User-Agent header, nothing else"

    // Progression et fin
    static func progressLine(phase: String, percent: Int,
                             megabytes: String) -> String {
        "\(phase): \(percent)% (\(megabytes))"
    }
    static func progressPhase(_ phase: String) -> String {
        "\(phase)…"
    }
    static func installed(model: String, revision: Int, path: String,
                          megabytes: String) -> String {
        "model \(model) revision \(revision) installed in \(path) (\(megabytes))"
    }
    static let nextStep =
        "run `fouine embed` to vectorise the pages, "
        + "then `fouine search --hybrid`"
    /// Le cache binaire du vocabulaire, produit tout de suite (UX-13) : sans
    /// lui, la première recherche par le sens paie ~5 s de lecture de
    /// `vocab.json` (audit A1m-15).
    static let vocabularyCached =
        "vocabulary cache written (vocab.bin) — the first search will not pay "
        + "for it"

    // État
    static func statusPresent(model: String, revision: Int, path: String,
                              megabytes: String) -> String {
        "semantic model: \(model) revision \(revision), \(megabytes), \(path)"
    }
    static func statusAbsent(path: String) -> String {
        "semantic model: missing from \(path) — `fouine model download` installs it"
    }
    static func alreadyInstalled(revision: Int) -> String {
        "model already installed (revision \(revision)) — "
        + "`fouine model download --force` reinstalls it"
    }
    static func removed(_ path: String) -> String {
        "model removed from \(path)"
    }
    static func nothingToRemove(_ path: String) -> String {
        "no model to remove in \(path)"
    }

    // Lignes de `doctor` et de `embed`
    static func doctorPresent(revision: Int) -> String {
        "present (revision \(revision))"
    }
    static let doctorAbsent = "MISSING — `fouine model download` installs it"

    /// Mégaoctets décimaux : c'est l'unité qu'affichent GitHub et le Finder.
    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}

// MARK: - fouine model

struct ModelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "model",
        abstract: ModelText.abstract,
        discussion: ModelText.discussion,
        subcommands: [ModelDownloadCommand.self, ModelStatusCommand.self,
                      ModelRemoveCommand.self],
        defaultSubcommand: ModelStatusCommand.self)
}

// MARK: - fouine model download

struct ModelDownloadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: ModelText.downloadAbstract,
        discussion: ModelText.discussion)

    @Option(name: .long, help: ArgumentHelp(ModelText.urlHelp))
    var url: String?

    @Flag(name: .long, help: ArgumentHelp(ModelText.forceHelp))
    var force = false

    func run() {
        CLI.guarded {
            let directory = EmbedPaths.modelDirectory()
            let source = try ModelDownloader.resolvedURL(override: url)
            let current = ModelDownloader.status(directory: directory)

            // Déjà là et pas de --force : ce n'est pas une panne, c'est une
            // commande sans objet. Code 0, et le geste pour forcer.
            if current.installed, !force {
                print(ModelText.alreadyInstalled(revision: current.revision ?? 0))
                return
            }

            // L'ANNONCE, avant le premier octet.
            //
            // AUDIT A1-05. Les deux constantes — « github.com, puis
            // release-assets.githubusercontent.com » et « 220 MB » — étaient
            // imprimées quelle que soit l'adresse : avec `FOUINE_MODEL_URL`
            // vers un autre serveur, Fouine annonçait des hôtes qu'il n'allait
            // pas contacter et une taille qu'il ne connaissait pas. Elles ne
            // valent que pour l'asset de release, et ne sont dites que là.
            let isDefaultSource =
                source.absoluteString == ModelDownloader.defaultURLString
            print(ModelText.announceHeader(model: ModelDownloader.expectedModelID,
                                           revision: ModelDownloader.expectedRevision))
            print(ModelText.announceSource(source.absoluteString))
            if source.isFileURL {
                print(ModelText.announceLocalSource(source.path))
            } else if isDefaultSource {
                print(ModelText.announceHosts(ModelText.hostsGitHub))
                print(ModelText.announceSent)
            } else {
                print(ModelText.announceUnknownHosts(source.host ?? "?"))
                print(ModelText.announceSent)
            }
            print(isDefaultSource
                  ? ModelText.announceSize(
                        ModelText.megabytes(ModelDownloader.expectedBytes))
                  : ModelText.announceUnknownSize)
            print(ModelText.announceDestination(directory.path))
            fflush(stdout)

            let reporter = ProgressReporter()
            let status = try ModelDownloader.install(
                into: directory, from: source, force: force,
                progress: { reporter.report($0) })
            reporter.finish()

            // CE QUI A ÉTÉ CONTACTÉ, et non ce qui était prévu (A1-05). Tous
            // les hôtes de cette liste ont été joints en `https:` : le délégué
            // refuse tout autre schéma en redirection (A1-03, D2-08).
            if !source.isFileURL {
                print(ModelText.contacted(status.contactedHosts))
            }
            print(ModelText.installed(
                model: status.modelID ?? ModelDownloader.expectedModelID,
                revision: status.revision ?? ModelDownloader.expectedRevision,
                path: directory.path,
                megabytes: ModelText.megabytes(status.bytesOnDisk)))
            // UX-13 : le cache du vocabulaire est produit MAINTENANT, pendant
            // que l'utilisateur attend déjà, et pas au premier `fouine search
            // --hybrid`, où il coûtait ~5 s à quelqu'un qui vient de taper une
            // requête. Best-effort : son échec ne change rien à l'installation.
            if EmbedPaths.warmVocabularyCache(at: directory) {
                print(ModelText.vocabularyCached)
            }
            print(ModelText.nextStep)
        }
    }
}

// MARK: - fouine model status

struct ModelStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: ModelText.statusAbstract)

    @Flag(name: .long, help: ArgumentHelp(ModelText.jsonHelp)) var json = false

    func run() {
        CLI.guarded {
            let directory = EmbedPaths.modelDirectory()
            let status = ModelDownloader.status(directory: directory)
            if json {
                var payload: [String: Any] = [
                    "installed": status.installed,
                    "path": directory.path,
                    "bytes": status.bytesOnDisk,
                    "url": ModelDownloader.defaultURLString,
                ]
                if let id = status.modelID { payload["model_id"] = id }
                if let revision = status.revision { payload["revision"] = revision }
                try CLI.printJSON(payload)
                return
            }
            if status.installed {
                print(ModelText.statusPresent(
                    model: status.modelID ?? ModelDownloader.expectedModelID,
                    revision: status.revision ?? 0,
                    path: directory.path,
                    megabytes: ModelText.megabytes(status.bytesOnDisk)))
            } else {
                print(ModelText.statusAbsent(path: directory.path))
            }
        }
    }
}

// MARK: - fouine model remove

struct ModelRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: ModelText.removeAbstract)

    func run() {
        CLI.guarded {
            let directory = EmbedPaths.modelDirectory()
            let removed = try ModelDownloader.remove(directory: directory)
            print(removed ? ModelText.removed(directory.path)
                          : ModelText.nothingToRemove(directory.path))
        }
    }
}

// MARK: - Affichage de la progression

/// Progression sur STDERR, jamais sur stdout : `fouine model download > log`
/// doit garder un journal lisible, et un `--json` futur ne doit pas être pollué.
///
/// Sur un terminal, une seule ligne réécrite (`\r`). Redirigé vers un fichier,
/// une ligne tous les 10 % — un `\r` dans un journal donne une bouillie.
/// Le rappel arrive d'un fil quelconque, d'où le verrou.
final class ProgressReporter: @unchecked Sendable {
    private let mutex = NSLock()
    private let interactive = isatty(STDERR_FILENO) == 1
    private var lastPercent = -1
    private var lastPhase: ModelDownloadPhase?
    private var wroteLine = false

    func report(_ progress: ModelDownloadProgress) {
        mutex.lock()
        defer { mutex.unlock() }
        if progress.phase != .downloading {
            guard lastPhase != progress.phase else { return }
            lastPhase = progress.phase
            endLine()
            write(ModelText.progressPhase(progress.phase.label) + "\n")
            return
        }
        lastPhase = .downloading
        let percent = Int((progress.fraction ?? 0) * 100)
        let step = interactive ? 1 : 10
        guard percent >= lastPercent + step || lastPercent < 0 else { return }
        lastPercent = percent - (percent % step)
        let line = ModelText.progressLine(
            phase: progress.phase.label, percent: percent,
            megabytes: ModelText.megabytes(progress.bytesReceived))
        if interactive {
            write("\r\u{1B}[K" + line)
            wroteLine = true
        } else {
            write(line + "\n")
        }
    }

    func finish() { mutex.lock(); endLine(); mutex.unlock() }

    private func endLine() {
        guard wroteLine else { return }
        write("\n")
        wroteLine = false
    }

    private func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
