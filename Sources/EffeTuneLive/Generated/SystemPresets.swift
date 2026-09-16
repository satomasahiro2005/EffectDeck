//  SystemPresets.swift
//  Tools/gen_presets.py が作る。手で直さないこと。
//
//  中身は EffeTune 同梱の .effetune_preset をそのまま持ってきたもの。
//  読むのは PipelineStore.parse で、ユーザーが保存したものと同じ経路を通る。

import Foundation

struct ETSystemPreset: Identifiable {
    var id: String { category + "/" + name }
    let category: String
    let name: String
    let effectCount: Int
    let json: String
}

let ETSystemPresets: [ETSystemPreset] = [
    ETSystemPreset(
      category: "4 Channel",
      name: "Matrix",
      effectCount: 4,
      json: #"""
      {"pipeline":[{"name":"Matrix","enabled":true,"parameters":{"mx":"0002p0311p1213"},"channel":"A"},{"name":"Volume","enabled":true,"parameters":{"vl":-6},"channel":"34"},{"name":"Time Alignment","enabled":true,"parameters":{"dl":30},"channel":"34"},{"name":"Narrow Range","enabled":true,"parameters":{"hf":100,"hs":-24,"lf":4000,"ls":-12},"channel":"34"}]}
      """#),
    ETSystemPreset(
      category: "4 Channel",
      name: "Rear Reverb",
      effectCount: 5,
      json: #"""
      {"pipeline":[{"name":"Matrix","enabled":true,"parameters":{"mx":"00021113"},"channel":"A"},{"name":"Volume","enabled":true,"parameters":{"vl":-6},"channel":"34"},{"name":"RS Reverb","enabled":true,"parameters":{"pd":0,"rs":10,"rt":1.5,"ds":8,"df":0.7,"dp":80,"hd":2000,"ld":200,"mx":100},"channel":"34"},{"name":"Hi Pass Filter","enabled":true,"parameters":{"fr":480,"sl":-12},"channel":"34"},{"name":"Stereo Blend","enabled":true,"parameters":{"stereo":200},"channel":"34"}]}
      """#),
    ETSystemPreset(
      category: "Amp Simulation",
      name: "Tube Amp",
      effectCount: 4,
      json: #"""
      {"pipeline":[{"name":"Volume","enabled":true,"parameters":{"vl":-10}},{"name":"Saturation","enabled":true,"parameters":{"dr":1.9,"bs":-0.1,"mx":100,"gn":4}},{"name":"Power Amp Sag","enabled":true,"parameters":{"ss":3,"ps":40,"rs":50,"mb":true}},{"name":"5Band PEQ","enabled":true,"parameters":{"f0":101.47202016208712,"g0":5.727272727272729,"q0":1,"t0":"pk","e0":true,"f1":316,"g1":0,"q1":1,"t1":"pk","e1":true,"f2":1000,"g2":0,"q2":1,"t2":"pk","e2":true,"f3":3160,"g3":0,"q3":1,"t3":"pk","e3":true,"f4":10000,"g4":0,"q4":1,"t4":"pk","e4":true}}]}
      """#),
    ETSystemPreset(
      category: "Lo-Fi",
      name: "Authentic Vinyl",
      effectCount: 9,
      json: #"""
      {"pipeline":[{"name":"Narrow Range","enabled":true,"parameters":{"hf":20,"hs":0,"lf":8400,"ls":-6}},{"name":"MS Matrix","enabled":true,"parameters":{"md":0,"mg":0,"sg":0,"sw":0}},{"name":"5Band PEQ","enabled":true,"parameters":{"f0":81.56369426401018,"g0":0.1818181818181813,"q0":0.71,"t0":"hp","e0":true,"f1":316,"g1":0,"q1":1,"t1":"pk","e1":true,"f2":1000,"g2":0,"q2":1,"t2":"pk","e2":true,"f3":3160,"g3":0,"q3":1,"t3":"pk","e3":true,"f4":10000,"g4":0,"q4":1,"t4":"pk","e4":true},"channel":"R"},{"name":"MS Matrix","enabled":true,"parameters":{"md":1,"mg":0,"sg":0,"sw":0}},{"name":"Multiband Saturation","enabled":true,"parameters":{"f1":200,"f2":4000,"bands":[{"dr":1.5,"bs":0.1,"mx":50,"gn":0},{"dr":1.5,"bs":0.1,"mx":50,"gn":0},{"dr":1.5,"bs":0.1,"mx":50,"gn":0}]}},{"name":"5Band PEQ","enabled":true,"parameters":{"f0":20,"g0":18,"q0":1,"t0":"pk","e0":true,"f1":316,"g1":0,"q1":1,"t1":"pk","e1":true,"f2":1000,"g2":0,"q2":1,"t2":"pk","e2":true,"f3":3160,"g3":0,"q3":1,"t3":"pk","e3":true,"f4":10000,"g4":0,"q4":1,"t4":"pk","e4":true}},{"name":"Wow Flutter","enabled":true,"parameters":{"rt":0.5,"dp":0.3,"rn":2,"rc":5,"rs":-6,"cp":0,"cs":100}},{"name":"Vinyl Artifacts","enabled":true,"parameters":{"pp":20,"pl":-24,"cm":500,"cl":-33,"hs":-42,"rb":-50,"xt":60,"tn":0,"wr":100,"rt":25,"rm":"Velocity","mx":100}},{"name":"Hum Generator","enabled":true,"parameters":{"fr":50,"tp":"Standard","hm":50,"tn":10,"in":1,"lv":-65}}]}
      """#),
    ETSystemPreset(
      category: "Lo-Fi",
      name: "Dsd Noise",
      effectCount: 3,
      json: #"""
      {"pipeline":[{"name":"Mute","enabled":true,"parameters":{},"inputBus":1,"outputBus":1},{"name":"Noise Blender","enabled":true,"parameters":{"nt":"white","lv":-53.3,"pc":true},"inputBus":1,"outputBus":1},{"name":"Hi Pass Filter","enabled":true,"parameters":{"fr":40000,"sl":-12},"inputBus":1}]}
      """#),
    ETSystemPreset(
      category: "Lo-Fi",
      name: "Needle Drop",
      effectCount: 6,
      json: #"""
      {"pipeline":[{"name":"Compressor","enabled":true,"parameters":{"th":-24,"rt":4,"at":3,"rl":100,"kn":3,"gn":0}},{"name":"Saturation","enabled":true,"parameters":{"dr":2,"bs":0.1,"mx":50,"gn":0}},{"name":"Wow Flutter","enabled":true,"parameters":{"rt":0.5,"dp":2,"rn":10,"rc":5,"rs":-6,"cp":0,"cs":100}},{"name":"Stereo Blend","enabled":true,"parameters":{"stereo":2}},{"name":"Volume","enabled":true,"parameters":{"vl":-6}},{"name":"Hi Pass Filter","enabled":true,"parameters":{"fr":2094,"sl":-12}}]}
      """#),
    ETSystemPreset(
      category: "Lo-Fi",
      name: "Old R2r Dac",
      effectCount: 3,
      json: #"""
      {"pipeline":[{"name":"Bit Crusher","enabled":true,"parameters":{"bd":16,"td":false,"zf":44100,"be":2,"sd":11}},{"name":"Simple Jitter","enabled":true,"parameters":{"rj":100}},{"name":"5Band PEQ","enabled":true,"parameters":{"f0":100,"g0":0,"q0":1,"t0":"pk","e0":true,"f1":20000,"g1":-9.40909090909091,"q1":0.7,"t1":"lp","e1":true,"f2":20000,"g2":1.636363636363637,"q2":0.9,"t2":"lp","e2":true,"f3":20000,"g3":5.5636363636363635,"q3":0.9,"t3":"lp","e3":true,"f4":20000,"g4":9.163636363636362,"q4":0.9,"t4":"lp","e4":true},"channel":"A"}]}
      """#),
    ETSystemPreset(
      category: "Lo-Fi",
      name: "Old Radio",
      effectCount: 6,
      json: #"""
      {"pipeline":[{"name":"Stereo Blend","enabled":true,"parameters":{"stereo":0}},{"name":"Volume","enabled":true,"parameters":{"vl":-12.1}},{"name":"Saturation","enabled":true,"parameters":{"dr":4.3,"bs":-0.1,"mx":100,"gn":2.9}},{"name":"Narrow Range","enabled":true,"parameters":{"hf":183,"hs":-12,"lf":1500,"ls":-12}},{"name":"Noise Blender","enabled":true,"parameters":{"nt":"white","lv":-36,"pc":false}},{"name":"Wow Flutter","enabled":true,"parameters":{"rt":0.5,"dp":4.9,"rn":39.4,"rc":2.5,"rs":-6,"cp":0,"cs":100}}]}
      """#),
    ETSystemPreset(
      category: "Lo-Fi",
      name: "Vinyl",
      effectCount: 10,
      json: #"""
      {"pipeline":[{"name":"MS Matrix","enabled":true,"parameters":{"md":0,"mg":0,"sg":0,"sw":0}},{"name":"5Band PEQ","enabled":true,"parameters":{"f0":81.56369426401018,"g0":0.1818181818181813,"q0":0.71,"t0":"hp","e0":true,"f1":316,"g1":0,"q1":1,"t1":"pk","e1":true,"f2":1000,"g2":0,"q2":1,"t2":"pk","e2":true,"f3":3160,"g3":0,"q3":1,"t3":"pk","e3":true,"f4":10000,"g4":0,"q4":1,"t4":"pk","e4":true},"channel":"R"},{"name":"MS Matrix","enabled":true,"parameters":{"md":1,"mg":0,"sg":0,"sw":0}},{"name":"Multiband Saturation","enabled":true,"parameters":{"f1":200,"f2":4000,"bands":[{"dr":1.5,"bs":0.1,"mx":50,"gn":0},{"dr":1.5,"bs":0.1,"mx":50,"gn":0},{"dr":1.5,"bs":0.1,"mx":50,"gn":0}]}},{"name":"5Band PEQ","enabled":true,"parameters":{"f0":20,"g0":18,"q0":1,"t0":"pk","e0":true,"f1":316,"g1":0,"q1":1,"t1":"pk","e1":true,"f2":1000,"g2":0,"q2":1,"t2":"pk","e2":true,"f3":3160,"g3":0,"q3":1,"t3":"pk","e3":true,"f4":10000,"g4":0,"q4":1,"t4":"pk","e4":true}},{"name":"Narrow Range","enabled":true,"parameters":{"hf":20,"hs":0,"lf":8400,"ls":-6}},{"name":"Wow Flutter","enabled":true,"parameters":{"rt":0.5,"dp":0.3,"rn":2,"rc":5,"rs":-6,"cp":0,"cs":100}},{"name":"Mute","enabled":true,"parameters":{},"inputBus":1,"outputBus":1},{"name":"Noise Blender","enabled":true,"parameters":{"nt":"white","lv":-50,"pc":true},"inputBus":1,"outputBus":1},{"name":"5Band PEQ","enabled":true,"parameters":{"f0":50.447653901651094,"g0":20,"q0":0.71,"t0":"ls","e0":true,"f1":499.49638980283174,"g1":-2.9999999999999973,"q1":1,"t1":"pk","e1":true,"f2":1000,"g2":0,"q2":0.71,"t2":"pk","e2":false,"f3":3160,"g3":0,"q3":1,"t3":"pk","e3":false,"f4":2111.057662598446,"g4":-20,"q4":0.71,"t4":"hs","e4":true},"inputBus":1}]}
      """#),
    ETSystemPreset(
      category: "Others",
      name: "Dsd Noise Listening",
      effectCount: 11,
      json: #"""
      {"pipeline":[{"name":"Pitch Shifter","enabled":true,"parameters":{"ps":-6,"ft":0,"ws":150,"xf":35}},{"name":"Pitch Shifter","enabled":true,"parameters":{"ps":-6,"ft":0,"ws":150,"xf":35}},{"name":"Pitch Shifter","enabled":true,"parameters":{"ps":-6,"ft":0,"ws":150,"xf":35}},{"name":"Pitch Shifter","enabled":true,"parameters":{"ps":-6,"ft":0,"ws":150,"xf":35}},{"name":"Pitch Shifter","enabled":true,"parameters":{"ps":-6,"ft":0,"ws":150,"xf":35}},{"name":"Pitch Shifter","enabled":true,"parameters":{"ps":-6,"ft":0,"ws":150,"xf":35}},{"name":"Pitch Shifter","enabled":true,"parameters":{"ps":-6,"ft":0,"ws":150,"xf":35}},{"name":"Pitch Shifter","enabled":true,"parameters":{"ps":-6,"ft":0,"ws":150,"xf":35}},{"name":"5Band PEQ","enabled":true,"parameters":{"f0":1160.3669775524222,"g0":0.16363636363636316,"q0":0.7,"t0":"hp","e0":true,"f1":1160.3669775524222,"g1":0.08181818181818158,"q1":0.7,"t1":"hp","e1":true,"f2":1160.3669775524222,"g2":0,"q2":0.7,"t2":"hp","e2":true,"f3":2519.8420997897433,"g3":-0.2454545454545473,"q3":1,"t3":"bp","e3":true,"f4":5072.308078524662,"g4":-0.08181818181818414,"q4":0.7,"t4":"lp","e4":true}},{"name":"Volume","enabled":true,"parameters":{"vl":24}},{"name":"Volume","enabled":true,"parameters":{"vl":12}}]}
      """#),
    ETSystemPreset(
      category: "Others",
      name: "Karaoke",
      effectCount: 7,
      json: #"""
      {"pipeline":[{"name":"Mute","enabled":true,"parameters":{},"inputBus":1,"outputBus":1},{"name":"Mute","enabled":true,"parameters":{},"inputBus":2,"outputBus":2},{"name":"Narrow Range","enabled":true,"parameters":{"hf":60,"hs":0,"lf":200,"ls":-48},"outputBus":2},{"name":"Stereo Blend","enabled":true,"parameters":{"stereo":200},"outputBus":1},{"name":"Polarity Inversion","enabled":true,"parameters":{},"inputBus":1},{"name":"Polarity Inversion","enabled":true,"parameters":{},"channel":"R"},{"name":"Pitch Shifter","enabled":true,"parameters":{"ps":0,"ft":0,"ws":150,"xf":35}}]}
      """#),
    ETSystemPreset(
      category: "Processor",
      name: "Bbe",
      effectCount: 2,
      json: #"""
      {"pipeline":[{"name":"5Band PEQ","enabled":true,"parameters":{"f0":20,"g0":0,"q0":0.16,"t0":"ap","e0":true,"f1":316,"g1":0,"q1":1,"t1":"pk","e1":true,"f2":1000,"g2":0,"q2":1,"t2":"pk","e2":true,"f3":3160,"g3":0,"q3":1,"t3":"pk","e3":true,"f4":10000,"g4":0,"q4":1,"t4":"pk","e4":true}},{"name":"5Band Dynamic EQ","enabled":true,"parameters":{"bs":[{"en":false,"ft":"pk","f":100,"q":1,"mg":6,"th":-18,"r":30.1,"kn":3,"a":10,"rl":100,"scf":100,"scq":1},{"en":false,"ft":"pk","f":300,"q":1,"mg":6,"th":-21,"r":30.1,"kn":3,"a":10,"rl":100,"scf":300,"scq":1},{"en":true,"ft":"hs","f":2517.850823588333,"q":1,"mg":6,"th":-18,"r":0.8228108312679314,"kn":3,"a":1,"rl":100,"scf":1177.687310711178,"scq":0.7},{"en":false,"ft":"pk","f":3000,"q":1,"mg":6,"th":-27,"r":30.1,"kn":3,"a":10,"rl":100,"scf":3000,"scq":1},{"en":false,"ft":"pk","f":10000,"q":1,"mg":6,"th":-30,"r":30.1,"kn":3,"a":10,"rl":100,"scf":10000,"scq":1}]}}]}
      """#),
    ETSystemPreset(
      category: "Processor",
      name: "Fm Radio",
      effectCount: 5,
      json: #"""
      {"pipeline":[{"name":"Volume","enabled":true,"parameters":{"vl":-3.5}},{"name":"Stereo Blend","enabled":true,"parameters":{"stereo":130}},{"name":"Multiband Compressor","enabled":true,"parameters":{"f1":100,"f2":500,"f3":2000,"f4":8000,"bands":[{"t":-20,"r":4,"a":30,"rl":150,"k":6,"g":-1,"gr":0},{"t":-22,"r":3,"a":20,"rl":120,"k":4,"g":0,"gr":0},{"t":-25,"r":2.5,"a":15,"rl":80,"k":4,"g":1,"gr":0},{"t":-28,"r":2,"a":10,"rl":60,"k":3,"g":1.5,"gr":0},{"t":-18,"r":5,"a":5,"rl":40,"k":2,"g":-2,"gr":0}]}},{"name":"Saturation","enabled":true,"parameters":{"dr":1.5,"bs":0.1,"mx":100,"gn":0}},{"name":"Noise Blender","enabled":true,"parameters":{"nt":"white","lv":-48,"pc":true}}]}
      """#),
    ETSystemPreset(
      category: "Spatial",
      name: "Live",
      effectCount: 6,
      json: #"""
      {"pipeline":[{"name":"Stereo Blend","enabled":true,"parameters":{"stereo":60}},{"name":"Multiband Saturation","enabled":true,"parameters":{"f1":200,"f2":4000,"bands":[{"dr":1.5,"bs":0.1,"mx":50,"gn":0},{"dr":1.5,"bs":0.1,"mx":50,"gn":0},{"dr":1.5,"bs":0.1,"mx":50,"gn":0}]}},{"name":"Narrow Range","enabled":true,"parameters":{"hf":20,"hs":-24,"lf":8400,"ls":-6}},{"name":"Wow Flutter","enabled":true,"parameters":{"rt":0.5,"dp":0.3,"rn":2,"rc":5,"rs":-6,"cp":0,"cs":100}},{"name":"Tremolo","enabled":true,"parameters":{"rt":10,"dp":0,"rn":50,"rc":13,"rs":-6,"cp":0,"cs":100}},{"name":"RS Reverb","enabled":true,"parameters":{"pd":10,"rs":10,"rt":2.4,"ds":8,"df":0.7,"dp":80,"hd":2000,"ld":200,"mx":16}}]}
      """#),
    ETSystemPreset(
      category: "Speaker Simulation",
      name: "Vintage Full Range",
      effectCount: 4,
      json: #"""
      {"pipeline":[{"name":"Dynamic Saturation","enabled":true,"parameters":{"sd":3,"ss":2,"sp":1,"sm":1,"dd":1.5,"db":0.1,"dm":50,"cm":50,"og":-2}},{"name":"Narrow Range","enabled":true,"parameters":{"hf":79,"hs":-24,"lf":11800,"ls":-6}},{"name":"Modal Resonator","enabled":true,"parameters":{"en":true,"rs":[{"en":true,"fr":6.86,"dc":15,"lp":7.19,"hp":5.8,"gn":0},{"en":true,"fr":7.52,"dc":12,"lp":7.86,"hp":6.48,"gn":-3},{"en":true,"fr":7.99,"dc":10,"lp":8.33,"hp":6.94,"gn":-6},{"en":true,"fr":8.34,"dc":8,"lp":8.68,"hp":7.29,"gn":-9},{"en":true,"fr":8.75,"dc":6,"lp":9.08,"hp":7.7,"gn":-12}],"mx":25,"sr":0}},{"name":"Doppler Distortion","enabled":true,"parameters":{"cf":20,"sm":0.03,"sc":6000,"df":1.5}}]}
      """#),
    ETSystemPreset(
      category: "Utilities",
      name: "Bgm",
      effectCount: 1,
      json: #"""
      {"pipeline":[{"name":"Loudness Equalizer","enabled":true,"parameters":{"sp":85,"rv":-24,"lg":10,"lf":180,"lq":0.6,"hq":0.6,"hg":0,"hf":4000}}]}
      """#),
    ETSystemPreset(
      category: "Visualize",
      name: "All Analyzers",
      effectCount: 5,
      json: #"""
      {"pipeline":[{"name":"Spectrogram","enabled":true,"parameters":{"dr":-96,"pt":12}},{"name":"Spectrum Analyzer","enabled":true,"parameters":{"dr":-96,"pt":12}},{"name":"Stereo Meter","enabled":true,"parameters":{"wt":0.1}},{"name":"Oscilloscope","enabled":true,"parameters":{"dt":0.01,"tm":"Auto","tl":0,"te":"Rising","ho":0.0001,"dl":0,"vo":0}},{"name":"Level Meter","enabled":true,"parameters":{}}]}
      """#),
]
