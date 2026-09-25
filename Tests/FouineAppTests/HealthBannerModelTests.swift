// HealthBannerModelTests.swift — tests du modèle de bandeau de santé (audit H4, registre I1).
// Propriété : A-App. SPEC §5.6 (amendement du 03/09/2026 : règle vert/orange/rouge).
//
// Les tests comparent le CAS de `HealthRow.Message` et le geste, jamais une
// clé ou une phrase : la phrase est l'affaire de `localizedText`, vérifiée à
// part pour ce qu'elle ne doit PAS dire (« verrou », « pid », « vecteur »).

import XCTest
import FouineCore
@testable import FouineApp

final class HealthBannerModelTests: XCTestCase {

    private func root(id: Int64, label: String, mounted: Bool = true, readable: Bool = true,
                      enabled: Bool = true,
                      probeReason: RootProbe.Reason? = nil) -> RootStatus {
        RootStatus(
            record: RootRecord(id: id, volUUID: "U\(id)", relPath: label.lowercased(),
                               label: label, enabled: enabled),
            absolutePath: mounted ? "/Volumes/Data/\(label)" : nil,
            mounted: mounted, readable: readable, reason: nil,
            probeReason: probeReason)
    }

    private func report(agent: AgentOperationalState = .active,
                        lock: WriteLock.LockStatus = .free,
                        installed: Bool = true, vectors: Int = 10,
                        roots: [RootStatus]? = nil,
                        currentPID: pid_t = 1) -> HealthBannerReport {
        HealthBannerEvaluator.evaluate(
            agentState: agent, lockStatus: lock,
            semanticInstalled: installed, hasVectors: vectors > 0,
            roots: roots ?? [root(id: 1, label: "Docs")],
            currentPID: currentPID)
    }

    // MARK: - Tout va bien

    func testNominalReportIsAllGreenWithoutButtons() {
        let r = report()
        XCTAssertTrue(r.isAllGreen)
        XCTAssertEqual(r.maxSeverity, .green)
        XCTAssertEqual(r.agentRow.message, .backgroundIndexingOn)
        XCTAssertEqual(r.writeLockRow.message, .indexAvailable)
        XCTAssertEqual(r.semanticRow.message, .semanticReady)
        XCTAssertEqual(r.rootsRow.message, .foldersAllAccessible)
        for row in r.rows {
            XCTAssertNil(row.action, "une ligne verte n'a pas besoin de bouton : \(row.kind)")
        }
    }

    // MARK: - 1. Indexation en arrière-plan

    func testAgentStates() {
        let on = report(agent: .active).agentRow
        XCTAssertEqual(on.severity, .green)
        XCTAssertEqual(on.message, .backgroundIndexingOn)

        let starting = report(agent: .waitingFirstReport).agentRow
        XCTAssertEqual(starting.severity, .green)
        XCTAssertEqual(starting.message, .backgroundIndexingStarting)

        // Éteint par l'utilisateur : son choix, pas un avertissement.
        let off = report(agent: .off).agentRow
        XCTAssertEqual(off.severity, .green)
        XCTAssertEqual(off.message, .backgroundIndexingOff)
        XCTAssertNil(off.action)

        let silent = report(agent: .registeredButSilent).agentRow
        XCTAssertEqual(silent.severity, .orange)
        XCTAssertEqual(silent.message, .backgroundIndexingNotStarting)
        XCTAssertEqual(silent.action, .reregisterAgent)

        let approval = report(agent: .requiresApproval).agentRow
        XCTAssertEqual(approval.severity, .orange)
        XCTAssertEqual(approval.message, .backgroundIndexingAwaitingApproval)
        XCTAssertEqual(approval.action, .openLoginItems)

        // Introuvable, copie hors d'Applications : orange, pas rouge — rien
        // n'est perdu.
        for copies in [AppCopiesReport.Verdict.notInstalled,
                       .outsideApplications(path: "/Users/moi/Downloads/Fouine.app")] {
            let notFound = HealthBannerEvaluator.evaluate(
                agentState: .notFound, appCopies: copies, lockStatus: .free,
                semanticInstalled: true, hasVectors: true,
                roots: [root(id: 1, label: "Docs")]).agentRow
            XCTAssertEqual(notFound.severity, .orange, "\(copies)")
            XCTAssertEqual(notFound.message, .backgroundIndexingServiceMissing, "\(copies)")
            XCTAssertEqual(notFound.action, .reregisterAgent, "\(copies)")
        }

        // Introuvable, copie unique dans Applications : c'est l'interrupteur
        // éteint. `smd` répond « introuvable » quelques secondes après
        // `unregister()` (25/09/2026) ; le bandeau disait « Fouine doit être
        // dans le dossier Applications » à une copie qui y était.
        let switchedOff = report(agent: .notFound).agentRow
        XCTAssertEqual(switchedOff.severity, .green)
        XCTAssertEqual(switchedOff.message, .backgroundIndexingOff)
        XCTAssertNil(switchedOff.action)

        let unknown = report(agent: .unknown).agentRow
        XCTAssertEqual(unknown.severity, .green)
        XCTAssertEqual(unknown.message, .backgroundIndexingUnknown)
        XCTAssertNil(unknown.action)
    }

    // MARK: - 2. Index (verrou d'écriture)

    /// Un verrou TENU est une activité normale : vert, formulé comme telle,
    /// avec l'heure de début et sans bouton.
    func testHeldLockIsNormalActivity() {
        let since = Date(timeIntervalSince1970: 1_756_900_000)
        for role in [LockRole.agent, .cli, .app] {
            let holder = LockHolder(pid: getpid(), role: role, since: since)
            let row = report(lock: .held(holder)).writeLockRow
            XCTAssertEqual(row.severity, .green)
            XCTAssertEqual(row.message, .indexUpdating(by: role, since: holder.clockText,
                                                       ownProcess: false))
            XCTAssertNil(row.action)
            XCTAssertTrue(row.localizedText.contains(holder.clockText), row.localizedText)
        }
    }

    /// L'application reconnaît SA PROPRE écriture (BU-31) : le pid du
    /// détenteur, et pas son rôle — une seconde Fouine ouverte sur la même
    /// base écrirait sous le même rôle, et serait, elle, un autre programme.
    func testItsOwnWriteIsRecognisedByThePID() {
        let holder = LockHolder(pid: 4242, role: .app, since: Date())
        let mine = report(lock: .held(holder), currentPID: 4242).writeLockRow
        XCTAssertEqual(mine.message, .indexUpdating(by: .app, since: holder.clockText,
                                                    ownProcess: true))
        let other = report(lock: .held(holder), currentPID: 99).writeLockRow
        XCTAssertEqual(other.message, .indexUpdating(by: .app, since: holder.clockText,
                                                     ownProcess: false))
        XCTAssertTrue(mine.localizedText.contains(holder.clockText))
    }

    /// Un verrou PÉRIMÉ se répare seul à la prochaine écriture : vert, texte
    /// neutre, pas de « Réessayer ». (Le bandeau H4 l'affichait en rouge.)
    func testStaleLockIsGreenWithoutAction() {
        let dead = LockHolder(pid: 999_999, role: .cli, since: Date())
        let row = report(lock: .stale(dead)).writeLockRow
        XCTAssertEqual(row.severity, .green)
        XCTAssertEqual(row.message, .indexAvailable)
        XCTAssertNil(row.action)
        XCTAssertTrue(report(lock: .stale(dead)).isAllGreen)
    }

    // MARK: - 3. Recherche sémantique

    /// Une option absente ou en préparation n'est pas un avertissement.
    func testSemanticStatesAreAllGreen() {
        let ready = report(installed: true, vectors: 42).semanticRow
        XCTAssertEqual(ready.severity, .green)
        XCTAssertEqual(ready.message, .semanticReady)

        let preparing = report(installed: true, vectors: 0).semanticRow
        XCTAssertEqual(preparing.severity, .green)
        XCTAssertEqual(preparing.message, .semanticPreparing)

        let missing = report(installed: false, vectors: 0).semanticRow
        XCTAssertEqual(missing.severity, .green)
        XCTAssertEqual(missing.message, .semanticNotInstalled)

        for row in [ready, preparing, missing] {
            XCTAssertNil(row.action)
        }
    }

    // MARK: - 4. Dossiers

    func testRootsStates() {
        let none = report(roots: []).rootsRow
        XCTAssertEqual(none.severity, .green)
        XCTAssertEqual(none.message, .noFolders)
        XCTAssertEqual(none.action, .chooseRoots, "le seul bouton d'une ligne verte : ajouter un dossier")

        let ok = root(id: 1, label: "Docs")
        let unmounted = root(id: 2, label: "External", mounted: false, readable: false)
        let unreadable = root(id: 3, label: "Secret", readable: false,
                              probeReason: .permissionDenied)

        let disk = report(roots: [ok, unmounted]).rootsRow
        XCTAssertEqual(disk.severity, .orange)
        XCTAssertEqual(disk.message, .diskNotPluggedIn(folder: "External"))
        XCTAssertNil(disk.action, "le geste est physique : rebrancher le disque")

        let denied = report(roots: [ok, unreadable]).rootsRow
        XCTAssertEqual(denied.severity, .orange)
        XCTAssertEqual(denied.message, .folderNotAllowed(folder: "Secret"))
        XCTAssertEqual(denied.action, .openPrivacySettings)

        // Le disque démonté passe avant le dossier illisible : un volume
        // absent rend ses dossiers illisibles, et c'est lui qu'il faut nommer.
        XCTAssertEqual(report(roots: [unreadable, unmounted]).rootsRow.message,
                       .diskNotPluggedIn(folder: "External"))
    }

    /// Seul un refus de macOS mène aux Réglages Système : un dossier déplacé,
    /// vide ou en erreur n'a rien à autoriser (suite de PB1).
    func testOnlyAPermissionDenialOpensPrivacySettings() {
        let moved = root(id: 4, label: "Moved", readable: false, probeReason: .missing)
        let row = report(roots: [moved]).rootsRow
        XCTAssertEqual(row.severity, .orange)
        XCTAssertEqual(row.message, .folderNotFound(folder: "Moved"))
        XCTAssertNil(row.action)

        let others: [RootProbe.Reason?] = [.noReadableFile, .system("Input/output error"), nil]
        for reason in others {
            let broken = root(id: 5, label: "Broken", readable: false, probeReason: reason)
            let row = report(roots: [broken]).rootsRow
            XCTAssertEqual(row.severity, .orange)
            XCTAssertEqual(row.message, .folderCannotBeRead(folder: "Broken"),
                           "\(String(describing: reason))")
            XCTAssertNil(row.action)
        }

        // Le refus passe devant, où qu'il soit dans la liste : c'est le seul
        // qu'un bouton répare. Puis le dossier introuvable.
        let denied = root(id: 6, label: "Secret", readable: false,
                          probeReason: .permissionDenied)
        let empty = root(id: 7, label: "Empty", readable: false, probeReason: .noReadableFile)
        XCTAssertEqual(report(roots: [moved, empty, denied]).rootsRow.message,
                       .folderNotAllowed(folder: "Secret"))
        XCTAssertEqual(report(roots: [empty, moved]).rootsRow.message,
                       .folderNotFound(folder: "Moved"))
    }

    /// Un dossier DÉSACTIVÉ par l'utilisateur n'est plus une promesse : son
    /// disque rangé ne colore pas le bandeau.
    func testDisabledRootsDoNotWarn() {
        let ok = root(id: 1, label: "Docs")
        let parked = root(id: 2, label: "Archive", mounted: false, readable: false, enabled: false)
        let row = report(roots: [ok, parked]).rootsRow
        XCTAssertEqual(row.severity, .green)
        XCTAssertEqual(row.message, .foldersAllAccessible)
    }

    // MARK: - Registre et règle de sévérité

    /// Un agent qui ne démarre pas alors que macOS connaît plusieurs
    /// Fouine.app : le bandeau NOMME cette cause (lot J2). Sans elle,
    /// l'utilisateur presse « Ré-enregistrer » en boucle sans effet — c'est ce
    /// qui s'est passé le 03/09/2026.
    func testSeveralCopiesNameTheCause() {
        let several = AppCopiesReport.Verdict.multipleCopies(extras: ["/Users/moi/fouine/Fouine.app"])
        for state in [AgentOperationalState.registeredButSilent, .notFound] {
            let row = HealthBannerEvaluator.evaluate(
                agentState: state, appCopies: several, lockStatus: .free,
                semanticInstalled: true, hasVectors: true,
                roots: [root(id: 1, label: "Docs")]).agentRow
            XCTAssertEqual(row.message, .backgroundIndexingSeveralCopies, "état \(state)")
            XCTAssertEqual(row.severity, .orange)
            XCTAssertEqual(row.action, .reregisterAgent)
        }
        // Sans copie parasite, le message reste celui d'avant.
        let plain = HealthBannerEvaluator.evaluate(
            agentState: .registeredButSilent, lockStatus: .free,
            semanticInstalled: true, hasVectors: true,
            roots: [root(id: 1, label: "Docs")]).agentRow
        XCTAssertEqual(plain.message, .backgroundIndexingNotStarting)
        // Un agent SAIN ne se fait pas alarmer par une copie de trop : la ligne
        // ne parle que d'un agent qui ne démarre pas.
        let healthy = HealthBannerEvaluator.evaluate(
            agentState: .active, appCopies: several, lockStatus: .free,
            semanticInstalled: true, hasVectors: true,
            roots: [root(id: 1, label: "Docs")]).agentRow
        XCTAssertEqual(healthy.message, .backgroundIndexingOn)
        XCTAssertEqual(healthy.severity, .green)
    }

    /// Rien dans le bandeau ne dit « verrou », « pid », « vecteur » ou
    /// « schéma » : le public n'est pas technicien (CLAUDE.md).
    func testLocalizedTextsSpeakToNonTechnicians() {
        let holder = LockHolder(pid: getpid(), role: .agent, since: Date())
        let messages: [HealthRow.Message] = [
            .backgroundIndexingOn, .backgroundIndexingStarting, .backgroundIndexingOff,
            .backgroundIndexingNotStarting, .backgroundIndexingAwaitingApproval,
            .backgroundIndexingServiceMissing, .backgroundIndexingSeveralCopies,
            .backgroundIndexingUnknown,
            .indexAvailable,
            .indexUpdating(by: .agent, since: holder.clockText, ownProcess: false),
            .indexUpdating(by: .cli, since: holder.clockText, ownProcess: false),
            .indexUpdating(by: .app, since: holder.clockText, ownProcess: false),
            .indexUpdating(by: .app, since: holder.clockText, ownProcess: true),
            .semanticReady, .semanticPreparing, .semanticNotInstalled,
            .noFolders, .diskNotPluggedIn(folder: "X"), .folderNotAllowed(folder: "X"),
            .folderNotFound(folder: "X"), .folderCannotBeRead(folder: "X"),
            .foldersAllAccessible,
        ]
        for message in messages {
            let text = message.localizedText.lowercased()
            XCTAssertFalse(text.isEmpty)
            for banned in ["lock", "pid", "vector", "schema", "rowid", "launchd", "verrou", "vecteur"] {
                XCTAssertFalse(text.contains(banned), "« \(banned) » dans « \(text) »")
            }
        }
    }

    /// Rouge seulement si des données sont en danger ou une fonction cassée :
    /// aucune des situations évaluées ici n'en est une.
    func testNoEvaluatedSituationIsRed() {
        let holder = LockHolder(pid: getpid(), role: .cli, since: Date())
        let dead = LockHolder(pid: 999_999, role: .agent, since: Date())
        let agents: [AgentOperationalState] = [.off, .waitingFirstReport, .active,
                                               .registeredButSilent, .requiresApproval,
                                               .notFound, .unknown]
        let locks: [WriteLock.LockStatus] = [.free, .held(holder), .stale(dead)]
        let rootSets: [[RootStatus]] = [
            [], [root(id: 1, label: "Docs")],
            [root(id: 2, label: "Ext", mounted: false, readable: false)],
            [root(id: 3, label: "Secret", readable: false)],
        ]
        for agent in agents {
            for lock in locks {
                for installed in [true, false] {
                    for roots in rootSets {
                        let r = report(agent: agent, lock: lock, installed: installed,
                                       vectors: installed ? 0 : 3, roots: roots)
                        XCTAssertLessThan(r.maxSeverity, .red,
                                          "\(agent) \(lock) installed=\(installed) roots=\(roots.count)")
                    }
                }
            }
        }
    }
}

/// A2-13 — la pastille « Tout fonctionne » ne masque plus le seul geste que le
/// §5.6 amendé exige sur une ligne VERTE.
final class HealthBannerGreenActionTests: XCTestCase {

    /// Aucune racine : les quatre lignes sont vertes, et pourtant il reste
    /// « Ajouter un dossier… » à proposer. Le cas s'atteint dès que la lecture
    /// des racines échoue — la barre latérale s'affiche alors, et disait
    /// « Tout fonctionne ».
    private var noFolders: HealthBannerReport {
        HealthBannerEvaluator.evaluate(
            agentState: .off, lockStatus: .free,
            semanticInstalled: false, hasVectors: false, roots: [])
    }

    func testGreenRowWithAnActionIsNotAllGreen() {
        let r = noFolders
        XCTAssertEqual(r.maxSeverity, .green)
        XCTAssertEqual(r.rootsRow.message, .noFolders)
        XCTAssertEqual(r.rootsRow.action, .chooseRoots)
        XCTAssertFalse(r.isAllGreen,
                       "A2-13 : la pastille masquait « Ajouter un dossier… »")
    }

    /// Et la barre latérale ne rend QUE cette ligne : les trois autres n'ont
    /// rien à dire.
    func testOnlyTheActionableRowIsDisplayed() {
        let rows = noFolders.rowsToDisplay
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.kind, .roots)
        XCTAssertEqual(rows.first?.action, .chooseRoots)
    }

    /// Rien n'a bougé pour le cas nominal : une racine lisible, tout est vert,
    /// aucun geste, et la pastille reste.
    func testNominalStillShowsTheBadge() {
        let root = RootStatus(
            record: RootRecord(id: 1, volUUID: "U1", relPath: "docs",
                               label: "Docs", enabled: true),
            absolutePath: "/Volumes/Data/Docs", mounted: true,
            readable: true, reason: nil)
        let r = HealthBannerEvaluator.evaluate(
            agentState: .active, lockStatus: .free,
            semanticInstalled: true, hasVectors: true, roots: [root])
        XCTAssertTrue(r.isAllGreen)
        XCTAssertTrue(r.rowsToDisplay.isEmpty)
    }

    /// Dès qu'une ligne n'est pas verte, le bandeau reste complet : on ne
    /// cache pas le contexte d'un avertissement.
    func testOrangeReportKeepsEveryRow() {
        let unreadable = RootStatus(
            record: RootRecord(id: 1, volUUID: "U1", relPath: "docs",
                               label: "Docs", enabled: true),
            absolutePath: "/Volumes/Data/Docs", mounted: true,
            readable: false, reason: nil)
        let r = HealthBannerEvaluator.evaluate(
            agentState: .active, lockStatus: .free,
            semanticInstalled: true, hasVectors: true, roots: [unreadable])
        XCTAssertEqual(r.maxSeverity, .orange)
        XCTAssertEqual(r.rowsToDisplay.count, 4)
    }
}

