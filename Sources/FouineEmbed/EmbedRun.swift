// EmbedRun.swift — production incrémentale des vecteurs de pages (`fouine
// embed`). Propriété : A-Embed.
//
// Même philosophie que OCRRun : lots budgétés, reprise gratuite, annulation
// consultée entre deux lots, journal en français.
//
// COHABITATION AVEC L'AGENT (audit A1) : l'agent détient le verrou d'écriture
// pendant tout un lot OCR (~10 min). Bloquer l'inférence sur ce verrou
// réduirait la pompe à ~5 % de rendement. Les vecteurs produits s'accumulent
// donc dans un TAMPON en mémoire (borné), une écriture est TENTÉE après chaque
// lot, et le tampon se vide dès qu'une fenêtre de verrou s'ouvre. Rien n'est
// jamais perdu : au pire, les pages du tampon non écrit sont réinférées à la
// prochaine invocation.
//
// LE VERROU EST RENDU APRÈS CHAQUE LOT ÉCRIT (audit B1-06, D2-04). Il ne
// l'était pas : `upsertVectors` le prenait paresseusement au premier lot, et
// seule la sortie du processus le rendait. Pendant les vingt heures d'une
// campagne, l'application ne pouvait donc plus ni ajouter un dossier, ni
// indexer, ni lancer l'OCR — elle échouait après cinq secondes d'attente sur
// une alerte à un seul bouton. Pire : tout le dispositif ci-dessus devenait du
// CODE MORT dès la cinquième seconde. `flushIfUnlocked` ne peut rendre `false`
// que si le verrou est tenu par un AUTRE processus ; en le gardant, la pompe
// se garantissait à elle-même de toujours réussir, `patiently` n'attendait
// plus, `maxPendingPages` n'était plus atteint, et « waiting for a lock
// window » ne pouvait plus s'imprimer. Le code écrit pour cohabiter était
// exactement celui qui excluait.
//
// Le coût de la libération est chiffré (D2-04) : un lot vaut ~4,8 s
// d'inférence, un `flock` + `stamp` vaut moins d'une milliseconde. Rendre et
// reprendre le verrou ~15 000 fois sur 20 h coûte quelques secondes au total.
// Il n'y a pas d'arbitrage. Le seul effet mesurable est une fenêtre de quelques
// secondes toutes les quelques secondes pendant laquelle un autre écrivain peut
// prendre le verrou et retarder un lot : c'est exactement le comportement
// voulu, l'utilisateur au clavier passe avant la campagne de fond.
//
// PRÉCAUTION (D2-04) : `releaseWriteLock()` passe par
// `barrierWriteWithoutTransaction`, il ne doit donc JAMAIS être appelé depuis
// l'intérieur d'une écriture. Ici il est appelé APRÈS le retour
// d'`upsertVectors`, jamais dans son corps.
//
// CURSEUR DE REPRISE (audit V2, 01/09/2026) — le point qui a changé. La
// sélection de lot était une anti-jointure NUE (`LEFT JOIN page_vec … WHERE
// v.rowid IS NULL LIMIT 24`) : elle rebalayait à chaque lot toutes les pages
// déjà vectorisées, ~8 s en fin de campagne contre 3,75 s d'inférence. Elle
// est désormais bornée par `rowid > curseur` (voir `pagesNeedingVector`), et
// c'est la POMPE qui porte le curseur :
//
//   · BALAYAGE AVANT : le curseur repart du dernier rowid du lot précédent.
//     Sur toute la campagne, `page_fts` n'est balayée qu'UNE fois.
//   · PASSE DE RATTRAPAGE : quand le balayage ne rend plus rien, le curseur
//     repart de 0. C'est indispensable — `replacePages` et `completeOCR`
//     invalident les vecteurs des pages qu'ils réécrivent (l'agent OCRise
//     pendant la campagne), et ces pages peuvent être DERRIÈRE le curseur.
//     La pompe s'arrête quand un balayage complet n'a rien rendu.
//   · L'incrémental est intact : une page COMPLÈTE n'est jamais sélectionnée,
//     quel que soit le curseur.
//
// FENÊTRAGE (schéma v5, constat C2-05) — ce que la pompe produit a changé. Une
// page ne vaut plus un vecteur mais jusqu'à `Schema.vecWindowMax` : le vecteur
// ne voyait que 56,2 % du texte du corpus (page moyenne 2 282 caractères,
// fenêtre 1 400), il en voit 97,4 %. Trois règles, et elles se tiennent :
//
//   · la fenêtre 0 est EXACTEMENT `prefix(1400)`, c'est-à-dire ce que la
//     campagne produisait au schéma v3. Les vecteurs déjà en base sont donc
//     réutilisés tels quels — `existingVectorChunks` les voit, et la pompe
//     n'infère QUE les fenêtres manquantes ;
//   · le dernier créneau (`vecWindowMax - 1`) est écrit à CHAQUE page traitée :
//     vrai vecteur si la fenêtre existe, blob VIDE (sentinelle) sinon. C'est
//     lui, et lui seul, qui dit « cette page est faite » à la sélection de lot ;
//   · la règle du vecteur nul (`minChars`) s'applique PAR FENÊTRE : une queue
//     de page qui ne porte qu'une note de bas de page ne doit pas classer.
//
// GARDE-FOU ANTI-BOUCLE. La passe de rattrapage repart de 0 tant qu'un
// balayage produit quelque chose. Si une passe re-sélectionne EXACTEMENT le
// même ensemble de pages que la précédente, c'est que quelque chose empêche la
// complétude d'être écrite (déclencheur SQL, invalidation en boucle) : la pompe
// s'arrête en le disant, plutôt que de tourner jusqu'au budget.

import Foundation
import FouineCore

public enum EmbedRun {

    public struct Config {
        /// PAGES par lot de sélection. Une page vaut jusqu'à
        /// `Schema.vecWindowMax` fenêtres : 24 pages font donc jusqu'à 72
        /// passages dans un appel au moteur, ~30 Mio de tenseurs.
        public var batchSize = 24
        /// Budget mural en minutes ; nil = jusqu'à épuisement de la file.
        public var budgetMinutes: Double?
        /// Sous ce nombre de caractères utiles, la page reçoit un VECTEUR NUL :
        /// une page quasi vide (« This Page Intentionally Left Blank », faux
        /// titres) produit un embedding dégénéré proche de tout (cos ~0,83
        /// mesuré) et polluerait chaque top-k sémantique. Le vecteur nul a un
        /// produit scalaire nul : jamais classé, et zéro inférence dépensée.
        /// Le canal lexical, lui, voit toujours ces pages.
        public var minChars = 100
        /// Poser un vecteur nul sur une fenêtre DÉGÉNÉRÉE — « AAAA… »,
        /// « ababab… », une bordure de tirets (constat MO-01). Réglable pour
        /// que les tests de fenêtrage, dont le texte est justement « aaaa… »,
        /// continuent d'éprouver ce qu'ils éprouvent.
        public var nullDegenerate = true
        /// Racines à préparer EN PREMIER (lot MC3, constat PM-05). La pompe
        /// fait une phase complète sur elles — curseur reparti de zéro —, puis
        /// une phase sans restriction. Vide = une seule phase, comme avant.
        ///
        /// POURQUOI DES PHASES ET NON UN `ORDER BY`. La sélection est bornée
        /// par `rowid > curseur` : c'est ce qui fait qu'une campagne ne balaie
        /// `page_fts` qu'une fois (audit V2). Trier par priorité avant le rowid
        /// rendrait le curseur faux dès le second lot. Deux balayages complets
        /// coûtent un balayage de plus ; un curseur faux coûte des pages jamais
        /// vectorisées.
        public var priorityFolders: [String] = []
        /// Restreindre TOUTE la campagne à ces racines (`fouine embed
        /// --folder`). `nil` = tout l'index, ce qui reste le défaut.
        public var onlyFolders: [String]?
        /// Extensions dont AUCUNE fenêtre n'est inférée : chaque fenêtre reçoit
        /// le vecteur nul, et la page est comptée comme faite (constat PM-09).
        /// Les tableurs par défaut — un vecteur de colonne de nombres ne décrit
        /// rien et occupe une place dans chaque top-k. Vider la liste
        /// (`--include-tables`, `embed.skip_spreadsheets false`) les rend à
        /// l'inférence.
        public var skipExtensions: Set<String> = [
            "csv", "tsv", "xls", "xlsx", "xlsm", "ods", "numbers",
        ]
        /// Nombre de DOCUMENTS distincts portant le même passage à partir
        /// duquel une fenêtre reçoit un vecteur nul (constat C2-16) ; `0`
        /// désarme la sonde. Quatre : le document de la fenêtre compte, donc
        /// trois copies ailleurs — un préambule de licence, un pied de page de
        /// cabinet, des conditions générales recopiées.
        public var sharedTextDocuments = 4
        /// Journal, VIDÉ à chaque ligne (audit V3, complément).
        ///
        /// `print` seul écrit dans le tampon de la libc : redirigé vers un
        /// fichier — c'est le cas de la campagne, `~/Library/Logs/Fouine/embed.log`
        /// — stdout n'est plus une console, la libc passe en tampon de bloc, et
        /// le journal n'avançait que par tranches de 4 096 octets, dernière ligne
        /// tronquée. Pour une pompe qui tourne treize heures et dont le journal
        /// est le SEUL témoin, c'est le témoin qui manque. Un `fflush` par ligne
        /// coûte une écriture toutes les 30 s.
        public var log: (String) -> Void = { line in
            print(line)
            fflush(stdout)
        }

        public init() {}
    }

    public struct Summary {
        /// PAGES rendues complètes ET écrites (leur sentinelle est en base).
        public let embedded: Int
        /// FENÊTRES écrites, sentinelles vides comprises — l'unité dans
        /// laquelle se compte le travail d'inférence depuis le schéma v5.
        public let windows: Int
        /// Pages INCOMPLÈTES restantes (indexées, sans sentinelle).
        public let remaining: Int
        /// Fenêtres assez longues pour être inférées, mais annulées parce que
        /// leur texte est DÉGÉNÉRÉ (MO-01). Comptées à part : c'est le seul
        /// chiffre qui dise qu'un corpus porte des documents malades.
        public let degenerate: Int
        /// Fenêtres annulées parce que leur texte est PARTAGÉ par assez de
        /// documents pour n'apprendre rien au canal sémantique (C2-16).
        public let sharedText: Int
        /// Fenêtres annulées parce que le document est un TABLEUR
        /// (`skipExtensions`, constat PM-09).
        public let tables: Int
        public let elapsed: TimeInterval
        /// Vrai si `shouldStop` a coupé la pompe (Ctrl-C, SIGTERM, bouton de
        /// l'app) — à distinguer d'un budget épuisé et d'une file vidée.
        public let interrupted: Bool
        public var pagesPerSecond: Double {
            elapsed > 0 ? Double(embedded) / elapsed : 0
        }
        /// Débit d'inférence proprement dit : c'est lui qui dimensionne une
        /// campagne, `pagesPerSecond` n'en est que la projection par page.
        public var windowsPerSecond: Double {
            elapsed > 0 ? Double(windows) / elapsed : 0
        }
    }

    /// Fenêtres d'une page : `(créneau, texte)`, dans l'ordre.
    ///
    /// Le découpage lui-même est dans `PageEmbedding` depuis le lot MC4 : le
    /// serveur MCP encode une page à la volée (`encode_if_missing`) et doit
    /// produire EXACTEMENT le vecteur que cette campagne aurait produit. Deux
    /// découpes du même texte finiraient par ne plus coïncider, et l'écart
    /// serait invisible — les deux rendraient des nombres plausibles.
    static func windows(for text: String) -> [(chunk: Int, text: String)] {
        PageEmbedding.windows(for: text)
    }

    /// Tampon maximal de vecteurs en attente d'écriture (~2 000 FENÊTRES ×
    /// 384 o ≈ 0,8 Mio, soit ~940 pages au taux mesuré de 2,13 fenêtres par
    /// page). Au plafond, la pompe attend une fenêtre de verrou.
    static let maxPendingPages = 2_000
    /// Patience maximale sur une écriture bloquée : l'agent libère le verrou
    /// entre deux lots OCR (~10 min), 15 min couvrent le pire cas.
    static let flushPatience: TimeInterval = 15 * 60
    static let flushRetryDelay: TimeInterval = 10
    /// Patience accordée à l'écriture FINALE quand l'arrêt a été DEMANDÉ :
    /// attendre un quart d'heure après un Ctrl-C serait le contraire d'un
    /// arrêt. Une écriture de tampon prend quelques millisecondes quand le
    /// verrou est libre ; s'il ne l'est pas, les pages seront réinférées.
    static let stopFlushPatience: TimeInterval = 1
    /// Tranche de sommeil maximale : `shouldStop` est consulté au moins une
    /// fois par seconde, y compris pendant les attentes de verrou (audit F6 —
    /// `patiently` dormait 10 s d'un bloc et jusqu'à 15 min au total, sans
    /// aucun point de sortie).
    static let napSlice: TimeInterval = 1

    /// `shouldStop:` suit la convention d'`OCRRun.run` : valeur par défaut,
    /// consulté entre deux lots (jamais au milieu d'un), les pages en vol se
    /// terminent, aucune transaction n'est coupée, et le tampon est écrit avant
    /// de rendre la main. La `Summary` porte `interrupted` : c'est à l'appelant,
    /// qui sait ce qu'il a demandé, d'en faire ce qu'il veut.
    @discardableResult
    public static func run(store: GRDBStore, engine: EmbedEngine,
                           config: Config = Config(),
                           shouldStop: @escaping @Sendable () -> Bool = { false })
        throws -> Summary {

        let start = Date()
        var pending: [(rowid: Int64, vec: Data)] = []
        /// Pages dont TOUTES les fenêtres attendent dans le tampon.
        var pendingPages = Set<Int64>()
        var written = 0                 // fenêtres écrites
        var writtenPages = 0            // pages rendues complètes ET écrites
        var produced = 0                // fenêtres inférées ou nulles
        var degenerate = 0              // fenêtres nulles : texte dégénéré
        var sharedText = 0              // fenêtres nulles : texte partagé
        var tables = 0                  // fenêtres nulles : document tableur
        var probeSeconds: TimeInterval = 0   // temps passé dans la sonde
        /// Extension par document, retenue d'un lot à l'autre : la règle des
        /// tableurs se décide par DOCUMENT, et un corpus en porte deux mille
        /// quand une campagne traite quatre cent mille pages.
        var extensions: [Int64: String] = [:]

        // FILET (B1-06). Quel que soit le chemin de sortie — file vidée, budget
        // épuisé, Ctrl-C, ou une erreur qui remonte —, la pompe ne laisse pas
        // `fouine.lock` derrière elle. Idempotent : sans verrou, sans effet.
        defer { store.releaseWriteLock() }

        /// Tente l'écriture du tampon. Rend `false` — et GARDE le tampon —
        /// quand le VERROU est tenu par un autre processus : c'est la seule
        /// panne qu'il soit légitime d'attendre. Toute AUTRE erreur remonte
        /// (audit X3 : le `try?` d'origine rendait une base corrompue ou un
        /// disque plein indiscernables d'un verrou, et la pompe réessayait
        /// alors quinze minutes avant d'abandonner sans rien dire).
        func flushIfUnlocked() throws -> Bool {
            guard !pending.isEmpty else { return true }
            let done = try unlessLocked { try store.upsertVectors(pending) }
            if done {
                written += pending.count
                writtenPages += pendingPages.count
                pending.removeAll(keepingCapacity: true)
                pendingPages.removeAll(keepingCapacity: true)
                // POINT DE REPOS (B1-06, D2-04). Le verrou est rendu ICI, tout
                // de suite après l'écriture réussie — pas en fin de boucle,
                // sinon le tampon resterait inutile. Le lot suivant le
                // reprendra paresseusement par `writeLocked`, c'est le contrat
                // documenté de `GRDBStore.releaseWriteLock`.
                store.releaseWriteLock()
            }
            return done
        }

        /// Écrit le tampon en réessayant tant que le verrou est tenu, au plus
        /// `patience`. Rend `false` si l'annulation a coupé l'attente.
        func flush(_ what: String, patience: TimeInterval) throws -> Bool {
            try patiently(config, what, patience: patience,
                          shouldStop: shouldStop, flushIfUnlocked)
        }

        /// Pages indexées qui n'ont pas encore leur sentinelle de complétude.
        /// C'est le VRAI reste-à-faire depuis le fenêtrage : une page qui porte
        /// sa fenêtre 0 mais pas ses fenêtres de queue est encore du travail.
        func incompletePages() throws -> Int {
            try max(0, store.indexedPageCount() - store.completeVectorPageCount())
        }

        func summary(interrupted: Bool) throws -> Summary {
            Summary(embedded: writtenPages, windows: written,
                    remaining: try incompletePages(),
                    degenerate: degenerate, sharedText: sharedText,
                    tables: tables,
                    elapsed: Date().timeIntervalSince(start),
                    interrupted: interrupted)
        }

        /// La fenêtre porte-t-elle un texte que trop de documents partagent ?
        ///
        /// La sonde ne tourne que sur les fenêtres qui allaient VRAIMENT être
        /// inférées, et seulement au-delà de 400 caractères : c'est une requête
        /// FTS5 par fenêtre — 4,8 ms de médiane à froid, ~17 ms sous charge de
        /// campagne, soit 11,6 % du temps d'une campagne mesurée le 10/09/2026
        /// sur la copie de production (lot SI1) —, et elle n'a rien à faire sur
        /// une queue de page. `sharedTextDocuments = 0` la désarme.
        func isShared(_ text: String) -> Bool {
            guard config.sharedTextDocuments > 0,
                  let query = SharedTextProbe.query(for: text) else { return false }
            let started = Date()
            defer { probeSeconds += Date().timeIntervalSince(started) }
            let count = (try? store.documentsSharing(
                rawFTS: query, atLeast: config.sharedTextDocuments)) ?? 0
            return count >= config.sharedTextDocuments
        }

        // Identité du modèle : posée avant le premier vecteur ; un changement
        // de modèle purge les vecteurs de l'ancien espace (GRDBStore+Vec).
        // Aucune écriture (donc aucun verrou) quand elle est déjà à jour.
        let posed = try patiently(config, "setting the model identity",
                                  patience: flushPatience, shouldStop: shouldStop) {
            try unlessLocked {
                try store.setVecMeta(modelID: engine.modelID,
                                     dim: engine.dimension,
                                     revision: engine.revision)
            }
        }
        guard posed else { return try summary(interrupted: true) }
        // L'identité du modèle est une ÉCRITURE : elle a pu prendre le verrou.
        // Point de repos, avant même le premier lot.
        store.releaseWriteLock()

        let deadline = config.budgetMinutes.map { start.addingTimeInterval($0 * 60) }
        // Le reste-à-faire est en PAGES INCOMPLÈTES, et non en vecteurs : une
        // page peut porter sa fenêtre 0 et devoir encore deux fenêtres de
        // queue, une campagne interrompue en laisse toujours.
        let backlog = try incompletePages()
        config.log("vectors: \(backlog) incomplete page(s) to produce, "
                   + "up to \(Schema.vecWindowMax) window(s) each "
                   + "(model \(engine.modelID) r\(engine.revision), "
                   + "dim \(engine.dimension))")
        // CE QUI TOURNE, ET OÙ (C2-04). La campagne du 2 septembre a été
        // auditée deux fois sans que personne puisse dire de son journal quel
        // back-end de calcul servait ni quel processus écrivait : C2 en a
        // déduit un mauvais réglage, D2 a dû le mesurer au `lsof`. Deux
        // renseignements, une ligne, une fois par campagne.
        config.log("vectors: compute back-end \(E5Encoder.computeUnitsName()) "
                   + "(FOUINE_EMBED_COMPUTE), pid \(getpid())")

        var lastLog = Date()
        // DÉBIT GLISSANT (C2-04). Le journal affichait `produced / (now -
        // start)` : une moyenne CUMULÉE depuis le lancement, qui affichait
        // 4,9-5,0 p/s là où la pompe tournait à 6,4-6,6 — et qui met des heures
        // à refléter un ralentissement. Chaque point de journal retient
        // (instant, produites) ; le débit et l'ETA se lisent sur la fenêtre.
        var samples: [(at: Date, produced: Int)] = [(start, 0)]
        var cursor: Int64 = 0          // dernier rowid traité du balayage courant
        var sweep = 1                  // 1 = balayage avant, ≥ 2 = rattrapage
        var producedInSweep = 0        // PAGES traitées dans le balayage courant
        var pagesDone = 0              // pages traitées, tampon compris
        var interrupted = false
        // Garde-fou anti-boucle : pages sélectionnées par le balayage courant et
        // par le précédent, comparées à la fin de chaque passe de RATTRAPAGE.
        // Le balayage avant (sweep 1) ne peut pas boucler — son curseur avance —
        // et c'est lui qui sélectionne tout le corpus : ne rien retenir de lui
        // évite d'en garder 390 000 rowids en mémoire pour rien.
        var sweepPages = Set<Int64>()
        var previousSweepPages: Set<Int64>?
        /// Vrai quand la campagne ENTIÈRE s'arrête (budget, annulation,
        /// garde-fou) — à distinguer de la fin d'une phase, qui passe à la
        /// suivante.
        var stopped = false

        // LES PHASES (lot MC3, constat PM-05). `roots.pinned` ne gouvernait que
        // la file d'OCR : sur la production, `M2SU` et `Personnel` étaient
        // épinglés et n'avaient AUCUN vecteur pendant que `Livres`, non
        // épinglé, en était aux deux tiers — la sélection balaie par rowid,
        // c'est-à-dire par ordre de découverte des documents. Une phase par
        // groupe de racines, chacune avec son propre curseur, met les dossiers
        // prioritaires devant sans toucher au curseur qui fait la vitesse.
        let phases = Self.phases(config)
        for phase in phases {
            cursor = 0
            sweep = 1
            producedInSweep = 0
            sweepPages = []
            previousSweepPages = nil
            if phases.count > 1 { config.log("vectors: phase — " + phase.label) }

        while true {
            if let deadline, Date() >= deadline { stopped = true; break }
            if shouldStop() { interrupted = true; stopped = true; break }

            // Le tampon est tout entier DERRIÈRE le curseur en balayage avant :
            // la clause d'exclusion ne coûte quelque chose que pendant la passe
            // de rattrapage, où elle évite de réinférer ce qui attend d'être
            // écrit. Les rowids du tampon sont des rowids de FENÊTRE : la
            // sélection, elle, raisonne en pages.
            let unwritten = pendingPages.filter { $0 > cursor }.sorted()
            let batch = try store.pagesNeedingVector(
                limit: config.batchSize, after: cursor, excluding: unwritten,
                topFolders: phase.folders)

            guard !batch.isEmpty else {
                // Fin d'un balayage. S'il n'a RIEN rendu, il ne reste rien
                // nulle part : la pompe a fini. Sinon, une passe de rattrapage
                // repart de 0 pour ramasser les pages invalidées derrière le
                // curseur pendant qu'on travaillait.
                guard producedInSweep > 0 else { break }
                // GARDE-FOU. Deux passes qui sélectionnent exactement le même
                // ensemble de pages ne convergeront jamais : la sentinelle de
                // complétude ne s'écrit pas, et rien de ce que la pompe peut
                // faire n'y changera quoi que ce soit.
                if sweep >= 2, let previous = previousSweepPages,
                   previous == sweepPages {
                    config.log("vectors: sweep \(sweep) selected exactly the "
                               + "same \(sweepPages.count) page(s) as the "
                               + "previous one — stopping instead of looping "
                               + "(their completeness sentinel is not being "
                               + "written; check the database and the log above)")
                    stopped = true
                    break
                }
                config.log("vectors: end of sweep \(sweep) "
                           + "(\(producedInSweep) page(s)) — catch-up pass from "
                           + "the start of the index")
                previousSweepPages = sweep >= 2 ? sweepPages : nil
                sweepPages = []
                cursor = 0
                producedInSweep = 0
                sweep += 1
                continue
            }
            if sweep >= 2 { sweepPages.formUnion(batch.map(\.rowid)) }

            // Créneaux DÉJÀ produits pour ces pages, en une requête : une page
            // dont la fenêtre 0 est en base ne doit surtout pas être
            // réinférée (13,7 h de GPU en jeu sur le corpus réel).
            let present = try store.existingVectorChunks(
                pageRowIDs: batch.map(\.rowid))

            let zero = Data(count: engine.dimension)
            var toInfer: [(rowid: Int64, text: String)] = []
            var ready: [(rowid: Int64, vec: Data)] = []
            let last = Schema.vecWindowMax - 1
            for page in batch {
                let windows = Self.windows(for: page.text)
                // LE TABLEUR SE DÉCIDE PAR DOCUMENT, pas par fenêtre (PM-09) :
                // une extension suffit à savoir qu'aucune de ses pages ne dira
                // rien au canal sémantique. L'extension est retenue d'un lot à
                // l'autre — un document porte des centaines de pages.
                let docID = page.rowid / Schema.pagesPerDocLimit
                var isTable = false
                if !config.skipExtensions.isEmpty {
                    if let known = extensions[docID] {
                        isTable = config.skipExtensions.contains(known)
                    } else {
                        let ext = (try? store.docRow(id: docID))?
                            .record.ext.lowercased() ?? ""
                        extensions[docID] = ext
                        isTable = config.skipExtensions.contains(ext)
                    }
                }
                for window in windows {
                    let rowid = Schema.vecRowID(pageRowID: page.rowid,
                                                chunk: window.chunk)
                    if present.contains(rowid) { continue }
                    // Vecteur nul PAR FENÊTRE, et quatre raisons de le poser.
                    // L'ordre va du moins cher au plus cher : lire une
                    // extension déjà connue, compter des caractères, lire le
                    // texte, puis seulement interroger l'index.
                    if isTable {
                        tables += 1
                        ready.append((rowid, zero))
                    } else if window.text
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .count < config.minChars {
                        // Une queue de page qui ne porte qu'une note de bas de
                        // page ne doit pas classer.
                        ready.append((rowid, zero))
                    } else if config.nullDegenerate,
                              TextDegeneracy.isDegenerate(window.text)
                                || TextDegeneracy.isMostlyNumeric(window.text) {
                        // Une colonne de nombres est aussi inutile au sens
                        // qu'une bordure de tirets : même chemin, même compte.
                        degenerate += 1
                        ready.append((rowid, zero))
                    } else if isShared(window.text) {
                        sharedText += 1
                        ready.append((rowid, zero))
                    } else {
                        toInfer.append((rowid, window.text))
                    }
                }
                // SENTINELLE DE COMPLÉTUDE : si la page n'a pas autant de
                // fenêtres que `vecWindowMax`, le dernier créneau reçoit un blob
                // VIDE. Il ne sera jamais chargé par `allVectors` (dimension
                // inattendue) mais il dit à la sélection de lot que la page est
                // faite. ~12 o par page, ~4 Mio à 390 000 pages.
                if windows.count <= last {
                    ready.append((Schema.vecRowID(pageRowID: page.rowid,
                                                  chunk: last), Data()))
                }
            }

            let vectors = toInfer.isEmpty ? []
                : try engine.embedPassages(toInfer.map(\.text))
            guard vectors.count == toInfer.count else {
                throw FouineEmbedError.inference(
                    "\(vectors.count) vector(s) for \(toInfer.count) window(s)")
            }
            pending.append(contentsOf: zip(toInfer, vectors).map {
                (rowid: $0.0.rowid, vec: VecQuantizer.quantize($0.1))
            })
            pending.append(contentsOf: ready)
            pendingPages.formUnion(batch.map(\.rowid))
            produced += toInfer.count + ready.count
            pagesDone += batch.count
            producedInSweep += batch.count
            // `pagesNeedingVector` rend les pages par rowid croissant : le
            // dernier du lot EST le nouveau curseur.
            cursor = batch[batch.count - 1].rowid

            _ = try flushIfUnlocked()
            if pending.count >= maxPendingPages {
                config.log("vectors: buffer full (\(pending.count) window(s) "
                           + "for \(pendingPages.count) page(s)) — "
                           + "waiting for a lock window")
                guard try flush("writing the buffer", patience: flushPatience)
                else { interrupted = true; stopped = true; break }
            }

            if Date().timeIntervalSince(lastLog) >= 30 {
                let now = Date()
                samples.append((now, produced))
                // Le débit glissant se mesure en FENÊTRES : c'est l'unité que
                // le modèle consomme. L'ETA, lui, se rend en pages restantes
                // converties au nombre de fenêtres réellement observé — le
                // corpus décide, pas une moyenne postulée.
                let rate = Self.slidingRate(samples, now: now)
                let perPage = pagesDone > 0
                    ? Double(produced) / Double(pagesDone) : 1
                let left = Double(max(0, backlog - pagesDone)) * perPage
                let eta = rate > 0 ? left / rate / 3600 : 0
                config.log(String(format:
                    "vectors: %d/%d page(s), %d window(s) (%d waiting to be "
                    + "written), %.2f win/s, %.2f p/s, ~%.1f h left",
                    pagesDone, backlog, produced, pending.count,
                    rate, rate / max(perPage, 0.001), eta))
                lastLog = now
            }
        }
            if stopped { break }
        }

        if !pending.isEmpty {
            // Après une annulation la patience tombe à une seconde : le tampon
            // est écrit s'il peut l'être tout de suite, sinon il est réinféré à
            // la reprise — c'est le contrat de cohabitation, et c'est ce qui
            // tient la promesse « rendre la main tout de suite ».
            let done = try flush("final write of the buffer",
                                 patience: interrupted ? stopFlushPatience
                                                       : flushPatience)
            if !done {
                config.log("vectors: \(pending.count) window(s) inferred but "
                           + "NOT written (lock held) — they will be produced "
                           + "again on the next run")
            }
        }

        let result = try summary(interrupted: interrupted)
        // Le DÉBIT RÉEL de cette passe, gardé en base pour que
        // `fouine embed --status` projette une fin de campagne au lieu
        // d'annoncer un nombre de pages (idée 7 de l'audit A1m). Best-effort :
        // rater cet enregistrement — le verrou est repris par l'agent, le
        // disque est plein — ne doit jamais faire échouer une campagne de vingt
        // heures qui vient d'aboutir.
        if result.windows > 0, result.windowsPerSecond > 0 {
            try? store.recordEmbedRate(windowsPerSecond: result.windowsPerSecond)
        }
        config.log(String(format:
            "vectors: %d page(s) and %d window(s) produced, %.2f win/s "
            + "(%.2f p/s), %d incomplete page(s) left, %@%@",
            result.embedded, result.windows, result.windowsPerSecond,
            result.pagesPerSecond, result.remaining,
            format(result.elapsed), result.interrupted ? " (interrupted)" : ""))
        // LES NULS À PART, et seulement s'il y en a. C'est le seul endroit d'où
        // l'on peut apprendre qu'un corpus porte un document malade ou vingt
        // devis au même pied de page — et le seul chiffre qui dise ce que la
        // sonde a coûté.
        if result.degenerate > 0 || result.sharedText > 0 || result.tables > 0 {
            config.log(String(format:
                "vectors: %d window(s) nulled: %d degenerate or numeric, "
                + "%d shared text, %d spreadsheet (probe: %.1f s)",
                result.degenerate + result.sharedText + result.tables,
                result.degenerate, result.sharedText, result.tables,
                probeSeconds))
        }
        return result
    }

    /// Les phases d'une campagne, dans l'ordre.
    ///
    /// Sans racine prioritaire ni restriction, une seule phase sans
    /// restriction : c'est le comportement d'avant le lot MC3, au caractère
    /// près. `onlyFolders` remplace tout — une campagne `--folder M2SU` ne doit
    /// toucher à rien d'autre, pas même aux racines épinglées.
    static func phases(_ config: Config)
        -> [(label: String, folders: [String]?)] {
        if let only = config.onlyFolders, !only.isEmpty {
            return [(only.joined(separator: ", "), only)]
        }
        var out: [(label: String, folders: [String]?)] = []
        if !config.priorityFolders.isEmpty {
            out.append((config.priorityFolders.joined(separator: ", ") + " first",
                        config.priorityFolders))
        }
        out.append(("every folder", nil))
        return out
    }

    /// Les étiquettes des racines épinglées (`roots.pinned`), pour la CLI comme
    /// pour l'agent : une seule traduction « identifiants → étiquettes » dans
    /// le dépôt. Une racine épinglée qui a été retirée depuis ne rend rien,
    /// sans bruit — c'est un réglage périmé, pas une panne.
    public static func pinnedFolderLabels(store: GRDBStore,
                                          settings: SettingsSnapshot) -> [String] {
        let pinned = settings.pinnedRoots
        guard !pinned.isEmpty, let roots = try? store.roots() else { return [] }
        return roots.filter { pinned.contains($0.id) }.map(\.label)
    }

    /// Fenêtre du débit glissant. Cinq minutes : assez long pour absorber une
    /// fenêtre de verrou tenue par l'agent (un lot OCR dure ~10 min, mais la
    /// pompe continue d'inférer pendant ce temps), assez court pour qu'un
    /// ralentissement se lise dans le journal avant la fin de la campagne.
    static let rateWindow: TimeInterval = 5 * 60

    /// Débit sur la fenêtre, en pages par seconde.
    ///
    /// Les échantillons sont (instant, pages produites depuis le début), dans
    /// l'ordre. On prend le plus ANCIEN qui soit encore dans la fenêtre — et à
    /// défaut le tout premier, ce qui redonne la moyenne cumulée pendant les
    /// cinq premières minutes, là où c'est la seule chose qu'on sache dire.
    /// `samples` porte toujours au moins le point de départ.
    static func slidingRate(_ samples: [(at: Date, produced: Int)],
                            now: Date) -> Double {
        guard let last = samples.last else { return 0 }
        let cutoff = now.addingTimeInterval(-rateWindow)
        let base = samples.last(where: { $0.at <= cutoff }) ?? samples[0]
        let seconds = last.at.timeIntervalSince(base.at)
        guard seconds > 0 else { return 0 }
        return Double(last.produced - base.produced) / seconds
    }

    /// Réessaie `body` toutes les `flushRetryDelay` secondes tant qu'il rend
    /// `false` (le verrou est tenu par un autre processus), pendant `patience`
    /// au plus. Rend `false` si l'ANNULATION a coupé l'attente, et propage
    /// toute erreur qui n'est pas un verrou.
    ///
    /// Le sommeil est découpé en tranches de `napSlice` : la pompe voyait
    /// jusque-là un Ctrl-C au bout de 10 s au mieux, de 15 min au pire.
    private static func patiently(_ config: Config, _ what: String,
                                  patience: TimeInterval,
                                  shouldStop: () -> Bool,
                                  _ body: () throws -> Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(patience)
        var attempt = 0
        while true {
            if try body() { return true }
            attempt += 1
            guard Date() < deadline else {
                config.log("vectors: \(what) failed after "
                           + "\(format(patience)) — giving up")
                return false
            }
            if attempt == 1 || attempt % 6 == 0 {
                config.log("vectors: \(what) postponed — the lock is held by "
                           + "another process (the agent, most likely), trying "
                           + "again every \(Int(flushRetryDelay)) s")
            }
            guard nap(min(flushRetryDelay, deadline.timeIntervalSinceNow),
                      shouldStop: shouldStop) else { return false }
        }
    }

    /// Exécute une écriture. Rend `false` si le VERROU d'écriture est tenu par
    /// un autre processus (attendre est la bonne réponse), et PROPAGE toute
    /// autre panne — disque plein, base corrompue (audit X3).
    private static func unlessLocked(_ body: () throws -> Void) throws -> Bool {
        do { try body(); return true }
        catch let error where WriteLock.isBusy(error) { return false }
    }

    /// Dort au plus `seconds`, par tranches de `napSlice`, en s'interrompant dès
    /// que `shouldStop()` est vrai. Rend `false` si l'annulation a été demandée.
    private static func nap(_ seconds: TimeInterval,
                            shouldStop: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while true {
            if shouldStop() { return false }
            let left = end.timeIntervalSinceNow
            guard left > 0 else { return true }
            Thread.sleep(forTimeInterval: min(napSlice, left))
        }
    }

    private static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s >= 3600 { return "\(s / 3600) h \((s % 3600) / 60) min" }
        if s >= 60 { return "\(s / 60) min \(s % 60) s" }
        return "\(s) s"
    }
}
