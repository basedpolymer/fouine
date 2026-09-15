// CrawlTests.swift — T8 (filtre d'exclusions) et T10 (idempotence) au niveau
// unitaire, sur arborescences temporaires réelles. Propriété : A-Ingest.

import XCTest
import FouineCore
@testable import FouineCrawl

final class CrawlExclusionsTests: XCTestCase {

    /// T8, volet unitaire : le filtre s'exerce sur des chemins SYNTHÉTIQUES —
    /// l'AppleDouble n'est plus discriminant sur APFS (0 fichier `._*` mesuré).
    func testExcludedComponents() {
        for name in [".DS_Store", ".ds_store", ".Trashes", ".TemporaryItems",
                     ".fseventsd", ".Spotlight-V100", ".git", "$RECYCLE.BIN",
                     "System Volume Information", "Thumbs.db", "thumbs.db",
                     "desktop.ini", "._resume.pdf", "._", "._.DS_Store",
                     ".noindex", "Cache.noindex", "projets.NOINDEX"] {
            XCTAssertTrue(CrawlExclusions.isExcluded(component: name),
                          "\(name) doit être exclu")
        }
    }

    func testKeptComponents() {
        for name in ["Arnaud - Chimie organique.pdf", "notes.md", "TD 3.docx",
                     "Chimie", ".hidden-but-fine.txt", "_underscore.pdf",
                     "desktop.ini.txt", "noindex.txt", "mon-noindex-doc.pdf"] {
            XCTAssertFalse(CrawlExclusions.isExcluded(component: name),
                           "\(name) ne doit pas être exclu")
        }
    }

    /// Le crawler ne retient que les extensions prises en charge par
    /// FouineExtract. `Package.swift` est gelé et ne donne pas FouineExtract à
    /// FouineCrawl : la liste est recopiée, et ce littéral — identique à celui
    /// de `RegistryTests.testSupportedExtensionsAreTheUnionOfSection53` — est ce
    /// qui fait échouer un test si l'une des deux dérive.
    func testIndexableExtensionsMirrorSection53() {
        // Le nombre, puis les familles. L'EGALITE avec le registre d'extraction
        // se prouve dans FouineExtractTests (`RegistryTests`), la seule suite
        // qui voie les deux modules ; ici on tient l'autre bout, pour qu'une
        // extension retiree de la liste casse aussi du cote du crawl.
        XCTAssertEqual(FouineCrawler.defaultIndexableExtensions.count, 114)
        for ext in ["pdf", "doc", "rtf", "rtfd", "docx", "odt", "ods", "odp",
                    "html", "htm", "webarchive", "txt", "md", "csv", "tsv",
                    "tex", "json", "log", "xlsx", "pptx", "xls", "ppt",
                    "epub", "cbz", "cbr", "djvu", "pages", "numbers", "key",
                    "eml", "emlx", "olk15msgsource", "mbox",
                    "xml", "xsd", "xsl", "xslt", "svg", "plist",
                    "srt", "vtt", "ipynb",
                    "ai", "sketch", "fig", "indd",
                    "py", "js", "tsx", "swift", "yaml", "sql", "sh", "css"] {
            XCTAssertTrue(FouineCrawler.defaultIndexableExtensions.contains(ext), ext)
        }
        // `psd` est une IMAGE (lot INT-F2) : comme `png`, il n'entre que sous
        // `extract.images`, et jamais par la liste par défaut.
        for ext in ["mp4", "png", "psd", "webp", "exe", "dmg"] {
            XCTAssertFalse(FouineCrawler.defaultIndexableExtensions.contains(ext), ext)
        }
    }

    // MARK: - INT-F1 : sorties de construction, SOUS un projet seulement

    /// La decision PURE, telle que le crawler l'appelle.
    func testBuildFolderIsExcludedOnlyUnderAProject() {
        for name in ["dist", "build", "OUT", "target", ".next", "coverage",
                     "vendor", "site-packages", "__snapshots__"] {
            XCTAssertTrue(CrawlExclusions.isExcludedBuildFolder(
                component: name, parentContainsProjectMarker: true), name)
            XCTAssertFalse(CrawlExclusions.isExcludedBuildFolder(
                component: name, parentContainsProjectMarker: false), name)
        }
        // Un nom qui n'est pas une sortie de construction ne l'est pas davantage
        // sous un projet.
        XCTAssertFalse(CrawlExclusions.isExcludedBuildFolder(
            component: "Chimie", parentContainsProjectMarker: true))
    }

    func testProjectMarkersAreRecognisedWhateverTheirCase() {
        for name in ["package.json", "Cargo.toml", "Package.swift", "Gemfile",
                     "pyproject.toml", "go.mod", ".git", "build.gradle.kts"] {
            XCTAssertTrue(CrawlExclusions.isProjectMarker(component: name), name)
        }
        XCTAssertFalse(CrawlExclusions.isProjectMarker(component: "notes.md"))
    }

    func testOpaqueBundles() {
        XCTAssertTrue(CrawlExclusions.isOpaqueBundle(component: "Rapport.pages"))
        XCTAssertTrue(CrawlExclusions.isOpaqueBundle(component: "Soutenance.KEY"))
        XCTAssertTrue(CrawlExclusions.isOpaqueBundle(component: "Budget.numbers"))
        XCTAssertFalse(CrawlExclusions.isOpaqueBundle(component: "Rapport.pdf"))
        XCTAssertFalse(CrawlExclusions.isOpaqueBundle(component: "pages"))
    }

    // MARK: - F5 : dépendances, caches et paquets

    /// Les trois familles ajoutées après l'audit F5. Ce sont celles qu'un
    /// ~/Documents ordinaire contient et qu'un dossier de livres n'a jamais eues.
    func testDependencyAndCacheDirectoriesAreExcluded() {
        for name in ["node_modules", ".venv", "venv", ".build", "DerivedData",
                     "deriveddata", "Pods", "Carthage", ".tox", "__pycache__",
                     ".cache", ".npm", ".cargo", ".gradle", ".m2",
                     ".svn", ".hg", ".Trash", ".DocumentRevisions-V100"] {
            XCTAssertTrue(CrawlExclusions.isExcluded(component: name),
                          "\(name) doit être exclu")
        }
    }

    /// Un nom qui RESSEMBLE à une exclusion n'en est pas une : le filtre porte
    /// sur le composant entier, jamais sur un préfixe.
    func testLookalikeNamesAreKept() {
        for name in ["node_modules.md", "Pods et casseroles.pdf", "cargo.txt",
                     "venv-notes.md", "Carthage - histoire.epub"] {
            XCTAssertFalse(CrawlExclusions.isExcluded(component: name),
                           "\(name) ne doit pas être exclu")
        }
    }

    /// `isPackageKey` FAIT AUTORITÉ quand il répond, la liste d'extensions prend
    /// le relais quand il rend `false` (disque réseau, volume sans
    /// LaunchServices) — c'est tout l'objet du repli.
    func testPackageDetectionUsesLaunchServicesThenExtensions() {
        // LaunchServices dit oui : on le croit, même sur une extension inconnue.
        XCTAssertTrue(CrawlExclusions.isPackage(extension: "trucmachin",
                                                declaredByLaunchServices: true))
        // LaunchServices dit non ou ne répond pas : le repli tranche.
        for ext in ["app", "APP", "photoslibrary", "musiclibrary", "fcpbundle",
                    "framework", "xcodeproj", "bundle", "kext", "appex",
                    "qlgenerator", "xcarchive", "dsym", "imovielibrary", "band",
                    "logicx", "sparsebundle", "vmwarevm", "pvm",
                    "pages", "key", "numbers"] {
            XCTAssertTrue(CrawlExclusions.isPackage(extension: ext,
                                                    declaredByLaunchServices: false),
                          "\(ext) doit être traité comme un paquet")
            XCTAssertTrue(CrawlExclusions.isPackage(extension: ext,
                                                    declaredByLaunchServices: nil),
                          "\(ext) doit être traité comme un paquet")
        }
        // Un dossier ordinaire reste un dossier, extension ou pas.
        for ext in ["", "old", "pdf", "sauvegarde", "2024"] {
            XCTAssertFalse(CrawlExclusions.isPackage(extension: ext,
                                                     declaredByLaunchServices: false),
                           "\(ext) ne doit pas être traité comme un paquet")
        }
    }

    /// `~/Library` s'exclut par CHEMIN : un dossier « Library » ailleurs est un
    /// dossier de documents comme un autre.
    func testHomeLibraryIsExcludedByPathNeverByName() {
        XCTAssertTrue(CrawlExclusions.isHomeLibrary(path: "/Users/x/Library",
                                                    home: "/Users/x"))
        XCTAssertTrue(CrawlExclusions.isHomeLibrary(path: "/Users/x/Library",
                                                    home: "/Users/x/"))
        XCTAssertFalse(CrawlExclusions.isHomeLibrary(path: "/Users/x/Livres/Library",
                                                     home: "/Users/x"))
        XCTAssertFalse(CrawlExclusions.isHomeLibrary(path: "/Volumes/Cours/Library",
                                                     home: "/Users/x"))
        // Un sous-dossier de ~/Library n'a pas à être testé : on ne descend
        // jamais dans ~/Library, donc on ne le rencontre pas.
        XCTAssertFalse(CrawlExclusions.isHomeLibrary(path: "/Users/x/Library/Mail",
                                                     home: "/Users/x"))
        // Un home vide ou « / » ne doit rien exclure.
        XCTAssertFalse(CrawlExclusions.isHomeLibrary(path: "/Library", home: ""))
        XCTAssertFalse(CrawlExclusions.isHomeLibrary(path: "/Library", home: "/"))
    }
}

/// Le prédicat « non résident » (F5). Le lecteur de drapeaux est simulé : le
/// noyau ne laisse pas un test poser `SF_DATALESS` sur un fichier.
final class FileResidencyTests: XCTestCase {

    let file = URL(fileURLWithPath: "/tmp/inexistant.pdf")

    func testDatalessFlagIsMaskedNotCompared() {
        // Le drapeau arrive TOUJOURS mêlé aux autres (UF_HIDDEN, UF_COMPRESSED
        // sur APFS…) : une égalité stricte ne verrait jamais rien.
        let mixed = FileResidency.datalessFlag | UInt32(UF_HIDDEN)
        XCTAssertTrue(FileResidency.isDataless(file, flags: { _ in mixed }))
        XCTAssertTrue(FileResidency.isDataless(file,
                                               flags: { _ in FileResidency.datalessFlag }))
        XCTAssertFalse(FileResidency.isDataless(file, flags: { _ in 0 }))
        XCTAssertFalse(FileResidency.isDataless(file, flags: { _ in UInt32(UF_HIDDEN) }))
        // `lstat` en échec : le fichier a disparu, ce n'est pas une éviction.
        XCTAssertFalse(FileResidency.isDataless(file, flags: { _ in nil }))
    }

    func testDatalessFlagValue() {
        XCTAssertEqual(FileResidency.datalessFlag, 0x4000_0000)
    }

    /// Le motif doit dire la cause ET la suite : sans la seconde moitié,
    /// l'utilisateur croit devoir intervenir.
    func testSkipReasonNamesTheCauseAndTheRemedy() {
        XCTAssertTrue(FileResidency.skipReason.contains("not downloaded"))
        XCTAssertTrue(FileResidency.skipReason.contains("once present"))
    }
}

final class FouineCrawlerTests: XCTestCase {

    var root: URL!
    var store: InMemoryStore!
    var rootRecord: RootRecord!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fouine-crawl-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        // La racine se résout par UUID de volume (§2.3), jamais par chemin seul.
        let resolved = try VolumeResolver.resolve(path: root)
        rootRecord = RootRecord(id: 1, volUUID: resolved.volUUID,
                                relPath: resolved.relPath, label: "TestRoot",
                                enabled: true)
        store = InMemoryStore()
        store.addRoot(rootRecord)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Outils

    @discardableResult
    func write(_ relative: String, _ contents: String = "contenu") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func mtime(of url: URL) throws -> Double {
        var st = stat()
        XCTAssertEqual(stat(url.path, &st), 0)
        return Double(st.st_mtimespec.tv_sec)
            + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000
    }

    func setMTime(_ url: URL, seconds: Int, nanoseconds: Int) {
        var times = [timespec(tv_sec: seconds, tv_nsec: nanoseconds),
                     timespec(tv_sec: seconds, tv_nsec: nanoseconds)]
        XCTAssertEqual(utimensat(AT_FDCWD, url.path, &times, 0), 0)
    }

    var relPathsIndexed: [String] {
        store.allDocs.map(\.record.relPath)
    }

    /// Le motif que `DjvuExtractor` écrit dans `docs.err`. RECOPIÉ ici, et non
    /// importé : `Package.swift` est gelé et FouineCrawlTests n'a pas
    /// FouineExtract. C'est ce littéral qui casse si l'une des deux dérive —
    /// `ExtractorTests.testDjvuSkipReasonCarriesTheToolToken` tient l'autre bout.
    enum DjvuExtractorReason {
        static let djvu = "djvu: djvulibre is missing (missing-tool:djvused)"
    }

    // MARK: - T8 : exclusions sur une arborescence réelle

    func testCrawlAppliesMandatoryExclusions() throws {
        try write("ok.pdf")
        try write("notes.txt")
        try write("sub/deep.md")
        try write("image.jpg")                       // extension non prise en charge
        try write("film.mp4")
        try write(".DS_Store")
        try write("._resume.pdf")
        try write("sub/._resume.pdf")
        try write(".Spotlight-V100/piege.pdf")
        try write(".Trashes/piege.pdf")
        try write(".TemporaryItems/piege.pdf")
        try write(".fseventsd/piege.pdf")
        try write(".git/objects/piege.pdf")
        try write("Thumbs.db")
        try write("desktop.ini")
        try write("$RECYCLE.BIN/piege.pdf")
        try write("System Volume Information/piege.pdf")
        // Paquet Apple : traité comme un FICHIER, jamais parcouru en profondeur.
        try write("Rapport.pages/Index/Document.iwa")
        try write("Soutenance.key/Index/piege.pdf")

        let crawler = FouineCrawler()
        let summary = try crawler.crawl(rootID: 1, mode: .full, store: store)

        // Rapport.pages et Soutenance.key entrent comme 1 document chacun ;
        // leurs fichiers internes (Document.iwa, piege.pdf) ne sont jamais parcourus.
        XCTAssertEqual(relPathsIndexed.map { ($0 as NSString).lastPathComponent }.sorted(),
                       ["Rapport.pages", "Soutenance.key", "deep.md", "notes.txt", "ok.pdf"])
        XCTAssertEqual(summary.seen, 5)
        XCTAssertEqual(summary.added, 5)
        XCTAssertGreaterThan(summary.skipped, 0)

        for path in relPathsIndexed {
            XCTAssertFalse(path.contains("/._"), path)
            XCTAssertFalse(path.contains(".DS_Store"), path)
            XCTAssertFalse(path.contains(".Spotlight-V100"), path)
            XCTAssertFalse(path.contains(".Trashes"), path)
            XCTAssertFalse(path.contains(".git/"), path)
            XCTAssertFalse(path.contains(".pages/"), path)
            XCTAssertFalse(path.contains(".key/"), path)
        }
    }

    /// Un dossier `.rtfd` est un paquet indexable : il entre comme FICHIER, et on
    /// ne descend pas dedans chercher son `TXT.rtf`.
    func testRTFDBundleIsAFileNotADirectory() throws {
        try write("Lettre.rtfd/TXT.rtf", "{\\rtf1 bonjour}")
        let summary = try FouineCrawler().crawl(rootID: 1, mode: .full, store: store)
        XCTAssertEqual(summary.seen, 1)
        XCTAssertEqual(relPathsIndexed.count, 1)
        XCTAssertTrue(relPathsIndexed[0].hasSuffix("Lettre.rtfd"), relPathsIndexed[0])
    }

    /// Un dossier iWork (`.pages`, `.numbers`, `.key`) est un paquet indexable :
    /// il entre comme FICHIER unique, sans descendre dans ses fragments internes.
    func testIWorkBundleIsAFileNotADirectory() throws {
        try write("Bilan.numbers/Index/Document.iwa", "data")
        try write("Bilan.numbers/QuickLook/Preview.pdf", "%PDF")
        let summary = try FouineCrawler().crawl(rootID: 1, mode: .full, store: store)
        XCTAssertEqual(summary.seen, 1)
        XCTAssertEqual(relPathsIndexed.count, 1)
        XCTAssertTrue(relPathsIndexed[0].hasSuffix("Bilan.numbers"), relPathsIndexed[0])
    }

    /// SOUS un projet logiciel, `build/` est une sortie d'outil : on ne l'indexe
    /// pas. AILLEURS, c'est un dossier de documents comme un autre — celui des
    /// travaux de la maison —, et il doit rester indexé.
    func testBuildFolderIsSkippedUnderAProjectAndKeptElsewhere() throws {
        try write("Projet/package.json", "{}")
        try write("Projet/build/rapport.pdf")
        try write("Projet/src/notes.md")
        try write("Maison/build/devis.pdf")
        try write("Maison/notes.md")

        let summary = try FouineCrawler().crawl(rootID: 1, mode: .full, store: store)
        let names = relPathsIndexed.sorted()
        XCTAssertTrue(names.contains { $0.hasSuffix("Maison/build/devis.pdf") }, "\(names)")
        XCTAssertFalse(names.contains { $0.contains("Projet/build/") }, "\(names)")
        XCTAssertTrue(names.contains { $0.hasSuffix("Projet/src/notes.md") }, "\(names)")
        XCTAssertEqual(summary.seen, 4)
    }

    /// Un dossier `Nom.mbox/` est UNE boîte aux lettres, donc UN document : on
    /// ne descend pas dedans compter ses milliers de messages.
    func testMailboxPackageIsAFileNotADirectory() throws {
        try write("Travail.mbox/mbox", "From a@b Mon Sep  8 09:00:00 2026\nSubject: x\n\ncorps\n")
        try write("Travail.mbox/Messages/1.emlx", "12\nSubject: x\n")
        let summary = try FouineCrawler().crawl(rootID: 1, mode: .full, store: store)
        XCTAssertEqual(summary.seen, 1)
        XCTAssertEqual(relPathsIndexed.count, 1)
        XCTAssertTrue(relPathsIndexed[0].hasSuffix("Travail.mbox"), relPathsIndexed[0])
    }

    // MARK: - F5 : le crawl survit à « j'ajoute ~/Documents »

    /// L'arborescence qu'un dossier de livres n'a jamais eue et que le premier
    /// ~/Documents apporte : un paquet applicatif, une photothèque, deux
    /// dossiers de dépendances, un dépôt git, un fichier caché — et, au milieu,
    /// deux documents qui DOIVENT être indexés.
    func testCrawlSkipsPackagesDependenciesAndHiddenFiles() throws {
        // Paquets. Un `.app` factice est un dossier + Contents/Info.plist :
        // LaunchServices le reconnaît sur l'extension, et le repli aussi.
        try write("Utilitaire.app/Contents/Info.plist", "<plist/>")
        try write("Utilitaire.app/Contents/Resources/manuel.pdf")
        try write("Photos.photoslibrary/database/index.pdf")
        try write("Projet.xcodeproj/project.pbxproj", "// x")
        // Dépendances et caches.
        try write("site/node_modules/lodash/README.md")
        try write("site/.git/objects/piege.pdf")
        try write("script/.venv/lib/notes.txt")
        try write("app/Pods/Alamofire/LISEZMOI.md")
        try write("app/DerivedData/Build/rapport.pdf")
        // Caché : un document caché n'est pas un document qu'on cherche.
        try write(".brouillon.pdf")
        try write(".config/outil/reglages.json")
        // Ce qui doit RESTER : un dossier à extension trompeuse et un vrai
        // document à l'intérieur, plus un document ordinaire.
        try write("photos.old/vacances.pdf")
        try write("Chimie/cours.pdf")

        let summary = try FouineCrawler().crawl(rootID: 1, mode: .full, store: store)

        XCTAssertEqual(relPathsIndexed.map { ($0 as NSString).lastPathComponent }.sorted(),
                       ["cours.pdf", "vacances.pdf"])
        XCTAssertEqual(summary.seen, 2)
        XCTAssertEqual(summary.added, 2)
        for path in relPathsIndexed {
            for interdit in [".app/", ".photoslibrary/", ".xcodeproj/",
                             "node_modules/", ".git/", ".venv/", "Pods/",
                             "DerivedData/", ".config/", ".brouillon"] {
                XCTAssertFalse(path.contains(interdit), "\(path) contient \(interdit)")
            }
        }
    }

    /// Un dossier nommé « rapport.pdf » qui n'est PAS un paquet reste un dossier :
    /// on descend dedans, et son contenu s'indexe.
    func testDirectoryWithAnIndexableExtensionIsStillTraversed() throws {
        try write("rapport.pdf/annexe.pdf")
        let summary = try FouineCrawler().crawl(rootID: 1, mode: .full, store: store)
        XCTAssertEqual(summary.seen, 1)
        XCTAssertTrue(relPathsIndexed[0].hasSuffix("rapport.pdf/annexe.pdf"),
                      relPathsIndexed[0])
    }

    /// `.skipsHiddenFiles` porte sur le CONTENU énuméré, pas sur la base : une
    /// racine elle-même cachée s'indexe normalement.
    func testHiddenRootIsStillCrawled() throws {
        let hidden = root.appendingPathComponent(".documents", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden,
                                                withIntermediateDirectories: true)
        try Data("contenu".utf8).write(to: hidden.appendingPathComponent("a.pdf"))

        let resolved = try VolumeResolver.resolve(path: hidden)
        let hiddenStore = InMemoryStore()
        hiddenStore.addRoot(RootRecord(id: 9, volUUID: resolved.volUUID,
                                       relPath: resolved.relPath,
                                       label: "Caché", enabled: true))

        let summary = try FouineCrawler().crawl(rootID: 9, mode: .full,
                                                store: hiddenStore)
        XCTAssertEqual(summary.seen, 1)
        XCTAssertEqual(hiddenStore.allDocs.count, 1)
    }

    /// `$HOME/Library` est écarté par CHEMIN — et un dossier « Library » qui
    /// n'est pas celui-là garde ses documents.
    func testHomeLibraryIsSkippedButOtherLibrariesAreNot() throws {
        try write("Library/Mail/message.txt")
        try write("Livres/Library/partition.pdf")

        // Le home est injecté : le test ne touche jamais au vrai ~.
        let asHome = try FouineCrawler(home: FouineCrawler.canonicalPath(root.path))
            .crawl(rootID: 1, mode: .full, store: store)
        XCTAssertEqual(asHome.seen, 1)
        XCTAssertTrue(relPathsIndexed[0].hasSuffix("Livres/Library/partition.pdf"),
                      relPathsIndexed[0])

        // Même arborescence, home ailleurs : les DEUX documents entrent.
        let other = InMemoryStore()
        other.addRoot(rootRecord)
        let asCorpus = try FouineCrawler(home: "/Users/quelquun-dautre")
            .crawl(rootID: 1, mode: .full, store: other)
        XCTAssertEqual(asCorpus.seen, 2)
    }

    // MARK: - F5 : fichiers non résidents (iCloud, File Provider)

    /// Lecteur de drapeaux simulé : `SF_DATALESS` sur les fichiers nommés.
    func dataless(_ names: Set<String>) -> FileResidency.FlagsReader {
        { url in
            names.contains(url.lastPathComponent) ? FileResidency.datalessFlag : 0
        }
    }

    /// Un fichier non téléchargé est ENREGISTRÉ `.skipped` avec sa raison — il
    /// n'est ni ignoré en silence (l'utilisateur ne comprendrait pas son
    /// absence) ni ouvert (ce qui le ferait descendre du nuage).
    func testNonResidentFileIsRecordedSkippedNeverOpened() throws {
        try write("present.pdf")
        try write("nuage.pdf")

        let crawler = FouineCrawler(flags: dataless(["nuage.pdf"]))
        let summary = try crawler.crawl(rootID: 1, mode: .full, store: store)

        // « vus » ne compte que les documents retenus pour l'indexation.
        XCTAssertEqual(summary.seen, 1)
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(summary.removed, 0)

        let evicted = try XCTUnwrap(
            store.allDocs.first { $0.record.relPath.hasSuffix("nuage.pdf") })
        XCTAssertEqual(evicted.record.state, .skipped)
        XCTAssertEqual(evicted.record.err, FileResidency.skipReason)
    }

    /// Et il ne DISPARAÎT pas au crawl suivant : il reste « présent », donc la
    /// passe de suppression ne le retire pas.
    func testNonResidentFileSurvivesTheDeletionPass() throws {
        try write("nuage.pdf")
        let crawler = FouineCrawler(flags: dataless(["nuage.pdf"]))
        _ = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        store.resetCounters()

        let second = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(second.removed, 0)
        XCTAssertEqual(store.removedIDs, [])
        XCTAssertEqual(store.allDocs.count, 1)
        // Idempotence (T10) : rien à réécrire, l'état est déjà le bon.
        XCTAssertEqual(store.upsertCount, 0)
    }

    /// LE point qui compte : quand le fichier redescend, le mtime et la taille
    /// n'ont pas bougé — le delta ne le verrait jamais. Un `.skipped` posé pour
    /// non-résidence est donc réexaminé à chaque crawl.
    func testDownloadedFileLeavesTheSkippedStateWithoutAnyMTimeChange() throws {
        let file = try write("nuage.pdf")
        setMTime(file, seconds: 1_700_000_000, nanoseconds: 4_242)

        _ = try FouineCrawler(flags: dataless(["nuage.pdf"]))
            .crawl(rootID: 1, mode: .delta, store: store)
        let before = try XCTUnwrap(store.allDocs.first)
        XCTAssertEqual(before.record.state, .skipped)

        // Rien n'a changé sur le disque, seule la résidence.
        XCTAssertEqual(try mtime(of: file), before.record.mtime)
        let summary = try FouineCrawler().crawl(rootID: 1, mode: .delta, store: store)

        XCTAssertEqual(summary.seen, 1)
        XCTAssertEqual(summary.updated, 1)
        let after = try XCTUnwrap(store.allDocs.first)
        XCTAssertEqual(after.record.state, .discovered)
        XCTAssertNil(after.record.err)
    }

    /// L'inverse : un document DÉJÀ extrait qui est évincé garde son état et son
    /// texte. Son contenu est dans l'index, il y reste juste — le dégrader en
    /// `.skipped` effacerait un résultat de recherche valide.
    func testEvictedButAlreadyExtractedDocumentIsNotDowngraded() throws {
        try write("livre.pdf")
        _ = try FouineCrawler().crawl(rootID: 1, mode: .delta, store: store)
        let doc = try XCTUnwrap(store.allDocs.first)
        try store.setDocState(doc.id, .extracted, err: nil)

        _ = try FouineCrawler(flags: dataless(["livre.pdf"]))
            .crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(store.allDocs.first?.record.state, .extracted)
        XCTAssertNil(store.allDocs.first?.record.err)
    }

    /// La sonde LIT des octets : c'est elle qui déclencherait le premier
    /// téléchargement. Un fichier illisible ET non résident ne doit donc PAS
    /// faire échouer la sonde — la preuve qu'elle ne l'a pas ouvert.
    func testProbeNeverOpensANonResidentFile() throws {
        try XCTSkipIf(getuid() == 0, "root lit tout, le test n'a pas de sens")
        let file = try write("nuage.pdf")
        XCTAssertEqual(chmod(file.path, 0o000), 0)
        defer { chmod(file.path, 0o600) }

        let crawler = FouineCrawler(store: store, flags: dataless(["nuage.pdf"]))
        XCTAssertNoThrow(try crawler.probeReadable(rootID: 1))
        // Et sans le filtre de résidence, la même sonde échoue : c'est bien lui
        // qui fait la différence, pas les permissions.
        XCTAssertThrowsError(try FouineCrawler(store: store).probeReadable(rootID: 1))
    }

    // MARK: - Enregistrement

    func testRecordFieldsFollowTheSchema() throws {
        let file = try write("Chimie/Arnaud.pdf")
        setMTime(file, seconds: 1_700_000_000, nanoseconds: 123_456_789)

        _ = try FouineCrawler().crawl(rootID: 1, mode: .full, store: store)
        let doc = try XCTUnwrap(store.allDocs.first).record

        // top_folder = LABEL de la racine, jamais le premier segment du chemin :
        // sur un volume interne ce segment vaut « Users » pour tout le monde.
        XCTAssertEqual(doc.topFolder, "TestRoot")
        XCTAssertNotEqual(doc.topFolder, "Users")
        // rel_path RELATIF À LA RACINE DU VOLUME, pas à la racine indexée.
        XCTAssertEqual(doc.relPath, rootRecord.relPath + "/Chimie/Arnaud.pdf")
        XCTAssertFalse(doc.relPath.hasPrefix("/"))
        XCTAssertEqual(doc.ext, "pdf")           // minuscule, sans point
        XCTAssertEqual(doc.size, 7)
        XCTAssertEqual(doc.state, .discovered)
        // mtime REAL : la partie fractionnaire d'APFS survit.
        XCTAssertEqual(doc.mtime, try mtime(of: file))
        XCTAssertNotEqual(doc.mtime, doc.mtime.rounded(.down))
    }

    func testExtensionIsLowercased() throws {
        try write("MAJUSCULES.PDF")
        _ = try FouineCrawler().crawl(rootID: 1, mode: .full, store: store)
        XCTAssertEqual(store.allDocs.first?.record.ext, "pdf")
    }

    // MARK: - T10 : deux passes consécutives, la seconde ne fait rien

    func testSecondCrawlIsANoOp() throws {
        try write("a.pdf")
        try write("b/c.txt")
        let crawler = FouineCrawler()

        let first = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(first.added, 2)
        store.resetCounters()

        let second = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(second.seen, 2)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.updated, 0)
        XCTAssertEqual(second.removed, 0)
        // Et le store ne voit AUCUNE écriture : un upsert no-op coûte quand même
        // une transaction d'écriture et un SELECT, en contention avec l'OCR.
        XCTAssertEqual(store.upsertCount, 0)
        XCTAssertEqual(store.noopUpsertCount, 0)
    }

    /// Un seul fichier modifié sur deux : une seule écriture, et le document
    /// inchangé garde son enregistrement.
    func testDeltaWritesOnlyTheChangedFile() throws {
        try write("stable.pdf")
        let touched = try write("bouge.pdf", "avant")
        let crawler = FouineCrawler()
        _ = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        let before = store.allDocs
        store.resetCounters()

        try Data("après, plus long".utf8).write(to: touched)
        setMTime(touched, seconds: 1_800_000_000, nanoseconds: 42)

        let summary = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(summary.seen, 2)
        XCTAssertEqual(summary.updated, 1)
        XCTAssertEqual(summary.added, 0)
        XCTAssertEqual(store.upsertCount, 1)
        XCTAssertEqual(store.allDocs.count, before.count)
        let stableRel = before.map(\.record.relPath).first { $0.hasSuffix("stable.pdf") }
        XCTAssertEqual(store.doc(relPath: stableRel ?? "")?.mtime,
                       before.first { $0.record.relPath == stableRel }?.record.mtime)
    }

    func testModifiedFileIsUpdated() throws {
        let file = try write("a.pdf", "avant")
        let crawler = FouineCrawler()
        _ = try crawler.crawl(rootID: 1, mode: .delta, store: store)

        try Data("après, plus long".utf8).write(to: file)
        setMTime(file, seconds: 1_800_000_000, nanoseconds: 42)

        let summary = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(summary.updated, 1)
        XCTAssertEqual(summary.added, 0)
        var st = stat()
        XCTAssertEqual(stat(file.path, &st), 0)
        XCTAssertEqual(store.allDocs.first?.record.size, Int64(st.st_size))
        XCTAssertEqual(store.allDocs.first?.record.mtime, try mtime(of: file))
    }

    /// La détection des suppressions se fait dans LES DEUX modes (§5.2).
    func testDeletedFileIsRemovedInBothModes() throws {
        let doomed = try write("parti.pdf")
        try write("reste.pdf")
        let crawler = FouineCrawler()
        _ = try crawler.crawl(rootID: 1, mode: .full, store: store)
        XCTAssertEqual(store.allDocs.count, 2)

        try FileManager.default.removeItem(at: doomed)
        let summary = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(summary.removed, 1)
        XCTAssertEqual(store.removedIDs.count, 1)
        XCTAssertEqual(relPathsIndexed.map { ($0 as NSString).lastPathComponent },
                       ["reste.pdf"])
    }

    // MARK: - « Éteint » n'est jamais « disparu » (constat C2-04)

    /// Une catégorie ÉTEINTE entre deux passes laisse ses documents en place.
    ///
    /// C'est le seul constat de l'audit C2 qui DÉTRUISAIT du travail déjà fait,
    /// et il se déclenchait tout seul : l'agent d'arrière-plan construit sa
    /// liste d'extensions depuis la table `settings`, pas depuis le
    /// `FOUINE_EXTRACT_IMAGES=1` d'un terminal, et sa passe suivante retirait
    /// les images de l'index — avec leurs pages d'OCR.
    func testDocumentsOfASwitchedOffCategoryStayInPlace() throws {
        try write("photo.png")
        try write("rapport.pdf")
        let withImages = FouineCrawler(
            indexableExtensions: FouineCrawler.defaultIndexableExtensions
                .union(["png"]))
        _ = try withImages.crawl(rootID: 1, mode: .full, store: store)
        XCTAssertEqual(store.allDocs.count, 2)
        store.resetCounters()

        // Les images sont éteintes : le fichier est toujours là, le crawl ne
        // le voit plus. Il ne doit ni le retirer, ni écrire quoi que ce soit.
        let off = try FouineCrawler().crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(off.removed, 0)
        XCTAssertEqual(store.removedIDs, [])
        XCTAssertEqual(store.upsertCount, 0)
        XCTAssertTrue(relPathsIndexed.contains { $0.hasSuffix("photo.png") },
                      "l'image reste indexée : \(relPathsIndexed)")
    }

    /// Contre-épreuve : la catégorie RALLUMÉE, un fichier vraiment disparu
    /// sort de l'index. Le retrait n'est pas supprimé, il est rendu au seul
    /// cas qui le mérite.
    func testAMissingFileOfAnEnabledCategoryIsStillRemoved() throws {
        let photo = try write("photo.png")
        try write("rapport.pdf")
        let withImages = FouineCrawler(
            indexableExtensions: FouineCrawler.defaultIndexableExtensions
                .union(["png"]))
        _ = try withImages.crawl(rootID: 1, mode: .full, store: store)

        try FileManager.default.removeItem(at: photo)
        let summary = try withImages.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(summary.removed, 1)
        XCTAssertEqual(store.removedIDs.count, 1)
        XCTAssertEqual(relPathsIndexed.map { ($0 as NSString).lastPathComponent },
                       ["rapport.pdf"])
    }

    /// Et un document d'une catégorie ALLUMÉE dont le fichier disparaît sort de
    /// l'index dans les deux configurations : le correctif ne touche qu'aux
    /// extensions absentes de la liste courante.
    func testAMissingPDFIsRemovedWhateverTheImageSetting() throws {
        let doomed = try write("parti.pdf")
        try write("photo.png")
        let withImages = FouineCrawler(
            indexableExtensions: FouineCrawler.defaultIndexableExtensions
                .union(["png"]))
        _ = try withImages.crawl(rootID: 1, mode: .full, store: store)

        try FileManager.default.removeItem(at: doomed)
        let summary = try FouineCrawler().crawl(rootID: 1, mode: .delta,
                                                store: store)
        XCTAssertEqual(summary.removed, 1, "le PDF disparu sort de l'index")
        XCTAssertTrue(relPathsIndexed.contains { $0.hasSuffix("photo.png") },
                      "l'image éteinte, elle, reste : \(relPathsIndexed)")
    }

    // MARK: - Une seule forme Unicode (constat A3-10)

    /// Un nom accentué écrit en NFD (« e » + accent combinant) est enregistré en
    /// NFC. Sans cela, `docs.rel_path` porte selon les jours l'une ou l'autre
    /// forme, et la comparaison d'octets de SQLite ne retrouve plus le document.
    func testAccentedNamesAreStoredInNFC() throws {
        let nfd = "the\u{300}se de me\u{301}decine.pdf"
        try write(nfd)

        _ = try FouineCrawler().crawl(rootID: 1, mode: .delta, store: store)
        let path = try XCTUnwrap(store.allDocs.first?.record.relPath)
        XCTAssertFalse(RelPath.needsNormalization(path),
                       "chemin non normalisé : \(Array(path.utf8))")
        XCTAssertTrue(path.hasSuffix("thèse de médecine.pdf"), path)
    }

    /// Et la passe suivante reste un no-op : la forme enregistrée est STABLE,
    /// sans quoi chaque crawl réécrirait le document et le ferait ré-extraire.
    func testAnAccentedNameIsStableAcrossCrawls() throws {
        try write("e\u{301}tude.pdf")
        let crawler = FouineCrawler()
        _ = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        store.resetCounters()

        let summary = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(summary.seen, 1)
        XCTAssertEqual(summary.added, 0)
        XCTAssertEqual(summary.updated, 0)
        XCTAssertEqual(summary.removed, 0)
        XCTAssertEqual(store.upsertCount, 0)
        XCTAssertEqual(store.relocateCount, 0)
    }

    // MARK: - Un outil qui apparaît (constat A3-05)

    /// Un `.djvu` indexé avant `brew install djvulibre` porte
    /// « missing-tool:djvused » : installer l'outil ne change ni sa taille ni son
    /// mtime, et le crawl delta ne regarde que ces deux-là. Sans relecture du
    /// motif, le document restait sauté à vie.
    func testSkippedForAMissingToolIsReconsideredWhenTheToolAppears() throws {
        try write("atlas.djvu")
        _ = try FouineCrawler().crawl(rootID: 1, mode: .delta, store: store)
        let doc = try XCTUnwrap(store.allDocs.first)
        try store.setDocState(doc.id, .skipped, err: DjvuExtractorReason.djvu)

        // L'outil est là, maintenant.
        let summary = try FouineCrawler(toolIsInstalled: { $0 == "djvused" })
            .crawl(rootID: 1, mode: .delta, store: store)

        XCTAssertEqual(summary.updated, 1)
        let after = try XCTUnwrap(store.allDocs.first)
        XCTAssertEqual(after.id, doc.id, "le document n'est pas refait, il est repris")
        XCTAssertEqual(after.record.state, .discovered)
        XCTAssertNil(after.record.err)
    }

    /// Tant que l'outil manque, le document reste sauté — et le crawl n'écrit
    /// rien du tout : la passe suivante doit rester un no-op.
    func testSkippedForAMissingToolStaysSkippedWhileTheToolIsAbsent() throws {
        try write("atlas.djvu")
        _ = try FouineCrawler().crawl(rootID: 1, mode: .delta, store: store)
        let doc = try XCTUnwrap(store.allDocs.first)
        try store.setDocState(doc.id, .skipped, err: DjvuExtractorReason.djvu)
        store.resetCounters()

        let summary = try FouineCrawler(toolIsInstalled: { _ in false })
            .crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(summary.updated, 0)
        XCTAssertEqual(store.allDocs.first?.record.state, .skipped)
        XCTAssertEqual(store.upsertCount, 0)
    }

    /// Les autres `.skipped` ne se réexaminent PAS : leur cause est dans le
    /// fichier, elle ne peut pas disparaître sans que le fichier bouge.
    func testOtherSkipReasonsAreNotReconsidered() throws {
        try write("tableur.xls")
        _ = try FouineCrawler().crawl(rootID: 1, mode: .delta, store: store)
        let doc = try XCTUnwrap(store.allDocs.first)
        try store.setDocState(doc.id, .skipped, err: "binary OLE format")

        let summary = try FouineCrawler(toolIsInstalled: { _ in true })
            .crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(summary.updated, 0)
        XCTAssertEqual(store.allDocs.first?.record.state, .skipped)
    }

    /// Le jeton se lit dans la phrase, et seulement lui : un motif qui parle
    /// d'un outil sans le nommer ne relance rien.
    func testMissingToolTokenIsParsedFromTheReason() {
        XCTAssertEqual(ExternalTool.missingTool(
            inSkipReason: "djvu: djvulibre is missing (missing-tool:djvused)"),
                       "djvused")
        XCTAssertEqual(ExternalTool.missingTool(inSkipReason: "missing-tool:pdftotext"),
                       "pdftotext")
        XCTAssertNil(ExternalTool.missingTool(inSkipReason: "unsupported format"))
        XCTAssertNil(ExternalTool.missingTool(inSkipReason: "missing-tool:"))
        XCTAssertNil(ExternalTool.missingTool(inSkipReason: nil))
        XCTAssertEqual(ExternalTool.overrideVariable(for: "djvused"), "FOUINE_DJVUSED")
    }

    // MARK: - Un format que Fouine apprend (lot INT-F1)

    /// Un `.xls` ou un `.ppt` indexé avant le lot F1 porte « unsupported binary
    /// OLE format ». Apprendre le format ne change ni la taille ni le mtime du
    /// fichier : sans relecture du motif, tous les classeurs d'un index
    /// existant resteraient sautés à vie.
    func testSkippedAsUnsupportedIsReconsideredWhenTheFormatIsNowIndexable() throws {
        try write("ancien.xls")
        _ = try FouineCrawler().crawl(rootID: 1, mode: .delta, store: store)
        let doc = try XCTUnwrap(store.allDocs.first)
        try store.setDocState(doc.id, .skipped, err: "unsupported binary OLE format")

        let summary = try FouineCrawler().crawl(rootID: 1, mode: .delta, store: store)

        XCTAssertEqual(summary.updated, 1)
        let after = try XCTUnwrap(store.allDocs.first)
        XCTAssertEqual(after.id, doc.id, "le document n'est pas refait, il est repris")
        XCTAssertEqual(after.record.state, .discovered)
        XCTAssertNil(after.record.err)
    }

    /// Un motif qui n'est pas « format non pris en charge » — trop gros, par
    /// exemple — ne se rejoue pas : sa cause est dans le fichier, et le fichier
    /// n'a pas bougé.
    func testSkippedForAnotherReasonStaysSkipped() throws {
        try write("enorme.xls")
        _ = try FouineCrawler().crawl(rootID: 1, mode: .delta, store: store)
        let doc = try XCTUnwrap(store.allDocs.first)
        try store.setDocState(doc.id, .skipped, err: "file too large (734003200 B)")
        store.resetCounters()

        let summary = try FouineCrawler().crawl(rootID: 1, mode: .delta, store: store)

        XCTAssertEqual(summary.updated, 0)
        let after = try XCTUnwrap(store.allDocs.first)
        XCTAssertEqual(after.record.state, .skipped)
        XCTAssertTrue(FouineCrawler.wasUnsupported("unsupported format: .ppt"))
        XCTAssertFalse(FouineCrawler.wasUnsupported("file too large (1 B)"))
        XCTAssertFalse(FouineCrawler.wasUnsupported(nil))
    }

    // MARK: - Renommer ne détruit rien (constat A3-02, schéma v6)

    /// Le doc_id est ce qui porte TOUT le reste : les pages, la couche OCR, la
    /// file d'attente et les vecteurs sont indexés par lui. Un renommage qui
    /// conserve le doc_id conserve donc, littéralement, tout le travail — et
    /// c'est la seule chose que ce test ait besoin de vérifier.
    func testRenamingAFileKeepsTheSameDocument() throws {
        let file = try write("avant.pdf")
        let crawler = FouineCrawler()
        _ = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        let before = try XCTUnwrap(store.allDocs.first)
        XCTAssertNotEqual(before.record.inode, 0, "l'inode doit être renseigné")
        store.resetCounters()

        try FileManager.default.moveItem(
            at: file, to: root.appendingPathComponent("après.pdf"))

        let summary = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(summary.moved, 1)
        XCTAssertEqual(summary.added, 0)
        XCTAssertEqual(summary.removed, 0)
        XCTAssertEqual(store.removedIDs, [], "rien ne doit être purgé")
        XCTAssertEqual(store.upsertCount, 0, "rien ne doit être ré-extrait")

        let after = try XCTUnwrap(store.allDocs.first)
        XCTAssertEqual(after.id, before.id, "MÊME document : pages, OCR et "
                       + "vecteurs sont indexés par cet identifiant")
        XCTAssertTrue(after.record.relPath.hasSuffix("après.pdf"))
        XCTAssertEqual(after.record.inode, before.record.inode)
    }

    /// Un dossier renommé, c'est n documents déplacés — et UNE transaction, pas
    /// n : c'est le cas réel qui coûtait des heures d'OCR.
    func testMovingAFolderOfThreeDocumentsIsOneTransaction() throws {
        for name in ["a.pdf", "b.txt", "c.md"] { try write("M2SU/\(name)") }
        let crawler = FouineCrawler()
        _ = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        let before = Dictionary(uniqueKeysWithValues: store.allDocs.map {
            (($0.record.relPath as NSString).lastPathComponent, $0.id)
        })
        XCTAssertEqual(before.count, 3)
        store.resetCounters()

        try FileManager.default.moveItem(
            at: root.appendingPathComponent("M2SU"),
            to: root.appendingPathComponent("M2 Sorbonne 2026"))

        let summary = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(summary.moved, 3)
        XCTAssertEqual(summary.added, 0)
        XCTAssertEqual(summary.removed, 0)
        XCTAssertEqual(store.removedIDs, [])
        XCTAssertEqual(store.relocateCount, 1, "un dossier se déplace d'un coup")

        for doc in store.allDocs {
            XCTAssertTrue(doc.record.relPath.contains("M2 Sorbonne 2026"),
                          doc.record.relPath)
            XCTAssertEqual(
                doc.id, before[(doc.record.relPath as NSString).lastPathComponent],
                "chaque document garde son identifiant")
        }
    }

    /// Un fichier REMPLACÉ par un autre du même nom porte un autre inode : le
    /// contenu a changé, il faut ré-extraire. Aucun déplacement là-dedans.
    func testReplacingAFileUnderTheSameNameReExtracts() throws {
        let file = try write("cours.pdf", "première version")
        let crawler = FouineCrawler()
        _ = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        let before = try XCTUnwrap(store.allDocs.first)
        store.resetCounters()

        // Remplacement : un AUTRE fichier prend le nom du premier.
        let replacement = try write("remplacant.tmp", "seconde version, plus longue")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)

        let summary = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(summary.moved, 0)
        XCTAssertEqual(summary.updated, 1, "contenu changé : ré-extraction")
        XCTAssertEqual(store.upsertCount, 1)
        let after = try XCTUnwrap(store.allDocs.first)
        XCTAssertEqual(after.id, before.id, "même chemin, donc même ligne")
        XCTAssertNotEqual(after.record.inode, before.record.inode)
    }

    /// Une COPIE porte un inode neuf : c'est un document de plus, pas un
    /// déplacement. L'original reste, et il n'a pas bougé.
    func testCopyingAFileCreatesASecondDocument() throws {
        let file = try write("original.pdf")
        let crawler = FouineCrawler()
        _ = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        let before = try XCTUnwrap(store.allDocs.first)
        store.resetCounters()

        try FileManager.default.copyItem(
            at: file, to: root.appendingPathComponent("copie.pdf"))

        let summary = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(summary.moved, 0)
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.removed, 0)
        XCTAssertEqual(store.allDocs.count, 2)
        XCTAssertEqual(store.doc(relPath: before.record.relPath)?.inode,
                       before.record.inode, "l'original n'a pas bougé")
    }

    /// Renommé ET modifié : le mtime a changé, l'identité ne correspond plus.
    /// On ne devine pas — le document est refait, et l'ancien sort de l'index.
    func testRenamedAndModifiedFileIsReExtracted() throws {
        let file = try write("brouillon.md", "court")
        let crawler = FouineCrawler()
        _ = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        store.resetCounters()

        let moved = root.appendingPathComponent("final.md")
        try FileManager.default.moveItem(at: file, to: moved)
        try Data("beaucoup plus long qu'avant".utf8).write(to: moved)
        setMTime(moved, seconds: 1_900_000_000, nanoseconds: 7)

        let summary = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(summary.moved, 0)
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.removed, 1)
        XCTAssertEqual(store.removedIDs.count, 1)
        XCTAssertEqual(relPathsIndexed.map { ($0 as NSString).lastPathComponent },
                       ["final.md"])
    }

    /// Une ligne d'avant le schéma v6 porte `inode = 0` : le premier crawl la
    /// renseigne SANS ré-extraire quoi que ce soit, et sans compter cela pour
    /// une mise à jour — rien de ce que l'utilisateur voit n'a changé.
    func testMigratedRowsGetTheirInodeWithoutReExtraction() throws {
        let file = try write("ancien.pdf")
        let crawler = FouineCrawler()
        _ = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        let doc = try XCTUnwrap(store.allDocs.first)
        store.forceInode(0, on: doc.id)          // simule une base migrée de v5
        store.resetCounters()

        let summary = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(summary.updated, 0)
        XCTAssertEqual(summary.moved, 0)
        XCTAssertEqual(store.upsertCount, 0, "aucune ré-extraction")
        XCTAssertEqual(store.relocateCount, 1)
        let after = try XCTUnwrap(store.allDocs.first)
        XCTAssertEqual(after.id, doc.id)
        XCTAssertEqual(after.record.inode, try inode(of: file))

        // Et la passe suivante n'écrit plus rien : le renseignement est unique.
        store.resetCounters()
        _ = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(store.relocateCount, 0)
    }

    /// Sans inode (volume FAT ou SMB, ligne jamais renseignée), on retombe sur
    /// l'ancien comportement : suppression puis redécouverte. Le contrat est
    /// « on ne rapproche QUE ce qu'on peut prouver ».
    func testAVolumeWithoutInodesFallsBackToTheOldBehaviour() throws {
        let file = try write("sansinode.pdf")
        let crawler = FouineCrawler()
        _ = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        let doc = try XCTUnwrap(store.allDocs.first)
        store.forceInode(0, on: doc.id)

        // Le fichier bouge AVANT que le crawl n'ait pu renseigner l'inode.
        try FileManager.default.moveItem(
            at: file, to: root.appendingPathComponent("ailleurs.pdf"))
        let summary = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(summary.moved, 0)
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.removed, 1)
    }

    func inode(of url: URL) throws -> Int64 {
        var st = stat()
        XCTAssertEqual(stat(url.path, &st), 0)
        return Int64(bitPattern: UInt64(st.st_ino))
    }

    // MARK: - Volume et lisibilité

    func testUnmountedVolumeIsReportedAsSuch() throws {
        store = InMemoryStore()
        store.addRoot(RootRecord(id: 1, volUUID: "00000000-DEAD-BEEF-0000-000000000000",
                                 relPath: "Users/personne/Livres", label: "Fantôme",
                                 enabled: true))
        XCTAssertThrowsError(try FouineCrawler().crawl(rootID: 1, mode: .full,
                                                       store: store)) { error in
            guard case FouineError.volumeNotMounted = error else {
                return XCTFail("attendu volumeNotMounted, obtenu \(error)")
            }
        }
    }

    /// T9 : racine déplacée ou supprimée -> rootUnreadable (sortie 5).
    func testProbeFailsWhenRootDisappears() throws {
        try FileManager.default.removeItem(at: root)
        let crawler = FouineCrawler(store: store)
        XCTAssertThrowsError(try crawler.probeReadable(rootID: 1)) { error in
            guard case FouineError.rootUnreadable = error else {
                return XCTFail("attendu rootUnreadable, obtenu \(error)")
            }
        }
    }

    func testProbeReadsAFileNotJustStat() throws {
        try write("lisible.pdf")
        XCTAssertNoThrow(try FouineCrawler(store: store).probeReadable(rootID: 1))
    }

    /// Le piège n°1 : `fileExists` réussit, la LECTURE échoue. C'est exactement le
    /// mode d'échec de TCC sur ~/Documents, reproduit ici par les permissions.
    func testProbeFailsWhenTheOnlyFileCannotBeRead() throws {
        try XCTSkipIf(getuid() == 0, "root lit tout, le test n'a pas de sens")
        let file = try write("interdit.pdf")
        XCTAssertEqual(chmod(file.path, 0o000), 0)
        defer { chmod(file.path, 0o600) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertThrowsError(try FouineCrawler(store: store).probeReadable(rootID: 1)) {
            guard case let FouineError.rootUnreadable(_, reason) = $0 else {
                return XCTFail("attendu rootUnreadable, obtenu \($0)")
            }
            // Message d'origine système, transmis tel quel (§7.1).
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testProbeRunsBeforeAnythingElse() throws {
        try write("lisible.pdf")
        try FileManager.default.removeItem(at: root)
        XCTAssertThrowsError(try FouineCrawler().crawl(rootID: 1, mode: .full,
                                                       store: store)) { error in
            guard case FouineError.rootUnreadable = error else {
                return XCTFail("attendu rootUnreadable, obtenu \(error)")
            }
        }
        XCTAssertTrue(store.allDocs.isEmpty)
    }

    func testProbeWithoutInjectedStoreIsRefused() {
        XCTAssertThrowsError(try FouineCrawler().probeReadable(rootID: 1)) { error in
            guard case FouineError.databaseFailure = error else {
                return XCTFail("attendu databaseFailure, obtenu \(error)")
            }
        }
    }

    /// Le crawler ne modifie JAMAIS le corpus (§3 : racines en lecture seule).
    func testCrawlWritesNothingUnderTheRoot() throws {
        try write("a.pdf")
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        let stamps = try before.map { path -> Double in
            try mtime(of: root.appendingPathComponent(path))
        }
        _ = try FouineCrawler().crawl(rootID: 1, mode: .full, store: store)
        let after = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(before, after)
        for (index, path) in after.enumerated() {
            XCTAssertEqual(try mtime(of: root.appendingPathComponent(path)),
                           stamps[index])
        }
    }
}
