// FouineCrawler.swift — parcours des racines, delta, suppressions (SPEC §5.2).
// Propriété : A-Ingest. NOM PUBLIC IMPOSÉ : `FouineCrawler`.
//
// Trois règles mesurées, non négociables :
//   · le volume se résout par UUID via VolumeResolver (URLResourceKey.
//     volumeUUIDStringKey), JAMAIS par diskutil, JAMAIS par le chemin de montage
//     seul (§2.3, §7.2 n°10) ;
//   · AVANT TOUT LE RESTE, on LIT EFFECTIVEMENT un fichier de la racine —
//     ouvrir et lire des octets, pas stat. ~/Documents est protégé par TCC,
//     ~/Livres ne l'est pas : sans ce test une racine s'indexe et l'autre reste
//     vide SANS LE MOINDRE MESSAGE. C'est le piège n°1 (§7.1) ;
//   · on ne hache JAMAIS le contenu : le triplet (rel_path, size, mtime) suffit,
//     APFS donne un mtime à la nanoseconde (§5.2, §7.2 n°15) ;
//   · UN RENOMMAGE N'EST PAS UNE SUPPRESSION (lot K6, constat A3-02). Un chemin
//     disparu et un chemin apparu qui portent le MÊME inode, la MÊME taille et
//     le MÊME mtime sont le même fichier : on déplace la ligne `docs`, on ne
//     détruit pas ses pages, son OCR, sa file ni ses vecteurs.
//
// Et le corpus est en LECTURE SEULE stricte : ce fichier n'ouvre jamais rien en
// écriture sous une racine indexée — ni, depuis l'audit F5, en LECTURE quand le
// fichier n'est pas résident (voir `FileResidency` : l'ouvrir le ferait
// descendre du nuage).

import Foundation
import FouineCore

public final class FouineCrawler: Crawler {
    /// Extensions retenues au parcours. Miroir de
    /// `DefaultExtractorRegistry.supportedExtensions` (§5.3) : `Package.swift`
    /// est gelé et FouineCrawl n'a pas FouineExtract dans ses dépendances, donc
    /// la liste est recopiée ici — et injectable pour que la CLI passe la vraie.
    public static let defaultIndexableExtensions: Set<String> = [
        // Documents texte
        "txt", "md", "csv", "tsv", "tex", "json", "log",
        // PDF, texte riche, bureautique
        "pdf", "doc", "rtf", "rtfd", "docx", "odt", "ods", "odp", "xlsx",
        "pptx", "xls", "ppt",
        // Web et XML
        "html", "htm", "webarchive", "xml", "xsd", "xsl", "xslt", "svg",
        "plist",
        // Livres, BD, documents numérisés
        "epub", "cbz", "cbr", "djvu",
        // iWork
        "pages", "numbers", "key",
        // Adobe et maquettes (lot INT-F2). `fig` et `indd` n'ont au mieux qu'un
        // aperçu à OCRiser : ils sont ici pour que leur refus soit NOMMÉ (le geste
        // à faire, pas « format non pris en charge ») — Fouine n'indexe pas les
        // noms de fichiers, ce refus est la seule trace du document.
        // (`psd` est une IMAGE : il n'entre que sous `extract.images`, par
        // `DefaultExtractorRegistry.imageExtensions`. De même, les SONS et les
        // VIDÉOS — mp3, m4a, wav, flac, mp4, mov, mkv… — n'entrent que sous
        // `extract.media`, par `DefaultExtractorRegistry.mediaExtensions` :
        // aucune ne figure dans cette liste, lot INT-F3.)
        "ai", "indd", "sketch", "fig",
        // Courriel (lot INT-F1) : `mbox` désigne aussi un PAQUET `Nom.mbox/`
        "eml", "emlx", "olk15msgsource", "mbox",
        // Sous-titres, carnets
        "srt", "vtt", "ipynb",
        // Fichiers techniques (lot INT-F1)
        "js", "mjs", "cjs", "jsx", "ts", "tsx", "vue", "svelte", "java",
        "kt", "kts", "scala", "groovy", "gradle", "c", "cc", "cpp", "cxx",
        "h", "hh", "hpp", "m", "mm", "cmake", "swift", "py", "pyi", "rb",
        "rs", "go", "php", "pl", "pm", "lua", "r", "cs", "fs", "vb", "sql",
        "graphql", "proto", "sh", "bash", "zsh", "fish", "ps1", "bat",
        "cmd", "dockerfile", "css", "scss", "sass", "less", "yaml", "yml",
        "toml", "ini", "cfg", "conf", "properties", "rst", "adoc",
        "asciidoc", "org", "textile", "mdx", "markdown", "mkd",
    ]

    public let indexableExtensions: Set<String>
    /// `Crawler.probeReadable(rootID:)` (§4.2, gelé) ne reçoit pas de store :
    /// la CLI injecte le sien ici. `probeReadable(rootID:store:)` reste
    /// disponible pour les appelants qui l'ont sous la main.
    private let store: (any IndexStore)?
    /// Lecteur de `st_flags` (F5) : injectable parce qu'un test ne peut pas
    /// fabriquer un fichier `SF_DATALESS` — voir `FileResidency`.
    private let flags: FileResidency.FlagsReader
    /// `$HOME` servant à reconnaître `$HOME/Library` (F5) : injectable pour que
    /// le test n'ait pas à toucher au vrai dossier de départ.
    private let home: String
    /// « Cet outil externe est-il installé MAINTENANT ? » (A3-05). Injectable :
    /// un test ne peut ni installer ni désinstaller djvulibre sur la machine
    /// qui l'exécute, et le résultat doit être le même partout.
    private let toolIsInstalled: @Sendable (String) -> Bool
    /// Ce que le crawl a à DIRE sans pouvoir le mettre dans `CrawlSummary` —
    /// aujourd'hui les lignes refusées d'un `.fouineignore` (lot IG1). Le
    /// contrat du §4.2 gèle la signature de `crawl` : il n'y a pas d'observateur
    /// à qui parler, et une ligne fautive qui ne se dirait nulle part laisserait
    /// l'utilisateur croire qu'un dossier est exclu alors qu'il ne l'est pas.
    /// Par défaut sur la sortie d'erreur, où la CLI, l'agent et l'app écrivent
    /// déjà leurs avertissements de dépannage.
    private let note: @Sendable (String) -> Void

    public init(store: (any IndexStore)? = nil,
                indexableExtensions: Set<String> = FouineCrawler.defaultIndexableExtensions,
                flags: @escaping FileResidency.FlagsReader = FileResidency.systemFlags,
                home: String = CrawlExclusions.homeDirectory,
                toolIsInstalled: @escaping @Sendable (String) -> Bool
                    = ExternalTool.isInstalled,
                note: @escaping @Sendable (String) -> Void = FouineCrawler.noteToStderr) {
        self.store = store
        self.indexableExtensions = indexableExtensions
        self.flags = flags
        self.home = home
        self.toolIsInstalled = toolIsInstalled
        self.note = note
    }

    /// Journal par défaut : une ligne sur `stderr`. Jamais `stdout` — un
    /// `fouine … --json` doit rester lisible par une machine.
    public static let noteToStderr: @Sendable (String) -> Void = { message in
        FileHandle.standardError.write(Data(("fouine: " + message + "\n").utf8))
    }

    // MARK: - Énumération

    /// Attributs demandés en une fois à l'énumérateur : les lire à la volée
    /// coûte un appel système par clé et par entrée.
    static let enumerationKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
    ]

    /// Les DEUX options que le §5.2 n'avait pas (audit F5) :
    ///
    ///   · `.skipsHiddenFiles` — un document caché n'est pas un document que
    ///     l'utilisateur cherche, et c'est le seul filtre qui couvre d'un coup
    ///     les `.dossier` qu'aucune liste ne peut épuiser (`.venv` d'un projet,
    ///     `.local`, `.config`, les caches d'outils pas encore inventés).
    ///     Attention : l'option porte sur le CONTENU énuméré, pas sur la base —
    ///     une racine elle-même cachée (`~/.docs`) s'indexe donc normalement ;
    ///   · `.skipsPackageDescendants` — LaunchServices connaît tous les types de
    ///     paquets installés ; on ne redescend jamais dans une photothèque de
    ///     200 Go. Le repli par extension reste nécessaire (`CrawlExclusions`)
    ///     là où il ne répond pas.
    static let enumerationOptions: FileManager.DirectoryEnumerationOptions =
        [.skipsHiddenFiles, .skipsPackageDescendants]

    // MARK: - Identité d'un fichier (constat A3-02)

    /// Ce qui fait qu'un fichier apparu AILLEURS est le fichier disparu ICI.
    ///
    /// Les trois critères sont exigés ENSEMBLE, et c'est délibéré. L'inode seul
    /// ne suffit pas : APFS le réattribue après une suppression, et un fichier
    /// effacé puis un autre créé peuvent le partager. Y ajouter la taille et le
    /// mtime — que `mv` ne touche pas, et qu'une réécriture change toujours —
    /// rend la confusion invraisemblable, et le pire cas d'une confusion est un
    /// document dont le texte est périmé, jamais un document détruit.
    struct FileIdentity: Hashable {
        let inode: Int64
        let size: Int64
        let mtime: Double
    }

    /// « Ce dossier est-il un projet logiciel ? », mémorisé (lot INT-F1).
    ///
    /// Le crawler ne pose la question que pour un dossier dont le NOM peut être
    /// une sortie de construction : le coût réel est donc d'un
    /// `contentsOfDirectory` par dossier qui contient un « build », un « dist »
    /// ou un « target », et jamais deux fois pour le même parent.
    final class ProjectMarkerCache {
        private var answers: [String: Bool] = [:]

        func isProject(_ directory: URL) -> Bool {
            let key = directory.path
            if let known = answers[key] { return known }
            let names = (try? FileManager.default
                .contentsOfDirectory(atPath: key)) ?? []
            let answer = names.contains { CrawlExclusions.isProjectMarker(component: $0) }
            answers[key] = answer
            return answer
        }
    }

    /// « Ce document a été sauté parce que Fouine ne lisait pas son format » :
    /// les trois phrases que le registre et `IndexText` écrivent commencent
    /// toutes par « unsupported » (`unsupported format`, `unsupported format:
    /// .ppt`, `unsupported binary OLE format`). Un motif d'outil absent
    /// (`missing-tool:`) ou de taille n'en relève pas.
    static func wasUnsupported(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return reason.lowercased().hasPrefix("unsupported")
    }

    /// Un fichier apparu à un chemin inconnu, mis de côté le temps de savoir si
    /// un chemin connu a disparu avec la même identité.
    private struct Candidate {
        let identity: FileIdentity
        let record: DocRecord
    }

    // MARK: - Crawler

    public func crawl(rootID: Int64, mode: CrawlMode,
                      store: any IndexStore) throws -> CrawlSummary {
        let root = try Self.root(id: rootID, store: store)
        let rootURL = try Self.rootURL(of: root)

        // LES EXCLUSIONS DE L'UTILISATEUR (lot IG1), relues à CHAQUE passe.
        // Relues et non mémorisées : le fichier change quand l'utilisateur le
        // veut, l'agent tourne des semaines, et une règle ajoutée ce matin doit
        // valoir à la passe de ce soir sans relancer quoi que ce soit.
        //
        // Le fichier UNI aux règles gardées par Fouine (lot IG2). Une base
        // qu'on ne peut pas lire fait échouer la racine plutôt que de la
        // parcourir sans ses règles : `docs(underRoot:)`, trois lignes plus
        // bas, échouerait de toute façon, et un parcours sans exclusions
        // réindexerait ce que l'utilisateur a retiré.
        var stored = IgnoreRuleSet()
        if let keeper = store as? any StoredIgnoreRulesStore {
            let decoded = IgnoreRuleSet.decode(try keeper.ignoreRulesJSON(rootID: rootID))
            stored = decoded.set
            for warning in decoded.warnings { note("root “\(root.label)”: " + warning) }
        }
        let ignore = IgnoreRules.load(root: rootURL, stored: stored)
        for warning in ignore?.warnings ?? [] { note(warning) }

        // Piège n°1 (§7.1) : AVANT TOUT.
        try Self.probe(rootURL: rootURL, flags: flags, ignore: ignore)

        var known: [String: DocRow] = [:]
        // Index d'identité des documents connus (A3-02). Seuls les inodes NON
        // NULS y entrent : une ligne d'avant le schéma v6, ou un volume qui ne
        // garantit pas l'inode (FAT, SMB), ne peut servir de source à un
        // rapprochement — on retombe alors sur l'ancien comportement.
        var byIdentity: [FileIdentity: [Int64]] = [:]
        var pathByID: [Int64: String] = [:]
        for row in try store.docs(underRoot: rootID) {
            known[row.record.relPath] = row
            pathByID[row.id] = row.record.relPath
            if row.record.inode != 0 {
                byIdentity[FileIdentity(inode: row.record.inode,
                                        size: row.record.size,
                                        mtime: row.record.mtime),
                           default: []].append(row.id)
            }
        }

        var seen = 0, added = 0, updated = 0, skipped = 0, removed = 0
        var present = Set<String>()
        /// Chemins apparus dont l'identité existe déjà quelque part : ils
        /// attendent la fin du parcours, seul moment où l'on sache quels chemins
        /// connus ont VRAIMENT disparu.
        var candidates: [Candidate] = []
        /// Renseignement de `docs.inode` pour les lignes qui n'en portent pas
        /// encore (base migrée depuis la v5) : même chemin, même contenu, on
        /// n'écrit QUE la colonne, et une seule fois dans la vie de la ligne.
        var backfill: [DocRelocation] = []

        // FileManager canonicalise la base d'énumération (mesuré : une racine
        // passée en /var/… rend des URL en /private/var/…). On parcourt donc le
        // chemin canonique, et c'est LUI qu'on retire pour obtenir le sous-chemin.
        let scanRoot = Self.canonicalPath(rootURL.path)
        let scanURL = URL(fileURLWithPath: scanRoot, isDirectory: true)

        let keys = Self.enumerationKeys
        let enumerator = FileManager.default.enumerator(
            at: scanURL, includingPropertiesForKeys: keys,
            options: Self.enumerationOptions,
            errorHandler: { _, _ in true })   // un sous-dossier illisible n'arrête
                                              // pas le lot (§7.2 n°13)
        guard let enumerator else {
            throw FouineError.rootUnreadable(
                path: rootURL.path,
                reason: RootProbe.Reason.system("cannot enumerate").token)
        }

        let projects = ProjectMarkerCache()

        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false

            if CrawlExclusions.isExcluded(component: name)
                || (isDirectory
                    && CrawlExclusions.isHomeLibrary(path: url.path, home: home)) {
                skipped += 1
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            // `.fouineignore` (lot IG1), AVANT tout le reste du traitement : un
            // dossier exclu ne doit pas même être ouvert, et un paquet exclu
            // (`.pages`, `.mbox`) ne doit pas devenir un document. Le chemin
            // comparé est relatif à LA RACINE — c'est ce que l'utilisateur voit
            // dans son Finder —, jamais le `rel_path` du volume.
            if let ignore, !ignore.isEmpty,
               ignore.matches(relPath: Self.subPath(of: url, scanRoot: scanRoot),
                              isDirectory: isDirectory) {
                skipped += 1
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            // Sortie de construction SOUS un projet logiciel (lot INT-F1). Le
            // test du parent ne coûte un `contentsOfDirectory` que sur les noms
            // qui peuvent être des sorties (« build », « dist »…), et une seule
            // fois par dossier parent.
            if isDirectory, CrawlExclusions.mightBeBuildFolder(component: name),
               CrawlExclusions.isExcludedBuildFolder(
                   component: name,
                   parentContainsProjectMarker: projects.isProject(
                       url.deletingLastPathComponent())) {
                skipped += 1
                enumerator.skipDescendants()
                continue
            }
            if values?.isSymbolicLink == true {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            let ext = url.pathExtension.lowercased()
            if isDirectory {
                // Un PAQUET est un fichier, pas un dossier : on ne descend jamais
                // dedans. `.skipsPackageDescendants` le fait déjà pour tout ce que
                // LaunchServices reconnaît ; le `skipDescendants()` explicite tient
                // le repli par extension, là où `isPackage` rend `false` (§F5).
                guard CrawlExclusions.isPackage(
                        extension: ext,
                        declaredByLaunchServices: values?.isPackage) else {
                    // Dossier ORDINAIRE, y compris s'il porte l'extension d'un
                    // fichier indexable : « photos.old » et un dossier nommé
                    // « rapport.pdf » sont légitimes, et leurs documents comptent.
                    continue
                }
                enumerator.skipDescendants()
                // Exception : les paquets-documents que l'extracteur SAIT lire —
                // `.rtfd` et les formats iWork (`.pages`, `.numbers`, `.key`) —
                // deviennent un DOCUMENT et poursuivent dans le traitement fichier.
                guard CrawlExclusions.documentPackageExtensions.contains(ext),
                      indexableExtensions.contains(ext) else {
                    skipped += 1
                    continue
                }
            }

            // Les extensions non prises en charge sont ignorées SILENCIEUSEMENT :
            // elles ne sont pas enregistrées et ne comptent pas comme exclusions.
            guard indexableExtensions.contains(ext) else { continue }

            var st = stat()
            guard stat(url.path, &st) == 0 else { continue }  // disparu entre-temps
            let size = Int64(st.st_size)
            // mtime REAL, epoch, granularité nanoseconde d'APFS (§4.1).
            let mtime = Double(st.st_mtimespec.tv_sec)
                + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000
            // IDENTIFIANT DE FICHIER (A3-02). `st_ino` et non
            // `fileResourceIdentifierKey` : le `stat` est déjà fait ici, il ne
            // coûte donc rien de plus, là où la clé d'URL demande un appel
            // système supplémentaire par entrée et rend un objet opaque qu'il
            // faudrait sérialiser pour le stocker.
            let inode = Int64(bitPattern: UInt64(st.st_ino))

            let relPath = Self.relPath(of: url, scanRoot: scanRoot, root: root)
            var record = DocRecord(volUUID: root.volUUID,
                                   relPath: relPath,
                                   ext: ext,
                                   topFolder: root.label,   // LABEL de la racine,
                                                            // pas le 1er segment
                                   size: size,
                                   mtime: mtime,
                                   state: .discovered,
                                   inode: inode)

            // Fichier NON RÉSIDENT (F5) : il est enregistré `.skipped`, il reste
            // `present` (donc pas retiré de l'index), et il n'est JAMAIS OUVERT.
            // Il ne compte ni en `seen` ni en `added` : « vus » désigne les
            // documents retenus pour l'indexation, et celui-ci ne l'est pas
            // encore.
            if FileResidency.isNonResident(url, flags: flags) {
                skipped += 1
                present.insert(relPath)
                if let previous = known[relPath] {
                    // Déjà extrait avant d'être évincé : son texte reste dans
                    // l'index et reste juste — on ne le dégrade pas. Seul un
                    // document jamais extrait passe en `.skipped`.
                    if previous.record.state == .discovered {
                        try store.setDocState(previous.id, .skipped,
                                              err: FileResidency.skipReason)
                    }
                } else {
                    record.state = .skipped
                    record.err = FileResidency.skipReason
                    _ = try store.upsertDoc(record)
                }
                continue
            }

            seen += 1
            present.insert(relPath)

            // On n'écrit QUE si le fichier est nouveau ou si (size, mtime) ont
            // bougé. `upsertDoc` est déjà un no-op logique dans le cas contraire
            // (il conserve state / ocr_state / n_pages), mais c'est un no-op qui
            // coûte une transaction d'écriture et un SELECT : sur le corpus réel,
            // 1 329 transactions par crawl delta pour zéro changement, en
            // contention avec l'OCR de l'agent. Le no-op du store reste le filet :
            // `known` ne porte que (size, mtime), et c'est exactement ce que le
            // store compare.
            if let previous = known[relPath] {
                if previous.record.size != size || previous.record.mtime != mtime {
                    _ = try store.upsertDoc(record)
                    updated += 1
                } else if previous.record.inode != inode {
                    // Même chemin, même contenu, inode absent ou différent.
                    // C'est le cas d'une base migrée depuis la v5 (inode 0) ; on
                    // renseigne la colonne SANS rien ré-extraire, et ce n'est
                    // pas une mise à jour du document — rien de ce que
                    // l'utilisateur voit n'a changé.
                    backfill.append(DocRelocation(id: previous.id, relPath: relPath,
                                                  topFolder: root.label, ext: ext,
                                                  inode: inode))
                } else if previous.record.state == .skipped,
                          previous.record.err == FileResidency.skipReason {
                    // Le fichier est REDEVENU résident. Sa matérialisation ne
                    // change ni sa taille ni son mtime : le delta (size, mtime)
                    // ne le verrait JAMAIS et il resterait `.skipped` à vie.
                    try store.setDocState(previous.id, .discovered, err: nil)
                    updated += 1
                } else if previous.record.state == .skipped,
                          let missing = ExternalTool.missingTool(
                              inSkipReason: previous.record.err),
                          toolIsInstalled(missing) {
                    // MÊME RAISONNEMENT, AUTRE CAUSE (A3-05). Un `.djvu` indexé
                    // avant `brew install djvulibre` porte
                    // « missing-tool:djvused » : installer l'outil ne change ni
                    // la taille ni le mtime du fichier, et le document restait
                    // sauté à vie — l'utilisateur n'avait d'autre recours qu'un
                    // `touch` sur chacun de ses fichiers.
                    //
                    // Avec le cas suivant, ce sont les TROIS seuls états
                    // `.skipped` que le crawl réexamine, et ils ont ceci en
                    // commun que leur cause est EXTÉRIEURE au fichier : elle
                    // peut disparaître sans que le fichier bouge. Un « fichier
                    // trop gros », lui, ne change pas tout seul.
                    try store.setDocState(previous.id, .discovered, err: nil)
                    updated += 1
                } else if previous.record.state == .skipped,
                          Self.wasUnsupported(previous.record.err),
                          indexableExtensions.contains(ext) {
                    // MÊME RAISONNEMENT, TROISIÈME CAUSE (lot INT-F1). La cause
                    // était dans FOUINE, pas dans le fichier : « unsupported
                    // binary OLE format » sur un `.xls` ou un `.ppt` indexé
                    // avant que Fouine sache les lire. Une version qui apprend
                    // un format ne change ni la taille ni le mtime du fichier ;
                    // sans cette relecture, tous les classeurs et diaporamas
                    // d'un index existant resteraient sautés à vie, et
                    // l'utilisateur ne saurait même pas qu'il y a quelque chose
                    // à relancer. La règle est GÉNÉRALE — tout motif
                    // « unsupported… » d'une extension que le registre prend
                    // désormais — pour que le prochain format appris n'ait pas
                    // à réécrire cette branche.
                    try store.setDocState(previous.id, .discovered, err: nil)
                    updated += 1
                }
            } else if inode != 0,
                      byIdentity[FileIdentity(inode: inode, size: size,
                                              mtime: mtime)] != nil {
                // Chemin inconnu, identité connue : peut-être un déplacement.
                // On ne tranche qu'après le parcours (un fichier COPIÉ porterait
                // un autre inode ; un fichier dont l'original existe encore ne
                // doit rien déplacer).
                candidates.append(Candidate(
                    identity: FileIdentity(inode: inode, size: size, mtime: mtime),
                    record: record))
            } else {
                _ = try store.upsertDoc(record)
                added += 1
            }
        }

        // RAPPROCHEMENT DES DÉPLACEMENTS (constat A3-02), avant la passe de
        // suppression : une source rapprochée ne doit surtout pas être purgée.
        //
        // Une source n'est éligible que si son chemin a VRAIMENT disparu. C'est
        // ce qui distingue un déplacement d'une copie : quand l'original est
        // encore là, son chemin est `present`, il ne peut pas servir de source,
        // et le nouveau fichier devient un document neuf — ce qu'il est.
        var moved = 0
        var relocations: [DocRelocation] = []
        var claimed = Set<Int64>()
        for candidate in candidates {
            let sources = (byIdentity[candidate.identity] ?? []).filter { id in
                !claimed.contains(id) && !present.contains(pathByID[id] ?? "")
            }
            guard let source = sources.min() else {   // départage déterministe
                _ = try store.upsertDoc(candidate.record)
                added += 1
                continue
            }
            claimed.insert(source)
            relocations.append(DocRelocation(id: source,
                                             relPath: candidate.record.relPath,
                                             topFolder: candidate.record.topFolder,
                                             ext: candidate.record.ext,
                                             inode: candidate.record.inode))
            moved += 1
        }
        // UNE SEULE transaction pour tout le lot : un dossier de mille documents
        // se déplace d'un coup ou pas du tout.
        try store.relocateDocs(relocations + backfill)

        // Suppressions : dans LES DEUX modes. Le parcours est le même, la liste
        // connue est la même, et un document dont le chemin n'existe plus doit
        // sortir de l'index (docs, page_fts par plage de rowid, page_src,
        // ocr_layout, ocr_queue — c'est `removeDoc` qui s'en charge, §5.2).
        //
        // « ÉTEINT » N'EST JAMAIS « DISPARU » (constat C2-04, 09/09/2026). La
        // liste d'extensions est reconstruite à CHAQUE passe depuis les
        // réglages (`IndexPass.init`) : une passe lancée sans `extract.images`
        // ne VOIT plus les .png du dossier, les prenait donc pour disparus et
        // les retirait — avec leurs pages d'OCR. Mesuré : 16 images et 12 pages
        // d'OCR (24,5 s de Vision) effacées par un seul `fouine index`. Et le
        // piège se déclenche TOUT SEUL : l'agent d'arrière-plan lit la table
        // `settings`, jamais le `FOUINE_EXTRACT_IMAGES=1` d'un terminal, donc
        // sa passe suivante effaçait ce que ce terminal venait de produire.
        //
        // Un document dont l'extension n'est plus dans la liste courante est
        // donc LAISSÉ EN PLACE, état inchangé, sans une écriture. Le retrait
        // n'appartient qu'à un geste explicite (`root remove --purge`) ou à un
        // fichier vraiment disparu d'une catégorie ALLUMÉE.
        for relPath in known.keys.sorted() where !present.contains(relPath) {
            guard let row = known[relPath], !claimed.contains(row.id) else { continue }
            guard indexableExtensions.contains(row.record.ext.lowercased()) else {
                continue
            }
            try store.removeDoc(id: row.id)
            removed += 1
        }
        // `mode` ne change ni le parcours ni la passe de suppression : le no-op
        // sur (size, mtime) inchangés est fait par le store, et un document
        // disparu doit sortir de l'index dans les deux cas. Il reste au contrat
        // pour la CLI (§4.3).

        return CrawlSummary(seen: seen, added: added, updated: updated,
                            removed: removed, skipped: skipped, moved: moved)
    }

    /// Lit effectivement un fichier de la racine (§4.2, §7.1). Utilisé par
    /// `fouine doctor`. Exige le store injecté à la construction.
    public func probeReadable(rootID: Int64) throws {
        guard let store else {
            throw FouineError.databaseFailure(
                "FouineCrawler.probeReadable(rootID:) needs an IndexStore: "
                + "build FouineCrawler(store:) or call "
                + "probeReadable(rootID:store:)")
        }
        try probeReadable(rootID: rootID, store: store)
    }

    public func probeReadable(rootID: Int64, store: any IndexStore) throws {
        let root = try Self.root(id: rootID, store: store)
        try Self.probe(rootURL: try Self.rootURL(of: root), flags: flags)
    }

    // MARK: - Résolution

    static func root(id: Int64, store: any IndexStore) throws -> RootRecord {
        guard let root = try store.roots().first(where: { $0.id == id }) else {
            throw FouineError.databaseFailure("unknown root: id \(id)")
        }
        return root
    }

    /// Volume par UUID, JAMAIS par chemin de montage seul (§2.3).
    static func rootURL(of root: RootRecord) throws -> URL {
        guard let mountPoint = VolumeResolver.mountPoint(forVolumeUUID: root.volUUID)
        else {
            throw FouineError.volumeNotMounted(uuid: root.volUUID)
        }
        return root.relPath.isEmpty
            ? mountPoint
            : mountPoint.appendingPathComponent(root.relPath)
    }

    /// Chemin RELATIF À LA RACINE DU VOLUME (§4.1 : `docs.rel_path`), jamais
    /// relatif à la racine indexée : il se compose du `rel_path` de la racine
    /// (déjà relatif au volume) et du sous-chemin sous cette racine.
    /// Le chemin est rendu en NFC (A3-10) : l'énumérateur de FileManager rend
    /// historiquement du NFD sur HFS+, et `docs.rel_path` se compare en SQLite
    /// par égalité d'OCTETS — un « é » décomposé ne retrouve jamais un « é »
    /// précomposé, sans le moindre message. Voir `RelPath`.
    /// Chemin relatif À LA RACINE INDEXÉE — celui qu'une règle de
    /// `.fouineignore` nomme, et celui que l'utilisateur voit dans son Finder.
    /// À ne pas confondre avec `relPath(of:scanRoot:root:)`, qui est relatif au
    /// VOLUME et porte donc le chemin de la racine en tête.
    static func subPath(of url: URL, scanRoot: String) -> String {
        var sub = strip(prefix: scanRoot, from: url.path)
            ?? strip(prefix: scanRoot, from: canonicalPath(url.path))
            ?? url.lastPathComponent
        while sub.hasPrefix("/") { sub.removeFirst() }
        return RelPath.normalized(sub)
    }

    static func relPath(of url: URL, scanRoot: String, root: RootRecord) -> String {
        var sub = strip(prefix: scanRoot, from: url.path)
            ?? strip(prefix: scanRoot, from: canonicalPath(url.path))
            ?? url.lastPathComponent
        while sub.hasPrefix("/") { sub.removeFirst() }
        if root.relPath.isEmpty { return RelPath.normalized(sub) }
        return RelPath.normalized(
            sub.isEmpty ? root.relPath : root.relPath + "/" + sub)
    }

    static func strip(prefix: String, from path: String) -> String? {
        if path == prefix { return "" }
        let separated = prefix.hasSuffix("/") ? prefix : prefix + "/"
        guard path.hasPrefix(separated) else { return nil }
        return String(path.dropFirst(separated.count))
    }

    /// `realpath(3)` : le chemin sans lien symbolique, tel que FileManager le rend.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Lisibilité (piège n°1, §7.1)

    /// Ouvre et LIT des octets. Un `FileManager.fileExists` ne sert à rien : c'est
    /// précisément le mode d'échec que l'on cherche à détecter (§4.3).
    static func probe(rootURL: URL,
                      flags: FileResidency.FlagsReader = FileResidency.systemFlags,
                      ignore: IgnoreRules? = nil)
        throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            throw FouineError.rootUnreadable(
                path: rootURL.path,
                reason: RootProbe.Reason.missing.token)
        }
        guard isDirectory.boolValue else {
            throw FouineError.rootUnreadable(
                path: rootURL.path,
                reason: RootProbe.Reason.system("the root is not a folder").token)
        }
        do {
            _ = try fm.contentsOfDirectory(atPath: rootURL.path)
        } catch {
            throw FouineError.rootUnreadable(
                path: rootURL.path,
                reason: RootProbe.Reason.system(
                    (error as NSError).localizedDescription).token)
        }
        guard let file = firstFile(under: rootURL, flags: flags, ignore: ignore) else {
            return          // racine vide : rien à lire, rien à reprocher
        }
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            _ = try handle.read(upToCount: 4_096)
        } catch {
            // Message d'origine système, tel quel : c'est lui qui dit « Operation
            // not permitted » quand TCC refuse (§7.1). La CLI y ajoute le geste.
            throw FouineError.rootUnreadable(
                path: file.path, reason: (error as NSError).localizedDescription)
        }
    }

    /// Premier fichier ordinaire sous la racine, exclusions appliquées. Recherche
    /// bornée : une racine gigantesque ne doit pas transformer la sonde en crawl.
    ///
    /// La sonde emprunte les MÊMES options que le crawl : elle doit lire un
    /// fichier que le crawl indexerait, sinon elle refuse une racine à cause
    /// d'un fichier caché qu'on n'aurait de toute façon jamais ouvert. Et elle
    /// écarte les fichiers non résidents (F5) — la sonde LIT vraiment des
    /// octets, c'est tout son objet, donc c'est précisément elle qui
    /// déclencherait le premier téléchargement d'un ~/Documents évincé.
    ///
    /// Les règles de l'utilisateur (`ignore`) s'y appliquent AUSSI, lot IG1 :
    /// une racine dont le seul contenu lisible est exclu est une racine VIDE —
    /// « rien à lire, rien à reprocher » —, jamais une racine illisible. Sans
    /// cela, la sonde ouvrirait le premier fichier d'un dossier `Santé/` que
    /// l'utilisateur vient d'exclure.
    static func firstFile(under rootURL: URL, limit: Int = 20_000,
                          flags: FileResidency.FlagsReader = FileResidency.systemFlags,
                          ignore: IgnoreRules? = nil)
        -> URL? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        let scanRoot = canonicalPath(rootURL.path)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: keys,
            options: enumerationOptions,
            errorHandler: { _, _ in true }) else { return nil }
        var inspected = 0
        while let url = enumerator.nextObject() as? URL, inspected < limit {
            inspected += 1
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            if CrawlExclusions.isExcluded(component: name) {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if let ignore, !ignore.isEmpty,
               ignore.matches(relPath: subPath(of: url, scanRoot: scanRoot),
                              isDirectory: values?.isDirectory == true) {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values?.isRegularFile == true,
               !FileResidency.isNonResident(url, flags: flags) { return url }
        }
        return nil
    }
}
