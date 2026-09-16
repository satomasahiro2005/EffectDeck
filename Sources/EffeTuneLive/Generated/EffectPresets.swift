//  EffectPresets.swift
//  Tools/gen_effect_presets.py が作る。手で直さないこと。
//
//  中身は EffeTune の各プラグインが定数で持っている出荷時プリセット
//  （上流の呼び名は「System Presets」）。上流は .js の先頭に
//  `const <NAME>_SYSTEM_PRESETS = Object.freeze([...])` を置き、
//  クラスに `static getSystemPresetGroups()` を生やしている。
//  読むのは EffectPresetApply で、params は ETParamCoding.decode が食う。
//
//  鎖ぜんぶのプリセット（SystemPresets.swift）とは別物。あちらは
//  .effetune_preset のファイルで、こちらはエフェクト 1 個ぶんの設定。

import Foundation

/// 出荷時プリセット 1 件。綴りは上流の `{ id, label, params }` に合わせる。
struct ETEffectPreset: Identifiable {
    /// **上流の id は別のエフェクトと重なる。** "gramophone" は
    /// AM Radio Simulator と SW Radio Simulator の両方にある（実測で 5 件）。
    /// ForEach に渡すのはエフェクト名と繋いだこちら。
    var id: String { effect + "/" + presetId }
    /// エフェクトの**表示名**。上流の PluginPresetStore が
    /// this.plugin.name で引くのと同じ鍵。
    let effect: String
    /// 上流の preset.id。一致判定に使う。
    let presetId: String
    /// 画面に出す名前。上流の preset.label。
    let label: String
    /// 上流 getSystemPresetGroups() のグループ名。
    /// **Tube Simulator 以外は全部空**（グループが 1 つしか無い）。
    let group: String
    /// 上流の preset.params をそのまま。辞書へ戻すのは ETEffectPreset.params。
    let json: String
}

/// 上流の並びのまま。グループの順（Pre → Power → Pre+Power）も、
/// グループの中の順も、上流が返したとおり。
let ETEffectPresetList: [ETEffectPreset] = [
    ETEffectPreset(
      effect: "Power Amp Sag",
      presetId: "vintage-tube-sag",
      label: "Vintage Tube Sag",
      group: "",
      json: #"""
      {"ss":8,"ps":30,"rs":25,"mb":false}
      """#),
    ETEffectPreset(
      effect: "Power Amp Sag",
      presetId: "modern-monoblocks",
      label: "Modern Monoblocks",
      group: "",
      json: #"""
      {"ss":1,"ps":85,"rs":70,"mb":true}
      """#),
    ETEffectPreset(
      effect: "Power Amp Sag",
      presetId: "pushed-combo",
      label: "Pushed Combo",
      group: "",
      json: #"""
      {"ss":12,"ps":20,"rs":50,"mb":false}
      """#),
    ETEffectPreset(
      effect: "Earphone Cable Sim",
      presetId: "high-impedance-source",
      label: "High Impedance Source",
      group: "",
      json: #"""
      {"zo":10,"rc":0.3,"lc":0.5,"lv":0.35,"zb":16,"rf0":120,"rq0":2,"rz0":48,"re0":true,"rf1":2000,"rq1":1.5,"rz1":36,"re1":false,"rf2":5000,"rq2":2,"rz2":64,"re2":false,"rf3":9000,"rq3":3,"rz3":80,"re3":false,"rf4":60,"rq4":1.5,"rz4":64,"re4":false}
      """#),
    ETEffectPreset(
      effect: "Earphone Cable Sim",
      presetId: "long-thin-cable",
      label: "Long Thin Cable",
      group: "",
      json: #"""
      {"zo":0.5,"rc":1.2,"lc":3,"lv":0.2,"zb":16,"rf0":120,"rq0":2,"rz0":48,"re0":true,"rf1":2000,"rq1":1.5,"rz1":36,"re1":false,"rf2":5000,"rq2":2,"rz2":64,"re2":false,"rf3":9000,"rq3":3,"rz3":80,"re3":false,"rf4":60,"rq4":1.5,"rz4":64,"re4":false}
      """#),
    ETEffectPreset(
      effect: "Earphone Cable Sim",
      presetId: "vintage-portable-out",
      label: "Vintage Portable Out",
      group: "",
      json: #"""
      {"zo":6,"rc":0.8,"lc":2,"lv":0.3,"zb":32,"rf0":120,"rq0":2,"rz0":48,"re0":true,"rf1":2000,"rq1":1.5,"rz1":36,"re1":false,"rf2":5000,"rq2":2,"rz2":64,"re2":false,"rf3":9000,"rq3":3,"rz3":80,"re3":false,"rf4":60,"rq4":1.5,"rz4":64,"re4":false}
      """#),
    ETEffectPreset(
      effect: "Loudness Equalizer",
      presetId: "late-night-listening",
      label: "Late Night Listening",
      group: "",
      json: #"""
      {"sp":63,"rv":-12,"lf":200,"lg":12,"lq":0.6,"hf":4000,"hg":6,"hq":0.6}
      """#),
    ETEffectPreset(
      effect: "Loudness Equalizer",
      presetId: "quiet-background",
      label: "Quiet Background",
      group: "",
      json: #"""
      {"sp":68,"rv":-6,"lf":180,"lg":7,"lq":0.6,"hf":4000,"hg":3,"hq":0.6}
      """#),
    ETEffectPreset(
      effect: "Loudness Equalizer",
      presetId: "near-reference-level",
      label: "Near Reference Level",
      group: "",
      json: #"""
      {"sp":80,"rv":-2,"lf":180,"lg":2,"lq":0.6,"hf":4000,"hg":0,"hq":0.6}
      """#),
    ETEffectPreset(
      effect: "AM Radio Simulator",
      presetId: "local-daytime",
      label: "Local Daytime Station",
      group: "",
      json: #"""
      {"rd":true,"tb":10,"pe":50,"md":90,"cp":6,"sm":"Mono","sg":-5,"sk":0,"fd":0.15,"st":0,"in":-65,"io":9,"tn":0,"bw":16,"ag":"Fast","dt":50,"hm":-70,"hz":"50","sp":"Table","og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "AM Radio Simulator",
      presetId: "pocket-transistor",
      label: "Pocket Transistor",
      group: "",
      json: #"""
      {"rd":true,"tb":6,"pe":50,"md":90,"cp":10,"sm":"Mono","sg":-18,"sk":1,"fd":0.15,"st":1,"in":-65,"io":9,"tn":0,"bw":8,"ag":"Fast","dt":50,"hm":-60,"hz":"50","sp":"Small","og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "AM Radio Simulator",
      presetId: "night-skywave",
      label: "Night Skywave",
      group: "",
      json: #"""
      {"rd":true,"tb":6,"pe":50,"md":90,"cp":6,"sm":"Mono","sg":-30,"sk":85,"fd":0.3,"st":5,"in":-50,"io":9,"tn":0,"bw":8,"ag":"Fast","dt":50,"hm":-70,"hz":"50","sp":"Table","og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "AM Radio Simulator",
      presetId: "summer-thunderstorm",
      label: "Summer Thunderstorm",
      group: "",
      json: #"""
      {"rd":true,"tb":6,"pe":50,"md":90,"cp":6,"sm":"Mono","sg":-25,"sk":60,"fd":0.2,"st":60,"in":-45,"io":9,"tn":0,"bw":12,"ag":"Fast","dt":50,"hm":-70,"hz":"50","sp":"Table","og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "AM Radio Simulator",
      presetId: "stereo-am-broadcast",
      label: "Stereo AM Broadcast",
      group: "",
      json: #"""
      {"rd":true,"tb":6,"pe":50,"md":90,"cp":6,"sm":"C-QUAM","sg":-8,"sk":0,"fd":0.15,"st":0,"in":-65,"io":9,"tn":0,"bw":12,"ag":"Fast","dt":50,"hm":-70,"hz":"50","sp":"Off","og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "Cassette Artifacts",
      presetId: "flagship-deck-metal",
      label: "Flagship Deck Metal",
      group: "",
      json: #"""
      {"dg":"Reference","tp":"Type IV","nr":"Dolby C","bs":0,"rl":6,"wf":0.04,"hs":-70,"dp":0,"az":0,"dl":0,"og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "Cassette Artifacts",
      presetId: "hifi-chrome",
      label: "Hi-Fi Chrome",
      group: "",
      json: #"""
      {"dg":"Hi-Fi","tp":"Type II","nr":"Dolby B","bs":0,"rl":8,"wf":0.1,"hs":-64,"dp":0.5,"az":1,"dl":0,"og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "Cassette Artifacts",
      presetId: "pocket-cassette-player",
      label: "Pocket Cassette Player",
      group: "",
      json: #"""
      {"dg":"Portable","tp":"Type I","nr":"Off","bs":0,"rl":12,"wf":0.4,"hs":-54,"dp":4,"az":4,"dl":0,"og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "Cassette Artifacts",
      presetId: "worn-mixtape",
      label: "Worn Mixtape",
      group: "",
      json: #"""
      {"dg":"Consumer","tp":"Type I","nr":"Off","bs":-3,"rl":15,"wf":0.65,"hs":-50,"dp":12,"az":-5,"dl":0,"og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "Cassette Artifacts",
      presetId: "hot-deck-saturation",
      label: "Hot Deck Saturation",
      group: "",
      json: #"""
      {"dg":"Consumer","tp":"Type II","nr":"Off","bs":1,"rl":18,"wf":0.2,"hs":-58,"dp":1,"az":1,"dl":0,"og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "FM Radio Simulator",
      presetId: "powerhouse-broadcast",
      label: "Powerhouse Broadcast",
      group: "",
      json: #"""
      {"rd":true,"em":"50","pr":9,"st":60,"tn":0,"bw":230,"mp":0,"dl":5,"fd":0,"sm":"Auto","og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "FM Radio Simulator",
      presetId: "distant-station",
      label: "Distant Station",
      group: "",
      json: #"""
      {"rd":true,"em":"50","pr":0,"st":18,"tn":0,"bw":230,"mp":10,"dl":5,"fd":1,"sm":"Auto","og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "FM Radio Simulator",
      presetId: "city-multipath",
      label: "City Drive Multipath",
      group: "",
      json: #"""
      {"rd":true,"em":"75","pr":0,"st":45,"tn":0,"bw":230,"mp":60,"dl":12,"fd":8,"sm":"Auto","og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "SW Radio Simulator",
      presetId: "major-broadcaster",
      label: "Major Broadcaster",
      group: "",
      json: #"""
      {"rd":true,"tb":4.5,"pe":50,"md":90,"cp":6,"sg":-8,"sk":25,"fd":0.3,"ds":1.4,"st":0.5,"in":-70,"io":1,"mo":"AM","tn":0,"bf":0,"bw":8,"de":"Envelope","ag":"Fast","dt":50,"hm":-80,"hz":"50","sp":"Table","og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "SW Radio Simulator",
      presetId: "transoceanic-night",
      label: "Transoceanic Night",
      group: "",
      json: #"""
      {"rd":true,"tb":4.5,"pe":50,"md":90,"cp":6,"sg":-25,"sk":95,"fd":1.5,"ds":3,"st":10,"in":-45,"io":1,"mo":"AM","tn":0,"bf":0,"bw":4,"de":"Synchronous","ag":"Fast","dt":50,"hm":-80,"hz":"50","sp":"Small","og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "SW Radio Simulator",
      presetId: "stormy-49m-band",
      label: "Stormy 49 m Band",
      group: "",
      json: #"""
      {"rd":true,"tb":4.5,"pe":50,"md":90,"cp":6,"sg":-20,"sk":80,"fd":3,"ds":5,"st":40,"in":-40,"io":0.5,"mo":"AM","tn":0,"bf":0,"bw":5,"de":"Envelope","ag":"Fast","dt":50,"hm":-80,"hz":"50","sp":"Small","og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "Tape Artifacts",
      presetId: "pristine-30-ips-reel",
      label: "Pristine 30 ips Reel",
      group: "",
      json: #"""
      {"sp":"30","tp":"Master","bs":0,"rl":3,"wf":0.06,"hs":-72,"og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "Tape Artifacts",
      presetId: "hobbyist-reel-to-reel",
      label: "Hobbyist Reel-to-Reel",
      group: "",
      json: #"""
      {"sp":"7.5","tp":"Standard","bs":0,"rl":9,"wf":0.3,"hs":-54,"og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "Tape Artifacts",
      presetId: "tired-old-reel",
      label: "Tired Old Reel",
      group: "",
      json: #"""
      {"sp":"7.5","tp":"Standard","bs":-4,"rl":9,"wf":0.7,"hs":-46,"og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "Vinyl Artifacts",
      presetId: "gentle-patina",
      label: "Gentle Patina",
      group: "",
      json: #"""
      {"pp":5,"pl":-36,"cm":150,"cl":-45,"hs":-54,"rb":-60,"xt":40,"tn":5,"wr":50,"rt":25,"rm":"Velocity","mx":100}
      """#),
    ETEffectPreset(
      effect: "Vinyl Artifacts",
      presetId: "thrift-store-copy",
      label: "Thrift Store Copy",
      group: "",
      json: #"""
      {"pp":90,"pl":-18,"cm":1600,"cl":-24,"hs":-36,"rb":-42,"xt":80,"tn":10,"wr":200,"rt":40,"rm":"Velocity","mx":100}
      """#),
    ETEffectPreset(
      effect: "Vinyl Artifacts",
      presetId: "rumbly-old-player",
      label: "Rumbly Old Player",
      group: "",
      json: #"""
      {"pp":20,"pl":-24,"cm":500,"cl":-33,"hs":-42,"rb":-40,"xt":60,"tn":10,"wr":100,"rt":25,"rm":"Velocity","mx":100}
      """#),
    ETEffectPreset(
      effect: "Vinyl Simulator",
      presetId: "audiophile-pressing",
      label: "Audiophile Pressing",
      group: "",
      json: #"""
      {"lv":0,"hf":16000,"mb":250,"sm":70,"rp":"33⅓","rd":120,"rg":1,"dr":0.2,"st":0,"sc":0,"sh":"Elliptical","rs":18,"rc":8,"tf":2,"tm":0.4,"cm":15,"dz":0.25,"ql":"Standard","og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "Vinyl Simulator",
      presetId: "well-worn-favorite",
      label: "Well-Worn Favorite",
      group: "",
      json: #"""
      {"lv":0,"hf":16000,"mb":250,"sm":70,"rp":"33⅓","rd":120,"rg":40,"dr":100,"st":10,"sc":0.5,"sh":"Elliptical","rs":18,"rc":8,"tf":2,"tm":0.4,"cm":15,"dz":0.25,"ql":"Standard","og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "Vinyl Simulator",
      presetId: "flea-market-45",
      label: "Flea Market 45",
      group: "",
      json: #"""
      {"lv":0,"hf":16000,"mb":250,"sm":70,"rp":"45","rd":75,"rg":60,"dr":500,"st":50,"sc":2,"sh":"Spherical","rs":18,"rc":18,"tf":2,"tm":0.4,"cm":15,"dz":0.25,"ql":"Standard","og":-3,"mx":100}
      """#),
    ETEffectPreset(
      effect: "Vinyl Simulator",
      presetId: "shellac-78",
      label: "78 rpm Shellac",
      group: "",
      json: #"""
      {"lv":0,"hf":8000,"mb":250,"sm":70,"rp":"78","rd":120,"rg":100,"dr":1000,"st":100,"sc":3,"sh":"Spherical","rs":25,"rc":25,"tf":4,"tm":0.4,"cm":15,"dz":0.25,"ql":"Standard","og":-3,"mx":100}
      """#),
    ETEffectPreset(
      effect: "Vinyl Simulator",
      presetId: "end-of-side",
      label: "End of Side",
      group: "",
      json: #"""
      {"lv":0,"hf":16000,"mb":250,"sm":70,"rp":"33⅓","rd":63,"rg":13.17,"dr":2,"st":0.08,"sc":0,"sh":"Elliptical","rs":18,"rc":8,"tf":2,"tm":0.4,"cm":15,"dz":0.25,"ql":"Standard","og":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "Auto Filter",
      presetId: "auto-filter-sweep",
      label: "Auto Filter Sweep",
      group: "",
      json: #"""
      {"md":"LFO","ft":"Low-pass","lf":200,"hf":4000,"rs":1.5,"mx":80,"rt":0.5,"wf":"Sine","sp":0,"sn":24,"at":20,"rl":250,"dr":"Up"}
      """#),
    ETEffectPreset(
      effect: "Auto Filter",
      presetId: "stereo-filter-sweep",
      label: "Stereo Filter Sweep",
      group: "",
      json: #"""
      {"md":"LFO","ft":"Low-pass","lf":160,"hf":6000,"rs":2,"mx":85,"rt":0.35,"wf":"Sine","sp":120,"sn":24,"at":20,"rl":250,"dr":"Up"}
      """#),
    ETEffectPreset(
      effect: "Auto Filter",
      presetId: "envelope-filter",
      label: "Envelope Filter",
      group: "",
      json: #"""
      {"md":"Envelope","ft":"Low-pass","lf":100,"hf":5000,"rs":1.2,"mx":85,"rt":0.5,"wf":"Sine","sp":0,"sn":24,"at":18,"rl":300,"dr":"Up"}
      """#),
    ETEffectPreset(
      effect: "Auto Filter",
      presetId: "auto-wah",
      label: "Auto Wah",
      group: "",
      json: #"""
      {"md":"Envelope","ft":"Band-pass","lf":180,"hf":2400,"rs":5,"mx":100,"rt":0.5,"wf":"Sine","sp":0,"sn":30,"at":8,"rl":180,"dr":"Up"}
      """#),
    ETEffectPreset(
      effect: "Auto Filter",
      presetId: "reverse-auto-wah",
      label: "Reverse Auto Wah",
      group: "",
      json: #"""
      {"md":"Envelope","ft":"Band-pass","lf":180,"hf":2800,"rs":4,"mx":100,"rt":0.5,"wf":"Sine","sp":0,"sn":30,"at":12,"rl":350,"dr":"Down"}
      """#),
    ETEffectPreset(
      effect: "Auto Pan",
      presetId: "gentle-auto-pan",
      label: "Gentle Auto Pan",
      group: "",
      json: #"""
      {"rt":0.35,"dp":45,"ct":0,"wd":70,"wf":"Sine","ph":0}
      """#),
    ETEffectPreset(
      effect: "Auto Pan",
      presetId: "wide-auto-pan",
      label: "Wide Auto Pan",
      group: "",
      json: #"""
      {"rt":0.7,"dp":100,"ct":0,"wd":100,"wf":"Sine","ph":0}
      """#),
    ETEffectPreset(
      effect: "Auto Pan",
      presetId: "fast-auto-pan",
      label: "Fast Auto Pan",
      group: "",
      json: #"""
      {"rt":4,"dp":85,"ct":0,"wd":100,"wf":"Triangle","ph":0}
      """#),
    ETEffectPreset(
      effect: "Chorus",
      presetId: "classic-chorus",
      label: "Classic Chorus",
      group: "",
      json: #"""
      {"md":"Chorus","rt":0.8,"dl":12,"dp":3,"vc":3,"ss":60,"fb":0,"mx":45}
      """#),
    ETEffectPreset(
      effect: "Chorus",
      presetId: "stereo-chorus",
      label: "Stereo Chorus",
      group: "",
      json: #"""
      {"md":"Stereo Chorus","rt":0.65,"dl":15,"dp":4,"vc":2,"ss":80,"fb":0,"mx":50}
      """#),
    ETEffectPreset(
      effect: "Chorus",
      presetId: "ensemble",
      label: "Ensemble",
      group: "",
      json: #"""
      {"md":"Ensemble","rt":0.45,"dl":20,"dp":6,"vc":6,"ss":100,"fb":0,"mx":60}
      """#),
    ETEffectPreset(
      effect: "Chorus",
      presetId: "flanger",
      label: "Flanger",
      group: "",
      json: #"""
      {"md":"Flanger","rt":0.35,"dl":2.5,"dp":2,"vc":1,"ss":35,"fb":45,"mx":50}
      """#),
    ETEffectPreset(
      effect: "Chorus",
      presetId: "jet-flanger",
      label: "Jet Flanger",
      group: "",
      json: #"""
      {"md":"Flanger","rt":0.18,"dl":1.5,"dp":1.4,"vc":1,"ss":70,"fb":-75,"mx":55}
      """#),
    ETEffectPreset(
      effect: "Chorus",
      presetId: "vibrato",
      label: "Vibrato",
      group: "",
      json: #"""
      {"md":"Vibrato","rt":4.5,"dl":8,"dp":5,"vc":1,"ss":50,"fb":0,"mx":100}
      """#),
    ETEffectPreset(
      effect: "Frequency Shifter",
      presetId: "shift-up",
      label: "Shift Up",
      group: "",
      json: #"""
      {"md":"Shift","sh":8,"cf":440,"mn":20,"mx":800,"rt":0.15,"dr":"Up","sp":0,"mix":100}
      """#),
    ETEffectPreset(
      effect: "Frequency Shifter",
      presetId: "shift-down",
      label: "Shift Down",
      group: "",
      json: #"""
      {"md":"Shift","sh":-8,"cf":440,"mn":20,"mx":800,"rt":0.15,"dr":"Down","sp":0,"mix":100}
      """#),
    ETEffectPreset(
      effect: "Frequency Shifter",
      presetId: "fine-detune",
      label: "Fine Detune",
      group: "",
      json: #"""
      {"md":"Shift","sh":2,"cf":440,"mn":20,"mx":800,"rt":0.15,"dr":"Up","sp":90,"mix":55}
      """#),
    ETEffectPreset(
      effect: "Frequency Shifter",
      presetId: "ring-modulator",
      label: "Ring Modulator",
      group: "",
      json: #"""
      {"md":"Ring Mod","sh":8,"cf":440,"mn":20,"mx":800,"rt":0.15,"dr":"Up","sp":0,"mix":100}
      """#),
    ETEffectPreset(
      effect: "Frequency Shifter",
      presetId: "barber-pole-up",
      label: "Barber-pole Up",
      group: "",
      json: #"""
      {"md":"Barber-pole","sh":8,"cf":440,"mn":20,"mx":900,"rt":0.12,"dr":"Up","sp":90,"mix":85}
      """#),
    ETEffectPreset(
      effect: "Frequency Shifter",
      presetId: "barber-pole-down",
      label: "Barber-pole Down",
      group: "",
      json: #"""
      {"md":"Barber-pole","sh":-8,"cf":440,"mn":20,"mx":900,"rt":0.12,"dr":"Down","sp":90,"mix":85}
      """#),
    ETEffectPreset(
      effect: "Phaser",
      presetId: "classic-phaser",
      label: "Classic Phaser",
      group: "",
      json: #"""
      {"md":"Classic","rt":0.5,"cf":1000,"rg":3,"st":6,"fb":20,"sp":90,"dr":"Up","mx":50}
      """#),
    ETEffectPreset(
      effect: "Phaser",
      presetId: "deep-phaser",
      label: "Deep Phaser",
      group: "",
      json: #"""
      {"md":"Classic","rt":0.25,"cf":700,"rg":4.5,"st":12,"fb":55,"sp":30,"dr":"Up","mx":55}
      """#),
    ETEffectPreset(
      effect: "Phaser",
      presetId: "stereo-phaser",
      label: "Stereo Phaser",
      group: "",
      json: #"""
      {"md":"Classic","rt":0.65,"cf":1200,"rg":3.5,"st":8,"fb":25,"sp":120,"dr":"Up","mx":50}
      """#),
    ETEffectPreset(
      effect: "Phaser",
      presetId: "barber-pole-up",
      label: "Barber-pole Up",
      group: "",
      json: #"""
      {"md":"Barber-pole","rt":0.35,"cf":1000,"rg":5,"st":8,"fb":30,"sp":60,"dr":"Up","mx":55}
      """#),
    ETEffectPreset(
      effect: "Phaser",
      presetId: "barber-pole-down",
      label: "Barber-pole Down",
      group: "",
      json: #"""
      {"md":"Barber-pole","rt":0.35,"cf":1000,"rg":5,"st":8,"fb":30,"sp":60,"dr":"Down","mx":55}
      """#),
    ETEffectPreset(
      effect: "Rotary Speaker",
      presetId: "rotary-slow",
      label: "Rotary Slow",
      group: "",
      json: #"""
      {"ss":"Slow","sp":100,"ac":2.2,"xo":800,"rb":0,"sw":75,"dd":45,"ad":55,"mx":70}
      """#),
    ETEffectPreset(
      effect: "Rotary Speaker",
      presetId: "rotary-fast",
      label: "Rotary Fast",
      group: "",
      json: #"""
      {"ss":"Fast","sp":100,"ac":1.4,"xo":800,"rb":0,"sw":85,"dd":65,"ad":70,"mx":78}
      """#),
    ETEffectPreset(
      effect: "Rotary Speaker",
      presetId: "gentle-rotary",
      label: "Gentle Rotary",
      group: "",
      json: #"""
      {"ss":"Slow","sp":75,"ac":3,"xo":900,"rb":0,"sw":45,"dd":25,"ad":30,"mx":55}
      """#),
    ETEffectPreset(
      effect: "Rotary Speaker",
      presetId: "vintage-rotor-slow",
      label: "Vintage Rotor Slow",
      group: "",
      json: #"""
      {"ss":"Slow","sp":100,"ac":2.8,"xo":800,"rb":-5,"sw":80,"dd":50,"ad":60,"mx":75}
      """#),
    ETEffectPreset(
      effect: "Rotary Speaker",
      presetId: "vintage-rotor-fast",
      label: "Vintage Rotor Fast",
      group: "",
      json: #"""
      {"ss":"Fast","sp":100,"ac":1.8,"xo":800,"rb":-5,"sw":90,"dd":70,"ad":75,"mx":82}
      """#),
    ETEffectPreset(
      effect: "Wow Flutter",
      presetId: "warped-record",
      label: "Warped Record",
      group: "",
      json: #"""
      {"rt":0.6,"dp":18,"rn":4,"rc":2,"rs":-6,"cp":0,"cs":100}
      """#),
    ETEffectPreset(
      effect: "Wow Flutter",
      presetId: "worn-cassette-motor",
      label: "Worn Cassette Motor",
      group: "",
      json: #"""
      {"rt":3,"dp":3,"rn":14,"rc":8,"rs":-6,"cp":0,"cs":100}
      """#),
    ETEffectPreset(
      effect: "Wow Flutter",
      presetId: "seasick-tape",
      label: "Seasick Tape",
      group: "",
      json: #"""
      {"rt":0.3,"dp":30,"rn":25,"rc":3,"rs":-4,"cp":30,"cs":80}
      """#),
    ETEffectPreset(
      effect: "Horn Resonator",
      presetId: "gramophone",
      label: "Gramophone",
      group: "",
      json: #"""
      {"co":450,"ln":90,"th":1.5,"mo":35,"cv":85,"dp":0.5,"tr":0.9,"wg":28}
      """#),
    ETEffectPreset(
      effect: "Horn Resonator",
      presetId: "vintage-theater",
      label: "Vintage Theater",
      group: "",
      json: #"""
      {"co":350,"ln":120,"th":5,"mo":150,"cv":30,"dp":0.05,"tr":0.99,"wg":30}
      """#),
    ETEffectPreset(
      effect: "Horn Resonator",
      presetId: "megaphone",
      label: "Megaphone",
      group: "",
      json: #"""
      {"co":700,"ln":40,"th":2,"mo":20,"cv":0,"dp":0.2,"tr":0.95,"wg":22}
      """#),
    ETEffectPreset(
      effect: "Horn Resonator Plus",
      presetId: "gramophone",
      label: "Gramophone",
      group: "",
      json: #"""
      {"co":450,"ln":90,"th":1.5,"mo":35,"cv":85,"dp":0.5,"tr":0.9,"wg":28}
      """#),
    ETEffectPreset(
      effect: "Horn Resonator Plus",
      presetId: "vintage-theater",
      label: "Vintage Theater",
      group: "",
      json: #"""
      {"co":350,"ln":120,"th":5,"mo":150,"cv":30,"dp":0.05,"tr":0.99,"wg":30}
      """#),
    ETEffectPreset(
      effect: "Horn Resonator Plus",
      presetId: "megaphone",
      label: "Megaphone",
      group: "",
      json: #"""
      {"co":700,"ln":40,"th":2,"mo":20,"cv":0,"dp":0.2,"tr":0.95,"wg":22}
      """#),
    ETEffectPreset(
      effect: "Modal Resonator",
      presetId: "wooden-body",
      label: "Wooden Body",
      group: "",
      json: #"""
      {"mx":25,"sr":0,"rs":[{"en":true,"fr":5.19,"dc":30,"lp":5.53,"hp":4.14,"gn":0},{"en":true,"fr":6.04,"dc":25,"lp":6.38,"hp":4.99,"gn":-4},{"en":true,"fr":6.75,"dc":18,"lp":7.09,"hp":5.7,"gn":-8},{"en":true,"fr":7.17,"dc":12,"lp":7.51,"hp":6.12,"gn":-12},{"en":true,"fr":7.86,"dc":8,"lp":8.2,"hp":6.81,"gn":-16}]}
      """#),
    ETEffectPreset(
      effect: "Modal Resonator",
      presetId: "metal-can",
      label: "Metal Can",
      group: "",
      json: #"""
      {"mx":20,"sr":0,"rs":[{"en":true,"fr":7,"dc":40,"lp":7.34,"hp":5.95,"gn":0},{"en":true,"fr":7.74,"dc":35,"lp":8.08,"hp":6.69,"gn":-2},{"en":true,"fr":8.22,"dc":30,"lp":8.56,"hp":7.17,"gn":-4},{"en":true,"fr":8.56,"dc":25,"lp":8.9,"hp":7.51,"gn":-6},{"en":true,"fr":8.96,"dc":20,"lp":9.3,"hp":7.91,"gn":-8}]}
      """#),
    ETEffectPreset(
      effect: "Modal Resonator",
      presetId: "plastic-enclosure",
      label: "Plastic Enclosure",
      group: "",
      json: #"""
      {"mx":30,"sr":0,"rs":[{"en":true,"fr":5.77,"dc":10,"lp":6.11,"hp":4.72,"gn":0},{"en":true,"fr":6.8,"dc":8,"lp":7.14,"hp":5.75,"gn":-3},{"en":true,"fr":7.55,"dc":6,"lp":7.89,"hp":6.5,"gn":-6},{"en":true,"fr":8.13,"dc":5,"lp":8.47,"hp":7.08,"gn":-9},{"en":true,"fr":8.63,"dc":4,"lp":8.97,"hp":7.58,"gn":-12}]}
      """#),
    ETEffectPreset(
      effect: "Dattorro Plate Reverb",
      presetId: "studio-plate",
      label: "Studio Plate",
      group: "",
      json: #"""
      {"pd":5,"bw":0.9995,"id1":0.75,"id2":0.625,"dc":0.45,"dd1":0.7,"dp":0.001,"md":1,"mr":1,"wm":28,"dm":100}
      """#),
    ETEffectPreset(
      effect: "Dattorro Plate Reverb",
      presetId: "vocal-plate",
      label: "Vocal Plate",
      group: "",
      json: #"""
      {"pd":25,"bw":0.9995,"id1":0.75,"id2":0.625,"dc":0.6,"dd1":0.7,"dp":0.0005,"md":2,"mr":0.8,"wm":32,"dm":100}
      """#),
    ETEffectPreset(
      effect: "Dattorro Plate Reverb",
      presetId: "dark-vintage-plate",
      label: "Dark Vintage Plate",
      group: "",
      json: #"""
      {"pd":10,"bw":0.65,"id1":0.75,"id2":0.625,"dc":0.62,"dd1":0.7,"dp":0.01,"md":1.5,"mr":0.6,"wm":30,"dm":100}
      """#),
    ETEffectPreset(
      effect: "Dattorro Plate Reverb",
      presetId: "long-wash",
      label: "Long Wash",
      group: "",
      json: #"""
      {"pd":10,"bw":0.9995,"id1":0.75,"id2":0.625,"dc":0.85,"dd1":0.7,"dp":0.002,"md":3,"mr":1.2,"wm":40,"dm":100}
      """#),
    ETEffectPreset(
      effect: "FDN Reverb",
      presetId: "tight-room",
      label: "Tight Room",
      group: "",
      json: #"""
      {"rt":0.45,"dt":8,"pd":5,"bd":14,"ds":4,"hd":7,"lc":120,"md":2,"mr":0.5,"df":100,"wm":22,"dm":100,"sw":100}
      """#),
    ETEffectPreset(
      effect: "FDN Reverb",
      presetId: "warm-hall",
      label: "Warm Hall",
      group: "",
      json: #"""
      {"rt":2.6,"dt":8,"pd":35,"bd":42,"ds":16,"hd":5,"lc":80,"md":3,"mr":0.3,"df":100,"wm":32,"dm":100,"sw":120}
      """#),
    ETEffectPreset(
      effect: "FDN Reverb",
      presetId: "bright-plate",
      label: "Bright Plate",
      group: "",
      json: #"""
      {"rt":1.6,"dt":8,"pd":10,"bd":12,"ds":2,"hd":1,"lc":250,"md":6,"mr":1.2,"df":100,"wm":32,"dm":100,"sw":140}
      """#),
    ETEffectPreset(
      effect: "FDN Reverb",
      presetId: "vast-cavern",
      label: "Vast Cavern",
      group: "",
      json: #"""
      {"rt":10,"dt":8,"pd":60,"bd":58,"ds":24,"hd":3,"lc":60,"md":5,"mr":0.2,"df":100,"wm":45,"dm":100,"sw":160}
      """#),
    ETEffectPreset(
      effect: "RS Reverb",
      presetId: "small-room",
      label: "Small Room",
      group: "",
      json: #"""
      {"pd":5,"rs":3.5,"rt":0.5,"ds":8,"df":0.6,"dp":70,"hd":4000,"ld":250,"mx":14}
      """#),
    ETEffectPreset(
      effect: "RS Reverb",
      presetId: "jazz-club",
      label: "Jazz Club",
      group: "",
      json: #"""
      {"pd":15,"rs":9,"rt":1.2,"ds":8,"df":0.7,"dp":75,"hd":3500,"ld":200,"mx":25}
      """#),
    ETEffectPreset(
      effect: "RS Reverb",
      presetId: "concert-hall",
      label: "Concert Hall",
      group: "",
      json: #"""
      {"pd":25,"rs":35,"rt":2.2,"ds":8,"df":0.75,"dp":70,"hd":3000,"ld":150,"mx":35}
      """#),
    ETEffectPreset(
      effect: "RS Reverb",
      presetId: "cathedral",
      label: "Cathedral",
      group: "",
      json: #"""
      {"pd":40,"rs":40,"rt":6,"ds":8,"df":0.8,"dp":60,"hd":1800,"ld":100,"mx":45}
      """#),
    ETEffectPreset(
      effect: "Dynamic Saturation",
      presetId: "subtle-cone-color",
      label: "Subtle Cone Color",
      group: "",
      json: #"""
      {"sd":2,"ss":1.5,"sp":0.8,"sm":1,"dd":1.2,"db":0.1,"dm":60,"cm":10,"og":0}
      """#),
    ETEffectPreset(
      effect: "Dynamic Saturation",
      presetId: "pushed-speaker",
      label: "Pushed Speaker",
      group: "",
      json: #"""
      {"sd":5,"ss":3,"sp":1.5,"sm":1.5,"dd":2,"db":0.16,"dm":100,"cm":25,"og":-0.6}
      """#),
    ETEffectPreset(
      effect: "Dynamic Saturation",
      presetId: "ragged-cone",
      label: "Ragged Cone",
      group: "",
      json: #"""
      {"sd":8,"ss":5,"sp":2.5,"sm":2,"dd":3,"db":0.3,"dm":100,"cm":35,"og":-1.7}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-line-12at7-thd0p01",
      label: "Line 12AT7 @0.01%",
      group: "Pre",
      json: #"""
      {"dr":-13.748,"tp":"12AT7","bi":0,"pv":250,"sz":10,"su":10,"og":0.619,"mx":100,"iv":2.828,"nf":30,"os":"Line","pt":"EL84","pb":320,"kr":270,"st":"0","zp":"8.0","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-line-12at7-thd0p1",
      label: "Line 12AT7 @0.1%",
      group: "Pre",
      json: #"""
      {"dr":0,"tp":"12AT7","bi":0,"pv":250,"sz":10,"su":10,"og":-17.268,"mx":100,"iv":4.5552,"nf":30,"os":"Line","pt":"EL84","pb":320,"kr":270,"st":"0","zp":"8.0","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-line-12ax7-thd0p01",
      label: "Line 12AX7 @0.01%",
      group: "Pre",
      json: #"""
      {"dr":-24.2637,"tp":"12AX7","bi":0,"pv":250,"sz":10,"su":10,"og":8.508,"mx":100,"iv":2.828,"nf":30,"os":"Line","pt":"EL84","pb":320,"kr":270,"st":"0","zp":"8.0","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-line-12ax7-thd0p1",
      label: "Line 12AX7 @0.1%",
      group: "Pre",
      json: #"""
      {"dr":-4.4922,"tp":"12AX7","bi":0,"pv":250,"sz":10,"su":10,"og":-11.264,"mx":100,"iv":2.828,"nf":30,"os":"Line","pt":"EL84","pb":320,"kr":270,"st":"0","zp":"8.0","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-line-12au7-open-loop-thd0p1",
      label: "Line 12AU7 Open-Loop @0.1%",
      group: "Pre",
      json: #"""
      {"dr":-19.2715,"tp":"12AU7","bi":0,"pv":250,"sz":10,"su":10,"og":28.495,"mx":100,"iv":2.828,"nf":0,"os":"Line","pt":"EL84","pb":320,"kr":270,"st":"0","zp":"8.0","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-line-12at7-thd1",
      label: "Line 12AT7 @1%",
      group: "Pre",
      json: #"""
      {"dr":0,"tp":"12AT7","bi":0,"pv":250,"sz":10,"su":10,"og":-21.421,"mx":100,"iv":7.3556,"nf":30,"os":"Line","pt":"EL84","pb":320,"kr":270,"st":"0","zp":"8.0","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-line-12ax7-thd1",
      label: "Line 12AX7 @1%",
      group: "Pre",
      json: #"""
      {"dr":0,"tp":"12AX7","bi":0,"pv":250,"sz":10,"su":10,"og":-23.276,"mx":100,"iv":6.7213,"nf":30,"os":"Line","pt":"EL84","pb":320,"kr":270,"st":"0","zp":"8.0","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-line-12au7-open-loop-thd1",
      label: "Line 12AU7 Open-Loop @1%",
      group: "Pre",
      json: #"""
      {"dr":-9.2656,"tp":"12AU7","bi":0,"pv":250,"sz":10,"su":10,"og":18.592,"mx":100,"iv":2.828,"nf":0,"os":"Line","pt":"EL84","pb":320,"kr":270,"st":"0","zp":"8.0","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "power-only-el84-pentode-10w-thd0p1",
      label: "EL84 Pentode 10 W @0.1%",
      group: "Power",
      json: #"""
      {"dr":-26.5898,"tp":"Bypass","bi":0,"pv":250,"sz":10,"su":10,"og":8.692,"mx":100,"iv":2.828,"nf":3,"os":"Power","pt":"EL84","pb":329.696,"kr":270,"st":"0","zp":"8.0","sl":"15","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "power-only-el84-distributed-10w-thd0p1",
      label: "EL84 Distributed 10 W @0.1%",
      group: "Power",
      json: #"""
      {"dr":-21.7715,"tp":"Bypass","bi":0,"pv":250,"sz":10,"su":10,"og":7.368,"mx":100,"iv":2.828,"nf":3,"os":"Power","pt":"EL84","pb":330.107,"kr":270,"st":"20","zp":"6.6","sl":"15","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "power-only-el34-distributed-20-37w-thd0p1",
      label: "EL34 Distributed 20–37 W @0.1%",
      group: "Power",
      json: #"""
      {"dr":-8.248,"tp":"Bypass","bi":0,"pv":250,"sz":10,"su":10,"og":3.862,"mx":100,"iv":2.828,"nf":4,"os":"Power","pt":"EL34","pb":443.775,"kr":470,"st":"43","zp":"6.6","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "power-only-6l6gc-pentode-thd0p1",
      label: "6L6GC Pentode @0.1%",
      group: "Power",
      json: #"""
      {"dr":-19.3086,"tp":"Bypass","bi":0,"pv":250,"sz":10,"su":10,"og":12.257,"mx":100,"iv":2.828,"nf":3,"os":"Power","pt":"6L6GC","pb":391.454,"kr":483.871,"st":"0","zp":"6.6","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "power-only-kt88-distributed-thd0p1",
      label: "KT88 Distributed @0.1%",
      group: "Power",
      json: #"""
      {"dr":0,"tp":"Bypass","bi":0,"pv":250,"sz":10,"su":10,"og":-3.474,"mx":100,"iv":3.1228,"nf":2,"os":"Power","pt":"KT88","pb":379.29,"kr":400,"st":"43","zp":"6.0","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "power-only-se-300b-thd0p1",
      label: "300B SE @0.1%",
      group: "Power",
      json: #"""
      {"dr":0,"tp":"Bypass","bi":0,"pv":250,"sz":10,"su":10,"og":16.672,"mx":100,"iv":35.0937,"nf":3,"os":"SingleEnded","pt":"EL84","pb":329.696,"kr":270,"st":"0","zp":"8.0","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "power-only-se-300b-thd1",
      label: "300B SE @1%",
      group: "Power",
      json: #"""
      {"dr":0,"tp":"Bypass","bi":0,"pv":250,"sz":10,"su":10,"og":-1.74,"mx":100,"iv":294.0743,"nf":3,"os":"SingleEnded","pt":"EL84","pb":329.696,"kr":270,"st":"0","zp":"8.0","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "power-only-se-2a3-thd0p1",
      label: "2A3 SE @0.1%",
      group: "Power",
      json: #"""
      {"dr":0,"tp":"Bypass","bi":0,"pv":250,"sz":10,"su":10,"og":21.17,"mx":100,"iv":17.932,"nf":3,"os":"SingleEnded","pt":"EL84","pb":329.696,"kr":270,"st":"0","zp":"8.0","sl":"8","sd":"2A3","sb":300,"sr":750,"sp":"2.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "power-only-se-2a3-thd1",
      label: "2A3 SE @1%",
      group: "Power",
      json: #"""
      {"dr":0,"tp":"Bypass","bi":0,"pv":250,"sz":10,"su":10,"og":1.892,"mx":100,"iv":165.7852,"nf":3,"os":"SingleEnded","pt":"EL84","pb":329.696,"kr":270,"st":"0","zp":"8.0","sl":"8","sd":"2A3","sb":300,"sr":750,"sp":"2.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "power-only-el84-pentode-10w",
      label: "EL84 Pentode 10 W @2%",
      group: "Power",
      json: #"""
      {"dr":-9.7187,"tp":"Bypass","bi":0,"pv":250,"sz":10,"su":10,"og":-7.474,"mx":100,"iv":2.828,"nf":3,"os":"Power","pt":"EL84","pb":329.696,"kr":270,"st":"0","zp":"8.0","sl":"15","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "power-only-el84-distributed-10w",
      label: "EL84 Distributed 10 W @2%",
      group: "Power",
      json: #"""
      {"dr":-6.541,"tp":"Bypass","bi":0,"pv":250,"sz":10,"su":10,"og":-7.311,"mx":100,"iv":2.828,"nf":3,"os":"Power","pt":"EL84","pb":330.107,"kr":270,"st":"20","zp":"6.6","sl":"15","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "power-only-el34-distributed-20-37w",
      label: "EL34 Distributed 20–37 W @2%",
      group: "Power",
      json: #"""
      {"dr":0,"tp":"Bypass","bi":0,"pv":250,"sz":10,"su":10,"og":-9.499,"mx":100,"iv":5.2733,"nf":4,"os":"Power","pt":"EL34","pb":443.775,"kr":470,"st":"43","zp":"6.6","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "power-only-6l6gc-pentode",
      label: "6L6GC Pentode @2%",
      group: "Power",
      json: #"""
      {"dr":0,"tp":"Bypass","bi":0,"pv":250,"sz":10,"su":10,"og":-7.171,"mx":100,"iv":3.3755,"nf":3,"os":"Power","pt":"6L6GC","pb":391.454,"kr":483.871,"st":"0","zp":"6.6","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "power-only-kt88-distributed",
      label: "KT88 Distributed @2%",
      group: "Power",
      json: #"""
      {"dr":0,"tp":"Bypass","bi":0,"pv":250,"sz":10,"su":10,"og":-10.747,"mx":100,"iv":7.5026,"nf":2,"os":"Power","pt":"KT88","pb":379.29,"kr":400,"st":"43","zp":"6.0","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-power-el84-distributed-thd0p1",
      label: "EL84 Distributed @0.1%",
      group: "Pre+Power",
      json: #"""
      {"dr":-58.4941,"tp":"12AX7","bi":0,"pv":250,"sz":10,"su":10,"og":9.942,"mx":100,"iv":2.828,"nf":3,"os":"Power","pt":"EL84","pb":330.107,"kr":270,"st":"20","zp":"6.6","sl":"15","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-power-el34-distributed-thd0p1",
      label: "EL34 Distributed @0.1%",
      group: "Pre+Power",
      json: #"""
      {"dr":-56.4687,"tp":"12AX7","bi":0,"pv":250,"sz":10,"su":10,"og":17.953,"mx":100,"iv":2.828,"nf":4,"os":"Power","pt":"EL34","pb":443.775,"kr":470,"st":"43","zp":"6.6","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-power-6l6gc-pentode-thd0p1",
      label: "6L6GC Pentode @0.1%",
      group: "Pre+Power",
      json: #"""
      {"dr":-58.5078,"tp":"12AX7","bi":0,"pv":250,"sz":10,"su":10,"og":17.309,"mx":100,"iv":2.828,"nf":3,"os":"Power","pt":"6L6GC","pb":391.454,"kr":483.871,"st":"0","zp":"6.6","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-power-kt88-distributed-thd0p1",
      label: "KT88 Distributed @0.1%",
      group: "Pre+Power",
      json: #"""
      {"dr":-56.4668,"tp":"12AX7","bi":0,"pv":250,"sz":10,"su":10,"og":21.702,"mx":100,"iv":2.828,"nf":4,"os":"Power","pt":"KT88","pb":379.29,"kr":400,"st":"43","zp":"6.0","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-se-300b-thd0p1",
      label: "300B SE @0.1%",
      group: "Pre+Power",
      json: #"""
      {"dr":-15.3125,"tp":"12AU7","bi":0,"pv":250,"sz":10,"su":10,"og":12.116,"mx":100,"iv":2.828,"nf":3,"os":"SingleEnded","pt":"EL84","pb":329.696,"kr":270,"st":"0","zp":"8.0","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-se-2a3-thd0p1",
      label: "2A3 SE @0.1%",
      group: "Pre+Power",
      json: #"""
      {"dr":-23.375,"tp":"12AU7","bi":0,"pv":250,"sz":10,"su":10,"og":18.838,"mx":100,"iv":2.828,"nf":3,"os":"SingleEnded","pt":"EL84","pb":329.696,"kr":270,"st":"0","zp":"8.0","sl":"8","sd":"2A3","sb":300,"sr":750,"sp":"2.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-power-el84-pentode-thd2",
      label: "EL84 Pentode @2%",
      group: "Pre+Power",
      json: #"""
      {"dr":-44.0059,"tp":"12AX7","bi":0,"pv":250,"sz":10,"su":10,"og":-7.372,"mx":100,"iv":2.828,"nf":3,"os":"Power","pt":"EL84","pb":329.696,"kr":270,"st":"0","zp":"8.0","sl":"15","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-power-el84-distributed-thd2",
      label: "EL84 Distributed @2%",
      group: "Pre+Power",
      json: #"""
      {"dr":-40.9844,"tp":"12AX7","bi":0,"pv":250,"sz":10,"su":10,"og":-7.077,"mx":100,"iv":2.828,"nf":3,"os":"Power","pt":"EL84","pb":330.107,"kr":270,"st":"20","zp":"6.6","sl":"15","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-power-el34-distributed-thd2",
      label: "EL34 Distributed @2%",
      group: "Pre+Power",
      json: #"""
      {"dr":-31.6973,"tp":"12AX7","bi":0,"pv":250,"sz":10,"su":10,"og":-6.761,"mx":100,"iv":2.828,"nf":4,"os":"Power","pt":"EL34","pb":443.775,"kr":470,"st":"43","zp":"6.6","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-power-6l6gc-pentode-thd2",
      label: "6L6GC Pentode @2%",
      group: "Pre+Power",
      json: #"""
      {"dr":-35.2441,"tp":"12AX7","bi":0,"pv":250,"sz":10,"su":10,"og":-5.095,"mx":100,"iv":2.828,"nf":3,"os":"Power","pt":"6L6GC","pb":391.454,"kr":483.871,"st":"0","zp":"6.6","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-power-kt88-distributed-thd2",
      label: "KT88 Distributed @2%",
      group: "Pre+Power",
      json: #"""
      {"dr":-31.543,"tp":"12AX7","bi":0,"pv":250,"sz":10,"su":10,"og":-3.143,"mx":100,"iv":2.828,"nf":4,"os":"Power","pt":"KT88","pb":379.29,"kr":400,"st":"43","zp":"6.0","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-se-300b-thd2",
      label: "300B SE @2%",
      group: "Pre+Power",
      json: #"""
      {"dr":-2.4844,"tp":"12AU7","bi":0,"pv":250,"sz":10,"su":10,"og":-0.437,"mx":100,"iv":2.828,"nf":3,"os":"SingleEnded","pt":"EL84","pb":329.696,"kr":270,"st":"0","zp":"8.0","sl":"8","sd":"300B","sb":400,"sr":1000,"sp":"3.5"}
      """#),
    ETEffectPreset(
      effect: "Tube Simulator",
      presetId: "listening-se-2a3-thd2",
      label: "2A3 SE @2%",
      group: "Pre+Power",
      json: #"""
      {"dr":-4.2559,"tp":"12AU7","bi":0,"pv":250,"sz":10,"su":10,"og":-0.065,"mx":100,"iv":2.828,"nf":3,"os":"SingleEnded","pt":"EL84","pb":329.696,"kr":270,"st":"0","zp":"8.0","sl":"8","sd":"2A3","sb":300,"sr":750,"sp":"2.5"}
      """#),
    ETEffectPreset(
      effect: "Crossfeed Filter",
      presetId: "subtle-blend",
      label: "Subtle Blend",
      group: "",
      json: #"""
      {"lv":-20,"dl":0.2,"lf":500}
      """#),
    ETEffectPreset(
      effect: "Crossfeed Filter",
      presetId: "vintage-receiver",
      label: "Vintage Receiver",
      group: "",
      json: #"""
      {"lv":-10,"dl":0.35,"lf":800}
      """#),
    ETEffectPreset(
      effect: "Crossfeed Filter",
      presetId: "living-room-speakers",
      label: "Living Room Speakers",
      group: "",
      json: #"""
      {"lv":-4,"dl":0.5,"lf":1000}
      """#),
]

/// エフェクトの表示名で引く。Dictionary(grouping:) は元の並びを保つので、
/// 上の順番がそのまま残る。
let ETEffectPresets: [String: [ETEffectPreset]] =
    Dictionary(grouping: ETEffectPresetList, by: \.effect)
