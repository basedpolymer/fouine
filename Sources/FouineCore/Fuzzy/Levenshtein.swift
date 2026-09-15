// Levenshtein.swift — distance exacte avec abandon anticipé (SPEC §5.5.2, P8).
// Propriété : A-Core.
//
// Budget : ≤ 10 ms par terme sur un vocabulaire d'un million d'entrées.
// D'où : deux lignes préallouées, aucune allocation dans la boucle, bande de
// largeur (2·max+1) et sortie dès que le minimum de la ligne dépasse le plafond.

import Foundation

struct LevenshteinScratch {
    private var previous: [Int]
    private var current: [Int]

    init(capacity: Int) {
        previous = [Int](repeating: 0, count: capacity + 1)
        current = [Int](repeating: 0, count: capacity + 1)
    }

    mutating func ensure(_ capacity: Int) {
        if previous.count < capacity + 1 {
            previous = [Int](repeating: 0, count: capacity + 1)
            current = [Int](repeating: 0, count: capacity + 1)
        }
    }

    /// Distance de `a` à `b`, ou `nil` si elle dépasse `maxDistance`.
    mutating func distance(_ a: [UInt32], _ b: [UInt32], maxDistance: Int) -> Int? {
        let n = a.count, m = b.count
        if abs(n - m) > maxDistance { return nil }
        if n == 0 { return m <= maxDistance ? m : nil }
        if m == 0 { return n <= maxDistance ? n : nil }
        ensure(max(n, m))

        for j in 0...m { previous[j] = j }

        for i in 1...n {
            current[0] = i
            let lo = max(1, i - maxDistance)
            let hi = min(m, i + maxDistance)
            if lo > 1 { current[lo - 1] = maxDistance + 1 }
            var rowMin = current[0]
            let ai = a[i - 1]
            var j = lo
            while j <= hi {
                let cost = (ai == b[j - 1]) ? 0 : 1
                var best = previous[j - 1] + cost      // substitution
                let del = previous[j] + 1              // suppression
                if del < best { best = del }
                let ins = current[j - 1] + 1           // insertion
                if ins < best { best = ins }
                current[j] = best
                if best < rowMin { rowMin = best }
                j += 1
            }
            if hi < m { current[hi + 1] = maxDistance + 1 }
            if rowMin > maxDistance { return nil }     // abandon anticipé
            swap(&previous, &current)
        }
        let d = previous[m]
        return d <= maxDistance ? d : nil
    }
}
