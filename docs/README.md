# docs

What each file here is. Design documents describe how something works now; notes are
records of one integration, investigation or test day and are not kept up to date.

## Design

| File | What it is |
|---|---|
| [external-processor.md](external-processor.md) | The `ETExternalProcessor` boundary that AUv3 and JSFX nodes run through, and the EffeTune patches it needs |
| [multichannel-output.md](multichannel-output.md) | Output on 2–16 channel audio interfaces, Routing, Bass Management |
| [jsfx-host-test-design.md](jsfx-host-test-design.md) | Test design for the JSFX host (Japanese). Partly implemented; its status section maps sections to `Tests/Unit/JSFX*Tests.swift` |
| [jsfx-bench.md](jsfx-bench.md) | The JSFX executor benchmark: variants, how to run it on the Mac CLI and the iPhone, how to read it (Japanese). Raw results are in `bench/` |

The contracts for users and language models are at the top of the repository:
[`JSFX.md`](../JSFX.md) and [`CHAIN.md`](../CHAIN.md).

## Logs

| File | What it is |
|---|---|
| [battery-log.md](battery-log.md) | Issue #5, battery drain with the screen off (Japanese). A running log: measured and guessed are kept apart, dead ends stay in |

## Notes

| File | What it is |
|---|---|
| [notes/effetune-2.10.0.md](notes/effetune-2.10.0.md) | What the EffeTune 2.10.0 integration changed |
| [notes/effetune-2.11.0.md](notes/effetune-2.11.0.md) | What the EffeTune 2.11.0 (DSP 0.11.0) integration changed |
| [notes/effetune-2.12.0.md](notes/effetune-2.12.0.md) | What the EffeTune 2.12.0 (DSP 0.12.0) integration changed |
| [notes/au-post-insert.md](notes/au-post-insert.md) | The first AUv3 host, a fixed post-insert. Superseded by AU nodes in the chain |
| [notes/mde-routing-question.md](notes/mde-routing-question.md) | The question for issues #3 and #4: when iOS keeps a player on the EffectDeck route |
| [notes/mde-routing-answer.md](notes/mde-routing-answer.md) | The answer, reconstructed from iOS 27's `MediaExperience` (Japanese) |
| [notes/test-2026-09-20.md](notes/test-2026-09-20.md) | The device checklist for build 2026.09.20 (Japanese) |

## Distribution and images

| Path | What it is |
|---|---|
| [altstore/](altstore/) | The AltStore PAL procedure and source from before the App Store release. URLs under `nemut.ai/effetune-live/` in it are live; do not rename them |
| `icon.png`, `icon-dark.png` | The app icon. The README shows them, and `site/src/worker.js` imports them |
| `shot-*.png` | The README screenshots. `site/tools/images.mjs` makes the site's images from them |
| `altstore-badge-*.png` | The old AltStore badge. Nothing references it now |

## Not in the repository

Some tracked files cite `docs/connect-log.md` (the log of the Unable to Connect
investigation) and `docs/apple/` (copies of Apple documentation). Both are kept only on the
owner's machine and are listed in `.gitignore`, as are the other local notes there. The
citations are kept so the owner can follow them; there is nothing to fetch.
