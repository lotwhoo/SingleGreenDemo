import Foundation

public struct ExperienceCapabilities: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let network = Self(rawValue: 1 << 0)
    public static let microphone = Self(rawValue: 1 << 1)
    public static let camera = Self(rawValue: 1 << 2)
    public static let backgroundUpdates = Self(rawValue: 1 << 3)
}

public enum ExperienceActionPlacement: Equatable, Sendable {
    case primary
    case secondary
}

public struct ExperienceActionEvent: RawRepresentable, Hashable, Identifiable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard StableCatalogIdentifierGrammar.isCanonical(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        precondition(
            StableCatalogIdentifierGrammar.isCanonical(rawValue),
            "ExperienceActionEvent must use the stable ASCII identifier grammar"
        )
        self.rawValue = rawValue
    }

    private init(canonicalRawValue: String) {
        self.rawValue = canonicalRawValue
    }

    public var id: String { rawValue }

    public static let tap = Self(canonicalRawValue: "tap")
    public static let swipeUp = Self(canonicalRawValue: "swipe_up")
    public static let swipeDown = Self(canonicalRawValue: "swipe_down")
    public static let triggerAlert = Self(canonicalRawValue: "trigger_alert")

    private static let compatibleDemoEvents: [Self: DemoEvent] = [
        .tap: .tap,
        .swipeUp: .swipeUp,
        .swipeDown: .swipeDown,
        .triggerAlert: .triggerAlert
    ]

    /// Bridges built-in descriptor actions to the legacy generic input surface.
    /// Custom actions are dispatched directly as `ExperienceActionEvent` values.
    public var compatibleDemoEvent: DemoEvent? {
        Self.compatibleDemoEvents[self]
    }

    /// Source-compatible bridge retained for built-in callers.
    /// Extension-owned actions use direct action dispatch and `compatibleDemoEvent` when bridging.
    public var demoEvent: DemoEvent {
        guard let event = compatibleDemoEvent else {
            preconditionFailure("Custom experience actions do not have a legacy DemoEvent")
        }
        return event
    }
}

public enum ExperienceActionTitleSource: Equatable, Sendable {
    case fixed(String)
    case snapshotPrimaryAction
}

public enum ExperienceActionIconSource: Equatable, Sendable {
    case fixed(String)
    case controlStatePrimaryAction(fallback: String)
}

public enum ExperienceActionAvailability: Equatable, Sendable {
    case always
    case controlStateAllowsPrimaryAction
}

public struct ExperienceActionDescriptor: Equatable, Identifiable, Sendable {
    public let id: String
    public let event: ExperienceActionEvent
    public let placement: ExperienceActionPlacement
    public let titleSource: ExperienceActionTitleSource
    public let iconSource: ExperienceActionIconSource
    public let accessibilityLabel: String
    public let availability: ExperienceActionAvailability

    public init(
        id: String,
        event: ExperienceActionEvent,
        placement: ExperienceActionPlacement,
        titleSource: ExperienceActionTitleSource,
        iconSource: ExperienceActionIconSource,
        accessibilityLabel: String,
        availability: ExperienceActionAvailability = .always
    ) {
        self.id = id
        self.event = event
        self.placement = placement
        self.titleSource = titleSource
        self.iconSource = iconSource
        self.accessibilityLabel = accessibilityLabel
        self.availability = availability
    }

    public func resolve(using snapshot: ExperienceSnapshot) -> ResolvedExperienceAction {
        let title = switch titleSource {
        case .fixed(let title): title
        case .snapshotPrimaryAction: snapshot.primaryActionTitle
        }
        let systemImageName = switch iconSource {
        case .fixed(let name): name
        case .controlStatePrimaryAction(let fallback):
            if let candidate = snapshot.controlState?.primaryActionSystemImage.trimmed,
               !candidate.isEmpty {
                candidate
            } else {
                fallback
            }
        }
        let isEnabled = switch availability {
        case .always: true
        case .controlStateAllowsPrimaryAction:
            snapshot.controlState?.allowsPrimaryAction ?? false
        }

        return ResolvedExperienceAction(
            id: id,
            event: event,
            placement: placement,
            title: title,
            systemImageName: systemImageName,
            accessibilityLabel: accessibilityLabel,
            isEnabled: isEnabled
        )
    }
}

public struct ResolvedExperienceAction: Equatable, Identifiable, Sendable {
    public let id: String
    public let event: ExperienceActionEvent
    public let placement: ExperienceActionPlacement
    public let title: String
    public let systemImageName: String
    public let accessibilityLabel: String
    public let isEnabled: Bool

    public init(
        id: String,
        event: ExperienceActionEvent,
        placement: ExperienceActionPlacement,
        title: String,
        systemImageName: String,
        accessibilityLabel: String,
        isEnabled: Bool
    ) {
        self.id = id
        self.event = event
        self.placement = placement
        self.title = title
        self.systemImageName = systemImageName
        self.accessibilityLabel = accessibilityLabel
        self.isEnabled = isEnabled
    }
}

public struct ExperienceDescriptor: Equatable, Identifiable, Sendable {
    public let kind: ExperienceKind
    public let displayName: String
    public let detail: String
    public let systemImageName: String
    public let capabilities: ExperienceCapabilities
    public let actions: [ExperienceActionDescriptor]

    public var id: String { kind.rawValue }

    public init(
        kind: ExperienceKind,
        displayName: String,
        detail: String,
        systemImageName: String,
        capabilities: ExperienceCapabilities = [],
        actions: [ExperienceActionDescriptor]
    ) {
        self.kind = kind
        self.displayName = displayName
        self.detail = detail
        self.systemImageName = systemImageName
        self.capabilities = capabilities
        self.actions = actions
    }
}

public enum ExperienceMetadataField: Equatable, Sendable {
    case displayName
    case detail
    case systemImageName
}

public enum ExperienceCatalogError: Error, Equatable, Sendable {
    case emptyCatalog
    case blankKindIdentifier
    case invalidKindIdentifier(String)
    case duplicateKind(ExperienceKind)
    case missingMetadata(kind: ExperienceKind, field: ExperienceMetadataField)
    case blankActionIdentifier(kind: ExperienceKind)
    case invalidActionIdentifier(kind: ExperienceKind, id: String)
    case blankActionEvent(kind: ExperienceKind, actionID: String)
    case invalidActionEvent(kind: ExperienceKind, actionID: String, event: String)
    case duplicateActionIdentifier(kind: ExperienceKind, id: String)
    case blankFixedActionTitle(kind: ExperienceKind, actionID: String)
    case blankActionIcon(kind: ExperienceKind, actionID: String)
    case blankAccessibilityLabel(kind: ExperienceKind, actionID: String)
    case multiplePrimaryActions(kind: ExperienceKind)
}

public struct ExperienceCatalog: Equatable, Sendable {
    public let descriptors: [ExperienceDescriptor]
    private let descriptorsByKind: [ExperienceKind: ExperienceDescriptor]

    public init(descriptors: [ExperienceDescriptor]) throws {
        guard !descriptors.isEmpty else {
            throw ExperienceCatalogError.emptyCatalog
        }

        var validated: [ExperienceKind: ExperienceDescriptor] = [:]
        for descriptor in descriptors {
            guard !descriptor.kind.rawValue.trimmed.isEmpty else {
                throw ExperienceCatalogError.blankKindIdentifier
            }
            guard StableCatalogIdentifierGrammar.isCanonical(descriptor.kind.rawValue) else {
                throw ExperienceCatalogError.invalidKindIdentifier(descriptor.kind.rawValue)
            }
            guard validated[descriptor.kind] == nil else {
                throw ExperienceCatalogError.duplicateKind(descriptor.kind)
            }
            try Self.validate(descriptor)
            validated[descriptor.kind] = descriptor
        }

        self.descriptorsByKind = validated
        let builtInKinds = Set(ExperienceKind.builtInCases)
        let orderedBuiltIns = ExperienceKind.builtInCases.compactMap { validated[$0] }
        let customDescriptors = descriptors.filter { !builtInKinds.contains($0.kind) }
        self.descriptors = orderedBuiltIns + customDescriptors
    }

    public func descriptor(for kind: ExperienceKind) -> ExperienceDescriptor? {
        descriptorsByKind[kind]
    }

    private static func validate(_ descriptor: ExperienceDescriptor) throws {
        let metadata: [(ExperienceMetadataField, String)] = [
            (.displayName, descriptor.displayName),
            (.detail, descriptor.detail),
            (.systemImageName, descriptor.systemImageName)
        ]
        for (field, value) in metadata where value.trimmed.isEmpty {
            throw ExperienceCatalogError.missingMetadata(kind: descriptor.kind, field: field)
        }

        var actionIDs: Set<String> = []
        var primaryCount = 0
        for action in descriptor.actions {
            guard !action.id.trimmed.isEmpty else {
                throw ExperienceCatalogError.blankActionIdentifier(kind: descriptor.kind)
            }
            guard StableCatalogIdentifierGrammar.isCanonical(action.id) else {
                throw ExperienceCatalogError.invalidActionIdentifier(
                    kind: descriptor.kind,
                    id: action.id
                )
            }
            let actionID = action.id
            guard actionIDs.insert(actionID).inserted else {
                throw ExperienceCatalogError.duplicateActionIdentifier(
                    kind: descriptor.kind,
                    id: actionID
                )
            }
            guard !action.event.rawValue.trimmed.isEmpty else {
                throw ExperienceCatalogError.blankActionEvent(
                    kind: descriptor.kind,
                    actionID: action.id
                )
            }
            guard StableCatalogIdentifierGrammar.isCanonical(action.event.rawValue) else {
                throw ExperienceCatalogError.invalidActionEvent(
                    kind: descriptor.kind,
                    actionID: action.id,
                    event: action.event.rawValue
                )
            }
            if action.placement == .primary {
                primaryCount += 1
            }
            if case .fixed(let title) = action.titleSource, title.trimmed.isEmpty {
                throw ExperienceCatalogError.blankFixedActionTitle(
                    kind: descriptor.kind,
                    actionID: action.id
                )
            }
            let iconName = switch action.iconSource {
            case .fixed(let name): name
            case .controlStatePrimaryAction(let fallback): fallback
            }
            guard !iconName.trimmed.isEmpty else {
                throw ExperienceCatalogError.blankActionIcon(
                    kind: descriptor.kind,
                    actionID: action.id
                )
            }
            guard !action.accessibilityLabel.trimmed.isEmpty else {
                throw ExperienceCatalogError.blankAccessibilityLabel(
                    kind: descriptor.kind,
                    actionID: action.id
                )
            }
        }
        guard primaryCount <= 1 else {
            throw ExperienceCatalogError.multiplePrimaryActions(kind: descriptor.kind)
        }
    }
}

public enum BuiltInExperienceActions {
    public static let primaryID = "primary"
    public static let swipeUpID = "swipe_up"
    public static let tapID = "tap"
    public static let swipeDownID = "swipe_down"

    public static func primary(
        event: ExperienceActionEvent,
        icon: String,
        accessibilityLabel: String
    ) -> ExperienceActionDescriptor {
        ExperienceActionDescriptor(
            id: primaryID,
            event: event,
            placement: .primary,
            titleSource: .snapshotPrimaryAction,
            iconSource: .fixed(icon),
            accessibilityLabel: accessibilityLabel
        )
    }

    public static let swipeUp = ExperienceActionDescriptor(
        id: swipeUpID,
        event: .swipeUp,
        placement: .secondary,
        titleSource: .fixed("上滑"),
        iconSource: .fixed("arrow.up"),
        accessibilityLabel: "上滑"
    )

    public static let tap = ExperienceActionDescriptor(
        id: tapID,
        event: .tap,
        placement: .secondary,
        titleSource: .fixed("点击"),
        iconSource: .fixed("hand.tap"),
        accessibilityLabel: "点击"
    )

    public static let swipeDown = ExperienceActionDescriptor(
        id: swipeDownID,
        event: .swipeDown,
        placement: .secondary,
        titleSource: .fixed("下滑"),
        iconSource: .fixed("arrow.down"),
        accessibilityLabel: "下滑"
    )

    public static let standardSecondary = [swipeUp, tap, swipeDown]
}
