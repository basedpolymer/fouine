// Subprocess.swift — lancement d'un outil externe, stdout et stderr capturés.
// Propriété : A-Ingest.
//
// QUATRE APPELANTS, ET PAS UN DE PLUS — c'est ici qu'on vient lire quelle
// surface externe existe, et l'en-tête est resté faux jusqu'au 10/09/2026
// (constat CM-35, deux appelants annoncés depuis le lot INT-F3) :
//   · /usr/bin/bsdtar (§5.3, voie imposée pour toute archive) ;
//   · djvused s'il est installé (§5.3) ;
//   · ffmpeg (`MediaDecoder.convert`) et ffprobe (`MediaMetadata.probe`), pour
//     les conteneurs qu'AVFoundation n'ouvre pas — les deux reçoivent
//     `-protocol_whitelist file`, sans quoi une playlist déguisée en `.mkv`
//     ferait ouvrir une adresse réseau à l'outil (CM-23).
// Les quatre sont cherchés par CHEMINS EXPLICITES et non dans le PATH depuis
// l'audit D8, voir `tool(_:)`. Aucun autre outil n'est invoqué, et rien n'est
// jamais écrit dans le corpus.
//
// TROIS garde-fous, tous OBLIGATOIRES parce que ni la sortie ni l'environnement
// d'un outil externe ne sont bornés par le fichier source :
//   · un PLAFOND D'OCTETS sur stdout (A11.2) — `FileGuard` ne voit que la taille
//     COMPRESSÉE d'une archive, et une entrée de 1,8 Mo peut se décompresser en
//     645 Mo. Au-delà du plafond le processus est tué et l'erreur est explicite ;
//   · un DÉLAI DE GARDE (A11.7) — un bsdtar bloqué gelait un worker et, la file
//     d'extraction attendant `waitUntilAllOperationsAreFinished`, la commande
//     entière. SIGTERM puis SIGKILL après un délai de grâce ;
//   · un ENVIRONNEMENT FIGÉ (S1, D8) — l'enfant n'hérite plus RIEN du père, ni
//     son PATH ni sa locale. Voir `childEnvironment` : ce n'est pas seulement
//     un durcissement, c'est ce qui rend les noms d'entrées accentués lisibles
//     depuis l'app et depuis l'agent.

import Foundation
import FouineCore

enum Subprocess {
    /// Plafond de stdout par défaut. Cohérent avec `Bsdtar.maxDecompressedBytes`
    /// (le seul appelant qui manipule des volumes) : 128 Mio, soit huit fois le
    /// plus gros conteneur du corpus une fois décompressé.
    static let defaultMaxOutputBytes = 128 << 20

    /// stderr ne porte qu'un message d'erreur : 64 Kio en couvrent largement les
    /// plus bavards, et l'excédent est jeté SANS interrompre l'outil.
    static let maxErrorBytes = 64 << 10

    /// Délai de garde par défaut. Étalon mesuré sur le corpus : le plus gros djvu
    /// (Huheey 1997, 1 049 pages) rend sa couche texte en 2,3 s pour 2,7 Mo, et
    /// le listage de la plus grosse archive prend 0,01 s. 60 s laissent donc un
    /// facteur 25 au pire cas connu.
    static let defaultTimeout: TimeInterval = 60

    /// Grâce laissée entre SIGTERM et SIGKILL, et plafond d'attente des lecteurs
    /// de tuyau une fois le processus terminé.
    static let terminationGrace: TimeInterval = 5

    /// ENVIRONNEMENT FIGÉ de tous les enfants (audit S1 et D8).
    ///
    /// `process.environment` n'était jamais posé : l'outil héritait de TOUT ce que
    /// portait le processus père — un PATH inscriptible sans root, la locale du
    /// terminal, et n'importe quelle variable que libarchive ou djvulibre lisent.
    /// L'enfant ne reçoit plus que ces trois-là.
    ///
    /// La locale n'est pas un détail cosmétique, c'est un CORRECTIF. Mesuré sur un
    /// zip contenant l'entrée « café/élève-œuvre.txt » (bsdtar 3.5.3 /
    /// libarchive 3.7.4) :
    ///   · environnement vide — le cas EXACT d'un agent launchd sans
    ///     `EnvironmentVariables` et d'une app lancée par le Finder — `bsdtar -tf`
    ///     rend « cafe\314\201/e\314\201le\314\200ve-\305\223uvre.txt », octal
    ///     littéral, que le `-xOf` suivant refuse (« Not found in archive ») ;
    ///   · `LANG=C`/`LC_ALL=C` : MÊME mutilation ;
    ///   · `C.UTF-8` : nom exact, extraction rc 0.
    /// Toute archive à entrée accentuée était donc illisible depuis l'app et
    /// l'agent, et lisible depuis le Terminal. C.UTF-8 existe sur macOS
    /// (`locale -a`) et donne l'indépendance de locale AVEC l'UTF-8 : c'est la
    /// seule valeur qui satisfasse les deux exigences.
    static let childEnvironment: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
    ]

    /// Répertoires où chercher un outil externe NON SYSTÈME (D8). La liste vit
    /// dans `ExternalTool` depuis le lot K6 : le crawl en a besoin lui aussi,
    /// pour savoir si l'outil qui manquait est apparu (constat A3-05), et il
    /// n'a pas FouineExtract dans ses dépendances.
    static let toolSearchPaths = ExternalTool.searchPaths

    /// Sortie complète d'un outil : stdout, et stderr MÊME QUAND rc = 0.
    ///
    /// stderr n'était lu que pour composer le message d'un code retour non nul,
    /// et jeté sinon (A11.11) : un outil qui avertit puis réussit — bsdtar sur une
    /// archive tronquée, djvused sur une page abîmée — ne laissait aucune trace.
    /// Il est désormais rendu à l'appelant, tronqué à `maxErrorBytes`, pour
    /// enrichir les diagnostics.
    struct Output {
        let stdout: Data
        /// stderr tronqué et détouré ; vide si l'outil n'a rien dit.
        let stderr: String
    }

    /// Lance `executable`, rend stdout. Code retour non nul -> FouineError.extraction
    /// portant le message de stderr. Dépassement du plafond ou du délai ->
    /// FouineError.extraction, processus tué.
    static func run(_ executable: String, _ arguments: [String],
                    what: String,
                    maxOutputBytes: Int = defaultMaxOutputBytes,
                    timeout: TimeInterval = defaultTimeout,
                    grace: TimeInterval = terminationGrace) throws -> Data {
        try capture(executable, arguments, what: what,
                    maxOutputBytes: maxOutputBytes, timeout: timeout,
                    grace: grace).stdout
    }

    /// Identique à `run`, mais rend AUSSI le stderr d'une exécution réussie.
    static func capture(_ executable: String, _ arguments: [String],
                        what: String,
                        maxOutputBytes: Int = defaultMaxOutputBytes,
                        timeout: TimeInterval = defaultTimeout,
                        grace: TimeInterval = terminationGrace) throws -> Output {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw FouineError.extraction("tool not found: \(executable)")
        }
        let tool = (executable as NSString).lastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = childEnvironment
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Les deux tuyaux se lisent en parallèle : une archive volumineuse remplit
        // le tampon de stdout pendant que l'outil écrit sur stderr, et l'inverse.
        // La lecture se fait PAR MORCEAUX, jamais d'un bloc : c'est ce qui permet
        // de s'arrêter — et d'arrêter l'outil — au premier octet de trop.
        let box = OutputBox()
        let killer = ProcessBox(process)
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) {
            let data = drain(outPipe.fileHandleForReading, cap: maxOutputBytes,
                             stopOnOverflow: true) {
                box.markOverflow()
                killer.terminate()
            }
            box.setOut(data)
        }
        DispatchQueue.global(qos: .utility).async(group: group) {
            // stderr : on cesse d'ACCUMULER mais on continue de VIDER le tuyau,
            // sans quoi un outil très bavard se bloquerait sur son écriture.
            box.setErr(drain(errPipe.fileHandleForReading, cap: maxErrorBytes,
                             stopOnOverflow: false, onOverflow: {}))
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            // Sans processus pour les fermer, les extrémités d'écriture resteraient
            // ouvertes et les deux lecteurs attendraient une fin de fichier qui ne
            // viendrait jamais.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            throw FouineError.extraction(
                "\(executable) could not start (\(what)): "
                + (error as NSError).localizedDescription)
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            killer.terminate()                              // SIGTERM
            if finished.wait(timeout: .now() + grace) == .timedOut {
                killer.kill()                               // puis SIGKILL
                _ = finished.wait(timeout: .now() + grace)
            }
        }
        // Les lecteurs finissent à la fermeture des tuyaux, donc à la mort du
        // processus ; l'attente reste bornée pour ne jamais geler un worker.
        _ = group.wait(timeout: .now() + grace)

        if timedOut {
            throw FouineError.extraction(
                "\(tool) did not return within \(Int(timeout)) s (\(what)): "
                + "process terminated")
        }
        if box.overflowed {
            throw FouineError.extraction(
                "output too large (\(what)): \(tool) went past "
                + "\(maxOutputBytes >> 20) MiB and was terminated")
        }
        let message = String(decoding: box.err, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw FouineError.extraction(
                "\(tool) failed (\(what), "
                + "code \(process.terminationStatus)): "
                + (message.isEmpty ? "no message" : message))
        }
        return Output(stdout: box.out, stderr: message)
    }

    /// Vide un tuyau par morceaux, en n'accumulant que `cap` octets. Rend le
    /// contenu tronqué ; `onOverflow` est appelé UNE fois, au premier octet de
    /// trop.
    private static func drain(_ handle: FileHandle, cap: Int,
                              stopOnOverflow: Bool,
                              onOverflow: () -> Void) -> Data {
        var data = Data()
        var overflowed = false
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }              // fin de fichier
            if overflowed { continue }              // on vide sans accumuler
            let room = cap - data.count
            if chunk.count > room {
                if room > 0 { data.append(chunk.prefix(room)) }
                overflowed = true
                onOverflow()
                if stopOnOverflow { break }
            } else {
                data.append(chunk)
            }
        }
        return data
    }

    /// Chemin d'un outil externe non système. Simple façade sur
    /// `ExternalTool.path` : le comportement (chemins explicites, override en
    /// dernier) et sa justification sont documentés là-bas, en un seul endroit.
    static func tool(_ name: String,
                     overrideVariable: String? = nil,
                     directories: [String] = toolSearchPaths,
                     environment: [String: String]
                        = ProcessInfo.processInfo.environment,
                     fileManager: FileManager = .default) -> String? {
        ExternalTool.path(name, overrideVariable: overrideVariable,
                          directories: directories, environment: environment,
                          fileManager: fileManager)
    }

    /// Sortie texte d'un outil SYSTÈME, ou `nil` si quoi que ce soit cloche.
    ///
    /// Contrat volontairement pauvre : l'appelant ne veut pas savoir POURQUOI
    /// `pmset` n'a pas répondu, il veut seulement ne pas rester pendu à
    /// l'attendre. `nil` = « illisible », et le garde-fou thermique se désactive
    /// en le disant, exactement comme aujourd'hui quand `pmset` est absent.
    static func text(_ executable: String, _ arguments: [String],
                     what: String, timeout: TimeInterval) -> String? {
        guard let data = try? run(executable, arguments, what: what,
                                  maxOutputBytes: 1 << 20, timeout: timeout)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Petit tampon verrouillé : les deux lectures de tuyau tournent sur des files
    /// distinctes et écrivent chacune la sienne.
    final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data()
        private var errData = Data()
        private var overflow = false
        func setOut(_ d: Data) { lock.lock(); outData = d; lock.unlock() }
        func setErr(_ d: Data) { lock.lock(); errData = d; lock.unlock() }
        func markOverflow() { lock.lock(); overflow = true; lock.unlock() }
        var out: Data { lock.lock(); defer { lock.unlock() }; return outData }
        var err: Data { lock.lock(); defer { lock.unlock() }; return errData }
        var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
    }

    /// Le processus est tué depuis la file de lecture (dépassement du plafond) ou
    /// depuis le fil appelant (délai de garde) : les deux passages sont sérialisés
    /// et `terminate()` sur un processus déjà mort lève une exception ObjC.
    final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        init(_ process: Process) { self.process = process }

        func terminate() {
            lock.lock(); defer { lock.unlock() }
            if process.isRunning { process.terminate() }
        }

        func kill() {
            lock.lock(); defer { lock.unlock() }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

// MARK: - Façade publique (audit F6)

/// Le SEUL point d'entrée public de `Subprocess`, pour les modules qui ont
/// besoin de lancer un outil système sans lui laisser la possibilité de geler
/// leur fil.
///
/// POURQUOI IL EXISTE. `pmset -g therm` était lancé par un `Process()` nu, dans
/// `FouineOCR/ThermalGovernor` et dans `FouineAgent/AgentConditions` : pas de
/// délai de garde, pas d'environnement figé, un `readDataToEndOfFile()` suivi
/// d'un `waitUntilExit()` — deux attentes non bornées à la suite. Un `pmset` qui
/// ne rend pas la main (IOKit occupé, machine qui sort de veille) gelait le
/// gouverneur thermique, donc la pompe OCR, donc l'agent (audit F6).
///
/// `Subprocess` lui-même reste `internal` : c'est la voie imposée de bsdtar et
/// de djvused (§5.3), avec ses plafonds d'octets et ses règles d'archive, et
/// rien de tout cela n'a de sens hors de FouineExtract. Ce qui se partage, ce
/// n'est pas l'outil d'extraction : c'est le lancement BORNÉ.
public enum BoundedTool {

    /// Délai des sondes système : 5 s. `pmset -g therm` répond en 0,02 s mesuré
    /// sur cette machine ; 5 s laissent un facteur 250 avant de conclure que la
    /// sonde est illisible. Court à dessein — un thermomètre interrogé toutes
    /// les minutes n'a aucune raison de faire attendre qui que ce soit.
    public static let probeTimeout: TimeInterval = 5

    /// Lance `executable` et rend sa sortie standard en texte ; `nil` si l'outil
    /// est absent, s'il échoue, ou s'il n'a pas rendu la main dans le délai —
    /// auquel cas il est interrompu (SIGTERM puis SIGKILL).
    ///
    /// - Parameters:
    ///   - executable: chemin ABSOLU. Jamais un nom cherché dans `PATH` (D8).
    ///   - what: ce qu'on cherchait, pour les journaux de l'appelant.
    public static func text(_ executable: String, _ arguments: [String],
                            what: String,
                            timeout: TimeInterval = probeTimeout) -> String? {
        Subprocess.text(executable, arguments, what: what, timeout: timeout)
    }
}
