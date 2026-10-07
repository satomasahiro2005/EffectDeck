// Tools/jsfx-bench/diff.cpp — jsfx-bench --diff: 同じ JSFX を EEL の実行系ごとに回して 1 ビットまで比べる。
//
//   jsfx-bench --diff [--diff-blocks 48] <file.jsfx|dir> ...
//
// ETJSFX ではなく ysfx をじかに使う（出力の NaN・非正規化数の拭き取りを通さず、変数とメモリも読める）。
// 実行系ごとに作り直して、同じ順に同じものを渡す:
//   - 48 kHz・ブロック長 256。1 ブロックのフレーム数は 256・1・17・64・255・… と変える
//   - 入力は ysfx_process_double（double のまま比べる）。正弦 + 雑音に、ときどき NaN・±Inf・
//     非正規化数・-0・大きな値を混ぜる
//   - ときどきつまみを動かし（範囲の中と外）、trigger と再生位置も送る
// 比べるもの: 毎ブロックの出力（bit）、最後の変数の全部（ysfx_enum_vars、bit）、EEL のメモリ全部、
// @serialize の中身（ysfx_save_state）。基準は NSEEL_EXEC_PORTABLE。
// 違ったら終了値 1。
#include "ysfx.h"
#include "WDL/eel2/ns-eel.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <map>
#include <string>
#include <sys/stat.h>
#include <vector>

namespace {
constexpr double kRate = 48000;
constexpr uint32_t kMaxFrames = 256;
constexpr uint32_t kMaxChannels = 8;
const uint32_t kFrameCycle[] = {256, 1, 17, 64, 255, 256, 128, 3, 256, 200};

uint64_t mix64(uint64_t x)
{
    x += 0x9e3779b97f4a7c15ull; x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ull;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebull; return x ^ (x >> 31);
}
uint64_t bitsOf(double v) { uint64_t b; std::memcpy(&b, &v, 8); return b; }

struct Run {
    bool loaded = false, compiled = false, modeOk = false;
    std::vector<uint64_t> out;                 // 出力の bit を全部
    std::map<std::string, uint64_t> vars;      // 最後の変数
    uint64_t memHash = 1469598103934665603ull; // EEL のメモリ全部
    uint32_t memNonZero = 0;
    std::vector<uint8_t> state;                // @serialize
    bool stateOk = false;
    double seconds = 0;
};

int collectVar(const char *name, ysfx_real *var, void *user)
{
    auto *vars = static_cast<std::map<std::string, uint64_t> *>(user);
    (*vars)[name] = bitsOf(*var);
    return 1;
}

double specialValue(uint64_t r)
{
    switch (r % 8) {
    case 0: return NAN;
    case 1: return INFINITY;
    case 2: return -INFINITY;
    case 3: return 1e-310;          // 非正規化数
    case 4: return -0.0;
    case 5: return 1e30;
    case 6: return -3.0;
    default: return 4.9e-324;
    }
}

Run runOnce(const std::string &path, int mode, uint32_t blocks)
{
    Run r;
    ysfx_config_t *config = ysfx_config_new();
    ysfx_t *fx = ysfx_new(config);
    ysfx_config_free(config);
    r.loaded = ysfx_load_file(fx, path.c_str(), 0);
    r.compiled = r.loaded && ysfx_compile(fx, 0);
    r.modeOk = ysfx_set_eel_exec_mode(fx, mode);
    if (!r.compiled || !r.modeOk) { ysfx_free(fx); return r; }
    ysfx_set_sample_rate(fx, kRate);
    ysfx_set_block_size(fx, kMaxFrames);
    ysfx_init(fx);

    const uint32_t ins = std::min<uint32_t>(std::max<uint32_t>(ysfx_get_num_inputs(fx), 2), kMaxChannels);
    const uint32_t outs = std::min<uint32_t>(std::max<uint32_t>(ysfx_get_num_outputs(fx), 2), kMaxChannels);
    std::vector<double> inBuf(kMaxChannels * kMaxFrames), outBuf(kMaxChannels * kMaxFrames);
    const double *inPtr[kMaxChannels];
    double *outPtr[kMaxChannels];
    for (uint32_t c = 0; c < kMaxChannels; ++c) { inPtr[c] = &inBuf[c * kMaxFrames]; outPtr[c] = &outBuf[c * kMaxFrames]; }

    uint64_t n = 0;
    double pos = 0;
    for (uint32_t b = 0; b < blocks; ++b) {
        const uint32_t frames = kFrameCycle[b % (sizeof kFrameCycle / sizeof *kFrameCycle)];
        const uint64_t rb = mix64(b * 977 + 13);
        // つまみ: 4 ブロックに 1 回、数本を範囲の中（ときどき外）へ
        if (b % 4 == 1) {
            for (uint32_t i = 0; i < ysfx_max_sliders; ++i) {
                if (!ysfx_slider_exists(fx, i)) continue;
                const uint64_t rs = mix64(rb ^ (i * 0x51ed27ull));
                if (rs % 3) continue;
                ysfx_slider_range_t range{};
                ysfx_slider_get_range(fx, i, &range);
                const double u = (double)(rs >> 11) * (1.0 / 9007199254740992.0);
                double v = range.min + (range.max - range.min) * u;
                if (rs % 17 == 0) v = range.max + 1 + u * 10;
                if (rs % 19 == 0) v = range.min - 1 - u * 10;
                ysfx_slider_set_value(fx, i, v, true);
            }
        }
        if (b % 7 == 3) ysfx_send_trigger(fx, (uint32_t)(rb % 10));
        ysfx_time_info_t t{};
        t.tempo = 90 + (double)(rb % 60); t.playback_state = (b / 8) % 2 ? ysfx_playback_playing : ysfx_playback_paused;
        t.time_position = pos; t.beat_position = pos * t.tempo / 60; t.time_signature[0] = 4; t.time_signature[1] = 4;
        ysfx_set_time_info(fx, &t);
        // 入力
        for (uint32_t c = 0; c < ins; ++c)
            for (uint32_t i = 0; i < frames; ++i) {
                const uint64_t k = n + i;
                const uint64_t rr = mix64(k * 2 + c + 0x1234);
                double v = 0.4 * std::sin(2 * 3.141592653589793 * (220 + 111 * c) * (double)k / kRate) +
                           0.05 * ((double)(rr >> 11) * (1.0 / 9007199254740992.0) * 2 - 1);
                if (b % 5 == 4 && rr % 37 == 0) v = specialValue(rr >> 7);
                inBuf[c * kMaxFrames + i] = v;
            }
        std::fill(outBuf.begin(), outBuf.end(), 0.0);
        ysfx_process_double(fx, inPtr, outPtr, ins, outs, frames);
        for (uint32_t c = 0; c < outs; ++c)
            for (uint32_t i = 0; i < frames; ++i) r.out.push_back(bitsOf(outBuf[c * kMaxFrames + i]));
        n += frames;
        pos += frames / kRate;
    }

    ysfx_enum_vars(fx, &collectVar, &r.vars);
    // EEL のメモリ（ysfx の上限 2M 語。確保していない塊は 0 として読む）
    std::vector<ysfx_real> chunk(65536);
    for (uint32_t addr = 0; addr < 2u * 1024 * 1024; addr += (uint32_t)chunk.size()) {
        ysfx_read_vmem(fx, addr, chunk.data(), (uint32_t)chunk.size());
        for (ysfx_real v : chunk) {
            const uint64_t bits = bitsOf(v);
            if (bits) ++r.memNonZero;
            r.memHash = mix64(r.memHash ^ bits);
        }
    }
    if (ysfx_state_t *s = ysfx_save_state(fx)) {
        r.stateOk = true;
        r.state.assign(s->data, s->data + s->data_size);
        for (uint32_t i = 0; i < s->slider_count; ++i) {
            uint8_t raw[12]; std::memcpy(raw, &s->sliders[i].index, 4); std::memcpy(raw + 4, &s->sliders[i].value, 8);
            r.state.insert(r.state.end(), raw, raw + 12);
        }
        ysfx_state_free(s);
    }
    ysfx_free(fx);
    return r;
}

void listInputs(const std::string &path, std::vector<std::string> &out)
{
    struct stat st{};
    if (stat(path.c_str(), &st) != 0) { std::fprintf(stderr, "jsfx-bench --diff: missing %s\n", path.c_str()); return; }
    if (!S_ISDIR(st.st_mode)) { out.push_back(path); return; }
    DIR *d = opendir(path.c_str());
    if (!d) return;
    std::vector<std::string> names;
    while (dirent *e = readdir(d)) {
        std::string name = e->d_name;
        if (name == "." || name == "..") continue;
        struct stat cs{};
        const std::string full = path + "/" + name;
        if (stat(full.c_str(), &cs) == 0 && S_ISREG(cs.st_mode)) names.push_back(full);
    }
    closedir(d);
    std::sort(names.begin(), names.end());
    out.insert(out.end(), names.begin(), names.end());
}
} // namespace

int ETJSFXBenchDiffMain(const std::vector<std::string> &paths, uint32_t blocks)
{
    std::vector<std::string> files;
    for (const auto &p : paths) listInputs(p, files);
    std::vector<int> modes;
    for (int m = 1; m < NSEEL_EXEC_COUNT; ++m) if (NSEEL_code_exec_mode_available(m)) modes.push_back(m);
    std::printf("jsfx-bench --diff: %zu files, %u blocks each, modes", files.size(), blocks);
    for (int m : modes) std::printf(" %s", NSEEL_code_exec_mode_name(m));
    std::printf(" vs portable\n");
    if (modes.empty()) { std::printf("RESULT FAIL (no executor other than portable in this build)\n"); return 1; }
    int failures = 0, compared = 0, skipped = 0;
    for (const auto &file : files) {
        const Run ref = runOnce(file, NSEEL_EXEC_PORTABLE, blocks);
        const char *base = std::strrchr(file.c_str(), '/');
        base = base ? base + 1 : file.c_str();
        if (!ref.compiled) {
            // 読めない・建たないものは実行系に関係ない。他の実行系でも同じかだけ見る。
            bool same = true;
            for (int m : modes) { Run r = runOnce(file, m, 1); same &= r.loaded == ref.loaded && r.compiled == ref.compiled; }
            std::printf("  %-34s not compiled (%s)%s\n", base, ref.loaded ? "compile" : "load", same ? "" : "  MISMATCH");
            if (!same) ++failures;
            ++skipped;
            continue;
        }
        std::string line;
        bool fileOk = true;
        for (int m : modes) {
            const Run r = runOnce(file, m, blocks);
            std::string why;
            if (!r.compiled || !r.modeOk) why = "not run";
            else {
                if (r.out.size() != ref.out.size()) why += "out-size ";
                else {
                    size_t bad = 0, first = (size_t)-1;
                    for (size_t i = 0; i < r.out.size(); ++i) if (r.out[i] != ref.out[i]) { if (!bad) first = i; ++bad; }
                    if (bad) why += "out(" + std::to_string(bad) + " smp, first " + std::to_string(first) + ") ";
                }
                if (r.vars != ref.vars) {
                    size_t bad = 0; std::string firstName;
                    for (const auto &kv : ref.vars) {
                        auto it = r.vars.find(kv.first);
                        if (it == r.vars.end() || it->second != kv.second) { if (!bad) firstName = kv.first; ++bad; }
                    }
                    if (r.vars.size() != ref.vars.size()) ++bad;
                    why += "vars(" + std::to_string(bad) + ", " + firstName + ") ";
                }
                if (r.memHash != ref.memHash) why += "mem ";
                if (r.stateOk != ref.stateOk || r.state != ref.state) why += "state ";
            }
            line += std::string(" ") + NSEEL_code_exec_mode_name(m) + "=" + (why.empty() ? "ok" : why);
            if (!why.empty()) fileOk = false;
        }
        ++compared;
        if (!fileOk) ++failures;
        std::printf("  %-34s %6zu smp %4zu vars mem%7u%s%s\n", base, ref.out.size(), ref.vars.size(), ref.memNonZero,
                    line.c_str(), fileOk ? "" : "  MISMATCH");
    }
    std::printf("compared %d, not compiled %d, mismatched %d\n", compared, skipped, failures);
    std::printf(failures ? "RESULT FAIL\n" : "RESULT ok\n");
    return failures ? 1 : 0;
}
