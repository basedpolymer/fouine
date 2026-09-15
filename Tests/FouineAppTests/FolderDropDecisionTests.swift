// FolderDropDecisionTests.swift — un dossier lâché sur l'icône du Dock (DD2).
// Propriété : A-App.
//
// La décision est pure : les cinq situations se jouent en mémoire, sans Finder,
// sans fenêtre et sans disque — c'est l'appelant qui regarde ce qu'il y a au
// bout du chemin.

import XCTest
@testable import FouineApp

final class FolderDropDecisionTests: XCTestCase {

    private static let roots = [
        DroppedFolderRoot(label: "Cours", path: "/Users/x/Documents/Cours"),
        DroppedFolderRoot(label: "Factures", path: "/Users/x/Factures"),
    ]

    private func decide(_ path: String, kind: DeepLinkFileKind = .directory,
                        roots: [DroppedFolderRoot] = FolderDropDecisionTests.roots)
        -> FolderDropDecision.Decision {
        FolderDropDecision.decide(url: URL(fileURLWithPath: path), kind: kind,
                                  roots: roots)
    }

    // MARK: - Les trois décisions

    func testARootItselfPreparesItsFilter() {
        XCTAssertEqual(decide("/Users/x/Documents/Cours"), .search(label: "Cours"))
    }

    /// `dossier:` ne filtre QUE sur la racine : le sous-dossier déposé prépare
    /// l'étiquette de sa racine, jamais la sienne — un filtre plus fin
    /// n'existe pas, et l'inventer rendrait zéro résultat.
    func testASubfolderPreparesTheFilterOfItsRoot() {
        XCTAssertEqual(decide("/Users/x/Documents/Cours/Thermo/TD"),
                       .search(label: "Cours"))
    }

    func testAFolderOutsideEveryRootIsProposedForAdding() {
        let url = URL(fileURLWithPath: "/Users/x/Ailleurs")
        XCTAssertEqual(decide("/Users/x/Ailleurs"), .proposeAdd(url))
    }

    /// Le piège du préfixe sans `/` : `Coursier` n'est pas sous `Cours`.
    func testAFolderWhoseNameStartsLikeARootIsNotUnderIt() {
        let url = URL(fileURLWithPath: "/Users/x/Documents/Coursier")
        XCTAssertEqual(decide("/Users/x/Documents/Coursier"), .proposeAdd(url))
    }

    func testTheDeepestRootWins() {
        let roots = Self.roots + [
            DroppedFolderRoot(label: "Documents", path: "/Users/x/Documents"),
        ]
        XCTAssertEqual(decide("/Users/x/Documents/Cours/Thermo", roots: roots),
                       .search(label: "Cours"))
    }

    // MARK: - Ce qui n'est pas un dossier

    func testAFileOpensNothing() {
        XCTAssertEqual(decide("/Users/x/Ailleurs/note.pdf", kind: .regular), .ignore)
    }

    /// Un `.pages` ou un `.rtfd` est un dossier pour le système de fichiers,
    /// un fichier pour qui le dépose : Fouine n'ouvre pas les documents.
    func testAPackageOpensNothing() {
        XCTAssertEqual(decide("/Users/x/Ailleurs/memoire.pages", kind: .package),
                       .ignore)
    }

    // MARK: - La forme Unicode

    /// Le Finder peut remettre un chemin DÉCOMPOSÉ (« é » = e + accent) là où
    /// la racine enregistrée est composée : sans normalisation, Fouine
    /// proposerait d'ajouter une seconde fois un dossier qu'elle suit déjà.
    func testADecomposedPathMatchesAComposedRoot() {
        let roots = [DroppedFolderRoot(
            label: "Réunions",
            path: "/Users/x/Réunions".precomposedStringWithCanonicalMapping)]
        let dropped = "/Users/x/Réunions/2026".decomposedStringWithCanonicalMapping
        XCTAssertEqual(decide(dropped, roots: roots), .search(label: "Réunions"))
    }

    // MARK: - Le texte posé dans le champ

    /// Guillemets toujours : l'étiquette par défaut est le nom du dossier, et
    /// un nom sur deux porte une espace (audit A1m-04). Espace finale toujours :
    /// le premier mot tapé ne colle pas au filtre.
    func testTheQueryQuotesTheLabelAndEndsWithASpace() {
        XCTAssertEqual(FolderDropDecision.searchText(label: "Mes cours"),
                       "dossier:\"Mes cours\" ")
    }

    // MARK: - La garde anti-doublon

    func testTheSameURLTwiceInTheSameSecondIsOneDrop() {
        var guardState = RecentOpenedURLs()
        let url = URL(fileURLWithPath: "/Users/x/Ailleurs")
        let now = Date()
        XCTAssertTrue(guardState.accept(url, now: now))
        XCTAssertFalse(guardState.accept(url, now: now.addingTimeInterval(0.05)))
    }

    func testTheSameFolderDroppedAgainLaterIsASecondDrop() {
        var guardState = RecentOpenedURLs()
        let url = URL(fileURLWithPath: "/Users/x/Ailleurs")
        let now = Date()
        XCTAssertTrue(guardState.accept(url, now: now))
        XCTAssertTrue(guardState.accept(url, now: now.addingTimeInterval(2)))
    }

    func testTwoDifferentFoldersBothPassTheGuard() {
        var guardState = RecentOpenedURLs()
        let now = Date()
        XCTAssertTrue(guardState.accept(URL(fileURLWithPath: "/a"), now: now))
        XCTAssertTrue(guardState.accept(URL(fileURLWithPath: "/b"), now: now))
    }
}
