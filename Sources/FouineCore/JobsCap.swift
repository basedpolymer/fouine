// JobsCap.swift — plafond commun de `--jobs`. Propriété : A-Core, audit X1.
//
// L'OCR se bornait déjà (`OCRRun.clampJobs`, §6.3) et l'agent aussi
// (`AgentPaths.extractJobs`, borné à 4 par construction) ; l'extraction de la
// CLI, non : `fouine extract --jobs 32` ouvrait 32 opérations concurrentes.
//
// Ce n'est pas la même mesure qui borne les deux passes :
//   · l'OCR est borné par le DÉBIT — 8 fils rendent 0,576 p/s contre 0,699 à
//     4 fils (§6.3) : une RÉGRESSION, pas un plateau ;
//   · l'extraction est bornée par la MÉMOIRE — 279 Mo par fil PDFKit (mesuré,
//     §6.1) plus jusqu'à 128 Mio par worker bsdtar
//     (`Bsdtar.maxDecompressedBytes`), soit environ 410 Mo par job dans le pire
//     cas. 4 jobs ≈ 1,6 Go de pics simultanés, ce que le Mac de référence
//     (Intel i5) encaisse ; 16 jobs ≈ 6,5 Go, c'est le swap et une passe qui
//     n'avance plus.
//
// Le plafond retenu est donc le même — 4 —, pour deux raisons différentes, et
// aucune des deux n'est un refus : une demande hors plafond est TRONQUÉE avec
// un avertissement, jamais rejetée.

import Foundation

public enum JobsCap {

    /// Plafond de la passe d'extraction (CLI et tout appelant qui prend un
    /// `--jobs` d'extraction).
    public static let extractMaxJobs = 4

    /// Ramène `jobs` dans `[1, cap]`, en journalisant la troncature.
    /// `reason` dit POURQUOI ce plafond-là : sans elle, un utilisateur qui voit
    /// sa demande ramenée de 16 à 4 croit à une limitation arbitraire.
    public static func clamp(_ jobs: Int, max cap: Int, reason: String,
                             log: (String) -> Void) -> Int {
        if jobs > cap {
            log("--jobs \(jobs) capped to \(cap): \(reason)")
            return cap
        }
        if jobs < 1 {
            log("--jobs \(jobs) raised to 1")
            return 1
        }
        return jobs
    }

    /// Plafond d'extraction, message compris.
    public static func clampExtract(_ jobs: Int,
                                    log: (String) -> Void = { print($0) }) -> Int {
        clamp(jobs, max: extractMaxJobs,
              reason: "279 MB per PDFKit thread and up to 128 MiB per bsdtar "
                    + "worker, i.e. ~1.6 GB of peaks at 4 threads (X1)",
              log: log)
    }
}
