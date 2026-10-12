// ガイドの文面。/guide は目次、/guide/<slug> が 1 ページずつ（2026-10-10 に 1 ページから分けた。
// 画像が多く 1 ページでは長すぎ、BRIR や AutoEq で探す人が着くページと共有するリンクが要るため）。
//
// **順番に読まなくてよい。**補正（correction）はやらなくてよいし、brir と chatgpt は先へ進みたい人向け。
// 各ページは「何ができるか → 短い手順 → 気をつけること → できたと言える条件」。
//
// **操作の名前はアプリの字と合わせる。**Output Correction・IR Reverb・Dry・Direct Cut・
// Channel Mode・True Stereo・15Band PEQ・Save current chain・Share this chain・Import from clipboard・
// System Presets は Sources/EffeTuneLive のラベルそのまま。アプリ側で変えたらここも変える。
//
// **リリースごとに変わることは書かない**（text.js の頭と同じ決め事）。test.mjs が TEXT と同じ目でここも見る
// （"build" という字も引っかかるので、鎖は assemble / put together と書く）。
//
// 外のデータの条件は言い切らずに「確かめて」と書く。ASH の素データ（CC BY-NC-SA 4.0 が原則）と
// 道具（AGPL-3.0）はライセンスが別もので、アプリに同梱する前提にしない。
//
// 中身は block の列で持ち、worker.js の guidePage が並べる。
//   { h, id }  章の中の見出し     { p }   段落（HTML 可）
//   { ol }     番号つきの手順      { ul }  箇条書き
//   { note }   気をつけること      { flow } 信号の通り道の 1 行
//   { table }  表（head と rows）  { shot } スクリーンショット（TEXT.shots の file）
//   { done }   「できたと言える条件」
//   { shots }  縦長の画面を横に並べる [[id, 説明], …]。id が TEXT.shots の file なら本物の画像、
//              それ以外は撮るまでのプレースホルダー（枠に id、下に説明）。撮ったら assets/shot-<id>.webp に置く
//   { wide }   横長の図かスクリーンショット 1 枚 [id, 説明]（同じくプレースホルダー）

import {
  AUTOEQ, AUTOEQ_RESULTS, ASH_SET, ASH_BRIRS, ASH_TOOLSET, CHAIN_MD, JSFX_MD, EFFETUNE,
  SONY_STORY, FRIEVE_PREFERENCE, FRIEVE_AUDIO, IR_GOLDEN, TESTS, DISCORD, GITHUB,
} from "./links.js";

const a = (href, label) => `<a href="${href}">${label}</a>`;
const b = (s) => `<strong>${s}</strong>`;
const c = (s) => `<code>${s}</code>`;

// 1 章 1 ページ（/guide/<slug>）。/guide は目次だけ。並びがそのまま前へ／次への順。
// title は h1 と <title>、description は meta と og。card は目次とトップのカードの 1 行。
export const GUIDE = {
  title: "Guide",
  description:
    "Get your music into EffectDeck, correct your headphones, try the effects, put a pair of speakers inside your headphones with a BRIR, make new effects with ChatGPT, and share a chain.",
  lead: "Six parts. Read them in any order. Correcting your headphones is optional, and the last parts are for when you want to go further.",
  pages: [
    {
      slug: "connect",
      title: "Get your music into EffectDeck",
      card: "Pick EffectDeck as the output in Control Center. Your music keeps playing, through your chain.",
      description: "Pick EffectDeck as the audio output in Control Center on iOS 27, and the music from your usual apps runs through your effect chain.",
      goal: "Your usual listening, running through EffectDeck, on the headphones or speakers you already use.",
      blocks: [
        { ol: [
          "Install EffectDeck on an iPhone or iPad running iOS 27 or later.",
          "Start playing in an app that shows up in Now Playing: a music app, a podcast player, Safari.",
          `Open Control Center, tap the AirPlay button on the music player, and pick ${b("EffectDeck")}.`,
          "The music keeps playing, out of whatever you were listening on before.",
        ] },
        { shots: [
          ["g-connect-1", "Control Center, with the music player"],
          ["g-connect-2", "The player: tap the AirPlay button"],
          ["g-connect-3", "The outputs: EffectDeck is in the list"],
          ["g-connect-3b", "EffectDeck picked"],
          ["g-connect-4", "EffectDeck: the chain running and the meters moving"],
        ] },
        { flow: ["Music app", "Your effect chain in EffectDeck", "Speaker, headphones or AirPods"] },
        { p: "EffectDeck shows up as an audio output through the Media Device Extension added in iOS 27. No jailbreak, no virtual audio cable, nothing to install on a computer." },
        { note: "This covers media playback, not every sound the device makes. An app with no Now Playing transport, a game for instance, does not go through it." },
        { done: ["Sound is coming out through EffectDeck. Nothing else in this guide needs more setup than that."] },
      ],
    },
    {
      slug: "correction",
      title: "Correct your headphones",
      tag: "Optional",
      card: "Give your headphones a known starting point, kept apart from the sound you make.",
      description: "Have ChatGPT set up an AutoEq correction for your headphones in EffectDeck, or import one into 15Band PEQ yourself, and keep it per output device with Output Correction.",
      goal: "Separate what your headphones do to the sound from what you want to do to it.",
      blocks: [
        { p: "Every pair of headphones has its own frequency response. A correction is an EQ that undoes the difference between that response and a chosen target, so that two different pairs start from about the same place. It gives every pair the same starting point." },
        { p: "A target is a reference point. The listening tests behind the common targets found a preferred average, and people spread out around it: some want more bass than the curve, some less." },
        { h: "The quick way: have ChatGPT set it up", id: "correction-chatgpt" },
        { ol: [
          `Tap ${b("Build with ChatGPT…")} at the top of the effect list. ChatGPT opens with the request already written, pointing it at ${a(CHAIN_MD, "CHAIN.md")}.`,
          "Tell it the model of your headphones, and the target if you have one in mind.",
          `Tap the link it gives you, or copy the chain and use ${b("Presets &rarr; Import from clipboard")}.`,
          "Read the numbers it produced and check the measurement it cites.",
        ] },
        { shots: [
          ["g-correction-7", "Build with ChatGPT… at the top of the effect list"],
          ["g-correction-8-0", "The request Build with ChatGPT… writes for you"],
          ["g-correction-8a", "Asking for a correction: ChatGPT finds a measurement on AutoEq"],
          ["g-correction-8", "The answer: 15Band PEQ, then Volume, and a link to tap"],
        ] },
        { note: "If there is no measurement of your model, do not let it make the numbers up. An invented correction is worse than none. A paid ChatGPT plan is worth it here: the free plan often skips the linked file and returns a chain that does not import." },
        { h: "Or do it yourself with AutoEq", id: "autoeq" },
        { ol: [
          `Open ${a(AUTOEQ, "autoeq.app")} and look up your headphones. Check whose measurement it is based on.`,
          `Under ${b("Select equalizer app")}, choose ${b("EqualizerAPO ParametricEq")} and download the file, ${c("ParametricEQ.txt")}: a Preamp line and ten ${c("Filter")} lines.`,
          `In EffectDeck, add ${b("15Band PEQ")} to the chain and use its ${b("Import")} button on that file.`,
        ] },
        { shots: [
          ["g-correction-2", "autoeq.app with the headphones selected"],
          ["g-correction-2b", "Select equalizer app: EqualizerAPO ParametricEq, with the Preamp below"],
          ["g-correction-4", "15Band PEQ in the chain, with its Import button"],
          ["g-correction-3", "Import: picking the ParametricEQ file"],
          ["g-correction-4b", "15Band PEQ after the import"],
          ["g-correction-5", "A Volume after the EQ, set to the Preamp value"],
        ] },
        { note: `The same files are in the ${a(AUTOEQ_RESULTS, "results folder of the AutoEq repository")}, one per model as ${c("<model> ParametricEQ.txt")}. Open yours on GitHub, tap ${b("Raw")} and save it to Files.` },
        { p: `The importer takes the peaking and shelf filters, up to fifteen, and does not read the ${c("Preamp")} line. Do the preamp's job with a ${b("Volume")} right after the EQ: set it to the Preamp value from the file, for example -4 dB. A correction with boosts in it would otherwise run hotter than the original.` },
        { note: `Why the Volume can come after the EQ: the chain runs in 32-bit floating point, so the EQ's boosts do not clip on the way to the Volume, and an EQ and a gain are both linear, so their order changes nothing but rounding far below hearing (24 bits of precision, around 144 dB).` },
        { h: "Keep it out of your way: Output Correction", id: "output-correction" },
        { p: `A correction belongs to the headphones, not to the sound you are playing with. ${b("Output Correction")} keeps it separate, per output device.` },
        { ol: [
          "Make a chain that holds the correction and nothing else.",
          `${b("Presets &rarr; Save current chain")}, named after the headphones.`,
          "Take the correction back out of your playing chain, so that it is not applied twice.",
          `Open ${b("Output Correction")} in Presets.`,
          "Pick the output device and assign the preset you just saved.",
          "Turn it on.",
        ] },
        { shots: [
          ["g-correction-10", "Presets: Save current chain, named after the headphones"],
          ["g-correction-11", "Saved: the preset under User Presets"],
          ["g-correction-12", "Output Correction: the correction assigned to the earbuds"],
          ["g-correction-13", "Choosing the saved preset for a device"],
          ["g-correction-14", "The correction runs after the chain, shown under it"],
        ] },
        { p: "From then on it runs after your chain, on its own. Change your sound as much as you like; the correction follows the output, not the chain. Plug in other headphones and the correction assigned to them comes along." },
        { done: [
          "You can switch the correction off and on and hear the difference on the same track.",
          "Changing the output changes the correction with it.",
        ] },
      ],
    },
    {
      slug: "effects",
      title: "Try the effects",
      card: "Finished presets first, then what each kind of effect does, then a chain of your own.",
      description: "Try EffectDeck's Vinyl, Tube Amp and Fm Radio presets, learn what EQ, dynamics, saturation, reverb and spatial effects do, and put a chain together.",
      goal: "Find a sound you actually like: finished presets first, single effects after, then a chain of your own.",
      blocks: [
        { h: "Start with a sound someone already finished", id: "presets" },
        { p: `${b("Presets")} (the stack button at the top) &rarr; ${b("System Presets")} holds complete chains, in folders such as Lo-Fi, Amp Simulation and Processor. Pick one and it replaces your chain. Play a track you know well, and switch it off and on at the same level.` },
        { note: `The same presets are also under ${b("Available Effects &rarr; Presets")}. From there a preset is added to your chain as a named ${b("Section")} instead of replacing it.` },
        { shots: [
          ["g-effects-1", "Available Effects, Presets: adds a preset as a Section"],
          ["g-effects-2", "Presets, System Presets, Lo-Fi"],
        ] },
        { table: {
          head: ["Preset", "What you hear"],
          rows: [
            ["Lo-Fi / Vinyl", "Surface noise, wow and flutter, the narrower band of a record"],
            ["Amp Simulation / Tube Amp", "The harmonics and soft compression of a valve stage"],
            ["Processor / Fm Radio", "Broadcast processing: squeezed, band-limited, loud"],
            ["Visualize / All Analyzers", "Nothing. It shows you the signal instead of changing it"],
          ],
        } },
        { shots: [
          ["g-effects-3", "The Vinyl preset loaded"],
          ["g-effects-4", "The Tube Amp preset loaded"],
          ["g-effects-5", "The Fm Radio preset loaded"],
          ["analyzers", "Analyzers: level meter, spectrogram, spectrum and stereo meter"],
        ] },
        { h: "What the effects do", id: "kinds" },
        { ul: [
          `${b("EQ")}: makes a band louder or quieter. The most direct control over tone. Start with the frequency and the gain.`,
          `${b("Dynamics")}: compressors, gates, limiters. They change how the loud and quiet parts relate. Start with the threshold.`,
          `${b("Saturation and distortion")}: non-linear, so they add harmonics that were not there. Start with the drive, and keep the output level honest.`,
          `${b("Reverb and delay")}: reflections and time. Start with the amount, not the length.`,
          `${b("Spatial")}: width, and where things sit between your ears.`,
          `${b("Analyzers")}: a spectrum analyzer, a spectrogram, meters. They change nothing and tell you what is happening, which is often what was missing.`,
          `${b("AUv3 plug-ins")}: effect plug-ins from other apps on your iPhone or iPad go in the same chain, next to the built-in ones.`,
        ] },
        { shots: [
          ["g-effects-6", "An EQ: bands on the response curve"],
          ["g-effects-7", "A compressor: threshold, ratio and gain reduction"],
          ["effects", "Saturation: Multiband Saturation with its drive"],
          ["g-effects-8", "A reverb: the amount and the length"],
          ["g-effects-9", "Spatial: Stereo Blend widening the image"],
          ["g-effects-10", "The spectrum analyzer while an EQ band moves"],
        ] },
        { note: "Compare at the same level. Whatever is louder sounds better for the first few seconds, and that is the easiest way to fool yourself." },
        { shots: [
          ["g-effects-11", "Level meter: effect off"],
          ["g-effects-12", "Level meter: effect on, at the same level"],
        ] },
        { h: "Put a chain together", id: "chain" },
        { p: `A chain runs top to bottom, so order matters. ${c("EQ &rarr; Saturation &rarr; Reverb")} is not ${c("Reverb &rarr; Saturation &rarr; EQ")}: an EQ before the saturation decides what gets distorted, an EQ after it decides what you keep. Add effects, remove them, switch one off, drag them into another order.` },
        { shots: [
          ["g-effects-13", "Adding an effect: search Available Effects"],
          ["g-effects-15", "An effect switched off in the chain"],
          ["g-effects-16", "EQ before Saturation, and the same chain the other way round"],
        ] },
        { p: `A ${b("Section")} groups a run of effects so that you can switch a whole idea off at once. Output Correction comes after all of it.` },
        { shots: [
          ["g-effects-17", "A Section grouping a run of effects"],
          ["g-effects-18", "The Section switched off as a whole"],
          ["routing", "Effects with bus routing badges"],
        ] },
        { done: [
          "You tried at least one preset, and at least one effect on its own.",
          "You saved a chain you like.",
        ] },
      ],
    },
    {
      slug: "brir",
      title: "Put a pair of speakers inside your headphones",
      tag: "Going further",
      card: "Download one BRIR file, load it in IR Reverb, and your headphones sound like speakers in front of you.",
      description: "Download a True Stereo BRIR from ASH Listening Set and load it into EffectDeck's IR Reverb to hear a pair of speakers in a room through your headphones.",
      goal: "Headphones that sound like a pair of speakers in front of you.",
      blocks: [
        { p: `A ${b("BRIR")} (binaural room impulse response) is a measurement of speakers in a real room, taken at the ears. Run the music through it and the sound moves out of your head and in front of you, like a pair of speakers on a desk.` },
        { h: "Get a file", id: "brir-sources" },
        { ol: [
          `Open the ${a(ASH_BRIRS, "BRIRs folder of ASH Listening Set")} and pick a room (R01, R02, and so on).`,
          `Download the file that ends in ${c("True_Stereo.wav")}, for example ${c("BRIR_R01_C1_True_Stereo.wav")}, and save it to Files.`,
        ] },
        { wide: ["g-brir-2", "ASH Listening Set on GitHub: a room's True_Stereo file"] },
        { shots: [
          ["g-brir-4", "The file in the Files app"],
        ] },
        { note: `ASH Listening Set is published under ${c("CC BY-NC-SA 4.0")}. Use it freely; do not sell it or pass the files on as your own.` },
        { h: "Load it", id: "brir-settings" },
        { ol: [
          `Add ${b("IR Reverb")} to the chain (${b("Available Effects &rarr; Effects")}).`,
          `${b("Import file&hellip;")} and pick the file you downloaded.`,
          `Turn ${b("Dry")} off and ${b("Direct Cut")} off.`,
          `Turn your volume down, then raise ${b("Wet Level")} until it sounds right.`,
        ] },
        { shots: [
          ["g-brir-5", "Available Effects: IR Reverb under Reverb"],
          ["g-brir-6", "Import file…: picking the downloaded file"],
          ["g-brir-7", "IR Reverb with the file loaded"],
          ["g-brir-8", "Dry off and Direct Cut off"],
          ["g-brir-10", "Wet Level raised, meters below clipping"],
        ] },
        { note: `${b("Dry")} adds the plain headphone sound back in. With a BRIR you only want the speakers, so it stays off.` },
        { done: [
          "The music sits in front of you instead of between your ears.",
          "Switching IR Reverb off and on makes the difference obvious.",
        ] },
      ],
    },
    {
      slug: "chatgpt",
      title: "Have ChatGPT make what is missing",
      tag: "Going further",
      card: "Describe a sound and get a chain, or a new effect written in JSFX.",
      description: "Use Build with ChatGPT… for a chain of EffectDeck's effects (CHAIN.md), or Write JSFX with ChatGPT for a new effect in JSFX, the script format REAPER uses (JSFX.md).",
      goal: "Describe a sound in words and get a chain or a new effect that EffectDeck loads.",
      blocks: [
        { p: `There are two doors. ${b("Build with ChatGPT…")}, at the top of the effect list, asks for a ${b("chain")} of the effects already here, following ${a(CHAIN_MD, "CHAIN.md")}. ${b("Write JSFX with ChatGPT")}, under Plugins, asks for ${b("one new effect")} written as a JSFX script, following ${a(JSFX_MD, "JSFX.md")}.` },
        // アプリの2つの口はchatgpt.comを直に開く（EffectPickerView.writeJSFX / buildChain、61efe19）。
        // 戻し方はCHAIN.mdの「Handing the chain over」と同じ2つ（リンクか、コードブロックを貼る）。
        { h: "A new effect in JSFX", id: "jsfx" },
        { p: `EffectDeck loads JSFX, the script format REAPER uses. One text file is one effect. ${a(JSFX_MD, "JSFX.md")} sets out what EffectDeck supports and what it rejects, and it is written to be handed to a language model as it is.` },
        { p: `${b("Write JSFX with ChatGPT")} opens ChatGPT with a short request that points it at JSFX.md. Import the file it returns with ${b("Import JSFX &rarr; From Files")}, or copy the script and use ${b("From Clipboard")}. For another assistant, ${a("/write", "Write JSFX with ChatGPT")} on this site has the same kind of request to copy.` },
        { h: "A chain of the effects already here", id: "chain-chatgpt" },
        { p: `${b("Build with ChatGPT…")} opens ChatGPT the same way to ask for a chain of the built-in effects, following ${a(CHAIN_MD, "CHAIN.md")}. Tap the link it returns, or copy the chain and use ${b("Import from clipboard")} in Presets.` },
        { h: "How it goes", id: "steps" },
        { ol: [
          "Describe the sound you want, in whatever language you think in.",
          "Let it read the specification and answer in that format.",
          `Take a chain in by its link or with ${b("Import from clipboard")}; take a script in with ${b("Import JSFX &rarr; From Files")} or ${b("From Clipboard")}.`,
          "Play it, and watch the meters.",
          "Adjust it yourself, or tell it what was wrong.",
        ] },
        { shots: [
          ["g-chatgpt-1", "Build with ChatGPT\u2026 at the top of the effect list"],
          ["g-chatgpt-3", "Write JSFX with ChatGPT, under Plugins"],
          ["g-chatgpt-5", "Import JSFX: From Files and From Clipboard"],
          ["g-chatgpt-6", "The new JSFX effect running in the chain"],
        ] },
        { note: "A paid plan is recommended for both: the model has to read a linked specification and keep a long piece of code consistent, and the free plan often does not. Loading without an error is also not the same as sounding right. That part is still yours to judge." },
        { done: [
          "Something you described in words is running in your chain.",
          "You listened to it, not only checked that it loaded.",
        ] },
      ],
    },
    {
      slug: "share",
      title: "Share what you made",
      card: "Save a chain, send it as a link, and try someone else's.",
      description: "Save an EffectDeck chain as a preset, share it as a link, and open chains other people made. What travels in a link and what does not.",
      goal: "Keep a sound, hand it to someone, and try theirs on your own gear.",
      blocks: [
        { h: "Save it", id: "save" },
        { p: `${b("Presets &rarr; Save current chain")} keeps a copy of the chain as it is now. It is a copy: editing the chain later does not change the preset.` },
        { h: "Make a link", id: "link" },
        { ul: [
          // 鎖はいつもeffectdeck.nemut.aiのリンクになる（ETShareLink.deckURL(for:)）。EffeTuneへはそのページから（parse.jsのeffeTuneLink）。
          `${b("Presets &rarr; Share this chain")}. Chains and JSFX scripts are shared as links on effectdeck.nemut.ai. With the app installed, they open in the app.`,
          `Without the app, the link shows the chain with ${b("Open in EffeTune")}, so someone on a computer can open it in the EffeTune web app. AUv3 plug-ins and JSFX effects are left out there.`,
          "The chain travels, the plug-ins do not: whoever opens it needs the same ones.",
          "A chain link does not carry JSFX source code. A JSFX script shared on its own does: the whole script is in the link, after the #, which browsers never send to a server.",
          "Impulse response files are not in links either. Send the file, or say where it came from and under what terms.",
          "With Output Correction on, you can share the chain alone or with the correction included. Either way, which headphones it belongs to stays on your device.",
        ] },
        { shots: [
          ["g-share-3", "Presets: Share this chain, with Import from clipboard below it"],
          ["g-share-5", "The share sheet with the link"],
        ] },
        { h: "Open someone else's", id: "open" },
        { ol: [
          `Tap the link with EffectDeck installed, or copy the chain and use ${b("Import from clipboard")}.`,
          "Check what it expects (an AUv3 plug-in, a JSFX effect, an impulse response) and fill in what you are missing.",
          "Save it as your own preset.",
        ] },
        { shots: [
          ["g-share-7", "Tapping a chain link: EffectDeck asks before it replaces your chain"],
          ["g-share-8", "EffectDeck offering to import the copied chain"],
        ] },
        { p: `People post chains on ${a(DISCORD, "Discord")}. The source, the specifications and the issue tracker are on ${a(GITHUB, "GitHub")}.` },
        { done: ["Your chain opens on someone else's phone, and theirs on yours."] },
      ],
    },
  ],
};

// /about の出典。**確かめたものだけリンクする。**AES の 3 本は e-library が機械から読めず
// 番号を確かめられないので、名前だけにして AES E-Library で引けるようにする。
export const SOURCES = {
  title: "Where this comes from",
  items: [
    `${a(EFFETUNE, "EffeTune")}: the open-source audio processor whose DSP EffectDeck uses, by Yoshiyuki Kobayashi (Frieve-A), under the MIT license.`,
    `${a(SONY_STORY, "Sony Group, Inside the Minds of Sony's Corporate Distinguished Engineers #1")}: his own account of his work, from professional audio signal processing to machine learning. In Japanese.`,
    `Frieve-A ${a(FRIEVE_PREFERENCE, "on fidelity and preference")} and ${a(FRIEVE_AUDIO, "on the end and rebirth of audio")}: keep the hardware faithful and inexpensive, and let DSP carry the taste. In Japanese.`,
    "Olive, Welti and McMullin (Audio Engineering Society, 2013): Listener Preferences for Different Headphone Target Response Curves; A Virtual Headphone Listening Test Methodology; Listener Preferences for In-Room Loudspeaker and Headphone Target Responses. In the AES E-Library.",
    `${a(AUTOEQ, "AutoEq")}: measurement-based corrections for thousands of headphones.`,
    `${a(ASH_SET, "ASH Listening Set")} and ${a(ASH_TOOLSET, "ASH Toolset")}: BRIR data, and the tool that makes it.`,
    `${a(IR_GOLDEN, "ir_prepare_golden.mjs")} and the ${a(TESTS, "tests")}: how the port is checked against the upstream code.`,
  ],
};
