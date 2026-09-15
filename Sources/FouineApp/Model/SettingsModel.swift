// SettingsModel.swift — l'état de la fenêtre de réglages ⌘, (audit U2). A-App.
//
// Tout ce que la fenêtre écrit va dans la table `settings` (schéma v4), PAS
// dans `UserDefaults` : l'agent launchd ne partage pas le domaine de
// préférences de l'app, et c'est précisément l'agent qu'il s'agit de régler.
// `Prefs` (UserDefaults) reste pour ce qui est purement d'interface — historique
// de recherche, mode flou, interrupteur sémantique.
//
// TROIS PRÉCAUTIONS D'INTERFACE :
//
//   1. Les écritures partent HORS DU FIL PRINCIPAL. Une écriture de réglage ne
//      prend pas `fouine.lock` (voir `GRDBStore+Settings.swift`), mais elle
//      passe par SQLite, dont le `busy_timeout` est de 5 s : cinq secondes de
//      roue qui tourne dans une fenêtre de réglages seraient inacceptables.
//
//   2. La valeur affichée est la valeur EFFECTIVE, avec sa provenance. Une clé
//      forcée par une variable d'environnement est montrée en lecture seule et
//      le dit : sans cela, l'utilisateur saisirait une valeur, la verrait
//      revenir à l'ancienne, et conclurait que la fenêtre est cassée.
//
//   3. Épingler une racine RE-PRIORISE les pages déjà en file, dans le même
//      geste. C'est la seule écriture de cette fenêtre qui prenne
//      `fouine.lock` — c'est un `UPDATE ocr_queue` —, et donc la seule qui
//      puisse échouer parce que l'agent travaille. On le dit alors, avec le nom
//      du détenteur (audit F3), au lieu de laisser croire que rien n'a bougé.

import Foundation
import SwiftUI
import AppKit
import FouineCore
import FouineIndex
import FouineOCR

@MainActor
final class SettingsModel: ObservableObject {

    private let service: StoreService
    private var settings: FouineCore.Settings?

    /// Valeurs effectives, par clé. Rechargées à chaque apparition de la
    /// fenêtre et après chaque écriture.
    @Published private(set) var values: [String: String] = [:]
    @Published private(set) var sources: [String: SettingSource] = [:]
    /// Dernier message à afficher (échec d'écriture, re-priorisation réussie).
    @Published var notice: String?
    /// Le titre de l'alerte qui porte `notice`. Nil = « Réglages ».
    ///
    /// Une alerte de Spotlight titrée « Réglages » ne dit pas de quoi elle
    /// parle : on demandait un retrait et on lisait « Réglages / Spotlight est
    /// à jour » (audit BU-25). Le titre nomme donc ce dont il s'agit.
    @Published var noticeTitle: String?
    /// Langues de reconnaissance disponibles SUR CETTE MACHINE. Lues une fois :
    /// `supportedRecognitionLanguages` instancie une requête Vision.
    @Published private(set) var availableOCRLanguages: [String] = []

    init(service: StoreService) {
        self.service = service
    }

    // MARK: - Chargement

    func load() async {
        let store = service.store
        if settings == nil {
            // TTL court : la fenêtre est ouverte quelques secondes, et l'agent
            // ou `fouine config set` peuvent écrire pendant ce temps.
            settings = FouineCore.Settings(store: store, ttl: 1)
        }
        guard let settings else { return }
        let snapshot = await Task.detached(priority: .userInitiated) {
            settings.reload()
        }.value
        apply(snapshot)

        if availableOCRLanguages.isEmpty {
            availableOCRLanguages = await Task.detached(priority: .userInitiated) {
                VisionOCREngine.supportedLanguages()
            }.value
        }
        await loadSpotlightHandover()
    }

    private func apply(_ snapshot: SettingsSnapshot) {
        var values: [String: String] = [:]
        var sources: [String: SettingSource] = [:]
        for entry in snapshot.table() {
            values[entry.spec.key] = entry.value
            sources[entry.spec.key] = entry.source
        }
        self.values = values
        self.sources = sources
    }

    // MARK: - Lecture typée

    func string(_ spec: SettingSpec) -> String { values[spec.key] ?? spec.fallback }

    func int(_ spec: SettingSpec) -> Int {
        Int(string(spec)) ?? Int(spec.fallback) ?? 0
    }

    func bool(_ spec: SettingSpec) -> Bool {
        SettingSpec.boolean(string(spec)) ?? false
    }

    func list(_ spec: SettingSpec) -> [String] {
        SettingSpec.tokens(string(spec))
    }

    func identifiers(_ spec: SettingSpec) -> Set<Int64> {
        Set(list(spec).compactMap(Int64.init))
    }

    /// Une clé forcée par l'environnement ne s'écrit pas : le contrôle est
    /// désactivé, et l'aide dit pourquoi.
    func isOverridden(_ spec: SettingSpec) -> Bool {
        sources[spec.key] == .environment
    }

    /// Le résumé d'un réglage, DANS LA LANGUE DE L'UTILISATEUR.
    ///
    /// `SettingSpec.summary` (FouineCore) reste la phrase anglaise qu'imprime
    /// `fouine config list` ; la fenêtre de réglages, elle, part de la CLÉ.
    /// Une clé que ce tableau ne connaît pas retombe sur `summary` — un réglage
    /// ajouté au cœur reste donc lisible plutôt qu'invisible.
    ///
    /// CES PHRASES SONT DES INFO-BULLES, PAS DES LIGNES DE COMMANDE (audit
    /// AP-14, BU-11). Elles disaient « Durée d'un lot d'OCR de l'agent… les
    /// conditions du §5.7 », « Identifiants des racines prioritaires pour
    /// l'OCR », « Fils d'extraction de l'agent d'arrière-plan », « codes
    /// BCP-47 » : les résumés de la CLI recopiés dans une fenêtre destinée à
    /// des gens qui n'ouvrent pas de terminal. Le vocabulaire de la CLI n'a pas
    /// bougé — `SettingSpec.summary` est intact —, seule la phrase de l'app
    /// change, et `SettingsSummaryTests` interdit désormais les mots de métier.
    static func summary(_ spec: SettingSpec) -> String {
        switch spec.key {
        case SettingKeys.ocrLanguages.key:
            return String(localized: "Languages Fouine expects on scanned pages, most likely first.")
        case SettingKeys.ocrJobs.key:
            return String(localized: "How many scanned pages are read at once (1 to 4; beyond that, fewer pages get read, not more).")
        case SettingKeys.extractJobs.key:
            return String(localized: "How many documents are read at once when you ask Fouine to update the index (1 to 4).")
        case SettingKeys.extractImages.key:
            return String(localized: "Index the images of the watched folders (photos, scans, Photoshop and camera RAW files) and read the text on them.")
        case SettingKeys.extractMedia.key:
            return String(localized: "Index audio and video files: their titles, artists, albums, descriptions, lyrics and chapters.")
        case SettingKeys.extractTranscribe.key:
            return String(localized: "Write down what is said in audio and video files, on this Mac. Slow, and needs a Dictation language installed.")
        case SettingKeys.transcribeMaxMinutes.key:
            return String(localized: "Longest recording Fouine will write down, in minutes. Beyond it, only the title and the chapters are indexed.")
        case SettingKeys.agentExtractJobs.key:
            return String(localized: "How many documents are read at once in the background (2 by default, so the Mac stays responsive).")
        case SettingKeys.agentOCRBudgetMinutes.key:
            return String(localized: "How long each batch of scanned pages lasts, in minutes. Fouine checks that the Mac is free before each batch.")
        case SettingKeys.agentPollSeconds.key:
            return String(localized: "How often Fouine looks for new documents and checks the conditions above, in seconds.")
        case SettingKeys.agentRequireAC.key:
            return String(localized: "Read scanned pages only when the Mac is plugged in. Unticked, Fouine reads them on battery too, and drains it.")
        case SettingKeys.agentPauseOnLowPower.key:
            return String(localized: "Stop reading scanned pages while Low Power Mode is on.")
        case SettingKeys.agentPauseOnThermal.key:
            return String(localized: "Stop reading scanned pages while the Mac is hot, and start again once it has cooled down.")
        case SettingKeys.agentPrepareMeaning.key:
            return String(localized: "Prepare search by meaning little by little in the background, once every scanned page has been read.")
        case SettingKeys.agentEmbedBudgetMinutes.key:
            return String(localized: "How long each stretch of that preparation lasts, in minutes.")
        // — Recherche par le sens (lot MC3). Le mot « tableur » se dit à des
        // gens qui n'ouvrent pas de terminal ; « vecteur » ne s'y dit jamais.
        case SettingKeys.embedSkipSpreadsheets.key:
            return String(localized: "Leave spreadsheets out of search by meaning: a page of figures teaches it nothing, and those pages stay findable word for word.")
        case SettingKeys.pinnedRoots.key:
            return String(localized: "The scanned pages of this folder are read before those of the other folders.")
        case SettingKeys.notifyOnQueueDrained.key:
            return String(localized: "Fouine tells you when the last scanned page has been read (Fouine must be open).")
        // — Spotlight (lot INT-S1). En FIN de tableau, comme les clés au cœur.
        case SettingKeys.spotlightEnabled.key:
            return String(localized: "Show the documents Fouine has read in Spotlight, the magnifying glass at the top right of the screen.")
        case SettingKeys.spotlightAllDocuments.key:
            return String(localized: "Show every document, and not only the ones Spotlight cannot read on its own.")
        case SettingKeys.spotlightTextKB.key:
            return String(localized: "How much text of each document is given to Spotlight, in kilobytes (64 to 4096).")
        // — Sources applicatives (lot INT-F4), en FIN de tableau comme au cœur.
        case SettingKeys.sourceNotes.key:
            return String(localized: "Search the notes of Apple Notes: Fouine copies their text into its own folder on this Mac.")
        case SettingKeys.sourceBear.key:
            return String(localized: "Search the notes of Bear: Fouine copies their text into its own folder on this Mac.")
        case SettingKeys.sourceAnki.key:
            return String(localized: "Search your Anki flashcards: Fouine copies their text into its own folder on this Mac, one file per deck.")
        default:
            return spec.summary
        }
    }

    func help(_ spec: SettingSpec) -> String {
        let summary = Self.summary(spec)
        guard isOverridden(spec), let name = spec.environmentVariable else {
            return summary
        }
        return String(localized: "\(summary)\n\nForced by the environment variable \(name): this value cannot be changed here while the variable is set.")
    }

    // MARK: - Écriture

    func set(_ spec: SettingSpec, _ raw: String) {
        guard let settings, !isOverridden(spec) else { return }
        let key = spec.key
        Task { [weak self] in
            let outcome: Result<SettingsSnapshot, Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        _ = try settings.set(key, raw)
                        return .success(settings.reload())
                    } catch {
                        return .failure(error)
                    }
                }.value
            guard let self else { return }
            switch outcome {
            case .success(let snapshot):
                self.apply(snapshot)
                self.noticeTitle = nil
                self.notice = nil
            case .failure(let error):
                self.noticeTitle = nil
                self.notice = ErrorText.describe(error)
            }
        }
    }

    func setBool(_ spec: SettingSpec, _ value: Bool) {
        set(spec, value ? "true" : "false")
    }

    func setInt(_ spec: SettingSpec, _ value: Int) { set(spec, String(value)) }

    func setList(_ spec: SettingSpec, _ values: [String]) {
        set(spec, values.joined(separator: ","))
    }

    // MARK: - Racines épinglées (audit F4)

    func isPinned(_ rootID: Int64) -> Bool {
        identifiers(SettingKeys.pinnedRoots).contains(rootID)
    }

    /// Épingle (ou dépingle) une racine ET re-priorise les pages DÉJÀ en file.
    ///
    /// Les deux vont ensemble : sur la base de l'auteur, 34 000 pages attendent
    /// depuis des jours, et cocher « Prioritaire pour l'OCR » sans rien changer
    /// à la file serait une case sans effet visible avant la prochaine
    /// extraction — c'est-à-dire, pour un corpus stable, jamais.
    func setPinned(_ rootID: Int64, _ pinned: Bool) {
        guard let settings else { return }
        var ids = identifiers(SettingKeys.pinnedRoots)
        if pinned { ids.insert(rootID) } else { ids.remove(rootID) }
        let value = ids.sorted().map(String.init).joined(separator: ",")
        let store = service.store

        Task { [weak self] in
            let outcome: Result<(SettingsSnapshot, Int), Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        _ = try settings.set(SettingKeys.pinnedRoots.key, value)
                        let snapshot = settings.reload()
                        // Le `UPDATE ocr_queue` prend `fouine.lock` : il peut
                        // échouer si l'agent OCRise. Le réglage, lui, est déjà
                        // écrit — la prochaine extraction l'appliquera.
                        let touched = try OCRPriority.repriorize(
                            store: store, rootID: rootID, pinned: pinned)
                        return .success((snapshot, touched))
                    } catch {
                        return .failure(error)
                    }
                }.value
            guard let self else { return }
            switch outcome {
            case .success(let (snapshot, touched)):
                self.apply(snapshot)
                self.noticeTitle = nil
                self.notice = touched > 0
                    ? (pinned
                       ? String(localized: "\(touched) page(s) already queued now go first.")
                       : String(localized: "\(touched) page(s) already queued get their priority back."))
                    : nil
            case .failure(let error):
                // Le réglage a pu être écrit et la re-priorisation échouer : on
                // recharge pour montrer l'état réel, et on nomme la cause.
                await self.load()
                self.noticeTitle = nil
                self.notice = String(localized: "Setting saved, but the pages already waiting keep their old order: \(ErrorText.describe(error)) The next update will read this folder first.")
            }
        }
    }

    // MARK: - Spotlight (lot INT-S1)

    /// Fouine peut-elle parler à Spotlight depuis ce processus ?
    ///
    /// Hors bundle (`swift run FouineApp`), non : la section reste affichée
    /// mais désactivée, avec l'aide qui dit pourquoi — la faire disparaître
    /// laisserait croire que le produit ne sait pas le faire (même règle que
    /// « Ouvrir Fouine à l'ouverture de session »).
    var spotlightAvailable: Bool { SpotlightDonor().isAvailable }

    var spotlightHelp: String {
        spotlightAvailable
            ? String(localized: "Your documents stay where they are. Spotlight keeps its list on this Mac.")
            : String(localized: "Only available from the installed application: “swift run FouineApp” cannot talk to Spotlight.")
    }

    /// Vrai pendant une remise : les deux boutons attendent leur tour.
    @Published private(set) var spotlightWorking = false

    /// La politique telle que la fenêtre l'affiche EN CE MOMENT.
    ///
    /// Elle est calculée ici, sur le fil principal, et transmise à la remise —
    /// plutôt que relue dans la base par le fil de travail. La raison est une
    /// course : l'écriture d'un réglage part elle aussi dans une tâche
    /// détachée, et une remise qui relirait la table pourrait y voir la valeur
    /// d'AVANT le clic — donc allumer Spotlight et ne rien donner.
    private func currentSpotlightPolicy(enabled: Bool? = nil,
                                        allDocuments: Bool? = nil) -> SpotlightPolicy {
        SpotlightPolicy(
            enabled: enabled ?? bool(SettingKeys.spotlightEnabled),
            allDocuments: allDocuments ?? bool(SettingKeys.spotlightAllDocuments),
            textKB: int(SettingKeys.spotlightTextKB))
    }

    /// La case « Montrer les documents de Fouine dans Spotlight ».
    ///
    /// Allumer redonne tout ; éteindre retire tout. Sans cela, décocher la
    /// case laisserait les documents dans Spotlight jusqu'à la fin des temps —
    /// un interrupteur qui n'éteint rien.
    func setSpotlightEnabled(_ on: Bool) {
        guard !isOverridden(SettingKeys.spotlightEnabled) else { return }
        setBool(SettingKeys.spotlightEnabled, on)
        if on {
            rebuild(policy: currentSpotlightPolicy(enabled: true), announce: nil)
        } else {
            removeFromSpotlight(announce: nil)
        }
    }

    /// Change la PORTÉE, puis redonne tout.
    ///
    /// Les deux vont ensemble, et c'est le même raisonnement que pour une
    /// racine épinglée : passer de « tout » à « seulement les scans » sans
    /// rien faire d'autre laisserait dans Spotlight des centaines de documents
    /// que l'utilisateur vient de décocher — un réglage sans effet visible est
    /// un réglage auquel personne ne croit.
    func setSpotlightAllDocuments(_ all: Bool) {
        guard !isOverridden(SettingKeys.spotlightAllDocuments) else { return }
        setBool(SettingKeys.spotlightAllDocuments, all)
        rebuild(policy: currentSpotlightPolicy(allDocuments: all), announce: nil)
    }

    /// « Mettre Spotlight à jour » : on efface tout ce que Fouine avait donné,
    /// puis on redonne. C'est aussi le seul geste qui retire les documents
    /// supprimés depuis — la base ne garde aucune trace d'une suppression.
    func refreshSpotlight() {
        rebuild(policy: currentSpotlightPolicy(),
                announce: String(localized: "Spotlight is up to date."))
    }

    private func rebuild(policy: SpotlightPolicy, announce: String?) {
        perform(announce: announce) { store in
            _ = try SpotlightSync.run(store: store, policy: policy,
                                      donor: SpotlightDonor(), fullRebuild: true)
        }
    }

    /// « Retirer les documents de Fouine de Spotlight ». Le marqueur repart à
    /// zéro : si l'utilisateur rallume la case, tout sera redonné.
    ///
    /// L'annonce dit le RETRAIT. Elle disait « Spotlight est à jour » — le
    /// message du bouton voisin —, si bien qu'on demandait un retrait et qu'on
    /// lisait une mise à jour (audit BU-25).
    func removeFromSpotlight(announce: String? = String(localized: "Fouine's documents have been removed from Spotlight.")) {
        perform(announce: announce) { store in
            try SpotlightDonor().deleteAll()
            try SpotlightSync.requestFullRebuild(store: store)
        }
    }

    // MARK: - La dernière remise, en clair (audit BU-26)

    /// Ce que la table dit de la dernière remise : sa date en secondes epoch
    /// (0 = jamais) et le nombre de documents donnés (0 = inconnu).
    @Published private(set) var spotlightHandover: (at: Double, count: Int) = (0, 0)

    /// Les deux marqueurs sont HORS du catalogue `all` : ils ne passent donc
    /// pas par `values`, et se lisent dans les lignes brutes.
    private func loadSpotlightHandover() async {
        let store = service.store
        let rows = await Task.detached(priority: .userInitiated) {
            (try? store.settingsRows()) ?? [:]
        }.value
        spotlightHandover = (
            at: Double(rows[SettingKeys.spotlightSyncedAt.key] ?? "") ?? 0,
            count: Int(rows[SettingKeys.spotlightSyncedCount.key] ?? "") ?? 0)
    }

    /// La phrase sous les deux boutons.
    ///
    /// Un don à Spotlight était invérifiable : `mdfind` ne voit pas ce que
    /// Fouine donne, le journal ne dit rien des succès, et le dossier de
    /// Spotlight est protégé. Ni l'utilisateur ni un dépanneur ne pouvaient
    /// savoir si la fonction marchait (audit BU-26). Une date et un compte
    /// suffisent — et sans compte (remise faite par une version antérieure à
    /// ce lot), la date seule vaut mieux que rien.
    static func handoverSummary(at seconds: Double, count: Int) -> String {
        guard seconds > 0 else {
            return String(localized: "Not handed over yet")
        }
        let when = Date(timeIntervalSince1970: seconds)
            .formatted(date: .abbreviated, time: .shortened)
        let line = String(localized: "Last handover on \(when)")
        guard count > 0 else { return line }
        return line + " · " + String(localized: "\(count) document(s)")
    }

    var spotlightHandoverSummary: String {
        Self.handoverSummary(at: spotlightHandover.at,
                             count: spotlightHandover.count)
    }

    /// Le travail part HORS DU FIL PRINCIPAL : une remise complète lit le texte
    /// de chaque document donné, et personne ne doit regarder une fenêtre de
    /// réglages figée pendant ce temps.
    private func perform(announce: String?,
                         _ work: @escaping @Sendable (GRDBStore) throws -> Void) {
        guard !spotlightWorking else { return }
        spotlightWorking = true
        let store = service.store
        Task { [weak self] in
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do { try work(store); return nil } catch {
                    return ErrorText.describe(error)
                }
            }.value
            guard let self else { return }
            self.spotlightWorking = false
            if let failure {
                self.noticeTitle = String(localized: "Spotlight")
                self.notice = String(localized: "Fouine could not update Spotlight (\(failure))")
            } else if let announce {
                self.noticeTitle = String(localized: "Spotlight")
                self.notice = announce
            }
            // La ligne « Dernière remise le… » se relit après CHAQUE geste :
            // c'est la seule preuve visible que quelque chose a eu lieu.
            await self.loadSpotlightHandover()
        }
    }

    // MARK: - Sources applicatives (lot INT-F4)

    /// Une source, telle que la fenêtre de réglages l'affiche.
    struct AppSourceState: Identifiable, Equatable {
        let id: String
        /// Nom de l'application, jamais traduit : « Apple Notes » s'appelle
        /// « Apple Notes » en français.
        let name: String
        let presence: SourcePresence
        let enabled: Bool
        /// Notes recopiées, telles qu'elles sont sur le disque.
        let notes: Int
    }

    @Published private(set) var appSources: [AppSourceState] = []
    /// Vrai pendant une recopie : les cases attendent leur tour.
    @Published private(set) var sourcesWorking = false

    /// L'état des sources, relu à chaque apparition de l'onglet.
    ///
    /// HORS DU FIL PRINCIPAL : `probe()` ouvre une base SQLite (celle d'une
    /// autre application, en lecture seule) et compte des fichiers. Quelques
    /// millisecondes, mais sur une base de notes volumineuse ou un disque
    /// réseau, personne ne doit regarder une fenêtre figée.
    func loadAppSources() async {
        let directory = FouinePaths.sourcesDirectory(for: AppPaths.databaseURL())
        let enabled = AppSources.all.map { source -> Bool in
            AppSources.settingKey(for: source.id).map { bool($0) } ?? false
        }
        appSources = await Task.detached(priority: .userInitiated) {
            AppSources.all.enumerated().map { index, source in
                let folder = directory.appendingPathComponent(source.rootLabel,
                                                              isDirectory: true)
                // C'est la source qui compte ses notes : un fichier par note
                // pour Notes et Bear, une page par carte pour Anki (lot AN1).
                return AppSourceState(
                    id: source.id, name: source.displayName,
                    presence: source.probe(), enabled: enabled[index],
                    notes: source.copiedNoteCount(in: folder))
            }
        }.value
    }

    /// La case « Rechercher aussi dans mes notes ».
    ///
    /// Allumer RECOPIE tout de suite, éteindre EFFACE tout de suite : même
    /// raisonnement que Spotlight et que les racines épinglées — un réglage
    /// sans effet visible est un réglage auquel personne ne croit. Et éteindre
    /// doit effacer les copies : les laisser ferait de la désactivation un
    /// demi-geste, avec des copies de notes personnelles oubliées sur le
    /// disque.
    func setAppSourceEnabled(_ id: String, _ on: Bool) {
        guard !sourcesWorking, let source = AppSources.source(id: id),
              let spec = AppSources.settingKey(for: id), !isOverridden(spec)
        else { return }
        setBool(spec, on)
        sourcesWorking = true
        let store = service.store
        let directory = FouinePaths.sourcesDirectory(for: AppPaths.databaseURL())

        Task { [weak self] in
            let failure: String? = await Task.detached(priority: .userInitiated) {
                if on {
                    let report = SourceSync.run(store: store, sources: [source],
                                                directory: directory)
                    return report.errors.first
                }
                return SourceSync.disable(source: source, store: store,
                                          directory: directory).error
            }.value
            guard let self else { return }
            self.sourcesWorking = false
            if let failure {
                self.noticeTitle = nil
                self.notice = String(localized: "Fouine could not read your notes (\(failure))")
            }
            await self.loadAppSources()
        }
    }

    /// Le geste à faire quand macOS refuse l'accès aux notes.
    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(AppPaths.privacyFullDiskPaneURL)
    }

    // MARK: - Langues OCR (audit X2)

    /// Les langues cochées, filtrées sur ce que la machine sait faire : un
    /// réglage hérité d'une autre machine (ou d'un `fouine config set` un peu
    /// large) ne doit pas afficher des cases qui n'existent pas.
    var selectedOCRLanguages: [String] {
        let wanted = list(SettingKeys.ocrLanguages)
        guard !availableOCRLanguages.isEmpty else { return wanted }
        let supported = Set(availableOCRLanguages.map { $0.lowercased() })
        return wanted.filter { supported.contains($0.lowercased()) }
    }

    /// Langues demandées mais absentes de cette machine. Affichées telles
    /// quelles : les taire ferait disparaître un réglage sans un mot.
    var unsupportedOCRLanguages: [String] {
        let wanted = list(SettingKeys.ocrLanguages)
        guard !availableOCRLanguages.isEmpty else { return [] }
        let supported = Set(availableOCRLanguages.map { $0.lowercased() })
        return wanted.filter { !supported.contains($0.lowercased()) }
    }

    func toggleOCRLanguage(_ language: String, _ on: Bool) {
        var wanted = list(SettingKeys.ocrLanguages)
        if on {
            guard !wanted.contains(where: { $0.lowercased() == language.lowercased() })
            else { return }
            wanted.append(language)
        } else {
            wanted.removeAll { $0.lowercased() == language.lowercased() }
            // Vider la liste ferait retomber la pompe sur le couple par défaut
            // sans que personne ne l'ait demandé : on refuse de décocher la
            // dernière langue plutôt que de mentir sur l'effet du geste.
            guard !wanted.isEmpty else {
                noticeTitle = nil
                notice = String(localized: "At least one recognition language is required.")
                return
            }
        }
        setList(SettingKeys.ocrLanguages, wanted)
    }

    /// Les langues de reconnaissance de cette machine, RANGÉES PAR LEUR NOM.
    ///
    /// L'ordre de Vision est celui des codes (`ar, ars, de, en, …`), ce qui
    /// donnait en français : Arabe, Arabe najdi, Allemand, Anglais… — une liste
    /// de dix-huit cases apparemment non triée (audit BU-09). On range donc par
    /// `localizedStandardCompare` du nom affiché, qui est celui que l'œil suit.
    var sortedOCRLanguages: [(code: String, name: String)] {
        availableOCRLanguages
            .map { (code: $0, name: OCRLanguageNames.display(identifier: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
