// MarkdownHTMLTests.swift — le guide se rend, et rien du fichier ne devient
// balise (BU-27). Propriété : A-App.
//
// Deux dangers, et un test pour chacun. Le premier est le rendu lui-même : une
// construction oubliée (un tableau, un bloc de code) ne casse rien, elle passe
// en texte brut — c'est-à-dire un guide illisible là où le document était clair.
// Le second est l'échappement : `docs/app.md` est un fichier du dépôt, et tout
// `<` qu'il contiendrait ouvrirait une balise dans la page. On le vérifie donc
// sur le VRAI fichier, pas sur un extrait figé qui vieillirait à côté de lui.

import XCTest
@testable import FouineApp

final class MarkdownHTMLTests: XCTestCase {

    // MARK: - Une construction, un cas

    func testHeadingsCarryTheirLevelAndAnAnchor() {
        let html = MarkdownHTML.body("# Titre\n\n## Deux\n\n#### Quatre")
        XCTAssertTrue(html.contains("<h1 id=\"titre\">Titre</h1>"), html)
        XCTAssertTrue(html.contains("<h2 id=\"deux\">Deux</h2>"), html)
        XCTAssertTrue(html.contains("<h4 id=\"quatre\">Quatre</h4>"), html)
    }

    func testParagraphsJoinTheirLinesAndSeparateOnBlankLines() {
        let html = MarkdownHTML.body("Une phrase\nqui continue.\n\nUne autre.")
        XCTAssertEqual(html, "<p>Une phrase\nqui continue.</p>\n<p>Une autre.</p>")
    }

    func testUnorderedListsWithContinuationLines() {
        let html = MarkdownHTML.body("""
        - Premier point
          qui se poursuit.
        - Second point
        """)
        XCTAssertEqual(html, """
        <ul>
        <li>Premier point\nqui se poursuit.</li>
        <li>Second point</li>
        </ul>
        """)
    }

    func testOrderedListsAndOneLevelOfNesting() {
        let html = MarkdownHTML.body("""
        1. Premier
        2. Second
           - imbriqué
        """)
        XCTAssertTrue(html.hasPrefix("<ol>"), html)
        XCTAssertTrue(html.contains("<li>Premier</li>"), html)
        XCTAssertTrue(html.contains("<ul>\n<li>imbriqué</li>\n</ul>"), html)
    }

    func testTablesGetAHeaderAndOneRowPerLine() {
        let html = MarkdownHTML.body("""
        | Panneau | Rôle |
        |---|---|
        | **Barre latérale** | L'état de l'index. |
        | Résultats | Les pages trouvées. |
        """)
        XCTAssertTrue(html.contains("<th>Panneau</th><th>Rôle</th>"), html)
        XCTAssertTrue(html.contains("<td><strong>Barre latérale</strong></td>"), html)
        XCTAssertEqual(html.components(separatedBy: "<tr>").count - 1, 3, html)
    }

    func testFencedCodeKeepsItsLinesAndEscapesThem() {
        let html = MarkdownHTML.body("""
        ```
        fouine search "a < b"
        ```
        """)
        XCTAssertEqual(html, "<pre><code>fouine search \"a &lt; b\"</code></pre>")
    }

    func testInlineMarkup() {
        XCTAssertEqual(MarkdownHTML.inline("**gras** et *penché*"),
                       "<strong>gras</strong> et <em>penché</em>")
        XCTAssertEqual(MarkdownHTML.inline("un `code` en ligne"),
                       "un <code>code</code> en ligne")
        XCTAssertEqual(MarkdownHTML.inline("[le dépôt](https://example.org/a?x=1)"),
                       "<a href=\"https://example.org/a?x=1\">le dépôt</a>")
    }

    /// Deux cas de `docs/app.md` qu'un rendu morceau par morceau perdait : le
    /// gras qui ENCADRE un code en ligne, et l'emphase repliée sur deux lignes.
    func testEmphasisSpansCodeAndLineBreaks() {
        XCTAssertEqual(MarkdownHTML.inline("**Un lien `fouine://`.** Suite"),
                       "<strong>Un lien <code>fouine://</code>.</strong> Suite")
        XCTAssertEqual(MarkdownHTML.inline("ou *Ajouter au\npresse-papiers*"),
                       "ou <em>Ajouter au\npresse-papiers</em>")
    }

    func testQuotesAndThematicBreaks() {
        let html = MarkdownHTML.body("> Une note.\n\n---\n\nSuite.")
        XCTAssertTrue(html.contains("<blockquote>\n<p>Une note.</p>\n</blockquote>"), html)
        XCTAssertTrue(html.contains("<hr>"), html)
    }

    func testWhatIsNotUnderstoodStaysText() {
        // Un tableau HTML écrit à la main dans le document ne doit pas devenir
        // un tableau : il devient du texte, visible tel quel.
        let html = MarkdownHTML.body("<table><tr><td>x</td></tr></table>")
        XCTAssertEqual(html, "<p>&lt;table&gt;&lt;tr&gt;&lt;td&gt;x&lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;</p>")
    }

    // MARK: - L'échappement

    func testTheSourceTextCannotOpenATag() {
        let html = MarkdownHTML.body("a < b & c > d, <script>alert(1)</script>")
        XCTAssertFalse(html.contains("<script"), html)
        XCTAssertTrue(html.contains("a &lt; b &amp; c &gt; d"), html)
    }

    // MARK: - Le vrai guide

    /// La racine du dépôt, déduite de l'emplacement de CE fichier.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()         // …/Tests/FouineAppTests
            .deletingLastPathComponent()         // …/Tests
            .deletingLastPathComponent()         // …
    }

    /// Les balises que le rendu produit — et aucune autre. Le test compte les
    /// `<` de la page : s'il y en a un de plus que de balises reconnues, c'est
    /// qu'un caractère du document est passé sans échappement.
    private static let knownTags: Set<String> = [
        "!doctype", "meta", "title", "style", "p", "h1", "h2", "h3", "h4",
        "ul", "ol", "li", "table", "thead", "tbody", "tr", "th", "td",
        "pre", "code", "blockquote", "hr", "a", "strong", "em",
    ]

    func testTheRealGuideRendersWithoutALooseAngleBracket() throws {
        let guideURL = Self.repositoryRoot.appendingPathComponent("docs/app.md")
        let markdown = try String(contentsOf: guideURL, encoding: .utf8)
        let html = MarkdownHTML.render(markdown, title: "Guide")

        let tags = try NSRegularExpression(pattern: "<[^>]+>")
            .matches(in: html, range: NSRange(html.startIndex..., in: html))
        XCTAssertEqual(tags.count, html.filter { $0 == "<" }.count,
                       "un « < » de la page n'ouvre aucune balise")

        for match in tags {
            let tag = String(html[Range(match.range, in: html)!])
            let name = tag.dropFirst()
                .drop(while: { $0 == "/" })
                .prefix(while: { $0.isLetter || $0.isNumber || $0 == "!" })
                .lowercased()
            XCTAssertTrue(Self.knownTags.contains(name), "balise inattendue : \(tag)")
        }

        let expectedH2 = markdown.components(separatedBy: "\n")
            .filter { $0.hasPrefix("## ") }.count
        XCTAssertGreaterThan(expectedH2, 0)
        XCTAssertEqual(html.components(separatedBy: "<h2 ").count - 1, expectedH2,
                       "le guide a \(expectedH2) titres de niveau 2")
    }
}
