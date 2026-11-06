# Graph peek

While the user changes a card's values and that card's own graph has scrolled off, a display-only copy of the
collapsed graph is shown pinned under the nav bar. It flips to the bottom edge when the finger is in the top band.
It fades about 0.8 s after the finger lifts (1.2 s after a pulse). Nothing in the card layout changes.

## Where the code is

| Part | File |
|---|---|
| Show/hide decision, placement, visibility test (Foundation only, Linux tests) | `Views/GraphPeekGate.swift`, `Tests/Unit/GraphPeekGateTests.swift` |
| Passive touch watcher on the enclosing `UIScrollView` | `Views/TouchWatch.swift` |
| Overlay host (`overlayPreferenceValue`), scroll state, measuring, transitions | `Views/GraphPeekOverlay.swift`, `Views/PipelineView.swift` (`chainList`) |
| Per-card gate, linger task, preference emission, peek content | `Views/EffectCardView.swift` |
| `etGraphPeekPulse`, `etGraphPeekCard`, `ETGraphPeekKey`, `etPeekGraphAnchor()` | `Views/Components.swift` |
| Pulse callers | `ParameterRow.set(_:pulses:)`, `ETValueField`, `.menu` pickers in custom graph views |
| Selection persistence (`etRemembers`) so the copy draws the same band/tab | the PEQ, Multiband, TonalBalance, PhaseSelectEq and Tube views |

Eligibility: not a drag preview, expanded with a body and a collapsed graph, not external, editable, not Follow Volume's
graph-only state, and not `NoteSpectrogramPlugin`, `RhythmAnalyzerPlugin` or `SpectrogramPlugin` (`peekExcluded`).

## Checks that need a device

1. Overlay y = 0 lands below the inline bar, in the iPhone NavigationStack and in the iPad split detail column
   (including the scroll-edge blur). The overlay ignores the container safe area and reads `safeAreaInsets` itself;
   the way the frame resolves on a real device is the main unverified point.
2. The touch watcher breaks nothing: slider drags, tapping a card open and closed, long-press reorder,
   swipe-to-delete, starting a scroll on a card, three-finger undo, graph marker drags, focusing a text field.
3. A Toggle's change lands inside the 0.3 s grace window (assumes `touchesEnded` reaches the recognizer first).
4. Look: material over cards with the shadow, muted cards, dark mode, Increase Contrast, Reduce Transparency.
5. Peek height on cards with several graphs (Compressor, Multiband, Tube HUD). The height is measured, not estimated;
   it may exceed 40% of the viewport.
6. Live analyzers fill in quickly inside a peek (Spectrum, Stereo trail, Level).
7. iPhone landscape and keyboard-up: no peek when the free height is under 2 x peek height + 48.
8. Follow Volume: editing a keyframe shows that keyframe's values plus the companion PEQ.
   The picked-band dashed curve is not shown on those cards (`pickedAt` starts at -1 in the copy).
9. VoiceOver slider adjustment shows the peek without moving focus; Switch Control.
10. Frame rate while dragging a PEQ band slider with the peek up, on the oldest device available.
11. A typed-value commit shows the peek on top.
12. Anchors keep resolving while the peek lingers during a scroll. The peek hides on scroll start, so this should not matter.
