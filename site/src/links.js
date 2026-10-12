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
// アプリのBuild with ChatGPT…が読ませるもの（EffectPickerView.buildChain）。
export const CHAIN_MD = "https://github.com/satomasahiro2005/EffectDeck/blob/main/CHAIN.md";
// Discordサーバー（EffectDeck Base）の入口。招待リンクを替えても外のリンクを直さずに済むよう、
// 人に見せるのは DISCORD だけで、招待リンクへは fxdb の 302 で飛ばす（worker.js の頭）。
export const DISCORD_HOST = "fxdb.nemut.ai";
export const DISCORD = `https://${DISCORD_HOST}`;
export const DISCORD_INVITE = "https://discord.gg/Y3DYJJmmDE";
export const TWITTER = "https://twitter.com/ainemut";
export const EMAIL = "support@nemut.ai";
export const EFFETUNE = "https://github.com/Frieve-A/effetune";
export const APPLE_PRIVACY = "https://www.apple.com/legal/privacy/";
export const CLOUDFLARE_PRIVACY = "https://www.cloudflare.com/privacypolicy/";
// プライバシーポリシーのLinks（アプリのChatGPTの2つの口がchatgpt.comを開く）。
export const OPENAI_PRIVACY = "https://openai.com/policies/privacy-policy/";

// /writeで見せる依頼文。**決め事はJSFX.mdに書き、ここには書かない。**
// 長くするとChatGPTへ渡る途中で切れる（"so keep"の手前までしか入らなかった）。
// アプリは2026-09-27からchatgpt.comを直に開き、依頼文も自分で持つ（DSPの版を入れるため）。
// /writeは古いビルドのボタンとホームのリンクのために残す。
export const CHATGPT_Q =
  "Write a JSFX effect for EffectDeck. " +
  "First read https://github.com/satomasahiro2005/EffectDeck/blob/main/JSFX.md " +
  "and follow it. Then ask me what effect I want.";
export const CHATGPT = "https://chatgpt.com/?q=" + encodeURIComponent(CHATGPT_Q);

// ページの主張の出典。**人物の経歴は一次資料で確かめたものだけ書く**（2026-10-10 に確認）。
// SONY_STORY: ソニーグループ R&D センター Tokyo Laboratory 19 の「主任研究員 / Distinguished Engineer」として
//   連載 Inside the Minds of Sony's Corporate Distinguished Engineers #1 に出ている。日本語のページ。
// FRIEVE_PREFERENCE: Fidelity と Preference を分ける考え方（note、日本語）。
export const SONY_STORY = "https://www.sony.com/ja/SonyInfo/technology/stories/entries/2021_kobayashi/";
export const FRIEVE_PREFERENCE = "https://note.com/frievea/n/na9057ee0bed3";
export const FRIEVE_AUDIO = "https://note.com/frievea/n/n8de6451b1efd";
// 移植の確かめ（公開しているテスト）。IR の前処理は上流のコードから golden を作って突き合わせている。
export const IR_GOLDEN = "https://github.com/satomasahiro2005/EffectDeck/blob/main/Tools/ir_prepare_golden.mjs";
export const TESTS = "https://github.com/satomasahiro2005/EffectDeck/tree/main/Tests";

// 補正と BRIR の入手先。**AutoEq は autoeq.app が正面**（repo の results は普通の人向けでないと README が言う）。
export const AUTOEQ = "https://autoeq.app/";
export const AUTOEQ_REPO = "https://github.com/jaakkopasanen/AutoEq";
// 機種ごとの <model> ParametricEQ.txt（autoeq.app の EqualizerAPO ParametricEq と同じ形式）。
export const AUTOEQ_RESULTS = "https://github.com/jaakkopasanen/AutoEq/tree/master/results";
// ASH Listening Set は素のデータ（CC BY-NC-SA 4.0 が原則）。ASH Toolset は生成する道具（AGPL-3.0）で、
// Simulation Export の True Stereo WAV BRIRs が BRIR_True_Stereo.wav（4ch、LL/LR/RL/RR）を出す。
export const ASH_SET = "https://github.com/ShanonPearce/ASH-Listening-Set";
// 部屋ごとに BRIR_Rxx_C1_True_Stereo.wav（4ch）がそのまま置いてある。ガイドはこれを 1 つ落とすだけにした。
export const ASH_BRIRS = "https://github.com/ShanonPearce/ASH-Listening-Set/tree/main/BRIRs";
export const ASH_TOOLSET = "https://github.com/ShanonPearce/ASH-Toolset";
export const IR_REVERB_DOC = "https://effetune.frieve.com/dsp/effects/ir-reverb/";
