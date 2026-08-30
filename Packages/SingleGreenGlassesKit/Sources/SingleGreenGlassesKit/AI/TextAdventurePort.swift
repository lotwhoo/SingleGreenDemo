import Foundation

/// Provider-neutral boundary for one validated, stateless game turn.
@MainActor
public protocol TextAdventureTurnProvider: AnyObject {
    func proposeTurn(_ request: TextAdventureTurnRequest) async throws -> TextAdventureCheckpoint
}

/// Provider-neutral boundary for the search-first, immutable run preparation flow.
@MainActor
public protocol TextAdventureRunPreparationProvider: AnyObject {
    func prepareTrendSeed(
        _ request: TextAdventureTrendPreparationRequest
    ) async throws -> TextAdventureTrendSeed

    func prepareFramework(
        _ request: TextAdventureFrameworkPreparationRequest
    ) async throws -> TextAdventurePreparedRun
}

public struct TextAdventureTrendPreparationRequest: Equatable, Sendable {
    public let sessionID: UUID
    public let seed: UInt64

    public init(sessionID: UUID, seed: UInt64) {
        self.sessionID = sessionID
        self.seed = seed
    }
}

public struct TextAdventureFrameworkPreparationRequest: Equatable, Sendable {
    public let sessionID: UUID
    public let seed: UInt64
    public let trendSeed: TextAdventureTrendSeed

    public init(sessionID: UUID, seed: UInt64, trendSeed: TextAdventureTrendSeed) {
        self.sessionID = sessionID
        self.seed = seed
        self.trendSeed = trendSeed
    }
}

@MainActor
public final class LocalTextAdventureRunPreparationProvider: TextAdventureRunPreparationProvider {
    public init() {}

    public func prepareTrendSeed(
        _ request: TextAdventureTrendPreparationRequest
    ) async throws -> TextAdventureTrendSeed {
        .reviewedFallback(seed: request.seed)
    }

    public func prepareFramework(
        _ request: TextAdventureFrameworkPreparationRequest
    ) async throws -> TextAdventurePreparedRun {
        let generated = GreenSignalStoryBriefGenerator.make(seed: request.seed)
        let brief = TextAdventureStoryBrief(
            seed: generated.seed,
            genre: generated.genre,
            setting: generated.setting,
            protagonistRole: generated.protagonistRole,
            motif: generated.motif,
            pressure: generated.pressure,
            relationship: generated.relationship,
            plotStructure: generated.plotStructure,
            tone: generated.tone,
            trendSeed: request.trendSeed
        )
        return try TextAdventurePreparedRun(
            storyBrief: brief,
            openingCheckpoint: GreenSignalGame.initialCheckpoint(brief: brief)
        )
    }
}

public struct TextAdventureTurnRequest: Equatable, Sendable {
    public let sessionID: UUID
    public let storyBrief: TextAdventureStoryBrief
    public let checkpoint: TextAdventureCheckpoint
    public let choice: TextAdventureChoice

    public init(
        sessionID: UUID,
        storyBrief: TextAdventureStoryBrief,
        checkpoint: TextAdventureCheckpoint,
        choice: TextAdventureChoice
    ) {
        self.sessionID = sessionID
        self.storyBrief = storyBrief
        self.checkpoint = checkpoint
        self.choice = choice
    }
}
