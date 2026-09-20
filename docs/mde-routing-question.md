# Reverse-engineering task: `MXCustomRoutingController` MDE routing decision

ユーザーが用意した課題文。issue #3 / #4 のため。**そのまま貼れる形で残す。**

---

Investigate the iOS 27 `MediaExperience` logic around:

```objc
-[MXCustomRoutingController modifyCurrentSelectionIfNecessary:isPlayingVideoOutput:]
```

The goal is to reconstruct exactly when an app that does **not** explicitly support the selected Media Device Extension protocol is allowed to remain on that route.

EffectDeck:
https://github.com/satomasahiro2005/EffectDeck

Relevant issues:
- #3: https://github.com/satomasahiro2005/EffectDeck/issues/3
- #4: https://github.com/satomasahiro2005/EffectDeck/issues/4

Please read both issues first; they contain the current reproduction results and logs.

## Known behavior

EffectDeck exposes an audio-only MDE protocol:

```text
media-device-protocol.ai.nemut.effetune
```

Observed allow/fallback conditions include:

- `MDESupportedProtocols`
- `MDESupportsUniversalURLPlayback`
- presence of a MusicVAD
- already/currently mirroring
- a long-form-video path involving `allowsExternalPlayback == NO`
- otherwise, video/long-form-video can trigger an AirPlay fallback

A normal Spotify session can be allowed with:

```text
isPlayingVideoOutput: NO
...
Allow session ... because there is a MusicVAD.
```

YouTube video playback instead reaches:

```text
isPlayingVideoOutput: YES
...
playing video or a long-form-video app.
Will attempt to switch to AirPlay
```

We also confirmed that this check is **not activation-only**. EffectDeck can already be connected and carrying Spotify, then starting YouTube playback invokes the routing decision again and disconnects EffectDeck.

## What to determine

Please reconstruct the decision tree of:

```objc
-[MXCustomRoutingController modifyCurrentSelectionIfNecessary:isPlayingVideoOutput:]
```

In particular:

1. What is the exact order of all allow/reject branches?
2. Can the MusicVAD allow path ever override `isPlayingVideoOutput == YES`, or is video rejected before that check?
3. What exact object/state is tested by the "there is a MusicVAD" condition?
4. Is that MusicVAD global, tied to SystemMusic, tied to the current session, or tied to the current Now Playing app?
5. What is the exact condition involving `allowsExternalPlayback == NO`?
6. Are MDE properties such as `RouteSupportsVideo`, `RouteSupportsScreen`, `OnlySupportsRealtimeAudio`, transport type, or any other endpoint capability consulted here?
7. What other conditions can allow an otherwise unsupported application to remain on the custom MDE protocol?
8. What calls/re-triggers this decision when playback/session state changes?

Please provide reconstructed pseudocode or a CFG where possible, plus relevant callees, selectors, constants, bundle keys, and log strings.

## Main question

The practical goal is to determine whether EffectDeck can legitimately satisfy a **single system-side allow condition** that would keep the audio-only MDE route active for both #3 and #4 when:

```text
isPlayingVideoOutput == YES
```

If no such condition exists, identify exactly which branch makes that impossible.
