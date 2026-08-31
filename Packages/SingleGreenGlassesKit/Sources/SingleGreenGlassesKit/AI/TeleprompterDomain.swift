import Foundation

public enum TeleprompterLimits {
    public static let maximumScriptCharacters = 20_000
    public static let maximumAlignmentLookahead = 5
}

public enum TeleprompterScriptError: Error, Equatable, Sendable {
    case empty
}

/// An immutable, locally segmented script. Segmentation keeps terminal
/// punctuation, removes layout whitespace, and renders each authored paragraph
/// boundary as exactly one slash so the HUD never needs a blank display row.
public struct TeleprompterScript: Equatable, Sendable {
    public let source: String
    public let sentences: [String]

    public init(_ source: String) throws {
        let limited = String(source.prefix(TeleprompterLimits.maximumScriptCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sentences = Self.segment(limited)
        guard !sentences.isEmpty else { throw TeleprompterScriptError.empty }
        self.source = limited
        self.sentences = sentences
    }

    private static func segment(_ source: String) -> [String] {
        var result: [String] = []
        var buffer = ""
        var hasPendingParagraphBreak = false
        let terminalCharacters: Set<Character> = ["。", "！", "？", "!", "?", "；", ";"]

        func flush() {
            let sentence = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            buffer = ""
        }

        for character in source {
            if isLineBreak(character) {
                if !buffer.isEmpty || !result.isEmpty {
                    hasPendingParagraphBreak = true
                }
                continue
            }
            if character.isWhitespace {
                // Spaces and tabs are layout artifacts on the single-green HUD.
                continue
            }

            if hasPendingParagraphBreak {
                if !buffer.isEmpty {
                    if buffer.last != "/", character != "/" { buffer.append("/") }
                    flush()
                } else if !result.isEmpty,
                          !result[result.count - 1].hasSuffix("/"),
                          character != "/" {
                    result[result.count - 1].append("/")
                }
                hasPendingParagraphBreak = false
            }

            if character == "/" {
                if !buffer.isEmpty {
                    if buffer.last != "/" { buffer.append("/") }
                    flush()
                } else if !result.isEmpty,
                          !result[result.count - 1].hasSuffix("/") {
                    result[result.count - 1].append("/")
                }
                continue
            }

            buffer.append(character)
            if terminalCharacters.contains(character) { flush() }
        }
        flush()
        return result
    }

    private static func isLineBreak(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
    }
}

public enum TeleprompterPhase: Equatable, Sendable {
    case ready
    case preparing
    case listening
    case paused
    case manualFallback
    case completed
}

public struct TeleprompterState: Equatable, Sendable {
    public let script: TeleprompterScript?
    public let sentenceIndex: Int
    public let phase: TeleprompterPhase
    public let userSafeError: String?
    let readingUTF16Offset: Int

    public init(
        script: TeleprompterScript? = nil,
        sentenceIndex: Int = 0,
        phase: TeleprompterPhase = .ready,
        userSafeError: String? = nil
    ) {
        self.init(
            script: script,
            sentenceIndex: sentenceIndex,
            readingUTF16Offset: 0,
            phase: phase,
            userSafeError: userSafeError
        )
    }

    init(
        script: TeleprompterScript?,
        sentenceIndex: Int,
        readingUTF16Offset: Int,
        phase: TeleprompterPhase,
        userSafeError: String? = nil
    ) {
        self.script = script
        let safeSentenceIndex = script.map {
            min(max(sentenceIndex, 0), $0.sentences.count - 1)
        } ?? 0
        self.sentenceIndex = safeSentenceIndex
        let sentenceLength = script.map {
            ($0.sentences[safeSentenceIndex] as NSString).length
        } ?? 0
        self.readingUTF16Offset = min(max(readingUTF16Offset, 0), sentenceLength)
        self.phase = phase
        self.userSafeError = userSafeError
    }

    public var progress: Double {
        guard let script, !script.sentences.isEmpty else { return 0 }
        if phase == .completed { return 1 }
        let sentenceLength = max((script.sentences[sentenceIndex] as NSString).length, 1)
        let sentenceProgress = Double(readingUTF16Offset) / Double(sentenceLength)
        return (Double(sentenceIndex) + sentenceProgress) / Double(script.sentences.count)
    }
}

struct TeleprompterSentenceProgressMatch: Equatable {
    let utf16Offset: Int
    let fraction: Double
    let confidence: Double
}

public struct TeleprompterAlignmentMatch: Equatable, Sendable {
    public let sentenceIndex: Int
    public let confidence: Double

    public init(sentenceIndex: Int, confidence: Double) {
        self.sentenceIndex = sentenceIndex
        self.confidence = min(max(confidence, 0), 1)
    }
}

/// Pure, deterministic alignment used by the teleprompter controller. It only
/// proposes the current anchor or a later sentence; it can never move backward.
public struct TeleprompterScriptAligner: Sendable {
    private static let maximumFuzzyCharacters = 256
    private static let maximumProgressProbeCharacters = 128

    public init() {}

    public func bestMatch(
        transcript: String,
        script: TeleprompterScript,
        anchor: Int
    ) -> TeleprompterAlignmentMatch? {
        let safeAnchor = min(max(anchor, 0), script.sentences.count - 1)
        let normalizedTranscript = Self.normalize(transcript)
        guard normalizedTranscript.count >= 2 else { return nil }

        let upperBound = min(
            script.sentences.count - 1,
            safeAnchor + TeleprompterLimits.maximumAlignmentLookahead
        )
        let scored = (safeAnchor...upperBound).compactMap { index -> ScoredCandidate? in
            let text = Self.normalize(script.sentences[index])
            guard !text.isEmpty else { return nil }
            return ScoredCandidate(
                index: index,
                score: Self.matchScore(
                    transcript: normalizedTranscript,
                    sentence: text
                ),
                text: text
            )
        }.sorted {
            if $0.score == $1.score { return $0.index < $1.index }
            return $0.score > $1.score
        }
        guard let best = scored.first,
              best.score >= Self.minimumConfidence(for: best.text.count) else {
            return nil
        }

        // Matching the sentence currently on screen is safe even when a later
        // sentence starts similarly: advancing one sentence cannot skip content.
        // A future jump still requires an unambiguous score lead.
        if best.index > safeAnchor {
            let secondScore = scored.dropFirst().first?.score ?? 0
            guard best.score - secondScore >= 0.12 else { return nil }
        }
        return TeleprompterAlignmentMatch(
            sentenceIndex: best.index,
            confidence: best.score
        )
    }

    public func proposedSentenceIndex(
        transcript: String,
        script: TeleprompterScript,
        anchor: Int
    ) -> Int {
        let safeAnchor = min(max(anchor, 0), script.sentences.count - 1)
        return bestMatch(
            transcript: transcript,
            script: script,
            anchor: safeAnchor
        )?.sentenceIndex ?? safeAnchor
    }

    /// Locates the most recently spoken text inside the current sentence. The
    /// floor makes progress monotonic across ASR utterance rotations, including
    /// providers that restart partial transcripts after every pause.
    func readingProgress(
        transcript: String,
        sentence: String,
        minimumUTF16Offset: Int
    ) -> TeleprompterSentenceProgressMatch? {
        let source = NormalizedSource(sentence)
        let normalizedTranscript = Array(Self.normalize(transcript))
        let transcriptCharacters = Array(
            normalizedTranscript.suffix(Self.maximumProgressProbeCharacters)
        )
        guard normalizedTranscript.count >= 4, !source.characters.isEmpty else { return nil }

        let minimumIndex = source.normalizedIndex(atOrBeforeUTF16Offset: minimumUTF16Offset)
        let searchStart = max(0, minimumIndex - transcriptCharacters.count)
        if let exactEnd = Self.firstExactEnd(
            needle: transcriptCharacters,
            haystack: source.characters,
            startingAt: searchStart,
            after: minimumIndex
        ) {
            return source.progressMatch(normalizedEndIndex: exactEnd, confidence: 1)
        }

        let fuzzyNeedle = Array(transcriptCharacters.suffix(64))
        let cumulativeCenter = min(source.characters.count, normalizedTranscript.count)
        let incrementalCenter = min(
            source.characters.count,
            minimumIndex + normalizedTranscript.count
        )
        var candidateEnds: Set<Int> = []
        for center in [cumulativeCenter, incrementalCenter] {
            let lower = max(minimumIndex + 1, center - 24)
            let upper = min(source.characters.count, center + 24)
            if lower <= upper { candidateEnds.formUnion(lower...upper) }
        }
        guard !candidateEnds.isEmpty else { return nil }

        var bestEnd: Int?
        var bestScore = 0.0
        for candidateEnd in candidateEnds.sorted() {
            let candidateStart = max(0, candidateEnd - fuzzyNeedle.count)
            let candidate = Array(source.characters[candidateStart..<candidateEnd])
            let score = Self.matchScore(
                transcript: String(fuzzyNeedle),
                sentence: String(candidate)
            )
            if score > bestScore || (score == bestScore && candidateEnd < (bestEnd ?? .max)) {
                bestScore = score
                bestEnd = candidateEnd
            }
        }
        guard bestScore >= 0.62, let bestEnd else { return nil }
        return source.progressMatch(normalizedEndIndex: bestEnd, confidence: bestScore)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().unicodeScalars.compactMap { scalar -> Character? in
            if CharacterSet.alphanumerics.contains(scalar)
                || (0x3400...0x9FFF).contains(Int(scalar.value)) {
                return Character(String(scalar))
            }
            return nil
        }.reduce(into: "") { $0.append($1) }
    }

    private static func matchScore(transcript: String, sentence: String) -> Double {
        guard !transcript.isEmpty, !sentence.isEmpty else { return 0 }
        if transcript.contains(sentence) { return 1 }
        if sentence.contains(transcript) {
            return Double(transcript.count) / Double(sentence.count)
        }

        // Bound quadratic fuzzy work for long, unpunctuated scripts. Exact
        // containment above still handles normal cumulative partials at any
        // position; fuzzy correction concentrates on the most recent speech.
        let transcriptCharacters = Array(transcript.suffix(maximumFuzzyCharacters))
        let sentenceCharacters = Array(sentence.suffix(maximumFuzzyCharacters))
        let commonLength = longestCommonSubsequenceLength(
            transcriptCharacters,
            sentenceCharacters
        )
        let recall = Double(commonLength) / Double(sentenceCharacters.count)
        let precision = Double(commonLength) / Double(transcriptCharacters.count)
        let lengthBalance = Double(min(transcriptCharacters.count, sentenceCharacters.count))
            / Double(max(transcriptCharacters.count, sentenceCharacters.count))
        let bigram = bigramDice(transcriptCharacters, sentenceCharacters)
        let fuzzyScore = 0.52 * recall
            + 0.18 * precision
            + 0.20 * bigram
            + 0.10 * lengthBalance

        return fuzzyScore
    }

    private static func minimumConfidence(for sentenceLength: Int) -> Double {
        if sentenceLength <= 4 { return 0.95 }
        if sentenceLength <= 8 { return 0.70 }
        return 0.64
    }

    private static func longestCommonSubsequenceLength(
        _ lhs: [Character],
        _ rhs: [Character]
    ) -> Int {
        var previous = Array(repeating: 0, count: rhs.count + 1)
        for left in lhs {
            var current = Array(repeating: 0, count: rhs.count + 1)
            for (offset, right) in rhs.enumerated() {
                current[offset + 1] = left == right
                    ? previous[offset] + 1
                    : max(previous[offset + 1], current[offset])
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private static func bigramDice(_ lhs: [Character], _ rhs: [Character]) -> Double {
        guard lhs.count >= 2, rhs.count >= 2 else { return lhs == rhs ? 1 : 0 }
        let leftPairs = pairCounts(lhs)
        let rightPairs = pairCounts(rhs)
        let overlap = leftPairs.reduce(into: 0) { total, entry in
            total += min(entry.value, rightPairs[entry.key] ?? 0)
        }
        return Double(2 * overlap) / Double((lhs.count - 1) + (rhs.count - 1))
    }

    private static func pairCounts(_ characters: [Character]) -> [String: Int] {
        guard characters.count >= 2 else { return [:] }
        return (0..<(characters.count - 1)).reduce(into: [:]) { counts, index in
            counts[String([characters[index], characters[index + 1]]), default: 0] += 1
        }
    }

    private static func firstExactEnd(
        needle: [Character],
        haystack: [Character],
        startingAt start: Int,
        after minimumEnd: Int
    ) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        let lastStart = haystack.count - needle.count
        guard start <= lastStart else { return nil }
        for candidateStart in start...lastStart {
            let candidateEnd = candidateStart + needle.count
            guard candidateEnd > minimumEnd else { continue }
            if haystack[candidateStart..<candidateEnd].elementsEqual(needle) {
                return candidateEnd
            }
        }
        return nil
    }
}

private struct NormalizedSource {
    let characters: [Character]
    let utf16EndOffsets: [Int]

    init(_ source: String) {
        var normalizedCharacters: [Character] = []
        var endOffsets: [Int] = []
        var utf16Offset = 0
        for character in source {
            let characterText = String(character)
            utf16Offset += characterText.utf16.count
            for scalar in characterText.lowercased().unicodeScalars where
                CharacterSet.alphanumerics.contains(scalar)
                    || (0x3400...0x9FFF).contains(Int(scalar.value)) {
                normalizedCharacters.append(Character(String(scalar)))
                endOffsets.append(utf16Offset)
            }
        }
        characters = normalizedCharacters
        utf16EndOffsets = endOffsets
    }

    func normalizedIndex(atOrBeforeUTF16Offset offset: Int) -> Int {
        utf16EndOffsets.prefix { $0 <= offset }.count
    }

    func progressMatch(
        normalizedEndIndex: Int,
        confidence: Double
    ) -> TeleprompterSentenceProgressMatch? {
        guard normalizedEndIndex > 0, normalizedEndIndex <= utf16EndOffsets.count else { return nil }
        return TeleprompterSentenceProgressMatch(
            utf16Offset: utf16EndOffsets[normalizedEndIndex - 1],
            fraction: Double(normalizedEndIndex) / Double(characters.count),
            confidence: confidence
        )
    }
}

private struct ScoredCandidate {
    let index: Int
    let score: Double
    let text: String
}
