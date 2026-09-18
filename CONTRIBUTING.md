# Contributing

An issue on its own is plenty. You do not have to send code.

## Written with an AI is fine

Issues, pull requests, either one. I am not asking you to declare it, and it counts
the same as anything else.

The one thing I do ask: **run it on a device first.** The extension needs iOS 27 and
no audio flows in the simulator, so a change can look right in the diff and still pass
silence through. Say which device and which iOS version you tried it on.

## Issues

Say what you were playing from (Spotify, Safari, a podcast app), what was in the chain,
and what you heard. If the app never appeared in Control Center, read **If it says
Unable to Connect** in the README first — it is usually Spotify's Canvas.

## Pull requests

`bash Scripts/build.sh` builds and installs on the attached device. `bash Scripts/setup.sh`
generates the Xcode project. Both are in the README under **Building**.

## About the DSP under `Vendor/effetune`

That code is EffeTune's, not this project's. If something looks wrong in there, raise it
here first. This host uses that code in ways upstream never intended, so most of what
looks like a DSP bug turns out to be ours.

**Do not report it upstream until you have reproduced it in EffeTune itself** — the
desktop or web build, without this app in the picture. Upstream is not responsible for
EffectDeck and must not be made to carry its bugs.
