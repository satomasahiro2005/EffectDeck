**Public beta on TestFlight.** [Join](https://testflight.apple.com/join/QtEVGZxn)

This is a beta. It will have bugs the App Store build does not.

**The beta icon is purple**, so you can tell which build you are on when
something misbehaves. Installing from the
[App Store](https://apps.apple.com/app/effectdeck/id6812467517) puts you back on
the released version at any time.

If you hit something, use **Settings → Report a problem** in the app (it fills in
the diagnostics and the log for you), or tell
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
- A script that overruns its time budget is bypassed automatically and says so
  on the card. **Re-enable** puts it back.
- **Details** shows how close to the deadline each script is running.
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

- Reordering is decided by how the cards actually overlap, so a card no longer
  runs away from your finger. You can scroll while reordering.
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

- Reporting a problem prefills the diagnostics and the last 1 MB of the log.
- Twitter ([@ainemut](https://twitter.com/ainemut)) was added as a lighter way to
  report something.
- Licenses moved to their own page.
- The text about picking EffectDeck when it will not stick was rewritten from
  what actually happens on the device: pick it while audio is playing, and if it
  drops back to the speaker a moment later, try again.

### Known

- YouTube and Spotify can refuse to hand audio over. iOS decides a video track
  exists, and nothing EffectDeck sets changes that. Stopping the video, or
  quitting the app, releases it. See #3 and #4.
- Battery while left routed overnight is still being measured. See #5.
