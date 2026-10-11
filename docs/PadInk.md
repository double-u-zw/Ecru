# PadInk continuous PDF navigation

Ecru advertises `PadInkGestureBridgeVersion = 1` in its bundle. The existing
bundle ID `local.leafink.reader.development` remains stable for compatibility.
PadInk sends process-targeted CGEvent scroll events; Ecru accepts them through its
window-local input monitor. There is no listener, runtime network dependency or
keyboard injection in Ecru.

| CGEvent field | Bridge v1 payload |
| --- | --- |
| type | scrollWheel |
| eventSourceUserData | `0x50494E4B0001` |
| scrollWheelEventPointDeltaAxis3 | `round(logDelta * 1_000_000)` |
| scrollWheelEventScrollPhase | began=1, changed=2, ended=4, cancelled=8 |
| scrollWheelEventIsContinuous | 1 |
| location | moving centroid in Quartz global coordinates |
| flags, axes 1 and 2 | 0 |

A gesture must begin on the PDF canvas in the active key document window.
Changed events without an accepted began, events older than 250ms, loss of focus,
Pencil takeover, cancellation and end clear the gesture. Each finite log delta
is limited to an absolute value of 1; PDF zoom remains within 15–600 percent.
Zero deltas permit two-finger pan. PDF coordinates are resolved before scaling
and adjusted beneath the moving centroid using the native clip view.

UI tests activate separate windows and temporarily interrupt PadInk's target.
Return focus to the Ecru document before checking device input. Automated tests
verify the receiver and PDF coordinates; they do not measure physical input or
video latency.
