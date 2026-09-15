// LockHolderTests.swift — le format d'une ligne de `fouine.lock` (audit F3).
// Propriété : A-Core.
//
// Le format est un CONTRAT entre versions : un binaire à jour doit pouvoir lire
// le verrou laissé par un binaire plus ancien, et l'inverse. D'où le jeton de
// version, et d'où ces cas — une ligne illisible ne doit JAMAIS nommer un
// détenteur au hasard, elle doit rendre `nil`.

import XCTest
import FouineCore
@testable import FouineIndex

final class LockHolderTests: XCTestCase {

    func testLineRoundTrip() throws {
        let since = Date(timeIntervalSince1970: 1_756_800_000)
        let holder = LockHolder(pid: 4242, role: .agent, since: since)
        let line = holder.line
        XCTAssertTrue(line.hasPrefix("fouine-lock 1 "), line)
        XCTAssertTrue(line.contains("pid=4242"), line)
        XCTAssertTrue(line.contains("role=agent"), line)
        XCTAssertTrue(line.hasSuffix("\n"), "la ligne doit être terminée")

        let parsed = try XCTUnwrap(LockHolder.parse(line))
        XCTAssertEqual(parsed.pid, 4242)
        XCTAssertEqual(parsed.role, .agent)
        // L'ISO-8601 est à la seconde : c'est la précision du champ.
        XCTAssertEqual(parsed.since.timeIntervalSince1970,
                       since.timeIntervalSince1970, accuracy: 1)
    }

    func testUnreadableLinesNameNobody() {
        for text in ["", "\n", "verrouille", "fouine-lock 1", "pid=12",
                     "fouine-lock 1 pid=zero role=cli",
                     "fouine-lock 1 pid=0 role=cli",
                     "fouine-lock 1 pid=-3 role=cli"] {
            XCTAssertNil(LockHolder.parse(text), "« \(text) » ne doit rien nommer")
        }
    }

    /// Un champ inconnu ou manquant ne fait pas échouer la lecture : seul `pid`
    /// est exigé. C'est ce qui permettra d'ajouter un champ sans casser les
    /// binaires déjà installés.
    func testUnknownFieldsAreIgnoredAndRoleDefaults() throws {
        let parsed = try XCTUnwrap(
            LockHolder.parse("fouine-lock 2 pid=7 host=ailleurs role=hublot\n"))
        XCTAssertEqual(parsed.pid, 7)
        XCTAssertEqual(parsed.role, .cli, "un rôle inconnu retombe sur cli")
    }

    /// `kill(pid, 0)` : seul ESRCH prouve l'absence. Le processus courant est
    /// vivant, `launchd` (pid 1) l'est aussi et ne nous appartient pas — c'est
    /// le cas EPERM, celui qu'il ne faut surtout pas prendre pour un mort.
    func testLivenessUsesESRCHOnly() {
        XCTAssertTrue(LockHolder(pid: getpid(), role: .cli, since: Date()).isAlive)
        XCTAssertTrue(LockHolder(pid: 1, role: .agent, since: Date()).isAlive,
                      "launchd est vivant même s'il ne nous appartient pas")
    }

    /// Le message d'occupation porte des DONNÉES, pas une phrase (palier 3.2).
    ///
    /// C'est ce qui permet à trois boucles de reprise (`EmbedRun`,
    /// `AgentStatusWriter`, `GRDBStore+Settings`) de distinguer « verrou tenu »
    /// de « base cassée » sans dépendre d'une phrase française, et à l'app de
    /// rendre la même information dans la langue de l'utilisateur.
    func testBusyMessageCarriesTheHolderAsData() throws {
        let since = Date(timeIntervalSince1970: 1_756_800_000)
        let holder = LockHolder(pid: getpid(), role: .agent, since: since)
        let message = WriteLock.busyMessage(holder: holder,
                                            path: "/tmp/fouine.lock")
        XCTAssertTrue(message.hasPrefix(WriteLock.busyToken), message)

        let error = FouineError.databaseFailure(message)
        XCTAssertTrue(WriteLock.isBusy(error))
        let busy = try XCTUnwrap(WriteLock.busy(error))
        XCTAssertEqual(busy.path, "/tmp/fouine.lock")
        XCTAssertEqual(busy.holder?.pid, getpid())
        XCTAssertEqual(busy.holder?.role, .agent)
        XCTAssertEqual(try XCTUnwrap(busy.holder).since.timeIntervalSince1970,
                       since.timeIntervalSince1970, accuracy: 1)

        // Rien de ce qui n'est pas un verrou ne doit se faire prendre pour un.
        XCTAssertNil(WriteLock.busy(FouineError.databaseFailure("disque plein")))
        XCTAssertNil(WriteLock.busy(FouineError.ocr("Vision")))
    }

    /// La phrase du §4.3 se REFAIT depuis les données, au mot près : c'est elle
    /// que lisent la CLI, l'agent et `docs.err`.
    ///
    /// Ce test fige la FORME (le détenteur est nommé, le message ne se
    /// préfixe pas) et, depuis que la CLI parle anglais (palier 3.5), les mots
    /// du §4.3 : ce sont eux que `docs.err` porte et que la documentation cite.
    func testBusyPhraseNamesTheHolderAndIsNotPrefixed() {
        let holder = LockHolder(pid: getpid(), role: .agent, since: Date())
        let message = WriteLock.busyMessage(holder: holder,
                                            path: "/tmp/fouine.lock")
        let phrase = IndexText.describe(FouineError.databaseFailure(message))
        XCTAssertTrue(phrase.contains("the agent"), phrase)
        XCTAssertTrue(phrase.contains("pid \(getpid())"), phrase)
        XCTAssertFalse(phrase.hasPrefix("database:"),
                       "le message d'occupation est déjà une phrase complète")
        XCTAssertEqual(IndexText.describe(FouineError.databaseFailure("disque plein")),
                       "database: disque plein")
    }

    /// Un détenteur mort ou non nommé ne part pas dans le message : on ne nomme
    /// jamais un détenteur incertain.
    func testBusyMessageWithoutHolderSaysSo() throws {
        let message = WriteLock.busyMessage(holder: nil, path: "/tmp/fouine.lock")
        let error = FouineError.databaseFailure(message)
        XCTAssertTrue(WriteLock.isBusy(error))
        let busy = try XCTUnwrap(WriteLock.busy(error))
        XCTAssertNil(busy.holder)
        XCTAssertEqual(busy.path, "/tmp/fouine.lock")
        XCTAssertTrue(IndexText.describe(error).contains("/tmp/fouine.lock"))
    }
}
