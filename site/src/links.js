// 外へ出るリンクと ID。アプリ側（ETShareLink / SettingsView / beta_release.md）と揃える。

// アプリが作る共有リンクの宛先で、唯一の associated domain（ETFXDLink.host / ETShareLink.deckBase）。
export const DECK_HOST = "effectdeck.nemut.ai";
// **短い方は人が打つための別名。**ページも AASA も持たず、全部を DECK_HOST へ 301。
// アプリはこの名前でリンクを作らない（受けるだけ）。
export const LINK_HOST = "fxd.nemut.ai";

export const APP_ID = "C82ST8T9MN.ai.nemut.effetune";
export const APP_STORE_ID = "6812467517";
export const APP_STORE = "https://apps.apple.com/app/effectdeck/id6812467517";
// **TestFlight はフッターのリンク 1 本だけ（worker.js）。**説明は書かない。
export const TESTFLIGHT = "https://testflight.apple.com/join/QtEVGZxn";
export const GITHUB = "https://github.com/satomasahiro2005/EffectDeck";
// どのビルドに何が入っているかはここに書く（ページには書かない）。
export const RELEASES = "https://github.com/satomasahiro2005/EffectDeck/releases";
export const LICENSE = "https://github.com/satomasahiro2005/EffectDeck/blob/main/LICENSE";
export const ISSUES = "https://github.com/satomasahiro2005/EffectDeck/issues";
export const JSFX_MD = "https://github.com/satomasahiro2005/EffectDeck/blob/main/JSFX.md";
export const TWITTER = "https://twitter.com/ainemut";
export const EMAIL = "support@nemut.ai";
export const EFFETUNE = "https://github.com/Frieve-A/effetune";
export const APPLE_PRIVACY = "https://www.apple.com/legal/privacy/";
export const CLOUDFLARE_PRIVACY = "https://www.cloudflare.com/privacypolicy/";

// アプリの「Write JSFX with ChatGPT」が開く/writeで見せる依頼文。**文面はここ1か所。**アプリは持たない。
// 変えてもアプリを出し直さなくて済む。
export const CHATGPT_Q =
  "Write a JSFX effect for EffectDeck, an iOS app that runs single-file JSFX. " +
  "First read https://github.com/satomasahiro2005/EffectDeck/blob/main/JSFX.md " +
  "and follow its authoring contract exactly. If you cannot open it, at least: " +
  "one file only, no import and no include(), and never write the text include( " +
  "anywhere; no file sliders, no filesystem, no MIDI; desc: comes before any @ " +
  "section; the interpreter is portable EEL2 without JIT, so keep @sample cheap. " +
  "Then ask me what effect I want, and reply with the complete script in one code block.";
export const CHATGPT = "https://chatgpt.com/?q=" + encodeURIComponent(CHATGPT_Q);
