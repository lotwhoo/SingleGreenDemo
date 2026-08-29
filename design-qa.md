# AI Conversation HUD Design QA

## Source of truth

- Reference: `docs/assets/ai-conversation-hud-minimal-reference.png`
- Reference pixels: 1774 × 887 (approximately 2:1)
- Required engineering constraint: `simulator.default.v2` keeps an 8:3 visible HUD safe area.
- Compared state and copy: `streaming` / `正在回答`, question `如何安排一次产品评审？`, answer `先明确目标，再聚焦关键流程，最后记录结论与下一步。`

## Implementation capture

- Capture: `docs/assets/ai-conversation-hud-minimal-implementation.png`
- Overflow capture: `docs/assets/ai-conversation-hud-two-line-overflow-implementation.png`
- Capture pixels: 1600 × 884
- Rendered from the real `ConversationHUDMapper` and `HUDOverlayView` at a 400-point host width with 4× raster scale.
- Focused XCTest cases: `ExperienceRuntimeTests.testMinimalConversationHUDRendersReferenceStateAtEightToThree` and `ExperienceRuntimeTests.testConversationHUDRendersLongStreamingAnswerInsideTwoLineViewport`; the overflow capture waits 480ms after the stream update so the 300ms transition has reached its stable two-line state.

## Visual comparison

| Criterion | Result | Evidence |
| --- | --- | --- |
| Information hierarchy | passed | Dynamic waveform and dimmer question form the top context row; the larger, brighter answer remains dominant. |
| Divider state placement | passed | `正在回答` is horizontally centered in the reserved gap between two symmetric rule segments. The same stable frame is used for listening, thinking, web-searching, and answering labels. |
| Layout rhythm | passed | Top context, centered divider, and answer viewport retain the reference ordering and generous negative space. |
| Color and styling | passed | Monochrome profile tint, opacity hierarchy, no cards, bubbles, border panel, gradient, or decorative raster asset. |
| Icon fidelity | passed | Uses the system waveform symbol instead of a text glyph or handcrafted approximation; active state has a low-amplitude animation and audio-level response. |
| 8:3 adaptation | passed | The 2:1 concept is projected into the existing 8:3 visible safe area. The answer wraps to two lines instead of reducing below the fixed readable answer style. |
| Two-line answer viewport | passed | Reference and long-overflow implementation were inspected together. The overflow capture exposes exactly the newest two complete lines; the previous line is fully clipped with no half-line fragment above them. |
| Overflow motion | passed by implementation review | The answer is bottom-anchored inside a `2 × 24pt × textScale` clipped viewport. When wrapping increases its intrinsic height, the content moves upward with the user-selected 300ms linear transition; Reduce Motion updates without animation. |
| Content fidelity | passed | Question, centered state, answer, and streaming cursor match the selected reference state. |
| Reduced Motion | passed by implementation review | Waveform activity becomes static and existing incremental-text behavior remains non-per-character animated. |

## Iteration history

1. Removed the previous left stage rail, but the first pass also removed the visible phase label.
2. Restored all user-visible phase labels into a single centered divider slot: `正在聆听`, `正在思考`, `正在联网搜索`, and `正在回答`.
3. Replaced the first offscreen `ImageRenderer` capture with a hosted 400-point, 4× raster capture so flowing text, auto-follow, and real device-scale typography are represented.
4. Added an answer-specific text style to preserve other experience title typography while allowing the selected AI answer to fit the 8:3 viewport without clipping.
5. Replaced the answer's arbitrary-height scroll viewport with a bottom-anchored exact two-line clipping viewport, then rendered a streaming update long enough to force more than two lines.
6. Increased the whole-line overflow transition from 80ms to 300ms so the upward exit remains readable instead of feeling abrupt; the static two-line geometry is unchanged.

## Remaining manual checks

- VoiceOver announcement frequency for rapid state changes.
- Optical readability and animation comfort on the physical monocular display.
- Real ASR audio-level responsiveness and real web-search transition timing.

final result: passed
