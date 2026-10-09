# External Processor ABI

**Status: in use.** AUv3 plugins (`ETAUExternalBridge`) and JSFX (`ETJSFXHost`) both run
through this boundary as nodes in the chain.

`ETExternalProcessor` is the host-neutral PCM boundary between the EffeTune engine and
anything that is not a native EffeTune effect. It accepts one planar `Float32` block and
deliberately performs no allocation or locking on the render thread.

There are eight slots (`ET_EXTERNAL_MAX_PROCESSORS` in `Sources/Shared/ETPipeline.h`).
`ETPipeline_SetExternalProcessorAt` fills one. Slots are stable, so a chain node keeps its
`externalIndex` while another AU or JSFX is added; the ninth one is refused ("The external
processor limit is 8.").

## Where it runs

EffeTune's descriptor ABI can only describe native effect instances.
`Patches/effetune-external-node.diff` extends it with an external node marker and a
callback, and `Scripts/setup.sh` applies it to the pinned EffeTune submodule. With the
patch the engine calls the processor at the node's own position in the descriptor, so the
chain can be `native -> AU -> native` without splitting the engine or losing bus state.
`Patches/effetune-external-routing.diff` gives the node the same channel selection and bus
merge rules as a native node.

`ETPipeline.c` finds the callback through a weak symbol. If the engine was built without
the patch, it falls back to running every filled slot, in slot order, after the native
pipeline on the final bus. That fallback is the post stage of the first integration; with
the patch applied it never runs, so a processor is never run twice.

The AVAudioEngine graph stays `Source -> Mixer`. Inserting an AU into that graph would make
it a fixed post-insert and process it a second time (see `AudioIO.swift`).

## Latency

Since EffeTune 2.11.0 the engine's latency planner also gives external nodes input
delays for parallel-bus compensation (`Patches/effetune-external-latency.diff`). The
patched engine aligns the node's routed channels (`align_input`) after the bus copy and
before the callback, as it does for native nodes, so the adapter receives aligned input.
`external_latency_compensated_once` in `Tests/Native/pipeline_engine.c` (the `engine`
preset, and `dsp.yml` in CI) checks this against the patched engine: an external node's
latency is counted once, and the dry parallel bus is delayed to match. Two things are not
measured yet: `align_input` lining up an external node's input channels when they arrive
with different latencies, and an AU or JSFX processor on a device.

The patches are kept in this repository until the corresponding upstream EffeTune change
is available at the pinned submodule revision. EffeTune 2.13.0's `Engine::setPipelineObserver`
does not replace them: it is a C++-only, read-only before/after view of a node's audio and
cannot run host processing at a node's position.

## Descriptor rules

The descriptor carries `latency`, `tailTime`, `maximumFramesToRender`, and
channel limits. An adapter must reject an unsupported processing rate or channel
width rather than silently inserting a sample-rate converter.

`ETPipeline_SetExternalProcessorAt` copies the descriptor and publishes the copy
atomically. Published copies are never freed, because the render thread may already hold
an older one. The `context` inside a copy still belongs to the adapter, so the adapter must
keep it alive for as long as any copy that points at it can run. `ETAUExternalBridge` does
that by retaining replaced contexts until the audio engine stops. Its `suspend()`, called
once no render callback can run, clears every external slot and only then releases them.
Destruction and replacement are control-plane operations.
