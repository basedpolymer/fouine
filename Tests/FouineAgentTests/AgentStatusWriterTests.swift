// AgentStatusWriterTests.swift — l'agent cesse d'être une boîte noire (F7).
// Propriété : A-Recette. Audit F7, D12/M23.
//
// « Seul diagnostic : `tail -f` du journal ; `agentStatusText` ne dit jamais ce
//   que l'agent fait ni où en est la file ; aucune notification. Pour un travail
//   de vingt heures, c'est le point d'abandon le plus probable. » (audit F7)
//
// Trois précautions y répondent, et chacune se teste :
//
//   1. écriture MENUE ET RARE — immédiate à chaque changement de phase, sinon
//      au plus une fois toutes les deux secondes ;
//   2. dernier état AVANT `exit(0)` — écrit sans attendre la cadence, sans quoi
//      l'app n'aurait plus que les cinq minutes de péremption pour deviner que
//      l'agent est parti ;
//   3. une panne d'état N'ARRÊTE RIEN — `agent_status` est de la télémétrie.
//
// La base est jetable, créée dans un dossier temporaire : jamais celle de
// production, où l'agent réel écrit.

import Foundation
import XCTest
import FouineCore
@testable import FouineAgent

final class AgentStatusWriterTests: XCTestCase {

    private var scratch: URL!
    private var store: GRDBStore!
    private var log: AgentLog!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-status-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
        store = GRDBStore()
        try store.open(at: scratch.appendingPathComponent("fouine.db"))
        log = AgentLog(url: scratch.appendingPathComponent("fouine.log"))
    }

    override func tearDownWithError() throws {
        store = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func makeWriter() -> AgentStatusWriter {
        AgentStatusWriter(store: store, log: log)
    }

    /// Un changement de phase est écrit TOUT DE SUITE : c'est le seul moment où
    /// l'attente de l'utilisateur est réellement suspendue à l'information.
    func testPhaseChangeIsPublishedImmediately() throws {
        let writer = makeWriter()
        XCTAssertNil(try store.agentStatus(),
                     "aucun agent n'a encore écrit : la table est vide")

        writer.publish(.crawl, detail: "Livres")
        let crawl = try XCTUnwrap(try store.agentStatus())
        XCTAssertEqual(crawl.phase, .crawl)
        XCTAssertEqual(crawl.detail, "Livres")
        XCTAssertEqual(crawl.pid, getpid())
        XCTAssertNotNil(crawl.updatedAt)

        // Changement de DÉTAIL sans changement de phase : LISSÉ (A2-10). Le
        // nom du document qui défile est un raffinement de la même
        // information, et `AgentPipeline` en publie un par document abouti —
        // c'était une transaction de sept UPSERT par document.
        writer.publish(.crawl, detail: "Cours")
        XCTAssertEqual(try store.agentStatus()?.detail, "Livres",
                       "A2-10 : un détail seul ne force pas l'écriture")

        writer.publish(.ocr, detail: "scan.pdf", done: 3, total: 40)
        let ocr = try XCTUnwrap(try store.agentStatus())
        XCTAssertEqual(ocr.phase, .ocr)
        XCTAssertEqual(ocr.done, 3)
        XCTAssertEqual(ocr.total, 40)
    }

    /// La progression PURE est bridée à une écriture toutes les deux secondes :
    /// un lot d'OCR de dix minutes doit coûter ~300 écritures, pas une par page.
    /// On vérifie le bridage sans attendre : la base doit garder la valeur du
    /// premier appel, pas celle du dernier.
    func testProgressWithoutPhaseChangeIsThrottled() throws {
        let writer = makeWriter()
        writer.publish(.ocr, detail: "scan.pdf", done: 0, total: 100)
        XCTAssertEqual(try store.agentStatus()?.done, 0)

        for done in 1...50 {
            writer.progress(done: done, total: 100)
        }
        XCTAssertEqual(try store.agentStatus()?.done, 0,
                       "cinquante progressions en quelques millisecondes ne "
                       + "doivent produire AUCUNE écriture supplémentaire "
                       + "(cadence de \(Int(AgentStatusWriter.minimumInterval)) s)")

        // Un changement de DÉTAIL non plus (A2-10) : cinquante documents
        // aboutis en quelques millisecondes, une seule écriture — celle du
        // départ.
        writer.progress(done: 51, total: 100, detail: "autre.pdf")
        let after = try XCTUnwrap(try store.agentStatus())
        XCTAssertEqual(after.done, 0)
        XCTAssertEqual(after.detail, "scan.pdf")

        // Un changement de PHASE, lui, passe toujours outre la cadence : c'est
        // le seul moment où l'attente de l'utilisateur est suspendue à
        // l'information. Et il emporte le dernier détail vu.
        writer.publish(.waiting, detail: "no AC power")
        let waiting = try XCTUnwrap(try store.agentStatus())
        XCTAssertEqual(waiting.phase, .waiting)
        XCTAssertEqual(waiting.detail, "no AC power")
        XCTAssertEqual(waiting.done, 51,
                       "la progression lissée n'est pas perdue : la prochaine "
                       + "écriture porte la dernière valeur vue")
    }

    /// A2-10, le chiffre du contrat : cinquante documents aboutis en quelques
    /// millisecondes coûtaient cinquante transactions de sept `UPSERT`.
    func testFiftyDocumentsCostOneWrite() throws {
        let writer = makeWriter()
        writer.publish(.extract, detail: "Livres", done: 0, total: 50)
        let first = try XCTUnwrap(try store.agentStatus()?.updatedAt)

        for n in 1...50 {
            writer.publish(.extract, detail: "document-\(n).pdf")
        }
        let after = try XCTUnwrap(try store.agentStatus())
        XCTAssertEqual(after.detail, "Livres")
        XCTAssertEqual(after.updatedAt, first,
                       "A2-10 : une transaction par document extrait, contre "
                       + "« deux ou trois par minute » annoncées en tête de "
                       + "deux fichiers")
    }

    /// `resetProgress` efface la barre : une phase qui n'a pas de progression
    /// (attente, repos) ne doit pas garder à l'écran celle du lot précédent.
    func testResetProgressClearsTheBar() throws {
        let writer = makeWriter()
        writer.publish(.ocr, detail: "scan.pdf", done: 20, total: 40)
        XCTAssertEqual(try store.agentStatus()?.total, 40)

        writer.publish(.waiting, detail: "en attente du secteur",
                       resetProgress: true)
        let waiting = try XCTUnwrap(try store.agentStatus())
        XCTAssertEqual(waiting.phase, .waiting)
        XCTAssertEqual(waiting.done, 0)
        XCTAssertEqual(waiting.total, 0)
    }

    /// `stopped` écrit SANS attendre la cadence, juste avant `exit(0)`. Sans
    /// cette écriture, un agent proprement arrêté serait indiscernable d'un
    /// agent mort en vol jusqu'à l'expiration des cinq minutes de péremption.
    func testStoppedIsWrittenEvenRightAfterAnotherWrite() throws {
        let writer = makeWriter()
        writer.publish(.ocr, detail: "scan.pdf", done: 7, total: 40)
        writer.stopped("SIGTERM")               // dans la même milliseconde

        let status = try XCTUnwrap(try store.agentStatus())
        XCTAssertEqual(status.phase, .stopped)
        XCTAssertEqual(status.detail, "SIGTERM")
        XCTAssertEqual(status.done, 0)
        XCTAssertEqual(status.total, 0)
    }

    /// La table porte UNE LIGNE PAR CHAMP, et non une ligne de JSON : un
    /// `sqlite3 "SELECT * FROM agent_status"` doit se lire à l'œil quand l'agent
    /// ne répond pas. C'est la seule situation où l'on regarde cette table.
    func testStatusIsStoredAsOneRowPerFieldReadableByHand() throws {
        let writer = makeWriter()
        writer.publish(.extract, detail: "traite.pdf", done: 12, total: 34)

        // Lu par le sqlite3 du système, en `mode=ro` : c'est le geste que fera
        // celui qui diagnostique un agent muet, et c'est donc lui qu'on teste.
        var rows: [String: String] = [:]
        for line in try readTable("SELECT key || '\t' || value FROM agent_status") {
            let parts = line.split(separator: "\t", maxSplits: 1,
                                   omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            rows[String(parts[0])] = String(parts[1])
        }
        XCTAssertEqual(Set(rows.keys),
                       ["phase", "detail", "done", "total", "started_at",
                        "updated_at", "pid"])
        XCTAssertEqual(rows["phase"], "extract")
        XCTAssertEqual(rows["detail"], "traite.pdf")
        XCTAssertEqual(rows["done"], "12")
        XCTAssertEqual(rows["total"], "34")
        XCTAssertEqual(rows["pid"], String(getpid()))
    }

    /// `sqlite3` du système, base en lecture seule.
    private func readTable(_ statement: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let path = scratch.appendingPathComponent("fouine.db").path
        process.arguments = ["file:\(path)?mode=ro", statement]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }

    /// Une panne d'état N'ARRÊTE RIEN : si la base refuse l'écriture, on le dit
    /// UNE fois dans le journal et l'agent continue. L'inverse — un agent qui
    /// s'arrête parce qu'il n'a pas pu dire ce qu'il faisait — serait une
    /// régression franche.
    ///
    /// On provoque la panne en fermant la base sous le writer : `store` n'est
    /// plus ouvert, chaque écriture lève, et `publish` ne doit pas propager.
    func testWriteFailureIsSwallowedAndLoggedOnce() throws {
        let closed = GRDBStore()          // jamais `open` : toute écriture lève
        let writer = AgentStatusWriter(store: closed, log: log)

        writer.publish(.crawl, detail: "Livres")
        writer.publish(.extract, detail: "traite.pdf")
        writer.stopped("fin")
        // Aucune exception n'est remontée : c'est tout le contrat.

        let journal = try String(contentsOf: scratch
            .appendingPathComponent("fouine.log"), encoding: .utf8)
        let complaints = journal.split(separator: "\n")
            .filter { $0.contains("agent_status") }
        XCTAssertEqual(complaints.count, 1,
                       "une base qui refuse l'état la refusera aussi aux 300 "
                       + "écritures suivantes : une seule plainte par épisode\n"
                       + journal)
        XCTAssertTrue(complaints[0].contains("warn"), String(complaints[0]))
    }

    // MARK: - A1m-10 : `detail` est un jeton, pas une phrase

    /// Le `detail` traverse TROIS contrats — `fouine status`, `status --json`
    /// et le serveur MCP — et l'app le traduit. Il ne peut donc pas être une
    /// phrase : sur cette machine, `fouine status` affichait « SIGTERM reçu »,
    /// du français au milieu d'une sortie anglaise, parce qu'un agent d'une
    /// version antérieure l'avait écrit dans la base (audit A1m-10).
    func testDetailIsAWrittenTokenAndReadsBackInEnglish() throws {
        // Écriture DIRECTE : `AgentStatusWriter.publish` ne réécrit qu'une fois
        // toutes les deux secondes hors changement de phase (c'est son contrat,
        // éprouvé plus haut), et ce test-ci porte sur la FORME du détail.
        for (token, english) in [
            (AgentStatusDetail.starting, "starting up"),
            (AgentStatusDetail.queueDrained, "OCR queue empty"),
            (AgentStatusDetail.pagesQueued(20226), "20226 page(s) queued"),
            (AgentStatusDetail.pagesLeft(315), "315 page(s) left"),
            (AgentStatusDetail.signalReceived("SIGTERM"), "SIGTERM received"),
            (AgentStatusDetail.document("Cours (2e partie).pdf"),
             "Cours (2e partie).pdf"),
        ] {
            try store.writeAgentStatus(AgentStatusRecord(phase: .ocr, detail: token))
            let stored = try XCTUnwrap(try store.agentStatus()?.detail)
            XCTAssertEqual(stored, token, "la BASE porte le jeton, pas la phrase")
            XCTAssertNotEqual(AgentStatusDetail.parse(stored), .free(stored),
                              "« \(stored) » doit se relire comme un jeton")
            XCTAssertEqual(AgentStatusDetail.english(stored), english)
        }
    }

    /// COMPATIBILITÉ : un `detail` qu'on ne sait pas lire — un agent d'une autre
    /// version, une condition d'attente du §5.7 — s'affiche tel quel. Lire
    /// quelque chose vaut mieux que rien.
    func testAnUnknownDetailIsShownAsIs() {
        for raw in ["SIGTERM reçu", "on battery; CPU_Speed_Limit 33 %",
                    "pages-queued(beaucoup)", "future-token(3)"] {
            XCTAssertEqual(AgentStatusDetail.english(raw), raw)
            XCTAssertEqual(AgentStatusDetail.parse(raw), .free(raw))
        }
    }

    /// La péremption est un contrat partagé avec l'app : au-delà de cinq
    /// minutes sans écriture, le statut ne veut plus rien dire et l'interface
    /// doit le marquer plutôt que d'afficher une barre figée.
    func testStaleThresholdIsFiveMinutesAndAgeIsReadable() throws {
        XCTAssertEqual(AgentStatusRecord.staleAfter, 300)

        let writer = makeWriter()
        writer.publish(.ocr, detail: "scan.pdf", done: 1, total: 2)
        let age = try XCTUnwrap(try store.agentStatus()?.age)
        XCTAssertGreaterThanOrEqual(age, 0)
        XCTAssertLessThan(age, AgentStatusRecord.staleAfter)
    }
}
