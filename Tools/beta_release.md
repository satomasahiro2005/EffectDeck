**Public beta on TestFlight.** [Join](https://testflight.apple.com/join/QtEVGZxn)

This is a beta. It will have bugs the App Store build does not.

**The beta icon is purple**, so you can tell which build you are on when
something misbehaves. Installing from the
[App Store](https://apps.apple.com/app/effectdeck/id6812467517) puts you back on
the released version at any time.

If you hit something, use **Settings → About → Report a problem** in the app (it
fills in the diagnostics and the log for you), or tell
[@ainemut](https://twitter.com/ainemut).

Everything here is new since 2026.09.20, the version on the App Store.

### JSFX

EffectDeck hosts JSFX, the script format REAPER uses, so an effect can be a text
file you wrote or downloaded rather than something we shipped.

- Import a `.jsfx` from Files or the share sheet. Files are judged by what is
  inside them, not by the extension, so a `.txt` holding a script is taken.
- Sliders come through with their real ranges and curves (linear, `log`, `sqr`),
  enums and hidden sliders. Values are typed in plainly, never as `1e-05`.
- Scripts that draw (`@gfx`) get their canvas, full screen, Retina, touch and
  keyboard, and `gfx_showmenu`.
- State (`@serialize`) is saved with the preset and comes back with it.
- A script that reports latency (PDC) has it compensated in the chain.
- A script that overruns its time budget is bypassed automatically, and the
  card says by how much. **Re-enable** puts it back.
- Imported scripts can be deleted again.
- Settings has **Adaptive** and **Pixel Perfect** for how a canvas is sized.

Three sample scripts are bundled with the beta so there is something to try
without hunting for one. They do not ship in the App Store version.

### Graphs

- Full-screen spectrogram. The grid is drawn over the image instead of under it,
  and the colours were corrected.
- FIR PEQ points can be dragged, and it has the same band header as the other
  band strips.

### The chain

- Reordering compares a card's edge with its neighbour's centre, so a tall card
  swaps after a short move and cards no longer flip back and forth.
- Hold a card with one finger and scroll with another.
- Sections were rebuilt. An unnamed section collapses, and a section imported
  from EffeTune is read as written rather than guessed at.
- Collapsed cards, numeric entry and display settings all survive a round trip.
- Search covers every pane.

### Power

- While no app is routed in, the bridge polls far less often: the receiver woke
  1000 times a second and now wakes 50, the sender 500 and now 5.
- EffectDeck no longer tells the system the device is gone every time discovery
  stops.

### Files

- Audio files can be sent in from the share sheet.

### Settings

- Reporting a problem prefills the diagnostics and the end of the log (up to
  about 4,000 characters). **Attach log** shares the whole log.
- Twitter ([@ainemut](https://twitter.com/ainemut)) was added as a lighter way to
  report something.

### Known

- YouTube and Spotify can refuse to hand audio over. iOS decides a video track
  exists, and nothing EffectDeck sets changes that. Stopping the video, or
  quitting the app, releases it. See #3 and #4.
- Battery while left routed overnight is still being measured. See #5.
