import Foundation

/// A position in the authored script. Offsets use the same UTF-16 coordinate
/// space as the HUD text selection boundary.
public struct ReadingPositionAnchor: Equatable, Hashable, Sendable {
    public let sentenceIndex: Int
    public let utf16Offset: Int

    public init(sentenceIndex: Int, utf16Offset: Int) {
        self.sentenceIndex = max(0, sentenceIndex)
        self.utf16Offset = max(0, utf16Offset)
    }
}

public enum ReadingRecognitionEventSemantics: Equatable, Sendable {
    case partial
    case final
}

/// Numeric-only evidence carried between pure evaluations. The controller may
/// retain this value, but it does not interpret candidate or threshold rules.
public struct ReadingPositionStability: Equatable, Sendable {
    public let scriptVersion: TeleprompterScriptVersion?
    public let candidateSentenceIndex: Int?
    public let candidateUTF16Offset: Int?
    public let observationCount: Int

    public init() {
        scriptVersion = nil
        candidateSentenceIndex = nil
        candidateUTF16Offset = nil
        observationCount = 0
    }

    init(
        scriptVersion: TeleprompterScriptVersion,
        candidate: ReadingPositionAnchor,
        observationCount: Int
    ) {
        self.scriptVersion = scriptVersion
        candidateSentenceIndex = candidate.sentenceIndex
        candidateUTF16Offset = candidate.utf16Offset
        self.observationCount = max(0, observationCount)
    }
}

public struct ReadingPositionInput: Equatable, Sendable {
    public let script: TeleprompterScript
    public let scriptVersion: TeleprompterScriptVersion
    public let anchor: ReadingPositionAnchor
    public let transcriptFragment: String
    public let eventSemantics: ReadingRecognitionEventSemantics

    public init(
        script: TeleprompterScript,
        scriptVersion: TeleprompterScriptVersion,
        anchor: ReadingPositionAnchor,
        transcriptFragment: String,
        eventSemantics: ReadingRecognitionEventSemantics
    ) {
        self.script = script
        self.scriptVersion = scriptVersion
        self.anchor = anchor
        self.transcriptFragment = transcriptFragment
        self.eventSemantics = eventSemantics
    }
}

public enum ReadingPositionStayReason: Equatable, Sendable {
    case staleScriptVersion
    case ambiguousExactMatch
    case noReliableMatch
    case awaitingStablePartial
}

/// Safe-to-record evidence categories. They intentionally contain no source or
/// transcript fragments and no provider payload.
public enum ReadingPositionEvidence: Equatable, Sendable {
    case sentenceProgress
    case stabilizedPartial
    case finalEvent
    case uniqueExactSuffix
}

public enum ReadingPositionDecision: Equatable, Sendable {
    case stay(reason: ReadingPositionStayReason)
    case advance(
        target: ReadingPositionAnchor,
        confidence: Double,
        evidence: ReadingPositionEvidence
    )
    case jump(
        target: ReadingPositionAnchor,
        distance: Int,
        confidence: Double,
        evidence: ReadingPositionEvidence
    )
}

public struct ReadingPositionEvaluation: Equatable, Sendable {
    public let decision: ReadingPositionDecision
    public let nextStability: ReadingPositionStability

    public init(
        decision: ReadingPositionDecision,
        nextStability: ReadingPositionStability
    ) {
        self.decision = decision
        self.nextStability = nextStability
    }
}

/// One reversible automatic jump. It contains positions and compatibility
/// markers only; script and recognition text never enter the undo contract.
struct ReadingPositionAutomaticJump: Equatable, Sendable {
    let scriptVersion: TeleprompterScriptVersion
    let alignmentGeneration: UInt64
    let source: ReadingPositionAnchor
    let target: ReadingPositionAnchor
}

/// Pure one-shot state used by the controller and phone UI. Compatibility is
/// checked again when consuming so a stale button action fails closed.
struct ReadingPositionUndoState: Equatable, Sendable {
    private(set) var automaticJump: ReadingPositionAutomaticJump?

    mutating func record(
        scriptVersion: TeleprompterScriptVersion,
        alignmentGeneration: UInt64,
        source: ReadingPositionAnchor,
        target: ReadingPositionAnchor
    ) {
        automaticJump = ReadingPositionAutomaticJump(
            scriptVersion: scriptVersion,
            alignmentGeneration: alignmentGeneration,
            source: source,
            target: target
        )
    }

    mutating func invalidate() {
        automaticJump = nil
    }

    func isAvailable(
        scriptVersion: TeleprompterScriptVersion,
        alignmentGeneration: UInt64,
        currentAnchor: ReadingPositionAnchor
    ) -> Bool {
        guard let automaticJump else { return false }
        return automaticJump.scriptVersion == scriptVersion
            && automaticJump.alignmentGeneration == alignmentGeneration
            && automaticJump.target == currentAnchor
    }

    mutating func consume(
        scriptVersion: TeleprompterScriptVersion,
        alignmentGeneration: UInt64,
        currentAnchor: ReadingPositionAnchor
    ) -> ReadingPositionAnchor? {
        guard isAvailable(
            scriptVersion: scriptVersion,
            alignmentGeneration: alignmentGeneration,
            currentAnchor: currentAnchor
        ) else {
            invalidate()
            return nil
        }
        defer { invalidate() }
        return automaticJump?.source
    }
}

/// Pure, deterministic reading-position policy. It has no UI, scheduler,
/// audio, network, persistence, or provider dependencies.
public struct ReadingPositionEngine: Sendable {
    private let aligner: TeleprompterScriptAligner

    public init() {
        aligner = TeleprompterScriptAligner()
    }

    init(aligner: TeleprompterScriptAligner) {
        self.aligner = aligner
    }

    public func evaluate(
        _ input: ReadingPositionInput,
        stability: ReadingPositionStability = .init()
    ) -> ReadingPositionEvaluation {
        guard input.script.version == input.scriptVersion else {
            return stay(.staleScriptVersion)
        }

        let anchor = safeAnchor(input.anchor, in: input.script)
        let compatibleStability = stability.scriptVersion == input.scriptVersion
            ? stability
            : ReadingPositionStability()
        let exactResolution = aligner.forwardJumpResolution(
            transcript: input.transcriptFragment,
            script: input.script,
            anchor: anchor.sentenceIndex,
            minimumUTF16Offset: anchor.utf16Offset
        )
        switch exactResolution {
        case .ambiguous:
            return stay(.ambiguousExactMatch)
        case .unique(let match) where match.skippedCharacterCount > 0:
            return ReadingPositionEvaluation(
                decision: .jump(
                    target: targetAfterExactMatch(match, script: input.script),
                    distance: match.skippedCharacterCount,
                    confidence: 1,
                    evidence: .uniqueExactSuffix
                ),
                nextStability: ReadingPositionStability()
            )
        case .noExactMatch, .unique:
            break
        }

        let match = aligner.bestMatch(
            transcript: input.transcriptFragment,
            script: input.script,
            anchor: anchor.sentenceIndex,
            minimumUTF16Offset: anchor.utf16Offset
        )
        let progress = match?.sentenceIndex == anchor.sentenceIndex || match == nil
            ? aligner.readingProgress(
                transcript: input.transcriptFragment,
                sentence: input.script.sentences[anchor.sentenceIndex],
                minimumUTF16Offset: anchor.utf16Offset
            )
            : nil

        if let match, match.sentenceIndex > anchor.sentenceIndex {
            return evaluateSentenceCompletion(
                matchedSentenceIndex: match.sentenceIndex,
                confidence: match.confidence,
                input: input,
                stability: compatibleStability
            )
        }

        let completionFraction = max(
            progress?.fraction ?? currentSentenceFraction(anchor, script: input.script),
            (match?.confidence ?? 0) >= 0.95 ? 1 : 0
        )
        switch input.eventSemantics {
        case .partial:
            if completionFraction >= 0.88, match != nil {
                let completionTarget = targetAfterSentence(
                    anchor.sentenceIndex,
                    script: input.script
                )
                let stable = incrementedStability(
                    compatibleStability,
                    candidate: completionTarget,
                    scriptVersion: input.scriptVersion
                )
                if stable.observationCount >= 2 {
                    return ReadingPositionEvaluation(
                        decision: .advance(
                            target: completionTarget,
                            confidence: match?.confidence ?? progress?.confidence ?? 0,
                            evidence: .stabilizedPartial
                        ),
                        nextStability: ReadingPositionStability()
                    )
                }
                if let progress, progress.utf16Offset > anchor.utf16Offset {
                    return ReadingPositionEvaluation(
                        decision: .advance(
                            target: ReadingPositionAnchor(
                                sentenceIndex: anchor.sentenceIndex,
                                utf16Offset: progress.utf16Offset
                            ),
                            confidence: progress.confidence,
                            evidence: .sentenceProgress
                        ),
                        nextStability: stable
                    )
                }
                return ReadingPositionEvaluation(
                    decision: .stay(reason: .awaitingStablePartial),
                    nextStability: stable
                )
            }
        case .final:
            // A final fragment may contain a small insertion or omission while
            // still describing the complete current sentence. The aligner
            // already bounds and scores that evidence; using its confidence
            // here completes the sentence without reclassifying a matching
            // suffix as an automatic jump.
            let finalCompletionFraction = max(
                completionFraction,
                match?.confidence ?? 0
            )
            if finalCompletionFraction >= 0.82 {
                return ReadingPositionEvaluation(
                    decision: .advance(
                        target: targetAfterSentence(anchor.sentenceIndex, script: input.script),
                        confidence: max(match?.confidence ?? 0, progress?.confidence ?? 0),
                        evidence: .finalEvent
                    ),
                    nextStability: ReadingPositionStability()
                )
            }
        }

        if let progress, progress.utf16Offset > anchor.utf16Offset {
            return ReadingPositionEvaluation(
                decision: .advance(
                    target: ReadingPositionAnchor(
                        sentenceIndex: anchor.sentenceIndex,
                        utf16Offset: progress.utf16Offset
                    ),
                    confidence: progress.confidence,
                    evidence: .sentenceProgress
                ),
                nextStability: ReadingPositionStability()
            )
        }
        return stay(.noReliableMatch)
    }

    private func evaluateSentenceCompletion(
        matchedSentenceIndex: Int,
        confidence: Double,
        input: ReadingPositionInput,
        stability: ReadingPositionStability
    ) -> ReadingPositionEvaluation {
        switch input.eventSemantics {
        case .final:
            return ReadingPositionEvaluation(
                decision: .advance(
                    target: targetAfterSentence(matchedSentenceIndex, script: input.script),
                    confidence: confidence,
                    evidence: .finalEvent
                ),
                nextStability: ReadingPositionStability()
            )
        case .partial:
            let completionTarget = targetAfterSentence(
                matchedSentenceIndex,
                script: input.script
            )
            let stable = incrementedStability(
                stability,
                candidate: completionTarget,
                scriptVersion: input.scriptVersion
            )
            guard stable.observationCount >= 2 else {
                return ReadingPositionEvaluation(
                    decision: .stay(reason: .awaitingStablePartial),
                    nextStability: stable
                )
            }
            return ReadingPositionEvaluation(
                decision: .advance(
                    target: completionTarget,
                    confidence: confidence,
                    evidence: .stabilizedPartial
                ),
                nextStability: ReadingPositionStability()
            )
        }
    }

    private func incrementedStability(
        _ stability: ReadingPositionStability,
        candidate: ReadingPositionAnchor,
        scriptVersion: TeleprompterScriptVersion
    ) -> ReadingPositionStability {
        let isSameCandidate = stability.candidateSentenceIndex == candidate.sentenceIndex
            && stability.candidateUTF16Offset == candidate.utf16Offset
        let count = isSameCandidate
            ? stability.observationCount + 1
            : 1
        return ReadingPositionStability(
            scriptVersion: scriptVersion,
            candidate: candidate,
            observationCount: count
        )
    }

    private func targetAfterExactMatch(
        _ match: TeleprompterForwardJumpMatch,
        script: TeleprompterScript
    ) -> ReadingPositionAnchor {
        guard match.reachesSentenceEnd else {
            return ReadingPositionAnchor(
                sentenceIndex: match.sentenceIndex,
                utf16Offset: match.utf16Offset
            )
        }
        return targetAfterSentence(match.sentenceIndex, script: script)
    }

    private func targetAfterSentence(
        _ sentenceIndex: Int,
        script: TeleprompterScript
    ) -> ReadingPositionAnchor {
        if sentenceIndex + 1 < script.sentences.count {
            return ReadingPositionAnchor(sentenceIndex: sentenceIndex + 1, utf16Offset: 0)
        }
        return ReadingPositionAnchor(
            sentenceIndex: script.sentences.count - 1,
            utf16Offset: (script.sentences.last! as NSString).length
        )
    }

    private func safeAnchor(
        _ anchor: ReadingPositionAnchor,
        in script: TeleprompterScript
    ) -> ReadingPositionAnchor {
        let sentenceIndex = min(anchor.sentenceIndex, script.sentences.count - 1)
        let sentenceLength = (script.sentences[sentenceIndex] as NSString).length
        return ReadingPositionAnchor(
            sentenceIndex: sentenceIndex,
            utf16Offset: min(anchor.utf16Offset, sentenceLength)
        )
    }

    private func currentSentenceFraction(
        _ anchor: ReadingPositionAnchor,
        script: TeleprompterScript
    ) -> Double {
        let length = max((script.sentences[anchor.sentenceIndex] as NSString).length, 1)
        return Double(anchor.utf16Offset) / Double(length)
    }

    private func stay(_ reason: ReadingPositionStayReason) -> ReadingPositionEvaluation {
        ReadingPositionEvaluation(
            decision: .stay(reason: reason),
            nextStability: ReadingPositionStability()
        )
    }
}
