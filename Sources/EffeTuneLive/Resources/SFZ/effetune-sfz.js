// effetune-sfz.js: 生成物。Tools/sfzjs/build.mjs が作る。手で直さない。
// pin: 5ffca1b31e8a74ada7140aefd0c9c9fe4b7740da
// esbuild: 0.28.2
// patch: effetune-js-sfz-pool-writer.diff sha256=7eb3d033f4255212b6ee31d9251ea13221fcfe2a8c912796407e38cef1baa157
// patch: effetune-js-sfz-stream-table.diff sha256=68b0c0d2d02125e5dcfa8b20861b6b9ca8f224084914f237ea2a6378dc8c54c7
// sha256: 4160568cbe5e102009a6dd2fb37445fb04ec95c7b262f67330d3340bde81586b
var ETSFZ = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __require = /* @__PURE__ */ ((x) => typeof require !== "undefined" ? require : typeof Proxy !== "undefined" ? new Proxy(x, {
    get: (a, b2) => (typeof require !== "undefined" ? require : a)[b2]
  }) : x)(function(x) {
    if (typeof require !== "undefined") return require.apply(this, arguments);
    throw Error('Dynamic require of "' + x + '" is not supported');
  });
  var __esm = (fn2, res, err) => function __init() {
    if (err) throw err[0];
    try {
      return fn2 && (res = (0, fn2[__getOwnPropNames(fn2)[0]])(fn2 = 0)), res;
    } catch (e8) {
      throw err = [e8], e8;
    }
  };
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // js/sfz/modulation-schema.js
  function property(kinds, name, defaultValue, min, max, unit = "Scalar", options = {}) {
    const { modulationUnit = unit, ...settings } = options;
    for (const kind of kinds) definitions.push(Object.freeze({
      kind: SFZ_MOD_KINDS[kind],
      id: SFZ_MOD_PROPERTY_IDS[name],
      name,
      default: defaultValue,
      min,
      max,
      unit: SFZ_MOD_UNITS[unit],
      modulationUnit: SFZ_MOD_UNITS[modulationUnit],
      integer: false,
      storage: SFZ_MOD_STORAGE_TYPES.Float,
      combine: 0,
      sampling: SFZ_MOD_SAMPLING.Dynamic,
      ...settings
    }));
  }
  function targetFor(key) {
    const condition = /^(?:(on|stop)_)?(lo|hi)hdcc([0-9]{1,3})$/.exec(key);
    if (condition) return destination(
      condition[1] === "on" ? K.ControllerStart : condition[1] === "stop" ? K.ControllerStop : K.ControllerCondition,
      Number(condition[3]),
      condition[2] === "lo" ? "ConditionLow" : "ConditionHigh"
    );
    const stop = /^stop_(lo|hi)cc([0-9]{1,3})$/.exec(key);
    if (stop) return destination(K.ControllerStop, Number(stop[2]), stop[1] === "lo" ? "ConditionLow" : "ConditionHigh");
    if (key === "lobpm" || key === "hibpm") return destination(K.TempoCondition, 0, key === "lobpm" ? "BpmLow" : "BpmHigh");
    if (key === "lotimer" || key === "hitimer") return destination(K.TimerCondition, 0, key === "lotimer" ? "TimerLow" : "TimerHigh");
    if (key === "sample_quality") return destination(K.SamplePlayback, 0, "SampleQuality");
    if (Object.hasOwn(amplifierFields, key)) return destination(K.Amplifier, 0, amplifierFields[key]);
    const velocity = /^amp_velcurve_([0-9]{1,3})$/.exec(key);
    if (velocity) return destination(K.VelocityCurvePoint, Number(velocity[1]), "Level");
    const crossfade = /^xf(in|out)_(lo|hi)(key|vel|cc([0-9]{1,3}))$/.exec(key);
    if (crossfade) return destination(
      K.Crossfade,
      crossfade[3] === "key" ? 0 : crossfade[3] === "vel" ? 1 : 2 + Number(crossfade[4]),
      `${crossfade[1] === "in" ? "In" : "Out"}${crossfade[2] === "lo" ? "Low" : "High"}`
    );
    const reverse = /^reverse_(lo|hi)cc([0-9]{1,3})$/.exec(key);
    if (reverse) return destination(K.ReverseController, Number(reverse[2]), reverse[1] === "lo" ? "ReverseLow" : "ReverseHigh");
    if (Object.hasOwn(dspFields, key)) return destination(K.VoiceDSP, 0, dspFields[key]);
    if (Object.hasOwn(noiseFields, key)) return destination(K.NoiseLayer, 0, noiseFields[key]);
    if (Object.hasOwn(playbackFields, key)) return destination(K.SamplePlayback, 0, playbackFields[key]);
    if (Object.hasOwn(lifecycleFields, key)) return destination(K.Lifecycle, 0, lifecycleFields[key]);
    const release = /^rt_decay([0-9]+)(_time)?$/.exec(key);
    if (release) return destination(K.ReleaseDecaySegment, Number(release[1]), release[2] ? "Time" : "ReleaseDecay", { kind: K.Lifecycle, index: 0 });
    const oscillator = /^oscillator_(detune|mod_depth)$/.exec(key);
    if (oscillator) return destination(K.Oscillator, 0, oscillator[1] === "detune" ? "OscillatorDetune" : "OscillatorModDepth");
    if (Object.hasOwn(rootFields, key)) return destination(K.Region, 0, rootFields[key]);
    let match = /^eq([1-3])_(type|dynamic|mode)$/.exec(key);
    if (match) return destination(K.Equalizer, Number(match[1]), { type: "EqType", dynamic: "Dynamic", mode: "FilterMode" }[match[2]]);
    match = /^eq([1-3])_(freq|bw|gain)$/.exec(key);
    if (match) return destination(K.Region, 0, `Eq${match[1]}${{ freq: "Frequency", bw: "Bandwidth", gain: "Gain" }[match[2]]}`);
    match = /^(cutoff|resonance)(2)?(?:_(random))?$/.exec(key);
    if (match) return destination(K.Filter, match[2] ? 2 : 1, match[3] ? match[1] === "cutoff" ? "Random" : "ResonanceRandom" : match[1] === "cutoff" ? "Cutoff" : "Resonance");
    match = /^fil(2)?_(type|gain|mode|keytrack|keycenter|veltrack|random)$/.exec(key);
    if (match) return destination(K.Filter, match[1] ? 2 : 1, {
      type: "FilterType",
      gain: "Gain",
      mode: "FilterMode",
      keytrack: "KeyTrack",
      keycenter: "KeyCenter",
      veltrack: "VelocityTrack",
      random: "Random"
    }[match[2]]);
    match = /^(ampeg|fileg|pitcheg|amplfo|fillfo|pitchlfo)_(.*)$/.exec(key);
    if (match && Object.hasOwn(fields, match[2])) return destination(fixedKinds[match[1]], 0, fields[match[2]]);
    match = /^eg([0-9]+)_(time|level|curve|shape)([0-9]+)$/.exec(key);
    if (match) return destination(
      K.EGStage,
      Number(match[3]),
      { time: "Time", level: "Level", curve: "Curve", shape: "Shape" }[match[2]],
      { kind: K.FlexEG, index: Number(match[1]) }
    );
    match = /^eg([0-9]+)_(.*)$/.exec(key);
    if (match && Object.hasOwn(fields, match[2])) return destination(
      K.FlexEG,
      Number(match[1]),
      match[2] === "sustain" ? "SustainPoint" : fields[match[2]]
    );
    match = /^lfo([0-9]+)_(wave|ratio|scale|offset)([0-9]+)$/.exec(key);
    if (match) return destination(K.LFOSubosc, Number(match[3]), fields[match[2]], { kind: K.LFO, index: Number(match[1]) });
    match = /^lfo([0-9]+)_step([0-9]+)$/.exec(key);
    if (match) return destination(K.LFOStep, Number(match[2]), "StepLevel", { kind: K.LFO, index: Number(match[1]) });
    match = /^lfo([0-9]+)_(.*)$/.exec(key);
    if (match && Object.hasOwn(fields, match[2])) return destination(K.LFO, Number(match[1]), fields[match[2]]);
    return null;
  }
  function sfzModulationTarget(key) {
    let target = targetFor(key), source = null, multiply = false;
    if (!target) {
      const generator = /^(eg|lfo)([0-9]+)_(.+)$/.exec(key);
      if (generator) {
        source = { kind: generator[1] === "eg" ? K.FlexEG : K.LFO, index: Number(generator[2]) };
        const cross = /^(freq|depth|depthadd)_lfo([0-9]+)$/.exec(generator[3]);
        if (cross) {
          target = destination(K.LFO, Number(cross[2]), cross[1] === "freq" ? "Frequency" : "Depth");
          multiply = cross[1] === "depth";
        } else {
          target = targetFor(generator[3].replace(/^driveshape$/, "drive").replace(/^noise(level|tone|step)$/, "noise_$1").replace(/^eq([1-3])(freq|bw|gain)$/, "eq$1_$2").replace(/^fil1gain$/, "fil_gain").replace(/^fil2gain$/, "fil2_gain"));
          multiply = generator[3] === "amplitude";
        }
      }
    }
    return target && SFZ_MOD_PROPERTIES.some((spec) => spec.kind === target.kind && spec.id === target.property) ? { target, source, multiply } : null;
  }
  var SFZ_MOD_KINDS, SFZ_MOD_PROPERTY_IDS, SFZ_MOD_UNITS, SFZ_MOD_SAMPLING, SFZ_MOD_STORAGE_TYPES, SFZ_MOD_ROUTE_FLAGS, SFZ_MOD_FILTER_TYPES, definitions, FLOAT_MAX, eg, lfo, SFZ_MOD_PROPERTIES, SFZ_MOD_SOURCES, SFZ_MOD_VIRTUAL_CONTROLLERS, SFZ_MOD_LAYOUT, SFZ_MOD_STORAGE, K, P, fields, fixedKinds, rootFields, playbackFields, lifecycleFields, dspFields, noiseFields, amplifierFields, destination;
  var init_modulation_schema = __esm({
    "js/sfz/modulation-schema.js"() {
      SFZ_MOD_KINDS = Object.freeze({
        Region: 0,
        AmpEG: 1,
        FilterEG: 2,
        PitchEG: 3,
        FlexEG: 4,
        EGStage: 5,
        AmpLFO: 6,
        FilterLFO: 7,
        PitchLFO: 8,
        LFO: 9,
        LFOSubosc: 10,
        LFOStep: 11,
        Filter: 12,
        Oscillator: 13,
        SamplePlayback: 14,
        Lifecycle: 15,
        ReleaseDecaySegment: 16,
        VoiceDSP: 17,
        NoiseLayer: 18,
        InitialController: 19,
        ReverseController: 20,
        Amplifier: 21,
        VelocityCurvePoint: 22,
        Crossfade: 23,
        ControllerCondition: 24,
        ControllerStart: 25,
        ControllerStop: 26,
        TempoCondition: 27,
        TimerCondition: 28,
        Equalizer: 29,
        Variable: 30
      });
      SFZ_MOD_PROPERTY_IDS = Object.freeze({
        Volume: 0,
        Amplitude: 1,
        Pitch: 2,
        Pan: 3,
        Width: 4,
        Position: 5,
        Delay: 6,
        Start: 7,
        Attack: 8,
        Hold: 9,
        Decay: 10,
        Sustain: 11,
        Release: 12,
        Depth: 13,
        Dynamic: 14,
        AttackShape: 15,
        DecayShape: 16,
        ReleaseShape: 17,
        DecayZero: 18,
        ReleaseZero: 19,
        Points: 20,
        SustainPoint: 21,
        Loop: 22,
        LoopCount: 23,
        Time: 24,
        Level: 25,
        Curve: 26,
        Shape: 27,
        Frequency: 28,
        Fade: 29,
        Phase: 30,
        Wave: 31,
        Count: 32,
        Ratio: 33,
        Scale: 34,
        Offset: 35,
        Steps: 36,
        StepLevel: 37,
        Cutoff: 38,
        Resonance: 39,
        FilterType: 40,
        Gain: 41,
        FilterMode: 42,
        KeyTrack: 43,
        KeyCenter: 44,
        VelocityTrack: 45,
        Random: 46,
        Eq1Frequency: 47,
        Eq1Bandwidth: 48,
        Eq1Gain: 49,
        Eq2Frequency: 50,
        Eq2Bandwidth: 51,
        Eq2Gain: 52,
        Eq3Frequency: 53,
        Eq3Bandwidth: 54,
        Eq3Gain: 55,
        Smooth: 57,
        Enabled: 58,
        AmpEnvelope: 59,
        ResonanceRandom: 60,
        BendSmooth: 61,
        BendStepUp: 62,
        BendStepDown: 63,
        NoteOffset: 64,
        SwitchOffset: 65,
        ScopeTune: 66,
        SourceWave: 67,
        OscillatorMode: 68,
        OscillatorMulti: 69,
        OscillatorDetune: 70,
        OscillatorPhase: 71,
        OscillatorQuality: 72,
        OscillatorModDepth: 73,
        OscillatorTableSize: 74,
        DelayBeats: 75,
        DelayBeatsRandom: 76,
        DelaySamples: 77,
        SyncBeats: 78,
        SyncOffset: 79,
        StopBeats: 80,
        SampleFadeout: 81,
        OffsetMode: 82,
        OffsetRandom: 83,
        LoopStartDelta: 84,
        LoopEndDelta: 85,
        LoopType: 86,
        LoopTune: 87,
        PlayCount: 88,
        NoteSelfMask: 89,
        OffCurve: 90,
        OffShape: 91,
        ReleaseDead: 92,
        ReleaseDecay: 93,
        SustainSwitch: 94,
        SostenutoSwitch: 95,
        SustainCC: 96,
        SostenutoCC: 97,
        SustainLow: 98,
        SostenutoLow: 99,
        SwitchVelocity: 100,
        PolyphonyStealing: 101,
        InitialValue: 102,
        ScopeVolume: 103,
        ScopeAmplitude: 104,
        ReverseLow: 105,
        ReverseHigh: 106,
        LoopRepeatLimit: 107,
        LoopRepeatLimited: 108,
        DspOrder: 120,
        Drive: 121,
        BitReduction: 122,
        Decimation: 123,
        NoiseLevel: 124,
        NoiseTone: 125,
        NoiseStep: 126,
        NoiseStereo: 127,
        NoiseFilter: 128,
        PanLaw: 129,
        PhaseInvert: 130,
        PanKeyTrack: 131,
        PanKeyCenter: 132,
        PanVelocityTrack: 133,
        PanRandom: 134,
        InLow: 135,
        InHigh: 136,
        OutLow: 137,
        OutHigh: 138,
        ConditionLow: 141,
        ConditionHigh: 142,
        BpmLow: 143,
        BpmHigh: 144,
        TimerLow: 145,
        TimerHigh: 146,
        SampleQuality: 147,
        EqType: 148,
        NoteEnabled: 149,
        SilentAction: 150,
        PositionKeyCenter: 151,
        PositionKeyTrack: 152,
        PositionVelocityTrack: 153,
        PositionRandom: 154,
        VariableValue: 155
      });
      SFZ_MOD_UNITS = Object.freeze({
        Scalar: 0,
        Seconds: 1,
        Percent: 2,
        Decibels: 3,
        Cents: 4,
        Hertz: 5,
        Cycles: 6,
        MidiKey: 7,
        Octaves: 8,
        Index: 9,
        Milliseconds: 10,
        Degrees: 11,
        Beats: 12
      });
      SFZ_MOD_SAMPLING = Object.freeze({ Birth: 0, Dynamic: 1, Envelope: 2 });
      SFZ_MOD_STORAGE_TYPES = Object.freeze({ Float: 0, UInt32: 1, UInt33: 2 });
      SFZ_MOD_ROUTE_FLAGS = Object.freeze({
        Multiply: 1,
        StepCurveA: 2,
        StepCurveB: 4,
        IntegerDepth: 8,
        IntegerHigh: 16,
        IntegerNegative: 32
      });
      SFZ_MOD_FILTER_TYPES = Object.freeze({
        lpf_1p: 1,
        lpf_2p: 2,
        hpf_1p: 3,
        hpf_2p: 4,
        bpf_2p: 5,
        brf_2p: 6,
        bpf_1p: 7,
        brf_1p: 8,
        apf_1p: 9,
        lpf_2p_sv: 10,
        hpf_2p_sv: 11,
        bpf_2p_sv: 12,
        brf_2p_sv: 13,
        pkf_2p: 14,
        lpf_4p: 15,
        hpf_4p: 16,
        lpf_6p: 17,
        hpf_6p: 18,
        comb: 19,
        pink: 20,
        lsh: 21,
        hsh: 22,
        peq: 23
      });
      definitions = [];
      FLOAT_MAX = 34028234663852886e22;
      eg = ["AmpEG", "FilterEG", "PitchEG"];
      lfo = ["AmpLFO", "FilterLFO", "PitchLFO", "LFO"];
      property(["Variable"], "VariableValue", 0, -FLOAT_MAX, FLOAT_MAX);
      property(["Region"], "NoteEnabled", 1, 0, 1, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Region"], "SilentAction", 0, 0, 1, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Region"], "Volume", 0, -144, 144, "Decibels");
      property(["Region"], "Amplitude", 100, 0, 100, "Percent");
      property(["Region"], "Pitch", 0, -12e3, 12e3, "Cents");
      property(["Region"], "Pan", 0, -100, 100, "Percent");
      property(["Region"], "Width", 100, -100, 100, "Percent");
      property(["Region"], "Position", 0, -100, 100, "Percent");
      property(["Region"], "BendSmooth", 0, 0, FLOAT_MAX, "Milliseconds", { sampling: SFZ_MOD_SAMPLING.Birth });
      for (const name of ["BendStepUp", "BendStepDown"]) property(
        ["Region"],
        name,
        1,
        1,
        1200,
        "Cents",
        { integer: true, sampling: SFZ_MOD_SAMPLING.Birth }
      );
      for (const name of ["NoteOffset", "SwitchOffset"]) property(
        ["Region"],
        name,
        0,
        -247,
        247,
        "MidiKey",
        { integer: true, sampling: SFZ_MOD_SAMPLING.Birth }
      );
      property(["Region"], "ScopeTune", 0, -28800, 28800, "Cents", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Region"], "ScopeVolume", 0, -432, 18, "Decibels", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Region"], "ScopeAmplitude", 100, 0, 100, "Percent", { sampling: SFZ_MOD_SAMPLING.Birth });
      for (let band = 1; band <= 3; band++) {
        property(["Region"], `Eq${band}Frequency`, [50, 500, 5e3][band - 1], 0, 3e4, "Hertz");
        property(["Region"], `Eq${band}Bandwidth`, 1, 1e-3, 4, "Octaves");
        property(["Region"], `Eq${band}Gain`, 0, -96, 24, "Decibels");
      }
      property(["Equalizer"], "EqType", 0, 0, 2, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Equalizer"], "Dynamic", 0, 0, 1, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Equalizer"], "FilterMode", 1, 0, 1, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      for (const name of ["Delay", "Attack", "Hold", "Decay", "Release"]) {
        property(eg, name, 0, 0, 100, "Seconds", { sampling: SFZ_MOD_SAMPLING.Envelope });
      }
      property(eg, "Start", 0, 0, 100, "Percent", { sampling: SFZ_MOD_SAMPLING.Envelope });
      property(eg, "Sustain", 0, 0, 100, "Percent", { sampling: SFZ_MOD_SAMPLING.Envelope });
      property(eg, "Dynamic", 0, 0, 1, "Scalar", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      for (const name of ["AttackShape", "DecayShape", "ReleaseShape"]) property(eg, name, 0, -FLOAT_MAX, FLOAT_MAX);
      property(eg, "DecayZero", 1, 0, 1, "Scalar", { integer: true });
      property(eg, "ReleaseZero", 0, 0, 1, "Scalar", { integer: true });
      property(["FilterEG", "PitchEG"], "Depth", 0, -12e3, 12e3, "Cents");
      property(["FlexEG"], "Dynamic", 0, 0, 1, "Scalar", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["FlexEG"], "AmpEnvelope", 0, 0, 1, "Scalar", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      for (const name of ["Points", "SustainPoint", "Loop", "LoopCount"]) {
        property(
          ["FlexEG"],
          name,
          ["Points", "LoopCount"].includes(name) ? 0 : -1,
          -1,
          65535,
          "Index",
          { integer: true, sampling: SFZ_MOD_SAMPLING.Birth }
        );
      }
      property(["EGStage"], "Time", 0, 0, FLOAT_MAX, "Seconds", { sampling: SFZ_MOD_SAMPLING.Envelope });
      property(["EGStage"], "Level", 0, -1, 1, "Scalar", { sampling: SFZ_MOD_SAMPLING.Envelope });
      property(["EGStage"], "Curve", 0, 0, 254, "Index", { integer: true });
      property(["EGStage"], "Shape", 0, -FLOAT_MAX, FLOAT_MAX);
      property(["AmpLFO", "FilterLFO", "PitchLFO"], "Delay", 0, 0, 100, "Seconds", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["AmpLFO", "FilterLFO", "PitchLFO"], "Fade", 0, 0, 100, "Seconds", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["AmpLFO", "FilterLFO", "PitchLFO"], "Frequency", 0, 0, 2e4, "Hertz");
      property(["LFO"], "Delay", 0, 0, FLOAT_MAX, "Seconds", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["LFO"], "Fade", 0, 0, FLOAT_MAX, "Seconds", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["LFO"], "Frequency", 0, 0, FLOAT_MAX, "Hertz");
      property(lfo, "Phase", 0, 0, 1, "Cycles", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(lfo, "Count", -1, -1, 16777216, "Index", { integer: true });
      property(lfo, "Steps", 0, 0, 65535, "Index", { integer: true });
      property(lfo, "Smooth", 0, 0, 1e4, "Milliseconds");
      property(["AmpLFO"], "Depth", 0, -10, 10, "Decibels");
      property(["FilterLFO", "PitchLFO"], "Depth", 0, -1200, 1200, "Cents");
      property(["LFO"], "Depth", 100, -FLOAT_MAX, FLOAT_MAX, "Percent");
      property([...lfo, "LFOSubosc"], "Wave", 1, -1, 13, "Index", { integer: true });
      property([...lfo, "LFOSubosc"], "Ratio", 1, 0, FLOAT_MAX);
      property([...lfo, "LFOSubosc"], "Scale", 1, -FLOAT_MAX, FLOAT_MAX);
      property([...lfo, "LFOSubosc"], "Offset", 0, -FLOAT_MAX, FLOAT_MAX);
      property(["LFOStep"], "StepLevel", 0, -100, 100, "Percent");
      property(["Filter"], "Enabled", 0, 0, 1, "Scalar", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Filter"], "Cutoff", 2e4, 0, 384e3, "Hertz", { modulationUnit: "Cents" });
      property(["Filter"], "Resonance", 0, 0, 40, "Decibels");
      property(["Filter"], "FilterType", 2, 1, 23, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Filter"], "Gain", 0, -144, 144, "Decibels");
      property(["Filter"], "FilterMode", 0, 0, 1, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Filter"], "KeyTrack", 0, 0, 1200, "Cents", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Filter"], "KeyCenter", 60, 0, 127, "MidiKey", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Filter"], "VelocityTrack", 0, -9600, 9600, "Cents", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Filter"], "Random", 0, 0, 9600, "Cents", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Filter"], "ResonanceRandom", 0, 0, 40, "Decibels", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Oscillator"], "Enabled", 0, 0, 1, "Scalar", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Oscillator"], "SourceWave", 0, 0, 6, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Oscillator"], "OscillatorMode", 0, 0, 2, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Oscillator"], "OscillatorMulti", 1, 1, 9, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Oscillator"], "OscillatorDetune", 0, -FLOAT_MAX, FLOAT_MAX, "Cents");
      property(["Oscillator"], "OscillatorPhase", 0, -FLOAT_MAX, 360, "Degrees", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Oscillator"], "OscillatorQuality", 2, 0, 3, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Oscillator"], "OscillatorModDepth", 100, -FLOAT_MAX, FLOAT_MAX, "Percent");
      property(["Oscillator"], "OscillatorTableSize", 0, 0, 4294967295, "Index", { integer: true, storage: SFZ_MOD_STORAGE_TYPES.UInt32, sampling: SFZ_MOD_SAMPLING.Birth });
      for (const name of ["DelayBeats", "DelayBeatsRandom"]) property(["SamplePlayback"], name, 0, 0, FLOAT_MAX, "Beats", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["SamplePlayback"], "DelaySamples", 0, 0, 4294967296, "Index", { integer: true, storage: SFZ_MOD_STORAGE_TYPES.UInt33, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["SamplePlayback"], "Delay", 0, -100, 100, "Seconds", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["SamplePlayback"], "LoopRepeatLimit", 0, 0, 4294967295, "Index", { integer: true, storage: SFZ_MOD_STORAGE_TYPES.UInt32, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["SamplePlayback"], "LoopRepeatLimited", 0, 0, 1, "Scalar", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      for (const name of ["SyncBeats", "SyncOffset"]) property(["SamplePlayback"], name, 0, 0, 32, "Beats", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["SamplePlayback"], "StopBeats", -1, -1, FLOAT_MAX, "Beats", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["SamplePlayback"], "SampleFadeout", 0, 0, FLOAT_MAX, "Seconds");
      property(["SamplePlayback"], "OffsetMode", 0, 0, 1, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["SamplePlayback"], "Offset", 0, -4294967296, 4294967296, "Index", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["SamplePlayback"], "OffsetRandom", 0, 0, 4294967296, "Index", { integer: true, storage: SFZ_MOD_STORAGE_TYPES.UInt33, sampling: SFZ_MOD_SAMPLING.Birth });
      for (const name of ["LoopStartDelta", "LoopEndDelta"]) property(["SamplePlayback"], name, 0, -4294967296, 4294967296, "Index");
      property(["SamplePlayback"], "LoopType", 0, 0, 2, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["SamplePlayback"], "LoopTune", 0, -FLOAT_MAX, FLOAT_MAX, "Cents");
      property(["SamplePlayback"], "PlayCount", 0, 0, 4294967296, "Index", { integer: true, storage: SFZ_MOD_STORAGE_TYPES.UInt33, sampling: SFZ_MOD_SAMPLING.Birth });
      for (const [name, value] of [["NoteSelfMask", 1], ["ReleaseDead", 0], ["SustainSwitch", 1], ["SostenutoSwitch", 1], ["SwitchVelocity", 0]]) {
        property(["Lifecycle"], name, value, 0, 1, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      }
      property(["Lifecycle"], "OffCurve", 10, -2, 10, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Lifecycle"], "OffShape", -10.3616, -FLOAT_MAX, FLOAT_MAX);
      property(["Lifecycle"], "ReleaseDecay", 0, 0, 200, "Decibels", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Lifecycle"], "PolyphonyStealing", 0, 0, 1, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      for (const [name, value] of [["SustainCC", 64], ["SostenutoCC", 66]]) property(["Lifecycle"], name, value, 0, 127, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      for (const name of ["SustainLow", "SostenutoLow"]) property(["Lifecycle"], name, 0.5, 0, 127, "Scalar", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["ReleaseDecaySegment"], "ReleaseDecay", 0, -200, 200, "Decibels", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["ReleaseDecaySegment"], "Time", -1, -1, FLOAT_MAX, "Seconds", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["InitialController"], "InitialValue", 0, 0, 1, "Scalar", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["ReverseController"], "ReverseLow", 0, 0, 127, "Scalar", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["ReverseController"], "ReverseHigh", 127, 0, 127, "Scalar", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["VoiceDSP"], "DspOrder", 1, 0, 14, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      for (const name of ["Drive", "BitReduction", "Decimation"]) property(["VoiceDSP"], name, 0, 0, 100, "Percent");
      property(["NoiseLayer"], "NoiseLevel", -96, -96, 24, "Decibels");
      property(["NoiseLayer"], "NoiseTone", 100, 0, 100, "Percent", { integer: true });
      property(["NoiseLayer"], "NoiseStep", 0, 0, 100, "Index", { integer: true });
      property(["NoiseLayer"], "NoiseStereo", 1, 0, 1, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["NoiseLayer"], "NoiseFilter", 1, 0, 23, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Amplifier"], "VelocityTrack", 100, -100, 100, "Percent");
      property(["Amplifier"], "Random", 0, -FLOAT_MAX, FLOAT_MAX, "Scalar", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Amplifier"], "PanLaw", 0, 0, 2, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Amplifier"], "PhaseInvert", 0, 0, 1, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Amplifier"], "PanKeyCenter", 60, 0, 127, "MidiKey", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      for (const name of ["PanKeyTrack", "PanVelocityTrack", "PanRandom"]) property(["Amplifier"], name, 0, -100, 100, "Percent", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Amplifier"], "PositionKeyCenter", 60, 0, 127, "MidiKey", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Amplifier"], "PositionKeyTrack", 0, -FLOAT_MAX, FLOAT_MAX, "Percent", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Amplifier"], "PositionVelocityTrack", 0, -200, 200, "Percent", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Amplifier"], "PositionRandom", 0, -100, 100, "Percent", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["VelocityCurvePoint"], "Level", 0, 0, 1, "Scalar", { sampling: SFZ_MOD_SAMPLING.Birth });
      for (const name of ["InLow", "InHigh", "OutLow", "OutHigh"]) property(["Crossfade"], name, name.startsWith("In") ? 0 : 127, 0, 127, "Scalar", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["Crossfade"], "Curve", 1, 0, 1, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      property(["ControllerCondition"], "ConditionLow", 0, 0, 1, "Scalar", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["ControllerCondition"], "ConditionHigh", 1, 0, 1, "Scalar", { sampling: SFZ_MOD_SAMPLING.Birth });
      for (const name of ["ConditionLow", "ConditionHigh"]) property(["ControllerStart", "ControllerStop"], name, -1, -1, 1, "Scalar", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["TempoCondition"], "BpmLow", 0, 0, 500, "Scalar", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["TempoCondition"], "BpmHigh", 500, 0, 500, "Scalar", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["TimerCondition"], "TimerLow", 0, 0, FLOAT_MAX, "Seconds", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["TimerCondition"], "TimerHigh", FLOAT_MAX, 0, FLOAT_MAX, "Seconds", { sampling: SFZ_MOD_SAMPLING.Birth });
      property(["SamplePlayback"], "SampleQuality", 0, 0, 10, "Index", { integer: true, sampling: SFZ_MOD_SAMPLING.Birth });
      SFZ_MOD_PROPERTIES = Object.freeze(definitions.map((definition) => {
        const defaults2 = { Release: 1e-3, Sustain: 100, DecayShape: -10.3616, ReleaseShape: -10.3616 };
        return definition.kind === SFZ_MOD_KINDS.AmpEG && Object.hasOwn(defaults2, definition.name) ? Object.freeze({ ...definition, default: defaults2[definition.name] }) : definition;
      }));
      SFZ_MOD_SOURCES = Object.freeze({ Constant: 0, Controller: 65536, Envelope: 196608, LFO: 262144, Note: 327680, Variable: 393216 });
      SFZ_MOD_VIRTUAL_CONTROLLERS = Object.freeze([
        [128, "PitchBend", "normalized", "channel", "event"],
        [129, "ChannelPressure", "normalized", "channel", "event"],
        [130, "PolyPressure", "normalized", "voice-key", "event"],
        [131, "NoteOnVelocity", "normalized", "instrument", "note-on"],
        [132, "NoteOffVelocity", "normalized", "instrument", "note-off"],
        [133, "NoteNumber", "normalized", "instrument", "note-event"],
        [134, "NoteGate", "boolean", "instrument", "note-event"],
        [135, "Random", "normalized", "instrument", "note-on"],
        [136, "BipolarRandom", "bipolar", "instrument", "note-on"],
        [137, "Alternate", "boolean", "instrument", "note-on"],
        [140, "KeyDelta", "semitones", "instrument", "note-on"],
        [141, "AbsoluteKeyDelta", "semitones", "instrument", "note-on"],
        [142, "Tempo", "BPM", "host", "sample"],
        [143, "Transport", "0-stop/1-play/2-loop", "host", "event"],
        [144, "SampleRate", "Hz", "engine", "prepare"],
        [145, "EngineTime", "seconds", "engine", "sample"],
        [146, "Numerator", "integer", "host", "event"],
        [147, "Denominator", "integer", "host", "event"],
        [148, "SongPosition", "quarter-notes", "host", "sample"],
        [149, "BarPosition", "quarter-notes", "host", "sample"],
        [150, "InstrumentTime", "seconds", "instrument", "sample"],
        [151, "SinceNoteOn", "seconds", "instrument", "sample"],
        [152, "SinceNoteOff", "seconds", "instrument", "sample"],
        [153, "KeysDown", "integer", "instrument", "note-event"],
        [154, "Voices", "integer", "instrument", "sample"],
        [155, "SampleOffset", "sample-frames", "instrument", "voice-start"]
      ].map(([id, name, unit, scope, sampling]) => Object.freeze({ id, name, unit, scope, sampling })));
      SFZ_MOD_LAYOUT = Object.freeze({
        Version: 3,
        HeaderWords: 14,
        DirectoryWords: 6,
        RouteWords: 10,
        CurveWords: 129,
        InstanceWords: 6,
        ParameterWords: 4,
        Profile: 1
      });
      SFZ_MOD_STORAGE = Object.freeze({
        MaxVoices: 128,
        EnvelopeStateBytes: 80,
        LfoStateBytes: 88,
        RouteStateBytes: 24,
        BornFactsBytes: 24,
        RegionPlanBytes: 256,
        PropertyPointerBytes: 8,
        StateIndexBytes: 4,
        OscillatorStateBytes: 144,
        PlaybackStateBytes: 40,
        VoiceDspStateBytes: 40,
        NoiseStateBytes: 496,
        PlaybackPlanBytes: 208,
        ReleaseSegmentBytes: 24,
        ReverseConditionBytes: 12,
        ParameterIndexBytes: 4,
        IntegerBaseBytes: 8,
        IntegerDepthBytes: 8,
        ConditionIndexBytes: 4,
        InitialControllerBytes: 512,
        GeneratorParametersBytes: 64,
        PreviewVoices: 1,
        TimerGroupBytes: 16 * 8 * 2,
        CachePageFrames: 4096,
        CachePageBytes: 32,
        CacheSampleMetadataBytes: 16,
        CacheRequestBytes: 24,
        CacheRequestCapacity: 4096,
        CacheModeBytes: 1,
        CacheHashLoad: 4,
        CacheForecastPageBytes: 16,
        CacheForecastSourceBytes: 64,
        CacheForecastSourceCapacity: 4096
      });
      K = SFZ_MOD_KINDS;
      P = SFZ_MOD_PROPERTY_IDS;
      fields = Object.freeze({
        delay: "Delay",
        start: "Start",
        attack: "Attack",
        hold: "Hold",
        decay: "Decay",
        sustain: "Sustain",
        release: "Release",
        depth: "Depth",
        dynamic: "Dynamic",
        attack_shape: "AttackShape",
        decay_shape: "DecayShape",
        release_shape: "ReleaseShape",
        decay_zero: "DecayZero",
        release_zero: "ReleaseZero",
        freq: "Frequency",
        fade: "Fade",
        phase: "Phase",
        wave: "Wave",
        count: "Count",
        ratio: "Ratio",
        scale: "Scale",
        offset: "Offset",
        steps: "Steps",
        smooth: "Smooth",
        points: "Points",
        loop: "Loop",
        loop_count: "LoopCount",
        ampeg: "AmpEnvelope"
      });
      fixedKinds = Object.freeze({
        ampeg: K.AmpEG,
        fileg: K.FilterEG,
        pitcheg: K.PitchEG,
        amplfo: K.AmpLFO,
        fillfo: K.FilterLFO,
        pitchlfo: K.PitchLFO
      });
      rootFields = Object.freeze({
        volume: "Volume",
        amplitude: "Amplitude",
        tune: "Pitch",
        pitch: "Pitch",
        pan: "Pan",
        width: "Width",
        position: "Position"
      });
      playbackFields = Object.freeze({
        delay: "Delay",
        delay_beats: "DelayBeats",
        delay_beats_random: "DelayBeatsRandom",
        delay_samples: "DelaySamples",
        sync_beats: "SyncBeats",
        sync_offset: "SyncOffset",
        stop_beats: "StopBeats",
        sample_fadeout: "SampleFadeout",
        offset_mode: "OffsetMode",
        offset: "Offset",
        offset_random: "OffsetRandom",
        loop_start: "LoopStartDelta",
        loop_length: "LoopEndDelta",
        loop_type: "LoopType",
        loop_tune: "LoopTune",
        count: "PlayCount"
      });
      lifecycleFields = Object.freeze({
        note_selfmask: "NoteSelfMask",
        off_curve: "OffCurve",
        off_shape: "OffShape",
        rt_dead: "ReleaseDead",
        rt_decay: "ReleaseDecay",
        sustain_sw: "SustainSwitch",
        sostenuto_sw: "SostenutoSwitch",
        sustain_cc: "SustainCC",
        sostenuto_cc: "SostenutoCC",
        sustain_lo: "SustainLow",
        sostenuto_lo: "SostenutoLow",
        sw_vel: "SwitchVelocity",
        polyphony_stealing: "PolyphonyStealing"
      });
      dspFields = Object.freeze({ dsp_order: "DspOrder", drive: "Drive", bitred: "BitReduction", decim: "Decimation" });
      noiseFields = Object.freeze({
        noise_level: "NoiseLevel",
        noise_tone: "NoiseTone",
        noise_step: "NoiseStep",
        noise_stereo: "NoiseStereo",
        noise_filter: "NoiseFilter"
      });
      amplifierFields = Object.freeze({
        amp_veltrack: "VelocityTrack",
        amp_veltrack_random: "Random",
        pan_law: "PanLaw",
        phase: "PhaseInvert",
        pan_keytrack: "PanKeyTrack",
        pan_keycenter: "PanKeyCenter",
        pan_veltrack: "PanVelocityTrack",
        pan_random: "PanRandom",
        position_keycenter: "PositionKeyCenter",
        position_keytrack: "PositionKeyTrack",
        position_veltrack: "PositionVelocityTrack",
        position_random: "PositionRandom"
      });
      destination = (kind, index, property2, parent = null) => ({ kind, index, property: P[property2], parent });
    }
  });

  // js/sfz/schema.js
  function sfzMidiKey(value) {
    if (/^-?[0-9]+$/.test(value)) return Number(value);
    const match = /^([a-g])([#b]?)(-?[0-9]+)$/i.exec(value);
    if (!match) return NaN;
    const pitch = { c: 0, d: 2, e: 4, f: 5, g: 7, a: 9, b: 11 }[match[1].toLowerCase()];
    return (Number(match[3]) + 1) * 12 + pitch + (match[2] === "#" ? 1 : match[2] === "b" ? -1 : 0);
  }
  function sfzControllerOpcode(key) {
    const match = /^(.*?)([0-9]{1,3})$/.exec(key);
    return match && Object.hasOwn(SFZ_CONTROLLER_FAMILIES, match[1]) && Number(match[2]) < 128 ? { family: match[1], controller: Number(match[2]) } : null;
  }
  function sfzControllerValue(region, family, controller) {
    return region[family + controller] ?? SFZ_CONTROLLER_FAMILIES[family];
  }
  function canonicalSfzOpcode(key) {
    key = key.replace(/^set_realcc([0-9]{1,3})$/, "set_hdcc$1");
    key = key.replace(/^oscillator_mod_smoothcc([0-9]{1,3})$/, "oscillator_mod_depth_smoothcc$1");
    key = key.replace(/^(eg|lfo)0*([0-9]+)_/, (_2, prefix, index) => `${prefix}${Number(index)}_`);
    key = key.replace(/^(amp|fil|pitch)_vel2/, "$1eg_vel2");
    key = key.replace(/^((?:amp|fil|pitch)lfo_(?:depth|freq))(chanaft|polyaft)$/, "$1_$2");
    if (Object.hasOwn(SFZ_ALIASES, key)) return SFZ_ALIASES[key];
    const alias = /^(volume|pan|pitch|cutoff|resonance)_cc([0-9]{1,3})$/.exec(key);
    const gain = /^(?:gain_cc|gain_oncc)([0-9]{1,3})$/.exec(key);
    const tune = /^(?:tune_cc|tune_oncc)([0-9]{1,3})$/.exec(key);
    const start = /^start_((?:lo|hi)(?:hd)?cc)([0-9]{1,3})$/.exec(key);
    const envelope = /^(ampeg_(?:delay|start|attack|hold|decay|sustain|release))(?:_?cc|_oncc)([0-9]{1,3})$/.exec(key);
    const equalizer = /^(eq[1-3]_(?:freq|bw|gain))(?:_?cc|_oncc)([0-9]{1,3})$/.exec(key);
    const canonical = alias ? `${alias[1]}_oncc${alias[2]}` : gain ? `volume_oncc${gain[1]}` : tune ? `pitch_oncc${tune[1]}` : start ? `on_${start[1]}${start[2]}` : envelope ? `${envelope[1]}_oncc${envelope[2]}` : equalizer ? `${equalizer[1]}_oncc${equalizer[2]}` : key;
    const modifier = /^([a-z0-9_]+)_(curvecc|smoothcc|stepcc)([0-9]{1,3})$/.exec(canonical);
    if (modifier) {
      const target = modifier[1] === "tune" ? "pitch" : modifier[1];
      if (Object.hasOwn(SFZ_MODULATION_TARGETS, target)) return `${target}_${modifier[2]}${Number(modifier[3])}`;
    }
    const generic = /^(.*?)(?:_oncc|_cc|cc)([0-9]{1,3})$/.exec(canonical);
    if (generic && sfzModulationTarget(generic[1])) return `${generic[1]}_oncc${Number(generic[2])}`;
    const controller = sfzControllerOpcode(canonical);
    return controller ? `${controller.family}${controller.controller}` : canonical;
  }
  var SFZ_EXTRA_DEFAULTS, SFZ_CONTROLLER_FAMILIES, SFZ_MODULATION_TARGETS, SFZ_MODULATION_DEPTH_RANGES, SFZ_EXTRA_FIELDS, SFZ_ENUMS, SFZ_ALIASES;
  var init_schema = __esm({
    "js/sfz/schema.js"() {
      init_modulation_schema();
      SFZ_EXTRA_DEFAULTS = Object.freeze({
        trigger: 0,
        lochan: 1,
        hichan: 16,
        lobend: -8192,
        hibend: 8192,
        lochanaft: 0,
        hichanaft: 127,
        lopolyaft: 0,
        hipolyaft: 127,
        loprog: 0,
        hiprog: 127,
        sw_lokey: -1,
        sw_hikey: -1,
        sw_last: -1,
        sw_lolast: -1,
        sw_hilast: -1,
        sw_down: -1,
        sw_up: -1,
        sw_previous: -1,
        sw_default: -1,
        group: 0,
        off_by: 0,
        off_mode: 0,
        off_time: 6e-3,
        polyphony: 0,
        note_polyphony: 0,
        bend_up: 200,
        bend_down: -200,
        cutoff: 2e4,
        resonance: 0,
        fil_type: 0,
        ampeg_delay: 0,
        ampeg_start: 0,
        amp_keytrack: 0,
        amp_keycenter: 60,
        amp_random: 0,
        pitch_veltrack: 0,
        pitch_random: 0,
        delay: 0,
        delay_random: 0,
        pitcheg_delay: 0,
        pitcheg_start: 0,
        pitcheg_attack: 0,
        pitcheg_hold: 0,
        pitcheg_decay: 0,
        pitcheg_sustain: 0,
        pitcheg_release: 0,
        pitcheg_depth: 0,
        fileg_delay: 0,
        fileg_start: 0,
        fileg_attack: 0,
        fileg_hold: 0,
        fileg_decay: 0,
        fileg_sustain: 0,
        fileg_release: 0,
        fileg_depth: 0,
        amplfo_delay: 0,
        amplfo_fade: 0,
        amplfo_freq: 0,
        amplfo_depth: 0,
        pitchlfo_delay: 0,
        pitchlfo_fade: 0,
        pitchlfo_freq: 0,
        pitchlfo_depth: 0,
        fillfo_delay: 0,
        fillfo_fade: 0,
        fillfo_freq: 0,
        fillfo_depth: 0,
        direction: 0,
        loop_count: -1,
        loop_crossfade: 0,
        ampeg_dynamic: 0,
        eq1_freq: 50,
        eq1_bw: 1,
        eq1_gain: 0,
        eq2_freq: 500,
        eq2_bw: 1,
        eq2_gain: 0,
        eq3_freq: 5e3,
        eq3_bw: 1,
        eq3_gain: 0
      });
      SFZ_CONTROLLER_FAMILIES = Object.freeze({
        locc: 0,
        hicc: 127,
        set_cc: -1,
        volume_oncc: 0,
        pan_oncc: 0,
        pitch_oncc: 0,
        cutoff_oncc: 0,
        resonance_oncc: 0,
        on_locc: -1,
        on_hicc: -1,
        ampeg_delay_oncc: 0,
        ampeg_start_oncc: 0,
        ampeg_attack_oncc: 0,
        ampeg_hold_oncc: 0,
        ampeg_decay_oncc: 0,
        ampeg_sustain_oncc: 0,
        ampeg_release_oncc: 0,
        eq1_freq_oncc: 0,
        eq1_bw_oncc: 0,
        eq1_gain_oncc: 0,
        eq2_freq_oncc: 0,
        eq2_bw_oncc: 0,
        eq2_gain_oncc: 0,
        eq3_freq_oncc: 0,
        eq3_bw_oncc: 0,
        eq3_gain_oncc: 0
      });
      SFZ_MODULATION_TARGETS = Object.freeze(Object.fromEntries(
        Object.keys(SFZ_CONTROLLER_FAMILIES).flatMap((family, id) => family.endsWith("_oncc") ? [[family.slice(0, -5), id]] : [])
      ));
      SFZ_MODULATION_DEPTH_RANGES = Object.freeze(Object.fromEntries(
        Object.entries(SFZ_MODULATION_TARGETS).map(([target, id]) => [id, Object.freeze(
          target.startsWith("ampeg_") ? [-100, 100] : /^eq[1-3]_freq$/.test(target) ? [-3e4, 3e4] : /^eq[1-3]_bw$/.test(target) ? [-4, 4] : /^eq[1-3]_gain$/.test(target) ? [-96, 24] : [-12e3, 12e3]
        )])
      ));
      SFZ_EXTRA_FIELDS = Object.freeze([
        ...Object.keys(SFZ_EXTRA_DEFAULTS),
        ...Object.keys(SFZ_CONTROLLER_FAMILIES).flatMap((prefix) => Array.from({ length: 128 }, (_2, cc) => prefix + cc))
      ]);
      SFZ_ENUMS = Object.freeze({
        trigger: { attack: 0, release: 1, release_key: 2, first: 3, legato: 4 },
        off_mode: { fast: 0, normal: 1, time: 2 },
        fil_type: SFZ_MOD_FILTER_TYPES,
        direction: { forward: 0, reverse: 1 }
      });
      SFZ_ALIASES = Object.freeze({
        loopcount: "loop_count",
        loopend: "loop_end",
        loopmode: "loop_mode",
        loopstart: "loop_start",
        looptype: "loop_type",
        looptune: "loop_tune",
        polyphony_group: "group",
        offby: "off_by",
        offmode: "off_mode",
        gain_random: "amp_random",
        bendup: "bend_up",
        benddown: "bend_down",
        bendstep: "bend_step",
        pitch: "tune",
        filtype: "fil_type",
        tune_keytrack: "pitch_keytrack",
        tune_random: "pitch_random",
        tune_veltrack: "pitch_veltrack",
        amp_attack: "ampeg_attack",
        amp_decay: "ampeg_decay",
        amp_delay: "ampeg_delay",
        amp_hold: "ampeg_hold",
        amp_release: "ampeg_release",
        amp_sustain: "ampeg_sustain",
        fil_attack: "fileg_attack",
        fil_decay: "fileg_decay",
        fil_delay: "fileg_delay",
        fil_depth: "fileg_depth",
        fil_hold: "fileg_hold",
        fil_release: "fileg_release",
        fil_sustain: "fileg_sustain",
        pitch_attack: "pitcheg_attack",
        pitch_decay: "pitcheg_decay",
        pitch_delay: "pitcheg_delay",
        pitch_depth: "pitcheg_depth",
        pitch_hold: "pitcheg_hold",
        pitch_release: "pitcheg_release",
        pitch_sustain: "pitcheg_sustain"
      });
    }
  });

  // js/sfz/limits.js
  function normalizeSfzSizeLimitMiB(value) {
    return SFZ_SIZE_LIMIT_MIB_OPTIONS.includes(value) ? value : SFZ_DEFAULT_MAX_BYTES / (1024 * 1024);
  }
  function getSfzMaxBytes(value) {
    return normalizeSfzSizeLimitMiB(value) * 1024 * 1024;
  }
  function requireSfzMaxBytes(value) {
    if (!Number.isSafeInteger(value) || value < 1 || value > SFZ_MAX_SUPPORTED_BYTES) {
      throw new RangeError("Invalid SFZ size limit.");
    }
    return value;
  }
  var SFZ_SIZE_LIMIT_MIB_OPTIONS, SFZ_DEFAULT_MAX_BYTES, SFZ_MAX_SUPPORTED_BYTES;
  var init_limits = __esm({
    "js/sfz/limits.js"() {
      SFZ_SIZE_LIMIT_MIB_OPTIONS = Object.freeze([64, 128, 256, 512, 1024]);
      SFZ_DEFAULT_MAX_BYTES = 256 * 1024 * 1024;
      SFZ_MAX_SUPPORTED_BYTES = 1024 * 1024 * 1024;
    }
  });

  // js/sfz/generators.js
  function isSfzGenerator(sample) {
    return Object.hasOwn(SFZ_GENERATOR_WAVES, sample);
  }
  function sfzGeneratorMetadata(sample) {
    return {
      size: 0,
      frames: sample === "*noise" || sample === "*silence" ? 2 : PERIOD_FRAMES,
      channels: 1,
      sampleRate: PERIOD_RATE
    };
  }
  function createSfzGeneratorSample(sample) {
    const { frames, sampleRate } = sfzGeneratorMetadata(sample);
    const pcm = new Float32Array(frames);
    for (let frame = 0; frame < frames; frame++) {
      const phase = frame / frames;
      if (sample === "*sine") pcm[frame] = Math.sin(2 * Math.PI * phase);
      else if (sample === "*saw") pcm[frame] = 2 * phase - 1;
      else if (sample === "*square") pcm[frame] = phase < 0.5 ? 1 : -1;
      else if (sample === "*triangle" || sample === "*tri") pcm[frame] = 1 - 4 * (phase < 0.5 ? 0.5 - phase : phase - 0.5);
    }
    return { sampleRate, channels: [pcm] };
  }
  var SFZ_GENERATOR_WAVES, PERIOD_FRAMES, PERIOD_RATE;
  var init_generators = __esm({
    "js/sfz/generators.js"() {
      SFZ_GENERATOR_WAVES = Object.freeze({
        "*sine": 1,
        "*saw": 2,
        "*square": 3,
        "*triangle": 4,
        "*tri": 4,
        "*noise": 5,
        "*silence": 6
      });
      PERIOD_FRAMES = 2048;
      PERIOD_RATE = Math.round(440 * Math.pow(2, (60 - 69) / 12) * PERIOD_FRAMES);
    }
  });

  // js/sfz/modulation.js
  function number(value) {
    return typeof value === "string" && !value.trim() ? NaN : Number(value);
  }
  function finiteFloat(value) {
    return Number.isFinite(value) && Number.isFinite(Math.fround(value));
  }
  function compileCurves(headers, diagnostics) {
    const curves = /* @__PURE__ */ new Map();
    for (const header of headers) {
      if (header.name !== "curve") continue;
      const id = number(header.opcodes.curve_index);
      if (!Number.isInteger(id) || id < 7 || id > 254) {
        diagnostics.push({ code: "curve-index", opcode: "curve_index" });
        continue;
      }
      if (curves.has(id)) {
        diagnostics.push({ code: "duplicate-curve", curve: id });
        continue;
      }
      const points = /* @__PURE__ */ new Map([[0, 0], [127, 1]]);
      let invalid2 = false;
      for (const [key, raw] of Object.entries(header.opcodes)) {
        if (key === "curve_index") continue;
        const match = /^v([0-9]{3})$/.exec(key);
        const value = number(raw);
        if (!match || Number(match[1]) > 127 || !finiteFloat(value)) {
          diagnostics.push({ code: "curve-point", curve: id, opcode: key });
          invalid2 = true;
        } else points.set(Number(match[1]), value);
      }
      if (invalid2) continue;
      const sorted = [...points].sort((a, b2) => a[0] - b2[0]);
      const values = new Float32Array(128);
      for (let index = 1; index < sorted.length; index++) {
        const [start, from] = sorted[index - 1], [end, to] = sorted[index];
        for (let point = start; point <= end; point++) {
          const fraction = (point - start) / (end - start);
          values[point] = from * (1 - fraction) + to * fraction;
        }
      }
      curves.set(id, values);
    }
    return [...curves].sort((a, b2) => a[0] - b2[0]).map(([id, values]) => ({ id, values }));
  }
  function variableOpcode(key) {
    const match = /^var([0-9]+)_(.+)$/.exec(key);
    if (!match) return null;
    const index = Number(match[1]), field = match[2];
    if (field === "mod") return { index, modifier: "mode" };
    const input = /^(oncc|curvecc)([0-9]{1,3})$/.exec(field);
    if (input) return { index, modifier: input[1] === "oncc" ? "depth" : "curve", controller: Number(input[2]) };
    const destination2 = sfzModulationTarget(field);
    return destination2 && destination2.source === null && (destination2.target.kind === SFZ_MOD_KINDS.Region || destination2.target.kind >= SFZ_MOD_KINDS.Filter) ? { index, modifier: "target", destination: destination2 } : null;
  }
  function opcodeFor(rawKey) {
    let key = canonicalSfzOpcode(rawKey), controller = null, modifier = "depth", note = null;
    const variable = variableOpcode(key);
    if (variable?.modifier === "target") return {
      ...variable.destination,
      source: { kind: SFZ_MOD_KINDS.Variable, index: variable.index },
      controller: null,
      note: null,
      modifier: "depth",
      key
    };
    if (key.endsWith("_mod")) {
      const resolved2 = sfzModulationTarget(key.slice(0, -4));
      return resolved2 && resolved2.source === null ? { ...resolved2, controller: null, note: null, modifier: "mode", key } : null;
    }
    const panCurve = /^(eg[0-9]+_pan)_curve$/.exec(key);
    if (panCurve) {
      key = panCurve[1];
      modifier = "curve";
    }
    const cc = /^(.*?)_(oncc|curvecc|smoothcc|stepcc|icurvecc)([0-9]{1,3})$/.exec(key);
    if (cc) {
      key = cc[1];
      controller = Number(cc[3]);
      modifier = cc[2] === "oncc" ? "depth" : cc[2].slice(0, -2);
    } else {
      const pressure = /^(.*?)_(chanaft|polyaft)$/.exec(key);
      if (pressure) {
        key = pressure[1];
        controller = pressure[2] === "chanaft" ? 129 : 130;
      }
      const velocity = /^(ampeg|fileg|pitcheg|eq[1-3])_vel2(.+)$/.exec(key);
      if (velocity) {
        key = `${velocity[1]}_${velocity[2]}`;
        note = 1;
      }
    }
    const resolved = sfzModulationTarget(key);
    return resolved ? { ...resolved, controller, note, modifier, key } : null;
  }
  function isSfzModulationOpcode(key) {
    return variableOpcode(key) !== null || opcodeFor(key) !== null || Object.hasOwn(pitchFields, key) || Object.hasOwn(oscillatorFields, key) || key === "bend_step" || scopeTunes.has(key) || scopeGains.test(key) || /^xf_(key|vel|cc)curve$/.test(key);
  }
  function compileRegion(region, regionIndex, diagnostics, offsets, initialControllers) {
    const instances = [], instanceIds = /* @__PURE__ */ new Map(), parameters = [], routes = /* @__PURE__ */ new Map(), modes = /* @__PURE__ */ new Map();
    const error2 = (code, opcode) => diagnostics.push({ code, region: regionIndex, opcode });
    function instance(kind, index = 0, parent = null) {
      if (!Number.isInteger(index) || index < 0 || index > 4294967295 || [SFZ_MOD_KINDS.FlexEG, SFZ_MOD_KINDS.LFO].includes(kind) && index === 0 || kind === SFZ_MOD_KINDS.Variable && (index === 0 || index > 65535) || kind === SFZ_MOD_KINDS.LFOSubosc && (index < 2 || index > 8)) {
        throw new Error("instance-index");
      }
      if ([SFZ_MOD_KINDS.InitialController, SFZ_MOD_KINDS.ReverseController, SFZ_MOD_KINDS.ControllerCondition, SFZ_MOD_KINDS.ControllerStart, SFZ_MOD_KINDS.ControllerStop].includes(kind) && index > 127) throw new Error("instance-index");
      if (kind === SFZ_MOD_KINDS.VelocityCurvePoint && index > 127 || kind === SFZ_MOD_KINDS.Crossfade && index > 129) throw new Error("instance-index");
      if (kind === SFZ_MOD_KINDS.Equalizer && (index < 1 || index > 3)) throw new Error("instance-index");
      const parentId = parent ? instance(parent.kind, parent.index) : 4294967295;
      const key = `${kind}:${index}:${parentId}`;
      if (!instanceIds.has(key)) {
        if (instances.length >= 65536) throw new Error("instance-count");
        const id = instances.length;
        instanceIds.set(key, id);
        instances.push({ kind, index, parent: parentId, parameters: /* @__PURE__ */ new Map() });
        for (const spec of SFZ_MOD_PROPERTIES) if (spec.kind === kind) instances[id].parameters.set(spec.id, spec.default);
      }
      return instanceIds.get(key);
    }
    instance(SFZ_MOD_KINDS.Region);
    instance(SFZ_MOD_KINDS.AmpEG);
    for (const [cc, value] of initialControllers) {
      instances[instance(SFZ_MOD_KINDS.InitialController, cc)].parameters.set(SFZ_MOD_PROPERTY_IDS.InitialValue, value);
    }
    const root = instances[0].parameters;
    const rawRegion = region.opcodes || {};
    root.set(SFZ_MOD_PROPERTY_IDS.NoteEnabled, Number(rawRegion.lokey) === -1 && Number(rawRegion.hikey) === -1 ? 0 : 1);
    root.set(SFZ_MOD_PROPERTY_IDS.SilentAction, Number(rawRegion.end) === -1 ? 1 : 0);
    if (Object.hasOwn(SFZ_GENERATOR_WAVES, region.sample)) {
      const oscillator = instances[instance(SFZ_MOD_KINDS.Oscillator)].parameters;
      oscillator.set(SFZ_MOD_PROPERTY_IDS.Enabled, 1);
      oscillator.set(SFZ_MOD_PROPERTY_IDS.SourceWave, SFZ_GENERATOR_WAVES[region.sample]);
    }
    root.set(SFZ_MOD_PROPERTY_IDS.NoteOffset, offsets.note_offset + 12 * offsets.octave_offset);
    root.set(SFZ_MOD_PROPERTY_IDS.SwitchOffset, offsets.sw_note_offset + 12 * offsets.sw_octave_offset);
    let scopeTune = 0, scopeVolume = 0, scopeAmplitude = 100;
    const crossfadeCurves = /* @__PURE__ */ new Map();
    for (const [rawKey, raw] of Object.entries(region.opcodes || {})) {
      const canonical = canonicalSfzOpcode(rawKey);
      const variable = variableOpcode(canonical);
      if (variable && variable.modifier !== "target") {
        try {
          const id = instance(SFZ_MOD_KINDS.Variable, variable.index);
          if (variable.modifier === "mode") {
            if (!["add", "mult"].includes(raw)) error2("variable-mode", rawKey);
            else modes.set(`${id}:${SFZ_MOD_PROPERTY_IDS.VariableValue}`, raw === "mult");
            continue;
          }
          if (!(variable.controller <= 127 || virtualControllers.has(variable.controller))) {
            error2("source-unavailable", rawKey);
            continue;
          }
          const value2 = number(raw), curve = variable.modifier === "curve";
          if (!finiteFloat(value2) || value2 < 0 || value2 > (curve ? 254 : 1) || curve && !Number.isInteger(value2)) {
            error2("variable-input", rawKey);
            continue;
          }
          const sourceA = SFZ_MOD_SOURCES.Controller | variable.controller, routeKey = `${id}:${SFZ_MOD_PROPERTY_IDS.VariableValue}:${sourceA}:0`;
          const route = routes.get(routeKey) || {
            instance: id,
            property: SFZ_MOD_PROPERTY_IDS.VariableValue,
            sourceA,
            sourceB: SFZ_MOD_SOURCES.Constant,
            depth: 0,
            curveA: 0,
            curveB: 0,
            smooth: 0,
            step: 0,
            flags: 0,
            transform: 0
          };
          route[curve ? "curveA" : "depth"] = value2;
          routes.set(routeKey, route);
        } catch (cause) {
          error2(cause.message, rawKey);
        }
        continue;
      }
      const crossfadeCurve = /^xf_(key|vel|cc)curve$/.exec(canonical);
      if (crossfadeCurve) {
        if (!["gain", "power"].includes(raw)) error2("crossfade-curve", rawKey);
        else crossfadeCurves.set(crossfadeCurve[1], raw === "power" ? 1 : 0);
        continue;
      }
      if (canonical === "loop_count" && number(raw) > 16777216) {
        const value2 = number(raw);
        if (!Number.isInteger(value2) || value2 > 4294967295) error2("loop-count", rawKey);
        else {
          const playback = instances[instance(SFZ_MOD_KINDS.SamplePlayback)].parameters;
          playback.set(SFZ_MOD_PROPERTY_IDS.LoopRepeatLimit, value2);
          playback.set(SFZ_MOD_PROPERTY_IDS.LoopRepeatLimited, 1);
        }
        continue;
      }
      const scopeGain = scopeGains.exec(canonical);
      if (scopeGain) {
        const value2 = number(raw), amplitude = scopeGain[2] === "amplitude";
        if (!finiteFloat(value2) || value2 < (amplitude ? 0 : -144) || value2 > (amplitude ? 100 : 6)) error2("scope-gain", rawKey);
        else if (amplitude) scopeAmplitude *= value2 * 0.01;
        else scopeVolume += value2;
        continue;
      }
      if (Object.hasOwn(oscillatorFields, canonical)) {
        const property2 = oscillatorFields[canonical], spec2 = propertySpecs.get(`${SFZ_MOD_KINDS.Oscillator}:${property2}`);
        const value2 = canonical === "oscillator" ? { on: 1, off: 0 }[raw] : number(raw);
        if (!finiteFloat(value2) || value2 < spec2.min || value2 > spec2.max || spec2.integer && !Number.isInteger(value2)) error2("oscillator-value", rawKey);
        else instances[instance(SFZ_MOD_KINDS.Oscillator)].parameters.set(property2, value2);
        continue;
      }
      if (Object.hasOwn(SFZ_PITCH_CONTROL_RANGES, canonical)) {
        error2("pitch-control-scope", rawKey);
        continue;
      }
      if (Object.hasOwn(pitchFields, canonical) || canonical === "bend_step" || scopeTunes.has(canonical)) {
        const value2 = number(raw);
        const property2 = canonical === "bend_step" ? SFZ_MOD_PROPERTY_IDS.BendStepUp : pitchFields[canonical];
        const spec2 = propertySpecs.get(`${SFZ_MOD_KINDS.Region}:${property2}`);
        if (scopeTunes.has(canonical)) {
          if (!Number.isInteger(value2) || Math.abs(value2) > 9600) error2("pitch-value", rawKey);
          else scopeTune += value2;
        } else if (!finiteFloat(value2) || value2 < spec2.min || value2 > spec2.max || spec2.integer && !Number.isInteger(value2)) {
          error2("pitch-value", rawKey);
        } else {
          root.set(property2, value2);
          if (canonical === "bend_step") root.set(SFZ_MOD_PROPERTY_IDS.BendStepDown, value2);
        }
        continue;
      }
      const opcode = opcodeFor(rawKey);
      if (!opcode) {
        if (/_((?:on|curve|smooth|step|icurve)cc)[0-9]+$/.test(rawKey) || /^(?:eg|lfo)[0-9]+_/.test(rawKey)) error2("target-unavailable", rawKey);
        continue;
      }
      const { target, source, controller, note, modifier, multiply } = opcode;
      if (target.kind === SFZ_MOD_KINDS.Amplifier && target.property === SFZ_MOD_PROPERTY_IDS.Random && (source !== null || controller !== null || note !== null || modifier === "mode")) {
        error2("static-setting-modulation", rawKey);
        continue;
      }
      if (modifier === "mode") {
        if (!["add", "mult"].includes(raw)) error2("route-value", rawKey);
        else {
          try {
            modes.set(`${instance(target.kind, target.index, target.parent)}:${target.property}`, raw === "mult");
          } catch (cause) {
            error2(cause.message, rawKey);
          }
        }
        continue;
      }
      if (controller !== null && !(controller <= 127 || virtualControllers.has(controller))) {
        error2("source-unavailable", rawKey);
        continue;
      }
      const spec = propertySpecs.get(`${target.kind}:${target.property}`);
      const routed = source !== null || controller !== null || note !== null;
      if (!routed && (opcode.key === "offset_mode" && raw === "samples" || (opcode.key === "delay_samples" || opcode.key === "amp_veltrack_random") && number(raw) === 0)) continue;
      const peakEq = /^eq([1-3])_type$/.exec(opcode.key);
      if (!routed && peakEq && raw === "peak" && !Object.keys(region.opcodes).some((key) => key.startsWith(`eq${peakEq[1]}_`) && !/^eq[1-3]_(type|freq|bw|gain)$/.test(key))) continue;
      if ((target.kind >= SFZ_MOD_KINDS.VelocityCurvePoint && target.kind <= SFZ_MOD_KINDS.Equalizer || target.property >= SFZ_MOD_PROPERTY_IDS.PositionKeyCenter && target.property <= SFZ_MOD_PROPERTY_IDS.PositionRandom) && routed) {
        error2("static-setting-modulation", rawKey);
        continue;
      }
      if (!routed && target.kind === SFZ_MOD_KINDS.SamplePlayback && ["offset", "loop_start", "delay"].includes(opcode.key)) continue;
      const adjusted = !routed && /^ampeg_(attack|hold|decay|release)$/.test(opcode.key) && region[opcode.key] !== void 0;
      let value = adjusted ? region[opcode.key] : !routed && target.property === SFZ_MOD_PROPERTY_IDS.FilterType ? SFZ_MOD_FILTER_TYPES[raw] : !routed && target.property === SFZ_MOD_PROPERTY_IDS.FilterMode ? { cents: 0, hz: 1 }[raw] : !routed && target.property === SFZ_MOD_PROPERTY_IDS.EqType ? { peak: 0, lshelf: 1, hshelf: 2 }[raw] : !routed && target.property === SFZ_MOD_PROPERTY_IDS.NoiseFilter ? { off: 0, on: 1 }[raw] ?? SFZ_MOD_FILTER_TYPES[raw] : !routed && (target.property === SFZ_MOD_PROPERTY_IDS.PanKeyCenter || target.property === SFZ_MOD_PROPERTY_IDS.PositionKeyCenter || target.kind === SFZ_MOD_KINDS.Crossfade && target.index === 0) ? sfzMidiKey(raw) : !routed && Object.hasOwn(lifecycleEnums, opcode.key) ? lifecycleEnums[opcode.key][raw] : number(raw);
      if (!routed && /^stop_(lo|hi)cc[0-9]+$/.test(opcode.key)) {
        if (!Number.isInteger(value) || value < -1 || value > 127) {
          error2("controller-condition", rawKey);
          continue;
        }
        if (value >= 0) value /= 127;
      }
      if (!routed && [SFZ_MOD_KINDS.ControllerStart, SFZ_MOD_KINDS.ControllerStop].includes(target.kind) && value < 0 && value !== -1) {
        error2("controller-condition", rawKey);
        continue;
      }
      if (!routed && target.property === SFZ_MOD_PROPERTY_IDS.SampleQuality && value === 0) {
        error2("sample-quality", rawKey);
        continue;
      }
      if (!finiteFloat(value) || !routed && (value < spec.min || value > spec.max || spec.integer && !Number.isInteger(value)) || modifier !== "depth" && value < 0 || ["curve", "icurve"].includes(modifier) && !Number.isInteger(value) || modifier === "curve" && value > 254 || modifier === "icurve" && value > 1) {
        error2("route-value", rawKey);
        continue;
      }
      if (target.property === SFZ_MOD_PROPERTY_IDS.Wave && [8, 9, 10, 11].includes(value) && !routed) {
        error2("wave-unverified", rawKey);
        continue;
      }
      if (target.property === SFZ_MOD_PROPERTY_IDS.OffCurve && ![-2, -1, 0, 1, 2, 10].includes(value)) {
        error2("off-curve", rawKey);
        continue;
      }
      const integerDepth = target.kind === SFZ_MOD_KINDS.SamplePlayback && controller !== null && source === null && note === null && (target.property === SFZ_MOD_PROPERTY_IDS.DelaySamples || target.property === SFZ_MOD_PROPERTY_IDS.Offset && region.opcodes.offset_mode !== "percent");
      if (integerDepth && modifier === "depth" && (!Number.isInteger(value) || Math.abs(value) > 4294967296)) {
        error2("route-value", rawKey);
        continue;
      }
      if (!routed && spec.integer && spec.storage === SFZ_MOD_STORAGE_TYPES.Float && Math.fround(value) !== value) {
        error2("integer-precision", rawKey);
        continue;
      }
      try {
        const targetId = instance(target.kind, target.index, target.parent);
        if (target.kind === SFZ_MOD_KINDS.Filter) instances[targetId].parameters.set(SFZ_MOD_PROPERTY_IDS.Enabled, 1);
        if (!routed) {
          instances[targetId].parameters.set(target.property, value);
          if (target.kind === SFZ_MOD_KINDS.LFO && target.property === SFZ_MOD_PROPERTY_IDS.Steps) instances[targetId].parameters.set(SFZ_MOD_PROPERTY_IDS.Wave, 13);
          if (target.kind === SFZ_MOD_KINDS.LFO && target.property === SFZ_MOD_PROPERTY_IDS.Wave && value !== 13) instances[targetId].parameters.set(SFZ_MOD_PROPERTY_IDS.Steps, 0);
        } else {
          const sourceA = source ? (source.kind === SFZ_MOD_KINDS.Variable ? SFZ_MOD_SOURCES.Variable : source.kind === SFZ_MOD_KINDS.FlexEG ? SFZ_MOD_SOURCES.Envelope : SFZ_MOD_SOURCES.LFO) | instance(source.kind, source.index) : note !== null ? SFZ_MOD_SOURCES.Note | note : SFZ_MOD_SOURCES.Controller | controller;
          const sourceB = source && controller !== null ? SFZ_MOD_SOURCES.Controller | controller : SFZ_MOD_SOURCES.Constant;
          const routeKey = `${targetId}:${target.property}:${sourceA}:${sourceB}`;
          const route = routes.get(routeKey) || {
            instance: targetId,
            property: target.property,
            sourceA,
            sourceB,
            depth: 0,
            curveA: 0,
            curveB: 0,
            smooth: 0,
            step: 0,
            flags: multiply ? 1 : 0,
            transform: 0
          };
          if (integerDepth) route.flags |= SFZ_MOD_ROUTE_FLAGS.IntegerDepth;
          if (modifier === "curve") route[source && controller !== null ? "curveB" : "curveA"] = value;
          else if (modifier === "icurve") {
            const flag = source && controller !== null ? 4 : 2;
            route.flags = value ? route.flags & ~flag : route.flags | flag;
          } else route[modifier] = value;
          routes.set(routeKey, route);
        }
      } catch (cause) {
        error2(cause.message, rawKey);
      }
    }
    root.set(SFZ_MOD_PROPERTY_IDS.ScopeTune, scopeTune);
    root.set(SFZ_MOD_PROPERTY_IDS.ScopeVolume, scopeVolume);
    root.set(SFZ_MOD_PROPERTY_IDS.ScopeAmplitude, scopeAmplitude);
    if (Object.hasOwn(SFZ_GENERATOR_WAVES, region.sample)) instances[instance(SFZ_MOD_KINDS.Oscillator)].parameters.set(SFZ_MOD_PROPERTY_IDS.Enabled, 1);
    for (const route of routes.values()) {
      const mode = modes.get(`${route.instance}:${route.property}`);
      if (mode !== void 0) route.flags = mode ? route.flags | 1 : route.flags & ~1;
    }
    for (const [id, entry] of instances.entries()) if (entry.kind === SFZ_MOD_KINDS.Variable)
      entry.parameters.set(SFZ_MOD_PROPERTY_IDS.VariableValue, modes.get(`${id}:${SFZ_MOD_PROPERTY_IDS.VariableValue}`) ? 1 : 0);
    const direct = (sourceId, targetId, property2, depth, multiply = false) => routes.set(`direct:${sourceId}:${property2}`, {
      instance: targetId,
      property: property2,
      sourceA: (instances[sourceId].kind <= SFZ_MOD_KINDS.EGStage ? SFZ_MOD_SOURCES.Envelope : SFZ_MOD_SOURCES.LFO) | sourceId,
      sourceB: SFZ_MOD_SOURCES.Constant,
      depth,
      curveA: 0,
      curveB: 0,
      smooth: 0,
      step: 0,
      flags: multiply ? 1 : 0,
      transform: 0
    });
    const replacement = instances.findIndex((entry) => entry.kind === SFZ_MOD_KINDS.FlexEG && entry.parameters.get(SFZ_MOD_PROPERTY_IDS.AmpEnvelope) === 1);
    direct(replacement < 0 ? instance(SFZ_MOD_KINDS.AmpEG) : replacement, instance(SFZ_MOD_KINDS.Region), SFZ_MOD_PROPERTY_IDS.Amplitude, 100, true);
    for (let id = 0; id < instances.length; id++) {
      const kind = instances[id].kind;
      if ([SFZ_MOD_KINDS.FilterEG, SFZ_MOD_KINDS.FilterLFO].includes(kind)) {
        const filter = instance(SFZ_MOD_KINDS.Filter, 1);
        instances[filter].parameters.set(SFZ_MOD_PROPERTY_IDS.Enabled, 1);
        direct(id, filter, SFZ_MOD_PROPERTY_IDS.Cutoff, 1);
      } else if ([SFZ_MOD_KINDS.PitchEG, SFZ_MOD_KINDS.PitchLFO].includes(kind)) direct(id, instance(SFZ_MOD_KINDS.Region), SFZ_MOD_PROPERTY_IDS.Pitch, 1);
      else if (kind === SFZ_MOD_KINDS.AmpLFO) direct(id, instance(SFZ_MOD_KINDS.Region), SFZ_MOD_PROPERTY_IDS.Volume, 1);
    }
    for (let id = 0; id < instances.length; id++) {
      const entry = instances[id];
      if (entry.kind !== SFZ_MOD_KINDS.FlexEG && entry.kind !== SFZ_MOD_KINDS.LFO) continue;
      const childKind = entry.kind === SFZ_MOD_KINDS.FlexEG ? SFZ_MOD_KINDS.EGStage : SFZ_MOD_KINDS.LFOStep;
      if (childKind === SFZ_MOD_KINDS.LFOStep && entry.parameters.get(SFZ_MOD_PROPERTY_IDS.Wave) !== 13) continue;
      const children = instances.filter((item) => item.parent === id && item.kind === childKind);
      const first = childKind === SFZ_MOD_KINDS.EGStage ? 0 : 1;
      const count = Math.max(
        entry.parameters.get(childKind === SFZ_MOD_KINDS.EGStage ? SFZ_MOD_PROPERTY_IDS.Points : SFZ_MOD_PROPERTY_IDS.Steps),
        ...children.map((item) => item.index + (childKind === SFZ_MOD_KINDS.EGStage ? 1 : 0)),
        0
      );
      if (count > 65535) {
        error2("instance-count", "points");
        continue;
      }
      for (let point = first; point < count + first; point++) instance(childKind, point, { kind: entry.kind, index: entry.index });
      entry.parameters.set(childKind === SFZ_MOD_KINDS.EGStage ? SFZ_MOD_PROPERTY_IDS.Points : SFZ_MOD_PROPERTY_IDS.Steps, count);
      if (childKind === SFZ_MOD_KINDS.EGStage && entry.parameters.get(SFZ_MOD_PROPERTY_IDS.SustainPoint) < 0) entry.parameters.set(SFZ_MOD_PROPERTY_IDS.SustainPoint, count - 1);
    }
    const parameterIds = /* @__PURE__ */ new Map();
    for (const [id, entry] of instances.entries()) {
      if ([SFZ_MOD_KINDS.ControllerCondition, SFZ_MOD_KINDS.ControllerStart, SFZ_MOD_KINDS.ControllerStop].includes(entry.kind)) {
        const low = entry.parameters.get(SFZ_MOD_PROPERTY_IDS.ConditionLow), high = entry.parameters.get(SFZ_MOD_PROPERTY_IDS.ConditionHigh);
        if (low >= 0 && high >= 0 && low > high) error2("controller-condition-range", "lohdcc/hihdcc");
      }
      if (entry.kind === SFZ_MOD_KINDS.TempoCondition && entry.parameters.get(SFZ_MOD_PROPERTY_IDS.BpmLow) > entry.parameters.get(SFZ_MOD_PROPERTY_IDS.BpmHigh) || entry.kind === SFZ_MOD_KINDS.TimerCondition && entry.parameters.get(SFZ_MOD_PROPERTY_IDS.TimerLow) > entry.parameters.get(SFZ_MOD_PROPERTY_IDS.TimerHigh)) error2("transport-condition-range", "lobpm/lotimer");
      if (entry.kind === SFZ_MOD_KINDS.Crossfade) {
        const curve = crossfadeCurves.get(entry.index === 0 ? "key" : entry.index === 1 ? "vel" : "cc");
        if (curve !== void 0) entry.parameters.set(SFZ_MOD_PROPERTY_IDS.Curve, curve);
        if (entry.parameters.get(SFZ_MOD_PROPERTY_IDS.InLow) > entry.parameters.get(SFZ_MOD_PROPERTY_IDS.InHigh) || entry.parameters.get(SFZ_MOD_PROPERTY_IDS.OutLow) > entry.parameters.get(SFZ_MOD_PROPERTY_IDS.OutHigh)) error2("crossfade-range", "xfin/xfout");
      }
      if (entry.kind === SFZ_MOD_KINDS.ReverseController && entry.parameters.get(SFZ_MOD_PROPERTY_IDS.ReverseLow) > entry.parameters.get(SFZ_MOD_PROPERTY_IDS.ReverseHigh)) error2("reverse-range", "reverse_locc");
      entry.firstParameter = parameters.length;
      for (const [property2, value] of [...entry.parameters].sort((a, b2) => a[0] - b2[0])) {
        parameterIds.set(`${id}:${property2}`, parameters.length);
        parameters.push({ instance: id, property: property2, value, combine: 0 });
      }
      entry.parameterCount = parameters.length - entry.firstParameter;
      delete entry.parameters;
    }
    const orderedRoutes = [], variableInputs = /* @__PURE__ */ new Map();
    for (const route of routes.values()) {
      if (instances[route.instance].kind === SFZ_MOD_KINDS.Variable && route.property === SFZ_MOD_PROPERTY_IDS.VariableValue) {
        if (!variableInputs.has(route.instance)) variableInputs.set(route.instance, []);
        variableInputs.get(route.instance).push(route);
      } else orderedRoutes.push(route);
    }
    for (const group of variableInputs.values()) orderedRoutes.push(...group);
    return { instances, parameters, routes: orderedRoutes.map((route) => ({
      ...route,
      target: parameterIds.get(`${route.instance}:${route.property}`)
    })) };
  }
  function compileSfzModulation(regions, headers = []) {
    const diagnostics = [], curves = compileCurves(headers, diagnostics);
    const initialControllers = /* @__PURE__ */ new Map();
    const offsets = Object.fromEntries(Object.keys(SFZ_PITCH_CONTROL_RANGES).map((key) => [key, 0]));
    for (const header of headers) for (const [key, raw] of Object.entries(header.opcodes)) {
      if (variableOpcode(key) && !["global", "master", "group", "region"].includes(header.name))
        diagnostics.push({ code: "variable-region-scope", opcode: key });
      const initialization = /^set_(hdcc|cc)([0-9]{1,3})$/.exec(key);
      if (initialization) {
        const cc = Number(initialization[2]);
        if (initialization[1] === "cc") initialControllers.delete(cc);
        else if (header.name === "control" && cc < 128 && Number.isFinite(Number(raw)) && Number(raw) >= 0 && Number(raw) <= 1) initialControllers.set(cc, Number(raw));
        else diagnostics.push({ code: "controller-initialization", opcode: key });
      }
      if ([SFZ_MOD_KINDS.SamplePlayback, SFZ_MOD_KINDS.Lifecycle, SFZ_MOD_KINDS.ReleaseDecaySegment].includes(opcodeFor(key)?.target.kind) && !["global", "master", "group", "region"].includes(header.name)) {
        diagnostics.push({ code: "playback-region-scope", opcode: key });
      }
      if ((Object.hasOwn(oscillatorFields, key) || opcodeFor(key)?.target.kind === SFZ_MOD_KINDS.Oscillator) && !["global", "master", "group", "region"].includes(header.name)) {
        diagnostics.push({ code: "oscillator-scope", opcode: key });
      }
      if ((Object.hasOwn(pitchFields, key) || key === "bend_step" || scopeTunes.has(key) || scopeGains.test(key)) && !["global", "master", "group", "region"].includes(header.name)) {
        diagnostics.push({ code: "pitch-region-scope", opcode: key });
      }
      if (!Object.hasOwn(SFZ_PITCH_CONTROL_RANGES, key)) continue;
      const value = number(raw);
      if (header.name !== "control") diagnostics.push({ code: "pitch-control-scope", opcode: key });
      else if (!Number.isInteger(value) || Math.abs(value) > SFZ_PITCH_CONTROL_RANGES[key]) {
        diagnostics.push({ code: "pitch-value", opcode: key });
      } else offsets[key] = value;
    }
    const compiledRegions = regions.map((region, index) => compileRegion(region, index, diagnostics, offsets, initialControllers));
    const curveIds = new Set(curves.map((curve) => curve.id));
    for (const [region, compiled] of compiledRegions.entries()) {
      const usedCurves = [
        ...compiled.routes.flatMap((route) => [route.curveA, route.curveB]),
        ...compiled.parameters.filter((parameter) => parameter.property === SFZ_MOD_PROPERTY_IDS.Curve).map((parameter) => parameter.value)
      ];
      for (const curve of usedCurves) {
        if (curve >= 4 && curve <= 6) diagnostics.push({ code: "curve-unverified", region, curve });
        else if (curve >= 7 && !curveIds.has(curve)) diagnostics.push({ code: "curve-missing", region, curve });
      }
    }
    return { version: SFZ_MOD_LAYOUT.Version, profile: SFZ_MODULATION_PROFILE, regions: compiledRegions, curves, diagnostics };
  }
  function packSfzModulation(compiled) {
    if (compiled.version !== SFZ_MOD_LAYOUT.Version || compiled.profile !== SFZ_MODULATION_PROFILE || compiled.diagnostics.length) {
      throw new Error("SFZ modulation cannot be compiled.");
    }
    const count = (field) => compiled.regions.reduce((sum, region) => sum + region[field].length, 0);
    const regionCount = compiled.regions.length, routeCount = count("routes"), instanceCount = count("instances"), parameterCount = count("parameters");
    const directoryOffset = SFZ_MOD_LAYOUT.HeaderWords, routeOffset = directoryOffset + regionCount * SFZ_MOD_LAYOUT.DirectoryWords;
    const curveOffset = routeOffset + routeCount * SFZ_MOD_LAYOUT.RouteWords;
    const instanceOffset = curveOffset + compiled.curves.length * SFZ_MOD_LAYOUT.CurveWords;
    const parameterOffset = instanceOffset + instanceCount * SFZ_MOD_LAYOUT.InstanceWords;
    const total = parameterOffset + parameterCount * SFZ_MOD_LAYOUT.ParameterWords;
    if (!Number.isSafeInteger(total) || total > 1073741823) throw new Error("SFZ modulation is too large.");
    const buffer = new ArrayBuffer(total * 4), u = new Uint32Array(buffer), f = new Float32Array(buffer);
    u.set([
      827479123,
      SFZ_MOD_LAYOUT.Version,
      regionCount,
      routeCount,
      compiled.curves.length,
      directoryOffset,
      routeOffset,
      curveOffset,
      instanceOffset,
      instanceCount,
      parameterOffset,
      parameterCount,
      SFZ_MOD_LAYOUT.Profile,
      0
    ]);
    let routeFirst = 0, instanceFirst = 0, parameterFirst = 0;
    for (const [index, region] of compiled.regions.entries()) {
      u.set(
        [routeFirst, region.routes.length, instanceFirst, region.instances.length, parameterFirst, region.parameters.length],
        directoryOffset + index * SFZ_MOD_LAYOUT.DirectoryWords
      );
      for (const route of region.routes) {
        const at = routeOffset + routeFirst++ * SFZ_MOD_LAYOUT.RouteWords;
        u.set([route.target, route.sourceA, route.sourceB, 0, route.curveA, route.curveB, 0, 0, route.flags, route.transform], at);
        if (route.flags & SFZ_MOD_ROUTE_FLAGS.IntegerDepth) {
          const magnitude = Math.abs(route.depth);
          u[at + 3] = magnitude % 4294967296;
          if (magnitude >= 4294967296) u[at + 8] |= SFZ_MOD_ROUTE_FLAGS.IntegerHigh;
          if (route.depth < 0) u[at + 8] |= SFZ_MOD_ROUTE_FLAGS.IntegerNegative;
        } else f[at + 3] = route.depth;
        f[at + 6] = route.smooth;
        f[at + 7] = route.step;
      }
      for (const instance of region.instances) u.set([
        instance.kind,
        instance.index,
        instance.parent,
        instance.firstParameter,
        instance.parameterCount,
        0
      ], instanceOffset + instanceFirst++ * SFZ_MOD_LAYOUT.InstanceWords);
      for (const parameter of region.parameters) {
        const at = parameterOffset + parameterFirst++ * SFZ_MOD_LAYOUT.ParameterWords;
        const spec = propertySpecs.get(`${region.instances[parameter.instance].kind}:${parameter.property}`);
        u.set([parameter.instance, parameter.property, 0, parameter.combine], at);
        if (spec.storage === SFZ_MOD_STORAGE_TYPES.Float) f[at + 2] = parameter.value;
        else {
          u[at + 2] = parameter.value % 4294967296;
          u[at + 3] = Math.floor(parameter.value / 4294967296);
        }
      }
    }
    for (const [index, curve] of compiled.curves.entries()) {
      const at = curveOffset + index * SFZ_MOD_LAYOUT.CurveWords;
      u[at] = curve.id;
      f.set(curve.values, at + 1);
    }
    return new Uint8Array(buffer);
  }
  var SFZ_MODULATION_SECTION_VERSION, SFZ_MODULATION_PROFILE, SFZ_MODULATION_SOURCES, propertySpecs, virtualControllers, pitchFields, scopeTunes, scopeGains, lifecycleEnums, oscillatorFields, SFZ_PITCH_CONTROL_RANGES;
  var init_modulation = __esm({
    "js/sfz/modulation.js"() {
      init_schema();
      init_generators();
      init_modulation_schema();
      SFZ_MODULATION_SECTION_VERSION = SFZ_MOD_LAYOUT.Version;
      SFZ_MODULATION_PROFILE = "sfz-linear-ramp-previous-sample-v3";
      SFZ_MODULATION_SOURCES = Object.freeze(Object.fromEntries(
        SFZ_MOD_VIRTUAL_CONTROLLERS.map((source) => [source.id, source.name])
      ));
      propertySpecs = new Map(SFZ_MOD_PROPERTIES.map((spec) => [`${spec.kind}:${spec.id}`, spec]));
      virtualControllers = new Set(SFZ_MOD_VIRTUAL_CONTROLLERS.map((source) => source.id));
      pitchFields = Object.freeze({
        bend_smooth: SFZ_MOD_PROPERTY_IDS.BendSmooth,
        bend_stepup: SFZ_MOD_PROPERTY_IDS.BendStepUp,
        bend_stepdown: SFZ_MOD_PROPERTY_IDS.BendStepDown
      });
      scopeTunes = /* @__PURE__ */ new Set(["global_tune", "master_tune", "group_tune"]);
      scopeGains = /^(global|master|group)_(volume|amplitude)$/;
      lifecycleEnums = Object.freeze({
        offset_mode: { samples: 0, percent: 1 },
        loop_type: { forward: 0, backward: 1, alternate: 2 },
        note_selfmask: { on: 1, off: 0 },
        rt_dead: { on: 1, off: 0 },
        sustain_sw: { on: 1, off: 0 },
        sostenuto_sw: { on: 1, off: 0 },
        sw_vel: { current: 0, previous: 1 },
        noise_stereo: { on: 1, off: 0 },
        pan_law: { no_law: 1, balance: 1, mma: 2, MMA: 2 },
        phase: { normal: 0, invert: 1 }
      });
      oscillatorFields = Object.freeze({
        oscillator: SFZ_MOD_PROPERTY_IDS.Enabled,
        oscillator_mode: SFZ_MOD_PROPERTY_IDS.OscillatorMode,
        oscillator_multi: SFZ_MOD_PROPERTY_IDS.OscillatorMulti,
        oscillator_phase: SFZ_MOD_PROPERTY_IDS.OscillatorPhase,
        oscillator_quality: SFZ_MOD_PROPERTY_IDS.OscillatorQuality,
        oscillator_table_size: SFZ_MOD_PROPERTY_IDS.OscillatorTableSize
      });
      SFZ_PITCH_CONTROL_RANGES = Object.freeze({
        note_offset: 127,
        octave_offset: 10,
        sw_note_offset: 127,
        sw_octave_offset: 10
      });
    }
  });

  // js/sfz/embedded-sample.js
  function embeddedSfzRanges(text2) {
    const ranges = [];
    let quote = false;
    for (let index = 0; index < text2.length; index++) {
      if (text2[index] === '"') quote = !quote;
      if (quote) continue;
      if (text2.startsWith("//", index)) {
        const end2 = text2.indexOf("\n", index + 2);
        index = end2 < 0 ? text2.length : end2;
        continue;
      }
      if (text2.startsWith("/*", index)) {
        const end2 = text2.indexOf("*/", index + 2);
        index = end2 < 0 ? text2.length : end2 + 1;
        continue;
      }
      if (text2[index] !== "<" || text2.slice(index, index + 8).toLowerCase() !== "<sample>") continue;
      const header = /^<sample>\s+name\s*=\s*("[^"]*"|[^<>\r\n]+?)\s+data\s*=/i.exec(text2.slice(index));
      if (!header) continue;
      const dataStart = index + header[0].length, end = text2.indexOf("$", dataStart);
      if (end < 0) throw Object.assign(new Error("An embedded instrument sample is incomplete."), { code: "prepare" });
      ranges.push({ start: index, dataStart, end: end + 1 });
      index = end;
    }
    return ranges;
  }
  function decodeEmbeddedSfzSample(encoded, maxBytes) {
    const bytes = new Uint8Array(Math.min(encoded.length, maxBytes));
    let length = 0;
    for (let index = 0; index < encoded.length; index++) {
      let value = encoded.charCodeAt(index);
      if (value === 36) return bytes.slice(0, length);
      if (value === 13 || value === 10) continue;
      if (value > 255 || length >= maxBytes) throw Object.assign(new Error("An embedded instrument sample could not be decoded."), { code: "prepare" });
      if (value === 61) {
        value = encoded.charCodeAt(++index);
        if (!Number.isInteger(value) || value > 255 || value === 36) throw Object.assign(new Error("An embedded instrument sample is incomplete."), { code: "prepare" });
        bytes[length++] = value + 192 & 255;
      } else bytes[length++] = value + 214 & 255;
    }
    throw Object.assign(new Error("An embedded instrument sample is incomplete."), { code: "prepare" });
  }
  var init_embedded_sample = __esm({
    "js/sfz/embedded-sample.js"() {
    }
  });

  // js/sfz/region-sentinels.js
  function normalizeSfzRegionSentinels(region) {
    const raw = region.opcodes ?? region;
    const noteEnabled = !(Number(raw.lokey) === -1 && Number(raw.hikey) === -1);
    const silentAction = Number(raw.end) === -1;
    if (!noteEnabled) {
      region.lokey = 0;
      region.hikey = 127;
    }
    if (region.pitch_keycenter === -1 && (!noteEnabled || Number(raw.key) === -1))
      region.pitch_keycenter = 60;
    if (silentAction) {
      region.sample = "*silence";
      region.offset = region.end = region.loop_start = region.loop_end = 0;
      region.loop_mode = 0;
    }
    return { noteEnabled, silentAction };
  }
  var init_region_sentinels = __esm({
    "js/sfz/region-sentinels.js"() {
    }
  });

  // js/sfz/effects.js
  function isSfzEffectOpcode(key, header) {
    if (header !== "effect") return regionRouting.test(key);
    const match = modulation.exec(key);
    return ["type", "bus", "tdfir_impulse"].includes(key) || routing.test(key) || allParameters.has(match?.[1] ?? key) || /^bypass_oncc[0-9]{1,3}$/.test(key);
  }
  function compileSfzEffects(regions, headers = []) {
    const diagnostics = [], nodes = [], direct = { directtomain: 100 };
    const fail2 = (code, opcode, index) => diagnostics.push({ code, opcode, index });
    const curveIds = new Set(headers.filter((header) => header.name === "curve").map((header) => Number(header.opcodes.curve_index)));
    const numeric = (value, min, max, integer = false) => {
      if (typeof value === "string" && !value.trim()) return null;
      const parsed = Number(value);
      return Number.isFinite(parsed) && parsed >= min && parsed <= max && (!integer || Number.isInteger(parsed)) ? parsed : null;
    };
    let requiredOutputs = 1;
    const compiledRegions = regions.map((region, index) => {
      const source = region.opcodes ?? region;
      const output = numeric(source.output ?? 0, 0, 1024, true);
      if (output === null) fail2("effect-output", "output", index);
      else requiredOutputs = Math.max(requiredOutputs, output + 1);
      const sends = Array.from({ length: 4 }, (_2, send) => {
        const key = `effect${send + 1}`, value = numeric(source[key] ?? 0, 0, 100);
        if (value === null) fail2("effect-send", key, index);
        return (value ?? 0) / 100;
      });
      return { output: output ?? 0, sends };
    });
    for (const [index, header] of headers.entries()) {
      if (header.name !== "effect" && header.name !== "midi") continue;
      const source = header.opcodes;
      if (header.name === "midi" || source.bus === "midi") {
        fail2("effect-midi-profile", "type", index);
        continue;
      }
      for (const [key, raw] of Object.entries(source)) if (routing.test(key)) {
        const value = numeric(raw, 0, 100);
        if (value === null) fail2("effect-routing-gain", key, index);
        else direct[key] = value;
      }
      const name = source.type;
      if (name === void 0 && Object.keys(source).every((key) => routing.test(key))) continue;
      if (!Object.hasOwn(SFZ_EFFECT_TYPES, name) || name === "chorus") {
        fail2("effect-type", "type", index);
        continue;
      }
      const bus = SFZ_EFFECT_BUS[source.bus ?? "main"];
      if (bus === void 0) {
        fail2("effect-bus", "bus", index);
        continue;
      }
      if (bus > 0 && bus < 9) requiredOutputs = Math.max(requiredOutputs, bus + 1);
      const definitions2 = SFZ_EFFECT_PARAMETERS[name];
      const parameters = definitions2.map((parameter) => parameter.default);
      const routes = /* @__PURE__ */ new Map();
      let bypassController = -1;
      for (const [key, raw] of Object.entries(source)) {
        if (["type", "bus", "tdfir_impulse"].includes(key) || routing.test(key)) continue;
        const bypass = /^bypass_oncc([0-9]{1,3})$/.exec(key);
        if (bypass) {
          const cc = Number(bypass[1]);
          if (cc > 155 || numeric(raw, 0, 1) === null) fail2("effect-bypass", key, index);
          else if (Number(raw)) bypassController = cc;
          continue;
        }
        const match = modulation.exec(key), base = match?.[1] ?? key;
        const parameterIndex = definitions2.findIndex((parameter) => parameter.name === base);
        if (parameterIndex < 0) {
          fail2("effect-parameter", key, index);
          continue;
        }
        const definition = definitions2[parameterIndex];
        if (!match) {
          const value = definition.options ? definition.options[raw] : numeric(raw, definition.min, definition.max, definition.unit === "index");
          if (value === void 0 || value === null) fail2("effect-value", key, index);
          else parameters[parameterIndex] = value;
        } else {
          const controller = Number(match[3]), property2 = match[2];
          if (controller > 155 || definition.options || definition.unit === "index") {
            fail2("effect-modulation", key, index);
            continue;
          }
          const routeKey = `${parameterIndex}:${controller}`;
          const route = routes.get(routeKey) ?? { parameter: parameterIndex, controller, depth: 0, curve: 0, smooth: 0, step: 0 };
          const field = { oncc: "depth", cc: "depth", curvecc: "curve", smoothcc: "smooth", stepcc: "step" }[property2];
          const value = numeric(
            raw,
            field === "depth" ? -34028234663852886e22 : 0,
            field === "curve" ? 255 : 34028234663852886e22,
            field === "curve"
          );
          if (value === null) fail2("effect-modulation-value", key, index);
          else {
            route[field] = value;
            routes.set(routeKey, route);
          }
        }
      }
      if (name === "tdfir" && !source.tdfir_impulse) fail2("effect-impulse", "tdfir_impulse", index);
      if (name === "static" && parameters[5] < parameters[6]) fail2("effect-time-order", "static_random_maxtime", index);
      for (const route of routes.values()) {
        if (route.curve >= 4 && route.curve <= 6) fail2("effect-curve-unverified", "curve", index);
        else if (route.curve >= 7 && !curveIds.has(route.curve)) fail2("effect-curve-missing", "curve", index);
      }
      nodes.push({
        type: SFZ_EFFECT_TYPES[name],
        bus,
        parameters,
        routes: [...routes.values()],
        bypassController,
        ...name === "tdfir" && { impulse: source.tdfir_impulse }
      });
    }
    if (nodes.length > SFZ_EFFECT_LAYOUT.MaximumNodes) fail2("effect-node-limit", "type", nodes.length);
    if (nodes.reduce((count, node) => count + node.routes.length, 0) > SFZ_EFFECT_LAYOUT.MaximumRoutes)
      fail2("effect-route-limit", "modulation", nodes.length);
    if (!headers.some((header) => header.name === "effect")) {
      for (let send = 0; send < 2; send++) if (compiledRegions.some((region) => region.sends[send] !== 0)) {
        const name = send ? "chorus" : "fverb";
        const parameters = SFZ_EFFECT_PARAMETERS[name].map((parameter) => parameter.default);
        if (!send) {
          parameters[1] = 0;
          parameters[7] = 100;
        }
        nodes.push({ type: SFZ_EFFECT_TYPES[name], bus: 9 + send, parameters, routes: [], bypassController: -1 });
        direct[`fx${send + 1}tomain`] = 100;
      }
    }
    return {
      version: 1,
      profile: SFZ_EFFECT_PROFILE,
      regions: compiledRegions,
      nodes,
      requiredOutputs,
      directToMain: direct.directtomain / 100,
      fxToMain: Array.from({ length: 4 }, (_2, index) => (direct[`fx${index + 1}tomain`] ?? 0) / 100),
      fxToMix: Array.from({ length: 4 }, (_2, index) => (direct[`fx${index + 1}tomix`] ?? 0) / 100),
      diagnostics
    };
  }
  function packSfzEffects(plan, resolveImpulse = () => void 0) {
    if (plan.version !== SFZ_EFFECT_LAYOUT.Version || plan.diagnostics.length) throw new Error("Invalid SFZ effect plan.");
    const routeCount = plan.nodes.reduce((total, node) => total + node.routes.length, 0);
    const parameterCount = plan.nodes.reduce((total, node) => total + node.parameters.length, 0);
    const regionOffset = SFZ_EFFECT_LAYOUT.HeaderWords;
    const nodeOffset = regionOffset + plan.regions.length * SFZ_EFFECT_LAYOUT.RegionWords;
    const parameterOffset = nodeOffset + plan.nodes.length * SFZ_EFFECT_LAYOUT.NodeWords;
    const routeOffset = parameterOffset + parameterCount;
    const impulseOffset = routeOffset + routeCount * SFZ_EFFECT_LAYOUT.RouteWords;
    const impulses = /* @__PURE__ */ new Map();
    for (const node of plan.nodes) if (node.type === SFZ_EFFECT_TYPES.tdfir && !impulses.has(node.impulse)) {
      const info = resolveImpulse(node.impulse);
      const row = info && [info.sampleOffsetOrId, info.frames, info.channels, info.rate];
      if (!row || row.some((value) => !Number.isInteger(value) || value < 0 || value > 4294967295) || !info.frames || ![1, 2].includes(info.channels) || info.rate < 1 || info.rate > 768e3)
        throw new Error("SFZ effect impulse is not prepared.");
      impulses.set(node.impulse, { index: impulses.size, row });
    }
    const words = impulseOffset + impulses.size * SFZ_EFFECT_LAYOUT.ImpulseWords;
    if (!Number.isSafeInteger(words) || words > 1073741823) throw new Error("SFZ effect plan is too large.");
    const bytes = new Uint8Array(words * 4), u = new Uint32Array(bytes.buffer), f = new Float32Array(bytes.buffer);
    u.set([
      SFZ_EFFECT_LAYOUT.Version,
      plan.regions.length,
      plan.nodes.length,
      routeCount,
      parameterCount,
      regionOffset,
      nodeOffset,
      parameterOffset,
      routeOffset,
      plan.requiredOutputs
    ]);
    f.set([plan.directToMain, ...plan.fxToMain, ...plan.fxToMix], 10);
    u.set([impulseOffset, impulses.size], 20);
    for (const { index, row } of impulses.values()) u.set(row, impulseOffset + index * SFZ_EFFECT_LAYOUT.ImpulseWords);
    for (const [index, region] of plan.regions.entries()) {
      const offset = regionOffset + index * SFZ_EFFECT_LAYOUT.RegionWords;
      u[offset] = region.output;
      f.set(region.sends, offset + 1);
    }
    let parameterIndex = 0, routeIndex = 0;
    for (const [index, node] of plan.nodes.entries()) {
      const impulse = node.type === SFZ_EFFECT_TYPES.tdfir ? impulses.get(node.impulse).index : 4294967295;
      u.set([
        node.type,
        node.bus,
        parameterIndex,
        node.parameters.length,
        routeIndex,
        node.routes.length,
        impulse,
        node.bypassController + 1
      ], nodeOffset + index * SFZ_EFFECT_LAYOUT.NodeWords);
      f.set(node.parameters, parameterOffset + parameterIndex);
      for (const route of node.routes) {
        const offset = routeOffset + routeIndex++ * SFZ_EFFECT_LAYOUT.RouteWords;
        u[offset] = route.parameter;
        u[offset + 1] = route.controller;
        f[offset + 2] = route.depth;
        u[offset + 3] = route.curve;
        f[offset + 4] = route.smooth;
        f[offset + 5] = route.step;
      }
      parameterIndex += node.parameters.length;
    }
    return bytes;
  }
  var SFZ_EFFECT_PROFILE, SFZ_EFFECT_LAYOUT, SFZ_EFFECT_TYPES, SFZ_EFFECT_BUS, scalar, percent, seconds, hz, db, choice, onoff, filterNames, delayModes, reverbTypes, SFZ_EFFECT_PARAMETERS, routing, regionRouting, modulation, allParameters;
  var init_effects = __esm({
    "js/sfz/effects.js"() {
      init_modulation_schema();
      SFZ_EFFECT_PROFILE = "effetune-sfz-effects-v1";
      SFZ_EFFECT_LAYOUT = Object.freeze({
        Version: 1,
        HeaderWords: 22,
        RegionWords: 5,
        NodeWords: 8,
        RouteWords: 6,
        ImpulseWords: 4,
        MaximumNodes: 64,
        MaximumRoutes: 4096
      });
      SFZ_EFFECT_TYPES = Object.freeze({
        apan: 1,
        comp: 2,
        delay: 3,
        disto: 4,
        eq: 5,
        filter: 6,
        fverb: 7,
        gate: 8,
        limiter: 9,
        lofi: 10,
        phaser: 11,
        static: 12,
        strings: 13,
        tdfir: 14,
        chorus: 15,
        gain: 16,
        rectify: 17
      });
      SFZ_EFFECT_BUS = Object.freeze({
        main: 0,
        aux1: 1,
        aux2: 2,
        aux3: 3,
        aux4: 4,
        aux5: 5,
        aux6: 6,
        aux7: 7,
        aux8: 8,
        fx1: 9,
        fx2: 10,
        fx3: 11,
        fx4: 12
      });
      scalar = (name, value, min, max, unit = "scalar") => ({ name, default: value, min, max, unit });
      percent = (name, value = 100) => scalar(name, value, 0, 100, "percent");
      seconds = (name, value, maximum = 10) => scalar(name, value, 0, maximum, "seconds");
      hz = (name, value, maximum = 3e4) => scalar(name, value, 0, maximum, "Hz");
      db = (name, value) => scalar(name, value, -144, 24, "dB");
      choice = (name, value, options) => ({ name, default: value, options });
      onoff = { off: 0, on: 1 };
      filterNames = { off: 0, ...SFZ_MOD_FILTER_TYPES };
      delayModes = Object.fromEntries([
        "stereo",
        "cross",
        "ping",
        "lrc",
        "rlc",
        "tlcr",
        "panning",
        "mod",
        "multimod",
        "chorus",
        "flanger",
        "detune"
      ].map((name, index) => [name, index]));
      reverbTypes = Object.fromEntries([
        "chamber",
        "small_room",
        "mid_room",
        "large_room",
        "small_hall",
        "mid_hall",
        "large_hall"
      ].map((name, index) => [name, index]));
      SFZ_EFFECT_PARAMETERS = Object.freeze({
        apan: [
          percent("apan_depth"),
          percent("apan_dry", 0),
          hz("apan_freq", 1, 100),
          scalar("apan_phase", 0, 0, 180, "degrees"),
          scalar("apan_waveform", 0, 0, 7, "index"),
          percent("apan_wet")
        ],
        comp: [
          seconds("comp_attack", 0.01),
          db("comp_gain", 0),
          scalar("comp_ratio", 2, 0, 100, "ratio"),
          seconds("comp_release", 0.1),
          choice("comp_stlink", 1, onoff),
          db("comp_threshold", -24)
        ],
        delay: [
          hz("delay_cutoff", 2e4),
          percent("delay_damphi", 0),
          percent("delay_damplo", 0),
          percent("delay_dry"),
          percent("delay_feedback", 0),
          choice("delay_filter", 0, filterNames),
          percent("delay_input"),
          percent("delay_levelc", 0),
          percent("delay_levell"),
          percent("delay_levelr"),
          hz("delay_lfofreq", 0.5, 100),
          percent("delay_moddepth", 0),
          choice("delay_mode", 0, delayModes),
          percent("delay_panc", 50),
          percent("delay_panl", 0),
          percent("delay_panr", 100),
          scalar("delay_resonance", 0, 0, 40, "dB"),
          percent("delay_spread"),
          scalar("delay_syncc", 0, 0, 64, "quarter-notes"),
          scalar("delay_syncl", 0, 0, 64, "quarter-notes"),
          scalar("delay_syncr", 0, 0, 64, "quarter-notes"),
          seconds("delay_time_tap", 0),
          seconds("delay_timec", 0.25),
          seconds("delay_timel", 0.25),
          seconds("delay_timer", 0.25),
          percent("delay_wet")
        ],
        disto: [
          percent("disto_depth", 0),
          percent("disto_dry", 0),
          scalar("disto_stages", 1, 1, 8, "index"),
          percent("disto_tone", 100),
          percent("disto_wet")
        ],
        eq: [
          scalar("eq_bw", 1, 1e-3, 4, "octaves"),
          hz("eq_freq", 1e3),
          db("eq_gain", 0),
          choice("eq_type", 0, { peq: 0, lsh: 1, hsh: 2 })
        ],
        filter: [
          hz("filter_cutoff", 2e4),
          scalar("filter_resonance", 0, 0, 40, "dB"),
          choice("filter_type", 2, filterNames),
          scalar("filter_gain", 0, -96, 96, "dB")
        ],
        fverb: [
          percent("reverb_damp", 50),
          percent("reverb_dry"),
          percent("reverb_input"),
          seconds("reverb_predelay", 0.01, 1),
          percent("reverb_size", 50),
          percent("reverb_tone", 50),
          choice("reverb_type", 0, reverbTypes),
          percent("reverb_wet", 30)
        ],
        gate: [
          seconds("gate_attack", 1e-3),
          seconds("gate_release", 0.2),
          choice("gate_stlink", 1, onoff),
          db("gate_threshold", -40),
          percent("gate", 100),
          seconds("gate_hold", 0)
        ],
        limiter: [],
        lofi: [percent("bitred", 0), percent("decim", 0)],
        phaser: [
          percent("phaser_depth"),
          percent("phaser_feedback", 0),
          hz("phaser_freq", 0.5, 100),
          percent("phaser_phase", 0),
          scalar("phaser_stages", 4, 1, 12, "index"),
          scalar("phaser_waveform", 0, 0, 7, "index"),
          percent("phaser_wet", 50)
        ],
        static: [
          percent("static_cyclic_level", 0),
          seconds("static_cyclic_time", 1, 120),
          choice("static_filter", 0, filterNames),
          percent("static_level", 0),
          percent("static_random_level", 0),
          seconds("static_random_maxtime", 1, 120),
          seconds("static_random_mintime", 0.1, 120),
          choice("static_stereo", 1, onoff),
          percent("static_tone", 50)
        ],
        strings: [scalar("strings_number", 12, 1, 107, "index"), percent("strings_wet", 50)],
        tdfir: [percent("tdfir_dry"), percent("tdfir_gain"), percent("tdfir_wet")],
        // Internal type for the v1 effect2 send; it is not an additional public alias.
        chorus: [],
        gain: [scalar("gain", 0, -144, 48, "dB")],
        rectify: [percent("rectify", 0), choice("rectify_mode", 0, { half: 0, full: 1 })]
      });
      routing = /^(?:directtomain|fx[1-4]to(?:main|mix))$/;
      regionRouting = /^(?:output|effect[1-4])$/;
      modulation = /^(.*)_(oncc|cc|curvecc|smoothcc|stepcc)([0-9]{1,3})$/;
      allParameters = new Set(Object.values(SFZ_EFFECT_PARAMETERS).flat().map((parameter) => parameter.name));
    }
  });

  // js/sfz/effects-asset.js
  function compileSfzEffectHeaders(regions, headers) {
    const authored = headers.some((header) => header.name === "effect" || header.name === "midi") || regions.some((region) => Object.keys(region.opcodes ?? region).some((key) => /^(?:output|effect[1-4])$/.test(key)));
    return authored ? compileSfzEffects(regions, headers) : null;
  }
  function effectSamplePaths(plan) {
    return [...new Set(plan?.nodes.filter((node) => node.impulse !== void 0).map((node) => node.impulse) ?? [])].sort();
  }
  function packSfzEffectModulation(modulationBytes, plan, resolveImpulse) {
    if (!plan) return modulationBytes;
    if (!(modulationBytes instanceof Uint8Array) || modulationBytes.byteLength % 4 || modulationBytes.byteLength < SFZ_MOD_LAYOUT.HeaderWords * 4) throw new Error("Invalid SFZ modulation section.");
    const original = new DataView(modulationBytes.buffer, modulationBytes.byteOffset, modulationBytes.byteLength);
    if (original.getUint32(0, true) !== 827479123 || original.getUint32(4, true) !== 3 || SFZ_MOD_LAYOUT.HeaderWords !== 14 || original.getUint32(8, true) !== plan.regions.length)
      throw new Error("Invalid SFZ modulation section.");
    const effects = packSfzEffects(plan, resolveImpulse);
    const fxOffset = modulationBytes.byteLength / 4 + 2;
    const bytes = new Uint8Array(modulationBytes.byteLength + 8 + effects.byteLength);
    bytes.set(modulationBytes.subarray(0, 56));
    bytes.set(modulationBytes.subarray(56), 64);
    bytes.set(effects, fxOffset * 4);
    const output = new DataView(bytes.buffer);
    output.setUint32(4, 4, true);
    for (const index of [5, 6, 7, 8, 10]) output.setUint32(index * 4, original.getUint32(index * 4, true) + 2, true);
    output.setUint32(56, fxOffset, true);
    output.setUint32(60, effects.byteLength / 4, true);
    return bytes;
  }
  var init_effects_asset = __esm({
    "js/sfz/effects-asset.js"() {
      init_effects();
      init_modulation_schema();
    }
  });

  // js/sfz/parser.js
  function validateExtraOpcode(key, number2) {
    const controller = sfzControllerOpcode(key);
    let low = -12e3, high = 12e3, integer = false;
    if (controller) {
      if (["locc", "hicc", "set_cc", "on_locc", "on_hicc"].includes(controller.family)) {
        low = controller.family.startsWith("on_") ? -1 : 0;
        high = 127;
        integer = true;
      } else {
        [low, high] = SFZ_MODULATION_DEPTH_RANGES[SFZ_MODULATION_TARGETS[controller.family.slice(0, -5)]];
      }
    } else if (key === "ampeg_dynamic") {
      low = 0;
      high = 1;
      integer = true;
    } else if (/^eq[1-3]_freq$/.test(key)) {
      low = 0;
      high = 3e4;
    } else if (/^eq[1-3]_bw$/.test(key)) {
      low = 1e-3;
      high = 4;
    } else if (/^eq[1-3]_gain$/.test(key)) {
      low = -96;
      high = 24;
    } else if (key.startsWith("sw_")) {
      low = -1;
      high = 127;
      integer = true;
    } else if (key === "lochan" || key === "hichan") {
      low = 1;
      high = 16;
      integer = true;
    } else if (["lobend", "hibend"].includes(key)) {
      low = -8192;
      high = 8192;
      integer = true;
    } else if (/^(?:lo|hi)(?:chanaft|polyaft|prog)$/.test(key) || key === "amp_keycenter") {
      low = 0;
      high = 127;
      integer = true;
    } else if (["group", "off_by"].includes(key)) {
      low = -2147483648;
      high = 2147483647;
      integer = true;
    } else if (key === "loop_count") {
      low = -1;
      high = 4294967295;
      integer = true;
    } else if (["polyphony", "note_polyphony"].includes(key)) {
      low = 1;
      high = 16777216;
      integer = true;
    } else if (key === "cutoff") {
      low = 0;
      high = 192e3;
    } else if (key === "resonance") {
      low = 0;
      high = 40;
    } else if (key === "amp_keytrack") {
      low = -96;
      high = 12;
    } else if (key === "amp_random") {
      low = 0;
      high = 24;
    } else if (key === "pitch_veltrack") {
      low = -9600;
      high = 9600;
    } else if (key === "bend_up" || key === "bend_down") {
      low = -9600;
      high = 9600;
      integer = true;
    } else if (key === "pitch_random") {
      low = 0;
      high = 9600;
    } else if (key === "off_time" || key === "delay" || key === "delay_random" || key === "loop_crossfade" || /^(?:amp|pitch|fil)(?:eg|lfo)_(?:delay|attack|hold|decay|release|fade)$/.test(key)) {
      low = 0;
      high = 100;
    } else if (/^(?:amp|pitch|fil)eg_(?:start|sustain)$/.test(key)) {
      low = 0;
      high = 100;
    } else if (/lfo_freq$/.test(key)) {
      low = 0;
      high = 2e4;
    } else if (key === "amplfo_depth") {
      low = -10;
      high = 10;
    }
    if (!Number.isFinite(number2) || number2 < low || number2 > high || integer && !Number.isInteger(number2)) {
      throw sfzError("prepare", `Invalid SFZ opcode ${key}.`);
    }
  }
  function sfzError(code, message, cause) {
    const error2 = new Error(message, cause ? { cause } : void 0);
    error2.code = code;
    return error2;
  }
  function normalizeSfzPath(value, directory = "") {
    if (typeof value !== "string") throw sfzError("prepare", "An SFZ file path is invalid.");
    const path = value.replaceAll("\\", "/");
    if (path.startsWith("/") || /^[a-z]:/i.test(path) || path.includes("\0")) {
      throw sfzError("prepare", "SFZ references must stay inside the selected folder.");
    }
    const parts = directory ? directory.split("/") : [];
    for (const part of path.split("/")) {
      if (!part || part === ".") continue;
      if (part === "..") {
        if (!parts.length) throw sfzError("prepare", "SFZ references must stay inside the selected folder.");
        parts.pop();
      } else parts.push(part);
    }
    return parts.join("/");
  }
  function stripComments(text2) {
    let result = "";
    let quoted = false;
    for (let index = 0; index < text2.length; index++) {
      const char = text2[index];
      if (char === '"') quoted = !quoted;
      if (!quoted && char === "/" && text2[index + 1] === "/") {
        while (index < text2.length && text2[index] !== "\n") index++;
        result += "\n";
      } else if (!quoted && char === "/" && text2[index + 1] === "*") {
        index += 2;
        while (index < text2.length && !(text2[index] === "*" && text2[index + 1] === "/")) index++;
        index++;
        result += " ";
      } else result += char;
    }
    return result;
  }
  function unquote(value) {
    return value.startsWith('"') && value.endsWith('"') ? value.slice(1, -1) : value;
  }
  function normalizeRegion(raw, samplePath, seqGroup, adjustedEnvelopes) {
    const region = { ...DEFAULTS, ...SFZ_EXTRA_DEFAULTS, sample: samplePath, seqGroup, opcodes: { ...raw } };
    for (const [key, value] of Object.entries(raw)) {
      if (key === "sample" || key === "key") continue;
      if (["load_start", "load_end", "load_mode"].includes(key)) {
        const number3 = Number(value);
        if (!Number.isSafeInteger(number3) || number3 < 0 || number3 > (key === "load_mode" ? 1 : 4294967296))
          throw sfzError("prepare", "The instrument sample loading range is invalid.");
        region[key] = number3;
        continue;
      }
      if (Object.hasOwn(SFZ_EXTRA_DEFAULTS, key) || sfzControllerOpcode(key)) {
        const number3 = Object.hasOwn(SFZ_ENUMS, key) ? SFZ_ENUMS[key][value] : key.startsWith("sw_") || key === "amp_keycenter" ? sfzMidiKey(value) : Number(value);
        validateExtraOpcode(key, number3);
        region[key] = number3;
        continue;
      }
      if (!SUPPORTED.has(key)) continue;
      let number2 = key === "loop_mode" ? LOOP_MODES.get(value) : NOTE_KEYS.has(key) ? sfzMidiKey(value) : Number(value);
      if (ENVELOPE_TIMES.has(key) && (!Number.isFinite(number2) || number2 < 0 || number2 > 100)) {
        adjustedEnvelopes.add(`${samplePath}: ${key}=${value}`);
        number2 = Number.isFinite(number2) ? number2 < 0 ? 0 : 100 : DEFAULTS[key];
      }
      if (!Number.isFinite(number2)) throw sfzError("prepare", `Invalid SFZ opcode ${key}.`);
      if (key === "key") {
        region.lokey = region.hikey = region.pitch_keycenter = number2;
      } else {
        if (INTEGER_KEYS.has(key) && !(key === "offset" && raw.offset_mode === "percent") && !Number.isInteger(number2)) {
          throw sfzError("prepare", `SFZ opcode ${key} must be an integer.`);
        }
        region[key] = number2;
      }
    }
    normalizeSfzRegionSentinels(region);
    if (!Object.hasOwn(raw, "fil_type") && Object.keys(raw).some((key) => ["cutoff", "resonance", "fileg_depth", "fillfo_depth"].includes(key) || ["cutoff_oncc", "resonance_oncc"].includes(sfzControllerOpcode(key)?.family))) region.fil_type = 2;
    if (region.lovel === 0) region.lovel = 1;
    for (const [low, high] of [
      ["lochan", "hichan"],
      ["lobend", "hibend"],
      ["lochanaft", "hichanaft"],
      ["lopolyaft", "hipolyaft"],
      ["loprog", "hiprog"]
    ]) {
      if (region[low] > region[high]) throw sfzError("prepare", `Invalid SFZ condition ${low}/${high}.`);
    }
    for (let cc = 0; cc < 128; cc++) {
      if (sfzControllerValue(region, "locc", cc) > sfzControllerValue(region, "hicc", cc)) {
        throw sfzError("prepare", `Invalid SFZ controller range ${cc}.`);
      }
    }
    if (region.lokey < 0 || region.hikey > 127 || region.lokey > region.hikey || region.lovel < 1 || region.hivel > 127 || region.lovel > region.hivel || region.lorand < 0 || region.hirand > 1 || region.lorand > region.hirand || region.seq_length < 1 || region.seq_length > 16777216 || region.seq_position < 1 || region.seq_position > region.seq_length || region.pitch_keycenter < 0 || region.pitch_keycenter > 127 || region.offset < 0 || region.pitch_keytrack < -1200 || region.pitch_keytrack > 1200 || region.transpose < -127 || region.transpose > 127 || region.tune < -1200 || region.tune > 1200 || region.volume < -144 || region.volume > 144 || region.pan < -100 || region.pan > 100 || region.amp_veltrack < -100 || region.amp_veltrack > 100 || ["ampeg_attack", "ampeg_hold", "ampeg_decay", "ampeg_release"].some((key) => region[key] < 0 || region[key] > 100) || region.ampeg_sustain < 0 || region.ampeg_sustain > 100) {
      throw sfzError("prepare", "SFZ region contains an invalid parameter range.");
    }
    return region;
  }
  function resolveSfzRegionOffset(region, frames) {
    return region.opcodes?.offset_mode === "percent" ? Math.floor((region.offset ?? 0) * 0.01 * frames) : region.offset ?? 0;
  }
  function instrumentPresentation(headers, regions, directory) {
    const keys = /* @__PURE__ */ new Map(), controllers = /* @__PURE__ */ new Map(), outputs = /* @__PURE__ */ new Map(), switches = /* @__PURE__ */ new Map(), groups = /* @__PURE__ */ new Set();
    const scopes = /* @__PURE__ */ new Map();
    let image = null;
    for (const header of headers) for (const [key, value] of Object.entries(header.opcodes)) {
      const label = /^label_(key|cc|output)([0-9]+)$/.exec(key);
      if (label) {
        const index = Number(label[2]), limit = label[1] === "output" ? 1024 : 127;
        if (header.name !== "control" || index > limit) throw sfzError("prepare", "An instrument label has an invalid location.");
        ({ key: keys, cc: controllers, output: outputs })[label[1]].set(index, value);
      }
      if (key === "image") image = normalizeSfzPath(value, directory);
      if (header.name === "control" && key === "group_label") groups.add(value);
    }
    for (const region of regions) {
      for (const name of ["global", "master", "region"]) {
        const label2 = region.opcodes[`${name}_label`];
        if (label2) scopes.set(`${name}:${label2}`, { scope: name, label: label2 });
      }
      const label = region.opcodes.sw_label;
      const first = region.sw_last >= 0 ? region.sw_last : region.sw_lolast;
      const last = region.sw_last >= 0 ? region.sw_last : region.sw_hilast;
      if (label && first >= 0 && last >= first) switches.set(`${first}:${last}:${label}`, { first, last, label });
      if (region.opcodes.group_label) groups.add(region.opcodes.group_label);
    }
    const labels = (map) => [...map].sort((a, b2) => a[0] - b2[0]).map(([index, label]) => ({ index, label }));
    return {
      keys: labels(keys),
      controllers: labels(controllers),
      outputs: labels(outputs),
      switches: [...switches.values()],
      groups: [...groups],
      ...scopes.size ? { scopes: [...scopes.values()] } : {},
      image
    };
  }
  async function parseSfz({
    selectedPath,
    readText,
    hasSample,
    resolveSample,
    maxBytes = SFZ_DEFAULT_MAX_BYTES,
    defines: sourceDefines = /* @__PURE__ */ new Map(),
    onDiagnostic = (detail) => console.warn("SFZ import:", detail)
  }) {
    requireSfzMaxBytes(maxBytes);
    selectedPath = normalizeSfzPath(selectedPath);
    const directory = selectedPath.includes("/") ? selectedPath.slice(0, selectedPath.lastIndexOf("/")) : "";
    const dependencies = /* @__PURE__ */ new Set();
    const embeddedPayloads = [], embeddedSamples = /* @__PURE__ */ new Map();
    const defines = new Map(sourceDefines);
    const diagnostics = {
      ignoredOpcodes: /* @__PURE__ */ new Set(),
      unsupportedHeaders: /* @__PURE__ */ new Set(),
      excludedOpcodes: /* @__PURE__ */ new Set(),
      missingSamples: /* @__PURE__ */ new Set(),
      invalidRegions: /* @__PURE__ */ new Set(),
      adjustedEnvelopes: /* @__PURE__ */ new Set()
    };
    let includeVisits = 0;
    let sourceChars = 0;
    let expandedChars = 0;
    const tooLarge = () => sfzError("too-large", "The SFZ definition is too large to load.");
    const expandDefines = (text3) => {
      let length = text3.length;
      if (length > maxBytes - expandedChars) throw tooLarge();
      const expanded = text3.replace(/\$[a-z0-9_]+/gi, (key) => {
        const value = defines.get(key) ?? key;
        length += value.length - key.length;
        if (length > maxBytes - expandedChars) throw tooLarge();
        return value;
      });
      expandedChars += length + 1;
      if (expandedChars > maxBytes) throw tooLarge();
      return expanded;
    };
    async function expand(path, ancestors = []) {
      if (ancestors.includes(path) || ancestors.length >= 32) throw sfzError("prepare", "SFZ includes are recursive or too deep.");
      if (++includeVisits > MAX_INCLUDE_VISITS) throw tooLarge();
      let text3 = await readText(path);
      if (typeof text3 !== "string") throw sfzError("prepare", "An SFZ include could not be found.");
      sourceChars += text3.length;
      if (sourceChars > maxBytes) throw tooLarge();
      dependencies.add(path);
      let cursor = 0, clean = "";
      for (const range of embeddedSfzRanges(text3)) {
        clean += text3.slice(cursor, range.dataStart) + `embedded_${embeddedPayloads.length}
`;
        embeddedPayloads.push(decodeEmbeddedSfzSample(text3.slice(range.dataStart, range.end), maxBytes));
        cursor = range.end;
      }
      if (cursor) text3 = clean + text3.slice(cursor);
      let output = "";
      for (const line of stripComments(text3).split(/\r?\n/)) {
        const define = /^\s*#define\s+(\$[a-z0-9_]+)\s+(.+)$/i.exec(line);
        const include = /^\s*#include\s+(.+)$/i.exec(line);
        if (define) defines.set(define[1], expandDefines(unquote(define[2].trim())));
        else if (include) {
          const base = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
          output += await expand(normalizeSfzPath(unquote(expandDefines(include[1].trim())), base), [...ancestors, path]);
        } else output += expandDefines(line) + "\n";
      }
      return output;
    }
    const text2 = await expand(selectedPath);
    const markers = [...text2.matchAll(/<([a-z0-9_]+)>|([a-z0-9_]+)\s*=/gi)];
    const regions = [];
    const pendingRegions = [];
    const initialCC = [];
    let global = /* @__PURE__ */ Object.create(null);
    let master = /* @__PURE__ */ Object.create(null);
    let group = /* @__PURE__ */ Object.create(null);
    let scope = /* @__PURE__ */ Object.create(null);
    let header = "";
    let defaultPath = "";
    let scriptPath = null;
    const headers = [];
    let seqGroup = 0;
    const finishRegion = () => {
      if (header !== "region") return;
      const raw = /* @__PURE__ */ Object.create(null);
      for (const inherited of [global, master, group, scope]) for (const [key, value] of Object.entries(inherited)) {
        delete raw[key];
        raw[key] = value;
      }
      pendingRegions.push({ raw, defaultPath, seqGroup });
    };
    for (let index = 0; index < markers.length; index++) {
      const marker = markers[index];
      if (marker[1]) {
        finishRegion();
        header = marker[1].toLowerCase();
        scope = /* @__PURE__ */ Object.create(null);
        headers.push({ name: header, opcodes: scope });
        if (!HEADERS.has(header) && header !== "sample") diagnostics.unsupportedHeaders.add(header);
        if (header === "global") {
          global = scope;
          master = /* @__PURE__ */ Object.create(null);
          group = /* @__PURE__ */ Object.create(null);
          seqGroup++;
        } else if (header === "master") {
          master = scope;
          group = /* @__PURE__ */ Object.create(null);
          seqGroup++;
        } else if (header === "group") {
          group = scope;
          seqGroup++;
        }
        continue;
      }
      const key = marker[2].toLowerCase();
      const value = unquote(text2.slice(marker.index + marker[0].length, markers[index + 1]?.index ?? text2.length).trim());
      if (header === "global" && key === "script") {
        scope.script = value;
        scriptPath = normalizeSfzPath(value, directory);
      } else if (header === "control" && key.startsWith("hint_")) diagnostics.excludedOpcodes.add(key);
      else if (header === "control" && key === "default_path") defaultPath = value.replaceAll("\\", "/");
      else if (header === "effect" && key === "tdfir_impulse") scope.tdfir_impulse = normalizeSfzPath(defaultPath + value, directory);
      else if (key === "loop_end_offset") {
        if (header !== "control" || !["0", "-1"].includes(value)) throw sfzError("prepare", "The instrument loop correction must be 0 or -1 under control.");
        scope.loop_end_offset = value;
      } else if (header === "control" && /^set_cc[0-9]{1,3}$/.test(key) && Number(key.slice(6)) < 128) {
        const number2 = Number(value);
        if (!Number.isInteger(number2) || number2 < 0 || number2 > 127) {
          throw sfzError("prepare", `Invalid SFZ opcode ${key}.`);
        }
        initialCC[Number(key.slice(6))] = number2;
        delete scope[key];
        scope[key] = value;
      } else if (header === "control" && /^set_(?:hdcc|realcc)[0-9]{1,3}$/.test(key)) {
        const cc = Number(key.match(/[0-9]+$/)[0]), number2 = Number(value);
        if (cc > 127 || !Number.isFinite(number2) || number2 < 0 || number2 > 1) throw sfzError("prepare", "An instrument controller has an invalid initial value.");
        initialCC[cc] = Math.round(number2 * 127);
        const canonical = canonicalSfzOpcode(key);
        delete scope[canonical];
        scope[canonical] = value;
      } else if (key === "key") {
        delete scope.key;
        scope.key = value;
        scope.lokey = scope.hikey = scope.pitch_keycenter = value;
      } else {
        const canonical = header === "effect" && isSfzEffectOpcode(key, header) ? key : canonicalSfzOpcode(key);
        delete scope[canonical];
        scope[canonical] = value;
        if (!SUPPORTED.has(canonical) && !Object.hasOwn(SFZ_EXTRA_DEFAULTS, canonical) && !sfzControllerOpcode(canonical) && !isSfzModulationOpcode(canonical) && !isSfzEffectOpcode(canonical, header) && !Object.hasOwn(SFZ_PITCH_CONTROL_RANGES, canonical) && !(header === "curve" && (canonical === "curve_index" || /^v[0-9]{3}$/.test(canonical))) && !(header === "sample" && ["name", "data"].includes(canonical)) && !["sw_label", "sw_note", "global_label", "master_label", "group_label", "region_label", "image"].includes(canonical) && !(canonical === "md5" && (resolveSample || value === "null")) && !/^(?:label_key|label_cc|label_output)[0-9]{1,4}$/.test(canonical)) diagnostics.ignoredOpcodes.add(canonical);
      }
    }
    finishRegion();
    for (const header2 of headers) if (header2.name === "sample") {
      const token = /^embedded_([0-9]+)$/.exec(header2.opcodes.data || "");
      const bytes = token && embeddedPayloads[Number(token[1])];
      if (!bytes || !header2.opcodes.name) throw sfzError("prepare", "An embedded instrument sample is incomplete.");
      const path = normalizeSfzPath(header2.opcodes.name, directory);
      if (embeddedSamples.has(path)) throw sfzError("prepare", "The instrument contains duplicate embedded sample names.");
      embeddedSamples.set(path, bytes);
    }
    let script = null;
    if (scriptPath !== null) {
      const source = await readText(scriptPath);
      if (typeof source !== "string") throw sfzError("prepare", "An instrument script could not be found.");
      if (source.length > 262144 || sourceChars + source.length > maxBytes) throw tooLarge();
      dependencies.add(scriptPath);
      script = { path: scriptPath, source };
    }
    let invalidRegionCount = 0;
    for (const { raw, defaultPath: regionDefaultPath, seqGroup: regionSeqGroup } of pendingRegions) {
      try {
        if (!raw.sample) continue;
        let sample = Number(raw.end) === -1 ? "*silence" : isSfzGenerator(raw.sample) ? raw.sample : normalizeSfzPath(regionDefaultPath + unquote(raw.sample), directory);
        const region = normalizeRegion(raw, sample, regionSeqGroup, diagnostics.adjustedEnvelopes);
        sample = region.sample;
        const generator = isSfzGenerator(sample);
        if (Number(raw.end) !== -1 && raw.md5 && raw.md5 !== "null") {
          if (!/^[a-f0-9]{32}$/i.test(raw.md5)) throw sfzError("sample-integrity", "An instrument sample has an invalid content fingerprint.");
          if (generator) diagnostics.ignoredOpcodes.add("md5");
          else if (resolveSample) sample = normalizeSfzPath(await resolveSample(sample, raw.md5.toLowerCase(), embeddedSamples));
        }
        region.sample = sample;
        for (let cc = 0; cc < 128; cc++) {
          if (initialCC[cc] !== void 0) region[`set_cc${cc}`] = initialCC[cc];
        }
        if (generator && Number(raw.end) !== -1) {
          region.pitch_keycenter = 60;
          region.loop_mode = 2;
        }
        if (!generator && !embeddedSamples.has(sample) && hasSample && !hasSample(sample)) {
          diagnostics.missingSamples.add(sample);
          continue;
        }
        regions.push(region);
      } catch (error2) {
        if (error2?.code !== "prepare") throw error2;
        invalidRegionCount++;
        diagnostics.invalidRegions.add(`${raw.sample || "(no sample)"}: ${error2.message}`);
      }
    }
    const detail = Object.fromEntries(Object.entries(diagnostics).map(([key, values]) => [key, [...values].sort()]));
    if (Object.values(detail).some((values) => values.length)) onDiagnostic?.(detail);
    const warnings = [];
    if (invalidRegionCount) warnings.push({ code: "invalid-regions", count: invalidRegionCount });
    if (diagnostics.missingSamples.size) warnings.push({ code: "missing-samples", count: diagnostics.missingSamples.size });
    if (diagnostics.adjustedEnvelopes.size) warnings.push({ code: "envelope-times-adjusted", count: diagnostics.adjustedEnvelopes.size });
    const modulation2 = compileSfzModulation(regions, headers);
    if (modulation2.diagnostics.length) onDiagnostic?.({ modulation: modulation2.diagnostics });
    const effects = compileSfzEffectHeaders(regions, headers);
    if (effects?.diagnostics.length) {
      onDiagnostic?.({ effects: effects.diagnostics });
      throw sfzError("prepare", "The instrument uses an effect setting that cannot be prepared.");
    }
    for (const path of effectSamplePaths(effects)) {
      if (!embeddedSamples.has(path) && hasSample && !hasSample(path)) throw sfzError(
        "prepare",
        "An instrument effect sample could not be found. Select its complete folder and try again."
      );
      dependencies.add(path);
    }
    return {
      regions,
      dependencies: [...dependencies].sort(),
      diagnostics: detail,
      warnings,
      source: text2,
      headers,
      script,
      modulation: modulation2,
      effects,
      embeddedSamples,
      presentation: instrumentPresentation(headers, regions, directory),
      unsupportedOpcodes: [...detail.ignoredOpcodes, ...detail.unsupportedHeaders.map((name) => `<${name}>`)]
    };
  }
  var MAX_INCLUDE_VISITS, SUPPORTED, DEFAULTS, LOOP_MODES, NOTE_KEYS, INTEGER_KEYS, ENVELOPE_TIMES, HEADERS;
  var init_parser = __esm({
    "js/sfz/parser.js"() {
      init_schema();
      init_limits();
      init_generators();
      init_modulation();
      init_embedded_sample();
      init_region_sentinels();
      init_effects();
      init_effects_asset();
      MAX_INCLUDE_VISITS = 1e4;
      SUPPORTED = /* @__PURE__ */ new Set([
        "load_start",
        "load_end",
        "load_mode",
        "sample",
        "key",
        "lokey",
        "hikey",
        "lovel",
        "hivel",
        "lorand",
        "hirand",
        "seq_length",
        "seq_position",
        "pitch_keycenter",
        "pitch_keytrack",
        "transpose",
        "tune",
        "volume",
        "pan",
        "amp_veltrack",
        "offset",
        "end",
        "loop_mode",
        "loop_start",
        "loop_end",
        "ampeg_attack",
        "ampeg_hold",
        "ampeg_decay",
        "ampeg_sustain",
        "ampeg_release"
      ]);
      DEFAULTS = Object.freeze({
        lokey: 0,
        hikey: 127,
        lovel: 1,
        hivel: 127,
        lorand: 0,
        hirand: 1,
        seq_length: 1,
        seq_position: 1,
        pitch_keycenter: 60,
        pitch_keytrack: 100,
        transpose: 0,
        tune: 0,
        volume: 0,
        pan: 0,
        amp_veltrack: 100,
        offset: 0,
        loop_mode: 0,
        loop_start: 0,
        ampeg_attack: 0,
        ampeg_hold: 0,
        ampeg_decay: 0,
        ampeg_sustain: 100,
        ampeg_release: 1e-3
      });
      LOOP_MODES = /* @__PURE__ */ new Map([["no_loop", 0], ["one_shot", 1], ["loop_continuous", 2], ["loop_sustain", 3]]);
      NOTE_KEYS = /* @__PURE__ */ new Set(["key", "lokey", "hikey", "pitch_keycenter"]);
      INTEGER_KEYS = /* @__PURE__ */ new Set([
        "lokey",
        "hikey",
        "lovel",
        "hivel",
        "seq_length",
        "seq_position",
        "pitch_keycenter",
        "transpose",
        "offset",
        "end",
        "loop_start",
        "loop_end"
      ]);
      ENVELOPE_TIMES = /* @__PURE__ */ new Set(["ampeg_attack", "ampeg_hold", "ampeg_decay", "ampeg_release"]);
      HEADERS = /* @__PURE__ */ new Set(["control", "global", "master", "group", "region", "curve", "effect", "midi"]);
    }
  });

  // js/sfz/script-format.js
  var SFZ_SCRIPT_PROGRAM_VERSION;
  var init_script_format = __esm({
    "js/sfz/script-format.js"() {
      SFZ_SCRIPT_PROGRAM_VERSION = 2;
    }
  });

  // js/sfz/runtime-support.js
  function sfzRuntimeLimitations(modulation2, effects) {
    const limitations = /* @__PURE__ */ new Set();
    if (effects && (effects.version !== 1 || !Array.isArray(effects.nodes) || effects.nodes.some((node) => !completedEffects.has(node.type)))) limitations.add("effects");
    if (!modulation2 || ![3, 4].includes(modulation2.version)) return [...limitations];
    for (const region of modulation2.regions) {
      for (const instance of region.instances) {
        if (instance.kind <= SFZ_MOD_KINDS.Oscillator || instance.kind === SFZ_MOD_KINDS.InitialController || instance.kind >= SFZ_MOD_KINDS.Amplifier && instance.kind <= SFZ_MOD_KINDS.Crossfade || completedKinds.has(instance.kind)) continue;
        limitations.add(`kind:${instance.kind}`);
      }
    }
    return [...limitations];
  }
  var completedKinds, completedEffects;
  var init_runtime_support = __esm({
    "js/sfz/runtime-support.js"() {
      init_modulation_schema();
      init_effects();
      completedKinds = /* @__PURE__ */ new Set([
        SFZ_MOD_KINDS.SamplePlayback,
        SFZ_MOD_KINDS.Lifecycle,
        SFZ_MOD_KINDS.ReleaseDecaySegment,
        SFZ_MOD_KINDS.VoiceDSP,
        SFZ_MOD_KINDS.NoiseLayer,
        SFZ_MOD_KINDS.ReverseController,
        SFZ_MOD_KINDS.ControllerCondition,
        SFZ_MOD_KINDS.ControllerStart,
        SFZ_MOD_KINDS.ControllerStop,
        SFZ_MOD_KINDS.TempoCondition,
        SFZ_MOD_KINDS.TimerCondition,
        SFZ_MOD_KINDS.Equalizer,
        SFZ_MOD_KINDS.Variable
      ]);
      completedEffects = /* @__PURE__ */ new Set([
        SFZ_EFFECT_TYPES.apan,
        SFZ_EFFECT_TYPES.comp,
        SFZ_EFFECT_TYPES.delay,
        SFZ_EFFECT_TYPES.disto,
        SFZ_EFFECT_TYPES.eq,
        SFZ_EFFECT_TYPES.filter,
        SFZ_EFFECT_TYPES.fverb,
        SFZ_EFFECT_TYPES.gate,
        SFZ_EFFECT_TYPES.limiter,
        SFZ_EFFECT_TYPES.lofi,
        SFZ_EFFECT_TYPES.phaser,
        SFZ_EFFECT_TYPES.static,
        SFZ_EFFECT_TYPES.strings,
        SFZ_EFFECT_TYPES.tdfir,
        SFZ_EFFECT_TYPES.chorus,
        SFZ_EFFECT_TYPES.gain,
        SFZ_EFFECT_TYPES.rectify
      ]);
    }
  });

  // js/sfz/sample-reader.js
  async function createSfzMemorySampleReader(bytes) {
    bytes = bytes.slice();
    const revision = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((value) => value.toString(16).padStart(2, "0")).join("");
    return Object.freeze({
      size: bytes.byteLength,
      revision,
      rangeSource: { kind: "file", file: new Blob([bytes]), offset: 0, revision },
      async readRange(offset, length) {
        requireSfzSampleRange(offset, length, bytes.byteLength);
        return bytes.slice(offset, offset + length);
      }
    });
  }
  function requireSfzSampleRange(offset, length, size) {
    if (!Number.isSafeInteger(size) || size < 0 || !Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(length) || length < 0 || length > SFZ_SAMPLE_RANGE_MAX_BYTES || !Number.isSafeInteger(offset + length) || offset + length > size) {
      throw sfzError("prepare", "An instrument sample could not be read. Reload the instrument.");
    }
  }
  function fileRevision(file) {
    if (!Number.isSafeInteger(file?.size) || file.size < 0 || !Number.isFinite(file.lastModified) || typeof file.slice !== "function") {
      throw sfzError("prepare", "An instrument sample could not be opened.");
    }
    return `${file.size}:${file.lastModified}`;
  }
  async function createSfzFileSampleReader(source) {
    const file = typeof source?.getFile === "function" ? await source.getFile() : source;
    const revision = fileRevision(file), size = file.size;
    return Object.freeze({ size, revision, rangeSource: file instanceof Blob ? { kind: "file", file, handle: typeof source?.getFile === "function" ? source : null, offset: 0, revision } : null, async readRange(offset, length) {
      requireSfzSampleRange(offset, length, size);
      try {
        if (typeof source?.getFile === "function" && fileRevision(await source.getFile()) !== revision) {
          throw sfzError("source-changed", "An instrument sample changed. Reload the instrument.");
        }
        const bytes = new Uint8Array(await file.slice(offset, offset + length).arrayBuffer());
        if (bytes.byteLength !== length) throw new Error("Short sample range");
        return bytes;
      } catch (cause) {
        if (cause?.code === "source-changed") throw cause;
        throw sfzError("source-changed", "An instrument sample changed or could not be read. Reload the instrument.", cause);
      }
    } });
  }
  var SFZ_SAMPLE_RANGE_MAX_BYTES;
  var init_sample_reader = __esm({
    "js/sfz/sample-reader.js"() {
      init_parser();
      SFZ_SAMPLE_RANGE_MAX_BYTES = 1024 * 1024;
    }
  });

  // js/sf2/parser.js
  function sf2Error(detail) {
    const error2 = new Error("This SoundFont could not be loaded. Choose another sound source.");
    error2.code = "invalid-sf2";
    error2.diagnostic = detail;
    return error2;
  }
  async function parseSf2(reader) {
    if (!Number.isSafeInteger(reader?.size) || reader.size < 12 || typeof reader.readRange !== "function") {
      throw sf2Error("Invalid source reader");
    }
    let metadataBytes = 0, chunkCount = 0;
    const read = async (offset, length) => {
      if (!Number.isSafeInteger(offset + length) || offset < 0 || length < 0 || offset + length > reader.size || metadataBytes + length > MAX_METADATA_BYTES) throw sf2Error("Metadata bounds exceeded");
      metadataBytes += length;
      const bytes = new Uint8Array(length);
      for (let at = 0; at < length; at += SFZ_SAMPLE_RANGE_MAX_BYTES) {
        const count = Math.min(SFZ_SAMPLE_RANGE_MAX_BYTES, length - at);
        const part = await reader.readRange(offset + at, count);
        if (!(part instanceof Uint8Array) || part.byteLength !== count) throw sf2Error("Short metadata read");
        bytes.set(part, at);
      }
      return bytes;
    };
    const chunks = async (start, end) => {
      const result = /* @__PURE__ */ new Map();
      for (let offset = start; offset < end; ) {
        if (++chunkCount > 4096 || end - offset < 8) throw sf2Error("Invalid chunk directory");
        const header2 = await read(offset, 8);
        const length = new DataView(header2.buffer).getUint32(4, true);
        let next = offset + 8 + length;
        if (length % 2 && next < end && (await read(next, 1))[0] === 0) next++;
        if (next > end) throw sf2Error("Chunk exceeds parent");
        let name = tag(header2), dataOffset = offset + 8, dataLength = length;
        if (name === "LIST") {
          if (length < 4) throw sf2Error("Short LIST chunk");
          name = tag(await read(dataOffset, 4));
          dataOffset += 4;
          dataLength -= 4;
        }
        if (result.has(name)) throw sf2Error(`Duplicate chunk ${name}`);
        result.set(name, { offset: dataOffset, length: dataLength });
        offset = next;
      }
      return result;
    };
    const header = await read(0, 12);
    if (tag(header) !== "RIFF" || tag(header.subarray(8)) !== "sfbk" || new DataView(header.buffer).getUint32(4, true) + 8 !== reader.size) throw sf2Error("Invalid RIFF sfbk size or type");
    const directory = await chunks(12, reader.size);
    const sections = {};
    for (const name of ["INFO", "sdta", "pdta"]) {
      const entry = directory.get(name);
      if (!entry) throw sf2Error(`Missing ${name}`);
      sections[name] = await chunks(entry.offset, entry.offset + entry.length);
    }
    const info = {};
    let version;
    for (const [name, entry] of sections.INFO) {
      const bytes = await read(entry.offset, entry.length);
      if (name === "ifil") {
        if (bytes.length !== 4) throw sf2Error("Invalid ifil");
        const view = new DataView(bytes.buffer);
        version = { major: view.getUint16(0, true), minor: view.getUint16(2, true) };
      } else info[name] = ascii(bytes);
    }
    if (!version || ![2, 3].includes(version.major) || ![0, 1, 4].includes(version.minor)) throw sf2Error("Unsupported SoundFont version");
    const smpl = sections.sdta.get("smpl"), sm24 = sections.sdta.get("sm24");
    if (!smpl || version.major === 2 && smpl.length % 2) throw sf2Error("Missing or invalid sample pool");
    const sampleFrames = Math.floor(smpl.length / 2);
    const sm24Offset = (version.major === 3 || version.minor >= 4) && sm24 && (version.major === 3 || sm24.length === sampleFrames + sampleFrames % 2) ? sm24.offset : null;
    const tables = {};
    for (const [name, stride] of Object.entries(RECORD_BYTES)) {
      const entry = sections.pdta.get(name);
      if (!entry || entry.length % stride || entry.length / stride > 65536 || entry.length < stride * (["phdr", "inst", "shdr"].includes(name) ? 2 : 1)) {
        throw sf2Error(`Invalid ${name} table`);
      }
      const bytes = await read(entry.offset, entry.length), view = new DataView(bytes.buffer);
      const records = [];
      for (let at = 0; at < bytes.length; at += stride) {
        const u16 = (offset) => view.getUint16(at + offset, true);
        const i16 = (offset) => view.getInt16(at + offset, true);
        const u32 = (offset) => view.getUint32(at + offset, true);
        const nameText = () => ascii(bytes.subarray(at, at + 20));
        if (name === "phdr") records.push({ name: nameText(), program: u16(20), bank: u16(22), bag: u16(24), library: u32(26), genre: u32(30), morphology: u32(34) });
        else if (name === "inst") records.push({ name: nameText(), bag: u16(20) });
        else if (name === "shdr") records.push({
          name: nameText(),
          start: u32(20),
          end: u32(24),
          loopStart: u32(28),
          loopEnd: u32(32),
          sampleRate: u32(36),
          originalPitch: view.getUint8(at + 40),
          pitchCorrection: view.getInt8(at + 41),
          sampleLink: u16(42),
          sampleType: u16(44)
        });
        else if (name.endsWith("bag")) records.push({ generator: u16(0), modulator: u16(2) });
        else if (name.endsWith("gen")) records.push({ operator: u16(0), amount: i16(2), unsignedAmount: u16(2) });
        else records.push({ source: u16(0), destination: u16(2), amount: i16(4), amountSource: u16(6), transform: u16(8) });
      }
      tables[name] = records;
    }
    const validateIndices = (records, field, terminal) => {
      let previous = 0;
      for (const record of records) {
        if (record[field] < previous || record[field] > terminal) throw sf2Error(`Invalid ${field} index`);
        previous = record[field];
      }
      if (previous !== terminal) throw sf2Error(`Invalid terminal ${field} index`);
    };
    for (const [headerName, prefix] of [["phdr", "p"], ["inst", "i"]]) {
      const bags = tables[`${prefix}bag`];
      validateIndices(tables[headerName], "bag", bags.length - 1);
      validateIndices(bags, "generator", tables[`${prefix}gen`].length - 1);
      validateIndices(bags, "modulator", tables[`${prefix}mod`].length - 1);
    }
    return {
      format: version.major === 3 ? "sf3" : "sf2",
      version,
      info,
      tables,
      smplOffset: smpl.offset,
      smplBytes: smpl.length,
      sm24Bytes: sm24?.length || 0,
      sm24Offset,
      sampleFrames,
      metadataBytes,
      presets: tables.phdr.slice(0, -1).map((preset, index) => ({ ...preset, index }))
    };
  }
  var MAX_METADATA_BYTES, RECORD_BYTES, ascii, tag;
  var init_parser2 = __esm({
    "js/sf2/parser.js"() {
      init_sample_reader();
      MAX_METADATA_BYTES = 16 * 1024 * 1024;
      RECORD_BYTES = { phdr: 38, pbag: 4, pmod: 10, pgen: 4, inst: 22, ibag: 4, imod: 10, igen: 4, shdr: 46 };
      ascii = (bytes) => new TextDecoder("windows-1252").decode(bytes).replace(/\0.*$/s, "");
      tag = (bytes) => String.fromCharCode(...bytes.subarray(0, 4));
    }
  });

  // js/sf2/modulation.js
  function packSf2Modulation(compiled) {
    const regionCount = compiled.regions.length;
    const routeCount = compiled.regions.reduce((count, region) => count + region.modulators.length, 0);
    if (routeCount > 1048576) throw sf2Error("Too many SoundFont modulation routes");
    const directoryOffset = HEADER_WORDS, routeOffset = directoryOffset + regionCount * DIRECTORY_WORDS;
    const generatorOffset = routeOffset + routeCount * ROUTE_WORDS;
    const buffer = new ArrayBuffer((generatorOffset + regionCount * GENERATOR_WORDS) * 4);
    const integers = new Uint32Array(buffer), values = new Float32Array(buffer);
    integers.set([
      827479123,
      SF2_MODULATION_SECTION_VERSION,
      regionCount,
      routeCount,
      0,
      directoryOffset,
      routeOffset,
      generatorOffset,
      generatorOffset,
      regionCount * GENERATOR_WORDS
    ]);
    let first = 0;
    for (const [regionIndex, region] of compiled.regions.entries()) {
      const routes = region.modulators, incoming = new Uint32Array(routes.length);
      if (routes.length > 65536) throw sf2Error("Too many modulation routes in a SoundFont zone");
      for (const route of routes) if (route.link >= 0) {
        if (route.link >= routes.length) throw sf2Error("Invalid modulation link");
        incoming[route.link]++;
      }
      const order = [];
      for (let index = 0; index < routes.length; index++) if (!incoming[index]) order.push(index);
      for (let at = 0; at < order.length; at++) {
        const target = routes[order[at]].link;
        if (target >= 0 && --incoming[target] === 0) order.push(target);
      }
      if (order.length !== routes.length) throw sf2Error("Circular compiled modulation");
      const indices = new Map(order.map((oldIndex, newIndex) => [oldIndex, newIndex]));
      integers.set([first, routes.length, regionIndex * GENERATOR_WORDS, GENERATOR_WORDS], directoryOffset + regionIndex * DIRECTORY_WORDS);
      if (region.generators.length !== GENERATOR_WORDS || region.generators.some((value) => !Number.isFinite(Math.fround(value)))) {
        throw sf2Error("Invalid compiled generator vector");
      }
      values.set(region.generators, generatorOffset + regionIndex * GENERATOR_WORDS);
      for (const index of order) {
        const route = routes[index], offset = routeOffset + first * ROUTE_WORDS;
        integers[offset] = route.link < 0 ? 65536 | route.destination : 131072 | indices.get(route.link);
        integers[offset + 1] = (route.source & 255) === 127 ? 131072 | indices.get(index) : route.source;
        integers[offset + 2] = route.amountSource;
        values[offset + 3] = route.amount;
        integers[offset + 8] = (route.source & 255) === 127 ? route.source : 0;
        integers[offset + 9] = route.transform;
        first++;
      }
    }
    return new Uint8Array(buffer);
  }
  var SF2_MODULATION_SECTION_VERSION, HEADER_WORDS, DIRECTORY_WORDS, ROUTE_WORDS, GENERATOR_WORDS;
  var init_modulation2 = __esm({
    "js/sf2/modulation.js"() {
      init_parser2();
      SF2_MODULATION_SECTION_VERSION = 2;
      HEADER_WORDS = 10;
      DIRECTORY_WORDS = 4;
      ROUTE_WORDS = 10;
      GENERATOR_WORDS = 61;
    }
  });

  // js/sfz/asset.js
  function sfzAssetWarmupSamples(payload) {
    const header = new DataView(payload, 32, 32);
    const regionCount = header.getUint32(8, true);
    const words = header.getUint32(20, true);
    const preparationOperations = 2 * regionCount + 2 + Math.ceil(words / 32);
    return Math.ceil(preparationOperations / 8);
  }
  function sfzAssetTailSeconds(payload, dataEntry = null) {
    if (!(payload instanceof ArrayBuffer) || payload.byteLength < 32 + HEADER_WORDS2 * 4 || payload.byteLength % 4) return null;
    const words = new Uint32Array(payload, 32), values = new Float32Array(payload, 32);
    if (words[0] !== 5457498 || words[1] !== 6 || words[3] !== 113 || SFZ_REGION_FIELDS.length !== 113 || Object.keys(SFZ_CONTROLLER_FAMILIES).length !== 26 || words[9] !== 0 || words[11] !== 0 || words[4] > words.length || HEADER_WORDS2 + words[2] * words[3] > words[4]) return null;
    const indices = Object.fromEntries(SFZ_REGION_FIELDS.map((name, index) => [name, index]));
    let initialCoarse = 0, initialFine = 0, tailSeconds = 0.2;
    for (let index = 0; index < words[2]; index++) {
      const base = HEADER_WORDS2 + index * words[3];
      const get = (name) => (INDEX_FIELDS.has(name) ? words : values)[base + indices[name]];
      const start = get("controlOffset"), count = get("controlCount");
      if (start < HEADER_WORDS2 + words[2] * words[3] || start + 2 * count > words[4]) return null;
      let pitchControllers = 0, pitchMagnitude = 0, controllerTrigger = false;
      let releaseControllers = 0, envelopeDelayControllers = 0;
      for (let cursor = start; cursor < start + 2 * count; cursor += 2) {
        const id = words[cursor], value = values[cursor + 1], family = Math.floor(id / 512), cc = id % 512;
        if (!Number.isFinite(value) || family > 25 || cc > 127) return null;
        if (family === 5) {
          pitchControllers += Math.min(0, value);
          pitchMagnitude += Math.abs(value);
        }
        if (family === 8 || family === 9) controllerTrigger = true;
        if (family === 10) envelopeDelayControllers += Math.max(0, value);
        if (family === 16) releaseControllers += Math.max(0, value);
        if (index === 0 && family === 2 && cc === 6) initialCoarse = value;
        if (index === 0 && family === 2 && cc === 38) initialFine = value;
      }
      const maximumRelease = Math.min(100, get("ampeg_release") + releaseControllers);
      const maximumEnvelopeDelay = Math.min(100, get("ampeg_delay") + envelopeDelayControllers);
      let tail = Math.max(maximumRelease, get("off_time"));
      const sampleTail = get("loop_mode") === 1 || get("trigger") === 1 || get("trigger") === 2 || controllerTrigger;
      if (sampleTail) {
        const looped = get("loop_mode") === 2 || get("loop_mode") === 3;
        if (looped && get("loop_count") < 0) return null;
        const bendRange = dataEntry ? Math.max(2, Math.max(initialCoarse, dataEntry.coarse) + Math.max(initialFine, dataEntry.fine) * 0.01) : 2;
        const key = Math.min(
          (get("lokey") - get("pitch_keycenter")) * get("pitch_keytrack"),
          (get("hikey") - get("pitch_keycenter")) * get("pitch_keytrack"),
          controllerTrigger ? (60 - get("pitch_keycenter")) * get("pitch_keytrack") : Infinity
        );
        const velocity = Math.min(
          get("pitch_veltrack") * get("lovel") / 127,
          get("pitch_veltrack") * get("hivel") / 127
        );
        const bend = Math.min(0, get("bend_down"), get("bend_up")) * bendRange / 2;
        let cents = key + get("transpose") * 100 + get("tune") + velocity - Math.abs(get("pitch_random")) + pitchControllers + bend + Math.min(0, get("pitcheg_depth")) - Math.abs(get("pitchlfo_depth"));
        const magnitude = Math.abs(key) + Math.abs(get("transpose") * 100) + Math.abs(get("tune")) + Math.abs(velocity) + Math.abs(get("pitch_random")) + pitchMagnitude + Math.abs(bend) + Math.abs(get("pitcheg_depth")) + Math.abs(get("pitchlfo_depth"));
        cents -= 1 + magnitude * 512 * 2 ** -23;
        const frames = get("end") - get("offset") + 2 + (looped ? Math.max(0, get("loop_count")) * (get("loop_end") - get("loop_start") + 1) : 0);
        tail = Math.max(tail, frames / get("sampleRate") / 2 ** (cents / 1200));
      }
      tail += get("delay") + get("delay_random") + maximumEnvelopeDelay;
      if (!Number.isFinite(tail) || tail < 0) return null;
      tailSeconds = Math.max(tailSeconds, tail);
    }
    return tailSeconds;
  }
  function sfzSampleCacheFootprint(sampleCount, cacheSlots, channels = 2, storage = null) {
    if (!Number.isInteger(sampleCount) || sampleCount < 1 || sampleCount > 1e4 || !Number.isInteger(cacheSlots) || cacheSlots < 1 || cacheSlots > 32768 || channels !== 1 && channels !== 2 || storage && (!Number.isInteger(storage.slots16) || storage.slots16 < 0 || storage.slots16 > cacheSlots)) throw sfzError("prepare", "Invalid SFZ sample cache capacity.");
    let buckets = 1;
    while (buckets < cacheSlots * SFZ_MOD_STORAGE.CacheHashLoad) buckets *= 2;
    const slots16 = storage?.slots16 ?? 0;
    return SFZ_MOD_STORAGE.CachePageFrames * channels * ((cacheSlots - slots16) * Float32Array.BYTES_PER_ELEMENT + slots16 * Int16Array.BYTES_PER_ELEMENT) + cacheSlots * SFZ_MOD_STORAGE.CachePageBytes + buckets * Uint32Array.BYTES_PER_ELEMENT + sampleCount * (2 * SFZ_MOD_STORAGE.CacheSampleMetadataBytes + (storage ? 2 * SFZ_MOD_STORAGE.CacheModeBytes : 0)) + SFZ_MOD_STORAGE.CacheRequestCapacity * SFZ_MOD_STORAGE.CacheRequestBytes + cacheSlots * SFZ_MOD_STORAGE.CacheForecastPageBytes + SFZ_MOD_STORAGE.CacheForecastSourceBytes * SFZ_MOD_STORAGE.CacheForecastSourceCapacity;
  }
  function sfzRequiresSampleStreaming(regions) {
    return regions.some((region) => region.load_mode !== void 0 || region.load_start !== void 0 || region.load_end !== void 0);
  }
  function packStreamedSfzAsset(regions, samples, { cacheSlots, storagePlan = null, ...options } = {}) {
    return packSfzAsset(regions, samples, { ...options, stream: { cacheSlots, storagePlan } });
  }
  function packSfzAsset(regions, samples, {
    maxBytes = SFZ_DEFAULT_MAX_BYTES,
    onWarning,
    script = null,
    stream = null,
    modulation: modulation2 = null,
    effects = null,
    sourceProfile = null,
    presets = null,
    preparationContext = null,
    onDiagnostic = (detail) => console.warn("SFZ sample preparation:", detail)
  } = {}) {
    requireSfzMaxBytes(maxBytes);
    if (!stream && sfzRequiresSampleStreaming(regions))
      throw sfzError("prepare", "This instrument needs sample streaming, which is unavailable in this audio configuration.");
    const soundFont = sourceProfile !== null;
    const genericModulation = !soundFont && modulation2?.version === 3;
    if (soundFont && (!stream || !["sf2-2.00", "sf2-2.01", "sf2-2.04", "sf3-3.00", "sf3-3.01", "sf3-3.04"].includes(sourceProfile) || !Array.isArray(presets))) {
      throw sfzError("prepare", "The SoundFont collection could not be prepared.");
    }
    const storagePlan = !soundFont && stream?.storagePlan;
    const headerWords = storagePlan ? SFZ_STORAGE_TABLE_HEADER_WORDS : soundFont ? SF2_TABLE_HEADER_WORDS : stream ? SFZ_STREAM_TABLE_HEADER_WORDS : HEADER_WORDS2;
    const scriptBytes = script?.bytes ?? new Uint8Array();
    if (!(scriptBytes instanceof Uint8Array) || scriptBytes.byteLength % 4 || script && (script.version !== SFZ_SCRIPT_PROGRAM_VERSION || scriptBytes.byteLength < 64 || scriptBytes.byteLength > 64 + 128 * 16 + 512 * 144 + 8192 * 16)) {
      throw sfzError("prepare", "The instrument script could not be prepared.");
    }
    if (!regions.length) throw sfzError("no-regions", "The SFZ has no playable regions.");
    const impulsePaths = effectSamplePaths(effects);
    let samplePaths = [.../* @__PURE__ */ new Set([...regions.map((region) => region.sample), ...impulsePaths])].sort();
    const sampleInfo = /* @__PURE__ */ new Map();
    let poolLength = 0;
    for (const path of samplePaths) {
      const pcm = samples.get(path);
      if (stream) {
        if (!Number.isSafeInteger(pcm?.frames) || pcm.frames < 1 || pcm.channels !== 1 && pcm.channels !== 2 || !Number.isInteger(pcm.sampleRate) || pcm.sampleRate < 1 || pcm.sampleRate > 768e3 || !/^[a-f0-9]{64}$/.test(pcm.revision)) {
          throw sfzError("prepare", "The SFZ sample metadata could not be prepared.");
        }
        sampleInfo.set(path, { sampleFrames: pcm.frames, channels: pcm.channels, sampleRate: pcm.sampleRate });
        continue;
      }
      const channels = pcm?.channels;
      const frames = channels?.[0]?.length;
      if (!Array.isArray(channels) || channels.length < 1 || channels.length > 2 || !frames || channels.some((channel) => !(channel instanceof Float32Array) || channel.length !== frames) || !Number.isSafeInteger(pcm.sampleRate) || pcm.sampleRate < 1 || pcm.sampleRate > 768e3) {
        throw sfzError("prepare", "SFZ samples must contain mono or stereo audio.");
      }
      sampleInfo.set(path, { sampleFrames: frames, channels: channels.length, sampleRate: pcm.sampleRate });
    }
    const playable = [];
    const playableIndices = [];
    const invalidRegions = [];
    let firstInvalid;
    let ignoredLoopPoints = 0;
    for (const [regionIndex, region] of regions.entries()) {
      const info = sampleInfo.get(region.sample);
      const end = region.end ?? info.sampleFrames - 1;
      const normalized = { ...SFZ_EXTRA_DEFAULTS, ...region, ...info, end, loop_end: region.loop_end ?? end, controlOffset: 0, controlCount: 0 };
      if (!soundFont) normalized.offset = resolveSfzRegionOffset(region, info.sampleFrames);
      if (!soundFont && normalized.loop_count > 16777216) normalized.loop_count = -1;
      try {
        if (normalized.offset > end || end >= info.sampleFrames || end < 0) {
          throw sfzError("prepare", "SFZ playback points exceed the sample.");
        }
        const invalidLoop = normalized.loop_start < 0 || normalized.loop_start > normalized.loop_end || normalized.loop_end > end;
        if (invalidLoop && (normalized.loop_mode === 0 || normalized.loop_mode === 1)) {
          normalized.loop_start = 0;
          normalized.loop_end = end;
        } else if (invalidLoop) throw sfzError("prepare", "SFZ loop points exceed the sample.");
        for (const key of SFZ_REGION_FIELDS) {
          if (key === "sampleOffset") continue;
          const value = normalized[key];
          if (!Number.isFinite(value)) throw sfzError("prepare", "SFZ region has invalid values.");
          if (INDEX_FIELDS.has(key) && (!Number.isSafeInteger(value) || value < 0 || value > 4294967295)) {
            throw sfzError("prepare", "SFZ sample positions must be non-negative integers.");
          }
        }
        if (invalidLoop) ignoredLoopPoints++;
        playable.push(normalized);
        playableIndices.push(regionIndex);
      } catch (error2) {
        if (error2?.code !== "prepare") throw error2;
        firstInvalid ??= error2;
        invalidRegions.push(`${region.sample}: ${error2.message}`);
      }
    }
    if (invalidRegions.length) onDiagnostic?.({ invalidRegions });
    if (soundFont && invalidRegions.length) throw firstInvalid;
    if (!playable.length) throw firstInvalid;
    regions = playable;
    if (!soundFont) {
      const ids = [...new Set(regions.flatMap((region) => [region.group, region.off_by]).filter((id) => id !== 0))].sort((a, b2) => a - b2);
      if (ids.length > 16777216) throw sfzError("too-large", "The instrument has too many exclusive groups.");
      const tokens = new Map(ids.map((id, index) => [id, index + 1]));
      regions = regions.map((region) => ({ ...region, group: tokens.get(region.group) ?? 0, off_by: tokens.get(region.off_by) ?? 0 }));
    }
    if (!stream) samplePaths = [.../* @__PURE__ */ new Set([...regions.map((region) => region.sample), ...impulsePaths])].sort();
    for (const [sampleIndex, path] of samplePaths.entries()) {
      const info = sampleInfo.get(path);
      info.sampleOffset = stream ? sampleIndex : poolLength;
      if (!stream) poolLength += info.sampleFrames * info.channels;
    }
    const groupIds = [...new Set(regions.map((region) => region.seqGroup))].sort((a, b2) => a - b2);
    const groupCount = groupIds.length;
    const groups = new Map(groupIds.map((id, index) => [id, index]));
    const controls = regions.map((region) => {
      const entries = [];
      for (const [key, value] of Object.entries(region)) {
        const route = sfzControllerOpcode(key);
        if (!route || value === SFZ_CONTROLLER_FAMILIES[route.family]) continue;
        if (genericModulation && !["locc", "hicc", "set_cc", "on_locc", "on_hicc"].includes(route.family)) continue;
        if (!Number.isFinite(value)) throw sfzError("prepare", "SFZ controller has an invalid value.");
        entries.push([CONTROLLER_IDS.get(route.family) * 512 + route.controller, value]);
      }
      return entries.sort((a, b2) => a[0] - b2[0]);
    });
    const controlWords = controls.reduce((sum, entries) => sum + 2 * entries.length, 0);
    const controlOffset = headerWords + SFZ_REGION_FIELDS.length * regions.length;
    const scriptOffset = controlOffset + controlWords;
    let modulationBytes = soundFont ? packSf2Modulation(modulation2) : modulation2 ? packSfzModulation({
      ...modulation2,
      regions: playableIndices.map((index) => modulation2.regions[index])
    }) : new Uint8Array();
    if (effects) {
      if (soundFont || !genericModulation) throw sfzError("prepare", "The instrument effects could not be prepared.");
      modulationBytes = packSfzEffectModulation(modulationBytes, {
        ...effects,
        regions: playableIndices.map((index) => effects.regions[index])
      }, (path) => {
        const info = sampleInfo.get(path);
        return info && {
          sampleOffsetOrId: info.sampleOffset,
          frames: info.sampleFrames,
          channels: info.channels,
          rate: info.sampleRate
        };
      });
    }
    const modulationOffset = scriptOffset + scriptBytes.byteLength / 4;
    const sampleTableOffset = modulationOffset + modulationBytes.byteLength / 4;
    const sampleWords = storagePlan ? 16 : 12;
    const residentRows = storagePlan ? samplePaths.flatMap((path) => storagePlan.residentRanges.get(path)) : [];
    const residentOffset = sampleTableOffset + (stream ? samplePaths.length * sampleWords : 0);
    const presetOffset = residentOffset + residentRows.length * 4;
    if (storagePlan && (!Number.isInteger(storagePlan.slots16) || storagePlan.slots16 < 0 || storagePlan.slots16 > stream.cacheSlots))
      throw sfzError("prepare", "Invalid instrument sample storage capacity.");
    const poolOffset = presetOffset + (soundFont ? presets.length * 4 : 0);
    const floatCount = poolOffset + poolLength;
    const byteLength = 32 + floatCount * 4;
    const sampleCacheBytes = stream ? sfzSampleCacheFootprint(
      samplePaths.length,
      stream.cacheSlots,
      samplePaths.some((path) => sampleInfo.get(path).channels === 2) ? 2 : 1,
      storagePlan
    ) : 0;
    const footprintBytes = byteLength;
    if (!Number.isSafeInteger(footprintBytes) || footprintBytes > maxBytes) {
      throw sfzError("too-large", "The SFZ samples are too large to load.");
    }
    const payload = new ArrayBuffer(byteLength);
    const outer = new DataView(payload);
    outer.setUint32(0, 826364997, true);
    outer.setUint32(4, 1, true);
    outer.setUint32(8, floatCount, true);
    outer.setUint32(12, 1, true);
    const packed = new Float32Array(payload, 32);
    const integers = new Uint32Array(payload, 32);
    integers.set([
      5457498,
      storagePlan ? SFZ_STORAGE_TABLE_VERSION : soundFont ? SF2_TABLE_VERSION : stream ? SFZ_STREAM_TABLE_VERSION : genericModulation ? SFZ_MODULATION_TABLE_VERSION : SFZ_TABLE_VERSION,
      regions.length,
      SFZ_REGION_FIELDS.length,
      poolOffset,
      floatCount,
      groupCount,
      controlWords,
      scriptOffset,
      scriptBytes.byteLength,
      modulationBytes.length ? modulationOffset : 0,
      modulationBytes.length / 4
    ]);
    if (stream) integers.set([sampleTableOffset, samplePaths.length, stream.cacheSlots, soundFont ? 65537 : storagePlan ? 2 : 1], 12);
    if (storagePlan) integers.set([storagePlan.slots16, residentOffset, residentRows.length, 0], 16);
    if (soundFont) {
      integers.set([presetOffset, presets.length], 16);
      for (const [index, preset] of presets.entries()) {
        const row = [preset.bank, preset.program, preset.firstRegion, preset.regionCount];
        if (row.some((value) => !Number.isSafeInteger(value) || value < 0 || value > 4294967295) || preset.firstRegion + preset.regionCount > regions.length) throw sfzError("prepare", "Invalid SoundFont preset directory.");
        integers.set(row, presetOffset + index * 4);
      }
    }
    new Uint8Array(payload, 32 + scriptOffset * 4, scriptBytes.byteLength).set(scriptBytes);
    new Uint8Array(payload, 32 + modulationOffset * 4, modulationBytes.byteLength).set(modulationBytes);
    let nextControl = controlOffset;
    for (const [index, region] of regions.entries()) {
      const info = sampleInfo.get(region.sample);
      const normalized = {
        ...region,
        ...info,
        seqGroup: groups.get(region.seqGroup),
        controlOffset: nextControl,
        controlCount: controls[index].length
      };
      for (const [id, value] of controls[index]) {
        integers[nextControl++] = id;
        packed[nextControl++] = value;
      }
      for (const [field, key] of SFZ_REGION_FIELDS.entries()) {
        const offset = headerWords + index * SFZ_REGION_FIELDS.length + field;
        if (INDEX_FIELDS.has(key)) integers[offset] = normalized[key];
        else packed[offset] = normalized[key];
      }
    }
    let residentCursor = 0;
    for (const path of samplePaths) {
      const pcm = samples.get(path);
      const info = sampleInfo.get(path);
      if (stream) {
        const offset = sampleTableOffset + info.sampleOffset * sampleWords;
        integers.set([pcm.frames >>> 0, Math.floor(pcm.frames / 4294967296), pcm.channels, pcm.sampleRate], offset);
        new Uint8Array(payload, 32 + (offset + 4) * 4, 32).set(pcm.revision.match(/../g).map((byte) => parseInt(byte, 16)));
        if (storagePlan) {
          const mode = pcm.storageMode ?? 0, intervals = storagePlan.residentRanges.get(path);
          if (![0, 1].includes(mode) || (mode ? !storagePlan.slots16 : storagePlan.slots16 === stream.cacheSlots))
            throw sfzError("prepare", "Invalid instrument sample storage format.");
          integers.set([mode, residentCursor, intervals.length, 0], offset + 12);
          let previous = -1;
          for (const [first, end] of intervals) {
            if (!Number.isSafeInteger(first) || !Number.isSafeInteger(end) || first < 0 || first <= previous || first >= end || end > pcm.frames)
              throw sfzError("prepare", "Invalid instrument sample residency range.");
            integers.set([first >>> 0, Math.floor(first / 4294967296), end >>> 0, Math.floor(end / 4294967296)], residentOffset + residentCursor++ * 4);
            previous = end;
          }
        }
        continue;
      }
      let cursor = poolOffset + info.sampleOffset;
      const poolWriter = globalThis.__effectdeckSfzPoolWriter;
      if (typeof poolWriter === "function") {
        poolWriter(path, cursor, info.sampleFrames, pcm.channels.length, pcm.channels);
        continue;
      }
      for (let frame = 0; frame < info.sampleFrames; frame++) {
        for (const channel of pcm.channels) {
          const value = channel[frame];
          if (!Number.isFinite(value)) throw sfzError("prepare", "SFZ audio contains invalid samples.");
          packed[cursor++] = value;
        }
      }
    }
    if (ignoredLoopPoints) onWarning?.({ code: "loop-points-ignored", count: ignoredLoopPoints });
    if (invalidRegions.length) onWarning?.({ code: "invalid-regions", count: invalidRegions.length });
    return {
      ...stream && { sampleCacheBytes },
      payload,
      warmupSamples: sfzAssetWarmupSamples(payload),
      tailSeconds: sfzAssetTailSeconds(payload),
      unsupportedRuntime: soundFont ? [] : sfzRuntimeLimitations(modulation2, effects),
      channels: 1,
      samples: floatCount,
      sampleRate: 1,
      layout: 0,
      formatTag: 1,
      rateDivider: 1,
      headBlock: 128,
      processingChannels: preparationContext?.processingChannels ?? 1,
      footprintBytes,
      ...preparationContext && { preparationContext }
    };
  }
  var SFZ_TABLE_VERSION, SFZ_MODULATION_TABLE_VERSION, SFZ_TABLE_HEADER_WORDS, SFZ_STREAM_TABLE_VERSION, SFZ_STREAM_TABLE_HEADER_WORDS, SFZ_STORAGE_TABLE_VERSION, SFZ_STORAGE_TABLE_HEADER_WORDS, SF2_TABLE_VERSION, SF2_TABLE_HEADER_WORDS, HEADER_WORDS2, SFZ_REGION_FIELDS, INDEX_FIELDS, CONTROLLER_IDS;
  var init_asset = __esm({
    "js/sfz/asset.js"() {
      init_modulation_schema();
      init_schema();
      init_parser();
      init_limits();
      init_script_format();
      init_modulation();
      init_runtime_support();
      init_effects_asset();
      init_modulation2();
      SFZ_TABLE_VERSION = 6;
      SFZ_MODULATION_TABLE_VERSION = 7;
      SFZ_TABLE_HEADER_WORDS = 12;
      SFZ_STREAM_TABLE_VERSION = 8;
      SFZ_STREAM_TABLE_HEADER_WORDS = 16;
      SFZ_STORAGE_TABLE_VERSION = 10;
      SFZ_STORAGE_TABLE_HEADER_WORDS = 20;
      SF2_TABLE_VERSION = 9;
      SF2_TABLE_HEADER_WORDS = 18;
      HEADER_WORDS2 = SFZ_TABLE_HEADER_WORDS;
      SFZ_REGION_FIELDS = Object.freeze([
        "sampleOffset",
        "sampleFrames",
        "channels",
        "sampleRate",
        "lokey",
        "hikey",
        "lovel",
        "hivel",
        "lorand",
        "hirand",
        "seq_length",
        "seq_position",
        "seqGroup",
        "pitch_keycenter",
        "pitch_keytrack",
        "transpose",
        "tune",
        "volume",
        "pan",
        "amp_veltrack",
        "offset",
        "end",
        "loop_mode",
        "loop_start",
        "loop_end",
        "ampeg_attack",
        "ampeg_hold",
        "ampeg_decay",
        "ampeg_sustain",
        "ampeg_release",
        ...Object.keys(SFZ_EXTRA_DEFAULTS),
        "controlOffset",
        "controlCount"
      ]);
      INDEX_FIELDS = /* @__PURE__ */ new Set(["sampleOffset", "sampleFrames", "offset", "end", "loop_start", "loop_end", "controlOffset", "controlCount"]);
      CONTROLLER_IDS = new Map(Object.keys(SFZ_CONTROLLER_FAMILIES).map((family, index) => [family, index]));
    }
  });

  // js/ir-library/ir-library-limits.js
  function maxIrLibraryBytesForName(name, namespace = "ir-library") {
    if (name === "index.json") return IR_LIBRARY_MAX_INDEX_BYTES;
    if (ANALYSIS_NAME_PATTERN.test(name)) return IR_LIBRARY_MAX_ANALYSIS_BYTES;
    if (namespace === "sfz-library" && /^[a-f0-9]{24}\.sfzbank$/.test(name)) return SFZ_MAX_SUPPORTED_BYTES;
    return IR_LIBRARY_MAX_ORIGINAL_BYTES;
  }
  function maxIrCacheBytesForName(name) {
    return name === "index.json" ? IR_LIBRARY_MAX_CACHE_INDEX_BYTES : IR_LIBRARY_MAX_CACHE_ENTRY_BYTES;
  }
  function requireBoundedIrBytes(value, maxBytes, label = "IR library data") {
    const byteLength = value instanceof ArrayBuffer || ArrayBuffer.isView(value) ? value.byteLength : null;
    if (!Number.isSafeInteger(byteLength)) throw new TypeError(`${label} must be binary.`);
    if (byteLength > maxBytes) throw new RangeError(`${label} is too large.`);
    return byteLength;
  }
  var IR_LIBRARY_MAX_ORIGINAL_BYTES, IR_LIBRARY_MAX_INDEX_BYTES, IR_LIBRARY_MAX_ANALYSIS_BYTES, IR_LIBRARY_MAX_CACHE_ENTRY_BYTES, IR_LIBRARY_MAX_CACHE_INDEX_BYTES, IR_LIBRARY_INDEX_TOO_LARGE_CODE, ANALYSIS_NAME_PATTERN;
  var init_ir_library_limits = __esm({
    "js/ir-library/ir-library-limits.js"() {
      init_limits();
      IR_LIBRARY_MAX_ORIGINAL_BYTES = 64 * 1024 * 1024;
      IR_LIBRARY_MAX_INDEX_BYTES = 32 * 1024 * 1024;
      IR_LIBRARY_MAX_ANALYSIS_BYTES = 4 * 1024 * 1024;
      IR_LIBRARY_MAX_CACHE_ENTRY_BYTES = 64 * 1024 * 1024;
      IR_LIBRARY_MAX_CACHE_INDEX_BYTES = 4 * 1024 * 1024;
      IR_LIBRARY_INDEX_TOO_LARGE_CODE = "ir-library-index-too-large";
      ANALYSIS_NAME_PATTERN = /^[a-f0-9]{24}(?:\.analysis|\.a[0-9]{9})$/;
    }
  });

  // js/ir-library/library-namespace.js
  function requireLibraryNamespace(namespace = "ir-library") {
    if (namespace !== "ir-library" && namespace !== "sfz-library") {
      throw new TypeError("Invalid audio library namespace.");
    }
    return namespace;
  }
  var init_library_namespace = __esm({
    "js/ir-library/library-namespace.js"() {
    }
  });

  // js/ir-library/electron-ir-library-backend.js
  function responseData(response, allowedCode = null) {
    if (response?.ok === true) return response.data;
    const indexTooLarge = allowedCode === IR_LIBRARY_INDEX_TOO_LARGE_CODE && response?.code === IR_LIBRARY_INDEX_TOO_LARGE_CODE;
    const error2 = new Error(indexTooLarge ? "The IR library index is too large." : "The IR library storage request failed.");
    if (indexTooLarge) error2.code = IR_LIBRARY_INDEX_TOO_LARGE_CODE;
    throw error2;
  }
  var ElectronIrLibraryBackend;
  var init_electron_ir_library_backend = __esm({
    "js/ir-library/electron-ir-library-backend.js"() {
      init_ir_library_limits();
      init_library_namespace();
      ElectronIrLibraryBackend = class {
        constructor(bridge, namespace = "ir-library") {
          if (!bridge || bridge.apiVersion !== 1) throw new Error("The IR library bridge is unavailable.");
          this.bridge = bridge;
          this.namespace = requireLibraryNamespace(namespace);
        }
        async read(name) {
          const allowedCode = name === "index.json" ? IR_LIBRARY_INDEX_TOO_LARGE_CODE : null;
          const data = responseData(await this.bridge.read({ name, namespace: this.namespace }), allowedCode);
          if (data === null) return null;
          requireBoundedIrBytes(data, maxIrLibraryBytesForName(name, this.namespace), "IR library item");
          return data instanceof Uint8Array ? data : new Uint8Array(data);
        }
        async exists(name) {
          return responseData(await this.bridge.exists({ name, namespace: this.namespace })) === true;
        }
        async writeAtomic(name, bytes) {
          requireBoundedIrBytes(bytes, maxIrLibraryBytesForName(name, this.namespace), "IR library item");
          responseData(await this.bridge.writeAtomic({ name, bytes, namespace: this.namespace }));
        }
        async remove(name) {
          responseData(await this.bridge.remove({ name, namespace: this.namespace }));
        }
        async list() {
          return responseData(await this.bridge.list({ namespace: this.namespace }));
        }
        async cleanupTemporary() {
          responseData(await this.bridge.cleanupTemporary({ namespace: this.namespace }));
        }
        async readCache(name) {
          const data = responseData(await this.bridge.readCache({ name, namespace: this.namespace }));
          if (data === null) return null;
          requireBoundedIrBytes(data, maxIrCacheBytesForName(name), "IR cache item");
          return data instanceof Uint8Array ? data : new Uint8Array(data);
        }
        async writeCacheAtomic(name, bytes) {
          requireBoundedIrBytes(bytes, maxIrCacheBytesForName(name), "IR cache item");
          responseData(await this.bridge.writeCacheAtomic({ name, bytes, namespace: this.namespace }));
        }
        async removeCache(name) {
          responseData(await this.bridge.removeCache({ name, namespace: this.namespace }));
        }
        async listCache() {
          return responseData(await this.bridge.listCache({ namespace: this.namespace }));
        }
      };
    }
  });

  // js/ir-library/ir-library-id.js
  var init_ir_library_id = __esm({
    "js/ir-library/ir-library-id.js"() {
    }
  });

  // js/ir-library/ir-library-name.js
  var init_ir_library_name = __esm({
    "js/ir-library/ir-library-name.js"() {
    }
  });

  // js/ir-library/ir-analysis-sidecar.js
  var init_ir_analysis_sidecar = __esm({
    "js/ir-library/ir-analysis-sidecar.js"() {
    }
  });

  // js/ir-library/ir-library-store.js
  var IR_LIBRARY_INDEX_NAME, encoder, decoder;
  var init_ir_library_store = __esm({
    "js/ir-library/ir-library-store.js"() {
      init_ir_library_id();
      init_ir_library_name();
      init_ir_analysis_sidecar();
      init_ir_library_limits();
      IR_LIBRARY_INDEX_NAME = "index.json";
      encoder = new TextEncoder();
      decoder = new TextDecoder();
    }
  });

  // js/ir-library/ir-pcm-cache.js
  function stableValue(value) {
    if (Array.isArray(value)) return value.map(stableValue);
    if (!value || typeof value !== "object") return value;
    const result = {};
    for (const key of Object.keys(value).sort()) result[key] = stableValue(value[key]);
    return result;
  }
  async function sha256Hex(value, cryptoProvider) {
    if (!cryptoProvider?.subtle?.digest) throw new Error("SHA-256 is unavailable.");
    const digest = new Uint8Array(await cryptoProvider.subtle.digest("SHA-256", textEncoder.encode(value)));
    return [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  }
  async function createPersistentIrPcmCacheName(irId, sampleRate, preparation = {}, cryptoProvider = globalThis.crypto) {
    if (!/^[a-f0-9]{24}$/.test(irId) || !Number.isSafeInteger(sampleRate) || sampleRate < 1e3 || sampleRate > 999999) {
      throw new TypeError("A valid IR ID and integer sample rate are required.");
    }
    const canonicalPreparation = JSON.stringify(stableValue(preparation));
    if (canonicalPreparation === "{}") return `${irId}@${sampleRate}.f32`;
    const suffix = await sha256Hex(canonicalPreparation, cryptoProvider);
    return `${irId}@${sampleRate}-${suffix}.f32`;
  }
  function encodePersistentIrPcm({ sampleRate, channelData }) {
    if (!Number.isSafeInteger(sampleRate) || sampleRate < 1e3 || sampleRate > 999999 || !Array.isArray(channelData) || channelData.length < 1 || channelData.length > MAX_PCM_CHANNELS) {
      throw new TypeError("Valid PCM sample rate and channels are required.");
    }
    const frames = channelData[0] instanceof Float32Array ? channelData[0].length : -1;
    if (frames < 1 || !channelData.every((channel) => channel instanceof Float32Array && channel.length === frames)) {
      throw new TypeError("PCM channels must be equally sized Float32Arrays.");
    }
    const payloadBytes = channelData.length * frames * Float32Array.BYTES_PER_ELEMENT;
    if (!Number.isSafeInteger(payloadBytes) || PCM_HEADER_BYTES + payloadBytes > IR_LIBRARY_MAX_CACHE_ENTRY_BYTES) {
      throw new RangeError("Persistent PCM cache entry is too large.");
    }
    const buffer = new ArrayBuffer(PCM_HEADER_BYTES + payloadBytes);
    const view = new DataView(buffer);
    view.setUint32(0, PCM_MAGIC, true);
    view.setUint16(4, PCM_VERSION, true);
    view.setUint16(6, channelData.length, true);
    view.setUint32(8, frames, true);
    view.setUint32(12, sampleRate, true);
    view.setUint32(16, payloadBytes, true);
    view.setUint32(20, 0, true);
    const payload = new Float32Array(buffer, PCM_HEADER_BYTES);
    channelData.forEach((channel, index) => payload.set(channel, index * frames));
    return new Uint8Array(buffer);
  }
  function decodePersistentIrPcm(value) {
    requireBoundedIrBytes(value, IR_LIBRARY_MAX_CACHE_ENTRY_BYTES, "Persistent PCM cache entry");
    const bytes = value instanceof ArrayBuffer ? new Uint8Array(value) : ArrayBuffer.isView(value) ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength) : null;
    if (!bytes || bytes.byteLength < PCM_HEADER_BYTES) throw new Error("Invalid persistent PCM cache entry.");
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const channels = view.getUint16(6, true);
    const frames = view.getUint32(8, true);
    const sampleRate = view.getUint32(12, true);
    const payloadBytes = view.getUint32(16, true);
    if (view.getUint32(0, true) !== PCM_MAGIC || view.getUint16(4, true) !== PCM_VERSION || view.getUint32(20, true) !== 0 || channels < 1 || channels > MAX_PCM_CHANNELS || frames < 1 || sampleRate < 1e3 || sampleRate > 999999 || payloadBytes !== channels * frames * Float32Array.BYTES_PER_ELEMENT || bytes.byteLength !== PCM_HEADER_BYTES + payloadBytes) throw new Error("Invalid persistent PCM cache entry.");
    const payload = new Float32Array(channels * frames);
    new Uint8Array(payload.buffer).set(bytes.subarray(PCM_HEADER_BYTES));
    for (const sample of payload) {
      if (!Number.isFinite(sample)) throw new Error("Invalid persistent PCM cache entry.");
    }
    return Object.freeze({
      sampleRate,
      channelData: Object.freeze(Array.from({ length: channels }, (_2, index) => payload.subarray(index * frames, (index + 1) * frames)))
    });
  }
  function emptyPersistentIndex() {
    return { version: PCM_CACHE_INDEX_VERSION, entries: {} };
  }
  function validPersistentEntry(name, entry) {
    return CACHE_FILE_PATTERN.test(name) && entry && Number.isSafeInteger(entry.byteLength) && entry.byteLength > 0 && entry.byteLength <= IR_LIBRARY_MAX_CACHE_ENTRY_BYTES && Number.isSafeInteger(entry.lastAccess) && entry.lastAccess >= 0;
  }
  var DEFAULT_IR_PCM_CACHE_BYTES, PCM_CACHE_INDEX_VERSION, PCM_CACHE_INDEX_NAME, PCM_MAGIC, PCM_VERSION, PCM_HEADER_BYTES, MAX_PCM_CHANNELS, CACHE_FILE_PATTERN, textEncoder, textDecoder, PersistentIrPcmCache;
  var init_ir_pcm_cache = __esm({
    "js/ir-library/ir-pcm-cache.js"() {
      init_ir_library_limits();
      DEFAULT_IR_PCM_CACHE_BYTES = 256 * 1024 * 1024;
      PCM_CACHE_INDEX_VERSION = 1;
      PCM_CACHE_INDEX_NAME = "index.json";
      PCM_MAGIC = 1129337417;
      PCM_VERSION = 1;
      PCM_HEADER_BYTES = 24;
      MAX_PCM_CHANNELS = 32;
      CACHE_FILE_PATTERN = /^[a-f0-9]{24}@[1-9][0-9]{3,5}(?:-[a-f0-9]{64})?\.f32$/;
      textEncoder = new TextEncoder();
      textDecoder = new TextDecoder();
      PersistentIrPcmCache = class {
        constructor(backend, options = {}) {
          const required = ["readCache", "writeCacheAtomic", "removeCache", "listCache"];
          if (!backend || !required.every((name) => typeof backend[name] === "function")) {
            throw new TypeError("A cache-capable IR library backend is required.");
          }
          this.backend = backend;
          this.maxBytes = options.maxBytes ?? DEFAULT_IR_PCM_CACHE_BYTES;
          if (!Number.isSafeInteger(this.maxBytes) || this.maxBytes < 0) throw new TypeError("Invalid persistent PCM cache limit.");
          this.indexWriteInterval = options.indexWriteInterval ?? 1;
          if (!Number.isInteger(this.indexWriteInterval) || this.indexWriteInterval < 1 || this.indexWriteInterval > 128) {
            throw new TypeError("Invalid persistent PCM index write interval.");
          }
          this.pendingIndexWrites = 0;
          this.diagnostic = options.onDiagnostic || ((error2) => console.error("IR PCM cache diagnostic:", error2));
          this.cryptoProvider = options.cryptoProvider || globalThis.crypto;
          this.clock = options.clock || (() => Date.now());
          this.index = emptyPersistentIndex();
          this.byteLength = 0;
          this.sequence = 0;
          this.opened = false;
          this.healthy = true;
          this.mutation = Promise.resolve();
        }
        async open() {
          if (this.opened) return this;
          let parsed;
          try {
            const bytes = await this.backend.readCache(PCM_CACHE_INDEX_NAME);
            if (bytes) requireBoundedIrBytes(bytes, IR_LIBRARY_MAX_CACHE_INDEX_BYTES, "Persistent PCM cache index");
            parsed = bytes ? JSON.parse(textDecoder.decode(bytes)) : emptyPersistentIndex();
            if (parsed?.version !== PCM_CACHE_INDEX_VERSION || !parsed.entries || typeof parsed.entries !== "object" || Array.isArray(parsed.entries)) {
              throw new Error("Invalid persistent PCM cache index.");
            }
          } catch (error2) {
            this.diagnostic(error2);
            await this.#recoverCorruptIndex();
            this.opened = true;
            return this;
          }
          const listed = await this.backend.listCache().catch(async (error2) => {
            this.diagnostic(error2);
            await this.#disableAndReset();
            return [];
          });
          if (!this.healthy) {
            this.opened = true;
            return this;
          }
          const files = new Map(listed.filter((item) => CACHE_FILE_PATTERN.test(item.name)).map((item) => [item.name, item.byteLength]));
          let changed = false;
          for (const [name, entry] of Object.entries(parsed.entries)) {
            if (!validPersistentEntry(name, entry) || files.get(name) !== entry.byteLength) {
              delete parsed.entries[name];
              changed = true;
            }
          }
          for (const name of files.keys()) {
            if (!parsed.entries[name]) {
              await this.backend.removeCache(name).catch((error2) => this.diagnostic(error2));
              changed = true;
            }
          }
          this.index = parsed;
          this.byteLength = Object.values(parsed.entries).reduce((total, entry) => total + entry.byteLength, 0);
          this.sequence = Object.values(parsed.entries).reduce((latest, entry) => Math.max(latest, entry.lastAccess), 0);
          await this.#evictToLimit();
          if (changed && this.healthy) await this.#writeIndexSafely();
          this.opened = true;
          return this;
        }
        get(irId, sampleRate, preparation = {}) {
          return this.#serialize(async () => {
            if (!this.healthy) return null;
            const name = await createPersistentIrPcmCacheName(irId, sampleRate, preparation, this.cryptoProvider);
            const entry = this.index.entries[name];
            if (!entry) return null;
            try {
              const bytes = await this.backend.readCache(name);
              if (!bytes || bytes.byteLength !== entry.byteLength) throw new Error("Persistent PCM cache entry is missing or corrupt.");
              const decoded = decodePersistentIrPcm(bytes);
              if (decoded.sampleRate !== sampleRate) throw new Error("Persistent PCM cache rate does not match.");
              entry.lastAccess = this.#nextAccess();
              await this.#writeIndexSafely(false);
              return decoded;
            } catch (error2) {
              this.diagnostic(error2);
              await this.#discardEntry(name);
              return null;
            }
          });
        }
        set(irId, sampleRate, preparation, pcm) {
          return this.#serialize(async () => {
            if (!this.healthy) return false;
            let bytes;
            let name;
            try {
              name = await createPersistentIrPcmCacheName(irId, sampleRate, preparation, this.cryptoProvider);
              bytes = encodePersistentIrPcm(pcm);
              if (pcm.sampleRate !== sampleRate || bytes.byteLength > this.maxBytes) return false;
              await this.backend.writeCacheAtomic(name, bytes);
            } catch (error2) {
              this.diagnostic(error2);
              return false;
            }
            const previous = this.index.entries[name];
            if (previous) this.byteLength -= previous.byteLength;
            this.index.entries[name] = { byteLength: bytes.byteLength, lastAccess: this.#nextAccess() };
            this.byteLength += bytes.byteLength;
            await this.#evictToLimit(name);
            if (!await this.#writeIndexSafely(false)) return false;
            return this.healthy && Boolean(this.index.entries[name]);
          });
        }
        delete(irId, sampleRate, preparation = {}) {
          return this.#serialize(async () => {
            const name = await createPersistentIrPcmCacheName(irId, sampleRate, preparation, this.cryptoProvider);
            if (!this.index.entries[name]) return false;
            await this.#discardEntry(name);
            return true;
          });
        }
        // Sample-bank preparation checkpoints groups of small pages. Other callers
        // retain immediate persistence; startup already removes unindexed orphan files.
        flush() {
          return this.#serialize(() => this.pendingIndexWrites ? this.#writeIndexSafely() : this.healthy);
        }
        deleteAll(irId) {
          return this.#serialize(async () => {
            if (!/^[a-f0-9]{24}$/.test(irId)) throw new TypeError("A valid IR ID is required.");
            const prefix = `${irId}@`;
            const names = Object.keys(this.index.entries).filter((name) => name.startsWith(prefix));
            for (const name of names) {
              const entry = this.index.entries[name];
              delete this.index.entries[name];
              this.byteLength -= entry.byteLength;
              await this.backend.removeCache(name).catch((error2) => this.diagnostic(error2));
            }
            if (names.length > 0) await this.#writeIndexSafely();
            return names.length;
          });
        }
        clear() {
          return this.#serialize(async () => {
            const files = await this.backend.listCache().catch((error2) => {
              this.diagnostic(error2);
              return [];
            });
            for (const file of files) await this.backend.removeCache(file.name).catch((error2) => this.diagnostic(error2));
            this.index = emptyPersistentIndex();
            this.byteLength = 0;
            await this.#writeIndexSafely();
          });
        }
        getStats() {
          return Object.freeze({ byteLength: this.byteLength, entryCount: Object.keys(this.index.entries).length, maxBytes: this.maxBytes });
        }
        #serialize(task) {
          const run = this.mutation.then(() => {
            if (!this.opened) throw new Error("Open the persistent PCM cache before using it.");
            return task();
          });
          this.mutation = run.catch(() => {
          });
          return run;
        }
        #nextAccess() {
          this.sequence = Math.max(this.sequence + 1, Math.floor(this.clock()));
          return this.sequence;
        }
        async #discardEntry(name) {
          const entry = this.index.entries[name];
          if (!entry) return;
          delete this.index.entries[name];
          this.byteLength -= entry.byteLength;
          await this.backend.removeCache(name).catch((error2) => this.diagnostic(error2));
          await this.#writeIndexSafely();
        }
        async #evictToLimit(protectedName = null) {
          while (this.byteLength > this.maxBytes) {
            const candidates = Object.entries(this.index.entries).filter(([name2]) => name2 !== protectedName).sort((left, right) => left[1].lastAccess - right[1].lastAccess);
            const oldest = candidates[0] || Object.entries(this.index.entries).sort((left, right) => left[1].lastAccess - right[1].lastAccess)[0];
            if (!oldest) break;
            const [name, entry] = oldest;
            delete this.index.entries[name];
            this.byteLength -= entry.byteLength;
            await this.backend.removeCache(name).catch((error2) => this.diagnostic(error2));
          }
        }
        async #writeIndexSafely(force = true) {
          if (!this.healthy) return false;
          if (!force && ++this.pendingIndexWrites < this.indexWriteInterval) return true;
          try {
            const bytes = textEncoder.encode(JSON.stringify(this.index));
            requireBoundedIrBytes(bytes, IR_LIBRARY_MAX_CACHE_INDEX_BYTES, "Persistent PCM cache index");
            await this.backend.writeCacheAtomic(PCM_CACHE_INDEX_NAME, bytes);
            this.pendingIndexWrites = 0;
            return true;
          } catch (error2) {
            this.diagnostic(error2);
            await this.#disableAndReset();
            return false;
          }
        }
        async #disableAndReset() {
          this.healthy = false;
          this.pendingIndexWrites = 0;
          const files = await this.backend.listCache().catch(() => []);
          for (const file of files) await this.backend.removeCache(file.name).catch(() => {
          });
          this.index = emptyPersistentIndex();
          this.byteLength = 0;
          await this.backend.writeCacheAtomic(PCM_CACHE_INDEX_NAME, textEncoder.encode(JSON.stringify(this.index))).catch(() => {
          });
        }
        async #recoverCorruptIndex() {
          const files = await this.backend.listCache().catch((error2) => {
            this.diagnostic(error2);
            return [];
          });
          for (const file of files) await this.backend.removeCache(file.name).catch((error2) => this.diagnostic(error2));
          this.index = emptyPersistentIndex();
          this.byteLength = 0;
          try {
            await this.backend.writeCacheAtomic(PCM_CACHE_INDEX_NAME, textEncoder.encode(JSON.stringify(this.index)));
            this.healthy = true;
          } catch (error2) {
            this.diagnostic(error2);
            this.healthy = false;
          }
        }
      };
    }
  });

  // js/ir-library/opfs-ir-library-backend.js
  function indexTooLargeError() {
    const error2 = new RangeError("The IR library index is too large.");
    error2.code = IR_LIBRARY_INDEX_TOO_LARGE_CODE;
    return error2;
  }
  function requireName(name) {
    if (typeof name !== "string" || !ALLOWED_NAME.test(name)) {
      throw new TypeError("Invalid IR library item.");
    }
    return name;
  }
  function requireCacheName(name) {
    if (typeof name !== "string" || !CACHE_NAME.test(name)) throw new TypeError("Invalid IR cache item.");
    return name;
  }
  function asBytes(value) {
    if (value instanceof ArrayBuffer) return new Uint8Array(value);
    if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    throw new TypeError("IR library data must be binary.");
  }
  async function openOpfsIrLibraryBackend(storage = globalThis.navigator?.storage, namespace = "ir-library") {
    const rootName = requireLibraryNamespace(namespace);
    if (typeof storage?.getDirectory !== "function") throw new Error("OPFS is unavailable.");
    const originRoot = await storage.getDirectory();
    const directory = await originRoot.getDirectoryHandle(rootName, { create: true });
    return new OpfsIrLibraryBackend(directory, rootName);
  }
  var ALLOWED_NAME, CACHE_NAME, OpfsIrLibraryBackend;
  var init_opfs_ir_library_backend = __esm({
    "js/ir-library/opfs-ir-library-backend.js"() {
      init_ir_library_limits();
      init_library_namespace();
      ALLOWED_NAME = /^(?:index\.json|[a-f0-9]{24}(?:\.(?:L|R))?\.[a-z0-9]{1,10})$/;
      CACHE_NAME = /^(?:index\.json|[a-f0-9]{24}@[1-9][0-9]{3,5}(?:-[a-f0-9]{64})?\.f32)$/;
      OpfsIrLibraryBackend = class {
        constructor(directory, namespace = "ir-library") {
          this.directory = directory;
          this.namespace = requireLibraryNamespace(namespace);
          this.cacheDirectoryPromise = null;
        }
        async read(name) {
          requireName(name);
          try {
            const handle = await this.directory.getFileHandle(name);
            const file = await handle.getFile();
            if (Number.isSafeInteger(file.size) && file.size > maxIrLibraryBytesForName(name, this.namespace)) {
              if (name === "index.json") throw indexTooLargeError();
              throw new RangeError("IR library item is too large.");
            }
            const buffer = await file.arrayBuffer();
            try {
              requireBoundedIrBytes(buffer, maxIrLibraryBytesForName(name, this.namespace), "IR library item");
            } catch (error2) {
              if (name === "index.json" && error2 instanceof RangeError) throw indexTooLargeError();
              throw error2;
            }
            return new Uint8Array(buffer);
          } catch (error2) {
            if (error2?.name === "NotFoundError") return null;
            throw error2;
          }
        }
        async exists(name) {
          requireName(name);
          try {
            await this.directory.getFileHandle(name);
            return true;
          } catch (error2) {
            if (error2?.name === "NotFoundError") return false;
            throw error2;
          }
        }
        async writeAtomic(name, bytes) {
          requireName(name);
          requireBoundedIrBytes(bytes, maxIrLibraryBytesForName(name, this.namespace), "IR library item");
          const handle = await this.directory.getFileHandle(name, { create: true });
          const writable = await handle.createWritable({ keepExistingData: false });
          try {
            await writable.write(asBytes(bytes));
            await writable.close();
          } catch (error2) {
            await writable.abort?.().catch(() => {
            });
            throw error2;
          }
        }
        async readSfzBankFile(name) {
          requireName(name);
          if (this.namespace !== "sfz-library" || !/^[a-f0-9]{24}\.sfzbank$/.test(name)) throw new TypeError("Invalid SFZ bank item.");
          try {
            const file = await (await this.directory.getFileHandle(name)).getFile();
            if (!Number.isSafeInteger(file.size) || file.size < 0) throw new RangeError("Invalid SFZ bank size.");
            return file;
          } catch (error2) {
            if (error2?.name === "NotFoundError") return null;
            throw error2;
          }
        }
        async writeSfzBankFile(name, file, { isCurrent, onProgress } = {}) {
          requireName(name);
          if (this.namespace !== "sfz-library" || !/^[a-f0-9]{24}\.sfzbank$/.test(name) || !Number.isSafeInteger(file?.size) || file.size < 12 || typeof file.slice !== "function") throw new TypeError("Invalid SFZ bank item.");
          const handle = await this.directory.getFileHandle(name, { create: true });
          const writable = await handle.createWritable({ keepExistingData: false });
          try {
            for (let offset = 0; offset < file.size; offset += 1024 * 1024) {
              if (isCurrent?.() === false) throw new DOMException("SFZ import was cancelled.", "AbortError");
              const length = Math.min(1024 * 1024, file.size - offset);
              const bytes = new Uint8Array(await file.slice(offset, offset + length).arrayBuffer());
              if (bytes.length !== length) throw new Error("The SFZ source changed during import.");
              await writable.write(bytes);
              onProgress?.({ completedBytes: offset + length, totalBytes: file.size });
            }
            if (isCurrent?.() === false) throw new DOMException("SFZ import was cancelled.", "AbortError");
            await writable.close();
          } catch (error2) {
            await writable.abort?.().catch(() => {
            });
            throw error2;
          }
        }
        async remove(name) {
          requireName(name);
          try {
            await this.directory.removeEntry(name);
          } catch (error2) {
            if (error2?.name !== "NotFoundError") throw error2;
          }
        }
        async list() {
          const names = [];
          for await (const [name, handle] of this.directory.entries()) {
            if (handle.kind === "file" && ALLOWED_NAME.test(name)) names.push(name);
          }
          return names;
        }
        async cleanupTemporary() {
        }
        async readCache(name) {
          requireCacheName(name);
          const directory = await this.#getCacheDirectory();
          try {
            const handle = await directory.getFileHandle(name);
            const file = await handle.getFile();
            if (Number.isSafeInteger(file.size) && file.size > maxIrCacheBytesForName(name)) {
              throw new RangeError("IR cache item is too large.");
            }
            const buffer = await file.arrayBuffer();
            requireBoundedIrBytes(buffer, maxIrCacheBytesForName(name), "IR cache item");
            return new Uint8Array(buffer);
          } catch (error2) {
            if (error2?.name === "NotFoundError") return null;
            throw error2;
          }
        }
        async writeCacheAtomic(name, bytes) {
          requireCacheName(name);
          requireBoundedIrBytes(bytes, maxIrCacheBytesForName(name), "IR cache item");
          const directory = await this.#getCacheDirectory();
          const handle = await directory.getFileHandle(name, { create: true });
          const writable = await handle.createWritable({ keepExistingData: false });
          try {
            await writable.write(asBytes(bytes));
            await writable.close();
          } catch (error2) {
            await writable.abort?.().catch(() => {
            });
            throw error2;
          }
        }
        async removeCache(name) {
          requireCacheName(name);
          const directory = await this.#getCacheDirectory();
          try {
            await directory.removeEntry(name);
          } catch (error2) {
            if (error2?.name !== "NotFoundError") throw error2;
          }
        }
        async listCache() {
          const directory = await this.#getCacheDirectory();
          const entries = [];
          for await (const [name, handle] of directory.entries()) {
            if (handle.kind !== "file" || name === "index.json" || !CACHE_NAME.test(name)) continue;
            const file = await handle.getFile();
            entries.push({ name, byteLength: file.size });
          }
          return entries;
        }
        #getCacheDirectory() {
          this.cacheDirectoryPromise ||= this.directory.getDirectoryHandle("cache", { create: true });
          return this.cacheDirectoryPromise;
        }
      };
    }
  });

  // js/ir-library/ir-library-factory.js
  function withDeadline(promise, timeoutMs) {
    let timer = null;
    const deadline = new Promise((_2, reject) => {
      timer = setTimeout(() => reject(new Error("Legacy IR library storage did not respond.")), timeoutMs);
      timer?.unref?.();
    });
    return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
  }
  function unavailableError() {
    const failure6 = new Error("The IR library is unavailable.");
    failure6.code = "ir-library-unavailable";
    return failure6;
  }
  function emitProgress(progress) {
    for (const listener of [...progressListeners]) {
      try {
        listener(progress);
      } catch {
      }
    }
  }
  async function migrateOpfsLibrary(source, target, indexBytes) {
    const names = (await withDeadline(source.list(), LEGACY_READ_DEADLINE_MS)).filter((name) => name !== IR_LIBRARY_INDEX_NAME);
    const progress = { phase: "copying", completedCount: 0, totalCount: names.length + 1, bytes: 0 };
    emitProgress({ ...progress });
    for (const name of names) {
      const bytes = await withDeadline(source.read(name), LEGACY_READ_DEADLINE_MS);
      if (!bytes) throw new Error("An IR library item disappeared during migration.");
      await target.writeAtomic(name, bytes);
      progress.completedCount += 1;
      progress.bytes += bytes.byteLength;
      emitProgress({ ...progress });
    }
    await target.writeAtomic(IR_LIBRARY_INDEX_NAME, indexBytes);
    progress.completedCount += 1;
    progress.bytes += indexBytes.byteLength;
    emitProgress({ ...progress, phase: "done" });
    return { migratedCount: names.length, migratedBytes: progress.bytes };
  }
  async function writeMigrationMarker(nativeBackend, result, diagnostic) {
    const marker = {
      version: 1,
      source: "opfs",
      status: result.status,
      migratedCount: result.migratedCount || 0,
      migratedBytes: result.migratedBytes || 0,
      completedAt: (/* @__PURE__ */ new Date()).toISOString()
    };
    try {
      await nativeBackend.writeAtomic(IR_LIBRARY_MIGRATION_MARKER_NAME, encoder2.encode(JSON.stringify(marker)));
    } catch (error2) {
      diagnostic?.(error2);
    }
  }
  async function runElectronMigration(nativeBackend, storage, diagnostic) {
    try {
      if (await nativeBackend.exists(IR_LIBRARY_INDEX_NAME)) return { status: "native" };
      if (await nativeBackend.exists(IR_LIBRARY_MIGRATION_MARKER_NAME)) return { status: "native" };
    } catch (error2) {
      diagnostic?.(error2);
      throw unavailableError();
    }
    let opfsBackend;
    let indexBytes;
    try {
      opfsBackend = await withDeadline(openOpfsIrLibraryBackend(storage), LEGACY_READ_DEADLINE_MS);
      indexBytes = await withDeadline(opfsBackend.read(IR_LIBRARY_INDEX_NAME), LEGACY_READ_DEADLINE_MS);
    } catch (error2) {
      diagnostic?.(error2);
      return { status: "skipped" };
    }
    let result;
    try {
      result = indexBytes ? { status: "migrated", ...await migrateOpfsLibrary(opfsBackend, nativeBackend, indexBytes) } : { status: "empty" };
    } catch (error2) {
      diagnostic?.(error2);
      throw unavailableError();
    }
    await writeMigrationMarker(nativeBackend, result, diagnostic);
    return result;
  }
  function ensureElectronIrLibraryMigration(options = {}) {
    const electronBridge = options.electronBridge || globalThis.window?.electronAPI?.irLibraryV1;
    if (!electronBridge) return Promise.resolve({ status: "not-electron" });
    const storage = options.storage || globalThis.navigator?.storage;
    let migration = migrationsByBridge.get(electronBridge);
    if (!migration) {
      let nativeBackend;
      try {
        nativeBackend = new ElectronIrLibraryBackend(electronBridge);
      } catch (error2) {
        options.onDiagnostic?.(error2);
        return Promise.reject(unavailableError());
      }
      const current = runElectronMigration(nativeBackend, storage, options.onDiagnostic).catch((error2) => {
        if (migrationsByBridge.get(electronBridge) === current) migrationsByBridge.delete(electronBridge);
        throw error2;
      });
      migration = current;
      migrationsByBridge.set(electronBridge, current);
    }
    return migration;
  }
  async function openElectronBackend(electronBridge, storage, diagnostic) {
    await ensureElectronIrLibraryMigration({ electronBridge, storage, onDiagnostic: diagnostic });
    return new ElectronIrLibraryBackend(electronBridge);
  }
  async function openIrLibraryBackend(options = {}) {
    const namespace = requireLibraryNamespace(options.namespace);
    const electronBridge = options.electronBridge || globalThis.window?.electronAPI?.irLibraryV1;
    const storage = options.storage || globalThis.navigator?.storage;
    if (electronBridge) {
      return namespace === "ir-library" ? openElectronBackend(electronBridge, storage, options.onDiagnostic) : new ElectronIrLibraryBackend(electronBridge, namespace);
    } else {
      try {
        return await openOpfsIrLibraryBackend(storage, namespace);
      } catch (error2) {
        options.onDiagnostic?.(error2);
        throw unavailableError();
      }
    }
  }
  var IR_LIBRARY_MIGRATION_MARKER_NAME, LEGACY_READ_DEADLINE_MS, encoder2, progressListeners, migrationsByBridge;
  var init_ir_library_factory = __esm({
    "js/ir-library/ir-library-factory.js"() {
      init_electron_ir_library_backend();
      init_ir_library_store();
      init_ir_pcm_cache();
      init_opfs_ir_library_backend();
      init_library_namespace();
      IR_LIBRARY_MIGRATION_MARKER_NAME = "legacy-migration.json";
      LEGACY_READ_DEADLINE_MS = 5e3;
      encoder2 = new TextEncoder();
      progressListeners = /* @__PURE__ */ new Set();
      migrationsByBridge = /* @__PURE__ */ new WeakMap();
    }
  });

  // js/ir-library/audio-header-metadata.js
  function ascii2(bytes, offset, length) {
    return String.fromCharCode(...bytes.subarray(offset, offset + length));
  }
  function parseWav(bytes) {
    if (bytes.byteLength < 12 || ascii2(bytes, 0, 4) !== "RIFF" || ascii2(bytes, 8, 4) !== "WAVE") return null;
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let offset = 12;
    let channels = null;
    let sampleRate = null;
    let blockAlign = null;
    let dataBytes = null;
    while (offset + 8 <= Math.min(bytes.byteLength, MAX_HEADER_SCAN_BYTES)) {
      const id = ascii2(bytes, offset, 4);
      const size = view.getUint32(offset + 4, true);
      if (id === "fmt " && size >= 16 && offset + 24 <= bytes.byteLength) {
        channels = view.getUint16(offset + 10, true);
        sampleRate = view.getUint32(offset + 12, true);
        blockAlign = view.getUint16(offset + 20, true);
      } else if (id === "data") {
        dataBytes = size;
        break;
      }
      offset += 8 + size + (size & 1);
    }
    if (!(channels > 0) || !(sampleRate > 0)) return null;
    return { channels, sampleRate, frames: blockAlign > 0 && dataBytes !== null ? Math.floor(dataBytes / blockAlign) : null };
  }
  function extended80(bytes, offset) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const exponent = view.getUint16(offset, false);
    const high = view.getUint32(offset + 2, false);
    const low = view.getUint32(offset + 6, false);
    if (exponent === 0 && high === 0 && low === 0) return 0;
    const sign = exponent & 32768 ? -1 : 1;
    const power = (exponent & 32767) - 16383;
    return sign * (high * 2 ** (power - 31) + low * 2 ** (power - 63));
  }
  function parseAiff(bytes) {
    if (bytes.byteLength < 12 || ascii2(bytes, 0, 4) !== "FORM" || !["AIFF", "AIFC"].includes(ascii2(bytes, 8, 4))) return null;
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let offset = 12;
    while (offset + 8 <= Math.min(bytes.byteLength, MAX_HEADER_SCAN_BYTES)) {
      const id = ascii2(bytes, offset, 4);
      const size = view.getUint32(offset + 4, false);
      if (id === "COMM" && size >= 18 && offset + 26 <= bytes.byteLength) {
        const channels = view.getUint16(offset + 8, false);
        const frames = view.getUint32(offset + 10, false);
        const sampleRate = Math.round(extended80(bytes, offset + 16));
        return channels > 0 && sampleRate > 0 ? { channels, frames, sampleRate } : null;
      }
      offset += 8 + size + (size & 1);
    }
    return null;
  }
  function parseFlac(bytes) {
    if (bytes.byteLength < 42 || ascii2(bytes, 0, 4) !== "fLaC" || (bytes[4] & 127) !== 0) return null;
    const length = bytes[5] << 16 | bytes[6] << 8 | bytes[7];
    if (length < 34 || bytes.byteLength < 8 + length) return null;
    const offset = 18;
    const packed = BigInt(bytes[offset]) << 56n | BigInt(bytes[offset + 1]) << 48n | BigInt(bytes[offset + 2]) << 40n | BigInt(bytes[offset + 3]) << 32n | BigInt(bytes[offset + 4]) << 24n | BigInt(bytes[offset + 5]) << 16n | BigInt(bytes[offset + 6]) << 8n | BigInt(bytes[offset + 7]);
    const sampleRate = Number(packed >> 44n & 0xfffffn);
    const channels = Number(packed >> 41n & 0x7n) + 1;
    const frames = Number(packed & 0xfffffffffn);
    return sampleRate > 0 ? { channels, sampleRate, frames: frames || null } : null;
  }
  function audioBytes(value) {
    return value instanceof ArrayBuffer ? new Uint8Array(value) : ArrayBuffer.isView(value) ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength) : null;
  }
  function parseIrAudioHeader(value) {
    const bytes = audioBytes(value);
    if (!bytes) return { channels: null, frames: null, sampleRate: null };
    return parseWav(bytes) || parseAiff(bytes) || parseFlac(bytes) || { channels: null, frames: null, sampleRate: null };
  }
  var MAX_HEADER_SCAN_BYTES;
  var init_audio_header_metadata = __esm({
    "js/ir-library/audio-header-metadata.js"() {
      MAX_HEADER_SCAN_BYTES = 1024 * 1024;
    }
  });

  // js/sfz/bank.js
  async function readSfzAudioHeader(readRange, size) {
    const read = async (position, length) => {
      if (position + length > size) return null;
      const bytes = await readRange(position, length);
      return bytes?.byteLength === length ? bytes : null;
    };
    const prefix = await read(0, 12);
    if (!prefix) return {};
    const signature2 = String.fromCharCode(...prefix.subarray(0, 4));
    let header;
    if (signature2 === "fLaC") header = await read(0, 42);
    else if (signature2 === "RIFF" || signature2 === "FORM") {
      let position = 12;
      let format;
      for (let count = 0; count < 128 && position < 1024 * 1024; count++) {
        const chunk = await read(position, 8);
        if (!chunk) break;
        const tag2 = String.fromCharCode(...chunk.subarray(0, 4));
        const length = new DataView(chunk.buffer, chunk.byteOffset, 8).getUint32(4, signature2 === "RIFF");
        if (signature2 === "RIFF" && tag2 === "fmt " && length >= 16) {
          const data = await read(position + 8, 16);
          if (!data) break;
          format = new Uint8Array(24);
          format.set(chunk);
          format.set(data, 8);
          new DataView(format.buffer).setUint32(4, 16, true);
        } else if (signature2 === "RIFF" && tag2 === "data" && format) {
          header = new Uint8Array(44);
          header.set(prefix);
          header.set(format, 12);
          header.set(chunk, 36);
          break;
        } else if (signature2 === "FORM" && tag2 === "COMM" && length >= 18) {
          const data = await read(position + 8, 18);
          if (!data) break;
          header = new Uint8Array(38);
          header.set(prefix);
          header.set(chunk, 12);
          header.set(data, 20);
          break;
        }
        position += 8 + length + (length & 1);
      }
    }
    const metadata = parseIrAudioHeader(header);
    return metadata.channels > 0 && metadata.frames > 0 && metadata.sampleRate > 0 ? metadata : {};
  }
  function encodeSfzBank(selectedPath, files, { maxBytes = SFZ_DEFAULT_MAX_BYTES, warnings = [] } = {}) {
    requireSfzMaxBytes(maxBytes);
    const ordered = [...files].sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0);
    let offset = 0;
    const entries = ordered.map(([path, bytes2]) => {
      const entry = { path: normalizeSfzPath(path), offset, length: bytes2.byteLength };
      offset += bytes2.byteLength;
      return entry;
    });
    const metadata = encoder3.encode(JSON.stringify({
      selectedPath,
      files: entries,
      ...warnings.length ? { warnings } : {}
    }));
    const size = 12 + metadata.byteLength + offset;
    if (size > maxBytes) throw sfzError("too-large", "The SFZ bank is too large to save.");
    const bytes = new Uint8Array(size);
    const view = new DataView(bytes.buffer);
    view.setUint32(0, MAGIC, true);
    view.setUint32(4, 1, true);
    view.setUint32(8, metadata.byteLength, true);
    bytes.set(metadata, 12);
    offset = 12 + metadata.byteLength;
    for (const [, data] of ordered) {
      bytes.set(data, offset);
      offset += data.byteLength;
    }
    return bytes;
  }
  function estimateSfzBankBytes(selectedPath, sizes) {
    let offset = 0;
    const files = [...sizes].sort(([a], [b2]) => a < b2 ? -1 : a > b2 ? 1 : 0).map(([path, length]) => {
      const entry = { path: normalizeSfzPath(path), offset, length };
      offset += length;
      return entry;
    });
    return 12 + encoder3.encode(JSON.stringify({ selectedPath, files })).byteLength + offset;
  }
  function validateSfzBankIndex(metadata, dataBytes) {
    if (!Array.isArray(metadata.files) || metadata.files.length > 1e4) throw sfzError("prepare", "Invalid SFZ bank file list.");
    if (metadata.warnings !== void 0 && (!Array.isArray(metadata.warnings) || metadata.warnings.length > WARNING_CODES.size || metadata.warnings.some((warning) => !WARNING_CODES.has(warning?.code) || !Number.isSafeInteger(warning.count) || warning.count < 1))) {
      throw sfzError("prepare", "Invalid SFZ bank load warnings.");
    }
    const files = /* @__PURE__ */ new Map();
    let expectedOffset = 0;
    for (const entry of metadata.files) {
      const path = normalizeSfzPath(entry.path);
      if (files.has(path) || entry.offset !== expectedOffset || !Number.isSafeInteger(entry.length) || entry.length < 0 || !Number.isSafeInteger(entry.offset + entry.length) || entry.offset + entry.length > dataBytes) {
        throw sfzError("prepare", "Invalid SFZ bank file range.");
      }
      files.set(path, Object.freeze({ offset: entry.offset, length: entry.length }));
      expectedOffset += entry.length;
    }
    if (expectedOffset !== dataBytes) throw sfzError("prepare", "Invalid SFZ bank size.");
    const selectedPath = normalizeSfzPath(metadata.selectedPath);
    if (!files.has(selectedPath)) throw sfzError("prepare", "The SFZ bank has no selected instrument.");
    return { selectedPath, files, warnings: metadata.warnings || [] };
  }
  function decodeSfzBank(bytes, { maxBytes = SFZ_DEFAULT_MAX_BYTES } = {}) {
    requireSfzMaxBytes(maxBytes);
    if (bytes?.byteLength > maxBytes) throw sfzError("too-large", "The SFZ bank is too large to load.");
    if (!(bytes instanceof Uint8Array) || bytes.byteLength < 12) throw sfzError("prepare", "Invalid SFZ bank.");
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const metadataLength = view.getUint32(8, true);
    if (view.getUint32(0, true) !== MAGIC || view.getUint32(4, true) !== 1 || metadataLength > bytes.byteLength - 12) throw sfzError("prepare", "Invalid SFZ bank header.");
    const metadata = JSON.parse(decoder2.decode(bytes.subarray(12, 12 + metadataLength)));
    const bank = validateSfzBankIndex(metadata, bytes.byteLength - 12 - metadataLength);
    const offset = 12 + metadataLength;
    return { ...bank, files: new Map([...bank.files].map(([path, entry]) => [path, bytes.subarray(offset + entry.offset, offset + entry.offset + entry.length)])) };
  }
  async function identifySfzBank(bytes) {
    const digest = await globalThis.crypto.subtle.digest("SHA-256", bytes);
    return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("").slice(0, 24);
  }
  var SFZ_BANK_MAGIC, MAGIC, encoder3, decoder2, WARNING_CODES;
  var init_bank = __esm({
    "js/sfz/bank.js"() {
      init_parser();
      init_limits();
      init_audio_header_metadata();
      SFZ_BANK_MAGIC = 827999827;
      MAGIC = SFZ_BANK_MAGIC;
      encoder3 = new TextEncoder();
      decoder2 = new TextDecoder("utf-8", { fatal: true });
      WARNING_CODES = /* @__PURE__ */ new Set([
        "invalid-regions",
        "missing-samples",
        "unsupported-regions",
        "reduced-bank",
        "loop-points-ignored",
        "envelope-times-adjusted"
      ]);
    }
  });

  // js/sfz/source.js
  function decodeSfzText(bytes) {
    const decode = (part) => {
      try {
        return utf8.decode(part);
      } catch {
        return legacy.decode(part);
      }
    };
    let raw = "";
    for (let index = 0; index < bytes.length; index += 8192) raw += String.fromCharCode(...bytes.subarray(index, index + 8192));
    const ranges = embeddedSfzRanges(raw);
    if (!ranges.length) return decode(bytes);
    let text2 = "", cursor = 0;
    for (const range of ranges) {
      text2 += decode(bytes.subarray(cursor, range.dataStart)) + raw.slice(range.dataStart, range.end);
      cursor = range.end;
    }
    return text2 + decode(bytes.subarray(cursor));
  }
  function attributes(text2) {
    const result = /* @__PURE__ */ new Map();
    for (const match of text2.matchAll(/\b([a-z_]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/gi)) {
      const value = (match[2] ?? match[3]).replace(
        /&(amp|quot|apos|lt|gt);/g,
        (_2, entity) => ({ amp: "&", quot: '"', apos: "'", lt: "<", gt: ">" })[entity]
      );
      result.set(match[1].toLowerCase(), value);
    }
    return result;
  }
  async function readSfzBankDefines(selectedPath, bankPaths, readText) {
    const bankDirectory = (path) => path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
    const candidates = bankPaths.filter((path) => !bankDirectory(path) || selectedPath.startsWith(bankDirectory(path) + "/")).sort((a, b2) => bankDirectory(b2).length - bankDirectory(a).length || a.localeCompare(b2));
    for (const path of candidates) {
      const text2 = await readText(path);
      if (!text2 || !/<AriaBank\b/i.test(text2)) continue;
      const directory = bankDirectory(path);
      const tags = [...text2.matchAll(/<(AriaElement|Define)\b([^<>]*)>/gi)].map((match) => ({ name: match[1].toLowerCase(), values: attributes(match[2]) }));
      const registered = tags.some((tag2) => tag2.name === "ariaelement" && tag2.values.has("path") && normalizeSfzPath(tag2.values.get("path"), directory).toLowerCase() === selectedPath.toLowerCase());
      if (!registered && candidates.filter((candidate) => bankDirectory(candidate) === directory).length !== 1) continue;
      const defines = /* @__PURE__ */ new Map();
      for (const { name, values } of tags) {
        const key = values.get("name");
        let value = values.get("value");
        if (name !== "define" || !/^\$[a-z0-9_]+$/i.test(key || "") || value === void 0) continue;
        if (key === "$sample_dir" && value.startsWith("$Banks/")) {
          const sourceDirectory = selectedPath.split("/").slice(0, -1);
          const samples = normalizeSfzPath("Samples", directory).split("/");
          let common = 0;
          while (common < sourceDirectory.length && sourceDirectory[common] === samples[common]) common++;
          value = "../".repeat(sourceDirectory.length - common) + samples.slice(common).join("/");
        }
        defines.set(key, value);
      }
      return { defines, bankPath: path };
    }
    return { defines: /* @__PURE__ */ new Map() };
  }
  var utf8, legacy;
  var init_source = __esm({
    "js/sfz/source.js"() {
      init_parser();
      init_embedded_sample();
      utf8 = new TextDecoder("utf-8", { fatal: true });
      legacy = new TextDecoder("windows-1252");
    }
  });

  // js/sfz/oscillator-source.js
  function resizeSfzCycle(input, frames, output = new Float32Array(frames)) {
    if (input.length === frames) {
      output.set(input);
      return output;
    }
    const ratio = input.length / frames;
    const scale = Math.min(1, 1 / ratio), radius = 16 / scale;
    for (let frame = 0; frame < frames; frame++) {
      const position = frame * ratio;
      let sum = 0, weights = 0;
      for (let source = Math.ceil(position - radius); source <= Math.floor(position + radius); source++) {
        const distance = (source - position) * scale;
        const window2 = 0.42 + 0.5 * Math.cos(Math.PI * distance / 16) + 0.08 * Math.cos(2 * Math.PI * distance / 16);
        const weight = (distance === 0 ? 1 : Math.sin(Math.PI * distance) / (Math.PI * distance)) * window2;
        sum += input[(source % input.length + input.length) % input.length] * weight;
        weights += weight;
      }
      output[frame] = sum / weights;
    }
    return output;
  }
  function sfzCyclePyramidFrames(frames) {
    if (!Number.isSafeInteger(frames) || frames < 1 || frames > 4294967295) throw failure("prepare");
    let total = frames;
    for (let level = frames; level > 1; ) {
      level = Math.ceil(level / 2);
      total += level;
    }
    if (total > 4294967295) throw failure("too-large");
    return total;
  }
  function prepareSfzCyclePyramid(input, frames) {
    const output = new Float32Array(sfzCyclePyramidFrames(frames));
    resizeSfzCycle(input, frames, output.subarray(0, frames));
    let mean = 0;
    for (const value of input) mean += value / input.length;
    let first = 0, length = frames;
    while (length > 1) {
      const next = Math.ceil(length / 2), at = first + length;
      if (next === 1) output[at] = mean;
      else resizeSfzCycle(output.subarray(first, at), next, output.subarray(at, at + next));
      first = at;
      length = next;
    }
    if (frames === 1) output[0] = mean;
    return output;
  }
  async function prepareSfzOscillatorSources(parsed, loadSample, maxBytes, { residentBytes = 0 } = {}) {
    if (parsed.sourceProfile) return { parsed, samples: /* @__PURE__ */ new Map() };
    const samples = /* @__PURE__ */ new Map(), identities = /* @__PURE__ */ new Map(), regions = [...parsed.regions];
    let bytes = 0;
    for (let index = 0; index < regions.length; index++) {
      const compiled = parsed.modulation?.regions[index];
      const oscillator = compiled?.instances.findIndex((instance) => instance.kind === SFZ_MOD_KINDS.Oscillator) ?? -1;
      if (oscillator < 0) continue;
      const get = (property2) => compiled.parameters.find((parameter) => parameter.instance === oscillator && parameter.property === property2)?.value;
      if (!get(SFZ_MOD_PROPERTY_IDS.Enabled)) continue;
      const region = regions[index], requested = get(SFZ_MOD_PROPERTY_IDS.OscillatorTableSize);
      const identity = JSON.stringify([region.sample, requested, region.offset, region.opcodes?.offset_mode, region.end]);
      let path = identities.get(identity);
      if (!path) {
        const pcm = await loadSample(region.sample, maxBytes - bytes);
        const sourceFrames = pcm?.channels?.[0]?.length;
        const start = resolveSfzRegionOffset(region, sourceFrames), end = region.end ?? sourceFrames - 1;
        if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start || end >= sourceFrames) throw failure("prepare");
        const inputFrames = end - start + 1, frames2 = requested || inputFrames;
        if (!Number.isSafeInteger(frames2) || frames2 < 1 || !Array.isArray(pcm.channels) || pcm.channels.length < 1 || pcm.channels.length > 2 || pcm.channels.some((channel) => !(channel instanceof Float32Array) || channel.length !== sourceFrames)) throw failure("prepare");
        const added = sfzCyclePyramidFrames(frames2) * pcm.channels.length * 4;
        if (bytes + added + Math.max(residentBytes, sourceFrames * pcm.channels.length * 4) > maxBytes) throw failure("too-large");
        path = `*prepared-cycle:${samples.size}`;
        samples.set(path, {
          sampleRate: 48e3,
          logicalFrames: frames2,
          channels: pcm.channels.map((channel) => prepareSfzCyclePyramid(channel.subarray(start, end + 1), frames2))
        });
        identities.set(identity, path);
        bytes += added;
      }
      const frames = samples.get(path).logicalFrames;
      regions[index] = {
        ...region,
        sample: path,
        offset: 0,
        end: frames - 1,
        loop_mode: 2,
        loop_start: 0,
        loop_end: frames - 1,
        pitch_keycenter: 60
      };
    }
    return { parsed: { ...parsed, regions }, samples };
  }
  var failure;
  var init_oscillator_source = __esm({
    "js/sfz/oscillator-source.js"() {
      init_modulation_schema();
      init_parser();
      failure = (code) => Object.assign(new Error("The instrument wavetable could not be prepared. Increase the sample memory limit or use a smaller waveform."), { code });
    }
  });

  // js/sfz/script-compiler.js
  function invalid(message, token = { line: 1 }) {
    const error2 = new Error(`NKSP line ${token.line}: ${message}`);
    error2.code = "script-invalid";
    error2.line = token.line;
    return error2;
  }
  function tokenize(source, disabledMessages = /* @__PURE__ */ new Set()) {
    if (typeof source !== "string" || source.length > 262144) throw invalid("Script exceeds its source budget.");
    const tokens = [];
    let at = 0, line = 1;
    while (at < source.length) {
      const start = at, c = source[at];
      if (/\s/.test(c)) {
        if (c === "\n") line++;
        at++;
        continue;
      }
      if (c === "{") {
        at++;
        while (at < source.length && source[at] !== "}") {
          if (source[at++] === "\n") line++;
        }
        if (at === source.length) throw invalid("Unterminated comment.", { line });
        at++;
        continue;
      }
      if (c === '"') {
        let value = "";
        at++;
        while (at < source.length && source[at] !== '"') {
          if (source[at] === "\n") line++;
          value += source[at++];
        }
        if (at === source.length) throw invalid("Unterminated string.", { line });
        at++;
        if (encoder4.encode(value).length >= 128) throw invalid("String exceeds 127 UTF-8 bytes.", { line });
        tokens.push({ text: value, kind: "string", line });
        continue;
      }
      const rest = source.slice(at);
      const match = /^(?:(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?(?:[ \t]*(?:da|[umcdhk])){0,2}(?:[ \t]*(?:s|Hz|B))?(?![A-Za-z_0-9])|[$~%@?]?[A-Za-z_][A-Za-z_0-9]*|\.(?:and|or|xor|not)\.|:=|->|<=|>=|[()[\],+*/=<>#!&;\-])/.exec(rest);
      if (!match) throw invalid(`Unexpected character ${c}.`, { line });
      at += match[0].length;
      tokens.push({ text: match[0], disabledMessage: disabledMessages.has(line), kind: /^[\d.]/.test(c) && !match[0].startsWith(".a") && !match[0].startsWith(".o") && !match[0].startsWith(".x") && !match[0].startsWith(".n") ? "number" : "token", line });
      if (at === start || tokens.length > 65536) throw invalid("Script exceeds its token budget.", { line });
    }
    tokens.push({ text: "<eof>", line });
    return tokens;
  }
  function preprocess(source) {
    const conditions = /* @__PURE__ */ new Set(), stack = [], disabledMessages = /* @__PURE__ */ new Set();
    let enabled = true, comment = false, string = false;
    const text2 = source.split(/\r?\n/).map((line, index) => {
      const startsInString = string;
      let visible = "";
      for (const character of line) {
        if (!string && !comment && character === "{") comment = true;
        else if (comment && character === "}") {
          comment = false;
          visible += " ";
          continue;
        } else if (!comment && character === '"') string = !string;
        visible += comment ? " " : character;
      }
      const match = !startsInString && /^\s*(SET_CONDITION|RESET_CONDITION|USE_CODE_IF|USE_CODE_IF_NOT|END_USE_CODE)\b(?:\s*\(\s*([A-Za-z_]\w*)\s*\))?\s*$/.exec(visible);
      if (!match) {
        if (conditions.has("NKSP_NO_MESSAGE")) disabledMessages.add(index + 1);
        return enabled ? visible : "";
      }
      const [, directive, name] = match;
      if (directive === "END_USE_CODE") {
        if (!stack.length) throw invalid("Unmatched END_USE_CODE.", { line: index + 1 });
        enabled = stack.pop();
      } else if (directive.startsWith("USE_CODE")) {
        if (!name || stack.length >= 32) throw invalid("Invalid conditional compilation block.", { line: index + 1 });
        stack.push(enabled);
        enabled = enabled && conditions.has(name) === (directive === "USE_CODE_IF");
      } else if (enabled) {
        if (!name) throw invalid("Missing condition name.", { line: index + 1 });
        if (directive === "SET_CONDITION") conditions.add(name);
        else conditions.delete(name);
      }
      return "";
    }).join("\n");
    if (comment) throw invalid("Unterminated comment.");
    if (stack.length) throw invalid("Unterminated conditional compilation block.");
    return { text: text2, disabledMessages };
  }
  function compileSfzScript(source) {
    if (typeof source !== "string" || source.length > 262144) throw invalid("Script exceeds its source budget.");
    const prepared = preprocess(source);
    const ast = new Parser(tokenize(prepared.text, prepared.disabledMessages)).parse();
    const instructions = [], constants2 = [], variables = [], globals = /* @__PURE__ */ new Map(), initialization = [], diagnostics = [];
    const warned = /* @__PURE__ */ new Set();
    const cells = [0, 0, 0], entries = Array(6).fill(4294967295), functionEntries = /* @__PURE__ */ new Map(), calls = [];
    let currentFunction = null;
    const emit = (op, a = 0, b2 = 0, c = 0) => {
      if (instructions.length >= 8192) throw invalid("Script exceeds its instruction budget.");
      instructions.push([OP[op], a, b2, c]);
      return instructions.length - 1;
    };
    function literal(node, negative = false) {
      if (node.kind === "string") return { number: 0, kind: 2, flags: 0, text: node.value };
      const match = /^((?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)((?:da|[umcdhk]){0,2})(s|Hz|B)?$/.exec(node.value.replace(/[ \t]/g, ""));
      if (!match) throw invalid("Invalid numeric literal.", node.token);
      const kind = /[.eE]/.test(match[1]) ? 1 : 0;
      const integer = kind ? 0n : BigInt(match[1]) * (negative ? -1n : 1n);
      if (integer < -(1n << 63n) || integer > 1n << 63n) throw invalid("Integer literal exceeds signed 64-bit storage.", node.token);
      let number2 = Number(match[1]) * (negative ? -1 : 1), flags = match[3] === "s" ? 1 : match[3] === "Hz" ? 2 : match[3] === "B" ? 3 : 0;
      let exponent = 0;
      for (const prefix of match[2].match(/da|[umcdhk]/g) || []) exponent += { u: -6, m: -3, c: -2, d: -1, da: 1, h: 2, k: 3 }[prefix];
      number2 *= 10 ** exponent;
      if (match[2]) flags |= 512 | (exponent & 255) << 16;
      if (!Number.isFinite(number2)) throw invalid("Invalid numeric literal.", node.token);
      return { number: number2, integer, kind, flags, text: "" };
    }
    function constant(value) {
      value.integer ??= value.kind === 0 ? BigInt(value.number) : 0n;
      if (value.kind === 0 && value.integer > (1n << 63n) - 1n) throw invalid("Integer literal exceeds signed 64-bit storage.");
      const index = constants2.findIndex((item) => item.number === value.number && item.integer === value.integer && item.kind === value.kind && item.flags === value.flags && item.text === value.text);
      if (index >= 0) return index;
      if (constants2.length >= 512) throw invalid("Script exceeds its constant budget.");
      constants2.push(value);
      return constants2.length - 1;
    }
    const numeric = (number2) => constant({ number: number2, kind: 0, flags: 0, text: "" });
    function staticCoefficient(node, depth = 0) {
      if (depth > 64) throw invalid("Constant expression is recursive or too deeply nested.", node.token);
      const checked = (integer, exponent) => {
        if (integer < -(1n << 63n) || integer > (1n << 63n) - 1n || exponent < -12 || exponent > 12) throw invalid("Constant arithmetic exceeds its numeric budget.", node.token);
        return { integer, exponent };
      };
      if (node.kind === "number" || node.kind === "unary" && node.op === "-" && node.value.kind === "number") {
        const value = literal(node.kind === "number" ? node : node.value, node.kind === "unary");
        if (value.kind !== 0 || value.flags & 3 || value.integer > (1n << 63n) - 1n) throw invalid("A constant unitless integer is required.", node.token);
        const exponent = value.flags >> 16 & 255;
        return checked(value.integer, exponent < 128 ? exponent : exponent - 256);
      }
      if (node.kind === "unary" && node.op === "-") {
        const value = staticCoefficient(node.value, depth + 1);
        return checked(-value.integer, value.exponent);
      }
      if (node.kind === "variable") {
        if (CONSTANTS.has(node.name) && Number.isInteger(CONSTANTS.get(node.name))) return { integer: BigInt(CONSTANTS.get(node.name)), exponent: 0 };
        const variable = globals.get(node.name);
        if (variable?.constant && variable.declaration.value) return staticCoefficient(variable.declaration.value, depth + 1);
      }
      if (node.kind === "binary") {
        const a = staticCoefficient(node.left, depth + 1), b2 = staticCoefficient(node.right, depth + 1);
        if (node.op === "*" || node.op === "/") {
          if (node.op === "/" && b2.integer === 0n) throw invalid("Constant division by zero.", node.token);
          if (node.op === "*") return checked(a.integer * b2.integer, a.exponent + b2.exponent);
          const difference = a.exponent - b2.exponent;
          const numerator = difference > 0 ? a.integer * 10n ** BigInt(difference) : a.integer;
          const denominator = difference < 0 ? b2.integer * 10n ** BigInt(-difference) : b2.integer;
          return checked(numerator / denominator, 0);
        }
        const exponent = Math.min(a.exponent, b2.exponent);
        const left = a.integer * 10n ** BigInt(a.exponent - exponent), right = b2.integer * 10n ** BigInt(b2.exponent - exponent);
        if (node.op === "+") return checked(left + right, exponent);
        if (node.op === "-") return checked(left - right, exponent);
      }
      throw invalid("A constant integer expression is required.", node.token);
    }
    function staticNumber(node) {
      const value = staticCoefficient(node);
      if (value.exponent < -12 || value.exponent > 12) throw invalid("Constant metric precision exceeds its budget.", node.token);
      const scale = 10n ** BigInt(Math.abs(value.exponent));
      if (value.exponent < 0 && value.integer % scale !== 0n) throw invalid("A whole constant integer is required.", node.token);
      return value.exponent < 0 ? value.integer / scale : value.integer * scale;
    }
    function declare(node, scope) {
      if (variables.length >= 128) throw invalid("Script exceeds its variable budget.", node.token);
      if (node.modifiers.includes("local") && node.modifiers.includes("polyphonic")) throw invalid("Variable has conflicting scopes.", node.token);
      if ([...CONSTANTS.keys(), ...SFZ_SCRIPT_VARIABLES].some((name) => name.slice(1) === node.name.slice(1))) throw invalid("Reserved variable name.", node.token);
      const array = /^[%?]/.test(node.name);
      if (scope === 2 && (array || node.name.startsWith("@"))) throw invalid("Polyphonic variables must be numeric scalars.", node.token);
      if (array !== Boolean(node.size)) throw invalid("Array declarations require a size.", node.token);
      const length = array ? Number(staticNumber(node.size)) : 1;
      if (!Number.isInteger(length) || length < 1 || cells[scope] + length > [256, 64, 16][scope]) throw invalid("Variable storage exceeds its budget.", node.token);
      const variable = {
        id: variables.length,
        scope,
        type: node.name[0] === "@" ? 2 : /[~?]/.test(node.name[0]) ? 1 : 0,
        offset: cells[scope],
        length,
        array,
        constant: node.modifiers.includes("const"),
        declaration: node
      };
      variables.push(variable);
      cells[scope] += length;
      return variable;
    }
    function collect(body) {
      for (const node of body) {
        if (node.kind === "declare" && !node.modifiers.includes("local")) {
          if ([...globals.keys(), ...CONSTANTS.keys(), ...SFZ_SCRIPT_VARIABLES].some((name) => name.slice(1) === node.name.slice(1))) throw invalid("Repeated or reserved variable.", node.token);
          const variable = declare(node, node.modifiers.includes("polyphonic") ? 2 : 0);
          globals.set(node.name, variable);
          if (variable.scope === 0) initialization.push(node);
          else if (node.value) throw invalid("Polyphonic variables cannot have an initializer.", node.token);
        }
        if (node.body) collect(node.body);
        if (node.yes) {
          collect(node.yes);
          collect(node.no);
        }
        if (node.cases) for (const item of node.cases) collect(item.body);
      }
    }
    collect(ast.declarations);
    for (const body of ast.callbacks.values()) collect(body);
    for (const fn2 of ast.functions.values()) collect(fn2.body);
    for (const fn2 of ast.functions.values()) {
      fn2.locals = /* @__PURE__ */ new Map();
      fn2.variables = [];
      fn2.firstLocal = cells[1];
      for (const node of [...fn2.parameters, ...fn2.result ? [fn2.result] : []]) {
        if ([...fn2.locals.keys()].some((name) => name.slice(1) === node.name.slice(1))) throw invalid("Repeated function parameter or result.", node.token);
        const variable = declare(node, 1);
        fn2.locals.set(node.name, variable);
        fn2.variables.push(variable);
      }
      const allocateLocals = (body) => {
        for (const node of body) {
          if (node.kind === "declare" && node.modifiers.includes("local")) node.variable = declare(node, 1);
          if (node.body) allocateLocals(node.body);
          if (node.yes) {
            allocateLocals(node.yes);
            allocateLocals(node.no);
          }
          if (node.cases) for (const item of node.cases) allocateLocals(item.body);
        }
      };
      allocateLocals(fn2.body);
      fn2.localCount = cells[1] - fn2.firstLocal;
    }
    function lookup(node, locals) {
      if (!locals.has(node.name) && [...locals.keys()].some((name) => name.slice(1) === node.name.slice(1))) throw invalid("Local variable was referenced with a different type prefix.", node.token);
      const variable = locals.get(node.name) || globals.get(node.name);
      if (!variable) throw invalid(`Unknown variable ${node.name}.`, node.token);
      return variable;
    }
    const type = (kind = 0, unit = 0, array = false, final = false) => ({ kind, unit, array, final });
    const currentFinal = /* @__PURE__ */ new Map();
    function variableType(variable, locals, depth) {
      if (variable.unit === void 0) {
        if (variable.resolvingType) throw invalid("Variable initializer is recursive.", variable.declaration.token);
        variable.resolvingType = true;
        const value = variable.declaration.value;
        const initial = value && !Array.isArray(value) ? typeOf(value, locals, depth + 1) : type();
        variable.unit = initial.unit;
        variable.final = initial.final;
        variable.resolvingType = false;
      }
      return type(variable.type, variable.unit, variable.array, variable.final);
    }
    function typeOf(node, locals, depth = 0) {
      if (depth > 64) throw invalid("Type expression exceeds its nesting budget.", node.token);
      if (node.kind === "number" || node.kind === "string") {
        const v = literal(node);
        return type(v.kind, v.flags & 3);
      }
      if (node.kind === "variable") {
        if (node.deprecatedArrayName && !warned.has(node)) {
          diagnostics.push({
            code: "legacy-array-name",
            severity: "warning",
            line: node.token.line,
            message: "Use %ALL_EVENTS for the NKSP event array."
          });
          warned.add(node);
        }
        if (CONSTANTS.has(node.name)) {
          if (node.index) throw invalid("A scalar constant cannot be indexed.", node.token);
          return type(/NI_MATH_(?:E|PI)$/.test(node.name) ? 1 : 0);
        }
        if (SFZ_SCRIPT_VARIABLES.includes(node.name)) {
          const array = node.name.startsWith("%");
          if (node.index) {
            const index = typeOf(node.index, locals, depth + 1);
            if (!array || index.kind !== 0 || index.unit || index.array) throw invalid("Invalid built-in variable index.", node.token);
          }
          return type(0, 0, array && !node.index);
        }
        const variable = lookup(node, locals);
        const result = variableType(variable, locals, depth);
        if (!variable.constant) result.final = currentFinal.get(variable.id) || false;
        if (node.index) {
          const index = typeOf(node.index, locals, depth + 1);
          if (index.kind !== 0 || index.unit || index.array || !result.array) throw invalid("Array index must be a unitless integer.", node.token);
          return { ...result, array: false };
        }
        return result;
      }
      if (node.kind === "unary") {
        const result = typeOf(node.value, locals, depth + 1);
        if (result.array || result.kind > 1) throw invalid("Numeric unary operator requires a number.", node.token);
        if (["not", ".not."].includes(node.op) && (result.kind !== 0 || result.unit)) throw invalid("Boolean and bit operators require unitless integers.", node.token);
        return ["not", ".not."].includes(node.op) ? type() : { ...result, final: result.final || node.op === "!" };
      }
      if (node.kind === "binary") {
        const left = typeOf(node.left, locals, depth + 1), right = typeOf(node.right, locals, depth + 1);
        if (["+", "-", "*", "/"].includes(node.op) && left.final !== right.final && !warned.has(node)) {
          diagnostics.push({
            code: "mixed-finalness",
            severity: "warning",
            line: node.token.line,
            message: "Combining final and relative values produces a final result."
          });
          warned.add(node);
        }
        if (left.array || right.array || left.kind === 3 || right.kind === 3) throw invalid("Operator requires scalar values.", node.token);
        if (node.op === "&") return type(2);
        if (left.kind !== right.kind || left.kind === 2) throw invalid("Numeric operands must have matching types; use an explicit cast.", node.token);
        let unit = left.unit;
        if (node.op === "*") {
          if (left.unit && right.unit) throw invalid("Multiplication cannot combine two units.", node.token);
          unit |= right.unit;
        } else if (node.op === "/") {
          if (right.unit && left.unit !== right.unit) throw invalid("Division has incompatible units.", node.token);
          if (right.unit) unit = 0;
        } else if (left.unit !== right.unit) throw invalid("Operands have different units.", node.token);
        if (["and", "or", ".and.", ".or.", ".xor.", "mod"].includes(node.op) && (left.kind !== 0 || unit)) throw invalid("Integer operation requires unitless integers.", node.token);
        return ["=", "#", "<", ">", "<=", ">=", "and", "or"].includes(node.op) ? type() : type(left.kind, unit, false, left.final || right.final);
      }
      if (node.kind === "call") {
        const fn2 = ast.functions.get(node.name);
        if (!fn2) throw invalid(`Unknown user function ${node.name}.`, node.token);
        if (node.args.length > fn2.parameters.length) throw invalid("Too many user function arguments.", node.token);
        for (let i = 0; i < fn2.parameters.length; i++) {
          const argument = node.args[i] || fn2.parameters[i].value;
          if (!argument) throw invalid("Missing user function argument.", node.token);
          const actual = typeOf(argument, node.args[i] ? locals : /* @__PURE__ */ new Map(), depth + 1);
          const expected = variableType(fn2.variables[i], /* @__PURE__ */ new Map(), depth + 1);
          if (actual.array || actual.kind !== expected.kind || actual.unit !== expected.unit) throw invalid("User function argument type or unit does not match.", node.token);
        }
        currentFinal.clear();
        return fn2.result ? { ...variableType(fn2.variables.at(-1), /* @__PURE__ */ new Map(), depth + 1), final: false } : type(3);
      }
      const args = node.args.map((arg) => typeOf(arg, locals, depth + 1));
      const first = args[0] || type();
      const requireNumeric = (index, units = [0]) => {
        const arg = args[index];
        if (arg && (arg.kind > 1 || arg.array || !units.includes(arg.unit))) throw invalid(`Invalid numeric argument for ${node.name}.`, node.token);
      };
      const requireInteger = (index, allowFinal = false) => {
        requireNumeric(index);
        if (args[index] && (args[index].kind !== 0 || !allowFinal && args[index].final)) throw invalid(`Argument requires a plain integer for ${node.name}.`, node.token);
      };
      if (["num_elements", "array_equal", "search", "sort"].includes(node.name)) {
        if (!first.array || node.name === "array_equal" && !args[1]?.array) throw invalid("Array argument required.", node.token);
        if (node.name === "array_equal" && first.kind !== args[1].kind) throw invalid("Array element types must match.", node.token);
        if (node.name === "search" && (!args[1] || args[1].array || args[1].kind !== first.kind || args[1].unit)) throw invalid("Search value must match the array element type.", node.token);
        if (node.name === "sort") {
          if (node.args[0].kind !== "variable" || lookup(node.args[0], locals).constant) throw invalid("Sorting requires a writable array.", node.token);
          requireNumeric(1);
          if (args[1] && args[1].kind !== 0) throw invalid("Sort direction must be an integer.", node.token);
        }
        return type(node.name === "sort" ? 3 : 0);
      }
      if (node.name === "by_marks") {
        requireInteger(0);
        return type(0, 0, true);
      }
      if (["sh_left", "sh_right"].includes(node.name)) {
        requireInteger(0, true);
        requireInteger(1);
        return first;
      }
      if (node.name === "message") {
        if (first.array || first.kind === 3) throw invalid("Message requires a scalar value.", node.token);
        return type(3);
      }
      if (["inc", "dec"].includes(node.name)) {
        requireNumeric(0, [0, 1, 2, 3]);
        if (first.kind !== 0 || node.args[0]?.kind !== "variable") throw invalid("Increment/decrement requires an integer variable.", node.token);
        return first;
      }
      if (["int", "real_to_int", "real", "int_to_real", "abs", "ceil", "floor", "round"].includes(node.name)) {
        requireNumeric(0, [0, 1, 2, 3]);
        if (["ceil", "floor", "round", "int", "real_to_int"].includes(node.name) && first.kind !== 1) throw invalid("Function requires a real number.", node.token);
        if (["real", "int_to_real"].includes(node.name) && first.kind !== 0) throw invalid("Function requires an integer number.", node.token);
        return type(["real", "int_to_real"].includes(node.name) ? 1 : ["int", "real_to_int"].includes(node.name) ? 0 : first.kind, first.unit, false, first.final);
      }
      if (["acos", "asin", "atan", "cos", "sin", "tan", "sqrt", "exp", "log", "log2", "log10", "pow"].includes(node.name)) {
        requireNumeric(0, [0, 1, 2, 3]);
        if (first.kind !== 1) throw invalid("Function requires real arguments.", node.token);
        if (node.name === "pow") {
          requireNumeric(1);
          if (args[1]?.kind !== 1) throw invalid("Power requires a real exponent.", node.token);
        }
        return first;
      }
      if (["min", "max", "random", "in_range"].includes(node.name)) {
        for (let i = 0; i < args.length; i++) {
          requireNumeric(i, [first.unit]);
          if (args[i].kind !== first.kind) throw invalid("Function argument types must match.", node.token);
        }
        return node.name === "in_range" ? type() : { ...first, final: args.some((arg) => arg.final) };
      }
      if (node.name === "wait") {
        requireNumeric(0, [0, 1]);
        return type(3);
      }
      if (node.name === "play_note") {
        requireInteger(0);
        requireInteger(1);
        requireNumeric(2, [0, 1]);
        requireNumeric(3, [0, 1]);
        return type();
      }
      if (node.name.startsWith("change_") || ["fade_in", "fade_out"].includes(node.name)) {
        if (!first.array) requireInteger(0);
        else if (first.kind !== 0) throw invalid("Note IDs require an integer array.", node.token);
        const units = /(?:attack|decay|release|_time|play_pos)$/.test(node.name) || node.name.startsWith("fade_") ? [0, 1] : /(?:_freq|cutoff)$/.test(node.name) ? [0, 2] : ["change_vol", "change_sustain", "change_cutoff_sustain"].includes(node.name) ? [0, 3] : [0];
        requireNumeric(1, units);
        if (["change_note", "change_velo", "change_pan", "change_reso", "change_pitch_lfo_depth", "change_cutoff_lfo_depth"].includes(node.name) || node.name.endsWith("_curve")) requireInteger(1, !["change_note", "change_velo"].includes(node.name) && !node.name.endsWith("_curve"));
        if (["change_tune", "fade_out"].includes(node.name)) requireNumeric(2);
        else requireInteger(2);
        return type(3);
      }
      for (let i = 0; i < args.length; i++) {
        if (i === 0 && first.array && first.kind === 0 && ["note_off", "ignore_event", "set_event_mark", "delete_event_mark", "set_event_par"].includes(node.name)) continue;
        requireInteger(i);
      }
      return type(["abort", "exit", "stop_wait", "ignore_controller", "ignore_event", "note_off", "set_event_mark", "delete_event_mark", "set_event_par"].includes(node.name) ? 3 : 0);
    }
    function reference(node, locals) {
      if (node.kind !== "variable") throw invalid("A variable is required.", node.token);
      const variable = lookup(node, locals);
      if (variable.constant) throw invalid("A constant cannot be modified.", node.token);
      if (node.index) expression(node.index, locals);
      else emit("constant", numeric(0));
      emit("reference", variable.id, node.index ? 0 : variable.length);
      return variable;
    }
    function expression(node, locals) {
      typeOf(node, locals);
      if (node.kind === "call") {
        const fn2 = ast.functions.get(node.name);
        for (let i = 0; i < fn2.parameters.length; i++) {
          emit("constant", numeric(0));
          expression(node.args[i] || fn2.parameters[i].value, node.args[i] ? locals : /* @__PURE__ */ new Map());
        }
        calls.push([emit("call", 0, fn2.firstLocal | fn2.parameters.length << 16, fn2.localCount), node]);
        currentFinal.clear();
        if (!fn2.result) emit("constant", numeric(0));
        return fn2.result ? fn2.variables.at(-1).type : 0;
      }
      if (node.kind === "number" || node.kind === "string") {
        const value = literal(node);
        emit("constant", constant(value));
        return value.kind;
      }
      if (node.kind === "unary") {
        if (node.op === "-" && node.value.kind === "number") {
          const value = literal(node.value, true);
          emit("constant", constant(value));
          return value.kind;
        }
        const type2 = expression(node.value, locals);
        emit("unary", ["-", "+", "not", ".not.", "!"].indexOf(node.op));
        return type2;
      }
      if (node.kind === "binary") {
        const left = expression(node.left, locals), right = expression(node.right, locals);
        emit("binary", BINARY.indexOf(node.op));
        return node.op === "&" ? 2 : left === 1 || right === 1 ? 1 : 0;
      }
      if (node.kind === "variable") {
        if (CONSTANTS.has(node.name)) {
          const kind = /NI_MATH_(?:E|PI)$/.test(node.name) ? 1 : 0;
          emit("constant", constant({ number: CONSTANTS.get(node.name), kind, flags: 0, text: "" }));
          return kind;
        }
        const builtin = SFZ_SCRIPT_VARIABLES.indexOf(node.name);
        if (builtin >= 0) {
          if (node.index) expression(node.index, locals);
          else emit("constant", numeric(0));
          emit("builtinVariable", builtin, node.index ? 0 : node.name.startsWith("%") ? 1 : 0);
          return 0;
        }
        const variable = lookup(node, locals);
        if (node.index && !variable.array) throw invalid("Scalar variable cannot be indexed.", node.token);
        if (variable.array && !node.index) {
          emit("constant", numeric(0));
          emit("reference", variable.id, variable.length);
        } else {
          if (node.index) expression(node.index, locals);
          else emit("constant", numeric(0));
          emit("load", variable.id);
        }
        return variable.type;
      }
      const id = SFZ_SCRIPT_BUILTINS.indexOf(node.name);
      if (id < 0) throw invalid(`Unknown function ${node.name}.`, node.token);
      const [min, max] = SIGNATURES.get(node.name) || (node.name.startsWith("change_") ? [2, 2] : [1, 1]);
      if (node.args.length < min || node.args.length > max) throw invalid(`Invalid argument count for ${node.name}.`, node.token);
      if (node.name === "message" && node.token.disabledMessage) {
        emit("constant", numeric(0));
        return 0;
      }
      for (let i = 0; i < node.args.length; i++) {
        if ((node.name === "inc" || node.name === "dec") && i === 0) reference(node.args[i], locals);
        else expression(node.args[i], locals);
      }
      emit("builtin", id, node.args.length);
      if (["wait", "fork", "stop_wait"].includes(node.name)) currentFinal.clear();
      return ["real", "int_to_real", "acos", "asin", "atan", "cos", "sin", "tan", "sqrt", "pow", "exp", "log", "log2", "log10"].includes(node.name) ? 1 : 0;
    }
    function initialize(node, variable, locals) {
      const values = Array.isArray(node.value) ? node.value : [node.value];
      if (values.length > variable.length) throw invalid("Too many array initializers.", node.token);
      for (let index = 0; index < variable.length; index++) {
        emit("constant", numeric(index));
        if (values[index]) {
          const actual = typeOf(values[index], locals), expected = variableType(variable, locals, 0);
          if (actual.array || actual.kind !== expected.kind || variable.array && (actual.unit || actual.final)) throw invalid("Initializer type does not match the declared variable.", node.token);
          expression(values[index], locals);
        } else emit("constant", constant({ number: 0, kind: variable.type, flags: 0, text: "" }));
        emit("store", variable.id, variable.array ? 1 : 0);
      }
      if (!variable.array) currentFinal.set(variable.id, values[0] ? typeOf(values[0], locals).final : false);
    }
    function block(body, inherited = /* @__PURE__ */ new Map()) {
      const locals = new Map(inherited);
      const declared = new Set(currentFunction && inherited === currentFunction.locals ? [...inherited.keys()].map((name) => name.slice(1)) : []);
      for (const node of body) {
        if (node.kind === "declare") {
          if (node.modifiers.includes("local")) {
            if (declared.has(node.name.slice(1))) throw invalid("Repeated local variable in the same block.", node.token);
            declared.add(node.name.slice(1));
            const variable = node.variable || declare(node, 1);
            locals.set(node.name, variable);
            initialize(node, variable, locals);
          }
        } else if (node.kind === "assign") {
          const variable = lookup(node.target, locals);
          typeOf(node.target, locals);
          if (variable.constant || variable.array && !node.target.index) throw invalid("Assignment target is not writable.", node.token);
          const actual = typeOf(node.value, locals), expected = variableType(variable, locals, 0);
          if (actual.array || actual.kind !== expected.kind || actual.unit !== expected.unit || variable.array && actual.final) throw invalid("Assignment type or unit does not match the variable.", node.token);
          if (node.target.index) expression(node.target.index, locals);
          else emit("constant", numeric(0));
          expression(node.value, locals);
          emit("store", variable.id, variable.array ? 1 : 0);
          if (!variable.array) currentFinal.set(variable.id, actual.final);
        } else if (node.kind === "expression") {
          if (currentFunction && node.value.kind === "builtin" && node.value.name === "exit") {
            if (node.value.args.length) throw invalid("Exit does not accept arguments.", node.token);
            currentFunction.exits.push(emit("jump"));
          } else {
            expression(node.value, locals);
            emit("drop");
          }
        } else if (node.kind === "if") {
          const condition = typeOf(node.condition, locals);
          if (condition.array || condition.kind > 1) throw invalid("Condition requires a numeric scalar.", node.token);
          expression(node.condition, locals);
          const branch = emit("jumpFalse");
          currentFinal.clear();
          block(node.yes, locals);
          const done = emit("jump");
          currentFinal.clear();
          instructions[branch][1] = instructions.length;
          block(node.no, locals);
          instructions[done][1] = instructions.length;
          currentFinal.clear();
        } else if (node.kind === "while") {
          const condition = typeOf(node.condition, locals);
          if (condition.array || condition.kind > 1) throw invalid("Condition requires a numeric scalar.", node.token);
          const start = instructions.length;
          expression(node.condition, locals);
          const done = emit("jumpFalse");
          currentFinal.clear();
          block(node.body, locals);
          emit("jump", start);
          instructions[done][1] = instructions.length;
          currentFinal.clear();
        } else if (node.kind === "synchronized") {
          emit("synchronized", 1);
          block(node.body, locals);
          emit("synchronized", 0);
        } else if (node.kind === "select") {
          const selected = typeOf(node.value, locals);
          if (selected.kind !== 0 || selected.array || selected.unit) throw invalid("Select requires a unitless integer.", node.token);
          expression(node.value, locals);
          const ends = [];
          for (const item of node.cases) {
            currentFinal.clear();
            const low = staticNumber(item.low), high = staticNumber(item.high);
            for (const bound of [item.low, item.high]) {
              const value = typeOf(bound, locals);
              if (value.kind !== 0 || value.array || value.unit) throw invalid("Case bounds require constant unitless integers.", node.token);
            }
            if (low > high) throw invalid("Case range is reversed.", node.token);
            emit("duplicate");
            expression(item.low, locals);
            expression(item.high, locals);
            emit("builtin", SFZ_SCRIPT_BUILTINS.indexOf("in_range"), 3);
            const next = emit("jumpFalse");
            emit("drop");
            block(item.body, locals);
            ends.push(emit("jump"));
            instructions[next][1] = instructions.length;
          }
          emit("drop");
          for (const end of ends) instructions[end][1] = instructions.length;
          currentFinal.clear();
        }
      }
    }
    entries[0] = 0;
    for (const declaration of initialization) initialize(declaration, globals.get(declaration.name), /* @__PURE__ */ new Map());
    block(ast.callbacks.get("init") || []);
    emit("end");
    for (let i = 1; i < 6; i++) if (ast.callbacks.has(SFZ_SCRIPT_CALLBACKS[i])) {
      currentFinal.clear();
      entries[i] = instructions.length;
      block(ast.callbacks.get(SFZ_SCRIPT_CALLBACKS[i]));
      emit("end");
    }
    for (const [name, fn2] of ast.functions) {
      currentFinal.clear();
      functionEntries.set(name, instructions.length);
      currentFunction = fn2;
      fn2.exits = [];
      for (let i = fn2.parameters.length - 1; i >= 0; i--) emit("store", fn2.variables[i].id);
      if (fn2.result) initialize(fn2.result, fn2.variables.at(-1), fn2.locals);
      block(fn2.body, fn2.locals);
      for (const exit of fn2.exits) instructions[exit][1] = instructions.length;
      emit("ret", fn2.result ? fn2.variables.at(-1).id + 1 : 0);
      currentFunction = null;
    }
    for (const [index, node] of calls) {
      if (!functionEntries.has(node.name)) throw invalid(`Unknown user function ${node.name}.`, node.token);
      instructions[index][1] = functionEntries.get(node.name);
    }
    const bytes = new Uint8Array(64 + variables.length * 16 + constants2.length * 144 + instructions.length * 16);
    const view = new DataView(bytes.buffer);
    let offset = 0;
    const u32 = (value) => {
      view.setUint32(offset, value, true);
      offset += 4;
    };
    [827542350, SFZ_SCRIPT_PROGRAM_VERSION, instructions.length, constants2.length, variables.length, 0, ...cells, ...entries, 0].forEach(u32);
    for (const variable of variables) [variable.scope, variable.type, variable.offset, variable.length].forEach(u32);
    for (const value of constants2) {
      if (value.kind === 0) view.setBigInt64(offset, value.integer, true);
      else view.setFloat64(offset, value.number, true);
      offset += 8;
      u32(value.kind);
      u32(value.flags);
      bytes.set(encoder4.encode(value.text), offset);
      offset += 128;
    }
    for (const instruction of instructions) instruction.forEach(u32);
    const requiredBuiltins = [...new Set(instructions.filter((instruction) => instruction[0] === OP.builtin).map((instruction) => SFZ_SCRIPT_BUILTINS[instruction[1]]))];
    return { version: SFZ_SCRIPT_PROGRAM_VERSION, bytes, callbacks: entries, requiredBuiltins, diagnostics };
  }
  var SFZ_SCRIPT_CALLBACKS, SFZ_SCRIPT_BUILTINS, SFZ_SCRIPT_VARIABLES, OP, BINARY, PRECEDENCE, CONSTANTS, SIGNATURES, encoder4, Parser;
  var init_script_compiler = __esm({
    "js/sfz/script-compiler.js"() {
      init_script_format();
      SFZ_SCRIPT_CALLBACKS = Object.freeze(["init", "note", "release", "controller", "rpn", "nrpn"]);
      SFZ_SCRIPT_BUILTINS = Object.freeze([
        "abort",
        "acos",
        "abs",
        "array_equal",
        "asin",
        "atan",
        "callback_status",
        "ceil",
        "cos",
        "dec",
        "exit",
        "exp",
        "floor",
        "fork",
        "inc",
        "int",
        "int_to_real",
        "in_range",
        "log",
        "log10",
        "log2",
        "lsb",
        "max",
        "message",
        "min",
        "msb",
        "num_elements",
        "pow",
        "random",
        "real",
        "real_to_int",
        "round",
        "search",
        "sh_left",
        "sh_right",
        "sin",
        "sort",
        "sqrt",
        "stop_wait",
        "tan",
        "wait",
        "by_marks",
        "change_amp_lfo_depth",
        "change_amp_lfo_freq",
        "change_attack",
        "change_cutoff",
        "change_cutoff_attack",
        "change_cutoff_decay",
        "change_cutoff_lfo_depth",
        "change_cutoff_lfo_freq",
        "change_cutoff_release",
        "change_cutoff_sustain",
        "change_decay",
        "change_note",
        "change_pan",
        "change_pan_curve",
        "change_pan_time",
        "change_pitch_lfo_depth",
        "change_pitch_lfo_freq",
        "change_play_pos",
        "change_release",
        "change_reso",
        "change_sustain",
        "change_tune",
        "change_tune_curve",
        "change_tune_time",
        "change_velo",
        "change_vol",
        "change_vol_curve",
        "change_vol_time",
        "delete_event_mark",
        "event_status",
        "fade_in",
        "fade_out",
        "get_event_par",
        "ignore_controller",
        "ignore_event",
        "note_off",
        "play_note",
        "set_controller",
        "set_event_mark",
        "set_event_par",
        "set_nrpn",
        "set_rpn"
      ]);
      SFZ_SCRIPT_VARIABLES = Object.freeze([
        "$KSP_TIMER",
        "$NKSP_PERF_TIMER",
        "%NKSP_CALLBACK_CHILD_ID",
        "$NKSP_CALLBACK_PARENT_ID",
        "$NKSP_REAL_TIMER",
        "$NI_CALLBACK_ID",
        "$NI_CALLBACK_TYPE",
        "$NKSP_IGNORE_WAIT",
        "%ALL_EVENTS",
        "$CC_NUM",
        "%CC",
        "$EVENT_ID",
        "$EVENT_NOTE",
        "$EVENT_VELOCITY",
        "%KEY_DOWN",
        "$RPN_ADDRESS",
        "$RPN_VALUE",
        "$ENGINE_UPTIME"
      ]);
      OP = Object.freeze({
        end: 0,
        constant: 1,
        load: 2,
        store: 3,
        builtinVariable: 4,
        reference: 5,
        unary: 6,
        binary: 7,
        jump: 8,
        jumpFalse: 9,
        builtin: 10,
        drop: 11,
        call: 12,
        ret: 13,
        duplicate: 14,
        synchronized: 15
      });
      BINARY = ["+", "-", "*", "/", "mod", "=", "#", "<", ">", "<=", ">=", "and", "or", ".and.", ".or.", ".xor.", "&"];
      PRECEDENCE = /* @__PURE__ */ new Map([
        ["or", 1],
        ["and", 2],
        ["=", 3],
        ["#", 3],
        ["<", 3],
        [">", 3],
        ["<=", 3],
        [">=", 3],
        [".or.", 4],
        [".xor.", 4],
        [".and.", 5],
        ["&", 0],
        ["+", 7],
        ["-", 7],
        ["*", 8],
        ["/", 8],
        ["mod", 8]
      ]);
      CONSTANTS = new Map([
        ["$CALLBACK_STATUS_QUEUE", 1],
        ["$CALLBACK_STATUS_RUNNING", 2],
        ["$CALLBACK_STATUS_TERMINATED", 0],
        ["$EVENT_STATUS_INACTIVE", 0],
        ["$EVENT_STATUS_NOTE_QUEUE", 1],
        ["$EVENT_PAR_NOTE", 0],
        ["$EVENT_PAR_TUNE", 1],
        ["$EVENT_PAR_VELOCITY", 2],
        ["$EVENT_PAR_VOLUME", 3],
        ["$VCC_MONO_AT", 128],
        ["$VCC_PITCH_BEND", 129],
        ["$NKSP_LINEAR", 0],
        ["$NKSP_EASE_IN_EASE_OUT", 1],
        ["$NI_MATH_E", Math.E],
        ["$NI_MATH_PI", Math.PI],
        ["~NI_MATH_E", Math.E],
        ["~NI_MATH_PI", Math.PI],
        ...SFZ_SCRIPT_CALLBACKS.map((name, index) => [`$NI_CB_TYPE_${name.toUpperCase()}`, index]),
        ...Array.from({ length: 4 }, (_2, i) => [`$EVENT_PAR_${i}`, i + 4]),
        ...Array.from({ length: 28 }, (_2, i) => [`$MARK_${i + 1}`, 2 ** i])
      ]);
      SIGNATURES = new Map([
        ["abort", [1, 1]],
        ["exit", [0, 0]],
        ["fork", [0, 2]],
        ["stop_wait", [1, 2]],
        ["wait", [1, 1]],
        ["play_note", [1, 4]],
        ["note_off", [1, 2]],
        ["ignore_controller", [0, 1]],
        ["ignore_event", [0, 1]],
        ["fade_in", [2, 2]],
        ["fade_out", [2, 3]],
        ["set_event_par", [3, 3]],
        ["set_rpn", [2, 2]],
        ["set_nrpn", [2, 2]],
        ["get_event_par", [2, 2]],
        ["sort", [1, 2]],
        ["search", [2, 2]],
        ["array_equal", [2, 2]],
        ["in_range", [3, 3]],
        ["random", [2, 2]],
        ["pow", [2, 2]],
        ["min", [2, 2]],
        ["max", [2, 2]],
        ["sh_left", [2, 2]],
        ["sh_right", [2, 2]],
        ["set_controller", [2, 2]],
        ["set_event_mark", [2, 2]],
        ["delete_event_mark", [2, 2]],
        ...["change_vol", "change_tune", "change_pan"].map((name) => [name, [2, 3]])
      ]);
      encoder4 = new TextEncoder();
      Parser = class {
        constructor(tokens) {
          this.tokens = tokens;
          this.at = 0;
          this.depth = 0;
        }
        peek(text2) {
          return this.tokens[this.at].text === text2;
        }
        take() {
          return this.tokens[this.at++];
        }
        accept(text2) {
          if (!this.peek(text2)) return false;
          this.at++;
          return true;
        }
        expect(text2) {
          if (!this.accept(text2)) throw invalid(`Expected ${text2}.`, this.tokens[this.at]);
        }
        expression(minimum = 0) {
          if (++this.depth > 64) throw invalid("Expression nesting exceeds 64 levels.", this.tokens[this.at]);
          const token = this.take();
          let node;
          if (["-", "+", "not", ".not.", "!"].includes(token.text)) node = { kind: "unary", op: token.text, value: this.expression(9), token };
          else if (token.text === "(") {
            node = this.expression();
            this.expect(")");
          } else if (token.kind === "number" || token.kind === "string") node = { kind: token.kind, value: token.text, token };
          else if (token.text === "call") {
            const name = this.take().text, args = [];
            if (this.accept("(")) {
              if (!this.peek(")")) do {
                args.push(this.expression());
              } while (this.accept(","));
              this.expect(")");
            }
            node = { kind: "call", name, args, token };
          } else if (/^[$~%@?]/.test(token.text)) {
            node = {
              kind: "variable",
              name: token.text === "$ALL_EVENTS" ? "%ALL_EVENTS" : token.text,
              deprecatedArrayName: token.text === "$ALL_EVENTS",
              token
            };
            if (this.accept("[")) {
              node.index = this.expression();
              this.expect("]");
            }
          } else if (/^[A-Za-z_]/.test(token.text)) {
            const args = [];
            if (token.text === "exit" && !this.peek("(")) {
              this.depth--;
              return { kind: "builtin", name: "exit", args, token };
            }
            this.expect("(");
            if (!this.peek(")")) do {
              args.push(this.expression());
            } while (this.accept(","));
            this.expect(")");
            node = { kind: "builtin", name: token.text, args, token };
          } else throw invalid("Expected an expression.", token);
          while (PRECEDENCE.has(this.tokens[this.at].text) && PRECEDENCE.get(this.tokens[this.at].text) >= minimum) {
            const op = this.take().text;
            node = { kind: "binary", op, left: node, right: this.expression(PRECEDENCE.get(op) + 1), token };
          }
          this.depth--;
          return node;
        }
        block(stop = ["end", "else", "case"]) {
          if (++this.depth > 64) throw invalid("Block nesting exceeds 64 levels.", this.tokens[this.at]);
          const body = [];
          while (!stop.includes(this.tokens[this.at].text) && !this.peek("<eof>")) {
            if (this.accept(";")) continue;
            body.push(this.statement());
          }
          this.depth--;
          return body;
        }
        statement() {
          const token = this.tokens[this.at];
          if (this.accept("declare")) {
            const modifiers = [];
            while (["const", "local", "polyphonic", "patch"].includes(this.tokens[this.at].text)) modifiers.push(this.take().text);
            const name = this.take().text;
            if (!/^[$~%@?][A-Za-z_]\w*$/.test(name)) throw invalid("Invalid variable name.", token);
            let size = null, value2 = null;
            if (this.accept("[")) {
              size = this.expression();
              this.expect("]");
            }
            if (this.accept(":=")) {
              if (size && this.accept("(")) {
                value2 = [];
                if (!this.peek(")")) do {
                  value2.push(this.expression());
                } while (this.accept(","));
                this.expect(")");
              } else value2 = this.expression();
            }
            return { kind: "declare", modifiers, name, size, value: value2, token };
          }
          if (this.accept("if")) {
            const condition = this.expression();
            const yes = this.block();
            const no = this.accept("else") ? this.block() : [];
            this.expect("end");
            this.expect("if");
            return { kind: "if", condition, yes, no, token };
          }
          if (this.accept("while")) {
            const condition = this.expression(), body = this.block();
            this.expect("end");
            this.expect("while");
            return { kind: "while", condition, body, token };
          }
          if (this.accept("select")) {
            const value2 = this.expression(), cases = [];
            while (this.accept("case")) {
              const low = this.expression();
              const high = this.accept("to") ? this.expression() : low;
              cases.push({ low, high, body: this.block() });
            }
            this.expect("end");
            this.expect("select");
            return { kind: "select", value: value2, cases, token };
          }
          if (this.accept("synchronized")) {
            const body = this.block();
            this.expect("end");
            this.expect("synchronized");
            return { kind: "synchronized", body, token };
          }
          const value = this.expression();
          if (this.accept(":=")) {
            if (value.kind !== "variable") throw invalid("Assignment requires a variable.", token);
            return { kind: "assign", target: value, value: this.expression(), token };
          }
          if (value.kind !== "builtin" && value.kind !== "call") throw invalid("Expected an assignment or function call.", token);
          return { kind: "expression", value, token };
        }
        parse() {
          const callbacks = /* @__PURE__ */ new Map(), functions = /* @__PURE__ */ new Map(), declarations = [];
          while (!this.peek("<eof>")) {
            if (this.accept(";")) continue;
            if (this.accept("on")) {
              const token = this.take(), name = token.text;
              if (!SFZ_SCRIPT_CALLBACKS.includes(name) || callbacks.has(name)) throw invalid("Unknown or repeated callback.", token);
              callbacks.set(name, this.block());
              this.expect("end");
              this.expect("on");
            } else if (this.accept("function")) {
              const token = this.take();
              if (functions.has(token.text) || SFZ_SCRIPT_BUILTINS.includes(token.text)) throw invalid("Repeated or reserved function.", token);
              const parameters = [];
              const parameter = () => {
                const name = this.take().text;
                if (!/^[$~@][A-Za-z_]\w*$/.test(name)) throw invalid("Function parameters must be scalar variables.", token);
                return { kind: "declare", name, modifiers: ["local"], value: this.accept(":=") ? this.expression() : null, token };
              };
              if (this.accept("(")) {
                if (!this.peek(")")) do {
                  parameters.push(parameter());
                } while (this.accept(","));
                this.expect(")");
              }
              const result = this.accept("->") ? parameter() : null;
              functions.set(token.text, { parameters, result, body: this.block(), token });
              this.expect("end");
              this.expect("function");
            } else {
              const statement = this.statement();
              if (statement.kind !== "declare") throw invalid("Only declarations are allowed outside callbacks.", statement.token);
              declarations.push(statement);
            }
          }
          return { callbacks, functions, declarations };
        }
      };
    }
  });

  // js/sfz/script-worker.js
  async function compileSfzScriptAsync(source) {
    if (typeof Worker === "undefined") return compileSfzScript(source);
    return new Promise((resolve, reject) => {
      const worker = new Worker(new URL("./script-worker.js", import_meta.url), { type: "module" });
      const finish = (error2, result) => {
        worker.terminate();
        if (error2) reject(error2);
        else resolve(result);
      };
      worker.onmessage = ({ data }) => {
        if (data.error) finish(Object.assign(new Error(data.error.message), data.error));
        else finish(null, data.result);
      };
      worker.onerror = () => finish(Object.assign(new Error("The instrument script could not be prepared."), { code: "script-invalid" }));
      worker.postMessage({ source });
    });
  }
  var import_meta;
  var init_script_worker = __esm({
    "js/sfz/script-worker.js"() {
      init_script_compiler();
      import_meta = {};
      if (typeof WorkerGlobalScope !== "undefined" && globalThis instanceof WorkerGlobalScope) {
        globalThis.onmessage = ({ data }) => {
          try {
            const result = compileSfzScript(data.source);
            globalThis.postMessage({ result }, [result.bytes.buffer]);
          } catch (error2) {
            globalThis.postMessage({ error: { code: error2.code, line: error2.line, message: error2.message } });
          }
        };
      }
    }
  });

  // js/sfz/sample-bank-source.js
  function encodeSfzBankBlob(selectedPath, files, { warnings = [] } = {}) {
    const ordered = [...files].sort(([a], [b2]) => a < b2 ? -1 : a > b2 ? 1 : 0);
    let offset = 0;
    const entries = ordered.map(([path, file]) => {
      if (!(file instanceof Uint8Array) && !(file instanceof Blob)) throw sfzError("prepare", "An SFZ source file could not be read.");
      const length = file instanceof Uint8Array ? file.byteLength : file?.size;
      if (!Number.isSafeInteger(length) || length < 0 || !Number.isSafeInteger(offset + length)) throw sfzError("too-large", "The SFZ source files are too large.");
      const entry = { path: normalizeSfzPath(path), offset, length };
      offset += length;
      return entry;
    });
    const index = { selectedPath: normalizeSfzPath(selectedPath), files: entries, ...warnings.length && { warnings } };
    validateSfzBankIndex(index, offset);
    const metadata = encoder5.encode(JSON.stringify(index));
    if (metadata.length > MAX_INDEX_BYTES) throw sfzError("too-large", "The SFZ file list is too large.");
    const prefix = new Uint8Array(12), view = new DataView(prefix.buffer);
    view.setUint32(0, SFZ_BANK_MAGIC, true);
    view.setUint32(4, 1, true);
    view.setUint32(8, metadata.length, true);
    return new Blob([prefix, metadata, ...ordered.map(([, file]) => file)]);
  }
  async function openSfzBankSource(file) {
    const reader = await createSfzFileSampleReader(file);
    const prefix = await reader.readRange(0, 12), view = new DataView(prefix.buffer, prefix.byteOffset, 12);
    const length = view.getUint32(8, true);
    if (view.getUint32(0, true) !== SFZ_BANK_MAGIC || view.getUint32(4, true) !== 1 || length > MAX_INDEX_BYTES || length > reader.size - 12) throw sfzError("prepare", "The stored SFZ instrument could not be read.");
    const metadata = new Uint8Array(length);
    for (let offset = 0; offset < length; offset += SFZ_SAMPLE_RANGE_MAX_BYTES) {
      metadata.set(await reader.readRange(12 + offset, Math.min(SFZ_SAMPLE_RANGE_MAX_BYTES, length - offset)), offset);
    }
    const bank = validateSfzBankIndex(JSON.parse(decoder3.decode(metadata)), reader.size - 12 - length);
    const createSampleReader = (path) => {
      const entry = bank.files.get(normalizeSfzPath(path));
      if (!entry) throw sfzError("prepare", "An instrument sample could not be found.");
      return Object.freeze({
        size: entry.length,
        rangeSource: reader.rangeSource && { ...reader.rangeSource, offset: reader.rangeSource.offset + 12 + length + entry.offset },
        openRangePort: reader.openRangePort,
        revision: `${reader.revision}:${entry.offset}:${entry.length}`,
        async readRange(offset, count) {
          requireSfzSampleRange(offset, count, entry.length);
          return reader.readRange(12 + length + entry.offset + offset, count);
        }
      });
    };
    return { ...bank, size: reader.size, createSampleReader };
  }
  var MAX_INDEX_BYTES, encoder5, decoder3;
  var init_sample_bank_source = __esm({
    "js/sfz/sample-bank-source.js"() {
      init_bank();
      init_sample_reader();
      init_parser();
      MAX_INDEX_BYTES = 8 * 1024 * 1024;
      encoder5 = new TextEncoder();
      decoder3 = new TextDecoder("utf-8", { fatal: true });
    }
  });

  // js/sf2/compiler.js
  function validSource(value, amountSource = false) {
    if (value >>> 10 > 3) return false;
    const index = value & 127;
    if (value & 128) return ![0, 6, 32, 38, 98, 99, 100, 101].includes(index) && index < 120 && !(index >= 33 && index <= 63);
    return [0, 2, 3, 10, 13, 14, 16].includes(index) || index === 127 && !amountSource;
  }
  function compileModulators(records, identities, diagnostics, isDefault = false) {
    const nodes = records.map((record, index) => ({ ...record, index, incoming: [], key: null }));
    for (const node of nodes) {
      const linked = Boolean(node.destination & 32768), target = node.destination & 32767;
      node.valid = validSource(node.source) && validSource(node.amountSource, true) && [0, 2].includes(node.transform) && (linked ? target < nodes.length && (nodes[target].source & 255) === 127 : node.destination >= 0 && node.destination < 60 && !RESERVED.has(node.destination) && !NON_MODULATED.has(node.destination) || isDefault && node.destination === SF2_INITIAL_PITCH);
      if (linked && node.valid) {
        node.target = nodes[target];
        nodes[target].incoming.push(node);
      }
    }
    const queue = nodes.filter((node) => node.valid && !node.target);
    for (let i = 0; i < queue.length; i++) {
      const node = queue[i];
      if ((node.source & 255) === 127 && !node.incoming.some((input) => input.valid)) continue;
      const signature2 = `${node.source}:${node.target ? `m${node.target.key}` : `g${node.destination}`}:${node.amountSource}:${node.transform}`;
      if (!identities.has(signature2)) identities.set(signature2, identities.size);
      node.key = identities.get(signature2);
      for (const input of node.incoming) if (input.valid) queue.push(input);
    }
    const result = /* @__PURE__ */ new Map();
    for (const node of nodes) {
      if (node.key === null) {
        diagnostics.ignoredModulators++;
        continue;
      }
      const { source, destination: destination2, amount, amountSource, transform, key } = node;
      result.set(key, {
        source,
        destination: destination2,
        amount,
        amountSource,
        transform,
        key,
        link: node.target?.key ?? null
      });
    }
    return result;
  }
  function zones(tables, header, prefix, index, identities, diagnostics) {
    const result = [], bags = tables[`${prefix}bag`], generators = tables[`${prefix}gen`], modulators = tables[`${prefix}mod`];
    const terminal = prefix === "p" ? 41 : 53;
    for (let bag = header[index].bag; bag < header[index + 1].bag; bag++) {
      const begin = bags[bag], end = bags[bag + 1], values = /* @__PURE__ */ new Map();
      for (let at = begin.generator; at < end.generator; at++) {
        const gen = generators[at], id = gen.operator, position = at - begin.generator;
        if (id > 60 || RESERVED.has(id) || prefix === "p" && INSTRUMENT_ONLY.has(id) || prefix === "i" && id === 41 || id === 43 && position !== 0 || id === 44 && !(position === 0 || position === 1 && generators[begin.generator].operator === 43)) {
          diagnostics.ignoredGenerators++;
          continue;
        }
        values.set(id, [41, 43, 44, 53].includes(id) ? gen.unsignedAmount : gen.amount);
        if (id === terminal) break;
      }
      const mods = compileModulators(modulators.slice(begin.modulator, end.modulator), identities, diagnostics);
      if (!values.has(terminal) && bag !== header[index].bag) {
        diagnostics.ignoredZones++;
        continue;
      }
      result.push({ generators: values, modulators: mods });
    }
    const global = result[0] && !result[0].generators.has(terminal) ? result.shift() : null;
    return result.map((zone) => ({
      generators: new Map([...global?.generators || [], ...zone.generators]),
      modulators: new Map([...global?.modulators || [], ...zone.modulators])
    }));
  }
  function compileSf2(parsed, { presetIndex = null } = {}) {
    const { tables } = parsed, identities = /* @__PURE__ */ new Map(), diagnostics = { ignoredGenerators: 0, ignoredModulators: 0, ignoredZones: 0, adjustedLoops: 0 };
    const defaultMods = compileModulators(SF2_DEFAULT_MODULATORS, identities, diagnostics, true);
    const instruments = /* @__PURE__ */ new Map(), regions = [], presets = [];
    let routeCount = 0;
    if (presetIndex !== null && (!Number.isInteger(presetIndex) || presetIndex < 0 || presetIndex >= parsed.presets.length)) throw sf2Error("Invalid preset selection");
    for (const preset of parsed.presets) {
      if (presetIndex !== null && preset.index !== presetIndex) continue;
      const firstRegion = regions.length;
      for (const presetZone of zones(tables, tables.phdr, "p", preset.index, identities, diagnostics)) {
        const instrumentId = presetZone.generators.get(41);
        if (instrumentId >= tables.inst.length - 1) throw sf2Error("Invalid instrument reference");
        if (!instruments.has(instrumentId)) instruments.set(instrumentId, zones(tables, tables.inst, "i", instrumentId, identities, diagnostics));
        for (const instrument of instruments.get(instrumentId)) {
          const sampleId = instrument.generators.get(53), sample = tables.shdr[sampleId];
          if (sampleId >= tables.shdr.length - 1) throw sf2Error("Invalid sample reference");
          const keyRange = intersect(instrument.generators.get(43) ?? 32512, presetZone.generators.get(43) ?? 32512);
          const velocityRange = intersect(instrument.generators.get(44) ?? 32512, presetZone.generators.get(44) ?? 32512);
          if (keyRange[0] > keyRange[1] || velocityRange[0] > velocityRange[1]) continue;
          if (keyRange[1] > 127 || velocityRange[1] > 127) throw sf2Error("Invalid MIDI zone range");
          const generators = Float64Array.from(SF2_GENERATOR_DEFAULTS);
          for (const [id, amount] of instrument.generators) generators[id] = amount;
          for (const [id, amount] of presetZone.generators) if (![41, 43, 44].includes(id)) generators[id] += amount;
          const start = sample.start + generators[0] + 32768 * generators[4];
          const end = sample.end + generators[1] + 32768 * generators[12];
          const requestedLoopStart = sample.loopStart + generators[2] + 32768 * generators[45];
          const requestedLoopEnd = sample.loopEnd + generators[3] + 32768 * generators[50];
          let loopStart = Math.max(start, Math.min(end, requestedLoopStart));
          let loopEnd = Math.max(start, Math.min(end, requestedLoopEnd));
          if (generators[54] & 1 && loopEnd <= loopStart) {
            loopStart = Math.max(start, sample.loopStart);
            loopEnd = Math.min(end, sample.loopEnd);
          }
          if (generators[54] & 1 && (loopStart !== requestedLoopStart || loopEnd !== requestedLoopEnd)) diagnostics.adjustedLoops++;
          if (sample.sampleType & 32768) throw sf2Error("The preset requires external ROM samples");
          const sampleType = sample.sampleType & ~16;
          if (![1, 2, 4, 8].includes(sampleType) || sampleType !== 1 && sample.sampleLink >= tables.shdr.length - 1 || start < 0 || end <= start || end > (sample.compressed?.frames ?? parsed.sampleFrames) || sample.sampleRate < 1 || sample.sampleRate > 768e3 || generators[54] & 1 && (loopStart < start || loopEnd > end || loopEnd <= loopStart)) {
            throw sf2Error(`Invalid sample geometry: ${JSON.stringify({ sampleId, start, end, loopStart, loopEnd, modes: generators[54], sample })}`);
          }
          const mods = new Map([...defaultMods, ...instrument.modulators]);
          for (const [key, mod] of presetZone.modulators) mods.set(key, { ...mod, amount: mod.amount + (mods.get(key)?.amount ?? 0) });
          const selected = [...mods.values()], indices = new Map(selected.map((mod, index) => [mod.key, index]));
          routeCount += selected.length;
          if (selected.length > 65536 || routeCount > 1048576) throw sf2Error("Too many compiled SoundFont modulation routes");
          const compiledMods = selected.map(({ key: _key, link, ...mod }) => ({ ...mod, link: link === null ? -1 : indices.get(link) ?? -1 }));
          regions.push({
            presetIndex: preset.index,
            bank: preset.bank,
            program: preset.program,
            sampleId,
            keyRange,
            velocityRange,
            generators,
            modulators: compiledMods,
            sample: {
              ...sample,
              start,
              end,
              loopStart,
              loopEnd,
              originalPitch: sample.originalPitch > 127 ? 60 : sample.originalPitch
            }
          });
          if (regions.length > 65536) throw sf2Error("Too many compiled SoundFont zones");
        }
      }
      presets.push({ ...preset, firstRegion, regionCount: regions.length - firstRegion });
    }
    return { format: "sf2", sourceProfile: `${parsed.format}-${parsed.version.major}.${String(parsed.version.minor).padStart(2, "0")}`, presets, regions, diagnostics };
  }
  var SF2_INITIAL_PITCH, SF2_GENERATOR_DEFAULTS, RESERVED, INSTRUMENT_ONLY, NON_MODULATED, defaults, SF2_DEFAULT_MODULATORS, intersect;
  var init_compiler = __esm({
    "js/sf2/compiler.js"() {
      init_parser2();
      SF2_INITIAL_PITCH = 60;
      SF2_GENERATOR_DEFAULTS = Object.freeze(Array.from({ length: 61 }, (_2, id) => id === 8 ? 13500 : [21, 23, 25, 26, 27, 28, 30, 33, 34, 35, 36, 38].includes(id) ? -12e3 : [46, 47, 58].includes(id) ? -1 : id === 56 ? 100 : [43, 44].includes(id) ? 32512 : 0));
      RESERVED = /* @__PURE__ */ new Set([14, 18, 19, 20, 42, 49, 55, 59, 60]);
      INSTRUMENT_ONLY = /* @__PURE__ */ new Set([0, 1, 2, 3, 4, 12, 45, 46, 47, 50, 53, 54, 57, 58]);
      NON_MODULATED = /* @__PURE__ */ new Set([41, 43, 44, 46, 47, 53, 54, 56, 57, 58]);
      defaults = [
        [1282, 48, 960, 0],
        [258, 8, -2400, 0],
        [13, 6, 50, 0],
        [129, 6, 50, 0],
        [1415, 48, 960, 0],
        [650, 17, 500, 0],
        [1419, 48, 960, 0],
        [219, 16, 200, 0],
        [221, 15, 200, 0],
        [526, SF2_INITIAL_PITCH, 12700, 16]
      ];
      SF2_DEFAULT_MODULATORS = Object.freeze(defaults.map(([source, destination2, amount, amountSource]) => Object.freeze({ source, destination: destination2, amount, amountSource, transform: 0 })));
      intersect = (a, b2) => [Math.max(a & 255, b2 & 255), Math.min(a >>> 8, b2 >>> 8)];
    }
  });

  // js/sf2/sample-reader.js
  function createSf2SampleReader(reader, { start, frames, sampleRate, smplOffset, sm24Offset = null }) {
    if (!reader || !Number.isSafeInteger(reader.size) || typeof reader.readRange !== "function" || !Number.isSafeInteger(start) || start < 0 || !Number.isSafeInteger(frames) || frames < 1 || !Number.isSafeInteger(smplOffset) || smplOffset < 0 || !Number.isInteger(sampleRate) || sampleRate < 1 || sampleRate > 768e3 || sm24Offset !== null && (!Number.isSafeInteger(sm24Offset) || sm24Offset < 0)) throw new RangeError("Invalid SoundFont sample range");
    const dataOffset = smplOffset + start * 2, lowByteOffset = sm24Offset === null ? null : sm24Offset + start;
    const end = dataOffset + frames * 2, lowEnd = lowByteOffset === null ? 0 : lowByteOffset + frames;
    if (!Number.isSafeInteger(end) || end > reader.size || !Number.isSafeInteger(lowEnd) || lowEnd > reader.size) {
      throw new RangeError("SoundFont sample exceeds its source");
    }
    const pcm = Object.freeze({ format: "sf2-pcm", channels: 1, frames, sampleRate, dataOffset, lowByteOffset });
    return Object.freeze({
      size: reader.size,
      pcm,
      rangeSource: reader.rangeSource,
      openRangePort: reader.openRangePort,
      revision: `${reader.revision}:${JSON.stringify(pcm)}`,
      readRange: (offset, length) => reader.readRange(offset, length)
    });
  }
  function createSf3SampleReader(reader, { start, frames, sampleRate, compressed }) {
    const pcm = Object.freeze({
      format: "sf3-vorbis",
      channels: 1,
      ...compressed,
      frames,
      sampleRate,
      firstFrame: start,
      sourceFrames: compressed.frames
    });
    return Object.freeze({
      size: reader.size,
      pcm,
      rangeSource: reader.rangeSource,
      openRangePort: reader.openRangePort,
      revision: `${reader.revision}:${JSON.stringify(pcm)}`,
      readRange: (offset, length) => reader.readRange(offset, length)
    });
  }
  var init_sample_reader2 = __esm({
    "js/sf2/sample-reader.js"() {
    }
  });

  // js/sf2/ogg-vorbis.js
  function checksum(bytes) {
    let crc2 = 0;
    for (let at = 0; at < bytes.length; at++) {
      crc2 ^= (at >= 22 && at < 26 ? 0 : bytes[at]) << 24;
      for (let bit = 0; bit < 8; bit++) crc2 = crc2 & 2147483648 ? crc2 << 1 ^ 79764919 : crc2 << 1;
    }
    return crc2 >>> 0;
  }
  async function page(read, offset, size, serial = null) {
    if (offset < 0 || offset + 27 > size) throw failure2("sample-format");
    const header = await read(offset, 27), view = new DataView(header.buffer, header.byteOffset, header.length);
    if (!signature(header) || header[4] !== 0 || header[5] & ~7 || !header[26] || serial !== null && view.getUint32(14, true) !== serial) throw failure2("sample-format");
    const laces = await read(offset + 27, header[26]);
    const length = 27 + laces.length + laces.reduce((sum, value) => sum + value, 0);
    if (offset + length > size) throw failure2("sample-format");
    const bytes = await read(offset, length);
    if (checksum(bytes) !== view.getUint32(22, true)) throw failure2("sample-format");
    const granule = view.getBigUint64(6, true);
    if (granule !== 0xffffffffffffffffn && granule > BigInt(Number.MAX_SAFE_INTEGER)) throw failure2("sample-format");
    return {
      offset,
      next: offset + length,
      flags: header[5],
      serial: view.getUint32(14, true),
      sequence: view.getUint32(18, true),
      granule: granule === 0xffffffffffffffffn ? -1 : Number(granule),
      laces,
      body: bytes.subarray(27 + laces.length)
    };
  }
  async function findPage(read, offset, size, serial) {
    const bytes = await read(offset, Math.min(MAX_PAGE * 2, size - offset));
    for (let at = 0; at + 27 <= bytes.length; at++) {
      if (!signature(bytes, at)) continue;
      try {
        return await page(read, offset + at, size, serial);
      } catch (error2) {
        if (error2.code !== "sample-format") throw error2;
      }
    }
    return null;
  }
  function packets(current, carry = [], skip = false) {
    const output = [];
    let at = 0, length = carry.reduce((sum, bytes) => sum + bytes.length, 0);
    for (const lace of current.laces) {
      const part = current.body.subarray(at, at + lace);
      at += lace;
      if (!skip) {
        carry.push(part);
        length += lace;
        if (length > MAX_HEADER_BYTES) throw failure2("sample-format");
      }
      if (lace < 255) {
        if (!skip) output.push(join(carry));
        carry = [];
        length = 0;
        skip = false;
      }
    }
    return { output, carry, skip };
  }
  async function readOggVorbisMetadata(read, size) {
    if (!Number.isSafeInteger(size) || size < 58) throw failure2("sample-format");
    const headers = [];
    let offset = 0, serial = null, sequence = 0, carry = [], headerBytes = 0;
    while (headers.length < 3) {
      const current = await page(read, offset, size, serial);
      if (current.sequence !== sequence++ || (offset === 0 ? current.flags !== 2 : Boolean(current.flags & 1) !== Boolean(carry.length))) throw failure2("sample-format");
      serial = current.serial;
      const result = packets(current, carry);
      carry = result.carry;
      for (const packet of result.output) {
        if (headers.length === 3 || !vorbis(packet, [1, 3, 5][headers.length])) throw failure2("sample-format");
        headerBytes += packet.length;
        if (headerBytes > MAX_HEADER_BYTES) throw failure2("sample-format");
        headers.push(packet);
      }
      offset = current.next;
      if (sequence > 1024 || current.flags & 4) throw failure2("sample-format");
    }
    if (carry.length) throw failure2("sample-format");
    const identification = headers[0], info = new DataView(identification.buffer, identification.byteOffset, identification.length);
    if (identification.length !== 30 || info.getUint32(7, true) !== 0 || identification[11] !== 1 || !(identification[29] & 1)) throw failure2("sample-format");
    const sampleRate = info.getUint32(12, true), smallBlock = identification[28] & 15, largeBlock = identification[28] >> 4;
    if (sampleRate < 1 || sampleRate > 768e3 || smallBlock < 6 || largeBlock < smallBlock || largeBlock > 13) throw failure2("sample-format");
    const tail = await read(Math.max(offset, size - MAX_PAGE - 1), size - Math.max(offset, size - MAX_PAGE - 1));
    let final;
    for (let at = 0; at + 27 <= tail.length; at++) {
      if (!signature(tail, at)) continue;
      try {
        const candidate = await page(read, Math.max(offset, size - MAX_PAGE - 1) + at, size, serial);
        if (candidate.flags & 4 && size - candidate.next <= 1 && candidate.granule > 0) {
          final = candidate;
          break;
        }
      } catch (error2) {
        if (error2.code !== "sample-format") throw error2;
      }
    }
    if (!final || final.offset < offset) throw failure2("sample-format");
    const lengths = [2];
    for (const header of headers.slice(0, 2)) {
      let remaining = header.length;
      while (remaining >= 255) {
        lengths.push(255);
        remaining -= 255;
      }
      lengths.push(remaining);
    }
    return {
      format: "sf3-vorbis",
      channels: 1,
      frames: final.granule,
      sampleRate,
      dataOffset: offset,
      endOffset: final.next,
      serial,
      description: join([Uint8Array.from(lengths), ...headers])
    };
  }
  async function decodeOggVorbisFrames(read, size, firstFrame, count, expected) {
    const metadata = await readOggVorbisMetadata(read, size);
    if (metadata.frames !== expected.frames || metadata.sampleRate !== expected.sampleRate) throw failure2("sample-changed");
    if (typeof globalThis.AudioDecoder !== "function" || typeof globalThis.EncodedAudioChunk !== "function") throw failure2("sample-codec-unavailable");
    const config = { codec: "vorbis", sampleRate: metadata.sampleRate, numberOfChannels: 1, description: metadata.description };
    if (!(await AudioDecoder.isConfigSupported(config)).supported) throw failure2("sample-codec-unavailable");
    let anchor = await page(read, metadata.dataOffset, metadata.endOffset, metadata.serial);
    let lower = anchor.offset, upper = metadata.endOffset;
    for (let attempts = 0; attempts < 32 && upper - lower > MAX_PAGE * 2; attempts++) {
      const middle = Math.floor((lower + upper) / 2), candidate = await findPage(read, middle, metadata.endOffset, metadata.serial);
      if (!candidate || candidate.granule >= firstFrame || candidate.flags & 4) upper = middle;
      else {
        anchor = candidate;
        lower = candidate.next;
      }
    }
    while (anchor.next < metadata.endOffset) {
      const next = await page(read, anchor.next, metadata.endOffset, metadata.serial);
      if (next.granule >= firstFrame || next.flags & 4) break;
      anchor = next;
    }
    const output = new Float32Array(count);
    let decoded = [], decodedFrames = 0, decoderError, position = anchor.offset === metadata.dataOffset ? 0 : null;
    const decoder5 = new AudioDecoder({ error(error2) {
      decoderError = error2;
    }, output(audio) {
      try {
        if (audio.numberOfChannels !== 1 || audio.sampleRate !== metadata.sampleRate || decodedFrames + audio.numberOfFrames > 1048576) throw failure2("sample-format");
        const pcm = new Float32Array(audio.numberOfFrames);
        audio.copyTo(pcm, { planeIndex: 0, format: "f32-planar" });
        decoded.push(pcm);
        decodedFrames += pcm.length;
      } catch (error2) {
        decoderError = error2;
      } finally {
        audio.close();
      }
    } });
    let current = anchor, carry = [], skip = Boolean(anchor.flags & 1), copied = 0, timestamp = 0, primer = null;
    try {
      for (let pages = 0; pages < 65536; pages++) {
        if (decoder5.state === "configured") decoder5.reset();
        decoder5.configure(config);
        const result = packets(current, carry, skip);
        carry = result.carry;
        skip = result.skip;
        for (const packet of primer ? [primer, ...result.output] : result.output) {
          if (!packet.length || packet[0] & 1) throw failure2("sample-format");
          decoder5.decode(new EncodedAudioChunk({ type: "key", timestamp: timestamp++, data: packet }));
        }
        await decoder5.flush();
        if (decoderError) throw failure2("sample-format");
        if (result.output.length) primer = result.output[result.output.length - 1];
        if (position === null && current.granule >= 0 && !(current.flags & 4)) position = current.granule - decodedFrames;
        if (position !== null) {
          for (const pcm of decoded) {
            const start = Math.max(firstFrame, position), end = Math.min(firstFrame + count, position + pcm.length, metadata.frames);
            if (end > start) {
              output.set(pcm.subarray(start - position, end - position), start - firstFrame);
              copied += end - start;
            }
            position += pcm.length;
          }
          decoded = [];
          decodedFrames = 0;
          if (copied === count) return output;
        }
        if (current.flags & 4 || current.next >= metadata.endOffset) break;
        const next = await page(read, current.next, metadata.endOffset, metadata.serial);
        if (next.sequence !== current.sequence + 1 || Boolean(next.flags & 1) !== Boolean(carry.length || skip)) throw failure2("sample-format");
        current = next;
      }
      throw failure2("sample-format");
    } finally {
      if (decoder5.state !== "closed") decoder5.close();
    }
  }
  var MAX_PAGE, MAX_HEADER_BYTES, failure2, signature, vorbis, join;
  var init_ogg_vorbis = __esm({
    "js/sf2/ogg-vorbis.js"() {
      MAX_PAGE = 65307;
      MAX_HEADER_BYTES = 256 * 1024;
      failure2 = (code) => Object.assign(new Error(code === "sample-codec-unavailable" ? "This browser cannot play compressed SoundFonts. Use a browser with Vorbis decoding support or choose an SF2 SoundFont." : "This compressed SoundFont could not be read. Choose another SoundFont."), { code });
      signature = (bytes, at = 0) => bytes[at] === 79 && bytes[at + 1] === 103 && bytes[at + 2] === 103 && bytes[at + 3] === 83;
      vorbis = (bytes, type) => bytes[0] === type && String.fromCharCode(...bytes.subarray(1, 7)) === "vorbis";
      join = (parts) => {
        const output = new Uint8Array(parts.reduce((size, bytes) => size + bytes.length, 0));
        let at = 0;
        for (const bytes of parts) {
          output.set(bytes, at);
          at += bytes.length;
        }
        return output;
      };
    }
  });

  // js/sf2/source.js
  async function openSf2Source(reader) {
    const parsed = await parseSf2(reader);
    for (const sample of parsed.tables.shdr.slice(0, -1)) {
      if (!(sample.sampleType & 16)) {
        if (parsed.sm24Offset !== null && sample.end > parsed.sm24Bytes) throw sf2Error("Incomplete PCM low-byte pool");
        continue;
      }
      if (parsed.version.major !== 3 || sample.start >= sample.end || sample.end > parsed.smplBytes) throw sf2Error("Invalid compressed sample bounds");
      const dataOffset = parsed.smplOffset + sample.start, dataBytes = Math.min(sample.end + 1, parsed.smplBytes) - sample.start;
      const metadata = await readOggVorbisMetadata((offset, length) => reader.readRange(dataOffset + offset, length), dataBytes);
      if (metadata.sampleRate !== sample.sampleRate) throw sf2Error("Compressed sample rate differs from SHDR");
      sample.compressed = { dataOffset, dataBytes: metadata.endOffset, frames: metadata.frames };
      sample.start = 0;
      sample.end = metadata.frames;
    }
    const compiled = compileSf2(parsed), views = /* @__PURE__ */ new Map();
    for (const region of compiled.regions) {
      const { sampleId, sample } = region;
      const view = views.get(sampleId);
      if (view) {
        view.start = Math.min(view.start, sample.start);
        view.end = Math.max(view.end, sample.end);
      } else views.set(sampleId, {
        sampleId,
        start: sample.start,
        end: sample.end,
        sampleRate: sample.sampleRate,
        ...sample.compressed && { compressed: sample.compressed }
      });
    }
    const samples = [...views.values()].sort((a, b2) => a.sampleId - b2.sampleId).map((view) => Object.freeze({ ...view, path: `sample:${String(view.sampleId).padStart(5, "0")}`, frames: view.end - view.start }));
    const byPath = new Map(samples.map((sample) => [sample.path, sample]));
    return { parsed, compiled, samples, sourceBytes: reader.size, createSampleReader(path) {
      const sample = byPath.get(path);
      if (!sample) throw new RangeError("Unknown SoundFont sample");
      return sample.compressed ? createSf3SampleReader(reader, sample) : createSf2SampleReader(reader, { ...sample, smplOffset: parsed.smplOffset, sm24Offset: parsed.sm24Offset });
    } };
  }
  var init_source2 = __esm({
    "js/sf2/source.js"() {
      init_parser2();
      init_compiler();
      init_sample_reader2();
      init_ogg_vorbis();
    }
  });

  // js/sfz/md5.js
  var rotations, constants, SfzMd5;
  var init_md5 = __esm({
    "js/sfz/md5.js"() {
      rotations = [[7, 12, 17, 22], [5, 9, 14, 20], [4, 11, 16, 23], [6, 10, 15, 21]];
      constants = Uint32Array.from({ length: 64 }, (_2, index) => Math.floor(4294967296 * Math.abs(Math.sin(index + 1))));
      SfzMd5 = class {
        constructor() {
          this.state = new Uint32Array([1732584193, 4023233417, 2562383102, 271733878]);
          this.pending = new Uint8Array(64);
          this.pendingView = new DataView(this.pending.buffer);
          this.used = 0;
          this.bytes = 0;
          this.result = null;
        }
        update(bytes) {
          if (this.result !== null || !(bytes instanceof Uint8Array) || !Number.isSafeInteger(this.bytes + bytes.length)) throw new Error("Invalid sample fingerprint input.");
          this.bytes += bytes.length;
          let offset = 0;
          if (this.used) {
            const count = Math.min(64 - this.used, bytes.length);
            this.pending.set(bytes.subarray(0, count), this.used);
            this.used += count;
            offset += count;
            if (this.used === 64) {
              this.block(this.pendingView, 0);
              this.used = 0;
            }
          }
          const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
          while (offset + 64 <= bytes.length) {
            this.block(view, offset);
            offset += 64;
          }
          if (offset < bytes.length) {
            this.pending.set(bytes.subarray(offset));
            this.used = bytes.length - offset;
          }
          return this;
        }
        block(words, offset) {
          let [a, b2, c, d] = this.state;
          for (let index = 0; index < 64; index++) {
            const round = index >>> 4;
            const mix = round === 0 ? b2 & c | ~b2 & d : round === 1 ? b2 & d | c & ~d : round === 2 ? b2 ^ c ^ d : c ^ (b2 | ~d);
            const word = round === 0 ? index : round === 1 ? 5 * index + 1 & 15 : round === 2 ? 3 * index + 5 & 15 : 7 * index & 15;
            const sum = a + mix + constants[index] + words.getUint32(offset + word * 4, true) | 0;
            const shift = rotations[round][index & 3];
            const next = b2 + (sum << shift | sum >>> 32 - shift) | 0;
            a = d;
            d = c;
            c = b2;
            b2 = next;
          }
          this.state[0] += a;
          this.state[1] += b2;
          this.state[2] += c;
          this.state[3] += d;
        }
        digest() {
          if (this.result !== null) return this.result;
          const length = this.bytes;
          const padding = new Uint8Array(this.used < 56 ? 64 - this.used : 128 - this.used);
          padding[0] = 128;
          const view = new DataView(padding.buffer);
          view.setUint32(padding.length - 8, length % 536870912 * 8, true);
          view.setUint32(padding.length - 4, Math.floor(length / 536870912), true);
          this.update(padding);
          this.result = Array.from(this.state, (word) => Array.from({ length: 4 }, (_2, byte) => (word >>> 8 * byte & 255).toString(16).padStart(2, "0")).join("")).join("");
          return this.result;
        }
      };
    }
  });

  // js/sfz/sample-integrity.js
  function normalizeSfzMd5(value) {
    if (typeof value !== "string" || !/^[a-f0-9]{32}$/i.test(value)) {
      throw sfzError("sample-integrity", "The instrument contains an invalid sample fingerprint. Check the instrument definition.");
    }
    return value.toLowerCase();
  }
  async function hashSfzSample(reader, { isCurrent, onProgress } = {}) {
    if (!reader || !Number.isSafeInteger(reader.size) || reader.size < 0 || typeof reader.readRange !== "function") {
      throw sfzError("prepare", "An instrument sample could not be opened. Reload the instrument.");
    }
    const hash = new SfzMd5();
    checkCurrent(isCurrent);
    for (let offset = 0; offset < reader.size; offset += SFZ_MD5_CHUNK_BYTES) {
      checkCurrent(isCurrent);
      const length = Math.min(SFZ_MD5_CHUNK_BYTES, reader.size - offset);
      const bytes = await reader.readRange(offset, length);
      checkCurrent(isCurrent);
      if (!(bytes instanceof Uint8Array) || bytes.length !== length) {
        throw sfzError("source-changed", "An instrument sample changed or could not be read. Reload the instrument.");
      }
      hash.update(bytes);
      onProgress?.({ completedBytes: offset + length, totalBytes: reader.size });
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
    checkCurrent(isCurrent);
    if (!reader.size) onProgress?.({ completedBytes: 0, totalBytes: 0 });
    return hash.digest();
  }
  function createSfzSampleIntegrity({
    openReader,
    candidatePaths = [],
    isCurrent,
    onProgress,
    onDiagnostic = (detail) => console.warn("SFZ sample fingerprint:", detail),
    maxLookupBytes = Number.MAX_SAFE_INTEGER,
    maxLookupFiles = Number.MAX_SAFE_INTEGER
  } = {}) {
    if (typeof openReader !== "function" || !Number.isSafeInteger(maxLookupBytes) || maxLookupBytes < 0 || !Number.isSafeInteger(maxLookupFiles) || maxLookupFiles < 0) throw new Error("Invalid sample integrity source.");
    const cache = /* @__PURE__ */ new Map();
    let lookupBytes = 0, lookupFiles = 0;
    const limit = () => sfzError(
      "sample-lookup-limit",
      "The matching instrument sample was not found within the search limit. Select a smaller instrument folder or restore the original sample name."
    );
    const fingerprint = async (path, reader, lookup) => {
      const prior = cache.get(path);
      if (prior && prior.revision === reader.revision && prior.size === reader.size) {
        await reader.readRange(0, 0);
        checkCurrent(isCurrent);
        return prior.digest;
      }
      if (lookup) {
        if (++lookupFiles > maxLookupFiles || reader.size > maxLookupBytes - lookupBytes) throw limit();
        lookupBytes += reader.size;
      }
      const digest = await hashSfzSample(reader, {
        isCurrent,
        onProgress: (progress) => onProgress?.({ ...progress, path, searching: lookup })
      });
      if (typeof reader.revision === "string" && reader.revision) {
        if (cache.size >= 4096) cache.delete(cache.keys().next().value);
        cache.set(path, { revision: reader.revision, size: reader.size, digest });
      }
      return digest;
    };
    return Object.freeze({ async resolve(path, declaration) {
      const expected = normalizeSfzMd5(declaration);
      checkCurrent(isCurrent);
      const named = await openReader(path);
      let actual = null;
      if (named) {
        actual = await fingerprint(path, named, false);
        if (actual === expected) return path;
      }
      const paths = typeof candidatePaths === "function" ? await candidatePaths(path) : candidatePaths;
      const visited = /* @__PURE__ */ new Set([path]);
      for (const candidate of paths) {
        checkCurrent(isCurrent);
        if (visited.has(candidate)) continue;
        if (visited.size > maxLookupFiles) throw limit();
        visited.add(candidate);
        const reader = await openReader(candidate);
        if (!reader) continue;
        if (await fingerprint(candidate, reader, true) === expected) {
          onDiagnostic?.({ code: "sample-renamed", path, resolvedPath: candidate, md5: expected });
          return candidate;
        }
      }
      onDiagnostic?.({ code: "sample-integrity", path, expected, actual });
      throw sfzError("sample-integrity", named ? "An instrument sample does not match its fingerprint. Restore the original sample or select the complete instrument folder." : "An instrument sample could not be found by name or fingerprint. Select the complete instrument folder.");
    } });
  }
  var SFZ_MD5_CHUNK_BYTES, checkCurrent;
  var init_sample_integrity = __esm({
    "js/sfz/sample-integrity.js"() {
      init_md5();
      init_parser();
      SFZ_MD5_CHUNK_BYTES = 256 * 1024;
      checkCurrent = (isCurrent) => {
        if (isCurrent?.() === false) throw sfzError("cancelled", "Instrument sample checking was cancelled.");
      };
    }
  });

  // js/sfz/sample-metadata.js
  async function readSfzWaveLoop(reader, maxBytes) {
    if (reader.size < 12) return null;
    let consumed = 0;
    const read = async (offset, length) => {
      consumed += length;
      if (consumed > maxBytes) throw sfzError("too-large", "The sample metadata exceeds the instrument size limit.");
      const bytes = await reader.readRange(offset, length);
      if (!(bytes instanceof Uint8Array) || bytes.length !== length) throw sfzError("prepare", "The sample metadata could not be read.");
      return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    };
    const header = await read(0, 12);
    if (header.getUint32(0, false) !== 1380533830 || header.getUint32(8, false) !== 1463899717) return null;
    const end = header.getUint32(4, true) + 8;
    if (end > reader.size || end < 12) throw sfzError("prepare", "The WAVE sample has invalid metadata.");
    for (let offset = 12; offset + 8 <= end; ) {
      const chunk = await read(offset, 8), size = chunk.getUint32(4, true), data = offset + 8;
      if (data + size > end) throw sfzError("prepare", "The WAVE sample has an incomplete metadata chunk.");
      if (chunk.getUint32(0, false) === 1936552044 && size >= 36) {
        const sampler = await read(data, Math.min(60, size));
        if (sampler.getUint32(28, true) > 0) {
          if (size < 60) throw sfzError("prepare", "The WAVE sample has an incomplete loop definition.");
          const type = sampler.getUint32(40, true);
          if (type > 2) throw sfzError("prepare", "The WAVE sample uses an unsupported loop direction.");
          return {
            start: sampler.getUint32(44, true),
            end: sampler.getUint32(48, true),
            type: ["forward", "alternate", "backward"][type],
            plays: sampler.getUint32(56, true)
          };
        }
      }
      offset = data + size + (size & 1);
    }
    return null;
  }
  function applySfzLoopMetadata(parsed, loops) {
    if (parsed.sourceProfile || ![...loops.values()].some(Boolean)) return parsed;
    const correction = parsed.headers?.filter((header) => header.name === "control").reduce((value, header) => header.opcodes.loop_end_offset === void 0 ? value : Number(header.opcodes.loop_end_offset), 0) ?? 0;
    const regions = parsed.regions.map((region) => {
      const loop = loops.get(region.sample);
      if (!loop) return region;
      const opcodes = { ...region.opcodes }, result = { ...region, opcodes };
      if (opcodes.loop_start === void 0) result.loop_start = loop.start + correction;
      if (opcodes.loop_end === void 0) result.loop_end = loop.end + correction;
      if (opcodes.loop_mode === void 0) result.loop_mode = Number(opcodes.count) > 0 ? 1 : 2;
      if (result.loop_mode >= 2 && opcodes.loop_count === void 0 && loop.plays > 0) {
        result.loop_count = loop.plays - 1;
        opcodes.loop_count = String(result.loop_count);
      }
      if (result.loop_mode >= 2 && opcodes.loop_type === void 0 && loop.type !== "forward") opcodes.loop_type = loop.type;
      return result;
    });
    return { ...parsed, regions, modulation: compileSfzModulation(regions, parsed.headers) };
  }
  async function prepareSfzLoopMetadata(parsed, createReader, maxBytes) {
    if (parsed.sourceProfile) return parsed;
    const loops = /* @__PURE__ */ new Map();
    for (const path of new Set(parsed.regions.map((region) => region.sample))) {
      if (!isSfzGenerator(path)) loops.set(path, await readSfzWaveLoop(await createReader(path), maxBytes));
    }
    return applySfzLoopMetadata(parsed, loops);
  }
  var init_sample_metadata = __esm({
    "js/sfz/sample-metadata.js"() {
      init_parser();
      init_modulation();
      init_generators();
    }
  });

  // js/midi/smf-scheduler.js
  function midiTransportPoints(timeline) {
    if (!timeline?.tempoMap?.length || !timeline?.timeSignatures?.length) return [];
    const points = [];
    let tempoIndex = 0, meterIndex = 0, tempo, meter;
    while (tempoIndex < timeline.tempoMap.length || meterIndex < timeline.timeSignatures.length) {
      const seconds2 = Math.min(
        timeline.tempoMap[tempoIndex]?.seconds ?? Infinity,
        timeline.timeSignatures[meterIndex]?.seconds ?? Infinity
      );
      while (timeline.tempoMap[tempoIndex]?.seconds === seconds2) tempo = timeline.tempoMap[tempoIndex++];
      while (timeline.timeSignatures[meterIndex]?.seconds === seconds2) meter = timeline.timeSignatures[meterIndex++];
      const bpm = 6e7 / tempo.microsecondsPerQuarter;
      points.push({
        seconds: seconds2,
        ppq: tempo.quarter + (seconds2 - tempo.seconds) * bpm / 60,
        barStartPpq: meter.quarter,
        bpm,
        numerator: meter.numerator,
        denominator: meter.denominator
      });
    }
    return points;
  }
  function midiMinimumPhysicalBpm(timeline) {
    const points = midiTransportPoints(timeline);
    return points.length ? points.reduce((minimum, point) => Math.min(minimum, point.bpm), Infinity) * 0.25 : 0;
  }
  var init_smf_scheduler = __esm({
    "js/midi/smf-scheduler.js"() {
    }
  });

  // js/audio/plugin-execution-capabilities.js
  function getPluginExecutionChannelMode(channel, outputChannelCount) {
    if (!Number.isInteger(outputChannelCount) || outputChannelCount < 1) return null;
    let mode;
    let firstChannel;
    let requiredChannels;
    switch (channel) {
      case "A":
        mode = "all";
        firstChannel = 0;
        requiredChannels = outputChannelCount;
        break;
      case "L":
        mode = "single";
        firstChannel = 0;
        requiredChannels = 1;
        break;
      case "R":
        mode = "single";
        firstChannel = 1;
        requiredChannels = 1;
        break;
      case null:
      case void 0:
        mode = outputChannelCount === 1 ? "mono" : "stereo-pair";
        firstChannel = 0;
        requiredChannels = outputChannelCount === 1 ? 1 : 2;
        break;
      case "34":
      case "56":
      case "78":
        mode = "stereo-pair";
        firstChannel = Number(channel[0]) - 1;
        requiredChannels = 2;
        break;
      case "910":
      case "1112":
      case "1314":
      case "1516":
        mode = "stereo-pair";
        firstChannel = Number(channel.slice(0, channel.length / 2)) - 1;
        requiredChannels = 2;
        break;
      default: {
        const parsedChannel = Number.parseInt(channel, 10);
        if (!Number.isInteger(parsedChannel) || parsedChannel <= 0) return null;
        mode = "single";
        firstChannel = parsedChannel - 1;
        requiredChannels = 1;
        break;
      }
    }
    return firstChannel + requiredChannels <= outputChannelCount ? mode : null;
  }
  var STANDARD_DSP_SAMPLE_RATES, STANDARD_WASM_EXECUTION_CAPABILITIES, UNBOUNDED_WASM_EXECUTION_CAPABILITIES;
  var init_plugin_execution_capabilities = __esm({
    "js/audio/plugin-execution-capabilities.js"() {
      STANDARD_DSP_SAMPLE_RATES = Object.freeze([
        44100,
        48e3,
        88200,
        96e3,
        176400,
        192e3
      ]);
      STANDARD_WASM_EXECUTION_CAPABILITIES = Object.freeze({
        requiresWasm: true,
        supportedSampleRates: STANDARD_DSP_SAMPLE_RATES
      });
      UNBOUNDED_WASM_EXECUTION_CAPABILITIES = Object.freeze({
        requiresWasm: true
      });
    }
  });

  // js/sfz/preparation-context.js
  function sfzPluginPreparationContext(plugin, { outputChannelCount, ...context }) {
    const mode = getPluginExecutionChannelMode(plugin.channel, outputChannelCount);
    if (!mode) throw sfzError("prepare", "The instrument channel selection is unavailable in these audio settings.");
    return sfzPreparationContext({
      ...context,
      processingChannels: mode === "all" ? outputChannelCount : mode === "single" || mode === "mono" ? 1 : 2
    });
  }
  function sfzPreparationContext({
    sampleRate,
    processingChannels,
    maxFrames,
    timeline = null,
    minimumPhysicalBpm = null,
    playerKind = 0
  } = {}) {
    if (!Number.isFinite(sampleRate) || sampleRate <= 0 || !Number.isInteger(processingChannels) || processingChannels < 1 || processingChannels > 16 || !Number.isInteger(maxFrames) || maxFrames < 1 || maxFrames > 4294967295 || playerKind !== 0 && playerKind !== 1) {
      throw sfzError("prepare", "The instrument audio configuration is unavailable. Try again after changing audio settings.");
    }
    if (minimumPhysicalBpm === null) {
      minimumPhysicalBpm = midiMinimumPhysicalBpm(timeline);
    }
    if (!Number.isFinite(minimumPhysicalBpm) || minimumPhysicalBpm < 0) {
      throw sfzError("prepare", "The instrument tempo configuration could not be prepared.");
    }
    return Object.freeze({ sampleRate, processingChannels, maxFrames, minimumPhysicalBpm, playerKind });
  }
  function sameSfzPreparationGeometry(left, right) {
    return !!left && !!right && left.sampleRate === right.sampleRate && left.processingChannels === right.processingChannels && left.maxFrames === right.maxFrames && left.playerKind === right.playerKind;
  }
  function sfzPreparationContextKey(context) {
    const value = sfzPreparationContext(context);
    return [value.sampleRate, value.processingChannels, value.maxFrames, value.minimumPhysicalBpm, value.playerKind].join(":");
  }
  async function materializeSfzAsset(descriptor, context, maxBytes, estimateEffectBytes) {
    if (typeof estimateEffectBytes !== "function") throw sfzError("prepare", "Instrument effect preparation is unavailable. Reload the app and try again.");
    const prepared = sfzPreparationContext(context);
    const nativeBytes = await estimateEffectBytes(descriptor.payload, prepared, descriptor.formatTag ?? 1);
    const footprintBytes = descriptor.payload.byteLength + nativeBytes;
    if (!Number.isSafeInteger(nativeBytes) || nativeBytes < 0 || !Number.isSafeInteger(footprintBytes) || footprintBytes > maxBytes) {
      throw sfzError("too-large", "The instrument needs more memory for these audio settings. Increase the SoundFont size limit or choose another instrument.");
    }
    const covered = sameSfzPreparationGeometry(descriptor.preparationContext, prepared) && nativeBytes <= (descriptor.nativePreparationBytes ?? -1) && descriptor.footprintBytes <= maxBytes;
    if (covered) return descriptor;
    return {
      ...descriptor,
      processingChannels: prepared.processingChannels,
      footprintBytes,
      preparationContext: prepared,
      nativePreparationBytes: nativeBytes
    };
  }
  async function prepareSfzAssetForContext(descriptor, context, maxBytes, estimateEffectBytes) {
    return descriptor.materializeForContext ? descriptor.materializeForContext(context, maxBytes, estimateEffectBytes) : materializeSfzAsset(descriptor, context, maxBytes, estimateEffectBytes);
  }
  var init_preparation_context = __esm({
    "js/sfz/preparation-context.js"() {
      init_smf_scheduler();
      init_parser();
      init_plugin_execution_capabilities();
    }
  });

  // js/sfz/service.js
  function fileMap(files) {
    const entries = Array.from(files || []);
    const rootNames = entries.filter((file) => !pathsByFile.has(file)).map((file) => file.webkitRelativePath?.split("/")[0]);
    const stripRoot = rootNames.length > 0 && rootNames.every((name) => name && name === rootNames[0]);
    const result = /* @__PURE__ */ new Map();
    for (const file of entries) {
      let path = pathsByFile.get(file) || file.webkitRelativePath || file.name;
      if (!pathsByFile.has(file) && stripRoot) path = path.slice(path.indexOf("/") + 1);
      path = normalizeSfzPath(path);
      if (!path || result.has(path)) throw sfzError("prepare", "The SFZ folder contains duplicate file paths.");
      result.set(path, file);
    }
    if ([...result.keys()].filter((path) => /\.(sf2|sf3|sfz)$/i.test(path)).length > 1e4) {
      throw sfzError("prepare", "The SFZ folder contains too many instruments.");
    }
    return result;
  }
  function listSfzFolderFiles(files) {
    return [...fileMap(files).keys()].filter((path) => /\.(sf2|sf3|sfz)$/i.test(path)).sort();
  }
  function sampleIntegrityResolver(openReader, candidatePaths, maxBytes, onDiagnostic, isCurrent, onProgress) {
    let embedded = /* @__PURE__ */ new Map();
    let integrity;
    return (path, md5, embeddedSamples) => {
      embedded = embeddedSamples;
      if (!integrity) {
        const candidates = [.../* @__PURE__ */ new Set([...embedded.keys(), ...candidatePaths()])];
        integrity = createSfzSampleIntegrity({
          maxLookupBytes: maxBytes,
          maxLookupFiles: candidates.length,
          onDiagnostic,
          isCurrent,
          onProgress,
          candidatePaths: candidates,
          openReader: (path2) => embedded.has(path2) ? createSfzMemorySampleReader(embedded.get(path2)) : openReader(path2)
        });
      }
      return integrity.resolve(path, md5);
    };
  }
  async function parseBankFiles(selectedPath, files, onDiagnostic, maxBytes, options = {}) {
    const readText = async (path) => {
      const bytes = files.get(path);
      return bytes ? decodeSfzText(bytes) : null;
    };
    const { defines } = await readSfzBankDefines(
      selectedPath,
      [...files.keys()].filter((path) => /\.bank\.xml$/i.test(path)),
      readText
    );
    return parseSfz({
      selectedPath,
      maxBytes,
      defines,
      readText,
      resolveSample: sampleIntegrityResolver(
        (path) => files.has(path) ? createSfzMemorySampleReader(files.get(path)) : null,
        () => files.keys(),
        maxBytes,
        onDiagnostic,
        options.isCurrent,
        options.onSourceProgress
      ),
      hasSample: (path) => files.has(path),
      onDiagnostic
    });
  }
  async function prepareBank(bytes, decode, onDiagnostic, maxBytes, options) {
    const bank = decodeSfzBank(bytes, { maxBytes });
    const parsed = await parseBankFiles(bank.selectedPath, bank.files, onDiagnostic, maxBytes, options);
    parsed.warnings = mergeSfzWarnings(bank.warnings, parsed.warnings);
    return {
      ...await prepareSfzSamples(parsed, (path) => bank.files.get(path), decode, maxBytes, onDiagnostic, options),
      sourceBytes: bytes.byteLength,
      name: bank.selectedPath.split("/").pop()
    };
  }
  async function prepareBankSource(id, file, { decode, prepareStreamedBank, prepareSoundFontBank: prepareSoundFontBank2, maxBytes, onDiagnostic, cacheBackend, isCurrent, onSourceProgress, onPreparationProgress, preparationContext, estimateEffectBytes }) {
    const source = await openSfzBankSource(file), definitions2 = /* @__PURE__ */ new Map();
    if (/\.sf[23]$/i.test(source.selectedPath)) {
      if (typeof prepareSoundFontBank2 !== "function") throw sfzError("prepare", "SoundFont playback is unavailable. Reload the app and try again.");
      const sf2 = await openSf2Source(source.createSampleReader(source.selectedPath));
      return {
        ...await prepareSoundFontBank2({
          id,
          source: sf2,
          maxBytes,
          onDiagnostic,
          cacheBackend,
          onProgress: onPreparationProgress,
          preparationContext,
          estimateEffectBytes
        }),
        name: source.selectedPath.split("/").pop(),
        format: sf2.parsed.format,
        presets: sf2.compiled.presets
      };
    }
    let definitionBytes = 0;
    const read = async (path) => {
      const reader = source.createSampleReader(path);
      if (reader.size > maxBytes) throw sfzError("too-large", "An SFZ source file exceeds the memory limit.");
      const bytes = new Uint8Array(reader.size);
      for (let offset = 0; offset < bytes.length; offset += SFZ_SAMPLE_RANGE_MAX_BYTES)
        bytes.set(await reader.readRange(offset, Math.min(SFZ_SAMPLE_RANGE_MAX_BYTES, bytes.length - offset)), offset);
      return bytes;
    };
    const readText = async (path) => {
      if (!source.files.has(path)) return null;
      if (definitions2.has(path)) return definitions2.get(path);
      definitionBytes += source.files.get(path).length;
      if (definitionBytes > maxBytes) throw sfzError("too-large", "The SFZ definitions exceed the memory limit.");
      const value = decodeSfzText(await read(path));
      definitions2.set(path, value);
      return value;
    };
    const { defines } = await readSfzBankDefines(
      source.selectedPath,
      [...source.files.keys()].filter((path) => /\.bank\.xml$/i.test(path)),
      readText
    );
    const parsed = await parseSfz({
      selectedPath: source.selectedPath,
      maxBytes,
      defines,
      readText,
      resolveSample: sampleIntegrityResolver(
        (path) => source.files.has(path) ? source.createSampleReader(path) : null,
        () => source.files.keys(),
        maxBytes,
        onDiagnostic,
        isCurrent,
        onSourceProgress
      ),
      hasSample: (path) => source.files.has(path),
      onDiagnostic
    });
    const createSampleReader = (path) => parsed.embeddedSamples.has(path) ? createSfzMemorySampleReader(parsed.embeddedSamples.get(path)) : source.createSampleReader(path);
    parsed.warnings = mergeSfzWarnings(source.warnings, parsed.warnings);
    const metadata = /* @__PURE__ */ new Map();
    for (const path of [.../* @__PURE__ */ new Set([...parsed.regions.map((region) => region.sample), ...effectSamplePaths(parsed.effects)])].sort()) {
      if (isSfzGenerator(path)) metadata.set(path, sfzGeneratorMetadata(path));
      else {
        const reader = await createSampleReader(path);
        metadata.set(path, {
          size: reader.size,
          revision: reader.revision,
          ...await readSfzAudioHeader(reader.readRange, reader.size)
        });
      }
    }
    let streamed = typeof prepareStreamedBank === "function" && sfzRequiresSampleStreaming(parsed.regions);
    if (!streamed) try {
      selectSfzRegionsForBudget(parsed.regions, metadata, maxBytes, definitionBytes);
    } catch (error2) {
      if (error2?.code !== "too-large" || typeof prepareStreamedBank !== "function") throw error2;
      streamed = true;
    }
    let prepared;
    if (!streamed) try {
      prepared = await prepareSfzSamples(
        parsed,
        read,
        decode,
        maxBytes,
        onDiagnostic,
        { preparationContext, estimateEffectBytes, onProgress: onPreparationProgress }
      );
    } catch (error2) {
      if (error2?.code !== "too-large" || typeof prepareStreamedBank !== "function") throw error2;
      streamed = true;
    }
    if (streamed) prepared = await prepareStreamedBank({
      id,
      parsed,
      metadata,
      maxBytes,
      definitionBytes,
      createSampleReader,
      onDiagnostic,
      cacheBackend,
      onProgress: onPreparationProgress,
      preparationContext,
      estimateEffectBytes
    });
    return {
      ...prepared,
      sourceBytes: file.size,
      presentation: prepared.presentation ?? await prepareSfzPresentation(parsed, read),
      name: source.selectedPath.split("/").pop()
    };
  }
  function mergeSfzWarnings(...groups) {
    const counts = /* @__PURE__ */ new Map();
    for (const group of groups) for (const { code, count } of group || []) {
      counts.set(code, Math.max(counts.get(code) || 0, count));
    }
    return [...counts].map(([code, count]) => ({ code, count })).sort((a, b2) => a.code < b2.code ? -1 : a.code > b2.code ? 1 : 0);
  }
  async function prepareSfzSamples(parsed, readSample, decode, maxBytes, onDiagnostic, { preparationContext = null, estimateEffectBytes, onProgress } = {}) {
    const script = parsed.script ? await compileSfzScriptAsync(parsed.script.source) : null;
    if (typeof decode !== "function" && parsed.regions.some((region) => !isSfzGenerator(region.sample))) {
      throw sfzError("prepare", "SFZ audio decoding is unavailable.");
    }
    const samples = /* @__PURE__ */ new Map(), loops = /* @__PURE__ */ new Map();
    let decodedBytes = 0;
    const paths = [.../* @__PURE__ */ new Set([...parsed.regions.map((region) => region.sample), ...effectSamplePaths(parsed.effects)])].sort();
    for (const path of paths) {
      if (isSfzGenerator(path)) {
        const pcm2 = createSfzGeneratorSample(path);
        decodedBytes += pcm2.channels[0].byteLength;
        if (decodedBytes > maxBytes) throw sfzError("too-large", "The SFZ samples are too large to load.");
        samples.set(path, pcm2);
        onProgress?.({ phase: "metadata", completedCount: samples.size, totalCount: paths.length });
        continue;
      }
      const bytes = parsed.embeddedSamples?.get(path) ?? await readSample(path);
      const header = parseIrAudioHeader(bytes);
      if (header.channels > 2) throw sfzError("prepare", "SFZ samples must contain mono or stereo audio.");
      if (header.frames && decodedBytes + header.frames * header.channels * 4 > maxBytes) {
        throw sfzError("too-large", "The SFZ samples are too large to load.");
      }
      loops.set(path, await readSfzWaveLoop({
        size: bytes.length,
        readRange: async (offset, length) => bytes.subarray(offset, offset + length)
      }, maxBytes));
      const pcm = await decode(bytes.slice().buffer, header?.sampleRate ?? null);
      decodedBytes += (pcm?.channels?.length ?? 0) * (pcm?.channels?.[0]?.length ?? 0) * 4;
      if (decodedBytes > maxBytes) throw sfzError("too-large", "The SFZ samples are too large to load.");
      samples.set(path, pcm);
      onProgress?.({ phase: "metadata", completedCount: samples.size, totalCount: paths.length });
    }
    const recovered = [];
    parsed = applySfzLoopMetadata(parsed, loops);
    const oscillators = await prepareSfzOscillatorSources(parsed, async (path) => samples.get(path), maxBytes, { residentBytes: decodedBytes });
    parsed = oscillators.parsed;
    for (const [path, pcm] of oscillators.samples) samples.set(path, pcm);
    let descriptor = packSfzAsset(parsed.regions, samples, {
      maxBytes,
      script,
      modulation: parsed.modulation,
      effects: parsed.effects,
      onDiagnostic: onDiagnostic ?? void 0,
      onWarning: (warning) => {
        if (warning.code === "invalid-regions") warning = {
          ...warning,
          count: warning.count + (parsed.warnings?.find((item) => item.code === warning.code)?.count || 0)
        };
        recovered.push(warning);
        console.warn("SFZ load warnings:", warning);
      }
    });
    if (preparationContext) descriptor = await materializeSfzAsset(descriptor, preparationContext, maxBytes, estimateEffectBytes);
    descriptor.materializeForContext = function(context, budget = maxBytes, estimate = estimateEffectBytes) {
      return materializeSfzAsset(this, context, budget, estimate);
    };
    descriptor.unsupportedOpcodes = parsed.unsupportedOpcodes || [];
    descriptor.incomplete = Boolean(parsed.diagnostics?.missingSamples?.length || parsed.diagnostics?.invalidRegions?.length || recovered.some((item) => item.code === "invalid-regions"));
    const warnings = mergeSfzWarnings(parsed.warnings, recovered);
    const regionCount = new DataView(descriptor.payload, 32, 32).getUint32(8, true);
    return {
      descriptor,
      sampleCount: samples.size,
      regionCount,
      presentation: await prepareSfzPresentation(parsed, readSample),
      ...warnings.length ? { warnings } : {}
    };
  }
  async function prepareSfzPresentation(parsed, readFile) {
    const presentation = parsed.presentation;
    if (!presentation) return null;
    if (!presentation.image) return presentation;
    const bytes = await readFile(presentation.image);
    if (!(bytes instanceof Uint8Array) || !bytes.length) throw sfzError("prepare", "The instrument image could not be found. Select its complete folder and try again.");
    const extension = presentation.image.split(".").pop().toLowerCase();
    const type = {
      bmp: "image/bmp",
      png: "image/png",
      jpg: "image/jpeg",
      jpeg: "image/jpeg",
      gif: "image/gif",
      webp: "image/webp",
      svg: "image/svg+xml"
    }[extension] || "application/octet-stream";
    return { ...presentation, imageBlob: new Blob([bytes], { type }) };
  }
  function selectSfzRegionsForBudget(regions, metadata, maxBytes, definitionBytes = 0) {
    const fits = (candidate) => {
      const paths = /* @__PURE__ */ new Set([...candidate.map((region) => region.sample), ...metadata.keys()]);
      let rawBytes = definitionBytes;
      let decodedBytes = 0;
      for (const path of paths) {
        const info = metadata.get(path);
        if (!info) return false;
        rawBytes += info.size;
        decodedBytes += (info.frames || 0) * (info.channels || 0) * 4;
      }
      const groups = new Set(candidate.map((region) => region.seqGroup)).size;
      const indexEntries = candidate.reduce((sum, region) => sum + region.hikey - region.lokey + 1, 0);
      const footprint = 32 + 4 * SFZ_TABLE_HEADER_WORDS + 4 * SFZ_REGION_FIELDS.length * candidate.length + decodedBytes + 4 * (129 + 2 * groups + indexEntries);
      return rawBytes <= maxBytes && footprint <= maxBytes;
    };
    if (fits(regions)) return { regions, reduced: false };
    throw sfzError("too-large", "The complete SFZ instrument exceeds the memory limit.");
  }
  var pathsByFile, decoder4, encoder6, VALID_ID, SfzLibraryService;
  var init_service = __esm({
    "js/sfz/service.js"() {
      init_ir_library_factory();
      init_audio_header_metadata();
      init_bank();
      init_asset();
      init_limits();
      init_parser();
      init_source();
      init_generators();
      init_oscillator_source();
      init_script_worker();
      init_sample_reader();
      init_sample_bank_source();
      init_source2();
      init_sample_integrity();
      init_sample_metadata();
      init_effects_asset();
      init_preparation_context();
      pathsByFile = /* @__PURE__ */ new WeakMap();
      decoder4 = new TextDecoder("utf-8", { fatal: true });
      encoder6 = new TextEncoder();
      VALID_ID = /^[a-f0-9]{24}$/;
      SfzLibraryService = class {
        constructor(backend, {
          onDiagnostic = (detail) => console.warn("SFZ library:", detail),
          getMaxBytes = () => getSfzMaxBytes(globalThis.window?.appConfig?.sfzMaxSizeMiB)
        } = {}) {
          this.backend = backend;
          this.onDiagnostic = onDiagnostic;
          this.getMaxBytes = getMaxBytes;
          this.entries = [];
          this.prepared = null;
          this.writes = Promise.resolve();
        }
        async open() {
          try {
            await this.backend.cleanupTemporary?.();
            const bytes = await this.backend.read("index.json");
            if (bytes) {
              const index = JSON.parse(decoder4.decode(bytes));
              if (index.version !== 1 || !Array.isArray(index.entries) || index.entries.length > 1e4 || index.entries.some((entry) => !VALID_ID.test(entry.id) || typeof entry.name !== "string" || !Number.isSafeInteger(entry.regionCount) || entry.regionCount < 1 || entry.streamedSource !== void 0 && typeof entry.streamedSource !== "boolean")) {
                throw new Error("Invalid SFZ library index.");
              }
              this.entries = index.entries;
            }
            return this;
          } catch (cause) {
            throw sfzError("storage", "The SFZ library could not be opened.", cause);
          }
        }
        async list() {
          await this.writes;
          return this.entries.map((entry) => ({ ...entry }));
        }
        async importFolderFiles(files, selectedPath, options = {}) {
          const maxBytes = requireSfzMaxBytes(this.getMaxBytes());
          const selectedFiles = fileMap(files);
          selectedPath = normalizeSfzPath(selectedPath);
          const getFile = async (path) => {
            const source = selectedFiles.get(path);
            if (typeof source?.getFile !== "function") return source;
            const file = await source.getFile();
            selectedFiles.set(path, file);
            return file;
          };
          if (/\.sf[23]$/i.test(selectedPath)) {
            const file = await getFile(selectedPath);
            if (!file || typeof this.backend.writeSfzBankFile !== "function" || typeof this.backend.readSfzBankFile !== "function") {
              throw sfzError("storage", "This browser cannot store the SoundFont. Try another browser.");
            }
            await openSf2Source(await createSfzFileSampleReader(file));
            return this._storeStreamedSource(selectedPath, /* @__PURE__ */ new Map([[selectedPath, file]]), options, maxBytes);
          }
          const read = async (path) => {
            const file = await getFile(path);
            if (!file) return null;
            if (file.size > maxBytes) throw sfzError("too-large", "An SFZ file is too large to save.");
            const bytes2 = new Uint8Array(await file.arrayBuffer());
            if (bytes2.byteLength > maxBytes) throw sfzError("too-large", "An SFZ file is too large to save.");
            return bytes2;
          };
          const storedFiles = /* @__PURE__ */ new Map();
          const readText = async (path) => {
            let bytes2 = storedFiles.get(path);
            if (!bytes2) {
              bytes2 = await read(path);
              if (!bytes2) return null;
              storedFiles.set(path, bytes2);
            }
            return decodeSfzText(bytes2);
          };
          const { defines, bankPath } = await readSfzBankDefines(
            selectedPath,
            [...selectedFiles.keys()].filter((path) => /\.bank\.xml$/i.test(path)),
            readText
          );
          for (const path of storedFiles.keys()) if (path !== bankPath) storedFiles.delete(path);
          const parsed = await parseSfz({
            selectedPath,
            maxBytes,
            defines,
            readText,
            resolveSample: sampleIntegrityResolver(async (path) => {
              const file = await getFile(path);
              if (!file) return null;
              if (typeof file.slice === "function") return createSfzFileSampleReader({
                size: file.size,
                lastModified: file.lastModified ?? 0,
                slice: (start, end) => file.slice(start, end)
              });
              return createSfzMemorySampleReader(await read(path));
            }, () => selectedFiles.keys(), maxBytes, this.onDiagnostic, options.isCurrent, options.onSourceProgress),
            hasSample: (path) => selectedFiles.has(path),
            onDiagnostic: this.onDiagnostic
          });
          if (!parsed.regions.length) throw sfzError("no-regions", "The SFZ has no playable regions.");
          if (parsed.presentation.image) {
            const bytes2 = await read(parsed.presentation.image);
            if (!bytes2) throw sfzError("prepare", "The instrument image could not be found. Select its complete folder and try again.");
            storedFiles.set(parsed.presentation.image, bytes2);
          }
          let accumulatedBytes = [...storedFiles.values()].reduce((sum, bytes2) => sum + bytes2.byteLength, 0);
          const metadata = /* @__PURE__ */ new Map();
          const sizes = new Map([...storedFiles].map(([path, bytes2]) => [path, bytes2.byteLength]));
          for (const path of [.../* @__PURE__ */ new Set([...parsed.regions.map((region) => region.sample), ...effectSamplePaths(parsed.effects)])].sort()) {
            if (isSfzGenerator(path)) {
              metadata.set(path, sfzGeneratorMetadata(path));
              continue;
            }
            const embedded = parsed.embeddedSamples.get(path);
            if (embedded) {
              metadata.set(path, { size: embedded.byteLength, ...parseIrAudioHeader(embedded) });
              continue;
            }
            const file = await getFile(path);
            const header = typeof file.slice === "function" ? await readSfzAudioHeader(async (position, length) => new Uint8Array(await file.slice(position, position + length).arrayBuffer()), file.size) : {};
            metadata.set(path, { size: file.size, ...header });
            sizes.set(path, file.size);
          }
          const rawSize = [...sizes.values()].reduce((sum, size) => sum + size, 0);
          const containerBytes = estimateSfzBankBytes(selectedPath, sizes) - rawSize;
          const canStream = typeof options.prepareStreamedBank === "function" && typeof this.backend.writeSfzBankFile === "function" && typeof this.backend.readSfzBankFile === "function";
          let streamed = canStream && sfzRequiresSampleStreaming(parsed.regions);
          if (!streamed) try {
            selectSfzRegionsForBudget(parsed.regions, metadata, maxBytes, accumulatedBytes + containerBytes);
          } catch (error2) {
            if (error2?.code !== "too-large" || !canStream) throw error2;
            streamed = true;
          }
          if (streamed) {
            const sourceFiles = new Map(storedFiles);
            for (const path of /* @__PURE__ */ new Set([...parsed.regions.map((region) => region.sample), ...effectSamplePaths(parsed.effects)])) {
              if (!isSfzGenerator(path) && !parsed.embeddedSamples.has(path)) sourceFiles.set(path, await getFile(path));
            }
            return this._storeStreamedSource(selectedPath, sourceFiles, options, maxBytes, parsed.warnings);
          }
          for (const path of [.../* @__PURE__ */ new Set([...parsed.regions.map((region) => region.sample), ...effectSamplePaths(parsed.effects)])].sort()) {
            if (isSfzGenerator(path)) continue;
            if (parsed.embeddedSamples.has(path)) continue;
            if (storedFiles.has(path)) continue;
            const file = selectedFiles.get(path);
            if (Number.isFinite(file?.size) && accumulatedBytes + file.size > maxBytes) {
              throw sfzError("too-large", "The SFZ bank is too large to save.");
            }
            const bytes2 = await read(path);
            accumulatedBytes += bytes2.byteLength;
            if (accumulatedBytes > maxBytes) throw sfzError("too-large", "The SFZ bank is too large to save.");
            storedFiles.set(path, bytes2);
          }
          const bytes = encodeSfzBank(selectedPath, storedFiles, {
            maxBytes,
            warnings: parsed.warnings || []
          });
          const id = await identifySfzBank(bytes);
          const prepared = { ...await prepareSfzSamples(
            parsed,
            (path) => storedFiles.get(path),
            options.decode,
            maxBytes,
            this.onDiagnostic
          ), name: selectedPath.split("/").pop() };
          const entry = {
            id,
            name: selectedPath.split("/").pop(),
            regionCount: prepared.regionCount,
            size: bytes.byteLength,
            fileCount: storedFiles.size,
            importedAt: (/* @__PURE__ */ new Date()).toISOString()
          };
          await this._write(async () => {
            try {
              await this.backend.writeAtomic(`${id}.sfzbank`, bytes);
              const entries = this.entries.filter((item) => item.id !== id).concat(entry).sort((a, b2) => a.id < b2.id ? -1 : 1);
              await this._saveIndex(entries);
              this.entries = entries;
              this.prepared = { id, bankBytes: bytes.byteLength, value: prepared };
            } catch (cause) {
              throw sfzError("storage", "The SFZ bank could not be saved.", cause);
            }
          });
          return { ...entry };
        }
        async _storeStreamedSource(selectedPath, sourceFiles, options, maxBytes, warnings = []) {
          const blob = encodeSfzBankBlob(selectedPath, sourceFiles, { warnings });
          const id = Array.from(globalThis.crypto.getRandomValues(new Uint8Array(12)), (byte) => byte.toString(16).padStart(2, "0")).join("");
          const name = `${id}.sfzbank`;
          return this._write(async () => {
            let committed = false;
            try {
              await this.backend.writeSfzBankFile(name, blob, { isCurrent: options.isCurrent, onProgress: options.onSourceProgress });
              const file = await this.backend.readSfzBankFile(name);
              const prepared = await prepareBankSource(id, file, {
                ...options,
                maxBytes,
                onDiagnostic: this.onDiagnostic,
                cacheBackend: this.backend
              });
              if (options.isCurrent?.() === false) throw sfzError("cancelled", "Instrument import was cancelled.");
              const entry = {
                id,
                name: selectedPath.split("/").pop(),
                regionCount: prepared.regionCount,
                size: blob.size,
                fileCount: sourceFiles.size,
                streamedSource: true,
                importedAt: (/* @__PURE__ */ new Date()).toISOString(),
                ...["sf2", "sf3"].includes(prepared.format) && { format: prepared.format }
              };
              const entries = this.entries.concat(entry).sort((a, b2) => a.id < b2.id ? -1 : 1);
              await this._saveIndex(entries);
              this.entries = entries;
              committed = true;
              this.prepared = { id, bankBytes: blob.size, streamedSource: true, value: prepared };
              return { ...entry };
            } finally {
              if (!committed) await this.backend.remove(name).catch((error2) => this.onDiagnostic?.({ sourceCleanup: error2 }));
            }
          });
        }
        async prepare(id, { decode, prepareStreamedBank, prepareSoundFontBank: prepareSoundFontBank2, isCurrent, onSourceProgress, onPreparationProgress, preparationContext, estimateEffectBytes } = {}) {
          const maxBytes = requireSfzMaxBytes(this.getMaxBytes());
          if (!VALID_ID.test(id)) return null;
          await this.writes;
          const entry = this.entries.find((item) => item.id === id);
          if (!entry) return null;
          if (this.prepared?.id === id) {
            const cached = this.prepared;
            let value = cached.value;
            if (!cached.streamedSource && cached.bankBytes > maxBytes || value.descriptor.footprintBytes > maxBytes) {
              throw sfzError("too-large", "The SFZ bank is too large to load.");
            }
            const key = preparationContext ? sfzPreparationContextKey(preparationContext) : null;
            if (preparationContext && key !== cached.contextKey) {
              const previous = value.descriptor;
              const descriptor = await prepareSfzAssetForContext(previous, preparationContext, maxBytes, estimateEffectBytes);
              if (isCurrent?.() === false) return null;
              value = { ...value, descriptor };
              if (this.prepared === cached) this.prepared = { ...cached, contextKey: key, value };
            }
            return value;
          }
          if (entry.streamedSource || typeof prepareStreamedBank === "function" && typeof this.backend.readSfzBankFile === "function") {
            if (typeof this.backend.readSfzBankFile !== "function") throw sfzError("storage", "The SFZ source files could not be opened.");
            const file = await this.backend.readSfzBankFile(`${id}.sfzbank`);
            if (!file) return null;
            const value = await prepareBankSource(id, file, {
              decode,
              prepareStreamedBank,
              prepareSoundFontBank: prepareSoundFontBank2,
              maxBytes,
              isCurrent,
              onSourceProgress,
              onPreparationProgress,
              onDiagnostic: this.onDiagnostic,
              cacheBackend: this.backend,
              preparationContext,
              estimateEffectBytes
            });
            await this.writes;
            if (!this.entries.includes(entry)) return null;
            this.prepared = {
              id,
              bankBytes: file.size,
              streamedSource: true,
              value,
              contextKey: preparationContext ? sfzPreparationContextKey(preparationContext) : null
            };
            return value;
          }
          let bytes;
          try {
            bytes = await this.backend.read(`${id}.sfzbank`);
          } catch (cause) {
            throw sfzError("storage", "The SFZ bank could not be read.", cause);
          }
          if (!bytes) return null;
          try {
            const value = await prepareBank(bytes, decode, this.onDiagnostic, maxBytes, { isCurrent, onSourceProgress, preparationContext, estimateEffectBytes, onProgress: onPreparationProgress });
            await this.writes;
            if (!this.entries.includes(entry)) return null;
            this.prepared = {
              id,
              bankBytes: bytes.byteLength,
              value,
              contextKey: preparationContext ? sfzPreparationContextKey(preparationContext) : null
            };
            return value;
          } catch (cause) {
            if (cause?.code) throw cause;
            throw sfzError("prepare", "The SFZ bank could not be prepared.", cause);
          }
        }
        async remove(id) {
          if (!VALID_ID.test(id)) throw sfzError("storage", "Invalid SFZ bank identifier.");
          await this._write(async () => {
            try {
              const entries = this.entries.filter((entry) => entry.id !== id);
              await this._saveIndex(entries);
              this.entries = entries;
              await this.backend.remove(`${id}.sfzbank`);
              if (this.prepared?.id === id) this.prepared = null;
            } catch (cause) {
              throw sfzError("storage", "The SFZ bank could not be removed.", cause);
            }
          });
        }
        async readMetadata(id) {
          await this.writes;
          const entry = this.entries.find((entry2) => entry2.id === id);
          if (!entry) return null;
          if (entry.size !== void 0 && entry.fileCount !== void 0) return { ...entry };
          const bytes = await this.backend.read(`${id}.sfzbank`);
          if (!bytes) return null;
          const bank = decodeSfzBank(bytes, { maxBytes: SFZ_MAX_SUPPORTED_BYTES });
          return { ...entry, size: bytes.byteLength, fileCount: bank.files.size };
        }
        _saveIndex(entries) {
          return this.backend.writeAtomic("index.json", encoder6.encode(JSON.stringify({ version: 1, entries })));
        }
        _write(operation) {
          const promise = this.writes.then(operation);
          this.writes = promise.catch(() => {
          });
          return promise;
        }
      };
    }
  });

  // js/vendor/offline-audio-encoders.mjs
  var offline_audio_encoders_exports = {};
  __export(offline_audio_encoders_exports, {
    AudioBufferSource: () => w0,
    AudioSample: () => y,
    AudioSampleSource: () => k0,
    BufferTarget: () => S0,
    FlacOutputFormat: () => P0,
    Output: () => G0
  });
  function l(e8) {
    if (!e8) throw new Error("Assertion failed.");
  }
  async function Ze(e8) {
    if (typeof Worker < "u" && typeof Bun > "u") {
      let x = new Blob([e8], { type: "text/javascript" }), t = URL.createObjectURL(x);
      return new Worker(t, { type: typeof Deno < "u" ? "module" : void 0 });
    } else {
      let x;
      try {
        x = (await Promise.resolve().then(() => Te(he(), 1))).Worker;
      } catch {
        x = Ye("worker_threads").Worker;
      }
      return new x(e8, { eval: true });
    }
  }
  function xt() {
    return Ze(`var Nr=Object.defineProperty;var xr=(k,B,j)=>B in k?Nr(k,B,{enumerable:!0,configurable:!0,writable:!0,value:j}):k[B]=j;var lA=(k=>typeof require!="undefined"?require:typeof Proxy!="undefined"?new Proxy(k,{get:(B,j)=>(typeof require!="undefined"?require:B)[j]}):k)(function(k){if(typeof require!="undefined")return require.apply(this,arguments);throw Error('Dynamic require of "'+k+'" is not supported')});var aA=(k,B,j)=>xr(k,typeof B!="symbol"?B+"":B,j);async function Qr(k={}){var eA,GA,qA;var B,j=k,$=!!globalThis.window,G=!!globalThis.WorkerGlobalScope,l=((GA=(eA=globalThis.process)==null?void 0:eA.versions)==null?void 0:GA.node)&&((qA=globalThis.process)==null?void 0:qA.type)!="renderer",o=[],u="./this.program",D=(A,r)=>{throw r},_A="",mA="",MA,TA;if($||G){try{mA=new URL(".",_A).href}catch(A){}G&&(TA=A=>{var r=new XMLHttpRequest;return r.open("GET",A,!1),r.responseType="arraybuffer",r.send(null),new Uint8Array(r.response)}),MA=async A=>{var r=await fetch(A,{credentials:"same-origin"});if(r.ok)return r.arrayBuffer();throw new Error(r.status+" : "+r.url)}}var b=console.log.bind(console),m=console.error.bind(console),y,M=!1,T;function OA(A){for(var r=0,n=A.length,t=new Uint8Array(n),E;r<n;++r)E=A.charCodeAt(r),t[r]=~E>>8&E;return t}var O,L,V,c,LA,dA,HA,d,hA,wA,JA,gA,X=!1;function R(){var A=h.buffer;V=new Int8Array(A),LA=new Int16Array(A),j.HEAPU8=c=new Uint8Array(A),dA=new Uint16Array(A),HA=new Int32Array(A),d=new Uint32Array(A),hA=new Float32Array(A),wA=new Float64Array(A),JA=new BigInt64Array(A),gA=new BigUint64Array(A)}function bA(){if(j.preRun)for(typeof j.preRun=="function"&&(j.preRun=[j.preRun]);j.preRun.length;)WA(j.preRun.shift());N(Q)}function yA(){X=!0,f.k()}function VA(){if(j.postRun)for(typeof j.postRun=="function"&&(j.postRun=[j.postRun]);j.postRun.length;)QA(j.postRun.shift());N(x)}function S(A){var n;(n=j.onAbort)==null||n.call(j,A),A="Aborted("+A+")",m(A),M=!0,A+=". Build with -sASSERTIONS for more info.";var r=new WebAssembly.RuntimeError(A);throw L==null||L(r),r}var H;function XA(){return OA(\`\\0asm\\0\\0\\0\\xFA#\\\`\\x7F\\x7F\\x7F\\0\\\`\\x7F\\x7F\\x7F\\x7F\\\`\\x7F\\x7F\\x7F\\\`\\x7F\\x7F\\\`\\x7F\\x7F\\x7F\\x7F\\x7F\\\`\\x7F\\0\\\`\\x7F~\\x7F\\x7F\\\`\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\\`\\x7F~~~~\\0\\\`\\x7F\\x7F\\0\\\`\\0\\0\\\`\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\0\\\`\\x7F\\x7F\\x7F\\x7F\\0\\\`||\\\`\\x7F~~\\x7F\\0\\\`\\x7F~\\x7F~\\\`\\x7F|\\0\\\`|\\x7F|\\\`|}\\\`|\\x7F\\\`\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\\`\\x07\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\0\\\`\\x7F|\\x7F\\\`\\x7F~\\x7F\\x7F\\x7F\\\`}}\\\`\\x7F|\\\`~~~~\\x7F\\\`\\f\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\0\\\`\\b\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\\`\\r\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\x7F\\\`\\x7F\\x7F}\\0\\\`~~~\\x7F\\\`\\x7F~~~\\0\\\`\\x7F~\\\`\\0\\x7F7	aa\\0ab\\0
ac\\0
ad\\0ae\\0af\\0ag\\0ah\\0ai\\0}|\\b\\r\\b\\b	\\r			\\v	\\x1B\\b\\0\\0\\f\\x07\\b\\b\\r !	\\0\\0\\v\\v\\f\\x07"


p\\x07\\x82\\x80\\x80\\b\\x7FA\\xA0\\xF2\\v\\x07Kj\\0k\\0\\x84l\\0pm\\0	n\\0wo\\0op\\0qq\\0vr\\0ts\\0ut\\0su\\0rv\\0xw\\0bx\\0\\x80y\\0{z\\0zA\\0y	!\\0A\\vlkjihgmna\\\`fcdeB|\\x83_]\\x82^\\x81}\\x7F\\f
\\xDC\\xBF	|\\xD0\\x7F \\0@ \\0Ak"(\\0"! ! \\0A\\bk(\\0"\\0 \\0A~q"\\0G@  \\0k"(" (\\b"6\\b  6 \\0 j!\\v  j"\\0(\\0" \\0 jAk(\\0G@ \\0(" \\0(\\b"\\x006\\b \\0 6  j!\\v  6\\0  A|qjAk Ar6\\0 \\x7F (\\0A\\bk"\\0A\\xFF\\0M@ \\0AvAk\\f\\v \\0g! \\0A kvAs AtkA\\xEE\\0j \\0A\\xFFM\\r\\0A? \\0A kvAs AtkA\\xC7\\0j"\\0 \\0A?O\\x1B\\v"At"\\0A\\xE0\\xD8\\0j6  \\0A\\xE8\\xD8\\0j"\\0(\\x006\\b \\0 6\\0 (\\b 6A\\xE8\\xE0\\0A\\xE8\\xE0\\0)\\0B \\xAD\\x86\\x847\\0\\v\\v\\x8E\\x7F|#\\0Ak"	$\\0} \\0\\xBC"A\\xFF\\xFF\\xFF\\xFF\\x07q"A\\xDA\\x9F\\xA4\\xFAM@C\\0\\0\\x80? A\\x80\\x80\\x80\\xCCI\\r \\0\\xBB+\\f\\v A\\xD1\\xA7\\xED\\x83M@ A\\xE4\\x97\\xDB\\x80O@D-DT\\xFB!	@D-DT\\xFB!	\\xC0 A\\0H\\x1B \\0\\xBB\\xA0+\\x8C\\f\\v \\0\\xBB! A\\0H@ D-DT\\xFB!\\xF9?\\xA0&\\f\\vD-DT\\xFB!\\xF9? \\xA1&\\f\\v A\\xD5\\xE3\\x88\\x87M@ A\\xE0\\xDB\\xBF\\x85O@D-DT\\xFB!@D-DT\\xFB!\\xC0 A\\0H\\x1B \\0\\xBB\\xA0+\\f\\v A\\0H@D\\xD2!3\\x7F|\\xD9\\xC0 \\0\\xBB\\xA1&\\f\\v \\0\\xBBD\\xD2!3\\x7F|\\xD9\\xC0\\xA0&\\f\\v \\0 \\0\\x93 A\\x80\\x80\\x80\\xFC\\x07O\\r\\0#\\0Ak"\\v$\\0@ \\0\\xBC"A\\xFF\\xFF\\xFF\\xFF\\x07q"A\\xDA\\x9F\\xA4\\xEEM@ 	 \\0\\xBB" D\\x83\\xC8\\xC9m0_\\xE4?\\xA2D\\0\\0\\0\\0\\0\\x008C\\xA0D\\0\\0\\0\\0\\0\\x008\\xC3\\xA0"D\\0\\0\\0P\\xFB!\\xF9\\xBF\\xA2\\xA0 Dcba\\xB4Q\\xBE\\xA2\\xA0"9\\b \\xFC! D\\0\\0\\0\\\`\\xFB!\\xE9\\xBFc@ 	  D\\0\\0\\0\\0\\0\\0\\xF0\\xBF\\xA0"D\\0\\0\\0P\\xFB!\\xF9\\xBF\\xA2\\xA0 Dcba\\xB4Q\\xBE\\xA2\\xA09\\b Ak!\\f\\v D\\0\\0\\0\\\`\\xFB!\\xE9?dE\\r 	  D\\0\\0\\0\\0\\0\\0\\xF0?\\xA0"D\\0\\0\\0P\\xFB!\\xF9\\xBF\\xA2\\xA0 Dcba\\xB4Q\\xBE\\xA2\\xA09\\b Aj!\\f\\v A\\x80\\x80\\x80\\xFC\\x07O@ 	 \\0 \\0\\x93\\xBB9\\bA\\0!\\f\\v \\v  AvA\\x96k"Atk\\xBE\\xBB9\\b\\x7F \\vA\\bj!
#\\0A\\xB0k"$\\0  AkAm"A\\0 A\\0J\\x1B"Ahlj!A\\xE0=(\\0"\\x07A\\0N@ \\x07Aj! !@ A\\xC0j Atj A\\0H|D\\0\\0\\0\\0\\0\\0\\0\\0 At(\\xF0=\\xB7\\v9\\0 Aj! Aj" G\\r\\0\\v\\v Ak!\\bA\\0! \\x07A\\0 \\x07A\\0J\\x1B!@A\\0!D\\0\\0\\0\\0\\0\\0\\0\\0!@ 
 Atj+\\0 A\\xC0j  kAtj+\\0\\xA2 \\xA0! Aj"AG\\r\\0\\v  Atj 9\\0  F Aj!E\\r\\0\\vA/ k!A0 k! AtA\\xF0=j! AH! Ak! \\x07!@  Atj+\\0!A\\0! ! A\\0J@@ A\\xE0j Atj D\\0\\0\\0\\0\\0\\0p>\\xA2\\xFC\\xB7"D\\0\\0\\0\\0\\0\\0p\\xC1\\xA2 \\xA0\\xFC6\\0  AtjA\\bk+\\0 \\xA0! Ak! Aj" G\\r\\0\\v\\v  \\b!" D\\0\\0\\0\\0\\0\\0\\xC0?\\xA2\\x9CD\\0\\0\\0\\0\\0\\0 \\xC0\\xA2\\xA0" \\xFC"\\f\\xB7\\xA1!@@@\\x7F E@ At j" (\\xDC"  u" tk"6\\xDC  \\fj!\\f  u\\f\\v \\b\\r At j(\\xDCAu\\v"\\rA\\0L\\r\\f\\vA!\\r D\\0\\0\\0\\0\\0\\0\\xE0?f\\r\\0A\\0!\\r\\f\\vA\\0!A\\0!A! A\\0J@@ A\\xE0j Atj"(\\0!\\x7F@  \\x7FA\\xFF\\xFF\\xFF\\x07 E\\rA\\x80\\x80\\x80\\b\\v k6\\0A!A\\0\\f\\vA\\0!A\\v! Aj" G\\r\\0\\v\\v@ \\r\\0A\\xFF\\xFF\\xFF!@@ \\0\\vA\\xFF\\xFF\\xFF!\\v At j" (\\xDC q6\\xDC\\v \\fAj!\\f \\rAG\\r\\0D\\0\\0\\0\\0\\0\\0\\xF0? \\xA1!A!\\r \\r\\0 D\\0\\0\\0\\0\\0\\0\\xF0? \\b!\\xA1!\\v@@ D\\0\\0\\0\\0\\0\\0\\0\\0a@A\\0! !  \\x07L\\r@ A\\xE0j Ak"Atj(\\0 r!  \\x07J\\r\\0\\v E\\r@ \\bAk!\\b A\\xE0j Ak"Atj(\\0E\\r\\0\\v\\f\\v@ A k!"D\\0\\0\\0\\0\\0\\0pAf@ A\\xE0j Atj D\\0\\0\\0\\0\\0\\0p>\\xA2\\xFC"\\xB7D\\0\\0\\0\\0\\0\\0p\\xC1\\xA2 \\xA0\\xFC6\\0 Aj! !\\b\\f\\v \\xFC!\\v A\\xE0j Atj 6\\0\\vD\\0\\0\\0\\0\\0\\0\\xF0? \\b!! A\\0N@ !@  "Atj  A\\xE0j Atj(\\0\\xB7\\xA29\\0 Ak! D\\0\\0\\0\\0\\0\\0p>\\xA2! \\r\\0\\vA\\0! !@ \\x07   \\x07J\\x1B!  Atj!\\bA\\0!D\\0\\0\\0\\0\\0\\0\\0\\0!@ At"
+\\xC0S \\b 
j+\\0\\xA2 \\xA0!  G Aj!\\r\\0\\v A\\xA0j  kAtj 9\\0 Ak!  G Aj!\\r\\0\\v\\vD\\0\\0\\0\\0\\0\\0\\0\\0! A\\0N@@ "Ak!  A\\xA0j Atj+\\0\\xA0! \\r\\0\\v\\v \\v \\x9A  \\r\\x1B9\\0 A\\xB0j$\\0 \\fA\\x07q\\f\\vA!@ "Aj! A\\xE0j \\x07 kAtj(\\0E\\r\\0\\v  j!@ A\\xC0j Aj"Atj  Atj(\\0\\xB79\\0A\\0!D\\0\\0\\0\\0\\0\\0\\0\\0!@ 
 Atj+\\0 A\\xC0j  kAtj+\\0\\xA2 \\xA0! Aj"AG\\r\\0\\v  Atj 9\\0  H\\r\\0\\v !\\f\\0\\v\\0\\v! \\v+\\0! A\\0H@ 	 \\x9A9\\bA\\0 k!\\f\\v 	 9\\b\\v \\vAj$\\0 	+\\b!@@@@ AqAk\\0\\v +\\f\\v \\x9A&\\f\\v +\\x8C\\f\\v &\\v 	Aj$\\0\\v\\xC6\\x7F~@ \\0E A Kr\\r\\0 \\0(\\0"E\\r\\0 E@A\\v@ \\0(" \\0(" jK\\r\\0  \\0(jA?jAv j" M\\r\\0 A\\x81\\x80\\x80K\\r Av" j   k I\\x1B"@A\\0! A\\xFF\\xFF\\xFF\\xFFK\\r At!\\x07\\vA\\0!  \\x07"E\\r \\0 6 \\0 6\\0\\vA\\xC0\\0 \\0("k" K@ \\0  j6 \\0 \\xAD \\0)\\b \\xAD\\x86\\x847\\bA\\v @ \\0  k"6 \\0 \\0("Aj6  Atj \\0)\\b \\xAD\\x86"\\b  v\\xAD\\x84"	B8\\x86 	B\\x80\\xFE\\x83B(\\x86\\x84 	B\\x80\\x80\\xFC\\x07\\x83B\\x86 	B\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 \\bB\\b\\x88B\\x80\\x80\\x80\\xF8\\x83 \\bB\\x88B\\x80\\x80\\xFC\\x07\\x83\\x84 \\bB(\\x88B\\x80\\xFE\\x83 \\bB8\\x88\\x84\\x84\\x847\\0 \\0 \\xAD7\\bA\\vA! \\0 \\0("\\0Aj6  \\0Atj \\xAD"\\bB8\\x86 \\bB\\x80\\xFE\\x83B(\\x86\\x84 \\bB\\x80\\x80\\xFC\\x07\\x83B\\x86 \\bB\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x847\\0\\v \\v\\x94\\x7F~@ E@ A\\x006\\0\\f\\v@ \\0($E\\r\\0 \\0(("A\\x7FF\\r\\0  K@ \\0A\\x7F6(A\\0\\v \\0  k6(\\v@@ \\0(\\b" \\0("kAt \\0(\\fAtj \\0("k O\\r \\0.\\r\\0\\vA\\0\\v  I@ @B\\x7F \\xAD\\x88B\\0 A\\xC0\\0I\\x1B! \\0(\\0" Atj)\\0!\\x07A\\xC0\\0 k" K@   \\x07\\x83  k"\\xAD\\x88\\xA7A\\0 A\\xC0\\0I\\x1B6\\0 \\0 \\0( j6\\f\\v   \\x07\\x83>\\0 \\0A\\x006 \\0 \\0(Aj6  F\\r \\x7F@  k"AM@  (\\0 t"6\\0\\f\\v A\\x006\\0A\\0" A\\xC0\\0K\\r\\v   \\0(Atj)\\0A\\xC0\\0 k\\xAD\\x88\\xA7r\\v6\\0 \\0 6A\\v \\0(\\0 Atj)\\0! A?M@  A\\xC0\\0 k\\xAD\\x88>\\0 \\0 6\\f\\v  >\\0 \\0 \\0(Aj6A\\v \\0(\\0 Atj)\\0! @  B\\x7F \\xAD\\x88\\x83A\\xC0\\0  jk\\xAD\\x88>\\0 \\0 \\0( j6\\f\\v  A\\xC0\\0 k\\xAD\\x88>\\0 \\0 \\0( j6\\vA\\v\\xEA\\x7F~@@@ \\0AGK\\rA\\xE8\\xE0\\0)\\0"\\x7FA\\b \\0AjA|q \\0A\\bM\\x1B"\\0A\\xFF\\0M@ \\0AvAk\\f\\v \\0A \\0g"kvAs AtkA\\xEE\\0j \\0A\\xFFM\\r\\0A? \\0A kvAs AtkA\\xC7\\0j" A?O\\x1B\\v"\\xAD\\x88"\\x07PE@@ \\x07 \\x07z"\\x07\\x88!~  \\x07\\xA7j"At"A\\xE8\\xD8\\0j(\\0" A\\xE0\\xD8\\0j"G@  \\04"\\r (" (\\b"6\\b  6  6\\b  (6  6 ( 6\\b Aj! B\\x88\\f\\vA\\xE8\\xE0\\0A\\xE8\\xE0\\0)\\0B~ \\xAD\\x89\\x837\\0 B\\x85\\v"\\x07B\\0R\\r\\0\\vA\\xE8\\xE0\\0)\\0!\\vA? y\\xA7k!@ P@A\\0!\\f\\v At"A\\xE8\\xD8\\0j(\\0! B\\x80\\x80\\x80\\x80T\\r\\0A\\xE3\\0!  A\\xE0\\xD8\\0j"F\\r\\0@ E\\r  \\04"\\r Ak! (\\b" G\\r\\0\\v\\v \\0A0jN\\r\\0\\v E\\r\\0  AtA\\xE0\\xD8\\0j"F\\r\\0@  \\04"\\r (\\b" G\\r\\0\\v\\vA\\0!\\v \\v\\xCB
\\x7F	~#\\0A\\xE0\\0k"$\\0 B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?\\x83!
  \\x85B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x7F\\x83!\\v B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?\\x83"\\fB \\x88! B0\\x88\\xA7A\\xFF\\xFFq!\\x07@@ B0\\x88\\xA7A\\xFF\\xFFq"	A\\xFF\\xFFkA\\x82\\x80~O@ \\x07A\\xFF\\xFFkA\\x81\\x80~K\\r\\v P B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\0\\x83"\\rB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0T \\rB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0Q\\x1BE@ B\\x80\\x80\\x80\\x80\\x80\\x80 \\x84!\\v\\f\\v P B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\0\\x83"B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0T B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0Q\\x1BE@ B\\x80\\x80\\x80\\x80\\x80\\x80 \\x84!\\v !\\f\\v  \\rB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0\\x85\\x84P@  \\x84P@B\\x80\\x80\\x80\\x80\\x80\\x80\\xE0\\xFF\\xFF\\0!\\vB\\0!\\f\\v \\vB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0\\x84!\\vB\\0!\\f\\v  B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0\\x85\\x84P@  \\r\\x84B\\0!P@B\\x80\\x80\\x80\\x80\\x80\\x80\\xE0\\xFF\\xFF\\0!\\v\\f\\v \\vB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0\\x84!\\v\\f\\v  \\r\\x84P@B\\0!\\f\\v  \\x84P@B\\0!\\f\\v \\rB\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?X@ A\\xD0\\0j  \\f  \\f \\fP"\\x1ByB\\xC0\\0B\\0 \\x1B|\\xA7"AkA k! )X"\\fB \\x88! )P!\\v B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?V\\r\\0 A@k  
  
 
P"\\b\\x1ByB\\xC0\\0B\\0 \\b\\x1B|\\xA7"\\bAk  \\bkAj! )H!
 )@!\\v \\x07 	j jA\\xFF\\xFF\\0k!@ 
B\\x86"B \\x88B\\x80\\x80\\x80\\x80\\b\\x84" B \\x88"~" B\\x86"B \\x88"
 B\\x80\\x80\\x84"\\r~|" T\\xAD  B1\\x88 \\x84B\\xFF\\xFF\\xFF\\xFF\\x83" \\fB\\xFF\\xFF\\xFF\\xFF\\x83"\\f~|" T\\xAD|  \\r~|   B\\x80\\x80\\xFE\\xFF\\x83" \\f~"  
~|" T\\xAD    B\\xFF\\xFF\\xFF\\xFF\\x83"~|"V\\xAD||"V\\xAD|  \\r~"  \\f~|" T\\xADB \\x86 B \\x88\\x84|   B \\x86|"V\\xAD|  \\r ~"\\r 
 \\f~|"\\f  ~|"  ~|"B \\x88  V\\xAD \\f \\rT\\xAD  \\fT\\xAD||B \\x86\\x84|" T\\xAD|    ~"\\f  
~|"B \\x88  \\fT\\xADB \\x86\\x84|"
 T\\xAD 
 B \\x86|" 
T\\xAD||"
 T\\xAD| 
  B \\x86"  ~|" T\\xAD|" T\\xAD|" 
T\\xAD|"B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\0\\x83PE@ Aj!\\f\\v B?\\x88 B\\x86 B?\\x88\\x84! B\\x86 B?\\x88\\x84! B\\x86! B\\x86\\x84!\\v A\\xFF\\xFFN@ \\vB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0\\x84!\\vB\\0!\\f\\v~ A\\0L@A k"\\x07A\\xFF\\0M@ A0j   A\\xFF\\0j" A j    Aj   \\x07%    \\x07% )0 )8\\x84B\\0R\\xAD )  )\\x84\\x84! )( )\\x84! )\\0! )\\b\\f\\vB\\0!\\f\\v B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?\\x83 \\xADB0\\x86\\x84\\v \\v\\x84!\\v P B\\0Y B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x7FQ\\x1BE@ \\v B|"P\\xAD|!\\v\\f\\v  B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x7F\\x85\\x84PE@ !\\f\\v \\v  B\\x83|" T\\xAD|!\\v\\v \\0 7\\0 \\0 \\v7\\b A\\xE0\\0j$\\0\\v\\x93~|\\x7F@\\x7F@ \\0\\xBD"B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\x07W@ \\0D\\0\\0\\0\\0\\0\\0\\0\\0a@D\\0\\0\\0\\0\\0\\0\\xF0\\xBF \\0 \\0\\xA2\\xA3\\v B\\0Y\\r \\0 \\0\\xA1D\\0\\0\\0\\0\\0\\0\\0\\0\\xA3\\v B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xF7\\xFF\\0V\\rA\\x81x! B \\x88"B\\x80\\x80\\xC0\\xFFR@ \\xA7\\f\\vA\\x80\\x80\\xC0\\xFF \\xA7\\rD\\0\\0\\0\\0\\0\\0\\0\\0\\vA\\xCBw! \\0D\\0\\0\\0\\0\\0\\0PC\\xA2\\xBD"B \\x88\\xA7\\vA\\xE2\\xBE%j"\\x07Av j\\xB7"D\\0\\0\\xE0\\xFEB.\\xE6?\\xA2 B\\xFF\\xFF\\xFF\\xFF\\x83 \\x07A\\xFF\\xFF?qA\\x9E\\xC1\\x9A\\xFFj\\xADB \\x86\\x84\\xBFD\\0\\0\\0\\0\\0\\0\\xF0\\xBF\\xA0"\\0 \\0 \\0D\\0\\0\\0\\0\\0\\0\\0@\\xA0\\xA3" \\0 \\0D\\0\\0\\0\\0\\0\\0\\xE0?\\xA2\\xA2"  \\xA2" \\xA2"\\0 \\0 \\0D\\x9F\\xC6x\\xD0	\\x9A\\xC3?\\xA2D\\xAFx\\x8E\\xC5q\\xCC?\\xA0\\xA2D\\xFA\\x97\\x99\\x99\\x99\\xD9?\\xA0\\xA2  \\0 \\0 \\0DDR>\\xDF\\xF1\\xC2?\\xA2D\\xDE\\xCB\\x96dF\\xC7?\\xA0\\xA2DY\\x93"\\x94$I\\xD2?\\xA0\\xA2D\\x93UUUUU\\xE5?\\xA0\\xA2\\xA0\\xA0\\xA2 Dv<y5\\xEF9\\xEA=\\xA2\\xA0 \\xA1\\xA0\\xA0!\\0\\v \\0\\v\\x80\\x7F~@ \\0)p"PE  \\0)x \\0(" \\0(,"k\\xAC|"WqE@#\\0Ak"$\\0A\\x7F!@\\x7F \\0 \\0(H"Ak r6H \\0( \\0(G@ \\0A\\0A\\0 \\0($\\0\\v \\0A\\x006 \\0B\\x007 \\0(\\0"Aq@ \\0 A r6\\0A\\x7F\\f\\v \\0 \\0(, \\0(0j"6\\b \\0 6 A\\x1BtAu\\v\\r\\0 \\0 AjA \\0( \\0AG\\r\\0 -\\0!\\v Aj$\\0 A\\0N\\r \\0(,! \\0(!\\v \\0B\\x7F7p \\0 6h \\0   k\\xAC|7xA\\x7F\\v B|! \\0(! \\0(\\b!@ \\0)p"P\\r\\0  }"  k\\xACY\\r\\0  \\xA7j!\\v \\0 6h \\0  \\0(,"\\0 k\\xAC|7x \\0 O@ Ak :\\0\\0\\v \\v]\\x7F@ \\0-\\0\\0"E@A\\0!\\f\\v@@  -\\0\\0"G Er\\r Ak"E\\r Aj! \\0-\\0! \\0Aj!\\0 \\r\\0\\vA\\0!\\v\\v  -\\0\\0k\\v\\xE1\\x07\\x7F \\0E@ \\r\\v E@ \\0	A\\0\\v@ AGK\\r\\0\\x7FA\\b AjA|q A\\bM\\x1B"A\\bj!\\x7F@ \\0Ak"\\b"(\\0" j"(\\0"  jAk(\\0G@  j" AjO@ (" (\\b"6\\b  6  j"  k"6\\0  A|qjAk Ar6\\0 \\x7F (\\0A\\bk"A\\xFF\\0M@ AvAk\\f\\v A g"kvAs AtkA\\xEE\\0j A\\xFFM\\r\\0A? A kvAs AtkA\\xC7\\0j" A?O\\x1B\\v"At"A\\xE0\\xD8\\0j6  A\\xE8\\xD8\\0j"(\\x006\\b  6\\0 (\\b 6A\\xE8\\xE0\\0A\\xE8\\xE0\\0)\\0B \\xAD\\x86\\x847\\0  6\\0  A|qjAk 6\\0A\\f\\v  K\\r (" (\\b"6\\b  6  6\\0  A|qjAk 6\\0A\\f\\v  AjO@  6\\0  A|qjAk 6\\0  j"  k"6\\0  A|qjAk Ar6\\0 \\x7F (\\0A\\bk"A\\xFF\\0M@ AvAk\\f\\v A g"kvAs AtkA\\xEE\\0j A\\xFFM\\r\\0A? A kvAs AtkA\\xC7\\0j" A?O\\x1B\\v"At"A\\xE0\\xD8\\0j6  A\\xE8\\xD8\\0j"(\\x006\\b  6\\0 (\\b 6A\\xE8\\xE0\\0A\\xE8\\xE0\\0)\\0B \\xAD\\x86\\x847\\0A\\f\\vA  M\\r\\vA\\0\\v\\v@ \\0\\v \\r"E\\r\\0  \\0  \\b(\\0A\\bk"\\x07  \\x07I\\x1B> \\0	 !\\x07\\v \\x07\\vu~ \\0  ~  ~| B \\x88" B \\x88"~| B\\xFF\\xFF\\xFF\\xFF\\x83" B\\xFF\\xFF\\xFF\\xFF\\x83"~"B \\x88  ~|"B \\x88|  ~ B\\xFF\\xFF\\xFF\\xFF\\x83|"B \\x88|7\\b \\0 B\\xFF\\xFF\\xFF\\xFF\\x83 B \\x86\\x847\\0\\vP~@ A\\xC0\\0q@  A@j\\xAD\\x86!B\\0!\\f\\v E\\r\\0  \\xAD"\\x86 A\\xC0\\0 k\\xAD\\x88\\x84!  \\x86!\\v \\0 7\\0 \\0 7\\b\\v\\xCD	\\x7F~#\\0A\\xF0\\0k"$\\0 B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\0\\x83!	@@ P" B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\0\\x83"
B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0}B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\x80\\x80\\x7FT 
P\\x1BE@ B\\0R 	B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0}"\\vB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\x80\\x80\\x7FV \\vB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\x80\\x80\\x7FQ\\x1B\\r\\v  
B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0T 
B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0Q\\x1BE@ B\\x80\\x80\\x80\\x80\\x80\\x80 \\x84! !\\f\\v P 	B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0T 	B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0Q\\x1BE@ B\\x80\\x80\\x80\\x80\\x80\\x80 \\x84!\\f\\v  
B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0\\x85\\x84P@B\\x80\\x80\\x80\\x80\\x80\\x80\\xE0\\xFF\\xFF\\0   \\x85  \\x85B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x7F\\x85\\x84P"\\x1B!B\\0  \\x1B!\\f\\v  	B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0\\x85\\x84P\\r  
\\x84P@  	\\x84B\\0R\\r  \\x83!  \\x83!\\f\\v  	\\x84PE\\r\\0 ! !\\f\\v    T 	 
V 	 
Q\\x1B"\\b\\x1B!
   \\b\\x1B"\\fB\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?\\x83!	   \\b\\x1B"\\vB0\\x88\\xA7A\\xFF\\xFFq!\\x07 \\fB0\\x88\\xA7A\\xFF\\xFFq"E@ A\\xE0\\0j 
 	 
 	 	P"\\x1ByB\\xC0\\0B\\0 \\x1B|\\xA7"Ak )h!	 )\\\`!
A k!\\v   \\b\\x1B! \\vB\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?\\x83! \\x07~  A\\xD0\\0j     P"\\x07\\x1ByB\\xC0\\0B\\0 \\x07\\x1B|\\xA7"\\x07AkA \\x07k!\\x07 )P! )X\\vB\\x86 B=\\x88\\x84B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x84! 	B\\x86 
B=\\x88\\x84  \\x85!~ B\\x86"  \\x07F\\r\\0  \\x07k"\\x07A\\xFF\\0K@B\\0!B\\f\\v A@k  A\\x80 \\x07k A0j   \\x07% )8! )0 )@ )H\\x84B\\0R\\xAD\\x84\\v!	B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x84!\\v 
B\\x86!
@ B\\0S@B\\0!B\\0! 	 
\\x85  \\v\\x85\\x84P\\r 
 	}! \\v } 	 
V\\xAD}"B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFFV\\r A j     P"\\x07\\x1ByB\\xC0\\0B\\0 \\x07\\x1B\\x84\\xA7A\\fk"\\x07  \\x07k! )(! ) !\\f\\v 	 
|" 	T\\xAD  \\v||"B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\b\\x83P\\r\\0 	B\\x83 B?\\x86 B\\x88\\x84\\x84! Aj! B\\x88!\\v \\fB\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x7F\\x83! A\\xFF\\xFFN@ B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0\\x84!B\\0!\\f\\vA\\0!\\x07@ A\\0J@ !\\x07\\f\\v Aj   A\\xFF\\0j   A k% )\\0 ) )\\x84B\\0R\\xAD\\x84! )\\b!\\v B=\\x86 B\\x88\\x84! B\\x88B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?\\x83 \\x07\\xADB0\\x86\\x84 \\x84!@@ \\xA7A\\x07q"AG@    AK\\xAD|"V\\xAD|!\\f\\v    B\\x83|"V\\xAD|!\\f\\v E\\r\\v\\v \\0 7\\0 \\0 7\\b A\\xF0\\0j$\\0\\v\\x84\\x7F~#\\0Ak"$\\0 \\0~ E@B\\0\\f\\v   Au"s k"\\xADB\\0 g"A\\xD1\\0j )\\bB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\0\\x85A\\x9E\\x80 k\\xADB0\\x86|B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x7FB\\0 A\\0H\\x1B\\x84! )\\0\\v7\\0 \\0 7\\b Aj$\\0\\v \\0 \\0 l"\\0\\r"A\\0 \\0\\x1B@ A\\0 \\0\\xFC\\v\\0\\v \\v\\xA55\\x7F\\x07~|#\\0Ak"$\\0#\\0A\\xA0k"\\v$\\0 \\v \\x006< \\v \\x006 \\vA\\x7F6 \\vAj"<#\\0A0k"\\f$\\0@\\x7F ("\\0 (hG@  \\0Aj6 \\0-\\0\\0\\f\\v \\v""\\0A F \\0A	kAIr\\r\\0\\vA!@@ A+k\\0\\0\\vA\\x7FA A-F\\x1B! ("\\0 (hG@  \\0Aj6 \\0-\\0\\0!\\f\\v !\\v@@@@@ A_q"\\0A\\xCE\\0F@@ AF\\r\\x7F ("\\0 (hG@  \\0Aj6 \\0-\\0\\0\\f\\v \\v! ,\\0\\xA0 Aj"! A rF\\r\\0\\f\\v\\0\\v \\0A\\xC9\\0G\\r@@ "\\0A\\x07F\\r\\x7F (" (hG@  Aj6 -\\0\\0\\f\\v \\v! \\0Aj! \\0,\\0\\xF1 A rF\\r\\0\\vA! \\0AG@ \\0AI@ !\\f\\v "A\\bF\\r\\v )p"B\\0Y@  (Ak6\\v AI\\r\\0 B\\0S!\\0@ \\0E@  (Ak6\\v Ak"AK\\r\\0\\v\\vB\\0!#\\0Ak"$\\0 \\xB2C\\0\\0\\x80\\x7F\\x94\\xBC"A\\xFF\\xFF\\xFFq!\\x7F Av"A\\xFFq"\\0@ \\0A\\xFFG@ \\xADB\\x86! A\\xFFqA\\x80\\xFF\\0j\\f\\v \\xADB\\x86!A\\xFF\\xFF\\f\\vA\\0 E\\r\\0  \\xADB\\0 g"\\0A\\xD1\\0j )\\bB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\0\\x85! )\\0!A\\x89\\xFF\\0 \\0k\\v!\\0 \\f 7  \\f \\0\\xADB0\\x86 Av\\xADB?\\x86\\x84 \\x847( Aj$\\0 \\f)(! \\f) !\\f\\v AG\\r\\v@\\x7F ("\\0 (hG@  \\0Aj6 \\0-\\0\\0\\f\\v \\vA(F@A!\\f\\vB\\x80\\x80\\x80\\x80\\x80\\x80\\xE0\\xFF\\xFF\\0! )pB\\0S\\r  (Ak6\\f\\v@\\x7F ("\\0 (hG@  \\0Aj6 \\0-\\0\\0\\f\\v \\v"\\0A0kA
I \\0A\\xC1\\0kAIr \\0A\\xDF\\0FrE \\0A\\xE1\\0kAOqE@ Aj!\\f\\v\\vB\\x80\\x80\\x80\\x80\\x80\\x80\\xE0\\xFF\\xFF\\0! \\0A)F\\r )p"B\\0Y@  (Ak6\\v E\\r@ B\\0Y@  (Ak6\\v Ak"\\r\\0\\v\\f\\v )pB\\0Y@  (Ak6\\vA\\xD0\\xD8\\0A6\\0 <\\f\\v@ A0G\\r\\0\\x7F ("\\0 (hG@  \\0Aj6 \\0-\\0\\0\\f\\v \\vA_qA\\xD8\\0F@#\\0A\\xB0k"$\\0\\x7F ("\\0 (hG@  \\0Aj6 \\0-\\0\\0\\f\\v \\v!@\\x7F@ A0G@@ A.G\\r ("\\0 (hF\\r\\0  \\0Aj6 \\0-\\0\\0\\f\\v ("\\0 (hG\\x7FA!  \\0Aj6 \\0-\\0\\0A! \\v!\\f\\v\\v \\v"A0G@A!\\x07\\f\\v@ B}!\\x7F ("\\0 (hG@  \\0Aj6 \\0-\\0\\0\\f\\v \\v"A0F\\r\\0\\vA!\\x07A!\\vB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF?!@@@@@ "A0k"A
I\\r\\0 A.G"\\0 A r"A\\xE1\\0kAKq\\r \\0\\r\\0 \\x07\\rA!\\x07 !\\f\\v A\\xD7\\0k  A9J\\x1B!\\0@ B\\x07W@ \\0 	Atj!	\\f\\v BX@ A0j \\0 A j  B\\0B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFD? Aj )0 )8 ) " )("  ) )   )\\b! )\\0!\\f\\v \\0E \\rr\\r\\0 A\\xD0\\0j  B\\0B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\xFF? A@k )P )X  A!\\r )H! )@!\\v B|!A!\\v ("\\0 (hG\\x7F  \\0Aj6 \\0-\\0\\0 \\v!\\f\\v\\vA.!\\v~ E@@ )pB\\0S\\r\\0  ("\\0Ak6 \\x07E\\r\\0  \\0Ak6\\v A\\xE0\\0jD\\0\\0\\0\\0\\0\\0\\0\\0 \\xB7\\xA6 )\\\`! )h\\f\\v B\\x07W@ !@ 	At!	 B|"B\\bR\\r\\0\\v\\v@@@ A_qA\\xD0\\0F@ Y"B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x7FR\\r )pB\\0Y\\r\\f\\vB\\0! )pB\\0S\\r\\v  (Ak6\\vB\\0!\\v 	E@ A\\xF0\\0jD\\0\\0\\0\\0\\0\\0\\0\\0 \\xB7\\xA6 )p! )x\\f\\v   \\x07\\x1BB\\x86 |B }"B\\xB3\\bY@A\\xD0\\xD8\\0A\\xC4\\x006\\0 A\\xA0j  A\\x90j )\\xA0 )\\xA8B\\x7FB\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xBF\\xFF\\xFF\\0 A\\x80j )\\x90 )\\x98B\\x7FB\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xBF\\xFF\\xFF\\0 )\\x80! )\\x88\\f\\v B\\xECuY@ 	A\\0N@@ A\\xA0j  B\\0B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xBF\\x7F  B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\xFF?U!\\0 A\\x90j   )\\xA0  \\0A\\0N"\\x1B )\\xA8  \\x1B  	At"\\0r!	 B}! )\\x98! )\\x90! \\0A\\0N\\r\\0\\v\\v~A5 B\\xD2\\b|"\\xA7"\\0A\\0 \\0A\\0J\\x1B B5Y\\x1B"\\0A\\xF1\\0O@ A\\x80j  )\\x88! )\\x80!B\\0\\f\\v A\\xE0jD\\0\\0\\0\\0\\0\\0\\xF0?A\\x90 \\0k! A\\xD0j  )\\xD0! A\\xF0j )\\xE0 )\\xE8 )\\xD8"X )\\xF8! )\\xF0\\v! A\\xC0j 	 	AqE  B\\0B\\0"A\\0G \\0A Iqq"\\0r$ A\\xB0j   )\\xC0 )\\xC8 A\\x90j )\\xB0 )\\xB8   A\\xA0j  B\\0  \\0\\x1BB\\0  \\0\\x1B A\\x80j )\\xA0 )\\xA8 )\\x90 )\\x98 A\\xF0j )\\x80 )\\x88  : )\\xF0" )\\xF8"B\\0B\\0"E@A\\xD0\\xD8\\0A\\xC4\\x006\\0\\v A\\xE0j   \\xA7W )\\xE0! )\\xE8\\f\\vA\\xD0\\xD8\\0A\\xC4\\x006\\0 A\\xD0j  A\\xC0j )\\xD0 )\\xD8B\\0B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\0 A\\xB0j )\\xC0 )\\xC8B\\0B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\0 )\\xB0! )\\xB8\\v! \\f 7\\0 \\f 7\\b A\\xB0j$\\0 \\f)\\b! \\f)\\0!\\f\\v )pB\\0S\\r\\0  (Ak6\\v !\\rA\\0!#\\0A\\x90\\xC6\\0k"$\\0@\\x7F@ A0G@@ A.G\\r ("\\0 (hF\\r\\0  \\0Aj6 \\0-\\0\\0\\f\\v ("\\0 (hG\\x7F  \\0Aj6 \\0-\\0\\0 \\v!A!\\f\\v\\v \\v"A0F@@ B}!\\x7F ("\\0 (hG@  \\0Aj6 \\0-\\0\\0\\f\\v \\v"A0F\\r\\0\\vA!\\vA!\\v A\\x006\\x90 \\f~@@@ A.F"\\0 A0k"A	Mr@@@ \\0Aq@ E@ !A!\\f\\v E!\\0\\f\\v B|! \\x07A\\xFCL@ 	 \\xA7 A0F\\x1B!	 A\\x90j \\x07Atj"\\0 \\b\\x7F  \\0(\\0A
ljA0k \\v6\\0A!A\\0 \\bAj"\\0 \\0A	F"\\0\\x1B!\\b \\0 \\x07j!\\x07\\f\\v A0F\\r\\0  (\\x80FAr6\\x80FA\\xDC\\x8F!	\\v\\x7F ("\\0 (hG@  \\0Aj6 \\0-\\0\\0\\f\\v \\v"A.F"\\0 A0k"A
Ir\\r\\0\\v\\v   \\x1B! E A_qA\\xC5\\0GrE@@ Y"B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x7FR\\r\\0B\\0! )pB\\0S\\r\\0  (Ak6\\v  |!\\f\\v E!\\0 A\\0H\\r\\v )pB\\0S\\r\\0  (Ak6\\v \\0E\\r\\0A\\xD0\\xD8\\0A6\\0 <B\\0!B\\0\\f\\v (\\x90"\\0E@ D\\0\\0\\0\\0\\0\\0\\0\\0 \\r\\xB7\\xA6 )\\0! )\\b\\f\\v  R B	UrE@ A0j \\r A j \\0$ Aj )0 )8 )  )( )! )\\f\\v B\\x9AY@A\\xD0\\xD8\\0A\\xC4\\x006\\0 A\\xE0\\0j \\r A\\xD0\\0j )\\\` )hB\\x7FB\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xBF\\xFF\\xFF\\0 A@k )P )XB\\x7FB\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xBF\\xFF\\xFF\\0 )@! )H\\f\\v B\\xEBuW@A\\xD0\\xD8\\0A\\xC4\\x006\\0 A\\x90j \\r A\\x80j )\\x90 )\\x98B\\0B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\0 A\\xF0\\0j )\\x80 )\\x88B\\0B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\0 )p! )x\\f\\v \\b@ \\bA\\bL@ A\\x90j \\x07Atj"\\0(\\0!
@ 
A
l!
 \\bAj"\\bA	G\\r\\0\\v \\0 
6\\0\\v \\x07Aj!\\x07\\v@ 	A	N BUr \\xA7"\\b 	Hr\\r\\0 B	Q@ A\\xC0j \\r A\\xB0j (\\x90$ A\\xA0j )\\xC0 )\\xC8 )\\xB0 )\\xB8 )\\xA0! )\\xA8\\f\\v B\\bW@ A\\x90j \\r A\\x80j (\\x90$ A\\xF0j )\\x90 )\\x98 )\\x80 )\\x88 A\\xE0jA\\b \\bkAt(\\xC0= A\\xD0j )\\xF0 )\\xF8 )\\xE0 )\\xE8T )\\xD0! )\\xD8\\f\\v BYA\\0 (\\x90"\\0 \\bA}lA\\xD0\\0jv\\x1B\\r\\0 A\\xE0j \\r A\\xD0j \\0$ A\\xC0j )\\xE0 )\\xE8 )\\xD0 )\\xD8 A\\xB0j \\bAtA\\x98=j(\\0 A\\xA0j )\\xC0 )\\xC8 )\\xB0 )\\xB8 )\\xA0! )\\xA8\\f\\v@ \\x07"\\0Ak!\\x07 A\\x90j \\0Atj"Ak(\\0E\\r\\0\\vA\\0!	@ \\bA	o"E@A\\0!\\f\\v A	j  B\\0S\\x1B!@ \\0E@A\\0!A\\0!\\0\\f\\vA\\x80\\x94\\xEB\\xDCA\\0 kAtA\\xE0=j(\\0"m!\\x07A\\0!A\\0!A\\0!
@ A\\x90j 
Atj"  (\\0" n"j"6\\0 AjA\\xFFq  E  
Fq"\\x1B! \\bA	k \\b \\x1B!\\b \\x07   lkl! 
Aj"
 \\0G\\r\\0\\v E\\r\\0  6\\0 \\0Aj!\\0\\v \\b kA	j!\\b\\v@ A\\x90j Atj! \\bA$H!@@@ \\r\\0 \\bA$G\\r (\\0A\\xD0\\xE9\\xF9M\\r\\0A$!\\b\\f\\v \\0A\\xFFj!\\x07A\\0!@ \\0! \\xAD A\\x90j \\x07A\\xFFq"Atj"\\x005\\0B\\x86|"B\\x81\\x94\\xEB\\xDCT\\x7FA\\0 B\\x80\\x94\\xEB\\xDC\\x80"B\\x80\\xEC\\x94\\xA3|~ |! \\xA7\\v! \\0 >\\0     P\\x1B  F\\x1B  AkA\\xFFq"G\\x1B!\\0 Ak!\\x07  G\\r\\0\\v 	Ak!	 !\\0 E\\r\\0\\v AkA\\xFFq" \\0F@ A\\x90j" \\0A\\xFEjA\\xFFqAtj"\\0 \\0(\\0 At j(\\0r6\\0 !\\0\\v \\bA	j!\\b A\\x90j Atj 6\\0\\f\\v\\v@@ \\0AjA\\xFFq! A\\x90j \\0AkA\\xFFqAtj!@A	A \\bA-J\\x1B! \\bA$G!\\x07@@ !A\\0!
@@@  
jA\\xFFq" \\0F\\r\\0 A\\x90j Atj(\\0" 
At(\\xB0="I\\r\\0  K\\r 
Aj"
AG\\r\\v\\v \\x07\\r\\0A\\0!
B\\0!B\\0!@ \\0  
jA\\xFFq"F@ \\0AjA\\xFFq"\\0At jA\\x006\\x8C\\v A\\x80j A\\x90j Atj(\\0$ A\\xF0j  B\\0B\\x80\\x80\\x80\\x80\\xE5\\x9A\\xB7\\x8E\\xC0\\0 A\\xE0j )\\xF0 )\\xF8 )\\x80 )\\x88 )\\xE8! )\\xE0! 
Aj"
AG\\r\\0\\v A\\xD0j \\r A\\xC0j   )\\xD0 )\\xD8B\\0! )\\xC8! )\\xC0!A5 	A\\xA3	j"A\\0 A\\0J\\x1B 	A\\x92wN\\x1B"\\x07A\\xF0\\0M\\r\\f\\v 	 j!	  \\0"F\\r\\0\\vA\\x80\\x94\\xEB\\xDC v!A\\x7F tA\\x7Fs!A\\0!
 !@ A\\x90j" Atj" 
 (\\0"\\x07 vj"6\\0 AjA\\xFFq  E  Fq"\\x1B! \\bA	k \\b \\x1B!\\b \\x07 q l!
 AjA\\xFFq" \\0G\\r\\0\\v 
E\\r  G@ \\0At j 
6\\0 !\\0\\f\\v  (\\0Ar6\\0\\f\\v\\v\\v A\\x90jD\\0\\0\\0\\0\\0\\0\\xF0?A\\xE1 \\x07k! A\\xB0j )\\x90 )\\x98 X )\\xB8! )\\xB0! A\\x80jD\\0\\0\\0\\0\\0\\0\\xF0?A\\xF1\\0 \\x07k! A\\xA0j   )\\x80 )\\x88Q A\\xF0j   )\\xA0" )\\xA8": A\\xE0j   )\\xF0 )\\xF8 )\\xE8! )\\xE0!\\v 	A\\xF1\\0j!@ AjA\\xFFq" \\0F\\r\\0@ A\\x90j Atj(\\0"A\\xFF\\xC9\\xB5\\xEEM@ E AjA\\xFFq \\0Fq\\r A\\xF0j \\r\\xB7D\\0\\0\\0\\0\\0\\0\\xD0?\\xA2 A\\xE0j   )\\xF0 )\\xF8 )\\xE8! )\\xE0!\\f\\v A\\x80\\xCA\\xB5\\xEEG@ A\\xD0j \\r\\xB7D\\0\\0\\0\\0\\0\\0\\xE8?\\xA2 A\\xC0j   )\\xD0 )\\xD8 )\\xC8! )\\xC0!\\f\\v \\r\\xB7! \\0 AjA\\xFFqF@ A\\x90j D\\0\\0\\0\\0\\0\\0\\xE0?\\xA2 A\\x80j   )\\x90 )\\x98 )\\x88! )\\x80!\\f\\v A\\xB0j D\\0\\0\\0\\0\\0\\0\\xE8?\\xA2 A\\xA0j   )\\xB0 )\\xB8 )\\xA8! )\\xA0!\\v \\x07A\\xEF\\0K\\r\\0 A\\xD0j  B\\0B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF?Q )\\xD0 )\\xD8B\\0B\\0"\\r\\0 A\\xC0j  B\\0B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF? )\\xC8! )\\xC0!\\v A\\xB0j     A\\xA0j )\\xB0 )\\xB8  : )\\xA8! )\\xA0!@ A\\xFC\\xFF\\xFF\\xFF\\x07qA\\xFC\\x07I@ 	!\\0\\f\\v  B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\0\\x837\\x98  7\\x90 A\\x80j  B\\0B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\xFF? )\\x90 )\\x98B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\xB8\\xC0\\0U! )\\x88  A\\0N"\\0\\x1B! )\\x80  \\0\\x1B!  \\x07G A\\0Hr 	A\\x92wHq  B\\0B\\0"A\\0GqE \\0 	j"\\0A\\x8F\\x07Lq\\r\\0A\\xD0\\xD8\\0A\\xC4\\x006\\0\\v A\\xF0j   \\0W )\\xF0! )\\xF8\\v7 \\f 7 A\\x90\\xC6\\0j$\\0 \\f)! \\f)!\\v \\v 7\\0 \\v 7\\b \\fA0j$\\0  \\v\\xFD\\0\\0\\xFD\\v\\0 \\vA\\xA0j$\\0 )\\0! )\\b!#\\0A k"\\v$\\0 B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?\\x83!~ B0\\x88B\\xFF\\xFF\\x83"\\xA7"A\\x81\\xF8\\0kA\\xFDM@ B\\x86 B<\\x88\\x84! A\\x80\\xF8\\0k\\xAD!@ B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\x83"B\\x81\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\bZ@ B|!\\f\\v B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\bR\\r\\0 B\\x83 |!\\vB\\0  B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\x07V"\\0\\x1B! \\0\\xAD |\\f\\v  \\x84P B\\xFF\\xFFRrE@ B\\x86 B<\\x88\\x84B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x84!B\\xFF\\f\\v A\\xFE\\x87K@B\\0!B\\xFF\\f\\vA\\x80\\xF8\\0A\\x81\\xF8\\0 P"\\x1B"\\0 k"A\\xF0\\0J@B\\0!B\\0\\f\\v  B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\0\\x84 \\x1B!A\\0! \\0 G@ \\vAj  A\\x80 k \\v) \\v)\\x84B\\0R!\\v \\v   % \\v)\\bB\\x86 \\v)\\0"B<\\x88\\x84!@ \\xAD B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\x83\\x84"B\\x81\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\bZ@ B|!\\f\\v B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\bR\\r\\0 B\\x83 |!\\v B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\b\\x85  B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\x07V"\\0\\x1B! \\0\\xAD\\v! \\vA j$\\0 Aj$\\0 B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x7F\\x83 B4\\x86\\x84 \\x84\\xBF\\v\\x91\\x7F~#\\0Ak"$\\0@@ \\0($E\\r\\0 \\0(( AtO\\r\\0 \\0A\\x7F6(\\f\\v E@A!\\f\\v@ \\0(E@@ A\\x07M\\r\\0@@ \\0(" \\0(\\bI@ \\0 Aj6  \\0(\\0 Atj)\\0"B8\\x86 B\\x80\\xFE\\x83B(\\x86\\x84 B\\x80\\x80\\xFC\\x07\\x83B\\x86 B\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 B\\b\\x88B\\x80\\x80\\x80\\xF8\\x83 B\\x88B\\x80\\x80\\xFC\\x07\\x83\\x84 B(\\x88B\\x80\\xFE\\x83 B8\\x88\\x84\\x84\\x847\\0\\0 A\\bk! A\\bj! \\0($E\\r \\0 \\0((A@j6(\\f\\v \\0.\\r\\0A\\0!\\f\\v A\\x07K\\r\\0\\v \\r\\0A!\\f\\v@ \\0 A\\fjA\\b\\fE@A\\0!\\f\\v  (\\f:\\0\\0A! Aj! Ak"\\r\\0\\v\\f\\v \\0 A\\fjA\\b\\fE@A\\0!\\f\\v  (\\f:\\0\\0A! Aj! Ak"\\r\\0\\v\\v Aj$\\0 \\v\\xA8\\x7F@ \\0(\\0"E \\0(\\b IrE@A! \\0(\\r\\v A t"" AKrE@ 	 \\0A\\x006\\0A\\0\\v \\0 6\\0A\\0! E\\r\\0 \\0(" " AKrE@ 	 \\0A\\x006A\\0\\v \\0 6 E\\r\\0 @ A\\0 \\xFC\\v\\0\\v \\0 6\\bA!\\v \\v\\xC8\\x7F@@@ \\0(" \\0(" AvjAjK\\r\\0 \\0( AtjA?jAv j" M\\r\\0 A\\x81\\x80\\x80K\\r \\0(\\0 Av" j   k I\\x1B"\\x7F A\\xFF\\xFF\\xFF\\xFFK\\r AtA\\0\\v"E\\r \\0 6 \\0 6\\0\\vA! E\\rA\\0!@ \\0  j-\\0\\0A\\b\\vE\\r  Aj"G\\r\\0\\v\\f\\vA\\0!\\v \\v\\xCE~\\x7F#\\0Ak"$\\0 \\xBD"B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\x07\\x83! \\0~ B4\\x88B\\xFF\\x83"PE@ B\\xFFR@ B\\x88! B\\x80\\xF8\\0|! B<\\x86\\f\\v B\\x88!B\\xFF\\xFF! B<\\x86\\f\\v P@B\\0!B\\0\\f\\v  B\\0 y\\xA7"\\x07A1j )\\bB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\0\\x85!A\\x8C\\xF8\\0 \\x07k\\xAD! )\\0\\v7\\0 \\0 B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x7F\\x83 B0\\x86\\x84 \\x847\\b Aj$\\0\\v\\xAB|\\x7F~|@ \\0*A\\xFFq"D\\0\\0\\0\\0\\0\\0\\x90<*"kD\\0\\0\\0\\0\\0\\0\\x80@* kI@ !\\f\\v  K@ \\0D\\0\\0\\0\\0\\0\\0\\xF0?\\xA0\\vA\\0!D\\0\\0\\0\\0\\0\\0\\x90@* K\\r\\0D\\0\\0\\0\\0\\0\\0\\0\\0 \\0\\xBD"\\x07B\\x80\\x80\\x80\\x80\\x80\\x80\\x80xQ\\rD\\0\\0\\0\\0\\0\\0\\xF0\\x7F* M@ \\0D\\0\\0\\0\\0\\0\\0\\xF0?\\xA0\\v \\x07B\\0S@D\\0\\0\\0\\0\\0\\0\\0V\\vD\\0\\0\\0\\0\\0\\0\\0pV\\v \\0A\\x80\\b+\\0\\xA2A\\x88\\b+\\0"\\xA0" \\xA1"A\\x98\\b+\\0\\xA2 A\\x90\\b+\\0\\xA2 \\0\\xA0\\xA0" \\xA2"\\0 \\0\\xA2 A\\xB8\\b+\\0\\xA2A\\xB0\\b+\\0\\xA0\\xA2 \\0 A\\xA8\\b+\\0\\xA2A\\xA0\\b+\\0\\xA0\\xA2 \\xBD"\\x07\\xA7AtA\\xF0q"+\\xF0\\b \\xA0\\xA0\\xA0! )\\xF8\\b \\x07B-\\x86|!\\b E@| \\x07B\\x80\\x80\\x80\\x80\\b\\x83P@ \\bB\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x88?}\\xBF"\\0 \\xA2 \\0\\xA0D\\0\\0\\0\\0\\0\\0\\0\\x7F\\xA2\\f\\v \\bB\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\xF0?|\\xBF" \\xA2" \\xA0"D\\0\\0\\0\\0\\0\\0\\xF0?c|#\\0Ak" B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\b7\\b +\\bD\\0\\0\\0\\0\\0\\0\\0\\xA29\\bD\\0\\0\\0\\0\\0\\0\\0\\0 D\\0\\0\\0\\0\\0\\0\\xF0?\\xA0"\\0   \\xA1\\xA0 D\\0\\0\\0\\0\\0\\0\\xF0? \\0\\xA1\\xA0\\xA0\\xA0D\\0\\0\\0\\0\\0\\0\\xF0\\xBF\\xA0"\\0 \\0D\\0\\0\\0\\0\\0\\0\\0\\0a\\x1B \\vD\\0\\0\\0\\0\\0\\0\\0\\xA2\\v\\v \\b\\xBF"\\0 \\xA2 \\0\\xA0\\v\\v\\xE7\\x7F#\\0Ak"$\\0@@@ \\0($E\\r\\0 \\0(( AtO\\r\\0 \\0A\\x7F6(\\f\\vA! E\\r@ \\0(E@@ A\\x07M\\r\\0@@ \\0(" \\0(\\bI@ \\0 Aj6 A\\bk! \\0($E\\r \\0 \\0((A@j6(\\f\\v \\0.E\\r\\v A\\x07K\\r\\0\\v \\r\\0\\f\\v@ \\0 A\\fjA\\b\\fE\\r Ak"\\r\\0\\v\\f\\v \\0 A\\fjA\\b\\fE\\r Ak"\\r\\0\\v\\f\\vA\\0!\\v Aj$\\0 \\v\\xB9\\x7F~@@ E\\r\\0@ \\0(" \\0(" jK\\r\\0  \\0(jA?jAv j" M\\r\\0 A\\x81\\x80\\x80K@A\\0\\v \\0(\\0 Av" j   k I\\x1B"\\x7F A\\xFF\\xFF\\xFF\\xFFK@A\\0\\v AtA\\0\\v"E\\r \\0 6 \\0 6\\0\\v \\0("@ \\0 A\\xC0\\0 k"   K\\x1B"j"6 \\0 \\0)\\b \\xAD\\x86"7\\b A\\xC0\\0G\\r \\0 \\0("Aj6 \\0(\\0 Atj B8\\x86 B\\x80\\xFE\\x83B(\\x86\\x84 B\\x80\\x80\\xFC\\x07\\x83B\\x86 B\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 B\\b\\x88B\\x80\\x80\\x80\\xF8\\x83 B\\x88B\\x80\\x80\\xFC\\x07\\x83\\x84 B(\\x88B\\x80\\xFE\\x83 B8\\x88\\x84\\x84\\x847\\0 \\0A\\x006  k!\\v A\\xC0\\0O@ \\0(! A@jAv"AtA\\bj"@ \\0(\\0 AtjA\\0 \\xFC\\v\\0\\v \\0  jAj6 A?q!\\v E\\r\\0 \\0 6 \\0B\\x007\\b\\vA!\\v \\v\\xD0\\x7F \\0 ("\\v ( "\\x07 (0"\\f (\\0"	 ($" (4" (" ("     \\f \\x07 \\v 	 \\0(\\0"j \\0(" \\0(\\f" \\0(\\b"sq sjA\\x88\\xB7\\xD5\\xC4kA\\x07w j"j  (\\f"j  (\\b"j  j   sq sjA\\xAA\\x91\\xE1\\xB9kA\\fw j"\\b  sq sjA\\xDB\\xE1\\x81\\xA1jAw \\bj"  \\bsq sjA\\x92\\xE2\\x88\\xF2kAw j"  \\bsq \\bsjA\\xD1\\xE0\\x8F\\xD4\\0kA\\x07w j"j ("\\r j (" j \\b j   sq sjA\\xAA\\x8C\\x9F\\xBCjA\\fw j"  sq sjA\\xED\\xF3\\xBE\\xBEkAw j"  sq sjA\\xFF\\xD5\\xE5kAw j"  sq sjA\\xD8\\xB1\\x82\\xCCjA\\x07w j"j (," j (("\\b j  j   sq sjA\\xD1\\x90\\xEC\\xA5\\x07kA\\fw j"
  sq sjA\\xCF\\xC8kAw 
j"  
sq sjA\\xC2\\xD0\\x8C\\xB5\\x07kAw j"  
sq 
sjA\\xA2\\xA2\\xC0\\xDCjA\\x07w j"j (<" j (8" j 
 j   sq sjA\\xED\\x9C\\x9EkA\\fw j"  sq sjA\\xF2\\xF8\\x9A\\xCCkAw j"  sq sjA\\xA1\\x90\\xD0\\xCDjAw j" s q sjA\\x9E\\xB5\\x87\\xCF\\0kAw j"j  	j  j  j  s q sjA\\xC0\\x99\\xFD\\xFDkA	w j" s q sjA\\xD1\\xB4\\xF9\\xB2jAw j" s q sjA\\xD6\\xF0\\xA4\\xB2kAw j" s q sjA\\xA3\\xDF\\xC3\\xCEkAw j"j  \\vj  j  \\bj  s q sjA\\xD3\\xA8\\x90jA	w j" s q sjA\\xFF\\xB2\\xF8\\xBAkAw j" s q sjA\\xB8\\x88\\xB0\\xC1kAw j" s q sjA\\xE6\\x9B\\x87\\x8FjAw j"j  \\x07j   j   j  s q sjA\\xAA\\xF0\\xA3\\xE6kA	w j" sq sjA\\xF9\\xE4\\xAB\\xD9\\0kAw j" sq sjA\\xED\\xA9\\xE8\\xAAjAw j"
 s q sjA\\xFB\\xAD\\xF0\\xB0kAw 
j"j  \\rj  j  
s q 
sjA\\x88\\xB8\\xC1kA	w j" s 
q sjA\\xD9\\x85\\xBC\\xBBjAw j" s" 
 \\fj  q sjA\\xF6\\xE6\\xD6\\x96\\x07kAw j"sjA\\xBE\\x8DkAw j"j  j  \\x07j  s sjA\\xFF\\x92\\xB8\\xC4\\x07kA\\vw j"  ssjA\\xA2\\xC2\\xF5\\xECjAw j"\\x07 s  j  s \\x07sjA\\xF4\\x8F\\xEBkAw \\x07j"sjA\\xBC\\xAB\\x84\\xDAkAw j"j \\x07 \\rj  \\vj  \\x07s sjA\\xA9\\x9F\\xFB\\xDEjA\\vw j"\\v  ssjA\\xA0\\xE9\\x92\\xCA\\0kAw \\vj"\\x07 \\vs  \\bj  \\vs \\x07sjA\\x90\\x87\\x81\\x8AkAw \\x07j"sjA\\xC6\\xFD\\xED\\xC4jAw j"j \\x07 j 	 \\vj  \\x07s sjA\\x86\\xB0\\xFB\\xAAkA\\vw j"\\x07  ssjA\\xFB\\x9E\\xC3\\xD8kAw \\x07j"	 \\x07s  j  \\x07s 	sjA\\x85\\xBA\\xA0$jAw 	j"sjA\\xC7\\xDF\\xAC\\xB1kAw j"j  j \\x07 \\fj  	s sjA\\x9B\\xCC\\x91\\xC9kA\\vw j"\\f s  	j  s \\fsjA\\xF8\\xF9\\x89\\xFDjAw \\fj"	sjA\\x9B\\xD3\\xCE\\xDAkAw 	j" \\fA\\x7Fsr 	sjA\\xBC\\xBB\\xDB\\xDE\\0kAw j"j  j  	j \\f \\rj  	A\\x7Fsr sjA\\x97\\xFF\\xAB\\x99jA
w j"\\r A\\x7Fsr sjA\\xD9\\xB8\\xAF\\xA3kAw \\rj" A\\x7Fsr \\rsjA\\xC7\\xBF\\xB1\\x1BkAw j" \\rA\\x7Fsr sjA\\xC3\\xB3\\xED\\xAAjAw j"j  j  \\bj \\r j  A\\x7Fsr sjA\\xEE\\xE6\\xCC\\x87\\x07kA
w j"\\b A\\x7Fsr sjA\\x83\\x97\\xC0\\0kAw \\bj" A\\x7Fsr \\bsjA\\xAF\\xC4\\xEE\\xD3\\x07kAw j" \\bA\\x7Fsr sjA\\xCF\\xFC\\xA1\\xFDjAw j"j  j  j  \\bj  A\\x7Fsr sjA\\xA0\\xB2\\xCCkA
w j" A\\x7Fsr sjA\\xEC\\xF9\\xFA\\xE7kAw j" A\\x7Fsr sjA\\xA1\\xA3\\xA0\\xF0jAw j" A\\x7Fsr sjA\\xFE\\x82\\xB2\\xC5\\0kAw j" j6\\0 \\0   j  A\\x7Fsr sjA\\xCB\\x9B\\x94\\x96kA
w j"j6\\f \\0   j  A\\x7Fsr sjA\\xBB\\xA5\\xDF\\xD6jAw j"j6\\b \\0  j  j  A\\x7Fsr sjA\\xEF\\xD8\\xE4\\xA3kAwj6\\v\\xA8\\0@ A\\x80\\bN@ \\0D\\0\\0\\0\\0\\0\\0\\xE0\\x7F\\xA2!\\0 A\\xFFI@ A\\xFF\\x07k!\\f\\v \\0D\\0\\0\\0\\0\\0\\0\\xE0\\x7F\\xA2!\\0A\\xFD  A\\xFDO\\x1BA\\xFEk!\\f\\v A\\x81xJ\\r\\0 \\0D\\0\\0\\0\\0\\0\\0\\\`\\xA2!\\0 A\\xB8pK@ A\\xC9\\x07j!\\f\\v \\0D\\0\\0\\0\\0\\0\\0\\\`\\xA2!\\0A\\xF0h  A\\xF0hM\\x1BA\\x92j!\\v \\0 A\\xFF\\x07j\\xADB4\\x86\\xBF\\xA2\\v\\xDB\\x7F~A!@ \\0B\\0R B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\0\\x83"B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0V B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0Q\\x1B\\r\\0 B\\0R B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\0\\x83"B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0V B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0Q\\x1B\\r\\0 \\0 \\x84  \\x84\\x84P@A\\0\\v  \\x83B\\0Y@ \\0 T  S  Q\\x1B@A\\x7F\\v \\0 \\x85  \\x85\\x84B\\0R\\v \\0 V  U  Q\\x1B@A\\x7F\\v \\0 \\x85  \\x85\\x84B\\0R!\\v \\v\\xEC\\x7F !@ \\0Aq@@ \\0-\\0\\0"E  A\\xFFqFr\\r \\0Aj"\\0Aq\\r\\0\\v\\v@@A\\x80\\x82\\x84\\b \\0(\\0"k rA\\x80\\x81\\x82\\x84xqA\\x80\\x81\\x82\\x84xG\\r\\0 A\\x81\\x82\\x84\\bl!@A\\x80\\x82\\x84\\b  s"k rA\\x80\\x81\\x82\\x84xqA\\x80\\x81\\x82\\x84xG\\r \\0(! \\0Aj"!\\0 A\\x80\\x82\\x84\\b krA\\x80\\x81\\x82\\x84xqA\\x80\\x81\\x82\\x84xF\\r\\0\\v\\f\\v \\0!\\v@ "\\0-\\0\\0"E\\r \\0Aj!  A\\xFFqG\\r\\0\\v\\v \\0A\\0 \\0-\\0\\0 A\\xFFqF\\x1B\\vf\\x7F~#\\0Ak"$\\0 \\0~ E@B\\0\\f\\v  \\xADB\\0A\\xF0\\0 g"Ask )\\bB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\0\\x85A\\x9E\\x80 k\\xADB0\\x86|! )\\0\\v7\\0 \\0 7\\b Aj$\\0\\vP~@ A\\xC0\\0q@  A@j\\xAD\\x88!B\\0!\\f\\v E\\r\\0 A\\xC0\\0 k\\xAD\\x86  \\xAD"\\x88\\x84!  \\x88!\\v \\0 7\\0 \\0 7\\b\\vK| \\0 \\0 \\0\\xA2"\\xA2"  \\xA2\\xA2 D\\xA7F;\\x8C\\x87\\xCD\\xC6>\\xA2Dt\\xE7\\xCA\\xE2\\xF9\\0*\\xBF\\xA0\\xA2  D\\xB2\\xFBn\\x89\\x81?\\xA2Dw\\xAC\\xCBTUU\\xC5\\xBF\\xA0\\xA2 \\0\\xA0\\xA0\\xB6\\v\\b\\0 \\0 B\\v9\\x7F@ A?MA\\0 B \\x88\\xA7" A k"v\\x1B\\r\\0 \\0  \\vE\\r\\0 \\0 \\xA7A \\v!\\v \\v\\xA6\\xD0\\x7F\\r~{#\\0Ak"$\\0 (\\x90J Aj 5! \\0(\\0!\\b@ E@ \\bA\\b6\\0\\f\\v (\\0!\\x1B (!@ \\b(E\\r\\0 \\0("\\b \\x1B6\\xAC
 \\b 6\\xA4
 \\b(\\xF4	E@ \\bA6\\xF8	\\f\\v \\b(\\xF0	!\\b#\\0A\\xF0\\x1Bk"\\f$\\0 \\fA\\xD8\\0j! @@@@@@@ \\b(\\0(\\0\\v\\0\\vA\\0!A!\\x7F@\\x7F@ \\b("
(\\x98$@ \\f 
-\\0\\xDA$"6 
A\\x006\\x98$\\f\\v 
(, \\fAjA\\b\\fE\\r	 \\f(!\\v@  -\\0\\x80F\\r\\0@ A\\xC9\\0G\\r\\0@ \\b("(\\x98$@ \\f -\\0\\xDA$"6 A\\x006\\x98$\\f\\v (, \\fAjA\\b\\fE\\r\\v \\f(!\\vA\\0! A\\xC4\\0G@ A\\xE6\\0G\\r\\f\\v@ \\b("
(\\x98$@ \\f 
-\\0\\xDA$"6 
A\\x006\\x98$\\f\\v 
(, \\fAjA\\b\\fE\\r\\v \\f(!\\v A\\xE6\\0F\\r A3G\\r\\0 \\b((, \\fA0j"A\\fE\\r
 \\b((, A\\b\\fE\\r
 \\f(0! \\b((, A\\b\\fE\\r
 \\f(0!
 \\b((, A\\b\\fE\\r
 \\f(0!\\x07 \\b((, A\\b\\fE\\r
 \\b((, \\f(0A\\xFF\\0q \\x07A\\x07tA\\x80\\xFF\\0q 
A\\xFF\\0q A\\x07tA\\x80\\xFF\\0qrAtrrE\\r
@ \\b("(\\x98$@ \\f -\\0\\xDA$"
6 A\\x006\\x98$\\f\\v (, \\fAjA\\b\\fE\\r\\v \\f(!
\\v 
A\\xE6\\0F\\r\\f
\\v@ A\\xFFG\\r\\0 \\b(A\\xFF:\\0\\xD8$ \\b((, \\fAjA\\b\\fE\\r
 \\f("A\\xFFF@ \\b("A6\\x98$ A\\xFF:\\0\\xDA$\\f\\v A~qA\\xF8G\\r\\0 \\b( :\\0\\xD9$A\\f\\vA\\0!A\\0 E\\rA\\0 \\b("(\\x84%\\r A6\\xDCA \\bA\\0 ($ ( \\0\\0A\\0\\f\\v Aj!A\\v! AI\\r\\0\\vA\\v! \\b(\\0 6\\0\\f\\v \\b("A\\x006t -\\0\\xD9$! -\\0\\xD8$!
 (," )7  
At/\\x90"
A\\btA\\x80\\xFEq  
A\\bvsAt/\\x90s6 \\f -\\0\\xD8$:\\x000 \\f -\\0\\xD9$"
:\\x001  \\fA\\xEC\\x1Bj"A\\b\\fE\\r@@ \\f(\\xEC\\x1B"A\\xFFF\\r\\0 \\f :\\x002 \\b((, A\\b\\fE\\r \\f(\\xEC\\x1B"A\\xFFF\\r\\0 
AvAq! \\f :\\x003A!@@@@@@ AvAq"\\vAk\\0\\v \\b(A\\xC06\\xE8\\b\\f\\v \\b(A\\x90 \\vt6\\xE8\\b\\f\\v \\b(A \\vt6\\xE8\\b\\vA\\0!\\v\\v !\\v@@\\x7F@@@@@@@@@@@@@@ Aq"\\x07Ak\\x07\\b	
\\v\\f\\0\\v \\b("(\\xF0\\r\\fA!\\f\\v \\b(!A\\x88\\xB1\\f\\f\\v \\b(!A\\x90\\xE2
\\f\\v\\v \\b(!A\\x80\\xDC\\v\\f
\\v \\b(!A\\xC0>\\f	\\v \\b(!A\\x80\\xFD\\0\\f\\b\\v \\b(!A\\xA2\\xAC\\f\\x07\\v \\b(!A\\xC0\\xBB\\f\\v \\b(!A\\x80\\xFA\\f\\v \\b(!A\\xC4\\xD8\\f\\v \\b(!A\\x80\\xF7\\f\\v \\b(!A\\x80\\xEE\\f\\v \\b("(\\x84%\\r A6\\xDCA \\bA ($ ( \\0\\0\\f\\v (\\x98\\v!  6\\xEC\\b\\vA\\0!\\x07\\v Av!\\r@@ \\xC0A\\0H@ \\b("A6\\xF0\\bA!	A\\0!@@ \\rA\\x07q\\0\\vA!	\\f\\vA!	\\f\\v \\b(" \\rA\\x07qAj6\\xF0\\bA\\0!	\\v  	6\\xF4\\b E!\\v \\f AvA\\x07q"	6\\xEC\\x1BA\\0!\\rA\\b!@@@@@@@@ 	Ak\\x07\\x07\\0\\v (\\xF0E\\r (\\xA0!\\f\\vA\\f!\\f\\vA!\\f\\vA!\\f\\vA!\\f\\vA !\\v  6\\xF8\\b !\\r\\v@@ 
AqE@ (\\xF0E\\r (\\x88 (\\x8CF\\r\\v (," \\fAjA\\b\\fE\\r\\b \\f \\f(":\\x004@ A\\x80q@@\\x7F A\\xE0qA\\xC0F@A!
 Aq\\f\\v A\\xF0qA\\xE0F@A!
 Aq\\f\\v A\\xF8qA\\xF0F@A!
 A\\x07q\\f\\v A\\xFCqA\\xF8F@A!
 Aq\\f\\v A\\xFEqA\\xFCF@A!
 Aq\\f\\vA! A\\xFEG\\rA!
A\\0\\v\\xAD!#A!@  \\fAjA\\b\\fE\\r\\f \\fA0j j \\f(":\\0\\0 Aj! A\\xC0qA\\x80G\\r A?q\\xAD #B\\x86\\x84!# 
Ak"
\\r\\0\\v #B\\x7FR\\r\\v  \\fj-\\0/! \\b("A6\\x98$  :\\0\\xDA$ (\\x84%\\r A6\\xDCA \\bA ($ ( \\0\\0\\f\\v \\xAD!#A!\\v \\b(" #7\\x80	 A6\\xFC\\b\\f\\v (,"	 \\fAjA\\b\\fE\\r\\x07 \\f \\f(":\\x004@ A\\x80qE@ \\f 6\\xEC\\x1BA!\\f\\v@@\\x7F A\\xE0qA\\xC0F@A!A\\f\\v A\\xF0qA\\xE0F@A!A\\f\\v A\\xF8qA\\xF0F@A!A\\x07\\f\\v A\\xFCqA\\xF8F@A!A\\f\\vA! A\\xFEqA\\xFCG@A!\\f\\vA\\v q!A!@ 	 \\fAjA\\b\\fE\\r\\v \\fA0j j \\f("
:\\0\\0 Aj! 
A\\xC0qA\\x80G\\r 
A?q Atr! Ak"\\r\\0\\v \\f 6\\xEC\\x1B A\\x7FG\\r\\f\\v \\fA\\x7F6\\xEC\\x1B\\v  \\fj-\\0/! \\b("A6\\x98$  :\\0\\xDA$ (\\x84%\\r A6\\xDCA \\bA ($ ( \\0\\0\\f\\v \\b(" 6\\x80	 A\\x006\\xFC\\b\\v \\b(!@@@ \\v@ (, \\fA\\xEC\\x1BjA\\b\\fE\\r
 \\fA0j" j \\f(\\xEC\\x1B"
:\\0\\0 Aj! \\vA\\x07F@ \\b((, \\fAjA\\b\\fE\\r\\v  j \\f(":\\0\\0 \\f  
A\\btr"
6\\xEC\\x1B Aj!\\v \\b(" 
Aj"6\\xE8\\b A\\x80\\x80O\\r !\\v \\x07\\r !\\v\\f\\v  \\fj-\\0/! A6\\x98$  :\\0\\xDA$ (\\x84%\\r A6\\xDCA \\bA ($ ( \\0\\0\\f\\v (, \\fA\\xEC\\x1BjA\\b\\fE\\r\\x07 \\fA0j" j \\f(\\xEC\\x1B"
:\\0\\0 Aj!\\v@@@ \\x07A\\fF\\r\\0 \\b((, \\fAjA\\b\\fE\\r
  \\vj \\f(":\\0\\0 \\f  
A\\btr"
6\\xEC\\x1B Aj!\\v \\x07A\\fk\\0\\v 
A\\xE8\\x07l!
\\f\\v 
A
l!
\\v \\b(" 
6\\xEC\\b\\v (, \\fA\\xEC\\x1BjA\\b\\fE\\r@ \\vE@A\\0!\\f\\v \\vAq! \\fA0j!A\\0!
A\\0! \\vAO@\\x7F \\f-\\x003 \\f-\\x002 \\f-\\x001 \\f-\\x000-\\0\\x80\\x1Bs-\\0\\x80\\x1Bs-\\0\\x80\\x1Bs-\\0\\x80\\x1B" \\vA|q"AF\\r\\0 \\f-\\x007 \\f-\\x006 \\f-\\x005 \\f-\\x004 s-\\0\\x80\\x1Bs-\\0\\x80\\x1Bs-\\0\\x80\\x1Bs-\\0\\x80\\x1B" A\\bF\\r\\0 \\f-\\0; \\f-\\0: \\f-\\x009 \\f-\\x008 s-\\0\\x80\\x1Bs-\\0\\x80\\x1Bs-\\0\\x80\\x1Bs-\\0\\x80\\x1B\\v! E\\r \\fA0j j!\\v@ -\\0\\0 A\\xFFqs-\\0\\x80\\x1B! Aj! 
Aj"
 G\\r\\0\\v\\v \\b(! A\\xFFq \\f(\\xEC\\x1BA\\xFFqG@ (\\x84%\\r A6\\xDCA \\bA ($ ( \\0\\0\\f\\v A\\x006\\xE4@@@ (\\xFC\\b\\r\\0 A6\\xFC\\b (\\x80	! (\\xE0"@  \\xAD \\xAD~7\\x80	\\f\\v (\\xF0@ (\\x88" (\\x8CG\\r  \\xAD \\xAD~7\\x80	 \\b(" (\\x8C6\\xE4\\f\\v E@ B\\x007\\x80	 \\b(" (\\xE8\\b6\\xE4\\f\\v  5\\xE8\\b \\xAD~7\\x80	\\v AqE \\rq\\r \\b(!\\v (\\x84%E@ A6\\xDCA \\bA ($ ( \\0\\0\\f\\v  (\\xD0AAj6\\xD0A\\f\\v \\b(\\0(\\0AF\\r \\b("(\\xF8\\b!\\x07 (\\xF0\\b!@@@ (\\xE8\\b" (\\xD8K\\r\\0  (\\xDCK\\r\\0 \\x07A I\\r (p\\r\\v (0"
@ 
Ak	 \\b("A\\x0060\\v (\\xDC$"
@ 
	 \\b("A\\x006\\xDC$ A\\x006P\\v (4"
@ 
Ak	 \\b("A\\x0064\\v (\\xE0$"
@ 
	 \\b("A\\x006\\xE0$ A\\x006T\\v (8"
@ 
Ak	 \\b("A\\x0068\\v (\\xE4$"
@ 
	 \\b("A\\x006\\xE4$ A\\x006X\\v (<"
@ 
Ak	 \\b("A\\x006<\\v (\\xE8$"
@ 
	 \\b("A\\x006\\xE8$ A\\x006\\\\\\v (@"
@ 
Ak	 \\b("A\\x006@\\v (\\xEC$"
@ 
	 \\b("A\\x006\\xEC$ A\\x006\\\`\\v (D"
@ 
Ak	 \\b("A\\x006D\\v (\\xF0$"
@ 
	 \\b("A\\x006\\xF0$ A\\x006d\\v (H"
@ 
Ak	 \\b("A\\x006H\\v (\\xF4$"
@ 
	 \\b("A\\x006\\xF4$ A\\x006h\\v (L"
@ 
Ak	 \\b("A\\x006L\\v (\\xF8$"
@ 
	 \\b("A\\x006\\xF8$ A\\x006l\\v (p"
@ 
	 \\b("A\\x006p\\v (\\xD8"   K\\x1B!
@@ @ 
A\\xFB\\xFF\\xFF\\xFFK\\r 
At"Aj!\\vA  AM\\x1B!\\rA\\0!@ \\v\\r"E\\r \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\0 \\b( Atj"	 Aj60 \\r\\r"E\\r 	A\\xDC$j"(\\0"@ 	\\v  6\\0 	 6P Aj" G\\r\\0\\v\\v \\x07A G@ \\b(!\\f\\v@ 
\\x7F 
A\\x80\\x80\\x80\\x80O@ \\b(A\\x006p\\f\\v 
AtA\\v\\r! \\b(" 6p \\r\\v \\b(\\0A\\b6\\0\\f
\\v \\b(\\0A\\b6\\0\\f	\\v  6\\xDC  
6\\xD8 (\\xF0\\b!\\vA\\0!
@@@@@@ E@ \\b(\\0"	(\\0!\\f\\v@ (\\xF8\\b!@@@@ (\\xF4\\bAk\\0\\v  
AFj!\\f\\v  
Ej!\\f\\v  
AFj!\\v (, \\fA\\xE8\\x1BjA\\b\\fE\\r \\f \\f(\\xE8\\x1B"A\\xFEq"\\x076\\xE8\\x1B@ Aq"@ \\b((, \\fA0j2E\\r \\b(" 
A\\xB0lj \\f(0Aj"	6\\xB8\\f  	M@ (\\x84%E@ A6\\xDCA \\bA\\0 ($ ( \\0\\0\\vA! \\b(\\0"	A6\\0\\f\\v  	k!\\f\\v \\b(" 
A\\xB0ljA\\x006\\xB8\\f\\v@@ A\\x80q@ (\\x84%\\r A6\\xDCA \\bA\\0 ($ ( \\0\\0\\f\\v@@@@@@ \\x07\\0\\v  
A\\xB0lj"A\\x006\\x90	 E\\r
 (,!~ A!O@  \\fA0j A k\\fE\\r\\f  \\fAjA \\fE\\r\\f \\f5 \\f50B \\x86\\x84\\f\\v  \\fAj \\fE\\r\\v \\f5\\v!#  #B Ak\\xAD\\x86B\\0 A\\xC0\\0M\\x1B"$\\x85 $}"#7\\x98	 \\b(! A M@ (\\xE8\\bE\\r  
Atj(0!\\x07 #\\xA7!	A\\0!@ \\x07 Atj 	6\\0 Aj" (\\xE8\\bI\\r\\0\\v\\f\\v A6t (p!	A\\0!@@ (\\xE8\\b"\\x07\\0\\v \\x07A~q! #\\xFD!0A\\0!@ 	 Atj 0\\xFD\\v\\0 Aj" G\\r\\0\\v  \\x07F\\r\\v@ 	 Atj #7\\0 Aj" \\x07G\\r\\0\\v\\f\\v  
A\\xB0lj"A6\\x90	 A\\x90	j!\\x07 A M@ \\x07  
At"\\rj(P"\\v6\\bA\\0! \\x07A\\x006\\f \\b("(\\xE8\\b@A Akt!	@ E\\r\\f (, \\fA0j \\fE\\r\\f \\v Atj \\f(0 	s 	k6\\0 Aj" \\b("(\\xE8\\b"I\\r\\0\\v \\x07(\\b!\\v At!\\v E\\r  \\rj(0 \\v \\xFC
\\0\\0 \\r\\f\\v \\x07 (p"	6\\b \\x07A6\\f \\b("A6t (\\xE8\\bE\\r\\0B Ak\\xAD\\x86B\\0 A\\xC0\\0M\\x1B!# A k!\\x07A\\0!@ (," \\fA0j \\x07\\fE\\r
  \\fAjA \\fE\\r
 	 Atj \\f5 \\f50B \\x86\\x84 #\\x85 #}7\\0 Aj" \\b("(\\xE8\\bI\\r\\0\\v\\v \\r\\f\\v \\x07AM@ (\\x84%\\r A6\\xDCA \\bA ($ ( \\0\\0\\f\\v \\x07AM@ AvA\\x07q" (\\xE8\\bO@ (\\x84%\\r A6\\xDCA \\bA\\0 ($ ( \\0\\0\\f\\v  
A\\xB0lj"\\x07A6\\x90	  
At"\\vj(P!	 \\x07 6\\xA4	 \\x07 	6\\xC8	 \\x7FB Ak\\xAD\\x86B\\0 A\\xC0\\0M\\x1B!# A k!\\r \\x07A\\xA8	j!A\\0!@ E\\r
 \\b((,!	  Atj~ A!O@ 	 \\fA0j \\r\\fE\\r\\f 	 \\fAjA \\fE\\r\\f \\f5 \\f50B \\x86\\x84\\f\\v 	 \\fAj \\fE\\r\\v \\f5\\v #\\x85 #}7\\0 Aj" G\\r\\0\\v \\b( \\v(, \\fA\\xEC\\x1Bj"	A\\fE\\r\\b \\x07 \\f(\\xEC\\x1B"\\r6\\x98	 \\b(!@@ \\rAM@ (, 	A\\fE\\r\\v  \\b("(\\xE8\\b"\\r \\f(\\xEC\\x1B"	vM \\rA\\x7F 	tA\\x7FsqEq\\r (\\x84%E@ A6\\xDCA \\bA\\0 ($ ( \\0\\0\\v \\b(\\0A6\\0\\f\\v@ (\\x84%E@ A6\\xDCA \\bA ($ ( \\0\\0\\f\\v  (\\xD0AAj6\\xD0A\\v \\b(\\0A6\\0\\f\\v \\x07 	6\\x9C	 \\x07 
A\\fl" \\b(jA\\xF8\\0j6\\xA0	 \\x07(\\x98	"\\rAI@ \\b  	  \\b("	jA\\xF8\\0j 	 \\vj(P \\rAFAE\\r
\\v \\b(!	@ A M@ 	 \\vj"\\v(0!@ E\\r\\0  \\x07)\\xA8	>\\0 AF\\r\\0  \\x07)\\xB0	> AF\\r\\0  \\x07)\\xB8	>\\b AF\\r\\0  \\x07)\\xC0	>\\f AF\\r\\0  \\x07)\\xC8	> AF\\r\\0  \\x07)\\xD0	> AF\\r\\0  \\x07)\\xD8	>\\v  Atj! 	(\\xE8\\b k!\\x07 \\v(P!	  jA K\\r 	 \\x07  @\\f\\v 	A6t At"@ 	(p \\x07A\\xA8	j \\xFC
\\0\\0\\v \\b("	 \\vj(P!\\v 	(\\xE8\\b k!\\x07 	(p j!	A\\0!\\r@@@@@@@@ \\0\\x07\\v \\x07A\\0L\\r 	A\\bk)\\0!#A\\0!@ 	 Atj" \\v Atj4\\0 Ak)\\0Bz~| A k)\\0} Ak)\\0 #|B\\x86|"#7\\0 Aj" \\x07G\\r\\0\\v\\f\\v \\x07A\\0L\\r 	A\\bk)\\0!#A\\0! \\x07AG@ \\x07Aq \\x07A\\xFE\\xFF\\xFF\\xFF\\x07q!\\x07@ 	 Atj" Ak)\\0 \\v Atj4\\0| # Ak)\\0"#}B~|"$7\\0 	 Ar"Atj" # \\v Atj4\\0| $ Ak)\\0}B~|"#7\\0 Aj" \\x07G\\r\\0\\vE\\r\\v 	 Atj" Ak)\\0 \\v Atj4\\0| # Ak)\\0}B~|7\\0\\f\\v \\x07A\\0L\\r 	A\\bk)\\0!#A\\0! \\x07AG@ \\x07Aq \\x07A\\xFE\\xFF\\xFF\\xFF\\x07q!\\x07@ 	 Atj"\\r \\v Atj4\\0 #B\\x86| \\rAk)\\0}"#7\\0 	 Ar"\\rAtj" \\v \\rAtj4\\0 #B\\x86| Ak)\\0}"#7\\0 Aj" \\x07G\\r\\0\\vE\\r\\v 	 Atj" \\v Atj4\\0 #B\\x86| Ak)\\0}7\\0\\f\\v \\x07A\\0L\\r \\x07Aq! 	A\\bk)\\0!# \\x07AO\\rA\\0!\\f\\v \\x07A\\0L\\rA\\0! \\x07AG@ \\x07A\\xFE\\xFF\\xFF\\xFF\\x07q!@ 	 \\rAtj \\v \\rAtj\\xFD\\0\\xFD\\v\\0 \\rAj"\\r G\\r\\0\\v  \\x07F\\r\\v@ 	 Atj \\v Atj4\\x007\\0 Aj" \\x07G\\r\\0\\v\\f\\v \\x07A\\xFC\\xFF\\xFF\\xFF\\x07q!\\x07A\\0!@ 	 Atj # \\v Atj4\\0|"#7\\0 	 Ar"Atj # \\v Atj4\\0|"#7\\0 	 Ar"Atj # \\v Atj4\\0|"#7\\0 	 Ar"Atj # \\v Atj4\\0|"#7\\0 Aj" \\x07G\\r\\0\\v E\\r\\v@ 	 Atj # \\v Atj4\\0|"#7\\0 Aj! \\rAj"\\r G\\r\\0\\v\\v\\f\\v 	 \\x07  @\\v E\\r \\b(\\0(\\0AG\\r\\f\\v \\x07A?M@ (\\x84%E@ A6\\xDCA \\bA ($ ( \\0\\0\\f\\v  (\\xD0AAj6\\xD0A\\f\\v AvAqAj" (\\xE8\\bO@ (\\x84%\\r A6\\xDCA \\bA\\0 ($ ( \\0\\0\\f\\vA\\0!\\x07A\\0!\\v\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!0#\\0Ak"$\\0 \\b(" 
A\\xB0lj"	A6\\x90	  
Atj(P!\\r 	 "6\\xA4	 	 \\r6\\xB0\\fB Ak\\xAD\\x86B\\0 A\\xC0\\0M\\x1B!# A k! 	A\\xB0
j!\\r A!I!@@ E\\r \\b((,! \\r \\vAtj~ E@  A\\fj \\fE\\r  A\\bjA \\fE\\r 5\\b 5\\fB \\x86\\x84\\f\\v  A\\bj \\fE\\r 5\\b\\v #\\x85 #}7\\0 \\vAj"\\v G\\r\\0\\v \\b((, A\\bjA\\fE\\r\\0 (\\b"AF@ \\b("(\\x84%E@ A6\\xDCA \\bA\\0 ($ ( \\0\\0\\v \\b(\\0A6\\0A!\\x07\\f\\v 	 Aj6\\xA8	 \\b((, A\\fjA\\fE\\r\\0 (\\fAsAk"A\\0H@ \\b("(\\x84%E@ A6\\xDCA \\bA\\0 ($ ( \\0\\0\\v \\b(\\0A6\\0A!\\x07\\f\\v 	 6\\xAC	 	A\\xB0	j!@@ 	(\\xA8	"\\v@ \\b((, A\\fj \\v\\f\\r\\vA\\0!\\x07\\f\\v  \\x07AtjA \\vAktA\\0 \\vA M\\x1B"\\v (\\fs \\vk6\\0 \\x07Aj"\\x07 G\\r\\0\\vA\\0!\\x07 \\b((, A\\bj"A\\fE\\r\\0 	 (\\b"6\\x98	 \\b(!\\v@ AM@ \\v(, A\\fE\\r  \\b("\\v(\\xE8\\b" (\\b"vM A\\x7F tA\\x7FsqEq\\r \\v(\\x84%E@ \\vA6\\xDCA \\bA\\0 \\v($ \\v( \\0\\0\\v \\b(\\0A6\\0A!\\x07\\f\\v@ \\v(\\x84%E@ \\vA6\\xDCA \\bA \\v($ \\v( \\0\\0\\f\\v \\v \\v(\\xD0AAj6\\xD0A\\v \\b(\\0A6\\0A!\\x07\\f\\v 	 6\\x9C	 	 
A\\fl"\\v \\b(jA\\xF8\\0j6\\xA0	 	(\\x98	"AI@ \\b   \\v \\b("jA\\xF8\\0j  
Atj(P AFAE\\r\\v \\b(! A M@  
Atj(0!A\\0!\\v@ AO@ A>q!\\v@  \\x07Atj \\r \\x07Atj\\xFD\\0\\0\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\r\\0\\b	
\\v\\0\\0\\xFD[\\0\\0 \\x07Aj"\\x07 \\vG\\r\\0\\v  \\vF\\r\\v@  \\vAtj \\r \\vAtj)\\0>\\0 \\vAj"\\v G\\r\\0\\v\\v@\\x7F 	(\\xAC	!\\rA\\0!	\\x7FB Ak\\xAD"#\\x86B\\0 ~A\\0!\\x07@ AO@ A|q!	@  \\x07Atj\\xFD\\0\\0\\xFD\\xA0 0\\xFD\\xAE!0 \\x07Aj"\\x07 	G\\r\\0\\v 0 0 0\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xAE"0 0 0\\xFD\\r\\x07\\0\\0\\0\\xFD\\xAE\\xFD\\x1B\\0!\\x07  	F\\r\\v@ \\x07  	Atj(\\0"\\v \\vAu"\\vs \\vkj!\\x07 	Aj"	 G\\r\\0\\v\\v \\x07\\xADB\\0\\v #\\x86} \\r\\xAD\\x87}"#B|"$BX@A\\0 $\\xA7AF\\rA\\f\\vA\\xC1\\0 #B?\\x87 #\\x85y\\xA7k\\v\\vA K\\r\\0\\x7FA\\0!\\x07\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!0A\\0!	\\x7F ~@ AO@ A|q!	@  \\x07Atj\\xFD\\0\\0\\xFD\\xA0 0\\xFD\\xAE!0 \\x07Aj"\\x07 	G\\r\\0\\v 0 0 0\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xAE"0 0 0\\xFD\\r\\x07\\0\\0\\0\\xFD\\xAE\\xFD\\x1B\\0!\\x07  	F\\r\\v@ \\x07  	Atj(\\0"\\v \\vAu"\\vs \\vkj!\\x07 	Aj"	 G\\r\\0\\v\\v \\x07\\xADB\\0\\v Ak\\xAD\\x86"#B|"$BX@A\\0 $\\xA7AF\\rA\\f\\vA\\xC1\\0 #B?\\x87 #\\x85y\\xA7k\\v\\vA K\\r\\0  
Atj(P! (\\xE8\\b k!  Atj!\\vA\\0!	@ A\\rO@ A\\0L\\r A\\rk!@A\\0!\\x07@@@@@@@@@@@@@@@@@@@@ Ak\\r\\f\\v
	\\b\\x07\\0\\v \\v 	AtjA\\x80k(\\0 (|l!\\x07\\v \\v 	AtjA\\xFC\\0k(\\0 (xl \\x07j!\\x07\\v \\v 	AtjA\\xF8\\0k(\\0 (tl \\x07j!\\x07\\v \\v 	AtjA\\xF4\\0k(\\0 (pl \\x07j!\\x07\\v \\v 	AtjA\\xF0\\0k(\\0 (ll \\x07j!\\x07\\v \\v 	AtjA\\xEC\\0k(\\0 (hl \\x07j!\\x07\\v \\v 	AtjA\\xE8\\0k(\\0 (dl \\x07j!\\x07\\v \\v 	AtjA\\xE4\\0k(\\0 (\\\`l \\x07j!\\x07\\v \\v 	AtjA\\xE0\\0k(\\0 (\\\\l \\x07j!\\x07\\v \\v 	AtjA\\xDC\\0k(\\0 (Xl \\x07j!\\x07\\v \\v 	AtjA\\xD8\\0k(\\0 (Tl \\x07j!\\x07\\v \\v 	AtjA\\xD4\\0k(\\0 (Pl \\x07j!\\x07\\v \\v 	AtjA\\xD0\\0k(\\0 (Ll \\x07j!\\x07\\v \\v 	AtjA\\xCC\\0k(\\0 (Hl \\x07j!\\x07\\v \\v 	AtjA\\xC8\\0k(\\0 (Dl \\x07j!\\x07\\v \\v 	AtjA\\xC4\\0k(\\0 (@l \\x07j!\\x07\\v \\v 	AtjA@j(\\0 (<l \\x07j!\\x07\\v \\v 	AtjA<k(\\0 (8l \\x07j!\\x07\\v \\v 	AtjA8k(\\0 (4l \\x07j!\\x07\\v \\v 	At"j"  j(\\0 A4k(\\0 (0l \\x07j A0k(\\0 (,lj A,k(\\0 ((lj A(k(\\0 ($lj A$k(\\0 ( lj A k(\\0 (lj Ak(\\0 (lj Ak(\\0 (lj Ak(\\0 (lj Ak(\\0 (\\flj A\\fk(\\0 (\\blj A\\bk(\\0 (lj Ak(\\0 (\\0lj \\ruj6\\0 	Aj"	 G\\r\\0\\v\\f\\v A	O@ A\\vO@ A\\fG@ A\\0L\\r \\vAk(\\0!	 (\\0! (! (\\b! (\\f! (! (! (! (! ( ! ($! ((!A\\0!\\x07@ \\v \\x07At"!j"  !j(\\0 A(k(\\0 l A,k(\\0 lj A$k(\\0 lj A k(\\0 lj Ak(\\0 lj Ak(\\0 lj Ak(\\0 lj Ak(\\0 lj A\\fk(\\0 lj A\\bk(\\0 lj 	 lj \\ruj"	6\\0 \\x07Aj"\\x07 G\\r\\0\\v\\f\\v A\\0L\\r \\vAk(\\0!	 (\\0! (! (\\b! (\\f! (! (! (! (! ( ! ($! ((!! (,!A\\0!\\x07@ \\v \\x07At""j"  "j(\\0 A,k(\\0 !l A0k(\\0 lj A(k(\\0 lj A$k(\\0 lj A k(\\0 lj Ak(\\0 lj Ak(\\0 lj Ak(\\0 lj Ak(\\0 lj A\\fk(\\0 lj A\\bk(\\0 lj 	 lj \\ruj"	6\\0 \\x07Aj"\\x07 G\\r\\0\\v\\f\\v A
G@ A\\0L\\r \\vAk(\\0!	 (\\0! (! (\\b! (\\f! (! (! (! (! ( !A\\0!\\x07@ \\v \\x07At"j"  j(\\0 A k(\\0 l A$k(\\0 lj Ak(\\0 lj Ak(\\0 lj Ak(\\0 lj Ak(\\0 lj A\\fk(\\0 lj A\\bk(\\0 lj 	 lj \\ruj"	6\\0 \\x07Aj"\\x07 G\\r\\0\\v\\f\\v A\\0L\\r \\vAk(\\0!	 (\\0! (! (\\b! (\\f! (! (! (! (! ( ! ($!A\\0!\\x07@ \\v \\x07At"j"  j(\\0 A$k(\\0 l A(k(\\0 lj A k(\\0 lj Ak(\\0 lj Ak(\\0 lj Ak(\\0 lj Ak(\\0 lj A\\fk(\\0 lj A\\bk(\\0 lj 	 lj \\ruj"	6\\0 \\x07Aj"\\x07 G\\r\\0\\v\\f\\v AO@ A\\x07O@ A\\bG@ A\\0L\\r \\vAk(\\0!	 (\\0! (! (\\b! (\\f! (! (! (!A\\0!\\x07@ \\v \\x07At"j"  j(\\0 Ak(\\0 l Ak(\\0 lj Ak(\\0 lj Ak(\\0 lj A\\fk(\\0 lj A\\bk(\\0 lj 	 lj \\ruj"	6\\0 \\x07Aj"\\x07 G\\r\\0\\v\\f\\v A\\0L\\r \\vAk(\\0!	 (\\0! (! (\\b! (\\f! (! (! (! (!A\\0!\\x07@ \\v \\x07At"j"  j(\\0 Ak(\\0 l A k(\\0 lj Ak(\\0 lj Ak(\\0 lj Ak(\\0 lj A\\fk(\\0 lj A\\bk(\\0 lj 	 lj \\ruj"	6\\0 \\x07Aj"\\x07 G\\r\\0\\v\\f\\v AG@ A\\0L\\r \\vAk(\\0!	 (\\0! (! (\\b! (\\f! (!A\\0!\\x07@ \\v \\x07At"j"  j(\\0 Ak(\\0 l Ak(\\0 lj A\\fk(\\0 lj A\\bk(\\0 lj 	 lj \\ruj"	6\\0 \\x07Aj"\\x07 G\\r\\0\\v\\f\\v A\\0L\\r \\vAk(\\0!	 (\\0! (! (\\b! (\\f! (! (!A\\0!\\x07@ \\v \\x07At"j"  j(\\0 Ak(\\0 l Ak(\\0 lj Ak(\\0 lj A\\fk(\\0 lj A\\bk(\\0 lj 	 lj \\ruj"	6\\0 \\x07Aj"\\x07 G\\r\\0\\v\\f\\v AO@ AG@ A\\0L\\r \\vAk(\\0!	 (\\0! (! (\\b!A\\0!\\x07@ \\v \\x07At"j"  j(\\0 A\\bk(\\0 l A\\fk(\\0 lj 	 lj \\ruj"	6\\0 \\x07Aj"\\x07 G\\r\\0\\v\\f\\v A\\0L\\r \\vAk(\\0!	 (\\0! (! (\\b! (\\f!A\\0!\\x07@ \\v \\x07At"j"  j(\\0 A\\fk(\\0 l Ak(\\0 lj A\\bk(\\0 lj 	 lj \\ruj"	6\\0 \\x07Aj"\\x07 G\\r\\0\\v\\f\\v AG@ A\\0L\\r \\vAk(\\0!	 (\\0!A\\0!\\x07 AG@ Aq A\\xFE\\xFF\\xFF\\xFF\\x07q!@ \\v \\x07At"j  j(\\0  	l \\ruj"	6\\0 \\v Ar"j  j(\\0  	l \\ruj"	6\\0 \\x07Aj"\\x07 G\\r\\0\\vE\\r\\v \\v \\x07At"j  j(\\0  	l \\ruj6\\0\\f\\v A\\0L\\r\\0 \\vAk(\\0!	 (\\0! (!A\\0!\\x07 AG@ Aq A\\xFE\\xFF\\xFF\\xFF\\x07q!@ \\v \\x07At"j"  j(\\0  	l A\\bk(\\0 lj \\ruj"	6\\0 \\v Ar"j"  j(\\0  	l A\\bk(\\0 lj \\ruj"	6\\0 \\x07Aj"\\x07 G\\r\\0\\vE\\r\\v \\v \\x07At"\\x07j"\\v \\x07 j(\\0  	l \\vA\\bk(\\0 lj \\ruj6\\0\\vA!\\x07\\f\\v  
Atj(P! (\\xE8\\b k!  Atj!\\vA\\0!\\x07@ A\\rO@ A\\0L\\r \\r\\xAD!$ A\\rk!	@B\\0!#@@@@@@@@@@@@@@@@@@@@ 	Ak\\r\\f\\v
	\\b\\x07\\0\\v \\v \\x07AtjA\\x80k4\\0 4|~!#\\v \\v \\x07AtjA\\xFC\\0k4\\0 4x~ #|!#\\v \\v \\x07AtjA\\xF8\\0k4\\0 4t~ #|!#\\v \\v \\x07AtjA\\xF4\\0k4\\0 4p~ #|!#\\v \\v \\x07AtjA\\xF0\\0k4\\0 4l~ #|!#\\v \\v \\x07AtjA\\xEC\\0k4\\0 4h~ #|!#\\v \\v \\x07AtjA\\xE8\\0k4\\0 4d~ #|!#\\v \\v \\x07AtjA\\xE4\\0k4\\0 4\\\`~ #|!#\\v \\v \\x07AtjA\\xE0\\0k4\\0 4\\\\~ #|!#\\v \\v \\x07AtjA\\xDC\\0k4\\0 4X~ #|!#\\v \\v \\x07AtjA\\xD8\\0k4\\0 4T~ #|!#\\v \\v \\x07AtjA\\xD4\\0k4\\0 4P~ #|!#\\v \\v \\x07AtjA\\xD0\\0k4\\0 4L~ #|!#\\v \\v \\x07AtjA\\xCC\\0k4\\0 4H~ #|!#\\v \\v \\x07AtjA\\xC8\\0k4\\0 4D~ #|!#\\v \\v \\x07AtjA\\xC4\\0k4\\0 4@~ #|!#\\v \\v \\x07AtjA@j4\\0 4<~ #|!#\\v \\v \\x07AtjA<k4\\0 48~ #|!#\\v \\v \\x07AtjA8k4\\0 44~ #|!#\\v \\v \\x07At"\\rj" \\r j(\\0 A4k4\\0 40~ #| A0k4\\0 4,~| A,k4\\0 4(~| A(k4\\0 4$~| A$k4\\0 4 ~| A k4\\0 4~| Ak4\\0 4~| Ak4\\0 4~| Ak4\\0 4~| Ak4\\0 4\\f~| A\\fk4\\0 4\\b~| A\\bk4\\0 4~| Ak4\\0 4\\0~| $\\x87\\xA7j6\\0 \\x07Aj"\\x07 G\\r\\0\\v\\f\\v A	O@ A\\vO@ A\\fG@ A\\0L\\r \\vAk(\\0!\\x07 \\r\\xAD!# 4\\0!$ 4!% 4\\b!& 4\\f!' 4!( 4!) 4!* 4!+ 4 !, 4$!- 4(!.A\\0!	@ \\v 	At"j"  j(\\0 A(k4\\0 -~ A,k4\\0 .~| A$k4\\0 ,~| A k4\\0 +~| Ak4\\0 *~| Ak4\\0 )~| Ak4\\0 (~| Ak4\\0 '~| A\\fk4\\0 &~| A\\bk4\\0 %~| \\x07\\xAC $~| #\\x87\\xA7j"\\x076\\0 	Aj"	 G\\r\\0\\v\\f\\v A\\0L\\r \\vAk(\\0!\\x07 \\r\\xAD!# 4\\0!$ 4!% 4\\b!& 4\\f!' 4!( 4!) 4!* 4!+ 4 !, 4$!- 4(!. 4,!/A\\0!	@ \\v 	At"j"  j(\\0 A,k4\\0 .~ A0k4\\0 /~| A(k4\\0 -~| A$k4\\0 ,~| A k4\\0 +~| Ak4\\0 *~| Ak4\\0 )~| Ak4\\0 (~| Ak4\\0 '~| A\\fk4\\0 &~| A\\bk4\\0 %~| \\x07\\xAC $~| #\\x87\\xA7j"\\x076\\0 	Aj"	 G\\r\\0\\v\\f\\v A
G@ A\\0L\\r \\vAk(\\0!\\x07 \\r\\xAD!# 4\\0!$ 4!% 4\\b!& 4\\f!' 4!( 4!) 4!* 4!+ 4 !,A\\0!	@ \\v 	At"j"  j(\\0 A k4\\0 +~ A$k4\\0 ,~| Ak4\\0 *~| Ak4\\0 )~| Ak4\\0 (~| Ak4\\0 '~| A\\fk4\\0 &~| A\\bk4\\0 %~| \\x07\\xAC $~| #\\x87\\xA7j"\\x076\\0 	Aj"	 G\\r\\0\\v\\f\\v A\\0L\\r \\vAk(\\0!\\x07 \\r\\xAD!# 4\\0!$ 4!% 4\\b!& 4\\f!' 4!( 4!) 4!* 4!+ 4 !, 4$!-A\\0!	@ \\v 	At"j"  j(\\0 A$k4\\0 ,~ A(k4\\0 -~| A k4\\0 +~| Ak4\\0 *~| Ak4\\0 )~| Ak4\\0 (~| Ak4\\0 '~| A\\fk4\\0 &~| A\\bk4\\0 %~| \\x07\\xAC $~| #\\x87\\xA7j"\\x076\\0 	Aj"	 G\\r\\0\\v\\f\\v AO@ A\\x07O@ A\\bG@ A\\0L\\r \\vAk(\\0!\\x07 \\r\\xAD!# 4\\0!$ 4!% 4\\b!& 4\\f!' 4!( 4!) 4!*A\\0!	@ \\v 	At"j"  j(\\0 Ak4\\0 )~ Ak4\\0 *~| Ak4\\0 (~| Ak4\\0 '~| A\\fk4\\0 &~| A\\bk4\\0 %~| \\x07\\xAC $~| #\\x87\\xA7j"\\x076\\0 	Aj"	 G\\r\\0\\v\\f\\v A\\0L\\r \\vAk(\\0!\\x07 \\r\\xAD!# 4\\0!$ 4!% 4\\b!& 4\\f!' 4!( 4!) 4!* 4!+A\\0!	@ \\v 	At"j"  j(\\0 Ak4\\0 *~ A k4\\0 +~| Ak4\\0 )~| Ak4\\0 (~| Ak4\\0 '~| A\\fk4\\0 &~| A\\bk4\\0 %~| \\x07\\xAC $~| #\\x87\\xA7j"\\x076\\0 	Aj"	 G\\r\\0\\v\\f\\v AG@ A\\0L\\r \\vAk(\\0!\\x07 \\r\\xAD!# 4\\0!$ 4!% 4\\b!& 4\\f!' 4!(A\\0!	@ \\v 	At"j"  j(\\0 Ak4\\0 '~ Ak4\\0 (~| A\\fk4\\0 &~| A\\bk4\\0 %~| \\x07\\xAC $~| #\\x87\\xA7j"\\x076\\0 	Aj"	 G\\r\\0\\v\\f\\v A\\0L\\r \\vAk(\\0!\\x07 \\r\\xAD!# 4\\0!$ 4!% 4\\b!& 4\\f!' 4!( 4!)A\\0!	@ \\v 	At"j"  j(\\0 Ak4\\0 (~ Ak4\\0 )~| Ak4\\0 '~| A\\fk4\\0 &~| A\\bk4\\0 %~| \\x07\\xAC $~| #\\x87\\xA7j"\\x076\\0 	Aj"	 G\\r\\0\\v\\f\\v AO@ AG@ A\\0L\\r \\vAk(\\0!\\x07 \\r\\xAD!# 4\\0!$ 4!% 4\\b!&A\\0!	@ \\v 	At"j"  j(\\0 A\\bk4\\0 %~ A\\fk4\\0 &~| \\x07\\xAC $~| #\\x87\\xA7j"\\x076\\0 	Aj"	 G\\r\\0\\v\\f\\v A\\0L\\r \\vAk(\\0!\\x07 \\r\\xAD!# 4\\0!$ 4!% 4\\b!& 4\\f!'A\\0!	@ \\v 	At"j"  j(\\0 A\\fk4\\0 &~ Ak4\\0 '~| A\\bk4\\0 %~| \\x07\\xAC $~| #\\x87\\xA7j"\\x076\\0 	Aj"	 G\\r\\0\\v\\f\\v AG@ A\\0L\\r \\vAk(\\0!\\x07 \\r\\xAD!# 4\\0!$A\\0!	 AG@ Aq A\\xFE\\xFF\\xFF\\xFF\\x07q!\\r@ \\v 	At"j  j(\\0 \\x07\\xAC $~ #\\x87\\xA7j"\\x076\\0 \\v Ar"j  j(\\0 \\x07\\xAC $~ #\\x87\\xA7j"\\x076\\0 	Aj"	 \\rG\\r\\0\\vE\\r\\v \\v 	At"j  j(\\0 \\x07\\xAC $~ #\\x87\\xA7j6\\0\\f\\v A\\0L\\r\\0 \\vAk(\\0!\\x07 \\r\\xAD!# 4\\0!$ 4!%A\\0!	 AG@ Aq A\\xFE\\xFF\\xFF\\xFF\\x07q!\\r@ \\v 	At"j"  j(\\0 \\x07\\xAC $~ A\\bk4\\0 %~| #\\x87\\xA7j"\\x076\\0 \\v Ar"j"  j(\\0 \\x07\\xAC $~ A\\bk4\\0 %~| #\\x87\\xA7j"\\x076\\0 	Aj"	 \\rG\\r\\0\\vE\\r\\v \\v 	At"j"  j(\\0 \\x07\\xAC $~ A\\bk4\\0 %~| #\\x87\\xA7j6\\0\\vA!\\x07\\f\\vA!\\x07 A6t At"\\v@ (p \\r \\v\\xFC
\\0\\0\\v \\b("\\r 
Atj(P! 	(\\xAC	!	 \\r(p \\vj!\\v \\r(\\xE8\\b k"\\rA\\0J@ 	\\xAD!$A\\0!	 Ak!@B\\0!#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@ Ak\\x1B\\r\\f\\v
	\\b\\x07\\0\\v \\v 	AtjA\\x80k)\\0 4|~!#\\v \\v 	AtjA\\xF8k)\\0 4x~ #|!#\\v \\v 	AtjA\\xF0k)\\0 4t~ #|!#\\v \\v 	AtjA\\xE8k)\\0 4p~ #|!#\\v \\v 	AtjA\\xE0k)\\0 4l~ #|!#\\v \\v 	AtjA\\xD8k)\\0 4h~ #|!#\\v \\v 	AtjA\\xD0k)\\0 4d~ #|!#\\v \\v 	AtjA\\xC8k)\\0 4\\\`~ #|!#\\v \\v 	AtjA\\xC0k)\\0 4\\\\~ #|!#\\v \\v 	AtjA\\xB8k)\\0 4X~ #|!#\\v \\v 	AtjA\\xB0k)\\0 4T~ #|!#\\v \\v 	AtjA\\xA8k)\\0 4P~ #|!#\\v \\v 	AtjA\\xA0k)\\0 4L~ #|!#\\v \\v 	AtjA\\x98k)\\0 4H~ #|!#\\v \\v 	AtjA\\x90k)\\0 4D~ #|!#\\v \\v 	AtjA\\x88k)\\0 4@~ #|!#\\v \\v 	AtjA\\x80k)\\0 4<~ #|!#\\v \\v 	AtjA\\xF8\\0k)\\0 48~ #|!#\\v \\v 	AtjA\\xF0\\0k)\\0 44~ #|!#\\v \\v 	AtjA\\xE8\\0k)\\0 40~ #|!#\\v \\v 	AtjA\\xE0\\0k)\\0 4,~ #|!#\\v \\v 	AtjA\\xD8\\0k)\\0 4(~ #|!#\\v \\v 	AtjA\\xD0\\0k)\\0 4$~ #|!#\\v \\v 	AtjA\\xC8\\0k)\\0 4 ~ #|!#\\v \\v 	AtjA@j)\\0 4~ #|!#\\v \\v 	AtjA8k)\\0 4~ #|!#\\v \\v 	AtjA0k)\\0 4~ #|!#\\v \\v 	AtjA(k)\\0 4~ #|!#\\v \\v 	AtjA k)\\0 4\\f~ #|!#\\v \\v 	AtjAk)\\0 4\\b~ #|!#\\v \\v 	AtjAk)\\0 4~ #|!#\\v \\v 	Atj"  	Atj4\\0 A\\bk)\\0 4\\0~ #| $\\x87|7\\0 	Aj"	 \\rG\\r\\0\\v\\v\\v Aj$\\0 \\x07E\\r\\x07 E\\r \\b(\\0(\\0AF\\r\\v  \\b(" 
A\\xB0lj(\\xB8\\f"\\x07jA M@ (\\xE8\\bE\\r  
Atj(0!A\\0!@  Atj"	 	(\\0 \\x07t6\\0 Aj" (\\xE8\\bI\\r\\0\\v\\f\\v A6t (\\xE8\\b"E\\r  
Atj(0!	 (p!\\v \\x07\\xAD!#A\\0! AG@ A~q!A\\0!@ \\v Atj 	 Atj\\xFD\\0 #\\xA7\\xFD\\xCB\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\v@ \\v Atj 	 Atj4\\0 #\\x867\\0 Aj" G\\r\\0\\v\\f\\v  (\\xD0AAj6\\xD0A\\v \\b(\\0A6\\0\\v \\b(\\0"	(\\0"AG\\r 
Aj"
 \\b("(\\xF0\\bI\\r\\0\\vA!\\f\\v AF\\r\\v \\b((,"(A\\x07q"@ \\fA\\x0060@  \\fA0jA\\b k\\f"E\\r\\0 \\f(0E\\r\\0 \\b("(\\x84%E@ A6\\xDCA \\bA\\0 ($ ( \\0\\0\\v \\b(\\0"	A6\\0 \\b(!
\\f\\v E\\r\\f \\b(\\0"	(\\0!\\v \\b(!
 AG\\r@ 
(,"("\\x07 ("M\\r\\0 ( "E\\r\\0\\x7F ("
 A?K\\r\\0 
A\\bv (\\0 Atj)\\0"$B8 \\xAD"#}"%\\x88\\xA7A\\xFFqA\\0 %B\\xC0\\0T\\x1BsAt/\\x90"	 
A\\btA\\x80\\xFEqs"
 A7K\\r\\0 
A\\bv $B0 #}"%\\x88\\xA7A\\xFFqA\\0 %B\\xC0\\0T\\x1BsAt/\\x90"
 	A\\btA\\x80\\xFEqs"	 A/K\\r\\0 	A\\bv $B( #}"%\\x88\\xA7A\\xFFqA\\0 %B\\xC0\\0T\\x1BsAt/\\x90"	 
A\\btA\\x80\\xFEqs"
 A'K\\r\\0 
A\\bv $B  #}"%\\x88\\xA7A\\xFFqA\\0 %B\\xC0\\0T\\x1BsAt/\\x90"
 	A\\btA\\x80\\xFEqs"	 AK\\r\\0 	A\\bv $B #}"%\\x88\\xA7A\\xFFqA\\0 %B\\xC0\\0T\\x1BsAt/\\x90"	 
A\\btA\\x80\\xFEqs"
 #B \\x84B7V\\r\\0 
A\\bv $B #}"%\\x88\\xA7A\\xFFqA\\0 %B\\xC0\\0T\\x1BsAt/\\x90"
 	A\\btA\\x80\\xFEqs"	 AK\\r\\0 	A\\bv $B\\b #}"$\\x88\\xA7A\\xFFqA\\0 $B\\xC0\\0T\\x1BsAt/\\x90" 
A\\btA\\x80\\xFEqs"
 #B0\\x84B7V\\r\\0 
A\\x07vA\\xFEq/\\x90 A\\btA\\x80\\xFEqs\\v! Aj! A\\x006   6\\v  \\x07I@ \\x07 k!
 (\\0 Atj! (!@  )\\0"#B0\\x88\\xA7s"A\\xFFqAtA\\x905j/\\0 A\\x07vA\\xFEq/\\x909s #B(\\x88\\xA7A\\xFFqAt/\\x901s #B \\x88\\xA7A\\xFFqAt/\\x90-s #\\xA7"AvA\\xFEq/\\x90)s AvA\\xFEq/\\x90%s A\\x07vA\\xFEq/\\x90!s A\\xFFqAt/\\x90s! A\\bj! 
Ak"
\\r\\0\\v  A\\xFF\\xFFq6\\v A\\x006@ ("
E\\r\\0 ( " 
O\\r\\0 (\\0 \\x07Atj)\\0!# (!@ #A8 k\\xAD\\x88\\xA7A\\xFFq A\\bvsAt/\\x90 A\\btA\\x80\\xFEqs! A\\bj" 
I\\r\\0\\v  6   6\\v /!  \\fA\\xE4\\x1BjA\\f \\b(\\0"	(\\0!\\r AG\\r\\v \\b(!
\\f\\v \\b(\\0"	(\\0AG\\r
\\v \\b(!
\\f\\v \\b(!
@@@@ AG"\\r\\0 \\f(\\xE4\\x1B G\\r\\0@ 
(\\xF4\\bAk\\0\\v 
(\\xE8\\bE\\r 
(4!\\x07A\\0!@ \\x07 At"j(\\0!@ 
(t@ 
(0 j  
(p Atj(\\0j6\\0\\f\\v 
(0 j" (\\0 j6\\0\\v Aj" 
(\\xE8\\bI\\r\\0\\v\\f\\v \\r 
(\\x84%E@ 
A6\\xDCA \\bA 
($ 
( \\0\\0 \\b(\\0!	 \\b(!
\\v 	A6\\0\\f\\v 
(\\xE8\\bE\\r 
(0!\\vA\\0!@ \\v At"j"(\\0!\\x07@ 
(tE@  
(4 j"(\\0"Aq \\x07Atr"\\x07 jAu6\\0  \\x07 kAu6\\0\\f\\v  
(p Atj)\\0"#B\\x83 \\x07\\xACB\\x86\\x84"$ #|B\\x88>\\0 
(4 j $ #}B\\x88>\\0\\v Aj" 
(\\xE8\\bI\\r\\0\\v\\f\\v 
(\\xE8\\bE\\r\\0 
(0!\\x07A\\0!@ \\x07 At"j(\\0!@ 
(t@ 
(4 j  
(p Atj(\\0k6\\0\\f\\v 
(4 j"  (\\0k6\\0\\v Aj" 
(\\xE8\\bI\\r\\0\\v\\vA\\0!\\r 
(\\xF0\\bE\\r\\0@@ 
(\\xE8\\b"E\\r\\0A\\xFF\\xFF\\xFF\\xFF\\x07A  
(\\xF8\\bk"v!A\\x80\\x80\\x80\\x80x u!\\x07 
 \\rAtj(0!\\vA\\0!@ \\v Atj(\\0" \\x07H  HrE@  Aj"G\\r\\f\\v\\v 
(\\x84%E@ 
A6\\xDCA \\bA 
($ 
( \\0\\0 \\b(\\0!	 \\b(!
\\v 	A6\\0\\v \\rAj"\\r 
(\\xF0\\bI\\r\\0\\v\\v@ 
(\\xB0AE\\r\\0 	(\\0AG\\r\\0 
(\\x84%\\r\\0 
)\\x80	"# 
)\\x98& 
5\\x80&|"$X\\r\\0 
(\\xDCAE@ 
A6\\xDCA \\bA 
($ 
( \\0\\0 \\b(!
\\v 
(\\x84& 
(\\xEC\\bG\\r\\0 
(\\x88& 
(\\xF0\\bG\\r\\0 
(\\x90& 
(\\xF8\\bG\\r\\0 
A\\x80&j"(\\0AI\\r\\0 \\f\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v  \\f\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v \\f )\\0"%70 \\f )\\b"&78 \\f )7@ \\f \\xFD\\0\\xFD\\vHA\\0! \\fA\\0;\\xD8\\x1B %\\xA7!A\\0!@ &\\xA7"
E\\r\\0@@ \\fAj Atj\\x7F E@A\\r\\f\\v A\\v"\\x076\\0 \\x07E\\r\\0 
 Aj"G\\r\\f\\v\\v@ \\fAj Atj(\\0"@ 	 \\f(8!
\\v Aj" 
I\\r\\0\\v \\b(\\0A\\b6\\0\\f	\\v \\f(4Al" # $}\\xA7"  I\\x1B" A2l"  I\\x1B!\\x07@ \\x07E@A\\0! \\f(8"@@ \\fAj Atj(\\0"@ 	 \\f(8!\\v Aj" I\\r\\0\\v\\v \\b(!
\\f\\v \\f \\f(0"	\\xAD"# \\f)H|7H \\x07 	I@ \\f \\x0760 \\x07\\xAD!# \\x07!	\\v \\b(\\0 	6 \\b( \\f)H #|7\\xE8@ \\f(8"E\\r\\0 Aq!\\vA\\0!
A\\0! AO@@ AkAv"@ Aj"Aq A\\xFE\\xFF\\xFF\\xFF\\x07q!A\\0!@   A\\xB0lj"A\\x006\\xF8 B\\x007\\xD8 A\\x006\\xD0 A\\x006\\xC8 B\\x007\\xA8 A\\x006\\xA0 A\\x006\\x98 B\\x007\\xF8 A\\x006\\xF0 A\\x006\\xE8 B\\x007\\xC8\\r A\\x006\\xC0\\r A\\x006\\xB8\\r B\\x007\\x98
 A\\x006\\x90
 A\\x006\\x88
 B\\x007\\xE8 A\\x006\\xE0 A\\x006\\xD8 B\\x007\\xB8 A\\x006\\xB0 A\\x006\\xA8 B\\x007\\b A\\x006\\0 A\\bj! Aj" G\\r\\0\\vE\\r\\v   A\\xB0lj"A\\x006\\xB8\\r B\\x007\\x98
 A\\x006\\x90
 A\\x006\\x88
 B\\x007\\xE8 A\\x006\\xE0 A\\x006\\xD8 B\\x007\\xB8 A\\x006\\xB0 A\\x006\\xA8 B\\x007\\b A\\x006\\0 Aj!\\v \\vE\\r\\v@   A\\xB0lj"A\\x006\\xA8 B\\x007\\b A\\x006\\0 Aj! 
Aj"
 \\vG\\r\\0\\v\\v \\x07 	k!\\x07 \\b \\fA0j \\fAj?E\\r\\0\\v \\b(\\0A\\x076\\0 \\f(8"E\\r\\bA\\0!\\x07@ \\fAj \\x07Atj(\\0"\\b@ \\b	 \\f(8!\\v \\x07Aj"\\x07 I\\r\\0\\v\\f\\b\\v 
A\\x006\\xDCA@@@@@ \\b(\\0"(\\0Ak\\0\\0\\v 
(,"(,"A\\x7FG@  AjAv6  AtA\\bjA8q6 A6\\0\\f
\\v B\\x007 
(\\b"E\\r 
)\\xC0A"#P\\r \\b # 
($ \\0AG\\r \\b(\\0A6\\0\\f\\v\\v 
(\\xE4"@ 
 6\\xE0\\v  
(\\xF0\\b6\\b  
(\\xF4\\b6\\f  
(\\xF8\\b6  
(\\xEC\\b6  
(\\xE8\\b"6 
 
)\\x80	 \\xAD|7\\xE8 \\b 
A\\xE8\\bj 
A0j? \\b(\\0!\\bE\\r \\bA\\x076\\0\\f
\\v \\b((,"B\\x80\\x80\\x80\\x80p7$ \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\b A\\x7F6, \\b(\\0!\\v A6\\0\\f\\v \\bA6\\0\\f\\v \\b(\\0A\\b6\\0\\f\\v \\b("A6\\x98$ A\\xFF:\\0\\xDA$ (\\x84%\\r\\0 A6\\xDCA \\bA ($ ( \\0\\0\\v \\b(\\0A6\\0\\f\\v \\b("(,"(A\\x07q"@  \\fA0jA\\b k\\fE\\r \\b(!\\v@ (\\x98$@ \\f -\\0\\xDA$"60 A\\x006\\x98$\\f\\v (, \\fA0jA\\b\\fE\\r \\b(! \\f(0!\\v@@ A\\xFFG\\r\\0 A\\xFF:\\0\\xD8$ \\b((, \\fA0jA\\b\\fE\\r \\f(0"A\\xFFG@ A~qA\\xF8F\\r \\b(!\\f\\v \\b("A6\\x98$ A\\xFF:\\0\\xDA$\\v (\\x84%E@ A6\\xDCA \\bA\\0 ($ ( \\0\\0\\v@@ \\b("(\\x98$@ \\f -\\0\\xDA$"60 A\\x006\\x98$\\f\\v (, \\fA0jA\\b\\fE\\r \\f(0!\\v A\\xFFG\\r\\0 \\b(A\\xFF:\\0\\xD8$ \\b((, \\fA0jA\\b\\fE\\r \\f(0"A\\xFFF@ \\b("A6\\x98$ A\\xFF:\\0\\xDA$\\f\\v A~qA\\xF8G\\r\\0\\v\\v \\b( :\\0\\xD9$ \\b(\\0A6\\0 \\b("(," (At (Avj6,@ (\\f"E\\r\\0 \\b A\\xC0\\xC1\\0j" ($ \\0 \\b(!\\r\\0 (,"("
A\\x07q\\r\\0  )\\0 (\\b (kAt (\\fAtj 
kAv\\xAD}7\\0\\f\\v B\\x007\\xC0A\\f\\v\\vA!\\f\\v@ \\b((, \\fA\\xE8\\x1BjA\\fE\\r\\0 \\f(\\xE8\\x1B! \\b((, \\fA\\xE4\\x1BjA\\x07\\fE\\r \\b((, \\fA\\fjA\\fE\\r A\\0G!@@@@ \\f(\\xE4\\x1B"	\\0\\v \\b(" \\f(\\f"6\\x80  6\\xFC A\\x006\\xF8 (, \\fA0j"A\\fE\\r \\b( \\f(06\\x88 \\b((, A\\fE\\r \\b( \\f(06\\x8C \\b((, A\\fE\\r \\b( \\f(06\\x90 \\b((, A\\fE\\r \\b( \\f(06\\x94 \\b((, A\\fE\\r \\b( \\f(06\\x98 \\b((, A\\fE\\r \\b( \\f(0Aj6\\x9C \\b((, A\\fE\\r \\b( \\f(0Aj6\\xA0 \\b("\\x07(,!A\\0!
#\\0Ak"$\\0@  A\\fjA\\fE\\r\\0  A\\bjA \\fE\\r\\0 \\x07 5\\b 5\\fB \\x86\\x847\\xA8A!
\\v Aj$\\0 
E\\r \\b("(, A\\xB0jAE A!Mr\\r \\b((, A"kE\\r \\b("A6\\xF0 \\xFD\\0\\0\\xB0\\xFDSE@ A\\x006\\xFC$\\v (\\x84%\\r (\\xD8E\\r ("E\\r \\b A\\xF8j ($ \\0\\0\\f\\v \\b("A\\x006\\xF4 \\f(\\f"E\\r  6\\xB0  6\\xAC A6\\xA8A\\0 k An"AnlG@ (,A\\x7F6(\\f\\v  6\\xB8 \\b("(\\xBC!@@@ (\\xB8"@ A\\xAA\\xD5\\xAA\\xD5\\0K\\r  Al"E\\r \\b( 6\\xBC\\f\\v A\\0! \\b( 6\\xBC E\\r\\v \\b("(\\xB8@A\\0!
@ (," \\fA0j"A \\fE\\r  \\fAj"A \\fE\\r 
Al" \\b("\\x07(\\xBCj \\f5 \\f50B \\x86\\x847\\0 \\x07(,"\\x07 A \\fE\\r \\x07 A \\fE\\r \\b("(\\xBC j \\f5 \\f50B \\x86\\x847\\b (, \\fA\\xEC\\x1BjA\\fE\\r \\b("(\\xBC j \\f(\\xEC\\x1B6 
Aj"
 (\\xB8I\\r\\0\\v\\v A6\\xF4 (\\x84%\\r (\\xE4E\\r ("E\\r \\b A\\xA8j ($ \\0\\0\\f\\v 	 \\b(A\\x006\\xBC\\v \\b(\\0A\\b6\\0\\f\\v \\b(" 	Atj(\\xD8!
 \\f(\\f! \\fA8jA\\0A\\xA8\\xFC\\v\\0 \\f 68 \\f 	60 \\f 64@@@@@ 	AG\\r\\0 (, \\fA@k"AE\\r AM@ \\b(\\0A\\b6\\0A\\0!\\f\\b\\v Ak! \\b("(\\xDC\\bE\\r\\0\\x7FA\\0 (\\xDC\\b"\\x07E\\r\\0 (\\xD8\\b!\\vA\\0! (\\0\\0!@@ \\v Atj(\\0\\0 F\\r Aj" \\x07G\\r\\0\\vA\\0\\f\\vA\\vE 
A\\0Gs\\r (,"A6$  At6(\\f\\v 
\\r\\v (, \\r\\f\\vA!\\x07 (,"A6$  At6(@@@@@ 	\\x07\\0\\v  !\\x07\\f\\v \\fA@k!A\\0!
#\\0Ak"$\\0@@ A\\bO@ \\b((,!\\x07 A\\x006\\b \\x07 A\\bjA\\b\\fE\\r \\x07 A\\fj"\\vA\\b\\fE\\r (\\b!\\r (\\f! \\x07 \\vA\\b\\fE\\r (\\f! \\x07 \\vA\\b\\fE\\r  \\r A\\btr Atr (\\fAtr"\\x076\\0@@ \\x07 A\\bk"K@ B\\x007\\0\\f\\v  \\x07Aj\\r"
6 
E@ \\b(\\0A\\b6\\0\\f\\v \\b((, 
 \\x07E\\rA\\0!
 ( (\\0jA\\0:\\0\\0 \\b((,!\\v A\\x006\\b \\v A\\bjA\\b\\fE\\r \\v A\\fj"\\rA\\b\\fE\\r (\\b! (\\f! \\v \\rA\\b\\fE\\r (\\f! \\v \\rA\\b\\fE\\r   A\\btr Atr"\\v (\\fAtr"
6\\b 
A\\xA1\\x8DO@A\\0!
 A\\x006\\b\\f\\v  \\x07k! 
E\\r\\0  \\vAt\\r"
6\\f 
E\\rA\\0!
@ 
At"\\v (\\fj"B\\x007\\0 AM@  
6\\b\\f\\v \\b((,!\\x07 A\\x006\\b@@ \\x07 A\\bjA\\b\\fE\\r\\0 \\x07 A\\fj"\\rA\\b\\fE\\r\\0 (\\b! (\\f! \\x07 \\rA\\b\\fE\\r\\0 (\\f! \\x07 \\rA\\b\\f\\r\\v  
6\\b\\f\\v   A\\btr Atr (\\fAtr6\\0 Ak" (\\f \\vj"\\x07(\\0"I@  
6\\b \\b((,A\\x7F6(\\f\\v \\x07 Aj\\r"\\r6 \\rE@ \\b(\\0A\\b6\\0  
6\\b\\f\\v @ \\rA\\0 \\xFC\\v\\0\\v  k! \\b((, \\x07( \\x07(\\0 (\\f \\vj"\\v(!\\x07E@ \\x07	 (\\f 
AtjA\\x006  
6\\b\\f\\v \\x07 \\v(\\0jA\\0:\\0\\0 
Aj"
 (\\bI\\r\\0\\v\\v E@A!
\\f\\v (\\bE@ (\\f	 A\\x006\\f\\v \\b((,A\\x7F6(\\f\\vA\\0!
 A\\x006\\b \\b(\\0A\\b6\\0\\f\\v \\b((,A\\x7F6(\\vA\\0!
\\v Aj$\\0 
!\\x07\\f\\vA\\0!#\\0Ak"$\\0 \\fA@k"
A\\0A\\xA0\\xFC\\v\\0@ \\b((, 
A\\x80E\\r\\0 \\b((," A\\fj"\\x07A \\fE\\r\\0  A\\bjA \\fE\\r\\0 
 5\\b 5\\fB \\x86\\x847\\x88 \\b((, AjA\\fE\\r\\0 
 (A\\0G6\\x90A\\x07!@@@ \\b((,"("\\vA\\x07q"\\r@  \\x07A\\b \\rk\\fE\\r A\\x82E\\r \\vAkA\\x07q"E\\r\\f\\v A\\x82E\\r\\v  A\\fj \\f\\r\\vA\\0!\\f\\vA\\0! \\b((, AjA\\b\\fE\\r\\0 
 ("6\\x94 @ 
 A "6\\x98 @A\\0!\\v@ 
(\\x98@ \\b((," A\\fjA \\f@  A\\bjA \\f\\r\\vA\\0!\\f\\v \\vAtj" 5\\b 5\\fB \\x86\\x847\\0A\\0! \\b((, Aj"\\x07A\\b\\fE\\r  (:\\0\\b \\b((, A	jA\\fE\\r \\b((, \\x07A\\fE\\r  -\\0A\\xFEq -\\0Aqr:\\0 \\b((, \\x07A\\fE\\r  -\\0AtAq -\\0A\\xFDqr:\\0@@ \\b((,"\\x07(A\\x07q"\\r@ \\x07 A\\fjA\\b \\rk\\fE\\r \\x07 \\rA\\xE6\\0j"\\rAvE\\r \\rA\\x07q"\\rE\\r\\f\\vA!\\r \\x07A\\rE\\r\\v \\x07 A\\fj \\r\\fE\\r\\v \\b((, AjA\\b\\fE\\r  ("\\x07:\\0@ \\x07A\\xFFq"\\rE\\r\\0  \\rA"\\x076@ \\x07@A\\0!\\x07 \\r\\r\\f\\v \\b(\\0A\\b6\\0\\f\\v@ (@ \\b((,"\\r A\\fjA \\f@ \\r A\\bjA \\f\\r\\vA\\0!\\f\\v \\x07Atj"\\r 5\\b 5\\fB \\x86\\x847\\0A\\0! \\b((, AjA\\b\\fE\\r \\r (:\\0\\b \\b((,"\\r(A\\x07q"\\x7F \\r A\\fjA\\b k\\fE\\r ArA\\v! \\r AvE\\r A\\x07q"@ \\r A\\fj \\fE\\r\\v \\x07Aj"\\x07 -\\0I\\r\\0\\v\\vA! \\vAj"\\v 
(\\x94I\\r\\0\\v\\f\\v \\b(\\0A\\b6\\0\\f\\v \\b((,A\\x7F6(\\v Aj$\\0 !\\x07\\f\\v \\fA@k!A\\0!\\x07#\\0Ak"
$\\0@ \\b((, 
A\\fj"A \\fE\\r\\0  
(\\f"A\\0 AI\\x1B6\\0 \\b((, A \\fE\\r\\0 
(\\f" \\b((,"\\v"((K@ A\\x7F6(\\f\\v@@ A\\x7FF@ A\\x006\\f\\v  Aj\\r"6 \\r\\v \\b(\\0A\\b6\\0\\f\\v@ E@A\\0!\\f\\v \\v  E\\r (!\\v  jA\\0:\\0\\0 \\b((, 
A\\fjA \\fE\\r\\0 
(\\f" \\b((,"\\v"((K@ A\\x7F6(\\f\\v@@ A\\x7FF@ A\\x006\\b\\f\\v  Aj\\r"6\\b \\r\\v \\b(\\0A\\b6\\0\\f\\v@ E@A\\0!\\f\\v \\v  E\\r (\\b!\\v  jA\\0:\\0\\0 \\b((, A\\fjA \\fE\\r\\0 \\b((, AjA \\fE\\r\\0 \\b((, AjA \\fE\\r\\0 \\b((, AjA \\fE\\r\\0 \\b((, AjA \\fE\\r\\0 (" \\b((,"((K@ A\\x7F6(\\f\\v A  AM\\x1B\\r"6  E@ \\b(\\0A\\b6\\0\\f\\v @   E\\r\\vA!\\x07\\v 
Aj$\\0\\f\\v @ \\f \\r"6@ E@ \\b(\\0A\\b6\\0A\\0!\\x07\\f\\v   !\\x07\\f\\v \\fA\\x006@\\f\\v @ \\f \\r"6D E@ \\b(\\0A\\b6\\0A\\0!\\x07\\f\\v   !\\x07\\f\\v \\fA\\x006DA!\\x07\\v@ \\b("(,"((@ (\\x84%E@ A6\\xDCA \\bA ($ ( \\0\\0\\vA! \\b(\\0"(\\0AF@ A6\\0\\v \\b((,B\\x80\\x80\\x80\\x80p7$\\f\\v B\\x80\\x80\\x80\\x80p7$ \\x07E@A!\\f\\vA\\0! (\\x84%\\r\\0 ("E\\r\\0 \\b \\fA0j ($ \\0\\0\\v@@@@@@@ 	Ak\\0\\v \\f(D"\\r\\f\\v \\f(D"@ 	\\v \\f(H"
@A\\0!@ \\f(L Atj("@ 	 \\f(H!
\\v Aj" 
I\\r\\0\\v\\v \\f(L"\\r\\f\\v \\f(\\xD4"
E \\f(\\xD8"ErE@A\\0!@ \\f(\\xD8 Atj("@ 	 \\f(\\xD4!
\\v Aj" 
I\\r\\0\\v \\f(\\xD8!\\v \\r\\f\\v \\f(D"@ 	\\v \\f(H"@ 	\\v \\f(\\\`"\\r\\f\\v \\f(@"E\\r\\v 	\\v \\r\\vA! E\\r@@ \\b("\\x07(\\f"E\\r\\0 \\b \\x07A\\xB8\\xC1\\0j" \\x07($ \\0 \\b(!\\x07\\r\\0 \\x07(,"("A\\x07q\\r\\0  )\\0 (\\b (kAt (\\fAtj kAv\\xAD}7\\0\\f\\v \\x07B\\x007\\xB8A\\v \\b(\\0A6\\0\\f\\vA\\0!\\v \\fA\\xF0\\x1Bj$\\0 \\0(\\0!\\b@@ E\\r\\0@ \\r\\0 \\b(E\\r\\0 \\0((\\xF0	"E\\r\\0 (\\0(\\0AF\\r\\v \\b(\\0AG\\r (\\x90JB\\x007\\f\\v \\b(\\0 (\\x90JB\\x007A\\0!\\x07AF\\r\\v \\bA6\\0A\\0!\\x07\\f\\v B\\x007\\b@@@ \\r\\0 -\\0\\0! \\0("\\b(\\xBC	"@ \\0 A\\bj \\b(\\xCC	 \\0AF\\r\\v@@ A\\xFF\\0q\\0\\v \\0(\\0 )\\b7\\xE8\\f\\v \\0(\\0")\\xF0B\\0R\\r\\0  )\\b7\\xF0\\v@ \\0("\\x07(\\xC0\\x07"E\\r\\0 \\0(\\0"	)\\xF8P\\r\\0 (\\0"\\vE\\r\\0 \\x07(\\xD0	"\\r \\vO\\r\\0 \\x07)\\xE0	"# 	($"\\xAD|B}!$@ \\rAl"\\b (j)\\0"% $V\\r@ # %X@@ )\\bB\\0R\\r\\0 \\x07(\\xBC	"E\\r\\0 \\0 A\\bj \\x07(\\xCC	 \\0AF\\r \\0(\\0!	 \\0(!\\x07\\v \\x07(\\xC0\\x07"( \\bj"\\b #7\\0 	)\\xF8!% )\\b!& \\b 6 \\b & %}7\\b \\x07 \\x07(\\xD0	Aj6\\xD0	 (\\0!\\v\\f\\v \\x07 \\x07(\\xD0	Aj6\\xD0	\\v \\rAj"\\r \\vI\\r\\0\\v\\v \\0  \\x1B  \\x07(\\xC8\\x07 \\x07(\\xCC	 \\x07(\\xC0	\\x07\\0E\\r\\v \\0(\\0 (\\x90JB\\x007A6\\0A\\0!\\x07\\f\\v \\0(" )\\xD8	 \\x1B\\xAD|7\\xD8	  )\\xE0	 \\xAD|7\\xE0	A!\\x07  (\\xE8	"\\b (\\xC8\\x07Aj"  \\bI\\x1B6\\xE8	 (\\x90JB\\x007 E\\r\\0  \\x1B (\\xA8"  \\x1BK\\x1B6\\xA8 \\0("\\0 \\x1B \\0(\\xAC"\\0 \\0 \\x1BI\\x1B6\\xAC\\v Aj$\\0 \\x07\\v	\\0 \\0\\xBDB4\\x88\\xA7\\vO| \\0 \\0\\xA2"\\0 \\0 \\0\\xA2"\\xA2 \\0DiP\\xEE\\xE0B\\x93\\xF9>\\xA2D'\\xE8\\x87\\xC0V\\xBF\\xA0\\xA2 DB:\\xE1SU\\xA5?\\xA2 \\0D\\x81^\\f\\xFD\\xFF\\xFF\\xDF\\xBF\\xA2D\\0\\0\\0\\0\\0\\0\\xF0?\\xA0\\xA0\\xA0\\xB6\\v\\0 \\0E@A\\0\\vA\\xD0\\xD8\\0 \\x006\\0A\\x7F\\v\\xF3\\x7F@ \\0E@A\\xB0\\xD8\\0(\\0@A\\xB0\\xD8\\0(\\0-!\\vA\\xF0\\xE0\\0(\\0@A\\xF0\\xE0\\0(\\0- r!\\vA\\xF4\\xE0\\0(\\0"\\0E\\r@ \\0(L \\0( \\0(G@ \\0- r!\\v \\0(8"\\0\\r\\0\\v\\f\\v \\0(LA\\0H!@@ \\0( \\0(F\\r\\0 \\0A\\0A\\0 \\0($\\0 \\0(\\r\\0A\\x7F! E\\r\\f\\v \\0(" \\0(\\b"G@ \\0  k\\xACA \\0((\\0\\vA\\0! \\0A\\x006 \\0B\\x007 \\0B\\x007 \\r\\v\\v \\v\\x9C\\r~	\\x7F#\\0Ak"\\v$\\0@ \\0("	E@ \\0(\\b!\\f\\v \\0A\\x7F6,@ \\0("\\x07 	O@ \\0(\\0!
\\f\\v \\0(\\0!
 \\0( "E\\r\\0\\x7F \\0(" A?K\\r\\0 A\\bv 
 \\x07Atj)\\0"B8 \\xAD"}"\\x88\\xA7A\\xFFqA\\0 B\\xC0\\0T\\x1BsAt/\\x90" A\\btA\\x80\\xFEqs" A7K\\r\\0 A\\bv B0 }"\\x88\\xA7A\\xFFqA\\0 B\\xC0\\0T\\x1BsAt/\\x90"\\b A\\btA\\x80\\xFEqs" A/K\\r\\0 A\\bv B( }"\\x88\\xA7A\\xFFqA\\0 B\\xC0\\0T\\x1BsAt/\\x90" \\bA\\btA\\x80\\xFEqs" A'K\\r\\0 A\\bv B  }"\\x88\\xA7A\\xFFqA\\0 B\\xC0\\0T\\x1BsAt/\\x90"\\b A\\btA\\x80\\xFEqs" AK\\r\\0 A\\bv B }"\\x88\\xA7A\\xFFqA\\0 B\\xC0\\0T\\x1BsAt/\\x90" \\bA\\btA\\x80\\xFEqs" B \\x84B7V\\r\\0 A\\bv B }"\\x88\\xA7A\\xFFqA\\0 B\\xC0\\0T\\x1BsAt/\\x90"\\b A\\btA\\x80\\xFEqs" AK\\r\\0 A\\bv B\\b }"\\x88\\xA7A\\xFFqA\\0 B\\xC0\\0T\\x1BsAt/\\x90" \\bA\\btA\\x80\\xFEqs" B0\\x84B7V\\r\\0 A\\x07vA\\xFEq/\\x90 A\\btA\\x80\\xFEqs\\v! \\x07Aj!\\x07 \\0A\\x006  \\0 6\\v \\x07 	I@ 	 \\x07k! 
 \\x07Atj! \\0(!\\x07@ \\x07 )\\0"B0\\x88\\xA7s"A\\xFFqAtA\\x905j/\\0 A\\x07vA\\xFEq/\\x909s B(\\x88\\xA7A\\xFFqAt/\\x901s B \\x88\\xA7A\\xFFqAt/\\x90-s \\xA7"AvA\\xFEq/\\x90)s AvA\\xFEq/\\x90%s A\\x07vA\\xFEq/\\x90!s A\\xFFqAt/\\x90s!\\x07 A\\bj! Ak"\\r\\0\\v \\0 \\x07A\\xFF\\xFFq6\\v \\0A\\x006 \\0(\\b 	k \\0(\\fA\\0GjAt"@ 
 
 	Atj \\xFC
\\0\\0\\v \\0A\\x006 \\0 \\0(\\b 	k"6\\b\\v \\v \\0( kAt" \\0(\\f"\\bk6\\fA\\0!@  \\bF\\r\\0 \\0(\\0 Atj" \\bj )\\0! \\b@  B8\\x86 B\\x80\\xFE\\x83B(\\x86\\x84 B\\x80\\x80\\xFC\\x07\\x83B\\x86 B\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 B\\b\\x88B\\x80\\x80\\x80\\xF8\\x83 B\\x88B\\x80\\x80\\xFC\\x07\\x83\\x84 B(\\x88B\\x80\\xFE\\x83 B8\\x88\\x84\\x84\\x847\\0\\v \\vA\\fj \\0(4 \\0(0\\0E@ \\0(\\0 \\0(\\bAtj 7\\0\\f\\v@ \\0(\\b" \\v(\\f \\0(\\f Atjj"	A\\x07jAv"\\fO\\r\\0 \\0(\\0!
 \\f "kAq"@A\\0!\\x07@ 
 Atj"\\b \\b)\\0"B8\\x86 B\\x80\\xFE\\x83B(\\x86\\x84 B\\x80\\x80\\xFC\\x07\\x83B\\x86 B\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 B\\b\\x88B\\x80\\x80\\x80\\xF8\\x83 B\\x88B\\x80\\x80\\xFC\\x07\\x83\\x84 B(\\x88B\\x80\\xFE\\x83 B8\\x88\\x84\\x84\\x847\\0 Aj! \\x07Aj"\\x07 G\\r\\0\\v\\v  \\fkA|K\\r\\0@ 
 Atj" )\\0"B8\\x86 B\\x80\\xFE\\x83B(\\x86\\x84 B\\x80\\x80\\xFC\\x07\\x83B\\x86 B\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 B\\b\\x88B\\x80\\x80\\x80\\xF8\\x83 B\\x88B\\x80\\x80\\xFC\\x07\\x83\\x84 B(\\x88B\\x80\\xFE\\x83 B8\\x88\\x84\\x84\\x847\\0  )\\b"B8\\x86 B\\x80\\xFE\\x83B(\\x86\\x84 B\\x80\\x80\\xFC\\x07\\x83B\\x86 B\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 B\\b\\x88B\\x80\\x80\\x80\\xF8\\x83 B\\x88B\\x80\\x80\\xFC\\x07\\x83\\x84 B(\\x88B\\x80\\xFE\\x83 B8\\x88\\x84\\x84\\x847\\b  )"B8\\x86 B\\x80\\xFE\\x83B(\\x86\\x84 B\\x80\\x80\\xFC\\x07\\x83B\\x86 B\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 B\\b\\x88B\\x80\\x80\\x80\\xF8\\x83 B\\x88B\\x80\\x80\\xFC\\x07\\x83\\x84 B(\\x88B\\x80\\xFE\\x83 B8\\x88\\x84\\x84\\x847  )"B8\\x86 B\\x80\\xFE\\x83B(\\x86\\x84 B\\x80\\x80\\xFC\\x07\\x83B\\x86 B\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 B\\b\\x88B\\x80\\x80\\x80\\xF8\\x83 B\\x88B\\x80\\x80\\xFC\\x07\\x83\\x84 B(\\x88B\\x80\\xFE\\x83 B8\\x88\\x84\\x84\\x847 Aj" \\fG\\r\\0\\v\\v \\0 	A\\x07q6\\f \\0 	Av6\\bA!\\v \\vAj$\\0 \\vH\\x7F\\x7F AM@ \\0(\\0! \\0Aj\\f\\v A k! \\0\\v(\\0! \\0  t6\\0 \\0  t A  kvr6\\v\\xAE\\x7F#\\0A\\xF0k"$\\0  6\\xEC  6\\xE8  \\x006\\0 E!	@@@@ AG@ \\0!\\x07A!\\b\\f\\v \\0!\\x07A!\\b \\r\\0 \\0!\\f\\v@ \\x07  Atj"
(\\0k" \\0'A\\0L@ \\x07!\\f\\v 	A\\x7Fs!\\vA!	@ \\v AHrAqE@ 
A\\bk(\\0!
 \\x07Ak"\\v 'A\\0N\\r \\v 
k 'A\\0N\\r\\v  \\bAtj 6\\0 A\\xE8j  \\\\"1 \\bAj!\\b  j! (\\xEC! !\\x07  (\\xE8"AGr\\r\\f\\v\\v \\x07!\\f\\v 	E\\r\\v  \\b[   =\\v A\\xF0j$\\0\\vK\\x7F \\0(! \\0\\x7F AM@ \\0(\\0! \\f\\v A k! !A\\0\\v" v6 \\0 A  kt  vr6\\0\\v\\x97\\x7F~ A\\x006\\0@ \\0\\x7F@@@ \\0(!@ \\0(" \\0(\\bO\\r\\0@ A\\xC0\\0O@ (\\0!\\f\\v (\\0! \\0(\\0 Atj)\\0 \\xAD\\x86"B\\0R\\r\\v   kA@k6\\0A\\0! \\0A\\x006 \\0 \\0(Aj"6  \\0(\\bO\\r\\0 \\0(\\0!@ (\\0!  Atj)\\0"PE\\r  A@k6\\0 \\0A\\x006 \\0 \\0(Aj"6  \\0(\\bI\\r\\0\\v\\v  \\0(\\fAt"I@ \\0(\\0 Atj)\\0B\\x7FA\\xC0\\0 k\\xAD\\x86\\x83 \\xAD\\x86"B\\0R\\r  (\\0  kj6\\0 \\0 6\\v \\0.\\r\\0\\vA\\0\\v  y\\xA7" (\\0j6\\0  \\0(jAj\\f\\v   y\\xA7"j6\\0 \\0  \\0(jAj"6 A\\xC0\\0I\\r \\0 \\0(Aj6A\\0\\v6\\vA\\v\\xDF\\v
\\x7F~@ \\0("AK\\r\\0 (!\\b (!	  A\\vE\\r\\0 \\0(\\0"A\\xFF\\0K\\r\\0  A\\x07\\vE\\r\\0 \\0(\\b! \\0(\\0AF@  \\0(kA'j!\\v A\\xFF\\xFF\\xFF\\x07K\\r\\0  A\\vE\\r\\0@@@@@@@@@@@ \\0(\\0\\x07\\0\\b\\x07\\v \\0(E\\r\\bA\\0!\\f\\v \\0("A\\xFF\\xFFK\\r	  A\\vE\\r	 \\0("A\\xFF\\xFFK\\r	  A\\vE\\r	 \\0("A\\xFF\\xFF\\xFF\\x07K\\r	  A\\vE\\r	 \\0("A\\xFF\\xFF\\xFF\\x07K\\r	  A\\vE\\r	 \\0( "A\\xFF\\xFF?K\\r	  A\\vE\\r	 \\0($Ak"A\\x07K\\r	  A\\vE\\r	 \\0((Ak"AK\\r	  A\\vE\\r	@ \\0)0"\\fB\\x80\\x80\\x80\\x80\\x80Z@ B\\0A$(\\r\\f\\v\\v  \\fA$(\\r\\0\\f
\\v  \\0A8jA\\x1B\\r\\x07\\f	\\v  \\0(\\bAt\\r\\f\\b\\v  \\0AjA\\x1BE\\r\\x07  \\0( \\0(\\bAk\\x1B\\r\\f\\x07\\v@  Al" \\0(j)\\0"\\fB \\x88\\xA7A \\vE\\r  \\f\\xA7A \\vE\\r  \\0( j)\\b"\\fB \\x88\\xA7A \\vE\\r  \\f\\xA7A \\vE\\r \\0( j("A\\xFF\\xFFK\\r  A\\vE\\r Aj" \\0(I\\r\\0\\v\\f\\v A'DE\\r A\\x8CA'\\x1BE\\r  \\0(DE\\r \\0(E\\r@  At" \\0(j(\\0"A\\xFFqA\\b\\vE\\r  A\\bvA\\xFFqA\\b\\vE\\r  AvA\\xFFqA\\b\\vE\\r  AvA\\b\\vE\\r \\0( j"(!
@ (" (" (\\0"AvjAjK\\r\\0 ( AtjA?jAv j" M\\r\\0 A\\x81\\x80\\x80K\\r\\x07 (\\0 Av"\\v j   k \\vI\\x1B"\\x7F A\\xFF\\xFF\\xFF\\xFFK\\r\\b AtA\\0\\v"E\\r  6  6\\0\\vA\\0! @@   
j-\\0\\0A\\b\\vE\\r\\x07 Aj" G\\r\\0\\v\\v Aj" \\0(I\\r\\0\\v\\f\\v  \\0( \\0(\\b\\x1B\\r\\f\\v  \\0(A \\vE\\r  \\0(;"A \\vE\\r  \\0( \\x1BE\\r  \\0(;"A \\vE\\r  \\0( \\x1BE\\r  \\0(A \\vE\\r  \\0( A \\vE\\r  \\0($A \\vE\\r  \\0((A \\vE\\r  \\0(,A \\vE\\r  \\0(0 \\0(,\\x1B\\r\\f\\v  \\0AjA\\x80\\x1BE\\r  \\0)\\x98A\\xC0\\0(E\\r  \\0(\\xA0A\\0GA\\vE\\r A\\x97E\\r \\0(\\xA4"A\\xFFK\\r  A\\b\\vE\\r \\0(\\xA4E\\r\\0@  \\0(\\xA8 Atj")\\0A\\xC0\\0(E\\r  -\\0\\bA\\b\\vE\\r  A	jA\\f\\x1BE\\r  -\\0AqA\\vE\\r  -\\0AvAqA\\vE\\r A\\xEE\\0E\\r  -\\0A\\b\\vE\\r@ -\\0E\\r\\0A\\0!@  ( Atj")\\0A\\xC0\\0(E\\r  -\\0\\bA\\b\\vE\\r A@ Aj" -\\0O\\r\\f\\v\\v\\f\\v Aj" \\0(\\xA4I\\r\\0\\v\\v ( (Atj"\\0 \\bAt 	j"I\\r \\0 k"\\0A\\x07q\\r\\0 \\0 AtA jF!\\x07\\v \\x07\\vA\\0\\v\\x95\\x7F \\0Aj"A\\x07jAxq" j \\0 \\0(\\0"jAkM\\x7F \\0(" \\0(\\b"6\\b  6  G@ \\0 \\0Ak(\\0A~qk"  k" (\\0j"6\\0  A|qjAk 6\\0 \\0 j"\\0  k"6\\0\\v\\x7F  AjO@ \\0 j"  kA\\bk"6\\b A\\bj" A|qjAk Ar6\\0 \\x7F (\\bA\\bk"A\\xFF\\0M@ AvAk\\f\\v A g"kvAs AtkA\\xEE\\0j A\\xFFM\\r\\0A? A kvAs AtkA\\xC7\\0j" A?O\\x1B\\v"At"A\\xE0\\xD8\\0j6\\f  A\\xE8\\xD8\\0j"(\\x006  6\\0 ( 6A\\xE8\\xE0\\0A\\xE8\\xE0\\0)\\0B \\xAD\\x86\\x847\\0 \\0 A\\bj"6\\0 \\0 A|qj\\f\\v \\0 j\\vAk 6\\0 \\0AjA\\0\\v\\v\\xC8\\x7F~@ \\0("A\\x07q\\r\\0\\x7F E@ \\0(! \\0(\\0!A\\0\\f\\v@ \\0(" \\0(G\\r\\0   A\\xFF\\0jAv"\\x07j"O\\r\\0 A\\x81\\x80\\x80K\\rA\\0! \\0(\\0  Av"\\bj  \\x07 \\bI\\x1B"\\x7F A\\xFF\\xFF\\xFF\\xFFK\\r AtA\\0\\v"E\\r \\0 6 \\0 6\\0 \\0(! \\0(!\\v \\0(\\0" Atj \\0)\\bA\\xC0\\0 k\\xAD\\x86"	B8\\x86 	B\\x80\\xFE\\x83B(\\x86\\x84 	B\\x80\\x80\\xFC\\x07\\x83B\\x86 	B\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 	B\\b\\x88B\\x80\\x80\\x80\\xF8\\x83 	B\\x88B\\x80\\x80\\xFC\\x07\\x83\\x84 	B(\\x88B\\x80\\xFE\\x83 	B8\\x88\\x84\\x84\\x847\\0 Av\\v!\\0  6\\0  \\0 Atj6\\0A!\\v \\v\\xC0\\v\\b\\x7F~A!@@@@@@ (\\0\\0\\v  (\\xA8"A\\0GA\\b\\vE\\r @ A!O@ Ak!A!  E\\r\\v A \\vE\\r\\v )\\b"B\\x7F \\xAD\\x86B\\x7F\\x85\\x83!\\r A!O@ \\r  A\\xC0\\0I\\x1B"\\rB \\x88\\xA7! A k"AMA\\0  v\\x1B\\r   \\vE\\r  \\r\\xA7A \\vE\\r\\f\\v A GA\\0 \\r\\xA7" v\\x1B\\r   \\vE\\r\\f\\v ("\\bAt"A\\xFFK\\r   (\\xA8"A\\0GrArA\\b\\vE\\r @ A!O@ Ak!A!  E\\r\\v A \\vE\\r\\v (@ Aj!	B\\x7F \\xAD\\x86B\\x7F\\x85!A\\0! A\\xC0\\0I!
 A!I!\\v A k"AK!\\f@ 	 Atj)\\0" \\x83!\\r@ \\vE@ \\fA \\r  
\\x1B"\\rB \\x88\\xA7"\\x07 v\\x1BE\\r  \\x07 \\vE\\r  \\r\\xA7A \\v\\r\\f\\v A GA\\0 \\r\\xA7"\\x07 v\\x1B\\r  \\x07 \\vE\\r\\v Aj" (I\\r\\0\\v\\v (\\b"AK\\r  A\\vE\\rA! (\\bAK\\r (\\f"AK\\r  A\\vE\\r (\\b"AK\\r  (8  \\bk ( ("(\\0 ( (\\f AFFE\\r\\f\\v ("\\bAtAk"A\\xFFK\\r   (\\xA8"A\\0GrA\\xC0\\0rA\\b\\vE\\r @ A!O@ Ak!A!  E\\r\\v A \\vE\\r\\v (@ A\\xA0j!	B\\x7F \\xAD\\x86B\\x7F\\x85!A\\0! A\\xC0\\0I!
 A!I!\\v A k"AK!\\f@ 	 Atj)\\0" \\x83!\\r@ \\vE@ \\fA \\r  
\\x1B"\\rB \\x88\\xA7"\\x07 v\\x1BE\\r  \\x07 \\vE\\r  \\r\\xA7A \\v\\r\\f\\v A GA\\0 \\r\\xA7"\\x07 v\\x1B\\r  \\x07 \\vE\\r\\v Aj" (I\\r\\0\\v\\v (Ak"AK\\r  A\\vE\\r  (AqA\\vE\\r (@ A j!A\\0!@   Atj(\\0A\\x7FA\\x7F ("tA\\x7Fs A O\\x1Bq \\vE\\r Aj" (I\\r\\0\\v\\v (\\b"AK\\r  A\\vE\\rA! (\\bAK\\r (\\f"AK\\r  A\\vE\\r (\\b"AK\\r  (\\xA0  \\bk ( ("(\\0 ( (\\f AFFE\\r\\f\\v  (\\xA8"A\\0GArA\\b\\vE\\r\\0 @ A!O@ Ak!\\x07A!  \\x07E\\r\\v A \\vE\\r\\v (\\b! (\\fE@ E\\rA\\x7FA\\x7F tA\\x7Fs A O\\x1B!\\x07A\\0!@  \\x07  Atj(\\0q \\vE\\r  Aj"G\\r\\0\\v\\f\\v E\\rB\\x7F \\xAD\\x86B\\x7F\\x85!A\\0! A\\xC0\\0I!\\b A!I!	 A k"\\x07AK!
@  Atj)\\0" \\x83!\\r\\x7F 	E@ 
A \\r  \\b\\x1B"\\rB \\x88\\xA7" \\x07v\\x1BE\\r   \\x07\\vE\\r  \\r\\xA7A \\v\\f\\v A GA\\0 \\r\\xA7" v\\x1B\\r   \\v\\vE\\rA!  Aj"G\\r\\0\\v\\f\\v \\0(\\0A\\x076\\0A\\0!\\v \\v\\xF9w5\\x7F$~{\\x07|}#\\0A\\xC0\\bk"$\\0 \\0(\\0(!& \\v\\x7F \\0((\\xAC	@A\\x7F AK\\r\\v \\x07(\\0"\\f A K6\\f \\fA6\\0 \\f 6\\b \\f(\\xA8  ljA\\bj\\v" 6\\0@ AI\\r\\0@ A\\x1BM@ Ak! Aj!\\r \\0(!\\f AlA\\xC4\\0kgAs jAM@ \\r  A\\xA0j \\f(\\xEC\\b\\0!\\f\\v \\r  A\\xA0j \\f(\\xF0\\b\\0!\\f\\v A M@ Aj Ak A\\xA0j \\0((\\xF4\\b\\0!\\f\\v }@@ } }@ }\\x7F@\\x7F@ Ak"A}H\\r\\0 A j! )\\b"H )"L )"IB\\x86}|"A AB?\\x87"A\\x85 A}"B )\\0"M I HB\\x86}|"A AB?\\x87"A\\x85 A}"A|!E BB\\x80\\x80\\x80\\x80\\bT AB\\x80\\x80\\x80\\x80\\bTq!\\r L I}"A AB?\\x87"A\\x85 A}"P I H}"A AB?\\x87"A\\x85 A}"C H M}"A AB?\\x87"A\\x85 A}"F||!D L LB?\\x87"A\\x85 A}"J I IB?\\x87"A\\x85 A}"N H HB?\\x87"A\\x85 A}"O M MB?\\x87"A\\x85 A}"K|||!G L M} H I}B~|"A AB?\\x87"A\\x85 A}"BB\\x80\\x80\\x80\\x80\\bT! P C F\\x84\\x84B\\x80\\x80\\x80\\x80\\bT! JB\\x80\\x80\\x80\\x80\\bT NB\\x80\\x80\\x80\\x80\\bTq OB\\x80\\x80\\x80\\x80\\bTq KB\\x80\\x80\\x80\\x80\\bTq!B\\0!C\\x7F\\x7F AI@A\\f\\v\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 B\\xFD\\0!h\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 E\\xFD\\0!i\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 D\\xFD\\0!j\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 G\\xFD\\0!k A~q!@ m\\xFD\\f\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0  Atj"\\fAk\\xFD\\0\\0"s\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xD5 \\f\\xFD\\0\\0"l\\xFD\\xCE \\fA k\\xFD\\0\\0\\xFD\\xCE \\fAk\\xFD\\0\\0"f \\fA\\bk\\xFD\\0\\0"r\\xFD\\xCEA\\xFD\\xCB\\xFD\\xD1\\xFD\\xC0"e\\xFD\\0B\\xFF\\xFF\\xFF\\xFF\\x07V\\x1BB\\x7FB\\0 e\\xFDB\\xFF\\xFF\\xFF\\xFF\\x07V\\x1B\\xFD\\xFDP!m n\\xFD\\f\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 l f\\xFD\\xD1 s r\\xFD\\xD1\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xD5\\xFD\\xCE\\xFD\\xC0"f\\xFD\\0B\\xFF\\xFF\\xFF\\xFF\\x07V\\x1BB\\x7FB\\0 f\\xFDB\\xFF\\xFF\\xFF\\xFF\\x07V\\x1B\\xFD\\xFDP!n e g\\xFD\\xCE!g f h\\xFD\\xCE!h p\\xFD\\f\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 l r\\xFD\\xD1\\xFD\\xC0"e\\xFD\\0B\\xFF\\xFF\\xFF\\xFF\\x07V\\x1BB\\x7FB\\0 e\\xFDB\\xFF\\xFF\\xFF\\xFF\\x07V\\x1B\\xFD\\xFDP!p o\\xFD\\f\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 l rA\\xFD\\xCB\\xFD\\xD1 s\\xFD\\xCE\\xFD\\xC0"f\\xFD\\0B\\xFF\\xFF\\xFF\\xFF\\x07V\\x1BB\\x7FB\\0 f\\xFDB\\xFF\\xFF\\xFF\\xFF\\x07V\\x1B\\xFD\\xFDP!o e j\\xFD\\xCE!j q\\xFD\\f\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 l\\xFD\\xC0"e\\xFD\\0B\\xFF\\xFF\\xFF\\xFF\\x07V\\x1BB\\x7FB\\0 e\\xFDB\\xFF\\xFF\\xFF\\xFF\\x07V\\x1B\\xFD\\xFDP!q f i\\xFD\\xCE!i e k\\xFD\\xCE!k Aj" G\\r\\0\\vA\\0  qA?\\xFD\\xCBA?\\xFD\\xCC\\xFDS\\x1B!A\\0  pA?\\xFD\\xCBA?\\xFD\\xCC\\xFDS\\x1B!A\\0 \\r oA?\\xFD\\xCBA?\\xFD\\xCC\\xFDS\\x1B!\\rA\\0  nA?\\xFD\\xCBA?\\xFD\\xCC\\xFDS\\x1B! g g e\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\0!C h h e\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\0!B i i e\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\0!E j j e\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\0!D k k e\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\0!G mA?\\xFD\\xCBA?\\xFD\\xCC\\xFDSAs"\\f  F\\r \\fAq\\v!@ A\\0  Atj"\\fAk)\\0"NB~ \\f)\\0"F| \\fA k)\\0| \\fAk)\\0"O \\fA\\bk)\\0"J|B\\x86}"A AB?\\x87"A\\x85 A}"KB\\xFF\\xFF\\xFF\\xFF\\x07X\\x1B! A\\0 F O} N J}B~|"A AB?\\x87"A\\x85 A}"AB\\xFF\\xFF\\xFF\\xFF\\x07X\\x1B! C K|!C A B|!B A\\0 F J}"A AB?\\x87"A\\x85 A}"KB\\xFF\\xFF\\xFF\\xFF\\x07X\\x1B! \\rA\\0 F JB\\x86} N|"A AB?\\x87"A\\x85 A}"AB\\xFF\\xFF\\xFF\\xFF\\x07X\\x1B!\\r D K|!D A E|!E A\\0 F FB?\\x87"A\\x85 A}"AB\\xFF\\xFF\\xFF\\xFF\\x07X\\x1B! A G|!G Aj" G\\r\\0\\v A\\0G\\v!\\fB\\x7F!AC\\0\\0\\bB!{ }C\\0\\0\\bB E\\r\\0C\\0\\0\\bB GB\\x7FQ\\r\\0 GP\\r G"A\\xBAD\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6\\v8\\xA0A\\0 E A DXr\\r DPE\\rC\\0\\0\\0\\0!{A\\f\\v A\\x006\\xA0C\\0\\0\\bB!{A\\0\\v!  {8\\xA4C\\0\\0\\bB\\f\\v D\\xBAD\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6!{ D!AA\\v!  {8\\xA4C\\0\\0\\bB!{C\\0\\0\\bB \\rE\\rC\\0\\0\\bB A EX\\r EPE\\rA!C\\0\\0\\0\\0\\v8\\xA8C\\0\\0\\bB\\f\\vA! E"A\\xBAD\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6\\v8\\xA8 E A BXr\\r BPE\\rA!C\\0\\0\\0\\0\\v8\\xACC\\0\\0\\bB\\f\\v B\\xBAD\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6!{A! B!A\\v  {8\\xACC\\0\\0\\bB A CV \\fqE\\r\\0A!C\\0\\0\\0\\0 CP\\r\\0 C\\xBAD\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6\\v8\\xB0\\v@@ (\\xB8k\\r\\0 *\\xA4C\\0\\0\\0\\0\\\\\\r\\0@ A!O@ )\\0"A\\xA7!A!\\f\\f\\v (\\0!A!\\f@   \\fAtj(\\0G\\r \\fAj"\\f G\\r\\0\\v\\f\\v@ A  \\fAtj)\\0R\\r  \\fAj"\\fG\\r\\0\\v\\f\\vAA &AK\\x1B!5 \\0(\\0!@ \\0((\\xA8	@ (\\xAC  A\\x7FGr\\r\\vA\\0  (\\xB8"\\f\\x1B"A  \\f\\x1B"\\f Ak  \\fK\\x1B"\\x1BK\\r\\0 Ak!  Atj! \\xB3!{ A!I!% !@ At"\\r A\\xA0jj*\\0 {\\\`E@  k! \\b !E"At"\\fj(\\0! \\x07 \\fj(\\0!" 	 \\fj(\\0! (\\x8CJ! (\\x88J!& \\0(\\0(\\xBC!@@  jA M@  \\rj!@@@@ \\0\\v A\\0L\\rA\\0!  I Ak  AtjIq A\\x07MrE@ A\\xFC\\xFF\\xFF\\xFF\\x07q!A\\0!\\r@  \\rAt"\\fj \\f j"\\fA\\bk\\xFD\\0\\0\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xB5 \\f\\xFD\\0\\0\\xFD\\xAE \\fAk\\xFD\\0\\0\\xFD\\xAE \\fA\\fk\\xFD\\0\\0 \\fAk\\xFD\\0\\0\\xFD\\xAEA\\xFD\\xAB\\xFD\\xB1\\xFD\\v\\0 \\rAj"\\r G\\r\\0\\v  F\\r\\v@  At"\\fj \\f j"\\fA\\bk(\\0Al \\f(\\0j \\fAk(\\0j \\fA\\fk(\\0 \\fAk(\\0jAtk6\\0 Aj" G\\r\\0\\v\\f\\v A\\0L\\rA\\0!  I A\\fk  AtjIq A\\x07MrE@ A\\xFC\\xFF\\xFF\\xFF\\x07q!A\\0!\\r@  \\rAt"\\fj \\f j"\\f\\xFD\\0\\0 \\fA\\fk\\xFD\\0\\0\\xFD\\xB1 \\fA\\bk\\xFD\\0\\0 \\fAk\\xFD\\0\\0\\xFD\\xB1\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xB5\\xFD\\xAE\\xFD\\v\\0 \\rAj"\\r G\\r\\0\\v  F\\r\\v@  At"\\fj \\f j"\\f(\\0 \\fA\\fk(\\0k \\fA\\bk(\\0 \\fAk(\\0kAlj6\\0 Aj" G\\r\\0\\v\\f\\v A\\0L\\rA\\0!\\r  I A\\bk  AtjIq A\\bIrE@ A\\xFC\\xFF\\xFF\\xFF\\x07q!\\rA\\0!@  At"\\fj \\f j"\\f\\xFD\\0\\0 \\fAk\\xFD\\0\\0A\\xFD\\xAB\\xFD\\xB1 \\fA\\bk\\xFD\\0\\0\\xFD\\xAE\\xFD\\v\\0 Aj" \\rG\\r\\0\\v \\r F\\r\\v \\rAr!\\f Aq@  \\rAt"\\rj \\r j"\\r(\\0 \\rAk(\\0Atk \\rA\\bk(\\0j6\\0 \\f!\\r\\v \\f F\\r@  \\rAt"j  j"\\f(\\0 \\fAk(\\0Atk \\fA\\bk(\\0j6\\0  Aj"\\fj \\f j"\\f(\\0 \\fAk(\\0Atk \\fA\\bk(\\0j6\\0 \\rAj"\\r G\\r\\0\\v\\f\\v A\\0L\\rA\\0!\\r  I Ak  AtjIq A\\fIrE@ A\\xFC\\xFF\\xFF\\xFF\\x07q!\\rA\\0!@  At"\\fj \\f j"\\f\\xFD\\0\\0 \\fAk\\xFD\\0\\0\\xFD\\xB1\\xFD\\v\\0 Aj" \\rG\\r\\0\\v \\r F\\r\\v \\rAr!\\f Aq@  \\rAt"\\rj \\r j"\\r(\\0 \\rAk(\\0k6\\0 \\f!\\r\\v \\f F\\r@  \\rAt"j  j"\\f(\\0 \\fAk(\\0k6\\0  Aj"\\fj \\f j"\\f(\\0 \\fAk(\\0k6\\0 \\rAj"\\r G\\r\\0\\v\\f\\v A M@  \\rj!@@@@ \\0\\v A\\0L\\rA\\0!  I Ak  AtjIq A\\x07MrE@ A\\xFC\\xFF\\xFF\\xFF\\x07q!A\\0!\\r@  \\rAt"\\fj \\f j"\\fA\\bk\\xFD\\0\\0\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xB5 \\f\\xFD\\0\\0\\xFD\\xAE \\fAk\\xFD\\0\\0\\xFD\\xAE \\fA\\fk\\xFD\\0\\0 \\fAk\\xFD\\0\\0\\xFD\\xAEA\\xFD\\xAB\\xFD\\xB1\\xFD\\v\\0 \\rAj"\\r G\\r\\0\\v  F\\r\\v@  At"\\fj \\f j"\\fA\\bk(\\0Al \\f(\\0j \\fAk(\\0j \\fA\\fk(\\0 \\fAk(\\0jAtk6\\0 Aj" G\\r\\0\\v\\f\\v A\\0L\\rA\\0!  I A\\fk  AtjIq A\\x07MrE@ A\\xFC\\xFF\\xFF\\xFF\\x07q!A\\0!\\r@  \\rAt"\\fj \\f j"\\f\\xFD\\0\\0 \\fA\\fk\\xFD\\0\\0\\xFD\\xB1 \\fA\\bk\\xFD\\0\\0 \\fAk\\xFD\\0\\0\\xFD\\xB1\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xB5\\xFD\\xAE\\xFD\\v\\0 \\rAj"\\r G\\r\\0\\v  F\\r\\v@  At"\\fj \\f j"\\f(\\0 \\fA\\fk(\\0k \\fA\\bk(\\0 \\fAk(\\0kAlj6\\0 Aj" G\\r\\0\\v\\f\\v A\\0L\\rA\\0!\\r  I A\\bk  AtjIq A\\bIrE@ A\\xFC\\xFF\\xFF\\xFF\\x07q!\\rA\\0!@  At"\\fj \\f j"\\f\\xFD\\0\\0 \\fAk\\xFD\\0\\0A\\xFD\\xAB\\xFD\\xB1 \\fA\\bk\\xFD\\0\\0\\xFD\\xAE\\xFD\\v\\0 Aj" \\rG\\r\\0\\v \\r F\\r\\v \\rAr!\\f Aq@  \\rAt"\\rj \\r j"\\r(\\0 \\rAk(\\0Atk \\rA\\bk(\\0j6\\0 \\f!\\r\\v \\f F\\r@  \\rAt"j  j"\\f(\\0 \\fAk(\\0Atk \\fA\\bk(\\0j6\\0  Aj"\\fj \\f j"\\f(\\0 \\fAk(\\0Atk \\fA\\bk(\\0j6\\0 \\rAj"\\r G\\r\\0\\v\\f\\v A\\0L\\rA\\0!\\r  I Ak  AtjIq A\\fIrE@ A\\xFC\\xFF\\xFF\\xFF\\x07q!\\rA\\0!@  At"\\fj \\f j"\\f\\xFD\\0\\0 \\fAk\\xFD\\0\\0\\xFD\\xB1\\xFD\\v\\0 Aj" \\rG\\r\\0\\v \\r F\\r\\v \\rAr!\\f Aq@  \\rAt"\\rj \\r j"\\r(\\0 \\rAk(\\0k6\\0 \\f!\\r\\v \\f F\\r@  \\rAt"j  j"\\f(\\0 \\fAk(\\0k6\\0  Aj"\\fj \\f j"\\f(\\0 \\fAk(\\0k6\\0 \\rAj"\\r G\\r\\0\\v\\f\\v  Atj!@@@@@ \\0\\v A\\0L\\rA\\0! AG@ A\\xFE\\xFF\\xFF\\xFF\\x07q!A\\0!\\r@  \\rAtj  \\rAtj"\\fAk\\xFD\\0\\0\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xD5 \\f\\xFD\\0\\0\\xFD\\xCE \\fA k\\xFD\\0\\0\\xFD\\xCE \\fAk\\xFD\\0\\0 \\fA\\bk\\xFD\\0\\0\\xFD\\xCEA\\xFD\\xCB\\xFD\\xD1 e\\xFD\\r\\0\\b	
\\v\\0\\0\\xFD[\\0\\0 \\rAj"\\r G\\r\\0\\v  F\\r\\v@  Atj  Atj"\\fAk)\\0B~ \\f)\\0| \\fA k)\\0| \\fAk)\\0 \\fA\\bk)\\0|B\\x86}>\\0 Aj" G\\r\\0\\v\\f\\v A\\0L\\rA\\0!\\r AG@ A\\xFE\\xFF\\xFF\\xFF\\x07q!\\rA\\0!@  Atj  Atj"\\fA\\bk\\xFD\\0\\0\\xFD\\f\\xFD\\xFF\\xFF\\xFF\\0\\0\\0\\0\\xFD\\xFF\\xFF\\xFF\\0\\0\\0\\0\\xFD\\xD5 \\f\\xFD\\0\\0\\xFD\\xCE \\fAk\\xFD\\0\\0\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xD5\\xFD\\xCE \\fAk\\xFD\\0\\0\\xFD\\xD1 e\\xFD\\r\\0\\b	
\\v\\0\\0\\xFD[\\0\\0 Aj" \\rG\\r\\0\\v \\r F\\r\\v@  \\rAtj  \\rAtj"\\fA\\bk)\\0B\\xFD\\xFF\\xFF\\xFF~ \\f)\\0| \\fAk)\\0B~| \\fAk)\\0}>\\0 \\rAj"\\r G\\r\\0\\v\\f\\v A\\0L\\rA\\0!\\r AG@ A\\xFE\\xFF\\xFF\\xFF\\x07q!\\rA\\0!@  Atj  Atj"\\f\\xFD\\0\\0 \\fA\\bk\\xFD\\0\\0A\\xFD\\xCB\\xFD\\xD1 \\fAk\\xFD\\0\\0\\xFD\\xCE e\\xFD\\r\\0\\b	
\\v\\0\\0\\xFD[\\0\\0 Aj" \\rG\\r\\0\\v \\r F\\r\\v@  \\rAtj  \\rAtj"\\f)\\0 \\fA\\bk)\\0B\\x86} \\fAk)\\0|>\\0 \\rAj"\\r G\\r\\0\\v\\f\\v A\\0L\\rA\\0!\\r AG@ A\\xFE\\xFF\\xFF\\xFF\\x07q!\\rA\\0!@  Atj  Atj"\\f\\xFD\\0\\0 \\fA\\bk\\xFD\\0\\0\\xFD\\xD1 e\\xFD\\r\\0\\b	
\\v\\0\\0\\xFD[\\0\\0 Aj" \\rG\\r\\0\\v \\r F\\r\\v@  \\rAtj  \\rAtj"\\f)\\0 \\fA\\bk)\\0}>\\0 \\rAj"\\r G\\r\\0\\v\\f\\v A\\0L\\rA\\0!\\r AG@ A\\xFE\\xFF\\xFF\\xFF\\x07q!\\rA\\0!@  Atj  Atj\\xFD\\0\\0 e\\xFD\\r\\0\\b	
\\v\\0\\0\\xFD[\\0\\0 Aj" \\rG\\r\\0\\v \\r F\\r\\v@  \\rAtj  \\rAtj)\\0>\\0 \\rAj"\\r G\\r\\0\\v\\f\\v At"\\fE\\r\\0   \\f\\xFC
\\0\\0\\v  j! " 68 " 6 "A\\x006\\b "A6\\0 \\0(   &    5     "A\\bjI!& " 6@ %E@ E\\r "Aj!A\\0!A\\0!\\f@ AF\\r\\0 " kAjAI\\r\\0 A~q!\\fA\\0!\\r@  \\rAt"j  j\\xFD\\0\\0\\xFD\\v\\0 \\rAj"\\r \\fG\\r\\0\\v \\f F\\r\\v  \\fk  \\fkAq"@@  \\fAt"\\rj  \\rj)\\x007\\0 \\fAj!\\f Aj" G\\r\\0\\v\\vAI\\r@  \\fAt"j  j)\\x007\\0  A\\bj"\\rj  \\rj)\\x007\\0  Aj"\\rj  \\rj)\\x007\\0  Aj"\\rj  \\rj)\\x007\\0 \\fAj"\\f G\\r\\0\\v\\f\\v E\\r\\0 "Aj!A\\0!A\\0!\\f@ AI\\r\\0   j"\\rAtj K@  " \\rAtjAjI\\r\\v A~q!\\fA\\0!\\r@  \\rAtj  \\rAtj\\xFD\\0\\xFD\\v\\0 \\rAj"\\r \\fG\\r\\0\\v \\f F\\r\\v  \\fk  \\fkAq"\\r@@  \\fAtj  \\fAtj4\\x007\\0 \\fAj!\\f Aj" \\rG\\r\\0\\v\\vAI\\r\\0@  \\fAtj  \\fAtj4\\x007\\0  \\fAj"\\rAtj  \\rAtj4\\x007\\0  \\fAj"\\rAtj  \\rAtj4\\x007\\0  \\fAj"\\rAtj  \\rAtj4\\x007\\0 \\fAj"\\f G\\r\\0\\v\\vA\\x7F "(\\xA8  ljA\\bj"\\r &j"\\f \\f \\rI\\x1B"\\f   \\f  I"\\f\\x1B!   ! \\f\\x1B!!\\v Aj! Aj" \\x1BM\\r\\0\\v \\0(\\0!\\v (\\xAC"\\fE\\r A\\x006\\x88 B\\x80\\x80\\x80\\x807\\x80 ((E\\r \\f Ak  \\fK\\x1B"%At!' A|q! Aq!6 A~q!& %Aj!7 At!8 %A|q!9 %Aq!+ A\\xA0\\xCB\\0j!D\\0\\0\\0\\0\\0\\0\\xF0? \\xB8\\xA3!wB Ak\\xAD"b\\x86!d \\xB8!x A\\x98j! A\\x90j!$ A K!0 AI!:A\\0!\\f@   \\fAtj"\\rA,j"6\\x8C@@ (\\x84"AF@ (," \\0(" \\fAtj(\\x8C"k!\\r@ 0E@A\\0!\\f \\rAO@@  \\fAt"\\rj \\r j\\xFD\\0\\0  \\rj\\xFD\\0\\0\\xFD\\xFA\\xFD\\xE6\\xFD\\v\\0 \\fAj"\\f G\\r\\0\\v "\\f F\\r\\v \\fAr!\\r 6@  \\fAt"\\fj \\f j*\\0  \\fj(\\0\\xB2\\x948\\0 \\r!\\f\\v  \\rF\\r@  \\fAt"\\rj \\r j*\\0  \\rj(\\0\\xB2\\x948\\0  \\rAj"\\rj \\r j*\\0  \\rj(\\0\\xB2\\x948\\0 \\fAj"\\f G\\r\\0\\v\\f\\vA\\0!\\f \\rA\\bO@@  \\fAt"\\rj \\r j\\xFD]\\0  \\fAtj\\xFD\\0\\0"f\\xFD\\0\\xB4\\xFD f\\xFD\\xB4\\xFD \\xFD\\xE6\\xFD[\\0\\0 \\fAj"\\f &G\\r\\0\\v &"\\f F\\r\\v \\fAr!\\r 6@  \\fAt"j  j*\\0  \\fAtj)\\0\\xB4\\x948\\0 \\r!\\f\\v  \\rF\\r\\0@  \\fAt"\\rj \\r j*\\0  \\fAtj)\\0\\xB4\\x948\\0  \\fAj"At"\\rj \\r j*\\0  Atj)\\0\\xB4\\x948\\0 \\fAj"\\f G\\r\\0\\v\\v   7  (\\xF8\\b\\f\\0 (\\x8C(\\0AF@A\\0!@ %AO@@ 'E"\\fE@ $  '\\xFC
\\0\\0\\v \\fE@ $  '\\xFC
\\0\\0\\v \\fE@ $  '\\xFC
\\0\\0\\v \\fE@ $  '\\xFC
\\0\\0\\v Aj" 9G\\r\\0\\v +E\\r\\vA\\0!\\f@ '@ $  '\\xFC
\\0\\0\\v \\fAj"\\f +G\\r\\0\\v\\v  (\\x84Aj6\\x84\\f\\v  (\\x80Aj6\\x80\\f\\v  n"A M@ \\r(4 (\\x88!@ AF@ E@A! A6\\x88\\f\\v B7\\x84A!\\f\\v AtAk K@  Aj6\\x88\\f\\v A\\x006\\x88  Aj"6\\x84\\v O\\r B7\\x84  \\fAj6\\x80\\f\\v@ (\\x88"Aq@A\\0!A\\0!A\\0!\\f %AO@@  At"j"\\f  $j+\\0 \\f+\\0\\xA19\\0  A\\br"\\rj"\\f \\r $j+\\0 \\f+\\0\\xA19\\0  Ar"\\rj"\\f \\r $j+\\0 \\f+\\0\\xA19\\0  Ar"\\rj"\\f \\r $j+\\0 \\f+\\0\\xA19\\0 Aj" 9G\\r\\0\\v !\\f +E\\r\\v@  \\fAt"j"\\r  $j+\\0 \\r+\\0\\xA19\\0 \\fAj!\\f Aj" +G\\r\\0\\v\\f\\v Av l n" Av"j!\\r \\0(" \\fAtj(\\x8C!\\x1B (,!@@ 0E@  \\rM\\r  Atj!A\\0!@  \\x1BkAO@ A\\xFC\\xFF\\xFF\\xFFq!A\\0!\\r@  \\rAt"\\fj \\f \\x1Bj\\xFD\\0\\0 \\f j\\xFD\\0\\0\\xFD\\xFA\\xFD\\xE6\\xFD\\v\\0 \\rAj"\\r G\\r\\0\\v  F\\r\\v Ar!\\f Aq@  At"\\rj \\r \\x1Bj*\\0 \\r j(\\0\\xB2\\x948\\0 \\f!\\v \\f F\\r\\0@  At"\\fj \\f \\x1Bj*\\0 \\f j(\\0\\xB2\\x948\\0  \\fAj"\\fj \\f \\x1Bj*\\0 \\f j(\\0\\xB2\\x948\\0 Aj" G\\r\\0\\v\\v@   k" k"\\f \\f K\\x1B"At j At \\x1B 8jkjAO@ A\\xFC\\xFF\\xFF\\xFFq! \\x1B Atj!A\\0!\\r@  \\r jAt"\\fj  \\rAtj\\xFD\\0\\0 \\f j\\xFD\\0\\0\\xFD\\xFA\\xFD\\xE6\\xFD\\v\\0 \\rAj"\\r G\\r\\0\\v  j!  F\\r  j!\\v Aj!\\f  kAq@  At"\\rj \\x1B Atj*\\0 \\r j(\\0\\xB2\\x948\\0 Aj! \\f!\\v  \\fF\\r\\0@  At"\\fj \\x1B Atj"\\r*\\0 \\f j(\\0\\xB2\\x948\\0  \\fAj"\\fj \\r* \\f j(\\0\\xB2\\x948\\0 Aj! Aj" G\\r\\0\\v\\v  K\\r\\f\\v  \\rM\\r  Atj!A\\0!@  \\x1BkA\\bO@ A\\xFE\\xFF\\xFF\\xFFq!A\\0!\\r@  \\rAt"\\fj \\f \\x1Bj\\xFD]\\0  \\rAtj\\xFD\\0\\0"f\\xFD\\0\\xB4\\xFD f\\xFD\\xB4\\xFD \\xFD\\xE6\\xFD[\\0\\0 \\rAj"\\r G\\r\\0\\v  F\\r\\v Ar!\\f Aq@  At"\\rj \\r \\x1Bj*\\0  Atj)\\0\\xB4\\x948\\0 \\f!\\v \\f F\\r\\0@  At"\\fj \\f \\x1Bj*\\0  Atj)\\0\\xB4\\x948\\0  Aj"\\rAt"\\fj \\f \\x1Bj*\\0  \\rAtj)\\0\\xB4\\x948\\0 Aj" G\\r\\0\\v\\v@   k" k"\\f \\f K\\x1B"At j At \\x1B 8jkjA\\bO@ A\\xFE\\xFF\\xFF\\xFFq! \\x1B Atj!A\\0!\\r@  \\r j"\\fAtj  \\rAtj\\xFD]\\0  \\fAtj\\xFD\\0\\0"f\\xFD\\0\\xB4\\xFD f\\xFD\\xB4\\xFD \\xFD\\xE6\\xFD[\\0\\0 \\rAj"\\r G\\r\\0\\v  j!  F\\r  j!\\v Aj!\\f  kAq@  Atj \\x1B Atj*\\0  Atj)\\0\\xB4\\x948\\0 Aj! \\f!\\v  \\fF\\r\\0@  Atj \\x1B Atj"\\r*\\0  Atj)\\0\\xB4\\x948\\0  Aj"\\fAtj \\r*  \\fAtj)\\0\\xB4\\x948\\0 Aj! Aj" G\\r\\0\\v\\v  M\\r\\v  AtjA\\x006\\0\\v   7  (\\xF8\\b\\f\\0 (\\x88! (\\x84! (\\x8C!\\v (\\b@ AF@ E@A! A6\\x88\\f\\v B7\\x84A!\\f\\v AtAk K@  Aj6\\x88\\f\\v A\\x006\\x88  Aj"6\\x84\\v O\\r\\0 B7\\x84  (\\x80Aj6\\x80\\v +\\x98"vD\\0\\0\\0\\0\\0\\0\\0\\0a\\r\\0A\\0!@@  %F@ %!\\f\\v  Aj"Atj+\\0\\x9A!tA\\0!\\f@@@@@@ \\0\\v\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 t\\xFD"\\0!e A~q!\\fA\\0!@ e A\\xC0j Atj\\xFD\\0\\0   kAtjA\\bk\\xFD\\0\\0 e\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF2\\xFD\\xF1!e Aj" \\fG\\r\\0\\v e e e\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0!t \\f F\\r\\v@ t A\\xC0j \\fAtj+\\0   \\fkAtj+\\0\\xA2\\xA1!t \\fAj"\\f G\\r\\0\\v\\v A\\xC0j Atj" t v\\xA3"t9\\0@ Av"E\\r\\0A\\0!\\f AG@ Aq A\\xFE\\xFF\\xFF\\xFF\\x07q!\\r@ A\\xC0j \\fAtj" t  \\fA\\x7FsAtj"+\\0\\xA2 +\\0"u\\xA09\\0  t u\\xA2 +\\0\\xA09\\0  t  \\fA\\xFE\\xFF\\xFF\\xFFsAtj"+\\0\\xA2 +\\b"u\\xA09\\b  t u\\xA2 +\\0\\xA09\\0 \\fAj"\\f \\rG\\r\\0\\vE\\r\\v A\\xC0j \\fAtj"\\r t  \\fA\\x7FsAtj"\\f+\\0\\xA2 \\r+\\0"u\\xA09\\0 \\f t u\\xA2 \\f+\\0\\xA09\\0\\v Aq@ A\\xC0j Atj"\\f \\f+\\0"u t\\xA2 u\\xA09\\0\\v  A\\x07tj!A\\0!\\f AI\\r A~q!\\fA\\0!@  Atj A\\xC0j Atj\\xFD\\0\\0"f\\xFD!\\0\\xB6\\xFD f\\xFD!\\xB6\\xFD \\xFD\\xE1\\xFD[\\0\\0 Aj" \\fG\\r\\0\\v \\f F\\r\\f\\v  t v\\xA3"t9\\xC0 !\\v \\f  \\f K\\x1B!@  \\fAtj A\\xC0j \\fAtj+\\0\\xB6\\x8C8\\0 \\f G \\fAj!\\f\\r\\0\\v\\v  AtjD\\0\\0\\0\\0\\0\\0\\xF0? t t\\xA2\\xA1 v\\xA2"v9\\0 ! vD\\0\\0\\0\\0\\0\\0\\0\\0b\\r\\v\\vA!\\f \\0(\\0"(\\xB4E@ (\\xB0!\\f\\v@ @  \\fj!A\\0!\\fD\\0\\0\\xE0\\xFF\\xFF\\xFF\\xEFA!tA!A\\0!@|  \\fAtj+\\0"uD\\0\\0\\0\\0\\0\\0\\0\\0d@ uD\\0\\0\\0\\0\\0\\0\\xE0?\\xA2 w\\xA2D\\xFE\\x82+eG\\xE7?\\xA2"uD\\0\\0\\0\\0\\0\\0\\0\\0 uD\\0\\0\\0\\0\\0\\0\\0\\0f\\x1B\\f\\vDn\\xB5\\xB5\\xB8\\x93FD\\0\\0\\0\\0\\0\\0\\0\\0 uD\\0\\0\\0\\0\\0\\0\\0\\0c\\x1B\\v  k\\xB8\\xA2  l\\xB8\\xA0"u t t ud"\\r\\x1B!t \\f  \\r\\x1B! Aj! \\fAj"\\f G\\r\\0\\vA Aj"\\r (\\xB8"\\f\\x1B!  \\r \\f\\x1B!;\\f\\vA! A (\\xB8"\\f\\x1B!; \\fE\\r\\0 E\\r\\v Ak!A\\0!, !\\r@|  \\rAk"1Atj+\\0"uD\\0\\0\\0\\0\\0\\0\\0\\0d@ uD\\0\\0\\0\\0\\0\\0\\xE0?\\xA2  \\rk\\xB8\\xA3D\\xFE\\x82+eG\\xE7?\\xA2"uD\\0\\0\\0\\0\\0\\0\\0\\0 uD\\0\\0\\0\\0\\0\\0\\0\\0f\\x1B\\f\\vDn\\xB5\\xB5\\xB8\\x93FD\\0\\0\\0\\0\\0\\0\\0\\0 uD\\0\\0\\0\\0\\0\\0\\0\\0c\\x1B\\v xfE@  ,j"At!\\x7F@ \\0(\\0"\\f(\\xB4@ :\\rA!2A\\f\\v \\f(\\xB0"2\\f\\vAA \\rgA\\\`s kA!j"\\f \\fAM\\x1B"\\f \\fAO\\x1B!2A\\v!)  ,j!< \\rA|q"! At!  j!" \\rAq!=  \\rk!( \\rA~q!  \\rAtj!  \\rAtj!  1A\\x07tj!- \\rgA\\\`s kA!j!>@ !E!?@ \\rE@A\\0!\\f\\f\\vD\\0\\0\\0\\0\\0\\0\\0\\0!tA\\0!A\\0!A\\0!\\f@ \\rAI"3E@@ - Atj"\\f*\\f\\x8B\\xBB"y \\f*\\b\\x8B\\xBB"z \\f*\\x8B\\xBB"v \\f*\\0\\x8B\\xBB"u t t uc\\x1B"u u vc\\x1B"u u zc\\x1B"u u yc\\x1B!t Aj" G\\r\\0\\v !\\f =E\\r\\v@ - \\fAtj*\\0\\x8B\\xBB"u t t uc\\x1B!t \\fAj!\\f Aj" =G\\r\\0\\v\\vA\\0!\\f tD\\0\\0\\0\\0\\0\\0\\0\\0e\\r\\0A ) > ) >I\\x1B ) :\\x1B".Akt"4Ak!@A\\0 4k!/ \\b ?At"j(\\0! \\x07 j(\\0!# 	 j(\\0!* (\\x8CJ! (\\x88J!\\x1B \\0(\\0(\\xBC! t A\\xC0jH@@@ . (\\xC0A\\x7Fsj"AN@A!\\f\\v ApH\\r A\\0H\\r\\vA t\\xB3!{D\\0\\0\\0\\0\\0\\0\\0\\0!t@ \\fAt" A\\xC0jj t  -j*\\0 {\\x94\\xBB\\xA0"uG" /  /J\\x1B @  4H\\x1B"6\\0 u \\xB7\\xA1!t \\fAj"\\f \\rG\\r\\0\\v !\\f\\vA\\0!A\\x80\\x80\\x80\\xFCA\\0 kAtk\\xBE!{D\\0\\0\\0\\0\\0\\0\\0\\0!t@ \\fAt" A\\xC0jj t  -j*\\0 {\\x94\\xBB\\xA0"uG" /  /J\\x1B @  4H\\x1B"6\\0 u \\xB7\\xA1!t \\fAj"\\f \\rG\\r\\0\\v\\vA\\0!\\f@@ 3@A\\0!\\f\\v\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!e@ A\\xC0j \\fAtj\\xFD\\0\\0\\xFD\\xA0 e\\xFD\\xAE!e \\fAj"\\f G\\r\\0\\v e e e\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xAE"f f f\\xFD\\r\\x07\\0\\0\\0\\xFD\\xAE\\xFD\\x1B\\0! "\\f \\rF\\r\\v@  A\\xC0j \\fAtj(\\0" Au"s kj! \\fAj"\\f \\rG\\r\\0\\v\\v@ dB\\0 \\xAD b\\x86} \\xAD"c\\x87}B\\x80\\x80\\x80\\x80\\b}B\\xFF\\xFF\\xFF\\xFFoX@ 0E@ (A\\0L\\rA\\0!\\f 4\\xC0!Q 4\\xC4!R 4\\xC8!S 4\\xCC!T 4\\xD0!U 4\\xD4!V 4\\xD8!W 4\\xDC!X 4\\xE0!Y 4\\xE4!Z 4\\xE8![ 4\\xEC!\\\\ 4\\xF0!] 4\\xF4!^ 4\\xF8!_ 4\\xFC!\\\` 4\\x80\\x07!a 4\\x84\\x07!H 4\\x88\\x07!I 4\\x8C\\x07!L 4\\x90\\x07!M 4\\x94\\x07!P 4\\x98\\x07!C 4\\x9C\\x07!F 4\\xA0\\x07!J 4\\xA4\\x07!N 4\\xA8\\x07!O 4\\xAC\\x07!K 4\\xB0\\x07!E 4\\xB4\\x07!D 4\\xB8\\x07!G 4\\xBC\\x07!B@B\\0!A@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@ 1 \\x1B\\r\\f\\v
	\\b\\x07\\0 \\v  \\fAtjA\\x80k4\\0 B~!A\\v  \\fAtjA\\xFC\\0k4\\0 G~ A|!A\\v  \\fAtjA\\xF8\\0k4\\0 D~ A|!A\\v  \\fAtjA\\xF4\\0k4\\0 E~ A|!A\\v  \\fAtjA\\xF0\\0k4\\0 K~ A|!A\\v  \\fAtjA\\xEC\\0k4\\0 O~ A|!A\\v  \\fAtjA\\xE8\\0k4\\0 N~ A|!A\\v  \\fAtjA\\xE4\\0k4\\0 J~ A|!A\\v  \\fAtjA\\xE0\\0k4\\0 F~ A|!A\\v  \\fAtjA\\xDC\\0k4\\0 C~ A|!A\\v  \\fAtjA\\xD8\\0k4\\0 P~ A|!A\\v  \\fAtjA\\xD4\\0k4\\0 M~ A|!A\\v  \\fAtjA\\xD0\\0k4\\0 L~ A|!A\\v  \\fAtjA\\xCC\\0k4\\0 I~ A|!A\\v  \\fAtjA\\xC8\\0k4\\0 H~ A|!A\\v  \\fAtjA\\xC4\\0k4\\0 a~ A|!A\\v  \\fAtjA@j4\\0 \\\`~ A|!A\\v  \\fAtjA<k4\\0 _~ A|!A\\v  \\fAtjA8k4\\0 ^~ A|!A\\v  \\fAtjA4k4\\0 ]~ A|!A\\v  \\fAtjA0k4\\0 \\\\~ A|!A\\v  \\fAtjA,k4\\0 [~ A|!A\\v  \\fAtjA(k4\\0 Z~ A|!A\\v  \\fAtjA$k4\\0 Y~ A|!A\\v  \\fAtjA k4\\0 X~ A|!A\\v  \\fAtjAk4\\0 W~ A|!A\\v  \\fAtjAk4\\0 V~ A|!A\\v  \\fAtjAk4\\0 U~ A|!A\\v  \\fAtjAk4\\0 T~ A|!A\\v  \\fAtjA\\fk4\\0 S~ A|!A\\v  \\fAtjA\\bk4\\0 R~ A|!A\\v  \\fAtjAk4\\0 Q~ A|!A\\v  \\fAt"j4\\0 A c\\x87}"AB\\x80\\x80\\x80\\x80\\b}B\\x81\\x80\\x80\\x80pT@A\\0!\\f\\f\\v  *j A>\\0 \\fAj"\\f (G\\r\\0\\v\\f\\v (A\\0L\\rA\\0!\\f 4\\xC0!Q 4\\xC4!R 4\\xC8!S 4\\xCC!T 4\\xD0!U 4\\xD4!V 4\\xD8!W 4\\xDC!X 4\\xE0!Y 4\\xE4!Z 4\\xE8![ 4\\xEC!\\\\ 4\\xF0!] 4\\xF4!^ 4\\xF8!_ 4\\xFC!\\\` 4\\x80\\x07!a 4\\x84\\x07!H 4\\x88\\x07!I 4\\x8C\\x07!L 4\\x90\\x07!M 4\\x94\\x07!P 4\\x98\\x07!C 4\\x9C\\x07!F 4\\xA0\\x07!J 4\\xA4\\x07!N 4\\xA8\\x07!O 4\\xAC\\x07!K 4\\xB0\\x07!E 4\\xB4\\x07!D 4\\xB8\\x07!G 4\\xBC\\x07!B@B\\0!A@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@ 1 \\x1B\\r\\f\\v
	\\b\\x07\\0 \\v  \\fAtjA\\x80k)\\0 B~!A\\v  \\fAtjA\\xF8k)\\0 G~ A|!A\\v  \\fAtjA\\xF0k)\\0 D~ A|!A\\v  \\fAtjA\\xE8k)\\0 E~ A|!A\\v  \\fAtjA\\xE0k)\\0 K~ A|!A\\v  \\fAtjA\\xD8k)\\0 O~ A|!A\\v  \\fAtjA\\xD0k)\\0 N~ A|!A\\v  \\fAtjA\\xC8k)\\0 J~ A|!A\\v  \\fAtjA\\xC0k)\\0 F~ A|!A\\v  \\fAtjA\\xB8k)\\0 C~ A|!A\\v  \\fAtjA\\xB0k)\\0 P~ A|!A\\v  \\fAtjA\\xA8k)\\0 M~ A|!A\\v  \\fAtjA\\xA0k)\\0 L~ A|!A\\v  \\fAtjA\\x98k)\\0 I~ A|!A\\v  \\fAtjA\\x90k)\\0 H~ A|!A\\v  \\fAtjA\\x88k)\\0 a~ A|!A\\v  \\fAtjA\\x80k)\\0 \\\`~ A|!A\\v  \\fAtjA\\xF8\\0k)\\0 _~ A|!A\\v  \\fAtjA\\xF0\\0k)\\0 ^~ A|!A\\v  \\fAtjA\\xE8\\0k)\\0 ]~ A|!A\\v  \\fAtjA\\xE0\\0k)\\0 \\\\~ A|!A\\v  \\fAtjA\\xD8\\0k)\\0 [~ A|!A\\v  \\fAtjA\\xD0\\0k)\\0 Z~ A|!A\\v  \\fAtjA\\xC8\\0k)\\0 Y~ A|!A\\v  \\fAtjA@j)\\0 X~ A|!A\\v  \\fAtjA8k)\\0 W~ A|!A\\v  \\fAtjA0k)\\0 V~ A|!A\\v  \\fAtjA(k)\\0 U~ A|!A\\v  \\fAtjA k)\\0 T~ A|!A\\v  \\fAtjAk)\\0 S~ A|!A\\v  \\fAtjAk)\\0 R~ A|!A\\v  \\fAtjA\\bk)\\0 Q~ A|!A\\v  \\fAtj)\\0 A c\\x87}"AB\\x80\\x80\\x80\\x80\\b}B\\x81\\x80\\x80\\x80pT@A\\0!\\f\\f\\v * \\fAtj A>\\0 \\fAj"\\f (G\\r\\0\\v\\f\\vA\\0!\\f@@ 3@A\\0!\\f\\v\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!e@ A\\xC0j \\fAtj\\xFD\\0\\0\\xFD\\xA0 e\\xFD\\xAE!e \\fAj"\\f G\\r\\0\\v e e e\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xAE"f f f\\xFD\\r\\x07\\0\\0\\0\\xFD\\xAE\\xFD\\x1B\\0! "\\f \\rF\\r\\v@  A\\xC0j \\fAtj(\\0" Au"s kj! \\fAj"\\f \\rG\\r\\0\\v\\v  ( A\\xC0j \\r  *\\x7F@@ \\xAD b\\x86"AB}B~Z@ \\0(!\\f\\f\\v \\0(!\\f AB\\x80\\x80\\x80\\x80\\b|B\\xFF\\xFF\\xFF\\xFFV\\r\\v \\fA\\x84	j AK .AKrE\\r \\fA\\xFC\\bj\\f\\v \\fA\\x80	j\\v(\\0\\v\\0\\v # *6\\xA0 # 6 #A\\x006\\b #A6\\0 \\0(  * \\x1B  ( \\r 5     #A\\bjI! # 6 # .6 # \\r6 #A j A\\xC0jA\\x80\\xFC
\\0\\0 #A\\xA0j!@ A!O@A\\0!A\\0!\\f@ \\rAF\\r\\0 # kApqA\\xE0~F\\r\\0@  \\fAt"j  j\\xFD\\0\\0\\xFD\\v\\0 \\fAj"\\f G\\r\\0\\v "\\f \\rF\\r\\v < \\fk \\r \\fkAq"@@  \\fAt"j  j)\\x007\\0 \\fAj!\\f Aj" G\\r\\0\\v\\vAI\\r@  \\fAt"j  j)\\x007\\0  A\\bj"j  j)\\x007\\0  Aj"j  j)\\x007\\0  Aj"j  j)\\x007\\0 \\fAj"\\f \\rG\\r\\0\\v\\f\\vA\\0!A\\0!\\f@ 3\\r\\0  "I   #jA\\xA0jIq\\r\\0@  \\fAtj  \\fAtj\\xFD\\0\\xFD\\v\\0 \\fAj"\\f G\\r\\0\\v "\\f \\rF\\r\\v < \\fk \\r \\fkAq"@@  \\fAtj  \\fAtj4\\x007\\0 \\fAj!\\f Aj" G\\r\\0\\v\\vAI\\r\\0@  \\fAtj  \\fAtj4\\x007\\0  \\fAj"Atj  Atj4\\x007\\0  \\fAj"Atj  Atj4\\x007\\0  \\fAj"Atj  Atj4\\x007\\0 \\fAj"\\f \\rG\\r\\0\\v\\vA\\x7F #(\\xA8  .j \\rljAj" j"\\f \\f I\\x1B!\\f\\v ? ! \\fA\\0G \\f  Iq"\\x1B!! \\f   \\x1B!  )Aj") 2M\\r\\0\\v\\v ,Aj!, \\rAj"\\r ;M\\r\\0\\v\\v (\\x80"\\f \\0(\\0"((I\\r\\0\\v\\f\\v \\x07("\\0 A M~ \\xAC )\\0\\v7\\b \\0A\\x006\\0  \\0(\\xA8jA\\bj"\\0   \\0  I"!\\x1B! \\v  A\\x7FF@ \\x07 !Atj(\\0"\\0 A K6\\f \\0A6\\0 \\0 6\\b \\0(\\xA8  ljA\\bj! \\v 
 !6\\0 \\v  6\\0 A\\xC0\\bj$\\0\\vn\\x7F \\0(LA\\0N \\0- \\0 \\0(\\f\\0 \\0-\\0\\0AqE@ \\0(8! \\0(4"@  68\\v @  64\\v \\0A\\xF4\\xE0\\0(\\0F@A\\xF4\\xE0\\0 6\\0\\v \\0(\\\`	 \\0	\\v\\v\\xB4\\x7F|}@ \\0(\\0"(\\0AG\\r\\0 A\\x006(A\\xB4!@@@@@@@@@@@@@@@@@\\x7F A;#"@  k\\f\\v ;\\v"A\\bG"E@A\\xF9 A\\b\\r  Aj6(  AtjA\\x006,\\f\\v@ Ak\\0\\vA\\x91 A\\r\\r  Aj6(  AtjA6,\\f\\vA\\xA3 A\\b\\r  Aj6(  AtjA6,\\f\\vA\\xED A\\r  Aj6(  AtjA6,\\f\\r\\vA\\x82 A\\r\\f  Aj6(  AtjA6,\\f\\f\\vA\\x89 A\\x07\\r  Aj6(  AtjA6,\\f\\v\\v A\\bI\\r\\vA\\xF0 AE\\r A	G\\rA\\xDA A	\\r\\x07  Aj6(  AtjA\\v6,\\f	\\vA\\xF0 A\\r\\v Aj!\\x07 \\0(\\0! \\x07D\\0\\0\\0\\0\\0\\0\\x906dE \\x07D\\0\\0\\0\\0\\0\\xE0?eEr\\r\\x07  ((Atj \\x07\\xB680 \\0(\\0" (("Aj6(  AtjA6,\\f\\x07\\vA\\xD2 A\\x07\\r  Aj6(  AtjA\\x076,\\f\\v@ Ak\\0\\vA\\x9A A\\r  Aj6(  AtjA\\b6,\\f\\vA\\xB4 A\\r\\r  Aj6(  AtjA	6,\\f\\vA\\xAC A\\x07\\r  Aj6(  AtjA
6,\\f\\v \\r\\0A\\xE4 A\\b\\r\\0  Aj6(  AtjA\\f6,\\f\\vA\\xE9 AE@ Aj!\\x07 \\0(\\0! \\x07D\\0\\0\\0\\0\\0\\0\\x90\\xB6fE \\x07D\\0\\0\\0\\0\\0\\xF0?eEr\\r  ((Atj \\x07\\xB680 \\0(\\0" (("Aj6(  AtjA\\r6,\\f\\v AI\\rA\\xD0 AE@ Aj}C\\xCD\\xCC\\xCC= A/#"E\\r\\0C\\xA4p}? Aj"D\\0\\0\\0p\\xAE\\xEF?cE\\r\\0 \\xB6\\v!\\b\\xFC! Aj  \\x1BA/#"} Aj\\xB6C\\xCD\\xCCL>\\v!	 \\0(\\0"((! AL@  Atj 	80 \\0(\\0" (("Aj6(  AtjA\\r6,\\f\\v  jAK\\rC\\0\\0\\x80?C\\0\\0\\x80?C\\0\\0\\x80? \\b\\x93\\x95C\\0\\0\\x80\\xBF\\x92"
 \\xB3\\x92\\x95!\\bA\\0!@  Atj 	80 \\0(\\0" ((Atj \\b \\xB3\\x9484 \\0(\\0" ((Atj 
 Aj"\\xB3\\x92 \\b\\x9488 \\0(\\0" (("Aj"6(  AtjA6,  G\\r\\0\\v\\f\\v AF\\rA\\xC0 AE@ AjC\\xCD\\xCCL>!	}C\\xCD\\xCCL> A/#"E\\r\\0C\\xA4p}? Aj"D\\0\\0\\0p\\xAE\\xEF?cE\\r\\0 \\xB6\\v!\\b Aj  \\x1BA/#"@ Aj\\xB6!	\\v \\0(\\0"((!\\xFC"AL@  Atj 	80 \\0(\\0" (("Aj6(  AtjA\\r6,\\f\\v  jAK\\rC\\0\\0\\x80?C\\0\\0\\x80?C\\0\\0\\x80? \\b\\x93\\x95C\\0\\0\\x80\\xBF\\x92"
 \\xB3\\x92\\x95!\\bA\\0!@  Atj 	80 \\0(\\0" ((Atj \\b \\xB3\\x9484 \\0(\\0" ((Atj 
 Aj"\\xB3\\x92 \\b\\x9488 \\0(\\0" (("Aj"6(  AtjA6,  G\\r\\0\\v\\f\\v AI\\rA\\xDF A\\r Aj\\xFC"AL@ \\0(\\0!\\f\\v}C\\0\\0\\0? A/#"E\\r\\0C\\0\\0\\x80? Aj"\\x07D\\0\\0\\0\\0\\0\\xF0?d\\r\\0 \\x07\\xB6 \\x07D\\0\\0\\0\\0\\0\\0\\x90\\xB6cE\\r\\0C\\0\\0\\0\\0\\v!	 \\0(\\0" ((Atj 64 \\0(\\0" ((Atj 	 \\xB3\\x9580 \\0(\\0" (("Aj6(  AtjA6,\\f\\vA\\xC2 A\\r\\0  Aj6(  AtjA6,\\v ((! @ Aj! A G\\r\\v\\v \\r\\0 A\\x80\\x80\\x80\\xF860 B\\x81\\x80\\x80\\x80\\xD07(\\v\\vD\\x7F#\\0Ak"$\\0     B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x7F\\x85 )\\0! \\0 )\\b7\\b \\0 7\\0 Aj$\\0\\v}\\x7F@@ \\0"AqE\\r\\0 -\\0\\0E@A\\0\\v@ Aj"AqE\\r -\\0\\0\\r\\0\\v\\f\\v@ "Aj!A\\x80\\x82\\x84\\b (\\0"k rA\\x80\\x81\\x82\\x84xqA\\x80\\x81\\x82\\x84xF\\r\\0\\v@ "Aj! -\\0\\0\\r\\0\\v\\v  \\0k\\v$\\0 \\0B\\x007p \\0 \\0(\\b6h \\0 \\0(, \\0(k\\xAC7x\\v\\x9C\\x7F#\\0A\\xF0k"$\\0  \\x006\\0A!@ AH\\r\\0 \\0!@ \\0 Ak"  Ak"\\x07Atj(\\0k"'A\\0N@ \\0 'A\\0N\\r\\v  Atj    'A\\0N"\\x1B"6\\0 Aj! Ak \\x07 \\x1B"AJ\\r\\0\\v\\v  [ A\\xF0j$\\0\\v\\0 @ \\0  \\xFC
\\0\\0\\v\\v\\xC2\\x7F~#\\0A k"$\\0 \\0(A\\x80&j A\\xB0\\x1B\\xFC
\\0\\0 \\0("A6\\xB0A (\\x88%!@ (\\x84%@ \\r 5\\0!\\v )!	 A6\\xD4A )\\xC8A"
 	T 
 	 \\v|Zr\\r A\\x006\\x84% 
 	}"	\\xA7"@ (\\b@@  At"j  j(\\0 Atj"6\\0 A\\xB0l"\\x07 \\0(j"\\bA\\x006\\xB4& \\bA6\\xA8& \\0( \\x07j 6\\xB0& Aj" (\\bI\\r\\0\\v \\0(!\\v  (\\x80& k6\\x80&  )\\x98& 	B\\xFF\\xFF\\xFF\\xFF\\x83|7\\x98& \\0 \\0("\\0A\\x80&j  \\0($ \\0(\\0!\\f\\v \\0   ($ (\\0!\\f\\v @\\f\\v@ (\\xF0E@ A\\x006\\xFC$\\f\\v (\\xFC$E\\r\\0 A\\x8C%j  (\\b (\\0 (A\\x07jAvKE@A!\\f\\v \\0(!\\v \\0   ($ (\\0!\\v A j$\\0 \\v\\xFD\\x7F@@@@@@@@ \\0\\x07\\v A\\0L\\r Ak(\\0!@  At"j" \\0 j(\\0 A\\bk(\\0Azlj Ak(\\0k A\\fk(\\0 jAtj"6\\0 Aj" G\\r\\0\\v\\f\\v A\\0L\\r Ak(\\0!A\\0! AG@ Aq A\\xFE\\xFF\\xFF\\xFF\\x07q!\\x07@  At"j" A\\fk(\\0 \\0 j(\\0j  A\\bk(\\0"kAlj"6\\0  Ar"j"\\b  \\0 j(\\0j  \\bA\\bk(\\0kAlj"6\\0 Aj" \\x07G\\r\\0\\vE\\r\\v  At"j" A\\fk(\\0 \\0 j(\\0j  A\\bk(\\0kAlj6\\0\\v A\\0L\\r Ak(\\0!A\\0! AG@ Aq A\\xFE\\xFF\\xFF\\xFF\\x07q!@  At"j"\\x07 \\0 j(\\0 Atj \\x07A\\bk(\\0k"6\\0  Ar"j"\\x07 \\0 j(\\0 Atj \\x07A\\bk(\\0k"6\\0 Aj" G\\r\\0\\vE\\r\\v  At"j" \\0 j(\\0 Atj A\\bk(\\0k6\\0\\v A\\0L\\r Aq! Ak(\\0! AO\\rA\\0!\\f\\v At"E\\r  \\0 \\xFC
\\0\\0\\v A\\xFC\\xFF\\xFF\\xFF\\x07q!\\x07A\\0!@  At"j  \\0 j(\\0j"6\\0  Ar"\\bj  \\0 \\bj(\\0j"6\\0  A\\br"\\bj  \\0 \\bj(\\0j"6\\0  A\\fr"j  \\0 j(\\0j"6\\0 Aj" \\x07G\\r\\0\\v E\\r\\v@  At"j  \\0 j(\\0j"6\\0 Aj! Aj" G\\r\\0\\v\\v\\v\\x8E\\b\\x7F#\\0Ak"\\b$\\0 \\0((\\xE8\\b!@ A  AM\\x1B@AA \\x1B!\\fAA \\x1B!\\r  v!	A\\0!@ \\0((, \\bA\\bj \\r\\fE@A\\0!\\f\\v 
At" (\\0j \\b(\\b"\\x076\\0@ \\x07 \\fI@ ( jA\\x006\\0 \\0("(,  Atj 	A\\0  
\\x1Bk"\\v \\x07 (\\xD8A\\0E@A\\0! \\0(\\0"(\\0AG\\r \\0("(\\x84%\\x7F  A6\\xDCA \\0A\\0 ($ ( \\0\\0 \\0(\\0\\vA6\\0A!\\f\\v  \\vj!\\f\\v \\0((, \\bA\\bjA\\fE@A\\0!\\f\\v ( j \\b(\\b"\\x076\\0A\\0  
\\x1B! \\x07E@  	O\\r 	 kAt"\\x07@  AtjA\\0 \\x07\\xFC\\v\\0\\v  	j k!\\f\\v  	O\\r\\0A \\x07AktA\\0 \\x07A M\\x1B!\\v@ \\0((, \\bA\\fj \\x07\\fE@A\\0!\\f\\v  Atj \\b(\\f \\vs \\vk6\\0 Aj! Aj" 	G\\r\\0\\v\\vA! 
Aj"
 vE\\r\\0\\v\\f\\v \\0(\\0A\\b6\\0A\\0!\\v \\bAj$\\0 \\v~ \\0)\\0" )\\0"V  Tk\\v\\x91~
\\x7F@ \\0\\x7F \\0("\\vAkAM@ \\0)\\bA\\xC0\\0 \\vk"	\\xAD\\x86!A\\0\\f\\v \\vA!I@A\\xC0\\0!	\\f\\v \\0 \\0)\\b" \\vA k\\xAD\\x887\\b A\\xE0\\0 \\vk"	\\xAD\\x86!A \\v"\\v6\\v@@ \\0("
 jAt \\vr \\0("\\fAtI\\r\\0 \\v AtjA?jAv 
j"\\r \\fM\\r\\0 \\rA\\x81\\x80\\x80K@A\\0\\vA\\0!
 \\0(\\0 \\fAv"\\v \\fj \\r \\r \\fk \\vI\\x1B"\\f\\x7F \\fA\\xFF\\xFF\\xFF\\xFFK@A\\0\\v \\fAtA\\0\\v"\\rE\\r \\0 \\f6 \\0 \\r6\\0\\v @ Aj!A\\x7F t!A\\x7FA kv!@ (\\0"
At 
Aus"
 r q!@ \\0\\x7F~ 
 v"\\r j"
 	M@ \\xAD 	 
k"	\\xAD\\x86 \\x84\\f\\v@ 
A\\xC1\\0I\\r\\0 \\0( 
 AtjA@jj"
 \\0("\\vAtj \\fAtI\\r\\0 
A?jAv \\vj"\\v \\fM\\r\\0 \\vA\\x81\\x80\\x80K@A\\0\\vA\\0!
 \\0(\\0 \\fAv" \\fj \\v \\v \\fk I\\x1B"\\f\\x7F \\fA\\xFF\\xFF\\xFF\\xFFK@A\\0\\v \\fAtA\\0\\v"\\vE\\r \\0 \\f6 \\0 \\v6\\0\\v@ 	 \\rI@ \\r 	k"	A j!
@\\x7F@~ \\0(E@A !\\v \\0A 6 \\0 B \\x88"7\\b B \\x86" 
A\\xC0\\0M\\r \\0 B \\x86"\\x07 B \\x88"\\b\\x84"7\\b \\0 \\0("
Aj"\\r6 \\0(\\0" 
Atj B\\b\\x86B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\0\\x83 \\bB8\\x86\\x84 B\\x80\\x80\\xFC\\x07\\x83B\\x86 B\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 B\\x86B\\x80\\x80\\x80\\xF8\\x83 B\\b\\x86B\\x80\\x80\\xFC\\x07\\x83\\x84 B\\b\\x88B\\x80\\xFE\\x83 \\x07B8\\x88\\x84\\x84\\x847\\0A\\0\\f\\v \\0 \\0("\\vAj"\\r6 \\0 \\0)\\b"B \\x86"\\x07 B \\x88"\\b\\x84"7\\b \\0(\\0" \\vAtj B\\b\\x86B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\0\\x83 \\bB8\\x86\\x84 B\\x80\\x80\\xFC\\x07\\x83B\\x86 B\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 B\\x86B\\x80\\x80\\x80\\xF8\\x83 B\\b\\x86B\\x80\\x80\\xFC\\x07\\x83\\x84 B\\b\\x88B\\x80\\xFE\\x83 \\x07B8\\x88\\x84\\x84\\x847\\0A\\0!\\v \\0A\\x006 
A\\xC0\\0K\\r B \\x86\\v! 	A_M\\rA  	k!	\\f\\v \\0 B\\xFF\\xFF\\xFF\\xFF\\x837\\bA \\v!\\vB\\0! 	A\\xC1\\0O@@\\x7F \\vE@ \\0B\\x007\\bA \\f\\v \\0 \\rAj"
6 \\0 \\0)\\b"B \\x86"7\\b  \\rAtj B\\x86B\\x80\\x80\\x80\\xF8\\x83 B\\b\\x86B\\x80\\x80\\xFC\\x07\\x83\\x84 B\\b\\x88B\\x80\\xFE\\x83 B8\\x88\\x84\\x847\\0 
!\\rA\\0\\v!\\v 	A k"	A\\xC0\\0K\\r\\0\\v\\v 	!
\\v \\0\\x7F \\vE@ \\0 B \\x887\\bA \\f\\v \\0 \\0("	Aj6 \\0 \\0)\\b"B \\x86"\\x07 B \\x88"\\b\\x84"7\\b \\0(\\0 	Atj B\\b\\x86B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\0\\x83 \\bB8\\x86\\x84 B\\x80\\x80\\xFC\\x07\\x83B\\x86 B\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 B\\x86B\\x80\\x80\\x80\\xF8\\x83 B\\b\\x86B\\x80\\x80\\xFC\\x07\\x83\\x84 B\\b\\x88B\\x80\\xFE\\x83 \\x07B8\\x88\\x84\\x84\\x847\\0A\\0\\v6A\\xE0\\0 
k!	B\\0!\\f\\v 	 \\rk"	A K\\r\\0 \\0\\x7F \\0(E@ \\0 B \\x887\\bA \\f\\v \\0 \\0("
Aj6 \\0 \\0)\\b"B \\x86"\\x07 B \\x88"\\b\\x84"7\\b \\0(\\0 
Atj B\\b\\x86B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\0\\x83 \\bB8\\x86\\x84 B\\x80\\x80\\xFC\\x07\\x83B\\x86 B\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 B\\x86B\\x80\\x80\\x80\\xF8\\x83 B\\b\\x86B\\x80\\x80\\xFC\\x07\\x83\\x84 B\\b\\x88B\\x80\\xFE\\x83 \\x07B8\\x88\\x84\\x84\\x847\\0A\\0\\v6 	A j!	 B \\x86!\\v \\xAD 	 k"	\\xAD\\x86 \\x84\\v! 	A K\\r \\0(E@ \\0 B \\x887\\bA \\f\\v \\0 \\0("
Aj6 \\0 \\0)\\b"B \\x86"\\x07 B \\x88"\\b\\x84"7\\b \\0(\\0 
Atj B\\b\\x86B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\0\\x83 \\bB8\\x86\\x84 B\\x80\\x80\\xFC\\x07\\x83B\\x86 B\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 B\\x86B\\x80\\x80\\x80\\xF8\\x83 B\\b\\x86B\\x80\\x80\\xFC\\x07\\x83\\x84 B\\b\\x88B\\x80\\xFE\\x83 \\x07B8\\x88\\x84\\x84\\x847\\0A\\0\\v6 	A j!	 B \\x86!\\v Aj! Ak"\\r\\0\\v\\vA!
 	A?K\\r\\0 \\0\\x7F \\0("A G@ \\r \\0  	\\xAD\\x887\\bA\\xC0\\0\\f\\v \\0 \\0)\\bA\\xC0\\0 	k\\xAD\\x86  	\\xAD\\x88\\x847\\bA\\xE0\\0\\v 	k6\\v 
\\vI\\x7F@ \\0 A\\xFFqA\\b\\vE\\r\\0 \\0 A\\bvA\\xFFqA\\b\\vE\\r\\0 \\0 AvA\\xFFqA\\b\\vE\\r\\0 \\0 AvA\\b\\v!\\v \\vJ\\x7F@ \\0-\\0\\0"E  -\\0\\0"Gr\\r\\0@ -\\0! \\0-\\0"E\\r Aj! \\0Aj!\\0  F\\r\\0\\v\\v  k\\v\\xA6\\b\\x7FAA \\x07\\x1B!AA \\x07\\x1B!	@@ E@ (\\0E@ (\\0" 	v\\r \\0  	\\vE\\r \\0   (\\0CE\\r\\f\\v \\0  	\\vE\\r (\\0"AK\\r \\0 A\\vE\\r E\\r@ \\0  \\bAtj(\\0A\\x7FA\\x7F (\\0"tA\\x7Fs A O\\x1Bq \\v@  \\bAj"\\bG\\r\\f\\v\\vA\\0\\v  j v!A\\0!@ A\\0  \\x1Bk"
 \\b"\\x07j!\\b@  At"\\rj"\\f(\\0E@A\\0!\\v  \\rj"\\f(\\0"\\r 	v\\r \\0 \\r 	\\vE\\r \\0  \\x07Atj 
 \\f(\\0C\\r\\f\\vA\\0!\\v \\0  	\\vE\\r \\f(\\0"
AK\\r \\0 
A\\vE\\r \\x07 \\bO\\r\\0@ \\0  \\x07Atj(\\0A\\x7FA\\x7F \\f(\\0"
tA\\x7Fs 
A O\\x1Bq 
\\vE\\r \\x07Aj"\\x07 \\bG\\r\\0\\v\\vA!\\v Aj" vE\\r\\0\\v\\v \\v\\vA\\v\\xA6|~\\x7F \\0\\xBD"B4\\x88\\xA7A\\xFFq"A\\xB2\\bM| A\\xFD\\x07M| \\0D\\0\\0\\0\\0\\0\\0\\0\\0\\xA2| \\0\\x99"\\0D\\0\\0\\0\\0\\0\\x000C\\xA0D\\0\\0\\0\\0\\0\\x000\\xC3\\xA0 \\0\\xA1"D\\0\\0\\0\\0\\0\\0\\xE0?d@ \\0 \\xA0D\\0\\0\\0\\0\\0\\0\\xF0\\xBF\\xA0\\f\\v \\0 \\xA0"\\0 D\\0\\0\\0\\0\\0\\0\\xE0\\xBFeE\\r\\0 \\0D\\0\\0\\0\\0\\0\\0\\xF0?\\xA0\\v"\\0\\x9A \\0 B\\0S\\x1B\\v \\0\\v\\xFC\\v~\\x7F~ \\0\\xBD"B4\\x88\\xA7A\\xFFq"A\\xFFG| E@  \\0D\\0\\0\\0\\0\\0\\0\\0\\0a\\x7FA\\0 \\0D\\0\\0\\0\\0\\0\\0\\xF0C\\xA2 H!\\0 (\\0A@j\\v6\\0 \\0\\v  A\\xFE\\x07k6\\0 B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\x87\\x80\\x7F\\x83B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\xF0?\\x84\\xBF \\0\\v\\v\\xD2\\b\\x7F{~  j!@@  	"\\rv! \\rE\\r\\0 \\rAk!	  O\\r\\v\\v     \\b \\r \\b \\rI\\x1B" \\r 
 \\0(\\xE8\\b\\0@ \\vE\\r\\0A\\0!A\\0!	 \\rA\\0N@A \\rt!	@  AtjA\\0  \\x1B" F\\x7FAA\\0!\\0 !\\bA\\0!
@  k"AO@ A|q!
  \\bAtj!\\0\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!\\x1BA\\0!\\b@ \\0 \\bAtj\\xFD\\0\\0"A\\xFD\\xAC \\xFDQ \\x1B\\xFDP!\\x1B \\bAj"\\b 
G\\r\\0\\v \\x1B \\x1B \\x1B\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFDP"\\x1B \\x1B \\x1B\\xFD\\r\\x07\\0\\0\\0\\xFDP\\xFD\\x1B\\0!\\0 
 F\\r 
 j!\\b\\v@ \\0  \\bAtj(\\0"\\0Au \\0sr!\\0 \\bAj!\\b 
Aj"
 G\\r\\0\\v\\v  j k! \\0gAsAjA \\0\\x1B\\v6\\0 Aj" 	G\\r\\0\\v\\v \\r L\\r\\0 \\r!@ Ak!A\\0!\\b@  	Atj  Atj"\\0(\\0"
 \\0("\\0 \\0 
I\\x1B6\\0 	Aj!	 Aj! \\bAj"\\b vE\\r\\0\\v  J\\r\\0\\v\\vA\\0!A\\0!A\\0!
@ \\r H\\r\\0 \\x07Ak! A\\xA0\\xEB\\0j!A\\0!\\x07@  \\rv!  \\x07Atj!  \\x07Atj!  As"A\\flj"\\0(\\0! \\0(!A!A\\0!	A\\0!\\b@ 	E  Oq\\r A\\0  	\\x1Bk!A\\0!@  	Atj)\\0"BT\\r\\0A\\x80\\x80 n\\xAD B}~B\\x88"P\\r\\0A\\xC0\\0 y\\xA7k"\\0  \\0 I\\x1B!\\v \\b A\\x7F  Ak\\xAD\\x88 B\\x86 \\x1B"\\xA7 Aj lAj"\\0 Av"kj \\0\\xAD  \\xAD}|B\\xFF\\xFF\\xFF\\xFFZ\\x1B"\\0A\\x7FF\\x1B!\\b \\v@  	At"j  j(\\0"A\\0 A I  lA
j" \\0Mq"\\x1B6\\0A\\0 \\b \\x1B!\\b  \\0 \\x1B!\\0\\v  	Atj \\b6\\0A\\x7F \\0 j"\\0 \\0 I\\x1B! 	Aj"	 \\rvE\\r\\0\\v 
 \\r Ak I"\\0\\x1B!
   \\0\\x1B!   \\0\\x1B! \\x07A \\rtj!\\x07 \\r J \\rAk!\\r\\r\\0\\v\\v \\f 
6  A\\flj! \\f(\\b!\\0A 
t"E"E@ \\0(\\0 (\\xA0k \\xFC
\\0\\0\\v \\vE rE@ \\0( A\\xA0\\xEB\\0j( \\xFC
\\0\\0\\v \\0(\\0!\\0A\\0!	@@ \\0 	Atj(\\0AI@ 	Aj"	 
vE\\r\\f\\v\\v \\fA6\\0\\v \\v\\xE9	\\x7F~#\\0Ak"	$\\0@ E\\r\\0 (\\0"E\\r\\0@ (" ("AjK\\r\\0 (A\\xCD\\0jAv j" M\\r\\0 A\\x81\\x80\\x80K\\r  Av" j   k I\\x1B"\\x7F A\\xFF\\xFF\\xFF\\xFFK\\r AtA\\0\\v"E\\r  6  6\\0\\v@A\\xC0\\0 ("k"AO@  Aj"6  )\\bB\\x86B\\xFE\\xFF\\0\\x847\\b\\f\\v @  A2k"6  ("Aj6  Atj )\\b \\xAD\\x86"\\vA\\xFE\\xFF\\0 v\\xAD\\x84"\\fB8\\x86 \\fB\\x80\\xFE\\x83B(\\x86\\x84 \\fB\\x80\\x80\\xFC\\x07\\x83B\\x86 \\fB\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 \\vB\\b\\x88B\\x80\\x80\\x80\\xF8\\x83 \\vB\\x88B\\x80\\x80\\xFC\\x07\\x83\\x84 \\vB(\\x88B\\x80\\xFE\\x83 \\vB8\\x88\\x84\\x84\\x847\\0 B\\xFE\\xFF\\x007\\b\\f\\v  ("Aj6  AtjB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\x9F~7\\0A\\0!\\v@  ("AjK\\r\\0 A@kAv j" M\\r\\0A\\0! A\\x81\\x80\\x80K\\r  Av" j   k I\\x1B"\\x7F A\\xFF\\xFF\\xFF\\xFFK\\r AtA\\0\\v"E\\r  6  6\\0 (!\\v@A\\xC0\\0 k"AO@  Aj6  )\\bB\\x867\\b\\f\\v @  A?k6  ("Aj6  Atj )\\b \\xAD\\x86"\\vB8\\x86 \\vB\\x80\\xFE\\x83B(\\x86\\x84 \\vB\\x80\\x80\\xFC\\x07\\x83B\\x86 \\vB\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 \\vB\\b\\x88B\\x80\\x80\\x80\\xF8\\x83 \\vB\\x88B\\x80\\x80\\xFC\\x07\\x83\\x84 \\vB(\\x88B\\x80\\xFE\\x83 \\vB8\\x88\\x84\\x84\\x847\\0 B\\x007\\b\\f\\v  ("Aj6  AtjB\\x007\\0\\vA\\0!A!  \\0(A\\0GA\\vE\\r\\0A!\\b \\x7F@@@@@@@@ \\0(\\0"A\\xFFL@ A\\xBFL@A A\\xC0F\\r
 A\\x80F\\r A\\x80G\\r	A	\\f
\\v A\\xC0F\\r A\\x80\\bF\\r A\\x80	G\\r\\bA\\f	\\v A\\xFF#L@ A\\x80F\\r A\\x80F\\r A\\x80 G\\r\\bA\\f\\f	\\v A\\xFF\\xFF\\0L@ A\\x80$F\\r A\\x80\\xC0\\0G\\r\\bA\\r\\f	\\v A\\x80\\x80F\\r A\\x80\\x80G\\r\\x07A\\f\\b\\vA\\f\\x07\\vA\\f\\vA\\f\\vA\\b\\f\\vA
\\f\\vA\\v\\f\\vA\\f\\vA\\bA A\\x81I"\\x1B!\\bA\\0!AA\\x07 \\x1B\\vA\\vE\\r\\0A\\0!@@@@@@@@ \\0("A\\xC3\\xD8L@ A\\xA1\\xACL@ A\\xC0>F\\r A\\x80\\xFD\\0G\\r\\bA!\\f	\\v A\\xA2\\xACF\\r A\\xC0\\xBBF\\r A\\x80\\xFAG\\r\\x07A\\b!\\f\\b\\v A\\xFF\\xEDL@ A\\xC4\\xD8F\\r A\\x80\\xF7F\\r A\\x88\\xB1G\\r\\x07A!\\f\\b\\v A\\x80\\xEEF\\r A\\x80\\xDC\\vG@ A\\x90\\xE2
G\\r\\x07A!\\f\\b\\vA!\\f\\x07\\vA!\\f\\vA!\\f\\vA\\x07!\\f\\vA	!\\f\\vA
!\\f\\vA\\v!\\f\\v A\\xE8\\x07p A\\x98\\xC8KrE@A\\f!A\\f!\\f\\v A
p A\\xF6\\xFF'KrE@A!A!\\f\\vA\\rA\\0 A\\x80\\x80I\\x1B"!\\v  A\\vE\\r\\0@@@@@ \\0(\\f\\0\\vA	!\\f\\vA
!\\f\\v \\0(\\bAk"AM\\r\\f\\vA\\b!\\v  A\\vE\\r\\0  \\0(A\\bkAw"AM\\x7F At(\\x90=A\\0\\vA\\vE\\r\\0 (\\0"E\\r\\0 (!@ (" ("\\x07AjK\\r\\0 A@kAv \\x07j"\\x07 M\\r\\0 \\x07A\\x81\\x80\\x80K@A\\0!\\f\\vA\\0!  Av" j \\x07 \\x07 k I\\x1B"\\x7F A\\xFF\\xFF\\xFF\\xFFK\\r AtA\\0\\v"E\\r  6  6\\0 (!\\v@A\\xC0\\0 k"AO@  Aj6  )\\bB\\x867\\b\\f\\v @  A?k6  ("Aj6  Atj )\\b \\xAD\\x86"\\vB8\\x86 \\vB\\x80\\xFE\\x83B(\\x86\\x84 \\vB\\x80\\x80\\xFC\\x07\\x83B\\x86 \\vB\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 \\vB\\b\\x88B\\x80\\x80\\x80\\xF8\\x83 \\vB\\x88B\\x80\\x80\\xFC\\x07\\x83\\x84 \\vB(\\x88B\\x80\\xFE\\x83 \\vB8\\x88\\x84\\x84\\x847\\0 B\\x007\\b\\f\\v  ("Aj6  AtjB\\x007\\0\\v@ \\0(E@ \\0("A\\0N\\x7F\\x7F A\\xFF\\0M@  A\\b\\v\\f\\v A\\xFFM@  AvA\\xC0rA\\b\\v  A?qA\\x80rA\\b\\vq\\f\\v A\\xFF\\xFFM@  A\\fvA\\xE0rA\\b\\v  AvA?qA\\x80rA\\b\\vq  A?qA\\x80rA\\b\\vq\\f\\v A\\xFF\\xFF\\xFF\\0M@  AvA\\xF0rA\\b\\v  A\\fvA?qA\\x80rA\\b\\vq  AvA?qA\\x80rA\\b\\vq  A?qA\\x80rA\\b\\vq\\f\\v A\\xFF\\xFF\\xFFM@  AvA\\xF8rA\\b\\v  AvA?qA\\x80rA\\b\\vq  A\\fvA?qA\\x80rA\\b\\vq  AvA?qA\\x80rA\\b\\vq  A?qA\\x80rA\\b\\vq\\f\\v  AvA\\xFCrA\\b\\v  AvA?qA\\x80rA\\b\\vq  AvA?qA\\x80rA\\b\\vq  A\\fvA?qA\\x80rA\\b\\vq  AvA?qA\\x80rA\\b\\vq  A?qA\\x80rA\\b\\vq\\vA\\0\\v\\rA\\0!\\f\\v \\0)"\\vB\\xFF\\xFF\\xFF\\xFF\\xFFX\\x7F\\x7F \\vB\\xFF\\0X@  \\v\\xA7A\\b\\v\\f\\v \\vB\\xFFX@  \\vB\\x88\\xA7A\\xC0rA\\b\\v  \\v\\xA7A?qA\\x80rA\\b\\vq\\f\\v \\vB\\xFF\\xFFX@  \\vB\\f\\x88\\xA7A\\xE0rA\\b\\v  \\v\\xA7"AvA?qA\\x80rA\\b\\vq  A?qA\\x80rA\\b\\vq\\f\\v \\vB\\xFF\\xFF\\xFF\\0X@  \\vB\\x88\\xA7A\\xF0rA\\b\\v  \\v\\xA7"A\\fvA?qA\\x80rA\\b\\vq  AvA?qA\\x80rA\\b\\vq  A?qA\\x80rA\\b\\vq\\f\\v \\vB\\xFF\\xFF\\xFFX@  \\vB\\x88\\xA7A\\xF8rA\\b\\v  \\v\\xA7"AvA?qA\\x80rA\\b\\vq  A\\fvA?qA\\x80rA\\b\\vq  AvA?qA\\x80rA\\b\\vq  A?qA\\x80rA\\b\\vq\\f\\v \\vB\\xFF\\xFF\\xFF\\xFF\\x07X@  \\vB\\x88\\xA7A\\xFCrA\\b\\v  \\v\\xA7"AvA?qA\\x80rA\\b\\vq  AvA?qA\\x80rA\\b\\vq  A\\fvA?qA\\x80rA\\b\\vq  AvA?qA\\x80rA\\b\\vq  A?qA\\x80rA\\b\\vq\\f\\v A\\xFEA\\b\\v  \\vB\\x88\\xA7A\\x80rA\\b\\vq  \\v\\xA7"AvA?qA\\x80rA\\b\\vq  AvA?qA\\x80rA\\b\\vq  A\\fvA?qA\\x80rA\\b\\vq  AvA?qA\\x80rA\\b\\vq  A?qA\\x80rA\\b\\vq\\vA\\0\\v\\r\\0A\\0!\\f\\v@ \\r\\0 \\0(\\0Ak" \\bv@A\\0!\\f\\v   \\b\\v\\r\\0A\\0!\\f\\v@@@@ A\\fk\\0\\v \\0("\\0A\\xFF\\xCFK@A\\0!\\f\\v  \\0A\\xE8\\x07nA\\b\\v\\rA\\0!\\f\\v \\0("\\0A\\xFF\\xFFK@A\\0!\\f\\v  \\0A\\v\\rA\\0!\\f\\v \\0("\\0A\\xFF\\xFF'K@A\\0!\\f\\v  \\0A
nA\\v\\r\\0A\\0!\\f\\vA\\0!A\\0!A\\0!A\\0!\\b#\\0Ak"$\\0  A\\fj A\\bj5\\x7F@ (\\b"E\\r\\0 (\\f!\\0 Aq!\\x07 AO@ A|q!
 \\0!@ -\\0 -\\0 -\\0 -\\0\\0 s-\\0\\x80\\x1Bs-\\0\\x80\\x1Bs-\\0\\x80\\x1Bs-\\0\\x80\\x1B! Aj! \\bAj"\\b 
G\\r\\0\\v \\x07E\\r \\0 
j!\\0\\v@ \\0-\\0\\0 s-\\0\\x80\\x1B! \\0Aj!\\0 Aj" \\x07G\\r\\0\\v\\v 	 :\\0AA\\0\\v Aj$\\0E\\r\\0  	-\\0A\\b\\v!\\v 	Aj$\\0 \\v\\xB2*	\\x7F{@ \\xAD \\xAD~B \\x88\\xA7\\r\\0 \\xAD  l"\\v\\xAD~B \\x88\\xA7\\r\\0 \\0(X!@  \\vl"\\v \\0(\\\\M@ !\\f\\v@  \\v"@ \\0 6X\\f\\v 	 \\0 \\v\\r"6X \\r\\0 \\0A\\x006\\\\A\\0\\v \\0 \\v6\\\\\\v@@@@@@@@@@@@@@@ A\\xE4\\0l j"A\\xACL@@ A\\xE5\\0k\\b\\v
\\f	\\f\\b\\f\\x07\\0\\v A\\xC9k\\b\\v\\v\\v\\v\\v@@@@@@@@ A\\x91k\\b\\0\\v A\\xADk\\v E\\r (! (! (!\\x07 (!\\b (\\f!	 (\\b!
 (!\\f (\\0!\\rA\\0!@  \\r At"j(\\x006\\0   \\fj(\\x006   
j(\\x006\\b   	j(\\x006\\f   \\bj(\\x006   \\x07j(\\x006   j(\\x006   j(\\x006 A j! Aj" G\\r\\0\\v\\f\\v E\\r (! (! (\\f!\\x07 (\\b!\\b (!	 (\\0!
A\\0!@  
 At"j(\\x006\\0   	j(\\x006   \\bj(\\x006\\b   \\x07j(\\x006\\f   j(\\x006   j(\\x006 Aj! Aj" G\\r\\0\\v\\f\\v E\\r (\\f! (\\b! (!\\x07 (\\0!\\bA\\0!@ AI\\r\\0  \\b At"jI \\b  Atj"	Iq \\x07 	I   \\x07jIqr  	I   jIq  	I   jIqrr\\r\\0 A|q!A\\0!@  Atj"	 \\b At"
j\\xFD\\0\\0" \\x07 
j\\xFD\\0\\0"\\xFD\\r\\f\\r\\0\\0  
j\\xFD\\0\\0"  
j\\xFD\\0\\0"\\xFD\\r\\0\\0\\f\\r\\xFD\\r\\0\\x07\\x1B\\xFD\\v0 	  \\xFD\\r\\b	
\\v\\x1B\\0\\0  \\xFD\\r\\0\\0\\b	
\\v\\x1B\\xFD\\r\\0\\x07\\x1B\\xFD\\v  	  \\xFD\\r\\x07\\0\\0  \\xFD\\r\\0\\0\\x07\\xFD\\r\\0\\x07\\x1B\\xFD\\v 	  \\xFD\\r\\0\\0\\0  \\xFD\\r\\0\\0\\0\\xFD\\r\\0\\x07\\x1B\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r  Atj!\\v Ar! Aq@  \\b At"j(\\x006\\0   \\x07j(\\x006   j(\\x006\\b   j(\\x006\\f Aj! !\\v  F\\r@  \\b At"j(\\x006\\0   \\x07j(\\x006   j(\\x006\\b   j(\\x006\\f  \\b Aj"j(\\x006   \\x07j(\\x006   j(\\x006   j(\\x006 A j! Aj" G\\r\\0\\v\\f\\v E\\r (! (\\0!\\x07A\\0!@ AI@A\\0!\\f\\v  \\x07 At"jI \\x07  Atj"Iq@A\\0!\\f\\v  I   jIq@A\\0!\\f\\v A|q!A\\0!@  Atj"\\b \\x07 At"	j\\xFD\\0\\0"  	j\\xFD\\0\\0"\\xFD\\r\\b	
\\v\\x1B\\f\\r\\xFD\\v \\b  \\xFD\\r\\0\\x07\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r  Atj!\\v@ Aq"\\bE@ !\\f\\v !@  \\x07 At"	j(\\x006\\0   	j(\\x006 Aj! A\\bj! Aj" \\bG\\r\\0\\v\\v  kA|K\\r@  \\x07 At"j(\\x006\\0   j(\\x006  \\x07 Aj"j(\\x006\\b   j(\\x006\\f  \\x07 A\\bj"j(\\x006   j(\\x006  \\x07 A\\fj"j(\\x006   j(\\x006 A j! Aj" G\\r\\0\\v\\f\\v E\\r (\\0!A\\0!@ AI@A\\0!\\f\\v  kAI@A\\0!\\f\\v A|q!A\\0!@  At"\\x07j  \\x07j\\xFD\\0\\0\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r  Atj!\\v@ Aq"\\x07E@ !\\f\\v !@   Atj(\\x006\\0 Aj! Aj! Aj" \\x07G\\r\\0\\v\\v  kA|K\\r@   Atj"(\\x006\\0  (6  (\\b6\\b  (\\f6\\f Aj! Aj" G\\r\\0\\v\\f\\v E\\rA\\0!@  At" (\\0j(\\0":\\0\\0  Av:\\0  A\\bv:\\0  ( j(\\0":\\0  Av:\\0  A\\bv:\\0 Aj! Aj" G\\r\\0\\v\\f\\v E\\rA\\0! AG@ Aq A~q!@  At"\\x07 (\\0j(\\0":\\0\\0  Av:\\0  A\\bv:\\0  (\\0 \\x07j(":\\0  Av:\\0  A\\bv:\\0 Aj! Aj" G\\r\\0\\vE\\r\\v  (\\0 Atj(\\0":\\0\\0  Av:\\0  A\\bv:\\0\\f\\v E\\r\\r (! (! (!\\x07 (!\\b (\\f!	 (\\b!
 (!\\f (\\0!\\rA\\0!@  \\r At"j(\\0;\\0   \\fj(\\0;   
j(\\0;   	j(\\0;   \\bj(\\0;\\b   \\x07j(\\0;
   j(\\0;\\f   j(\\0; Aj! Aj" G\\r\\0\\v\\f\\r\\v E\\r\\f (! (! (\\f!\\x07 (\\b!\\b (!	 (\\0!
A\\0!@  
 At"j(\\0;\\0   	j(\\0;   \\bj(\\0;   \\x07j(\\0;   j(\\0;\\b   j(\\0;
 A\\fj! Aj" G\\r\\0\\v\\f\\f\\v E\\r\\v (\\f! (\\b!\\x07 (!\\b (\\0!	A\\0! AM\\r
 A|q!A\\0!@  Atj"
 	 At"j\\xFD\\0\\0"  \\bj\\xFD\\0\\0"\\xFD\\r\\b	\\0\\0\\f\\r\\0\\0  \\x07j\\xFD\\0\\0"\\xFD\\x1B\\xFD  j\\xFD\\0\\0"\\xFD\\x1B\\xFD \\xFD\\x1B\\xFD \\xFD\\x1B\\xFD\\x07\\xFD\\v 
  \\xFD\\r\\0\\0\\0\\0\\0 \\xFD\\x1B\\0\\xFD \\xFD\\x1B\\0\\xFD \\xFD\\x1B\\xFD \\xFD\\x1B\\xFD\\x07\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\v  Atj!\\f
\\v E\\r
 (! (\\0!A\\0! AM\\r\\b A|q!A\\0!@  At"\\x07j  \\x07j\\xFD\\0\\0"  \\x07j\\xFD\\0\\0"\\xFD\\r\\0\\x07\\xFD\\f\\xFF\\xFF\\0\\0\\xFF\\xFF\\0\\0\\xFF\\xFF\\0\\0\\xFF\\xFF\\0\\0\\xFDN  \\xFD\\r\\b	
\\v\\x1B\\f\\r\\xFD\\f\\xFF\\xFF\\0\\0\\xFF\\xFF\\0\\0\\xFF\\xFF\\0\\0\\xFF\\xFF\\0\\0\\xFDN\\xFD\\x86\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r
  Atj!\\f\\b\\v E\\r	 (\\0!A\\0! AM\\r A|q!A\\0!@  Atj  Atj\\xFD\\0\\0\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\r\\0\\b	\\f\\r\\0\\0\\0\\0\\xFD[\\0\\0 Aj" G\\r\\0\\v  F\\r	  Atj!\\f\\v E\\r\\bA\\0!@  At" (\\0j(\\0:\\0\\0  ( j(\\0:\\0  (\\b j(\\0:\\0  (\\f j(\\0:\\0  ( j(\\0:\\0  ( j(\\0:\\0  ( j(\\0:\\0  ( j(\\0:\\0\\x07 A\\bj! Aj" G\\r\\0\\v\\f\\b\\v E\\r\\x07A\\0!@  At" (\\0j(\\0:\\0\\0  ( j(\\0:\\0  (\\b j(\\0:\\0  (\\f j(\\0:\\0  ( j(\\0:\\0  ( j(\\0:\\0 Aj! Aj" G\\r\\0\\v\\f\\x07\\v E\\rA\\0!@  At" (\\0j(\\0:\\0\\0  ( j(\\0:\\0  (\\b j(\\0:\\0  (\\f j(\\0:\\0 Aj! Aj" G\\r\\0\\v\\f\\v E\\rA\\0! AG@ Aq A~q!@  At" (\\0j(\\0:\\0\\0  ( j(\\0:\\0  Ar" (\\0j(\\0:\\0  ( j(\\0:\\0 Aj! Aj" G\\r\\0\\vE\\r\\v  At" (\\0j(\\0:\\0\\0  ( j(\\0:\\0\\f\\v E\\r Aq!A\\0!@ AI@A\\0!\\f\\v A|q!\\x07A\\0!@  At" (\\0j(\\0:\\0\\0  (\\0 j(:\\0  (\\0 j(\\b:\\0  (\\0 j(\\f:\\0 Aj! Aj" \\x07G\\r\\0\\v E\\r\\v@  (\\0 Atj(\\0:\\0\\0 Aj! Aj! Aj" G\\r\\0\\v\\f\\v@@@@ Ak\\0\\x07\\v E Er\\r A|q!	 Aq!\\bA\\0! AI!
@A\\0!A\\0!@ 
E@@  At"  Atj"\\x07(\\0j(\\x006\\0  \\x07( j(\\x006  \\x07(\\b j(\\x006\\b  \\x07(\\f j(\\x006\\f Aj! Aj" 	G\\r\\0\\v ! \\bE\\r\\vA\\0!@   Atj(\\0 Atj(\\x006\\0 Aj! Aj! Aj" \\bG\\r\\0\\v\\v Aj" G\\r\\0\\v\\f\\v E Er\\r A~q!\\b Aq!	A\\0!@A\\0!@ AG@@  At"
  Atj"\\f(\\0j(\\0"\\x07:\\0\\0  \\x07Av:\\0  \\x07A\\bv:\\0  \\f( 
j(\\0"\\x07:\\0  \\x07Av:\\0  \\x07A\\bv:\\0 Aj! Aj" \\bG\\r\\0\\v 	E\\r\\v   Atj(\\0 Atj(\\0":\\0\\0  Av:\\0  A\\bv:\\0 Aj!\\v Aj" G\\r\\0\\v\\f\\v E Er\\r A|q"At!
 AI!\\f@A\\0!@ \\fE@@  Atj \\x07At"\\b  Atj"	(\\0j(\\0\\xFD 	( \\bj(\\0\\xFD 	(\\b \\bj(\\0\\xFD 	(\\f \\bj(\\0\\xFD\\xFD[\\0\\0 Aj" G\\r\\0\\v  
j! " F\\r\\v@   Atj(\\0 \\x07Atj(\\0;\\0 Aj! Aj" G\\r\\0\\v\\v \\x07Aj"\\x07 G\\r\\0\\v\\f\\v E Er\\r A|q!	 Aq!\\bA\\0! AI!
@A\\0!A\\0!@ 
E@@  At"  Atj"\\x07(\\0j(\\0:\\0\\0  \\x07( j(\\0:\\0  \\x07(\\b j(\\0:\\0  \\x07(\\f j(\\0:\\0 Aj! Aj" 	G\\r\\0\\v ! \\bE\\r\\vA\\0!@   Atj(\\0 Atj(\\0:\\0\\0 Aj! Aj! Aj" \\bG\\r\\0\\v\\v Aj" G\\r\\0\\v\\f\\v@   Atj(\\0;\\0 Aj! Aj" G\\r\\0\\v\\f\\v@   At"j(\\0;\\0   j(\\0; Aj! Aj" G\\r\\0\\v\\f\\v@  	 At"j(\\0;\\0   \\bj(\\0;   \\x07j(\\0;   j(\\0; A\\bj! Aj" G\\r\\0\\v\\v \\0 \\0(P" \\vj"6P  K@ \\0 \\0(TAj6T\\v \\0(X! \\0A@k" A@rj!@A\\xC0\\0 A?qk" \\vK@ \\vE\\r   \\v\\xFC
\\0\\0\\f\\v @   \\xFC
\\0\\0\\v  \\0   j! \\v k"A\\xC0\\0O@@ \\0 \\xFD\\0\\x000\\xFD\\v\\x000 \\0 \\xFD\\0\\0 \\xFD\\v\\0  \\0 \\xFD\\0\\0\\xFD\\v\\0 \\0 \\xFD\\0\\0\\0\\xFD\\v\\0\\0  \\0  A@k! A@j"A?K\\r\\0\\v\\v E\\r\\0 \\0  \\xFC
\\0\\0\\vA!\\v \\v\\xC4\\x7F{|@ C\\0\\0\\0\\0_@ A\\0L\\r AO@ A\\xFC\\xFF\\xFF\\xFF\\x07q!@ \\0 Atj\\xFD\\f\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\v@ \\0 AtjA\\x80\\x80\\x80\\xFC6\\0 Aj" G\\r\\0\\v\\f\\v C\\0\\0\\x80?\\\`@ A\\0L\\r Ak\\xB8!\\r AO@ A\\xFC\\xFF\\xFF\\xFF\\x07q!D-DT\\xFB!@ \\r\\xA3\\xFD!
\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!\\b@ \\0 Atj 
 \\b\\xFD\\xFE\\xFD\\xF2"\\v\\xFD!\\0\\xB6
\\xFD \\v\\xFD!\\xB6
\\xFD  
 \\b \\b\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE\\xFD\\xF2"\\v\\xFD!\\0\\xB6
\\xFD  \\v\\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0 \\b\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE!\\b Aj" G\\r\\0\\v  F\\r\\vD\\0\\0\\0\\0\\0\\0\\xF0? \\r\\xA3!\\r@ \\0 Atj \\xB8D-DT\\xFB!@\\xA2 \\r\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0 Aj" G\\r\\0\\v\\f\\v C\\0\\0\\x80?] C\\0\\0\\0\\0^qE@ \\xB2C\\0\\0\\x80>\\x94\\xFC\\0!@ A\\0L\\r\\0 AO@ A\\xFC\\xFF\\xFF\\xFF\\x07q!@ \\0 Atj\\xFD\\f\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\v@ \\0 AtjA\\x80\\x80\\x80\\xFC6\\0 Aj" G\\r\\0\\v\\v AH\\r \\0  k"Atj! Ak"\\xB8!\\rA\\0! A\\xFC\\xFF\\xFF\\xFFqE AIrE@ A\\xFC\\xFF\\xFF\\xFF\\x07q!D\\0\\0\\0\\0\\0\\0\\xF0? \\r\\xA3D-DT\\xFB!	@\\xA2\\xFD!
 \\xFD!\\v\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!\\bA\\0!@ \\0 At"\\x07j \\b\\xFD\\xFE 
\\xFD\\xF2"	\\xFD!\\0\\xB6
\\xFD 	\\xFD!\\xB6
\\xFD  \\b \\b\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE 
\\xFD\\xF2"	\\xFD!\\0\\xB6
\\xFD  	\\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0  \\x07j \\b \\v\\xFD\\xAE"	\\xFD\\xFE 
\\xFD\\xF2"\\f\\xFD!\\0\\xB6
\\xFD \\f\\xFD!\\xB6
\\xFD  	 \\b\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE 
\\xFD\\xF2"	\\xFD!\\0\\xB6
\\xFD  	\\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0 \\b\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE!\\b Aj" G\\r\\0\\v  F\\r\\vD\\0\\0\\0\\0\\0\\0\\xF0? \\r\\xA3D-DT\\xFB!	@\\xA2!\\r@ \\0 At"j \\xB8 \\r\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0  j  j\\xB7 \\r\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0 Aj" G\\r\\0\\v\\f\\v C\\0\\0\\0?\\x94 \\xB2\\x94\\xFC\\0!@ A\\0L\\r\\0 AO@ A\\xFC\\xFF\\xFF\\xFF\\x07q!@ \\0 Atj\\xFD\\f\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\v@ \\0 AtjA\\x80\\x80\\x80\\xFC6\\0 Aj" G\\r\\0\\v\\v AH\\r\\0 \\0  k"Atj! Ak"\\xB8!\\rA\\0! A\\xFC\\xFF\\xFF\\xFFqE AIrE@ A\\xFC\\xFF\\xFF\\xFF\\x07q!D\\0\\0\\0\\0\\0\\0\\xF0? \\r\\xA3D-DT\\xFB!	@\\xA2\\xFD!
 \\xFD!\\v\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!\\bA\\0!@ \\0 At"\\x07j \\b\\xFD\\xFE 
\\xFD\\xF2"	\\xFD!\\0\\xB6
\\xFD 	\\xFD!\\xB6
\\xFD  \\b \\b\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE 
\\xFD\\xF2"	\\xFD!\\0\\xB6
\\xFD  	\\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0  \\x07j \\b \\v\\xFD\\xAE"	\\xFD\\xFE 
\\xFD\\xF2"\\f\\xFD!\\0\\xB6
\\xFD \\f\\xFD!\\xB6
\\xFD  	 \\b\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE 
\\xFD\\xF2"	\\xFD!\\0\\xB6
\\xFD  	\\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0 \\b\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE!\\b Aj" G\\r\\0\\v  F\\r\\vD\\0\\0\\0\\0\\0\\0\\xF0? \\r\\xA3D-DT\\xFB!	@\\xA2!\\r@ \\0 At"j \\xB8 \\r\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0  j  j\\xB7 \\r\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0 Aj" G\\r\\0\\v\\v\\v\\xC7w\\x7F{\\v|} \\0(\\0!@ \\0("
(\\x88 I@@ (\\xACE@A!\\f\\v At! A\\xFF\\xFF\\xFF\\xFFK!A! 
! !\\x7F (( \\fM@ ! !
\\f\\v @A\\0!\\f\\v \\r"\\r\\x7F  \\fAtj"(\\x8C"@ 	 \\0(\\0! \\0(!\\v  \\r6\\x8C  \\r6\\x8C \\fAj!\\f\\f !
A\\0! \\v\\v!\\v 
(\\xD4
@A Aj"At" AM\\x1B!A At" AM\\x1B! At!\\r At! A\\xFF\\xFF\\xFF\\xFFK! A\\xFF\\xFF\\xFF\\xFFK!A\\0!@ !A\\0!\\x7F@ E\\r\\0 
 At"j(\\0!@ \\0(\\0(@A\\0!\\f@ \\r \\r"E\\r  \\fAt"j"
A\\x98\\xCA\\0j"\\x07(\\0"\\b@ \\b	 \\0( j(\\0!\\v \\x07 6\\0 
 6\\0  j(\\0\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\0  \\0("
 j(\\0"j" (\\0Aj6\\0 \\fAj"\\f \\0(\\0(I\\r\\0\\v\\f\\v \\r\\v \\r"E\\r\\0 (\\xB8J"\\f@ \\f	 \\0(!
\\v  6   6\\xB8J  
j(\\0( \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\0 \\0( j(\\0" ( Aj6  \\r"
E\\r\\0 "(\\xBCJ"\\f@ \\f	 \\0( j(\\0!\\v  
6$  
6\\xBCJ ($\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\0 \\0( j(\\0" ($Aj6$ \\r\\0 \\r"E\\r\\0 (\\xC0J"
@ 
	\\v  6(  6\\xC0J \\0(\\0(\\xAC@ A\\xFF\\xFF\\xFF\\xFFK\\r \\0( j(\\0! \\r\\r"E\\r (\\xC4J"@ 	\\v  6,  6\\xC4J\\vA\\0!
A\\0!@ \\0(\\0( K@A\\0! A\\xFF\\xFF\\xFF\\xFFK\\r \\0( j(\\0!\\f \\r\\r"E\\r \\f At"j"\\x07A\\xC8\\xCA\\0j"\\b(\\0"@ 	 \\0( j(\\0!\\f\\v \\b 6\\0 \\x07 6X \\r\\r"E\\r \\f j"(\\xCCJ"\\f@ \\f	\\v  6\\\\  6\\xCCJ Aj!\\f\\v\\v@@ \\0( j(\\0! 
 \\0(\\0"\\f(O\\r\\0A\\0!  
Al"jA\\xB8\\xC5\\0j \\f(\\xC4E\\r \\0( j(\\0 jA\\xB8\\xC5\\0j \\0(\\0(\\xC4E\\r \\0( j(\\0 jA\\xC4\\xC5\\0j \\0(\\0(\\xC4E\\r 
Aj!
 \\0( j(\\0 jA\\xC4\\xC5\\0j \\0(\\0(\\xC4\\r\\f\\v\\vA\\0! A\\xFF\\xFF\\xFF\\xFFK\\r\\0 \\r\\r"
E\\r\\0 "(\\x88K"\\f@ \\f	 \\0( j(\\0!\\v  
6\\x98  
6\\x88K \\r\\r"E\\r\\0 (\\x8CK"
@ 
	\\v  6\\x9C  6\\x8CK \\0( j(\\0! \\r\\r"
E\\r\\0 "(\\x90K"\\f@ \\f	 \\0( j(\\0!\\v  
6\\xA0  
6\\x90K \\r\\r"E\\r\\0 (\\x94K"
@ 
	\\v  6\\xA4  6\\x94K \\0( j(\\0A\\xF8\\xC6\\0j \\0(\\0(\\xC4E\\r\\0 \\0( j(\\0A\\x84\\xC7\\0j \\0(\\0(\\xC4E\\r\\0 \\0( j(\\0A\\x90\\xC7\\0j \\0(\\0(\\xC4E\\r\\0 \\0( j(\\0A\\x9C\\xC7\\0j \\0(\\0(\\xC4E\\r\\0 \\0( j(\\0A\\xA0\\xEB\\0j \\0(\\0(\\xC4! \\0(" E\\r  j(\\0A\\xAC\\xEB\\0j \\0(\\0(\\xC4! \\0(" E\\r  j(\\0"A\\x98\\xCB\\0j! A\\x88\\xCA\\0j!
A\\0!@ A\\xFF\\xFF\\xFF\\xFFK\\r\\0A At" AM\\x1B\\r"E\\r\\0 (\\0"@ 	\\v  6\\0 
 6\\0A!\\v \\0(\\0(\\xBC"E A\\0Gq! \\0("
 E Er\\r  
j(\\0"A\\x9C\\xCB\\0j! A\\x8C\\xCA\\0j!
A\\0!@ A\\xFF\\xFF\\xFF\\xFFK\\r\\0A At" AM\\x1B\\r"E\\r\\0 (\\0"@ 	\\v  6\\0 
 6\\0A!\\v !\\v \\0(\\v!
 Aj" 
(\\xD4
I\\r\\0\\v \\0(\\0!\\v E\\r\\v 
 6\\x88@ AI\\r\\0 (\\xACE\\r\\0 ((E\\r\\0 Ar! Aq! A\\xFC\\xFF\\xFF\\xFF\\x07q! Au"\\fAj!\\rC\\0\\0\\x80? Ak"\\xB2"=\\x95!IC\\0\\0\\x80? \\xB2"EC\\0\\0\\x80?\\x92">\\x95!J \\fA\\xFC\\xFF\\xFF\\xFF\\x07q"Ar! Aj"\\x1BAu"Aj! Au"Aj"A\\xFC\\xFF\\xFF\\xFF\\x07q! A\\xFC\\xFF\\xFF\\xFF\\x07q"Ar!D\\0\\0\\0\\0\\0\\0 @ \\xB7"3\\xA3"8\\xFD!)D-DT\\xFB!@ \\xB8"4\\xA3\\xFD!&D\\0\\0\\0\\0\\0\\0\\0@ 3\\xA3\\xFD!' 3D\\0\\0\\0\\0\\0\\0\\xE0?\\xA2"5\\xFD!$C\\0\\0\\x80? \\xB3"?\\x95"G G\\x92!HD\\0\\0\\0\\0\\0\\0\\xF0? 3\\xA3"3 3\\xA0!9C\\0\\0\\x80? \\xB3C\\0\\0\\x80?\\x92"@\\x95"F F\\x92!KC\\0\\0\\0@ =\\x95\\xFD!.C\\0\\0\\0@ ?\\x95\\xFD!( G\\xFD!/C\\0\\0\\0@ @\\x95\\xFD!0 F\\xFD!*C\\0\\0\\0@ >\\x95\\xFD!1D\\0\\0\\0\\0\\0\\0\\xF0? 4\\xA3"2D-DT\\xFB!)@\\xA2"4\\xFD!" 2D-DT\\xFB!@\\xA2"3\\xFD!# 2D\\xD2!3\\x7F|\\xD92@\\xA2"6\\xFD!% 2D-DT\\xFB!9@\\xA2";\\xFD!+ 8D\\0\\0\\0\\0\\0\\0\\xE0\\xBF\\xA2"<\\xFD!, \\xFD!- \\fAK!A\\0!
@ \\0( 
Atj(\\x8C!\\x07@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@  
Atj"(,\\0\\x07\\b	
\\v\\f\\r\\v@@ @A\\0! A\\0H\\r#A\\0! AM\\r\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!@ \\x07 Atj ( \\xFD\\xFA\\xFD\\xE6\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v " "G\\r\\f#\\v \\fA\\0L@A\\0!\\f"\\vA\\0! E\\r\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!@ \\x07 Atj . \\xFD\\xFA\\xFD\\xE6\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v \\f" "G\\r\\f!\\v@ \\x07 Atj \\xB3 H\\x948\\0  F Aj!E\\r\\0\\v !\\f!\\v@ \\x07 Atj \\xB3 I I\\x92\\x948\\0 Aj" \\fG\\r\\0\\v \\f!\\f\\v A\\0L\\r A\\0! AO@\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!@ \\x07 Atj / \\xFD\\xFA\\xFD\\xE6"\\xFD_\\xFD\\f-DT\\xFB!@-DT\\xFB!@\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD   "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD_\\xFD\\f-DT\\xFB!@-DT\\xFB!@\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD   \\xFD!\\xB6
\\xFD \\xFD\\f\\\\\\x8F\\xC2\\xBE\\\\\\x8F\\xC2\\xBE\\\\\\x8F\\xC2\\xBE\\\\\\x8F\\xC2\\xBE\\xFD\\xE6 \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE4\\xFD\\xE0\\xFD\\f\\x8F\\xC2\\xF5\\xBE\\x8F\\xC2\\xF5\\xBE\\x8F\\xC2\\xF5\\xBE\\x8F\\xC2\\xF5\\xBE\\xFD\\xE6\\xFD\\fR\\xB8?R\\xB8?R\\xB8?R\\xB8?\\xFD\\xE4\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v " F\\r!\\v@ \\x07 Atj G \\xB3\\x94"=\\xBBD-DT\\xFB!@\\xA2\\xB6
C\\\\\\x8F\\xC2\\xBE\\x94 =C\\0\\0\\0\\xBF\\x92\\x8BC\\x8F\\xC2\\xF5\\xBE\\x94CR\\xB8?\\x92\\x928\\0 Aj" G\\r\\0\\v\\f \\v A\\0L\\rA\\0! AO@\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!@ \\x07 Atj \\xFD\\xFE" "\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD   "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE"  "\\xFD\\xF2"!\\xFD!\\0\\xB6
\\xFD  !\\xFD!\\xB6
\\xFD \\xFD\\f
\\xD7\\xA3=
\\xD7\\xA3=
\\xD7\\xA3=
\\xD7\\xA3=\\xFD\\xE6  #\\xFD\\xF2"\\xFD!\\0\\xB6
\\xFD \\xFD!\\xB6
\\xFD    #\\xFD\\xF2"\\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f=
\\xD7>=
\\xD7>=
\\xD7>=
\\xD7>\\xFD\\xE4\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v " F\\r \\v@ \\x07 Atj \\xB8"2 4\\xA2\\xB6
C
\\xD7\\xA3=\\x94 2 3\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C=
\\xD7>\\x92\\x928\\0 Aj" G\\r\\0\\v\\f\\v A\\0L\\rA\\0! AO@\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!@ \\xFD\\xFE" "\\xFD\\xF2" \\xFD!\\0\\xB6
!=  \\xFD!\\xB6
!>  "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE"  "\\xFD\\xF2"!\\xFD!\\0\\xB6
!? !\\xFD!\\xB6
!@  #\\xFD\\xF2"!\\xFD!\\0\\xB6
!A !\\xFD!\\xB6
!B   #\\xFD\\xF2"!\\xFD!\\0\\xB6
!C !\\xFD!\\xB6
!D \\x07 Atj  %\\xFD\\xF2"\\xFD!\\0\\xB6
\\xFD \\xFD!\\xB6
\\xFD    %\\xFD\\xF2"\\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD \\xFD\\fy]?\\xBCy]?\\xBCy]?\\xBCy]?\\xBC\\xFD\\xE6 =\\xFD >\\xFD  ?\\xFD  @\\xFD \\xFD\\f\\xB4\\xAB>\\xB4\\xAB>\\xB4\\xAB>\\xB4\\xAB>\\xFD\\xE6 A\\xFD B\\xFD  C\\xFD  D\\xFD \\xFD\\f&\\xFA\\xBE&\\xFA\\xBE&\\xFA\\xBE&\\xFA\\xBE\\xFD\\xE6\\xFD\\f\\xAE\\xB7>\\xAE\\xB7>\\xAE\\xB7>\\xAE\\xB7>\\xFD\\xE4\\xFD\\xE4\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v " F\\r\\v@ \\xB8"2 4\\xA2\\xB6
!= 2 3\\xA2\\xB6
!> \\x07 Atj 2 6\\xA2\\xB6
Cy]?\\xBC\\x94 =C\\xB4\\xAB>\\x94 >C&\\xFA\\xBE\\x94C\\xAE\\xB7>\\x92\\x92\\x928\\0 Aj" G\\r\\0\\v\\f\\v A\\0L\\rA\\0! AO@\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!@ \\x07 Atj\\xFD\\f\\0\\0\\0\\0\\0\\0\\xF0?\\0\\0\\0\\0\\0\\0\\xF0? ' \\xFD\\xFE $\\xFD\\xF1\\xFD\\xF2" \\xFD\\xF2\\xFD\\xF1" \\xFD\\xF2"\\xFD!\\0\\xB6\\xFD \\xFD!\\xB6\\xFD \\xFD\\f\\0\\0\\0\\0\\0\\0\\xF0?\\0\\0\\0\\0\\0\\0\\xF0? '  "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE $\\xFD\\xF1\\xFD\\xF2" \\xFD\\xF2\\xFD\\xF1" \\xFD\\xF2"\\xFD!\\0\\xB6\\xFD  \\xFD!\\xB6\\xFD \\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v " F\\r\\v@ \\x07 AtjD\\0\\0\\0\\0\\0\\0\\xF0? \\xB8 5\\xA1 9\\xA2"2 2\\xA2\\xA1"2 2\\xA2\\xB68\\0 Aj" G\\r\\0\\v\\f\\v A\\0L\\rA\\0! AO@\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!@ \\xFD\\xFE" "\\xFD\\xF2" \\xFD!\\0\\xB6
!=  \\xFD!\\xB6
!>  "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE"  "\\xFD\\xF2"!\\xFD!\\0\\xB6
!? !\\xFD!\\xB6
!@  #\\xFD\\xF2"!\\xFD!\\0\\xB6
!A !\\xFD!\\xB6
!B   #\\xFD\\xF2"!\\xFD!\\0\\xB6
!C !\\xFD!\\xB6
!D  %\\xFD\\xF2"!\\xFD!\\0\\xB6
!L !\\xFD!\\xB6
!M   %\\xFD\\xF2"!\\xFD!\\0\\xB6
!N !\\xFD!\\xB6
!O \\x07 Atj  +\\xFD\\xF2"\\xFD!\\0\\xB6
\\xFD \\xFD!\\xB6
\\xFD    +\\xFD\\xF2"\\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD \\xFD\\f\\xBF\\xA6\\xE3;\\xBF\\xA6\\xE3;\\xBF\\xA6\\xE3;\\xBF\\xA6\\xE3;\\xFD\\xE6 L\\xFD M\\xFD  N\\xFD  O\\xFD \\xFD\\fp+\\xAB\\xBDp+\\xAB\\xBDp+\\xAB\\xBDp+\\xAB\\xBD\\xFD\\xE6 =\\xFD >\\xFD  ?\\xFD  @\\xFD \\xFD\\fp\\xF5\\x8D>p\\xF5\\x8D>p\\xF5\\x8D>p\\xF5\\x8D>\\xFD\\xE6 A\\xFD B\\xFD  C\\xFD  D\\xFD \\xFD\\f\\xBCP\\xD5\\xBE\\xBCP\\xD5\\xBE\\xBCP\\xD5\\xBE\\xBCP\\xD5\\xBE\\xFD\\xE6\\xFD\\f\\xBA\\xC0\\\\>\\xBA\\xC0\\\\>\\xBA\\xC0\\\\>\\xBA\\xC0\\\\>\\xFD\\xE4\\xFD\\xE4\\xFD\\xE4\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v " F\\r\\v@ \\xB8"2 4\\xA2\\xB6
!= 2 3\\xA2\\xB6
!> 2 6\\xA2\\xB6
!? \\x07 Atj 2 ;\\xA2\\xB6
C\\xBF\\xA6\\xE3;\\x94 ?Cp+\\xAB\\xBD\\x94 =Cp\\xF5\\x8D>\\x94 >C\\xBCP\\xD5\\xBE\\x94C\\xBA\\xC0\\\\>\\x92\\x92\\x92\\x928\\0 Aj" G\\r\\0\\v\\f\\v *0"=C\\0\\0\\0\\0^ =C\\0\\0\\0?_qE@ A\\0L\\rA\\0! AK@\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!@ \\xFD\\xFE $\\xFD\\xF1" ,\\xFD\\xF2  )\\xFD\\xF2\\xFD\\xF2"\\xFD!!2 \\x07 Atj \\xFD!\\0\\xB6\\xFD 2\\xB6\\xFD   "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE $\\xFD\\xF1" ,\\xFD\\xF2  )\\xFD\\xF2\\xFD\\xF2"\\xFD!\\0\\xB6\\xFD  \\xFD!\\xB6\\xFD \\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v " F\\r\\v@ \\x07 Atj \\xB8 5\\xA1"2 <\\xA2 2 8\\xA2\\xA2\\xB68\\0 Aj" G\\r\\0\\v\\f\\v A\\0L\\r\\x1BD\\0\\0\\0\\0\\0\\0\\xF0? 5 =\\xBB\\xA2\\xA3"2D\\0\\0\\0\\0\\0\\0\\xE0\\xBF\\xA2!:A\\0! AK@ :\\xFD! 2\\xFD! \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!@ \\xFD\\xFE $\\xFD\\xF1"! \\xFD\\xF2 !  \\xFD\\xF2\\xFD\\xF2"!\\xFD!!7 \\x07 Atj !\\xFD!\\0\\xB6\\xFD 7\\xB6\\xFD   "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE $\\xFD\\xF1"! \\xFD\\xF2 !  \\xFD\\xF2\\xFD\\xF2"!\\xFD!\\0\\xB6\\xFD  !\\xFD!\\xB6\\xFD \\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v " F\\r\\v@ \\x07 Atj \\xB8 5\\xA1"7 :\\xA2 7 2\\xA2\\xA2\\xB68\\0 Aj" G\\r\\0\\v\\f\\x1B\\v A\\0L\\rA\\0! AO@\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!@ \\x07 Atj & \\xFD\\xFE\\xFD\\xF2"\\xFD!\\0\\xB6
\\xFD \\xFD!\\xB6
\\xFD  &  "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE\\xFD\\xF2"\\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD \\xFD\\f\\x85\\xEB\\xBE\\x85\\xEB\\xBE\\x85\\xEB\\xBE\\x85\\xEB\\xBE\\xFD\\xE6\\xFD\\fq=
?q=
?q=
?q=
?\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v " F\\r\\x1B\\v@ \\x07 Atj \\xB8 3\\xA2\\xB6
C\\x85\\xEB\\xBE\\x94Cq=
?\\x928\\0 Aj" G\\r\\0\\v\\f\\v A\\0L\\rA\\0! AO@\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!@ \\x07 Atj & \\xFD\\xFE\\xFD\\xF2"\\xFD!\\0\\xB6
\\xFD \\xFD!\\xB6
\\xFD  &  "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE\\xFD\\xF2"\\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v " F\\r\\v@ \\x07 Atj \\xB8 3\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0 Aj" G\\r\\0\\v\\f\\v A\\0L\\rA\\0! AO@\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!@ \\xFD\\xFE" "\\xFD\\xF2" \\xFD!\\0\\xB6
!=  \\xFD!\\xB6
!>  "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE"  "\\xFD\\xF2"!\\xFD!\\0\\xB6
!? !\\xFD!\\xB6
!@  #\\xFD\\xF2"!\\xFD!\\0\\xB6
!A !\\xFD!\\xB6
!B   #\\xFD\\xF2"!\\xFD!\\0\\xB6
!C !\\xFD!\\xB6
!D \\x07 Atj  %\\xFD\\xF2"\\xFD!\\0\\xB6
\\xFD \\xFD!\\xB6
\\xFD    %\\xFD\\xF2"\\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD \\xFD\\fo\\x83\\xBAo\\x83\\xBAo\\x83\\xBAo\\x83\\xBA\\xFD\\xE6 =\\xFD >\\xFD  ?\\xFD  @\\xFD \\xFD\\f9\\xB4\\xC8=9\\xB4\\xC8=9\\xB4\\xC8=9\\xB4\\xC8=\\xFD\\xE6 A\\xFD B\\xFD  C\\xFD  D\\xFD \\xFD\\f\\xDB\\xF9\\xFE\\xBE\\xDB\\xF9\\xFE\\xBE\\xDB\\xF9\\xFE\\xBE\\xDB\\xF9\\xFE\\xBE\\xFD\\xE6\\xFD\\f\\xF2\\xD2\\xCD>\\xF2\\xD2\\xCD>\\xF2\\xD2\\xCD>\\xF2\\xD2\\xCD>\\xFD\\xE4\\xFD\\xE4\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v " F\\r\\v@ \\xB8"2 4\\xA2\\xB6
!= 2 3\\xA2\\xB6
!> \\x07 Atj 2 6\\xA2\\xB6
Co\\x83\\xBA\\x94 =C9\\xB4\\xC8=\\x94 >C\\xDB\\xF9\\xFE\\xBE\\x94C\\xF2\\xD2\\xCD>\\x92\\x92\\x928\\0 Aj" G\\r\\0\\v\\f\\v A\\0L\\rA\\0! AO@\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!@ \\xFD\\xFE" "\\xFD\\xF2" \\xFD!\\0\\xB6
!=  \\xFD!\\xB6
!>  "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE"  "\\xFD\\xF2"!\\xFD!\\0\\xB6
!? !\\xFD!\\xB6
!@  #\\xFD\\xF2"!\\xFD!\\0\\xB6
!A !\\xFD!\\xB6
!B   #\\xFD\\xF2"!\\xFD!\\0\\xB6
!C !\\xFD!\\xB6
!D \\x07 Atj  %\\xFD\\xF2"\\xFD!\\0\\xB6
\\xFD \\xFD!\\xB6
\\xFD    %\\xFD\\xF2"\\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD \\xFD\\fX.\\xBCX.\\xBCX.\\xBCX.\\xBC\\xFD\\xE6 =\\xFD >\\xFD  ?\\xFD  @\\xFD \\xFD\\f\\xBD\\xE0\\v>\\xBD\\xE0\\v>\\xBD\\xE0\\v>\\xBD\\xE0\\v>\\xFD\\xE6 A\\xFD B\\xFD  C\\xFD  D\\xFD \\xFD\\fyu\\xFA\\xBEyu\\xFA\\xBEyu\\xFA\\xBEyu\\xFA\\xBE\\xFD\\xE6\\xFD\\fh'\\xBA>h'\\xBA>h'\\xBA>h'\\xBA>\\xFD\\xE4\\xFD\\xE4\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v " F\\r\\v@ \\xB8"2 4\\xA2\\xB6
!= 2 3\\xA2\\xB6
!> \\x07 Atj 2 6\\xA2\\xB6
CX.\\xBC\\x94 =C\\xBD\\xE0\\v>\\x94 >Cyu\\xFA\\xBE\\x94Ch'\\xBA>\\x92\\x92\\x928\\0 Aj" G\\r\\0\\v\\f\\v A\\0L\\rA\\0! AO@@ \\x07 Atj\\xFD\\f\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\xFD\\v\\0 Aj" G\\r\\0\\v " F\\r\\v@ \\x07 AtjA\\x80\\x80\\x80\\xFC6\\0 Aj" G\\r\\0\\v\\f\\v@@ @A! A\\0L\\rA! AM\\r\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!A\\0!@ \\x07 Atj 1 \\xFD\\xFA\\xFD\\xE6\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v ! !  G\\r\\f\\vA! \\fA\\0L\\rA! E\\r\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!A\\0!@ \\x07 Atj 0 \\xFD\\xFA\\xFD\\xE6\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v ! \\r! \\f G\\r\\f\\v@ \\x07 AtjAk \\xB3 J J\\x92\\x948\\0  F Aj!E\\r\\0\\v !\\f\\v@ \\x07 AtjAk \\xB3 K\\x948\\0  \\fF Aj!E\\r\\0\\v \\r!\\f\\v \\x07  *0L\\f\\v *8 E\\x94\\xFC\\0"\\b *4 E\\x94\\xFC\\0"k! *0"=C\\0\\0\\0\\0_@ \\xB2C\\xCD\\xCC\\xCC<\\x94\\xFC\\0!@    J\\x1B"A\\0L@A\\0!\\f\\v At"E\\r\\0 \\x07A\\0 \\xFC\\v\\0\\v  j"   J\\x1B" L\\r \\xB7!2  k"	AM@A!\\f\\v 	A|q! \\x07 Atj!\\vD-DT\\xFB!	@ 2\\xA3\\xFD!\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!A\\0!@ \\v Atj  \\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD    "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD   \\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v  j!  	F\\r Ar!\\f\\r\\v =C\\0\\0\\x80?\\\`@ \\xB2C33\\xF3>\\x94\\xFC\\0!@    J\\x1B"A\\0L@A\\0!\\f\\v At"E\\r\\0 \\x07A\\0 \\xFC\\v\\0\\v  j"   J\\x1B" L\\r\\f \\xB7!2  k"	AM@A!\\f\\f\\v 	A|q! \\x07 Atj!\\vD-DT\\xFB!	@ 2\\xA3\\xFD!\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!A\\0!@ \\v Atj  \\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD    "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD   \\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v  j!  	F\\r\\f Ar!\\f\\v\\v =C\\0\\0\\x80?] =C\\0\\0\\0\\0^qE@ \\xB2C\\0\\0\\x80>\\x94\\xFC\\0!@    J\\x1B"A\\0L@A\\0!\\f\\v At"E\\r\\0 \\x07A\\0 \\xFC\\v\\0\\v  j"   J\\x1B" L\\r
 \\xB7!2  k"	AM@A!\\f
\\v 	A|q! \\x07 Atj!\\vD-DT\\xFB!	@ 2\\xA3\\xFD!\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!A\\0!@ \\v Atj  \\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD    "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD   \\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v  j!  	F\\r
 Ar!\\f	\\v =C\\0\\0\\0?\\x94 \\xB2\\x94\\xFC\\0!@    J\\x1B"A\\0L@A\\0!\\f\\v At"E\\r\\0 \\x07A\\0 \\xFC\\v\\0\\v  j"   J\\x1B" L\\r\\x07 \\xB7!2  k"	AM@A!\\f\\x07\\v 	A|q! \\x07 Atj!\\vD-DT\\xFB!	@ 2\\xA3\\xFD!\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!A\\0!@ \\v Atj  \\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD    "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD   \\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v  j!  	F\\r\\x07 Ar!\\f\\v *8!? *4 *0!>@ >!=C\\xCD\\xCCL=!> =C\\0\\0\\0\\0_\\r\\0C33s?!> =C\\0\\0\\x80?\\\`\\r\\0C\\0\\0\\0?!> =C\\0\\0\\0\\0^E =C\\0\\0\\x80?]Er\\r\\0\\v  ? E\\x94\\xFC\\0"	k! E\\x94">\\xFC\\0!\\b =C\\0\\0\\0?\\x94"= >\\x8F\\x94\\xFC\\0"   J\\x1B"A\\0L@A\\0!\\f\\v \\xB7!2 AM@A\\0!A!\\f\\v A\\xFC\\xFF\\xFF\\xFF\\x07q!D-DT\\xFB!	@ 2\\xA3\\xFD!\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!A\\0!@ \\x07 Atj  \\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD    "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD   \\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v  F\\r Ar!\\f\\v \\x07  *0L\\f\\v A\\0L\\rA\\0! AO@\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!@ \\x07 Atj\\xFD\\f\\0\\0\\0\\0\\0\\0\\xF0?\\0\\0\\0\\0\\0\\0\\xF0? ' \\xFD\\xFE $\\xFD\\xF1\\xFD\\xF2" \\xFD\\xF2\\xFD\\xF1"\\xFD!\\0\\xB6\\xFD \\xFD!\\xB6\\xFD \\xFD\\f\\0\\0\\0\\0\\0\\0\\xF0?\\0\\0\\0\\0\\0\\0\\xF0? '  "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE $\\xFD\\xF1\\xFD\\xF2" \\xFD\\xF2\\xFD\\xF1"\\xFD!\\0\\xB6\\xFD  \\xFD!\\xB6\\xFD \\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v " F\\r\\v@ \\x07 AtjD\\0\\0\\0\\0\\0\\0\\xF0? \\xB8 5\\xA1 9\\xA2"2 2\\xA2\\xA1\\xB68\\0 Aj" G\\r\\0\\v\\f\\v A\\0L\\rA\\0! AO@\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!@ \\x07 Atj & \\xFD\\xFE\\xFD\\xF2"\\xFD!\\0\\xB6
\\xFD \\xFD!\\xB6
\\xFD  &  "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE\\xFD\\xF2"\\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v " F\\r\\v@ \\x07 Atj \\xB8 3\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0 Aj" G\\r\\0\\v\\f\\vD\\0\\0\\0\\0\\0\\0\\xF0? 2\\xA3!2@ \\x07 Atj \\xB8D-DT\\xFB!	@\\xA2 2\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0 Aj! Aj" G\\r\\0\\v\\v  \\b k"   J\\x1B"H@@  k"AK@ A|q!\\v \\x07 Atj!A\\0!@  Atj\\xFD\\f\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\xFD\\v\\0 Aj" \\vG\\r\\0\\v \\v F\\r  \\vj!\\v@ \\x07 AtjA\\x80\\x80\\x80\\xFC6\\0 Aj" G\\r\\0\\v\\v !\\v  \\b   \\bJ\\x1B"H@ \\xB7!2@  k"\\vAK@ \\vA|q!\\b \\x07 Atj! \\xFD\\xFD\\f\\0\\0\\0\\0\\xFF\\xFF\\xFF\\xFF\\xFE\\xFF\\xFF\\xFF\\xFD\\xFF\\xFF\\xFF\\xFD\\xAE!D-DT\\xFB!	@ 2\\xA3\\xFD!A\\0!@  Atj  \\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD    "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD   \\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFD\\xAE! Aj" \\bG\\r\\0\\v \\b \\vF\\r  \\bk!  \\bj!\\vD\\0\\0\\0\\0\\0\\0\\xF0? 2\\xA3!2@ \\x07 Atj \\xB7D-DT\\xFB!	@\\xA2 2\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0 Ak! Aj" G\\r\\0\\v\\v !\\v = \\xB2\\x94\\xFC\\0!@  	   	J\\x1B"N@ !\\f\\v  kAt"E\\r\\0 \\x07 AtjA\\0 \\xFC\\v\\0\\v@  	j"   J\\x1B" L\\r\\0 \\xB7!2  k"\\bAM\\x7FA \\bA|q! \\x07 Atj!	D-DT\\xFB!	@ 2\\xA3\\xFD!\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!A\\0!@ 	 Atj  \\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD    "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD   \\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v  j!  \\bF\\r Ar\\v! \\bAj!D\\0\\0\\0\\0\\0\\0\\xF0? 2\\xA3!2@ \\x07 Atj \\xB8D-DT\\xFB!	@\\xA2 2\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0 Aj! Aj" G\\r\\0\\v\\v   k"   J\\x1B"H@@  k"	AK@ 	A|q!\\b \\x07 Atj!\\vA\\0!@ \\v Atj\\xFD\\f\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\xFD\\v\\0 Aj" \\bG\\r\\0\\v \\b 	F\\r  \\bj!\\v@ \\x07 AtjA\\x80\\x80\\x80\\xFC6\\0 Aj" G\\r\\0\\v\\v !\\v  L\\r\\r \\xB7!2  k"\\bAK@ \\bA|q! \\x07 Atj!	 \\xFD\\xFD\\f\\0\\0\\0\\0\\xFF\\xFF\\xFF\\xFF\\xFE\\xFF\\xFF\\xFF\\xFD\\xFF\\xFF\\xFF\\xFD\\xAE!D-DT\\xFB!	@ 2\\xA3\\xFD!A\\0!@ 	 Atj  \\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD    "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD   \\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFD\\xAE! Aj" G\\r\\0\\v  \\bF\\r  k!  j!\\vD\\0\\0\\0\\0\\0\\0\\xF0? 2\\xA3!2@ \\x07 Atj \\xB7D-DT\\xFB!	@\\xA2 2\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0 Ak! Aj" G\\r\\0\\v\\f\\r\\v 	Aj!D\\0\\0\\0\\0\\0\\0\\xF0? 2\\xA3!2@ \\x07 Atj \\xB8D-DT\\xFB!	@\\xA2 2\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0 Aj! Aj" G\\r\\0\\v\\v  \\b k"   J\\x1B"H@@  k"\\vAK@ \\vA|q!	 \\x07 Atj!A\\0!@  Atj\\xFD\\f\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\xFD\\v\\0 Aj" 	G\\r\\0\\v 	 \\vF\\r  	j!\\v@ \\x07 AtjA\\x80\\x80\\x80\\xFC6\\0 Aj" G\\r\\0\\v\\v !\\v  \\b   \\bJ\\x1B"H@ \\xB7!2@  k"	AK@ 	A|q!\\b \\x07 Atj!\\v \\xFD\\xFD\\f\\0\\0\\0\\0\\xFF\\xFF\\xFF\\xFF\\xFE\\xFF\\xFF\\xFF\\xFD\\xFF\\xFF\\xFF\\xFD\\xAE!D-DT\\xFB!	@ 2\\xA3\\xFD!A\\0!@ \\v Atj  \\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD    "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD   \\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFD\\xAE! Aj" \\bG\\r\\0\\v \\b 	F\\r  \\bk!  \\bj!\\vD\\0\\0\\0\\0\\0\\0\\xF0? 2\\xA3!2@ \\x07 Atj \\xB7D-DT\\xFB!	@\\xA2 2\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0 Ak! Aj" G\\r\\0\\v\\v !\\v  J\\r\\f\\v\\v 	Aj!D\\0\\0\\0\\0\\0\\0\\xF0? 2\\xA3!2@ \\x07 Atj \\xB8D-DT\\xFB!	@\\xA2 2\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0 Aj! Aj" G\\r\\0\\v\\v  \\b k"   J\\x1B"H@@  k"\\vAK@ \\vA|q!	 \\x07 Atj!A\\0!@  Atj\\xFD\\f\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\xFD\\v\\0 Aj" 	G\\r\\0\\v 	 \\vF\\r  	j!\\v@ \\x07 AtjA\\x80\\x80\\x80\\xFC6\\0 Aj" G\\r\\0\\v\\v !\\v  \\b   \\bJ\\x1B"H@ \\xB7!2@  k"	AK@ 	A|q!\\b \\x07 Atj!\\v \\xFD\\xFD\\f\\0\\0\\0\\0\\xFF\\xFF\\xFF\\xFF\\xFE\\xFF\\xFF\\xFF\\xFD\\xFF\\xFF\\xFF\\xFD\\xAE!D-DT\\xFB!	@ 2\\xA3\\xFD!A\\0!@ \\v Atj  \\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD    "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD   \\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFD\\xAE! Aj" \\bG\\r\\0\\v \\b 	F\\r  \\bk!  \\bj!\\vD\\0\\0\\0\\0\\0\\0\\xF0? 2\\xA3!2@ \\x07 Atj \\xB7D-DT\\xFB!	@\\xA2 2\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0 Ak! Aj" G\\r\\0\\v\\v !\\v  J\\r\\f	\\v 	Aj!D\\0\\0\\0\\0\\0\\0\\xF0? 2\\xA3!2@ \\x07 Atj \\xB8D-DT\\xFB!	@\\xA2 2\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0 Aj! Aj" G\\r\\0\\v\\v  \\b k"   J\\x1B"H@@  k"\\vAK@ \\vA|q!	 \\x07 Atj!A\\0!@  Atj\\xFD\\f\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\xFD\\v\\0 Aj" 	G\\r\\0\\v 	 \\vF\\r  	j!\\v@ \\x07 AtjA\\x80\\x80\\x80\\xFC6\\0 Aj" G\\r\\0\\v\\v !\\v  \\b   \\bJ\\x1B"H@ \\xB7!2@  k"	AK@ 	A|q!\\b \\x07 Atj!\\v \\xFD\\xFD\\f\\0\\0\\0\\0\\xFF\\xFF\\xFF\\xFF\\xFE\\xFF\\xFF\\xFF\\xFD\\xFF\\xFF\\xFF\\xFD\\xAE!D-DT\\xFB!	@ 2\\xA3\\xFD!A\\0!@ \\v Atj  \\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD    "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD   \\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFD\\xAE! Aj" \\bG\\r\\0\\v \\b 	F\\r  \\bk!  \\bj!\\vD\\0\\0\\0\\0\\0\\0\\xF0? 2\\xA3!2@ \\x07 Atj \\xB7D-DT\\xFB!	@\\xA2 2\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0 Ak! Aj" G\\r\\0\\v\\v !\\v  J\\r\\f\\x07\\v 	Aj!D\\0\\0\\0\\0\\0\\0\\xF0? 2\\xA3!2@ \\x07 Atj \\xB8D-DT\\xFB!	@\\xA2 2\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0 Aj! Aj" G\\r\\0\\v\\v  \\b k"   J\\x1B"H@@  k"\\vAK@ \\vA|q!	 \\x07 Atj!A\\0!@  Atj\\xFD\\f\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\0\\0\\x80?\\xFD\\v\\0 Aj" 	G\\r\\0\\v 	 \\vF\\r  	j!\\v@ \\x07 AtjA\\x80\\x80\\x80\\xFC6\\0 Aj" G\\r\\0\\v\\v !\\v  \\b   \\bJ\\x1B"H@ \\xB7!2@  k"	AK@ 	A|q!\\b \\x07 Atj!\\v \\xFD\\xFD\\f\\0\\0\\0\\0\\xFF\\xFF\\xFF\\xFF\\xFE\\xFF\\xFF\\xFF\\xFD\\xFF\\xFF\\xFF\\xFD\\xAE!D-DT\\xFB!	@ 2\\xA3\\xFD!A\\0!@ \\v Atj  \\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD  \\xFD!\\xB6
\\xFD    "\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xFE\\xFD\\xF2" \\xFD!\\0\\xB6
\\xFD   \\xFD!\\xB6
\\xFD \\xFD\\f\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\0\\0\\0\\xBF\\xFD\\xE6\\xFD\\f\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\0\\0\\0?\\xFD\\xE4\\xFD\\v\\0 \\xFD\\f\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFC\\xFF\\xFF\\xFF\\xFD\\xAE! Aj" \\bG\\r\\0\\v \\b 	F\\r  \\bk!  \\bj!\\vD\\0\\0\\0\\0\\0\\0\\xF0? 2\\xA3!2@ \\x07 Atj \\xB7D-DT\\xFB!	@\\xA2 2\\xA2\\xB6
C\\0\\0\\0\\xBF\\x94C\\0\\0\\0?\\x928\\0 Ak! Aj" G\\r\\0\\v\\v !\\v  L\\r\\v  kAt"E\\r \\x07 AtjA\\0 \\xFC\\v\\0\\f\\v  H\\r  k"AK@ A|q! \\x07 Atj!\\b \\xFD\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE!A\\0!@ \\b AtjAk * - \\xFD\\xB1A\\xFD\\xAB\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE\\xFD\\xFA\\xFD\\xE6\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v  F\\r  j!\\v@ \\x07 AtjAk F  kAtAj\\xB2\\x948\\0  F Aj!E\\r\\0\\v\\f\\v  H\\r \\x1B k"AK@ A|q! \\x07 Atj!\\b \\xFD\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE!A\\0!@ \\b AtjAk * - \\xFD\\xB1A\\xFD\\xAB\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE\\xFD\\xFA\\xFD\\xE6\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v  F\\r  j!\\v@ \\x07 AtjAk F  kAtAj\\xB2\\x948\\0  F Aj!E\\r\\0\\v\\f\\v  L\\r  k"AK@ A|q! \\x07 Atj!\\b \\xFD\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE!A\\0!@ \\b Atj\\xFD\\f\\0\\0\\0@\\0\\0\\0@\\0\\0\\0@\\0\\0\\0@ ( \\xFD\\xFA\\xFD\\xE6\\xFD\\xE5\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v  F\\r  j!\\v@ \\x07 AtjC\\0\\0\\0@ \\xB3 H\\x94\\x938\\0 Aj" G\\r\\0\\v\\f\\v  L\\r\\0  k"AK@ A|q! \\x07 Atj!\\b \\xFD\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE!A\\0!@ \\b Atj\\xFD\\f\\0\\0\\0@\\0\\0\\0@\\0\\0\\0@\\0\\0\\0@ ( \\xFD\\xFA\\xFD\\xE6\\xFD\\xE5\\xFD\\v\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xAE! Aj" G\\r\\0\\v  F\\r  j!\\v@ \\x07 AtjC\\0\\0\\0@ \\xB3 H\\x94\\x938\\0 Aj" G\\r\\0\\v\\v 
Aj"
 \\0(\\0"((I\\r\\0\\v\\v A M@ \\0(A\\x076\\xF8\\b\\vA\\v A\\b6\\0A\\0\\v\\x91\\x07\\x7F~\\x7F@A\\x88\\xD6\\0(\\0"\\xAD \\0A\\x07jAxq"\\xADB\\x07|B\\xF8\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\0\\x83|"\\bB\\xFF\\xFF\\xFF\\xFFX@ \\b\\xA7"\\0?\\0AtM\\r \\0\\r\\vA\\xD0\\xD8\\0A06\\0A\\x7F\\f\\vA\\x88\\xD6\\0 \\x006\\0 \\v"A\\x7FG@  j"\\0AkA6\\0 \\0Ak"A6\\0@\\x7FA\\xE0\\xE0\\0(\\0"\\x7F (\\bA\\0\\v F@  Ak(\\0A~q"k"Ak(\\0!\\x07  \\x006\\b  \\x07A~q"k"\\0 \\0(\\0jAk-\\0\\0Aq@ \\0(" \\0(\\b"6\\b  6 \\0  j jAk"6\\0\\f\\v Ak\\f\\v A6\\0  \\x006\\b  6 A6\\fA\\xE0\\xE0\\0 6\\0 Aj\\v"\\0  \\0k"6\\0\\v \\0 A|qjAk Ar6\\0 \\0\\x7F \\0(\\0A\\bk"A\\xFF\\0M@ AvAk\\f\\v A g"kvAs AtkA\\xEE\\0j A\\xFFM\\r\\0A? A kvAs AtkA\\xC7\\0j" A?O\\x1B\\v"At"A\\xE0\\xD8\\0j6 \\0 A\\xE8\\xD8\\0j"(\\x006\\b  \\x006\\0 \\0(\\b \\x006A\\xE8\\xE0\\0A\\xE8\\xE0\\0)\\0B \\xAD\\x86\\x847\\0\\v A\\x7FG\\v\\xCC!\\x7F\\x07{~#\\0A0k"
$\\0 \\0(\\0!\\b\\x7F@@ E@ \\b(\\xE4AK\\r\\v@ \\b(\\fE\\r\\0 \\0("A\\xCC\\x07j (\\0 \\b( \\b($ \\b(A\\x07jAvK \\0(\\0!\\b\\r\\0 \\bA\\b6\\0A\\0\\f\\v \\0("(\\0" (\\xC8\\x07"6\\x94J \\b(\\xC0!\\x07  (\\xA4	6\\xB8k \\b($"\\vAqE@A\\0! \\v!@ Aj! Aq Av!E\\r\\0\\vA  AO\\x1B!\\v \\b(\\xC4! 
 \\v6\\0 
 \\b( 6 \\b(! 
A\\x006\\f 
 6\\b \\b(! 
 6 
A\\x006 
 6 \\x07    K\\x1B" \\x07 I\\x1B!@@@\\x7F@@@\\x7F@@@\\x7F@@@\\x7F@\\x7F\\x7FA\\0 \\b(E\\r\\0@ \\b("E@\\f\\v@@@ AO@ \\vAI\\r ("	(\\0! (\\0"\\f(\\0! \\vAF@A!\\f\\v \\vAk"\\x07A~q! \\xFD! \\xFD!A\\0!@ ! ! \\f AtAr"j\\xFD]\\0"  \\xFD\\r\\x07\\0\\0"\\xFD\\xB8  \\xFD\\xB6\\xFD\\xB1\\xFD\\xC9 \\xFD\\xCE  	j\\xFD]\\0"  \\xFD\\r\\x07\\0\\0"\\xFD\\xB8  \\xFD\\xB6\\xFD\\xB1\\xFD\\xC9\\xFD\\xCE! \\xFD\\xC7 \\xFD\\xC7\\xFD\\xD1" \\xFD\\xC7 \\xFD\\xC7\\xFD\\xD1"\\xFD\\xD1\\xFD\\xC0 \\x1B\\xFD\\xCE  \\xFDN  \\xFDQA\\xFD\\xCC\\xFD\\xCE\\xFD\\xC0\\xFD\\xCE!\\x1B Aj" G\\r\\0\\v   \\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE \\x1B \\x1B \\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\r\\0\\x07!  \\x07F\\r \\x07Ar! \\xFD\\x1B! \\xFD\\x1B!\\f\\v \\vAI\\r\\0 ("\\r(\\0! (\\0"	(\\0!\\x7F \\vAF@A\\f\\v \\vAk"\\x07A~q! \\xFD! \\xFD!A\\0!@ \\x1B \\r AtAr"j\\xFD]\\0"  \\xFD\\r\\x07\\0\\0\\xFD\\xB1"  	j\\xFD]\\0"  \\xFD\\r\\x07\\0\\0\\xFD\\xB1"\\xFD\\xAEA\\xFD\\xAC\\xFD\\xA0  \\xFD\\xB1\\xFD\\xA0\\xFD\\xAE\\xFD\\xC9\\xFD\\xCE!\\x1B  \\xFD\\xA0 \\xFD\\xA0\\xFD\\xAE\\xFD\\xC9\\xFD\\xCE! ! ! Aj" G\\r\\0\\v   \\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE \\x1B \\x1B \\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\r\\0\\x07!  \\x07F\\r \\xFD\\x1B! \\xFD\\x1B! \\x07Ar\\v!@  \\r At"j(\\0"\\x07 k"\\f\\xFD \\f  	j(\\0" k"jAu\\xFD\\xFD\\xA0 \\xFD  \\fk\\xFD\\xFD\\xA0\\xFD\\xAE\\xFD\\xC9\\xFD\\xCE! \\x07! ! Aj" \\vG\\r\\0\\v\\f\\vA! 
A6\\f\\f\\v@ \\f At"j(\\0"\\x07\\xAC \\xAC}"\\xFD   	j(\\0"\\xAC \\xAC}"}\\xFD\\xFD\\xC0 \\xFD\\xCE \\xFD  |B\\x87\\xFD\\xFD\\xC0\\xFD\\xCE! ! \\x07! Aj" \\vG\\r\\0\\v\\v 
A\\0A \\xFD\\0 \\xFDT"\\x1B"6\\fA\\0 \\r\\v@ A O@ ( !\\f ((!\\x07 (! (\\0!A\\0!@ \\x07 Atj  At"\\rj(\\0"	\\xAC  \\rj(\\0"\\xAC}7\\0 \\f \\rj  	q  	sAuj6\\0 Aj" \\b($"M\\r\\0\\v\\f\\v \\vE@A\\0!\\f\\v ( !	 ($!\\f (! (\\0!\\x07A\\0!@ \\f At"\\rj \\x07 \\rj"(\\0  \\rj"(\\0k6\\0 	 \\rj (\\0 (\\0jAu6\\0 Aj" \\b($"I\\r\\0\\v\\vA\\0 \\r \\b(!A\\vA\\0!A\\0! @ A0j!	 A\\xA8j!\\fA\\0!\\x07@ \\x07At!A\\0!@ \\b($"E\\r\\0  j(\\0!\\rA\\0!A\\0!@@ \\r Atj(\\0 r"Aq! Aj" O\\r\\0 E\\r\\v\\v E\\r\\0A\\0! \\r\\0@ Aj! Aq Au!E\\r\\0\\v E\\r\\0A\\0!@ AO@ A|q!A\\0!@ \\r Atj" \\xFD\\0\\0 \\xFD\\xAC\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\v@ \\r Atj" (\\0 u6\\0 Aj" G\\r\\0\\v\\v !\\v \\f \\x07A\\xE0lj"  \\b("  I\\x1B"6\\xA8  6\\xD8 	 j  k6\\0 \\x07Aj"\\x07 \\b("I\\r\\0\\v\\vE\\r \\b($!A\\v!\\fA\\0!@ E@A\\0!\\f\\v ( !	A\\0!@@ 	 Atj(\\0 r"Aq!\\x07 Aj" O\\r\\0 \\x07E\\r\\v\\vA\\0! E \\x07r\\r\\0A\\0!@ Aj! Aq Au!E\\r\\0\\v E\\r\\0A\\0!@ AO@ A|q!A\\0!\\x07@ 	 \\x07Atj" \\xFD\\0\\0 \\xFD\\xAC\\xFD\\v\\0 \\x07Aj"\\x07 G\\r\\0\\v  F\\r\\v@ 	 Atj" (\\0 u6\\0 Aj" G\\r\\0\\v\\v !\\v   \\b("  I\\x1B"6\\xD0:  6\\x80>   k6P \\b($!	@ \\b(A O@ 	E@A!\\x07\\f\\v ($! ((!A\\0!B\\0!@@  Atj)\\0 \\x84"B\\x83! Aj" 	O\\r\\0 P\\r\\v\\vA! PE@A\\0!\\x07 \\xA7\\rA\\0!@ Aj! B\\x83 B\\x87!P\\r\\0\\v E\\r\\v \\xAD!A\\0!@ 	AF\\r\\0 	A~q!A\\0!\\x07@  \\x07Atj  \\x07Atj\\xFD\\0\\0 \\xA7\\xFD\\xCC \\xFD\\r\\0\\b	
\\v\\0\\0\\xFD[\\0\\0 \\x07Aj"\\x07 G\\r\\0\\v  	G\\r\\0 !\\x07\\f\\v@  Atj  Atj)\\0 \\x87>\\0 Aj" 	G\\r\\0\\v !\\x07\\f\\vA\\0! 	E@A\\0!\\x07\\f\\v ($!A\\0!@@  Atj(\\0 r"Aq! Aj" 	O\\r\\0 E\\r\\v\\vA\\0!\\x07 E r\\r\\0A\\0!@ Aj! Aq Au!E\\r\\0\\v E\\r\\0A\\0!@ 	AO@ 	A|q!@  \\x07Atj" \\xFD\\0\\0 \\xFD\\xAC\\xFD\\v\\0 \\x07Aj"\\x07 G\\r\\0\\v  	F\\r\\v@  Atj" (\\0 u6\\0 Aj" 	G\\r\\0\\v\\v !\\x07\\v  \\x07 \\b("  \\x07K\\x1B"6\\xB0A  6\\xE0DA!   kAj6TA\\0 \\fE\\r \\b(!\\v @ A\\xA8j! A\\xE0\\xC9\\0j!\\r A\\xB8\\xC9\\0j! A\\xD8\\0j!	 A\\xB8\\xC8\\0j!\\f A\\xE8\\xC4\\0j! A0j!\\x07A\\0!A!@@  "Aj"G\\r\\0 \\b(\\xD8E Er\\r\\0 A6\\xB8k\\v \\0    \\v \\x07 At"j(\\0  j(\\0  At"j  \\fj  	j  j" \\r j7A\\0   A\\xE0lj (\\0A\\xB0lj(\\0\\x1B!  \\0(\\0"\\b("I\\r\\0\\v\\v E\\rA\\v \\0    \\v (P" A A( A!I\\x1Bj(\\0 A\\xA8\\xC5\\0j A\\xF8\\xC8\\0j A\\x98j A\\xD8\\xC9\\0j A\\x80\\xCA\\0j7 \\0    \\v (T" A$A( A!I\\x1Bj(\\0 A\\xB0\\xC5\\0j A\\x80\\xC9\\0j A\\xA0j A\\xDC\\xC9\\0j A\\x84\\xCA\\0j7 \\0(\\0!\\b\\r\\v \\b(\\r 
 (\\x90JJ! \\0(\\0" E\\r (E\\r\\x07 A\\xB8\\xC9\\0j!\\x07 A\\xA8j! A0j!A\\0!\\f\\v \\b(\\r\\0 
AA (\\x84J" (\\xE0I"j"\\x07 (\\xE4I" j"I"  j" \\x07  \\x1B"I"\\x1B (\\x80J j   \\x1BI\\x1B"6\\f\\v 
 (\\x90JJ\\r \\0(\\0\\vA\\x076\\0A\\0\\f\\r\\v\\x7F@@@@ Ak\\0\\v  (\\xB8IA\\xB0ljA\\xA8j!A4!A0!\\f\\v  (\\xB8IA\\xB0ljA\\xA8j!A0!A\\xD4\\0\\f\\v  (\\xDCIA\\xB0ljA\\x88>j!A4!A\\xD4\\0!\\f\\v  (\\xD8IA\\xB0ljA\\xA87j!A\\xD0\\0!A\\xD4\\0\\v!A\\x88>!A\\xDC\\xC9\\0\\f\\v@ \\0 \\v  At"j(\\0  A\\xE0lj  \\x07j(\\0A\\xB0lj (\\x90J6E\\r Aj" \\0(\\0(I\\r\\0\\v\\f\\vA\\x88\\b!A\\xBC\\xC9\\0\\v!\\x07  j(\\0!  \\x07j(\\0! \\0 \\v  j(\\0  (\\x90J6E\\r \\0 \\v   j A\\xB0lj (\\x90J6E\\r\\v \\0((\\0(\\x90J"(A\\x07q"\\x7F A\\b kE\\r\\b \\0((\\0(\\x90J \\v 
 
A,j5E\\rA\\0! 
(\\0! 
(,"A\\x07K@@ -\\0\\x07At/\\x90 -\\0At/\\x90! -\\0At/\\x90% -\\0At/\\x90) -\\0At/\\x90- -\\0At/\\x901  /\\0\\0"A\\bt A\\bvrs"A\\xFFqAtA\\x905j/\\0 A\\x07vA\\xFEq/\\x909sssssss! A\\bj! A\\bk"A\\x07K\\r\\0\\v\\v E\\r Aq\\r \\f\\vA\\0\\f\\x07\\v -\\0\\0 A\\x80\\xFEqA\\bvsAt/\\x90 A\\bts! Aj! Ak\\v!\\x07 AF\\r\\0@ -\\0 -\\0\\0 A\\x80\\xFEqA\\bvsAt/\\x90" A\\btsA\\x80\\xFEqA\\bvsAt/\\x90 A\\bts! Aj! \\x07Ak"\\x07\\r\\0\\v\\v \\0((\\0(\\x90J A\\xFF\\xFFqA\\v\\r\\v \\0(\\0A\\b6\\0A\\0\\f\\vA\\0 \\0 \\0((\\0 \\0(\\0($ )E\\r \\0(\\0!\\b\\v \\0("\\0A\\x006\\xC4\\x07 \\0 \\0(\\xC8\\x07Aj6\\xC8\\x07 \\0 \\0)\\xC0 \\b5$|7\\xC0A\\f\\v \\0(\\0A\\b6\\0A\\0\\v 
A0j$\\0\\v\\xA6\\b\\x7FA! \\0(\\0(\\0A	G@ \\0("A\\x8C%j" (\\xDC%A?q"j"A\\x80:\\0\\0 Aj! A8I\\x7FA7 k A?s"@ A\\0 \\xFC\\v\\0\\v A\\xCC%j   !A8\\v"@ A\\0 \\xFC\\v\\0\\v  (\\xDC%"At6\\xC4%  (\\xE0%At Avr6\\xC8% A\\xCC%j   A\\xEC%j \\xFD\\0\\0\\xCC%\\xFD\\v\\0\\0 (\\xE4%"@ 	\\v A\\0A\\xE0\\0\\xFC\\v\\0 \\0((\\xBC	 \\0(A\\x006\\xBC \\0("A\\x006\\xF4 (,"(\\0"@ 	\\v A\\x006$ B\\x0070 B\\x007\\0 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\b B\\x7F7( \\0("(0"@ Ak	 \\0("A\\x0060\\v (\\xDC$"@ 	 \\0("A\\x006\\xDC$ A\\x006P\\v (4"@ Ak	 \\0("A\\x0064\\v (\\xE0$"@ 	 \\0("A\\x006\\xE0$ A\\x006T\\v (8"@ Ak	 \\0("A\\x0068\\v (\\xE4$"@ 	 \\0("A\\x006\\xE4$ A\\x006X\\v (<"@ Ak	 \\0("A\\x006<\\v (\\xE8$"@ 	 \\0("A\\x006\\xE8$ A\\x006\\\\\\v (@"@ Ak	 \\0("A\\x006@\\v (\\xEC$"@ 	 \\0("A\\x006\\xEC$ A\\x006\\\`\\v (D"@ Ak	 \\0("A\\x006D\\v (\\xF0$"@ 	 \\0("A\\x006\\xF0$ A\\x006d\\v (H"@ Ak	 \\0("A\\x006H\\v (\\xF4$"@ 	 \\0("A\\x006\\xF4$ A\\x006h\\v (L"@ Ak	 \\0("A\\x006L\\v (\\xF8$"@ 	 \\0("A\\x006\\xF8$ A\\x006l\\v (p"@ 	 \\0("A\\x006p\\v B\\x007\\xD8 (("@ A\\x90\\xD6\\0G@ 8 \\0(!\\v A\\x006(\\vA! (\\xFC$@ \\xFD\\0\\0\\xB0 \\xFD\\0\\0\\xEC%\\xFD#\\xFDc!\\v B\\x007\\x84% A\\xD8jA\\0A\\x80\\xFC\\v\\0 B\\x007  \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\0 \\0("A\\x006\\xDC\\b A6\\xD8 \\0(\\0"\\0A	6\\0 \\0A\\x006\\v \\v\\xBF\\x7F~#\\0A\\x80k"$\\0@@@  B\\0B\\0"E\\r\\0\\x7F B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?\\x83!
\\x7F B0\\x88\\xA7A\\xFF\\xFFq"\\x07A\\xFF\\xFFG@A \\x07\\rAA  
\\x84P\\x1B\\f\\v  
\\x84P\\v\\vE\\r\\0 B0\\x88\\xA7"\\bA\\xFF\\xFFq"A\\xFF\\xFFG\\r\\v Aj      )" )"  T )\\b! )\\0!\\f\\v  B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\0\\x83"
  B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\0\\x83"	"A\\0L@  
  	"@ !\\f\\v A\\xF0\\0j  B\\0B\\0 )x! )p!\\f\\v B0\\x88\\xA7A\\xFF\\xFFq!\\x07 ~  A\\xE0\\0j  
B\\0B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xBB\\xC0\\0 )h"
B0\\x88\\xA7A\\xF8\\0k! )\\\`\\v! \\x07E@ A\\xD0\\0j  	B\\0B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xBB\\xC0\\0 )X"	B0\\x88\\xA7A\\xF8\\0k!\\x07 )P!\\v 	B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?\\x83B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\0\\x84!\\v 
B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?\\x83B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\0\\x84!
  \\x07J@@~ 
 \\v}  V\\xAD}"	B\\0Y@ 	  }"\\x84P@ A j  B\\0B\\0 )(! ) !\\f\\v 	B\\x86 B?\\x88\\x84\\f\\v 
B\\x86 B?\\x88\\x84\\v!
 B\\x86! Ak" \\x07J\\r\\0\\v \\x07!\\v@ 
 \\v}  V\\xAD}"	B\\0S@ 
!	\\f\\v 	  }"\\x84B\\0R\\r\\0 A0j  B\\0B\\0 )8! )0!\\f\\v 	B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?X@@ B?\\x88 Ak! B\\x86! 	B\\x86\\x84"	B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\0T\\r\\0\\v\\v \\bA\\x80\\x80q!\\x07 A\\0L@ A@k  	B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?\\x83 A\\xF8\\0j \\x07r\\xADB0\\x86\\x84B\\0B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xC3? )H! )@!\\f\\v 	B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?\\x83  \\x07r\\xADB0\\x86\\x84!\\v \\0 7\\0 \\0 7\\b A\\x80j$\\0\\v\\xBC*\\x7F~#\\0A\\xB0k"\\r$\\0@ \\0(\\0"(\\0AG@A\\r!\\f\\v ("A	kAxI@A!\\f\\v@@ AG@ A\\x006\\f\\v (\\r\\v A\\x006\\v ("A!kAcI@A!\\f\\v ( "A\\xFF\\xFF?K@A!\\f\\v@ ($"E@ A\\x80 A\\x80	 (\\xAC"\\b\\x1B"6$\\f\\v A\\x80\\x80kA\\x90\\x80|I@A\\x07!\\f\\v (\\xAC!\\b\\v \\bA K@A\\b!\\f\\v  \\bI@A
!\\f\\v@ \\x7F@ (\\xB0"E@A AvAj AM\\x1B AM\\r AF@A\\x07 A\\xC1I\\rA\\b A\\x81I\\rA	 A\\xC1I\\rA
 A\\x81	I\\r A\\x81O\\rA\\v\\f\\vA\\r A\\x81I\\rAA A\\x81	I\\x1B\\f\\v AkAuO\\rA	!\\f\\vA\\fA\\r A\\x81$I\\x1B\\v6\\xB0\\v@ (\\b@A\\v! A\\x80$K"	 A\\x81\\xF7Iq A\\x80\\x80Kr A\\xFF\\xFF'Kr A\\x80\\x80OA\\0 A
p\\x1Br\\r A\\bkAw"AO AGq\\r (\\xC4"
A\\bK\\r \\bA\\fK 	rE A\\x80\\xF7Kr\\r\\f\\v (\\xC4"
AI\\r\\0A!
 A6\\xC4\\v 
 (\\xC0M@  
6\\xC0\\v (\\xE0!\\x7F@ (\\xDC"@A E\\rA\\0!@@  Atj(\\0"E\\r\\0 (\\0AG\\r\\0 \\0( Aj6\\xC0\\x07\\f\\v Aj" G\\r\\0\\v\\f\\v @A\\f!\\f\\vA\\f\\vA\\0!
A\\0!\\bA\\0!@A\\f!@@@@@  Atj(\\0"(\\0\\x07\\x07\\0\\v \\r\\x7FA\\0 ("A\\xE3\\xF18K\\r\\0 E AFrE@ (")\\0!A!@A\\0  Alj)\\0"B\\x7FQ  TrE\\r ! Aj" G\\r\\0\\v\\vA\\vE\\rA!\\f\\v \\b\\rA!\\b\\f\\v\\x7FA\\0!@@ (\\xA0@A\\0! )\\x98"B\\xCC\\x82PE B\\x88\\xB1Tr\\r (\\xA4"	E\\r (\\xA8"\\f 	AtjAk-\\0\\0A\\xAAG\\r 	Ak!@ \\f Atj"-\\0\\b"E A\\xAAF A\\xE4\\0IrEr\\r )\\0B\\xCC\\x82PE\\r -\\0!@@  I@ E\\r ("\\x07-\\0\\bAM\\r\\f\\v E\\r (!\\x07\\v \\x07)\\0B\\xCC\\x82PE\\rA! AF\\r\\0@ \\x07 Atj"\\v)\\0B\\xCC\\x82PE\\r \\v-\\0\\b \\vA\\bk-\\0\\0AjG\\r Aj" G\\r\\0\\v\\vA! Aj" 	G\\r\\0\\v\\f\\v (\\xA4"	E\\r 	Ak!\\x07 (\\xA8!\\v@ \\v Atj"-\\0\\bE\\r -\\0!@@  \\x07I@ E\\r (-\\0\\bAM\\r\\f\\v E\\r\\v AF\\r\\0 (!\\fA!@ \\f Atj"A\\bk-\\0\\0Aj -\\0\\bG\\r Aj" G\\r\\0\\v\\vA! Aj" 	G\\r\\0\\v\\v \\f\\vA\\0\\v\\r\\f\\v\\x7F@ ("-\\0\\0"E\\r\\0@ A\\xFF\\0kA\\xFFqA\\xA1O@ -\\0! Aj! \\r\\f\\v\\vA\\0\\f\\vA ("-\\0\\0"E\\r\\0@@A!	@ \\xC0A\\0N\\r\\0@ A\\xFFq"\\x07A\\xE0qA\\xC0G\\r\\0 ,\\0A\\xBF\\x7FJ\\r\\0A!	 \\x07A\\xDEqA\\xC0G\\rA\\0\\f\\v@ A\\xF0qA\\xE0G\\r\\0 -\\0"\\vA\\xC0qA\\x80G\\r\\0 ,\\0"A\\xBF\\x7FJ\\r\\0A\\0!\\f \\x07A\\xE0F \\vA\\xA0qA\\x80Fq\\rA!	@@ \\x07A\\xEDk\\0\\v \\vA\\xE0qA\\xA0G\\r\\f\\v \\vA\\xBFG A\\xBEqA\\xBEGr\\r\\f\\v@ A\\xF8qA\\xF0G\\r\\0 -\\0"\\vA\\xC0qA\\x80G\\r\\0 ,\\0A\\xBF\\x7FJ\\r\\0 ,\\0A\\xBF\\x7FJ\\r\\0A!	 \\x07A\\xF0G \\vA\\xB0qA\\x80Gr\\rA\\0\\f\\v@ A\\xFCqA\\xF8G\\r\\0 -\\0"\\vA\\xC0qA\\x80G\\r\\0 ,\\0A\\xBF\\x7FJ\\r\\0 ,\\0A\\xBF\\x7FJ\\r\\0 ,\\0A\\xBF\\x7FJ\\r\\0A!	 \\x07A\\xF8G \\vA\\xB8qA\\x80Gr\\rA\\0\\f\\vA\\0!\\f A\\xFEqA\\xFCG\\r -\\0"A\\xC0qA\\x80G\\r ,\\0A\\xBF\\x7FJ\\r ,\\0A\\xBF\\x7FJ\\r ,\\0A\\xBF\\x7FJ\\r ,\\0A\\xBF\\x7FJ\\rA!	 \\x07A\\xFCG\\r\\0 A\\xBCqA\\x80F\\r\\vA!\\f  	j"-\\0\\0"\\r\\v\\v \\f\\vE\\r@@ (Ak\\0\\v 
\\r ("A\\xC8E@ A\\x88E\\r\\v (A G\\r ( A G\\rA!
\\f\\v \\rA!\\v Aj" G\\r\\0\\v \\bE\\v!	 \\0("B\\x007\\xC4\\x07 A\\x006\\x88 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xB4\\b \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xC4\\b \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xD4\\b A\\x006\\xE4\\b B\\x80\\x80\\x80\\x80 7\\xAC\\b \\0("(\\x88	@ A\\x006\\xBC\\b\\v (\\x8C	@ A\\x006\\xC4\\b\\v (\\x90	@ A\\x006\\xCC\\b\\v (\\x94	@ A\\x006\\xD0\\b\\v (\\x98	@ A\\x006\\xD4\\b\\v (\\x9C	@ A\\x006\\xDC\\b\\v (\\xA0	@ A\\x006\\xE0\\b\\v A6\\x84	 A6\\x80	 A6\\xFC\\b A6\\xF4\\b A6\\xF0\\b A6\\xEC\\b A6\\xE8\\b A\\x076\\xF8\\bA\\0! \\0(\\0"A\\x006\\0 A\\b6\\xC0	 B\\x007\\xB4	  6\\xCC	 A\\x006\\xC4	 A\\x006\\xBC	@ (("E\\r\\0 A\\x8Cj! A\\x8Cj!\\b AK@ A|q!A\\0!@ \\b At"
j\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\0  
j\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\v@ \\b At"jA\\x006\\0  jA\\x006\\0 Aj" G\\r\\0\\v\\v (\\xD4
@A\\0!\\b@  \\bAtj(\\0!@ ("E@ \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v  \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xB8J\\f\\v A\\x98\\xCA\\0j!
A\\0!@ AO@ A|q!A\\0!@  At"\\x07j\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\0 \\x07 
j\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\v@  At"jA\\x006\\0  
jA\\x006\\0 Aj" G\\r\\0\\v\\v \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v  \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xB8J A\\xB8\\xC9\\0j! A\\xC8\\xCA\\0j!
 A\\xD8\\0j!\\x07A\\0!@ \\x07 At"jA\\x006\\0  
jA\\x006\\0  j"A\\x006\\xCCJ A\\x006\\\\  AtjA\\x006\\0 Aj" (I\\r\\0\\v\\v \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\x98 B\\x007\\x88K B\\x007\\x88J B\\x007\\xD8I \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\x90K \\bAj"\\b (\\xD4
I\\r\\0\\v\\vA! \\0 ($ME\\r\\0A\\0!@ \\0("(\\xD4
"@@  Atj(\\0(\\x90J"A\\x006 B\\x80 7 A\\x80\\x80\\r"6\\0 E\\r Aj" G\\r\\0\\v !\\v@ \\0(\\0"(E@ B\\x007\\xB0
 B\\x007\\xE0	 A\\x006\\xD0	 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xB8
 A\\x006\\xC8
 B\\x007\\xF8 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xE8\\f\\v  ($Aj l"6\\x9C
@ ("E\\r\\0 A\\xFC	j!\\bA\\0! AtA \\x1B!
 A\\x80\\x80\\x80\\x80I!\\x07@@ E \\x07rE@  AtjA\\x006\\xFC	\\f\\v \\b Atj 
\\r"6\\0 E\\r\\0  Aj"G\\r\\f\\v\\v A\\b6\\0\\f\\v A\\x006\\xA0
@ (\\xF0	"\\r\\0\\x7FAA\\b"@ AA "6\\0 @ AA\\xE0\\xC1\\0"6 @ AA8"6, @ A6\\xE0\\b A\\xC0\\0\\r"6\\xD8\\b @ A6\\xD8 A	6\\0 \\f\\v 	\\v 	\\v 	\\v 	\\vA\\0\\v! \\0( 6\\xF0	 \\r\\0 \\0(\\0A6\\0\\f\\v\\x7FA!@ (\\0(\\0A	G\\r\\0 ("A\\x006\\xD4$ \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xC4$ \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xB4$ \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xA4$ B\\x80\\x80\\x80\\x80 7\\x9C$ ("A	6\\xD8A (,"\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\b A\\x80\\b6 A\\x80\\xC0\\0\\r"6\\0 E@ (\\0A\\b6\\0A\\f\\v  64 A
60 A\\x7F6, B\\x80\\x80\\x80\\x80p7$ ("A\\v6 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\b A\\x006\\x98$  \\x006$ A\\f6  A\\r6 A6 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xE0 A\\x006\\xF0 (\\0"(! A\\x006\\x88%  6\\xFC$ B7\\x80%A! ("(\\x80%E (\\0"A	Fq A\\bFr\\r\\0 B\\x007\\xC0A A\\x006\\xFC$ B\\x007\\xE8 A\\x006\\xB0A (,"B\\x80\\x80\\x80\\x80p7$ \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\b A\\x7F6, (\\0"A6\\0@ ("(\\x80%\\r\\0 ((A\\x90\\xD6\\0F\\r (\\b"E\\r\\0 B\\0 ($ \\0AF\\r (! (\\0!\\v A\\x006\\0 A\\x006\\xF0 (\\xBC	 (A\\x006\\xBC ("A\\x006\\xF4  (\\0(6\\xFC$ B\\x007\\xE0@ (\\x80%E@ A\\x8C%j" (\\xDC%A?q"j"A\\x80:\\0\\0 Aj! A8I\\x7FA7 k A?s"@ A\\0 \\xFC\\v\\0\\v A\\xCC%j   !A8\\v"@ A\\0 \\xFC\\v\\0\\v  (\\xDC%"At6\\xC4%  (\\xE0%At Avr6\\xC8% A\\xCC%j   A\\xEC%j \\xFD\\0\\0\\xCC%\\xFD\\v\\0\\0 (\\xE4%"@ 	\\v A\\0A\\xE0\\0\\xFC\\v\\0 (!\\f\\v A\\x006\\x80%\\v \\xFD\\f#Eg\\x89\\xAB\\xCD\\xEF\\xFE\\xDC\\xBA\\x98vT2\\xFD\\v\\xCC% \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xDC%A\\0! ("A\\x006\\xDCA A\\x006\\xB0A A\\x006\\xD0A \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xB8A\\v \\v@ \\0(\\0A6\\0\\f\\v \\0(\\0"( \\0("B\\x007\\xB0
 B\\x007\\xE0	 A\\x006\\xD0	 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xB8
 A\\x006\\xC8
 B\\x007\\xF8 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xE8E\\r\\0 A\\x006\\xF4	\\v (\\0(\\x90JA\\xC3\\xC2\\xB1\\xB2A \\vE@ \\0(\\0A\\x076\\0\\f\\v \\0 \\0((\\0A\\0A\\0)E\\r \\0(! \\0(\\0"(@ A6\\xF4	\\v A"6\\x98 B\\x007\\x90  ($6\\xA0 \\0( \\0(\\0($6\\xA4 \\0(A\\x006\\xA8 \\0(A\\x006\\xAC \\0( \\0(\\0( 6\\xB0 \\0( \\0(\\0(6\\xB4 \\0( \\0(\\0(6\\xB8 \\0( \\0(\\0)\\xD07\\xC0 \\0(\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xC8 \\0(\\0(\\f@ \\0("\\xFD\\f#Eg\\x89\\xAB\\xCD\\xEF\\xFE\\xDC\\xBA\\x98vT2\\xFD\\v\\x8C\\b \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\x9C\\b\\v \\0("A\\x90j (\\0(\\x90J3E@ \\0(\\0A\\x076\\0\\f\\v \\0 \\0((\\0A\\0A\\0)E\\r \\0(A\\xFF\\xFF\\xFF\\x076\\xA8 \\0(B\\x007\\xC0 	@ \\rA6\\0 \\0(\\0(\\xE0! \\rA\\b6\\b \\r\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v \\r E6 \\r \\0((\\0(\\x90J3E@ \\0(\\0A\\x076\\0\\f\\v \\0 \\0((\\0A\\0A\\0)E\\r\\v@ \\0(\\0"(\\xE0"E\\r\\0A\\0!@ (\\xDC Atj(\\0"  AkF6  \\0((\\0(\\x90J3E@ \\0(\\0A\\x076\\0A!\\f\\v \\0 \\0((\\0A\\0A\\0)@ Aj" \\0(\\0"(\\xE0"O\\r\\f\\v\\vA!\\f\\v@ \\0("(\\xBC	"E\\r\\0A! \\0 A\\xF8j (\\xCC	 \\0 \\0(\\0!AG\\r\\0 A6\\0\\f\\vA\\0! (E\\r \\0(A6\\xF4	\\f\\v \\0(\\0A\\b6\\0\\v \\rA\\xB0j$\\0 \\v\\xF0&
\\x7F~#\\0A k"\\x07$\\0@ \\0E\\r\\0@@@ \\0(\\0"(\\0\\0\\v (\\xDC"@ 	 \\0(\\0B\\x007\\xDC\\vA! \\0("(\\xD4	"E\\r A\\xA0\\xD7\\0G\\x7F 8 \\0( \\vA\\x006\\xD4	\\f\\v \\0("(\\xD0
\\r\\0 (\\xC4\\x07"E\\r\\0  6$ \\0 ME@A!\\f\\v \\0AOAs! \\0(\\0!\\v (\\f@ \\0("A\\xCC\\x07j" (\\x9C\\bA?q"j"A\\x80:\\0\\0 Aj! A8I\\x7FA7 k A?s"@ A\\0 \\xFC\\v\\0\\v A\\x8C\\bj   !A8\\v"@ A\\0 \\xFC\\v\\0\\v  (\\x9C\\b"At6\\x84\\b  (\\xA0\\bAt Avr6\\x88\\b A\\x8C\\bj    \\xFD\\0\\0\\x8C\\b\\xFD\\v\\0\\xC8 (\\xA4\\b"@ 	\\v A\\0A\\xE0\\0\\xFC\\v\\0\\v@ \\0("(\\xD0
@ !\\f\\v@ \\0(\\0"(\\0\\r\\0 (\\xB8	"@ (\\xB8!\\b (\\xAC! (\\xA8! )\\xC0!\\v@@@ \\0 )\\xE8B| (\\xCC	 \\0\\0\\v \\0 A\\xC8jAA\\0A\\0 \\0("(\\xCC	 (\\xC0	\\x07\\0\\r\\0 \\x07 \\vB\\0 \\vB\\x80\\x80\\x80\\x80\\x80X\\x1B"\\f<\\0 \\x07 \\fB\\b\\x88<\\0 \\x07 \\fB\\x88<\\0 \\x07 \\fB\\x88<\\0 \\x07 \\fB \\x88\\xA7Aq \\bAtrA\\xF0j:\\0\\0@ \\0 \\0(\\0)\\xE8B| \\0("(\\xCC	 (\\xB8	\\0\\0\\v \\0 \\x07AA\\0A\\0 \\0("(\\xCC	 (\\xC0	\\x07\\0\\r\\0 \\x07 :\\0 \\x07 A\\bv:\\0 \\x07 Av:\\0 \\x07 :\\0 \\x07 A\\bv:\\0 \\x07 Av:\\0\\0@ \\0 \\0(\\0)\\xE8B\\b| \\0("(\\xCC	 (\\xB8	\\0\\0\\v \\0 \\x07AA\\0A\\0 \\0("(\\xCC	 (\\xC0	\\x07\\0\\r\\0 \\0((\\xC0\\x07"\\bE\\r \\b(\\0"E\\r \\0(\\0)\\xF0P\\r Aq! \\b(!A\\0!A\\0!@ AO@ A|q!	@ \\v  Alj")\\0T@ B\\x7F7\\0\\v \\v )T@ B\\x7F7\\v \\v )0T@ B\\x7F70\\v \\v )HT@ B\\x7F7H\\v Aj" 	G\\r\\0\\v E\\r\\v@ \\v  Alj")\\0T@ B\\x7F7\\0\\v Aj! Aj" G\\r\\0\\v\\v@ \\b(\\0"E\\r\\0 \\b(!#\\0A\\xD0k"$\\0 B7\\b@ Al"E\\r\\0 B\\x98\\x80\\x80\\x80\\x807A!@ Aj Atj" A\\bk(\\0 Ak(\\0jAj"6\\0 Aj!  K\\r\\0\\v\\x7F Ak"A\\0L@A\\0!A!A!A\\0\\f\\v  j!A!A!@\\x7F AqAF@   Aj= A\\bjA1 Aj\\f\\v@ Aj"	 Ak"
Atj(\\0  kO@   (\\f A\\0 	0\\f\\v   Aj=\\v AF@ A\\bjA/A\\0\\f\\v A\\bj 
/A\\v!  (\\bAr"6\\b Aj" I\\r\\0\\v (\\f"A\\0G\\v!	    A\\0 Aj0 AG (\\b"AGr 	rE\\r\\0@\\x7F AL@ A\\bj  \\\\"1  j\\f\\v A\\bj"A/  (\\bA\\x07s6\\b A1 Ak"
 Aj" Ak"	Atj(\\0k (\\b (\\f AkA 0 A/  (\\bAr"6\\b 
  (\\f 	A 0 	\\v! Ak! (\\f" AG (\\b"AGrr\\r\\0\\v\\v A\\xD0j$\\0 \\b(\\0"AI\\r\\0A!A!@@ \\b(" Alj")\\0"\\vB\\x7FR@ \\v  AljAk)\\0Q\\r\\v  Alj" )7  \\xFD\\0\\0\\xFD\\v\\0 Aj! \\b(\\0!\\v Aj" I\\r\\0\\v  M\\r\\0 \\b(!  "kAq"	@A\\0!@  Alj"\\bA\\x006 \\bB\\x007\\b \\bB\\x7F7\\0 Aj! Aj" 	G\\r\\0\\v\\v  kA|K\\r\\0@  Alj"A\\x006X B\\x007P B\\x7F7H A\\x006@ B\\x0078 B\\x7F70 A\\x006( B\\x007  B\\x7F7 A\\x006 B\\x007\\b B\\x7F7\\0 Aj" G\\r\\0\\v\\v@ \\0 \\0(\\0)\\xF0B| \\0("(\\xCC	 (\\xB8	\\0\\0\\v \\0("(\\xC0\\x07"(\\0E\\rA\\0!@ \\x07 Al" (j)\\0"\\vB8\\x86 \\vB\\x80\\xFE\\x83B(\\x86\\x84 \\vB\\x80\\x80\\xFC\\x07\\x83B\\x86 \\vB\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 \\vB\\b\\x88B\\x80\\x80\\x80\\xF8\\x83 \\vB\\x88B\\x80\\x80\\xFC\\x07\\x83\\x84 \\vB(\\x88B\\x80\\xFE\\x83 \\vB8\\x88\\x84\\x84\\x847\\0 \\x07 ( j)\\b"\\vB8\\x86 \\vB\\x80\\xFE\\x83B(\\x86\\x84 \\vB\\x80\\x80\\xFC\\x07\\x83B\\x86 \\vB\\x80\\x80\\x80\\xF8\\x83B\\b\\x86\\x84\\x84 \\vB\\b\\x88B\\x80\\x80\\x80\\xF8\\x83 \\vB\\x88B\\x80\\x80\\xFC\\x07\\x83\\x84 \\vB(\\x88B\\x80\\xFE\\x83 \\vB8\\x88\\x84\\x84\\x847\\b \\x07 ( j/"A\\bt A\\bvr; \\0 \\x07AA\\0A\\0 (\\xCC	 (\\xC0	\\x07\\0\\r Aj" \\0("(\\xC0\\x07"(\\0I\\r\\0\\v\\f\\v \\0(\\0A6\\0\\v \\0(!A  \\0(\\0"(\\0\\x1B!\\v (\\xC4	"E\\r\\0 \\0 A\\x90j (\\xCC	 \\0\\0 \\0(\\0!\\v (E@ !\\f\\v \\0((\\xF0	"E@ !\\f\\v P@ !\\f\\vA! \\r\\0 \\0(\\0A6\\0\\v \\0("(\\xD4	"@ A\\xA0\\xD7\\0G@ 8 \\0(!\\v A\\x006\\xD4	\\v \\0(\\0"(\\xDC"@ 	 \\0(\\0"B\\x007\\xDC \\0(!\\v ((@A\\0!@  At"j(\\x8C"@ 	 \\0(" jA\\x006\\x8C \\0(\\0!\\v Aj" ((I\\r\\0\\v\\v (\\xD4
@A\\0!\\b@  \\bAt"j(\\0"@A\\0! \\0(\\0"(@@  j(\\0" At"	j(\\x98J"
@ 
	 \\0(" j(\\0" 	jA\\x006\\x98J \\0(\\0!\\v Aj" (I\\r\\0\\v\\v (\\xB8J"@ 	 \\0(" j(\\0"A\\x006\\xB8J\\v (\\xBCJ"@ 	 \\0(" j(\\0"A\\x006\\xBCJ\\v (\\xC0J"@ 	 \\0(" j(\\0"A\\x006\\xC0J\\v (\\xC4J"@ 	 \\0(" j(\\0A\\x006\\xC4J\\vA\\0! \\0(\\0(@@  j(\\0" At"j(\\xC8J"	@ 		 \\0(" j(\\0" jA\\x006\\xC8J\\v  j(\\xCCJ"@ 	 \\0(" j(\\0 jA\\x006\\xCCJ\\v Aj" \\0(\\0(I\\r\\0\\v\\v  j(\\0"(\\x88K"@ 	 \\0( j(\\0"A\\x006\\x88K\\v (\\x8CK"@ 	 \\0( j(\\0"A\\x006\\x8CK\\v (\\x90K"@ 	 \\0( j(\\0"A\\x006\\x90K\\v (\\x94K"@ 	 \\0( j(\\0"A\\x006\\x94K\\v (\\x98K"@ 	 \\0( j(\\0"A\\x006\\x98K\\v (\\x9CK"@ 	 \\0( j(\\0"A\\x006\\x9CK\\v (\\xB8E"@ 	\\v (\\xBCE"@ 	\\v A\\x006\\xC0E B\\x007\\xB8E \\0( j(\\0"(\\xC4E"@ 	\\v (\\xC8E"@ 	\\v A\\x006\\xCCE B\\x007\\xC4E \\0( j(\\0"(\\xD0E"@ 	\\v (\\xD4E"@ 	\\v A\\x006\\xD8E B\\x007\\xD0E \\0( j(\\0"(\\xDCE"@ 	\\v (\\xE0E"@ 	\\v A\\x006\\xE4E B\\x007\\xDCE \\0( j(\\0"(\\xE8E"@ 	\\v (\\xECE"@ 	\\v A\\x006\\xF0E B\\x007\\xE8E \\0( j(\\0"(\\xF4E"@ 	\\v (\\xF8E"@ 	\\v A\\x006\\xFCE B\\x007\\xF4E \\0( j(\\0"(\\x80F"@ 	\\v (\\x84F"@ 	\\v A\\x006\\x88F B\\x007\\x80F \\0( j(\\0"(\\x8CF"@ 	\\v (\\x90F"@ 	\\v A\\x006\\x94F B\\x007\\x8CF \\0( j(\\0"(\\x98F"@ 	\\v (\\x9CF"@ 	\\v A\\x006\\xA0F B\\x007\\x98F \\0( j(\\0"(\\xA4F"@ 	\\v (\\xA8F"@ 	\\v A\\x006\\xACF B\\x007\\xA4F \\0( j(\\0"(\\xB0F"@ 	\\v (\\xB4F"@ 	\\v A\\x006\\xB8F B\\x007\\xB0F \\0( j(\\0"(\\xBCF"@ 	\\v (\\xC0F"@ 	\\v A\\x006\\xC4F B\\x007\\xBCF \\0( j(\\0"(\\xC8F"@ 	\\v (\\xCCF"@ 	\\v A\\x006\\xD0F B\\x007\\xC8F \\0( j(\\0"(\\xD4F"@ 	\\v (\\xD8F"@ 	\\v A\\x006\\xDCF B\\x007\\xD4F \\0( j(\\0"(\\xE0F"@ 	\\v (\\xE4F"@ 	\\v A\\x006\\xE8F B\\x007\\xE0F \\0( j(\\0"(\\xECF"@ 	\\v (\\xF0F"@ 	\\v A\\x006\\xF4F B\\x007\\xECF \\0( j(\\0"(\\xF8F"@ 	\\v (\\xFCF"@ 	\\v A\\x006\\x80G B\\x007\\xF8F \\0( j(\\0"(\\x84G"@ 	\\v (\\x88G"@ 	\\v A\\x006\\x8CG B\\x007\\x84G \\0( j(\\0"(\\x90G"@ 	\\v (\\x94G"@ 	\\v A\\x006\\x98G B\\x007\\x90G \\0( j(\\0"(\\x9CG"@ 	\\v (\\xA0G"@ 	\\v A\\x006\\xA4G B\\x007\\x9CG \\0( j(\\0"(\\xA0k"@ 	\\v (\\xA4k"@ 	\\v A\\x006\\xA8k B\\x007\\xA0k \\0( j(\\0"(\\xACk"@ 	\\v (\\xB0k"@ 	\\v A\\x006\\xB4k B\\x007\\xACk \\0(!\\v \\bAj"\\b (\\xD4
I\\r\\0\\v \\0(\\0!\\v@ (E\\r\\0 (E\\r\\0A\\0!@  At"j(\\xFC	"@ 	 \\0(" jA\\x006\\xFC	 \\0(\\0!\\v Aj" (I\\r\\0\\v\\v B\\x8D\\x80\\x80\\x80\\x80\\x80\\x80\\x80?7, B\\x80\\x80\\x80\\x807$ \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0D\\xAC\\0\\0\\xFD\\v \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v \\0(\\0"\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xBC \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xAC \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xD0 B\\x80\\x80\\x80\\x807\\xE0 \\0("B\\x007\\x88	 A\\x006\\xC0\\x07 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\x90	 B\\x007\\xA4	 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xAC	 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xBC	 A\\x006\\xCC	 A6\\xD4
@ (\\0AG\\r\\0 B7 \\09 \\0(\\0"(\\0AG\\r\\0 B\\x80\\x80\\x80\\x80\\xD0\\x007\\xC0 \\xFD\\f\\b\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xAC\\v E@ \\0(\\0A6\\0\\v E!\\v \\x07A j$\\0 \\v\\x87\\x7F~#\\0A\\xD0k"$\\0 B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?\\x83!\\v B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?\\x83!
  \\x85B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x7F\\x83!\\f B0\\x88\\xA7A\\xFF\\xFFq!\\x07@@ B0\\x88\\xA7A\\xFF\\xFFq"\\bA\\xFF\\xFFkA\\x82\\x80~O@ \\x07A\\xFF\\xFFkA\\x81\\x80~K\\r\\v P B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\0\\x83"B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0T B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0Q\\x1BE@ B\\x80\\x80\\x80\\x80\\x80\\x80 \\x84!\\f\\f\\v P B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\0\\x83"B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0T B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0Q\\x1BE@ B\\x80\\x80\\x80\\x80\\x80\\x80 \\x84!\\f !\\f\\v  B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0\\x85\\x84P@  B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0\\x85\\x84P@B\\0!B\\x80\\x80\\x80\\x80\\x80\\x80\\xE0\\xFF\\xFF\\0!\\f\\f\\v \\fB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0\\x84!\\fB\\0!\\f\\v  B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0\\x85\\x84P@B\\0!\\f\\v  \\x84P@B\\x80\\x80\\x80\\x80\\x80\\x80\\xE0\\xFF\\xFF\\0 \\f  \\x84P\\x1B!\\fB\\0!\\f\\v  \\x84P@ \\fB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0\\x84!\\fB\\0!\\f\\v B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?X@ A\\xC0j  
  
 
P"\\x1ByB\\xC0\\0B\\0 \\x1B|\\xA7"AkA k! )\\xC8!
 )\\xC0!\\v B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?V\\r\\0 A\\xB0j  \\v  \\v \\vP"	\\x1ByB\\xC0\\0B\\0 	\\x1B|\\xA7"	Ak  	jAk! )\\xB8!\\v )\\xB0!\\v A\\xA0j \\vB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\0\\x84"B\\x86 B1\\x88\\x84"B\\0B\\x80\\x80\\x80\\x80\\xB0\\xE6\\xBC\\x82\\xF5\\0 }"B\\0 A\\x90jB\\0 )\\xA8}B\\0 B\\0 A\\x80j )\\x98B\\x86 )\\x90B?\\x88\\x84"B\\0 B\\0 A\\xF0j B\\0B\\0 )\\x88}B\\0 A\\xE0j )\\xF8B\\x86 )\\xF0B?\\x88\\x84"B\\0 B\\0 A\\xD0j B\\0B\\0 )\\xE8}B\\0 A\\xC0j )\\xD8B\\x86 )\\xD0B?\\x88\\x84"B\\0 B\\0 A\\xB0j B\\0B\\0 )\\xC8}B\\0 A\\xA0j B\\0 )\\xB8B\\x86 )\\xB0B?\\x88\\x84B}"B\\0 A\\x90j B\\x86B\\0 B\\0 A\\xF0\\0j B\\0B\\0 )\\xA8 )\\xA0" )\\x98|" T\\xAD| BV\\xAD|}B\\0 A\\x80jB }B\\0 B\\0  \\b \\x07kj"\\bA\\xFF\\xFF\\0j!~ )p"B\\x86"\\r )\\x88"B\\x86 )\\x80B?\\x88\\x84|"B\\xE7\\xEC\\0}"B \\x88" 
B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\0\\x84"B\\x86"B \\x88"~" B\\x86"B \\x88"\\v  V\\xAD \\r V\\xAD )xB\\x86 B?\\x88\\x84 B?\\x88|||B}"B \\x88"~|"\\r T\\xAD \\r \\r B\\xFF\\xFF\\xFF\\xFF\\x83" B?\\x88" 
B\\x86\\x84B\\xFF\\xFF\\xFF\\xFF\\x83"
~|"\\rV\\xAD|  ~|  ~" 
 ~|" T\\xADB \\x86 B \\x88\\x84| \\r B \\x86|" \\rT\\xAD|   B\\xFF\\xFF\\xFF\\xFF\\x83" 
~"\\r  \\v~|" \\rT\\xAD    B\\xFE\\xFF\\xFF\\xFF\\x83"\\r~|"V\\xAD||"V\\xAD|   ~" \\r ~|"  
~|"
 \\v ~|"B \\x88 
 V\\xAD  T\\xAD  
V\\xAD||B \\x86\\x84|" T\\xAD|     \\r~"
 \\v ~|"B \\x88  
T\\xADB \\x86\\x84|"
 T\\xAD 
 
 B \\x86|"
V\\xAD||"V\\xAD|   
 B \\x86" \\r ~| T\\xADB\\x7F\\x85"V  
Rq\\xAD|"V\\xAD|"B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\0X@  \\x84! A\\xD0\\0j  B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\0T"\\x07\\xAD"\\v\\x86"
  \\v\\x86 B\\x88 \\x07A?s\\xAD\\x88\\x84"   \\bA\\xFE\\xFF\\0j  \\x07\\x1BAk! B1\\x86 )X} )P"B\\0R\\xAD}!\\vB\\0 }\\f\\v A\\xE0\\0j B?\\x86 B\\x88\\x84"
 B\\x88"   B0\\x86 )h} )\\\`"B\\0R\\xAD}!\\v !B\\0 }\\v! A\\xFF\\xFFN@ \\fB\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0\\x84!\\fB\\0!\\f\\v~ A\\0J@ \\vB\\x86 B?\\x88\\x84! B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?\\x83 \\xADB0\\x86\\x84!\\v B\\x86\\f\\v A\\x8F\\x7FL@B\\0!\\f\\v A@k 
 A k% A0j   A\\xF0\\0j A j   )@"
 )H"\\v )8 )(B\\x86 ) "B?\\x88\\x84} )0" B\\x86"T\\xAD}!  }\\v! Aj  BB\\0   BB\\0 \\v 
  
B\\x83" |"T   T\\xAD|" V  Q\\x1B\\xAD|" 
T\\xAD|"   B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0T  )V  )"V  Q\\x1Bq\\xAD|"V\\xAD|"  B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0T  )\\0V  )\\b"V  Q\\x1Bq\\xAD|" T\\xAD| \\f\\x84!\\f\\v \\0 7\\0 \\0 \\f7\\b A\\xD0j$\\0\\v\\xC0\\x7F~A\\x7F!@ \\0B\\0R B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\0\\x83"B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0V B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0Q\\x1B\\r\\0 B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\0\\x83"B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0V B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0Rq\\r\\0 \\0  \\x84\\x84P@A\\0\\v  \\x83B\\0Y@  R  Sq\\r \\0  \\x85\\x84B\\0R\\v \\0B\\0R  U  Q\\x1B\\r\\0 \\0  \\x85\\x84B\\0R!\\v \\v\\x7F#\\0Ak" \\x009\\b \\0 +\\b\\xA2\\v\\xB7\\x7F#\\0A\\xD0\\0k"$\\0@ A\\x80\\x80N@ A j  B\\0B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\xFF\\xFF\\0 )(! ) ! A\\xFF\\xFFI@ A\\xFF\\xFF\\0k!\\f\\v Aj  B\\0B\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\xFF\\xFF\\0A\\xFD\\xFF  A\\xFD\\xFFO\\x1BA\\xFE\\xFFk! )! )!\\f\\v A\\x81\\x80\\x7FJ\\r\\0 A@k  B\\0B\\x80\\x80\\x80\\x80\\x80\\x80\\x809 )H! )@! A\\xF4\\x80~K@ A\\x8D\\xFF\\0j!\\f\\v A0j  B\\0B\\x80\\x80\\x80\\x80\\x80\\x80\\x809A\\xE8\\x81}  A\\xE8\\x81}M\\x1BA\\x9A\\xFEj! )8! )0!\\v   B\\0 A\\xFF\\xFF\\0j\\xADB0\\x86 \\0 \\xFD\\0\\0\\xFD\\v\\0 A\\xD0\\0j$\\0\\v<\\0 \\0 7\\0 \\0 B\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF?\\x83 B\\x80\\x80\\x80\\x80\\x80\\x80\\xC0\\xFF\\xFF\\0\\x83B0\\x88\\xA7 B0\\x88\\xA7A\\x80\\x80qr\\xADB0\\x86\\x847\\b\\v\\xED\\x7F~@@@@@@\\x7F \\0(" \\0(hG@ \\0 Aj6 -\\0\\0\\f\\v \\0\\v"A+k\\0\\0\\v\\x7F \\0(" \\0(hG@ \\0 Aj6 -\\0\\0\\f\\v \\0\\v"A:kAuK@ A-F! !\\f\\v \\0)pB\\0Y\\r\\f\\v A:kAuK\\r \\0)pB\\0S\\r\\f\\v \\0 \\0(Ak6\\v \\0 \\0(Ak6\\vB\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x80\\x7F\\v@ A0kA
O\\r\\0A\\0!@  A
ljA0k"A\\xCC\\x99\\xB3\\xE6\\0H\\x7F \\0(" \\0(hG@ \\0 Aj6 -\\0\\0\\f\\v \\0\\v"A0k"A	Mq\\r\\0\\v \\xAC! A
O\\r\\0@ \\xAD B
~|!\\x7F \\0(" \\0(hG@ \\0 Aj6 -\\0\\0\\f\\v \\0\\v"A0k"A	M B0}"B\\xAE\\x8F\\x85\\xD7\\xC7\\xC2\\xEB\\xA3Sq\\r\\0\\v A
O\\r\\0@\\x7F \\0(" \\0(hG@ \\0 Aj6 -\\0\\0\\f\\v \\0\\vA0kA
I\\r\\0\\v\\v \\0)pB\\0Y@ \\0 \\0(Ak6\\vB\\0 }  \\x1B\\v
\\0 \\0hA\\0 \\0\\x1B\\vn\\x7F#\\0A\\x80k"$\\0 AN@ \\0 Atj 6\\0  \\0(\\0A>@ \\0 Atj"(\\0 \\0 Aj"Atj(\\0A>  (\\0Aj6\\0  G\\r\\0\\v\\v A\\x80j$\\0\\v\\0 \\0AkZ"\\0\\x7F \\0 Z"\\0A rA\\0 \\0\\x1B\\v\\v:\\x7F \\0(<#\\0Ak"\\0$\\0  A\\xFFq \\0A\\bj,! \\0)\\b! \\0Aj$\\0B\\x7F  \\x1B\\v\\xBB\\x07\\x7F#\\0A k"$\\0  \\0("6 \\0(!  6  6   k"6  j!A! Aj!\\x7F@@@@ \\0(<   A\\fj\\x07,E@  (\\f"\\x07F\\r \\x07A\\0N\\r\\f\\v A\\x7FG\\r\\v \\0 \\0(,"6 \\0 6 \\0  \\0(0j6 \\f\\v A\\bA\\0 \\x07 ("\\bK"	\\x1Bj" \\x07 \\bA\\0 	\\x1Bk"\\b (\\0j6\\0 A\\fA 	\\x1Bj" (\\0 \\bk6\\0  \\x07k!  	k! !\\f\\v\\v \\0A\\x006 \\0B\\x007 \\0 \\0(\\0A r6\\0A\\0 AF\\r\\0  (k\\v A j$\\0\\v\\xD6\\x7F#\\0A k"$\\0  6   \\0(0"A\\0Gk6 \\0(,!  6  6A !@@ \\0 \\0(< AjA A\\fj\\b,\\x7FA  (\\f"A\\0J\\rA A \\x1B\\v \\0(\\0r6\\0\\f\\v (" "O\\r\\0 \\0 \\0(,"6 \\0   kj6\\b \\0(0@ \\0 Aj6  jAk -\\0\\0:\\0\\0\\v !\\v A j$\\0 \\v\\x9A\\x7F@ ("("E\\r\\0  ($ \\0E\\r\\0 A\\x006\\0 (\\0A6\\0A\\0\\v@@ (\\0@@ ("(\\x84%E\\r\\0 (\\xD0AAI\\r\\0 (\\0A\\x076\\0\\f\\v  \\0  ($ (\\0"AF@ (\\0A\\x076\\0\\f\\vA!\\0 (\\0\\r@@@ Ak\\0\\v (\\0!\\0 ((,-\\0A\\x07qE@ \\0A
6\\0\\f\\v \\0A6\\0\\f\\v ("("E\\r  ($ \\0E\\r\\v (\\0A6\\0\\f\\v (\\0A\\x076\\0\\vA\\0!\\0\\v \\0\\v\\xFD\\v\\x7F~#\\0Ak"\\x07$\\0  Atj!\\v@@ E@ E\\r@ \\0 \\x07A\\bj2E@A\\0!	\\f\\vA!	  \\x07(\\b"AvA\\0 Aqks6\\0 Aj" \\vI\\r\\0\\v\\f\\vA\\x7F v!\\r\\x7F@ \\0(" \\0(\\b"\\bO@\\f\\v \\0(\\0 Atj)\\0 \\0("\\f\\xAD\\x86!A\\0\\f\\vA\\v!@@@@@ E@A\\xC0\\0 \\fk!@  \\vI@A\\xC0\\0 k"\\xAD! \\xAD!@ ! !@ PE@ y"\\xA7!\\f\\v@ Aj" \\bO\\r  \\0(\\0 Atj)\\0"y"\\xA7j! P\\r\\0\\v\\v  \\rK@\\f\\v\\v  \\x86B\\x86" \\x88"\\xA7!
@   A\\x7FsjA?q"M@  \\x86!  k! !\\f\\v Aj" \\bO\\r \\0(\\0 Atj)\\0"A\\xC0\\0  j"k\\xAD\\x86!  \\xAD\\x88 \\x84\\xA7!
\\v \\x07 
6\\f  
  tr"AvA\\0 Aqks6\\0 Aj" \\vI\\r\\0\\v\\v \\0   \\bI" Eqj6 \\0A\\xC0\\0 A\\xC0\\0A\\0 \\x1B \\x1Bk6\\f\\x07\\v \\0A\\x006 \\0 \\b Aj"  \\bI\\x1B6\\f\\v \\0 \\x07A\\bj2E\\r \\x07 \\x07(\\b j"6\\bA\\0!
A\\0!\\f\\v \\0 6 \\0A\\x006\\v \\0 \\x07A\\fj  k\\fE\\r  t! \\x07 \\x07(\\f 
r"6\\fA\\0!   r"AvA\\0 Aqks6\\0 Aj! \\0(!\\f \\0(\\b!\\bB\\0! \\0(" \\0(I@ \\0(\\0 Atj)\\0 \\f\\xAD\\x86!\\v  \\bI  \\vOr\\r\\vA!\\f\\vA\\0!\\f\\0\\v\\0\\vA!	\\v \\x07Aj$\\0 	\\v\\0 \\0\\r\\v\\f\\0 (\\0A6\\0\\v\\0\\v\\xAF\\x7F~ (\\0"\\f(\\0AF@A\\v (\\0! (! (\\b"E@  (\\xA0
 k6\\xA0
A\\0\\v At!\\b A\\xFC	j!\\r@  \\x07At"\\0j(\\0"!	 \\0 \\rj(\\0"!
A\\0!\\v@ \\b"\\0E\\r\\0@ 	-\\0\\0" 
-\\0\\0"F@ 
Aj!
 	Aj!	 \\0Ak"\\0\\r\\f\\v\\v  k!\\v\\v \\v@A\\0!\\0@ @A\\0!@  At"j(\\0"\\b  j(\\0"G@ !\\0\\f\\v Aj" G\\r\\0\\v\\vA\\0!A\\0!\\b\\v  ) \\0\\xAD|7\\xB0
 )!  \\b6\\xC8
  6\\xC4
  \\x006\\xC0
  \\x076\\xBC
   \\xAD\\x80>\\xB8
 \\fA6\\0A\\v \\x07Aj"\\x07 G\\r\\0\\v  (\\xA0
 k"\\x006\\xA0
A\\0!\\x07@ AG\\x7F Aq A~q!\\b@ At!\\0 \\x07At! ("(\\xA0
At"@  j(\\xFC	" \\0 j \\xFC
\\0\\0\\v ("(\\xA0
At"@  j(\\x80
" \\0 j \\xFC
\\0\\0\\v \\x07Aj"\\x07 \\bG\\r\\0\\vE\\r ("(\\xA0
 \\0\\vAt"\\0E\\r\\0  \\x07Atj(\\xFC	"  Atj \\0\\xFC
\\0\\0\\vA\\0\\v\\x96\\x7F ("(\\xF8	@ A6\\0 A\\xE6\\x98\\x85\\x9B6\\0\\0 (A\\x006\\xF8	A\\0\\v (\\xAC
"\\0E@A\\v (\\0" \\0K@  \\x006\\0 \\0!\\v @  (\\xA4
 \\xFC
\\0\\0\\v ("\\0 (\\0" \\0(\\xA4
j6\\xA4
 \\0 \\0(\\xAC
 k6\\xAC
A\\0\\v\\x87\\x07\\x07\\x7F{~A\\0 k!
A t!\\b  j v"\\v k!@ AjA  \\vgAskI@A\\0!@B\\0! 
 \\vj"
 \\x07K@A\\0!@  \\x07k"\\fAO@ \\fA|q!	 \\0 \\x07Atj!\\r\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!@ \\r Atj\\xFD\\0\\0\\xFD\\xA0 \\xFD\\xAE! Aj" 	G\\r\\0\\v   \\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xAE"  \\xFD\\r\\x07\\0\\0\\0\\xFD\\xAE\\xFD\\x1B\\0! 	 \\fF\\r \\x07 	j!\\x07\\v@  \\0 \\x07Atj(\\0" Au"s kj! \\x07Aj"\\x07 
I\\r\\0\\v\\v \\xAD! !\\x07\\v  Atj 7\\0  \\vj! Aj" \\bG\\r\\0\\v\\f\\vA\\0!@B\\0! 
 \\vj"
 \\x07K@@  \\x07k"\\fAO@ \\fA~q!	 \\0 \\x07Atj!\\r\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0!A\\0!@  \\r Atj\\xFD]\\0\\xFD\\xA0\\xFD\\xC9\\xFD\\xCE! Aj" 	G\\r\\0\\v   \\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\0! 	 \\fF\\r \\x07 	j!\\x07\\v@  \\0 \\x07Atj(\\0" Au"s k\\xAD|! \\x07Aj"\\x07 
I\\r\\0\\v\\v !\\x07\\v  Atj 7\\0  \\vj! Aj" \\bG\\r\\0\\v\\v  H@A\\0! \\b!@@ Av"E\\r\\0 AG@ Aq@ AkAv"\\0@ \\0Aj"\\0Aq \\0A\\xFE\\xFF\\xFF\\xFF\\x07q!	A\\0!\\0@  \\bAtj"\\x07  Atj")\\b )\\0|7\\0 \\x07 ) )|7\\b \\x07 )( ) |7 \\x07 )8 )0|7 A\\bj! \\bAj!\\b \\0Aj"\\0 	G\\r\\0\\vE\\r\\v  \\bAtj"  Atj"\\0)\\b \\0)\\0|7\\0  \\0) \\0)|7\\b Aj! \\bAj!\\b\\vE\\r\\v  \\bAtj  Atj"\\0)\\b \\0)\\0|7\\0 Aj! \\bAj!\\b\\v Ak" J\\r\\0\\v\\v\\v\\xA7		{\\x7F}\\x7F A\\0L@A\\0\\f\\v@{ AI@\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\f\\v A\\xFC\\xFF\\xFF\\xFF\\x07q!@ \\0 \\fAtj"\\r\\xFD\\0\\0" \\rA\\fk\\xFD\\0\\0"\\v\\xFD\\xB1 \\rA\\bk\\xFD\\0\\0"
 \\rAk\\xFD\\0\\0"	\\xFD\\xB1\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xB5\\xFD\\xAE\\xFD\\xA0 \\xFD\\xAE! 
\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xB5 \\xFD\\xAE \\rAk\\xFD\\0\\0\\xFD\\xAE \\v 	\\xFD\\xAEA\\xFD\\xAB\\xFD\\xB1\\xFD\\xA0 \\x07\\xFD\\xAE!\\x07  	\\xFD\\xB1\\xFD\\xA0 \\xFD\\xAE!  	A\\xFD\\xAB\\xFD\\xB1 
\\xFD\\xAE\\xFD\\xA0 \\xFD\\xAE! \\xFD\\xA0 \\b\\xFD\\xAE!\\b \\fAj"\\f G\\r\\0\\v   \\b \\b \\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xAE"  \\xFD\\r\\x07\\0\\0\\0\\xFD\\xAE"\\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xAE"  \\xFD\\r\\x07\\0\\0\\0\\xFD\\xAE!   \\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xAE"  \\xFD\\r\\x07\\0\\0\\0\\xFD\\xAE!   \\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xAE"  \\xFD\\r\\x07\\0\\0\\0\\xFD\\xAE! \\x07 \\x07 \\xFD\\r\\b	
\\v\\f\\r\\0\\0\\xFD\\xAE"\\x07 \\x07 \\xFD\\r\\x07\\0\\0\\0\\xFD\\xAE\\xFD\\x1B\\0!\\r  F\\r  \\xFD\\r\\0\\0\\0  \\xFD\\r\\0\\0\\0\\xFD\\r\\0\\x07\\x1B\\v!@ \\r \\0 Atj"\\fA\\bk(\\0"Al \\f(\\0"j \\fAk(\\0j \\fA\\fk(\\0" \\fAk(\\0"\\fjAtk"\\r \\rAu"\\rs \\rkj!\\r  k  \\fkAlj\\xFD  \\fAtk j\\xFD  \\fk\\xFD \\xFD\\xFD\\xA0 \\xFD\\xAE! Aj" G\\r\\0\\v \\xFD\\x1B!\\f \\xFD\\x1B! \\xFD\\x1B! \\xFD\\x1B\\0\\f\\v \\xFD\\x1B\\0! \\xFD\\x1B\\0! \\xFD\\x1B\\0!\\f \\xFD\\x1B\\0\\v!\\0 }\\x7F@  \\f \\f K\\x1B" \\0 \\0 K\\x1B" \\r \\r K\\x1B I@A \\f \\0 \\0 \\fK\\x1B" \\r \\r K\\x1B O\\r \\f \\0 \\r \\0 \\rI\\x1BK\\rA\\f\\vA\\0" \\rC\\0\\0\\0\\0\\f\\vAA \\0 \\rK\\x1B\\v! \\xB8D\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6\\v8\\0  } \\xB8D\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6C\\0\\0\\0\\0\\v8  \\f} \\f\\xB8D\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6C\\0\\0\\0\\0\\v8\\b  \\0} \\0\\xB8D\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6C\\0\\0\\0\\0\\v8\\f  \\r} \\r\\xB8D\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6C\\0\\0\\0\\0\\v8 \\v\\xEC\\x07\\x07\\x7F~	{}@ A\\0L@\\f\\v@ AF@\\f\\v A\\xFE\\xFF\\xFF\\xFF\\x07q!@  \\0 Atj"\\xFD]\\0" A\\fk\\xFD]\\0"\\xFD\\xB1 A\\bk\\xFD]\\0" Ak\\xFD]\\0"\\xFD\\xB1\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xB5\\xFD\\xAE\\xFD\\xA0\\xFD\\xC9\\xFD\\xCE!  \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xB5 \\xFD\\xAE Ak\\xFD]\\0\\xFD\\xAE  \\xFD\\xAEA\\xFD\\xAB\\xFD\\xB1\\xFD\\xA0\\xFD\\xC9\\xFD\\xCE!   \\xFD\\xB1\\xFD\\xA0\\xFD\\xC9\\xFD\\xCE!   A\\xFD\\xAB\\xFD\\xB1 \\xFD\\xAE\\xFD\\xA0\\xFD\\xC9\\xFD\\xCE!  \\xFD\\xA0\\xFD\\xC9\\xFD\\xCE! Aj" G\\r\\0\\v   \\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\0!   \\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\0!\\r   \\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\0!\\f   \\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\0!
   \\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\0!\\v  F\\r\\v@ 
 \\0 Atj"(\\0" A\\fk(\\0"	k A\\bk(\\0"\\b Ak(\\0"kAlj"\\x07 \\x07Au"\\x07s \\x07k\\xAD|!
 \\v Ak(\\0 \\bAl jj  	jAtk" Au"s k\\xAD|!\\v \\r  k" Au"s k\\xAD|!\\r \\f  Atk \\bj" Au"s k\\xAD|!\\f   Au"s k\\xAD|! Aj" G\\r\\0\\v\\v }\\x7F@ \\r \\f \\f \\rV\\x1B" 
 
 V\\x1B" \\v \\v V\\x1B T@A \\f 
 
 \\fV\\x1B" \\v \\v V\\x1B \\rZ\\r \\f 
 \\v 
 \\vT\\x1BV\\rA\\f\\vA\\0"\\0 PE\\rC\\0\\0\\0\\0\\f\\vAA 
 \\vV\\x1B\\v!\\0 \\xBAD\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6\\v8\\0  \\rP}C\\0\\0\\0\\0 \\r\\xBAD\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6\\v8  \\fP}C\\0\\0\\0\\0 \\f\\xBAD\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6\\v8\\b  
P}C\\0\\0\\0\\0 
\\xBAD\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6\\v8\\f  \\vP}C\\0\\0\\0\\0 \\v\\xBAD\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6\\v8 \\0\\v\\x8E
~\\x07\\x7F{}@@ } }@ }\\x7F@ }@ A}H\\r\\0 \\0Ak4\\0" B?\\x87"\\x85 }"\\bB\\x80\\x80\\x80\\x80\\bT!A!@@\\x7F A}F@A\\f\\v A\\0 \\0A\\fk4\\0" B?\\x87"\\x85 }"B\\xFF\\xFF\\xFF\\xFF\\x07X\\x1B!  \\b|!\\b  }" B?\\x87"\\x85 }! A~G\\rB\\0! B\\x80\\x80\\x80\\x80\\bT\\v!\\0A!A!\\f\\v \\0A\\bk4\\0"\\x07 B\\x86} |" B?\\x87"\\x85 }"
B\\x80\\x80\\x80\\x80\\bT! A\\0 \\x07 \\x07B?\\x87"\\x85 }"B\\xFF\\xFF\\xFF\\xFF\\x07X\\x1B!  \\b|!\\b \\x07 }" B?\\x87"\\x85 }"\\v |!  \\v\\x84B\\x80\\x80\\x80\\x80\\bT!A!@ A\\x7FF@B\\0! !B\\0!\\x07A!\\f\\v A\\0 \\0Ak4\\0" \\x07B\\x86} |"\\v \\vB?\\x87"\\v\\x85 \\v}"\\vB\\xFF\\xFF\\xFF\\xFF\\x07X\\x1B!  }  \\x07}B~|" B?\\x87"\\x85 }"B\\x80\\x80\\x80\\x80\\bT! 
 \\v|!
 A\\0  B?\\x87"\\x85 }"B\\xFF\\xFF\\xFF\\xFF\\x07X\\x1B! A\\0  \\x07}" B?\\x87"\\x85 }"B\\xFF\\xFF\\xFF\\xFF\\x07X\\x1B!  \\b|!\\b  |!B\\0!\\x07A\\0! !\\r\\x7F@@ \\0\\v\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD\\0!\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 
\\xFD\\0!\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD\\0!\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\b\\xFD\\0!\\x1B A~q!A\\0!\\r@ \\xFD\\f\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\0 \\rAtj")\\0\\xFD\\xFD\\xC7" A\\fk\\xFD\\0"\\xFD\\xD1 A\\bk\\xFD\\0"" Ak\\xFD\\0"\\xFD\\xD1\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xD5\\xFD\\xCE\\xFD\\xC0"\\xFD\\0B\\xFF\\xFF\\xFF\\xFF\\x07V\\x1BB\\x7FB\\0 \\xFDB\\xFF\\xFF\\xFF\\xFF\\x07V\\x1B\\xFD\\xFDP! \\xFD\\f\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 "\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\xD5 \\xFD\\xCE Ak\\xFD\\0\\xFD\\xCE  \\xFD\\xCEA\\xFD\\xCB\\xFD\\xD1\\xFD\\xC0"\\xFD\\0B\\xFF\\xFF\\xFF\\xFF\\x07V\\x1BB\\x7FB\\0 \\xFDB\\xFF\\xFF\\xFF\\xFF\\x07V\\x1B\\xFD\\xFDP!  \\xFD\\xCE!  \\xFD\\xCE!  \\xFD\\f\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0  \\xFD\\xD1\\xFD\\xC0"\\xFD\\0B\\xFF\\xFF\\xFF\\xFF\\x07V\\x1BB\\x7FB\\0 \\xFDB\\xFF\\xFF\\xFF\\xFF\\x07V\\x1B\\xFD\\xFDP!  \\xFD\\f\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0  A\\xFD\\xCB\\xFD\\xD1 "\\xFD\\xCE\\xFD\\xC0"\\xFD\\0B\\xFF\\xFF\\xFF\\xFF\\x07V\\x1BB\\x7FB\\0 \\xFDB\\xFF\\xFF\\xFF\\xFF\\x07V\\x1B\\xFD\\xFDP!  \\xFD\\xCE!  \\xFD\\xCE! !\\xFD\\f\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFF\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD\\xC0"\\xFD\\0B\\xFF\\xFF\\xFF\\xFF\\x07V\\x1BB\\x7FB\\0 \\xFDB\\xFF\\xFF\\xFF\\xFF\\x07V\\x1B\\xFD\\xFDP!!  \\x1B\\xFD\\xCE!\\x1B \\rAj"\\r G\\r\\0\\vA\\0  !A?\\xFD\\xCBA?\\xFD\\xCC\\xFDS\\x1B!A\\0   A?\\xFD\\xCBA?\\xFD\\xCC\\xFDS\\x1B!A\\0  A?\\xFD\\xCBA?\\xFD\\xCC\\xFDS\\x1B!A\\0  A?\\xFD\\xCBA?\\xFD\\xCC\\xFDS\\x1B!   \\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\0!\\x07   \\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\0!   \\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\0!
   \\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\0! \\x1B \\x1B \\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xCE\\xFD\\0!\\b A?\\xFD\\xCBA?\\xFD\\xCC\\xFDSAs"  F\\r Aq!\\r\\v@ \\rA\\0 \\0 Atj"\\rA\\bk4\\0"\\vB~ \\r4\\0"| \\rAk4\\0| \\rA\\fk4\\0"	 \\rAk4\\0"|B\\x86}"\\f \\fB?\\x87"\\f\\x85 \\f}"\\fB\\xFF\\xFF\\xFF\\xFF\\x07X\\x1B!\\r A\\0  	} \\v }B~|"	 	B?\\x87"	\\x85 	}"	B\\xFF\\xFF\\xFF\\xFF\\x07X\\x1B! \\x07 \\f|!\\x07  	|! A\\0  }"	 	B?\\x87"	\\x85 	}"	B\\xFF\\xFF\\xFF\\xFF\\x07X\\x1B! A\\0  B\\x86} \\v|" B?\\x87"\\x85 }"B\\xFF\\xFF\\xFF\\xFF\\x07X\\x1B!  	|!  
|!
 A\\0  B?\\x87"\\x85 }"B\\xFF\\xFF\\xFF\\xFF\\x07X\\x1B!  \\b|!\\b Aj" G\\r\\0\\v \\rA\\0G\\v! A\\0G!\\v A\\0G! A\\0G!\\0\\vB\\x7F!C\\0\\0\\bB!# }C\\0\\0\\bB E\\r\\0C\\0\\0\\bB \\bB\\x7FQ\\r\\0 \\bP\\r \\b"\\xBAD\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6\\v8\\0A!\\rA\\0 \\0  VqE\\r PE\\rC\\0\\0\\0\\0\\f\\vA\\0!\\r A\\x006\\0C\\0\\0\\bB\\v8C\\0\\0\\bB\\f\\v \\xBAD\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6!# !A\\v!  #8C\\0\\0\\bB!#C\\0\\0\\bB   
VqE\\r 
PE\\rA!\\rC\\0\\0\\0\\0\\v8\\bC\\0\\0\\bB\\f\\vA! 
"\\xBAD\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6\\v8\\b   VqE\\r PE\\rA!\\rC\\0\\0\\0\\0\\v8\\f C\\0\\0\\bB8 \\r\\v \\xBAD\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB6!#A! !\\v  #8\\f  \\x07V qE@ C\\0\\0\\bB8 \\v \\x07P@ C\\0\\0\\0\\x008A\\v  \\x07\\xBAD\\xEF9\\xFA\\xFEB.\\xE6?\\xA2 \\xB8\\xA3D\\xFE\\x82+eG\\xF7?\\xA2\\xB68A\\v\\x88;\\r~{\\x7F@ A\\rO@ A\\0L\\r \\xAD!\\x07A\\0! A\\rk!+@B\\0!@@@@@@@@@@@@@@@@@@@@@ +\\r\\f\\v
	\\b\\x07\\0\\v \\0 AtjA\\x80k4\\0 4|~!\\v \\0 AtjA\\xFC\\0k4\\0 4x~ |!\\v \\0 AtjA\\xF8\\0k4\\0 4t~ |!\\v \\0 AtjA\\xF4\\0k4\\0 4p~ |!\\v \\0 AtjA\\xF0\\0k4\\0 4l~ |!\\v \\0 AtjA\\xEC\\0k4\\0 4h~ |!\\v \\0 AtjA\\xE8\\0k4\\0 4d~ |!\\v \\0 AtjA\\xE4\\0k4\\0 4\\\`~ |!\\v \\0 AtjA\\xE0\\0k4\\0 4\\\\~ |!\\v \\0 AtjA\\xDC\\0k4\\0 4X~ |!\\v \\0 AtjA\\xD8\\0k4\\0 4T~ |!\\v \\0 AtjA\\xD4\\0k4\\0 4P~ |!\\v \\0 AtjA\\xD0\\0k4\\0 4L~ |!\\v \\0 AtjA\\xCC\\0k4\\0 4H~ |!\\v \\0 AtjA\\xC8\\0k4\\0 4D~ |!\\v \\0 AtjA\\xC4\\0k4\\0 4@~ |!\\v \\0 AtjA@j4\\0 4<~ |!\\v \\0 AtjA<k4\\0 48~ |!\\v \\0 AtjA8k4\\0 44~ |!\\v \\0 Atj"A4k4\\0 40~ | A0k4\\0 4,~| A,k4\\0 4(~| A(k4\\0 4$~| A$k4\\0 4 ~| A k4\\0 4~| Ak4\\0 4~| Ak4\\0 4~| Ak4\\0 4~| Ak4\\0 4\\f~| A\\fk4\\0 4\\b~| A\\bk4\\0 4~| Ak4\\0 4\\0~|!\\v  At"j \\0 j(\\0  \\x07\\x87\\xA7k6\\0 Aj" G\\r\\0\\v\\f\\v@@ A	O@ A\\vO@ A\\fG@ A\\0L\\r \\xAD! 4\\0!\\x07 4!\\b 4\\b!	 4\\f!
 4!\\v 4!\\f 4!\\r 4! 4 ! 4$! 4(!A\\0! AM\\r A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD! \\v\\xFD! \\f\\xFD! \\r\\xFD! \\xFD! \\xFD!\\x1B \\xFD! \\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0  A(k\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5  A,k\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE \\x1B A$k\\xFD\\0\\0" \\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A k\\xFD\\0\\0"!\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0""\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"#\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"$\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"%\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A\\fk\\xFD\\0\\0"&\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A\\bk\\xFD\\0\\0"'\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"(\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE \\xA7"\\xFD\\xCC  \\xFD\\xC8\\xFD\\xD5  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE \\x1B  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  !\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  "\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  #\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  $\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  %\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  &\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  '\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  (\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE \\xFD\\xCC\\xFD\\r\\0\\b	
\\v\\x1B\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  G\\r\\f\\v A\\0L\\r \\xAD! 4\\0!\\x07 4!\\b 4\\b!	 4\\f!
 4!\\v 4!\\f 4!\\r 4! 4 ! 4$! 4(! 4,!A\\0! AO@ A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD! \\v\\xFD! \\f\\xFD! \\r\\xFD! \\xFD! \\xFD!\\x1B \\xFD! \\xFD! \\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0  A,k\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5  A0k\\xFD\\0\\0" \\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A(k\\xFD\\0\\0"!\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE \\x1B A$k\\xFD\\0\\0""\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A k\\xFD\\0\\0"#\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"$\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"%\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"&\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"'\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A\\fk\\xFD\\0\\0"(\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A\\bk\\xFD\\0\\0")\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"*\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE \\xA7"\\xFD\\xCC  \\xFD\\xC8\\xFD\\xD5   \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  !\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE \\x1B "\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  #\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  $\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  %\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  &\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  '\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  (\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  )\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  *\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE \\xFD\\xCC\\xFD\\r\\0\\b	
\\v\\x1B\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\v@  At"j \\0 j"(\\0 A,k4\\0 ~ A0k4\\0 ~| A(k4\\0 ~| A$k4\\0 ~| A k4\\0 ~| Ak4\\0 \\r~| Ak4\\0 \\f~| Ak4\\0 \\v~| Ak4\\0 
~| A\\fk4\\0 	~| A\\bk4\\0 \\b~| Ak4\\0 \\x07~| \\x87\\xA7k6\\0 Aj" G\\r\\0\\v\\f\\v A
G@ A\\0L\\r \\xAD! 4\\0!\\x07 4!\\b 4\\b!	 4\\f!
 4!\\v 4!\\f 4!\\r 4! 4 !A\\0! AM\\r A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD! \\v\\xFD! \\f\\xFD! \\r\\xFD! \\xFD! \\xFD!\\x1BA\\0!@  At"j \\0 j"\\xFD\\0\\0  A k\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5 \\x1B A$k\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0" \\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"!\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A\\fk\\xFD\\0\\0""\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A\\bk\\xFD\\0\\0"#\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"$\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE \\xA7"\\xFD\\xCC  \\xFD\\xC8\\xFD\\xD5 \\x1B \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE   \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  !\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  "\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  #\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  $\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE \\xFD\\xCC\\xFD\\r\\0\\b	
\\v\\x1B\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  G\\r\\f\\v A\\0L\\r \\xAD! 4\\0!\\x07 4!\\b 4\\b!	 4\\f!
 4!\\v 4!\\f 4!\\r 4! 4 ! 4$!A\\0! AO@ A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD! \\v\\xFD! \\f\\xFD! \\r\\xFD! \\xFD! \\xFD!\\x1B \\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0 \\x1B A$k\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5  A(k\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A k\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0" \\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"!\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0""\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"#\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A\\fk\\xFD\\0\\0"$\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A\\bk\\xFD\\0\\0"%\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"&\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE \\xA7"\\xFD\\xCC \\x1B \\xFD\\xC8\\xFD\\xD5  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE   \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  !\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  "\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  #\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  $\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  %\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  &\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE \\xFD\\xCC\\xFD\\r\\0\\b	
\\v\\x1B\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\v@  At"j \\0 j"(\\0 A$k4\\0 ~ A(k4\\0 ~| A k4\\0 ~| Ak4\\0 \\r~| Ak4\\0 \\f~| Ak4\\0 \\v~| Ak4\\0 
~| A\\fk4\\0 	~| A\\bk4\\0 \\b~| Ak4\\0 \\x07~| \\x87\\xA7k6\\0 Aj" G\\r\\0\\v\\f\\v@@ AO@ A\\x07O@ A\\bG@ A\\0L\\r\\x07 \\xAD! 4\\0!\\x07 4!\\b 4\\b!	 4\\f!
 4!\\v 4!\\f 4!\\rA\\0! AM\\r A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD! \\v\\xFD! \\f\\xFD! \\r\\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5  Ak\\xFD\\0\\0"\\x1B\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A\\fk\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A\\bk\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0" \\xFD\\xC7\\xFD\\xD5\\xFD\\xCE \\xA7"\\xFD\\xCC  \\xFD\\xC8\\xFD\\xD5  \\x1B\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE   \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE \\xFD\\xCC\\xFD\\r\\0\\b	
\\v\\x1B\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  G\\r\\f\\x07\\v A\\0L\\r \\xAD! 4\\0!\\x07 4!\\b 4\\b!	 4\\f!
 4!\\v 4!\\f 4!\\r 4!A\\0! AO@ A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD! \\v\\xFD! \\f\\xFD! \\r\\xFD! \\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0  Ak\\xFD\\0\\0"\\x1B\\xFD\\xC7\\xFD\\xD5  A k\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A\\fk\\xFD\\0\\0" \\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A\\bk\\xFD\\0\\0"!\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0""\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE \\xA7"\\xFD\\xCC  \\x1B\\xFD\\xC8\\xFD\\xD5  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE   \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  !\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  "\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE \\xFD\\xCC\\xFD\\r\\0\\b	
\\v\\x1B\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\x07\\v@  At"j \\0 j"(\\0 Ak4\\0 \\r~ A k4\\0 ~| Ak4\\0 \\f~| Ak4\\0 \\v~| Ak4\\0 
~| A\\fk4\\0 	~| A\\bk4\\0 \\b~| Ak4\\0 \\x07~| \\x87\\xA7k6\\0 Aj" G\\r\\0\\v\\f\\v AG@ A\\0L\\r \\xAD! 4\\0!\\x07 4!\\b 4\\b!	 4\\f!
 4!\\vA\\0! AM\\r A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD! \\v\\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A\\fk\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A\\bk\\xFD\\0\\0"\\x1B\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE \\xA7"\\xFD\\xCC  \\xFD\\xC8\\xFD\\xD5  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\x1B\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE \\xFD\\xCC\\xFD\\r\\0\\b	
\\v\\x1B\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  G\\r\\f\\v A\\0L\\r \\xAD! 4\\0!\\x07 4!\\b 4\\b!	 4\\f!
 4!\\v 4!\\fA\\0! AO@ A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD! \\v\\xFD! \\f\\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"\\x1B\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A\\fk\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A\\bk\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE \\xA7"\\xFD\\xCC  \\xFD\\xC8\\xFD\\xD5  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\x1B\\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE \\xFD\\xCC\\xFD\\r\\0\\b	
\\v\\x1B\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\v@  At"j \\0 j"(\\0 Ak4\\0 \\v~ Ak4\\0 \\f~| Ak4\\0 
~| A\\fk4\\0 	~| A\\bk4\\0 \\b~| Ak4\\0 \\x07~| \\x87\\xA7k6\\0 Aj" G\\r\\0\\v\\f\\v@ AO@ AG@ A\\0L\\r\\x07 \\xAD! 4\\0!\\x07 4!\\b 4\\b!	A\\0! AM\\r A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0  A\\bk\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5  A\\fk\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE \\xA7"\\xFD\\xCC  \\xFD\\xC8\\xFD\\xD5  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE \\xFD\\xCC\\xFD\\r\\0\\b	
\\v\\x1B\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  G\\r\\f\\x07\\v A\\0L\\r \\xAD! 4\\0!\\x07 4!\\b 4\\b!	 4\\f!
A\\0! AO@ A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0  A\\fk\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  A\\bk\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE \\xA7"\\xFD\\xCC  \\xFD\\xC8\\xFD\\xD5  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE \\xFD\\xCC\\xFD\\r\\0\\b	
\\v\\x1B\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\x07\\v@  At"j \\0 j"(\\0 A\\fk4\\0 	~ Ak4\\0 
~| A\\bk4\\0 \\b~| Ak4\\0 \\x07~| \\x87\\xA7k6\\0 Aj" G\\r\\0\\v\\f\\v@ AG@ A\\0L\\r\\x07 \\xAD! 4\\0!\\x07A\\0! AM\\r A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5 \\xA7"\\xFD\\xCC  \\xFD\\xC8\\xFD\\xD5 \\xFD\\xCC\\xFD\\r\\0\\b	
\\v\\x1B\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  G\\r\\f\\x07\\v A\\0L\\r \\xAD! 4\\0!\\x07 4!\\bA\\0! AO@ A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0  Ak\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5  A\\bk\\xFD\\0\\0"\\xFD\\xC7\\xFD\\xD5\\xFD\\xCE \\xA7"\\xFD\\xCC  \\xFD\\xC8\\xFD\\xD5  \\xFD\\xC8\\xFD\\xD5\\xFD\\xCE \\xFD\\xCC\\xFD\\r\\0\\b	
\\v\\x1B\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\x07\\v@  At"j \\0 j"(\\0 Ak4\\0 \\x07~ A\\bk4\\0 \\b~| \\x87\\xA7k6\\0 Aj" G\\r\\0\\v\\f\\v@  At"j \\0 j"(\\0 Ak4\\0 \\x07~ \\x87\\xA7k6\\0 Aj" G\\r\\0\\v\\f\\v@  At"j \\0 j"(\\0 A\\bk4\\0 \\b~ A\\fk4\\0 	~| Ak4\\0 \\x07~| \\x87\\xA7k6\\0 Aj" G\\r\\0\\v\\f\\v@  At"j \\0 j"(\\0 Ak4\\0 
~ Ak4\\0 \\v~| A\\fk4\\0 	~| A\\bk4\\0 \\b~| Ak4\\0 \\x07~| \\x87\\xA7k6\\0 Aj" G\\r\\0\\v\\f\\v@  At"j \\0 j"(\\0 Ak4\\0 \\f~ Ak4\\0 \\r~| Ak4\\0 \\v~| Ak4\\0 
~| A\\fk4\\0 	~| A\\bk4\\0 \\b~| Ak4\\0 \\x07~| \\x87\\xA7k6\\0 Aj" G\\r\\0\\v\\f\\v@  At"j \\0 j"(\\0 A k4\\0 ~ A$k4\\0 ~| Ak4\\0 \\r~| Ak4\\0 \\f~| Ak4\\0 \\v~| Ak4\\0 
~| A\\fk4\\0 	~| A\\bk4\\0 \\b~| Ak4\\0 \\x07~| \\x87\\xA7k6\\0 Aj" G\\r\\0\\v\\f\\v@  At"j \\0 j"(\\0 A(k4\\0 ~ A,k4\\0 ~| A$k4\\0 ~| A k4\\0 ~| Ak4\\0 \\r~| Ak4\\0 \\f~| Ak4\\0 \\v~| Ak4\\0 
~| A\\fk4\\0 	~| A\\bk4\\0 \\b~| Ak4\\0 \\x07~| \\x87\\xA7k6\\0 Aj" G\\r\\0\\v\\v\\v\\xF4,\\r\\x7F\\f{@ A\\rO@ A\\0L\\r A\\rk!\\x07@A\\0!@@@@@@@@@@@@@@@@@@@@@ \\x07\\r\\f\\v
	\\b\\x07\\0\\v \\0 AtjA\\x80k(\\0 (|l!\\v \\0 AtjA\\xFC\\0k(\\0 (xl j!\\v \\0 AtjA\\xF8\\0k(\\0 (tl j!\\v \\0 AtjA\\xF4\\0k(\\0 (pl j!\\v \\0 AtjA\\xF0\\0k(\\0 (ll j!\\v \\0 AtjA\\xEC\\0k(\\0 (hl j!\\v \\0 AtjA\\xE8\\0k(\\0 (dl j!\\v \\0 AtjA\\xE4\\0k(\\0 (\\\`l j!\\v \\0 AtjA\\xE0\\0k(\\0 (\\\\l j!\\v \\0 AtjA\\xDC\\0k(\\0 (Xl j!\\v \\0 AtjA\\xD8\\0k(\\0 (Tl j!\\v \\0 AtjA\\xD4\\0k(\\0 (Pl j!\\v \\0 AtjA\\xD0\\0k(\\0 (Ll j!\\v \\0 AtjA\\xCC\\0k(\\0 (Hl j!\\v \\0 AtjA\\xC8\\0k(\\0 (Dl j!\\v \\0 AtjA\\xC4\\0k(\\0 (@l j!\\v \\0 AtjA@j(\\0 (<l j!\\v \\0 AtjA<k(\\0 (8l j!\\v \\0 AtjA8k(\\0 (4l j!\\v  \\0 Atj"A4k(\\0 (0lj A0k(\\0 (,lj A,k(\\0 ((lj A(k(\\0 ($lj A$k(\\0 ( lj A k(\\0 (lj Ak(\\0 (lj Ak(\\0 (lj Ak(\\0 (lj Ak(\\0 (\\flj A\\fk(\\0 (\\blj A\\bk(\\0 (lj Ak(\\0 (\\0lj!\\v  At"\\bj \\0 \\bj(\\0  uk6\\0 Aj" G\\r\\0\\v\\f\\v@@ A	O@ A\\vO@ A\\fG@ A\\0L\\r (\\0!\\x07 (!\\b (\\b!	 (\\f!
 (!\\v (!\\f (!\\r (! ( ! ($! ((! AM\\r A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD! \\v\\xFD! \\f\\xFD! \\r\\xFD! \\xFD! \\xFD!\\x1B \\xFD! \\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0 A(k\\xFD\\0\\0 \\xFD\\xB5 A,k\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A$k\\xFD\\0\\0 \\x1B\\xFD\\xB5\\xFD\\xAE A k\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A\\fk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A\\bk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE \\xFD\\xAC\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  G\\r\\f\\v A\\0L\\r (\\0!\\x07 (!\\b (\\b!	 (\\f!
 (!\\v (!\\f (!\\r (! ( ! ($! ((! (,! AO@ A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD! \\v\\xFD! \\f\\xFD! \\r\\xFD! \\xFD! \\xFD!\\x1B \\xFD! \\xFD! \\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0 A,k\\xFD\\0\\0 \\xFD\\xB5 A0k\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A(k\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A$k\\xFD\\0\\0 \\x1B\\xFD\\xB5\\xFD\\xAE A k\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A\\fk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A\\bk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE \\xFD\\xAC\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\v@  At"j \\0 j"(\\0 A,k(\\0 l A0k(\\0 lj A(k(\\0 lj A$k(\\0 lj A k(\\0 lj Ak(\\0 \\rlj Ak(\\0 \\flj Ak(\\0 \\vlj Ak(\\0 
lj A\\fk(\\0 	lj A\\bk(\\0 \\blj Ak(\\0 \\x07lj uk6\\0 Aj" G\\r\\0\\v\\f\\v A
G@ A\\0L\\r (\\0!\\x07 (!\\b (\\b!	 (\\f!
 (!\\v (!\\f (!\\r (! ( ! AM\\r A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD! \\v\\xFD! \\f\\xFD! \\r\\xFD! \\xFD! \\xFD!\\x1BA\\0!@  At"j \\0 j"\\xFD\\0\\0 A k\\xFD\\0\\0 \\xFD\\xB5 A$k\\xFD\\0\\0 \\x1B\\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A\\fk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A\\bk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE \\xFD\\xAC\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  G\\r\\f\\v A\\0L\\r (\\0!\\x07 (!\\b (\\b!	 (\\f!
 (!\\v (!\\f (!\\r (! ( ! ($! AO@ A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD! \\v\\xFD! \\f\\xFD! \\r\\xFD! \\xFD! \\xFD!\\x1B \\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0 A$k\\xFD\\0\\0 \\x1B\\xFD\\xB5 A(k\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A k\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A\\fk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A\\bk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE \\xFD\\xAC\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\v@  At"j \\0 j"(\\0 A$k(\\0 l A(k(\\0 lj A k(\\0 lj Ak(\\0 \\rlj Ak(\\0 \\flj Ak(\\0 \\vlj Ak(\\0 
lj A\\fk(\\0 	lj A\\bk(\\0 \\blj Ak(\\0 \\x07lj uk6\\0 Aj" G\\r\\0\\v\\f\\v@@ AO@ A\\x07O@ A\\bG@ A\\0L\\r\\x07 (\\0!\\x07 (!\\b (\\b!	 (\\f!
 (!\\v (!\\f (!\\r AM\\r A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD! \\v\\xFD! \\f\\xFD! \\r\\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0 Ak\\xFD\\0\\0 \\xFD\\xB5 Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A\\fk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A\\bk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE \\xFD\\xAC\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  G\\r\\f\\x07\\v A\\0L\\r (\\0!\\x07 (!\\b (\\b!	 (\\f!
 (!\\v (!\\f (!\\r (! AO@ A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD! \\v\\xFD! \\f\\xFD! \\r\\xFD! \\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0 Ak\\xFD\\0\\0 \\xFD\\xB5 A k\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A\\fk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A\\bk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE \\xFD\\xAC\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\x07\\v@  At"j \\0 j"(\\0 Ak(\\0 \\rl A k(\\0 lj Ak(\\0 \\flj Ak(\\0 \\vlj Ak(\\0 
lj A\\fk(\\0 	lj A\\bk(\\0 \\blj Ak(\\0 \\x07lj uk6\\0 Aj" G\\r\\0\\v\\f\\v AG@ A\\0L\\r (\\0!\\x07 (!\\b (\\b!	 (\\f!
 (!\\v AM\\r A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD! \\v\\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0 Ak\\xFD\\0\\0 \\xFD\\xB5 Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A\\fk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A\\bk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE \\xFD\\xAC\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  G\\r\\f\\v A\\0L\\r (\\0!\\x07 (!\\b (\\b!	 (\\f!
 (!\\v (!\\f AO@ A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD! \\v\\xFD! \\f\\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0 Ak\\xFD\\0\\0 \\xFD\\xB5 Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A\\fk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A\\bk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE \\xFD\\xAC\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\v@  At"j \\0 j"(\\0 Ak(\\0 \\vl Ak(\\0 \\flj Ak(\\0 
lj A\\fk(\\0 	lj A\\bk(\\0 \\blj Ak(\\0 \\x07lj uk6\\0 Aj" G\\r\\0\\v\\f\\v@ AO@ AG@ A\\0L\\r\\x07 (\\0!\\x07 (!\\b (\\b!	 AM\\r A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0 A\\bk\\xFD\\0\\0 \\xFD\\xB5 A\\fk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE \\xFD\\xAC\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  G\\r\\f\\x07\\v A\\0L\\r (\\0!\\x07 (!\\b (\\b!	 (\\f!
 AO@ A\\xFC\\xFF\\xFF\\xFF\\x07q! \\x07\\xFD! \\b\\xFD! 	\\xFD! 
\\xFD!A\\0!@  At"j \\0 j"\\xFD\\0\\0 A\\fk\\xFD\\0\\0 \\xFD\\xB5 Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE A\\bk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE Ak\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE \\xFD\\xAC\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\x07\\v@  At"j \\0 j"(\\0 A\\fk(\\0 	l Ak(\\0 
lj A\\bk(\\0 \\blj Ak(\\0 \\x07lj uk6\\0 Aj" G\\r\\0\\v\\f\\v@ AG@ A\\0L\\r\\x07 (\\0!A\\0! AM\\r A\\xFC\\xFF\\xFF\\xFF\\x07q! \\xFD!@  At"\\x07j \\0 \\x07j"\\x07\\xFD\\0\\0 \\x07Ak\\xFD\\0\\0 \\xFD\\xB5 \\xFD\\xAC\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  G\\r\\f\\x07\\v A\\0L\\r (\\0! (!\\x07A\\0! AO@ A\\xFC\\xFF\\xFF\\xFF\\x07q! \\xFD! \\x07\\xFD!@  At"\\bj \\0 \\bj"\\b\\xFD\\0\\0 \\bAk\\xFD\\0\\0 \\xFD\\xB5 \\bA\\bk\\xFD\\0\\0 \\xFD\\xB5\\xFD\\xAE \\xFD\\xAC\\xFD\\xB1\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\x07\\v@  At"j \\0 j"(\\0 Ak(\\0 l A\\bk(\\0 \\x07lj uk6\\0 Aj" G\\r\\0\\v\\f\\v@  At"j \\0 j"(\\0 Ak(\\0 l uk6\\0 Aj" G\\r\\0\\v\\f\\v@  At"j \\0 j"(\\0 A\\bk(\\0 \\bl A\\fk(\\0 	lj Ak(\\0 \\x07lj uk6\\0 Aj" G\\r\\0\\v\\f\\v@  At"j \\0 j"(\\0 Ak(\\0 
l Ak(\\0 \\vlj A\\fk(\\0 	lj A\\bk(\\0 \\blj Ak(\\0 \\x07lj uk6\\0 Aj" G\\r\\0\\v\\f\\v@  At"j \\0 j"(\\0 Ak(\\0 \\fl Ak(\\0 \\rlj Ak(\\0 \\vlj Ak(\\0 
lj A\\fk(\\0 	lj A\\bk(\\0 \\blj Ak(\\0 \\x07lj uk6\\0 Aj" G\\r\\0\\v\\f\\v@  At"j \\0 j"(\\0 A k(\\0 l A$k(\\0 lj Ak(\\0 \\rlj Ak(\\0 \\flj Ak(\\0 \\vlj Ak(\\0 
lj A\\fk(\\0 	lj A\\bk(\\0 \\blj Ak(\\0 \\x07lj uk6\\0 Aj" G\\r\\0\\v\\f\\v@  At"j \\0 j"(\\0 A(k(\\0 l A,k(\\0 lj A$k(\\0 lj A k(\\0 lj Ak(\\0 \\rlj Ak(\\0 \\flj Ak(\\0 \\vlj Ak(\\0 
lj A\\fk(\\0 	lj A\\bk(\\0 \\blj Ak(\\0 \\x07lj uk6\\0 Aj" G\\r\\0\\v\\v\\v\\xE83\\x7F|{\\b}@@@ AI A OqE@ E\\r At"@ A\\0 \\xFC\\v\\0\\v A~q!  kAj!\\x07@ \\0 Atj"\\b*\\0\\xBB!
A\\0!@ AG@ 
\\xFD!)@  Atj"	 ) \\b Atj\\xFD]\\0\\xFD_\\xFD\\xF2 	\\xFD\\0\\0\\xFD\\xF0\\xFD\\v\\0 Aj" G\\r\\0\\v " F\\r\\v@  Atj"	 
 \\b Atj*\\0\\xBB\\xA2 	+\\0\\xA09\\0 Aj" G\\r\\0\\v\\v Aj" \\x07G\\r\\0\\v\\f\\v A\\bM@ B\\x0078 \\0*\\f!: \\0*!; \\0*\\b!< \\0*!= \\0*!> \\0*!?  \\0*\\xBB"
 \\0*\\0\\xBB"\\v\\xA2"98  
 >\\xBB"\\f\\xA2 ?\\xBB"\\r \\v\\xA2\\xA0"90  
 <\\xBB"\\xA2 \\r \\f\\xA2 =\\xBB" \\v\\xA2\\xA0\\xA0"9(  
 :\\xBB"\\xA2 \\r \\xA2  \\f\\xA2 ;\\xBB" \\v\\xA2\\xA0\\xA0\\xA0"9   
 \\xA2 \\r \\xA2  \\xA2  \\f\\xA2  \\v\\xA2\\xA0\\xA0\\xA0\\xA0"9  
 \\xA2 \\r \\xA2  \\xA2  \\xA2  \\f\\xA2  \\v\\xA2\\xA0\\xA0\\xA0\\xA0\\xA0"9  
 \\r\\xA2 \\r \\xA2  \\xA2  \\xA2  \\xA2  \\f\\xA2 \\f \\v\\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0"9\\b  
 
\\xA2 \\r \\r\\xA2  \\xA2  \\xA2  \\xA2  \\xA2 \\f \\f\\xA2 \\v \\v\\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0"
9\\0 A	H\\r\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 
\\xFD"\\0!*\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!+\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!,\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!-\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!.\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!/\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!0\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!1 A\\bk"A~q!A\\0!@ \\0 Atj"A j\\xFD]\\0\\xFD_") Aj\\xFD]\\0\\xFD_\\xFD\\xF2 1\\xFD\\xF0!1 ) A\\bj\\xFD]\\0\\xFD_\\xFD\\xF2 0\\xFD\\xF0!0 ) A\\fj\\xFD]\\0\\xFD_\\xFD\\xF2 /\\xFD\\xF0!/ ) Aj\\xFD]\\0\\xFD_\\xFD\\xF2 .\\xFD\\xF0!. ) Aj\\xFD]\\0\\xFD_\\xFD\\xF2 -\\xFD\\xF0!- ) Aj\\xFD]\\0\\xFD_\\xFD\\xF2 ,\\xFD\\xF0!, ) Aj\\xFD]\\0\\xFD_\\xFD\\xF2 +\\xFD\\xF0!+ ) )\\xFD\\xF2 *\\xFD\\xF0!* Aj" G\\r\\0\\v * * )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0!\\v + + )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0!\\f , , )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0!\\r - - )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! . . )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! / / )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 0 0 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 1 1 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0!  G@ A\\bj!@ \\0 Atj"*\\0\\xBB"
 Ak*\\0\\xBB\\xA2 \\xA0! 
 Ak*\\0\\xBB\\xA2 \\xA0! 
 Ak*\\0\\xBB\\xA2 \\xA0! 
 Ak*\\0\\xBB\\xA2 \\xA0! 
 A\\fk*\\0\\xBB\\xA2 \\xA0! 
 A\\bk*\\0\\xBB\\xA2 \\r\\xA0!\\r 
 Ak*\\0\\xBB\\xA2 \\f\\xA0!\\f 
 
\\xA2 \\v\\xA0!\\v Aj" G\\r\\0\\v\\v  98  90  9(  9   9  \\r9  \\f9\\b  \\v9\\0\\v A8j! A\\rO@A\\0! A\\0A\\xC8\\0\\xFC\\v\\0 +P! +X!\\x1B +\\\`! +h! +p!  \\0*<\\xBB"
 \\0*$\\xBB"\\v\\xA2 \\0*8\\xBB"\\f \\0* \\xBB"\\xA2 \\0*4\\xBB"\\r \\0*\\xBB"\\xA2 \\0*0\\xBB" \\0*\\xBB"\\xA2 \\0*,\\xBB" \\0*\\xBB"\\xA2 \\0*(\\xBB" \\0*\\xBB"\\xA2 \\v \\0*\\f\\xBB"\\xA2  \\0*\\b\\xBB"\\xA2  \\0*\\xBB"\\xA2  \\0*\\0\\xBB"\\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0"90  
 \\xA2 \\f \\v\\xA2 \\r \\xA2  \\xA2  \\xA2  \\xA2 \\v \\xA2  \\xA2  \\xA2  \\xA2  \\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0" 9(  
 \\xA2 \\f \\xA2 \\r \\v\\xA2  \\xA2  \\xA2  \\xA2 \\v \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0"!9   
 \\xA2 \\f \\xA2 \\r \\xA2  \\v\\xA2  \\xA2  \\xA2 \\v \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0""9  
 \\r\\xA2 \\f \\xA2 \\r \\xA2  \\xA2  \\v\\xA2  \\xA2 \\v \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0"#9  
 \\f\\xA2 \\f \\r\\xA2 \\r \\xA2  \\xA2  \\xA2  \\v\\xA2 \\v \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0"$9\\b  
 
\\xA2 \\f \\f\\xA2 \\r \\r\\xA2  \\xA2  \\xA2  \\xA2 \\v \\v\\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0"%9\\0 \\0* !:  
 \\xA2  \\f \\xA2\\xA0\\xA0"9p  
 \\xA2 \\f \\xA2  \\r \\xA2\\xA0\\xA0\\xA0"9h  
 \\xA2 \\f \\xA2 \\r \\xA2   \\xA2\\xA0\\xA0\\xA0\\xA0"9\\\`  
 \\xA2 \\f \\xA2 \\r \\xA2  \\xA2 \\x1B  \\xA2\\xA0\\xA0\\xA0\\xA0\\xA0"\\x1B9X  
 \\xA2 \\f \\xA2 \\r \\xA2  \\xA2  \\xA2   \\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0"9P  
 \\xA2 \\f \\xA2 \\r \\xA2  \\xA2  \\xA2  \\xA2 \\v \\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0"&9H  
 \\xA2 \\f \\xA2 \\r \\xA2  \\xA2  \\xA2  \\xA2 \\v \\xA2  \\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0"'9@  
 \\xA2 +x\\xA0"(9x  
 :\\xBB\\xA2 \\f \\xA2 \\r \\xA2  \\xA2  \\xA2  \\xA2 \\v \\xA2  \\xA2  \\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0"
98 AL\\r\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 !\\xFD"\\0!*\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0  \\xFD"\\0!+\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!,\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 
\\xFD"\\0!-\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 '\\xFD"\\0!.\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 &\\xFD"\\0!/\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!0\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\x1B\\xFD"\\0!1\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!2\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!3\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 %\\xFD"\\0!4\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 $\\xFD"\\0!5\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 #\\xFD"\\0!6\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 "\\xFD"\\0!7\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!8\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 (\\xFD"\\0!9 Ak"A~q!@ \\0 Atj"A@k\\xFD]\\0\\xFD_") Aj\\xFD]\\0\\xFD_\\xFD\\xF2 9\\xFD\\xF0!9 ) A\\bj\\xFD]\\0\\xFD_\\xFD\\xF2 8\\xFD\\xF0!8 ) A\\fj\\xFD]\\0\\xFD_\\xFD\\xF2 3\\xFD\\xF0!3 ) Aj\\xFD]\\0\\xFD_\\xFD\\xF2 2\\xFD\\xF0!2 ) Aj\\xFD]\\0\\xFD_\\xFD\\xF2 1\\xFD\\xF0!1 ) Aj\\xFD]\\0\\xFD_\\xFD\\xF2 0\\xFD\\xF0!0 ) Aj\\xFD]\\0\\xFD_\\xFD\\xF2 /\\xFD\\xF0!/ ) A j\\xFD]\\0\\xFD_\\xFD\\xF2 .\\xFD\\xF0!. ) A$j\\xFD]\\0\\xFD_\\xFD\\xF2 -\\xFD\\xF0!- ) A(j\\xFD]\\0\\xFD_\\xFD\\xF2 ,\\xFD\\xF0!, ) A,j\\xFD]\\0\\xFD_\\xFD\\xF2 +\\xFD\\xF0!+ ) A0j\\xFD]\\0\\xFD_\\xFD\\xF2 *\\xFD\\xF0!* ) A4j\\xFD]\\0\\xFD_\\xFD\\xF2 7\\xFD\\xF0!7 ) A8j\\xFD]\\0\\xFD_\\xFD\\xF2 6\\xFD\\xF0!6 ) A<j\\xFD]\\0\\xFD_\\xFD\\xF2 5\\xFD\\xF0!5 ) )\\xFD\\xF2 4\\xFD\\xF0!4 Aj" G\\r\\0\\v * * )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0!\\v + + )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0!\\f , , )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0!\\r - - )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! . . )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! / / )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 0 0 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 1 1 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 2 2 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 3 3 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 4 4 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 5 5 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 6 6 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 7 7 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 8 8 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 9 9 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0!  G@ Aj!@ \\0 Atj"*\\0\\xBB"
 A<k*\\0\\xBB\\xA2 \\xA0! 
 A8k*\\0\\xBB\\xA2 \\xA0! 
 A4k*\\0\\xBB\\xA2 \\xA0! 
 A0k*\\0\\xBB\\xA2 \\xA0! 
 A,k*\\0\\xBB\\xA2 \\xA0! 
 A(k*\\0\\xBB\\xA2 \\xA0! 
 A$k*\\0\\xBB\\xA2 \\xA0! 
 A k*\\0\\xBB\\xA2 \\xA0! 
 Ak*\\0\\xBB\\xA2 \\xA0! 
 Ak*\\0\\xBB\\xA2 \\r\\xA0!\\r 
 Ak*\\0\\xBB\\xA2 \\f\\xA0!\\f 
 Ak*\\0\\xBB\\xA2 \\v\\xA0!\\v 
 A\\fk*\\0\\xBB\\xA2 \\xA0! 
 A\\bk*\\0\\xBB\\xA2 \\xA0! 
 Ak*\\0\\xBB\\xA2 \\xA0! 
 
\\xA2 \\xA0! Aj" G\\r\\0\\v\\v  9x  9p  9h  9\\\`  9X  9P  9H  9@  98  \\r90  \\f9(  \\v9   9  9  9\\b  9\\0\\v B\\x007  \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\0 \\0*!: \\0*!; \\0*!< \\0*!= \\0*\\f!> \\0* !? \\0*\\b!@ \\0*$!A  \\0*,\\xBB"
 \\0*\\xBB"\\v\\xA2 \\0*(\\xBB"\\f \\0*\\0\\xBB"\\r\\xA2 +P\\xA0\\xA0"9P  
 @\\xBB"\\xA2 \\f \\v\\xA2 A\\xBB" \\r\\xA2\\xA0\\xA0"9H  
 >\\xBB"\\xA2 \\f \\xA2  \\v\\xA2 ?\\xBB" \\r\\xA2\\xA0\\xA0\\xA0"9@  
 <\\xBB"\\xA2 \\f \\xA2  \\xA2  \\v\\xA2 =\\xBB" \\r\\xA2\\xA0\\xA0\\xA0\\xA0"98  
 :\\xBB"\\xA2 \\f \\xA2  \\xA2  \\xA2  \\v\\xA2 ;\\xBB" \\r\\xA2\\xA0\\xA0\\xA0\\xA0\\xA0"90  
 \\xA2 \\f \\xA2  \\xA2  \\xA2  \\xA2  \\v\\xA2  \\r\\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0"\\x1B9(  
 \\xA2 \\f \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\v\\xA2  \\r\\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0"9   
 \\xA2 \\f \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\v\\xA2  \\r\\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0"9  
 \\xA2 \\f \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\v\\xA2  \\r\\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0"9  
 \\f\\xA2 \\f \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\v\\xA2 \\v \\r\\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0"9\\b  
 
\\xA2 \\f \\f\\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2  \\xA2 \\v \\v\\xA2 \\r \\r\\xA2\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0\\xA0"\\v9\\0  
 \\r\\xA2 +X\\xA0"
9X A\\rH\\r\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\v\\xFD"\\0!*\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!+\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!,\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!-\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!.\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\x1B\\xFD"\\0!/\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!0\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!1\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!2\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!3\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 \\xFD"\\0!4\\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0 
\\xFD"\\0!5 A\\fk"A~q!A\\0!@ \\0 Atj"A0j\\xFD]\\0\\xFD_") Aj\\xFD]\\0\\xFD_\\xFD\\xF2 5\\xFD\\xF0!5 ) A\\bj\\xFD]\\0\\xFD_\\xFD\\xF2 4\\xFD\\xF0!4 ) A\\fj\\xFD]\\0\\xFD_\\xFD\\xF2 3\\xFD\\xF0!3 ) Aj\\xFD]\\0\\xFD_\\xFD\\xF2 2\\xFD\\xF0!2 ) Aj\\xFD]\\0\\xFD_\\xFD\\xF2 1\\xFD\\xF0!1 ) Aj\\xFD]\\0\\xFD_\\xFD\\xF2 0\\xFD\\xF0!0 ) Aj\\xFD]\\0\\xFD_\\xFD\\xF2 /\\xFD\\xF0!/ ) A j\\xFD]\\0\\xFD_\\xFD\\xF2 .\\xFD\\xF0!. ) A$j\\xFD]\\0\\xFD_\\xFD\\xF2 -\\xFD\\xF0!- ) A(j\\xFD]\\0\\xFD_\\xFD\\xF2 ,\\xFD\\xF0!, ) A,j\\xFD]\\0\\xFD_\\xFD\\xF2 +\\xFD\\xF0!+ ) )\\xFD\\xF2 *\\xFD\\xF0!* Aj" G\\r\\0\\v * * )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0!\\v + + )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0!\\f , , )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0!\\r - - )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! . . )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! / / )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 0 0 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 1 1 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 2 2 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 3 3 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 4 4 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0! 5 5 )\\xFD\\r\\b	
\\v\\f\\r\\0\\x07\\xFD\\xF0\\xFD!\\0!  G@ A\\fj!@ \\0 Atj"*\\0\\xBB"
 A,k*\\0\\xBB\\xA2 \\xA0! 
 A(k*\\0\\xBB\\xA2 \\xA0! 
 A$k*\\0\\xBB\\xA2 \\xA0! 
 A k*\\0\\xBB\\xA2 \\xA0! 
 Ak*\\0\\xBB\\xA2 \\xA0! 
 Ak*\\0\\xBB\\xA2 \\xA0! 
 Ak*\\0\\xBB\\xA2 \\xA0! 
 Ak*\\0\\xBB\\xA2 \\xA0! 
 A\\fk*\\0\\xBB\\xA2 \\xA0! 
 A\\bk*\\0\\xBB\\xA2 \\r\\xA0!\\r 
 Ak*\\0\\xBB\\xA2 \\f\\xA0!\\f 
 
\\xA2 \\v\\xA0!\\v Aj" G\\r\\0\\v\\v  9X  9P  9H  9@  98  90  9(  9   9  \\r9  \\f9\\b  \\v9\\0\\f\\vA Aj" AM\\x1B!\\v  M\\r\\0  k!@ \\0 Atj"\\b*\\0\\xBB!
A\\0!@ AO@ A~q! 
\\xFD!)A\\0!@  Atj"\\x07 ) \\b Atj\\xFD]\\0\\xFD_\\xFD\\xF2 \\x07\\xFD\\0\\0\\xFD\\xF0\\xFD\\v\\0 Aj" G\\r\\0\\v  F\\r\\vA  AM\\x1B!@  Atj"\\x07 
 \\b Atj*\\0\\xBB\\xA2 \\x07+\\0\\xA09\\0 Aj" G\\r\\0\\v\\v Ak! Aj" G\\r\\0\\v\\v\\v\\x93\\x7F@ E@ -\\x000\\r@ ((" j" (,"\\0L@ ($!\\0\\f\\vA\\x80 \\0 \\0A\\x80L\\x1B!\\0@ \\0"At!\\0  H\\r\\0\\v ($ !\\0  6,  \\x006$ ((!\\v @ \\0 j  \\xFC
\\0\\0\\v  (( j6(\\f\\v A:\\x000@ (" j" ("\\0L@ (\\f!\\0\\f\\vA\\x80  \\0 \\0A\\x80 L\\x1B!\\0@ \\0"At!\\0  H\\r\\0\\v (\\f !\\0  6  \\x006\\f (!\\v @ \\0 j  \\xFC
\\0\\0\\v  ( j6@ (" ( "\\0H@ (!\\0\\f\\v (A \\0At \\0AH\\x1B"At!\\0  6   \\x006 (!\\v \\0 Atj"\\0 6 \\0 6\\0  Aj6\\vA\\0\\v\\xDF\\x07\\x7F~ \\0(4 l"A\\0 A\\0J\\x1B!\\x07A  \\0(8k!\\v@  \\x07F@@ \\0A\\x006 \\0A\\x006 \\0(\\0"\\r(\\0"(\\0\\r\\0A\\x80\\x80\\x80\\x80xA  (k"u!A\\xFF\\xFF\\xFF\\xFF\\x07 v! \\0(! ("A|q! Aq! A~q! Aq! ($"\\bAj! \\b\\xADB|!\\x1B \\r(! AI!@@ \\r(\\0"\\f(@ (\\xA0
!	@  (\\xC4\\x07k"  k"\\0 \\0 K\\x1B"E\\r\\0 @ A\\xFC	j!  l!A\\0!
@A\\0!\\0@ AG@@ 	At"\\x07  \\0Atj"\\v(\\0j  Atj"(\\x006\\0 \\v( \\x07j (6\\0 Aj! \\0Aj"\\0 G\\r\\0\\v E\\r\\v  \\0Atj(\\0 	Atj  Atj(\\x006\\0 Aj!\\v 	Aj!	 
Aj"
 G\\r\\0\\v\\f\\v 	 j!	\\v  	6\\xA0
\\v  K!
@  M (\\xC4\\x07"\\0 \\bKr\\r\\0@ E@  A\\x7Fsj\\xAD" \\x1B \\0Aj\\xAD}"B\\0  \\x1BX\\x1B"  V\\x1B\\xA7"Aj"A IA~ \\0k Ir\\r \\0 Apq"j!\\0  j!  G\\r  K!
\\f\\v@A\\0!@  Atj(\\0" H  Jr\\r (\\0 Atj(\\0 \\0Atj 6\\0 Aj! Aj" G\\r\\0\\v Aj" I!
 \\0Aj"\\0 \\bK\\r  K\\r\\0\\v\\f\\v@ Aj" I!
 \\0Aj"\\0 \\bK\\r  K\\r\\0\\v\\v  \\x006\\xC4\\x07 \\0 \\bK@ \\rA\\0OE\\r \\r(!@ E\\r\\0 (\\0!\\vA\\0!\\0A\\0! E@@ \\v Atj"\\f(\\0"  \\bAt"\\x07j(\\x006\\0 \\f("  \\x07j(\\x006\\0 \\f(\\b"  \\x07j(\\x006\\0 \\f(\\f"  \\x07j(\\x006\\0 Aj" G\\r\\0\\v E\\r\\v@ \\v Atj(\\0"  \\bAtj(\\x006\\0 Aj! \\0Aj"\\0 G\\r\\0\\v\\v A6\\xC4\\x07\\v 
\\r\\0\\vA\\0\\v \\fA6\\0\\v \\0( Atj" (\\0 \\vu6\\0 Aj!\\f\\v\\vA\\x7F\\v\\xED\\x7FAA<"\\x7F  68  \\x0064@AA\\b"@ AA\\x80"6\\0 @ AA\\xD8
"6 @ AA\\xC0\\xEB\\0"\\x076\\0 \\x07@ \\x07AA "\\b6\\x90J \\b\\r \\x07	\\v 	\\v 	\\v 	\\v 	A\\0\\v A6\\xE4 A\\x80\\x80\\x80\\xF860 \\xFD\\fD\\xAC\\0\\0\\0\\0\\0\\0\\0\\0\\0\\r\\0\\0\\0\\xFD\\v  \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\0 A6\\xD4
 \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v 9 (\\0AF@ B\\x80\\x80\\x80\\x80\\xD0\\x007\\xC0 \\xFD\\f\\b\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xAC\\v A\\x006\\xD0
 (\\0" A\\xA8j6\\xE8D (\\0" A\\xD8j6\\xECD (\\0" A\\x88\\bj6\\xF0D (\\0" A\\xB8\\vj6\\xF4D (\\0" A\\xE8j6\\xF8D (\\0" A\\x98j6\\xFCD (\\0" A\\xC8j6\\x80E (\\0" A\\xF8j6\\x84E (\\0" A\\xA8j6\\x88E (\\0" A\\xD8j6\\x8CE (\\0" A\\x88#j6\\x90E (\\0" A\\xB8&j6\\x94E (\\0" A\\xE8)j6\\x98E (\\0" A\\x98-j6\\x9CE (\\0" A\\xC80j6\\xA0E (\\0" A\\xF83j6\\xA4E (\\0" A\\xA87j6\\xA8E (\\0" A\\xD8:j6\\xACE (\\0" A\\x88>j6\\xB0E (\\0" A\\xB8\\xC1\\0j6\\xB4E (\\0" A\\xB8\\xC5\\0j6\\xB8H (\\0" A\\xC4\\xC5\\0j6\\xBCH (\\0" A\\xD0\\xC5\\0j6\\xC0H (\\0" A\\xDC\\xC5\\0j6\\xC4H (\\0" A\\xE8\\xC5\\0j6\\xC8H (\\0" A\\xF4\\xC5\\0j6\\xCCH (\\0" A\\x80\\xC6\\0j6\\xD0H (\\0" A\\x8C\\xC6\\0j6\\xD4H (\\0" A\\x98\\xC6\\0j6\\xD8H (\\0" A\\xA4\\xC6\\0j6\\xDCH (\\0" A\\xB0\\xC6\\0j6\\xE0H (\\0" A\\xBC\\xC6\\0j6\\xE4H (\\0" A\\xC8\\xC6\\0j6\\xE8H (\\0" A\\xD4\\xC6\\0j6\\xECH (\\0" A\\xE0\\xC6\\0j6\\xF0H (\\0" A\\xEC\\xC6\\0j6\\xF4H (\\0" A\\xF8\\xC6\\0j6\\xF8H (\\0" A\\x84\\xC7\\0j6\\xFCH (\\0" A\\x90\\xC7\\0j6\\x80I (\\0" A\\x9C\\xC7\\0j6\\x84I ("(\\0A\\xB8\\xC5\\0jA\\0A\\xCC\\xFC\\v\\0 (\\0"A\\x84\\xC7\\0jA\\0A$\\xFC\\v\\0 B\\x007\\xB0k \\xFD\\f\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\xFD\\v\\xA0k  6\\0@ (\\0"(\\0AG\\r\\0  6   \\x006  6 B7 9 (\\0"\\0(\\0AG\\r\\0 \\0B\\x80\\x80\\x80\\x80\\xD0\\x007\\xC0 \\0B\\x007\\xB4 \\0B\\b7\\xAC \\0A\\x006\\v  R@ (\\0"\\0@ \\0(A6\\xD0
 \\0S \\0("(\\xF0	"\\x7F P ("(\\xD8\\b"\\x7F 	 ( \\v(,"(\\0	 	 ("(x	 (|	 A\\x006\\x80 B\\x007x ("(\\x84	 (\\x88	 A\\x006\\x8C B\\x007\\x84 ("(\\x90	 (\\x94	 A\\x006\\x98 B\\x007\\x90 ("(\\x9C	 (\\xA0	 A\\x006\\xA4 B\\x007\\x9C ("(\\xA8	 (\\xAC	 A\\x006\\xB0 B\\x007\\xA8 ("(\\xB4	 (\\xB8	 A\\x006\\xBC B\\x007\\xB4 ("(\\xC0	 (\\xC4	 A\\x006\\xC8 B\\x007\\xC0 ("(\\xCC	 (\\xD0	 A\\x006\\xD4 B\\x007\\xCC (	 (\\0	 	 \\0( \\v(\\0"(\\xB8E	 (\\xBCE	 A\\x006\\xC0E B\\x007\\xB8E \\0((\\0"(\\xC4E	 (\\xC8E	 A\\x006\\xCCE B\\x007\\xC4E \\0((\\0"(\\xD0E	 (\\xD4E	 A\\x006\\xD8E B\\x007\\xD0E \\0((\\0"(\\xDCE	 (\\xE0E	 A\\x006\\xE4E B\\x007\\xDCE \\0((\\0"(\\xE8E	 (\\xECE	 A\\x006\\xF0E B\\x007\\xE8E \\0((\\0"(\\xF4E	 (\\xF8E	 A\\x006\\xFCE B\\x007\\xF4E \\0((\\0"(\\x80F	 (\\x84F	 A\\x006\\x88F B\\x007\\x80F \\0((\\0"(\\x8CF	 (\\x90F	 A\\x006\\x94F B\\x007\\x8CF \\0((\\0"(\\x98F	 (\\x9CF	 A\\x006\\xA0F B\\x007\\x98F \\0((\\0"(\\xA4F	 (\\xA8F	 A\\x006\\xACF B\\x007\\xA4F \\0((\\0"(\\xB0F	 (\\xB4F	 A\\x006\\xB8F B\\x007\\xB0F \\0((\\0"(\\xBCF	 (\\xC0F	 A\\x006\\xC4F B\\x007\\xBCF \\0((\\0"(\\xC8F	 (\\xCCF	 A\\x006\\xD0F B\\x007\\xC8F \\0((\\0"(\\xD4F	 (\\xD8F	 A\\x006\\xDCF B\\x007\\xD4F \\0((\\0"(\\xE0F	 (\\xE4F	 A\\x006\\xE8F B\\x007\\xE0F \\0((\\0"(\\xECF	 (\\xF0F	 A\\x006\\xF4F B\\x007\\xECF \\0((\\0"(\\xF8F	 (\\xFCF	 A\\x006\\x80G B\\x007\\xF8F \\0((\\0"(\\x84G	 (\\x88G	 A\\x006\\x8CG B\\x007\\x84G \\0((\\0"(\\x90G	 (\\x94G	 A\\x006\\x98G B\\x007\\x90G \\0((\\0"(\\x9CG	 (\\xA0G	 A\\x006\\xA4G B\\x007\\x9CG \\0((\\0"(\\xA0k	 (\\xA4k	 A\\x006\\xA8k B\\x007\\xA0k \\0((\\0"(\\xACk	 (\\xB0k	 A\\x006\\xB4k B\\x007\\xACk \\0((\\0(\\x90J"(\\0	 	 \\0((\\0	 \\0(	 \\0(\\0	 \\0	\\v 	A\\0\\v A\\0\\v\\v\\x07\\0 \\0(\\f\\v\\x07\\0 \\0((\\v\\x07\\0 \\0($\\v\\0 \\0( Atj(\\0\\v\\0 \\0( Atj(\\v\\x07\\0 \\0(\\v.\\x7F \\0(! \\0(\\b H@  ! \\0 6\\b \\0 6\\v \\v:\\0 \\0A\\x006 \\0A\\x006 \\0(\\0SE@A\\x7F\\v \\0A\\0:\\x000 \\0A\\x006(A\\x7FA\\0 \\0(\\0 \\0R\\x1B\\v\\0#\\0\\v\\0#\\0 \\0kApq"\\0$\\0 \\0\\v\\0 \\0$\\0\\v\\0\\0\\v\\r\\0 \\0A\\x80j\\0\\0\\v\\0\\0\\v\\0~\\0\\vh\\x7F \\0D\\0\\0\\0\\0\\0\\0\\0\\0@A\\x98\\xF1\\0(\\0A\\x1BAA \\0AF\\x1B \\0AF\\x1B"\\0AkvAq@A\\x98\\xF2\\0A\\x98\\xF2\\0(\\0A \\0Aktr6\\0\\f\\v \\0At(\\x80T"@ \\0 \\0\\v\\v\\v\\0B\\0\\v\\0A\\0\\v\\v\\0 \\0(<,\\v5\\x7F@ \\0At" A\\xE0\\xD8\\0j"6\\xE4X  6\\xE8X \\0Aj"\\0A\\xC0\\0G\\r\\0\\vA0N\\v\\v\\xCFM\\0A\\x80\\b\\vp\\xFE\\x82+eGg@\\0\\0\\0\\0\\0\\x008C\\0\\0\\xFA\\xFEB.v\\xBF:;\\x9E\\xBC\\x9A\\xF7\\f\\xBD\\xBD\\xFD\\xFF\\xFF\\xFF\\xFF\\xDF?<TUUUU\\xC5?\\x91+\\xCFUU\\xA5?\\xD0\\xA4g\\x81?\\0\\0\\0\\0\\0\\0\\xC8B\\xEF9\\xFA\\xFEB.\\xE6?$\\xC4\\x82\\xFF\\xBD\\xBF\\xCE?\\xB5\\xF4\\f\\xD7\\bk\\xAC?\\xCCPF\\xD2\\xAB\\xB2\\x83?\\x84:N\\x9B\\xE0\\xD7U?\\0A\\xFE\\b\\v\\xF8\\xF0?n\\xBF\\x88O;\\x9B<53\\xFB\\xA9=\\xF6\\xEF?]\\xDC\\xD8\\x9C\\\`q\\xBCa\\x80w>\\x9A\\xEC\\xEF?\\xD1f\\x87z^\\x90\\xBC\\x85\\x7Fn\\xE8\\xE3\\xEF?\\xF6g5R\\xD2\\x8C<t\\x85\\xD3\\xB0\\xD9\\xEF?\\xFA\\x8E\\xF9#\\x80\\xCE\\x8B\\xBC\\xDE\\xF6\\xDD)k\\xD0\\xEF?a\\xC8\\xE6aN\\xF7\\\`<\\xC8\\x9BuE\\xC7\\xEF?\\x99\\xD33[\\xE4\\xA3\\x90<\\x83\\xF3\\xC6\\xCA>\\xBE\\xEF?m{\\x83]\\xA6\\x9A\\x97<\\x89\\xF9lX\\xB5\\xEF?\\xFC\\xEF\\xFD\\x92\\xB5\\x8E<\\xF7Gr+\\x92\\xAC\\xEF?\\xD1\\x9C/p=\\xBE><\\xA2\\xD1\\xD32\\xEC\\xA3\\xEF?\\vn\\x90\\x894j\\xBC\\x1B\\xD3\\xFE\\xAFf\\x9B\\xEF?\\xBD/*RV\\x95\\xBCQ[\\xD0\\x93\\xEF?U\\xEAN\\x8C\\xEF\\x80P\\xBC\\xCC1l\\xC0\\xBD\\x8A\\xEF?\\xF4\\xD5\\xB9#\\xC9\\x91\\xBC\\xE0-\\xA9\\xAE\\x9A\\x82\\xEF?\\xAFU\\\\\\xE9\\xE3\\xD3\\x80<Q\\x8E\\xA5\\xC8\\x98z\\xEF?H\\x93\\xA5\\xEA\\x1B\\x80\\xBC{Q}<\\xB8r\\xEF?=2\\xDEU\\xF0\\x8F\\xBC\\xEA\\x8D\\x8C8\\xF9j\\xEF?\\xBFS?\\x8C\\x89\\x8B<u\\xCBo\\xEB[c\\xEF?&\\xEBv\\x9C\\xD9\\x96\\xBC\\xD4\\\\\\x84\\xE0[\\xEF?\\\`/:>\\xF7\\xEC\\x9A<\\xAA\\xB9h1\\x87T\\xEF?\\x9D8\\x86\\xCB\\x82\\xE7\\x8F\\xBC\\xD9\\xFC"PM\\xEF?\\x8D\\xC3\\xA6DAo\\x8A<\\xD6\\x8Cb\\x88;F\\xEF?}\\xE4\\xB0z\\x80<\\x96\\xDC}\\x91I?\\xEF?\\x94\\xA8\\xA8\\xE3\\xFD\\x8E\\x96<8bunz8\\xEF?}Ht\\xF2^\\x87<?\\xA6\\xB2O\\xCE1\\xEF?\\xF2\\xE7\\x98+G\\x80<\\xDD|\\xE2eE+\\xEF?^\\bq?{\\xB8\\x96\\xBC\\x81c\\xF5\\xE1\\xDF$\\xEF?1\\xAB	m\\xE1\\xF7\\x82<\\xE1\\xDE\\xF5\\x9D\\xEF?\\xFA\\xBFo\\x9B!=\\xBC\\x90\\xD9\\xDA\\xD0\\x7F\\xEF?\\xB4
\\fr\\x827\\x8B<\\v\\xE4\\xA6\\x85\\xEF?\\x8F\\xCB\\xCE\\x89\\x92n<V/>\\xA9\\xAF\\f\\xEF?\\xB6\\xAB\\xB0MuM\\x83<\\xB71
\\xFE\\xEF?Lt\\xAC\\xE2B\\x86<1\\xD8L\\xFCp\\xEF?J\\xF8\\xD3]9\\xDD\\x8F<\\xFFd\\xB2\\b\\xFC\\xEE?[\\x8E;\\x80\\xA3\\x86\\xBC\\xF1\\x9F\\x92_\\xC5\\xF6\\xEE?hPK\\xCC\\xEDJ\\x92\\xBC\\xCB\\xA9:7\\xA7\\xF1\\xEE?\\x8E-Q\\x1B\\xF8\\x07\\x99\\xBCf\\xD8m\\xAE\\xEC\\xEE?\\xD26\\x94>\\xE8\\xD1q\\xBC\\xF7\\x9F\\xE54\\xDB\\xE7\\xEE?\\x1B\\xCE\\xB3\\x99\\xBC\\xE5\\xA8\\xC3-\\xE3\\xEE?mL*\\xA7H\\x9F\\x85<"4L\\xA6\\xDE\\xEE?\\x8Ai(z\\\`\\x93\\xBC\\x80\\xACE\\xDA\\xEE?[\\x89H\\x8F\\xA7X\\xBC*.\\xF7!
\\xD6\\xEE?\\x1B\\x9AIg\\x9B,|\\xBC\\x97\\xA8P\\xD9\\xF5\\xD1\\xEE?\\xAC\\xC2\\\`\\xEDcC<-\\x89a\\\`\\b\\xCE\\xEE?\\xEFd;	f\\x96<W\\0\\xEDA\\xCA\\xEE?y\\xA1\\xDA\\xE1\\xCCn<\\xD0<\\xC1\\xB5\\xA2\\xC6\\xEE?0?\\x8E\\xFF\\x93<\\xDE\\xD3\\xD7\\xF0*\\xC3\\xEE?\\xB0\\xAFz\\xBB\\xCE\\x90v<'*6\\xD5\\xDA\\xBF\\xEE?w\\xE0T\\xEB\\xBD\\x93<\\r\\xDD\\xFD\\x99\\xB2\\xBC\\xEE?\\x8E\\xA3q\\x004\\x94\\x8F\\xBC\\xA7,\\x9Dv\\xB2\\xB9\\xEE?I\\xA3\\x93\\xDC\\xCC\\xDE\\x87\\xBCBf\\xCF\\xA2\\xDA\\xB6\\xEE?_8\\xBD\\xC6\\xDEx\\xBC\\x82O\\x9DV+\\xB4\\xEE?\\xF6\\\\{\\xECF\\x86\\xBC\\x92]\\xCA\\xA4\\xB1\\xEE?\\x8E\\xD7\\xFD5\\x93<\\xDA'\\xB56G\\xAF\\xEE?\\x9B\\x8A/\\xB7\\x98{<\\xFD\\xC7\\x97\\xD4\\xAD\\xEE?	T\\xE2\\xE1c\\x90<)TH\\xDD\\x07\\xAB\\xEE?\\xEA\\xC6P\\x85\\xC74<\\xB7FY\\x8A&\\xA9\\xEE?5\\xC0d+\\xE62\\x94<H!\\xADo\\xA7\\xEE?\\x9Fv\\x99aJ\\xE4\\x8C\\xBC	\\xDCv\\xB9\\xE1\\xA5\\xEE?\\xA8M\\xEF;\\xC53\\x8C\\xBC\\x85U:\\xB0~\\xA4\\xEE?\\xAE\\xE9+\\x89xS\\x84\\xBC \\xC3\\xCC4F\\xA3\\xEE?XXVx\\xDD\\xCE\\x93\\xBC%"U\\x828\\xA2\\xEE?d~\\x80\\xAAW<s\\xA9L\\xD4U\\xA1\\xEE?("^\\xBF\\xEF\\xB3\\x93\\xBC\\xCD;\\x7Ff\\x9E\\xA0\\xEE?\\x82\\xB94\\x87\\xADj\\xBC\\xBF\\xDA\\vu\\xA0\\xEE?\\xEE\\xA9m\\xB8\\xEFgc\\xBC/e<\\xB2\\x9F\\xEE?Q\\x88\\xE0T=\\xDC\\x80\\xBC\\x84\\x94Q\\xF9}\\x9F\\xEE?\\xCF>Z~dx\\xBCt_\\xEC\\xE8u\\x9F\\xEE?\\xB0}\\x8B\\xC0J\\xEE\\x86\\xBCt\\x81\\xA5H\\x9A\\x9F\\xEE?\\x8A\\xE6U2\\x86\\xBC\\xC9gBV\\xEB\\x9F\\xEE?\\xD3\\xD4	^\\xCB\\x9C\\x90<?]\\xDEOi\\xA0\\xEE?\\xA5M\\xB9\\xDC2{\\xBC\\x87\\xEBs\\xA1\\xEE?k\\xC0gT\\xFD\\xEC\\x94<2\\xC10\\xED\\xA1\\xEE?Ul\\xD6\\xAB\\xE1\\xEBe<bN\\xCF6\\xF3\\xA2\\xEE?B\\xCF\\xB3/\\xC5\\xA1\\x88\\xBC>T'\\xA4\\xEE?47;\\xF1\\xB6i\\x93\\xBC\\xCEL\\x99\\x89\\xA5\\xEE?\\xFF:\\x84^\\x80\\xBC\\xAD\\xC7#F\\xA7\\xEE?nWr\\xD8P\\xD4\\x94\\xBC\\xED\\x92D\\x9B\\xD9\\xA8\\xEE?\\0\\x8A[g\\xAD\\x90<\\x99f\\x8A\\xD9\\xC7\\xAA\\xEE?\\xB4\\xEA\\xF0\\xC1/\\xB7\\x8D<\\xDB\\xA0*B\\xE5\\xAC\\xEE?\\xFF\\xE7\\xC5\\x9C\\\`\\xB6e\\xBC\\x8CD\\xB52\\xAF\\xEE?D_\\xF3Y\\x83\\xF6{<6w\\x99\\xAE\\xB1\\xEE?\\x83=\\xA7	\\x93\\xBC\\xC6\\xFF\\x91\\v[\\xB4\\xEE?)l\\x8B\\xB8\\xA9]\\xBC\\xE5\\xC5\\xCD\\xB07\\xB7\\xEE?Y\\xB9\\x90|\\xF9#l\\xBCR\\xC8\\xCBD\\xBA\\xEE?\\xAA\\xF9\\xF4"CC\\x92\\xBCPN\\xDE\\x9F\\x82\\xBD\\xEE?K\\x8Ef\\xD7l\\xCA\\x85\\xBC\\xBA\\x07\\xCAp\\xF1\\xC0\\xEE?'\\xCE\\x91+\\xFC\\xAFq<\\x90\\xF0\\xA3\\x82\\x91\\xC4\\xEE?\\xBBs
\\xE15\\xD2m<##\\xE3c\\xC8\\xEE?c"b"\\xC5\\x87\\xBCe\\xE5]{f\\xCC\\xEE?\\xD51\\xE2\\xE3\\x86\\x8B<3-J\\xEC\\x9B\\xD0\\xEE?\\xBB\\xBC\\xD3\\xD1\\xBB\\x91\\xBC]%>\\xB2\\xD5\\xEE?\\xD21\\xEE\\x9C1\\xCC\\x90<X\\xB30\\x9E\\xD9\\xEE?\\xB3Zsn\\x84i\\x84<\\xBF\\xFDyUk\\xDE\\xEE?\\xB4\\x9D\\x8E\\x97\\xCD\\xDF\\x82\\xBCz\\xF3\\xD3\\xBFk\\xE3\\xEE?\\x873\\xCB\\x92w\\x8C<\\xAD\\xD3Z\\x99\\x9F\\xE8\\xEE?\\xFA\\xD9\\xD1J\\x8F{\\x90\\xBCf\\xB6\\x8D)\\x07\\xEE\\xEE?\\xBA\\xAE\\xDCV\\xD9\\xC3U\\xBC\\xFBO\\xB8\\xA2\\xF3\\xEE?@\\xF6\\xA6=\\xA4\\x90\\xBC:Y\\xE5\\x8Dr\\xF9\\xEE?4\\x93\\xAD8\\xF4\\xD6h\\xBCG^\\xFB\\xF2v\\xFF\\xEE?5\\x8AXk\\xE2\\xEE\\x91\\xBCJ\\xA10\\xB0\\xEF?\\xCD\\xDD_
\\xD7\\xFFt<\\xD2\\xC1K\\x90\\f\\xEF?\\xAC\\x98\\x92\\xFA\\xFB\\xBD\\x91\\xBC	\\xD7[\\xC2\\xEF?\\xB3\\f\\xAF0\\xAEns<\\x9CR\\x85\\xDD\\x9B\\xEF?\\x94\\xFD\\x9F\\\\2\\xE3\\x8E<z\\xD0\\xFF_\\xAB \\xEF?\\xACY	\\xD1\\x8F\\xE0\\x84<K\\xD1W.\\xF1'\\xEF?gN8\\xAF\\xCDc<\\xB5\\xE7\\x94m/\\xEF?h\\x92l,kg<i\\x90\\xEF\\xDC 7\\xEF?\\xD2\\xB5\\xCC\\x83\\x8A\\x80\\xBC\\xFA\\xC3]U\\v?\\xEF?o\\xFA\\xFF?]\\xAD\\x8F\\xBC|\\x89\\x07J-G\\xEF?I\\xA9u8\\xAE\\r\\x90\\xBC\\xF2\\x89\\r\\b\\x87O\\xEF?\\xA7\\x07=\\xA6\\x85\\xA3t<\\x87\\xA4\\xFB\\xDCX\\xEF?"@ \\x9E\\x91\\x82\\xBC\\x98\\x83\\xC9\\xE3\\\`\\xEF?\\xAC\\x92\\xC1\\xD5PZ\\x8E<\\x852\\xDB\\xE6i\\xEF?Kk\\xACY:\\x84<\\\`\\xB4\\xF3!s\\xEF?>\\xB4\\x07!\\xD5\\x82\\xBC_\\x9B{3\\x97|\\xEF?\\xC9\\rG;\\xB9*\\x89\\xBC)\\xA1\\xF5F\\x86\\xEF?\\xD3\\x88:\\\`\\xB6t<\\xF6?\\x8B\\xE7.\\x90\\xEF?qr\\x9DQ\\xEC\\xC5\\x83<\\x83L\\xC7\\xFBQ\\x9A\\xEF?\\xF0\\x91\\xD3\\x8F\\xF7\\x8F\\xBC\\xDA\\x90\\xA4\\xA2\\xAF\\xA4\\xEF?}t#\\xE2\\x98\\xAE\\x8D\\xBC\\xF1g\\x8E-H\\xAF\\xEF?\\b \\xAAA\\xBC\\xC3\\x8E<'Za\\xEE\\x1B\\xBA\\xEF?2\\xEB\\xA9\\xC3\\x94+\\x84<\\x97\\xBAk7+\\xC5\\xEF?\\xEE\\x85\\xD11\\xA9d\\x8A<@En[v\\xD0\\xEF?\\xED\\xE3;\\xE4\\xBA7\\x8E\\xBC\\xBE\\x9C\\xAD\\xFD\\xDB\\xEF?\\x9D\\xCD\\x91M;\\x89w<\\xD8\\x90\\x9E\\x81\\xC1\\xE7\\xEF?\\x89\\xCC\\\`A\\xC1S<\\xF1q\\x8F+\\xC2\\xF3\\xEF?infinity\\0bartlett\\0connes\\0flattop\\0bartlett_hann\\0nan\\0blackman\\0nuttall\\0kaiser_bessel\\0welch\\0image/png\\0hamming\\0rectangle\\0triangle\\0blackman_harris_4term_92db\\0-->\\0reference libFLAC git-3f1ecff8 20260304\\0tukey(5e-1)\\0punchout_tukey(\\0partial_tukey(\\0subdivide_tukey(\\0gauss(\\0A\\x81\\x1B\\v\\x83\\x07	\\x1B8?61$#*-pw~ylkbeHOFATSZ]\\xE0\\xE7\\xEE\\xE9\\xFC\\xFB\\xF2\\xF5\\xD8\\xDF\\xD6\\xD1\\xC4\\xC3\\xCA\\xCD\\x90\\x97\\x9E\\x99\\x8C\\x8B\\x82\\x85\\xA8\\xAF\\xA6\\xA1\\xB4\\xB3\\xBA\\xBD\\xC7\\xC0\\xC9\\xCE\\xDB\\xDC\\xD5\\xD2\\xFF\\xF8\\xF1\\xF6\\xE3\\xE4\\xED\\xEA\\xB7\\xB0\\xB9\\xBE\\xAB\\xAC\\xA5\\xA2\\x8F\\x88\\x81\\x86\\x93\\x94\\x9D\\x9A' ).;<52\\r
WPY^KLEBohafst}z\\x89\\x8E\\x87\\x80\\x95\\x92\\x9B\\x9C\\xB1\\xB6\\xBF\\xB8\\xAD\\xAA\\xA3\\xA4\\xF9\\xFE\\xF7\\xF0\\xE5\\xE2\\xEB\\xEC\\xC1\\xC6\\xCF\\xC8\\xDD\\xDA\\xD3\\xD4ing\\\`ur{|QV_XMJCD\\v\\f!&/(=:34NI@GRU\\\\[vqx\\x7Fjmdc>907"%,+\\b\\xAE\\xA9\\xA0\\xA7\\xB2\\xB5\\xBC\\xBB\\x96\\x91\\x98\\x9F\\x8A\\x8D\\x84\\x83\\xDE\\xD9\\xD0\\xD7\\xC2\\xC5\\xCC\\xCB\\xE6\\xE1\\xE8\\xEF\\xFA\\xFD\\xF4\\xF3fLaC\\0A\\x92\\v\\xA56\\x80\\x80
\\0\\x1B\\x80\\0\\0\\x803\\x806\\0<\\x009\\x80(\\0-\\x80'\\x80"\\0c\\x80f\\0l\\0i\\x80x\\0}\\x80w\\x80r\\0P\\0U\\x80_\\x80Z\\0K\\x80N\\0D\\0A\\x80\\xC3\\x80\\xC6\\0\\xCC\\0\\xC9\\x80\\xD8\\0\\xDD\\x80\\xD7\\x80\\xD2\\0\\xF0\\0\\xF5\\x80\\xFF\\x80\\xFA\\0\\xEB\\x80\\xEE\\0\\xE4\\0\\xE1\\x80\\xA0\\0\\xA5\\x80\\xAF\\x80\\xAA\\0\\xBB\\x80\\xBE\\0\\xB4\\0\\xB1\\x80\\x93\\x80\\x96\\0\\x9C\\0\\x99\\x80\\x88\\0\\x8D\\x80\\x87\\x80\\x82\\0\\x83\\x81\\x86\\x8C\\x89\\x81\\x98\\x9D\\x81\\x97\\x81\\x92\\xB0\\xB5\\x81\\xBF\\x81\\xBA\\xAB\\x81\\xAE\\xA4\\xA1\\x81\\xE0\\xE5\\x81\\xEF\\x81\\xEA\\xFB\\x81\\xFE\\xF4\\xF1\\x81\\xD3\\x81\\xD6\\xDC\\xD9\\x81\\xC8\\xCD\\x81\\xC7\\x81\\xC2@E\\x81O\\x81J[\\x81^TQ\\x81s\\x81v|y\\x81hm\\x81g\\x81b#\\x81&,)\\x818=\\x817\\x812\\x81\\x81\\v\\x81\\x81\\x83\\f	\\x83\\x83\\x8305\\x83?\\x83:+\\x83.$!\\x83\\\`e\\x83o\\x83j{\\x83~tq\\x83S\\x83V\\\\Y\\x83HM\\x83G\\x83B\\xC0\\xC5\\x83\\xCF\\x83\\xCA\\xDB\\x83\\xDE\\xD4\\xD1\\x83\\xF3\\x83\\xF6\\xFC\\xF9\\x83\\xE8\\xED\\x83\\xE7\\x83\\xE2\\xA3\\x83\\xA6\\xAC\\xA9\\x83\\xB8\\xBD\\x83\\xB7\\x83\\xB2\\x90\\x95\\x83\\x9F\\x83\\x9A\\x8B\\x83\\x8E\\x84\\x81\\x83\\x80\\x85\\x82\\x8F\\x82\\x8A\\x9B\\x82\\x9E\\x94\\x91\\x82\\xB3\\x82\\xB6\\xBC\\xB9\\x82\\xA8\\xAD\\x82\\xA7\\x82\\xA2\\xE3\\x82\\xE6\\xEC\\xE9\\x82\\xF8\\xFD\\x82\\xF7\\x82\\xF2\\xD0\\xD5\\x82\\xDF\\x82\\xDA\\xCB\\x82\\xCE\\xC4\\xC1\\x82C\\x82FLI\\x82X]\\x82W\\x82Rpu\\x82\\x7F\\x82zk\\x82nda\\x82 %\\x82/\\x82*;\\x82>41\\x82\\x82\\x82\\b\\r\\x82\\x07\\x82\\0\\0\\x86\\x8C\\0
\\x98\\0\\0\\x92\\xB0\\x006\\0<\\xBA\\0(\\xAE\\xA4\\0"\\xE0\\0f\\0l\\xEA\\0x\\xFE\\xF4\\0r\\0P\\xD6\\xDC\\0Z\\xC8\\0N\\0D\\xC2@\\0\\xC6\\0\\xCCJ\\0\\xD8^T\\0\\xD2\\0\\xF0v|\\0\\xFAh\\0\\xEE\\0\\xE4b\\0\\xA0&,\\0\\xAA8\\0\\xBE\\0\\xB42\\0\\x96\\0\\x9C\\0\\x88\\0\\x82\\x80\\f\\x8A\\x9E\\x940\\xB6\\xBC:\\xA8.$\\xA2\\\`\\xE6\\xECj\\xF8~t\\xF2\\xD0V\\\\\\xDAH\\xCE\\xC4B\\xC0FL\\xCAX\\xDE\\xD4Rp\\xF6\\xFCz\\xE8nd\\xE2 \\xA6\\xAC*\\xB8>4\\xB2\\x90\\x9A\\b\\x8E\\x84	\\x80

\\f	\\x8A
	\\x9E	\\x94

0	\\xB6	\\xBC
:	\\xA8
.
$	\\xA2
\\\`	\\xE6	\\xEC
j	\\xF8
~
t	\\xF2	\\xD0
V
\\\\	\\xDA
H	\\xCE	\\xC4
B
\\xC0	F	L
\\xCA	X
\\xDE
\\xD4	R	p
\\xF6
\\xFC	z
\\xE8	n	d
\\xE2	 
\\xA6
\\xAC	*
\\xB8	>	4
\\xB2
\\x90		
\\x9A	\\b
\\x8E
\\x84	\\0\\f\\x86\\f\\x8C
\\f\\x98\\f\\x92\\f\\xB06<\\f\\xBA(\\f\\xAE\\f\\xA4"\\f\\xE0fl\\f\\xEAx\\f\\xFE\\f\\xF4rP\\f\\xD6\\f\\xDCZ\\f\\xC8ND\\f\\xC2\\f@\\xC6\\xCC\\fJ\\xD8\\f^\\fT\\xD2\\xF0\\fv\\f|\\xFA\\fh\\xEE\\xE4\\fb\\xA0\\f&\\f,\\xAA\\f8\\xBE\\xB4\\f2\\f\\x96\\x9C\\f\\x88\\f\\f\\x82\\0\\0\\x80+\\x80<\\0S\\x80D\\0x\\0o\\x80\\xA3\\x80\\xB4\\0\\x88\\0\\x9F\\x80\\xF0\\0\\xE7\\x80\\xDB\\x80\\xCC\\0C\\x81Th\\x7F\\x81\\x07\\x81;\\x81,\\xE0\\xF7\\x81\\xCB\\x81\\xDC\\xB3\\x81\\xA4\\x98\\x8F\\x81\\x83\\x82\\x94\\xA8\\xBF\\x82\\xD0\\xC7\\x82\\xFB\\x82\\xEC 7\\x82\\v\\x82s\\x82dXO\\x82\\xC0\\xD7\\x83\\xEB\\x83\\xFC\\x93\\x83\\x84\\xB8\\xAF\\x83c\\x83tH_\\x830'\\x83\\x1B\\x83\\f\\x85(?\\x85PG\\x85{\\x85l\\xA0\\xB7\\x85\\x8B\\x85\\x9C\\xF3\\x85\\xE4\\xD8\\xCF\\x85@W\\x84k\\x84|\\x848/\\x84\\xE3\\x84\\xF4\\xC8\\xDF\\x84\\xB0\\xA7\\x84\\x9B\\x84\\x8C\\x80\\x07\\x97\\x87\\xAB\\x87\\xBC\\x07\\xD3\\x87\\xC4\\x07\\xF8\\x07\\xEF\\x87#\\x874\\x07\\b\\x07\\x87p\\x07g\\x87[\\x87L\\x07\\xC3\\x86\\xD4\\xE8\\xFF\\x86\\x90\\x87\\x86\\xBB\\x86\\xAC\\\`w\\x86K\\x86\\\\3\\x86$\\x86\\x8A
(
?\\x8AP
G\\x8A{\\x8Al
\\xA0
\\xB7\\x8A\\x8B\\x8A\\x9C
\\xF3\\x8A\\xE4
\\xD8
\\xCF\\x8A@\\vW\\x8Bk\\x8B|\\v\\x8B\\v8\\v/\\x8B\\xE3\\x8B\\xF4\\v\\xC8\\v\\xDF\\x8B\\xB0\\v\\xA7\\x8B\\x9B\\x8B\\x8C\\v\\x80\\b\\x97\\x88\\xAB\\x88\\xBC\\b\\xD3\\x88\\xC4\\b\\xF8\\b\\xEF\\x88#\\x884\\b\\b\\b\\x88p\\bg\\x88[\\x88L\\b\\xC3\\x89\\xD4	\\xE8	\\xFF\\x89\\x90	\\x87\\x89\\xBB\\x89\\xAC	\\\`	w\\x89K\\x89\\\\	3\\x89$		\\x89\\0\\x8F+\\x8F<S\\x8FDxo\\x8F\\xA3\\x8F\\xB4\\x88\\x9F\\x8F\\xF0\\xE7\\x8F\\xDB\\x8F\\xCCC\\x8ETh\\x7F\\x8E\\x07\\x8E;\\x8E,\\xE0\\xF7\\x8E\\xCB\\x8E\\xDC\\xB3\\x8E\\xA4\\x98\\x8F\\x8E\\x83\\x8D\\x94\\r\\xA8\\r\\xBF\\x8D\\xD0\\r\\xC7\\x8D\\xFB\\x8D\\xEC\\r \\r7\\x8D\\v\\x8D\\rs\\x8Dd\\rX\\rO\\x8D\\xC0\\f\\xD7\\x8C\\xEB\\x8C\\xFC\\f\\x93\\x8C\\x84\\f\\xB8\\f\\xAF\\x8Cc\\x8Ct\\fH\\f_\\x8C0\\f'\\x8C\\x1B\\x8C\\f\\f\\0\\0\\x94\\xA8\\0<\\xD0\\0D\\0x\\xEC \\0\\xB4\\0\\x88\\0\\xF0dX\\0\\xCC@\\xD4\\xE8|\\x908\\xAC\\\`\\xF4\\xC8\\\\\\xB0$\\x8C\\f\\x80(\\f\\xBCP\\f\\xC4\\f\\xF8l\\xA0\\f4\\f\\b\\x9C\\fp\\xE4\\xD8\\fL
\\xC0	T	h
\\xFC	
\\x84
\\xB8	,	\\xE0
t
H	\\xDC
0	\\xA4	\\x98
\\f\\x80(\\xBCP\\xC4\\xF8l\\xA04\\b\\x9Cp\\xE4\\xD8L\\x1B\\xC0Th\\x1B\\xFC\\x1B\\x84\\x1B\\xB8,\\xE0\\x1Bt\\x1BH\\xDC\\x1B0\\xA4\\x98\\x1B\\f\\0\\x94\\xA8<\\xD0Dx\\xEC \\xB4\\x88\\xF0dX\\xCC@\\xD4\\xE8|\\x908\\xAC\\\`\\xF4\\xC8\\\\\\xB0$\\x8C?\\x80<<(?\\xBC<P?\\xC4?\\xF8<l<\\xA0?4?\\b<\\x9C?p<\\xE4<\\xD8?L9\\xC0:T:h9\\xFC:9\\x849\\xB8:,:\\xE09t9H:\\xDC90:\\xA4:\\x989\\f3\\x000\\x940\\xA83<0\\xD03D3x0\\xEC0 3\\xB43\\x8803\\xF00d0X3\\xCC5@6\\xD46\\xE85|6\\x905586\\xAC6\\\`5\\xF45\\xC86\\\\5\\xB06$65\\x8C"\\0!\\x94!\\xA8"<!\\xD0"D"x!\\xEC! "\\xB4"\\x88!"\\xF0!d!X"\\xCC$@'\\xD4'\\xE8$|'\\x90$$8'\\xAC'\\\`$\\xF4$\\xC8'\\\\$\\xB0'$'$\\x8C.\\x80--(.\\xBC-P.\\xC4.\\xF8-l-\\xA0.4.\\b-\\x9C.p-\\xE4-\\xD8.L(\\xC0+T+h(\\xFC+(\\x84(\\xB8+,+\\xE0(t(H+\\xDC(0+\\xA4+\\x98(\\f\\0\\0{\\x80\\xF3\\x80\\x88\\0\\xE3\\x81\\x98k\\x81\\xC3\\x83\\xB80K\\x83 [\\x82\\xD3\\x82\\xA8\\x83\\x87\\xF8\\x07p\\x07\\v\\x87\\\`\\x1B\\x86\\x93\\x86\\xE8@;\\x84\\xB3\\x84\\xC8\\xA3\\x85\\xD8P+\\x85\\x8Fx\\xF0\\x8B\\x8F\\xE0\\x9B\\x8E\\x8Eh\\xC0\\f\\xBB\\x8C3\\x8CH\\f#\\x8DX\\r\\xD0\\r\\xAB\\x8D\\x80\\b\\xFB\\x88s\\x88\\b\\bc\\x89	\\x90	\\xEB\\x89C\\x8B8\\v\\xB0\\v\\xCB\\x8B\\xA0
\\xDB\\x8AS\\x8A(
\\x9Ex\\xF0\\x8B\\x9E\\xE0\\x9B\\x9F\\x9Fh\\xC0\\xBB\\x9D3\\x9DH#\\x9CX\\xD0\\xAB\\x9C\\x80\\xFB\\x99s\\x99\\bc\\x98\\x90\\xEB\\x98C\\x9A8\\xB0\\xCB\\x9A\\xA0\\x1B\\xDB\\x9BS\\x9B(\\x1B\\0{\\x91\\xF3\\x91\\x88\\xE3\\x90\\x98k\\x90\\xC3\\x92\\xB80K\\x92 [\\x93\\xD3\\x93\\xA8\\x83\\x96\\xF8p\\v\\x96\\\`\\x1B\\x97\\x93\\x97\\xE8@;\\x95\\xB3\\x95\\xC8\\xA3\\x94\\xD8P+\\x94\\xBCx<\\xF0<\\x8B\\xBC\\xE0=\\x9B\\xBD\\xBDh=\\xC0?\\xBB\\xBF3\\xBFH?#\\xBEX>\\xD0>\\xAB\\xBE\\x80;\\xFB\\xBBs\\xBB\\b;c\\xBA:\\x90:\\xEB\\xBAC\\xB888\\xB08\\xCB\\xB8\\xA09\\xDB\\xB9S\\xB9(9\\x003{\\xB3\\xF3\\xB3\\x883\\xE3\\xB2\\x9822k\\xB2\\xC3\\xB0\\xB8000K\\xB0 1[\\xB1\\xD3\\xB1\\xA81\\x83\\xB4\\xF84p4\\v\\xB4\\\`5\\x1B\\xB5\\x93\\xB5\\xE85@7;\\xB7\\xB3\\xB7\\xC87\\xA3\\xB6\\xD86P6+\\xB6\\0"{\\xA2\\xF3\\xA2\\x88"\\xE3\\xA3\\x98##k\\xA3\\xC3\\xA1\\xB8!0!K\\xA1  [\\xA0\\xD3\\xA0\\xA8 \\x83\\xA5\\xF8%p%\\v\\xA5\\\`$\\x1B\\xA4\\x93\\xA4\\xE8$@&;\\xA6\\xB3\\xA6\\xC8&\\xA3\\xA7\\xD8'P'+\\xA7\\xADx-\\xF0-\\x8B\\xAD\\xE0,\\x9B\\xAC\\xACh,\\xC0.\\xBB\\xAE3\\xAEH.#\\xAFX/\\xD0/\\xAB\\xAF\\x80*\\xFB\\xAAs\\xAA\\b*c\\xAB+\\x90+\\xEB\\xABC\\xA98)\\xB0)\\xCB\\xA9\\xA0(\\xDB\\xA8S\\xA8((\\0\\0\\xF8p\\0\\x88\\xE0\\x90h	@
\\xB8
0	\\xC8\\xA0\\fX\\f\\xD0(\\x80x\\xF0\\b\\\`\\x98\\xE8\\x1B\\xC08\\xB0\\x1BH \\xD8P\\xA8!\\x80"x"\\xF0!\\b'\\\`$\\x98$'\\xE8(\\xC0+8+\\xB0(H. -\\xD8-P.\\xA83\\x000\\xF80p3\\x885\\xE066\\x905h:@9\\xB890:\\xC8<\\xA0?X?\\xD0<(G\\x80DxD\\xF0G\\bA\\\`B\\x98BA\\xE8N\\xC0M8M\\xB0NHH K\\xD8KPH\\xA8U\\0V\\xF8VpU\\x88S\\xE0PP\\x90Sh\\\\@_\\xB8_0\\\\\\xC8Z\\xA0YXY\\xD0Z(f\\0e\\xF8epf\\x88\\\`\\xE0cc\\x90\\\`ho@l\\xB8l0o\\xC8i\\xA0jXj\\xD0i(t\\x80wxw\\xF0t\\br\\\`q\\x98qr\\xE8}\\xC0~8~\\xB0}H{ x\\xD8xP{\\xA8\\x8B\\x80\\x88x\\x88\\xF0\\x8B\\b\\x8D\\\`\\x8E\\x98\\x8E\\x8D\\xE8\\x82\\xC0\\x818\\x81\\xB0\\x82H\\x84 \\x87\\xD8\\x87P\\x84\\xA8\\x99\\0\\x9A\\xF8\\x9Ap\\x99\\x88\\x9F\\xE0\\x9C\\x9C\\x90\\x9Fh\\x90@\\x93\\xB8\\x930\\x90\\xC8\\x96\\xA0\\x95X\\x95\\xD0\\x96(\\xAA\\0\\xA9\\xF8\\xA9p\\xAA\\x88\\xAC\\xE0\\xAF\\xAF\\x90\\xACh\\xA3@\\xA0\\xB8\\xA00\\xA3\\xC8\\xA5\\xA0\\xA6X\\xA6\\xD0\\xA5(\\xB8\\x80\\xBBx\\xBB\\xF0\\xB8\\b\\xBE\\\`\\xBD\\x98\\xBD\\xBE\\xE8\\xB1\\xC0\\xB28\\xB2\\xB0\\xB1H\\xB7 \\xB4\\xD8\\xB4P\\xB7\\xA8\\xCC\\0\\xCF\\xF8\\xCFp\\xCC\\x88\\xCA\\xE0\\xC9\\xC9\\x90\\xCAh\\xC5@\\xC6\\xB8\\xC60\\xC5\\xC8\\xC3\\xA0\\xC0X\\xC0\\xD0\\xC3(\\xDE\\x80\\xDDx\\xDD\\xF0\\xDE\\b\\xD8\\\`\\xDB\\x98\\xDB\\xD8\\xE8\\xD7\\xC0\\xD48\\xD4\\xB0\\xD7H\\xD1 \\xD2\\xD8\\xD2P\\xD1\\xA8\\xED\\x80\\xEEx\\xEE\\xF0\\xED\\b\\xEB\\\`\\xE8\\x98\\xE8\\xEB\\xE8\\xE4\\xC0\\xE78\\xE7\\xB0\\xE4H\\xE2 \\xE1\\xD8\\xE1P\\xE2\\xA8\\xFF\\0\\xFC\\xF8\\xFCp\\xFF\\x88\\xF9\\xE0\\xFA\\xFA\\x90\\xF9h\\xF6@\\xF5\\xB8\\xF50\\xF6\\xC8\\xF0\\xA0\\xF3X\\xF3\\xD0\\xF0(\\0\\0\\x81#\\x820C\\x84P\\\`s\\x87\\x83\\x88\\x90	\\xA0
\\xB3\\x8B\\xC0\\f\\xD3\\x8D\\xE3\\x8E\\xF0\\x91 3\\x92@S\\x94c\\x97p\\x80\\x93\\x98\\xA3\\x9B\\xB0\\xC3\\x9D\\xD0\\xE0\\xF3\\x9E\\xA2#  3\\xA1@&S\\xA7c\\xA4p%\\x80*\\x93\\xAB\\xA3\\xA8\\xB0)\\xC3\\xAE\\xD0/\\xE0,\\xF3\\xAD\\x003\\xB2#\\xB100C\\xB7P6\\\`5s\\xB4\\x83\\xBB\\x90:\\xA09\\xB3\\xB8\\xC0?\\xD3\\xBE\\xE3\\xBD\\xF0<\\xC4E F3\\xC7@@S\\xC1c\\xC2pC\\x80L\\x93\\xCD\\xA3\\xCE\\xB0O\\xC3\\xC8\\xD0I\\xE0J\\xF3\\xCB\\0U\\xD4#\\xD70VC\\xD1PP\\\`Ss\\xD2\\x83\\xDD\\x90\\\\\\xA0_\\xB3\\xDE\\xC0Y\\xD3\\xD8\\xE3\\xDB\\xF0Z\\0f\\xE7#\\xE40eC\\xE2Pc\\\`\\\`s\\xE1\\x83\\xEE\\x90o\\xA0l\\xB3\\xED\\xC0j\\xD3\\xEB\\xE3\\xE8\\xF0i\\xF7v u3\\xF4@sS\\xF2c\\xF1pp\\x80\\x7F\\x93\\xFE\\xA3\\xFD\\xB0|\\xC3\\xFB\\xD0z\\xE0y\\xF3\\xF8\\b\\x89 \\x8A3\\v@\\x8CS\\rcp\\x8F\\x80\\x80\\x93\\xA3\\xB0\\x83\\xC3\\xD0\\x85\\xE0\\x86\\xF3\\x07\\0\\x99#\\x1B0\\x9ACP\\x9C\\\`\\x9Fs\\x83\\x90\\x90\\xA0\\x93\\xB3\\xC0\\x95\\xD3\\xE3\\xF0\\x96\\0\\xAA+#(0\\xA9C.P\\xAF\\\`\\xACs-\\x83"\\x90\\xA3\\xA0\\xA0\\xB3!\\xC0\\xA6\\xD3'\\xE3$\\xF0\\xA5;\\xBA \\xB938@\\xBFS>c=p\\xBC\\x80\\xB3\\x932\\xA31\\xB0\\xB0\\xC37\\xD0\\xB6\\xE0\\xB5\\xF34\\0\\xCCM#N0\\xCFCHP\\xC9\\\`\\xCAsK\\x83D\\x90\\xC5\\xA0\\xC6\\xB3G\\xC0\\xC0\\xD3A\\xE3B\\xF0\\xC3]\\xDC \\xDF3^@\\xD9SXc[p\\xDA\\x80\\xD5\\x93T\\xA3W\\xB0\\xD6\\xC3Q\\xD0\\xD0\\xE0\\xD3\\xF3Rn\\xEF \\xEC3m@\\xEASkchp\\xE9\\x80\\xE6\\x93g\\xA3d\\xB0\\xE5\\xC3b\\xD0\\xE3\\xE0\\xE0\\xF3a\\0\\xFF~#}0\\xFCC{P\\xFA\\\`\\xF9sx\\x83w\\x90\\xF6\\xA0\\xF5\\xB3t\\xC0\\xF3\\xD3r\\xE3q\\xF0\\xF0\\0\\0\\f 
0@P\\\`p0\\x806\\x90<\\xA0:\\xB0(\\xC0.\\xD0$\\xE0"\\xF0e\\x80c\\x90i\\xA0o\\xB0}\\xC0{\\xD0q\\xE0w\\xF0U\\0SY _0M@KPA\\\`Gp\\xCF\\x80\\xC9\\x90\\xC3\\xA0\\xC5\\xB0\\xD7\\xC0\\xD1\\xD0\\xDB\\xE0\\xDD\\xF0\\xFF\\0\\xF9\\xF3 \\xF50\\xE7@\\xE1P\\xEB\\\`\\xEDp\\xAA\\0\\xAC\\xA6 \\xA00\\xB2@\\xB4P\\xBE\\\`\\xB8p\\x9A\\x80\\x9C\\x90\\x96\\xA0\\x90\\xB0\\x82\\xC0\\x84\\xD0\\x8E\\xE0\\x88\\xF0\\x9B\\x81\\x9D\\x91\\x97\\xA1\\x91\\xB1\\x83\\xC1\\x85\\xD1\\x8F\\xE1\\x89\\xF1\\xAB\\xAD\\xA7!\\xA11\\xB3A\\xB5Q\\xBFa\\xB9q\\xFE\\xF8\\xF2!\\xF41\\xE6A\\xE0Q\\xEAa\\xECq\\xCE\\x81\\xC8\\x91\\xC2\\xA1\\xC4\\xB1\\xD6\\xC1\\xD0\\xD1\\xDA\\xE1\\xDC\\xF1TRX!^1LAJQ@aFqd\\x81b\\x91h\\xA1n\\xB1|\\xC1z\\xD1p\\xE1v\\xF11\\x817\\x91=\\xA1;\\xB1)\\xC1/\\xD1%\\xE1#\\xF1\\x07\\r!\\v1AQaq3\\x835\\x93?\\xA39\\xB3+\\xC3-\\xD3'\\xE3!\\xF3#	3\\x1BCScsVPZ#\\\\3NCHSBcDsf\\x83\\\`\\x93j\\xA3l\\xB3~\\xC3x\\xD3r\\xE3t\\xF3\\xFC\\xFA\\xF0#\\xF63\\xE4C\\xE2S\\xE8c\\xEEs\\xCC\\x83\\xCA\\x93\\xC0\\xA3\\xC6\\xB3\\xD4\\xC3\\xD2\\xD3\\xD8\\xE3\\xDE\\xF3\\x99\\x83\\x9F\\x93\\x95\\xA3\\x93\\xB3\\x81\\xC3\\x87\\xD3\\x8D\\xE3\\x8B\\xF3\\xA9\\xAF\\xA5#\\xA33\\xB1C\\xB7S\\xBDc\\xBBs\\xA8\\xAE\\xA4"\\xA22\\xB0B\\xB6R\\xBCb\\xBAr\\x98\\x82\\x9E\\x92\\x94\\xA2\\x92\\xB2\\x80\\xC2\\x86\\xD2\\x8C\\xE2\\x8A\\xF2\\xCD\\x82\\xCB\\x92\\xC1\\xA2\\xC7\\xB2\\xD5\\xC2\\xD3\\xD2\\xD9\\xE2\\xDF\\xF2\\xFD\\xFB\\xF1"\\xF72\\xE5B\\xE3R\\xE9b\\xEFrg\\x82a\\x92k\\xA2m\\xB2\\x7F\\xC2y\\xD2s\\xE2u\\xF2WQ["]2OBIRCbEr"\\b2BRbr2\\x824\\x92>\\xA28\\xB2*\\xC2,\\xD2&\\xE2 \\xF2\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\x07\\0\\0\\0\\0\\0\\0\\0\\xD1t\\x9E\\0W\\x9D\\xBD*\\x80pR\\xFF\\xFF>'
\\0\\0\\0d\\0\\0\\0\\xE8\\0\\0'\\0\\0\\xA0\\x86\\0@B\\0\\x80\\x96\\x98\\0\\0\\xE1\\xF5\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\x83\\xF9\\xA2\\0DNn\\0\\xFC)\\0\\xD1W'\\0\\xDD4\\xF5\\0b\\xDB\\xC0\\0<\\x99\\x95\\0A\\x90C\\0cQ\\xFE\\0\\xBB\\xDE\\xAB\\0\\xB7a\\xC5\\0:n$\\0\\xD2MB\\0I\\xE0\\0	\\xEA.\\0\\x92\\xD1\\0\\xEB\\xFE\\0)\\xB1\\0\\xE8>\\xA7\\0\\xF55\\x82\\0D\\xBB.\\0\\x9C\\xE9\\x84\\0\\xB4&p\\0A~_\\0\\xD6\\x919\\0S\\x839\\0\\x9C\\xF49\\0\\x8B_\\x84\\0(\\xF9\\xBD\\0\\xF8;\\0\\xDE\\xFF\\x97\\0\\x98\\0/\\xEF\\0
Z\\x8B\\0mm\\0\\xCF~6\\0	\\xCB'\\0FO\\xB7\\0\\x9Ef?\\0-\\xEA_\\0\\xBA'u\\0\\xE5\\xEB\\xC7\\0={\\xF1\\0\\xF79\\x07\\0\\x92R\\x8A\\0\\xFBk\\xEA\\0\\xB1_\\0\\b]\\x8D\\x000V\\0{\\xFCF\\0\\xF0\\xABk\\0 \\xBC\\xCF\\x006\\xF4\\x9A\\0\\xE3\\xA9\\0^a\\x91\\0\\b\\x1B\\xE6\\0\\x85\\x99e\\0\\xA0_\\0\\x8D@h\\0\\x80\\xD8\\xFF\\0'sM\\01\\0\\xCAV\\0\\xC9\\xA8s\\0{\\xE2\\\`\\0k\\x8C\\xC0\\0\\xC4G\\0\\xCDg\\xC3\\0	\\xE8\\xDC\\0Y\\x83*\\0\\x8Bv\\xC4\\0\\xA6\\x96\\0D\\xAF\\xDD\\0W\\xD1\\0\\xA5>\\0\\x07\\xFF\\x003~?\\0\\xC22\\xE8\\0\\x98O\\xDE\\0\\xBB}2\\0&=\\xC3\\0k\\xEF\\0\\x9F\\xF8^\\x005:\\0\\x7F\\xF2\\xCA\\0\\xF1\\x87\\0|\\x90!\\0j$|\\0\\xD5n\\xFA\\x000-w\\0;C\\0\\xB5\\xC6\\0\\xC3\\x9D\\0\\xAD\\xC4\\xC2\\0,MA\\0\\f\\0]\\0\\x86}F\\0\\xE3q-\\0\\x9B\\xC6\\x9A\\x003b\\0\\0\\xB4\\xD2|\\0\\xB4\\xA7\\x97\\x007U\\xD5\\0\\xD7>\\xF6\\0\\xA3\\0Mv\\xFC\\0d\\x9D*\\0p\\xD7\\xAB\\0c|\\xF8\\0z\\xB0W\\0\\xE7\\0\\xC0IV\\0;\\xD6\\xD9\\0\\xA7\\x848\\0$#\\xCB\\0\\xD6\\x8Aw\\0ZT#\\0\\0\\xB9\\0\\xF1
\\x1B\\0\\xCE\\xDF\\0\\x9F1\\xFF\\0fj\\0\\x99Wa\\0\\xAC\\xFBG\\0~\\x7F\\xD8\\0"e\\xB7\\x002\\xE8\\x89\\0\\xE6\\xBF\\\`\\0\\xEF\\xC4\\xCD\\0l6	\\0]?\\xD4\\0\\xDE\\xD7\\0X;\\xDE\\0\\xDE\\x9B\\x92\\0\\xD2"(\\0(\\x86\\xE8\\0\\xE2XM\\0\\xC6\\xCA2\\0\\b\\xE3\\0\\xE0}\\xCB\\0\\xC0P\\0\\xF3\\xA7\\0\\xE0[\\0.4\\0\\x83b\\0\\x83H\\0\\xF5\\x8E[\\0\\xAD\\xB0\\x7F\\0\\xE9\\xF2\\0HJC\\0g\\xD3\\0\\xAA\\xDD\\xD8\\0\\xAE_B\\0ja\\xCE\\0
(\\xA4\\0\\xD3\\x99\\xB4\\0\\xA6\\xF2\\0\\\\w\\x7F\\0\\xA3\\xC2\\x83\\0a<\\x88\\0\\x8Asx\\0\\xAF\\x8CZ\\0o\\xD7\\xBD\\0-\\xA6c\\0\\xF4\\xBF\\xCB\\0\\x8D\\x81\\xEF\\0&\\xC1g\\0U\\xCAE\\0\\xCA\\xD96\\0(\\xA8\\xD2\\0\\xC2a\\x8D\\0\\xC9w\\0&\\0F\\x9B\\0\\xC4Y\\xC4\\0\\xC8\\xC5D\\0M\\xB2\\x91\\0\\0\\xF3\\0\\xD4C\\xAD\\0)I\\xE5\\0\\xFD\\xD5\\0\\0\\xBE\\xFC\\0\\x94\\xCC\\0p\\xCE\\xEE\\0>\\xF5\\0\\xEC\\xF1\\x80\\0\\xB3\\xE7\\xC3\\0\\xC7\\xF8(\\0\\x93\\x94\\0\\xC1q>\\0.	\\xB3\\0\\vE\\xF3\\0\\x88\\x9C\\0\\xAB {\\0.\\xB5\\x9F\\0G\\x92\\xC2\\0{2/\\0\\fUm\\0r\\xA7\\x90\\0k\\xE7\\x001\\xCB\\x96\\0yJ\\0Ay\\xE2\\0\\xF4\\xDF\\x89\\0\\xE8\\x94\\x97\\0\\xE2\\xE6\\x84\\0\\x991\\x97\\0\\x88\\xEDk\\0__6\\0\\xBB\\xFD\\0H\\x9A\\xB4\\0g\\xA4l\\0qrB\\0\\x8D]2\\0\\x9F\\xB8\\0\\xBC\\xE5	\\0\\x8D1%\\0\\xF7t9\\x000\\0\\r\\f\\0K\\bh\\0,\\xEEX\\0G\\xAA\\x90\\0t\\xE7\\0\\xBD\\xD6$\\0\\xF7}\\xA6\\0nHr\\0\\x9F\\xEF\\0\\x8E\\x94\\xA6\\0\\xB4\\x91\\xF6\\0\\xD1SQ\\0\\xCF
\\xF2\\0 \\x983\\0\\xF5K~\\0\\xB2ch\\0\\xDD>_\\0@]\\0\\x85\\x89\\x7F\\0UR)\\x007d\\xC0\\0m\\xD8\\x002H2\\0[Lu\\0Nq\\xD4\\0ETn\\0\\v	\\xC1\\0*\\xF5i\\0f\\xD5\\0'\\x07\\x9D\\0]P\\0\\xB4;\\xDB\\0\\xEAv\\xC5\\0\\x87\\xF9\\0Ik}\\0'\\xBA\\0\\x96i)\\0\\xC6\\xCC\\xAC\\0\\xADT\\0\\x90\\xE2j\\0\\x88\\xD9\\x89\\0,rP\\0\\xA4\\xBE\\0w\\x07\\x94\\0\\xF30p\\0\\0\\xFC'\\0\\xEAq\\xA8\\0f\\xC2I\\0d\\xE0=\\0\\x97\\xDD\\x83\\0\\xA3?\\x97\\0C\\x94\\xFD\\0\\r\\x86\\x8C\\x001A\\xDE\\0\\x929\\x9D\\0\\xDDp\\x8C\\0\\xB7\\xE7\\0\\b\\xDF;\\07+\\0\\\\\\x80\\xA0\\0Z\\x80\\x93\\0\\x92\\0\\xE8\\xD8\\0l\\x80\\xAF\\0\\xDB\\xFFK\\x008\\x90\\0Yv\\0b\\xA5\\0a\\xCB\\xBB\\0\\xC7\\x89\\xB9\\0@\\xBD\\0\\xD2\\xF2\\0Iu'\\0\\xEB\\xB6\\xF6\\0\\xDB"\\xBB\\0
\\xAA\\0\\x89&/\\0d\\x83v\\0	;3\\0\\x94\\0Q:\\xAA\\0\\xA3\\xC2\\0\\xAF\\xED\\xAE\\0\\\\&\\0m\\xC2M\\0-z\\x9C\\0\\xC0V\\x97\\0?\\x83\\0	\\xF0\\xF6\\0+@\\x8C\\0m1\\x99\\x009\\xB4\\x07\\0\\f \\0\\xD8\\xC3[\\0\\xF5\\x92\\xC4\\0\\xC6\\xADK\\0N\\xCA\\xA5\\0\\xA77\\xCD\\0\\xE6\\xA96\\0\\xAB\\x92\\x94\\0\\xDDBh\\0c\\xDE\\0v\\x8C\\xEF\\0h\\x8BR\\0\\xFC\\xDB7\\0\\xAE\\xA1\\xAB\\0\\xDF1\\0\\0\\xAE\\xA1\\0\\f\\xFB\\xDA\\0dMf\\0\\xED\\xB7\\0)e0\\0WV\\xBF\\0G\\xFF:\\0j\\xF9\\xB9\\0u\\xBE\\xF3\\0(\\x93\\xDF\\0\\xAB\\x800\\0f\\x8C\\xF6\\0\\xCB\\0\\xFA"\\0\\xD9\\xE4\\0=\\xB3\\xA4\\0W\\x1B\\x8F\\x006\\xCD	\\0NB\\xE9\\0\\xBE\\xA4\\x003#\\xB5\\0\\xF0\\xAA\\0Oe\\xA8\\0\\xD2\\xC1\\xA5\\0\\v?\\0[x\\xCD\\0#\\xF9v\\0{\\x8B\\0\\x89r\\0\\xC6\\xA6S\\0on\\xE2\\0\\xEF\\xEB\\0\\0\\x9BJX\\0\\xC4\\xDA\\xB7\\0\\xAAf\\xBA\\0v\\xCF\\xCF\\0\\xD1\\0\\xB1\\xF1-\\0\\x8C\\x99\\xC1\\0\\xC3\\xADw\\0\\x86H\\xDA\\0\\xF7]\\xA0\\0\\xC6\\x80\\xF4\\0\\xAC\\xF0/\\0\\xDD\\xEC\\x9A\\0?\\\\\\xBC\\0\\xD0\\xDEm\\0\\x90\\xC7\\0*\\xDB\\xB6\\0\\xA3%:\\0\\0\\xAF\\x9A\\0\\xADS\\x93\\0\\xB6W\\0)-\\xB4\\0K\\x80~\\0\\xDA\\x07\\xA7\\0v\\xAA\\0{Y\\xA1\\0*\\0\\xDC\\xB7-\\0\\xFA\\xE5\\xFD\\0\\x89\\xDB\\xFE\\0\\x89\\xBE\\xFD\\0\\xE4vl\\0\\xA9\\xFC\\0>\\x80p\\0\\x85n\\0\\xFD\\x87\\xFF\\0(>\\x07\\0ag3\\0*\\x86\\0M\\xBD\\xEA\\0\\xB3\\xE7\\xAF\\0\\x8Fmn\\0\\x95g9\\x001\\xBF[\\0\\x84\\xD7H\\x000\\xDF\\0\\xC7-C\\0%a5\\0\\xC9p\\xCE\\x000\\xCB\\xB8\\0\\xBFl\\xFD\\0\\xA4\\0\\xA2\\0l\\xE4\\0Z\\xDD\\xA0\\0!oG\\0b\\xD2\\0\\xB9\\\\\\x84\\0paI\\0kV\\xE0\\0\\x99R\\0PU7\\0\\xD5\\xB7\\x003\\xF1\\xC4\\0n_\\0]0\\xE4\\0\\x85.\\xA9\\0\\xB2\\xC3\\0\\xA126\\0\\b\\xB7\\xA4\\0\\xEA\\xB1\\xD4\\0\\xF7!\\0\\x8Fi\\xE4\\0'\\xFFw\\0\\f\\x80\\0\\x8D@-\\0O\\xCD\\xA0\\0 \\xA5\\x99\\0\\xB3\\xA2\\xD3\\0/]
\\0\\xB4\\xF9B\\0\\xDA\\xCB\\0}\\xBE\\xD0\\0\\x9B\\xDB\\xC1\\0\\xAB\\xBD\\0\\xCA\\xA2\\x81\\0\\bj\\\\\\0.U\\0'\\0U\\0\\x7F\\xF0\\0\\xE1\\x07\\x86\\0\\vd\\0\\x96A\\x8D\\0\\x87\\xBE\\xDE\\0\\xDA\\xFD*\\0k%\\xB6\\0{\\x894\\0\\xF3\\xFE\\0\\xB9\\xBF\\x9E\\0hjO\\0J*\\xA8\\0O\\xC4Z\\0-\\xF8\\xBC\\0\\xD7Z\\x98\\0\\xF4\\xC7\\x95\\0\\rM\\x8D\\0 :\\xA6\\0\\xA4W_\\0?\\xB1\\0\\x808\\x95\\0\\xCC \\0q\\xDD\\x86\\0\\xC9\\xDE\\xB6\\0\\xBF\\\`\\xF5\\0Me\\0\\x07k\\0\\x8C\\xB0\\xAC\\0\\xB2\\xC0\\xD0\\0QUH\\0\\xFB\\0\\x95r\\xC3\\0\\xA3;\\0\\xC0@5\\0\\xDC{\\0\\xE0E\\xCC\\0N)\\xFA\\0\\xD6\\xCA\\xC8\\0\\xE8\\xF3A\\0|d\\xDE\\0\\x9Bd\\xD8\\0\\xD9\\xBE1\\0\\xA4\\x97\\xC3\\0wX\\xD4\\0i\\xE3\\xC5\\0\\xF0\\xDA\\0\\xBA:<\\0FF\\0Uu_\\0\\xD2\\xBD\\xF5\\0n\\x92\\xC6\\0\\xAC.]\\0D\\xED\\0>B\\0a\\xC4\\x87\\0)\\xFD\\xE9\\0\\xE7\\xD6\\xF3\\0"|\\xCA\\0o\\x915\\0\\b\\xE0\\xC5\\0\\xFF\\xD7\\x8D\\0nj\\xE2\\0\\xB0\\xFD\\xC6\\0\\x93\\b\\xC1\\0|]t\\0k\\xAD\\xB2\\0\\xCDn\\x9D\\0>r{\\0\\xC6j\\0\\xF7\\xCF\\xA9\\0)s\\xDF\\0\\xB5\\xC9\\xBA\\0\\xB7\\0Q\\0\\xE2\\xB2\\r\\0t\\xBA$\\0\\xE5}\\\`\\0t\\xD8\\x8A\\0\\r,\\0\\x81\\f\\0~f\\x94\\0)\\0\\x9Fzv\\0\\xFD\\xFD\\xBE\\0VE\\xEF\\0\\xD9~6\\0\\xEC\\xD9\\0\\x8B\\xBA\\xB9\\0\\xC4\\x97\\xFC\\x001\\xA8'\\0\\xF1n\\xC3\\0\\x94\\xC56\\0\\xD8\\xA8V\\0\\xB4\\xA8\\xB5\\0\\xCF\\xCC\\0\\x89-\\0oW4\\0,V\\x89\\0\\x99\\xCE\\xE3\\0\\xD6 \\xB9\\0k^\\xAA\\0>*\\x9C\\0_\\xCC\\0\\xFD\\vJ\\0\\xE1\\xF4\\xFB\\0\\x8E;m\\0\\xE2\\x86,\\0\\xE9\\xD4\\x84\\0\\xFC\\xB4\\xA9\\0\\xEF\\xEE\\xD1\\0.5\\xC9\\0/9a\\x008!D\\0\\x1B\\xD9\\xC8\\0\\x81\\xFC
\\0\\xFBJj\\0/\\xD8\\0S\\xB4\\x84\\0N\\x99\\x8C\\0T"\\xCC\\0*U\\xDC\\0\\xC0\\xC6\\xD6\\0\\v\\x96\\0p\\xB8\\0i\\x95d\\0&Z\\\`\\0?R\\xEE\\0\\x7F\\0\\xF4\\xB5\\0\\xFC\\xCB\\xF5\\x004\\xBC-\\x004\\xBC\\xEE\\0\\xE8]\\xCC\\0\\xDD^\\\`\\0g\\x8E\\x9B\\0\\x923\\xEF\\0\\xC9\\xB8\\0aX\\x9B\\0\\xE1W\\xBC\\0Q\\x83\\xC6\\0\\xD8>\\0\\xDDqH\\0-\\xDD\\0\\xAF\\xA1\\0!,F\\0Y\\xF3\\xD7\\0\\xD9z\\x98\\0\\x9ET\\xC0\\0O\\x86\\xFA\\0V\\xFC\\0\\xE5y\\xAE\\0\\x89"6\\x008\\xAD"\\0g\\x93\\xDC\\0U\\xE8\\xAA\\0\\x82&8\\0\\xCA\\xE7\\x9B\\0Q\\r\\xA4\\0\\x993\\xB1\\0\\xA9\\xD7\\0iH\\0e\\xB2\\xF0\\0\\x7F\\x88\\xA7\\0\\x88L\\x97\\0\\xF9\\xD16\\0!\\x92\\xB3\\0{\\x82J\\0\\x98\\xCF!\\0@\\x9F\\xDC\\0\\xDCGU\\0\\xE1t:\\0g\\xEBB\\0\\xFE\\x9D\\xDF\\0^\\xD4_\\0{g\\xA4\\0\\xBA\\xACz\\0U\\xF6\\xA2\\0+\\x88#\\0A\\xBAU\\0Yn\\b\\0!*\\x86\\x009G\\x83\\0\\x89\\xE3\\xE6\\0\\xE5\\x9E\\xD4\\0I\\xFB@\\0\\xFFV\\xE9\\0\\xCA\\0\\xC5Y\\x8A\\0\\x94\\xFA+\\0\\xD3\\xC1\\xC5\\0\\xC5\\xCF\\0\\xDBZ\\xAE\\0G\\xC5\\x86\\0\\x85Cb\\0!\\x86;\\0,y\\x94\\0a\\x87\\0*L{\\0\\x80,\\0C\\xBF\\0\\x88&\\x90\\0x<\\x89\\0\\xA8\\xC4\\xE4\\0\\xE5\\xDB{\\0\\xC4:\\xC2\\0&\\xF4\\xEA\\0\\xF7g\\x8A\\0\\r\\x92\\xBF\\0e\\xA3+\\0=\\x93\\xB1\\0\\xBD|\\v\\0\\xA4Q\\xDC\\0'\\xDDc\\0i\\xE1\\xDD\\0\\x9A\\x94\\0\\xA8)\\x95\\0h\\xCE(\\0	\\xED\\xB4\\0D\\x9F \\0N\\x98\\xCA\\0p\\x82c\\0~|#\\0\\xB92\\0\\xA7\\xF5\\x8E\\0V\\xE7\\0!\\xF1\\b\\0\\xB5\\x9D*\\0o~M\\0\\xA5Q\\0\\xB5\\xF9\\xAB\\0\\x82\\xDF\\xD6\\0\\x96\\xDDa\\06\\0\\xC4:\\x9F\\0\\x83\\xA2\\xA1\\0r\\xEDm\\x009\\x8Dz\\0\\x82\\xB8\\xA9\\0k2\\\\\\0F'[\\0\\x004\\xED\\0\\xD2\\0w\\0\\xFC\\xF4U\\0YM\\0\\xE0q\\x80\\0A\\xC3\\xD3\\0\\vz@\\xFB!\\xF9?\\0\\0\\0\\0-Dt>\\0\\0\\0\\x80\\x98F\\xF8<\\0\\0\\0\\\`Q\\xCCx;\\0\\0\\0\\x80\\x83\\x1B\\xF09\\0\\0\\0@ %z8\\0\\0\\0\\x80"\\x82\\xE36\\0\\0\\0\\0\\xF3i5\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0A\\xE0\\xD4\\0\\v\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0A\\x88\\xD6\\0\\v	 9\\0\\0\\0\\0\\0	\\0A\\x9C\\xD6\\0\\v\\0A\\xB0\\xD6\\0\\v\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\x880\\0\\0\\0\\0A\\xDC\\xD6\\0\\v\\xFF\\xFF\\xFF\\xFF\\0A\\xA0\\xD7\\0\\v\\0A\\xAC\\xD7\\0\\v\\0A\\xC4\\xD7\\0\\v\\0\\0\\0\\0\\0\\0\\x984\\0\\0\\0\\0A\\xDC\\xD7\\0\\v\\0A\\xEC\\xD7\\0\\v\\xFF\\xFF\\xFF\\xFF
\\0A\\xB0\\xD8\\0\\v\\xA0+\`)}function Aj(A){return A}async function RA(A){return A}async function SA(A,r){try{var n=await RA(A),t=await WebAssembly.instantiate(n,r);return t}catch(E){m(\`failed to asynchronously prepare wasm: \${E}\`),S(E)}}async function UA(A,r,n){return SA(r,n)}function NA(){var A={a:Rr};return A}async function xA(){function A(q,s){return f=q.exports,Xr(f),R(),f}function r(q){return A(q.instance)}var n=NA();if(j.instantiateWasm)return new Promise((q,s)=>{j.instantiateWasm(n,(e,v)=>{q(A(e,v))})});H!=null||(H=XA());var t=await UA(y,H,n),E=r(t);return E}class U{constructor(r){aA(this,"name","ExitStatus");this.message=\`Program terminated with exit(\${r})\`,this.status=r}}var N=A=>{for(;A.length>0;)A.shift()(j)},x=[],QA=A=>x.push(A),Q=[],WA=A=>Q.push(A),J=!0,YA=()=>S(""),W=0,zA=()=>{J=!1,W=0},K={},Y=A=>{if(A instanceof U||A=="unwind")return T;D(1,A)},z=()=>J||W>0,Z=A=>{var r;T=A,z()||((r=j.onExit)==null||r.call(j,A),M=!0),D(A,new U(A))},ZA=(A,r)=>{T=A,Z(A)},Ar=ZA,rr=()=>{if(!z())try{Ar(T)}catch(A){Y(A)}},jr=A=>{if(!M)try{A(),rr()}catch(r){Y(r)}},nr=()=>performance.now(),tr=(A,r)=>{if(K[A]&&(clearTimeout(K[A].id),delete K[A]),!r)return 0;var n=setTimeout(()=>{delete K[A],jr(()=>tA(A,nr()))},r);return K[A]={id:n,timeout_ms:r},0},kr=()=>2147483648,Br=(A,r)=>Math.ceil(A/r)*r,Er=A=>{var r=h.buffer.byteLength,n=(A-r+65535)/65536|0;try{return h.grow(n),R(),1}catch(t){}},er=A=>{var r=c.length;A>>>=0;var n=kr();if(A>n)return!1;for(var t=1;t<=4;t*=2){var E=r*(1+.2/t);E=Math.min(E,A+100663296);var q=Math.min(n,Br(Math.max(A,E),65536)),s=Er(q);if(s)return!0}return!1},Gr=A=>52,qr=(A,r,n,t)=>52,sr=9007199254740992,lr=-9007199254740992,ar=A=>A<lr||A>sr?NaN:Number(A);function $r(A,r,n,t){return r=ar(r),70}for(var Fr=[null,[],[]],AA=new TextDecoder,rA=(A,r,n,t)=>{var E=r+n;if(t)return E;for(;A[r]&&!(r>=E);)++r;return r},ur=(A,r=0,n,t)=>{var E=rA(A,r,n,t);return AA.decode(A.buffer?A.subarray(r,E):new Uint8Array(A.slice(r,E)))},Dr=(A,r)=>{var n=Fr[A];r===0||r===10?((A===1?b:m)(ur(n)),n.length=0):n.push(r)},vr=(A,r,n)=>{if(!A)return"";var t=rA(c,A,r,n);return AA.decode(c.subarray(A,t))},ir=(A,r,n,t)=>{for(var E=0,q=0;q<n;q++){var s=d[r>>2],e=d[r+4>>2];r+=8;for(var v=0;v<e;v++)Dr(A,c[s+v]);E+=e}return d[t>>2]=E,0},jA=A=>{var r=j["_"+A];return r},or=(A,r)=>{V.set(A,r)},Ir=A=>{for(var r=0,n=0;n<A.length;++n){var t=A.charCodeAt(n);t<=127?r++:t<=2047?r+=2:t>=55296&&t<=57343?(r+=4,++n):r+=3}return r},cr=(A,r,n,t)=>{if(!(t>0))return 0;for(var E=n,q=n+t-1,s=0;s<A.length;++s){var e=A.codePointAt(s);if(e<=127){if(n>=q)break;r[n++]=e}else if(e<=2047){if(n+1>=q)break;r[n++]=192|e>>6,r[n++]=128|e&63}else if(e<=65535){if(n+2>=q)break;r[n++]=224|e>>12,r[n++]=128|e>>6&63,r[n++]=128|e&63}else{if(n+3>=q)break;r[n++]=240|e>>18,r[n++]=128|e>>12&63,r[n++]=128|e>>6&63,r[n++]=128|e&63,s++}}return r[n]=0,n-E},Kr=(A,r,n)=>cr(A,c,r,n),nA=A=>BA(A),pr=A=>{var r=Ir(A)+1,n=nA(r);return Kr(A,n,r),n},fr=()=>EA(),Cr=A=>kA(A),Pr=(A,r,n,t,E)=>{var q={string:F=>{var C=0;return F!=null&&F!==0&&(C=pr(F)),C},array:F=>{var C=nA(F.length);return or(F,C),C}};function s(F){return r==="string"?vr(F):r==="boolean"?!!F:F}var e=jA(A),v=[],w=0;if(t)for(var I=0;I<t.length;I++){var sA=q[n[I]];sA?(w===0&&(w=fr()),v[I]=sA(t[I])):v[I]=t[I]}var g=e(...v);function Ur(F){return w!==0&&Cr(w),s(F)}return g=Ur(g),g},_r=(A,r,n,t)=>{var E=!n||n.every(s=>s==="number"||s==="boolean"),q=r!=="string";return q&&E&&!t?jA(A):(...s)=>Pr(A,r,n,s,t)},p=new Uint8Array(123),i=25;i>=0;--i)p[48+i]=52+i,p[65+i]=i,p[97+i]=26+i;if(p[43]=62,p[47]=63,j.noExitRuntime&&(J=j.noExitRuntime),j.print&&(b=j.print),j.printErr&&(m=j.printErr),j.wasmBinary&&(y=j.wasmBinary),j.arguments&&(o=j.arguments),j.thisProgram&&(u=j.thisProgram),j.preInit)for(typeof j.preInit=="function"&&(j.preInit=[j.preInit]);j.preInit.length>0;)j.preInit.shift()();j.cwrap=_r;var mr,Mr,Tr,Or,Lr,dr,Hr,hr,wr,Jr,gr,br,tA,kA,BA,EA,yr,Vr,h;function Xr(A){mr=j._init_encoder=A.l,Mr=j._free=A.m,Tr=j._get_encode_input_ptr=A.n,Or=j._send_samples=A.o,Lr=j._get_output_data=A.p,dr=j._get_frame_count=A.q,Hr=j._get_frame_size=A.r,hr=j._get_frame_samples=A.s,wr=j._get_header_data=A.t,Jr=j._get_header_size=A.u,gr=j._finish_encoder=A.v,br=j._malloc=A.w,tA=A.x,kA=A.y,BA=A.z,EA=A.A,yr=h=A.j,Vr=A.__indirect_function_table}var Rr={c:YA,b:zA,d:tr,e:er,g:Gr,i:qr,f:$r,h:ir,a:Z};function Sr(){bA();function A(){var r;j.calledRun=!0,!M&&(yA(),O==null||O(j),(r=j.onRuntimeInitialized)==null||r.call(j),VA())}j.setStatus?(j.setStatus("Running..."),setTimeout(()=>{setTimeout(()=>j.setStatus(""),1),A()},1)):A()}var f;return f=await xA(),Sr(),X?B=j:B=new Promise((A,r)=>{O=A,L=r}),B}var $A=Qr;var a,P=null,DA,vA,iA,oA,IA,cA,KA,pA,fA,CA,Wr=async()=>{if(!a){if(P)return P;P=$A(),a=await P,P=null,DA=a.cwrap("init_encoder","number",["number","number","number"]),vA=a.cwrap("get_encode_input_ptr","number",["number","number"]),iA=a.cwrap("send_samples","number",["number","number"]),oA=a.cwrap("get_output_data","number",["number"]),IA=a.cwrap("get_frame_count","number",["number"]),cA=a.cwrap("get_frame_size","number",["number","number"]),KA=a.cwrap("get_frame_samples","number",["number","number"]),pA=a.cwrap("get_header_data","number",["number"]),fA=a.cwrap("get_header_size","number",["number"]),CA=a.cwrap("finish_encoder","number",["number"])}},Yr=async(k,B,j)=>{await Wr();let $=DA(k,B,j);if($===0)throw new Error("Failed to initialize FLAC encoder.");let G=pA($),l=fA($),o=a.HEAPU8.slice(G,G+l).buffer;return{ctx:$,header:o}},PA=k=>{let B=[],j=IA(k),$=oA(k),G=0;for(let l=0;l<j;l++){let o=cA(k,l),u=KA(k,l),D=a.HEAPU8.slice($+G,$+G+o).buffer;B.push({encodedData:D,samples:u}),G+=o}return B},zr=(k,B,j)=>{let $=new Uint8Array(B),G=vA(k,$.length);if(G===0)throw new Error("Failed to allocate encoder input buffer.");a.HEAPU8.set($,G);let l=iA(k,j);if(l<0)throw new Error(\`Encode failed with error code \${l}.\`);return PA(k)},Zr=k=>{if(CA(k)<0)throw new Error("Flush failed.");return PA(k)},FA=k=>{let{id:B,command:j}=k;(async()=>{try{let G,l=[];switch(j.type){case"init":{let{ctx:u,header:D}=await Yr(j.data.numberOfChannels,j.data.sampleRate,j.data.bitsPerSample);G={type:j.type,ctx:u,header:D},l.push(D)}break;case"encode":{let u=zr(j.data.ctx,j.data.audioData,j.data.numSamples);for(let D of u)l.push(D.encodedData);G={type:j.type,packets:u}}break;case"flush":{let u=Zr(j.data.ctx);for(let D of u)l.push(D.encodedData);G={type:j.type,packets:u}}break}uA({id:B,success:!0,data:G},l)}catch(G){uA({id:B,success:!1,error:G})}})()},uA=(k,B)=>{_?_.postMessage(k,B!=null?B:[]):self.postMessage(k,{transfer:B!=null?B:[]})},_=null;try{_=lA("worker_threads").parentPort}catch(k){}_?_.on("message",FA):self.addEventListener("message",k=>FA(k.data));setInterval(()=>{},1e3);
`);
  }
  function O0(e8) {
    if (!e8) throw new Error("Assertion failed.");
  }
  var be, hx, Ce, je, ge, ke, z, we, ye, Te, he, At, it, D0, I, j, _e, ot, N, z0, N0, H0, F0, Y, L, h0, Bx, b, mx, W0, Se, px, Z, v0, V0, H, $0, B0, U0, Ex, bx, Ie, V, Cx, jx, gx, K0, O, kx, P2, C, J0, X0, wx, Q0, yx, w, xx, Sx, Pe, Ix, Y0, Z0, Px, Tx, _x, ex, Me, Mx, qx, Rx, gt, Gx, Ox, x0, Lx, kt, wt, yt, Vx, $x, Ux, zx, tx, Nx, Ot, m0, $, y, M, W, Hx, Wx, f0, Kx, Oe, Jx, Yx, Zx, nx, Le, xe, e0, Xx, Ve, rx, Qx, ee, b0, n0, Ax, C0, ix, re, _, j0, ne, Ae, ie, A0, ox, K2, G, sx, ax, se, i0, c0, J, Fx, g0, fx, Ue, oe, ae, k0, w0, l0, t0, q, ce, U, r0, u0, cx, te, Fe, le, fe, p0, E0, ze, Ne, He, We, Ke, ue, Je, d0, y0, lx, de, Xe, Qe, T0, _0, T, ux, dx, S0, fn, I0, X, s0, P0, ve, o0, M0, q0, R0, a0, vx, G0, De, Ye, et, tt, Be, me, rt, pe;
  var init_offline_audio_encoders = __esm({
    "js/vendor/offline-audio-encoders.mjs"() {
      be = Object.create;
      hx = Object.defineProperty;
      Ce = Object.getOwnPropertyDescriptor;
      je = Object.getOwnPropertyNames;
      ge = Object.getPrototypeOf;
      ke = Object.prototype.hasOwnProperty;
      z = ((e8) => typeof __require < "u" ? __require : typeof Proxy < "u" ? new Proxy(e8, { get: (x, t) => (typeof __require < "u" ? __require : x)[t] }) : e8)(function(e8) {
        if (typeof __require < "u") return __require.apply(this, arguments);
        throw Error('Dynamic require of "' + e8 + '" is not supported');
      });
      we = (e8, x) => () => {
        try {
          return x || e8((x = { exports: {} }).exports, x), x.exports;
        } catch (t) {
          throw x = 0, t;
        }
      };
      ye = (e8, x, t, r) => {
        if (x && typeof x == "object" || typeof x == "function") for (let n of je(x)) !ke.call(e8, n) && n !== t && hx(e8, n, { get: () => x[n], enumerable: !(r = Ce(x, n)) || r.enumerable });
        return e8;
      };
      Te = (e8, x, t) => (t = e8 != null ? be(ge(e8)) : {}, ye(x || !e8 || !e8.__esModule ? hx(t, "default", { value: e8, enumerable: true }) : t, e8));
      he = we(() => {
      });
      At = Math.PI / 180;
      it = 180 / Math.PI;
      D0 = (e8) => e8 && e8[e8.length - 1];
      I = (e8) => e8.constructor === Uint8Array ? e8 : ArrayBuffer.isView(e8) ? new Uint8Array(e8.buffer, e8.byteOffset, e8.byteLength) : new Uint8Array(e8);
      j = (e8) => e8.constructor === DataView ? e8 : ArrayBuffer.isView(e8) ? new DataView(e8.buffer, e8.byteOffset, e8.byteLength) : new DataView(e8);
      _e = typeof globalThis.TextEncoder < "u" ? globalThis.TextEncoder : class {
        constructor() {
          this.encoding = "utf-8";
        }
        encode(x = "") {
          let t = new Uint8Array(3 * x.length), r = 0;
          for (let n = 0; n < x.length; n++) {
            let A = x.charCodeAt(n);
            if (A < 128) t[r++] = A;
            else if (A < 2048) t[r++] = 192 | A >> 6, t[r++] = 128 | A & 63;
            else if (A < 55296 || A > 57343) t[r++] = 224 | A >> 12, t[r++] = 128 | A >> 6 & 63, t[r++] = 128 | A & 63;
            else {
              let i = n + 1 < x.length ? x.charCodeAt(n + 1) : 0;
              A < 56320 && i >= 56320 && i <= 57343 ? (A = 65536 + (A - 55296 << 10) + (i - 56320), n++, t[r++] = 240 | A >> 18, t[r++] = 128 | A >> 12 & 63, t[r++] = 128 | A >> 6 & 63, t[r++] = 128 | A & 63) : (t[r++] = 239, t[r++] = 191, t[r++] = 189);
            }
          }
          return t.slice(0, r);
        }
      };
      ot = typeof globalThis.TextDecoder < "u" ? globalThis.TextDecoder : class {
        constructor(x = "utf-8") {
          let t = x.trim().toLowerCase();
          if (t === "utf-8" || t === "utf8" || t === "unicode-1-1-utf-8") this.encoding = "utf-8";
          else if (t === "utf-16le" || t === "utf-16") this.encoding = "utf-16le";
          else if (t === "utf-16be") this.encoding = "utf-16be";
          else throw new RangeError(`The encoding label provided ('${x}') is invalid.`);
        }
        decode(x) {
          let t = x ? I(x) : new Uint8Array(0), r = [];
          if (this.encoding === "utf-8") {
            let A = t.length >= 3 && t[0] === 239 && t[1] === 187 && t[2] === 191 ? 3 : 0;
            for (; A < t.length; ) {
              let i = t[A];
              if (i < 128) {
                r.push(i), A++;
                continue;
              }
              let s, o;
              if (i >= 194 && i < 224) s = 1, o = i & 31;
              else if (i >= 224 && i < 240) s = 2, o = i & 15;
              else if (i >= 240 && i < 245) s = 3, o = i & 7;
              else {
                r.push(65533), A++;
                continue;
              }
              let a = i === 224 ? 160 : i === 240 ? 144 : 128, F = i === 237 ? 159 : i === 244 ? 143 : 191, f = 1;
              for (; f <= s; f++) {
                let d = A + f < t.length ? t[A + f] : 0;
                if (d < a || d > F) break;
                o = o << 6 | d & 63, a = 128, F = 191;
              }
              A += f, f <= s ? r.push(65533) : o >= 65536 ? (o -= 65536, r.push(55296 | o >> 10, 56320 | o & 1023)) : r.push(o);
            }
          } else {
            let A = this.encoding === "utf-16le", i = A ? 255 : 254, s = A ? 254 : 255, o = t.length >= 2 && t[0] === i && t[1] === s ? 2 : 0;
            for (; o + 1 < t.length; ) {
              let a = A ? t[o] | t[o + 1] << 8 : t[o] << 8 | t[o + 1];
              if (o += 2, a >= 55296 && a <= 56319) {
                let F = o + 1 < t.length ? A ? t[o] | t[o + 1] << 8 : t[o] << 8 | t[o + 1] : -1;
                F >= 56320 && F <= 57343 ? (r.push(a, F), o += 2) : r.push(65533);
              } else a >= 56320 && a <= 57343 ? r.push(65533) : r.push(a);
            }
            o < t.length && r.push(65533);
          }
          let n = "";
          for (let A = 0; A < r.length; A += 8192) n += String.fromCharCode(...r.slice(A, A + 8192));
          return n;
        }
      };
      N = new _e();
      z0 = { bt709: 1, bt470bg: 5, smpte170m: 6, bt2020: 9, smpte432: 12 };
      N0 = { bt709: 1, smpte170m: 6, linear: 8, "iec61966-2-1": 13, pq: 16, hlg: 18 };
      H0 = { rgb: 0, bt709: 1, bt470bg: 5, smpte170m: 6, "bt2020-ncl": 9 };
      F0 = (e8) => e8 instanceof ArrayBuffer || typeof SharedArrayBuffer < "u" && e8 instanceof SharedArrayBuffer || ArrayBuffer.isView(e8);
      Y = class {
        constructor() {
          this.currentPromise = Promise.resolve(), this.pending = 0;
        }
        async acquire() {
          let x, t = new Promise((n) => {
            let A = false;
            x = () => {
              A || (n(), this.pending--, A = true);
            };
          }), r = this.currentPromise;
          return this.currentPromise = t, this.pending++, await r, x;
        }
      };
      L = (e8) => {
        throw new Error(`Unexpected value: ${e8}`);
      };
      h0 = (e8, x, t, r) => {
        t = t >>> 0, t = t & 16777215, r ? (e8.setUint8(x, t & 255), e8.setUint8(x + 1, t >>> 8 & 255), e8.setUint8(x + 2, t >>> 16 & 255)) : (e8.setUint8(x, t >>> 16 & 255), e8.setUint8(x + 1, t >>> 8 & 255), e8.setUint8(x + 2, t & 255));
      };
      Bx = (e8, x, t, r) => {
        t = b(t, -8388608, 8388607), t < 0 && (t = t + 16777216 & 16777215), h0(e8, x, t, r);
      };
      b = (e8, x, t) => Math.max(x, Math.min(t, e8));
      mx = (e8, x, t) => e8 + (x - e8) * t;
      W0 = (e8, x) => Math.round(e8 * x) / x;
      Se = /^[a-z]{3}$/;
      px = (e8) => Se.test(e8);
      Z = 1e6 * (1 + Number.EPSILON);
      v0 = class {
        constructor() {
          this.currentPromise = Promise.resolve();
        }
        call(x) {
          return this.currentPromise = this.currentPromise.then(x);
        }
      };
      V0 = null;
      H = () => V0 !== null ? V0 : V0 = !!(typeof navigator < "u" && (navigator.vendor?.match(/apple/i) || /AppleWebKit/.test(navigator.userAgent) && !/Chrome/.test(navigator.userAgent) || /\b(iPad|iPhone|iPod)\b/.test(navigator.userAgent)));
      $0 = null;
      B0 = () => $0 !== null ? $0 : $0 = typeof navigator < "u" && navigator.userAgent?.includes("Firefox");
      U0 = null;
      Ex = () => {
        if (U0 !== null) return U0;
        if (typeof navigator > "u") return null;
        let e8 = /\bChrome\/(\d+)/.exec(navigator.userAgent);
        return e8 ? U0 = Number(e8[1]) : null;
      };
      bx = (e8) => typeof globalThis.isSecureContext < "u" && !globalThis.isSecureContext ? `${e8} is not available in this environment; this may be because this page is running in an insecure context. Try serving your page over HTTPS or use localhost.` : `${e8} is not available in this environment.`;
      Ie = (async () => {
      })().constructor;
      V = (e8) => e8 instanceof Ie || e8 instanceof Promise ? true : typeof e8?.then == "function";
      Cx = function* (e8) {
        for (let x in e8) {
          let t = e8[x];
          t !== void 0 && (yield { key: x, value: t });
        }
      };
      jx = (e8) => {
        let x = "";
        for (let t = 0; t < e8.length; t++) x += String.fromCharCode(e8[t]);
        return btoa(x);
      };
      gx = () => {
        Symbol.dispose ??= /* @__PURE__ */ Symbol("Symbol.dispose");
      };
      K0 = (e8) => Array.isArray(e8) ? e8 : [e8];
      O = class {
        constructor() {
          this._listeners = /* @__PURE__ */ new Map();
        }
        on(x, t, r) {
          this._listeners.has(x) || this._listeners.set(x, /* @__PURE__ */ new Set());
          let n = { fn: t, once: r?.once ?? false };
          return this._listeners.get(x).add(n), () => {
            this._listeners.get(x)?.delete(n);
          };
        }
        _emit(...x) {
          let [t, r] = x, n = this._listeners.get(t);
          if (n) for (let A of n) {
            try {
              A.fn(r);
            } catch (i) {
              console.error(i);
            }
            A.once && n.delete(A);
          }
        }
      };
      kx = (e8) => e8 !== null && typeof e8 == "object" && Object.getPrototypeOf(e8) === Object.prototype && Object.values(e8).every((x) => typeof x == "string");
      (function(e8) {
        e8[e8.Silent = 0] = "Silent", e8[e8.Errors = 1] = "Errors", e8[e8.Warnings = 2] = "Warnings", e8[e8.Info = 3] = "Info";
      })(P2 || (P2 = {}));
      C = class e {
        constructor() {
        }
        static get level() {
          return e._level;
        }
        static set level(x) {
          if (x !== P2.Silent && x !== P2.Errors && x !== P2.Warnings && x !== P2.Info) throw new TypeError("Invalid log level. Use one of the values of the LogLevel enum.");
          e._level = x;
        }
        static get _emitter() {
          return e._emitterInstance ??= new O();
        }
        static on(x, t, r) {
          return e._emitter.on(x, t, r);
        }
        static _error(...x) {
          e._emitter._emit("error", x), e._level >= P2.Errors && console.error(...x);
        }
        static _warn(...x) {
          e._emitter._emit("warn", x), e._level >= P2.Warnings && console.warn(...x);
        }
        static _info(...x) {
          e._emitter._emit("info", x), e._level >= P2.Info && console.info(...x);
        }
      };
      C._level = P2.Info;
      C._emitterInstance = null;
      J0 = class {
        constructor(x, t) {
          if (this.data = x, this.mimeType = t, !(x instanceof Uint8Array)) throw new TypeError("data must be a Uint8Array.");
          if (typeof t != "string") throw new TypeError("mimeType must be a string.");
        }
      };
      X0 = class {
        constructor(x, t, r, n) {
          if (this.data = x, this.mimeType = t, this.name = r, this.description = n, !(x instanceof Uint8Array)) throw new TypeError("data must be a Uint8Array.");
          if (t !== void 0 && typeof t != "string") throw new TypeError("mimeType, when provided, must be a string.");
          if (r !== void 0 && typeof r != "string") throw new TypeError("name, when provided, must be a string.");
          if (n !== void 0 && typeof n != "string") throw new TypeError("description, when provided, must be a string.");
        }
      };
      wx = (e8) => {
        if (!e8 || typeof e8 != "object") throw new TypeError("tags must be an object.");
        if (e8.title !== void 0 && typeof e8.title != "string") throw new TypeError("tags.title, when provided, must be a string.");
        if (e8.description !== void 0 && typeof e8.description != "string") throw new TypeError("tags.description, when provided, must be a string.");
        if (e8.artist !== void 0 && typeof e8.artist != "string") throw new TypeError("tags.artist, when provided, must be a string.");
        if (e8.album !== void 0 && typeof e8.album != "string") throw new TypeError("tags.album, when provided, must be a string.");
        if (e8.albumArtist !== void 0 && typeof e8.albumArtist != "string") throw new TypeError("tags.albumArtist, when provided, must be a string.");
        if (e8.trackNumber !== void 0 && (!Number.isInteger(e8.trackNumber) || e8.trackNumber <= 0)) throw new TypeError("tags.trackNumber, when provided, must be a positive integer.");
        if (e8.tracksTotal !== void 0 && (!Number.isInteger(e8.tracksTotal) || e8.tracksTotal <= 0)) throw new TypeError("tags.tracksTotal, when provided, must be a positive integer.");
        if (e8.discNumber !== void 0 && (!Number.isInteger(e8.discNumber) || e8.discNumber <= 0)) throw new TypeError("tags.discNumber, when provided, must be a positive integer.");
        if (e8.discsTotal !== void 0 && (!Number.isInteger(e8.discsTotal) || e8.discsTotal <= 0)) throw new TypeError("tags.discsTotal, when provided, must be a positive integer.");
        if (e8.genre !== void 0 && typeof e8.genre != "string") throw new TypeError("tags.genre, when provided, must be a string.");
        if (e8.date !== void 0 && (!(e8.date instanceof Date) || Number.isNaN(e8.date.getTime()))) throw new TypeError("tags.date, when provided, must be a valid Date.");
        if (e8.creationTime !== void 0 && e8.creationTime !== null && (!(e8.creationTime instanceof Date) || Number.isNaN(e8.creationTime.getTime()))) throw new TypeError("tags.creationTime, when provided, must be a valid Date or null.");
        if (e8.beatsPerMinute !== void 0 && (!Number.isInteger(e8.beatsPerMinute) || e8.beatsPerMinute <= 0)) throw new TypeError("tags.beatsPerMinute, when provided, must be a positive integer.");
        if (e8.lyrics !== void 0 && typeof e8.lyrics != "string") throw new TypeError("tags.lyrics, when provided, must be a string.");
        if (e8.images !== void 0) {
          if (!Array.isArray(e8.images)) throw new TypeError("tags.images, when provided, must be an array.");
          for (let x of e8.images) {
            if (!x || typeof x != "object") throw new TypeError("Each image in tags.images must be an object.");
            if (!(x.data instanceof Uint8Array)) throw new TypeError("Each image.data must be a Uint8Array.");
            if (typeof x.mimeType != "string") throw new TypeError("Each image.mimeType must be a string.");
            if (!["coverFront", "coverBack", "unknown"].includes(x.kind)) throw new TypeError("Each image.kind must be 'coverFront', 'coverBack', or 'unknown'.");
          }
        }
        if (e8.comment !== void 0 && typeof e8.comment != "string") throw new TypeError("tags.comment, when provided, must be a string.");
        if (e8.raw !== void 0) {
          if (!e8.raw || typeof e8.raw != "object") throw new TypeError("tags.raw, when provided, must be an object.");
          for (let x of Object.values(e8.raw)) if (x !== null && typeof x != "string" && !(Array.isArray(x) && x.every((t) => typeof t == "string")) && !(x instanceof Uint8Array) && !(Array.isArray(x) && x.every((t) => t instanceof Uint8Array)) && !(x instanceof J0) && !(x instanceof X0) && !kx(x)) throw new TypeError("Each value in tags.raw must be a string, string array, Uint8Array, Uint8Array array, RichImageData, AttachedFile, Record<string, string>, or null.");
        }
      };
      Q0 = (e8) => e8.title === void 0 && e8.description === void 0 && e8.artist === void 0 && e8.album === void 0 && e8.albumArtist === void 0 && e8.trackNumber === void 0 && e8.tracksTotal === void 0 && e8.discNumber === void 0 && e8.discsTotal === void 0 && e8.genre === void 0 && e8.beatsPerMinute === void 0 && e8.date === void 0 && e8.lyrics === void 0 && (!e8.images || e8.images.length === 0) && e8.comment === void 0 && (e8.raw === void 0 || Object.keys(e8.raw).length === 0);
      yx = (e8) => {
        if (!e8 || typeof e8 != "object") throw new TypeError("disposition must be an object.");
        if (e8.default !== void 0 && typeof e8.default != "boolean") throw new TypeError("disposition.default must be a boolean.");
        if (e8.primary !== void 0 && typeof e8.primary != "boolean") throw new TypeError("disposition.primary must be a boolean.");
        if (e8.forced !== void 0 && typeof e8.forced != "boolean") throw new TypeError("disposition.forced must be a boolean.");
        if (e8.original !== void 0 && typeof e8.original != "boolean") throw new TypeError("disposition.original must be a boolean.");
        if (e8.commentary !== void 0 && typeof e8.commentary != "boolean") throw new TypeError("disposition.commentary must be a boolean.");
        if (e8.hearingImpaired !== void 0 && typeof e8.hearingImpaired != "boolean") throw new TypeError("disposition.hearingImpaired must be a boolean.");
        if (e8.visuallyImpaired !== void 0 && typeof e8.visuallyImpaired != "boolean") throw new TypeError("disposition.visuallyImpaired must be a boolean.");
      };
      w = class e2 {
        constructor(x) {
          this.bytes = x, this.pos = 0;
        }
        seekToByte(x) {
          this.pos = 8 * x;
        }
        readBit() {
          let x = Math.floor(this.pos / 8), t = this.bytes[x] ?? 0, r = 7 - (this.pos & 7), n = (t & 1 << r) >> r;
          return this.pos++, n;
        }
        readBits(x) {
          if (x === 1) return this.readBit();
          let t = 0;
          for (let r = 0; r < x; r++) t <<= 1, t |= this.readBit();
          return t;
        }
        writeBits(x, t) {
          let r = this.pos + x;
          for (let n = this.pos; n < r; n++) {
            let A = Math.floor(n / 8), i = this.bytes[A], s = 7 - (n & 7);
            i &= ~(1 << s), i |= (t & 1 << r - n - 1) >> r - n - 1 << s, this.bytes[A] = i;
          }
          this.pos = r;
        }
        copyBits(x, t) {
          let r = 0;
          for (r; r < x - 7; r += 8) this.writeBits(8, t.readBits(8));
          let n = x - r;
          n > 0 && this.writeBits(n, t.readBits(n));
        }
        readAlignedByte() {
          if (this.pos % 8 !== 0) throw new Error("Bitstream is not byte-aligned.");
          let x = this.pos / 8, t = this.bytes[x] ?? 0;
          return this.pos += 8, t;
        }
        skipBits(x) {
          this.pos += x;
        }
        getBitsLeft() {
          return this.bytes.length * 8 - this.pos;
        }
        clone() {
          let x = new e2(this.bytes);
          return x.pos = this.pos, x;
        }
      };
      xx = [96e3, 88200, 64e3, 48e3, 44100, 32e3, 24e3, 22050, 16e3, 12e3, 11025, 8e3, 7350];
      Sx = [-1, 1, 2, 3, 4, 5, 6, 8];
      Pe = [1, 2, 3, 4, 6, 7, 17, 19, 20, 21, 22];
      Ix = (e8) => {
        if (!e8 || e8.byteLength < 2) throw new TypeError("AAC description must be at least 2 bytes long.");
        let x = new w(e8), t = Y0(x), { frequencyIndex: r, sampleRate: n } = Z0(x), A = x.readBits(4), i = null;
        A >= 1 && A <= 7 && (i = Sx[A]);
        let s = t, o = false, a = n;
        (t === 5 || t === 29) && (o = t === 29, a = Z0(x).sampleRate, s = Y0(x), s === 22 && x.skipBits(4));
        let F = 1024;
        if (Pe.includes(s) && (F = x.readBits(1) ? 960 : 1024), t !== 5 && t !== 29) for (; x.getBitsLeft() > 15; ) {
          let f = x.pos;
          if (x.readBits(11) !== 695) {
            x.pos = f + 1;
            continue;
          }
          Y0(x) === 5 && x.readBits(1) && (a = Z0(x).sampleRate, x.getBitsLeft() > 11 && x.readBits(11) === 1352 && (o = !!x.readBits(1)));
          break;
        }
        return i !== null && i > 1 && (o = false), { objectType: t, coreObjectType: s, frequencyIndex: r, channelConfiguration: A, coreSampleRate: n, outputSampleRate: a, outputNumberOfChannels: o && i === 1 ? 2 : i, frameLength: F };
      };
      Y0 = (e8) => {
        let x = e8.readBits(5);
        return x === 31 ? 32 + e8.readBits(6) : x;
      };
      Z0 = (e8) => {
        let x = e8.readBits(4);
        return x === 15 ? { frequencyIndex: x, sampleRate: e8.readBits(24) } : { frequencyIndex: x, sampleRate: x < xx.length ? xx[x] : null };
      };
      Px = (e8) => {
        let x = e8.objectType === 5 || e8.objectType === 29, t = e8.objectType === 29, r = x ? e8.outputSampleRate / 2 : e8.outputSampleRate, n = t ? 1 : e8.outputNumberOfChannels, A = Sx.indexOf(n);
        if (A === -1) throw new TypeError(`Unsupported number of channels: ${e8.outputNumberOfChannels}`);
        let i = 16;
        e8.objectType >= 32 && (i += 6), ex(r) === 15 && (i += 24), x && (i += 9, ex(e8.outputSampleRate) === 15 && (i += 24));
        let s = Math.ceil(i / 8), o = new Uint8Array(s), a = new w(o);
        return Tx(a, e8.objectType), _x(a, r), a.writeBits(4, A), x && (_x(a, e8.outputSampleRate), Tx(a, 2)), a.writeBits(3, 0), o;
      };
      Tx = (e8, x) => {
        x < 32 ? e8.writeBits(5, x) : (e8.writeBits(5, 31), e8.writeBits(6, x - 32));
      };
      _x = (e8, x) => {
        let t = ex(x);
        e8.writeBits(4, t), t === 15 && e8.writeBits(24, x);
      };
      ex = (e8) => {
        let x = xx.indexOf(e8);
        return x === -1 ? 15 : x;
      };
      Me = "1.65.2";
      Mx = `Mediabunny v${Me}`;
      (function(e8) {
        e8[e8.NON_IDR_SLICE = 1] = "NON_IDR_SLICE", e8[e8.SLICE_DPA = 2] = "SLICE_DPA", e8[e8.SLICE_DPB = 3] = "SLICE_DPB", e8[e8.SLICE_DPC = 4] = "SLICE_DPC", e8[e8.IDR = 5] = "IDR", e8[e8.SEI = 6] = "SEI", e8[e8.SPS = 7] = "SPS", e8[e8.PPS = 8] = "PPS", e8[e8.AUD = 9] = "AUD", e8[e8.SPS_EXT = 13] = "SPS_EXT";
      })(qx || (qx = {}));
      (function(e8) {
        e8[e8.RASL_N = 8] = "RASL_N", e8[e8.RASL_R = 9] = "RASL_R", e8[e8.BLA_W_LP = 16] = "BLA_W_LP", e8[e8.RSV_IRAP_VCL23 = 23] = "RSV_IRAP_VCL23", e8[e8.VPS_NUT = 32] = "VPS_NUT", e8[e8.SPS_NUT = 33] = "SPS_NUT", e8[e8.PPS_NUT = 34] = "PPS_NUT", e8[e8.AUD_NUT = 35] = "AUD_NUT", e8[e8.PREFIX_SEI_NUT = 39] = "PREFIX_SEI_NUT", e8[e8.SUFFIX_SEI_NUT = 40] = "SUFFIX_SEI_NUT";
      })(Rx || (Rx = {}));
      gt = new Uint8Array([0, 0, 0, 1]);
      (function(e8) {
        e8[e8.audAllowed = 0] = "audAllowed", e8[e8.beforeFirstVcl = 1] = "beforeFirstVcl", e8[e8.afterFirstVcl = 2] = "afterFirstVcl", e8[e8.eoBitstreamAllowed = 3] = "eoBitstreamAllowed", e8[e8.noMoreDataAllowed = 4] = "noMoreDataAllowed";
      })(Gx || (Gx = {}));
      Ox = (e8) => {
        if (e8.byteLength < 19) throw new Error("Invalid Opus identification header: too short.");
        let x = j(e8), t = x.getUint8(9), r = x.getUint16(10, true), n = x.getUint32(12, true), A = x.getInt16(16, true), i = x.getUint8(18), s = null;
        return i && (s = e8.subarray(19, 21 + t)), { outputChannelCount: t, preSkip: r, inputSampleRate: n, outputGain: A, channelMappingFamily: i, channelMappingTable: s };
      };
      (function(e8) {
        e8[e8.STREAMINFO = 0] = "STREAMINFO", e8[e8.VORBIS_COMMENT = 4] = "VORBIS_COMMENT", e8[e8.PICTURE = 6] = "PICTURE";
      })(x0 || (x0 = {}));
      Lx = (e8, x, t) => {
        let r = [e8], n = N.encode(Mx), A = new Uint8Array(4 + n.length), i = new DataView(A.buffer);
        i.setUint32(0, n.length, true), A.set(n, 4), r.push(A);
        let s = [], o = (D, c) => {
          let v = `${D}=${c}`, u = N.encode(v);
          A = new Uint8Array(4 + u.length), i = new DataView(A.buffer), i.setUint32(0, u.length, true), A.set(u, 4), r.push(A), s.push(D);
        };
        for (let { key: D, value: c } of Cx(x)) switch (D) {
          case "title":
            o("TITLE", c);
            break;
          case "description":
            o("DESCRIPTION", c);
            break;
          case "artist":
            o("ARTIST", c);
            break;
          case "album":
            o("ALBUM", c);
            break;
          case "albumArtist":
            o("ALBUMARTIST", c);
            break;
          case "genre":
            o("GENRE", c);
            break;
          case "date":
            o("DATE", c.toISOString().slice(0, 10));
            break;
          case "comment":
            o("COMMENT", c);
            break;
          case "lyrics":
            o("LYRICS", c);
            break;
          case "trackNumber":
            o("TRACKNUMBER", c.toString());
            break;
          case "tracksTotal":
            o("TRACKTOTAL", c.toString());
            break;
          case "discNumber":
            o("DISCNUMBER", c.toString());
            break;
          case "discsTotal":
            o("DISCTOTAL", c.toString());
            break;
          case "beatsPerMinute":
            o("BPM", c.toString());
            break;
          case "images":
            {
              if (!t) break;
              for (let v of c) {
                let u = v.kind === "coverFront" ? 3 : v.kind === "coverBack" ? 4 : 0, B = new Uint8Array(v.mimeType.length);
                for (let g = 0; g < v.mimeType.length; g++) B[g] = v.mimeType.charCodeAt(g);
                let h = N.encode(v.description ?? ""), m = new Uint8Array(8 + B.length + 4 + h.length + 16 + 4 + v.data.length), p = j(m);
                p.setUint32(0, u, false), p.setUint32(4, B.length, false), m.set(B, 8), p.setUint32(8 + B.length, h.length, false), m.set(h, 12 + B.length), p.setUint32(28 + B.length + h.length, v.data.length, false), m.set(v.data, 32 + B.length + h.length);
                let R = jx(m);
                o("METADATA_BLOCK_PICTURE", R);
              }
            }
            break;
          case "raw":
            break;
          case "creationTime":
            break;
          default:
            L(D);
        }
        if (x.raw) for (let D in x.raw) {
          let c = x.raw[D] ?? x.raw[D.toLowerCase()];
          if (!(D === "vendor" || c == null || s.includes(D))) {
            if (typeof c == "string") o(D, c);
            else if (Array.isArray(c) && c.every((u) => typeof u == "string")) for (let u of c) o(D, u);
          }
        }
        let a = new Uint8Array(4);
        j(a).setUint32(0, s.length, true), r.splice(2, 0, a);
        let F = r.reduce((D, c) => D + c.length, 0), f = new Uint8Array(F), d = 0;
        for (let D of r) f.set(D, d), d += D.length;
        return f;
      };
      kt = [128, 138, 192, 128, 140, 192, 160, 174, 240, 160, 176, 240, 192, 208, 288, 192, 210, 288, 224, 242, 336, 224, 244, 336, 256, 278, 384, 256, 280, 384, 320, 348, 480, 320, 350, 480, 384, 416, 288 * 2, 384, 418, 288 * 2, 448, 486, 336 * 2, 448, 488, 336 * 2, 256 * 2, 278 * 2, 384 * 2, 256 * 2, 279 * 2, 384 * 2, 320 * 2, 348 * 2, 480 * 2, 320 * 2, 349 * 2, 480 * 2, 384 * 2, 417 * 2, 576 * 2, 384 * 2, 418 * 2, 576 * 2, 448 * 2, 487 * 2, 672 * 2, 448 * 2, 488 * 2, 672 * 2, 512 * 2, 557 * 2, 768 * 2, 512 * 2, 558 * 2, 768 * 2, 640 * 2, 696 * 2, 960 * 2, 640 * 2, 697 * 2, 960 * 2, 768 * 2, 835 * 2, 1152 * 2, 768 * 2, 836 * 2, 1152 * 2, 896 * 2, 975 * 2, 1344 * 2, 896 * 2, 976 * 2, 1344 * 2, 1024 * 2, 1114 * 2, 1536 * 2, 1024 * 2, 1115 * 2, 1536 * 2, 1152 * 2, 1253 * 2, 1728 * 2, 1152 * 2, 1254 * 2, 1728 * 2, 1280 * 2, 1393 * 2, 1920 * 2, 1280 * 2, 1394 * 2, 1920 * 2];
      wt = new Uint8Array([5, 4, 65, 67, 45, 51]);
      yt = new Uint8Array([5, 4, 69, 65, 67, 51]);
      Vx = (e8) => {
        let r = e8 >> 2, n = 4096, A = 0, i = 12, s = 0;
        for (r < 0 && (r = -r, A = 128), r += 33, r > 8191 && (r = 8191); (r & n) !== n && i >= 5; ) n >>= 1, i--;
        return s = r >> i - 4 & 15, ~(A | i - 5 << 4 | s) & 255;
      };
      $x = (e8) => {
        let t = 2048, r = 0, n = 11, A = 0, i = e8 >> 3;
        for (i < 0 ? i = -i - 1 : r = 128, i > 4095 && (i = 4095); (i & t) !== t && n >= 5; ) t >>= 1, n--;
        return A = i >> (n === 4 ? 1 : n - 4) & 15, (r | n - 4 << 4 | A) ^ 85;
      };
      gx();
      Ux = -1 / 0;
      zx = -1 / 0;
      tx = null;
      typeof FinalizationRegistry < "u" && (tx = new FinalizationRegistry((e8) => {
        let x = performance.now();
        e8.type === "video" ? (x - Ux >= 1e3 && (C._error("A VideoSample was garbage collected without first being closed. For proper resource management, make sure to call close() on all your VideoSamples as soon as you're done using them."), Ux = x), typeof VideoFrame < "u" && e8.data instanceof VideoFrame && e8.data.close()) : (x - zx >= 1e3 && (C._error("An AudioSample was garbage collected without first being closed. For proper resource management, make sure to call close() on all your AudioSamples as soon as you're done using them."), zx = x), typeof AudioData < "u" && e8.data instanceof AudioData && e8.data.close());
      }));
      Nx = ["I420", "I420P10", "I420P12", "I420A", "I420AP10", "I420AP12", "I422", "I422P10", "I422P12", "I422A", "I422AP10", "I422AP12", "I444", "I444P10", "I444P12", "I444A", "I444AP10", "I444AP12", "NV12", "RGBA", "RGBX", "BGRA", "BGRX"];
      Ot = new Set(Nx);
      m0 = /* @__PURE__ */ new Set(["f32", "f32-planar", "s16", "s16-planar", "s32", "s32-planar", "u8", "u8-planar"]);
      $ = class {
        constructor() {
          this._referenceCount = 0;
        }
      };
      y = class e3 {
        get microsecondTimestamp() {
          return Math.trunc(Z * this.timestamp);
        }
        get microsecondDuration() {
          return Math.trunc(Z * this.duration);
        }
        constructor(x) {
          if (this._closed = false, f0(x)) {
            if (x.format === null) throw new TypeError("AudioData with null format is not supported.");
            this._data = x, this.format = x.format, this.sampleRate = x.sampleRate, this.numberOfFrames = x.numberOfFrames, this.numberOfChannels = x.numberOfChannels, this.timestamp = x.timestamp / 1e6, this.duration = x.numberOfFrames / x.sampleRate;
          } else if (x instanceof $) {
            if (this._data = x, x._referenceCount++, this.format = x.getFormat(), !m0.has(this.format)) throw new TypeError("getFormat() must return an AudioSampleFormat.");
            if (this.sampleRate = x.getSampleRate(), !Number.isInteger(this.sampleRate) || this.sampleRate <= 0) throw new TypeError("getSampleRate() must return a positive integer.");
            if (this.numberOfFrames = x.getNumberOfFrames(), !Number.isInteger(this.numberOfFrames) || this.numberOfFrames < 0) throw new TypeError("getNumberOfFrames() must return a non-negative integer.");
            if (this.numberOfChannels = x.getNumberOfChannels(), !Number.isInteger(this.numberOfChannels) || this.numberOfChannels <= 0) throw new TypeError("getNumberOfChannels() must return a positive integer.");
            if (this.timestamp = x.getTimestamp(), !Number.isFinite(this.timestamp)) throw new TypeError("getTimestamp() must return a finite number.");
            this.duration = this.numberOfFrames / this.sampleRate;
          } else {
            if (!x || typeof x != "object") throw new TypeError("Invalid AudioDataInit: must be an object.");
            if (!m0.has(x.format)) throw new TypeError("Invalid AudioDataInit: invalid format.");
            if (!Number.isFinite(x.sampleRate) || x.sampleRate <= 0) throw new TypeError("Invalid AudioDataInit: sampleRate must be > 0.");
            if (!Number.isInteger(x.numberOfChannels) || x.numberOfChannels === 0) throw new TypeError("Invalid AudioDataInit: numberOfChannels must be an integer > 0.");
            if (!Number.isFinite(x?.timestamp)) throw new TypeError("init.timestamp must be a number.");
            let t = x.data.byteLength / (M(x.format) * x.numberOfChannels);
            if (!Number.isInteger(t)) throw new TypeError("Invalid AudioDataInit: data size is not a multiple of frame size.");
            this.format = x.format, this.sampleRate = x.sampleRate, this.numberOfFrames = t, this.numberOfChannels = x.numberOfChannels, this.timestamp = x.timestamp, this.duration = t / x.sampleRate;
            let r;
            if (x.data instanceof ArrayBuffer) r = new Uint8Array(x.data);
            else if (ArrayBuffer.isView(x.data)) r = new Uint8Array(x.data.buffer, x.data.byteOffset, x.data.byteLength);
            else throw new TypeError("Invalid AudioDataInit: data is not a BufferSource.");
            let n = this.numberOfFrames * this.numberOfChannels * M(this.format);
            if (r.byteLength < n) throw new TypeError("Invalid AudioDataInit: insufficient data size.");
            this._data = r;
          }
          tx?.register(this, { type: "audio", data: this._data }, this);
        }
        allocationSize(x) {
          if (!x || typeof x != "object") throw new TypeError("options must be an object.");
          if (!Number.isInteger(x.planeIndex) || x.planeIndex < 0) throw new TypeError("planeIndex must be a non-negative integer.");
          if (x.format !== void 0 && !m0.has(x.format)) throw new TypeError("Invalid format.");
          if (x.frameOffset !== void 0 && (!Number.isInteger(x.frameOffset) || x.frameOffset < 0)) throw new TypeError("frameOffset must be a non-negative integer.");
          if (x.frameCount !== void 0 && (!Number.isInteger(x.frameCount) || x.frameCount < 0)) throw new TypeError("frameCount must be a non-negative integer.");
          if (this._closed) throw new Error("AudioSample is closed.");
          let t = x.format ?? this.format, r = x.frameOffset ?? 0;
          if (r >= this.numberOfFrames) throw new RangeError("frameOffset out of range");
          let n = x.frameCount !== void 0 ? x.frameCount : this.numberOfFrames - r;
          if (n > this.numberOfFrames - r) throw new RangeError("frameCount out of range");
          let A = M(t), i = W(t);
          if (i && x.planeIndex >= this.numberOfChannels) throw new RangeError("planeIndex out of range");
          if (!i && x.planeIndex !== 0) throw new RangeError("planeIndex out of range");
          return (i ? n : n * this.numberOfChannels) * A;
        }
        copyTo(x, t) {
          if (!F0(x)) throw new TypeError("destination must be an ArrayBuffer or an ArrayBuffer view.");
          if (!t || typeof t != "object") throw new TypeError("options must be an object.");
          if (!Number.isInteger(t.planeIndex) || t.planeIndex < 0) throw new TypeError("planeIndex must be a non-negative integer.");
          if (t.format !== void 0 && !m0.has(t.format)) throw new TypeError("Invalid format.");
          if (t.frameOffset !== void 0 && (!Number.isInteger(t.frameOffset) || t.frameOffset < 0)) throw new TypeError("frameOffset must be a non-negative integer.");
          if (t.frameCount !== void 0 && (!Number.isInteger(t.frameCount) || t.frameCount < 0)) throw new TypeError("frameCount must be a non-negative integer.");
          if (this._closed) throw new Error("AudioSample is closed.");
          let { format: r, frameCount: n, frameOffset: A } = t, { planeIndex: i } = t, s = this.format, o = r ?? this.format;
          if (!o) throw new Error("Destination format not determined");
          let a = this.numberOfFrames, F = this.numberOfChannels, f = A ?? 0;
          if (f >= a) throw new RangeError("frameOffset out of range");
          let d = n !== void 0 ? n : a - f;
          if (d > a - f) throw new RangeError("frameCount out of range");
          let D = M(o), c = W(o);
          if (c && i >= F) throw new RangeError("planeIndex out of range");
          if (!c && i !== 0) throw new RangeError("planeIndex out of range");
          let u = (c ? d : d * F) * D;
          if (x.byteLength < u) throw new RangeError("Destination buffer is too small");
          let B = j(x), h = Wx(o);
          if (f0(this._data)) if (H() && F > 2 && o !== s) {
            Oe(this._data, B, s, o, F, i, f, d);
            return;
          } else try {
            this._data.copyTo(x, { planeIndex: i, frameOffset: f, frameCount: d, format: o });
            return;
          } catch (E) {
            if (o === "f32-planar") throw E;
            s = "f32-planar";
          }
          let m = Hx(s), p = M(s), R = W(s), g;
          if (this._data instanceof $) {
            let E = (k) => {
              let S = this._data.getDataPlane(k);
              if (!(S instanceof Uint8Array)) throw new TypeError("getDataPlane() must return a Uint8Array.");
              let Q = a * p * (R ? 1 : F);
              if (S.byteLength !== Q) throw new TypeError(`Data plane ${k} has invalid size. Expected exactly ${Q} bytes, got ${S.byteLength} bytes.`);
              return S;
            };
            if (R) if (c) g = E(i), i = 0;
            else {
              g = new Uint8Array(a * p * F);
              for (let k = 0; k < F; k++) {
                let S = E(k);
                g.set(S, k * a * p);
              }
            }
            else g = E(0);
          } else if (this._data instanceof Uint8Array) g = this._data;
          else if (l(s === "f32-planar"), c) g = new Uint8Array(this._data.allocationSize({ format: "f32-planar", planeIndex: i })), this._data.copyTo(g, { format: "f32-planar", planeIndex: i }), i = 0;
          else {
            g = new Uint8Array(this._data.allocationSize({ format: "f32-planar", planeIndex: 0 }) * F);
            for (let E = 0; E < F; E++) this._data.copyTo(g.subarray(E * a * p, (E + 1) * a * p), { format: "f32-planar", planeIndex: E });
          }
          let Dx = j(g);
          for (let E = 0; E < d; E++) if (c) {
            let k = E * D, S;
            R ? S = (i * a + (E + f)) * p : S = ((E + f) * F + i) * p;
            let Q = m(Dx, S);
            h(B, k, Q);
          } else for (let k = 0; k < F; k++) {
            let Q = (E * F + k) * D, L0;
            R ? L0 = (k * a + (E + f)) * p : L0 = ((E + f) * F + k) * p;
            let Ee = m(Dx, L0);
            h(B, Q, Ee);
          }
        }
        clone() {
          if (this._closed) throw new Error("AudioSample is closed.");
          if (this._data instanceof $) {
            let x = new e3(this._data);
            return x.setTimestamp(this.timestamp), x;
          } else if (f0(this._data)) {
            let x = new e3(this._data.clone());
            return x.setTimestamp(this.timestamp), x;
          } else return new e3({ format: this.format, sampleRate: this.sampleRate, numberOfFrames: this.numberOfFrames, numberOfChannels: this.numberOfChannels, timestamp: this.timestamp, data: this._data });
        }
        trim(x, t = this.numberOfFrames) {
          if (!Number.isInteger(x) || x < 0) throw new TypeError("startFrame must be a non-negative integer.");
          if (!Number.isInteger(t) || t < 0) throw new TypeError("endFrame must be a non-negative integer.");
          if (x > this.numberOfFrames) throw new RangeError("startFrame out of range.");
          if (t > this.numberOfFrames) throw new RangeError("endFrame out of range.");
          if (t < x) throw new RangeError("endFrame must not be less than startFrame.");
          if (this._closed) throw new Error("AudioSample is closed.");
          let r = t - x, n = M(this.format), A;
          if (W(this.format)) {
            let i = r * n;
            if (A = new Uint8Array(i * this.numberOfChannels), r > 0) for (let s = 0; s < this.numberOfChannels; s++) this.copyTo(A.subarray(s * i, (s + 1) * i), { planeIndex: s, format: this.format, frameOffset: x, frameCount: r });
          } else A = new Uint8Array(r * this.numberOfChannels * n), r > 0 && this.copyTo(A, { planeIndex: 0, format: this.format, frameOffset: x, frameCount: r });
          return new e3({ data: A, format: this.format, sampleRate: this.sampleRate, numberOfChannels: this.numberOfChannels, timestamp: this.timestamp + x / this.sampleRate });
        }
        close() {
          this._closed || (tx?.unregister(this), this._data instanceof $ ? (this._data._referenceCount--, this._data._referenceCount === 0 && this._data.close()) : f0(this._data) ? this._data.close() : this._data = new Uint8Array(0), this._closed = true);
        }
        toAudioData() {
          if (this._closed) throw new Error("AudioSample is closed.");
          return this._data instanceof $ ? this._createAudioDataFromData() : f0(this._data) ? this._data.timestamp === this.microsecondTimestamp ? this._data.clone() : this._createAudioDataFromData() : new AudioData({ format: this.format, sampleRate: this.sampleRate, numberOfFrames: this.numberOfFrames, numberOfChannels: this.numberOfChannels, timestamp: this.microsecondTimestamp, data: this._data.buffer instanceof ArrayBuffer ? this._data : this._data.slice() });
        }
        _createAudioDataFromData() {
          if (W(this.format)) {
            let x = this.allocationSize({ planeIndex: 0, format: this.format }), t = new ArrayBuffer(x * this.numberOfChannels);
            for (let r = 0; r < this.numberOfChannels; r++) this.copyTo(new Uint8Array(t, r * x, x), { planeIndex: r, format: this.format });
            return new AudioData({ format: this.format, sampleRate: this.sampleRate, numberOfFrames: this.numberOfFrames, numberOfChannels: this.numberOfChannels, timestamp: this.microsecondTimestamp, data: t });
          } else {
            let x = new ArrayBuffer(this.allocationSize({ planeIndex: 0, format: this.format }));
            return this.copyTo(x, { planeIndex: 0, format: this.format }), new AudioData({ format: this.format, sampleRate: this.sampleRate, numberOfFrames: this.numberOfFrames, numberOfChannels: this.numberOfChannels, timestamp: this.microsecondTimestamp, data: x });
          }
        }
        toAudioBuffer() {
          if (this._closed) throw new Error("AudioSample is closed.");
          let x = new AudioBuffer({ numberOfChannels: this.numberOfChannels, length: this.numberOfFrames, sampleRate: this.sampleRate }), t = new Float32Array(this.allocationSize({ planeIndex: 0, format: "f32-planar" }) / 4);
          for (let r = 0; r < this.numberOfChannels; r++) this.copyTo(t, { planeIndex: r, format: "f32-planar" }), x.copyToChannel(t, r);
          return x;
        }
        setTimestamp(x) {
          if (!Number.isFinite(x)) throw new TypeError("newTimestamp must be a number.");
          this.timestamp = x;
        }
        [Symbol.dispose]() {
          this.close();
        }
        static *_fromAudioBuffer(x, t) {
          if (!(x instanceof AudioBuffer)) throw new TypeError("audioBuffer must be an AudioBuffer.");
          let r = 48e3 * 5, n = x.numberOfChannels, A = x.sampleRate, i = x.length, s = Math.floor(r / n), o = 0, a = i;
          for (; a > 0; ) {
            let F = Math.min(s, a), f = new Float32Array(n * F);
            for (let d = 0; d < n; d++) x.copyFromChannel(f.subarray(d * F, (d + 1) * F), d, o);
            yield new e3({ format: "f32-planar", sampleRate: A, numberOfFrames: F, numberOfChannels: n, timestamp: t + o / A, data: f }), o += F, a -= F;
          }
        }
        static fromAudioBuffer(x, t) {
          if (!(x instanceof AudioBuffer)) throw new TypeError("audioBuffer must be an AudioBuffer.");
          let r = 48e3 * 5, n = x.numberOfChannels, A = x.sampleRate, i = x.length, s = Math.floor(r / n), o = 0, a = i, F = [];
          for (; a > 0; ) {
            let f = Math.min(s, a), d = new Float32Array(n * f);
            for (let c = 0; c < n; c++) x.copyFromChannel(d.subarray(c * f, (c + 1) * f), c, o);
            let D = new e3({ format: "f32-planar", sampleRate: A, numberOfFrames: f, numberOfChannels: n, timestamp: t + o / A, data: d });
            F.push(D), o += f, a -= f;
          }
          return F;
        }
      };
      M = (e8) => {
        switch (e8) {
          case "u8":
          case "u8-planar":
            return 1;
          case "s16":
          case "s16-planar":
            return 2;
          case "s32":
          case "s32-planar":
            return 4;
          case "f32":
          case "f32-planar":
            return 4;
          default:
            throw new Error("Unknown AudioSampleFormat");
        }
      };
      W = (e8) => {
        switch (e8) {
          case "u8-planar":
          case "s16-planar":
          case "s32-planar":
          case "f32-planar":
            return true;
          default:
            return false;
        }
      };
      Hx = (e8) => {
        switch (e8) {
          case "u8":
          case "u8-planar":
            return (x, t) => (x.getUint8(t) - 128) / 128;
          case "s16":
          case "s16-planar":
            return (x, t) => x.getInt16(t, true) / 32768;
          case "s32":
          case "s32-planar":
            return (x, t) => x.getInt32(t, true) / 2147483648;
          case "f32":
          case "f32-planar":
            return (x, t) => x.getFloat32(t, true);
        }
      };
      Wx = (e8) => {
        switch (e8) {
          case "u8":
          case "u8-planar":
            return (x, t, r) => x.setUint8(t, b(Math.round(r * 128) + 128, 0, 255));
          case "s16":
          case "s16-planar":
            return (x, t, r) => x.setInt16(t, b(Math.round(r * 32768), -32768, 32767), true);
          case "s32":
          case "s32-planar":
            return (x, t, r) => x.setInt32(t, b(Math.round(r * 2147483648), -2147483648, 2147483647), true);
          case "f32":
          case "f32-planar":
            return (x, t, r) => x.setFloat32(t, r, true);
        }
      };
      f0 = (e8) => typeof AudioData < "u" && e8 instanceof AudioData;
      Kx = (e8) => {
        switch (e8) {
          case "u8-planar":
            return "u8";
          case "s16-planar":
            return "s16";
          case "s32-planar":
            return "s32";
          case "f32-planar":
            return "f32";
          default:
            return e8;
        }
      };
      Oe = (e8, x, t, r, n, A, i, s) => {
        let o = Hx(t), a = Wx(r), F = M(t), f = M(r), d = W(t);
        if (W(r)) if (d) {
          let c = new ArrayBuffer(s * F), v = j(c);
          e8.copyTo(c, { planeIndex: A, frameOffset: i, frameCount: s, format: t });
          for (let u = 0; u < s; u++) {
            let B = u * F, h = u * f, m = o(v, B);
            a(x, h, m);
          }
        } else {
          let c = new ArrayBuffer(s * n * F), v = j(c);
          e8.copyTo(c, { planeIndex: 0, frameOffset: i, frameCount: s, format: t });
          for (let u = 0; u < s; u++) {
            let B = (u * n + A) * F, h = u * f, m = o(v, B);
            a(x, h, m);
          }
        }
        else if (d) {
          let c = s * F, v = new ArrayBuffer(c), u = j(v);
          for (let B = 0; B < n; B++) {
            e8.copyTo(v, { planeIndex: B, frameOffset: i, frameCount: s, format: t });
            for (let h = 0; h < s; h++) {
              let m = h * F, p = (h * n + B) * f, R = o(u, m);
              a(x, p, R);
            }
          }
        } else {
          let c = new ArrayBuffer(s * n * F), v = j(c);
          e8.copyTo(c, { planeIndex: 0, frameOffset: i, frameCount: s, format: t });
          for (let u = 0; u < s; u++) for (let B = 0; B < n; B++) {
            let h = u * n + B, m = h * F, p = h * f, R = o(v, m);
            a(x, p, R);
          }
        }
      };
      Jx = (e8, x) => {
        let t = e8.allocationSize({ format: x, planeIndex: 0 }), r = new ArrayBuffer(t);
        return e8.copyTo(r, { format: x, planeIndex: 0 }), new y({ data: r, format: x, numberOfChannels: e8.numberOfChannels, sampleRate: e8.sampleRate, timestamp: e8.timestamp, duration: e8.duration });
      };
      Yx = /* @__PURE__ */ new Map();
      Zx = /* @__PURE__ */ new Map();
      nx = (e8) => {
        if (!e8 || typeof e8 != "object") throw new TypeError("Encoding config must be an object.");
        if (!U.includes(e8.codec)) throw new TypeError(`Invalid audio codec '${e8.codec}'. Must be one of: ${U.join(", ")}.`);
        let x = e8.bitrate;
        if (e8.quality === void 0 && x === void 0 && !(q.includes(e8.codec) || e8.codec === "flac" || e8.codec === "truehd")) throw new TypeError("config.quality must be provided for compressed audio codecs.");
        if (e8.quality !== void 0 && x !== void 0) throw new TypeError("config.quality and config.bitrate cannot both be provided.");
        if (e8.quality !== void 0 && !(e8.quality instanceof e0)) throw new TypeError("config.quality, when provided, must be a Quality.");
        if (x !== void 0 && !(x instanceof e0) && (!Number.isInteger(x) || x <= 0)) throw new TypeError("config.bitrate, when provided, must be a positive integer or a quality.");
        if (e8.transform !== void 0) {
          if (typeof e8.transform != "object" || !e8.transform) throw new TypeError("config.transform, when provided, must be an object.");
          if (e8.transform.numberOfChannels !== void 0 && (!Number.isInteger(e8.transform.numberOfChannels) || e8.transform.numberOfChannels <= 0)) throw new TypeError("config.transform.numberOfChannels, when provided, must be a positive integer.");
          if (e8.transform.sampleRate !== void 0 && (!Number.isInteger(e8.transform.sampleRate) || e8.transform.sampleRate <= 0)) throw new TypeError("config.transform.sampleRate, when provided, must be a positive integer.");
          if (e8.transform.sampleFormat !== void 0 && !["u8", "s16", "s32", "f32"].includes(e8.transform.sampleFormat)) throw new TypeError("config.transform.sampleFormat, when provided, must be one of: u8, s16, s32, f32.");
          if (e8.transform.process !== void 0 && typeof e8.transform.process != "function") throw new TypeError("config.transform.process, when provided, must be a function.");
        }
        if (e8.onEncodedPacket !== void 0 && typeof e8.onEncodedPacket != "function") throw new TypeError("config.onEncodedPacket, when provided, must be a function.");
        if (e8.onEncoderConfig !== void 0 && typeof e8.onEncoderConfig != "function") throw new TypeError("config.onEncoderConfig, when provided, must be a function.");
        if (e8.onEncodedSample !== void 0 && typeof e8.onEncodedSample != "function") throw new TypeError("config.onEncodedSample, when provided, must be a function.");
        Le(e8.codec, e8);
      };
      Le = (e8, x) => {
        if (!x || typeof x != "object") throw new TypeError("Encoding options must be an object.");
        let t = x.bitrateMode;
        if (t !== void 0 && !["constant", "variable"].includes(t)) throw new TypeError("bitrateMode, when provided, must be 'constant' or 'variable'.");
        if (x.fullCodecString !== void 0 && typeof x.fullCodecString != "string") throw new TypeError("fullCodecString, when provided, must be a string.");
        if (x.fullCodecString !== void 0 && p0(x.fullCodecString) !== e8) throw new TypeError(`fullCodecString, when provided, must be a string that matches the specified codec (${e8}).`);
      };
      xe = (e8) => {
        let x = e8.bitrateMode;
        return { codec: e8.fullCodecString ?? te(e8.codec, e8.numberOfChannels, e8.sampleRate), numberOfChannels: e8.numberOfChannels, sampleRate: e8.sampleRate, bitrate: e8.quality?._toAudioBitrate(e8.codec), bitrateMode: e8.quality?._bitrateMode ?? x, ...E0(e8.codec) };
      };
      e0 = class {
        constructor(x) {
          if ((typeof x == "number" || typeof x == "string") && (x = { quality: x }), !x || typeof x != "object") throw new TypeError("options must be an object.");
          if (x.bitrateMode !== void 0 && !["constant", "variable"].includes(x.bitrateMode)) throw new TypeError("options.bitrateMode, when provided, must be 'constant' or 'variable'.");
          if ("quality" in x) {
            if (typeof x.quality == "string" ? !(x.quality in Xx) : typeof x.quality != "number" || Number.isNaN(x.quality)) throw new TypeError("options.quality must be a number, or one of 'very-low', 'low', 'medium', 'high' or 'very-high'.");
            if (x.preferBitrate !== void 0 && typeof x.preferBitrate != "boolean") throw new TypeError("options.preferBitrate, when provided, must be a boolean.");
            if ("bitrate" in x || "quantizer" in x) throw new TypeError("options.quality cannot be combined with options.bitrate or options.quantizer.");
            this._quality = typeof x.quality == "string" ? Xx[x.quality] : x.quality, this._preferBitrate = x.preferBitrate ?? false, this._bitrate = void 0, this._quantizer = void 0;
          } else {
            if (x.bitrate !== void 0 && (!Number.isInteger(x.bitrate) || x.bitrate <= 0)) throw new TypeError("options.bitrate, when provided, must be a positive integer.");
            if (x.quantizer !== void 0 && (!Number.isInteger(x.quantizer) || x.quantizer < 0)) throw new TypeError("options.quantizer, when provided, must be a non-negative integer.");
            if (x.bitrate === void 0 && x.quantizer === void 0) throw new TypeError("At least one of options.bitrate or options.quantizer must be set.");
            if ("preferBitrate" in x) throw new TypeError("options.preferBitrate can only be combined with options.quality.");
            this._quality = void 0, this._preferBitrate = false, this._bitrate = x.bitrate, this._quantizer = x.quantizer;
          }
          this._bitrateMode = x.bitrateMode;
        }
        _toVideoRateControl(x, t, r, n) {
          let A = Ve[x], i = null, s = this._bitrateMode ?? n ?? "variable";
          if (this._quantizer !== void 0) {
            if (A) if (this._quantizer < A.min || this._quantizer > A.max) {
              if (this._bitrate === void 0) throw new Error(`Quantizer ${this._quantizer} is out of range for codec '${x}'; must be between ${A.min} and ${A.max}.`);
            } else i = this._quantizer, this._bitrate === void 0 && (s = "quantizer");
            else if (this._bitrate === void 0) throw new Error(`Codec '${x}' does not support quantizer-based encoding. Provide a bitrate in the Quality to define a fallback.`);
          } else this._bitrate === void 0 && A && !this._preferBitrate && (l(this._quality !== void 0), i = b(Math.round(mx(A.worst, A.best, this._quality)), A.min, A.max));
          let o;
          if (this._bitrate !== void 0) o = this._bitrate;
          else {
            let a = this._quality;
            a === void 0 && (l(i !== null && A), a = b((i - A.worst) / (A.best - A.worst), 0, 1)), o = Qx(x, t, r, rx(a));
          }
          return { quantizer: i, bitrate: o, bitrateMode: s };
        }
        _toVideoBitrate(x, t, r) {
          return this._bitrate !== void 0 ? this._bitrate : (l(this._quality !== void 0), Qx(x, t, r, rx(this._quality)));
        }
        _toAudioBitrate(x) {
          if (q.includes(x) || x === "flac" || x === "truehd") return;
          if (this._bitrate !== void 0) return this._bitrate;
          if (this._quality === void 0) throw new Error("This Quality defines neither a quality level nor a bitrate and therefore cannot be used for audio encoding.");
          let t = rx(this._quality), n = { aac: 128e3, opus: 64e3, mp3: 16e4, vorbis: 64e3, ac3: 384e3, eac3: 192e3, dts: 768e3 }[x];
          if (!n) throw new Error(`Unhandled codec: ${x}`);
          let A = n * t;
          return x === "aac" ? A = [96e3, 128e3, 16e4, 192e3].reduce((s, o) => Math.abs(o - A) < Math.abs(s - A) ? o : s) : x === "opus" || x === "vorbis" ? A = Math.max(6e3, A) : x === "mp3" && (A = [8e3, 16e3, 24e3, 32e3, 4e4, 48e3, 64e3, 8e4, 96e3, 112e3, 128e3, 16e4, 192e3, 224e3, 256e3, 32e4].reduce((s, o) => Math.abs(o - A) < Math.abs(s - A) ? o : s)), Math.round(A / 1e3) * 1e3;
        }
      };
      Xx = { "very-low": 0, low: 0.25, medium: 0.5, high: 0.75, "very-high": 1 };
      Ve = { avc: { min: 0, max: 51, worst: 41, best: 16 }, hevc: { min: 0, max: 51, worst: 41, best: 16 }, vp9: (Ex() ?? 1 / 0) < 145 ? { min: 0, max: 63, worst: 52, best: 20 } : { min: 0, max: 255, worst: 208, best: 80 }, av1: { min: 0, max: 255, worst: 208, best: 80 } };
      rx = (e8) => 0.3 * Math.exp(2.5538 * e8);
      Qx = (e8, x, t, r) => {
        let n = x * t, A = 1920 * 1080, i = 3e6, s = Math.pow(n / A, 0.95), o = i * s, a = { avc: 1, hevc: 0.6, vp9: 0.6, av1: 0.4, vp8: 1.2, prores: 22e7 / i }, f = o * a[e8] * r;
        return Math.ceil(f / 1e3) * 1e3;
      };
      ee = (e8, x) => {
        if (e8 !== void 0) return e8;
        if (x !== void 0) return x instanceof e0 ? x : new e0({ bitrate: x });
      };
      b0 = class {
        static supports(x, t) {
          return false;
        }
      };
      n0 = class {
        static supports(x, t) {
          return false;
        }
      };
      Ax = [];
      C0 = [];
      ix = (e8) => {
        if (e8.prototype instanceof b0) {
          let x = e8;
          if (Ax.includes(x)) {
            C._warn("Video encoder already registered.");
            return;
          }
          Ax.push(x), Yx.clear();
        } else if (e8.prototype instanceof n0) {
          let x = e8;
          if (C0.includes(x)) {
            C._warn("Audio encoder already registered.");
            return;
          }
          C0.push(x), Zx.clear();
        } else throw new TypeError("Encoder must be a CustomVideoEncoder or CustomAudioEncoder.");
      };
      re = new Uint8Array(0);
      _ = class e4 {
        constructor(x, t, r, n, A = -1, i, s) {
          if (this.data = x, this.type = t, this.timestamp = r, this.duration = n, this.sequenceNumber = A, x === re && i === void 0) throw new Error("Internal error: byteLength must be explicitly provided when constructing metadata-only packets.");
          if (i === void 0 && (i = x.byteLength), !(x instanceof Uint8Array)) throw new TypeError("data must be a Uint8Array.");
          if (t !== "key" && t !== "delta") throw new TypeError('type must be either "key" or "delta".');
          if (!Number.isFinite(r)) throw new TypeError("timestamp must be a number.");
          if (!Number.isFinite(n) || n < 0) throw new TypeError("duration must be a non-negative number.");
          if (!Number.isFinite(A)) throw new TypeError("sequenceNumber must be a number.");
          if (!Number.isInteger(i) || i < 0) throw new TypeError("byteLength must be a non-negative integer.");
          if (s !== void 0 && (typeof s != "object" || !s)) throw new TypeError("sideData, when provided, must be an object.");
          if (s?.alpha !== void 0 && !(s.alpha instanceof Uint8Array)) throw new TypeError("sideData.alpha, when provided, must be a Uint8Array.");
          if (s?.alphaByteLength !== void 0 && (!Number.isInteger(s.alphaByteLength) || s.alphaByteLength < 0)) throw new TypeError("sideData.alphaByteLength, when provided, must be a non-negative integer.");
          this.byteLength = i, this.sideData = s ?? {}, this.sideData.alpha && this.sideData.alphaByteLength === void 0 && (this.sideData.alphaByteLength = this.sideData.alpha.byteLength);
        }
        get isMetadataOnly() {
          return this.data === re;
        }
        get microsecondTimestamp() {
          return Math.trunc(Z * this.timestamp);
        }
        get microsecondDuration() {
          return Math.trunc(Z * this.duration);
        }
        toEncodedVideoChunk() {
          if (this.isMetadataOnly) throw new TypeError("Metadata-only packets cannot be converted to a video chunk.");
          if (typeof EncodedVideoChunk > "u") throw new Error("EncodedVideoChunk is not available in this environment.");
          return new EncodedVideoChunk({ data: this.data, type: this.type, timestamp: this.microsecondTimestamp, duration: this.microsecondDuration });
        }
        alphaToEncodedVideoChunk(x = this.type) {
          if (!this.sideData.alpha) throw new TypeError("This packet does not contain alpha side data.");
          if (this.isMetadataOnly) throw new TypeError("Metadata-only packets cannot be converted to a video chunk.");
          if (typeof EncodedVideoChunk > "u") throw new Error("EncodedVideoChunk is not available in this environment.");
          return new EncodedVideoChunk({ data: this.sideData.alpha, type: x, timestamp: this.microsecondTimestamp, duration: this.microsecondDuration });
        }
        toEncodedAudioChunk() {
          if (this.isMetadataOnly) throw new TypeError("Metadata-only packets cannot be converted to an audio chunk.");
          if (typeof EncodedAudioChunk > "u") throw new Error("EncodedAudioChunk is not available in this environment.");
          return new EncodedAudioChunk({ data: this.data, type: this.type, timestamp: this.microsecondTimestamp, duration: this.microsecondDuration });
        }
        static fromEncodedChunk(x, t) {
          if (!(x instanceof EncodedVideoChunk || x instanceof EncodedAudioChunk)) throw new TypeError("chunk must be an EncodedVideoChunk or EncodedAudioChunk.");
          let r = new Uint8Array(x.byteLength);
          return x.copyTo(r), new e4(r, x.type, x.timestamp / 1e6, (x.duration ?? 0) / 1e6, void 0, void 0, t);
        }
        clone(x) {
          if (x !== void 0 && (typeof x != "object" || x === null)) throw new TypeError("options, when provided, must be an object.");
          if (x?.data !== void 0 && !(x.data instanceof Uint8Array)) throw new TypeError("options.data, when provided, must be a Uint8Array.");
          if (x?.type !== void 0 && x.type !== "key" && x.type !== "delta") throw new TypeError('options.type, when provided, must be either "key" or "delta".');
          if (x?.timestamp !== void 0 && !Number.isFinite(x.timestamp)) throw new TypeError("options.timestamp, when provided, must be a number.");
          if (x?.duration !== void 0 && !Number.isFinite(x.duration)) throw new TypeError("options.duration, when provided, must be a number.");
          if (x?.sequenceNumber !== void 0 && !Number.isFinite(x.sequenceNumber)) throw new TypeError("options.sequenceNumber, when provided, must be a number.");
          if (x?.sideData !== void 0 && (typeof x.sideData != "object" || x.sideData === null)) throw new TypeError("options.sideData, when provided, must be an object.");
          return new e4(x?.data ?? this.data, x?.type ?? this.type, x?.timestamp ?? this.timestamp, x?.duration ?? this.duration, x?.sequenceNumber ?? this.sequenceNumber, this.byteLength, x?.sideData ?? this.sideData);
        }
      };
      j0 = class {
        constructor(x) {
          this.sourceSampleRate = null, this.sourceNumberOfChannels = null, this.startTime = null, this.bufferStartFrame = 0, this.maxWrittenFrame = null, this.targetSampleRate = x.targetSampleRate, this.targetNumberOfChannels = x.targetNumberOfChannels, this.onSample = x.onSample, this.bufferSizeInFrames = Math.floor(this.targetSampleRate * 5), this.bufferSizeInSamples = this.bufferSizeInFrames * this.targetNumberOfChannels;
        }
        doChannelMixerSetup() {
          l(this.sourceNumberOfChannels !== null);
          let x = this.sourceNumberOfChannels, t = this.targetNumberOfChannels;
          x === 1 && t === 2 ? this.channelMixer = (r, n) => r[n * x] : x === 1 && t === 4 ? this.channelMixer = (r, n, A) => r[n * x] * +(A < 2) : x === 1 && t === 6 ? this.channelMixer = (r, n, A) => r[n * x] * +(A === 2) : x === 2 && t === 1 ? this.channelMixer = (r, n) => {
            let A = n * x;
            return 0.5 * (r[A] + r[A + 1]);
          } : x === 2 && t === 4 ? this.channelMixer = (r, n, A) => A < 2 ? r[n * x + A] : 0 : x === 2 && t === 6 ? this.channelMixer = (r, n, A) => A < 2 ? r[n * x + A] : 0 : x === 4 && t === 1 ? this.channelMixer = (r, n) => {
            let A = n * x;
            return 0.25 * (r[A] + r[A + 1] + r[A + 2] + r[A + 3]);
          } : x === 4 && t === 2 ? this.channelMixer = (r, n, A) => {
            let i = n * x;
            return 0.5 * (r[i + A] + r[i + A + 2]);
          } : x === 4 && t === 6 ? this.channelMixer = (r, n, A) => {
            let i = n * x;
            return A < 2 ? r[i + A] : A === 2 || A === 3 ? 0 : r[i + A - 2];
          } : x === 6 && t === 1 ? this.channelMixer = (r, n) => {
            let A = n * x;
            return Math.SQRT1_2 * (r[A] + r[A + 1]) + r[A + 2] + 0.5 * (r[A + 4] + r[A + 5]);
          } : x === 6 && t === 2 ? this.channelMixer = (r, n, A) => {
            let i = n * x;
            return r[i + A] + Math.SQRT1_2 * (r[i + 2] + r[i + A + 4]);
          } : x === 6 && t === 4 ? this.channelMixer = (r, n, A) => {
            let i = n * x;
            return A < 2 ? r[i + A] + Math.SQRT1_2 * r[i + 2] : r[i + A + 2];
          } : this.channelMixer = (r, n, A) => A < x ? r[n * x + A] : 0;
        }
        ensureTempBufferSize(x) {
          let t = this.tempSourceBuffer.length;
          for (; t < x; ) t *= 2;
          if (t !== this.tempSourceBuffer.length) {
            let r = new Float32Array(t);
            r.set(this.tempSourceBuffer), this.tempSourceBuffer = r;
          }
        }
        async add(x) {
          if (this.sourceSampleRate === null) {
            this.sourceSampleRate = x.sampleRate, this.sourceNumberOfChannels = x.numberOfChannels, this.startTime = x.timestamp;
            let a = Math.ceil(this.targetSampleRate / this.sourceSampleRate);
            this.bufferCapacityInFrames = this.bufferSizeInFrames + a, this.outputBuffer = new Float32Array(this.bufferCapacityInFrames * this.targetNumberOfChannels), this.tempSourceBuffer = new Float32Array(this.sourceSampleRate * this.sourceNumberOfChannels), this.doChannelMixerSetup();
          }
          l(this.startTime !== null);
          let t = x.numberOfFrames * x.numberOfChannels;
          this.ensureTempBufferSize(t);
          let r = x.allocationSize({ planeIndex: 0, format: "f32" }), n = new Float32Array(this.tempSourceBuffer.buffer, 0, r / 4);
          x.copyTo(n, { planeIndex: 0, format: "f32" });
          let A = Math.round((x.timestamp - this.startTime) * this.sourceSampleRate), i = A + x.numberOfFrames, s = Math.floor((A - 1) * this.targetSampleRate / this.sourceSampleRate) + 1, o = Math.ceil(i * this.targetSampleRate / this.sourceSampleRate);
          for (let a = s; a < o; a++) {
            if (a < this.bufferStartFrame) continue;
            for (; a >= this.bufferStartFrame + this.bufferCapacityInFrames; ) await this.finalizeCurrentBuffer(), this.bufferStartFrame += this.bufferSizeInFrames;
            let F = a - this.bufferStartFrame;
            l(F < this.bufferCapacityInFrames);
            let f = a * this.sourceSampleRate / this.targetSampleRate - A, d = Math.floor(f), D = Math.ceil(f), c = f - d;
            for (let v = 0; v < this.targetNumberOfChannels; v++) {
              let u = 0, B = 0;
              d >= 0 && d < x.numberOfFrames && (u = this.channelMixer(n, d, v)), D >= 0 && D < x.numberOfFrames && (B = this.channelMixer(n, D, v));
              let h = u + c * (B - u), m = F * this.targetNumberOfChannels + v;
              this.outputBuffer[m] += h;
            }
            this.maxWrittenFrame === null ? this.maxWrittenFrame = F : this.maxWrittenFrame = Math.max(this.maxWrittenFrame, F);
          }
        }
        async finalizeCurrentBuffer() {
          if (this.maxWrittenFrame === null) return;
          l(this.startTime !== null);
          let x = Math.min(this.maxWrittenFrame + 1, this.bufferSizeInFrames) * this.targetNumberOfChannels, t = new Float32Array(x);
          t.set(this.outputBuffer.subarray(0, x));
          let r = new y({ format: "f32", sampleRate: this.targetSampleRate, numberOfChannels: this.targetNumberOfChannels, timestamp: this.startTime + this.bufferStartFrame / this.targetSampleRate, data: t });
          await this.onSample(r), this.outputBuffer.copyWithin(0, this.bufferSizeInSamples), this.outputBuffer.fill(0, this.outputBuffer.length - this.bufferSizeInSamples), this.maxWrittenFrame = this.maxWrittenFrame >= this.bufferSizeInFrames ? this.maxWrittenFrame - this.bufferSizeInFrames : null;
        }
        async finalize() {
          for (; this.maxWrittenFrame !== null; ) await this.finalizeCurrentBuffer(), this.bufferStartFrame += this.bufferSizeInFrames;
        }
      };
      ne = (e8) => e8 === 0 ? null : e8 === 1 ? 192 : e8 >= 2 && e8 <= 5 ? 144 * 2 ** e8 : e8 === 6 ? "uncommon-u8" : e8 === 7 ? "uncommon-u16" : e8 >= 8 && e8 <= 15 ? 2 ** e8 : null;
      Ae = (e8) => {
        let x = 0, t = new w(K2(e8, 1));
        for (; t.readBits(1) === 1; ) x++;
        if (x === 0) return t.readBits(7);
        let r = [], n = x - 1, A = new w(K2(e8, n)), i = 8 - x - 1;
        for (let o = 0; o < i; o++) r.unshift(t.readBits(1));
        for (let o = 0; o < n; o++) for (let a = 0; a < 8; a++) {
          let F = A.readBits(1);
          a < 2 || r.unshift(F);
        }
        return r.reduce((o, a, F) => o | a << F, 0);
      };
      ie = (e8, x) => {
        if (x === "uncommon-u16") return sx(e8) + 1;
        if (x === "uncommon-u8") return G(e8) + 1;
        if (typeof x == "number") return x;
        L(x), l(false);
      };
      A0 = class e5 {
        constructor(x, t, r, n, A) {
          this.bytes = x, this.view = t, this.offset = r, this.start = n, this.end = A, this.bufferPos = n - r;
        }
        static tempFromBytes(x) {
          return new e5(x, j(x), 0, 0, x.length);
        }
        get length() {
          return this.end - this.start;
        }
        get filePos() {
          return this.offset + this.bufferPos;
        }
        set filePos(x) {
          this.bufferPos = x - this.offset;
        }
        get remainingLength() {
          return Math.max(this.end - this.filePos, 0);
        }
        skip(x) {
          this.bufferPos += x;
        }
        slice(x, t = this.end - x) {
          if (x < this.start || x + t > this.end) throw new RangeError("Slicing outside of original slice.");
          return new e5(this.bytes, this.view, this.offset, x, x + t);
        }
      };
      ox = (e8, x) => {
        if (x < 0 || e8.filePos < e8.start || e8.filePos + x > e8.end) throw new RangeError(`Tried reading [${e8.filePos}, ${e8.filePos + x}), but slice is [${e8.start}, ${e8.end}). This is likely an internal error, please report it alongside the file that caused it.`);
      };
      K2 = (e8, x) => {
        ox(e8, x);
        let t = e8.bytes.subarray(e8.bufferPos, e8.bufferPos + x);
        return e8.bufferPos += x, t;
      };
      G = (e8) => (ox(e8, 1), e8.view.getUint8(e8.bufferPos++));
      sx = (e8) => {
        ox(e8, 2);
        let x = e8.view.getUint16(e8.bufferPos, false);
        return e8.bufferPos += 2, x;
      };
      ax = (e8) => {
        let x = 0;
        for (let t = 0; t < 4; t++) {
          x <<= 7;
          let r = G(e8);
          if (x |= r & 127, (r & 128) === 0) break;
        }
        return x;
      };
      se = (e8) => {
        if (G(e8) !== 3) throw new Error("Invalid esds: expected ES_Descriptor.");
        ax(e8), e8.skip(2);
        let t = G(e8), r = (t & 128) !== 0, n = (t & 64) !== 0, A = (t & 32) !== 0;
        if (r && e8.skip(2), n) {
          let f = G(e8);
          e8.skip(f);
        }
        if (A && e8.skip(2), G(e8) !== 4) throw new Error("Invalid esds: expected DecoderConfigDescriptor.");
        let s = ax(e8), o = e8.filePos, a = G(e8);
        e8.skip(12);
        let F = null;
        if (s > e8.filePos - o) {
          if (G(e8) !== 5) throw new Error("Invalid esds: expected DecoderSpecificInfo.");
          let d = ax(e8);
          F = K2(e8, d);
        }
        return { objectTypeIndication: a, decoderSpecificInfo: F };
      };
      i0 = class {
        constructor() {
          this._connectedTrack = null, this._closingPromise = null, this._closed = false, this._nominalBitrate = null;
        }
        _ensureValidAdd() {
          if (!this._connectedTrack) throw new Error("Source is not connected to an output track.");
          if (this._connectedTrack.output.state === "canceled") throw new Error("Output has been canceled.");
          if (this._connectedTrack.output.state === "finalizing" || this._connectedTrack.output.state === "finalized") throw new Error("Output has been finalized.");
          if (this._connectedTrack.output.state === "pending") throw new Error("Output has not started.");
          if (this._closed) throw new Error("Source is closed.");
        }
        async _start() {
        }
        async _flushAndClose(x) {
        }
        close() {
          if (this._closingPromise) return;
          let x = this._connectedTrack;
          if (!x) throw new Error("Cannot call close without connecting the source to an output track.");
          if (x.output.state === "pending") throw new Error("Cannot call close before output has been started.");
          this._closingPromise = (async () => {
            await this._flushAndClose(false), this._closed = true, !(x.output.state === "finalizing" || x.output.state === "finalized") && x.output._muxer.onTrackClose(x);
          })();
        }
        async _flushOrWaitForOngoingClose(x) {
          return this._closingPromise ??= (async () => {
            await this._flushAndClose(x), this._closed = true;
          })();
        }
      };
      c0 = class extends i0 {
        constructor(x) {
          if (super(), !t0.includes(x)) throw new TypeError(`Invalid video codec '${x}'. Must be one of: ${t0.join(", ")}.`);
          this._codec = x;
        }
      };
      J = class extends i0 {
        constructor(x) {
          if (super(), !U.includes(x)) throw new TypeError(`Invalid audio codec '${x}'. Must be one of: ${U.join(", ")}.`);
          this._codec = x;
        }
      };
      Fx = 2048;
      g0 = class {
        setError(x) {
          this.errorSet || (this.error = x, this.errorSet = true);
        }
        constructor(x, t) {
          this.source = x, this.encodingConfig = t, this.ensureEncoderPromise = null, this.encoderInitialized = false, this.encoder = null, this.muxer = null, this.lastNumberOfChannels = null, this.lastSampleRate = null, this.isPcmEncoder = false, this.outputSampleSize = null, this.writeOutputValue = null, this.pcmMeta = null, this.pcmStartTimestamp = 0, this.pcmEmittedFrames = 0, this.pcmReadBuffer = new ArrayBuffer(0), this.pcmScratchView = null, this.pcmScratchFrames = 0, this.customEncoder = null, this.customEncoderCallSerializer = new v0(), this.customEncoderQueueSize = 0, this.lastEndSampleIndex = null, this.resampler = null, this.error = null, this.errorSet = false, this.lastMuxerPromise = Promise.resolve(), this.closed = false;
        }
        async add(x, t) {
          try {
            if (this.checkForEncoderError(), this.source._ensureValidAdd(), this.lastNumberOfChannels !== null && this.lastSampleRate !== null) {
              if (x.numberOfChannels !== this.lastNumberOfChannels || x.sampleRate !== this.lastSampleRate) throw new Error(`Audio parameters must remain constant. Expected ${this.lastNumberOfChannels} channels at ${this.lastSampleRate} Hz, got ${x.numberOfChannels} channels at ${x.sampleRate} Hz.`);
            } else this.lastNumberOfChannels = x.numberOfChannels, this.lastSampleRate = x.sampleRate;
            let r = this.encodingConfig;
            r.transform?.numberOfChannels !== void 0 || r.transform?.sampleRate !== void 0 ? (this.resampler || (this.resampler = new j0({ targetNumberOfChannels: r.transform.numberOfChannels ?? x.numberOfChannels, targetSampleRate: r.transform.sampleRate ?? x.sampleRate, onSample: async (A) => {
              await this.processAndEncode(A, true);
            } })), await this.resampler.add(x)) : await this.processAndEncode(x, t);
          } finally {
            t && x.close();
          }
        }
        async processAndEncode(x, t) {
          let r = this.encodingConfig;
          if (r.transform?.sampleFormat !== void 0 && Kx(x.format) !== r.transform.sampleFormat) {
            let n = Jx(x, r.transform.sampleFormat);
            t && x.close(), x = n, t = true;
          }
          if (r.transform?.process) try {
            let n = r.transform.process(x);
            if (V(n) && (n = await n), n === null) return;
            Array.isArray(n) || (n = [n]);
            try {
              for (let A of n) if (!(A instanceof y)) throw new TypeError("The audio process function must return an AudioSample, null, or an array of AudioSamples.");
              for (let A of n) await this.encodeSample(A, true);
            } finally {
              for (let A of n) A instanceof y && A.close();
            }
          } finally {
            t && x.close();
          }
          else await this.encodeSample(x, t);
        }
        async encodeSample(x, t) {
          try {
            if (this.encoderInitialized || (this.ensureEncoderPromise || this.ensureEncoder(x), this.encoderInitialized || await this.ensureEncoderPromise), l(this.encoderInitialized), this.closed) return;
            {
              let r = Math.round(x.timestamp * x.sampleRate), n = Math.round((x.timestamp + x.duration) * x.sampleRate);
              if (this.lastEndSampleIndex === null) this.lastEndSampleIndex = n;
              else {
                let A = r - this.lastEndSampleIndex;
                if (A >= 64) {
                  let i = M(x.format), s = new Uint8Array(i * A * x.numberOfChannels);
                  (x.format === "u8" || x.format === "u8-planar") && s.fill(2 ** 7);
                  let o = new y({ data: s, format: x.format, sampleRate: x.sampleRate, numberOfChannels: x.numberOfChannels, numberOfFrames: A, timestamp: this.lastEndSampleIndex / x.sampleRate });
                  await this.encodeSample(o, true);
                }
                this.lastEndSampleIndex += x.numberOfFrames;
              }
            }
            if (this.encodingConfig.onEncodedSample?.(x), this.customEncoder) {
              this.customEncoderQueueSize++;
              let r = x.clone(), n = this.customEncoderCallSerializer.call(() => this.customEncoder.encode(r)).catch((A) => this.setError(A)).finally(() => {
                this.customEncoderQueueSize--, r.close();
              });
              this.customEncoderQueueSize >= 4 && await n, await this.lastMuxerPromise;
            } else if (this.isPcmEncoder) await this.doPcmEncoding(x, t);
            else {
              l(this.encoder);
              let r = x.toAudioData();
              this.encoder.encode(r), r.close(), t && x.close(), this.encoder.encodeQueueSize >= 4 && await new Promise((n) => this.encoder.addEventListener("dequeue", n, { once: true })), await this.lastMuxerPromise;
            }
          } finally {
            t && x.close();
          }
        }
        async doPcmEncoding(x, t) {
          l(this.outputSampleSize), l(this.writeOutputValue);
          let { numberOfChannels: r, numberOfFrames: n, sampleRate: A, timestamp: i } = x;
          this.pcmMeta || (this.pcmMeta = { decoderConfig: { codec: this.encodingConfig.codec, numberOfChannels: r, sampleRate: A } }, this.pcmStartTimestamp = i);
          let s = x.format === "s32" || x.format === "s32-planar", o = s ? "s32" : "f32", a = s ? 1 / 2147483648 : 1, F = x.allocationSize({ planeIndex: 0, format: o });
          this.pcmReadBuffer.byteLength < F && (this.pcmReadBuffer = new ArrayBuffer(F));
          let f = s ? new Int32Array(this.pcmReadBuffer, 0, F / 4) : new Float32Array(this.pcmReadBuffer, 0, F / 4);
          x.copyTo(f, { planeIndex: 0, format: o }), t && x.close();
          let d = 0;
          for (; d < n; ) {
            this.pcmScratchView ??= new DataView(new ArrayBuffer(Fx * r * this.outputSampleSize));
            let D = Math.min(Fx - this.pcmScratchFrames, n - d), c = this.pcmScratchFrames * r, v = d * r;
            for (let u = 0; u < D * r; u++) this.writeOutputValue(this.pcmScratchView, (c + u) * this.outputSampleSize, f[v + u] * a);
            this.pcmScratchFrames += D, d += D, this.pcmScratchFrames === Fx && await this.emitPcmScratchPacket();
          }
        }
        async emitPcmScratchPacket() {
          l(this.outputSampleSize), l(this.pcmScratchView), l(this.pcmMeta?.decoderConfig);
          let { numberOfChannels: x, sampleRate: t } = this.pcmMeta.decoderConfig, r = this.pcmScratchFrames * x * this.outputSampleSize, n = new _(new Uint8Array(this.pcmScratchView.buffer, 0, r), "key", this.pcmStartTimestamp + this.pcmEmittedFrames / t, this.pcmScratchFrames / t);
          this.pcmEmittedFrames += this.pcmScratchFrames, this.pcmScratchView = null, this.pcmScratchFrames = 0, this.encodingConfig.onEncodedPacket?.(n, this.pcmMeta), await this.muxer.addEncodedAudioPacket(this.source._connectedTrack, n, this.pcmMeta);
        }
        ensureEncoder(x) {
          this.ensureEncoderPromise = (async () => {
            let { format: t, numberOfChannels: r, sampleRate: n, timestamp: A } = x, i = ee(this.encodingConfig.quality, this.encodingConfig.bitrate), s = xe({ numberOfChannels: r, sampleRate: n, ...this.encodingConfig, quality: i });
            this.encodingConfig.onEncoderConfig?.(s), this.source._nominalBitrate = s.bitrate ?? null;
            let o = C0.find((a) => a.supports(this.encodingConfig.codec, s));
            if (o) this.customEncoder = new o(), this.customEncoder.codec = this.encodingConfig.codec, this.customEncoder.config = s, this.customEncoder.onPacket = (a, F) => {
              if (!(a instanceof _)) throw new TypeError("The first argument passed to onPacket must be an EncodedPacket.");
              if (F !== void 0 && (!F || typeof F != "object")) throw new TypeError("The second argument passed to onPacket must be an object or undefined.");
              this.encodingConfig.onEncodedPacket?.(a, F), this.lastMuxerPromise = this.muxer.addEncodedAudioPacket(this.source._connectedTrack, a, F).catch((f) => {
                this.setError(f);
              });
            }, this.customEncoder.onError = (a) => {
              this.setError(a);
            }, await this.customEncoder.init();
            else if (q.includes(this.encodingConfig.codec)) this.initPcmEncoder();
            else {
              if (typeof AudioEncoder > "u") throw new Error(bx("AudioEncoder"));
              let a;
              try {
                a = (await AudioEncoder.isConfigSupported(s)).supported ?? false;
              } catch {
                a = false;
              }
              if (!a) throw new Error(`This specific encoder configuration (${s.codec}, ${s.bitrate} bps, ${s.numberOfChannels} channels, ${s.sampleRate} Hz) is not supported in this environment. Consider using another codec or changing your audio parameters.`);
              let f = await Ue(this.encodingConfig.codec, s.codec) / s.sampleRate, d = 0, D = new Error("Encoding error").stack;
              this.encoder = new AudioEncoder({ output: (c, v) => {
                if (v?.decoderConfig && (ae(this.encodingConfig.codec, s, v.decoderConfig), this.encodingConfig.codec === "opus" && v.decoderConfig.description)) {
                  let B = I(v.decoderConfig.description);
                  d = Ox(B).preSkip / Fe;
                }
                let u = _.fromEncodedChunk(c);
                u = u.clone({ timestamp: W0(u.timestamp - f - d, s.sampleRate), duration: c.duration != null ? W0(u.duration, s.sampleRate) : void 0 }), B0() && (d = 0), this.encodingConfig.onEncodedPacket?.(u, v), this.lastMuxerPromise = this.muxer.addEncodedAudioPacket(this.source._connectedTrack, u, v).catch((B) => {
                  this.setError(B);
                });
              }, error: (c) => {
                c.stack = D, this.setError(c);
              } }), this.encoder.configure(s), this.encodingConfig.codec === "aac" && H() && oe(this.encoder, t, r, n, A);
            }
            l(this.source._connectedTrack), this.muxer = this.source._connectedTrack.output._muxer, this.encoderInitialized = true;
          })();
        }
        initPcmEncoder() {
          this.isPcmEncoder = true;
          let x = this.encodingConfig.codec, { dataType: t, sampleSize: r, littleEndian: n } = fe(x);
          switch (this.outputSampleSize = r, r) {
            case 1:
              t === "unsigned" ? this.writeOutputValue = (A, i, s) => A.setUint8(i, b(Math.round(s * 128) + 128, 0, 255)) : t === "signed" ? this.writeOutputValue = (A, i, s) => {
                A.setInt8(i, b(Math.round(s * 128), -128, 127));
              } : t === "ulaw" ? this.writeOutputValue = (A, i, s) => {
                let o = b(Math.round(s * 32768), -32768, 32767);
                A.setUint8(i, Vx(o));
              } : t === "alaw" ? this.writeOutputValue = (A, i, s) => {
                let o = b(Math.round(s * 32768), -32768, 32767);
                A.setUint8(i, $x(o));
              } : l(false);
              break;
            case 2:
              t === "unsigned" ? this.writeOutputValue = (A, i, s) => A.setUint16(i, b(Math.round(s * 32768) + 32768, 0, 65535), n) : t === "signed" ? this.writeOutputValue = (A, i, s) => A.setInt16(i, b(Math.round(s * 32768), -32768, 32767), n) : l(false);
              break;
            case 3:
              t === "unsigned" ? this.writeOutputValue = (A, i, s) => h0(A, i, b(Math.round(s * 8388608) + 8388608, 0, 16777215), n) : t === "signed" ? this.writeOutputValue = (A, i, s) => Bx(A, i, b(Math.round(s * 8388608), -8388608, 8388607), n) : l(false);
              break;
            case 4:
              t === "unsigned" ? this.writeOutputValue = (A, i, s) => A.setUint32(i, b(Math.round(s * 2147483648) + 2147483648, 0, 4294967295), n) : t === "signed" ? this.writeOutputValue = (A, i, s) => A.setInt32(i, b(Math.round(s * 2147483648), -2147483648, 2147483647), n) : t === "float" ? this.writeOutputValue = (A, i, s) => A.setFloat32(i, s, n) : l(false);
              break;
            case 8:
              t === "float" ? this.writeOutputValue = (A, i, s) => A.setFloat64(i, s, n) : l(false);
              break;
            default:
              L(r), l(false);
          }
        }
        async flushAndClose(x) {
          try {
            x || (this.checkForEncoderError(), this.resampler && await this.resampler.finalize(), this.pcmScratchFrames > 0 && await this.emitPcmScratchPacket()), this.closed = true, x || (this.customEncoder ? this.customEncoderCallSerializer.call(() => this.customEncoder.flush()) : this.encoder && await this.encoder.flush());
          } finally {
            this.closed = true, this.resampler = null, this.customEncoder ? await this.customEncoderCallSerializer.call(() => this.customEncoder.close()).catch((t) => this.setError(t)) : this.encoder && this.encoder.state !== "closed" && this.encoder.close();
          }
          x || this.checkForEncoderError();
        }
        getQueueSize() {
          return this.customEncoder ? this.customEncoderQueueSize : this.isPcmEncoder ? 0 : this.encoder?.encodeQueueSize ?? 0;
        }
        checkForEncoderError() {
          if (this.errorSet) throw this.error;
        }
      };
      fx = /* @__PURE__ */ new Map();
      Ue = (e8, x) => {
        let t = fx.get(x);
        return t || (t = (async () => {
          let A = { codec: x, numberOfChannels: 1, sampleRate: 48e3, ...E0(e8) }, i = 4096, s = 2 * i, o = "f32-planar", a = [], F = null, f = null, d = -1 / 0, D = 0, c = null, v = new AudioEncoder({ output: (h, m) => {
            m?.decoderConfig && (F ??= m.decoderConfig), a.push(h);
          }, error: (h) => {
            c ??= h;
          } }), u = new AudioDecoder({ output: (h) => {
            let m = new Float32Array(h.numberOfFrames);
            h.copyTo(m, { planeIndex: 0, format: o }), h.close();
            for (let p = 0; p < m.length; p++) m[p] > d && (d = m[p], f = D + p);
            D += m.length;
          }, error: (h) => {
            c ??= h;
          } });
          try {
            v.configure(A), e8 === "aac" && H() && oe(v, o, 1, 48e3, 0);
            let h = new Float32Array(1 * s);
            h[i] = 1;
            let m = new AudioData({ data: h, format: o, numberOfChannels: 1, numberOfFrames: s, sampleRate: 48e3, timestamp: 0 });
            v.encode(m), m.close(), await v.flush(), l(F), ae(e8, A, F), u.configure(F);
            for (let p of a) u.decode(p);
            await u.flush();
          } catch (h) {
            throw c ?? h;
          } finally {
            v.state !== "closed" && v.close(), u.state !== "closed" && u.close();
          }
          l(f !== null);
          let B = Math.round(a[0].timestamp / 1e6 * 48e3);
          return f - i + B;
        })(), fx.set(x, t), t.catch(() => fx.delete(x)), t);
      };
      oe = (e8, x, t, r, n) => {
        let i = M(x), s = new Uint8Array(i * 1024 * t);
        (x === "u8" || x === "u8-planar") && s.fill(2 ** 7);
        let o = new AudioData({ data: s, format: x, numberOfChannels: t, numberOfFrames: 1024, sampleRate: r, timestamp: Math.round(1e6 * (n - 1024 / r)) });
        e8.encode(o), o.close();
      };
      ae = (e8, x, t) => {
        if (e8 === "aac") {
          if (t.description && t.description.byteLength > 0 && I(t.description)[0] === 3) {
            let { decoderSpecificInfo: n } = se(A0.tempFromBytes(I(t.description)));
            t.description = n ?? void 0;
          }
          let r = false;
          if (!t.description || t.description.byteLength < 2 ? r = true : r = Ix(I(t.description)).objectType === 0, r) {
            let n = Number(D0(x.codec.split(".")));
            t.description = Px({ objectType: n, outputNumberOfChannels: t.numberOfChannels, outputSampleRate: t.sampleRate });
          }
        }
      };
      k0 = class extends J {
        constructor(x) {
          nx(x), super(x.codec), this._encoder = new g0(this, x);
        }
        add(x) {
          if (!(x instanceof y)) throw new TypeError("audioSample must be an AudioSample.");
          return this._encoder.add(x, false);
        }
        _flushAndClose(x) {
          return this._encoder.flushAndClose(x);
        }
      };
      w0 = class extends J {
        constructor(x, t = {}) {
          if (nx(x), typeof t != "object" || !t) throw new TypeError("options must be an object.");
          if (t.startTimestamp !== void 0 && !Number.isFinite(t.startTimestamp)) throw new TypeError("options.startTimestamp, when provided, must be a finite number.");
          super(x.codec), this._encoder = new g0(this, x), this._accumulatedTime = t.startTimestamp ?? 0;
        }
        async add(x) {
          if (!(x instanceof AudioBuffer)) throw new TypeError("audioBuffer must be an AudioBuffer.");
          let t = y._fromAudioBuffer(x, this._accumulatedTime);
          this._accumulatedTime += x.duration;
          for (let r of t) await this._encoder.add(r, true);
        }
        _flushAndClose(x) {
          return this._encoder.flushAndClose(x);
        }
      };
      l0 = class extends i0 {
        constructor(x) {
          if (super(), !r0.includes(x)) throw new TypeError(`Invalid subtitle codec '${x}'. Must be one of: ${r0.join(", ")}.`);
          this._codec = x;
        }
      };
      t0 = ["avc", "hevc", "vp9", "av1", "vp8", "prores"];
      q = ["pcm-s16", "pcm-s16be", "pcm-s24", "pcm-s24be", "pcm-s32", "pcm-s32be", "pcm-f32", "pcm-f32be", "pcm-f64", "pcm-f64be", "pcm-u8", "pcm-s8", "ulaw", "alaw"];
      ce = ["aac", "opus", "mp3", "vorbis", "flac", "ac3", "eac3", "dts", "truehd"];
      U = [...ce, ...q];
      r0 = ["webvtt"];
      u0 = ["ap4x", "ap4h", "apch", "apcn", "apcs", "apco"];
      cx = ["dtsc", "dtsh", "dtsl", "dtse"];
      te = (e8, x, t) => {
        if (e8 === "aac") return x >= 2 && t <= 24e3 ? "mp4a.40.29" : t <= 24e3 ? "mp4a.40.5" : "mp4a.40.2";
        if (e8 === "mp3") return "mp3";
        if (e8 === "opus") return "opus";
        if (e8 === "vorbis") return "vorbis";
        if (e8 === "flac") return "flac";
        if (e8 === "ac3") return "ac-3";
        if (e8 === "eac3") return "ec-3";
        if (e8 === "dts") return "dtsc";
        if (e8 === "truehd") return "mlpa";
        if (q.includes(e8)) return e8;
        throw new TypeError(`Unhandled codec '${e8}'.`);
      };
      Fe = 48e3;
      le = /^pcm-([usf])(\d+)(be)?$/;
      fe = (e8) => {
        if (l(q.includes(e8)), e8 === "ulaw") return { dataType: "ulaw", sampleSize: 1, littleEndian: true, silentValue: 255 };
        if (e8 === "alaw") return { dataType: "alaw", sampleSize: 1, littleEndian: true, silentValue: 213 };
        let x = le.exec(e8);
        l(x);
        let t;
        x[1] === "u" ? t = "unsigned" : x[1] === "s" ? t = "signed" : t = "float";
        let r = Number(x[2]) / 8, n = x[3] !== "be", A = e8 === "pcm-u8" ? 2 ** 7 : 0;
        return { dataType: t, sampleSize: r, littleEndian: n, silentValue: A };
      };
      p0 = (e8) => e8.startsWith("avc1") || e8.startsWith("avc3") ? "avc" : e8.startsWith("hev1") || e8.startsWith("hvc1") ? "hevc" : e8 === "vp8" ? "vp8" : e8.startsWith("vp09") ? "vp9" : e8.startsWith("av01") ? "av1" : u0.includes(e8) ? "prores" : e8 === "mp3" || e8 === "mp4a.69" || e8 === "mp4a.6B" || e8 === "mp4a.6b" || e8 === "mp4a.40.34" ? "mp3" : e8.startsWith("mp4a.40.") || e8 === "mp4a.67" ? "aac" : e8 === "opus" || e8 === "Opus" ? "opus" : e8 === "vorbis" ? "vorbis" : e8 === "flac" ? "flac" : e8 === "ac-3" || e8 === "ac3" ? "ac3" : e8 === "ec-3" || e8 === "eac3" ? "eac3" : cx.includes(e8) ? "dts" : e8 === "mlpa" ? "truehd" : e8 === "ulaw" ? "ulaw" : e8 === "alaw" ? "alaw" : le.test(e8) ? e8 : e8 === "webvtt" ? "webvtt" : null;
      E0 = (e8) => e8 === "aac" ? { aac: { format: "aac" } } : e8 === "opus" ? { opus: { format: "opus" } } : {};
      ze = ["avc1", "avc3", "hev1", "hvc1", "vp8", "vp09", "av01", ...u0];
      Ne = /^(avc1|avc3)\.[0-9a-fA-F]{6}$/;
      He = /^(hev1|hvc1)\.(?:[ABC]?\d+)\.[0-9a-fA-F]{1,8}\.[LH]\d+(?:\.[0-9a-fA-F]{1,2}){0,6}$/;
      We = /^vp09(?:\.\d{2}){3}(?:(?:\.\d{2}){5})?$/;
      Ke = /^av01\.\d\.\d{2}[MH]\.\d{2}(?:\.\d\.\d{3}\.\d{2}\.\d{2}\.\d{2}\.\d)?$/;
      ue = (e8, x) => {
        if (!e8) throw new TypeError("Video chunk metadata must be provided.");
        if (typeof e8 != "object") throw new TypeError("Video chunk metadata must be an object.");
        if (!e8.decoderConfig) throw new TypeError("Video chunk metadata must include a decoder configuration.");
        if (typeof e8.decoderConfig != "object") throw new TypeError("Video chunk metadata decoder configuration must be an object.");
        if (typeof e8.decoderConfig.codec != "string") throw new TypeError("Video chunk metadata decoder configuration must specify a codec string.");
        if (!ze.some((t) => e8.decoderConfig.codec.startsWith(t))) throw new TypeError("Video chunk metadata decoder configuration codec string must be a valid video codec string as specified in the Mediabunny Codec Registry.");
        if (!Number.isInteger(e8.decoderConfig.codedWidth) || e8.decoderConfig.codedWidth <= 0) throw new TypeError("Video chunk metadata decoder configuration must specify a valid codedWidth (positive integer).");
        if (!Number.isInteger(e8.decoderConfig.codedHeight) || e8.decoderConfig.codedHeight <= 0) throw new TypeError("Video chunk metadata decoder configuration must specify a valid codedHeight (positive integer).");
        if (e8.decoderConfig.displayAspectWidth !== void 0 && (!Number.isInteger(e8.decoderConfig.displayAspectWidth) || e8.decoderConfig.displayAspectWidth <= 0)) throw new TypeError("Video chunk metadata decoder configuration displayAspectWidth, when defined, must be a positive integer.");
        if (e8.decoderConfig.displayAspectHeight !== void 0 && (!Number.isInteger(e8.decoderConfig.displayAspectHeight) || e8.decoderConfig.displayAspectHeight <= 0)) throw new TypeError("Video chunk metadata decoder configuration displayAspectHeight, when defined, must be a positive integer.");
        if (e8.decoderConfig.displayAspectWidth !== void 0 != (e8.decoderConfig.displayAspectHeight !== void 0)) throw new TypeError("Video chunk metadata decoder configuration must specify both displayAspectWidth and displayAspectHeight, or neither.");
        if (e8.decoderConfig.description !== void 0 && !F0(e8.decoderConfig.description)) throw new TypeError("Video chunk metadata decoder configuration description, when defined, must be an ArrayBuffer or an ArrayBuffer view.");
        if (e8.decoderConfig.colorSpace !== void 0) {
          let { colorSpace: t } = e8.decoderConfig;
          if (typeof t != "object") throw new TypeError("Video chunk metadata decoder configuration colorSpace, when provided, must be an object.");
          let r = Object.keys(z0);
          if (t.primaries != null && !r.includes(t.primaries)) throw new TypeError(`Video chunk metadata decoder configuration colorSpace primaries, when defined, must be one of ${r.join(", ")}.`);
          let n = Object.keys(N0);
          if (t.transfer != null && !n.includes(t.transfer)) throw new TypeError(`Video chunk metadata decoder configuration colorSpace transfer, when defined, must be one of ${n.join(", ")}.`);
          let A = Object.keys(H0);
          if (t.matrix != null && !A.includes(t.matrix)) throw new TypeError(`Video chunk metadata decoder configuration colorSpace matrix, when defined, must be one of ${A.join(", ")}.`);
          if (t.fullRange != null && typeof t.fullRange != "boolean") throw new TypeError("Video chunk metadata decoder configuration colorSpace fullRange, when defined, must be a boolean.");
        }
        if (e8.decoderConfig.codec.startsWith("avc1") || e8.decoderConfig.codec.startsWith("avc3")) {
          if (!Ne.test(e8.decoderConfig.codec)) throw new TypeError("Video chunk metadata decoder configuration codec string for AVC must be a valid AVC codec string as specified in Section 3.4 of RFC 6381.");
        } else if (e8.decoderConfig.codec.startsWith("hev1") || e8.decoderConfig.codec.startsWith("hvc1")) {
          if (!He.test(e8.decoderConfig.codec)) throw new TypeError("Video chunk metadata decoder configuration codec string for HEVC must be a valid HEVC codec string as specified in Section E.3 of ISO 14496-15.");
        } else if (e8.decoderConfig.codec.startsWith("vp8")) {
          if (e8.decoderConfig.codec !== "vp8") throw new TypeError('Video chunk metadata decoder configuration codec string for VP8 must be "vp8".');
        } else if (e8.decoderConfig.codec.startsWith("vp09")) {
          if (!We.test(e8.decoderConfig.codec)) throw new TypeError('Video chunk metadata decoder configuration codec string for VP9 must be a valid VP9 codec string as specified in Section "Codecs Parameter String" of https://www.webmproject.org/vp9/mp4/.');
        } else if (e8.decoderConfig.codec.startsWith("av01")) {
          if (!Ke.test(e8.decoderConfig.codec)) throw new TypeError('Video chunk metadata decoder configuration codec string for AV1 must be a valid AV1 codec string as specified in Section "Codecs Parameter String" of https://aomediacodec.github.io/av1-isobmff/.');
        } else if (u0.some((t) => e8.decoderConfig.codec.startsWith(t)) && !u0.some((t) => e8.decoderConfig.codec === t)) throw new TypeError(`Video chunk metadata decoder configuration codec string for ProRes must be one of the valid ProRes four-character codes: ${u0.join(", ")}.`);
        if (x !== null && p0(e8.decoderConfig.codec) !== x) throw new TypeError(`Video chunk metadata decoder configuration codec string '${e8.decoderConfig.codec}' does not fit to the track codec '${x}'.`);
      };
      Je = ["mp4a", "mp3", "opus", "vorbis", "flac", "ulaw", "alaw", "pcm", "ac-3", "ec-3", "dts", "mlpa"];
      d0 = (e8, x) => {
        if (!e8) throw new TypeError("Audio chunk metadata must be provided.");
        if (typeof e8 != "object") throw new TypeError("Audio chunk metadata must be an object.");
        if (!e8.decoderConfig) throw new TypeError("Audio chunk metadata must include a decoder configuration.");
        if (typeof e8.decoderConfig != "object") throw new TypeError("Audio chunk metadata decoder configuration must be an object.");
        if (typeof e8.decoderConfig.codec != "string") throw new TypeError("Audio chunk metadata decoder configuration must specify a codec string.");
        if (!Je.some((t) => e8.decoderConfig.codec.startsWith(t))) throw new TypeError("Audio chunk metadata decoder configuration codec string must be a valid audio codec string as specified in the Mediabunny Codec Registry.");
        if (!Number.isInteger(e8.decoderConfig.sampleRate) || e8.decoderConfig.sampleRate <= 0) throw new TypeError("Audio chunk metadata decoder configuration must specify a valid sampleRate (positive integer).");
        if (!Number.isInteger(e8.decoderConfig.numberOfChannels) || e8.decoderConfig.numberOfChannels <= 0) throw new TypeError("Audio chunk metadata decoder configuration must specify a valid numberOfChannels (positive integer).");
        if (e8.decoderConfig.description !== void 0 && !F0(e8.decoderConfig.description)) throw new TypeError("Audio chunk metadata decoder configuration description, when defined, must be an ArrayBuffer or an ArrayBuffer view.");
        if (e8.decoderConfig.codec.startsWith("mp4a") && e8.decoderConfig.codec !== "mp4a.69" && e8.decoderConfig.codec !== "mp4a.6B" && e8.decoderConfig.codec !== "mp4a.6b") {
          if (!["mp4a.40.2", "mp4a.40.02", "mp4a.40.5", "mp4a.40.05", "mp4a.40.29", "mp4a.67"].includes(e8.decoderConfig.codec)) throw new TypeError("Audio chunk metadata decoder configuration codec string for AAC must be a valid AAC codec string as specified in https://www.w3.org/TR/webcodecs-aac-codec-registration/.");
        } else if (e8.decoderConfig.codec.startsWith("mp3") || e8.decoderConfig.codec.startsWith("mp4a")) {
          if (e8.decoderConfig.codec !== "mp3" && e8.decoderConfig.codec !== "mp4a.69" && e8.decoderConfig.codec !== "mp4a.6B" && e8.decoderConfig.codec !== "mp4a.6b") throw new TypeError('Audio chunk metadata decoder configuration codec string for MP3 must be "mp3", "mp4a.69" or "mp4a.6B".');
        } else if (e8.decoderConfig.codec.startsWith("opus")) {
          if (e8.decoderConfig.codec !== "opus") throw new TypeError('Audio chunk metadata decoder configuration codec string for Opus must be "opus".');
          if (e8.decoderConfig.description && e8.decoderConfig.description.byteLength < 18) throw new TypeError("Audio chunk metadata decoder configuration description, when specified, is expected to be an Identification Header as specified in Section 5.1 of RFC 7845.");
        } else if (e8.decoderConfig.codec.startsWith("vorbis")) {
          if (e8.decoderConfig.codec !== "vorbis") throw new TypeError('Audio chunk metadata decoder configuration codec string for Vorbis must be "vorbis".');
          if (!e8.decoderConfig.description) throw new TypeError("Audio chunk metadata decoder configuration for Vorbis must include a description, which is expected to adhere to the format described in https://www.w3.org/TR/webcodecs-vorbis-codec-registration/.");
        } else if (e8.decoderConfig.codec.startsWith("flac")) {
          if (e8.decoderConfig.codec !== "flac") throw new TypeError('Audio chunk metadata decoder configuration codec string for FLAC must be "flac".');
          if (!e8.decoderConfig.description || e8.decoderConfig.description.byteLength < 42) throw new TypeError("Audio chunk metadata decoder configuration for FLAC must include a description, which is expected to adhere to the format described in https://www.w3.org/TR/webcodecs-flac-codec-registration/.");
        } else if (e8.decoderConfig.codec.startsWith("ac-3") || e8.decoderConfig.codec.startsWith("ac3")) {
          if (e8.decoderConfig.codec !== "ac-3") throw new TypeError('Audio chunk metadata decoder configuration codec string for AC-3 must be "ac-3".');
        } else if (e8.decoderConfig.codec.startsWith("ec-3") || e8.decoderConfig.codec.startsWith("eac3")) {
          if (e8.decoderConfig.codec !== "ec-3") throw new TypeError('Audio chunk metadata decoder configuration codec string for EC-3 must be "ec-3".');
        } else if (e8.decoderConfig.codec.startsWith("dts")) {
          if (!cx.includes(e8.decoderConfig.codec)) throw new TypeError(`Audio chunk metadata decoder configuration codec string for DTS must be one of the following four-character codes: ${cx.join(", ")}.`);
        } else if (e8.decoderConfig.codec.startsWith("mlpa")) {
          if (e8.decoderConfig.codec !== "mlpa") throw new TypeError('Audio chunk metadata decoder configuration codec string for TrueHD must be "mlpa".');
        } else if ((e8.decoderConfig.codec.startsWith("pcm") || e8.decoderConfig.codec.startsWith("ulaw") || e8.decoderConfig.codec.startsWith("alaw")) && !q.includes(e8.decoderConfig.codec)) throw new TypeError(`Audio chunk metadata decoder configuration codec string for PCM must be one of the supported PCM codecs (${q.join(", ")}).`);
        if (x !== null && p0(e8.decoderConfig.codec) !== x) throw new TypeError(`Audio chunk metadata decoder configuration codec string '${e8.decoderConfig.codec}' does not fit to the track codec '${x}'.`);
      };
      y0 = class {
        constructor(x) {
          this.mutex = new Y(), this.trackPacketOrderValidators = /* @__PURE__ */ new WeakMap(), this.output = x;
        }
        onTrackClose(x) {
        }
        validateTimestamp(x, t, r) {
          let n = this.trackPacketOrderValidators.get(x);
          n || (n = new lx(), this.trackPacketOrderValidators.set(x, n));
          let A = r ? "key" : "delta";
          if (n.digest(t, A)) return;
          if (n.maxTimestamp === null) throw new Error("First packet must be a key packet.");
          let i = A === "key" ? n.maxTimestamp : n.maxTimestampBeforeLastKeyPacket;
          throw new Error(`Timestamps cannot be smaller than the largest timestamp of the previous GOP (a GOP begins with a key packet and ends right before the next key packet). Got ${t}s, but largest timestamp is ${i}s.`);
        }
      };
      lx = class {
        constructor() {
          this.maxTimestamp = null, this.maxTimestampBeforeLastKeyPacket = null;
        }
        check(x, t) {
          if (this.maxTimestamp === null) return t === "key";
          let r = t === "key" ? this.maxTimestamp : this.maxTimestampBeforeLastKeyPacket;
          return r === null || x >= r;
        }
        digest(x, t) {
          return this.check(x, t) ? (t === "key" && (this.maxTimestampBeforeLastKeyPacket = this.maxTimestamp), this.maxTimestamp = Math.max(this.maxTimestamp ?? -1 / 0, x), true) : false;
        }
      };
      de = new Uint8Array([102, 76, 97, 67]);
      Xe = 38;
      Qe = 34;
      T0 = class extends y0 {
        constructor(x, t) {
          super(x), this.metadataWritten = false, this.blockSizes = [], this.frameSizes = [], this.sampleRate = null, this.channels = null, this.bitsPerSample = null, this.format = t;
        }
        async start() {
          let x = await this.mutex.acquire();
          this.writer = await this.output._getRootWriter(!!this.format._options.appendOnly), this.writer.write(de);
          let t = this.output.tracks[0];
          l(t?.isAudioTrack()), t.metadata.decoderConfig && (d0({ decoderConfig: t.metadata.decoderConfig }, t.source._codec), this.applyDecoderConfig(t.metadata.decoderConfig)), x();
        }
        applyDecoderConfig(x) {
          l(x.description), this.sampleRate = x.sampleRate, this.channels = x.numberOfChannels;
          let t = new w(I(x.description));
          t.skipBits(167), this.bitsPerSample = t.readBits(5) + 1, this.format._options.appendOnly && this.writeHeader({ minimumBlockSize: 16, maximumBlockSize: 65535, minimumFrameSize: 0, maximumFrameSize: 0, sampleRate: this.sampleRate, channels: this.channels, bitsPerSample: this.bitsPerSample, totalSamples: 0 });
        }
        writeHeader({ bitsPerSample: x, minimumBlockSize: t, maximumBlockSize: r, minimumFrameSize: n, maximumFrameSize: A, sampleRate: i, channels: s, totalSamples: o }) {
          l(this.writer.getPos() === 4);
          let a = !Q0(this.output._metadataTags), F = new w(new Uint8Array(4));
          F.writeBits(1, +!a), F.writeBits(7, x0.STREAMINFO), F.writeBits(24, Qe), this.writer.write(F.bytes);
          let f = new w(new Uint8Array(18));
          if (f.writeBits(16, t), f.writeBits(16, r), f.writeBits(24, n), f.writeBits(24, A), f.writeBits(20, i), f.writeBits(3, s - 1), f.writeBits(5, x - 1), o >= 2 ** 32) throw new Error("This muxer only supports writing up to 2 ** 32 samples");
          f.writeBits(4, 0), f.writeBits(32, o), this.writer.write(f.bytes), this.writer.write(new Uint8Array(16));
        }
        writePictureBlock(x) {
          let t = 32 + x.mimeType.length + (x.description?.length ?? 0) + x.data.length, r = new Uint8Array(t), n = 0, A = j(r);
          A.setUint32(n, x.kind === "coverFront" ? 3 : x.kind === "coverBack" ? 4 : 0), n += 4, A.setUint32(n, x.mimeType.length), n += 4, r.set(N.encode(x.mimeType), 8), n += x.mimeType.length, A.setUint32(n, x.description?.length ?? 0), n += 4, r.set(N.encode(x.description ?? ""), n), n += x.description?.length ?? 0, n += 16, A.setUint32(n, x.data.length), n += 4, r.set(x.data, n), n += x.data.length, l(n === t);
          let i = new w(new Uint8Array(4));
          i.writeBits(1, 0), i.writeBits(7, x0.PICTURE), i.writeBits(24, t), this.writer.write(i.bytes), this.writer.write(r);
        }
        writeVorbisCommentAndPictureBlock() {
          if (this.format._options.appendOnly || this.writer.seek(Xe + de.byteLength), Q0(this.output._metadataTags)) {
            this.metadataWritten = true;
            return;
          }
          let x = this.output._metadataTags.images ?? [];
          for (let n of x) this.writePictureBlock(n);
          let t = Lx(new Uint8Array(0), this.output._metadataTags, false), r = new w(new Uint8Array(4));
          r.writeBits(1, 1), r.writeBits(7, x0.VORBIS_COMMENT), r.writeBits(24, t.length), this.writer.write(r.bytes), this.writer.write(t), this.metadataWritten = true;
        }
        async getMimeType() {
          return "audio/flac";
        }
        async addEncodedVideoPacket() {
          throw new Error("FLAC does not support video.");
        }
        async addEncodedAudioPacket(x, t, r) {
          let n = await this.mutex.acquire();
          try {
            this.validateTimestamp(x, t.timestamp, t.type === "key"), this.sampleRate === null && (d0(r, x.source._codec), l(r), l(r.decoderConfig), this.applyDecoderConfig(r.decoderConfig)), this.metadataWritten || this.writeVorbisCommentAndPictureBlock();
            let A = A0.tempFromBytes(t.data);
            A.skip(2);
            let i = K2(A, 2), s = new w(i), o = ne(s.readBits(4));
            if (o === null) throw new Error("Invalid FLAC frame: Invalid block size.");
            Ae(A);
            let a = ie(A, o);
            this.format._options.appendOnly || (this.blockSizes.push(a), this.frameSizes.push(t.data.length));
            let F = this.writer.getPos();
            this.writer.write(t.data), this.format._options.onFrame && this.format._options.onFrame(t.data, F), await this.writer.flush();
          } finally {
            n();
          }
        }
        addSubtitleCue() {
          throw new Error("FLAC does not support subtitles.");
        }
        async finalize() {
          let x = await this.mutex.acquire();
          if (this.sampleRate === null) throw new Error("Cannot finalize an empty FLAC file: no packets were added and the track specified no decoderConfig in its metadata, so there's no telling what the file should look like.");
          if (this.metadataWritten || this.writeVorbisCommentAndPictureBlock(), !this.format._options.appendOnly) {
            let t = 1 / 0, r = 0, n = 1 / 0, A = 0, i = 0;
            for (let s = 0; s < this.blockSizes.length; s++) n = Math.min(n, this.frameSizes[s]), A = Math.max(A, this.frameSizes[s]), r = Math.max(r, this.blockSizes[s]), i += this.blockSizes[s], s !== this.blockSizes.length - 1 && (t = Math.min(t, this.blockSizes[s]));
            this.blockSizes.length === 0 && (t = 16, r = 65535, n = 0, A = 0), l(this.channels !== null), l(this.bitsPerSample !== null), this.writer.seek(4), this.writeHeader({ minimumBlockSize: t, maximumBlockSize: r, minimumFrameSize: n, maximumFrameSize: A, sampleRate: this.sampleRate, channels: this.channels, bitsPerSample: this.bitsPerSample, totalSamples: i });
          }
          x();
        }
      };
      _0 = class {
        constructor(x, t) {
          if (this.finalized = false, this.started = false, this.pos = 0, this.trackedWrites = null, this.trackedStart = -1, this.trackedEnd = -1, x._writerAcquired) throw new Error("Can't have multiple Writers for the same Target.");
          this.target = x, x._setMonotonicity(t), x._writerAcquired = true;
        }
        start() {
          l(!this.started), this.target._start(), this.started = true;
        }
        write(x) {
          l(this.started && !this.finalized), this.maybeTrackWrites(x), this.target._write(x, this.pos), this.pos += x.byteLength;
        }
        seek(x) {
          this.pos = x;
        }
        getPos() {
          return this.pos;
        }
        async flush() {
          return l(this.started && !this.finalized), this.target._flush();
        }
        async finalize() {
          l(this.started && !this.finalized), await this.target._finalize(), this.finalized = true;
        }
        maybeTrackWrites(x) {
          if (!this.trackedWrites) return;
          let t = this.getPos();
          if (t < this.trackedStart) {
            if (t + x.byteLength <= this.trackedStart) return;
            x = x.subarray(this.trackedStart - t), t = 0;
          }
          let r = t + x.byteLength - this.trackedStart, n = this.trackedWrites.byteLength;
          for (; n < r; ) n *= 2;
          if (n !== this.trackedWrites.byteLength) {
            let A = new Uint8Array(n);
            A.set(this.trackedWrites, 0), this.trackedWrites = A;
          }
          this.trackedWrites.set(x, t - this.trackedStart), this.trackedEnd = Math.max(this.trackedEnd, t + x.byteLength);
        }
        startTrackingWrites() {
          this.trackedWrites = new Uint8Array(2 ** 10), this.trackedStart = this.getPos(), this.trackedEnd = this.trackedStart;
        }
        stopTrackingWrites() {
          if (!this.trackedWrites) throw new Error("Internal error: Can't get tracked writes since nothing was tracked.");
          let t = { data: this.trackedWrites.subarray(0, this.trackedEnd - this.trackedStart), start: this.trackedStart, end: this.trackedEnd };
          return this.trackedWrites = null, t;
        }
      };
      T = class extends O {
        constructor() {
          super(...arguments), this._writerAcquired = false, this._monotonicity = null, this.onwrite = null;
        }
        _setMonotonicity(x) {
          this._monotonicity !== false && (this._monotonicity = x);
        }
        _dispatchWrite(x, t) {
          this.onwrite?.(x, t), this._emit("write", { start: x, end: t });
        }
        slice(x) {
          if (!Number.isInteger(x) || x < 0) throw new TypeError("offset must be a non-negative integer.");
          return new I0(this, x);
        }
      };
      ux = 2 ** 16;
      dx = 2 ** 32;
      S0 = class extends T {
        constructor(x = {}) {
          if (super(), this.buffer = null, this._maxPos = 0, !x || typeof x != "object") throw new TypeError("BufferTarget options, when provided, must be an object.");
          if (x.onFinalize !== void 0 && typeof x.onFinalize != "function") throw new TypeError("options.onFinalize, when provided, must be a function.");
          if (this._options = x, this._supportsResize = "resize" in new ArrayBuffer(0), this._supportsResize) try {
            this._buffer = new ArrayBuffer(ux, { maxByteLength: dx });
          } catch {
            this._buffer = new ArrayBuffer(ux), this._supportsResize = false;
          }
          else this._buffer = new ArrayBuffer(ux);
          this._bytes = new Uint8Array(this._buffer);
        }
        _ensureSize(x) {
          l(this._buffer), l(this._bytes);
          let t = this._buffer.byteLength;
          for (; t < x; ) t *= 2;
          if (t !== this._buffer.byteLength) {
            if (t > dx) throw new Error(`ArrayBuffer exceeded maximum size of ${dx} bytes. Please consider using another target.`);
            if (this._supportsResize) this._buffer.resize(t);
            else {
              let r = new ArrayBuffer(t), n = new Uint8Array(r);
              n.set(this._bytes, 0), this._buffer = r, this._bytes = n;
            }
          }
        }
        _start() {
        }
        _write(x, t) {
          l(this._bytes), this._ensureSize(t + x.byteLength), this._bytes.set(x, t), this._maxPos = Math.max(this._maxPos, t + x.byteLength), this._dispatchWrite(t, t + x.byteLength);
        }
        async _flush() {
        }
        async _finalize() {
          l(this._buffer), "transferToFixedLength" in this._buffer ? this.buffer = this._buffer.transferToFixedLength(this._maxPos) : this.buffer = this._buffer.slice(0, this._maxPos), this._buffer = null, this._bytes = null, this._options.onFinalize && await this._options.onFinalize(this.buffer), this._emit("finalized");
        }
        async _close() {
        }
        _getSlice(x, t) {
          return l(this._bytes), this._bytes.slice(x, t);
        }
      };
      fn = 2 ** 24;
      I0 = class extends T {
        constructor(x, t) {
          super(), this._baseTarget = x, this._offset = t;
        }
        _start() {
        }
        _write(x, t) {
          this._baseTarget._write(x, this._offset + t), this._dispatchWrite(t, t + x.byteLength);
        }
        _flush() {
          return this._baseTarget._flush();
        }
        async _finalize() {
          this._emit("finalized");
        }
        async _close() {
        }
        _setMonotonicity(x) {
          super._setMonotonicity(x), this._baseTarget._setMonotonicity(x);
        }
      };
      X = class {
        constructor(x, t) {
          if (this.rootPath = x, this.getTarget = t, typeof x != "string") throw new TypeError("rootPath must be a string.");
          if (typeof t != "function") throw new TypeError("getTarget must be a function.");
        }
      };
      s0 = class {
        get supportsVideoRotationMetadata() {
          return this.supportsVideoTransformationMetadata;
        }
        get requiresMaximumPacketCount() {
          return false;
        }
        getSupportedVideoCodecs() {
          return this.getSupportedCodecs().filter((x) => t0.includes(x));
        }
        getSupportedAudioCodecs() {
          return this.getSupportedCodecs().filter((x) => U.includes(x));
        }
        getSupportedSubtitleCodecs() {
          return this.getSupportedCodecs().filter((x) => r0.includes(x));
        }
        _codecUnsupportedHint(x) {
          return "";
        }
        _isFragmentedIsobmff() {
          return false;
        }
      };
      P0 = class extends s0 {
        constructor(x = {}) {
          if (!x || typeof x != "object") throw new TypeError("options must be an object.");
          if (x.appendOnly !== void 0 && typeof x.appendOnly != "boolean") throw new TypeError("options.appendOnly, when provided, must be a boolean.");
          super(), this._options = x;
        }
        _createMuxer(x) {
          return new T0(x, this);
        }
        get _name() {
          return "FLAC";
        }
        getSupportedTrackCounts() {
          return { video: { min: 0, max: 0 }, audio: { min: 1, max: 1 }, subtitle: { min: 0, max: 0 }, total: { min: 1, max: 1 } };
        }
        get fileExtension() {
          return ".flac";
        }
        get mimeType() {
          return "audio/flac";
        }
        getSupportedCodecs() {
          return ["flac"];
        }
        get supportsVideoTransformationMetadata() {
          return false;
        }
        get supportsTimestampedMediaData() {
          return false;
        }
        get negativeTimestampSupport() {
          return null;
        }
      };
      ve = ["video", "audio", "subtitle"];
      o0 = class e6 {
        constructor(x, t, r, n, A) {
          this.id = x, this.output = t, this.type = r, this.source = n, this.metadata = A;
        }
        isVideoTrack() {
          return this.type === "video";
        }
        isAudioTrack() {
          return this.type === "audio";
        }
        isSubtitleTrack() {
          return this.type === "subtitle";
        }
        canBePairedWith(x) {
          if (!(x instanceof e6)) throw new TypeError("other must be an OutputTrack.");
          if (this === x) return false;
          let t = K0(this.metadata.group), r = K0(x.metadata.group);
          for (let n of t) if (this.type !== x.type && r.some((s) => n === s) || r.some((s) => n._pairedGroups.has(s))) return true;
          return false;
        }
      };
      M0 = class extends o0 {
        constructor(x, t, r, n) {
          super(x, t, "video", r, n);
        }
      };
      q0 = class extends o0 {
        constructor(x, t, r, n) {
          super(x, t, "audio", r, n);
        }
      };
      R0 = class extends o0 {
        constructor(x, t, r, n) {
          super(x, t, "subtitle", r, n);
        }
      };
      a0 = class e7 {
        constructor() {
          this._pairedGroups = /* @__PURE__ */ new Set();
        }
        pairWith(x) {
          if (!(x instanceof e7)) throw new TypeError("other must be an OutputTrackGroup.");
          if (this === x) throw new TypeError("Cannot pair a group with itself.");
          this._pairedGroups.add(x), x._pairedGroups.add(this);
        }
      };
      vx = (e8) => {
        if (!e8 || typeof e8 != "object") throw new TypeError("metadata must be an object.");
        if (e8.languageCode !== void 0 && !px(e8.languageCode)) throw new TypeError("metadata.languageCode, when provided, must be a three-letter, ISO 639-2/T language code.");
        if (e8.name !== void 0 && typeof e8.name != "string") throw new TypeError("metadata.name, when provided, must be a string.");
        if (e8.disposition !== void 0 && yx(e8.disposition), e8.maximumPacketCount !== void 0 && (!Number.isInteger(e8.maximumPacketCount) || e8.maximumPacketCount < 0)) throw new TypeError("metadata.maximumPacketCount, when provided, must be a non-negative integer.");
        if (e8.bitrate !== void 0 && (!Number.isFinite(e8.bitrate) || e8.bitrate < 0)) throw new TypeError("metadata.bitrate, when provided, must be a non-negative number.");
        if (e8.averageBitrate !== void 0 && (!Number.isFinite(e8.averageBitrate) || e8.averageBitrate < 0)) throw new TypeError("metadata.averageBitrate, when provided, must be a non-negative number.");
        if (e8.group !== void 0 && !(e8.group instanceof a0) && (!Array.isArray(e8.group) || e8.group.some((x) => !(x instanceof a0)))) throw new TypeError("metadata.group, when provided, must be an OutputTrackGroup instance or an array of OutputTrackGroup instances.");
      };
      G0 = class extends O {
        get target() {
          let x = "Output.target cannot be used when using PathedTarget with an async callback. Use the 'target' event instead.";
          if (this._rootTargetPromise) throw new TypeError(x);
          let t = this._getRootTarget();
          if (V(t)) throw new TypeError(x);
          return t;
        }
        constructor(x) {
          if (super(), this.state = "pending", this.defaultTrackGroup = new a0(), this.tracks = [], this._onFinalize = null, this._unfinalizedTargets = /* @__PURE__ */ new Set(), this._rootWriterPromise = null, this._startPromise = null, this._cancelPromise = null, this._finalizePromise = null, this._mutex = new Y(), this._metadataTags = {}, this._rootTarget = null, this._rootTargetPromise = null, this._firstMediaStreamTimestamp = null, !x || typeof x != "object") throw new TypeError("options must be an object.");
          if (!(x.format instanceof s0)) throw new TypeError("options.format must be an OutputFormat.");
          if (!(x.target instanceof T || x.target instanceof X)) throw new TypeError("options.target must be a Target or a PathedTarget.");
          if (x.target instanceof T && this._rememberTarget(x.target), x.initTarget !== void 0 && !(x.initTarget instanceof T) && typeof x.initTarget != "function") throw new Error("options.initTarget, when provided, must be a Target or a function that returns or resolves to a Target.");
          if (x.onFinalize !== void 0 && typeof x.onFinalize != "function") throw new TypeError("options.onFinalize, when provided, must be a function.");
          this.format = x.format, this._target = x.target, this._onFinalize = x.onFinalize ?? null, this._initTarget = x.initTarget ?? null, this._initTarget instanceof T && this._rememberTarget(this._initTarget), this._muxer = x.format._createMuxer(this);
        }
        _getTargetValidated(x) {
          l(this._target instanceof X);
          let t = this._target.getTarget(x), r = (n) => {
            if (!(n instanceof T)) throw new TypeError("getTarget must return a Target.");
            return n;
          };
          return V(t) ? t.then(r) : r(t);
        }
        async _getTarget(x) {
          l(this._target instanceof X);
          let t = await this._getTargetValidated(x);
          return this._emit("target", { target: t, request: x, isRoot: x.isRoot }), this.state === "canceled" ? await t._close() : this._rememberTarget(t), t;
        }
        _rememberTarget(x) {
          this._unfinalizedTargets.add(x), x.on("finalized", () => this._unfinalizedTargets.delete(x), { once: true });
        }
        async _getInitTarget() {
          if (l(this._initTarget !== null), this._initTarget instanceof T) return this._initTarget;
          let x = await this._initTarget();
          return this.state === "canceled" ? await x._close() : this._rememberTarget(x), x;
        }
        _hasInitTarget() {
          return this._initTarget !== null;
        }
        _getRootTarget() {
          if (this._rootTarget) return this._rootTarget;
          if (this._rootTargetPromise) return this._rootTargetPromise;
          if (this._target instanceof T) return this._emit("target", { target: this._target, request: null, isRoot: true }), this._rootTarget = this._target, this._target;
          let x = { path: this._target.rootPath, isRoot: true, mimeType: this.format.mimeType }, t = this._getTargetValidated(x), r = (n) => (this.state === "canceled" ? n._close() : this._rememberTarget(n), this._emit("target", { target: n, request: x, isRoot: true }), this._rootTarget = n, n);
          return V(t) ? this._rootTargetPromise = t.then(r) : r(t);
        }
        _getRootWriter(x) {
          return this._rootWriterPromise ??= (async () => {
            let t = await this._getRootTarget(), r = new _0(t, typeof x == "boolean" ? x : x(t));
            return r.start(), r;
          })();
        }
        addVideoTrack(x, t = {}) {
          if (!(x instanceof c0)) throw new TypeError("source must be a VideoSource.");
          if (vx(t), t.rotation !== void 0 && ![0, 90, 180, 270].includes(t.rotation)) throw new TypeError(`Invalid video rotation: ${t.rotation}. Has to be 0, 90, 180 or 270.`);
          if (t.flip !== void 0 && typeof t.flip != "boolean") throw new TypeError("metadata.flip, when provided, must be a boolean.");
          if (t.transformationMatrix !== void 0 && (!Array.isArray(t.transformationMatrix) || t.transformationMatrix.length !== 9 || !t.transformationMatrix.every((n) => Number.isFinite(n)))) throw new TypeError("metadata.transformationMatrix, when provided, must be an array of 9 finite numbers.");
          if (t.frameRate !== void 0 && (!Number.isFinite(t.frameRate) || t.frameRate <= 0)) throw new TypeError(`Invalid video frame rate: ${t.frameRate}. Must be a positive number.`);
          if (t.hasOnlyKeyPackets !== void 0 && typeof t.hasOnlyKeyPackets != "boolean") throw new TypeError("metadata.hasOnlyKeyPackets, when provided, must be a boolean.");
          if (t.canBeTransparent !== void 0 && typeof t.canBeTransparent != "boolean") throw new TypeError("metadata.canBeTransparent, when provided, must be a boolean.");
          if (t.decoderConfig !== void 0 && ue({ decoderConfig: t.decoderConfig }, x._codec), t.primingPacket !== void 0) {
            if (!(t.primingPacket instanceof _)) throw new TypeError("metadata.primingPacket, when provided, must be an EncodedPacket.");
            if (t.decoderConfig === void 0) throw new TypeError("metadata.primingPacket can only be provided alongside metadata.decoderConfig.");
          }
          let r = { ...t };
          return r.group ??= this.defaultTrackGroup, this._addTrack(new M0(this.tracks.length + 1, this, x, r));
        }
        addAudioTrack(x, t = {}) {
          if (!(x instanceof J)) throw new TypeError("source must be an AudioSource.");
          if (vx(t), t.decoderConfig !== void 0 && d0({ decoderConfig: t.decoderConfig }, x._codec), t.primingPacket !== void 0) {
            if (!(t.primingPacket instanceof _)) throw new TypeError("metadata.primingPacket, when provided, must be an EncodedPacket.");
            if (t.decoderConfig === void 0) throw new TypeError("metadata.primingPacket can only be provided alongside metadata.decoderConfig.");
          }
          let r = { ...t };
          return r.group ??= this.defaultTrackGroup, this._addTrack(new q0(this.tracks.length + 1, this, x, r));
        }
        addSubtitleTrack(x, t = {}) {
          if (!(x instanceof l0)) throw new TypeError("source must be a SubtitleSource.");
          vx(t);
          let r = { ...t };
          return r.group ??= this.defaultTrackGroup, this._addTrack(new R0(this.tracks.length + 1, this, x, r));
        }
        setMetadataTags(x) {
          if (wx(x), this.state !== "pending") throw new Error("Cannot set metadata tags after output has been started or canceled.");
          this._metadataTags = x;
        }
        _addTrack(x) {
          if (this.state !== "pending") throw new Error("Cannot add track after output has been started or canceled.");
          if (x.source._connectedTrack) throw new Error("Source is already used for a track.");
          let t = this.format.getSupportedTrackCounts(), r = this.tracks.reduce((i, s) => i + (s.type === x.type ? 1 : 0), 0), n = t[x.type].max;
          if (r === n) throw new Error(n === 0 ? `${this.format._name} does not support ${x.type} tracks.` : `${this.format._name} does not support more than ${n} ${x.type} track${n === 1 ? "" : "s"}.`);
          let A = t.total.max;
          if (this.tracks.length === A) throw new Error(`${this.format._name} does not support more than ${A} tracks${A === 1 ? "" : "s"} in total.`);
          if (x.isVideoTrack()) {
            let i = this.format.getSupportedVideoCodecs();
            if (i.length === 0) throw new Error(`${this.format._name} does not support video tracks.` + this.format._codecUnsupportedHint(x.source._codec));
            if (!i.includes(x.source._codec)) throw new Error(`Codec '${x.source._codec}' cannot be contained within ${this.format._name}. Supported video codecs are: ${i.map((s) => `'${s}'`).join(", ")}.` + this.format._codecUnsupportedHint(x.source._codec));
          } else if (x.isAudioTrack()) {
            let i = this.format.getSupportedAudioCodecs();
            if (i.length === 0) throw new Error(`${this.format._name} does not support audio tracks.` + this.format._codecUnsupportedHint(x.source._codec));
            if (!i.includes(x.source._codec)) throw new Error(`Codec '${x.source._codec}' cannot be contained within ${this.format._name}. Supported audio codecs are: ${i.map((s) => `'${s}'`).join(", ")}.` + this.format._codecUnsupportedHint(x.source._codec));
          } else if (x.isSubtitleTrack()) {
            let i = this.format.getSupportedSubtitleCodecs();
            if (i.length === 0) throw new Error(`${this.format._name} does not support subtitle tracks.` + this.format._codecUnsupportedHint(x.source._codec));
            if (!i.includes(x.source._codec)) throw new Error(`Codec '${x.source._codec}' cannot be contained within ${this.format._name}. Supported subtitle codecs are: ${i.map((s) => `'${s}'`).join(", ")}.` + this.format._codecUnsupportedHint(x.source._codec));
          }
          return this.tracks.push(x), x.source._connectedTrack = x, x;
        }
        hasEnoughTracks() {
          let x = this.format.getSupportedTrackCounts();
          for (let r of ve) {
            let n = this.tracks.reduce((i, s) => i + (s.type === r ? 1 : 0), 0), A = x[r].min;
            if (n < A) return false;
          }
          let t = x.total.min;
          return !(this.tracks.length < t);
        }
        async start() {
          let x = this.format.getSupportedTrackCounts();
          for (let r of ve) {
            let n = this.tracks.reduce((i, s) => i + (s.type === r ? 1 : 0), 0), A = x[r].min;
            if (n < A) throw new Error(A === x[r].max ? `${this.format._name} requires exactly ${A} ${r} track${A === 1 ? "" : "s"}.` : `${this.format._name} requires at least ${A} ${r} track${A === 1 ? "" : "s"}.`);
          }
          let t = x.total.min;
          if (this.tracks.length < t) throw new Error(t === x.total.max ? `${this.format._name} requires exactly ${t} track${t === 1 ? "" : "s"}.` : `${this.format._name} requires at least ${t} track${t === 1 ? "" : "s"}.`);
          if (this.state === "canceled") throw new Error("Output has been canceled.");
          return this._startPromise ? (C._warn("Output has already been started."), this._startPromise) : this._startPromise = (async () => {
            this.state = "started";
            let r = this._mutex.acquire();
            try {
              await this._muxer.start();
              let n = this.tracks.map((A) => A.source._start());
              await Promise.all(n);
            } finally {
              (await r)();
            }
          })();
        }
        getMimeType() {
          return this._muxer.getMimeType();
        }
        async cancel() {
          if (this.state === "canceled") return this._cancelPromise ?? void 0;
          if (this.state === "finalizing" || this.state === "finalized") {
            this.state === "finalized" && C._warn("Output has already been finalized.");
            return;
          }
          return this._cancelPromise = (async () => {
            this.state = "canceled";
            let x = await this._mutex.acquire();
            try {
              let t = this.tracks.map((r) => r.source._flushOrWaitForOngoingClose(true));
              await Promise.all(t), await Promise.all([...this._unfinalizedTargets].map((r) => r._close())), this._unfinalizedTargets.clear();
            } finally {
              x();
            }
          })();
        }
        async finalize() {
          if (this.state === "pending") throw new Error("Cannot finalize before starting.");
          if (this.state === "canceled") throw new Error("Cannot finalize after canceling.");
          return this._finalizePromise ? (C._warn("Output has already been finalized."), this._finalizePromise) : this._finalizePromise = (async () => {
            this.state = "finalizing";
            let x = await this._mutex.acquire();
            try {
              let t = this.tracks.map((r) => r.source._flushOrWaitForOngoingClose(false));
              if (await Promise.all(t), await this._muxer.finalize(), this._rootWriterPromise) {
                let r = await this._rootWriterPromise;
                r.finalized || (await r.flush(), await r.finalize());
              }
              this._onFinalize && await this._onFinalize(), this.state = "finalized";
            } catch (t) {
              throw this.state = "canceled", t;
            } finally {
              await Promise.all([...this._unfinalizedTargets].map((t) => t._close().catch(() => {
              }))), this._unfinalizedTargets.clear(), x();
            }
          })();
        }
      };
      De = /* @__PURE__ */ Symbol.for("mediabunny loaded");
      globalThis[De] && C._error(`[WARNING]
Mediabunny was loaded twice. This will likely cause Mediabunny not to work correctly. Check if multiple dependencies are importing different versions of Mediabunny, or if something is being bundled incorrectly.`);
      globalThis[De] = true;
      Ye = ((e8) => typeof z < "u" ? z : typeof Proxy < "u" ? new Proxy(e8, { get: (x, t) => (typeof z < "u" ? z : x)[t] }) : e8)(function(e8) {
        if (typeof z < "u") return z.apply(this, arguments);
        throw Error('Dynamic require of "' + e8 + '" is not supported');
      });
      et = [8e3, 16e3, 22050, 24e3, 32e3, 44100, 48e3, 88200, 96e3, 176400, 192e3];
      tt = class extends n0 {
        constructor() {
          super(...arguments), this.worker = null, this.workerError = null, this.nextMessageId = 0, this.pendingMessages = /* @__PURE__ */ new Map(), this.ctx = null, this.chunkMetadata = {}, this.description = null, this.nextTimestampInSamples = null;
        }
        static supports(e8, x) {
          return e8 === "flac" && x.numberOfChannels >= 1 && x.numberOfChannels <= 8 && et.includes(x.sampleRate);
        }
        async init() {
          this.worker = await xt();
          let e8 = (t) => {
            let r = this.pendingMessages.get(t.id);
            O0(r !== void 0), this.pendingMessages.delete(t.id), t.success ? r.resolve(t.data) : r.reject(t.error);
          }, x = (t) => {
            this.workerError = t;
            for (let r of this.pendingMessages.values()) r.reject(t);
            this.pendingMessages.clear(), this.worker?.terminate(), this.worker = null;
          };
          if (this.worker.addEventListener) this.worker.addEventListener("message", (t) => e8(t.data)), this.worker.addEventListener("error", (t) => {
            x(new Error(t.message || "FLAC encoder worker failed to load or crashed."));
          });
          else {
            let t = this.worker;
            t.on("message", e8), t.on("error", x);
          }
        }
        resetInternalState() {
          this.nextTimestampInSamples = null, this.chunkMetadata = { decoderConfig: { codec: "flac", numberOfChannels: this.config.numberOfChannels, sampleRate: this.config.sampleRate, description: this.description } };
        }
        async encode(e8) {
          if (this.ctx === null) {
            let n;
            switch (e8.format) {
              case "u8":
              case "u8-planar":
              case "s16":
              case "s16-planar":
                n = 16;
                break;
              case "s32":
              case "s32-planar":
              case "f32":
              case "f32-planar":
                n = 24;
                break;
              default:
                rt(e8.format), O0(false);
            }
            let A = await this.sendCommand({ type: "init", data: { numberOfChannels: this.config.numberOfChannels, sampleRate: this.config.sampleRate, bitsPerSample: n } });
            this.ctx = A.ctx, this.description = new Uint8Array(A.header), this.resetInternalState();
          }
          this.nextTimestampInSamples === null && (this.nextTimestampInSamples = Math.round(e8.timestamp * this.config.sampleRate));
          let x = e8.allocationSize({ format: "s32", planeIndex: 0 }), t = new ArrayBuffer(x);
          e8.copyTo(t, { format: "s32", planeIndex: 0 });
          let r = await this.sendCommand({ type: "encode", data: { ctx: this.ctx, audioData: t, numSamples: e8.numberOfFrames } }, [t]);
          this.emitPackets(r.packets);
        }
        async flush() {
          if (this.ctx === null) return;
          let e8 = await this.sendCommand({ type: "flush", data: { ctx: this.ctx } });
          this.emitPackets(e8.packets), this.resetInternalState();
        }
        close() {
          this.worker?.terminate();
        }
        emitPackets(e8) {
          O0(this.nextTimestampInSamples !== null);
          for (let x of e8) {
            let t = new Uint8Array(x.encodedData), r = new _(t, "key", this.nextTimestampInSamples / this.config.sampleRate, x.samples / this.config.sampleRate);
            this.nextTimestampInSamples += x.samples, this.onPacket(r, this.chunkMetadata), this.chunkMetadata = {};
          }
        }
        sendCommand(e8, x) {
          return new Promise((t, r) => {
            if (this.workerError) {
              r(this.workerError);
              return;
            }
            let n = this.nextMessageId++;
            this.pendingMessages.set(n, { resolve: t, reject: r }), O0(this.worker), x ? this.worker.postMessage({ id: n, command: e8 }, x) : this.worker.postMessage({ id: n, command: e8 });
          });
        }
      };
      Be = false;
      me = () => {
        Be || (Be = true, ix(tt));
      };
      rt = (e8) => {
        throw new Error(`Unexpected value: ${e8}`);
      };
      pe = /* @__PURE__ */ Symbol.for("@mediabunny/flac-encoder loaded");
      globalThis[pe] && C._error(`[WARNING]
@mediabunny/flac-encoder was loaded twice. This will likely cause the encoder not to work correctly. Check if multiple dependencies are importing different versions of @mediabunny/flac-encoder, or if something is being bundled incorrectly.`);
      globalThis[pe] = true;
      me();
    }
  });

  // js/sfz/flac-stream.js
  function crc(bytes, width, polynomial) {
    let value = 0;
    const top = 2 ** (width - 1), mask = 2 ** width - 1;
    for (const byte of bytes) {
      value ^= byte << width - 8;
      for (let bit = 0; bit < 8; bit++) value = (value << 1 ^ (value & top ? polynomial : 0)) & mask;
    }
    return value;
  }
  function codedNumber(bits) {
    const first = bits.read(8);
    if (first < 128) return first;
    let count = 0;
    for (let mask = 128; first & mask; mask >>>= 1) count++;
    if (count < 2 || count > 7) fail();
    let value = first & 2 ** (7 - count) - 1;
    for (let i = 1; i < count; i++) {
      const byte = bits.read(8);
      if ((byte & 192) !== 128) fail();
      value = value * 64 + (byte & 63);
    }
    if (value < (count === 2 ? 128 : 2 ** (5 * count - 4))) fail();
    return value;
  }
  function readFlacFrameHeader(bytes, metadata) {
    const bits = new Bits(bytes);
    if (bits.read(14) !== 16382 || bits.read(1)) fail();
    const variable = bits.read(1), blockCode = bits.read(4), rateCode = bits.read(4);
    const assignment = bits.read(4), depthCode = bits.read(3);
    if (bits.read(1) || !blockCode || rateCode === 15 || assignment > 10 || depthCode === 3) fail();
    const number2 = codedNumber(bits);
    if (!variable && number2 > 2147483647) fail();
    const frames = blockCode === 1 ? 192 : blockCode <= 5 ? 144 * 2 ** blockCode : blockCode === 6 ? bits.read(8) + 1 : blockCode === 7 ? bits.read(16) + 1 : 2 ** blockCode;
    const rates = [metadata.sampleRate, 88200, 176400, 192e3, 8e3, 16e3, 22050, 24e3, 32e3, 44100, 48e3, 96e3];
    const rate = rateCode < 12 ? rates[rateCode] : rateCode === 12 ? bits.read(8) * 1e3 : bits.read(16) * (rateCode === 14 ? 10 : 1);
    const depth = [metadata.bitsPerSample, 8, 12, 0, 16, 20, 24, 32][depthCode];
    const channels = assignment < 8 ? assignment + 1 : 2;
    const headerBytes = bits.position / 8;
    if (bits.read(8) !== crc(bytes.subarray(0, headerBytes), 8, 7) || frames > 65535 || channels !== metadata.channels || rate !== metadata.sampleRate || depth !== metadata.bitsPerSample) fail();
    const firstFrame = variable ? number2 : number2 * metadata.maxBlockFrames;
    if (!Number.isSafeInteger(firstFrame) || firstFrame + frames > metadata.frames) fail();
    return { bits, frames, firstFrame, assignment, depth, channels };
  }
  function residual(bits, output, order) {
    const method = bits.read(2), partitions = 2 ** bits.read(4);
    if (method > 1 || output.length % partitions || output.length / partitions <= order) fail();
    const parameterBits = method + 4, escape = 2 ** parameterBits - 1;
    let cursor = order;
    for (let part = 0; part < partitions; part++) {
      const parameter = bits.read(parameterBits), count = output.length / partitions - (part === 0 ? order : 0);
      const rawBits = parameter === escape ? bits.read(5) : 0;
      for (let i = 0; i < count; i++) {
        if (parameter === escape) output[cursor++] = bits.signed(rawBits);
        else {
          const folded = bits.unary() * 2 ** parameter + bits.read(parameter);
          if (folded > 4294967294) fail();
          output[cursor++] = folded % 2 ? -(folded + 1) / 2 : folded / 2;
        }
      }
    }
  }
  function subframe(bits, frames, depth) {
    if (bits.read(1)) fail();
    const type = bits.read(6), wasted = bits.read(1) ? bits.unary() + 1 : 0;
    depth -= wasted;
    if (depth < 1 || depth > 33) fail();
    const output = new Float64Array(frames);
    if (type === 0) output.fill(bits.signed(depth));
    else if (type === 1) for (let i = 0; i < frames; i++) output[i] = bits.signed(depth);
    else {
      const order = type >= 32 ? type - 31 : type >= 8 && type <= 12 ? type - 8 : -1;
      if (order < 0 || order >= frames) fail();
      for (let i = 0; i < order; i++) output[i] = bits.signed(depth);
      const coefficients = [];
      let shift = 0;
      if (type >= 32) {
        const precision = bits.read(4) + 1;
        shift = bits.signed(5);
        if (precision === 16 || shift < 0) fail();
        for (let i = 0; i < order; i++) coefficients.push(bits.signed(precision));
      } else coefficients.push(...[[], [1], [2, -1], [3, -3, 1], [4, -6, 4, -1]][order]);
      residual(bits, output, order);
      for (let i = order; i < frames; i++) {
        let prediction = 0;
        for (let j2 = 0; j2 < order; j2++) prediction += coefficients[j2] * output[i - j2 - 1];
        if (!Number.isSafeInteger(prediction)) fail();
        output[i] += Math.floor(prediction / 2 ** shift);
        if (!Number.isSafeInteger(output[i])) fail();
      }
    }
    if (wasted) for (let i = 0; i < frames; i++) output[i] *= 2 ** wasted;
    return output;
  }
  function decodeFlacFrame(bytes, metadata) {
    const header = readFlacFrameHeader(bytes, metadata);
    const { bits, frames, channels, assignment, depth } = header;
    const decoded = [];
    for (let channel = 0; channel < channels; channel++) {
      const side = (assignment === 8 || assignment === 10) && channel === 1 || assignment === 9 && channel === 0;
      decoded.push(subframe(bits, frames, depth + (side ? 1 : 0)));
    }
    if (bits.position % 8 && bits.read(8 - bits.position % 8)) fail();
    const footer = bits.position / 8;
    if (bits.read(16) !== crc(bytes.subarray(0, footer), 16, 32773)) fail();
    const pcm = new Float32Array(frames * channels), scale = 2 ** (1 - depth);
    for (let i = 0; i < frames; i++) {
      let left = decoded[0][i], right = channels === 2 ? decoded[1][i] : left;
      if (assignment === 8) right = left - right;
      else if (assignment === 9) left += right;
      else if (assignment === 10) {
        const mid = left * 2 + Math.abs(right) % 2;
        left = (mid + right) / 2;
        right = (mid - right) / 2;
      }
      if (!Number.isSafeInteger(left) || !Number.isSafeInteger(right)) fail();
      const modulus = 2 ** depth, half = modulus / 2;
      left = (left % modulus + modulus) % modulus;
      right = (right % modulus + modulus) % modulus;
      if (left >= half) left -= modulus;
      if (right >= half) right -= modulus;
      pcm[i * channels] = left * scale;
      if (channels === 2) pcm[i * channels + 1] = right * scale;
    }
    return { firstFrame: header.firstFrame, frames, pcm, bytesConsumed: bits.position / 8 };
  }
  async function readFlacMetadata(read, size) {
    let offset = 4, info, last = false;
    const seekPoints = [];
    for (let count = 0; !last && count < 1024; count++) {
      const header = await read(offset, 4), type = header[0] & 127;
      last = Boolean(header[0] & 128);
      const length = header[1] * 65536 + header[2] * 256 + header[3];
      offset += 4;
      if (offset + length > size || type === 127 || !info && type !== 0) fail();
      if (type === 0) {
        if (info || length !== 34) fail();
        const bytes = await read(offset, length), view = new DataView(bytes.buffer, bytes.byteOffset, length);
        const packed = view.getBigUint64(10);
        info = {
          format: "flac",
          channels: Number(packed >> 41n & 7n) + 1,
          bitsPerSample: Number(packed >> 36n & 31n) + 1,
          sampleRate: Number(packed >> 44n),
          frames: Number(packed & 0xfffffffffn),
          maxBlockFrames: view.getUint16(2),
          maxFrameBytes: bytes[7] * 65536 + bytes[8] * 256 + bytes[9],
          contentDigest: Array.from(bytes.subarray(18), (byte) => byte.toString(16).padStart(2, "0")).join("")
        };
        if (info.channels > 2 || !info.sampleRate || !info.frames || !info.maxBlockFrames || info.bitsPerSample < 4) fail();
      } else if (type === 3) {
        if (length % 18 || length / 18 > 65536) fail();
        for (let position = 0; position < length; position += 18 * 256) {
          const bytes = await read(offset + position, Math.min(length - position, 18 * 256));
          const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
          for (let i = 0; i < bytes.length; i += 18) {
            const frame = view.getBigUint64(i), relative = view.getBigUint64(i + 8);
            if (frame === 0xffffffffffffffffn) continue;
            if (frame >= BigInt(info.frames) || relative > BigInt(size) || seekPoints.length && Number(frame) <= seekPoints.at(-1).frame) fail();
            seekPoints.push(Object.freeze({ frame: Number(frame), offset: Number(relative) }));
          }
        }
      }
      offset += length;
    }
    if (!last || !info || offset >= size) fail();
    return Object.freeze({ ...info, dataOffset: offset, size, seekPoints: Object.freeze(seekPoints) });
  }
  var fail, FLAC_MAX_FRAME_BYTES, Bits;
  var init_flac_stream = __esm({
    "js/sfz/flac-stream.js"() {
      fail = () => {
        throw Object.assign(new Error("The FLAC sample could not be read."), { code: "sample-format" });
      };
      FLAC_MAX_FRAME_BYTES = 1024 * 1024;
      Bits = class {
        constructor(bytes) {
          this.bytes = bytes;
          this.position = 0;
        }
        read(count) {
          if (count < 0 || count > 36 || this.position + count > this.bytes.length * 8) fail();
          let value = 0;
          while (count) {
            const bit = this.position % 8, take = Math.min(count, 8 - bit);
            value = value * 2 ** take + (this.bytes[this.position >>> 3] >>> 8 - bit - take & 2 ** take - 1);
            this.position += take;
            count -= take;
          }
          return value;
        }
        signed(count) {
          const value = this.read(count);
          return count && value >= 2 ** (count - 1) ? value - 2 ** count : value;
        }
        unary() {
          let zeros = 0;
          while (!this.read(1)) if (++zeros > FLAC_MAX_FRAME_BYTES * 8) fail();
          return zeros;
        }
      };
    }
  });

  // js/sfz/sample-stream.js
  async function pcmMetadata(read, size, prefix) {
    const wave = text(prefix.subarray(0, 4)) === "RIFF";
    const kind = text(prefix.subarray(8, 12));
    if (wave ? kind !== "WAVE" : kind !== "AIFF" && kind !== "AIFC") throw error("sample-format");
    let offset = 12, format, data;
    for (let count = 0; count < 1024 && offset + 8 <= size; count++) {
      const header = await read(offset, 8), view = new DataView(header.buffer, header.byteOffset, 8);
      const tag2 = text(header.subarray(0, 4)), length = view.getUint32(4, wave), start = offset + 8;
      if (start + length > size) throw error("sample-format");
      if (wave && tag2 === "fmt ") {
        if (length < 16) throw error("sample-format");
        const bytes = await read(start, Math.min(length, 40)), v = new DataView(bytes.buffer, bytes.byteOffset, bytes.length);
        let code = v.getUint16(0, true);
        if (code === 65534) {
          if (length < 40 || v.getUint16(16, true) < 22) throw error("sample-format");
          code = v.getUint16(24, true);
          if (text(bytes.subarray(26, 40)) !== "\0\0\0\0\0\x80\0\0\xAA\x008\x9Bq") throw error("sample-format");
        }
        format = {
          channels: v.getUint16(2, true),
          sampleRate: v.getUint32(4, true),
          blockAlign: v.getUint16(12, true),
          bitsPerSample: v.getUint16(14, true),
          float: code === 3,
          littleEndian: true,
          unsigned: true
        };
        if (code !== 1 && code !== 3) throw error("sample-format");
      } else if (!wave && tag2 === "COMM") {
        if (length < (kind === "AIFC" ? 22 : 18)) throw error("sample-format");
        const bytes = await read(start, kind === "AIFC" ? 22 : 18), v = new DataView(bytes.buffer, bytes.byteOffset, bytes.length);
        const exponent = v.getUint16(8), fraction = Number(v.getBigUint64(10));
        const compression = kind === "AIFC" ? text(bytes.subarray(18, 22)) : "NONE";
        if (!["NONE", "twos", "sowt", "fl32", "FL32", "fl64", "FL64"].includes(compression)) throw error("sample-format");
        format = {
          channels: v.getUint16(0),
          frames: v.getUint32(2),
          bitsPerSample: v.getUint16(6),
          sampleRate: fraction * 2 ** ((exponent & 32767) - 16383 - 63),
          littleEndian: compression === "sowt",
          float: compression.toLowerCase().startsWith("fl"),
          unsigned: false
        };
        if (exponent & 32768) throw error("sample-format");
        format.blockAlign = format.channels * Math.ceil(format.bitsPerSample / 8);
      } else if (wave && tag2 === "data") data = { dataOffset: start, dataBytes: length };
      else if (!wave && tag2 === "SSND") {
        if (length < 8) throw error("sample-format");
        const bytes = await read(start, 8), skip = new DataView(bytes.buffer, bytes.byteOffset, 8).getUint32(0);
        if (skip > length - 8) throw error("sample-format");
        data = { dataOffset: start + 8 + skip, dataBytes: length - 8 - skip };
      }
      if (format && data) break;
      offset = start + length + (length & 1);
    }
    if (!format || !data || !Number.isSafeInteger(format.sampleRate) || format.sampleRate < 1 || format.sampleRate > 768e3 || format.channels < 1 || format.channels > 2 || ![8, 16, 24, 32, 64].includes(format.bitsPerSample) || format.float && ![32, 64].includes(format.bitsPerSample) || !format.float && format.bitsPerSample === 64 || format.blockAlign !== format.channels * format.bitsPerSample / 8 || data.dataBytes % format.blockAlign) throw error("sample-format");
    const frames = data.dataBytes / format.blockAlign;
    if (!frames || format.frames !== void 0 && format.frames !== frames) throw error("sample-format");
    return Object.freeze({ format: "pcm", ...format, ...data, frames, size });
  }
  function decodePcm(bytes, metadata) {
    const { bitsPerSample: bits, channels, littleEndian: le2, float, unsigned } = metadata;
    const width = bits / 8, frames = bytes.length / (width * channels), pcm = new Float32Array(frames * channels);
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.length);
    for (let i = 0; i < pcm.length; i++) {
      const at = i * width;
      let value;
      if (float) value = bits === 32 ? view.getFloat32(at, le2) : view.getFloat64(at, le2);
      else if (bits === 8) value = unsigned ? bytes[at] - 128 : view.getInt8(at);
      else if (bits === 16) value = view.getInt16(at, le2);
      else if (bits === 24) {
        value = le2 ? bytes[at] + bytes[at + 1] * 256 + bytes[at + 2] * 65536 : bytes[at] * 65536 + bytes[at + 1] * 256 + bytes[at + 2];
        if (value >= 8388608) value -= 16777216;
      } else value = view.getInt32(at, le2);
      if (!Number.isFinite(value)) throw error("sample-format");
      pcm[i] = float ? value : value * 2 ** (1 - bits);
      if (!Number.isFinite(pcm[i])) throw error("sample-format");
    }
    return pcm;
  }
  var SFZ_SAMPLE_PAGE_FRAMES, SFZ_SAMPLE_MAX_READ_BYTES, error, text, SfzSampleStream;
  var init_sample_stream = __esm({
    "js/sfz/sample-stream.js"() {
      init_flac_stream();
      init_sample_reader();
      init_ogg_vorbis();
      SFZ_SAMPLE_PAGE_FRAMES = 4096;
      SFZ_SAMPLE_MAX_READ_BYTES = SFZ_SAMPLE_RANGE_MAX_BYTES;
      error = (code) => Object.assign(new Error("The instrument sample could not be prepared."), { code });
      text = (bytes) => String.fromCharCode(...bytes);
      SfzSampleStream = class _SfzSampleStream {
        static async open(readRange, size, pcm = null) {
          if (!Number.isSafeInteger(size) || size < 12) throw error("sample-format");
          const read = async (offset, length) => {
            if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 1 || length > SFZ_SAMPLE_MAX_READ_BYTES || offset + length > size) throw error("sample-range");
            const result = await readRange(offset, length), bytes = result instanceof Uint8Array ? result : new Uint8Array(result);
            if (bytes.length !== length) throw error("sample-changed");
            return bytes;
          };
          if (pcm) {
            if (pcm.format === "sf3-vorbis") {
              if (pcm.channels !== 1 || !Number.isSafeInteger(pcm.frames) || pcm.frames < 1 || !Number.isInteger(pcm.sampleRate) || pcm.sampleRate < 1 || pcm.sampleRate > 768e3 || !Number.isSafeInteger(pcm.firstFrame) || pcm.firstFrame < 0 || !Number.isSafeInteger(pcm.sourceFrames) || pcm.firstFrame + pcm.frames > pcm.sourceFrames || !Number.isSafeInteger(pcm.dataOffset) || pcm.dataOffset < 0 || !Number.isSafeInteger(pcm.dataBytes) || pcm.dataBytes < 58 || pcm.dataOffset + pcm.dataBytes > size) throw error("sample-format");
              return new _SfzSampleStream(read, Object.freeze({ ...pcm, size }));
            }
            const { frames, sampleRate, dataOffset, lowByteOffset } = pcm;
            if (pcm.format !== "sf2-pcm" || pcm.channels !== 1 || !Number.isSafeInteger(frames) || frames < 1 || !Number.isInteger(sampleRate) || sampleRate < 1 || sampleRate > 768e3 || !Number.isSafeInteger(dataOffset) || dataOffset < 0 || !Number.isSafeInteger(dataOffset + frames * 2) || dataOffset + frames * 2 > size || lowByteOffset !== null && (!Number.isSafeInteger(lowByteOffset) || lowByteOffset < 0 || !Number.isSafeInteger(lowByteOffset + frames) || lowByteOffset + frames > size)) throw error("sample-format");
            return new _SfzSampleStream(read, Object.freeze({ ...pcm, size }));
          }
          const prefix = await read(0, 12), signature2 = text(prefix.subarray(0, 4));
          const metadata = signature2 === "fLaC" ? await readFlacMetadata(read, size) : signature2 === "RIFF" || signature2 === "FORM" ? await pcmMetadata(read, size, prefix) : null;
          if (!metadata) throw error("sample-format");
          return new _SfzSampleStream(read, metadata);
        }
        constructor(read, metadata) {
          this.read = read;
          this.metadata = metadata;
          this.index = metadata.format === "flac" ? [
            { frame: 0, offset: metadata.dataOffset },
            ...metadata.seekPoints.filter((point) => point.frame > 0).map((point) => ({ frame: point.frame, offset: metadata.dataOffset + point.offset }))
          ] : [];
        }
        async readFrames(firstFrame, count) {
          const m = this.metadata;
          if (!Number.isSafeInteger(firstFrame) || !Number.isSafeInteger(count) || firstFrame < 0 || count < 1 || count > 65536 || firstFrame + count > m.frames) throw error("sample-range");
          if (m.format === "pcm") return decodePcm(await this.read(m.dataOffset + firstFrame * m.blockAlign, count * m.blockAlign), m);
          if (m.format === "sf3-vorbis") return decodeOggVorbisFrames(
            (offset2, length) => this.read(m.dataOffset + offset2, length),
            m.dataBytes,
            m.firstFrame + firstFrame,
            count,
            { frames: m.sourceFrames, sampleRate: m.sampleRate }
          );
          if (m.format === "sf2-pcm") {
            const bytes = await this.read(m.dataOffset + firstFrame * 2, count * 2);
            const low = m.lowByteOffset === null ? null : await this.read(m.lowByteOffset + firstFrame, count);
            const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength), pcm = new Float32Array(count);
            for (let frame = 0; frame < count; frame++) {
              const high = view.getInt16(frame * 2, true);
              pcm[frame] = low ? (high * 256 + low[frame]) / 8388608 : high / 32768;
            }
            return pcm;
          }
          let anchor = this.index[0];
          for (const point of this.index) if (point.frame <= firstFrame && point.frame >= anchor.frame) anchor = point;
          let lower = anchor.offset, upper = m.size;
          const next = this.index.find((point) => point.frame > firstFrame);
          if (next) upper = next.offset;
          const seekWindow = Math.min(FLAC_MAX_FRAME_BYTES, (m.maxFrameBytes || FLAC_MAX_FRAME_BYTES) * 2);
          while (firstFrame - anchor.frame > m.maxBlockFrames * 8 && upper - lower > seekWindow * 2) {
            const middle = Math.floor((lower + upper) / 2);
            const candidate = await this.findFrame(middle);
            if (!candidate || candidate.frame > firstFrame) upper = middle;
            else {
              anchor = candidate;
              lower = candidate.offset;
            }
          }
          let offset = anchor.offset, expected = anchor.frame, copied = 0;
          const output = new Float32Array(count * m.channels);
          while (copied < count) {
            const length = Math.min(m.maxFrameBytes || FLAC_MAX_FRAME_BYTES, FLAC_MAX_FRAME_BYTES, m.size - offset);
            if (!length) throw error("sample-format");
            const decoded = decodeFlacFrame(await this.read(offset, length), m);
            if (decoded.firstFrame !== expected) throw error("sample-format");
            const start = Math.max(firstFrame, decoded.firstFrame), end = Math.min(firstFrame + count, decoded.firstFrame + decoded.frames);
            if (end > start) {
              output.set(decoded.pcm.subarray((start - decoded.firstFrame) * m.channels, (end - decoded.firstFrame) * m.channels), (start - firstFrame) * m.channels);
              copied += end - start;
            }
            expected += decoded.frames;
            offset += decoded.bytesConsumed;
          }
          this.remember({ frame: expected, offset });
          return output;
        }
        remember(point) {
          if (point.frame >= this.metadata.frames || this.index.some((existing) => existing.frame === point.frame)) return;
          if (this.index.length >= Math.max(256, this.metadata.seekPoints.length + 1)) return;
          this.index.push(point);
          this.index.sort((a, b2) => a.frame - b2.frame);
        }
        async findFrame(offset) {
          const m = this.metadata, bytes = await this.read(offset, Math.min(
            FLAC_MAX_FRAME_BYTES,
            (m.maxFrameBytes || FLAC_MAX_FRAME_BYTES) * 2,
            m.size - offset
          ));
          for (let at = 0; at + 6 < bytes.length; at++) {
            if (bytes[at] !== 255 || (bytes[at + 1] & 254) !== 248) continue;
            try {
              const header = readFlacFrameHeader(bytes.subarray(at), m);
              decodeFlacFrame(bytes.subarray(at), m);
              return { frame: header.firstFrame, offset: offset + at };
            } catch {
            }
          }
          return null;
        }
        async readPage(pageIndex) {
          return this.readPages(pageIndex, 1);
        }
        async readPages(pageIndex, pageCount) {
          if (!Number.isInteger(pageCount) || pageCount < 1 || pageCount > 16) throw error("sample-range");
          if (!Number.isSafeInteger(pageIndex) || pageIndex < 0) throw error("sample-range");
          const firstFrame = pageIndex * SFZ_SAMPLE_PAGE_FRAMES;
          const frames = Math.min(SFZ_SAMPLE_PAGE_FRAMES * pageCount, this.metadata.frames - firstFrame);
          return { pageIndex, firstFrame, frames, channels: this.metadata.channels, pcm: await this.readFrames(firstFrame, frames) };
        }
      };
    }
  });

  // js/sfz/sample-supply-port.js
  async function startSfzWorkerSupply(worker, { port, rangePort, ...options }) {
    const ports = rangePort ? [port, rangePort] : [port];
    return worker.call("supply", { ...options, port, rangePort }, ports);
  }
  async function attachSfzWorkerSupply({
    port,
    generation,
    pluginId,
    operationRevision,
    replayEpoch,
    provider,
    onClose = () => {
    }
  }) {
    let closed = false, polling = false, requested = false, nextId = 1;
    const pending = /* @__PURE__ */ new Map();
    const identity = { pluginId, generation, operationRevision, replayEpoch };
    const close = (code) => {
      if (closed) return;
      closed = true;
      provider.close();
      for (const request2 of pending.values()) request2.reject(failure3(code));
      pending.clear();
      port.close();
      onClose(code);
    };
    const request = (type, payload = {}, transfer = []) => new Promise((resolve, reject) => {
      if (closed) {
        reject(failure3("sample-cancelled"));
        return;
      }
      const requestId = nextId++;
      pending.set(requestId, { resolve, reject });
      port.postMessage({ ...identity, ...payload, type, requestId }, transfer);
    });
    const poll = async () => {
      requested = true;
      if (polling || closed) return;
      polling = true;
      try {
        while (requested) {
          if (closed) break;
          requested = false;
          const result = await request("sfzPollPages");
          if (!result?.ok) throw failure3("sample-generation");
          await provider.requestPages(result.requests);
        }
      } catch (error2) {
        if (!closed) port.postMessage({ ...identity, type: "sfzStreamFailed", code: error2.code || "sample-read" });
        close(error2.code || "sample-read");
      } finally {
        polling = false;
      }
    };
    provider.publish = async (page2) => {
      const result = await request("sfzPublishPage", { page: page2 }, [page2.pcm.buffer]);
      return result?.ok === true;
    };
    port.onmessage = ({ data }) => {
      if (data?.type === "sfzStreamStop") {
        close("sample-cancelled");
        return;
      }
      if (data?.type === "sfzStreamPollNeeded") {
        void poll();
        return;
      }
      const request2 = pending.get(data?.requestId);
      if (!request2) return;
      pending.delete(data.requestId);
      request2.resolve(data);
    };
    port.onmessageerror = () => close("sample-read");
    port.start?.();
    void poll();
    return close;
  }
  var failure3;
  var init_sample_supply_port = __esm({
    "js/sfz/sample-supply-port.js"() {
      failure3 = (code) => Object.assign(new Error("The instrument sample channel was closed."), { code });
    }
  });

  // js/sfz/sample-stream-worker.js
  function attachSfzSampleStreamWorker(endpoint) {
    const streams = /* @__PURE__ */ new Map(), reads = /* @__PURE__ */ new Map();
    let nextRead = 1, queue = Promise.resolve(), metadataBytes = 0, directSources = null, rangePort = null;
    const rangeReads = /* @__PURE__ */ new Map();
    const directRead = async (sample, offset, length) => {
      const reader = directSources[sample], source = reader?.source;
      if (!source || !Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 1 || length > SFZ_SAMPLE_MAX_READ_BYTES || offset + length > reader.size) throw failure4("sample-range");
      if (source.kind === "file") {
        if (source.handle) {
          const current = await source.handle.getFile();
          if (`${current.size}:${current.lastModified}` !== source.revision) throw failure4("source-changed");
        }
        const bytes = new Uint8Array(await source.file.slice(source.offset + offset, source.offset + offset + length).arrayBuffer());
        if (bytes.length !== length) throw failure4("source-changed");
        return bytes;
      }
      if (source.kind !== "protected" || !rangePort || rangeReads.size >= 4) throw failure4("sample-capacity");
      const requestId = nextRead++;
      return new Promise((resolve, reject) => {
        rangeReads.set(requestId, { resolve, reject, length, revision: source.revision });
        rangePort.postMessage({
          requestId,
          relativePath: source.relativePath,
          revision: source.revision,
          offset: source.offset + offset,
          length
        });
      });
    };
    const read = (sample, offset, length) => directSources ? directRead(sample, offset, length) : new Promise((resolve, reject) => {
      const id = nextRead++;
      reads.set(id, { resolve, reject });
      endpoint.postMessage({ type: "read", sample, id, offset, length });
    });
    endpoint.onmessage = ({ data }) => {
      if (data.type === "read-result") {
        const pending = reads.get(data.id);
        if (!pending) return;
        reads.delete(data.id);
        if (data.error) pending.reject(failure4(data.error));
        else pending.resolve(data.bytes);
        return;
      }
      queue = queue.then(async () => {
        try {
          let result;
          if (data.type === "open") {
            if (!Number.isInteger(data.sample) || data.sample < 0 || data.sample >= 1e4 || streams.has(data.sample)) throw failure4("sample-range");
            const stream = await SfzSampleStream.open((offset, length) => read(data.sample, offset, length), data.size, data.pcm);
            const bytes = 512 + (stream.metadata.seekPoints?.length || 0) * 24;
            if (metadataBytes + bytes > 16 * 1024 * 1024) throw failure4("sample-capacity");
            metadataBytes += bytes;
            streams.set(data.sample, stream);
            result = stream.metadata;
          } else if (data.type === "supply") {
            if (directSources || !data.port || data.sources.length !== data.samples.length || reads.size) throw failure4("sample-generation");
            directSources = data.sources;
            rangePort = data.rangePort;
            if (rangePort) {
              rangePort.onmessage = ({ data: result2 }) => {
                const pending = rangeReads.get(result2?.requestId);
                if (!pending) return;
                rangeReads.delete(result2.requestId);
                const bytes = result2.data?.bytes;
                if (!result2.ok) pending.reject(failure4(result2.code || "sample-read"));
                else if (result2.data.revision !== pending.revision || bytes?.length !== pending.length) pending.reject(failure4("source-changed"));
                else pending.resolve(bytes);
              };
              rangePort.start?.();
            }
            const serial = /* @__PURE__ */ new Map();
            const local = {
              statelessPcmReads: true,
              async open(sample) {
                if (streams.has(sample)) return streams.get(sample).metadata;
                const source = directSources[sample];
                const stream = await SfzSampleStream.open((offset, length) => read(sample, offset, length), source.size, source.pcm);
                streams.set(sample, stream);
                return stream.metadata;
              },
              readPage(sample, page2) {
                return this.readPages(sample, page2, 1);
              },
              readPages(sample, page2, count) {
                const stream = streams.get(sample);
                if (!stream) return Promise.reject(failure4("sample-range"));
                if (stream.metadata.format === "pcm" || stream.metadata.format === "sf2-pcm") return stream.readPages(page2, count);
                const task = (serial.get(sample) || Promise.resolve()).then(() => stream.readPages(page2, count));
                serial.set(sample, task.catch(() => {
                }));
                return task;
              },
              close() {
                rangePort?.postMessage({ type: "close" });
                rangePort?.close();
                for (const pending of rangeReads.values()) pending.reject(failure4("sample-cancelled"));
                rangeReads.clear();
              }
            };
            const { SfzSamplePageProvider: SfzSamplePageProvider2 } = await Promise.resolve().then(() => (init_sample_page_provider(), sample_page_provider_exports));
            const provider = new SfzSamplePageProvider2({
              assetId: data.assetId,
              generation: data.generation,
              worker: local,
              createReader: (samplePath) => {
                const source = directSources[data.paths.indexOf(samplePath)];
                return { ...source, revision: data.samples[data.paths.indexOf(samplePath)].sourceRevision };
              },
              publish: () => false
            });
            provider.samples = data.samples;
            provider.paths = data.paths;
            for (const sample of streams.keys()) provider.openSamples.set(sample, Promise.resolve());
            await attachSfzWorkerSupply({ ...data, provider, onClose: (code) => {
              if (code !== "sample-cancelled") endpoint.postMessage({ type: "supply-error", code });
            } });
            result = true;
          } else if (data.type === "page" || data.type === "pages") {
            const stream = streams.get(data.sample);
            if (!stream) throw failure4("sample-range");
            result = data.type === "page" ? await stream.readPage(data.pageIndex) : await stream.readPages(data.pageIndex, data.pageCount);
          } else throw failure4("sample-range");
          endpoint.postMessage({ type: "result", id: data.id, result }, result.pcm ? [result.pcm.buffer] : []);
        } catch (error2) {
          endpoint.postMessage({ type: "result", id: data.id, error: error2.code || "sample-format" });
        }
      });
    };
  }
  var import_meta2, failure4, SfzSampleStreamWorker;
  var init_sample_stream_worker = __esm({
    "js/sfz/sample-stream-worker.js"() {
      init_sample_stream();
      init_sample_supply_port();
      import_meta2 = {};
      failure4 = (code) => Object.assign(new Error("The instrument sample could not be prepared."), { code });
      SfzSampleStreamWorker = class {
        constructor({ workerFactory = () => new Worker(new URL("./sample-stream-worker.js", import_meta2.url), { type: "module" }) } = {}) {
          this.worker = workerFactory();
          this.readers = /* @__PURE__ */ new Map();
          this.pending = /* @__PURE__ */ new Map();
          this.nextId = 1;
          this.closed = false;
          this.worker.onmessage = ({ data }) => {
            void this.receive(data);
          };
          const failed = () => {
            if (this.closed) return;
            this.close("sample-worker");
            this.onSupplyError?.(failure4("sample-worker"));
          };
          this.worker.onerror = failed;
          this.worker.onmessageerror = failed;
        }
        async receive(data) {
          if (this.closed) return;
          if (data.type === "read") {
            try {
              const reader = this.readers.get(data.sample);
              if (!reader || !Number.isSafeInteger(data.offset) || !Number.isSafeInteger(data.length) || data.offset < 0 || data.length < 1 || data.length > SFZ_SAMPLE_MAX_READ_BYTES || data.offset + data.length > reader.size) throw failure4("sample-range");
              const value = await reader.readRange(data.offset, data.length);
              if (this.closed) return;
              const bytes = value instanceof Uint8Array ? value.slice() : new Uint8Array(value).slice();
              if (bytes.length !== data.length) throw failure4("sample-changed");
              this.worker.postMessage({ type: "read-result", id: data.id, bytes }, [bytes.buffer]);
            } catch (error2) {
              if (!this.closed) this.worker.postMessage({ type: "read-result", id: data.id, error: error2.code || "sample-read" });
            }
          } else if (data.type === "supply-error") {
            this.onSupplyError?.(failure4(data.code));
          } else if (data.type === "result") {
            const pending = this.pending.get(data.id);
            if (!pending) return;
            this.pending.delete(data.id);
            if (data.error) pending.reject(failure4(data.error));
            else pending.resolve(data.result);
          }
        }
        call(type, arguments_, transfer = []) {
          if (this.closed) return Promise.reject(failure4("sample-cancelled"));
          if (this.pending.size >= 4096) return Promise.reject(failure4("sample-capacity"));
          const id = this.nextId++;
          return new Promise((resolve, reject) => {
            this.pending.set(id, { resolve, reject });
            this.worker.postMessage({ type, id, ...arguments_ }, transfer);
          });
        }
        async open(sample, reader) {
          if (!Number.isInteger(sample) || sample < 0 || sample >= 1e4 || this.readers.has(sample) || !reader || !Number.isSafeInteger(reader.size) || typeof reader.readRange !== "function") throw failure4("sample-range");
          this.readers.set(sample, reader);
          try {
            const metadata = await this.call("open", { sample, size: reader.size, pcm: reader.pcm });
            return Object.freeze({ ...metadata, revision: reader.revision });
          } catch (error2) {
            this.readers.delete(sample);
            throw error2;
          }
        }
        readPage(sample, pageIndex) {
          return this.call("page", { sample, pageIndex });
        }
        readPages(sample, pageIndex, pageCount) {
          return this.call("pages", { sample, pageIndex, pageCount });
        }
        close(code = "sample-cancelled") {
          if (this.closed) return;
          this.closed = true;
          this.worker.terminate();
          for (const pending of this.pending.values()) pending.reject(failure4(code));
          this.pending.clear();
          this.readers.clear();
        }
      };
      if (typeof WorkerGlobalScope !== "undefined" && globalThis instanceof WorkerGlobalScope) attachSfzSampleStreamWorker(globalThis);
    }
  });

  // js/sfz/sample-page-provider.js
  var sample_page_provider_exports = {};
  __export(sample_page_provider_exports, {
    SfzSamplePageProvider: () => SfzSamplePageProvider,
    createSfzSampleProviderFactory: () => createSfzSampleProviderFactory
  });
  async function createSfzSampleProviderFactory({
    assetId,
    paths,
    createReader,
    persistentCache = null,
    onProgress = null,
    workerFactory,
    storageModes = null
  } = {}) {
    const capturedPaths = Object.freeze([...paths]);
    const readers = /* @__PURE__ */ new Map();
    for (const path of capturedPaths) readers.set(path, await createReader(path));
    const create = (generation, publish, progress) => new SfzSamplePageProvider({
      assetId,
      generation,
      createReader: (path) => readers.get(path),
      persistentCache,
      publish,
      onProgress: progress,
      workerFactory,
      storageModes
    });
    const preparation = create(1, () => {
    }, onProgress);
    let samples;
    try {
      samples = await preparation.prepare(capturedPaths);
    } finally {
      preparation.close();
    }
    const factory = async ({ generation, publish, onProgress: progress, onProvider } = {}) => {
      const provider = create(generation, publish, progress);
      try {
        onProvider?.(provider);
        const current = await provider.prepare(
          capturedPaths,
          samples.every((sample) => sample.sourceGeometry) ? samples : null
        );
        if (current.some((sample, index) => sample.revision !== samples[index].revision)) throw failure5("sample-generation");
        return provider;
      } catch (error2) {
        provider.close();
        throw error2;
      }
    };
    Object.defineProperty(factory, "samples", { value: samples, enumerable: true });
    Object.defineProperty(factory, "startSupply", { value: async (provider, context) => {
      const sources = capturedPaths.map((path) => readers.get(path));
      if (sources.some((reader) => !reader.rangeSource || reader.rangeSource.kind === "protected" && !reader.openRangePort)) return false;
      const protectedReader = sources.find((reader) => reader.rangeSource.kind === "protected");
      if (protectedReader && sources.some((reader) => reader.rangeSource.kind === "protected" && reader.rangeSource.bankId !== protectedReader.rangeSource.bankId)) throw failure5("sample-generation");
      const rangePort = protectedReader ? await protectedReader.openRangePort() : null;
      try {
        await startSfzWorkerSupply(provider.worker, {
          ...context,
          rangePort,
          sources: sources.map((reader) => ({ size: reader.size, pcm: reader.pcm, source: reader.rangeSource })),
          samples,
          paths: capturedPaths,
          assetId,
          generation: provider.generation
        });
        return true;
      } catch (error2) {
        rangePort?.close();
        throw error2;
      }
    } });
    return Object.freeze(factory);
  }
  var failure5, MAX_PUBLISH_IN_FLIGHT, pageKey, SfzSamplePageProvider;
  var init_sample_page_provider = __esm({
    "js/sfz/sample-page-provider.js"() {
      init_sample_stream_worker();
      init_sample_stream();
      init_sample_supply_port();
      failure5 = (code) => Object.assign(new Error("The instrument samples could not be prepared. Reload the instrument."), { code });
      MAX_PUBLISH_IN_FLIGHT = 4;
      pageKey = (sample, pageIndex, resident = false) => `${sample}:${pageIndex}:${resident ? 1 : 0}`;
      SfzSamplePageProvider = class {
        constructor({
          assetId,
          generation,
          createReader,
          publish,
          persistentCache = null,
          worker = null,
          workerFactory,
          onProgress = null,
          storageModes = null
        } = {}) {
          if (!/^[a-f0-9]{24}$/.test(assetId) || !Number.isSafeInteger(generation) || generation < 1 || typeof createReader !== "function" || typeof publish !== "function") {
            worker?.close();
            throw failure5("sample-range");
          }
          this.assetId = assetId;
          this.generation = generation;
          this.createReader = createReader;
          this.publish = publish;
          this._worker = worker;
          this.workerFactory = workerFactory;
          this.persistentCache = persistentCache;
          this.onProgress = onProgress;
          this.storageModes = storageModes;
          this.samples = [];
          this.pending = /* @__PURE__ */ new Map();
          this.queue = [];
          this.pumping = false;
          this.closed = false;
          this.prepared = /* @__PURE__ */ new Set();
          this.paths = null;
          this.preparing = false;
          this.openSamples = /* @__PURE__ */ new Map();
        }
        get worker() {
          return this._worker ??= new SfzSampleStreamWorker({ workerFactory: this.workerFactory });
        }
        async prepare(paths, knownPcm = null) {
          if (this.closed) throw failure5("sample-cancelled");
          if (this.preparing || !Array.isArray(paths) || !paths.length || paths.length > 1e4 || paths.some((path) => typeof path !== "string") || new Set(paths).size !== paths.length) throw failure5("sample-range");
          if (this.paths && (this.paths.length !== paths.length || paths.some((path, index) => path !== this.paths[index]))) throw failure5("sample-generation");
          this.paths ??= [...paths];
          this.preparing = true;
          try {
            if (knownPcm) {
              if (knownPcm.length !== paths.length) throw failure5("sample-generation");
              for (let sample = 0; sample < paths.length; sample++) {
                const reader = await this.createReader(paths[sample]), metadata = knownPcm[sample];
                if (this.closed) throw failure5("sample-cancelled");
                if (!metadata.sourceGeometry || !["sf2-pcm", "sf3-vorbis"].includes(reader.pcm?.format) || reader.revision !== metadata.sourceRevision || reader.size !== metadata.sourceSize) throw failure5("sample-generation");
              }
              this.samples = knownPcm;
              this.onProgress?.({ phase: "metadata", completedCount: paths.length, totalCount: paths.length });
              return knownPcm;
            }
            for (let sample = this.samples.length; sample < paths.length; sample++) {
              const reader = await this.createReader(paths[sample]);
              if (this.closed) throw failure5("sample-cancelled");
              const rawPcm = reader.pcm?.format === "sf2-pcm";
              const sourceGeometry = rawPcm || reader.pcm?.format === "sf3-vorbis";
              const metadata = sourceGeometry ? (await SfzSampleStream.open(reader.readRange, reader.size, reader.pcm)).metadata : await this.worker.open(sample, reader);
              if (!sourceGeometry) this.openSamples.set(sample, Promise.resolve());
              if (this.closed) throw failure5("sample-cancelled");
              const identityFields = [
                this.assetId,
                paths[sample],
                reader.revision,
                metadata.frames,
                metadata.channels,
                metadata.sampleRate,
                metadata.contentDigest || ""
              ];
              if (this.storageModes) identityFields.push("pcm-storage-v1", this.storageModes[sample]);
              const identity = new TextEncoder().encode(JSON.stringify(identityFields));
              const digest = new Uint8Array(await globalThis.crypto.subtle.digest("SHA-256", identity));
              if (this.closed) throw failure5("sample-cancelled");
              const revision = Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
              this.samples.push(Object.freeze({
                sample,
                frames: metadata.frames,
                channels: metadata.channels,
                sampleRate: metadata.sampleRate,
                revision,
                ...this.storageModes && { storageMode: this.storageModes[sample] },
                ...rawPcm && { rawPcm: true },
                ...sourceGeometry && { sourceGeometry: true, sourceRevision: reader.revision, sourceSize: reader.size }
              }));
              this.onProgress?.({ phase: "metadata", completedCount: this.samples.length, totalCount: paths.length });
            }
            return Object.freeze([...this.samples]);
          } finally {
            this.preparing = false;
          }
        }
        openSample(sample) {
          if (!this.samples[sample]?.sourceGeometry) return Promise.resolve();
          let opened = this.openSamples.get(sample);
          if (!opened) {
            opened = (async () => {
              const reader = await this.createReader(this.paths[sample]);
              if (this.closed) throw failure5("sample-cancelled");
              const metadata = await this.worker.open(sample, reader), expected = this.samples[sample];
              if (reader.revision !== expected.sourceRevision || metadata.frames !== expected.frames || metadata.channels !== expected.channels || metadata.sampleRate !== expected.sampleRate) throw failure5("sample-generation");
            })();
            this.openSamples.set(sample, opened);
          }
          return opened;
        }
        validate(request) {
          const metadata = this.samples[request?.sample];
          if (this.closed) throw failure5("sample-cancelled");
          if (request?.generation !== this.generation) throw failure5("sample-generation");
          if (!Number.isInteger(request.sample) || request.sample < 0 || !metadata || !Number.isSafeInteger(request.pageIndex) || request.pageIndex < 0 || request.pageIndex * SFZ_SAMPLE_PAGE_FRAMES >= metadata.frames) throw failure5("sample-range");
          return metadata;
        }
        requestPages(requests) {
          if (!Array.isArray(requests) || requests.length > 4096) return Promise.reject(failure5("sample-capacity"));
          try {
            for (const request of requests) this.validate(request);
            const unique = new Set(requests.map((request) => pageKey(request.sample, request.pageIndex, request.resident)));
            const newCount = [...unique].filter((key) => !this.pending.has(key)).length;
            if (this.pending.size + newCount > 4096) throw failure5("sample-capacity");
            const pending = requests.map((request) => this.enqueue(request));
            if (!this.pumping) void this.pump();
            return Promise.all(pending);
          } catch (error2) {
            return Promise.reject(error2);
          }
        }
        enqueue(request) {
          const key = pageKey(request.sample, request.pageIndex, request.resident), existing = this.pending.get(key);
          if (existing) return existing.promise;
          const job = { sample: request.sample, pageIndex: request.pageIndex, resident: Boolean(request.resident) };
          job.promise = new Promise((resolve, reject) => {
            job.resolve = resolve;
            job.reject = reject;
          });
          this.pending.set(key, job);
          this.queue.push(job);
          return job.promise;
        }
        async load(job) {
          const metadata = this.samples[job.sample];
          const preparation = { kind: "sfz-sample-page-v1", revision: metadata.revision, page: job.pageIndex };
          const frames = Math.min(SFZ_SAMPLE_PAGE_FRAMES, metadata.frames - job.pageIndex * SFZ_SAMPLE_PAGE_FRAMES);
          const persistent = job.resident && this.persistentCache && metadata.sampleRate >= 1e3;
          const cached = persistent ? await this.persistentCache.get(this.assetId, metadata.sampleRate, preparation) : null;
          let result;
          if (cached && cached.channelData.length === metadata.channels && cached.channelData.every((channel) => channel.length === frames)) {
            const pcm = new Float32Array(frames * metadata.channels);
            for (let channel = 0; channel < metadata.channels; channel++)
              for (let frame = 0; frame < frames; frame++) pcm[frame * metadata.channels + channel] = cached.channelData[channel][frame];
            result = { pageIndex: job.pageIndex, firstFrame: job.pageIndex * SFZ_SAMPLE_PAGE_FRAMES, frames, channels: metadata.channels, pcm };
          } else {
            if (metadata.sourceGeometry) await this.openSample(job.sample);
            result = await this.worker.readPage(job.sample, job.pageIndex);
            if (persistent && !this.closed) {
              const channelData = Array.from({ length: metadata.channels }, (_2, channel) => {
                const pcm = new Float32Array(frames);
                for (let frame = 0; frame < frames; frame++) pcm[frame] = result.pcm[frame * metadata.channels + channel];
                return pcm;
              });
              await this.persistentCache.set(this.assetId, metadata.sampleRate, preparation, { sampleRate: metadata.sampleRate, channelData });
            }
          }
          return result;
        }
        async pump() {
          this.pumping = true;
          const publications = /* @__PURE__ */ new Set(), decoding = /* @__PURE__ */ new Set();
          const finish = (item, error2) => {
            if (error2) item.reject(error2);
            else {
              if (item.resident) this.prepared.add(pageKey(item.sample, item.pageIndex, true));
              item.resolve();
            }
            const key = pageKey(item.sample, item.pageIndex, item.resident);
            if (this.pending.get(key) === item) this.pending.delete(key);
          };
          const decode = async (batch) => {
            const job = batch[0];
            try {
              let decoded;
              if (batch.length === 1) decoded = await this.load(job);
              else {
                if (this.samples[job.sample].sourceGeometry) await this.openSample(job.sample);
                decoded = await this.worker.readPages(job.sample, job.pageIndex, batch.length);
              }
              for (const item of batch) {
                while (publications.size >= MAX_PUBLISH_IN_FLIGHT && !this.closed) await Promise.race(publications);
                if (this.closed) throw failure5("sample-cancelled");
                const first = (item.pageIndex - job.pageIndex) * SFZ_SAMPLE_PAGE_FRAMES;
                const frames = Math.min(SFZ_SAMPLE_PAGE_FRAMES, decoded.frames - first);
                const page2 = batch.length === 1 ? decoded : {
                  pageIndex: item.pageIndex,
                  firstFrame: item.pageIndex * SFZ_SAMPLE_PAGE_FRAMES,
                  frames,
                  channels: decoded.channels,
                  pcm: decoded.pcm.slice(first * decoded.channels, (first + frames) * decoded.channels)
                };
                const publication = Promise.resolve().then(() => {
                  if (this.closed) throw failure5("sample-cancelled");
                  return this.publish({ ...page2, sample: item.sample, generation: this.generation, resident: item.resident });
                }).then((accepted) => {
                  if (accepted === false) throw failure5("sample-capacity");
                  if (this.closed) throw failure5("sample-cancelled");
                  finish(item);
                }).catch((error2) => finish(item, error2)).finally(() => publications.delete(publication));
                publications.add(publication);
              }
            } catch (error2) {
              for (const item of batch) finish(item, error2);
            }
          };
          try {
            while ((this.queue.length || decoding.size || publications.size) && !this.closed) {
              const job = this.queue[0];
              const capacity = job && this.samples[job.sample].rawPcm && this.worker.statelessPcmReads ? MAX_PUBLISH_IN_FLIGHT : 1;
              if (!job || decoding.size >= capacity) {
                await Promise.race([...decoding, ...publications]);
                continue;
              }
              this.queue.shift();
              const batch = [job];
              if (!job.resident && typeof this.worker.readPages === "function") {
                while (batch.length < 16 && this.queue.length) {
                  const next = this.queue[0];
                  if (next.resident || next.sample !== job.sample || next.pageIndex !== job.pageIndex + batch.length) break;
                  batch.push(this.queue.shift());
                }
              }
              const task = decode(batch).finally(() => decoding.delete(task));
              decoding.add(task);
            }
          } finally {
            this.pumping = false;
          }
        }
        async preload(requests) {
          if (!Array.isArray(requests) || requests.length > 32768) throw failure5("sample-capacity");
          const unique = /* @__PURE__ */ new Map();
          for (const request of requests) {
            const normalized = { ...request, generation: this.generation, resident: true };
            this.validate(normalized);
            unique.set(pageKey(normalized.sample, normalized.pageIndex, true), normalized);
          }
          let preparationError;
          try {
            let completed = 0;
            for (const [key, request] of unique) {
              if (!this.prepared.has(key)) await this.requestPages([request]);
              if (this.closed) throw failure5("sample-cancelled");
              this.onProgress?.({ phase: "prebuffer", completedCount: ++completed, totalCount: unique.size });
            }
          } catch (error2) {
            preparationError = error2;
          }
          try {
            await this.persistentCache?.flush?.();
          } catch (error2) {
            if (!preparationError) preparationError = error2;
            else console.warn("Sample cache checkpoint failed:", error2);
          }
          if (preparationError) throw preparationError;
          if (this.closed) throw failure5("sample-cancelled");
        }
        close() {
          if (this.closed) return;
          this.closed = true;
          this._worker?.close();
          for (const job of this.pending.values()) job.reject(failure5("sample-cancelled"));
          this.pending.clear();
          this.queue.length = 0;
          this.prepared.clear();
          this.openSamples.clear();
        }
      };
    }
  });

  // entry.mjs
  var entry_exports = {};
  __export(entry_exports, {
    SFZ_REGION_FIELDS: () => SFZ_REGION_FIELDS,
    SfzLibraryService: () => SfzLibraryService,
    attachSfzSampleStreamWorker: () => attachSfzSampleStreamWorker,
    compileSf2: () => compileSf2,
    decodeSfzBank: () => decodeSfzBank,
    encodeSfzBank: () => encodeSfzBank,
    identifySfzBank: () => identifySfzBank,
    listSfzFolderFiles: () => listSfzFolderFiles,
    mergeSfzWarnings: () => mergeSfzWarnings,
    normalizeSfzPath: () => normalizeSfzPath,
    openSf2Source: () => openSf2Source,
    packSf2Modulation: () => packSf2Modulation,
    packSfzAsset: () => packSfzAsset,
    packStreamedSfzAsset: () => packStreamedSfzAsset,
    parseSf2: () => parseSf2,
    parseSfz: () => parseSfz,
    prepareSfzSamples: () => prepareSfzSamples,
    prepareSoundFontBank: () => prepareSoundFontBank,
    prepareStreamedSfzBank: () => prepareStreamedSfzBank,
    samplePlayerPreparationData: () => samplePlayerPreparationData,
    selectSfzRegionsForBudget: () => selectSfzRegionsForBudget,
    sf2SamplerRegions: () => sf2SamplerRegions,
    sfzPluginPreparationContext: () => sfzPluginPreparationContext,
    sfzPreparationContext: () => sfzPreparationContext
  });
  init_parser();
  init_asset();
  init_service();
  init_bank();

  // js/audio/offline-output-settings.js
  var WAV_SAMPLE_FORMATS = Object.freeze([
    Object.freeze({ id: "pcm16", labelKey: "dialog.config.offlineOutput.wav.pcm16" }),
    Object.freeze({ id: "pcm24", labelKey: "dialog.config.offlineOutput.wav.pcm24" }),
    Object.freeze({ id: "float32", labelKey: "dialog.config.offlineOutput.wav.float32" })
  ]);
  var FLAC_SAMPLE_FORMATS = Object.freeze([
    Object.freeze({ id: "pcm16", labelKey: "dialog.config.offlineOutput.flac.pcm16" }),
    Object.freeze({ id: "pcm24", labelKey: "dialog.config.offlineOutput.flac.pcm24" })
  ]);
  var LOSSLESS_SAMPLE_RATES = Object.freeze([44100, 48e3, 88200, 96e3, 176400, 192e3]);
  var DEFAULT_OFFLINE_OUTPUT_SETTINGS = Object.freeze({
    format: "wav",
    sampleRate: 96e3,
    wavSampleFormat: "pcm24",
    flacSampleFormat: "pcm24"
  });
  var OFFLINE_OUTPUT_FORMATS = Object.freeze({
    wav: Object.freeze({
      id: "wav",
      labelKey: "dialog.config.offlineOutput.format.wav",
      filterLabel: "WAV Audio",
      extension: "wav",
      mimeType: "audio/wav",
      sampleRates: LOSSLESS_SAMPLE_RATES,
      defaultSampleRate: 96e3,
      qualityType: "wavSampleFormat",
      qualityOptions: WAV_SAMPLE_FORMATS,
      defaultQuality: "pcm24",
      maxChannels: 16
    }),
    flac: Object.freeze({
      id: "flac",
      labelKey: "dialog.config.offlineOutput.format.flac",
      filterLabel: "FLAC Audio",
      extension: "flac",
      mimeType: "audio/flac",
      sampleRates: LOSSLESS_SAMPLE_RATES,
      defaultSampleRate: 96e3,
      qualityType: "flacSampleFormat",
      qualityOptions: FLAC_SAMPLE_FORMATS,
      defaultQuality: "pcm24",
      maxChannels: 8
    })
  });
  var isPlainObject = (value) => {
    if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
    const prototype = Object.getPrototypeOf(value);
    return prototype === Object.prototype || prototype === null;
  };
  function getOfflineOutputFormat(id) {
    return typeof id === "string" && Object.hasOwn(OFFLINE_OUTPUT_FORMATS, id) ? OFFLINE_OUTPUT_FORMATS[id] : OFFLINE_OUTPUT_FORMATS.wav;
  }
  function normalizeOfflineOutputSettings(value) {
    const input = isPlainObject(value) ? value : {};
    const hasKnownFormat = typeof input.format === "string" && Object.hasOwn(OFFLINE_OUTPUT_FORMATS, input.format);
    if (!hasKnownFormat) return { ...DEFAULT_OFFLINE_OUTPUT_SETTINGS };
    const format = input.format;
    const definition = OFFLINE_OUTPUT_FORMATS[format];
    const sampleRate = definition.sampleRates.includes(input.sampleRate) ? input.sampleRate : definition.defaultSampleRate;
    return {
      format,
      sampleRate,
      wavSampleFormat: WAV_SAMPLE_FORMATS.some((option) => option.id === input.wavSampleFormat) ? input.wavSampleFormat : DEFAULT_OFFLINE_OUTPUT_SETTINGS.wavSampleFormat,
      flacSampleFormat: FLAC_SAMPLE_FORMATS.some((option) => option.id === input.flacSampleFormat) ? input.flacSampleFormat : DEFAULT_OFFLINE_OUTPUT_SETTINGS.flacSampleFormat
    };
  }
  function validateOfflineOutputChannels(settings, channelCount) {
    const normalized = normalizeOfflineOutputSettings(settings);
    const format = getOfflineOutputFormat(normalized.format);
    if (!Number.isInteger(channelCount) || channelCount < 1) {
      throw new TypeError("channelCount must be a positive integer");
    }
    if (channelCount <= format.maxChannels) return format;
    const error2 = new Error(`${format.id} does not support ${channelCount} channels`);
    error2.userMessageKey = "error.offlineOutput.unsupportedChannels";
    error2.userMessageValues = {
      format: format.id.toUpperCase(),
      maxChannels: format.maxChannels
    };
    throw error2;
  }

  // js/audio/audio-encoder.js
  var MAX_WAV_DATA_SIZE = 4294967295 - 36;
  var WAV_ASYNC_CHUNK_FRAMES = 16 * 1024;
  var FLAC_PCM16_CHUNK_FRAMES = 16 * 1024;
  function createOutputError(userMessageKey, message, cause, userMessageValues = void 0) {
    const error2 = new Error(message, cause ? { cause } : void 0);
    error2.userMessageKey = userMessageKey;
    if (userMessageValues) error2.userMessageValues = userMessageValues;
    return error2;
  }
  function throwIfAborted(signal) {
    if (!signal?.aborted) return;
    throw createOutputError("status.processingCanceled", "Offline output encoding was canceled");
  }
  function reportProgress(callback, phase, progress = null) {
    callback?.({ phase, progress });
  }
  function getWavBytesPerSample(sampleFormat) {
    return sampleFormat === "pcm16" ? 2 : sampleFormat === "pcm24" ? 3 : 4;
  }
  function getResampledFrameCount(length, inputSampleRate, outputSampleRate) {
    const outputLength = Math.round(length * outputSampleRate / inputSampleRate);
    if (!Number.isSafeInteger(outputLength) || outputLength < 1) {
      throw createOutputError(
        "error.offlineOutput.rateConversionFailed",
        "Invalid resampling output length"
      );
    }
    return outputLength;
  }
  function validateWavDataSize(numberOfChannels, length, sampleFormat) {
    const dataSize = length * numberOfChannels * getWavBytesPerSample(sampleFormat);
    if (!Number.isSafeInteger(dataSize) || dataSize < 0 || dataSize > MAX_WAV_DATA_SIZE) {
      throw createOutputError("error.offlineOutput.invalidOutput", "WAV output is too large");
    }
    return dataSize;
  }
  function preflightOfflineOutput(audioBuffer, settings) {
    const normalized = normalizeOfflineOutputSettings(settings);
    const definition = validateOfflineOutputChannels(normalized, audioBuffer?.numberOfChannels);
    const outputLength = getResampledFrameCount(
      audioBuffer?.length,
      audioBuffer?.sampleRate,
      normalized.sampleRate
    );
    if (normalized.format === "wav") {
      validateWavDataSize(
        audioBuffer.numberOfChannels,
        outputLength,
        normalized.wavSampleFormat
      );
    }
    return { definition, normalized, outputLength };
  }
  function quantizePcm16(raw) {
    const sample = raw < -1 ? -1 : raw > 1 ? 1 : raw;
    return Math.round(sample < 0 ? sample * 32768 : sample * 32767);
  }
  function quantizePcm24(raw) {
    const sample = raw < -1 ? -1 : raw > 1 ? 1 : raw;
    return Math.round(sample < 0 ? sample * 8388608 : sample * 8388607);
  }
  function quantizeFlacPcm24(raw) {
    const integer = Math.round(raw * 2147483648);
    return (integer < -2147483648 ? -2147483648 : integer > 2147483647 ? 2147483647 : integer) >> 8;
  }
  function createWavEncoding(audioBuffer, sampleFormat) {
    const formatCode = sampleFormat === "float32" ? 3 : 1;
    const bitsPerSample = sampleFormat === "pcm16" ? 16 : sampleFormat === "pcm24" ? 24 : 32;
    const bytesPerSample = bitsPerSample / 8;
    const numChannels = audioBuffer.numberOfChannels;
    const samples = audioBuffer.length;
    const blockAlign = numChannels * bytesPerSample;
    const dataSize = validateWavDataSize(numChannels, samples, sampleFormat);
    const buffer = new ArrayBuffer(44 + dataSize);
    const view = new DataView(buffer);
    const writeString = (offset, value) => {
      for (let index = 0; index < value.length; index++) {
        view.setUint8(offset + index, value.charCodeAt(index));
      }
    };
    writeString(0, "RIFF");
    view.setUint32(4, 36 + dataSize, true);
    writeString(8, "WAVE");
    writeString(12, "fmt ");
    view.setUint32(16, 16, true);
    view.setUint16(20, formatCode, true);
    view.setUint16(22, numChannels, true);
    view.setUint32(24, audioBuffer.sampleRate, true);
    view.setUint32(28, audioBuffer.sampleRate * blockAlign, true);
    view.setUint16(32, blockAlign, true);
    view.setUint16(34, bitsPerSample, true);
    writeString(36, "data");
    view.setUint32(40, dataSize, true);
    return {
      buffer,
      view,
      bytesPerSample,
      numChannels,
      samples,
      channels: Array.from(
        { length: numChannels },
        (_2, channel) => audioBuffer.getChannelData(channel)
      )
    };
  }
  function writeWavFrames(wav, sampleFormat, startFrame, endFrame) {
    let offset = 44 + startFrame * wav.numChannels * wav.bytesPerSample;
    for (let frame = startFrame; frame < endFrame; frame++) {
      for (let channel = 0; channel < wav.numChannels; channel++) {
        const raw = wav.channels[channel][frame];
        const sample = raw < -1 ? -1 : raw > 1 ? 1 : raw;
        if (sampleFormat === "pcm16") {
          wav.view.setInt16(offset, quantizePcm16(raw), true);
        } else if (sampleFormat === "pcm24") {
          const integer = quantizePcm24(raw) & 16777215;
          wav.view.setUint8(offset, integer & 255);
          wav.view.setUint8(offset + 1, integer >> 8 & 255);
          wav.view.setUint8(offset + 2, integer >> 16 & 255);
        } else {
          wav.view.setFloat32(offset, raw, true);
        }
        offset += wav.bytesPerSample;
      }
    }
  }
  var AudioEncoder2 = class {
    constructor({
      loadVendor = () => Promise.resolve().then(() => (init_offline_audio_encoders(), offline_audio_encoders_exports)),
      createOfflineContext = (channels, length, sampleRate) => new OfflineAudioContext(channels, length, sampleRate)
    } = {}) {
      this.loadVendor = loadVendor;
      this.createOfflineContext = createOfflineContext;
    }
    /** Legacy-compatible 24-bit WAV encoder. */
    encodeWAV(audioBuffer) {
      return this.encodeWav(audioBuffer, "pcm24");
    }
    encodeWav(audioBuffer, sampleFormat) {
      const wav = createWavEncoding(audioBuffer, sampleFormat);
      writeWavFrames(wav, sampleFormat, 0, wav.samples);
      return new Blob([wav.buffer], { type: "audio/wav" });
    }
    async encodeWavAsync(audioBuffer, sampleFormat, { signal } = {}) {
      throwIfAborted(signal);
      const wav = createWavEncoding(audioBuffer, sampleFormat);
      for (let startFrame = 0; startFrame < wav.samples; startFrame += WAV_ASYNC_CHUNK_FRAMES) {
        throwIfAborted(signal);
        const endFrame = Math.min(startFrame + WAV_ASYNC_CHUNK_FRAMES, wav.samples);
        writeWavFrames(wav, sampleFormat, startFrame, endFrame);
        if (endFrame < wav.samples) {
          await new Promise((resolve) => setTimeout(resolve, 0));
        }
      }
      throwIfAborted(signal);
      return new Blob([wav.buffer], { type: "audio/wav" });
    }
    async resampleAudioBuffer(audioBuffer, targetSampleRate, { signal, onProgress } = {}) {
      if (audioBuffer.sampleRate === targetSampleRate) return audioBuffer;
      throwIfAborted(signal);
      const outputLength = getResampledFrameCount(
        audioBuffer.length,
        audioBuffer.sampleRate,
        targetSampleRate
      );
      reportProgress(onProgress, "resampling", 0);
      try {
        const context = this.createOfflineContext(
          audioBuffer.numberOfChannels,
          outputLength,
          targetSampleRate
        );
        const source = context.createBufferSource();
        source.buffer = audioBuffer;
        source.connect(context.destination);
        source.start();
        const rendered = await context.startRendering();
        throwIfAborted(signal);
        if (!rendered || rendered.length !== outputLength || rendered.numberOfChannels !== audioBuffer.numberOfChannels) {
          throw new Error("Unexpected resampling result");
        }
        reportProgress(onProgress, "resampling", 1);
        return rendered;
      } catch (error2) {
        if (error2?.userMessageKey) throw error2;
        throw createOutputError(
          "error.offlineOutput.rateConversionFailed",
          "Offline output sample-rate conversion failed",
          error2
        );
      }
    }
    trimTrailingEncodedZeros(audioBuffer, settings, minimumSeconds) {
      if (!Number.isFinite(minimumSeconds) || minimumSeconds < 0) return audioBuffer;
      const format = settings.format === "wav" ? settings.wavSampleFormat : settings.flacSampleFormat;
      const quantize = format === "float32" ? (value) => value : format === "pcm16" ? quantizePcm16 : settings.format === "flac" ? quantizeFlacPcm24 : quantizePcm24;
      let length = Math.min(audioBuffer.length, Math.max(1, Math.ceil(minimumSeconds * audioBuffer.sampleRate)));
      for (let channel = 0; channel < audioBuffer.numberOfChannels; channel++) {
        const samples = audioBuffer.getChannelData(channel);
        for (let frame = audioBuffer.length - 1; frame >= length; frame--) {
          if (quantize(samples[frame]) !== 0) {
            length = frame + 1;
            break;
          }
        }
      }
      if (length === audioBuffer.length) return audioBuffer;
      const trimmed = this.createOfflineContext(audioBuffer.numberOfChannels, length, audioBuffer.sampleRate).createBuffer(audioBuffer.numberOfChannels, length, audioBuffer.sampleRate);
      for (let channel = 0; channel < audioBuffer.numberOfChannels; channel++) {
        trimmed.getChannelData(channel).set(audioBuffer.getChannelData(channel).subarray(0, length));
      }
      return trimmed;
    }
    async encode(audioBuffer, settings, { onProgress, signal, trimTrailingZerosAfterSeconds } = {}) {
      const { definition, normalized } = preflightOfflineOutput(audioBuffer, settings);
      throwIfAborted(signal);
      const resampled = await this.resampleAudioBuffer(audioBuffer, normalized.sampleRate, {
        signal,
        onProgress
      });
      throwIfAborted(signal);
      const outputBuffer = this.trimTrailingEncodedZeros(resampled, normalized, trimTrailingZerosAfterSeconds);
      reportProgress(onProgress, "encoding", 0);
      const blob = normalized.format === "wav" ? await this.encodeWavAsync(outputBuffer, normalized.wavSampleFormat, { signal }) : await this.encodeFlac(outputBuffer, normalized, { signal });
      throwIfAborted(signal);
      if (!(blob instanceof Blob) || blob.size === 0 || blob.type !== definition.mimeType) {
        throw createOutputError("error.offlineOutput.invalidOutput", "Encoder produced invalid output");
      }
      reportProgress(onProgress, "encoding", 1);
      return {
        blob,
        format: normalized.format,
        extension: definition.extension,
        mimeType: definition.mimeType,
        sampleRate: normalized.sampleRate,
        numberOfChannels: outputBuffer.numberOfChannels
      };
    }
    async encodeFlac(audioBuffer, settings, { signal } = {}) {
      let vendor;
      try {
        vendor = await this.loadVendor();
      } catch (error2) {
        console.error("Failed to load offline audio codec assets:", error2);
        throw createOutputError(
          "error.offlineOutput.codecAssetsUnavailable",
          "Offline audio codec assets could not be loaded",
          error2
        );
      }
      throwIfAborted(signal);
      const target = new vendor.BufferTarget();
      const format = new vendor.FlacOutputFormat();
      const output = new vendor.Output({ format, target });
      const pcm16 = settings.flacSampleFormat === "pcm16";
      const source = pcm16 ? new vendor.AudioSampleSource({ codec: "flac" }) : new vendor.AudioBufferSource({ codec: "flac" });
      output.addAudioTrack(source);
      const abort = () => {
        output.cancel().catch((error2) => console.warn("Failed to cancel offline audio encoding:", error2));
      };
      signal?.addEventListener("abort", abort, { once: true });
      try {
        await output.start();
        throwIfAborted(signal);
        if (pcm16) {
          await this.addFlacPcm16Samples(vendor, source, audioBuffer, { signal });
        } else {
          await source.add(audioBuffer);
        }
        throwIfAborted(signal);
        await output.finalize();
        if (!target.buffer || target.buffer.byteLength === 0) {
          throw createOutputError("error.offlineOutput.invalidOutput", "Encoder produced an empty output buffer");
        }
        return new Blob([target.buffer], { type: getOfflineOutputFormat(settings.format).mimeType });
      } catch (error2) {
        await output.cancel().catch(() => {
        });
        if (error2?.userMessageKey) throw error2;
        console.error("Offline audio encoding failed:", {
          format: settings.format,
          sampleRate: audioBuffer.sampleRate,
          numberOfChannels: audioBuffer.numberOfChannels,
          error: error2
        });
        throw createOutputError(
          "error.offlineOutput.encoderInitializationFailed",
          "Offline audio encoding failed",
          error2
        );
      } finally {
        signal?.removeEventListener("abort", abort);
      }
    }
    async addFlacPcm16Samples(vendor, source, audioBuffer, { signal } = {}) {
      const numberOfChannels = audioBuffer.numberOfChannels;
      const channels = Array.from(
        { length: numberOfChannels },
        (_2, channel) => audioBuffer.getChannelData(channel)
      );
      for (let startFrame = 0; startFrame < audioBuffer.length; startFrame += FLAC_PCM16_CHUNK_FRAMES) {
        throwIfAborted(signal);
        const endFrame = Math.min(startFrame + FLAC_PCM16_CHUNK_FRAMES, audioBuffer.length);
        const frameCount = endFrame - startFrame;
        const data = new ArrayBuffer(frameCount * numberOfChannels * 2);
        const view = new DataView(data);
        let offset = 0;
        for (let frame = startFrame; frame < endFrame; frame++) {
          for (let channel = 0; channel < numberOfChannels; channel++) {
            view.setInt16(offset, quantizePcm16(channels[channel][frame]), true);
            offset += 2;
          }
        }
        const sample = new vendor.AudioSample({
          data,
          format: "s16",
          numberOfChannels,
          sampleRate: audioBuffer.sampleRate,
          timestamp: startFrame / audioBuffer.sampleRate
        });
        try {
          await source.add(sample);
        } finally {
          sample.close();
        }
        if (endFrame < audioBuffer.length) {
          await new Promise((resolve) => setTimeout(resolve, 0));
        }
      }
    }
  };

  // js/sfz/streamed-bank.js
  init_ir_library_factory();
  init_ir_pcm_cache();
  init_asset();
  init_generators();
  init_parser();
  init_sample_reader();
  init_sample_page_provider();
  init_script_worker();
  init_oscillator_source();
  init_sample_stream_worker();
  init_sample_metadata();
  init_effects_asset();
  init_preparation_context();

  // js/sfz/storage-plan.js
  init_parser();
  init_effects_asset();
  var PAGE = 4096;
  var pcm16Key = (path) => `\0sfz-pcm16-v1:${path}`;
  function sfzStorageVariants(parsed, cycles = /* @__PURE__ */ new Set()) {
    const sources = /* @__PURE__ */ new Map(), modes = /* @__PURE__ */ new Map();
    const add = (path, mode) => {
      const key = mode === 1 ? pcm16Key(path) : path;
      sources.set(key, path);
      modes.set(key, mode);
      return key;
    };
    const regions = parsed.regions.map((region) => ({
      ...region,
      sample: add(region.sample, region.load_mode ?? 0)
    }));
    for (const path of effectSamplePaths(parsed.effects)) add(path, 0);
    const paths = [...sources.keys()].sort();
    const mandatory = new Set(paths.filter((path) => cycles.has(sources.get(path)) || effectSamplePaths(parsed.effects).includes(path)));
    return { parsed: { ...parsed, regions }, paths, sources, modes, mandatory };
  }
  function sfzResidentRanges(regions, samples, mandatory = /* @__PURE__ */ new Set()) {
    const ranges = new Map([...samples.keys()].map((path) => [path, []]));
    for (const path of mandatory) ranges.get(path).push([0, samples.get(path).frames]);
    for (const region of regions) {
      if (region.load_start === void 0 && region.load_end === void 0) continue;
      const frames = samples.get(region.sample).frames;
      const rawFirst = region.load_start ?? 0, rawEnd = region.load_end === void 0 ? frames : region.load_end + 1;
      if (rawFirst > rawEnd) throw sfzError("prepare", "The instrument sample loading range is invalid.");
      const first = Math.min(frames, rawFirst), end = Math.min(frames, rawEnd);
      if (first < end) ranges.get(region.sample).push([
        Math.floor(first / PAGE) * PAGE,
        Math.min(frames, Math.ceil(end / PAGE) * PAGE)
      ]);
    }
    for (const [path, intervals] of ranges) {
      intervals.sort((a, b2) => a[0] - b2[0]);
      const merged = [];
      for (const [first, end] of intervals) {
        const last = merged.at(-1);
        if (last && first <= last[1]) last[1] = Math.max(last[1], end);
        else merged.push([first, end]);
      }
      ranges.set(path, merged);
    }
    return ranges;
  }
  function sfzStorageSlots(total, samples, ranges) {
    let required16 = 0, required32 = 0, count16 = 0, count32 = 0;
    for (const [path, sample] of samples) {
      const pages = ranges.get(path).reduce((sum, [first, end]) => sum + Math.ceil(end / PAGE) - Math.floor(first / PAGE), 0);
      if (sample.storageMode === 1) {
        count16++;
        required16 += pages;
      } else {
        count32++;
        required32 += pages;
      }
    }
    const minimum16 = required16 + (count16 ? 1 : 0), minimum32 = required32 + (count32 ? 1 : 0);
    if (total < minimum16 + minimum32) return null;
    const slots16 = !count16 ? 0 : !count32 ? total : Math.max(minimum16, Math.min(total - minimum32, Math.round(total * count16 / (count16 + count32))));
    return { cacheSlots: total, slots16, residentRanges: ranges, minimumSlots: minimum16 + minimum32 };
  }

  // js/sfz/streamed-bank.js
  async function prepareStreamedSfzBank({
    id,
    parsed,
    maxBytes,
    createSampleReader,
    cacheBackend,
    onDiagnostic,
    onProgress,
    preparationContext = null,
    estimateEffectBytes
  }, { workerFactory, persistentCache } = {}) {
    parsed = await prepareSfzLoopMetadata(parsed, createSampleReader, maxBytes);
    const script = parsed.script ? await compileSfzScriptAsync(parsed.script.source) : null;
    let cycleWorker, cycleSample = 0, oscillators;
    try {
      oscillators = await prepareSfzOscillatorSources(parsed, async (path, budget) => {
        if (isSfzGenerator(path)) return createSfzGeneratorSample(path);
        cycleWorker ??= new SfzSampleStreamWorker({ workerFactory });
        const sample = cycleSample++, info = await cycleWorker.open(sample, await createSampleReader(path));
        if (info.frames * info.channels * 4 > budget) throw sfzError("too-large", "The wavetable needs more sample memory.");
        const channels = Array.from({ length: info.channels }, () => new Float32Array(info.frames));
        for (let page2 = 0; page2 * 4096 < info.frames; page2++) {
          const decoded = await cycleWorker.readPage(sample, page2);
          for (let channel = 0; channel < info.channels; channel++) for (let frame = 0; frame < decoded.frames; frame++) {
            channels[channel][page2 * 4096 + frame] = decoded.pcm[frame * info.channels + channel];
          }
        }
        return { sampleRate: info.sampleRate, channels };
      }, maxBytes);
    } finally {
      cycleWorker?.close();
    }
    parsed = oscillators.parsed;
    if (persistentCache === void 0) {
      try {
        const backend = cacheBackend || await openIrLibraryBackend({ namespace: "sfz-library", onDiagnostic });
        persistentCache = await new PersistentIrPcmCache(backend, { onDiagnostic, indexWriteInterval: 128 }).open();
      } catch (error2) {
        onDiagnostic?.({ sampleCache: error2 });
        persistentCache = null;
      }
    }
    const storage = parsed.modulation?.format === "sf2" ? null : sfzStorageVariants(parsed, new Set(oscillators.samples.keys()));
    if (storage) parsed = storage.parsed;
    const paths = storage?.paths ?? [.../* @__PURE__ */ new Set([...parsed.regions.map((region) => region.sample), ...effectSamplePaths(parsed.effects)])].sort();
    const readers = /* @__PURE__ */ new Map();
    const factory = await createSfzSampleProviderFactory({
      assetId: id,
      paths,
      persistentCache,
      onProgress,
      workerFactory,
      storageModes: storage ? paths.map((path) => storage.modes.get(path)) : null,
      createReader: async (key) => {
        const path = storage?.sources.get(key) ?? key;
        if (readers.has(path)) return readers.get(path);
        const opened = (async () => {
          if (!oscillators.samples.has(path) && !isSfzGenerator(path)) return createSampleReader(path);
          const pcm = oscillators.samples.get(path) ?? createSfzGeneratorSample(path);
          const blob = new AudioEncoder2().encodeWav({
            numberOfChannels: pcm.channels.length,
            length: pcm.channels[0].length,
            sampleRate: pcm.sampleRate,
            getChannelData: (channel) => pcm.channels[channel]
          }, "float32");
          const reader = await createSfzFileSampleReader(new File([blob], "generator.wav", { lastModified: 0 }));
          const digest = new Uint8Array(await globalThis.crypto.subtle.digest("SHA-256", await blob.arrayBuffer()));
          return { ...reader, revision: Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("") };
        })();
        readers.set(path, opened);
        return opened;
      }
    });
    const samples = new Map(paths.map((path, index) => [path, factory.samples[index]]));
    if (typeof globalThis.__effectdeckSfzSampleTable === "function") {
      const table = [];
      for (const [index, key] of paths.entries()) {
        const path = storage?.sources.get(key) ?? key;
        table.push({
          index,
          path,
          reader: await readers.get(path),
          sample: factory.samples[index],
          mode: storage ? storage.modes.get(key) : 0
        });
      }
      globalThis.__effectdeckSfzSampleTable(table);
    }
    const build = async (context, budget = maxBytes, estimate = estimateEffectBytes, previous = null) => {
      const warnings2 = [];
      const options = {
        maxBytes: budget,
        script,
        modulation: parsed.modulation,
        effects: parsed.effects,
        sourceProfile: parsed.sourceProfile ?? null,
        presets: parsed.presets ?? null,
        onDiagnostic,
        onWarning: (warning) => warnings2.push(warning)
      };
      const ranges = storage ? sfzResidentRanges(parsed.regions, samples, storage.mandatory) : new Map(paths.map((path) => [path, []]));
      if (!storage) for (const path of /* @__PURE__ */ new Set([...oscillators.samples.keys(), ...effectSamplePaths(parsed.effects)]))
        ranges.get(path)?.push([0, samples.get(path).frames]);
      const maximumPlan = storage ? sfzStorageSlots(32768, samples, ranges) : null;
      if (storage && !maximumPlan) throw sfzError("too-large", "The instrument needs more sample memory. Increase the SFZ memory limit.");
      const required = [];
      for (const [sample, path] of paths.entries()) for (const [first, end] of ranges.get(path))
        for (let pageIndex = Math.floor(first / 4096); pageIndex <= Math.floor((end - 1) / 4096); pageIndex++)
          required.push(Object.freeze({ sample, pageIndex }));
      const minimum = storage ? maximumPlan.minimumSlots : required.length + 1;
      if (minimum > 32768) throw sfzError("too-large", "The instrument needs more sample memory. Increase the SFZ memory limit.");
      const cacheChannels = factory.samples.some((sample) => sample.channels === 2) ? 2 : 1;
      const plan = (slots) => storage ? sfzStorageSlots(slots, samples, ranges) : null;
      const cacheBytes = (slots) => sfzSampleCacheFootprint(samples.size, slots, cacheChannels, plan(slots));
      const provisional = packStreamedSfzAsset(
        parsed.regions,
        samples,
        { ...options, cacheSlots: minimum, storagePlan: plan(minimum) }
      );
      let descriptor2 = provisional;
      if (context) {
        const materialized = await materializeSfzAsset(provisional, context, budget, estimate);
        const otherBytes = materialized.nativePreparationBytes - cacheBytes(minimum);
        if (!Number.isSafeInteger(otherBytes) || otherBytes < 0) throw sfzError("prepare", "Instrument preparation is unavailable. Reload the app and try again.");
        if (previous && sameSfzPreparationGeometry(previous.preparationContext, materialized.preparationContext) && otherBytes <= previous.nativeNonCacheBytes && previous.footprintBytes <= budget)
          return { descriptor: previous, warnings: warnings2 };
        let low = minimum;
        let high = Math.max(minimum, Math.min(32768, factory.samples.reduce((count, sample) => Math.min(32768, count + Math.ceil(sample.frames / 4096)), 0) + 2));
        while (low < high) {
          const middle = Math.ceil((low + high) / 2);
          if (provisional.payload.byteLength + otherBytes + cacheBytes(middle) <= budget) low = middle;
          else high = middle - 1;
        }
        warnings2.length = 0;
        if (storage) descriptor2 = packStreamedSfzAsset(
          parsed.regions,
          samples,
          { ...options, cacheSlots: low, storagePlan: plan(low), preparationContext: materialized.preparationContext }
        );
        else {
          new Uint32Array(provisional.payload, 32)[14] = low;
          descriptor2.preparationContext = materialized.preparationContext;
        }
        descriptor2.processingChannels = materialized.processingChannels;
        descriptor2.nativeNonCacheBytes = otherBytes;
        descriptor2.nativePreparationBytes = otherBytes + cacheBytes(low);
        descriptor2.footprintBytes = descriptor2.payload.byteLength + descriptor2.nativePreparationBytes;
        descriptor2.sampleCacheSlots = low;
      } else descriptor2.sampleCacheSlots = minimum;
      descriptor2.sampleCacheBytes = cacheBytes(descriptor2.sampleCacheSlots);
      descriptor2.sampleProviderFactory = async (context2) => {
        const provider = await factory(context2);
        try {
          await provider.preload(required);
          provider.startSupply = (context3) => factory.startSupply(provider, context3);
          return provider;
        } catch (error2) {
          provider.close();
          throw error2;
        }
      };
      descriptor2.materializeForContext = async (context2, nextBudget, nextEstimate) => {
        const next = (await build(context2, nextBudget, nextEstimate, descriptor2)).descriptor;
        next.unsupportedOpcodes = descriptor2.unsupportedOpcodes;
        next.incomplete = descriptor2.incomplete;
        return next;
      };
      return { descriptor: descriptor2, warnings: warnings2 };
    };
    const { descriptor, warnings } = await build(preparationContext);
    descriptor.unsupportedOpcodes = [...parsed.unsupportedOpcodes || []];
    descriptor.incomplete = Boolean(parsed.diagnostics?.missingSamples?.length || parsed.diagnostics?.invalidRegions?.length || warnings.some((warning) => warning.code === "invalid-regions"));
    const counts = new Map((parsed.warnings || []).map((warning) => [warning.code, warning.count]));
    for (const warning of warnings) counts.set(warning.code, (counts.get(warning.code) || 0) + warning.count);
    return {
      descriptor,
      sampleCount: paths.length,
      regionCount: new Uint32Array(descriptor.payload, 32)[2],
      ...counts.size && { warnings: [...counts].map(([code, count]) => ({ code, count })) }
    };
  }

  // entry.mjs
  init_sample_stream_worker();
  init_preparation_context();

  // js/sfz/effect-cost.js
  init_parser();
  init_preparation_context();
  function samplePlayerPreparationData(payload) {
    if (!(payload instanceof ArrayBuffer) || payload.byteLength < 56 || payload.byteLength > 4294967295 || payload.byteLength % 4)
      throw sfzError("prepare", "The instrument preparation data is invalid.");
    const header = new DataView(payload);
    const controlBytes = 32 + header.getUint32(48, true) * 4;
    if (header.getUint32(0, true) !== 826364997 || controlBytes < 56 || controlBytes > payload.byteLength)
      throw sfzError("prepare", "The instrument preparation data is invalid.");
    return { control: payload.slice(0, controlBytes), payloadBytes: payload.byteLength };
  }

  // entry.mjs
  init_parser2();
  init_compiler();
  init_source2();

  // js/sf2/asset.js
  function sf2SamplerRegions(source) {
    const samples = new Map(source.samples.map((sample) => [sample.sampleId, sample]));
    return source.compiled.regions.map((region) => {
      const sample = samples.get(region.sampleId), end = region.sample.end - sample.start - 1;
      return {
        sample: sample.path,
        lokey: region.keyRange[0],
        hikey: region.keyRange[1],
        lovel: region.velocityRange[0],
        hivel: region.velocityRange[1],
        lorand: 0,
        hirand: 1,
        seq_length: 1,
        seq_position: 1,
        seqGroup: 0,
        pitch_keycenter: region.sample.originalPitch,
        pitch_keytrack: 100,
        transpose: 0,
        tune: region.sample.pitchCorrection,
        volume: 0,
        pan: 0,
        amp_veltrack: 0,
        offset: region.sample.start - sample.start,
        end,
        loop_mode: region.generators[54] & 1 ? region.generators[54] & 2 ? 3 : 2 : 0,
        loop_start: region.sample.loopStart - sample.start,
        loop_end: region.sample.loopEnd - sample.start - 1,
        ampeg_attack: 0,
        ampeg_hold: 0,
        ampeg_decay: 0,
        ampeg_sustain: 100,
        ampeg_release: 1e-3
      };
    });
  }
  async function prepareSoundFontBank({ source, ...options }, providerOptions) {
    if (source.samples.some((sample) => sample.compressed) && (typeof globalThis.AudioDecoder !== "function" || !(await AudioDecoder.isConfigSupported({ codec: "vorbis", sampleRate: 44100, numberOfChannels: 1 })).supported)) {
      const error2 = new Error("This browser cannot play compressed SoundFonts. Use a browser with Vorbis decoding support or choose an SF2 SoundFont.");
      error2.code = "sample-codec-unavailable";
      throw error2;
    }
    options.onDiagnostic?.({ sf2: source.compiled.diagnostics });
    const parsed = {
      regions: sf2SamplerRegions(source),
      modulation: source.compiled,
      sourceProfile: source.compiled.sourceProfile,
      presets: source.compiled.presets
    };
    return {
      ...await prepareStreamedSfzBank({ ...options, parsed, createSampleReader: source.createSampleReader }, providerOptions),
      sourceBytes: source.sourceBytes
    };
  }

  // entry.mjs
  init_modulation2();
  return __toCommonJS(entry_exports);
})();
/*! Bundled license information:

mediabunny/dist/modules/src/misc.js:
mediabunny/dist/modules/src/logging.js:
mediabunny/dist/modules/src/metadata.js:
mediabunny/dist/modules/shared/bitstream.js:
mediabunny/dist/modules/shared/aac-misc.js:
mediabunny/dist/modules/src/version.js:
mediabunny/dist/modules/src/codec-data.js:
mediabunny/dist/modules/src/pcm.js:
mediabunny/dist/modules/src/sample.js:
mediabunny/dist/modules/src/encode.js:
mediabunny/dist/modules/src/custom-coder.js:
mediabunny/dist/modules/src/packet.js:
mediabunny/dist/modules/src/resample.js:
mediabunny/dist/modules/src/flac/flac-misc.js:
mediabunny/dist/modules/src/reader.js:
mediabunny/dist/modules/src/isobmff/isobmff-reader.js:
mediabunny/dist/modules/src/media-source.js:
mediabunny/dist/modules/src/codec.js:
mediabunny/dist/modules/src/muxer.js:
mediabunny/dist/modules/src/flac/flac-muxer.js:
mediabunny/dist/modules/src/writer.js:
mediabunny/dist/modules/src/target.js:
mediabunny/dist/modules/src/output-format.js:
mediabunny/dist/modules/src/output.js:
mediabunny/dist/modules/src/index.js:
@mediabunny/flac-encoder/dist/bundles/mediabunny-flac-encoder.mjs:
  (*!
   * Copyright (c) 2026-present, Vanilagy and contributors
   *
   * This Source Code Form is subject to the terms of the Mozilla Public
   * License, v. 2.0. If a copy of the MPL was not distributed with this
   * file, You can obtain one at https://mozilla.org/MPL/2.0/.
   *)
*/
