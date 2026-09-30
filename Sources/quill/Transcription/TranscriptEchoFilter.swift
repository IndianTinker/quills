import Foundation

/// Speaker playback can also reach the mic. Keep the system's original and
/// suppress only long, nearly identical mic spans at the same time. Short
/// acknowledgments, later repetitions, and distinct overlapping speech stay.
enum TranscriptEchoFilter {
    static func removingEcho(from segments: [Transcript.Segment]) -> [Transcript.Segment] {
        let system = segments.filter { $0.speaker == "them" }
            .sorted { $0.start_ms < $1.start_ms }
        return segments.filter { mic in
            guard mic.speaker == "me", mic.end_ms > mic.start_ms else { return true }
            let words = tokens(mic.text)
            guard words.count >= 5 else { return true }

            let nearby = system.filter {
                $0.start_ms < mic.end_ms && $0.end_ms > mic.start_ms
            }
            guard !nearby.isEmpty else { return true }

            // Require coverage of the mic span, allowing a small acoustic /
            // recognition delay. Union intervals so overlaps aren't counted twice.
            var covered = 0
            var end = mic.start_ms
            for span in nearby {
                let lo = max(mic.start_ms, span.start_ms - 250)
                let hi = min(mic.end_ms, span.end_ms + 250)
                covered += max(0, hi - max(end, lo))
                end = max(end, hi)
            }
            guard Double(covered) / Double(mic.end_ms - mic.start_ms) >= 0.8 else {
                return true
            }

            // Sentence boundaries can differ between tracks. Match against a
            // contiguous passage across adjacent system segments, allowing at
            // most 10% word edits. No bag-of-words or global text deduplication.
            let source = nearby.flatMap { tokens($0.text) }
            return substringDistance(words, in: source) > words.count / 10
        }
    }

    private static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Levenshtein distance to the best contiguous source passage. The zero
    /// first row permits an unmatched prefix; taking the minimum permits a suffix.
    private static func substringDistance(_ words: [String], in source: [String]) -> Int {
        var previous = Array(repeating: 0, count: source.count + 1)
        for (i, word) in words.enumerated() {
            var row = Array(repeating: i + 1, count: source.count + 1)
            for (j, other) in source.enumerated() {
                row[j + 1] = min(
                    previous[j] + (word == other ? 0 : 1),
                    min(previous[j + 1] + 1, row[j] + 1)
                )
            }
            previous = row
        }
        return previous.min() ?? words.count
    }
}
