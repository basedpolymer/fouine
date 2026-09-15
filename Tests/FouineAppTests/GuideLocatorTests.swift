// GuideLocatorTests.swift — le guide se trouve dans le bundle, dans la langue
// de l'application (BU-27, DC1). Propriété : A-App.
//
// `swift test` ne tourne pas depuis Fouine.app : `Bundle.main` n'a aucun
// Guide.*.md, et c'est le cas « hors bundle » qu'on veut voir échouer
// proprement. Le cas nominal se joue sur un bundle FABRIQUÉ dans un dossier
// temporaire — même forme que celui que `Packaging/bundle.sh` produit, qui
// copie les DEUX langues.

import XCTest
@testable import FouineApp

final class GuideLocatorTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("guide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Un `.bundle` minimal : Contents/Resources, comme Fouine.app.
    private func makeBundle(english: String?, french: String?) throws -> Bundle {
        let root = directory.appendingPathComponent("Test-\(UUID().uuidString).bundle")
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources,
                                                withIntermediateDirectories: true)
        if let english {
            try english.write(to: resources.appendingPathComponent("Guide.en.md"),
                              atomically: true, encoding: .utf8)
        }
        if let french {
            try french.write(to: resources.appendingPathComponent("Guide.fr.md"),
                             atomically: true, encoding: .utf8)
        }
        return try XCTUnwrap(Bundle(url: root))
    }

    // MARK: - Trouver le guide dans sa langue

    func testTheGuideFollowsTheLanguageOfTheApplication() throws {
        let bundle = try makeBundle(english: "# Guide", french: "# Guide")
        XCTAssertEqual(try XCTUnwrap(GuideLocator.url(bundle: bundle,
                                                      languageCode: "fr")).lastPathComponent,
                       "Guide.fr.md")
        XCTAssertEqual(try XCTUnwrap(GuideLocator.url(bundle: bundle,
                                                      languageCode: "fr-CA")).lastPathComponent,
                       "Guide.fr.md")
        XCTAssertEqual(try XCTUnwrap(GuideLocator.url(bundle: bundle,
                                                      languageCode: "en")).lastPathComponent,
                       "Guide.en.md")
    }

    /// Toute autre langue lit l'anglais, qui fait foi — langue inconnue comprise.
    func testAnyOtherLanguageReadsTheEnglishGuide() throws {
        let bundle = try makeBundle(english: "# Guide", french: "# Guide")
        for code in ["de", "es", "pt-BR", nil] {
            XCTAssertEqual(try XCTUnwrap(GuideLocator.url(bundle: bundle,
                                                          languageCode: code)).lastPathComponent,
                           "Guide.en.md", "langue \(code ?? "nil")")
        }
    }

    /// Une copie à qui il manque une langue sert l'autre : un guide dans la
    /// mauvaise langue se lit, une fenêtre vide non.
    func testAMissingTranslationFallsBackOnTheOtherLanguage() throws {
        let englishOnly = try makeBundle(english: "# Guide", french: nil)
        XCTAssertEqual(try XCTUnwrap(GuideLocator.url(bundle: englishOnly,
                                                      languageCode: "fr")).lastPathComponent,
                       "Guide.en.md")

        let frenchOnly = try makeBundle(english: nil, french: "# Guide")
        XCTAssertEqual(try XCTUnwrap(GuideLocator.url(bundle: frenchOnly,
                                                      languageCode: "en")).lastPathComponent,
                       "Guide.fr.md")
    }

    func testWithoutTheGuideThereIsNoURLAndNoPage() throws {
        let bundle = try makeBundle(english: nil, french: nil)
        XCTAssertNil(GuideLocator.url(bundle: bundle, languageCode: "fr"))
        XCTAssertNil(GuideLocator.page(bundle: bundle, languageCode: "fr"))
    }

    func testThePageIsRenderedAndItsBaseIsTheGuideFolder() throws {
        let bundle = try makeBundle(english: "# Guide\n\nTwo words.",
                                    french: "# Guide\n\nDeux mots.")
        let page = try XCTUnwrap(GuideLocator.page(bundle: bundle, languageCode: "fr"))
        XCTAssertTrue(page.html.contains("<h1 id=\"guide\">Guide</h1>"), page.html)
        XCTAssertTrue(page.html.contains("Deux mots"), page.html)
        XCTAssertEqual(page.baseURL.lastPathComponent, "Resources")

        let english = try XCTUnwrap(GuideLocator.page(bundle: bundle, languageCode: "en"))
        XCTAssertTrue(english.html.contains("Two words"), english.html)
    }

    // MARK: - Les liens du guide

    func testExternalLinksLeaveTheWindowAndAnchorsStay() throws {
        XCTAssertTrue(GuideLocator.opensInBrowser(
            try XCTUnwrap(URL(string: "https://example.org/aide"))))
        XCTAssertTrue(GuideLocator.opensInBrowser(
            try XCTUnwrap(URL(string: "mailto:quelquun@example.org"))))
        XCTAssertFalse(GuideLocator.opensInBrowser(
            try XCTUnwrap(URL(string: "file:///tmp/Guide.fr.md#index"))))
    }
}
