import Foundation

public enum TextAdventureLimits {
    public static let minimumEndingTurn = 10
    public static let maximumTurn = 12
    public static let minimumNarrativeCharacters = 18
    public static let maximumNarrativeCharacters = 40
    public static let minimumNarrativeSentences = 2
    public static let maximumNarrativeSentences = 2
    public static let minimumChoiceCharacters = 3
    public static let maximumChoiceCharacters = 9
    public static let maximumRecapCharacters = 28
    public static let maximumHintCharacters = 18
    public static let maximumInventoryItems = 3
    public static let maximumInventoryItemCharacters = 8
    public static let maximumTrendFieldCharacters = 32
}

public enum TextAdventureValidationError: Error, Equatable, Sendable {
    case turnOutOfRange
    case narrativeLengthOutOfRange
    case invalidNarrativeSentenceCount
    case narrativeContainsLineBreakOrControl
    case fragmentedNarrative
    case recapTooLong
    case hintTooLong
    case statusOutOfRange
    case tooManyInventoryItems
    case invalidInventoryItem
    case choicesRequired
    case choicesForbidden
    case invalidChoiceLabel
    case duplicateChoices
    case forbiddenContent
    case endingTooEarly
    case ongoingAtTurnLimit
    case nonSequentialTurn
    case missingStoryBrief
    case invalidTrendSeed
    case invalidOpeningCheckpoint
    case preparationSeedMismatch
}

public enum TextAdventureChoice: String, Codable, Equatable, Sendable {
    case a
    case b
}

public enum TextAdventureOutcome: String, Codable, Equatable, Sendable {
    case ongoing
    case ended
}

public enum TextAdventureGenre: String, Codable, CaseIterable, Equatable, Sendable {
    case survivalMystery = "survival_mystery"
    case scienceMystery = "science_mystery"
    case gothicMystery = "gothic_mystery"
    case urbanMystery = "urban_mystery"
    case nearFutureAI = "near_future_ai"
    case cosmicAdventure = "cosmic_adventure"
    case culturalFantasy = "cultural_fantasy"
    case timeLoopDrama = "time_loop_drama"
    case cozyInvestigation = "cozy_investigation"
    case socialPuzzle = "social_puzzle"
}

public enum TextAdventureSetting: String, Codable, CaseIterable, Equatable, Sendable {
    case stormValley = "storm_valley"
    case fogHarbor = "fog_harbor"
    case desertRelay = "desert_relay"
    case snowObservatory = "snow_observatory"
    case neonMegacity = "neon_megacity"
    case orbitalStation = "orbital_station"
    case deepSeaLab = "deep_sea_lab"
    case midnightMuseum = "midnight_museum"
    case nightTrain = "night_train"
    case virtualArchive = "virtual_archive"
    case ancientTownFestival = "ancient_town_festival"
    case robotCompetition = "robot_competition"
    case climateDome = "climate_dome"
    case lunarHotel = "lunar_hotel"
}

public enum TextAdventureProtagonistRole: String, Codable, CaseIterable, Equatable, Sendable {
    case radioVolunteer = "radio_volunteer"
    case trailMapper = "trail_mapper"
    case nightArchivist = "night_archivist"
    case weatherObserver = "weather_observer"
    case aiCompanionTrainer = "ai_companion_trainer"
    case digitalRestorer = "digital_restorer"
    case deepSeaResearcher = "deep_sea_researcher"
    case orbitalCourier = "orbital_courier"
    case cultureConservator = "culture_conservator"
    case eventProducer = "event_producer"
}

public enum TextAdventureMotif: String, Codable, CaseIterable, Equatable, Sendable {
    case lostSignal = "lost_signal"
    case sealedRoom = "sealed_room"
    case misleadingMap = "misleading_map"
    case midnightVisitor = "midnight_visitor"
    case futureMessage = "future_message"
    case memoryMismatch = "memory_mismatch"
    case aiSecret = "ai_secret"
    case livingArtifact = "living_artifact"
    case duplicateIdentity = "duplicate_identity"
    case reversedClock = "reversed_clock"
}

public enum TextAdventurePressure: String, Codable, CaseIterable, Equatable, Sendable {
    case failingPower = "failing_power"
    case risingWater = "rising_water"
    case closingWeather = "closing_weather"
    case unstableRoute = "unstable_route"
    case dataErasure = "data_erasure"
    case trustBreakdown = "trust_breakdown"
    case publicCountdown = "public_countdown"
    case realityDrift = "reality_drift"
}

public enum TextAdventureRelationship: String, Codable, CaseIterable, Equatable, Sendable {
    case estrangedFriend = "estranged_friend"
    case aiCompanion = "ai_companion"
    case rivalPartner = "rival_partner"
    case missingRelative = "missing_relative"
    case unreliableExpert = "unreliable_expert"
    case futureSelf = "future_self"
    case anonymousStranger = "anonymous_stranger"
}

public enum TextAdventurePlotStructure: String, Codable, CaseIterable, Equatable, Sendable {
    case timeLoop = "time_loop"
    case lockedRoom = "locked_room"
    case socialDeduction = "social_deduction"
    case memoryReconstruction = "memory_reconstruction"
    case rescueNegotiation = "rescue_negotiation"
    case chainMystery = "chain_mystery"
    case moralDilemma = "moral_dilemma"
    case artifactQuest = "artifact_quest"
}

public enum TextAdventureTone: String, Codable, CaseIterable, Equatable, Sendable {
    case warmSuspense = "warm_suspense"
    case wittyAdventure = "witty_adventure"
    case cosmicWonder = "cosmic_wonder"
    case cozyMystery = "cozy_mystery"
    case melancholicHope = "melancholic_hope"
    case lightUncanny = "light_uncanny"
    case investigative = "investigative"
}

/// A compact, safety-reviewed abstraction of current creative signals.
/// It never contains raw search results, titles, people, URLs, or copied text.
public struct TextAdventureTrendSeed: Codable, Equatable, Sendable {
    public let theme: String
    public let socialTension: String
    public let emotionalQuestion: String
    public let settingArchetype: String
    public let freshnessNote: String

    public init(
        theme: String,
        socialTension: String,
        emotionalQuestion: String,
        settingArchetype: String,
        freshnessNote: String
    ) throws {
        let fields = [theme, socialTension, emotionalQuestion, settingArchetype, freshnessNote]
        guard fields.allSatisfy({
            !$0.trimmed.isEmpty
                && $0.count <= TextAdventureLimits.maximumTrendFieldCharacters
                && TextAdventureContentPolicy.isTrendSafe($0)
        }) else {
            throw TextAdventureValidationError.invalidTrendSeed
        }
        self.theme = theme
        self.socialTension = socialTension
        self.emotionalQuestion = emotionalQuestion
        self.settingArchetype = settingArchetype
        self.freshnessNote = freshnessNote
    }

    public static func reviewedFallback(seed: UInt64) -> Self {
        let variants: [Self] = [
            try! Self(
                theme: "人与智能伙伴建立边界",
                socialTension: "效率与自主选择之间的拉扯",
                emotionalQuestion: "信任应当由谁来证明",
                settingArchetype: "近未来公共空间",
                freshnessNote: "采用长期可用的科技生活议题"
            ),
            try! Self(
                theme: "记忆与身份的重新确认",
                socialTension: "共同记忆与个人判断发生冲突",
                emotionalQuestion: "遗忘是否也能保护关系",
                settingArchetype: "封闭的文化空间",
                freshnessNote: "采用经典身份谜题的当代表达"
            ),
            try! Self(
                theme: "陌生人之间逐步建立协作",
                socialTension: "公开评价与真实动机彼此错位",
                emotionalQuestion: "被看见是否等于被理解",
                settingArchetype: "移动中的临时社区",
                freshnessNote: "采用轻悬疑群像关系议题"
            )
        ]
        return variants[Int(seed % UInt64(variants.count))]
    }
}

/// Immutable, locally-authored premise constraints for one complete run.
public struct TextAdventureStoryBrief: Codable, Equatable, Sendable {
    public let seed: UInt64
    public let genre: TextAdventureGenre
    public let setting: TextAdventureSetting
    public let protagonistRole: TextAdventureProtagonistRole
    public let motif: TextAdventureMotif
    public let pressure: TextAdventurePressure
    public let relationship: TextAdventureRelationship
    public let plotStructure: TextAdventurePlotStructure
    public let tone: TextAdventureTone
    public let trendSeed: TextAdventureTrendSeed

    public init(
        seed: UInt64,
        genre: TextAdventureGenre,
        setting: TextAdventureSetting,
        protagonistRole: TextAdventureProtagonistRole,
        motif: TextAdventureMotif,
        pressure: TextAdventurePressure,
        relationship: TextAdventureRelationship,
        plotStructure: TextAdventurePlotStructure,
        tone: TextAdventureTone,
        trendSeed: TextAdventureTrendSeed
    ) {
        self.seed = seed
        self.genre = genre
        self.setting = setting
        self.protagonistRole = protagonistRole
        self.motif = motif
        self.pressure = pressure
        self.relationship = relationship
        self.plotStructure = plotStructure
        self.tone = tone
        self.trendSeed = trendSeed
    }

    public init(
        seed: UInt64,
        genre: TextAdventureGenre,
        setting: TextAdventureSetting,
        protagonistRole: TextAdventureProtagonistRole,
        motif: TextAdventureMotif,
        pressure: TextAdventurePressure,
        relationship: TextAdventureRelationship,
        plotStructure: TextAdventurePlotStructure,
        tone: TextAdventureTone
    ) {
        self.init(
            seed: seed,
            genre: genre,
            setting: setting,
            protagonistRole: protagonistRole,
            motif: motif,
            pressure: pressure,
            relationship: relationship,
            plotStructure: plotStructure,
            tone: tone,
            trendSeed: .reviewedFallback(seed: seed)
        )
    }

    public func hasSameScenario(as other: TextAdventureStoryBrief) -> Bool {
        genre == other.genre
            && setting == other.setting
            && protagonistRole == other.protagonistRole
            && motif == other.motif
            && pressure == other.pressure
            && relationship == other.relationship
            && plotStructure == other.plotStructure
            && tone == other.tone
            && trendSeed == other.trendSeed
    }
}

public enum GreenSignalStoryBriefGenerator {
    public static func make(seed: UInt64) -> TextAdventureStoryBrief {
        TextAdventureStoryBrief(
            seed: seed,
            genre: indexed(TextAdventureGenre.allCases, seed: seed, salt: 0),
            setting: indexed(TextAdventureSetting.allCases, seed: seed, salt: 1),
            protagonistRole: indexed(TextAdventureProtagonistRole.allCases, seed: seed, salt: 2),
            motif: indexed(TextAdventureMotif.allCases, seed: seed, salt: 3),
            pressure: indexed(TextAdventurePressure.allCases, seed: seed, salt: 4),
            relationship: indexed(TextAdventureRelationship.allCases, seed: seed, salt: 5),
            plotStructure: indexed(TextAdventurePlotStructure.allCases, seed: seed, salt: 6),
            tone: indexed(TextAdventureTone.allCases, seed: seed, salt: 7),
            trendSeed: .reviewedFallback(seed: seed)
        )
    }

    public static func random() -> TextAdventureStoryBrief {
        make(seed: UInt64.random(in: UInt64.min...UInt64.max))
    }

    private static func indexed<Value>(_ values: [Value], seed: UInt64, salt: UInt64) -> Value {
        let mixed = splitMix64(seed &+ (salt &* 0x9E3779B97F4A7C15))
        return values[Int(mixed % UInt64(values.count))]
    }

    private static func splitMix64(_ value: UInt64) -> UInt64 {
        var mixed = value &+ 0x9E3779B97F4A7C15
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
        return mixed ^ (mixed >> 31)
    }
}

public struct TextAdventureStatus: Codable, Equatable, Sendable {
    public let energy: Int
    public let signal: Int
    public let inventory: [String]

    public init(energy: Int, signal: Int, inventory: [String]) throws {
        guard (0...3).contains(energy), (0...3).contains(signal) else {
            throw TextAdventureValidationError.statusOutOfRange
        }
        guard inventory.count <= TextAdventureLimits.maximumInventoryItems else {
            throw TextAdventureValidationError.tooManyInventoryItems
        }
        guard inventory.allSatisfy({
            let count = $0.count
            return !$0.trimmed.isEmpty
                && count <= TextAdventureLimits.maximumInventoryItemCharacters
                && TextAdventureContentPolicy.isDisplaySafe($0)
        }) else {
            throw TextAdventureValidationError.invalidInventoryItem
        }
        self.energy = energy
        self.signal = signal
        self.inventory = inventory
    }

    private enum CodingKeys: String, CodingKey { case energy, signal, inventory }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            energy: container.decode(Int.self, forKey: .energy),
            signal: container.decode(Int.self, forKey: .signal),
            inventory: container.decode([String].self, forKey: .inventory)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(energy, forKey: .energy)
        try container.encode(signal, forKey: .signal)
        try container.encode(inventory, forKey: .inventory)
    }
}

public struct TextAdventureCheckpoint: Codable, Equatable, Sendable {
    public let turn: Int
    public let narrative: String
    public let recap: String
    public let hint: String
    public let status: TextAdventureStatus
    public let choiceA: String?
    public let choiceB: String?
    public let outcome: TextAdventureOutcome

    public init(
        turn: Int,
        narrative: String,
        recap: String,
        hint: String,
        status: TextAdventureStatus,
        choiceA: String?,
        choiceB: String?,
        outcome: TextAdventureOutcome
    ) throws {
        guard (0...TextAdventureLimits.maximumTurn).contains(turn) else {
            throw TextAdventureValidationError.turnOutOfRange
        }
        guard narrative.count >= TextAdventureLimits.minimumNarrativeCharacters,
              narrative.count <= TextAdventureLimits.maximumNarrativeCharacters else {
            throw TextAdventureValidationError.narrativeLengthOutOfRange
        }
        guard !TextAdventureContentPolicy.containsLineBreakOrControl(narrative) else {
            throw TextAdventureValidationError.narrativeContainsLineBreakOrControl
        }
        let sentenceCount = TextAdventureContentPolicy.sentenceCount(in: narrative)
        guard sentenceCount >= TextAdventureLimits.minimumNarrativeSentences,
              sentenceCount <= TextAdventureLimits.maximumNarrativeSentences else {
            throw TextAdventureValidationError.invalidNarrativeSentenceCount
        }
        guard !TextAdventureContentPolicy.looksFragmented(narrative) else {
            throw TextAdventureValidationError.fragmentedNarrative
        }
        guard TextAdventureContentPolicy.isDisplaySafe(narrative) else {
            throw TextAdventureValidationError.forbiddenContent
        }
        guard !recap.trimmed.isEmpty,
              recap.count <= TextAdventureLimits.maximumRecapCharacters else {
            throw TextAdventureValidationError.recapTooLong
        }
        guard !hint.trimmed.isEmpty,
              hint.count <= TextAdventureLimits.maximumHintCharacters else {
            throw TextAdventureValidationError.hintTooLong
        }
        guard TextAdventureContentPolicy.isDisplaySafe(recap),
              TextAdventureContentPolicy.isDisplaySafe(hint) else {
            throw TextAdventureValidationError.forbiddenContent
        }

        switch outcome {
        case .ongoing:
            guard turn < TextAdventureLimits.maximumTurn else {
                throw TextAdventureValidationError.ongoingAtTurnLimit
            }
            guard let choiceA, let choiceB else {
                throw TextAdventureValidationError.choicesRequired
            }
            guard Self.isValidChoice(choiceA), Self.isValidChoice(choiceB) else {
                throw TextAdventureValidationError.invalidChoiceLabel
            }
            guard choiceA != choiceB else {
                throw TextAdventureValidationError.duplicateChoices
            }
        case .ended:
            guard turn >= TextAdventureLimits.minimumEndingTurn else {
                throw TextAdventureValidationError.endingTooEarly
            }
            guard choiceA == nil, choiceB == nil else {
                throw TextAdventureValidationError.choicesForbidden
            }
        }

        self.turn = turn
        self.narrative = narrative
        self.recap = recap
        self.hint = hint
        self.status = status
        self.choiceA = choiceA
        self.choiceB = choiceB
        self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey {
        case turn, narrative, recap, hint, status, choiceA, choiceB, outcome
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            turn: container.decode(Int.self, forKey: .turn),
            narrative: container.decode(String.self, forKey: .narrative),
            recap: container.decode(String.self, forKey: .recap),
            hint: container.decode(String.self, forKey: .hint),
            status: container.decode(TextAdventureStatus.self, forKey: .status),
            choiceA: container.decodeIfPresent(String.self, forKey: .choiceA),
            choiceB: container.decodeIfPresent(String.self, forKey: .choiceB),
            outcome: container.decode(TextAdventureOutcome.self, forKey: .outcome)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(turn, forKey: .turn)
        try container.encode(narrative, forKey: .narrative)
        try container.encode(recap, forKey: .recap)
        try container.encode(hint, forKey: .hint)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(choiceA, forKey: .choiceA)
        try container.encodeIfPresent(choiceB, forKey: .choiceB)
        try container.encode(outcome, forKey: .outcome)
    }

    private static func isValidChoice(_ value: String) -> Bool {
        let count = value.count
        return !value.trimmed.isEmpty
            && count >= TextAdventureLimits.minimumChoiceCharacters
            && count <= TextAdventureLimits.maximumChoiceCharacters
            && !TextAdventureContentPolicy.containsLineBreakOrControl(value)
            && TextAdventureContentPolicy.isDisplaySafe(value)
    }
}

enum TextAdventureContentPolicy {
    static func isDisplaySafe(_ value: String) -> Bool {
        let lowered = value.lowercased()
        guard !lowered.contains("http://"),
              !lowered.contains("https://"),
              !lowered.contains("www."),
              !value.contains("`"),
              !value.contains("#"),
              !value.contains("**"),
              !value.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) else {
            return false
        }
        return true
    }

    static func isTrendSafe(_ value: String) -> Bool {
        guard isDisplaySafe(value), !containsLineBreakOrControl(value) else { return false }
        let lowered = value.lowercased()
        guard !value.contains("《"), !value.contains("》"),
              !value.contains("“"), !value.contains("”") else { return false }
        let blocked = [
            "政治", "战争", "犯罪", "伤亡", "灾难", "医疗", "未成年", "儿童",
            "指控", "仇恨", "自残", "自杀", "色情", "性侵", "违法", "教程",
            "politic", "war", "crime", "casualty", "medical", "minor", "hate",
            "self-harm", "suicide", "sexual", "allegation"
        ]
        return !blocked.contains(where: lowered.contains)
    }

    static func containsLineBreakOrControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: true
            default: false
            }
        }
    }

    static func sentenceCount(in value: String) -> Int {
        let terminators = CharacterSet(charactersIn: "。！？!?")
        return value.unicodeScalars.filter { terminators.contains($0) }.count
    }

    static func looksFragmented(_ value: String) -> Bool {
        value.components(separatedBy: CharacterSet(charactersIn: "。！？!?"))
            .filter { !$0.trimmed.isEmpty }
            .contains { sentence in
                let clauses = sentence.split(separator: "，", omittingEmptySubsequences: true)
                guard clauses.count >= 4 else { return false }
                return clauses.filter { $0.count <= 5 }.count >= 3
            }
    }
}

public enum GreenSignalGame {
    public static func initialCheckpoint(brief: TextAdventureStoryBrief) -> TextAdventureCheckpoint {
        let narrative = "你抵达\(brief.setting.displayName)，却发现\(brief.motif.shortCopy)。\(brief.pressure.shortCopy)，先决定怎么做。"
        return try! TextAdventureCheckpoint(
            turn: 0,
            narrative: narrative,
            recap: "\(brief.setting.displayName)出现异常，首个谜题已经现身。",
            hint: "先确认线索，再决定立场。",
            status: try! TextAdventureStatus(
                energy: 3,
                signal: 1,
                inventory: [brief.motif.initialItem]
            ),
            choiceA: "先观察细节",
            choiceB: "立刻采取行动",
            outcome: .ongoing
        )
    }

    public static func initialCheckpoint() -> TextAdventureCheckpoint {
        initialCheckpoint(brief: GreenSignalStoryBriefGenerator.make(seed: 0))
    }

    public static func validateTransition(
        from checkpoint: TextAdventureCheckpoint,
        to proposal: TextAdventureCheckpoint
    ) throws {
        guard proposal.turn == checkpoint.turn + 1 else {
            throw TextAdventureValidationError.nonSequentialTurn
        }
    }
}

private extension TextAdventureSetting {
    var displayName: String {
        switch self {
        case .stormValley: "暴雨山谷"
        case .fogHarbor: "雾锁旧港"
        case .desertRelay: "荒漠中继站"
        case .snowObservatory: "雪原观测站"
        case .neonMegacity: "霓虹新城"
        case .orbitalStation: "轨道空间站"
        case .deepSeaLab: "深海实验室"
        case .midnightMuseum: "深夜博物馆"
        case .nightTrain: "夜行列车"
        case .virtualArchive: "虚拟档案城"
        case .ancientTownFestival: "古镇灯会"
        case .robotCompetition: "机器人赛场"
        case .climateDome: "气候穹顶"
        case .lunarHotel: "月球旅馆"
        }
    }
}

private extension TextAdventureMotif {
    var shortCopy: String {
        switch self {
        case .lostSignal: "异常求救信号"
        case .sealedRoom: "反锁的房间"
        case .misleadingMap: "矛盾的旧地图"
        case .midnightVisitor: "陌生的新鲜脚印"
        case .futureMessage: "未来发来的消息"
        case .memoryMismatch: "互相矛盾的记忆"
        case .aiSecret: "AI隐藏的秘密"
        case .livingArtifact: "会回应的文物"
        case .duplicateIdentity: "重复出现的身份"
        case .reversedClock: "逆向行走的钟"
        }
    }

    var initialItem: String {
        switch self {
        case .lostSignal: "旧接收器"
        case .sealedRoom: "铜钥匙"
        case .misleadingMap: "旧地图"
        case .midnightVisitor: "手电筒"
        case .futureMessage: "延时终端"
        case .memoryMismatch: "记忆碎片"
        case .aiSecret: "加密芯片"
        case .livingArtifact: "修复刷"
        case .duplicateIdentity: "身份卡"
        case .reversedClock: "停摆手表"
        }
    }
}

private extension TextAdventurePressure {
    var shortCopy: String {
        switch self {
        case .failingPower: "电量正在下降"
        case .risingWater: "积水正在上涨"
        case .closingWeather: "天气迅速恶化"
        case .unstableRoute: "退路开始松动"
        case .dataErasure: "数据即将清除"
        case .trustBreakdown: "队友开始隐瞒"
        case .publicCountdown: "倒计时已公开"
        case .realityDrift: "现实开始错位"
        }
    }
}

public enum TextAdventureDirection: Equatable, Sendable { case left, right, up, down }
public enum TextAdventureOverlay: Equatable, Sendable { case story, recap, status }
public enum TextAdventurePhase: Equatable, Sendable {
    case idle
    case searchingInspiration
    case generatingFramework
    case playing
    case ending
}

public struct TextAdventurePreparedRun: Equatable, Sendable {
    public let storyBrief: TextAdventureStoryBrief
    public let openingCheckpoint: TextAdventureCheckpoint

    public init(
        storyBrief: TextAdventureStoryBrief,
        openingCheckpoint: TextAdventureCheckpoint
    ) throws {
        guard openingCheckpoint.turn == 0,
              openingCheckpoint.outcome == .ongoing else {
            throw TextAdventureValidationError.invalidOpeningCheckpoint
        }
        self.storyBrief = storyBrief
        self.openingCheckpoint = openingCheckpoint
    }
}

public struct TextAdventureState: Equatable, Sendable {
    public internal(set) var phase: TextAdventurePhase
    public internal(set) var storyBrief: TextAdventureStoryBrief?
    public internal(set) var checkpoint: TextAdventureCheckpoint?
    public internal(set) var overlay: TextAdventureOverlay
    public internal(set) var isRequestInFlight: Bool
    public internal(set) var userSafeError: String?
    public internal(set) var preparationSeed: UInt64?

    public init() {
        phase = .idle
        storyBrief = nil
        checkpoint = nil
        overlay = .story
        isRequestInFlight = false
        userSafeError = nil
        preparationSeed = nil
    }

    init(
        phase: TextAdventurePhase,
        storyBrief: TextAdventureStoryBrief,
        checkpoint: TextAdventureCheckpoint
    ) {
        self.phase = phase
        self.storyBrief = storyBrief
        self.checkpoint = checkpoint
        overlay = .story
        isRequestInFlight = false
        userSafeError = nil
        preparationSeed = nil
    }
}

public enum TextAdventureReducerEvent: Equatable, Sendable {
    case beginPreparation(UInt64)
    case beginFrameworkGeneration
    case preparationSucceeded(TextAdventurePreparedRun)
    case preparationFailed
    case start(TextAdventureStoryBrief)
    case choose(TextAdventureChoice)
    case showRecap
    case showStatus
    case requestSucceeded(TextAdventureCheckpoint)
    case requestFailed
    case reset
}

public enum TextAdventureEffect: Equatable, Sendable {
    case request(TextAdventureStoryBrief, TextAdventureCheckpoint, TextAdventureChoice)
    case cancelRequest
}

public enum TextAdventureReducer {
    @discardableResult
    public static func reduce(
        state: inout TextAdventureState,
        event: TextAdventureReducerEvent
    ) throws -> [TextAdventureEffect] {
        switch event {
        case .beginPreparation(let seed):
            state = TextAdventureState()
            state.phase = .searchingInspiration
            state.preparationSeed = seed
            return [.cancelRequest]
        case .beginFrameworkGeneration:
            guard state.phase == .searchingInspiration else { return [] }
            state.phase = .generatingFramework
            return []
        case .preparationSucceeded(let prepared):
            guard let seed = state.preparationSeed else {
                throw TextAdventureValidationError.missingStoryBrief
            }
            guard prepared.storyBrief.seed == seed else {
                throw TextAdventureValidationError.preparationSeedMismatch
            }
            state = TextAdventureState(
                phase: .playing,
                storyBrief: prepared.storyBrief,
                checkpoint: prepared.openingCheckpoint
            )
            return []
        case .preparationFailed:
            state = TextAdventureState()
            state.userSafeError = "故事准备暂时失败，请重新开始。"
            return []
        case .start(let brief):
            state = TextAdventureState(
                phase: .playing,
                storyBrief: brief,
                checkpoint: GreenSignalGame.initialCheckpoint(brief: brief)
            )
            return [.cancelRequest]
        case .choose(let choice):
            guard state.phase == .playing,
                  !state.isRequestInFlight,
                  let brief = state.storyBrief,
                  let checkpoint = state.checkpoint else { return [] }
            state.isRequestInFlight = true
            state.overlay = .story
            state.userSafeError = nil
            return [.request(brief, checkpoint, choice)]
        case .showRecap:
            guard state.checkpoint != nil else { return [] }
            state.overlay = .recap
            return []
        case .showStatus:
            guard state.checkpoint != nil else { return [] }
            state.overlay = .status
            return []
        case .requestSucceeded(let proposal):
            guard state.isRequestInFlight,
                  state.storyBrief != nil,
                  let checkpoint = state.checkpoint else {
                throw TextAdventureValidationError.missingStoryBrief
            }
            try GreenSignalGame.validateTransition(from: checkpoint, to: proposal)
            state.checkpoint = proposal
            state.phase = proposal.outcome == .ended ? .ending : .playing
            state.overlay = .story
            state.isRequestInFlight = false
            state.userSafeError = nil
            return []
        case .requestFailed:
            guard state.isRequestInFlight else { return [] }
            state.isRequestInFlight = false
            state.overlay = .story
            state.userSafeError = "信号暂时中断，请重试当前选择。"
            return []
        case .reset:
            state = TextAdventureState()
            return [.cancelRequest]
        }
    }
}
