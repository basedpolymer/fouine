// IgnoreRulesDraftTests.swift — la logique de la feuille « Ce que Fouine
// ignore… » (lot IG2). Propriété : A-App.
//
// Ce que ces tests protègent :
//   · chaque règle se lit en clair, sans motif ;
//   · les trois gestes fabriquent la bonne règle, et refusent ce qui ne peut
//     pas en être une avec une phrase ;
//   · « déjà ignoré » se juge sur ce qui est exclu (`Santé/2025/` sous
//     `Santé/`), et distingue le fichier `.fouineignore` des réglages ;
//   · la conséquence est dite avant d'enregistrer, avec un nombre quand on a
//     les documents, sans nombre sinon ;
//   · « Mettre à jour maintenant » n'est proposé que si personne ne le fera.
//
// LANGUE : `swift test` ne tourne pas depuis Fouine.app, `String(localized:)`
// rend donc l'anglais source (même raison que `PageCountAffordanceTests`).

import XCTest
import FouineCore
import FouineCrawl
@testable import FouineApp

final class IgnoreRulesDraftTests: XCTestCase {

    private var scratch: URL!
    private var root: URL { scratch.appendingPathComponent("Perso", isDirectory: true) }

    override func setUpWithError() throws {
        // `/tmp` et non `/private/tmp` exprès : le panneau d'ouverture rend le
        // chemin canonique, et la racine a pu être enregistrée sous l'autre.
        scratch = URL(fileURLWithPath: "/tmp/fouine-ignore-draft-\(UUID().uuidString)",
                      isDirectory: true)
        for folder in ["Perso/Santé/2025", "Perso/Cours", "Autre"] {
            try FileManager.default.createDirectory(
                at: scratch.appendingPathComponent(folder),
                withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func doc(_ sub: String, _ ext: String) -> DocRow {
        DocRow(id: 1, record: DocRecord(volUUID: "V", relPath: "Users/moi/Perso/" + sub,
                                        ext: ext, topFolder: "Perso", size: 1, mtime: 1))
    }

    private var documents: [DocRow] {
        [doc("Santé/bilan.pdf", "pdf"), doc("Santé/2025/prise.pdf", "pdf"),
         doc("Cours/TD.pdf", "pdf"), doc("Cours/notes.md", "md"),
         doc("Cours/INDEX.md", "md"), doc("Cours/plan.docx", "docx")]
    }

    private func draft(stored: [String] = [], file: String? = nil,
                       docs: [DocRow]? = nil) throws -> IgnoreRulesDraft {
        IgnoreRulesDraft(
            rootLabel: "Perso", rootPath: root.path, rootRelPath: "Users/moi/Perso",
            snapshot: .init(stored: try IgnoreRuleSet(validating: stored),
                            file: file.map { IgnoreRules(text: $0) },
                            docs: docs ?? documents))
    }

    // MARK: - Les phrases

    func testEveryRuleReadsInPlainWords() {
        XCTAssertEqual(IgnoreRulesDraft.phrase(for: "Santé/"), "The folder “Santé”")
        XCTAssertEqual(IgnoreRulesDraft.phrase(for: "Cours/Archives/"),
                       "The folder “Cours › Archives”")
        XCTAssertEqual(IgnoreRulesDraft.phrase(for: "*.md"), "Every .md file")
        XCTAssertEqual(IgnoreRulesDraft.phrase(for: "INDEX.md"), "Files named “INDEX.md”")
        XCTAssertEqual(IgnoreRulesDraft.phrase(for: "Cours/INDEX.md"),
                       "“Cours › INDEX.md” in this folder")
        XCTAssertEqual(IgnoreRulesDraft.phrase(for: "*brouillon*"), "Names like “*brouillon*”")
    }

    func testKeptRulesComeFirstAndFileRulesCannotBeRemoved() throws {
        let rows = try draft(stored: ["Santé/"], file: "*.md\n").rows
        XCTAssertEqual(rows.map(\.rule), ["Santé/", "*.md"])
        XCTAssertEqual(rows.map(\.fromFile), [false, true])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    // MARK: - « Ignorer un dossier… »

    func testAFolderInsideTheRootBecomesARule() throws {
        var d = try draft()
        let chosen = "/private" + root.appendingPathComponent("Santé/2025").path
        XCTAssertEqual(d.addFolder(at: chosen), .added)
        XCTAssertEqual(d.draft.rules, ["Santé/2025/"])
        XCTAssertTrue(d.hasChanges)
    }

    func testTheRootItselfAndAFolderOutsideAreRefused() throws {
        var d = try draft()
        XCTAssertEqual(d.addFolder(at: root.path), .refused(.wholeFolder))
        XCTAssertEqual(d.addFolder(at: scratch.appendingPathComponent("Autre").path),
                       .refused(.outsideFolder))
        XCTAssertFalse(d.hasChanges)
        XCTAssertEqual(d.text(for: .refused(.outsideFolder)), "Choose a folder inside “Perso”.")
    }

    func testAFolderAlreadyCoveredIsNotAddedTwice() throws {
        var kept = try draft(stored: ["Santé/"])
        XCTAssertEqual(kept.addFolder(at: root.appendingPathComponent("Santé/2025").path),
                       .alreadySkipped)
        var filed = try draft(file: "sante/\n")
        XCTAssertEqual(filed.addFolder(at: root.appendingPathComponent("Santé").path),
                       .skippedByFile)
        XCTAssertFalse(filed.hasChanges)
    }

    // MARK: - « Ignorer un type de fichier »

    func testAKindOfFileBecomesAnExtensionRule() throws {
        var d = try draft()
        XCTAssertEqual(d.addKindOfFile(".MD"), .added)
        XCTAssertEqual(d.draft.rules, ["*.md"])
        XCTAssertEqual(d.addKindOfFile("md"), .alreadySkipped)

        // Une règle de NOM ne rend pas un type entier « déjà ignoré ».
        var named = try draft(stored: ["x.pdf"])
        XCTAssertEqual(named.addKindOfFile("pdf"), .added)
    }

    func testTheMenuOffersOnlyKindsPresentAndNotYetSkipped() throws {
        let d = try draft(file: "*.docx\n")
        XCTAssertEqual(d.kindsOfFile.map(\.ext), ["pdf", "md"], "les plus nombreux d'abord")
        XCTAssertEqual(d.kindsOfFile.map(\.count), [3, 2])
        XCTAssertTrue(try draft(docs: []).kindsOfFile.isEmpty)
    }

    // MARK: - « Ignorer les fichiers nommés… »

    func testATypedNameIsValidated() throws {
        var d = try draft()
        XCTAssertEqual(d.addFileName(" INDEX.md \n"), .added)
        XCTAssertEqual(d.draft.rules, ["INDEX.md"])
        XCTAssertEqual(d.addFileName("Cours/INDEX.md"), .refused(.notOneName))
        XCTAssertEqual(d.addFileName("a.md\nb.md"), .refused(.notOneName))
        XCTAssertEqual(d.addFileName("!INDEX.md"), .refused(.reservedFirstCharacter))
        XCTAssertEqual(d.addFileName("#notes"), .refused(.reservedFirstCharacter))
        XCTAssertEqual(d.draft.rules, ["INDEX.md"], "un refus n'ajoute rien")
    }

    func testANameUnderAnExtensionRuleIsAlreadySkipped() throws {
        var d = try draft(stored: ["*.md"])
        XCTAssertEqual(d.addFileName("INDEX.md"), .alreadySkipped)
        XCTAssertEqual(d.text(for: .alreadySkipped), "Fouine already skips this.")
    }

    // MARK: - La conséquence

    func testTheConsequenceIsSaidBeforeSaving() throws {
        var d = try draft()
        XCTAssertNil(d.consequence, "rien d'ajouté : rien à dire")
        XCTAssertTrue(d.consequenceSentences.isEmpty)

        _ = d.addFolder(at: root.appendingPathComponent("Santé").path)
        XCTAssertEqual(d.consequence, .leaving(2))
        XCTAssertEqual(d.consequenceSentences, [
            "About 2 document(s) will leave the index at the next update. Your files are not touched.",
        ])

        _ = d.addFileName("absent.txt")
        XCTAssertEqual(d.consequence, .leaving(2), "le compte porte sur tout le brouillon")
    }

    func testNothingLeavingAndAnUnknownCountAreSaidToo() throws {
        var none = try draft()
        _ = none.addFileName("absent.txt")
        XCTAssertEqual(none.consequence, .nothingLeaves)

        var blind = IgnoreRulesDraft(
            rootLabel: "Perso", rootPath: root.path, rootRelPath: "Users/moi/Perso",
            snapshot: .init(stored: IgnoreRuleSet(), file: nil, docs: nil))
        _ = blind.addFileName("INDEX.md")
        XCTAssertEqual(blind.consequence, .unknown)
        XCTAssertTrue(blind.kindsOfFile.isEmpty)
    }

    func testRemovingARuleSaysWhatComesBackAndSavingSettlesTheDraft() throws {
        var d = try draft(stored: ["Santé/", "*.md"])
        d.remove("Santé/")
        XCTAssertTrue(d.hasChanges)
        XCTAssertNil(d.consequence)
        XCTAssertEqual(d.consequenceSentences,
                       ["What you no longer skip comes back at the next update."])
        d.markSaved()
        XCTAssertFalse(d.hasChanges)
        XCTAssertEqual(d.saved.rules, ["*.md"])
    }

    // MARK: - Après l'enregistrement

    func testUpdateNowIsOfferedOnlyWhenNobodyWillUpdate() {
        XCTAssertFalse(IgnoreRulesDraft.offersUpdateNow(agentState: .active))
        XCTAssertFalse(IgnoreRulesDraft.offersUpdateNow(agentState: .waitingFirstReport))
        for state in [AgentOperationalState.off, .registeredButSilent, .requiresApproval,
                      .notFound, .unknown] {
            XCTAssertTrue(IgnoreRulesDraft.offersUpdateNow(agentState: state), "\(state)")
        }
        XCTAssertNotEqual(IgnoreRulesDraft.savedText(automaticUpdates: true),
                          IgnoreRulesDraft.savedText(automaticUpdates: false))
    }
}
