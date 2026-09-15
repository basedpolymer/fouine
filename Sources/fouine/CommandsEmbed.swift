// CommandsEmbed.swift — `fouine embed` : production des vecteurs sémantiques
// (recherche hybride, §12). Propriété : A-Embed (01/09/2026).

import Foundation
import Dispatch
import ArgumentParser
import FouineCore
import FouineEmbed

/// Drapeau d'arrêt partagé entre les gestionnaires de signaux et la pompe.
/// `NSLock` plutôt qu'un booléen nu : `shouldStop` est lu depuis le fil de
/// travail et écrit depuis la file du `DispatchSource`.
private final class StopFlag: @unchecked Sendable {
    private let mutex = NSLock()
    private var requested = false
    func request() { mutex.lock(); requested = true; mutex.unlock() }
    var isRequested: Bool {
        mutex.lock(); defer { mutex.unlock() }; return requested
    }
}

struct EmbedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "embed",
        abstract: "Produce the semantic vectors of the pages (hybrid search).",
        discussion: """
        Incremental and resumable: only the pages without a vector are
        processed, and any page whose text changes (re-extraction, OCR) has to
        be produced again. The model (multilingual-e5-small converted to
        CoreML) lives in ~/Library/Application Support/Fouine/models/e5-small
        and is installed with `fouine model download` (220 MB, downloaded on
        demand, SHA-256 fingerprint checked). Tools/convert_e5.py is still the
        way to rebuild it yourself.

        Inference is expensive (CPU): prefer to run it with the OCR agent
        paused, or with --budget-minutes for bounded slices.
        """)

    @Option(name: .customLong("budget-minutes"),
            help: "Stop after N minutes (default: until the queue is empty).")
    var budgetMinutes: Double?

    @Option(name: .long, help: "Pages per inference batch (24 by default).")
    var batch: Int = 24

    @Option(name: .long,
            help: ArgumentHelp("Only prepare this folder, by its label; repeatable. "
                + "Without it, the pinned folders (roots.pinned) come first, "
                + "then the rest of the index. Spreadsheets are left out of "
                + "both passes unless --include-tables is given, and this "
                + "option does not change that."))
    var folder: [String] = []

    @Flag(name: .customLong("include-tables"),
          help: ArgumentHelp("Also vectorise spreadsheets, which are skipped by "
              + "default (a column of numbers describes nothing)."))
    var includeTables = false

    @Option(name: .customLong("model-dir"),
            help: "Model directory (default: Application Support, or FOUINE_MODEL_DIR).")
    var modelDir: String?

    @Flag(name: .long, help: "Print the vector coverage and exit.")
    var status = false

    @Option(name: .long,
            help: "Benchmark: infer N synthetic pages WITHOUT writing anything.")
    var bench: Int?

    func run() {
        // LE VERROU DE CAMPAGNE, AVANT TOUT (constat C2-11). Deux `fouine
        // embed` sur la même base refaisaient le même travail en parallèle,
        // tous deux en sortie 0 : le verrou d'écriture ne peut pas s'y opposer,
        // il est rendu après chaque lot exprès. Pris ici, avant d'ouvrir quoi
        // que ce soit : rien à rendre si l'on sort à la ligne suivante.
        //
        // `--bench` n'ouvre pas la base et `--status` ne fait que lire : ni
        // l'un ni l'autre n'est une campagne, ni ne doit en empêcher une.
        // LA GARDE D'ESSAI, AVANT MÊME LE VERROU DE CAMPAGNE (lot L1C).
        // `--status` et `--bench` restent lisibles en fin d'essai : le premier
        // ne fait que lire, le second n'écrit rien — refuser un compteur
        // n'apprendrait rien à personne.
        if bench == nil, !status { LicenseGate.requireIndexing() }
        var campaign: EmbedCampaignLock?
        if bench == nil, !status {
            do {
                campaign = try EmbedCampaignLock.acquire(
                    databaseURL: CLI.databaseURL())
            } catch let busy as EmbedCampaignLock.Busy {
                // QUI TIENT LE VERROU (lot AG1, PR-21). Depuis que la mise à
                // jour automatique prépare le sens elle-même, le détenteur le
                // plus probable est l'agent — et « a vectorisation campaign is
                // already running (pid 1234) » n'apprend rien à qui n'a lancé
                // aucune campagne. Le pid du lot est dans `agent_status` : on
                // compare, et on dit le geste. Une lecture, jamais le verrou.
                CLI.fail("fouine: " + (Self.agentHolderMessage(busy)
                                       ?? busy.description))
                Foundation.exit(3)          // §4.3 : base verrouillée
            } catch {
                // Un fichier de verrou impossible à ouvrir n'est pas une raison
                // de refuser une campagne de vingt heures : on le dit, et on y va.
                CLI.warn(CLI.describe(error))
            }
        }
        CLI.guarded {
            if let bench {
                try runBench(pages: bench)
                return
            }
            // `--status` est une lecture : elle refuse une base absente au
            // lieu d'en fabriquer une (audit A1m-09).
            let store = status ? try CLI.openStoreReadOnly()
                               : try CLI.openStore()
            if status {
                let stats = try store.stats()
                let indexed = stats["pages_indexed", default: 0]
                let vectors = stats["pages_vec", default: 0]
                let complete = stats["pages_vec_complete", default: 0]
                let windows = stats["vectors_vec", default: 0]
                let meta = try store.vecMeta()
                print("indexed pages: \(indexed)")
                print("vectorised pages: \(vectors) "
                      + (indexed > 0
                         ? String(format: "(%.1f%%)",
                                  100 * Double(vectors) / Double(indexed))
                         : ""))
                // TROIS lignes, parce que « vectorisée » ne veut plus dire
                // « finie » (schéma v5) : une page reprise du schéma v3 porte
                // sa fenêtre 0 et doit encore ses fenêtres de queue.
                print("  complete (every window): \(complete)")
                print("  first window only: \(max(0, vectors - complete))")
                print("  incomplete pages left: \(max(0, indexed - complete))")
                print("vectors (windows): \(windows)")
                if let model = meta["model_id"] {
                    print("model: \(model) r\(meta["revision"] ?? "?"), "
                          + "dim \(meta["dim"] ?? "?")")
                }
                if let chars = meta["win_chars"], let stride = meta["win_stride"],
                   let perPage = meta["win_max"] {
                    print("windows: up to \(perPage) per page, \(chars) char(s) "
                          + "every \(stride)")
                }
                // FIN DE CAMPAGNE EN HEURES, depuis le débit RÉEL de la
                // dernière passe (idée 7 de l'audit A1m). « il reste 28 h » se
                // comprend, « il reste 385 626 pages » non. Aucune passe n'a
                // encore tourné ? On dit le geste plutôt qu'un chiffre inventé.
                let forecast = try store.embedForecast()
                print(String(format: "windows per page (measured here): %.2f",
                             forecast.windowsPerPage))
                if let hours = forecast.remainingHours,
                   let rate = forecast.windowsPerSecond {
                    let done = ISO8601DateFormatter()
                    let when = Date().addingTimeInterval(hours * 3600)
                    print(String(format:
                        "remaining: ~%.0f window(s) at %.2f win/s (last run) "
                        + "-> ~%.1f h, done around %@",
                        forecast.remainingWindows, rate, hours,
                        done.string(from: when)))
                    if let at = forecast.measuredAt {
                        print("  (throughput measured on the run of "
                              + "\(ISO8601DateFormatter().string(from: at)))")
                    }
                } else if forecast.incompletePages == 0 {
                    print("remaining: nothing — every indexed page is complete")
                } else {
                    print("remaining: ~\(Int(forecast.remainingWindows.rounded())) "
                          + "window(s); no throughput measured yet — run "
                          + "`fouine embed` once and this line will give hours")
                }
                return
            }

            var config = EmbedRun.Config()
            config.batchSize = max(1, batch)
            config.budgetMinutes = budgetMinutes
            // LES DOSSIERS (lot MC3, constat PM-05), AVANT LE MODÈLE. `--folder`
            // restreint toute la campagne ; sans lui, les racines épinglées
            // passent devant et le reste suit. Une étiquette inconnue est
            // refusée en 64 avec les vraies (règle de `FolderCheck`) : sans ce
            // refus, `--folder M2SUU` aurait produit une campagne qui ne fait
            // rien, en sortie 0. Le refus est décidé ICI plutôt qu'après le
            // chargement du modèle : une faute de frappe ne doit pas coûter
            // 220 Mo et deux secondes et demie avant d'être dite.
            let snapshot = SettingsSnapshot.load(from: store).snapshot
            if !folder.isEmpty {
                config.onlyFolders = try FolderCheck.resolve(
                    folder, known: try store.roots().map(\.label))
            } else {
                config.priorityFolders = EmbedRun.pinnedFolderLabels(
                    store: store, settings: snapshot)
            }
            // Les tableurs, sauf demande contraire (constat PM-09). Le réglage
            // gouverne la campagne de l'agent comme celle de la main ;
            // `--include-tables` le désarme pour CETTE campagne seulement.
            if includeTables || !snapshot.embedSkipSpreadsheets {
                config.skipExtensions = []
            }

            let dir = modelDir.map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath,
                    isDirectory: true)
            } ?? EmbedPaths.modelDirectory()
            let engine = try E5Encoder(modelDir: dir)

            // Annulation (audit F6) : une campagne dure treize heures. Sans
            // gestionnaire, un Ctrl-C tuait le processus au milieu d'un lot —
            // les vecteurs déjà inférés étaient perdus et la dernière ligne du
            // journal restait dans le tampon de la libc. SIGINT, SIGTERM et
            // SIGHUP demandent maintenant l'arrêt : la pompe finit son lot,
            // écrit son tampon, journalise son résumé et sort en 0.
            let stop = installStopHandlers(log: { CLI.warn($0) })
            defer { stop.sources.forEach { $0.cancel() } }
            let summary = try EmbedRun.run(store: store, engine: engine,
                                           config: config,
                                           shouldStop: { stop.flag.isRequested })
            if summary.interrupted {
                CLI.warn("stop requested — \(summary.remaining) page(s) still "
                         + "need vectors, `fouine embed` will pick up here")
            }
            fflush(stdout)
        }
        // Le verrou de campagne vit aussi longtemps que cette variable.
        campaign?.release()
    }

    /// Le refus, quand c'est la mise à jour automatique qui prépare le sens.
    /// `nil` si ce n'est pas elle (ou qu'on n'en sait rien) : on ne nomme
    /// jamais un détenteur qu'on n'a pas identifié.
    static func agentHolderMessage(_ busy: EmbedCampaignLock.Busy) -> String? {
        guard let holder = busy.holder,
              let store = try? CLI.openStoreReadOnly(),
              let status = try? store.agentStatus(),
              status.pid == holder.pid, !status.isStale else { return nil }
        return "the background agent is preparing meaning — it will stop by "
            + "itself; or turn the setting off "
            + "(`fouine config set agent.prepareMeaning false`)"
    }

    /// Détourne SIGINT, SIGTERM et SIGHUP vers un drapeau d'arrêt. Même montage
    /// que l'agent (`FouineAgent/main.swift`) : `SIG_IGN` neutralise l'action
    /// par défaut, un `DispatchSource` hors du fil principal reçoit le signal —
    /// le fil principal, lui, est occupé à inférer.
    ///
    /// SIGHUP est le troisième, et il manquait. C'est le signal que reçoit un
    /// processus dont le TERMINAL se ferme : une campagne de treize heures
    /// lancée depuis une fenêtre de Terminal mourait alors sans un mot — action
    /// par défaut, pas de résumé, tampon de vecteurs perdu, et un journal qui
    /// s'arrête au milieu d'une ligne sans qu'on sache si c'est un plantage.
    /// Le signal reçu est désormais JOURNALISÉ, pour la même raison : un arrêt
    /// dont on ne connaît pas la cause coûte une heure de diagnostic.
    ///
    /// (Pour une campagne qui doit survivre à la fermeture du terminal, le
    /// geste reste `nohup fouine embed …` ou un `caffeinate -i`.)
    private func installStopHandlers(log: @escaping @Sendable (String) -> Void)
        -> (flag: StopFlag, sources: [any DispatchSourceSignal]) {
        let flag = StopFlag()
        let wanted: [(number: Int32, name: String)] = [
            (SIGINT, "SIGINT"), (SIGTERM, "SIGTERM"), (SIGHUP, "SIGHUP"),
        ]
        for entry in wanted { signal(entry.number, SIG_IGN) }
        let sources = wanted.map { entry -> any DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(
                signal: entry.number, queue: .global(qos: .utility))
            source.setEventHandler {
                log("received \(entry.name) — finishing the batch and writing "
                    + "the buffer")
                flag.request()
            }
            source.resume()
            return source
        }
        return (flag, sources)
    }

    /// Inférence pure (ni base ni verrou) : mesure le débit du modèle sur cette
    /// machine, pour dimensionner la campagne et comparer FOUINE_EMBED_COMPUTE.
    private func runBench(pages: Int) throws {
        let dir = modelDir.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath,
                isDirectory: true)
        } ?? EmbedPaths.modelDirectory()
        let engine = try E5Encoder(modelDir: dir)
        // La RÉPARTITION du chargement, pas seulement son total (audit
        // A1m-15) : lire le vocabulaire et faire ouvrir le réseau par CoreML
        // sont deux postes très différents, et un seul des deux se répare.
        print(String(format:
            "load: vocabulary %.0f ms + CoreML %.0f ms = %.0f ms",
            engine.loadTimings.vocabularyMS, engine.loadTimings.modelMS,
            engine.loadTimings.totalMS))
        // Le texte du banc d'essai reste FRANÇAIS : c'est une donnée de
        // mesure, pas un message. Le modèle est multilingue, et changer le
        // texte changerait les chiffres publiés dans docs/search.md.
        let sample = String(repeating:
            "L'énergie libre de Gibbs gouverne la spontanéité des transformations "
            + "chimiques à température et pression constantes, tandis que la "
            + "cinétique fixe la vitesse à laquelle l'équilibre est atteint. ",
            count: 7)
        let texts = (0..<pages).map { "\(sample) [page \($0)]" }
        _ = try engine.embedPassages([texts[0]])          // chauffe
        let start = Date()
        var done = 0
        while done < pages {
            let slice = Array(texts[done..<min(done + max(1, batch), pages)])
            _ = try engine.embedPassages(slice)
            done += slice.count
        }
        let dt = Date().timeIntervalSince(start)
        let compute = ProcessInfo.processInfo
            .environment["FOUINE_EMBED_COMPUTE"] ?? "all"
        // PLUS DE PROJECTION SUR UN CORPUS IMAGINAIRE (idée 7 de l'audit A1m).
        // Le banc annonçait « 379 267 pages ~ N h » : ce nombre était celui du
        // corpus de recette, codé en dur, et il ne disait rien du corpus de qui
        // lance la commande. Le banc mesure un DÉBIT, sans ouvrir la base ;
        // c'est `fouine embed --status` qui projette, sur les pages réelles et
        // le débit de la dernière passe.
        let rate = Double(pages) / dt
        // Entiers par interpolation (CM-05) : `%d` de `String(format:)` lit
        // 32 bits, et le dépôt n'en garde aucun sur un `Int`.
        print("bench: \(pages) window(s) in "
              + String(format: "%.1f s -> %.2f win/s", dt, rate)
              + " (compute \(compute), batch \(batch)); "
              + String(format: "1000 pages ~ %.1f min at 2.13 window(s) per page",
                       1000 * 2.13 / rate / 60))
        print("(`fouine embed --status` projects the END of the campaign on "
              + "YOUR corpus, from the throughput of the last run.)")
    }
}
