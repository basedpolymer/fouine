// QueryParserTests.swift — la table EXACTE du §5.5.1, ligne par ligne.
// Propriété : A-Core.

import XCTest
@testable import FouineCore

final class QueryParserTests: XCTestCase {

    private func fts(_ input: String) throws -> String {
        try QueryParser.parse(input).fts()
    }

    // MARK: - Table §5.5.1

    func testBareWordsBecomeAND() throws {
        XCTAssertEqual(try fts("azote reduction"), "azote AND reduction")
    }

    func testQuotedPhraseStaysAPhrase() throws {
        XCTAssertEqual(try fts("\"gaz parfait\""), "\"gaz parfait\"")
    }

    func testPrefixIsPreserved() throws {
        XCTAssertEqual(try fts("spectro*"), "spectro*")
    }

    /// ARBITRAGE T5 (post-recette) : `-terme` exclut le DOCUMENT entier. La
    /// négation ne participe plus au MATCH de page : elle sort par
    /// `negativeFTS` (le Store la traduit en `doc_id NOT IN (…)`). Un NOT
    /// seul est refusé avec un message clair (plus de `NOT biologie` nu qui
    /// finissait en erreur SQLite).
    func testNegationLeavesTheMatchAndFeedsNegativeFTS() throws {
        let parsed = try QueryParser.parse("enthalpie -biologie")
        XCTAssertEqual(parsed.fts(), "enthalpie")
        XCTAssertEqual(parsed.negativeFTS, "biologie")

        let multi = try QueryParser.parse("enthalpie -biologie -geologie")
        XCTAssertEqual(multi.fts(), "enthalpie")
        XCTAssertEqual(multi.negativeFTS, "biologie OR geologie")

        XCTAssertNil(try QueryParser.parse("enthalpie").negativeFTS)
        XCTAssertThrowsError(try fts("-biologie")) { error in
            XCTAssertEqual(error as? QueryError, .exclusionOnly)
        }
    }

    func testProximityBecomesNEAR() throws {
        XCTAssertEqual(try fts("pres:5 azote reduction"), "NEAR(azote reduction, 5)")
        XCTAssertEqual(try fts("pres:10 energie libre gibbs"),
                       "NEAR(energie libre gibbs, 10)")
    }

    func testFolderFilterLeavesTheTextAlone() throws {
        let parsed = try QueryParser.parse("dossier:Cours enthalpie")
        XCTAssertEqual(parsed.fts(), "enthalpie")
        XCTAssertEqual(parsed.folders, ["Cours"])
        XCTAssertTrue(parsed.exts.isEmpty)
    }

    /// Une étiquette de dossier avec une ESPACE se filtre entre guillemets
    /// (audit A1m-04). Avant, le guillemet coupait le mot : `dossier:` partait
    /// avec une valeur vide — donc sans poser le moindre filtre — et
    /// « Mes cours » devenait une phrase à chercher dans le texte, ce qui
    /// rendait zéro résultat sans un mot d'explication. L'étiquette par défaut
    /// d'une racine étant le dernier segment de son chemin, « Mes cours »,
    /// « Travaux dirigés » ou « M2 Chimie » sont le cas ordinaire.
    func testQuotedFolderLabelWithSpaces() throws {
        let parsed = try QueryParser.parse("dossier:\"Mes cours\" enthalpie")
        XCTAssertEqual(parsed.fts(), "enthalpie")
        XCTAssertEqual(parsed.folders, ["Mes cours"])

        // Guillemet jamais refermé : la valeur reste une valeur de filtre.
        let unterminated = try QueryParser.parse("enthalpie dossier:\"Mes cours")
        XCTAssertEqual(unterminated.folders, ["Mes cours"])

        // L'extension aussi, et la phrase ORDINAIRE n'a pas bougé.
        XCTAssertEqual(try QueryParser.parse("ext:\"pdf\" azote").exts, ["pdf"])
        XCTAssertEqual(try fts("\"gaz parfait\" azote"),
                       "\"gaz parfait\" AND azote")
    }

    func testExtensionFilter() throws {
        let parsed = try QueryParser.parse("ext:PDF chromatographie")
        XCTAssertEqual(parsed.fts(), "chromatographie")
        XCTAssertEqual(parsed.exts, ["pdf"])
    }

    func testCombinedFilters() throws {
        let parsed = try QueryParser.parse("dossier:Livres ext:pdf \"gaz parfait\" azote")
        XCTAssertEqual(parsed.folders, ["Livres"])
        XCTAssertEqual(parsed.exts, ["pdf"])
        XCTAssertEqual(parsed.fts(), "\"gaz parfait\" AND azote")
    }

    // MARK: - Contrepartie de D3 : préfixes courts refusés

    func testShortPrefixIsRefused() throws {
        for short in ["ch*", "a*", "abc*"] {
            XCTAssertThrowsError(try fts(short)) { error in
                XCTAssertEqual(error as? QueryError, .prefixTooShort(
                    String(short.dropLast())))
                XCTAssertEqual((error as? QueryError)?.errorDescription,
                               "prefix too short, give at least 4 letters")
            }
        }
        XCTAssertEqual(try fts("abcd*"), "abcd*")
    }

    // MARK: - A1m-07 : les mots-clés FTS5 tapés nus

    /// `polymere OR catalyse` vidait le SQL de la requête interne et sortait en
    /// **3** — « base verrouillée ou corrompue » — pour une faute de frappe
    /// (mesuré le 04/09/2026 sur la base de production). Il refuse maintenant en
    /// disant la règle, ce que la CLI traduit en sortie 64.
    func testBareFTSOperatorsAreRefused() throws {
        for word in ["AND", "OR", "NOT"] {
            XCTAssertThrowsError(try fts("polymere \(word) catalyse"),
                                 "« \(word) » nu doit être refusé") { error in
                XCTAssertEqual(error as? QueryError, .ftsOperator(word))
                XCTAssertEqual(
                    (error as? QueryError)?.errorDescription,
                    "“\(word)” is a search operator, not a word: Fouine combines "
                    + "words with AND by default; to exclude a word, write -word "
                    + "(put it in quotes to search for the word itself)")
            }
            // Exclu (`-OR`), il produirait la même erreur de syntaxe par
            // `negativeFTS` : même refus.
            XCTAssertThrowsError(try fts("polymere -\(word)")) { error in
                XCTAssertEqual(error as? QueryError, .ftsOperator(word))
            }
            // Dans un NEAR(…), où l'expression est bâtie autrement.
            XCTAssertThrowsError(try fts("pres:3 azote \(word) carbone")) { error in
                XCTAssertEqual(error as? QueryError, .ftsOperator(word))
            }
        }
    }

    /// LA CASSE COMPTE : « or » et « ou » sont du français courant, « and » de
    /// l'anglais, et FTS5 ne les lit comme opérateurs qu'en majuscules.
    func testLowercaseOperatorsStayOrdinaryWords() throws {
        XCTAssertEqual(try fts("or"), "or")
        XCTAssertEqual(try fts("and not"), "and AND not")
        XCTAssertEqual(try fts("Or"), "Or")
        // Entre guillemets, le mot en majuscules redevient cherchable.
        XCTAssertEqual(try fts("\"OR\""), "\"OR\"")
    }

    /// `NEAR` n'est un opérateur FTS5 QUE suivi d'une parenthèse : `azote NEAR
    /// carbone` reste une recherche du mot « near », qui ne casse rien.
    func testNEARIsRefusedOnlyBeforeAParenthesis() throws {
        XCTAssertThrowsError(try fts("NEAR(azote carbone, 5)")) { error in
            XCTAssertEqual(error as? QueryError, .ftsOperator("NEAR"))
        }
        XCTAssertThrowsError(try fts("NEAR (azote carbone, 5)")) { error in
            XCTAssertEqual(error as? QueryError, .ftsOperator("NEAR"))
        }
        XCTAssertEqual(try fts("azote NEAR carbone"), "azote AND NEAR AND carbone")
    }

    // MARK: - Idée 5 de l'audit A1 : une étiquette de dossier inconnue

    /// `dossier:Cour` filtrait sur une étiquette qui n'existe pas et rendait
    /// zéro résultat, sans un mot : indiscernable d'un corpus qui ne contient
    /// pas le terme. `top_folder` se compare EXACTEMENT en SQL.
    func testUnknownFolderIsNamedWithTheOnesThatExist() throws {
        XCTAssertThrowsError(
            try FolderCheck.resolve(["Cour"], known: ["M2SU", "Livres"])
        ) { error in
            XCTAssertEqual(error as? QueryError,
                           .unknownFolder("Cour", known: ["Livres", "M2SU"]))
            XCTAssertEqual((error as? QueryError)?.errorDescription,
                           "unknown folder “Cour” — yours are: Livres, M2SU")
        }
        // ON NE REFUSE QUE CE QU'ON PEUT CONTREDIRE : sans étiquette connue,
        // le filtre part tel quel. Un refus fondé sur une liste vide serait un
        // faux positif — exactement le défaut qu'on répare.
        XCTAssertEqual(try FolderCheck.resolve(["Cour"], known: []), ["Cour"])
    }

    /// La casse est le SEUL écart toléré, et l'étiquette est canonisée : sans
    /// cela, `dossier:livres` filtrerait sur une chaîne que SQL ne trouve pas.
    func testFolderLabelIsCanonicalisedByCaseOnly() throws {
        XCTAssertEqual(try FolderCheck.resolve(["livres"], known: ["Livres"]),
                       ["Livres"])
        XCTAssertEqual(try FolderCheck.resolve(["Mes cours"],
                                               known: ["Mes cours", "Livres"]),
                       ["Mes cours"])
        XCTAssertEqual(try FolderCheck.resolve([], known: ["Livres"]), [])
        // Un accent n'est PAS un écart de casse : filtrer sur un dossier que
        // l'utilisateur n'a pas nommé vaudrait moins qu'un refus qui dit quoi
        // taper.
        XCTAssertThrowsError(try FolderCheck.resolve(["Ecole"], known: ["École"]))
    }

    func testEmptyQueryIsRefused() throws {
        XCTAssertThrowsError(try fts("dossier:Cours")) { error in
            XCTAssertEqual(error as? QueryError, .emptyQuery)
        }
    }

    // MARK: - Échappement

    func testSpecialCharactersAreQuoted() throws {
        XCTAssertEqual(try fts("c(n)"), "\"c(n)\"")
        XCTAssertEqual(try fts("a:b"), "\"a:b\"")
        XCTAssertEqual(try fts("sous-titre azote"), "\"sous-titre\" AND azote")
        XCTAssertEqual(try fts("^caret"), "\"^caret\"")
    }

    // MARK: - Termes bruts conservés pour le flou

    func testRawTermsAreKeptForFuzzyExpansion() throws {
        let parsed = try QueryParser.parse(
            "dossier:Cours enthalpie \"gaz parfait\" -biologie pres:5 azote reduction")
        XCTAssertEqual(Set(parsed.terms), ["enthalpie", "azote", "reduction"])
    }

    func testSearchQueryCarriesFiltersAndTerms() throws {
        let q = try QueryParser.searchQuery("dossier:Cours ext:pdf enthalpie", limit: 7)
        XCTAssertEqual(q.fts, "enthalpie")
        XCTAssertEqual(q.folders, ["Cours"])
        XCTAssertEqual(q.exts, ["pdf"])
        XCTAssertEqual(q.terms, ["enthalpie"])
        XCTAssertEqual(q.limit, 7)
    }

    // MARK: - Substitution des variantes (§5.5.3)

    func testSubstitutionBuildsORGroupsOutsidePhrasesAndNEAR() {
        let expanded = GRDBStore.substitute(
            "azote AND \"gaz azote\" AND NEAR(azote reduction, 5)",
            terms: ["azote"], expansions: ["azote": ["azotr"]])
        XCTAssertEqual(expanded,
                       "(\"azote\" OR \"azotr\") AND \"gaz azote\" "
                       + "AND NEAR(azote reduction, 5)")
    }

    func testSubstitutionIsAnIdentityWithoutExpansions() {
        let fts = "enthalpie AND polymere"
        XCTAssertEqual(GRDBStore.substitute(fts, terms: [], expansions: [:]), fts)
    }

    // MARK: - Alias anglais des préfixes (lot MP1, PR-03 et PR-04)

    /// `near:` et `folder:` valent `pres:` et `dossier:` PARTOUT — y compris
    /// avec une valeur entre guillemets. Mesuré le 09/09/2026 sur la base de
    /// production : `near:5 azote reduction` rendait 0 page contre 7 pour
    /// `pres:5 …`, et `folder:Livres energie` 0 contre 28 658.
    func testEnglishPrefixAliases() throws {
        XCTAssertEqual(try fts("near:5 azote reduction"),
                       "NEAR(azote reduction, 5)")
        XCTAssertEqual(try fts("NEAR:5 azote reduction"),
                       "NEAR(azote reduction, 5)")
        let folder = try QueryParser.parse("folder:Livres energie")
        XCTAssertEqual(folder.folders, ["Livres"])
        XCTAssertEqual(folder.fts(), "energie")
        XCTAssertEqual(try QueryParser.parse("folder:\"Mes cours\" enthalpie").folders,
                       ["Mes cours"])
        // La forme CANONIQUE ne bouge pas : rien à distinguer en aval.
        XCTAssertEqual(try QueryParser.parse("folder:Livres energie").folders,
                       try QueryParser.parse("dossier:Livres energie").folders)
    }

    /// Un préfixe inconnu était un MOT ORDINAIRE, cherché tel quel : zéro
    /// résultat sans un mot (PR-04). Il se dit maintenant, en nommant les trois
    /// filtres.
    func testAnUnknownPrefixIsRefusedAndNamesTheFilters() throws {
        for word in ["type:pdf", "dans:Livres", "TYPE:pdf"] {
            XCTAssertThrowsError(try fts("azote \(word)"),
                                 "« \(word) » doit être refusé") { error in
                XCTAssertEqual((error as? QueryError)?.errorDescription,
                               "“\(word.prefix(while: { $0 != ":" }).lowercased()):” "
                               + "is not a filter — filters are "
                               + "dossier:/folder:, ext:, pres:/near:, nom:/name:, texte:/body:, chemin:/path:")
            }
        }
        // Dans un NEAR(…) aussi : sinon le faux filtre y entrerait en membre.
        XCTAssertThrowsError(try fts("pres:5 azote type:pdf")) { error in
            XCTAssertEqual(error as? QueryError,
                           .unknownPrefix("type:", known: QueryParser.knownPrefixLabels))
        }
    }

    /// CE QUI N'EST PAS UN PRÉFIXE : une URL (la valeur commence par `//`), une
    /// heure (des chiffres avant le deux-points), une seule lettre, une valeur
    /// vide, et tout ce qui est entre guillemets.
    func testWhatLooksLikeAPrefixAndIsNot() throws {
        XCTAssertEqual(try fts("https://exemple.org"), "\"https://exemple.org\"")
        XCTAssertEqual(try fts("10:30"), "\"10:30\"")
        XCTAssertEqual(try fts("a:b"), "\"a:b\"")
        XCTAssertEqual(try fts("\"type:pdf\""), "\"type:pdf\"")
        // `-type:pdf` ÉTAIT ACCEPTÉ ici jusqu'au 14/09/2026 : il devenait la
        // négation du mot « type:pdf », donc la phrase FTS5 « type pdf » — il
        // n'excluait pas les PDF et pouvait exclure autre chose. Il est refusé
        // depuis le lot MN1 ; `ExclusionRefusalTests` porte la règle.
        XCTAssertThrowsError(try fts("azote -type:pdf"))
        XCTAssertNil(QueryParser.unknownPrefix(in: "type:"))
        XCTAssertNil(QueryParser.unknownPrefix(in: "dossier:Livres"))
    }

    // MARK: - Guillemets typographiques (lot QP1)

    /// macOS remplace les guillemets tapés : `“gaz parfait”` était deux mots
    /// flanqués de caractères invisibles à l'œil, pas une phrase.
    func testTypographicQuotesAndTheCurlyApostropheAreNormalized() throws {
        for typed in ["\u{201C}gaz parfait\u{201D}", "\u{201E}gaz parfait\u{201F}",
                      "\u{2033}gaz parfait\u{2033}", "\u{00AB}gaz parfait\u{00BB}"] {
            XCTAssertEqual(try fts(typed), "\"gaz parfait\"", typed)
        }
        XCTAssertEqual(try fts("l\u{2019}azote"), try fts("l'azote"))
        XCTAssertEqual(QueryParser.normalizingQuotes("\u{201C}a\u{201D} \u{00AB}b\u{00BB} l\u{2019}c"),
                       "\"a\" \"b\" l'c")
    }

    /// La typographie française met une espace À L'INTÉRIEUR des guillemets.
    func testFrenchGuillemetsWithInnerSpacesMakeThePhrase() throws {
        XCTAssertEqual(try QueryParser.parse("\u{00AB} catalyse \u{00BB}").nodes,
                       [.phrase("catalyse")])
        XCTAssertEqual(try QueryParser.parse("dossier:\u{00AB}\u{202F}Mes cours\u{202F}\u{00BB} x").folders,
                       ["Mes cours"])
    }

    /// Le canal sémantique s'éteint sur une phrase (RK-01) : il doit la voir.
    func testAsksForExactPhraseSeesTypographicQuotes() {
        XCTAssertTrue(QueryParser.asksForExactPhrase("\u{201C}energie libre\u{201D}"))
        XCTAssertTrue(QueryParser.asksForExactPhrase("\u{00AB} energie libre \u{00BB}"))
        XCTAssertFalse(QueryParser.asksForExactPhrase("energie libre"))
    }

    // MARK: - `nom:` et `texte:` (lot QP1)

    func testNamePrefixFeedsNameTermsAndNotThePage() throws {
        let plan = try QueryParser.searchQuery("nom:rapport azote")
        XCTAssertEqual(plan.nameTerms, ["rapport"])
        XCTAssertEqual(plan.fts, "azote")
        XCTAssertEqual(try QueryParser.searchQuery("name:\"analyse JB\"").nameTerms,
                       ["analyse JB"])
        // Seul, il est une requête entière — même à côté d'une exclusion.
        XCTAssertEqual(try QueryParser.parse("nom:rapport").nodes, [])
        XCTAssertEqual(try QueryParser.parse("nom:rapport -brouillon").negativeFTS, "brouillon")
        // Valeur vide : rien, comme `dossier:` seul.
        XCTAssertThrowsError(try QueryParser.parse("nom:")) { error in
            XCTAssertEqual(error as? QueryError, .emptyQuery)
        }
    }

    func testBodyPrefixIsAPageTermThatTurnsTheNameOff() throws {
        let body = try QueryParser.searchQuery("texte:rapport annuel")
        XCTAssertEqual(body.fts, "rapport AND annuel")
        XCTAssertEqual(body.terms, ["rapport", "annuel"])
        XCTAssertFalse(body.nameBoost)
        XCTAssertTrue(try QueryParser.searchQuery("rapport annuel").nameBoost)
        XCTAssertEqual(try QueryParser.parse("body:\"gaz parfait\"").nodes,
                       [.phrase("gaz parfait")])
    }

    /// Le texte envoyé au modèle : `texte:` garde sa valeur, `nom:` et les
    /// filtres sortent — y compris une valeur de filtre entre guillemets.
    func testSemanticTextKeepsBodyValuesAndDropsNameValues() {
        XCTAssertEqual(QueryParser.semanticText("texte:rapport"), "rapport")
        XCTAssertEqual(QueryParser.semanticText("nom:rapport"), "")
        XCTAssertEqual(QueryParser.semanticText(
            "nom:\"analyse JB\" dossier:\"Mes cours\" ext:pdf pres:5 chat -chien \u{00AB} au chaud \u{00BB} body:x"),
            "chat au chaud x")
    }

    // MARK: - Montants (lot MP1, C2-12)

    /// Le document porte « 1 512,50 » (espace fine insécable) et le tokenizer
    /// en fait `1` et `512,50` : `1512,50` rendait 0 page, `1 512,50` en rendait
    /// 2. Les deux écritures partent désormais ensemble, dans les deux sens.
    /// Les DEUX membres sont entre guillemets : `1512,50` nu est une erreur de
    /// syntaxe FTS5 (« syntax error near "," », vérifié le 10/09/2026).
    func testAmountsCarryBothSpellings() throws {
        XCTAssertEqual(try fts("1512,50"), "(\"1512,50\" OR \"1 512,50\")")
        XCTAssertEqual(try fts("1 512,50"), "(\"1 512,50\" OR \"1512,50\")")
        XCTAssertEqual(try fts("12345,67"), "(\"12345,67\" OR \"12 345,67\")")
        XCTAssertEqual(try fts("1512.50"), "(\"1512.50\" OR \"1 512.50\")")
        // Le montant recollé reste UN terme, et le mot qui suit ne l'est pas.
        XCTAssertEqual(try fts("facture 1 512,50"),
                       "facture AND (\"1 512,50\" OR \"1512,50\")")
    }

    /// PAS DE VARIANTE sur un nombre à trois chiffres ni sur une année : `2003`
    /// deviendrait `"2 003"`, et l'année est le nombre le plus tapé de tous.
    func testShortNumbersAndYearsKeepTheirSingleForm() throws {
        XCTAssertEqual(try fts("2003"), "2003")
        XCTAssertEqual(try fts("512,50"), "\"512,50\"")
        XCTAssertEqual(try fts("15125"), "15125")
        // Deux nombres sans décimale restent deux termes, comme avant.
        XCTAssertEqual(try fts("1 512"), "1 AND 512")
    }
}
