// swift-tools-version: 5.10
// Fouine — moteur de recherche plein texte macOS avec OCR Vision non destructif.
// Manifeste tenu par L'ORCHESTRATEUR (SPEC §9.2). Un lot ne l'édite pas de sa
// propre initiative : il peut y AJOUTER une cible quand sa consigne le demande
// explicitement (c'est ainsi que FouineLicense est arrivée), et signale la
// modification dans son rapport. Retirer ou renommer une cible, changer une
// dépendance ou un drapeau reste un geste de l'orchestrateur.
//
// Trois dépendances, pas une de plus (SPEC §2.2) :
//   GRDB.swift (MIT)            — lie le SQLite du SYSTÈME (FTS5 3.43.2 mesuré)
//   swift-argument-parser (Apache-2.0)
//   Sparkle (MIT)               — mises à jour signées EdDSA, sur FouineApp SEULE
//
// La troisième est arrivée au palier 2.9 (audit produit D13) et se justifie
// ainsi : distribuée hors App Store, Fouine n'a aucun autre moyen de porter un
// correctif de sécurité à un utilisateur qui a déjà téléchargé le DMG. Sparkle
// est la seule implémentation éprouvée sur macOS, elle fonctionne en runtime
// durci SANS bac à sable (notre configuration exacte) et vérifie chaque paquet
// par signature EdDSA. Elle est **éteinte par défaut** (SUEnableAutomaticChecks
// = false dans Packaging/Info.plist) : rien ne part sur le réseau tant que
// l'utilisateur n'a pas cliqué « Rechercher les mises à jour… » ou armé
// l'interrupteur des réglages. Voir docs/updates.md.
import PackageDescription

let package = Package(
    name: "Fouine",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "fouine", targets: ["fouine"]),
        .library(name: "FouineCore", targets: ["FouineCore"]),
        .library(name: "FouineCrawl", targets: ["FouineCrawl"]),
        .library(name: "FouineExtract", targets: ["FouineExtract"]),
        .library(name: "FouineOCR", targets: ["FouineOCR"]),
        .library(name: "FouineEmbed", targets: ["FouineEmbed"]),
        // FouineIndex : LA passe d'indexation, partagée par la CLI, l'app et
        // l'agent (audit F2). Aucune dépendance SPM nouvelle.
        .library(name: "FouineIndex", targets: ["FouineIndex"]),
        // Palier 4 (D2 § 5). DEUX cibles, et le découpage n'est pas cosmétique :
        // sans lui le MIT annoncé sur le serveur MCP serait décoratif
        // (D2 § 5.9, LICENSING.md).
        .library(name: "FouineMCPKit", targets: ["FouineMCPKit"]),
        .library(name: "FouineMCP", targets: ["FouineMCP"]),
        // FouineLicense (lot L1C) : essai de 30 jours, clé Creem, relais.
        .library(name: "FouineLicense", targets: ["FouineLicense"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        // Sparkle 2 : XCFramework binaire téléchargé à la résolution. N'est liée
        // QUE par FouineApp — ni la CLI, ni l'agent, ni aucune bibliothèque du
        // moteur n'en dépendent, et `swift test` ne la charge jamais.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .target(
            name: "FouineCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "FouineCrawl", dependencies: ["FouineCore"]),
        .target(name: "FouineExtract", dependencies: ["FouineCore"]),
        // FouineOCR dépend de FouineExtract : le PageRenderer rend aussi les images
        // des archives cbz/cbr et les médias embarqués OOXML via ses helpers (§5.3).
        .target(name: "FouineOCR", dependencies: ["FouineCore", "FouineExtract"]),
        // FouineEmbed : vecteurs sémantiques et recherche hybride (§12).
        // CoreML + Accelerate (frameworks système) — aucune dépendance SPM.
        .target(name: "FouineEmbed", dependencies: ["FouineCore"]),
        // FouineIndex : `IndexPass` + observateur + priorité OCR. Les trois
        // pipelines d'indexation s'y réduisent à un adaptateur de sortie
        // (audit F2, F3, F4, X3). FouineOCR pour `OCRPass`, qui rend le verrou.
        .target(
            name: "FouineIndex",
            dependencies: ["FouineCore", "FouineCrawl", "FouineExtract", "FouineOCR"]
        ),
        // FouineMCPKit : transport ligne à ligne, hygiène de stdout, JSON-RPC,
        // routeur bi-époque, registre d'outils, enveloppes, budget et curseurs,
        // journal stderr. **ZÉRO dépendance** — pas même FouineCore, et c'est
        // exactement ce qui rend son MIT réel (D2 § 5.9) : un tiers peut
        // reprendre ces fichiers dans son propre projet, y compris commercial,
        // et y brancher un autre moteur — ce que la licence source-available du
        // reste du dépôt ne permet pas (LI1).
        // Foundation et CryptoKit sont des cadriciels du SYSTÈME, pas
        // des paquets SPM : la doctrine « trois dépendances, pas une de plus »
        // tient (§2.2).
        // `LICENSE` est exclu de la compilation : c'est le texte MIT qui couvre
        // CETTE cible et lui seule, pas une ressource à embarquer.
        .target(name: "FouineMCPKit", exclude: ["LICENSE"]),
        // FouineMCP : le serveur proprement dit — ouverture en lecture seule,
        // cycle de vie, et les outils. Lie FouineCore et FouineEmbed, donc
        // sous la licence source-available de Fouine, donc l'exécutable livré
        // aussi (LICENSING.md).
        .target(name: "FouineMCP",
                dependencies: ["FouineMCPKit", "FouineCore", "FouineEmbed"]),
        // FouineLicense (lot L1C) : l'essai de 30 jours, le fichier
        // `license.json`, les quatre états, et le client du relais de licence.
        // **ZÉRO dépendance**, pas même FouineCore : la décision « l'index a-t-il
        // le droit de se mettre à jour ? » est prise par les TROIS exécutables
        // (application, agent, ligne de commande) et ne doit dépendre ni du
        // store, ni du schéma, ni d'une ouverture de base — l'agent la prend à
        // chaque réveil sans rien ouvrir. Foundation et `os` sont des
        // cadriciels du SYSTÈME, pas des paquets SPM : la doctrine « trois
        // dépendances, pas une de plus » tient (§2.2).
        .target(name: "FouineLicense"),
        .executableTarget(
            name: "fouine",
            dependencies: [
                "FouineCore", "FouineCrawl", "FouineExtract", "FouineOCR",
                "FouineEmbed", "FouineIndex", "FouineMCP", "FouineLicense",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "FouineApp",
            dependencies: ["FouineCore", "FouineCrawl", "FouineExtract",
                           "FouineOCR", "FouineEmbed", "FouineIndex",
                           "FouineLicense",
                           .product(name: "Sparkle", package: "Sparkle")],
            // Le String Catalog de l'app (palier 3.2, audit U1) est EXCLU de la
            // compilation SwiftPM, et ce n'est pas un oubli. Déclaré en
            // `.process`, SwiftPM le compilerait dans un bundle voisin
            // (`Fouine_FouineApp.bundle`) que l'accesseur `Bundle.module`
            // cherche À CÔTÉ de l'exécutable — donc hors de Fouine.app une fois
            // celui-ci copié dedans —, et l'app ferait un `fatalError` AU
            // LANCEMENT. Les traductions passent par `Bundle.main` :
            // `Packaging/bundle.sh` compile le catalogue en
            // Contents/Resources/{en,fr}.lproj/ avant la signature. Sans cette
            // ligne, `swift build` avertit « unhandled file » à chaque build.
            // Voir docs/i18n.md.
            exclude: ["Resources/Localizable.xcstrings"],
            // Sparkle est un framework DYNAMIQUE : l'exécutable le référence en
            // @rpath/Sparkle.framework/Versions/B/Sparkle. Sans ce rpath, l'app
            // bâtie ne se lance pas — dyld ne sait pas où chercher, et le
            // message n'arrive que dans les journaux du système.
            // Packaging/bundle.sh copie le framework dans Contents/Frameworks/,
            // qui est bien ../Frameworks depuis Contents/MacOS/Fouine.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath",
                              "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .executableTarget(
            name: "FouineAgent",
            // FouineEmbed depuis le lot AG1 : l'agent prépare aussi la
            // recherche par le sens, entre deux lots d'OCR (constat PR-21).
            dependencies: ["FouineCore", "FouineCrawl", "FouineExtract",
                           "FouineOCR", "FouineIndex", "FouineEmbed",
                           "FouineLicense"]
        ),
        // Cible de tests de l'interface (audit F1 : « aucun test sur
        // SearchModel »). SwiftPM sait tester une cible EXÉCUTABLE : le
        // `main.swift` de FouineApp reste du code de haut niveau, il n'est
        // simplement jamais exécuté depuis les tests.
        .testTarget(name: "FouineAppTests",
                    dependencies: ["FouineApp", "FouineCore", "FouineLicense"]),
        // Cible de tests de l'AGENT (audit D12/M23 : « zéro test sur
        // FouineApp/, FouineAgent/, fouine/ »). Même procédé que ci-dessus :
        // SwiftPM sait tester une cible exécutable, et le `main.swift` de
        // FouineAgent n'est jamais exécuté depuis les tests.
        //
        // Ce qui est testable ici est ce qui NE DÉPEND PAS de launchd : les six
        // conditions d'entrée en OCR (§5.7), le journal 0o600 à rotation bornée
        // (audit S4) et la publication de l'état dans `agent_status` (audit F7).
        // La boucle `Agent.start()`, elle, ne se teste qu'en installant un
        // LaunchAgent : elle reste hors de portée, et c'est assumé.
        .testTarget(name: "FouineAgentTests",
                    dependencies: ["FouineAgent", "FouineCore", "FouineLicense"]),
        .testTarget(name: "FouineCoreTests", dependencies: ["FouineCore"]),
        // DIXIÈME suite (lot L1C) : les quatre états, le fichier, et le client
        // du relais éprouvé par un `URLProtocol` de substitution — aucun de ces
        // tests ne sort sur le réseau.
        .testTarget(name: "FouineLicenseTests", dependencies: ["FouineLicense"]),
        .testTarget(name: "FouineCrawlTests", dependencies: ["FouineCrawl"]),
        // FouineOCR et FouineCrawl : ImageExtractorTests (lot H2, E4) exerce le
        // rendu et l'OCR réel d'une image seule et la reconnaissance des
        // paquets-documents. L'import était fait sans être déclaré : un build
        // incrémental le tolérait, un build propre le refusait.
        .testTarget(name: "FouineExtractTests",
                    dependencies: ["FouineExtract", "FouineOCR", "FouineCrawl"]),
        .testTarget(name: "FouineOCRTests", dependencies: ["FouineOCR"]),
        .testTarget(name: "FouineEmbedTests",
                    dependencies: ["FouineEmbed", "FouineCore"]),
        .testTarget(name: "FouineIndexTests",
                    dependencies: ["FouineIndex", "FouineCore", "FouineCrawl"]),
        // NEUVIÈME suite (palier 4). `Transcripts/` est EXCLU de la
        // compilation : ce sont des `.jsonl` lus par `#filePath`, comme le fait
        // déjà `MaintenanceRecetteTests` pour `docs/cli.md`. Déclarés en
        // ressource, ils demanderaient un `Bundle.module` dont on n'a pas
        // besoin ; non déclarés du tout, SwiftPM avertirait « unhandled file »
        // à chaque build.
        // GRDB y figure pour UN test : celui qui bouscule `meta.schema_version`
        // par une connexion séparée, comme le ferait une mise à jour de Fouine
        // pendant qu'un serveur tourne. Aucune dépendance SPM nouvelle — c'est
        // le paquet déjà résolu.
        .testTarget(name: "FouineMCPTests",
                    dependencies: ["FouineMCPKit", "FouineMCP", "FouineCore",
                                   .product(name: "GRDB", package: "GRDB.swift")],
                    exclude: ["Transcripts"]),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["FouineCore", "FouineCrawl", "FouineExtract", "FouineOCR"],
            path: "Tests/Integration"
        ),
    ]
)
