// CommandsIndex.swift — crawl, extract, index, ocr (SPEC §4.3, §5.3, §6.1, annexe B).
// Propriété : A-Core.

import Foundation
import ArgumentParser
import FouineCore
import FouineOCR

/// `--only` confronté à l'index (constat CM-11).
///
/// `fouine extract --only /chemin/qui-nexiste-pas` affichait « no document to
/// extract » et sortait en **0** : la même réponse qu'un corpus déjà entièrement
/// extrait. Une faute de frappe dans un chemin est une erreur d'ARGUMENT.
///
/// L'appariement est celui de la passe elle-même — chemin absolu OU `rel_path`
/// (§8.1) —, sans quoi on refuserait ce qui aurait marché.
enum OnlyDocument {

    static func check(_ only: String?, store: GRDBStore) throws {
        guard let only, !only.isEmpty else { return }
        let expanded = (only as NSString).expandingTildeInPath
        // `try?` rend `nil` aussi bien pour un volume démonté que pour un
        // document absent : dans les deux cas on continue par le `rel_path`.
        if (try? store.docID(forAbsolutePath: expanded)) != nil { return }
        let relative = expanded.hasPrefix("/") ? String(expanded.dropFirst()) : expanded
        for volume in try store.volumes() {
            if try store.docID(volUUID: volume.uuid, relPath: relative) != nil { return }
            if try store.docID(volUUID: volume.uuid, relPath: expanded) != nil { return }
        }
        throw UsageRefusal(
            message: "no indexed document matches \(only) — `fouine crawl` "
            + "discovers new files, `fouine status --unreadable` lists those "
            + "Fouine could not read")
    }
}

/// Le défaut d'un `--jobs` non fourni (audit U2).
///
/// Il ne vient plus d'un littéral mais du réglage `extract.jobs` / `ocr.jobs`,
/// que la fenêtre de réglages et `fouine config set` écrivent. L'option de
/// ligne de commande reste PRIORITAIRE quand elle est donnée : un réglage
/// enregistré ne doit pas prendre le pas sur ce qu'on vient de taper.
enum Jobs {
    static func extract(_ explicit: Int?, store: GRDBStore) -> Int {
        explicit ?? settings(store).extractJobs
    }
    static func ocr(_ explicit: Int?, store: GRDBStore) -> Int {
        explicit ?? settings(store).ocrJobs
    }
    private static func settings(_ store: GRDBStore) -> SettingsSnapshot {
        let (snapshot, warning) = SettingsSnapshot.load(from: store)
        if let warning { FileHandle.standardError.write(Data((warning + "\n").utf8)) }
        return snapshot
    }
}

// MARK: - fouine crawl

struct CrawlCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crawl", abstract: "Walk the roots and update docs.")

    @Option(name: .long, help: "Root (identifier or label); default: all of them.")
    var root: String?

    @Flag(name: .long, help: "Full walk (also detects deletions).")
    var full = false

    @Flag(name: .long, help: "Incremental walk (default).")
    var delta = false

    func run() {
        // La garde d'essai vient AVANT l'ouverture de la base : c'est aussi ici
        // que `trial_started` se pose pour qui installe la ligne de commande
        // sans jamais lancer l'application (lot L1C).
        LicenseGate.requireIndexing()
        CLI.guarded {
            let store = try CLI.openStore()
            let mode: CrawlMode = full ? .full : .delta
            try Pipeline.crawl(store: store, rootSelector: root, mode: mode)
        }
    }
}

// MARK: - fouine extract

struct ExtractCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract", abstract: "Extract the text of the discovered documents.")

    @Option(name: .long,
            help: "Number of extraction threads (default: the `extract.jobs` setting).")
    var jobs: Int?

    @Option(name: .customLong("budget-minutes"), help: "Clean stop after M minutes.")
    var budgetMinutes: Int?

    @Option(name: .long, help: "A single document (absolute path or rel_path).")
    var only: String?

    func run() {
        LicenseGate.requireIndexing()
        CLI.guarded {
            let store = try CLI.openStore()
            try OnlyDocument.check(only, store: store)
            try Pipeline.extract(store: store, jobs: Jobs.extract(jobs, store: store),
                                 budgetMinutes: budgetMinutes, only: only)
        }
    }
}

// MARK: - fouine index

struct IndexCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index", abstract: "= crawl --delta then extract.")

    @Flag(name: .customLong("with-ocr"), help: "Run the OCR pass afterwards.")
    var withOCR = false

    @Option(name: .long,
            help: "Number of extraction threads (default: the `extract.jobs` setting).")
    var jobs: Int?

    @Option(name: .customLong("budget-minutes"), help: "Clean stop after M minutes.")
    var budgetMinutes: Int?

    func run() {
        LicenseGate.requireIndexing()
        CLI.guarded {
            let store = try CLI.openStore()
            try Pipeline.crawl(store: store, rootSelector: nil, mode: .delta)
            try Pipeline.extract(store: store,
                                 jobs: Jobs.extract(jobs, store: store),
                                 budgetMinutes: budgetMinutes, only: nil)
            if withOCR {
                // L'OCR a son propre plafond et sa propre raison d'être borné
                // (le DÉBIT, §6.3) : `--jobs` d'`index` ne le pilote pas.
                try runOCRCommand(store: store, jobs: Jobs.ocr(nil, store: store),
                                  budgetMinutes: budgetMinutes,
                                  prioFolder: nil, only: nil)
            }
        }
    }
}

// MARK: - fouine ocr

struct OCRCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ocr",
        abstract: "Vision .accurate OCR pass (a single pass, decision D1).",
        subcommands: [OCRExport.self, OCRImport.self, OCRRequeue.self])

    @Option(name: .long,
            help: "Number of OCR threads (default: the `ocr.jobs` setting).")
    var jobs: Int?

    @Option(name: .customLong("budget-minutes"), help: "Clean stop after M minutes.")
    var budgetMinutes: Int?

    @Option(name: .customLong("prio-folder"), help: "Process this root first.")
    var prioFolder: String?

    @Option(name: .long, help: "A single document (absolute path or rel_path).")
    var only: String?

    func run() {
        LicenseGate.requireIndexing()
        CLI.guarded {
            let store = try CLI.openStore()
            // Refus en 64 AVANT le verrou et le préchauffage de Vision : la
            // passe refusait déjà un chemin inconnu, mais en 1 (une panne) et
            // après avoir pris le verrou.
            try OnlyDocument.check(only, store: store)
            // Verrou tenu par l'agent ou l'app : on refuse ICI, en 3, avec UNE
            // ligne (reste du lot CL1, constat CM-26).
            //
            // CE QUE ÇA REMPLACE. La file se tire par une LECTURE
            // (`nextOCRBatch`) : la passe partait donc, préchauffait Vision
            // (8,5 s), puis échouait à l'écriture de CHAQUE page — « database
            // locked — … » une fois par page, trois lots identiques avant que
            // le détecteur d'enlisement ne rende la main —, et sortait en 0.
            // Un script qui enchaîne les passes ne voyait aucune erreur ; les
            // autres commandes d'écriture, elles, sortent en 3 avec la phrase
            // du verrou (§4.3, `docs/agent.md` § 6).
            //
            // FILE VIDE : ON NE REGARDE PAS LE VERROU. `fouine ocr` sur une
            // file vide n'écrit rien et doit rester un no-op à 0, verrou tenu
            // ou pas — c'est ce que l'agent et l'app appellent en boucle.
            try Self.refuseIfLocked(store: store)
            try runOCRCommand(store: store, jobs: Jobs.ocr(jobs, store: store),
                              budgetMinutes: budgetMinutes,
                              prioFolder: prioFolder, only: only)
        }
    }

    /// Sonde du verrou d'écriture, sans l'attendre ni le prendre — la même que
    /// `status` et `doctor` publient (`WriteLock.inspect`).
    ///
    /// `.stale` refuse AUSSI : le `flock` est bien tenu (c'est ce que la sonde
    /// mesure), seul le NOM inscrit est périmé. Notre PROPRE détenteur, en
    /// revanche, ne nous bloque pas : `open()` a pu prendre le verrou pour
    /// migrer le schéma, et `flock` oppose deux descripteurs du même processus.
    static func refuseIfLocked(store: GRDBStore) throws {
        guard (try store.ocrQueueLength()) > 0 else { return }
        let path = StatusCommand.lockPath(of: store)
        let holder: LockHolder
        switch WriteLock.inspect(path: path) {
        case .free: return
        case .held(let h), .stale(let h): holder = h
        }
        guard holder.pid != ProcessInfo.processInfo.processIdentifier else { return }
        throw FouineError.databaseFailure(
            WriteLock.busyMessage(holder: holder, path: path))
    }
}

// MARK: - fouine ocr requeue

struct OCRRequeue: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "requeue",
        abstract: "Requeue doubtful or no-lines pages into ocr_queue.",
        discussion: """
            Re-enqueues scanned pages of the chosen population into ocr_queue \
            (attempts = 0, lowest priority 3), without touching existing indexed \
            text. A subsequent `fouine ocr` pass will re-process them.

            Pages already present in the queue are left untouched (ignored).
            """)

    @Flag(name: .long,
          help: "Requeue doubtful pages (0 < conf < 0.60; default).")
    var doubtful = false

    @Flag(name: .customLong("no-lines"),
          help: "Requeue pages with NO recognised line at all (conf <= 0 or null).")
    var noLines = false

    @Option(name: .long, help: "Maximum number of pages to requeue.")
    var limit: Int = 100_000

    @Flag(name: .long, help: "JSON output.")
    var json = false

    func validate() throws {
        if doubtful && noLines {
            throw ValidationError("Cannot specify both --doubtful and --no-lines.")
        }
        if limit <= 0 {
            throw ValidationError("--limit must be greater than 0.")
        }
    }

    func run() {
        CLI.guarded {
            let store = try CLI.openStore()
            let population: GRDBStore.OCRPagePopulation = noLines ? .noLines : .doubtful
            let result = try store.requeueOCRPages(population, limit: limit)
            let popName = noLines ? "no-lines" : "doubtful"
            if json {
                try CLI.printJSON([
                    "population": noLines ? "no_lines" : "doubtful",
                    "requeued": result.requeued,
                    "already_queued": result.alreadyQueued,
                    "total_candidates": result.totalCandidates,
                    "limit": limit
                ])
            } else {
                print("\(result.requeued) page(s) requeued for OCR (\(result.alreadyQueued) already queued, ignored) [population: \(popName)]")
            }
        }
    }
}

struct OCRExport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export pages to be OCR'd as JSONL (appendix B).")

    @Flag(name: .long, help: "The pages queued for OCR (ocr_queue).")
    var pending = false

    @Flag(name: .customLong("no-lines"),
          help: "The pages with NO recognised line at all, rather than the doubtful ones.")
    var noLines = false

    @Option(name: .long, help: "Maximum number of exported pages.")
    var limit: Int = 100_000

    @Option(name: .customLong("render-png"), help: "Folder for the PNG renders.")
    var renderPNG: String?

    @Option(name: .long, help: "Output JSONL file.")
    var out: String

    func run() {
        CLI.guarded {
            let store = try CLI.openStore()
            var lines: [String] = []
            var toRender: [(docID: Int64, page: Int, path: String)] = []
            if pending {
                for p in try store.pendingOCRPages(limit: limit) {
                    lines.append(try JSONL.encode([
                        "doc_id": p.docID, "page": p.page,
                        "vol_uuid": p.volUUID, "rel_path": p.relPath, "prio": p.prio,
                    ]))
                    if renderPNG != nil {
                        let url = try VolumeResolver.absolutePath(
                            volUUID: p.volUUID, relPath: p.relPath)
                        toRender.append((p.docID, p.page, url.path))
                    }
                }
            } else {
                // Sans --pending : les pages OCRisées à reprendre (annexe B,
                // « re-OCR des pages douteuses », index idx_page_src_conf).
                //
                // DEUX populations depuis l'audit A6 : par défaut les pages
                // DOUTEUSES (0 < conf < 0,60, le vrai gisement) ; avec
                // --no-lines, les pages dont aucune ligne n'a été reconnue
                // (sentinelle conf = 0), qui relèvent d'un nouveau rendu.
                // L'ancien seuil de 0,30 ne remontait QUE ces dernières.
                let population: GRDBStore.OCRPagePopulation =
                    noLines ? .noLines : .doubtful
                for p in try store.ocrPagesToRevisit(
                    population, below: GRDBStore.doubtfulConfidenceThreshold,
                    limit: limit) {
                    var obj: [String: Any] = [
                        "doc_id": p.docID, "page": p.page,
                        "vol_uuid": p.volUUID, "rel_path": p.relPath,
                    ]
                    if let c = p.conf { obj["conf"] = c }
                    lines.append(try JSONL.encode(obj))
                    if renderPNG != nil {
                        let url = try VolumeResolver.absolutePath(
                            volUUID: p.volUUID, relPath: p.relPath)
                        toRender.append((p.docID, p.page, url.path))
                    }
                }
            }
            let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            try text.write(to: URL(fileURLWithPath: out), atomically: true,
                           encoding: .utf8)
            let kind = pending ? " (OCR queue)"
                : (noLines ? " (pages with no recognised line)" : " (doubtful pages)")
            print("\(lines.count) page(s) exported to \(out)" + kind)
            if let dir = renderPNG {
                let dirURL = URL(fileURLWithPath: dir)
                try FileManager.default.createDirectory(
                    at: dirURL, withIntermediateDirectories: true)
                let n = try OCRExportRender.renderPNGs(
                    store: store, pages: toRender, dpi: 150, to: dirURL)
                print("\(n) PNG render(s) in \(dir)")
            }
        }
    }
}

struct OCRImport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import an external OCR JSONL (appendix B). No privilege.")

    @Argument(help: "JSONL file produced by an external engine.")
    var file: String

    func run() {
        CLI.guarded {
            let store = try CLI.openStore()
            let content = try String(contentsOf: URL(fileURLWithPath: file),
                                     encoding: .utf8)
            var imported = 0, invalid = 0, unknownDoc = 0
            for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                guard let obj = try? JSONSerialization.jsonObject(
                        with: Data(line.utf8)) as? [String: Any],
                      let relPath = obj["rel_path"] as? String,
                      let volUUID = obj["vol_uuid"] as? String,
                      let page = (obj["page"] as? NSNumber)?.intValue,
                      // Le numéro de page vient d'un FICHIER : sans cette borne,
                      // « page: 100000 » écrivait au rowid de la page 0 du
                      // document suivant (audit S2). Le store refuserait, mais
                      // en interrompant l'import ; ici la ligne est simplement
                      // comptée invalide, comme toute autre ligne mal formée.
                      page >= 1, page <= Schema.maxPage else {
                    invalid += 1
                    continue
                }
                guard let docID = try store.docID(volUUID: volUUID, relPath: relPath)
                else { unknownDoc += 1; continue }

                let engine = (obj["engine"] as? String) ?? "external"
                let engineRev = (obj["engine_rev"] as? String) ?? "?"
                let rawLines = (obj["lines"] as? [[String: Any]]) ?? []
                var all: [OCRLine] = []
                for l in rawLines {
                    guard let t = l["t"] as? String,
                          let x = (l["x"] as? NSNumber)?.doubleValue,
                          let y = (l["y"] as? NSNumber)?.doubleValue,
                          let w = (l["w"] as? NSNumber)?.doubleValue,
                          let h = (l["h"] as? NSNumber)?.doubleValue else {
                        invalid += 1
                        continue
                    }
                    let c = (l["c"] as? NSNumber)?.doubleValue ?? 0
                    all.append(OCRLine(text: t, x: x, y: y, w: w, h: h, confidence: c))
                }
                // Filtrage par confiance identique au §6.2 : le canal externe
                // n'a AUCUN privilège. TOUTES les lignes vont dans ocr_layout.
                let kept = all.filter { $0.confidence >= GRDBStore.lowConfidenceThreshold }
                let text = all.isEmpty
                    ? ((obj["text"] as? String) ?? "")
                    : kept.map(\.text).joined(separator: "\n")
                let mean = kept.isEmpty ? 0
                    : kept.map(\.confidence).reduce(0, +) / Double(kept.count)

                try store.completeOCR(
                    docID: docID, page: page,
                    result: OCRPage(text: text, lines: all, level: .accurate,
                                    seconds: 0, engine: .external,
                                    engineRev: "\(engine)-\(engineRev)",
                                    meanConfidence: mean))
                imported += 1
            }
            print("\(imported) page(s) imported")
            if unknownDoc > 0 {
                CLI.warn("\(unknownDoc) line(s) ignored: unknown document "
                         + "(no match for vol_uuid + rel_path)")
            }
            if invalid > 0 {
                CLI.warn("\(invalid) invalid line(s) ignored")
            }
        }
    }
}

enum JSONL {
    static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
