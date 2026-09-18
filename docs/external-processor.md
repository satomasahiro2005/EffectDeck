# External Processor ABI

`ETExternalProcessor` is the host-neutral PCM boundary for future AUv3 and
JSFX adapters. It accepts one planar `Float32` block and deliberately performs
no allocation or locking on the render thread.

The first integration point is the final EffeTune bus:

```text
native EffeTune pipeline -> ETExternalProcessor -> output
```

This is intentionally a safe staging point, not the final arbitrary-position
node implementation. The current EffeTune descriptor ABI can only describe
native effect instances; splitting it around an external callback would lose
bus state and parallel-path delay compensation. A later engine-level node type
can move the same ABI into an arbitrary position without changing AU/JSFX
adapters.

The descriptor carries `latency`, `tailTime`, `maximumFramesToRender`, and
channel limits. An adapter must reject an unsupported processing rate or channel
width rather than silently inserting a sample-rate converter.

`ETPipeline_SetExternalProcessor` borrows the descriptor. The adapter must keep
the context alive until the render thread is stopped or the processor is
cleared. Destruction and replacement are therefore control-plane operations.
