# EffectDeck JSFX compatibility

EffectDeck hosts single-file audio JSFX with the portable EEL2 interpreter from
JoepVanlier/ysfx commit `5c3452fee62583aa3d1b7e877d0c758c4024af89`.
It does not use JIT or executable memory. Imported source is copied into the
app's Application Support container and the original Files/iCloud URL is not
used at runtime.

## Authoring contract (read this first)

**You are writing a single-file JSFX that must load in EffectDeck, not in
REAPER.** Assume nothing from the REAPER documentation: every statement below
is taken from this repository's host implementation and is enforced at import
or compile time.

Hard requirements, in order of how often they are violated:

1. **One file. No `import`, no `include()`.** There is no mechanism to pull in
   another file. Inline everything.
2. **No filesystem and no MIDI.** File sliders, external samples, images from
   disk, dropped files, and all MIDI send functions are absent. An effect built
   around any of them cannot work here.
3. **`desc:` first**, before any `@` section.
4. **Do not write the text `include(` anywhere**, including inside a string —
   it is a plain text search. See the rejection table.
5. **No JIT.** The interpreter is portable EEL2. A script that repeatedly
   misses the block deadline is forced into passthrough.

If a requirement conflicts with what you know about REAPER JSFX, this document
wins.

### Where to learn the language itself

**This document only describes the differences.** It is not a JSFX tutorial and
deliberately does not restate the language. For syntax, the EEL2 built-ins, the
meaning of each `@` section, slider declaration forms, the `gfx_*` API, and
everything else, read the primary sources:

| | |
|---|---|
| Language and API reference | REAPER's *JS: Programming Reference* (`Help → JS Programming Reference` in REAPER, also mirrored as the JSFX docs on cockos.com) |
| The interpreter actually used here | [JoepVanlier/ysfx](https://github.com/JoepVanlier/ysfx) — this repo embeds it, so its behaviour is the ground truth for anything ambiguous |
| Real effects to learn idioms from | [geraintluff/jsfx](https://github.com/geraintluff/jsfx), [JoepVanlier/JSFX](https://github.com/JoepVanlier/JSFX), [Sonic-Anomaly/Sonic-Anomaly-JSFX](https://github.com/Sonic-Anomaly/Sonic-Anomaly-JSFX), [mawi-design/JSFX](https://github.com/mawi-design/JSFX) |

When reading those, keep the limits below in mind: much of what you will find in
the wild uses `import`, file sliders, or MIDI, none of which exist here.

### Start from this skeleton

```jsfx
desc:My Effect
author:Your Name

slider1:0<-24,24,0.1>Gain (dB)

@init
g = 1;

@slider
g = 10 ^ (slider1 / 20);

@sample
spl0 *= g;
spl1 *= g;
```

`desc:` must appear before the first `@` section. The import layer accepts a
file only if it finds `desc:` or one of `@init` `@slider` `@block` `@sample`
`@serialize` `@gfx` within the first 80 lines.

### The file itself

- **A file extension is not required.** REAPER stores JSFX without one and
  EffectDeck never looks at the extension — the content decides. `.jsfx`,
  `.txt`, and no extension all work, from Files, from a share sheet, or from a
  link.
- **Single file only.** There is no `import` and no `include()`, so everything
  must live in one file. See the rejection rules below.
- UTF-8 is expected. A byte-order mark is stripped. Latin-1 also loads.

### Rules that reject a file outright

Checked before compilation. A rejected file is never copied into the app.
**Each row is a mechanical check — verify your output against all of them.**

| Rule | What triggers it |
|---|---|
| `import` | a line whose **first non-blank characters** are `import ` or `import	` |
| `filename:` / `data:` | a line starting with either word |
| `include(` | the text `include(` **anywhere on a line**, unless the line starts with `//` |
| Nesting | more than 256 levels of `(` `[` `{` |
| Inline EEL | more than 1024 `<?` blocks |
| String literal | a single literal longer than 64 KiB, or one that is never closed |
| Size | source larger than 1 MiB |

**Watch the `include(` rule.** It is a plain text search, so it also fires
inside a string:

```jsfx
#label = "include(this)";   // rejected, even though it is only text
```

Only a line whose comment starts before the match is exempt. If you need that
word in a string, break it up (`"inclu" + "de("`).

### Self-check before returning a script

- [ ] `desc:` is the first non-comment line
- [ ] no line begins with `import`, `filename:`, or `data:`
- [ ] the text `include(` appears nowhere (strings and comments included)
- [ ] no MIDI function, no file slider, no external resource
- [ ] every `@sample` body is cheap; per-block work is in `@block`
- [ ] if it draws, it reads `gfx_w` / `gfx_h` instead of assuming a size
- [ ] if it has state worth keeping, it has an `@serialize`

### What you can rely on

- `spl0`–`spl63`. EffectDeck feeds the channels the chain is carrying.
- `@init` `@slider` `@block` `@sample` `@serialize` `@gfx`.
- `slider1`–`slider256`, including enum (`{A,B,C}`), hidden (`-`), and
  named-variable sliders. Curves `:log` `:sqr` `:log!` `:sqr!` work.
- `sliderchange()` and `slider_automate()`.
- Strings, local memory, FFT/MDCT, and inline `<? ?>`.
- `pdc_delay` / `pdc_bot_ch` / `pdc_top_ch`. Changes are picked up while running.
- `@serialize` with `file_var` / `file_mem` / `file_string` on handle 0. This is
  what makes a setting survive a preset save and an app restart.
- Graphics: LICE drawing, text, images in slots 0–127, mouse, keyboard, and
  `gfx_showmenu`.

### What is not there

- **MIDI.** Send functions are no-ops. Do not build an effect around MIDI.
- **The filesystem.** No file sliders, no external samples, no images loaded
  from disk, no dropped files.
- `slider_next_chg()` — automation is not sample-accurate here.
- `gfx_idle` / `gfx_idle_only`.
- Cross-instance `gmem`, `_global.*`, and `regXX` are not guaranteed.
- REAPER project APIs and its gain-reduction meter integration.

### Graphics: size your canvas from `gfx_w` / `gfx_h`

EffectDeck draws at the size you declare with `@gfx <w> <h>` and then scales the
result to fit the card, so **a script that hard-codes coordinates to its
declared size still looks right**. But the canvas can also be handed a different
size (full screen, or the Pixel Perfect setting), so reading `gfx_w` / `gfx_h`
and laying out from them is better:

```jsfx
@gfx 640 360
s = gfx_w / 640;        // scale everything from the declared width
gfx_rect(10 * s, 10 * s, 100 * s, 30 * s, 1);
```

Declaring a very large canvas is fine but wastes memory: the framebuffer is
capped at 2048 × 2048 and 16 MiB per instance.

### Input: a tap is a press and a release

A quick tap delivers the press and the release within microseconds of each
other. EffectDeck holds the release until at least one `@gfx` frame has run, so
the classic edge test works:

```jsfx
@gfx
down = mouse_cap & 1;
down && !last_down ? choice = gfx_showmenu("One|Two|Three");
last_down = down;
```

`gfx_showmenu` blocks that instance's graphics thread while the menu is open;
audio and other effects keep running. The menu string is capped at 64 KiB.

### Staying inside the deadline

The interpreter is portable EEL2 — **there is no JIT**. A script that repeatedly
misses the block deadline is put into passthrough on its own, and the card shows
the measured overrun with a Re-enable button. Keep `@sample` cheap; move
anything that can run once per block into `@block`.

### Limits at a glance

| | |
|---|---|
| Source | 1 MiB |
| Saved state | 16 MiB |
| EEL RAM | 16 MiB per instance, 64 MiB process-wide |
| Image slots | 0–127, 2048 × 2048 each |
| Image memory | 16 MiB per instance, 64 MiB process-wide |
| Framebuffer | 2048 × 2048, 16 MiB per instance, 64 MiB process-wide |
| Menu string | 64 KiB |

---

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
