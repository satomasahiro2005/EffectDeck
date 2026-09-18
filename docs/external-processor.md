# External Processor ABI

`ETExternalProcessor` is the host-neutral PCM boundary for future AUv3 and
JSFX adapters. It accepts one planar `Float32` block and deliberately performs
no allocation or locking on the render thread. Up to eight processors can be
published as an ordered segment, so the external part of the EffectDeck chain
can already be reordered without changing the render callback.

The first integration point is the final EffeTune bus:

```text
External A -> native EffeTune pipeline -> External B -> output
```

The pre and post segments are real processing stages, so an AU/JSFX chain can
already surround the native pipeline. This is still not arbitrary insertion
between two native effects: the current EffeTune descriptor ABI can only
describe native effect instances. `Patches/effetune-external-node.diff` extends
that ABI with an external node marker and callback. `Scripts/setup.sh` applies
it to the pinned EffeTune submodule, after which the same descriptor order can
be `native -> AU -> native` without splitting the engine or losing bus state.

The patch is kept in this repository until the corresponding upstream
EffeTune change is available at the pinned submodule revision.

The descriptor carries `latency`, `tailTime`, `maximumFramesToRender`, and
channel limits. An adapter must reject an unsupported processing rate or channel
width rather than silently inserting a sample-rate converter.

`ETPipeline_SetExternalProcessor` borrows the descriptor. The adapter must keep
the context alive until the render thread is stopped or the processor is
cleared. Destruction and replacement are therefore control-plane operations.
