// L10nTests.swift — le garde-fou de la traduction (palier 3.2, audit U1).
// Propriété : A-App.
//
// Trois choses, et chacune correspond à une façon de perdre la traduction :
//
//   1. `Tools/l10n-lint.sh` passe. C'est LUI le garde-fou réel — il rapproche
//      chaque chaîne visible de `Sources/FouineApp/**` du catalogue et exige
//      une valeur `fr` à l'état `translated`. Le test n'est que la façon de le
//      faire tourner à chaque `swift test`, pour qu'une contribution qui écrit
//      `Text("Nouveau bouton")` s'en aperçoive avant l'utilisateur.
//
//   2. Chaque cas d'erreur RENDU PAR L'APP a sa clé au catalogue, traduite.
//      C'est le point sur lequel un contrat gelé (§4.2) ne protège de rien :
//      ajouter un cas à `FouineError` compile parfaitement sans y penser, et
//      `ErrorText` afficherait alors une phrase anglaise dans une fenêtre
//      française.
//
//   3. Les comptes accordent. Le français met 0 et 1 au singulier, l'anglais
//      met 0 au pluriel : la règle vit dans les VARIATIONS du catalogue, pas
//      dans le code, et c'est là qu'on la vérifie.
//
// LANGUE DE BASE EN TEST. `swift test` ne tourne pas depuis Fouine.app :
// `Bundle.main` n'a aucun `.lproj`, et `String(localized:)` rend donc la CLÉ,
// c'est-à-dire l'anglais source. Les assertions de rendu portent sur cet
// anglais-là ; le français se vérifie sur le catalogue, qui est la source de
// ce que `xcstringstool` compilera dans `fr.lproj`.

import XCTest
import FouineCore
import FouineEmbed
@testable import FouineApp

final class L10nTests: XCTestCase {

    // MARK: - Emplacements

    /// La racine du dépôt, déduite de l'emplacement de CE fichier : le test ne
    /// dépend ni du répertoire courant, ni d'une variable d'environnement.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/FouineAppTests/L10nTests.swift
            .deletingLastPathComponent()         // …/Tests/FouineAppTests
            .deletingLastPathComponent()         // …/Tests
            .deletingLastPathComponent()         // …
    }

    private static var appCatalogURL: URL {
        repositoryRoot.appendingPathComponent(
            "Sources/FouineApp/Resources/Localizable.xcstrings")
    }

    // MARK: - 1. Le lint

    func testL10nLintPasses() throws {
        let script = Self.repositoryRoot
            .appendingPathComponent("Tools/l10n-lint.sh")
        try XCTSkipUnless(FileManager.default.isExecutableFile(
            atPath: script.path), "Tools/l10n-lint.sh absent ou non exécutable")

        let process = Process()
        process.executableURL = script
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0,
                       "Tools/l10n-lint.sh a échoué :\n" + text)
    }

    // MARK: - 2. Les erreurs rendues par l'app

    /// Un échantillon COUVRANT : les huit cas de `FouineError`, les cinq de
    /// `QueryError`, les quatre motifs typés de `SettingsError` et les deux de
    /// `FouineEmbedError` — tout ce qu'`ErrorText.describe` sait rendre.
    private static let renderedErrors: [(Error, key: String)] = [
        // Sans l'UUID depuis le lot I1 : il reste dans la CLI et le journal.
        (FouineError.volumeNotMounted(uuid: "ABC"),
         "the disk is not plugged in: plug it back in and try again"),
        (FouineError.rootUnreadable(path: "/x",
                                    reason: RootProbe.Reason.missing.token),
         "unreadable folder: %@ — %@"),
        (FouineError.rootUnreadable(
            path: "/x", reason: RootProbe.Reason.permissionDenied.token),
         "unreadable folder: %@ — %@. %@"),
        (FouineError.databaseFailure("disque plein"), "database: %@"),
        (FouineError.budgetExhausted(remaining: 3),
         "budget exhausted, %lld item(s) left in the queue"),
        (FouineError.unsupported(ext: "xyz"), "unsupported format: .%@"),
        (FouineError.fileTooLarge(bytes: 12), "file too large (%lld B)"),
        (FouineError.extraction("pdftotext"), "extraction: %@"),
        (FouineError.ocr("Vision"), "OCR: %@"),
        (QueryError.prefixTooShort("sp"),
         "prefix too short, give at least 4 letters"),
        (QueryError.emptyQuery,
         "empty query: give at least one term to search for"),
        (QueryError.exclusionOnly,
         "exclusion alone (-term): add at least one term to search for"),
        (QueryError.ftsOperator("OR"),
         "“%@” in capitals is an instruction, not a word: Fouine already searches for all the words you type; to exclude one, write -word."),
        (QueryError.unknownFolder("Cour", known: ["Livres", "M2SU"]),
         "no folder is called “%@”. Yours are: %@"),
        (SettingsError("x", reason: .notABoolean(value: "abc", key: "k")),
         "“%@” is not a boolean for %@: expected true/false (or 1/0, yes/no)"),
        (SettingsError("x", reason: .notAnInteger(value: "a", key: "k",
                                                  min: 1, max: 4)),
         "“%@” is not an integer for %@: expected a number between %lld and %lld"),
        (SettingsError("x", reason: .notARootIdentifier(value: "a", key: "k")),
         "“%@” is not a folder identifier for %@: expected integers separated by commas"),
        (SettingsError("x", reason: .unknownKey("k")),
         "unknown setting key: %@"),
        (FouineEmbedError.model("CoreML"), "meaning-search model: %@"),
        (FouineEmbedError.inference("shape"), "inference: %@"),
    ]

    func testEveryRenderedErrorHasATranslatedKey() throws {
        let catalog = try Self.catalog()
        for (error, key) in Self.renderedErrors {
            XCTAssertTrue(catalog.keys.contains(key),
                          "« \(key) » manque à Localizable.xcstrings "
                          + "(erreur : \(error))")
            assertTranslated(key, in: catalog)
            XCTAssertFalse(ErrorText.describe(error).isEmpty,
                           "\(error) ne rend rien")
        }
    }

    /// L'aide de `SemanticAvailability` ne renvoie plus l'utilisateur vers un
    /// script Python (audit B1-07).
    ///
    /// La phrase « Model missing from … — produce it with Tools/convert_e5.py »
    /// était affichée DEUX fois dans l'interface — sous l'interrupteur de la
    /// barre latérale et dans l'onglet Sémantique — quinze lignes au-dessus du
    /// bouton « Download the model (220.2 MB)… » du même onglet, et elle
    /// désignait un fichier absent du bundle. C'était un vestige d'avant que le
    /// modèle devienne téléchargeable, et tout utilisateur de la v1.0.0 qui
    /// ouvre cet onglet avant d'avoir téléchargé le modèle le voyait.
    ///
    /// Le test porte sur le RENDU, pas sur la clé : c'est le rendu qui est
    /// affiché, et une régression pourrait passer par un autre cas.
    func testModelMissingSendsToSettingsNotToAScript() throws {
        let rendered = SemanticAvailability.modelMissing.help
        XCTAssertFalse(rendered.contains("Tools/"), rendered)
        XCTAssertFalse(rendered.contains(".py"), rendered)
        XCTAssertFalse(rendered.isEmpty)
        // Et le geste EST là : le nom exact de l'onglet et celui du bouton.
        // L'onglet ne s'appelle plus « Semantic » mais « Search by meaning »
        // (UX-10) — un mot que le public visé ne connaît pas n'a pas à servir
        // de point de repère dans une consigne.
        XCTAssertTrue(rendered.contains("Settings"), rendered)
        XCTAssertTrue(rendered.contains("Search by meaning"), rendered)
        XCTAssertFalse(rendered.contains("Semantic"), rendered)

        let catalog = try Self.catalog()
        let key = "Model not installed — Settings ▸ Search by meaning ▸ “Download the model”."
        XCTAssertTrue(catalog.keys.contains(key), "« \(key) » manque")
        assertTranslated(key, in: catalog)
        // Les anciennes clés sont RETIRÉES du catalogue, pas seulement
        // inutilisées : une clé morte finit par être retraduite, puis réutilisée.
        for dead in ["Model missing from %@ — produce it with Tools/convert_e5.py.",
                     "Model not installed — Settings ▸ Semantic ▸ “Download the model”."] {
            XCTAssertFalse(catalog.keys.contains(dead),
                           "« \(dead) » est encore au catalogue")
        }
    }

    /// Le repli du canal sémantique ne parle ni de vecteur ni de commande
    /// (A2-05, SPEC §5.6 amendé du 03/09/2026).
    ///
    /// Ce que l'app affichait sous les résultats et dans la barre latérale :
    /// « Recherche sémantique indisponible (modèle d'embeddings : aucun vecteur
    /// en base — lancez “fouine embed”) — repli sur la recherche plein texte. »
    /// Trois mots que le public ne connaît pas, et une commande qu'il ne sait
    /// pas lancer. Le test porte sur le RENDU : c'est lui qui est affiché.
    func testSemanticFallbackSpeaksNoJargon() throws {
        let rendered = ErrorText.describe(
            FouineEmbedError.model(SemanticService.noVectorsDetail))
        for banned in ["vecteur", "vector", "embed", "fouine "] {
            XCTAssertFalse(rendered.lowercased().contains(banned),
                           "« \(banned) » est encore là : \(rendered)")
        }
        // Et le geste EST là : le nom exact de l'onglet des réglages, qui
        // s'appelle « Search by meaning » depuis UX-10 — et qui PRÉPARE les
        // pages depuis UX-12, au lieu de se contenter d'expliquer l'étape.
        XCTAssertTrue(rendered.contains("Settings"), rendered)
        XCTAssertTrue(rendered.contains("Search by meaning"), rendered)
        XCTAssertFalse(rendered.contains("Semantic"), rendered)

        let catalog = try Self.catalog()
        for key in ["no page is ready for meaning search yet — Settings ▸ Search by meaning prepares them",
                    "meaning-search model: %@",
                    "the meaning search is not ready yet"] {
            XCTAssertTrue(catalog.keys.contains(key), "« \(key) » manque")
            assertTranslated(key, in: catalog)
        }
        // Les anciennes clés sont RETIRÉES, pas seulement inutilisées : une clé
        // morte finit par être retraduite, puis réutilisée.
        for dead in ["embedding model: %@",
                     "no vector in the database — run “fouine embed”",
                     "vector index not loaded",
                     "no page is ready for meaning search yet — Settings ▸ Semantic explains the remaining step",
                     "No page is ready for meaning search yet — Settings ▸ Semantic explains the remaining step."] {
            XCTAssertFalse(catalog.keys.contains(dead),
                           "« \(dead) » est encore au catalogue")
        }
    }

    /// Le verrou occupé : le cas TYPÉ du palier 3.2. L'app le rend depuis les
    /// données — rôle, heure —, jamais depuis la phrase du cœur. Depuis le lot
    /// I1, ni le pid ni le chemin du verrou n'y figurent : le public n'est pas
    /// technicien, et l'heure de début suffit à décider d'attendre.
    func testBusyLockIsRenderedFromData() throws {
        let catalog = try Self.catalog()
        for key in ["the index is being updated (%@) — try again when it is finished",
                    "the index is being updated by another program — try again in a moment",
                    "background indexing, since %@", "command line, since %@",
                    "this application, since %@"] {
            XCTAssertTrue(catalog.keys.contains(key), "« \(key) » manque")
            assertTranslated(key, in: catalog)
        }
        for gone in ["the database is being written by %@ (pid %@) since %@",
                     "the app", "the agent", "the fouine command"] {
            XCTAssertFalse(catalog.keys.contains(gone), "clé morte encore au catalogue : \(gone)")
        }

        let holder = LockHolder(pid: getpid(), role: .agent, since: Date())
        let error = FouineError.databaseFailure(
            WriteLock.busyMessage(holder: holder, path: "/tmp/fouine.lock"))
        let rendered = ErrorText.describe(error)
        XCTAssertTrue(rendered.contains(holder.clockText), rendered)
        XCTAssertFalse(rendered.contains("pid"), rendered)
        // Et surtout : plus rien du message brut ne transparaît.
        XCTAssertFalse(rendered.contains(WriteLock.busyToken), rendered)

        let anonymous = FouineError.databaseFailure(
            WriteLock.busyMessage(holder: nil, path: "/tmp/fouine.lock"))
        let anonymousText = ErrorText.describe(anonymous)
        XCTAssertFalse(anonymousText.isEmpty)
        XCTAssertFalse(anonymousText.contains("/tmp/fouine.lock"), anonymousText)
        XCTAssertFalse(anonymousText.contains(WriteLock.busyToken), anonymousText)
    }

    /// Les six phases de l'agent : la barre latérale les affiche, elles sont
    /// donc au catalogue comme le reste.
    func testEveryAgentPhaseIsTranslated() throws {
        let catalog = try Self.catalog()
        for phase in AgentStatusRecord.Phase.allCases {
            let name = AgentPhaseText.name(phase)
            XCTAssertFalse(name.isEmpty, "\(phase) n'a pas de nom")
            XCTAssertTrue(catalog.keys.contains(name),
                          "« \(name) » (phase \(phase)) manque au catalogue")
            assertTranslated(name, in: catalog)
        }
    }

    /// Ce que l'agent DIT qu'il fait : un jeton sans langue, traduit ici
    /// (audit A1m-10).
    ///
    /// La barre latérale française affichait « 20226 page(s) queued » et
    /// « starting up » en anglais : `AgentDetailText` ne savait traduire que
    /// `queue-drained`. Les jetons portant un nombre sont rendus par une clé à
    /// pluriel du catalogue, comme le reste des comptes.
    func testEveryAgentDetailTokenIsTranslated() throws {
        let catalog = try Self.catalog()
        for key in ["Every scanned page has been read", "starting up", "stopping",
                    "%lld scanned page(s) to read",
                    "%lld page(s) still to recognise"] {
            XCTAssertTrue(catalog.keys.contains(key), "« \(key) » manque")
            assertTranslated(key, in: catalog)
        }
        // Rien d'un jeton ne transparaît dans ce que lit l'utilisateur.
        for token in [AgentStatusDetail.queueDrained, AgentStatusDetail.starting,
                      AgentStatusDetail.pagesQueued(20226),
                      AgentStatusDetail.pagesLeft(315),
                      AgentStatusDetail.signalReceived("SIGTERM")] {
            let rendered = AgentDetailText.text(token)
            XCTAssertFalse(rendered.isEmpty, token)
            XCTAssertNotEqual(rendered, token, "jeton brut affiché")
            XCTAssertFalse(rendered.contains("queue-drained"), rendered)
            XCTAssertFalse(rendered.contains("pages-"), rendered)
            XCTAssertFalse(rendered.contains("SIGTERM"),
                           "le nom du signal reste dans la CLI : \(rendered)")
        }
        // Un NOM passe tel quel, un jeton inconnu aussi (compatibilité).
        XCTAssertEqual(AgentDetailText.text(AgentStatusDetail.document("Cours.pdf")),
                       "Cours.pdf")
        XCTAssertEqual(AgentDetailText.text("SIGTERM reçu"), "SIGTERM reçu")
    }

    /// Les onze réglages de la fenêtre ⌘, : leur résumé vient du CATALOGUE.
    ///
    /// Depuis le palier 3.5, `SettingSpec.summary` est lui aussi en anglais :
    /// comparer les deux chaînes ne prouve donc plus rien. Ce qui prouve que
    /// l'app ne retombe pas sur la phrase du cœur, c'est que la clé soit AU
    /// catalogue et traduite — `SettingsModel.summary` ne retombe sur
    /// `spec.summary` que pour une clé que sa table ignore, et cette clé-là
    /// manquerait alors au catalogue.
    @MainActor
    func testEverySettingSummaryIsLocalized() throws {
        let catalog = try Self.catalog()
        for spec in SettingKeys.all {
            let summary = SettingsModel.summary(spec)
            XCTAssertTrue(catalog.keys.contains(summary),
                          "le réglage « \(spec.key) » retombe sur une phrase "
                          + "absente du catalogue : « \(summary) »")
            assertTranslated(summary, in: catalog)
        }
    }

    // MARK: - 3. L'accord des comptes

    /// Le français met 0 ET 1 au singulier, l'anglais met 0 au pluriel : c'est
    /// la règle CLDR, elle vit dans les variations du catalogue, et c'est ce
    /// qui remplace l'ancien `abs(n) < 2 ? singulier : pluriel` codé en dur.
    /// Les clés dont la forme SINGULIER dit la chose au lieu de la compter :
    /// « La dernière requête lancée » est meilleur français que « Les 1
    /// dernières requêtes lancées », et l'anglais suit. Elles sont nommées ici
    /// une par une, pour que la règle générale — une forme de pluriel porte le
    /// nombre — reste vraie partout ailleurs (audit B1-24).
    private static let pluralsWithoutCountInSingular: Set<String> = [
        "The last %lld queries run, each one click away."
    ]

    func testPluralKeysCarryBothFormsInBothLanguages() throws {
        let strings = try Self.rawStrings()
        var plurals = 0
        for (key, entry) in strings {
            guard let localizations = entry["localizations"] as? [String: Any],
                  let fr = localizations["fr"] as? [String: Any],
                  let variations = fr["variations"] as? [String: Any],
                  let plural = variations["plural"] as? [String: Any]
            else { continue }
            plurals += 1
            XCTAssertNotNil(plural["one"], "« \(key) » : pas de forme « one »")
            XCTAssertNotNil(plural["other"], "« \(key) » : pas de forme « other »")
            for form in ["one", "other"] {
                guard let unit = (plural[form] as? [String: Any])?["stringUnit"]
                        as? [String: Any] else {
                    return XCTFail("« \(key) » : forme \(form) illisible")
                }
                XCTAssertEqual(unit["state"] as? String, "translated", key)
                let value = unit["value"] as? String ?? ""
                XCTAssertFalse(value.isEmpty, "« \(key) » : forme \(form) vide")
                let mayOmit = form == "one"
                    && Self.pluralsWithoutCountInSingular.contains(key)
                if mayOmit {
                    XCTAssertFalse(value.contains("%lld"),
                                   "« \(key) » : la forme « one » est inscrite "
                                   + "comme sans nombre, elle n'en porte donc "
                                   + "pas — « \(value) »")
                } else {
                    XCTAssertTrue(value.contains("%lld") || value.contains("%@") || value.contains("%1$@") || value.contains("%2$@"),
                                  "« \(key) » : la forme \(form) doit porter le "
                                  + "nombre — « \(value) »")
                }
            }
            // L'anglais doit avoir les MÊMES variations : sans elles, `en.lproj`
            // n'aurait pas de `.stringsdict` et « 1 pages » reviendrait.
            let en = localizations["en"] as? [String: Any]
            XCTAssertNotNil((en?["variations"] as? [String: Any])?["plural"],
                            "« \(key) » : l'anglais n'a pas de variation")
        }
        XCTAssertGreaterThanOrEqual(plurals, 10,
                                    "les comptes parlés doivent passer par des "
                                    + "variations de pluriel")
    }

    /// Deux accords fautifs étaient atteignables dans un cas COURANT, parce que
    /// deux clés `%lld` n'avaient aucune variation : « Les 1 dernières requêtes
    /// lancées » après la toute première recherche, et « Page 1 sur 1 pages
    /// porteuses de texte » sur un document d'une seule page (audit B1-24).
    ///
    /// La seconde a DEUX arguments et son accord dépend du second : sa règle vit
    /// donc dans une `substitution` du catalogue, pas dans une variation de
    /// premier niveau — c'est le mécanisme que `xcstringstool` compile en
    /// `NSStringLocalizedFormatKey`. Les deux mécanismes sont vérifiés ici.
    func testTheTwoFaultyAgreementsAreFixed() throws {
        let strings = try Self.rawStrings()

        // a. Variation de premier niveau, un seul argument.
        let history = try XCTUnwrap(
            strings["The last %lld queries run, each one click away."],
            "la clé de l'historique a disparu du catalogue")
        for lang in ["en", "fr"] {
            let entry = (history["localizations"] as? [String: Any])?[lang]
            let plural = ((entry as? [String: Any])?["variations"]
                          as? [String: Any])?["plural"] as? [String: Any]
            XCTAssertNotNil(plural,
                            "« The last %lld queries run » n'a pas de variation "
                            + "de pluriel en \(lang) : « Les 1 dernières "
                            + "requêtes lancées » reviendrait")
        }

        // b. Substitution sur le SECOND argument.
        let page = try XCTUnwrap(strings["Page %lld of %lld pages carrying text"],
                                 "la clé de l'aperçu a disparu du catalogue")
        for lang in ["en", "fr"] {
            let entry = try XCTUnwrap(
                (page["localizations"] as? [String: Any])?[lang]
                    as? [String: Any], lang)
            let substitutions = try XCTUnwrap(
                entry["substitutions"] as? [String: Any],
                "« Page %lld of %lld pages carrying text » n'a pas de "
                + "substitution en \(lang) : « Page 1 sur 1 pages » reviendrait")
            let total = try XCTUnwrap(
                substitutions.values.first as? [String: Any], lang)
            XCTAssertEqual(total["argNum"] as? Int, 2,
                           "l'accord porte sur le NOMBRE DE PAGES, "
                           + "pas sur le numéro de page (\(lang))")
            let plural = try XCTUnwrap(
                (total["variations"] as? [String: Any])?["plural"]
                    as? [String: Any], lang)
            for form in ["one", "other"] {
                let unit = (plural[form] as? [String: Any])?["stringUnit"]
                    as? [String: Any]
                let value = unit?["value"] as? String ?? ""
                XCTAssertEqual(unit?["state"] as? String, "translated",
                               "\(lang)/\(form)")
                XCTAssertTrue(value.contains("%arg"),
                              "\(lang)/\(form) doit porter le nombre substitué "
                              + "— « \(value) »")
            }
            // La chaîne porteuse doit référencer la substitution, sinon le
            // nombre de pages disparaîtrait de la phrase.
            let format = (entry["stringUnit"] as? [String: Any])?["value"]
                as? String ?? ""
            XCTAssertTrue(format.contains("%#@"),
                          "\(lang) : « \(format) » n'appelle pas la substitution")
        }
    }

    /// Sept comptes français faux au singulier, mesurés le 09/09/2026 sur le
    /// catalogue livré (audit AP-19, lot L2). Trois écrivaient l'accord entre
    /// parenthèses — « %lld ignoré(s) », « %@ p. chargée(s) » —, quatre le
    /// posaient au pluriel quel que soit le nombre, dont « dans le 1 document
    /// trouvé », que la première recherche d'un seul résultat affichait.
    ///
    /// LA COUPURE EST DANS LE TYPE DE L'ARGUMENT, pas dans la phrase : les
    /// quatre clés en `%lld` (un entier NU, que Foundation peut trancher)
    /// reçoivent une variation ; les trois en `%@` portent un nombre DÉJÀ
    /// formaté par `Format.integer`, que `xcstringstool` refuse dans un
    /// pluriel (docs/i18n.md), et se reformulent donc sans accord du tout.
    /// Une phrase qui ne compte pas est préférable à une parenthèse.
    func testTheSevenFaultyCountsOfAP19AreFixed() throws {
        let strings = try Self.rawStrings()

        // a. Les quatre clés en %lld : le rendu à 1 et à 3.
        let counted: [String: (one: String, other: String)] = [
            "%lld skipped": ("1 ignoré", "3 ignorés"),
            "about %lld h left": ("environ 1 h restante",
                                  "environ 3 h restantes"),
            "about %lld min left": ("environ 1 min restante",
                                    "environ 3 min restantes"),
            "in the %lld document(s) found": ("dans 1 document trouvé",
                                              "dans les 3 documents trouvés"),
        ]
        for (key, forms) in counted {
            let entry = try XCTUnwrap(strings[key], "« \(key) » a disparu")
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any], key)
            let fr = try XCTUnwrap(localizations["fr"] as? [String: Any], key)
            let plural = try XCTUnwrap(
                (fr["variations"] as? [String: Any])?["plural"]
                    as? [String: Any],
                "« \(key) » n'a pas de variation fr : le singulier serait faux")
            for (form, count, want) in [("one", 1, forms.one),
                                        ("other", 3, forms.other)] {
                let value = ((plural[form] as? [String: Any])?["stringUnit"]
                             as? [String: Any])?["value"] as? String ?? ""
                XCTAssertEqual(
                    value.replacingOccurrences(of: "%lld", with: "\(count)"),
                    want, "« \(key) » rendu à \(count)")
            }
            // Sans variation ANGLAISE, `en.lproj` n'a pas de `.stringsdict` et
            // c'est l'anglais qui dirait « 1 skipped » depuis la forme unique.
            let en = localizations["en"] as? [String: Any]
            XCTAssertNotNil((en?["variations"] as? [String: Any])?["plural"],
                            "« \(key) » : l'anglais n'a pas de variation")
        }

        // b. Les trois clés en %@ : une phrase qui ne s'accorde plus. L'espace
        // devant les deux-points est l'espace fine insécable U+202F (AP-20) et
        // l'apostrophe est courbe (BU-10) — écrites en échappement pour que le
        // test reste lisible.
        let invariant = [
            "%@ p. loaded": "%@ p. pour l\u{2019}instant",
            "%@ of %@ pages are ready":
                "Pages prêtes\u{202F}: %1$@ sur %2$@",
            "Not supported here, therefore ignored: %@":
                "Non pris en charge ici, donc ignorés\u{202F}: %@",
        ]
        for (key, want) in invariant {
            let entry = try XCTUnwrap(strings[key], "« \(key) » a disparu")
            let value = (((entry["localizations"] as? [String: Any])?["fr"]
                          as? [String: Any])?["stringUnit"]
                         as? [String: Any])?["value"] as? String
            XCTAssertEqual(value, want, "« \(key) »")
        }
    }

    /// Les nombres PARLÉS restent nus : `Format.integer` groupe les milliers, et
    /// un séparateur — l'espace fine insécable du français comme la virgule de
    /// l'anglais — fait entendre deux nombres au synthétiseur. L'affichage
    /// groupe, le libellé non (audit U3).
    ///
    /// Le séparateur d'affichage est celui de `Locale.current` depuis l'audit
    /// B1-13 : `Format.integer` le laissait choisir puis l'écrasait par U+202F
    /// pour toutes les langues, et ce test verrouillait le défaut. Il vérifie
    /// maintenant que le groupement SUIT la locale, sans nommer de constante.
    func testSpokenCountsCarryNoThinSpace() {
        XCTAssertFalse(AccessibilityText.documents(1_203).contains("\u{202F}"))
        XCTAssertFalse(AccessibilityText.pages(1_203).contains("\u{202F}"))

        let separator = Locale.current.groupingSeparator ?? ""
        XCTAssertEqual(Format.integer(1_203), "1\(separator)203",
                       "le groupement est celui de Locale.current")
        XCTAssertFalse(separator.isEmpty,
                       "une locale sans séparateur de groupement rendrait ce "
                       + "test aveugle")
    }

    /// La mise à jour automatique, dite dans la langue de l'utilisateur
    /// (UX-03). Les clés de l'agent d'arrière-plan (B1-05) sont RETIRÉES, pas
    /// seulement inutilisées : « agent », « ré-enregistrer » et « Developer
    /// ID » n'ont jamais rien voulu dire pour le public visé.
    func testAutomaticUpdateKeysAreTranslated() throws {
        let catalog = try Self.catalog()
        let expectedKeys = [
            "Keep the index up to date automatically",
            "Fouine checks your folders from time to time and updates the index by itself, even when its window is closed.",
            "Automatic updates are on. macOS may ask you to confirm in System Settings ▸ General ▸ Login Items.",
            "Automatic updates are off. You can still update the index whenever you like.",
            "Automatic updates have been restarted. macOS may ask you to confirm in System Settings ▸ General ▸ Login Items.",
            "Add a folder first.",
            "Available once Fouine is allowed to read your folders."
        ]
        for key in expectedKeys {
            XCTAssertTrue(catalog.keys.contains(key), "clé absente du catalogue : \(key)")
            assertTranslated(key, in: catalog)
        }
        for gone in ["The agent is registered but is not starting.",
                     "Re-register",
                     "Waiting for the first report…",
                     "Registers the background agent with macOS again.",
                     "Agent registered. macOS may ask for a confirmation in System Settings ▸ General ▸ Login Items.",
                     "Agent unregistered.",
                     "Index in the background",
                     "Automatically index documents in the background when changes are detected.",
                     "Failed: %@ — requires the app installed and signed (Fouine.app with a stable Developer ID identity); impossible from “swift run FouineApp”.",
                     // Le texte d'enregistrement qu'aucune vue ne lisait
                     // (lot MN2). « active » reste : l'accessibilité s'en sert.
                     "unknown",
                     "waiting for first report",
                     "registered but silent",
                     "waiting for approval in System Settings ▸ General ▸ Login Items",
                     "not registered",
                     "background indexing not found (requires the app installed and signed)",
                     "unknown state"] {
            XCTAssertFalse(catalog.keys.contains(gone),
                           "clé morte encore au catalogue : \(gone)")
        }
    }

    /// Le bandeau de santé et l'écran d'échec d'ouverture (H4, registre I1) :
    /// les clés parlent à des non-techniciens, et celles du registre H4
    /// (« Write lock », « vectors », « Run fouine doctor in Terminal ») sont
    /// RETIRÉES, pas seulement inutilisées.
    func testHealthAndOpenFailureKeysAreTranslated() throws {
        let catalog = try Self.catalog()
        let expectedKeys = [
            "Background indexing: on",
            "Background indexing: off",
            "Index available",
            "The index is being updated (background indexing, since %@)",
            "Search by meaning: ready",
            "Search by meaning: being prepared",
            "Search by meaning: not installed",
            "No folder to index",
            "The disk holding “%@” is not plugged in",
            "Fouine is not allowed to read “%@”",
            "Allow access…",
            "Diagnostic",
            "Copy",
            "Try again in a moment: the index is being updated (%@).",
            "This index was created by a newer version of Fouine. Update Fouine.",
            "The disk is full. Free up some disk space, then try again.",
        ]
        for key in expectedKeys {
            XCTAssertTrue(catalog.keys.contains(key), "clé absente du catalogue : \(key)")
            assertTranslated(key, in: catalog)
        }
        for gone in ["All systems operational", "Write lock: free", "Write lock: busy",
                     "Semantic model: installed, 0 vectors", "Run fouine doctor in Terminal",
                     "Background agent: service not found",
                     // UX-03 : la pastille « Tout fonctionne » disait à la fois
                     // moins et plus que la carte « Index ».
                     "Everything is working",
                     // HU1 : « sémantique » ne se dit plus dans l'app, le
                     // produit appelle cela « la recherche par le sens ».
                     "Semantic search: ready",
                     "Semantic search: being prepared",
                     "Semantic search: not installed"] {
            XCTAssertFalse(catalog.keys.contains(gone), "clé morte encore au catalogue : \(gone)")
        }
    }

    /// AUCUN MOT DE L'IMPLÉMENTATION DANS LE CATALOGUE (HU1).
    ///
    /// La règle est dans CLAUDE.md depuis le début (« pas de vecteur, pas de
    /// verrou, pas de pid »), et elle se perdait clé par clé : la carte
    /// « Index » annonçait « OCR en cours — 12 pages restantes », la feuille de
    /// désinstallation parlait de « l'agent d'arrière-plan », un onglet de
    /// réglages de « la recherche sémantique » quand l'interrupteur juste
    /// au-dessus s'appelle « Chercher aussi par le sens ». Le test porte sur
    /// les CLÉS et sur les VALEURS des deux langues : une clé anglaise propre
    /// avec une traduction française qui dit « file OCR » ne vaut rien.
    ///
    /// Les deux exceptions sont nommées, et documentées dans docs/i18n.md :
    /// `ErrorText` préfixe un détail technique de « OCR : » ou
    /// « text recognition (OCR) » pour qu'il soit recopiable dans un rapport
    /// de bogue.
    func testNoImplementationWordReachesTheReader() throws {
        let exempt: Set<String> = ["OCR: %@", "text recognition (OCR)"]
        let banned = ["semantic", "sémantique", "vector", "vecteur", "lexical",
                      "cosin", "rowid", "OCR queue", "file OCR", "stats()",
                      "background agent", "agent d'arrière-plan",
                      "agent d’arrière-plan", "write lock", "verrou"]
        for (key, entry) in try Self.catalog() where !exempt.contains(key) {
            var texts = [key]
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for language in localizations.values {
                texts.append(contentsOf: Self.values(in: language))
            }
            for text in texts {
                for word in banned {
                    XCTAssertFalse(text.lowercased().contains(word.lowercased()),
                                   "« \(word) » est visible dans « \(text) »")
                }
            }
        }
    }

    /// Toutes les valeurs d'une localisation : la simple, les variations de
    /// pluriel, les substitutions.
    private static func values(in localization: Any) -> [String] {
        guard let localization = localization as? [String: Any] else { return [] }
        var out: [String] = []
        if let unit = localization["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String { out.append(value) }
        for node in [localization["variations"], localization["substitutions"]] {
            guard let node = node as? [String: Any] else { continue }
            for child in node.values { out.append(contentsOf: values(in: child)) }
            // Les substitutions portent leurs variations un cran plus bas.
            for child in node.values where (child as? [String: Any]) != nil {
                for grandChild in ((child as? [String: Any]) ?? [:]).values {
                    out.append(contentsOf: values(in: grandChild))
                }
            }
        }
        return out
    }

    // MARK: - 4. Le rendu, catalogue COMPILÉ

    /// Le seul contrôle qui voie ce que voit l'utilisateur.
    ///
    /// `swift test` ne tourne pas depuis `Fouine.app` : `Bundle.main` n'a aucun
    /// `.lproj`, `String(localized:)` rend la CLÉ, et un désaccord de type entre
    /// la clé et la traduction reste alors PARFAITEMENT invisible. C'est ce qui
    /// s'est produit le 04/09/2026 : vingt et une clés annonçaient `%@` —
    /// le code y interpolait `Format.integer(n)`, donc une chaîne — pendant que
    /// la traduction écrivait `%lld`, imposé par `xcstringstool` qui refuse
    /// `%@` dans un pluriel. En anglais de base, tout allait bien ; dans l'app
    /// livrée, Foundation lisait le POINTEUR de la chaîne comme un entier 64
    /// bits et la barre latérale annonçait « 105 553 137 941 168 pages encore
    /// à reconnaître ».
    ///
    /// Ce test compile le catalogue avec `xcstringstool` — le même outil, la
    /// même commande que `Packaging/bundle.sh` — puis rend CHAQUE clé portant
    /// un compte, en français et en anglais. Un nombre qui n'est pas celui
    /// qu'on a passé fait échouer.
    func testCompiledCataloguesRenderTheCountsThemselves() throws {
        let tool = try Self.xcstringstool()
        let directory = try Self.compiledCatalogues(with: tool)
        defer { try? FileManager.default.removeItem(at: directory) }

        let separator = Locale.current.groupingSeparator ?? ""
        for language in ["fr", "en"] {
            let bundle = try XCTUnwrap(
                Bundle(path: directory.appendingPathComponent("\(language).lproj").path),
                "\(language).lproj absent du catalogue compilé")
            for (key, kinds) in try Self.renderableKeys() {
                for count in [1, 2, 4321] {
                    let format = bundle.localizedString(forKey: key, value: "",
                                                        table: nil)
                    XCTAssertFalse(format.isEmpty,
                                   "« \(key) » absente de \(language).lproj")
                    let arguments: [CVarArg] = kinds.map {
                        $0 == .integer ? count as CVarArg : "…" as CVarArg
                    }
                    let rendered = String(format: format, locale: .current,
                                          arguments: arguments)
                    let flat = separator.isEmpty ? rendered
                        : rendered.replacingOccurrences(of: separator, with: "")
                    let numbers = flat
                        .components(separatedBy: CharacterSet.decimalDigits.inverted)
                        .filter { !$0.isEmpty }
                    // a. Aucune adresse. Une phrase peut porter des chiffres en
                    //    clair — « ~410 Mo de pics », « 8 fils » —, mais aucun
                    //    compte de Fouine n'a dix chiffres, là où une adresse du
                    //    tas en a quinze : « 105 553 137 941 168 ».
                    for number in numbers {
                        XCTAssertLessThan(number.count, 10,
                                          "« \(key) » en \(language), \(count) : "
                                          + "« \(rendered) » — un `%lld` face à un "
                                          + "argument objet affiche l'ADRESSE de "
                                          + "cet objet")
                    }
                    // b. Le compte arrive bien dans la phrase. Seules les formes
                    //    de singulier inscrites comme sans nombre en sont
                    //    dispensées (« La dernière requête lancée »).
                    let mayOmit = count == 1
                        && Self.pluralsWithoutCountInSingular.contains(key)
                    if kinds.contains(.integer), !mayOmit {
                        XCTAssertTrue(numbers.contains("\(count)"),
                                      "« \(key) » en \(language), \(count) : "
                                      + "« \(rendered) » ne porte pas le compte "
                                      + "qu'on lui a passé")
                    }
                }
            }
        }
    }

    /// La compilation elle-même ne doit RIEN avertir : « Cannot reliably infer
    /// argument number for plural variation » veut dire que deux entiers se
    /// disputent l'accord et que le second nom restera au pluriel — « 1 page
    /// dans 1 documents ». L'avertissement se noie dans la sortie de
    /// `make bundle` ; ici il échoue.
    func testCompilingTheCataloguesWarnsAboutNothing() throws {
        let tool = try Self.xcstringstool()
        for catalog in [Self.appCatalogURL,
                        Self.repositoryRoot
                            .appendingPathComponent("Packaging/InfoPlist.xcstrings")] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("l10n-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let process = Process()
            process.executableURL = tool
            process.arguments = ["compile", catalog.path,
                                 "--output-directory", directory.path]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = Pipe()
            try process.run()
            let said = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) ?? ""
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0,
                           "xcstringstool a échoué sur \(catalog.lastPathComponent)")
            XCTAssertTrue(said.isEmpty,
                          "\(catalog.lastPathComponent) : xcstringstool avertit —\n\(said)")
        }
    }

    // MARK: - Outils

    private enum ArgumentKind { case integer, object }

    /// `xcstringstool`, ou un saut : il vient d'Xcode, pas des outils en ligne
    /// de commande, et un worktree neuf peut n'en avoir aucun.
    private static func xcstringstool() throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "xcstringstool"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0 && !path.isEmpty,
                          "xcstringstool introuvable (Xcode absent)")
        return URL(fileURLWithPath: path)
    }

    /// Le catalogue de l'app compilé en `{en,fr}.lproj`, comme le fait
    /// `Packaging/bundle.sh` avant de signer.
    private static func compiledCatalogues(with tool: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("l10n-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = tool
        process.arguments = ["compile", appCatalogURL.path,
                             "--output-directory", directory.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "xcstringstool a échoué")
        return directory
    }

    /// TOUTES les clés du catalogue, avec le TYPE de chacun de leurs arguments
    /// dans l'ordre.
    ///
    /// Le type vient de la CLÉ, engendrée par le compilateur à partir de ce que
    /// le code interpole : c'est la référence, jamais la traduction. Et le
    /// balayage porte sur toutes les clés, y compris celles sans compte —
    /// c'est précisément une clé en `%@` traduite par `%lld` qui a produit
    /// l'adresse mémoire du 04/09/2026, et la filtrer sur « porte un entier »
    /// reviendrait à ne pas la regarder.
    private static func renderableKeys() throws -> [(String, [ArgumentKind])] {
        let pattern = "%(?:([0-9]+)\\$)?[-+ #0]*[0-9]*(?:\\.[0-9]+)?(lld|ld|d|@)"
        let regex = try NSRegularExpression(pattern: pattern)
        var out: [(String, [ArgumentKind])] = []
        for key in try rawStrings().keys.sorted() {
            var kinds: [Int: ArgumentKind] = [:]
            var auto = 0
            let range = NSRange(key.startIndex..<key.endIndex, in: key)
            for match in regex.matches(in: key, range: range) {
                let position: Int
                if let r = Range(match.range(at: 1), in: key) {
                    position = Int(key[r]) ?? 0
                } else {
                    auto += 1
                    position = auto
                }
                let letter = String(key[Range(match.range(at: 2), in: key)!])
                kinds[position] = letter == "@" ? .object : .integer
            }
            // Les positions doivent se suivre : une clé qui saute un argument
            // ne se rend pas sans deviner ce qu'on lui passe.
            guard kinds.isEmpty || kinds.keys.sorted() == Array(1...kinds.count)
            else { continue }
            out.append((key, kinds.keys.sorted().map { kinds[$0]! }))
        }
        XCTAssertGreaterThanOrEqual(
            out.filter { $0.1.contains(.integer) }.count, 50,
            "les comptes de l'app passent par des clés à `%lld` — il en manque")
        return out
    }

    private static func rawStrings() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: appCatalogURL)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any],
              let strings = root["strings"] as? [String: [String: Any]]
        else { throw XCTSkip("Localizable.xcstrings illisible") }
        XCTAssertEqual(root["sourceLanguage"] as? String, "en",
                       "l'anglais est la langue de BASE")
        return strings
    }

    static func catalog() throws -> [String: [String: Any]] {
        try rawStrings()
    }

    /// La clé a-t-elle une valeur `fr` à l'état « translated » ?
    private func assertTranslated(_ key: String,
                                  in catalog: [String: [String: Any]],
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        guard let entry = catalog[key],
              let localizations = entry["localizations"] as? [String: Any],
              let fr = localizations["fr"] as? [String: Any] else {
            return XCTFail("« \(key) » n'a pas de traduction fr",
                           file: file, line: line)
        }
        var units: [[String: Any]] = []
        if let unit = fr["stringUnit"] as? [String: Any] { units.append(unit) }
        for variation in (fr["variations"] as? [String: Any])?.values ?? [:].values {
            for form in (variation as? [String: Any])?.values ?? [:].values {
                if let unit = (form as? [String: Any])?["stringUnit"]
                    as? [String: Any] { units.append(unit) }
            }
        }
        XCTAssertFalse(units.isEmpty, "« \(key) » : fr vide",
                       file: file, line: line)
        for unit in units {
            XCTAssertEqual(unit["state"] as? String, "translated",
                           "« \(key) »", file: file, line: line)
            XCTAssertFalse((unit["value"] as? String ?? "").isEmpty,
                           "« \(key) » : valeur fr vide", file: file, line: line)
        }
    }
}
