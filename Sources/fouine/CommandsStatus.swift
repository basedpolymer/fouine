// CommandsStatus.swift — `fouine status` et `fouine doctor` (SPEC §4.3, §7.1).
// Propriété : A-Core.

import Foundation
import ArgumentParser
import FouineCore
import FouineExtract
import FouineEmbed

// MARK: - fouine status

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "State of the index and of the roots.")

    @Flag(name: .long, help: "JSON output.") var json = false

    @Flag(name: .long,
          help: "List the documents Fouine could not read: path, extension, reason.")
    var unreadable = false

    /// Au-delà, la liste ne se lit plus dans un terminal — et le compte total
    /// est déjà sur la ligne `documents`. Le reste se lit par `--json`.
    static let unreadableLimit = 500

    func run() {
        CLI.guarded {
            let store = try CLI.openStoreReadOnly()
            let stats = try store.stats()
            // Documents dont la langue reste à déterminer (lot U3, R-10) : le
            // rattrapage se fait tout seul, 300 documents par passe, et c'est
            // le seul endroit qui dit combien il en reste. Hors de `stats()`
            // pour ne pas alourdir un appel que l'app fait en boucle.
            let withoutLanguage = try store.documentsWithoutLanguageCount()
            let reports = try store.roots().map(RootReport.init)
            // Réglages effectifs et état de l'agent (audit U2, F7). Sans eux,
            // `status` décrivait une base sans jamais dire avec quels réglages
            // elle est tenue à jour, ni par qui — « l'agent est une boîte
            // noire », et le seul diagnostic était `tail -f` du journal.
            let settings = SettingsSnapshot(rows: try store.settingsRows())
            let agent = try store.agentStatus()
            // « Ma campagne tourne-t-elle encore ? » (constat C2-11). Le verrou
            // d'écriture ne répond pas à cette question — `embed` le rend après
            // chaque lot —, celui de campagne si. Sonde pure : ni création, ni
            // attente, `status` reste une lecture.
            let campaign = store.databaseURL
                .flatMap { EmbedCampaignLock.probe(databaseURL: $0) }
            // Le verrou d'écriture, SONDÉ (constat CM-26) : `doctor` et l'outil
            // MCP `fouine_status` publiaient l'objet, `status --json` non —
            // deux contrats, deux réponses à la même question. Sonde pure,
            // `status` reste une lecture.
            let lockStatus = WriteLock.inspect(path: Self.lockPath(of: store))
            // C2-14 : « quel fichier n'a pas été lu ? » n'avait aucune réponse
            // en ligne de commande — le cœur sait (il sert l'app et le serveur
            // MCP), la CLI ne demandait pas. Lu SEULEMENT sur demande : c'est
            // une lecture de plus sur `docs`.
            let unreadableRows = unreadable
                ? try store.unreadableDocuments(limit: Self.unreadableLimit)
                : []

            let dbBytes = stats["db_bytes"] ?? 0
            let pagesIndexed = stats["pages_indexed"] ?? 0
            let bytesPerPage = pagesIndexed > 0 ? (dbBytes / pagesIndexed) : 0
            // Le budget disque (MO-03), projeté À COUVERTURE SÉMANTIQUE PLEINE
            // et non à l'état du jour : c'est la seule échéance qui intéresse.
            let forecast = Self.diskForecast(stats: stats)

            if json {
                var payload: [String: Any] = [:]
                // Les clés du contrat §4.3 d'abord, INCHANGÉES : `settings` et
                // `agent` s'ajoutent, ils ne remplacent rien.
                for (k, v) in stats { payload[k] = v }
                payload["bytes_per_page"] = bytesPerPage
                // Clé ADDITIVE (MO-03) : ce que la base pèse, ce qu'elle
                // pèsera à couverture sémantique pleine, et où le budget
                // tombe. Rien ne s'arrête à 100 % — `level` est un
                // avertissement, pas un état de panne.
                payload["disk_budget"] = Self.diskBudgetJSON(forecast)
                // `db_path` (audit A1m-14) : la sortie TEXTE affichait déjà le
                // chemin, le JSON non — un script qui enchaîne `status` devait
                // appeler `doctor` pour savoir sur quel index il travaille.
                // Clé additive, comme `doctor --json` la porte déjà.
                payload["db_path"] = store.databaseURL?.path ?? ""
                payload["docs_without_language"] = withoutLanguage
                // Clé AJOUTÉE (C2-11) : `null` quand aucune campagne ne tourne.
                payload["semantic_campaign"] = campaign
                    .map { ["pid": Int($0.pid), "since": $0.isoText] as [String: Any] }
                    ?? NSNull()
                // `write_lock` a EXACTEMENT la forme de celui de `doctor`
                // (CM-26) : même constructeur, aucune divergence possible.
                payload["write_lock"] = Self.writeLockJSON(lockStatus)
                // Clé ADDITIVE (AG1) : ce que la mise à jour automatique fait
                // de la recherche par le sens, et où elle en est.
                payload["meaning_background"] = Self.meaningJSON(settings: settings,
                                                                stats: stats)
                payload["roots"] = reports.map(\.json)
                payload["settings"] = settings.table().map(ConfigCommand.json)
                payload["agent"] = Self.agentJSON(agent)
                // Publiées SEULEMENT avec `--unreadable` : sans l'option, la
                // sortie de `status` est celle d'avant, à `write_lock` près.
                if unreadable {
                    let total = (stats["docs_failed"] ?? 0) + (stats["docs_skipped"] ?? 0)
                    payload["unreadable"] = unreadableRows.map(Self.unreadableJSON)
                    payload["unreadable_total"] = total
                }
                try CLI.printJSON(payload)
                return
            }
            for warning in settings.warnings { CLI.warn(warning) }

            print("documents   total \(stats["docs_total"] ?? 0) · "
                  + "extracted \(stats["docs_extracted"] ?? 0) · "
                  + "failed \(stats["docs_failed"] ?? 0) · "
                  + "skipped \(stats["docs_skipped"] ?? 0) · "
                  + "language unknown \(withoutLanguage)")
            print("pages       indexed \(stats["pages_indexed"] ?? 0) · "
                  + "native \(stats["pages_native"] ?? 0) · "
                  + "ocr_accurate \(stats["pages_ocr_accurate"] ?? 0)")
            // Deux populations distinctes (audit A6) : une page sans aucune ligne
            // reconnue n'est pas une page « peu sûre », c'est une page à re-rendre.
            print("OCR pages   doubtful \(stats["pages_ocr_low_conf"] ?? 0) "
                  + "(0 < conf < \(GRDBStore.doubtfulConfidenceThreshold)) · "
                  + "no recognised line \(stats["pages_ocr_no_lines"] ?? 0)")
            print("OCR queue   \(stats["ocr_queue_len"] ?? 0) page(s)")
            // DEUX nombres depuis le fenêtrage (schéma v5) : une page porte
            // jusqu'à trois vecteurs, et « 1,1 M de vecteurs » sur 390 000
            // pages se lirait comme une couverture de 280 %.
            print("vectors     \(stats["pages_vec"] ?? 0) page(s) vectorised, "
                  + "\(stats["vectors_vec"] ?? 0) vector(s) "
                  + "(\(stats["pages_vec_complete"] ?? 0) page(s) complete — "
                  + "hybrid search, `fouine embed`)")
            if let campaign {
                print("vectorisation: running (pid \(campaign.pid), "
                      + "since \(campaign.clockText))")
            }
            // La préparation du sens confiée à la mise à jour automatique
            // (lot AG1, PR-21) : sans cette ligne, rien en ligne de commande
            // ne disait qui doit finir la campagne, ni si elle avance.
            print("meaning     " + Self.meaningLine(settings: settings, stats: stats))

            var dbLine = "database    \(dbBytes) bytes"
            if bytesPerPage > 0 {
                // La projection « 1 M / 4 M pages » (MO-03) était une règle de
                // trois LINÉAIRE depuis l'état COURANT : elle annonçait
                // « 4,9 GiB at 1 M » sur une base dont la campagne sémantique
                // n'était qu'aux deux tiers — donc optimiste à court terme —
                // et personne n'a un million de pages. Ce qui se joue est
                // l'échéance du budget de la SPEC sur le corpus RÉEL.
                dbLine += " (" + Self.diskBudgetLine(forecast,
                                                     bytesPerPage: bytesPerPage) + ")"
            }
            dbLine += " — " + (store.databaseURL?.path ?? "?")
            print(dbLine)
            print("agent       \(Self.agentLine(agent))")
            print("roots:")
            let pinned = settings.pinnedRoots
            for r in reports {
                print("  [\(r.root.id)] \(r.root.label)  \(r.path)"
                      + (pinned.contains(r.root.id) ? "  ★ first for OCR" : ""))
                print("        enabled=\(r.root.enabled) mounted=\(r.mounted) "
                      + "readable=\(r.readable)"
                      + (r.reasonText.map { "  (\($0))" } ?? ""))
            }
            print("effective settings (`fouine config list` for the details):")
            for entry in settings.table() {
                print("  " + ConfigCommand.describe(entry))
            }
            if unreadable {
                let total = (stats["docs_failed"] ?? 0) + (stats["docs_skipped"] ?? 0)
                print("documents not read (\(total)):")
                if unreadableRows.isEmpty { print("  none") }
                for row in unreadableRows {
                    print("  \(row.relPath) · \(row.ext) · \(Self.unreadableReason(row))")
                }
                if total > unreadableRows.count {
                    print("  … and \(total - unreadableRows.count) more "
                          + "(`fouine status --unreadable --json` lists them all)")
                }
            }
        }
    }

    // MARK: - Préparation du sens en arrière-plan (constat PR-21, lot AG1)

    /// Pages indexées qui n'ont pas encore toutes leurs fenêtres. Le calcul vit
    /// dans `StatusJSON` (FouineCore) depuis le lot MC4 : `fouine_status` le
    /// publie aussi, et deux calculs du même chiffre finiraient par diverger.
    static func meaningPagesLeft(_ stats: [String: Int]) -> Int {
        StatusJSON.meaningPagesLeft(stats)
    }

    /// « background: on (10 min batches) · last batch 2026-09-11T09:12:03Z ·
    /// 118302 page(s) left ».
    static func meaningLine(settings: SettingsSnapshot,
                            stats: [String: Int]) -> String {
        var parts: [String] = []
        parts.append(settings.agentPrepareMeaning
                     ? "background: on (\(settings.agentEmbedBudgetMinutes) min batches)"
                     : "background: off (agent.prepareMeaning)")
        let at = settings.agentLastEmbedBatchAt
        if at > 0 {
            let date = Date(timeIntervalSince1970: at)
            parts.append("last batch " + ISO8601DateFormatter().string(from: date))
        } else if settings.agentPrepareMeaning {
            parts.append("no batch yet")
        }
        let left = meaningPagesLeft(stats)
        parts.append(left == 0 ? "every indexed page is ready"
                               : "\(left) page(s) left")
        return parts.joined(separator: " · ")
    }

    /// L'objet `meaning_background`, le MÊME dans `status --json`,
    /// `doctor --json` et `fouine_status` (lot MC4).
    static func meaningJSON(settings: SettingsSnapshot,
                            stats: [String: Int]) -> [String: Any] {
        StatusJSON.meaningJSON(settings: settings, stats: stats)
    }

    // MARK: - Budget disque (constat MO-03)

    /// La projection du budget pour CETTE base. `status` et `doctor` la lisent
    /// ici tous les deux : deux calculs du même chiffre finiraient par ne plus
    /// dire la même chose.
    ///
    /// AUCUNE LECTURE NOUVELLE : les trois nombres viennent de `stats()`, que
    /// les deux commandes appellent déjà. La géométrie des fenêtres reste la
    /// CONSTANTE du corpus de production (2,13) : la mesurer sur cette base
    /// (`embedForecast`) coûte 1,5 s sur la base de production du 09/09/2026
    /// — mesuré, `status --json` passe de 1,66 s à 3,19 s, médiane de trois
    /// passes interleavées — parce que c'est un balayage de `page_vec` avec
    /// sous-requête `EXISTS` sur 764 872 lignes. Ce que la mesure gagnerait :
    /// moins de 5 % sur la projection (les vecteurs qui manquent pèsent ~5 %
    /// de la base), donc aucun seuil.
    static func diskForecast(stats: [String: Int]) -> DiskForecast {
        StatusJSON.diskForecast(stats: stats)
    }

    /// Le contenu des parenthèses de la ligne `database`.
    static func diskBudgetLine(_ f: DiskForecast, bytesPerPage: Int) -> String {
        var parts = [humanBytes(f.bytes),
                     String(format: "%.1f KiB/page", Double(bytesPerPage) / 1024.0)]
        parts.append("at full meaning coverage ~\(humanBytes(f.bytesAtFullVectors)) "
                     + "(\(percent(f.ratioAtFullVectors)) of the "
                     + "\(humanBytes(f.budgetBytes)) budget)")
        if let pages = f.pagesAtBudget {
            // Arrondi au millier : « 450 823 pages » se lirait comme une
            // échéance calculée au document près, ce qu'elle n'est pas.
            parts.append("budget reached near \(thousands(pages)) pages")
        }
        return parts.joined(separator: " · ")
    }

    /// L'objet `disk_budget`, le MÊME dans `status --json`, `doctor --json` et
    /// `fouine_status` (lot MC4).
    static func diskBudgetJSON(_ f: DiskForecast) -> [String: Any] {
        StatusJSON.diskBudgetJSON(f)
    }

    /// La ligne de `doctor`, ou `nil` quand il n'y a rien à dire. Le geste est
    /// dedans : dire « 91 % » sans dire quoi faire ne renseigne personne, et
    /// dire « ça va s'arrêter » serait faux — rien ne s'arrête (décision du
    /// 09/09/2026, n° 3).
    static func diskBudgetDoctorLine(_ f: DiskForecast) -> String? {
        guard f.warns else { return nil }
        return "\(percent(f.ratioOfBudgetNow)) now, "
            + "\(percent(f.ratioAtFullVectors)) at full meaning coverage of the "
            + "\(humanBytes(f.budgetBytes)) budget — nothing stops at 100 %; "
            + "free space with `fouine maintain --vacuum`, or remove folders "
            + "you no longer need"
    }

    /// Des octets décimaux (10³), comme le budget de la SPEC et comme le
    /// Finder. Le zéro final tombe : le budget s'écrit « 2.5 GB », pas
    /// « 2.50 GB » — et une base de recette « 0.3 MB », pas « 0.0 GB ».
    static func humanBytes(_ bytes: Int) -> String {
        let value = Double(bytes)
        if value < 1e6 { return String(format: "%.0f kB", value / 1e3) }
        if value < 1e9 { return String(format: "%.1f MB", value / 1e6) }
        var text = String(format: "%.2f", value / 1e9)
        if text.hasSuffix("0") { text.removeLast() }
        return text + " GB"
    }

    static func percent(_ ratio: Double) -> String {
        String(format: "%.0f %%", ratio * 100.0)
    }

    /// Un compte arrondi au millier LE PLUS PROCHE, avec séparateurs :
    /// « 451,000 ». Tronquer ferait dire « 450,000 » pour 450 823, ce qui est
    /// une échéance plus proche que la réalité.
    static func thousands(_ value: Int) -> String {
        let rounded = Int((Double(value) / 1_000).rounded()) * 1_000
        let fmt = NumberFormatter()
        // `en_US`, pas `en_US_POSIX` : ce dernier ne groupe pas les milliers,
        // et « 451000 » se relit deux fois.
        fmt.locale = Locale(identifier: "en_US")
        fmt.numberStyle = .decimal
        return fmt.string(from: NSNumber(value: rounded)) ?? String(rounded)
    }

    // MARK: - Documents non lus (constat C2-14)

    /// Le motif, en une phrase. `err` porte ce que l'extraction a rendu ; un
    /// document `skipped` sans motif est un format que Fouine ne lit pas —
    /// « skipped » tout court ne l'apprendrait à personne.
    static func unreadableReason(_ row: DocumentListing) -> String {
        if let err = row.err, !err.isEmpty { return err }
        switch row.state {
        case .skipped: return "skipped (no extractor for this format)"
        case .failed:  return "failed (no reason recorded)"
        default:       return unreadableState(row.state)
        }
    }

    /// Le MÊME vocabulaire que l'outil MCP `fouine_list_documents`
    /// (`ToolSupport.state`) : deux mots pour le même état obligeraient à
    /// traduire d'une surface à l'autre.
    static func unreadableState(_ state: DocState) -> String {
        switch state {
        case .discovered: return "pending"
        case .extracted:  return "indexed"
        case .failed:     return "failed"
        case .skipped:    return "skipped"
        }
    }

    static func unreadableJSON(_ row: DocumentListing) -> [String: Any] {
        [
            "doc_id": row.id,
            "path": row.relPath,
            "ext": row.ext,
            "reason": unreadableReason(row),
            "status": unreadableState(row.state),
        ]
    }

    // MARK: - Verrou d'écriture, une seule forme (constat CM-26)

    /// Le chemin du verrou de la base ouverte. `doctor` et `status` le
    /// calculaient chacun de leur côté ; ils le lisent désormais ici.
    static func lockPath(of store: GRDBStore) -> String {
        store.databaseURL.map { FouinePaths.lockURL(for: $0).path }
            ?? FouinePaths.lockURL().path
    }

    /// L'objet `write_lock`, IDENTIQUE dans `status --json` et `doctor --json`
    /// (et de même forme que celui du serveur MCP) : `{status, held, probe}` et,
    /// quand quelqu'un est nommé, `role`, `pid`, `since`.
    ///
    /// `probe` est le FAIT (audit A1m-03) : ce que le `flock` a répondu, et non
    /// ce que le fichier raconte. `status` garde ses trois valeurs pour ne pas
    /// rompre le contrat.
    static func writeLockJSON(_ lockStatus: WriteLock.LockStatus) -> [String: Any] {
        var object: [String: Any] = [
            "status": {
                switch lockStatus {
                case .free:  return "free"
                case .held:  return "held"
                case .stale: return "stale"
                }
            }(),
            "held": {
                if case .held = lockStatus { return true }
                return false
            }(),
            "probe": lockStatus.isFree ? "free" : "held",
        ]
        let holder: LockHolder?
        switch lockStatus {
        case .held(let h):  holder = h
        case .stale(let h): holder = h
        case .free:         holder = nil
        }
        if let holder {
            object["role"] = holder.role.rawValue
            object["pid"] = Int(holder.pid)
            object["since"] = ISO8601DateFormatter().string(from: holder.since)
        }
        return object
    }

    // MARK: - État de l'agent (audit F7)

    /// La ligne d'état de l'agent, en clair.
    ///
    /// Trois cas, et la distinction compte : jamais vu (aucun agent n'a jamais
    /// tourné sur cette base), périmé (le processus a disparu ou n'écrit plus
    /// depuis cinq minutes — c'est un agent MORT, pas un agent au repos), et
    /// vivant, avec sa phase et sa progression.
    static func agentLine(_ status: AgentStatusRecord?) -> String {
        guard let status else {
            return "no report published yet — run `fouine doctor` to check background agent status"
        }
        var parts = [status.phase.english]
        // Le `detail` est un JETON sans langue (`AgentStatusDetail`) : la CLI le
        // rend en ANGLAIS. Elle l'imprimait tel quel, ce qui affichait
        // « SIGTERM reçu » — du français au milieu d'une sortie anglaise
        // contractuelle — dès qu'un agent d'une version antérieure l'avait
        // écrit (audit A1m-10). Un jeton inconnu passe tel quel.
        if !status.detail.isEmpty {
            parts.append(AgentStatusDetail.english(status.detail))
        }
        if status.total > 0 { parts.append("\(status.done)/\(status.total)") }
        if let age = status.age {
            parts.append(String(format: "updated %.0f s ago", age))
        }
        parts.append("pid \(status.pid)")
        if status.isStale {
            parts.append(status.isAlive
                         ? "STALE STATUS (no write for 5 min)"
                         : "PROCESS GONE — agent stopped")
        }
        return parts.joined(separator: " · ")
    }

    static func agentJSON(_ status: AgentStatusRecord?) -> [String: Any] {
        guard let status else {
            return [
                "known": false,
                "report_published": false,
            ]
        }
        var object: [String: Any] = [
            "known": true,
            "report_published": true,
            "phase": status.phase.rawValue,
            // `detail` reste la valeur STOCKÉE — un jeton, qu'un script peut
            // comparer sans lire une phrase —, et `detail_text` en donne la
            // lecture anglaise. Clé additive : le contrat §4.3 n'interdit pas
            // les ajouts (audit A1m-10).
            "detail": status.detail,
            "detail_text": AgentStatusDetail.english(status.detail),
            "done": status.done,
            "total": status.total,
            "pid": Int(status.pid),
            "alive": status.isAlive,
            "stale": status.isStale,
        ]
        if let age = status.age { object["age_seconds"] = Int(age) }
        return object
    }
}

// MARK: - fouine doctor

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnosis: volumes, EFFECTIVE read of the roots, OCR queue.")

    @Flag(name: .long, help: "JSON output.") var json = false
    @Flag(name: .long, help: "Deep database integrity check.") var deep = false

    /// L'objet `background_agent`, augmenté de ce que la BASE sait (CM-12).
    ///
    /// `ok` ne bouge PAS : la décision de l'audit est que le silence est un
    /// défaut à dire, pas un verdict de panne — un Mac éteint trois jours n'a
    /// rien de cassé. Les trois clés sont ADDITIVES, `log_last_line` est
    /// toujours présente (`null` sans journal) pour qu'un script n'ait pas à
    /// distinguer « absente » de « pas de journal ».
    static func backgroundAgentJSON(_ report: BackgroundAgentReport,
                                    idle: AgentIdle.Report?,
                                    logLastLine: String?) -> [String: Any] {
        var object = report.json
        if let idle {
            object["last_run"] = idle.iso
            object["idle_seconds"] = idle.idleSeconds
            object["guidance"] = idle.guidance
        }
        object["log_last_line"] = logLastLine.map { $0 as Any } ?? NSNull()
        return object
    }

    /// Geste à faire quand djvused manque. `DjvuExtractor.overrideVariable`
    /// dépanne une installation hors des trois répertoires standard.
    static let djvuGuidance =
        "djvulibre is missing — `brew install djvulibre` (.djvu files stay "
        + "“skipped” without it; the \(DjvuExtractor.overrideVariable) variable "
        + "points at a djvused installed elsewhere)"

    func run() {
        CLI.guarded {
            // `--deep` ÉCRIT : l'`integrity-check` FTS5 est un `INSERT` et il
            // tient le verrou nommé. C'est la seule branche de `doctor` qui
            // ouvre en écriture — et elle refuse quand même une base absente
            // (audit A1m-09), sans quoi le diagnostic fabriquerait l'index
            // qu'il prétend diagnostiquer.
            let store = deep ? try CLI.openExistingStoreForWriting()
                             : try CLI.openStoreReadOnly()
            let stats = try store.stats()
            let reports = try store.roots().map(RootReport.init)
            let context = "CLI — inherits the permissions of the terminal that "
                + "runs it (the SMAppService agent, for its part, can show no "
                + "privacy prompt at all)"
            let failing = reports.filter { !$0.readable }
            // djvulibre est le SEUL outil externe non système du produit, et le
            // seul dont l'absence se voit à l'index sans se voir nulle part
            // ailleurs : les .djvu passent `skipped` en silence (audit D8).
            // Cherché par chemins explicites, donc la réponse de doctor vaut
            // aussi pour l'app et pour l'agent, PATH minimal compris.
            let djvused = DjvuExtractor.tool()
            // Le modèle sémantique manque en silence, exactement comme djvulibre :
            // sans lui `fouine embed` refuse de partir et `--hybrid` retombe sur
            // la recherche plein texte, sans qu'aucune commande ne dise pourquoi
            // (audit D6). `doctor` le dit, et donne le geste.
            let model = ModelDownloader.status()
            // Les réglages, pour la ligne `meaning` (AG1) : une lecture de la
            // table `settings`, la même que celle de `fouine status`.
            let settings = SettingsSnapshot(rows: try store.settingsRows())

            // L'agent d'arrière-plan (audit B1-05) : croisement launchctl + agent_status.
            let agentReport = LaunchdAgentProbe.evaluate(store: store)
            // CE QUE LA BASE SAIT, ET QUE LAUNCHD NE DIT PAS (constat CM-12).
            // `not registered` décrit le service ; il ne dit pas que l'index
            // n'a rien avalé depuis trois jours. `fouine status` le disait,
            // `doctor` — « le premier geste, toujours » — non.
            let running: Bool
            if case .running = agentReport.diagnosis { running = true } else { running = false }
            let idle = AgentIdle.describe(status: agentReport.agentStatus,
                                          running: running)
            // La dernière ligne du journal : le seul endroit où un incident
            // (racine illisible, OCR en échec) se voit.
            let logLine = AgentIdle.lastLogLine(at: FouinePaths.agentLogURL())

            // Les copies de Fouine.app connues de LaunchServices (lot J2). Une
            // copie parasite de numéro de build supérieur — celle que
            // `make ci-bundle` laissait à la racine du dépôt — devient la copie
            // « par défaut » et fait échouer l'agent armé depuis /Applications
            // en EX_CONFIG, sans que rien ne le dise. C'est LA cause qu'il
            // fallait deviner à la main le 03/09/2026.
            let copiesReport = AppCopiesLookup.report()

            // État du verrou d'écriture (audit H4).
            let lockStatus = WriteLock.inspect(path: StatusCommand.lockPath(of: store))

            // Le budget disque (MO-03), pour la ligne d'avertissement et pour
            // le JSON. Même calcul que `status`, même objet.
            let forecast = StatusCommand.diskForecast(stats: stats)

            var deepReport: DeepCheckReport?
            if deep {
                let dbBytes = stats["db_bytes"] ?? 0
                let mb = max(1, Int(round(Double(dbBytes) / (1024.0 * 1024.0))))
                // Calibré sur la base de production réelle de 1,8 Go : ~0,12 s/Mo (quick_check + intégrité FTS5)
                let expectedSeconds = max(3, Int(round(Double(mb) * 0.12)))
                if !json {
                    print("deep check: reading \(mb) MB, this can take ~\(expectedSeconds) s "
                          + "(the FTS5 check holds the write lock: other writers see the database as locked)")
                }
                // Chaque étape s'annonce EN COMMENÇANT (MO-04) : 86 s mesurées
                // sur 2,2 Go, dont l'essentiel dans l'`integrity-check` FTS5 —
                // sans cela, rien ne distingue un contrôle qui travaille d'un
                // contrôle bloqué. Muet en `--json` : une ligne de progression
                // au milieu de l'objet le rendrait illisible à un script.
                deepReport = try store.deepCheck(onStep: json ? nil : { name in
                    print("  \(name)…")
                })
            }

            if json {
                var payload: [String: Any] = [
                    "context": context,
                    "ocr_queue_len": stats["ocr_queue_len"] ?? 0,
                    "db_bytes": stats["db_bytes"] ?? 0,
                    "db_path": store.databaseURL?.path ?? "",
                    // Le MÊME constructeur que `status --json` (CM-26) : les
                    // deux commandes ne peuvent plus décrire le verrou
                    // différemment.
                    "write_lock": StatusCommand.writeLockJSON(lockStatus),
                    // La sonde est câblée depuis l'intégration de la vague 1
                    // (`makeExtractorRegistry` rend un DefaultExtractorRegistry,
                    // inconditionnellement) : la clé reste au contrat de sortie,
                    // sa valeur n'a plus de branche « après câblage » (audit A12).
                    "extraction_probe": "available",
                    "djvused": djvused ?? "",
                    // Le MÊME objet que `status --json` (AG1).
                    "meaning_background": StatusCommand.meaningJSON(
                        settings: settings, stats: stats),
                    "semantic_model": model.installed,
                    "semantic_model_path": model.directory.path,
                    "semantic_model_vectors": stats["vectors_vec"] ?? 0,
                    "background_agent": Self.backgroundAgentJSON(
                        agentReport, idle: idle, logLastLine: logLine),
                    // Contrat J2 : `app_copies` est TOUJOURS un tableau (vide
                    // si l'app n'est pas installée), `app_default` un chemin ou
                    // `null` — jamais une clé absente, un lecteur JSON ne doit
                    // pas avoir à distinguer les deux.
                    "app_copies": copiesReport.copies,
                    "app_default": copiesReport.defaultCopy.map { $0 as Any } ?? NSNull(),
                    // Ce qui est POSÉ dans /Applications, quel que soit son
                    // identifiant (A2-03) : `app_copies` ne peut pas le dire,
                    // il ne connaît que l'identifiant courant. Toujours
                    // présent, `null` quand il n'y a rien là-bas.
                    "app_at_expected_path": copiesReport.atExpectedPath.map {
                        ["path": $0.path,
                         "identifier": $0.identifier.map { $0 as Any } ?? NSNull(),
                         "version": $0.version.map { $0 as Any } ?? NSNull()] as Any
                    } ?? NSNull(),
                    "roots": reports.map(\.json),
                    // Un verrou PÉRIMÉ (détenteur mort) n'invalide pas `ok` : il
                    // se répare seul à la prochaine écriture (`ExclusiveLock.stamp`
                    // reprend le verrou en le journalisant). Le dire — `status:
                    // "stale"` — oui ; en faire une panne, non (lot I1).
                    // `ok` tombe aussi sur une incohérence de `page_vec`
                    // (audit A1m-05) : une ligne au rowid d'un autre schéma
                    // fait rendre au canal sémantique une page réelle SANS
                    // rapport avec la requête — c'est une panne, pas une
                    // fragmentation. Le CODE DE SORTIE, lui, ne change pas :
                    // la réparation est un geste (`maintain --repair`), pas un
                    // échec de la commande qui la signale.
                    "ok": failing.isEmpty
                        && (deepReport == nil
                            || (deepReport!.quickCheck == "ok"
                                && deepReport!.ftsIntegrity == "ok"
                                && (deepReport!.vectors?.isClean ?? true)
                                // Un écart `docs`/`docs_fts` ne fausse AUCUN
                                // résultat : il prive seulement des documents
                                // du bonus de nom (D-R3). Signalé, jamais une
                                // panne — et `maintain --repair` le règle.
                                )),
                ]
                // Le budget disque, sous la MÊME forme que `status --json`
                // (MO-03). Toujours présent : un script de diagnostic n'a pas
                // à deviner si la clé manque parce que tout va bien.
                payload["disk_budget"] = StatusCommand.diskBudgetJSON(forecast)
                if let guidance = StatusCommand.diskBudgetDoctorLine(forecast) {
                    payload["disk_budget_guidance"] = guidance
                }
                if let deepReport {
                    payload["database"] = deepReport.json
                }
                if let revision = model.revision {
                    payload["semantic_model_revision"] = revision
                }
                if !model.installed { payload["semantic_model_guidance"] = ModelText.doctorAbsent }
                if let guidance = copiesReport.guidance { payload["app_copies_guidance"] = guidance }
                if djvused == nil { payload["djvulibre_guidance"] = Self.djvuGuidance }
                // Le geste TCC n'a de sens que pour un REFUS de lecture ; un
                // dossier disparu n'en est pas un (observation 5 de la recette).
                if failing.contains(where: { $0.reason == .permissionDenied }) {
                    payload["tcc_guidance"] = RootProbe.tccGuidance
                }
                try CLI.printJSON(payload)
            } else {
                let lockText: String
                switch lockStatus {
                case .free:
                    lockText = "free"
                case .held(let holder):
                    let df = ISO8601DateFormatter()
                    lockText = "held by \(holder.role.rawValue) pid \(holder.pid) since \(df.string(from: holder.since))"
                case .stale(let holder):
                    let df = ISO8601DateFormatter()
                    lockText = "stale (held by \(holder.role.rawValue) pid \(holder.pid) since \(df.string(from: holder.since)))"
                }

                print("context tested : \(context)")
                print("database       : \(store.databaseURL?.path ?? "?") "
                      + "(\(stats["db_bytes"] ?? 0) bytes)")
                // RIEN quand tout va bien (MO-03) : un diagnostic qui parle du
                // budget à qui en est à 3 % n'apprend rien et inquiète.
                if let budget = StatusCommand.diskBudgetDoctorLine(forecast) {
                    print("disk budget    : \(budget)")
                }
                print("write lock     : \(lockText)")
                print("OCR queue      : \(stats["ocr_queue_len"] ?? 0) page(s)")
                print("text-layer probe : available")
                print("djvulibre      : "
                      + (djvused ?? "MISSING — \(Self.djvuGuidance)"))
                print("semantic model : "
                      + (model.installed
                         ? ModelText.doctorPresent(revision: model.revision ?? 0)
                         : ModelText.doctorAbsent))
                // La MÊME ligne que `status` (AG1) : deux commandes ne doivent
                // pas décrire différemment le même travail. Rien de plus, sauf
                // la contradiction qu'un dépanneur doit voir — le réglage est
                // armé et le modèle n'est pas là, donc rien ne se préparera
                // jamais, en silence.
                print("meaning        : "
                      + StatusCommand.meaningLine(settings: settings, stats: stats))
                if settings.agentPrepareMeaning, !model.installed {
                    print("  what to do: prepare meaning is on but the model is "
                          + "not installed — `fouine model download`")
                }
                var agentLine = agentReport.displayText
                if let idle { agentLine += " — " + idle.text }
                print("background agent : \(agentLine)")
                if let logLine { print("log            : \(logLine)") }
                print("application    : \(copiesReport.displayText)")
                if reports.isEmpty { print("no root registered") }
                for r in reports {
                    print("")
                    print("root [\(r.root.id)] \(r.root.label)")
                    print("  path    \(r.path)")
                    print("  volume  \(r.root.volUUID) — "
                          + (r.mounted ? "mounted" : "NOT MOUNTED"))
                    if r.readable {
                        print("  effective read of a file: OK")
                    } else {
                        print("  effective read of a file: FAILED — "
                              + (r.reasonText ?? "?"))
                        // Geste TCC UNIQUEMENT pour un refus de lecture
                        // (EPERM/EACCES) — jamais pour un dossier disparu
                        // (observation 5 de la recette, §7.1).
                        if r.reason == .permissionDenied {
                            print("  what to do: \(RootProbe.tccGuidance)")
                        }
                    }
                }
                if let deepReport {
                    print("")
                    print("database integrity check (--deep):")
                    print("  PRAGMA quick_check : \(deepReport.quickCheck)")
                    print("  FTS5 integrity     : \(deepReport.ftsIntegrity)")
                    print("  page count / size  : \(deepReport.pageCount) pages (\(deepReport.pageSize) bytes/page)")
                    let fragMo = Double(deepReport.fragmentationBytes) / (1024.0 * 1024.0)
                    // `%d` lit 32 bits (CM-05) : les entiers passent par
                    // l'interpolation, seuls les flottants restent formatés.
                    print("  freelist count     : \(deepReport.freelistCount) pages "
                          + String(format: "(%.1f%% fragmentation, %.2f MB)",
                                   deepReport.fragmentationPct, fragMo))
                    print("  WAL size           : \(deepReport.walBytes) bytes")
                    print("  journal mode       : \(deepReport.journalMode)")
                    if let vectors = deepReport.vectors {
                        print("  semantic vectors   : \(vectors.rows) row(s) in page_vec, "
                              + "\(vectors.total) inconsistent")
                        for kind in VectorAnomaly.Kind.allCases where vectors.count(kind) > 0 {
                            let sample = vectors.samples.filter { $0.kind == kind }
                                .map { String($0.rowid) }.joined(separator: ", ")
                            print("      \(vectors.count(kind)) × \(kind.english)"
                                  + (sample.isEmpty ? "" : " (rowid \(sample)…)"))
                        }
                        if !vectors.isClean {
                            print("      what to do: `fouine maintain --repair` removes them; "
                                  + "`fouine embed` then produces the missing vectors again")
                        }
                    }
                    if let names = deepReport.docNames {
                        print("  document names     : \(names.names) row(s) in docs_fts "
                              + "for \(names.docs) document(s)")
                        if !names.consistent {
                            print("      what to do: `fouine maintain --repair` rebuilds "
                                  + "docs_fts from docs")
                        }
                    }
                    // Le détail par étape (MO-04). Mesuré sur 2,15 Go :
                    // `quick_check` 79,6 s et `fts5_integrity` 92,0 s — deux
                    // postes comparables, et non « FTS5 et le reste »,
                    // contrairement à ce qu'on supposait.
                    for step in deepReport.steps {
                        let name = step.name.count >= 14 ? step.name
                            : step.name.padding(toLength: 14, withPad: " ", startingAt: 0)
                        print(String(format: "  step \(name): %.1f ms", step.elapsedMS))
                    }
                    print(String(format: "  check duration     : %.1f ms", deepReport.elapsedMS))
                }
            }

            if let first = failing.first {
                // Motif brut : CLI.describe ajoute le geste TCC si (et
                // seulement si) c'est un refus de lecture.
                throw FouineError.rootUnreadable(
                    path: first.path,
                    reason: (first.reason ?? .noReadableFile).token)
            }

            if let deepReport, deepReport.quickCheck.lowercased() != "ok" || deepReport.ftsIntegrity != "ok" {
                throw MaintenanceError("database integrity check failed: quick_check=\(deepReport.quickCheck), fts=\(deepReport.ftsIntegrity)")
            }
        }
    }
}
