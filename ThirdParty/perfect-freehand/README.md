# perfect-freehand provenance

Source: https://github.com/steveruizok/perfect-freehand
Pinned commit: `176e00f2399f4969e1b0965c5921d96a3e50ce9f`.
`src/*.ts` and `LICENSE` are unmodified upstream files at that commit. MIT,
Copyright (c) 2021 Stephen Ruiz Ltd. The app bundles this license. There is no
JavaScript pen runtime, CDN or external resource at runtime.

`Sources/PerfectFreehand.swift` ports stroke points and the full outline algorithm:
vector construction, offset interpolation, sharp-turn arcs, radius, edge point
selection, round / flat caps, simulated pressure and numeric taper reference.
The batch port supports linear pressure easing and upstream default numeric-taper
easing; arbitrary JavaScript easing callbacks and boolean whole-length taper are
not exposed by this Swift API. These unused options are not claimed as supported.

`Tests/PerfectFreehandReference.mjs` runs the original TypeScript after Node's
syntax-only type stripping; import extensions are adapted to `.mjs`. Swift tests
compare both intermediate points and outline vertices against those results.

The v1–v3 `PerfectPenBuilder` was a streaming adapter, not an assertion that
an entire growing stroke exactly equals upstream's batch output. It retains
edge spacing (.12), restrained actual-force thinning
(.30 for identified tablet input only), no simulated pressure or taper. Last actual
endpoint is immediately present; the preceding provisional endpoint settles on
next input. This is not prediction. A stationary release performs no refit.

Intentional mathematical-note adaptations:
- no initial minimum-length suppression, no 3-unit end-noise skip;
- no invented [1,1] sample for a dot, no synthesized pressure for two-point strokes;
- immutable 64-centerpoint blocks overlap three points; internal boundaries have
  flat caps. v2 splits direction reversals at the actual cusp and joins equally
  wound spans with original-radius caps. All contours fill once;
- v2 normalizes the incoming/outgoing bisector before applying the radius,
  rather than shrinking short connections through a non-unit direction blend;
- v2 uses one semicircle for the end cap, instead of the repeated 3π reference
  traversal. `joinedNormals:false` keeps the batch reference upstream-exact;
- v2 preserves v1's input centerlines, force mapping and nominal width. Recipe
  version is distinct from baked-outline schema: old stored strokes never rerun
  this adapter. `Tests/PerfectPenV1Reference.swift` freezes the f057c21 adapter
  for comparisons only and is never included in the shipping app;
- upstream-style quadratic outline interpolation is flattened once at 0.015 PDF
  point tolerance; saved contours are authoritative. Erasure clips these contours,
  without calling the pen generator or regenerating caps on fragments.

Raw received events remain independently traceable. They are Ecru AppKit events,
not claimed as original Pencil hardware samples. Width/pressure and render recipe
are fixed defaults, not a user-facing collection of algorithm controls. Historical
stroke recipes do not run this new generator when opened.

The frozen v3 adapter keeps the v2 envelope / reversal unions but replaces the
recursive .35 streamline position filter with `ResponsivePenPath.swift`: real
endpoints are interpolated using centripetal-knot tangent directions, constrained
cubic Hermite handles, one provisional interval, and fixed PDF-coordinate
flattening. This is a bounded native connection scheme, not a claim to reproduce
unmodified Catmull–Rom or a GoodNotes algorithm. No startup-length threshold,
inertia, timestamp velocity, synthesized pressure, tilt or release refit. The
existing linear measured-force radius mapping remains unchanged; generated
vertices interpolate force inside the original interval without amplification.
Stable blocks only receive settled intervals. `Tests/PerfectPenV2Reference.swift`
freezes f4c407a for process-local prefix replay and is not shipped. The frozen v1
and v2 comparisons continue to be independently runnable.

The shipping v4 brush retains the v3 responsive trajectory but replaces the
product outline generator with Ecru's native `PenBrushEnvelope` in
`PenBrush.swift`: variable-radius circle tangents, outer circular joins, bounded
inner joins, consistent span winding and geometrically flattened caps. No
closed midpoint edge smoothing. This is not an upstream perfect-freehand or
GoodNotes algorithm. The unchanged upstream port, source and license remain
independently tested. `Tests/PerfectPenV3Reference.swift` freezes 5662838
for comparison only and is never shipped.

`PenForceProfile` operates on received moving samples with bounded diameter
factor .78–1.16 and an analytic distance-domain response to linearly varying
reported force. It does not infer force from speed or auxiliary point spacing
or claim hardware calibration. Auxiliary curve vertices interpolate already
decided diameter factors. No inertia, future sample wait or release taper.
The existing outline schema is a baked geometry capability, not a request to
rerun a particular generator. Historical stroke appearances never change.
