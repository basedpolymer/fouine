// CommandsMaintenance.swift — `fouine backup` et `fouine maintain` (SPEC §4.3, C2-06).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available

import Foundation
import ArgumentParser
import FouineCore
// `LanguageDetector` vit dans FouineIndex : le cœur ne peut pas l'appeler sans
// un cycle de dépendances, c'est donc la CLI qui l'injecte (lot U3, R-10).
import FouineIndex

// MARK: - fouine backup

struct BackupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup",
        abstract: "Online snapshot backup using SQLite backup API.")

    @Argument(help: "Destination file path for the backup.")
    var destination: String

    @Flag(name: .long, help: "Overwrite destination if it already exists.")
    var force = false

    @Flag(name: .long, help: "JSON output.")
    var json = false

    func run() {
        CLI.guarded {
            let store = try CLI.openStore()
            let destURL = URL(fileURLWithPath: (destination as NSString).expandingTildeInPath)
            let report = try store.backup(to: destURL, force: force)

            if json {
                try CLI.printJSON(report.json)
            } else {
                let mb = Double(report.bytes) / (1024.0 * 1024.0)
                print("backup completed successfully:")
                print("  destination   : \(report.destination)")
                // INTERPOLATION, jamais `%d` (constat CM-05). `String(format:)`
                // lit `%d` sur 32 bits : au-delà de 2 Gio — la base de
                // production les dépasse — la seule commande dont le métier est
                // de dire « votre sauvegarde est faite » annonçait
                // « -2143854592 bytes ». Le JSON, lui, portait déjà le bon
                // entier.
                print("  size          : \(report.bytes) bytes "
                      + String(format: "(%.2f MB)", mb))
                print(String(format: "  duration      : %.1f ms", report.elapsedMS))
                print("  quick_check   : \(report.quickCheck)")
                print("  fts_integrity : \(report.ftsIntegrity)")
            }
        }
    }
}

// MARK: - fouine maintain

struct MaintainCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "maintain",
        // VACUUM est derrière `--vacuum` : l'annoncer dans le résumé comme les
        // trois autres opérations le faisait passer pour un défaut, et un
        // `maintain` ordinaire ne rendait alors « que » 16 Kio (constat C2-17).
        abstract: "Database maintenance: optimize FTS5, PRAGMA optimize, checkpoint; VACUUM with --vacuum.")

    @Flag(name: .long, help: "Reclaim unused pages with VACUUM.")
    var vacuum = false

    @Flag(name: .long, help: "Force VACUUM even if freelist is 0.")
    var force = false

    @Flag(name: .long,
          help: "Remove the page_vec rows `doctor --deep` reports as inconsistent, and clear the OCR failure mark of documents without any scanned page.")
    var repair = false

    @Flag(name: .long,
          help: "Detect the language of documents that do not have one yet, from the text already in the index.")
    var detectLanguages = false

    @Flag(name: .long,
          help: "Detect the language of every document again, including those that already have one.")
    var redetectLanguages = false

    @Flag(name: .long, help: "JSON output.")
    var json = false

    func run() {
        CLI.guarded {
            let store = try CLI.openStore()

            // Le rattrapage passe par `writeLocked`, donc par le MÊME
            // `fouine.lock` que le reste de `maintain` (sortie 3 si l'agent le
            // tient). Il vient AVANT les optimisations : il écrit dans `docs`,
            // et `PRAGMA optimize` n'a aucune raison de tourner avant.
            var languages: LanguageBackfillReport?
            if detectLanguages || redetectLanguages {
                // `--redetect-languages` (C2-01) : la détection a changé d'avis
                // — elle vote désormais sur trois tranches au lieu de lire la
                // tête du document —, donc les documents QUI ONT DÉJÀ une
                // langue sont ceux qu'il faut relire en premier. On les rend
                // candidats en effaçant la colonne, en une transaction.
                if redetectLanguages { try store.resetAllLanguages() }
                let backfill = try store.backfillLanguages(
                    limit: Int.max,
                    sampleCharacters: LanguageDetector.sampleCharacters,
                    detect: { LanguageDetector.detect(LanguageDetector.sample(pages: $0)) })
                languages = backfill
                if !json {
                    if redetectLanguages {
                        let undetermined = backfill.scanned - backfill.determined
                        // Entiers par interpolation (CM-05).
                        print("language detection: \(backfill.scanned) document(s) "
                              + "read, \(backfill.determined) with a language, "
                              + "\(undetermined) undetermined, "
                              + String(format: "%.0f ms", backfill.elapsedMS))
                    } else {
                        print("language detection: \(backfill.scanned) document(s) read, "
                              + "\(backfill.remaining) left")
                    }
                    if backfill.scanned > 0 {
                        print("  languages                 : \(backfill.distribution)")
                    }
                }
            }

            let report = try store.maintain(vacuum: vacuum, force: force,
                                            repair: repair, progress: { msg in
                if !json {
                    print(msg)
                }
            })

            if json {
                var payload = report.json
                if let languages { payload["language_backfill"] = languages.json }
                try CLI.printJSON(payload)
            } else {
                print(String(format: "maintenance completed in %.1f ms:", report.totalElapsedMS))
                for step in report.steps {
                    // `%s` attend une chaîne C : `String(format:)` y déposait
                    // les octets UTF-16 d'un `String` Swift et la ligne
                    // sortait en charabia (« ®£®E¯ » pour « page_fts
                    // optimize »). `%@` est le seul verbe qui prenne un objet
                    // Objective-C, et le calage se fait donc à la main.
                    let name = step.name.padding(toLength: max(26, step.name.count),
                                                 withPad: " ", startingAt: 0)
                    print(String(format: "  - %@ : %.1f ms", name, step.elapsedMS))
                }
                if report.vacuumExecuted {
                    let mb = Double(report.bytesReclaimed) / (1024.0 * 1024.0)
                    // Même piège 32 bits que la ligne `size` de `backup` (CM-05).
                    print("  reclaimed                 : \(report.bytesReclaimed) bytes "
                          + String(format: "(%.2f MB)", mb))
                    print("  freelist pages            : \(report.freelistBefore) -> \(report.freelistAfter)")
                }
                if let repaired = report.vectorRepair {
                    print("  page_vec rows removed     : \(repaired.total)")
                    for kind in VectorAnomaly.Kind.allCases where repaired.count(kind) > 0 {
                        print("      \(kind.rawValue): \(repaired.count(kind)) — \(kind.english)")
                    }
                    if repaired.pagesRequeued > 0 {
                        print("  pages back to vectorise   : \(repaired.pagesRequeued) "
                              + "(run `fouine embed` to produce them again)")
                    }
                }
                if let cleared = report.ocrFailuresCleared {
                    print("  OCR failure marks cleared : \(cleared)")
                }
                print("  database size             : \(report.bytesBefore) -> \(report.bytesAfter) bytes")
            }
        }
    }
}
