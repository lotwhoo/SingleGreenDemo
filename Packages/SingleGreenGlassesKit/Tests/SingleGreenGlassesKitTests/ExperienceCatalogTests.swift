import XCTest
@testable import SingleGreenGlassesKit

@MainActor
final class ExperienceCatalogTests: XCTestCase {
    func testExperienceKindRawIDsAndOrderArePinnedCompatibilityContract() {
        XCTAssertEqual(
            ExperienceKind.allCases,
            [.conversation, .systemStatus, .navigation, .notification, .caption]
        )
        XCTAssertEqual(
            ExperienceKind.allCases.map(\.rawValue),
            ["conversation", "systemStatus", "navigation", "notification", "caption"]
        )
    }

    func testOpenIdentifiersAcceptOnlyCanonicalCaseSensitiveASCIIGrammar() {
        let accepted = [
            "a",
            "A1",
            "test.focus-Coach_2",
            "systemStatus",
            "trigger_alert"
        ]
        for identifier in accepted {
            XCTAssertEqual(ExperienceKind(rawValue: identifier)?.rawValue, identifier)
            XCTAssertEqual(ExperienceActionEvent(rawValue: identifier)?.rawValue, identifier)
        }

        let rejected = [
            "",
            " wrapped",
            "wrapped ",
            "line\nfeed",
            "control\u{7F}",
            ".leadingDot",
            "slash/value",
            "café"
        ]
        for identifier in rejected {
            XCTAssertNil(ExperienceKind(rawValue: identifier), "Unexpected kind: \(identifier)")
            XCTAssertNil(
                ExperienceActionEvent(rawValue: identifier),
                "Unexpected action event: \(identifier)"
            )
        }
    }

    func testBuiltInDescriptorsPinCompleteMetadataCapabilitiesAndActions() {
        let controller = VoiceConversationController(dependencies: missingDependencies())
        let sessions: [any ExperienceSession] = [
            CaptionExperience(),
            NotificationExperience(),
            NavigationExperience(),
            SystemStatusExperience(),
            AIConversationExperience(controller: controller, providerDetail: "Opaque host detail")
        ]
        let runtime = ExperienceRuntime(sessions: sessions)
        let swipeUp = expectedSecondaryAction(
            id: "swipe_up",
            event: .swipeUp,
            title: "上滑",
            icon: "arrow.up"
        )
        let tap = expectedSecondaryAction(
            id: "tap",
            event: .tap,
            title: "点击",
            icon: "hand.tap"
        )
        let swipeDown = expectedSecondaryAction(
            id: "swipe_down",
            event: .swipeDown,
            title: "下滑",
            icon: "arrow.down"
        )
        let expected = [
            ExperienceDescriptor(
                kind: .conversation,
                displayName: "AI 对话",
                detail: "Opaque host detail",
                systemImageName: "waveform.circle",
                capabilities: [.network, .microphone, .backgroundUpdates],
                actions: [ExperienceActionDescriptor(
                    id: "primary",
                    event: .tap,
                    placement: .primary,
                    titleSource: .snapshotPrimaryAction,
                    iconSource: .controlStatePrimaryAction(fallback: "waveform"),
                    accessibilityLabel: "控制 AI 对话",
                    availability: .controlStateAllowsPrimaryAction
                )]
            ),
            ExperienceDescriptor(
                kind: .systemStatus,
                displayName: "状态",
                detail: "体验场景 · 本地样例",
                systemImageName: "gauge.with.dots.needle.33percent",
                capabilities: [],
                actions: [
                    expectedPrimaryAction(
                        event: .tap,
                        icon: "arrow.clockwise",
                        accessibilityLabel: "展开或收起状态"
                    ),
                    swipeUp, tap, swipeDown
                ]
            ),
            ExperienceDescriptor(
                kind: .navigation,
                displayName: "导航",
                detail: "体验场景 · 本地样例",
                systemImageName: "location.north.line",
                capabilities: [],
                actions: [
                    expectedPrimaryAction(
                        event: .tap,
                        icon: "location.fill",
                        accessibilityLabel: "展开或收起导航详情"
                    ),
                    swipeUp, tap, swipeDown
                ]
            ),
            ExperienceDescriptor(
                kind: .notification,
                displayName: "通知",
                detail: "体验场景 · 本地样例",
                systemImageName: "bell",
                capabilities: [],
                actions: [
                    expectedPrimaryAction(
                        event: .triggerAlert,
                        icon: "bell.badge.fill",
                        accessibilityLabel: "显示提醒"
                    ),
                    tap, swipeDown
                ]
            ),
            ExperienceDescriptor(
                kind: .caption,
                displayName: "字幕 / 提词",
                detail: "体验场景 · 本地样例",
                systemImageName: "captions.bubble",
                capabilities: [],
                actions: [
                    expectedPrimaryAction(
                        event: .tap,
                        icon: "text.bubble.fill",
                        accessibilityLabel: "播放或暂停字幕"
                    ),
                    swipeUp, tap, swipeDown
                ]
            )
        ]

        XCTAssertEqual(runtime.availableDescriptors, expected)
        XCTAssertEqual(runtime.availableDescriptors.map(\.id), [
            "conversation", "systemStatus", "navigation", "notification", "caption"
        ])
    }

    func testCatalogSortsDescriptorsByExperienceKindAllCases() throws {
        let catalog = try ExperienceCatalog(descriptors: [
            descriptor(kind: .caption),
            descriptor(kind: .systemStatus),
            descriptor(kind: .conversation)
        ])

        XCTAssertEqual(catalog.descriptors.map(\.kind), [.conversation, .systemStatus, .caption])
    }

    func testCatalogKeepsBuiltInOrderThenCustomRegistrationOrder() throws {
        let firstCustom = ExperienceKind("test.focusCoach")
        let secondCustom = ExperienceKind("test.objectReader")
        let catalog = try ExperienceCatalog(descriptors: [
            descriptor(kind: firstCustom),
            descriptor(kind: .caption),
            descriptor(kind: .systemStatus),
            descriptor(kind: secondCustom),
            descriptor(kind: .conversation)
        ])

        XCTAssertEqual(
            catalog.descriptors.map(\.kind),
            [.conversation, .systemStatus, .caption, firstCustom, secondCustom]
        )
    }

    func testCatalogRejectsEmptyDuplicateKindAndMissingMetadata() throws {
        XCTAssertThrowsError(try ExperienceCatalog(descriptors: [])) {
            XCTAssertEqual($0 as? ExperienceCatalogError, .emptyCatalog)
        }
        let navigation = descriptor(kind: .navigation)
        XCTAssertThrowsError(try ExperienceCatalog(descriptors: [navigation, navigation])) {
            XCTAssertEqual($0 as? ExperienceCatalogError, .duplicateKind(.navigation))
        }

        let missing: [(ExperienceMetadataField, ExperienceDescriptor)] = [
            (.displayName, descriptor(kind: .caption, displayName: " \t")),
            (.detail, descriptor(kind: .caption, detail: "\n")),
            (.systemImageName, descriptor(kind: .caption, systemImageName: ""))
        ]
        for (field, invalid) in missing {
            XCTAssertThrowsError(try ExperienceCatalog(descriptors: [invalid])) {
                XCTAssertEqual(
                    $0 as? ExperienceCatalogError,
                    .missingMetadata(kind: .caption, field: field)
                )
            }
        }
    }

    func testCatalogRejectsInvalidActionIdentifiersAndMultiplePrimaries() {
        XCTAssertCatalogError(
            actions: [action(id: " ")],
            equals: .blankActionIdentifier(kind: .caption)
        )
        XCTAssertCatalogError(
            actions: [action(id: "same"), action(id: "same", placement: .secondary)],
            equals: .duplicateActionIdentifier(kind: .caption, id: "same")
        )
        XCTAssertCatalogError(
            actions: [action(id: "one"), action(id: "two")],
            equals: .multiplePrimaryActions(kind: .caption)
        )
        XCTAssertCatalogError(
            actions: [action(id: "primary ")],
            equals: .invalidActionIdentifier(kind: .caption, id: "primary ")
        )
        XCTAssertCatalogError(
            actions: [action(id: "\tprimary")],
            equals: .invalidActionIdentifier(kind: .caption, id: "\tprimary")
        )
        XCTAssertCatalogError(
            actions: [action(id: "primary/name")],
            equals: .invalidActionIdentifier(kind: .caption, id: "primary/name")
        )
        XCTAssertCatalogError(
            actions: [action(id: "primary\u{7F}")],
            equals: .invalidActionIdentifier(kind: .caption, id: "primary\u{7F}")
        )
    }

    func testCatalogRejectsWhitespaceAliasBeforeItCanCollideWithCanonicalActionID() {
        XCTAssertCatalogError(
            actions: [
                action(id: "same"),
                action(id: " same ", placement: .secondary)
            ],
            equals: .invalidActionIdentifier(kind: .caption, id: " same ")
        )
    }

    func testCatalogRejectsBlankActionPresentationMetadata() {
        XCTAssertCatalogError(
            actions: [action(titleSource: .fixed("\t"))],
            equals: .blankFixedActionTitle(kind: .caption, actionID: "primary")
        )
        XCTAssertCatalogError(
            actions: [action(iconSource: .fixed(" "))],
            equals: .blankActionIcon(kind: .caption, actionID: "primary")
        )
        XCTAssertCatalogError(
            actions: [action(iconSource: .controlStatePrimaryAction(fallback: "\n"))],
            equals: .blankActionIcon(kind: .caption, actionID: "primary")
        )
        XCTAssertCatalogError(
            actions: [action(accessibilityLabel: "")],
            equals: .blankAccessibilityLabel(kind: .caption, actionID: "primary")
        )
    }

    func testInteractiveActionEventsMapToCompatibleDemoEvents() {
        XCTAssertEqual(ExperienceActionEvent.tap.demoEvent, .tap)
        XCTAssertEqual(ExperienceActionEvent.swipeUp.demoEvent, .swipeUp)
        XCTAssertEqual(ExperienceActionEvent.swipeDown.demoEvent, .swipeDown)
        XCTAssertEqual(ExperienceActionEvent.triggerAlert.demoEvent, .triggerAlert)
        XCTAssertNil(ExperienceActionEvent("test.customAction").compatibleDemoEvent)
    }

    func testCustomExperienceRegistersActivatesAndDispatchesThroughGenericRuntimeControls() async {
        let customKind = ExperienceKind("test.focusCoach")
        let customEvent = ExperienceActionEvent("test.advancePrompt")
        let custom = OpenRegistrationExperience(kind: customKind, action: customEvent)
        let runtime = ExperienceRuntime(sessions: [
            custom,
            TrackingExperience(
                descriptor: descriptor(kind: .caption),
                allowsAction: true
            ),
            TrackingExperience(
                descriptor: descriptor(kind: .systemStatus),
                allowsAction: true
            )
        ])

        XCTAssertEqual(runtime.availableKinds, [.systemStatus, .caption, customKind])
        XCTAssertEqual(runtime.selectedKind, .systemStatus)

        await runtime.activate(customKind)

        XCTAssertEqual(runtime.selectedKind, customKind)
        XCTAssertEqual(runtime.selectedDescriptor.kind, customKind)
        XCTAssertEqual(runtime.selectedDescriptor.displayName, "Focus coach")
        XCTAssertEqual(runtime.activeActions.map(\.id), ["advance_prompt"])
        XCTAssertEqual(runtime.activeActions.first?.event, customEvent)
        XCTAssertEqual(runtime.activeActions.first?.title, "Advance prompt")
        XCTAssertEqual(runtime.activeActions.first?.systemImageName, "forward.fill")
        XCTAssertTrue(runtime.activeActions.first?.isEnabled == true)
        XCTAssertEqual(runtime.controlState?.statusTitle, "Ready")

        await runtime.performAction(id: "advance_prompt")

        XCTAssertEqual(custom.receivedActions, [customEvent])
        XCTAssertEqual(custom.receivedLegacyEvents, [])
        XCTAssertEqual(runtime.lastEventDescription, customEvent.rawValue)
        XCTAssertEqual(runtime.scene.revision, 1)
    }

    func testActionResolutionUsesLatestSnapshotForTitleIconAndAvailability() {
        let descriptor = ExperienceActionDescriptor(
            id: "primary",
            event: .tap,
            placement: .primary,
            titleSource: .snapshotPrimaryAction,
            iconSource: .controlStatePrimaryAction(fallback: "fallback"),
            accessibilityLabel: "Control",
            availability: .controlStateAllowsPrimaryAction
        )
        let disabled = descriptor.resolve(using: snapshot(
            title: "开始对话",
            controlState: nil
        ))
        let enabled = descriptor.resolve(using: snapshot(
            title: "结束说话",
            controlState: ExperienceControlState(
                statusTitle: "正在听",
                statusDetail: "Test",
                errorMessage: nil,
                primaryActionSystemImage: "stop.fill",
                allowsPrimaryAction: true
            )
        ))
        let trimmed = descriptor.resolve(using: snapshot(
            title: "结束说话",
            controlState: ExperienceControlState(
                statusTitle: "正在听",
                statusDetail: "Test",
                errorMessage: nil,
                primaryActionSystemImage: "  stop.circle.fill \n",
                allowsPrimaryAction: true
            )
        ))
        let blankUsesFallback = descriptor.resolve(using: snapshot(
            title: "开始对话",
            controlState: ExperienceControlState(
                statusTitle: "待命",
                statusDetail: "Test",
                errorMessage: nil,
                primaryActionSystemImage: " \t\n ",
                allowsPrimaryAction: true
            )
        ))

        XCTAssertEqual(disabled.title, "开始对话")
        XCTAssertEqual(disabled.systemImageName, "fallback")
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertEqual(enabled.title, "结束说话")
        XCTAssertEqual(enabled.systemImageName, "stop.fill")
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertEqual(trimmed.systemImageName, "stop.circle.fill")
        XCTAssertEqual(blankUsesFallback.systemImageName, "fallback")
    }

    func testRuntimeControlOnlyConversationSnapshotRefreshesActiveActionWithoutSceneChange() async {
        let action = ExperienceActionDescriptor(
            id: "primary",
            event: .tap,
            placement: .primary,
            titleSource: .snapshotPrimaryAction,
            iconSource: .controlStatePrimaryAction(fallback: "waveform"),
            accessibilityLabel: "控制 AI 对话",
            availability: .controlStateAllowsPrimaryAction
        )
        let descriptor = CapabilityCatalogFixtureExample.makeDescriptor(
            kind: .conversation,
            displayName: "AI test",
            detail: "Control-only fixture",
            systemImageName: "waveform.circle",
            capabilities: [.network, .microphone, .backgroundUpdates],
            actions: [action]
        )
        let initialControl = ExperienceControlState(
            statusTitle: "正在连接",
            statusDetail: "Test",
            errorMessage: nil,
            primaryActionSystemImage: "hourglass",
            allowsPrimaryAction: false
        )
        let session = CapabilityCatalogFixtureExperience(
            descriptor: descriptor,
            primaryActionTitle: "连接语音识别",
            controlState: initialControl
        )
        let runtime = ExperienceRuntime(sessions: [session])
        let unchangedScene = runtime.scene

        XCTAssertEqual(runtime.activeActions.first?.title, "连接语音识别")
        XCTAssertEqual(runtime.activeActions.first?.systemImageName, "hourglass")
        XCTAssertFalse(runtime.activeActions.first?.isEnabled ?? true)

        session.emitControlOnlySnapshot(
            primaryActionTitle: "结束说话",
            controlState: ExperienceControlState(
                statusTitle: "正在听",
                statusDetail: "Test",
                errorMessage: nil,
                primaryActionSystemImage: "stop.fill",
                allowsPrimaryAction: true
            )
        )
        await waitUntil { runtime.activeActions.first?.title == "结束说话" }

        XCTAssertEqual(runtime.scene, unchangedScene)
        XCTAssertEqual(runtime.activeActions.first?.title, "结束说话")
        XCTAssertEqual(runtime.activeActions.first?.systemImageName, "stop.fill")
        XCTAssertTrue(runtime.activeActions.first?.isEnabled == true)
    }

    func testRuntimeDoesNotSendUnknownOrDisabledActionsToSession() async {
        let session = TrackingExperience(
            descriptor: descriptor(
                kind: .caption,
                actions: [action(availability: .controlStateAllowsPrimaryAction)]
            ),
            allowsAction: false
        )
        let runtime = ExperienceRuntime(sessions: [session])

        await runtime.performAction(id: "unknown")
        await runtime.performAction(id: "primary")

        XCTAssertEqual(session.events, [])
        XCTAssertEqual(runtime.lastEventDescription, "ready")
    }

    func testRuntimePerformsEnabledActionThroughMappedEventAndPublishesSnapshot() async {
        let session = TrackingExperience(
            descriptor: descriptor(
                kind: .notification,
                actions: [action(event: .triggerAlert)]
            ),
            allowsAction: true
        )
        let runtime = ExperienceRuntime(sessions: [session])

        await runtime.performAction(id: "primary")

        XCTAssertEqual(session.events, [.triggerAlert])
        XCTAssertEqual(runtime.lastEventDescription, "trigger_alert")
        XCTAssertEqual(runtime.scene.revision, 1)
    }

    func testDelayedActionFromPreviousSelectionDoesNotReachNewExperience() async {
        let origin = TrackingExperience(
            descriptor: descriptor(kind: .navigation),
            allowsAction: true
        )
        let destination = TrackingExperience(
            descriptor: descriptor(kind: .caption),
            allowsAction: true
        )
        let runtime = ExperienceRuntime(sessions: [origin, destination])
        let capturedKind = runtime.selectedKind
        let capturedActionID = runtime.activeActions[0].id

        await runtime.activate(.caption)
        await runtime.performAction(id: capturedActionID, expectedKind: capturedKind)

        XCTAssertEqual(runtime.selectedKind, .caption)
        XCTAssertEqual(origin.events, [])
        XCTAssertEqual(destination.events, [])
        XCTAssertEqual(runtime.lastEventDescription, "activate_caption")
    }

    func testDelayedResetFromPreviousSelectionDoesNotResetNewExperience() async {
        let origin = TrackingExperience(
            descriptor: descriptor(kind: .navigation),
            allowsAction: true
        )
        let destination = TrackingExperience(
            descriptor: descriptor(kind: .caption),
            allowsAction: true
        )
        let runtime = ExperienceRuntime(sessions: [origin, destination])
        let capturedKind = runtime.selectedKind

        await runtime.activate(.caption)
        let destinationResetCount = destination.resetCount
        await runtime.handle(.reset, expectedKind: capturedKind)

        XCTAssertEqual(runtime.selectedKind, .caption)
        XCTAssertEqual(destination.resetCount, destinationResetCount)
        XCTAssertEqual(runtime.lastEventDescription, "activate_caption")
    }

    func testDelayedActivationIntentFromPreviousSelectionDoesNotResetDestination() async {
        let origin = TrackingExperience(
            descriptor: descriptor(kind: .navigation),
            allowsAction: true
        )
        let delayedDestination = TrackingExperience(
            descriptor: descriptor(kind: .caption),
            allowsAction: true
        )
        let winningDestination = TrackingExperience(
            descriptor: descriptor(kind: .notification),
            allowsAction: true
        )
        let runtime = ExperienceRuntime(sessions: [
            origin,
            delayedDestination,
            winningDestination
        ])
        let capturedOrigin = runtime.selectedKind

        await runtime.activate(.notification)
        await runtime.activate(.caption, expectedKind: capturedOrigin)

        XCTAssertEqual(runtime.selectedKind, .notification)
        XCTAssertEqual(delayedDestination.resetCount, 0)
        XCTAssertEqual(winningDestination.resetCount, 1)
        XCTAssertEqual(runtime.lastEventDescription, "activate_notification")
    }

    func testSupersededActivationNeverResetsItsDestination() async {
        let origin = SuspendedOriginResetExperience()
        let supersededDestination = TrackingExperience(
            descriptor: descriptor(kind: .caption),
            allowsAction: true
        )
        let winningDestination = TrackingExperience(
            descriptor: descriptor(kind: .notification),
            allowsAction: true
        )
        let runtime = ExperienceRuntime(sessions: [
            origin,
            supersededDestination,
            winningDestination
        ])

        let supersededActivation = Task { await runtime.activate(.caption) }
        await waitUntil { origin.isFirstResetSuspended }
        await runtime.activate(.notification)

        origin.completeFirstReset()
        await supersededActivation.value

        XCTAssertEqual(runtime.selectedKind, .notification)
        XCTAssertEqual(supersededDestination.resetCount, 0)
        XCTAssertEqual(winningDestination.resetCount, 1)
        XCTAssertEqual(runtime.lastEventDescription, "activate_notification")
    }

    func testBuiltInPrimaryActionsPreserveFourLocalExperienceTransitions() async {
        let runtime = ExperienceRuntime()

        XCTAssertEqual(runtime.scene.presentation, .compact)
        await runtime.performAction(id: "primary")
        XCTAssertEqual(runtime.scene.presentation, .focused)

        await runtime.activate(.navigation)
        await runtime.performAction(id: "primary")
        XCTAssertEqual(runtime.scene.presentation, .focused)

        await runtime.activate(.notification)
        await runtime.performAction(id: "primary")
        XCTAssertEqual(runtime.scene.presentation, .alert)
        XCTAssertEqual(runtime.lastEventDescription, "trigger_alert")

        await runtime.activate(.caption)
        await runtime.performAction(id: "primary")
        XCTAssertEqual(runtime.primaryActionTitle, "暂停字幕")
    }

    func testConversationPrimaryActionPreservesControllerFailureTransition() async {
        let controller = VoiceConversationController(dependencies: missingDependencies())
        let runtime = ExperienceRuntime(sessions: [
            AIConversationExperience(controller: controller, providerDetail: "Test providers")
        ])

        XCTAssertTrue(runtime.activeActions.first?.isEnabled == true)
        await runtime.performAction(id: "primary")

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(runtime.lastEventDescription, VoiceConversationState.failed.rawValue)
    }

    func testPerformActionUsesSameGenerationIsolationAsCompatibleHandleAPI() async {
        let source = SuspendedActionExperience()
        let destination = TrackingExperience(
            descriptor: descriptor(kind: .caption),
            allowsAction: true
        )
        let runtime = ExperienceRuntime(sessions: [source, destination])

        let staleAction = Task { await runtime.performAction(id: "primary") }
        await waitUntil { source.isHandling }
        await runtime.activate(.caption)
        source.complete()
        await staleAction.value

        XCTAssertEqual(runtime.selectedKind, .caption)
        XCTAssertEqual(runtime.scene.sceneID, "tracking_caption")
        XCTAssertEqual(runtime.lastEventDescription, "activate_caption")
    }

    func testNewerActionOnSameSessionRejectsOlderActionCompletion() async {
        let session = SameSessionSupersedingActionExperience()
        let runtime = ExperienceRuntime(sessions: [session])

        let olderAction = Task { await runtime.performAction(id: "slow") }
        await waitUntil { session.isFirstActionSuspended }
        await runtime.performAction(id: "newer")

        XCTAssertEqual(runtime.scene.revision, 2)
        XCTAssertEqual(runtime.lastEventDescription, "swipe_down")

        session.completeFirstAction()
        await olderAction.value

        XCTAssertEqual(session.scene.revision, 99)
        XCTAssertEqual(runtime.scene.revision, 2)
        XCTAssertEqual(runtime.lastEventDescription, "swipe_down")
    }

    func testCustomDescriptorFixtureFeedsHostFacingDataWithoutKindSwitches() {
        let custom = ExperienceDescriptor(
            kind: .caption,
            displayName: "Custom registered experience",
            detail: "Fixture-owned metadata",
            systemImageName: "wand.and.stars",
            capabilities: [.camera],
            actions: [
                ExperienceActionDescriptor(
                    id: "launch",
                    event: .tap,
                    placement: .secondary,
                    titleSource: .fixed("Launch"),
                    iconSource: .fixed("play.fill"),
                    accessibilityLabel: "Launch fixture"
                )
            ]
        )
        let runtime = ExperienceRuntime(sessions: [
            CapabilityCatalogFixtureExperience(descriptor: custom)
        ])

        XCTAssertEqual(runtime.selectedDescriptor, custom)
        XCTAssertEqual(runtime.availableDescriptors, [custom])
        XCTAssertEqual(runtime.activeActions.map(\.id), ["launch"])
        XCTAssertEqual(runtime.activeActions.first?.title, "Launch")
    }

    private func XCTAssertCatalogError(
        actions: [ExperienceActionDescriptor],
        equals expected: ExperienceCatalogError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ExperienceCatalog(descriptors: [descriptor(kind: .caption, actions: actions)]),
            file: file,
            line: line
        ) {
            XCTAssertEqual($0 as? ExperienceCatalogError, expected, file: file, line: line)
        }
    }

    private func waitUntil(
        iterations: Int = 500,
        _ predicate: @MainActor () -> Bool
    ) async {
        for _ in 0..<iterations {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for deterministic fixture")
    }
}

private func descriptor(
    kind: ExperienceKind,
    displayName: String = "Test experience",
    detail: String = "Test detail",
    systemImageName: String = "testtube.2",
    actions: [ExperienceActionDescriptor] = [action()]
) -> ExperienceDescriptor {
    ExperienceDescriptor(
        kind: kind,
        displayName: displayName,
        detail: detail,
        systemImageName: systemImageName,
        actions: actions
    )
}

private func expectedPrimaryAction(
    event: ExperienceActionEvent,
    icon: String,
    accessibilityLabel: String
) -> ExperienceActionDescriptor {
    ExperienceActionDescriptor(
        id: "primary",
        event: event,
        placement: .primary,
        titleSource: .snapshotPrimaryAction,
        iconSource: .fixed(icon),
        accessibilityLabel: accessibilityLabel,
        availability: .always
    )
}

private func expectedSecondaryAction(
    id: String,
    event: ExperienceActionEvent,
    title: String,
    icon: String
) -> ExperienceActionDescriptor {
    ExperienceActionDescriptor(
        id: id,
        event: event,
        placement: .secondary,
        titleSource: .fixed(title),
        iconSource: .fixed(icon),
        accessibilityLabel: title,
        availability: .always
    )
}

private func action(
    id: String = "primary",
    event: ExperienceActionEvent = .tap,
    placement: ExperienceActionPlacement = .primary,
    titleSource: ExperienceActionTitleSource = .fixed("Run"),
    iconSource: ExperienceActionIconSource = .fixed("play.fill"),
    accessibilityLabel: String = "Run test action",
    availability: ExperienceActionAvailability = .always
) -> ExperienceActionDescriptor {
    ExperienceActionDescriptor(
        id: id,
        event: event,
        placement: placement,
        titleSource: titleSource,
        iconSource: iconSource,
        accessibilityLabel: accessibilityLabel,
        availability: availability
    )
}

private func snapshot(
    title: String,
    controlState: ExperienceControlState?
) -> ExperienceSnapshot {
    ExperienceSnapshot(
        scene: HUDScene(sceneID: "test", revision: 0, presentation: .compact, elements: []),
        primaryActionTitle: title,
        eventDescription: "test",
        controlState: controlState
    )
}

@MainActor
private final class OpenRegistrationExperience: ExperienceSession {
    let descriptor: ExperienceDescriptor
    private(set) var scene: HUDScene
    let primaryActionTitle = "Advance prompt"
    let controlState: ExperienceControlState? = ExperienceControlState(
        statusTitle: "Ready",
        statusDetail: "Extension-owned control state",
        errorMessage: nil,
        primaryActionSystemImage: "forward.fill",
        allowsPrimaryAction: true
    )
    private(set) var receivedActions: [ExperienceActionEvent] = []
    private(set) var receivedLegacyEvents: [DemoEvent] = []

    init(kind: ExperienceKind, action: ExperienceActionEvent) {
        self.descriptor = ExperienceDescriptor(
            kind: kind,
            displayName: "Focus coach",
            detail: "Test-only independently registered experience",
            systemImageName: "scope",
            capabilities: [.backgroundUpdates],
            actions: [
                ExperienceActionDescriptor(
                    id: "advance_prompt",
                    event: action,
                    placement: .primary,
                    titleSource: .snapshotPrimaryAction,
                    iconSource: .controlStatePrimaryAction(fallback: "forward.fill"),
                    accessibilityLabel: "Advance focus prompt",
                    availability: .controlStateAllowsPrimaryAction
                )
            ]
        )
        self.scene = HUDScene(
            sceneID: "open_registration_\(kind.rawValue)",
            revision: 0,
            presentation: .compact,
            elements: []
        )
    }

    func handle(_ event: DemoEvent) async {
        receivedLegacyEvents.append(event)
    }

    func handle(_ action: ExperienceActionEvent) async {
        receivedActions.append(action)
        scene = HUDScene(
            sceneID: scene.sceneID,
            revision: scene.revision + 1,
            presentation: scene.presentation,
            elements: scene.elements
        )
    }

    func reset() async {}
}

@MainActor
private final class TrackingExperience: ExperienceSession {
    let descriptor: ExperienceDescriptor
    private(set) var events: [DemoEvent] = []
    private(set) var resetCount = 0
    private(set) var scene: HUDScene
    let primaryActionTitle = "Run"
    let controlState: ExperienceControlState?

    init(descriptor: ExperienceDescriptor, allowsAction: Bool) {
        self.descriptor = descriptor
        self.scene = HUDScene(
            sceneID: "tracking_\(descriptor.kind.rawValue)",
            revision: 0,
            presentation: .compact,
            elements: []
        )
        self.controlState = ExperienceControlState(
            statusTitle: "Test",
            statusDetail: "Tracking",
            errorMessage: nil,
            primaryActionSystemImage: "play.fill",
            allowsPrimaryAction: allowsAction
        )
    }

    func handle(_ event: DemoEvent) async {
        events.append(event)
        scene = HUDScene(
            sceneID: scene.sceneID,
            revision: scene.revision + 1,
            presentation: scene.presentation,
            elements: scene.elements
        )
    }

    func reset() async {
        resetCount += 1
    }
}

@MainActor
private final class SuspendedOriginResetExperience: ExperienceSession {
    let descriptor = ExperienceDescriptor(
        kind: .navigation,
        displayName: "Suspended activation origin",
        detail: "Overlapping activation fixture",
        systemImageName: "pause",
        actions: []
    )
    let scene = HUDScene(
        sceneID: "suspended_activation_origin",
        revision: 0,
        presentation: .compact,
        elements: []
    )
    let primaryActionTitle = "Run"
    private(set) var isFirstResetSuspended = false
    private var resetCount = 0
    private var firstResetContinuation: CheckedContinuation<Void, Never>?

    func handle(_ event: DemoEvent) async {}

    func reset() async {
        resetCount += 1
        guard resetCount == 1 else { return }
        isFirstResetSuspended = true
        await withCheckedContinuation { continuation in
            firstResetContinuation = continuation
        }
        isFirstResetSuspended = false
    }

    func completeFirstReset() {
        firstResetContinuation?.resume()
        firstResetContinuation = nil
    }
}

@MainActor
private final class SuspendedActionExperience: ExperienceSession {
    let descriptor = ExperienceDescriptor(
        kind: .navigation,
        displayName: "Suspended",
        detail: "Isolation fixture",
        systemImageName: "pause",
        actions: [action()]
    )
    private(set) var scene = HUDScene(
        sceneID: "suspended_navigation",
        revision: 0,
        presentation: .compact,
        elements: []
    )
    let primaryActionTitle = "Wait"
    private(set) var isHandling = false
    private var continuation: CheckedContinuation<Void, Never>?

    func handle(_ event: DemoEvent) async {
        isHandling = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        scene = HUDScene(
            sceneID: "stale_navigation",
            revision: 99,
            presentation: .result,
            elements: []
        )
    }

    func reset() async {}

    func complete() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SameSessionSupersedingActionExperience: ExperienceSession {
    let descriptor = ExperienceDescriptor(
        kind: .navigation,
        displayName: "Same-session isolation",
        detail: "Newer action supersedes an older completion",
        systemImageName: "arrow.triangle.2.circlepath",
        actions: [
            ExperienceActionDescriptor(
                id: "slow",
                event: .tap,
                placement: .primary,
                titleSource: .fixed("Slow"),
                iconSource: .fixed("tortoise"),
                accessibilityLabel: "Run slow action"
            ),
            ExperienceActionDescriptor(
                id: "newer",
                event: .swipeDown,
                placement: .secondary,
                titleSource: .fixed("Newer"),
                iconSource: .fixed("hare"),
                accessibilityLabel: "Run newer action"
            )
        ]
    )
    private(set) var scene = HUDScene(
        sceneID: "same_session",
        revision: 0,
        presentation: .compact,
        elements: []
    )
    let primaryActionTitle = "Slow"
    private(set) var isFirstActionSuspended = false
    private var firstActionContinuation: CheckedContinuation<Void, Never>?
    private var invocationCount = 0

    func handle(_ event: DemoEvent) async {
        invocationCount += 1
        if invocationCount == 1 {
            isFirstActionSuspended = true
            await withCheckedContinuation { continuation in
                firstActionContinuation = continuation
            }
            scene = HUDScene(
                sceneID: "same_session_stale",
                revision: 99,
                presentation: .alert,
                elements: []
            )
            return
        }

        scene = HUDScene(
            sceneID: "same_session_newer",
            revision: 2,
            presentation: .result,
            elements: []
        )
    }

    func reset() async {}

    func completeFirstAction() {
        firstActionContinuation?.resume()
        firstActionContinuation = nil
    }
}

private func missingDependencies() -> VoiceConversationDependencies {
    VoiceConversationDependencies(
        inputMode: { .pushToTalk },
        voiceActivatedInputAvailable: { false },
        prepareSpeechInput: { _ in
            throw ConversationPreparationFailure(
                userSafeMessage: "Missing input configuration",
                failureCode: .configurationMissing
            )
        },
        prepareAgent: {
            throw ConversationPreparationFailure(
                userSafeMessage: "Missing Agent configuration",
                failureCode: .configurationMissing
            )
        },
        requestMicrophonePermission: { false },
        sleep: { _ in },
        presentationCopy: .catalogFixture
    )
}

private extension ConversationPresentationCopy {
    static let catalogFixture = Self(
        voiceActivatedUnavailable: "Voice activation unavailable",
        microphonePermissionDenied: "Microphone permission denied",
        speechRecognitionUnavailable: "Speech recognition unavailable",
        noSpeech: "No speech",
        replyPreparationUnavailable: "Reply preparation unavailable",
        emptyReply: "Empty reply",
        inconsistentReplyStream: "Inconsistent reply stream",
        incompleteReplyStream: "Incomplete reply stream",
        unexpectedReplyFailure: "Unexpected reply failure",
        interruptedReplyPrefix: "Interrupted: ",
        failedReplyPrefix: "Failed: ",
        contextCommitFailed: "Context commit failed"
    )
}
