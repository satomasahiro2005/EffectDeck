# EffectDeck JSFX compatibility

EffectDeck hosts single-file audio JSFX with the portable EEL2 interpreter from
JoepVanlier/ysfx commit `5c3452fee62583aa3d1b7e877d0c758c4024af89`.
It does not use JIT or executable memory. Imported source is copied into the
app's Application Support container and the original Files/iCloud URL is not
used at runtime.

## Supported

- `@init`, `@slider`, `@block`, `@sample`, `@gfx`, and `@serialize`
- strings, EEL local memory, FFT/MDCT, inline `<? ... ?>`
- up to 256 numeric, enum, hidden, and custom-variable sliders
- linear, `:log`, `:sqr`, `:log!`, and `:sqr!` slider curves; UI movement is
  converted through ysfx's pinned normalized-value functions
- 10 host triggers, `sliderchange()`, and `slider_automate()`
- `spl0` through `spl63`, analyzer passthrough, and audio generators
- dynamic PDC notification and conservative infinite-tail processing
- persistent in-memory LICE graphics, text, Retina, basic keyboard/mouse input,
  and synchronous `gfx_showmenu`
- serializer handle 0 numeric, memory, string, and slider state

## Deliberate v1 limits

- No `import`, file `include()`, file sliders, external audio/image/data files,
  arbitrary filesystem access, dropped files, or REAPER project APIs.
- No MIDI routing. MIDI send functions are immediate no-ops.
- No sample-accurate host automation (`slider_next_chg()`).
- No runtime editor for `config:` values.
- `gfx_idle` and `gfx_idle_only` are not supported. Modern Unicode keyboard
  behavior and OS-global `options:want_all_kb` capture are not guaranteed.
- Cross-instance `gmem`, `_global.*`, and `regXX` behavior is not guaranteed.
- The host does not expose REAPER's native gain-reduction meter integration.

## Resource limits

- Source: 1 MiB
- Saved state: 16 MiB
- EEL RAM: 16 MiB per instance, 64 MiB process-wide
- GFX images: slots 0–127, 2048 × 2048 maximum, 16 MiB per instance and
  64 MiB process-wide for offscreen images
- Presentation framebuffer: 2048 × 2048 and 16 MiB per instance,
  64 MiB process-wide
- Menu payload: 64 KiB

Compile, initialization, destruction, state operations, and sample-rate
maintenance run off the audio thread. Repeated full-block deadline overruns put
only the offending JSFX into safe passthrough. Physical-device performance is
still a release gate and is intentionally not claimed by a Mac-only build.
