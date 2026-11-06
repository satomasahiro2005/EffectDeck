//  sfz_admission.c
//  SFZ / SoundFont の資産が、上流の見積り（et_sample_player_preparation_bytes）どおりの footprint で
//  カーネルに受け入れられるかを、本物の engine で見る（-DET_NATIVE_WITH_ENGINE=ON）。
//  見本は Tests/Fixtures/SFZ（Tools/golden/sfz_golden.mjs が上流の JS で作った payload）。
//
//  確保の見積りは CONTROL 専用で PCM を読まない。footprint は「payload のバイト数 + 返した追加分」
//  だけが正しく、1 バイト足りなければ commit が断る（-3）。見積りが上流とずれると、ここで落ちる。

#include "effetune/abi.h"
#include "et_test.h"

#ifndef ET_SFZ_FIXTURES
#error "ET_SFZ_FIXTURES (Tests/Fixtures/SFZ) is required"
#endif

enum { FR = 128, SAMPLE_RATE_HZ = 48000, PLAYER_SFZ = 0, PLAYER_SF2 = 1, BLOCKS = 40 };

static uint8_t *readAll(const char *name, size_t *n)
{
    char path[512];
    snprintf(path, sizeof path, "%s/%s", ET_SFZ_FIXTURES, name);
    FILE *f = fopen(path, "rb");
    ET_CHECK_MSG(f != NULL, "cannot open %s", path);
    fseek(f, 0, SEEK_END);
    *n = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *b = (uint8_t *)malloc(*n);
    ET_CHECK(b != NULL);
    ET_CHECK(fread(b, 1, *n, f) == *n);
    fclose(f);
    return b;
}

static uint32_t le32(const uint8_t *b, int o)
{
    return (uint32_t)b[o] | (uint32_t)b[o + 1] << 8 | (uint32_t)b[o + 2] << 16 | (uint32_t)b[o + 3] << 24;
}

typedef struct {
    int prepStatus;     // et_sample_player_preparation_bytes の戻り
    int commitStatus;   // asset_begin が取れたときの commit の戻り（取れなければ -99）
    uint32_t stateAfterCommit;
    uint32_t stateAfterRun;
    int processStatus;  // 最後の process の戻り
    int began;
} Result;

// delta は見積りの footprint に足す差（0 が上流どおり、-1 は 1 バイト足りない）。
// proc は見積りと begin の processingChannels、runChannels は process に渡す実際のチャンネル数。
static Result admitRun(const char *type, uint32_t kind, const char *file, uint32_t proc, uint32_t runChannels,
                       int32_t delta, int configureStream)
{
    Result r = { 0, -99, 0, 0, 0, 0 };
    size_t n;
    uint8_t *b = readAll(file, &n);
    et_engine e = et_engine_create();
    ET_CHECK(et_engine_prepare(e, (float)SAMPLE_RATE_HZ, 4, FR, 0) == 0);
    et_instance inst = et_instance_create(e, type);
    uint32_t ctl = 32 + 4 * le32(b, 48);
    if (ctl > n) ctl = (uint32_t)n;
    uint64_t add = 0;
    r.prepStatus = (int)et_sample_player_preparation_bytes(b, ctl, n, 1, (float)SAMPLE_RATE_HZ, proc, FR, 0,
                                                           &add, kind);
    uint32_t footprint = (uint32_t)((int64_t)(n + add) + delta);
    uint8_t *staging = et_instance_asset_begin_ptr(e, inst, 0, 1, le32(b, 8), 0, FR, 1, 0, 0, proc,
                                                   footprint, n, 0);
    r.began = staging != NULL;
    if (staging) {
        memcpy(staging, b, n);
        r.commitStatus = (int)et_instance_asset_commit(e, inst, 0, n, 1);
        r.stateAfterCommit = et_instance_asset_state(e, inst, 0);
        if (configureStream) ET_CHECK(et_instance_stream_configure(e, inst, 9, 0) == 0);
        float *buf = et_arena_combined_ptr(e);
        for (int k = 0; k < BLOCKS; k++) {
            memset(buf, 0, sizeof(float) * runChannels * FR);
            r.processStatus = (int)et_instance_process(e, inst, buf, runChannels, FR, (double)k * FR / SAMPLE_RATE_HZ);
        }
        r.stateAfterRun = et_instance_asset_state(e, inst, 0);
    }
    et_engine_destroy(e);
    free(b);
    return r;
}

static Result admit(const char *type, uint32_t kind, const char *file, uint32_t proc, int32_t delta,
                    int configureStream)
{
    return admitRun(type, kind, file, proc, 2, delta, configureStream);
}

static void expectActive(Result r)
{
    ET_CHECK_MSG(r.prepStatus == 0, "prep=%d", r.prepStatus);
    ET_CHECK(r.began);
    ET_CHECK_MSG(r.commitStatus == 0, "commit=%d", r.commitStatus);
    ET_CHECK_MSG(r.stateAfterCommit == ET_ASSET_STATE_PREPARING, "state=%u", r.stateAfterCommit);
    ET_CHECK(r.processStatus == 0);
    ET_CHECK_MSG(r.stateAfterRun == ET_ASSET_STATE_ACTIVE, "state=%u", r.stateAfterRun);
}

ET_CASE(sfz_two_samples_admitted)
{
    expectActive(admit("SFZNotePlayerPlugin", PLAYER_SFZ, "payloads/asset-two-samples.bin", 2, 0, 0));
}

ET_CASE(sfz_plain_admitted)
{
    expectActive(admit("SFZNotePlayerPlugin", PLAYER_SFZ, "payloads/imports-plain.bin", 2, 0, 0));
}

// v6（モジュレーション無し）・v7（モジュレーション付き）・効果つきの見本を、見積りどおりの footprint で通す。
ET_CASE(sfz_v6_goldens_admitted)
{
    static const char *const files[] = { "payloads/asset-bad-loop-oneshot.bin", "payloads/asset-groups-and-offsets.bin",
                                         "payloads/asset-two-samples.bin" };
    for (size_t i = 0; i < sizeof files / sizeof files[0]; i++)
        expectActive(admit("SFZNotePlayerPlugin", PLAYER_SFZ, files[i], 2, 0, 0));
}

ET_CASE(sfz_v7_goldens_admitted)
{
    static const char *const files[] = { "payloads/imports-plain.bin", "payloads/imports-cc-aftertouch-program.bin",
                                         "payloads/imports-curve-and-modulation.bin", "payloads/imports-script.bin",
                                         "payloads/imports-trigger-all.bin" };
    for (size_t i = 0; i < sizeof files / sizeof files[0]; i++)
        expectActive(admit("SFZNotePlayerPlugin", PLAYER_SFZ, files[i], 2, 0, 0));
}

ET_CASE(sfz_effects_admitted)
{
    expectActive(admit("SFZNotePlayerPlugin", PLAYER_SFZ, "payloads/imports-effects.bin", 2, 0, 0));
}

// 見積りの footprint は下限。1 バイト足りないと commit が断り、資産は STAGED のまま動かない。
ET_CASE(sfz_footprint_one_byte_short_rejected)
{
    Result r = admit("SFZNotePlayerPlugin", PLAYER_SFZ, "payloads/imports-plain.bin", 2, -1, 0);
    ET_CHECK(r.prepStatus == 0);
    ET_CHECK(r.began);
    ET_CHECK_MSG(r.commitStatus == -3, "commit=%d", r.commitStatus);
    ET_CHECK_MSG(r.stateAfterRun == ET_ASSET_STATE_STAGED, "state=%u", r.stateAfterRun);
}

// 0.16 時代の payload（版 2）は、見積りの段で断られる。
ET_CASE(sfz_legacy_v2_payload_rejected)
{
    Result r = admit("SFZNotePlayerPlugin", PLAYER_SFZ, "legacy-v2-payload.bin", 2, 4096, 0);
    ET_CHECK_MSG(r.prepStatus == -1, "prep=%d", r.prepStatus);
    ET_CHECK_MSG(r.stateAfterRun == ET_ASSET_STATE_ERROR, "state=%u", r.stateAfterRun);
}

// 効果つきの payload は、begin の processingChannels と process のチャンネル数が違うと動かせない
// （commitSfzEffects が一致を要る）。見積りと begin に同じ値を入れる理由。
ET_CASE(sfz_effects_channel_mismatch_fails)
{
    Result r = admitRun("SFZNotePlayerPlugin", PLAYER_SFZ, "payloads/imports-effects.bin", 1, 2, 0, 0);
    ET_CHECK(r.prepStatus == 0 && r.began && r.commitStatus == 0);
    ET_CHECK_MSG(r.stateAfterRun == ET_ASSET_STATE_ERROR, "state=%u process=%d", r.stateAfterRun,
                 r.processStatus);
}

ET_CASE(sfz_effects_channels_match_active)
{
    Result r = admitRun("SFZNotePlayerPlugin", PLAYER_SFZ, "payloads/imports-effects.bin", 1, 1, 0, 0);
    ET_CHECK(r.prepStatus == 0 && r.began && r.commitStatus == 0);
    ET_CHECK_MSG(r.stateAfterRun == ET_ASSET_STATE_ACTIVE, "state=%u", r.stateAfterRun);
}

ET_CASE(sf2_native_fixture_admitted)
{
    Result r = admit("SoundFontPlayerPlugin", PLAYER_SF2, "payloads/sf2-native-fixture.bin", 2, 0, 0);
    ET_CHECK(r.prepStatus == 0 && r.began && r.commitStatus == 0);
    ET_CHECK_MSG(r.stateAfterRun == ET_ASSET_STATE_PREPARING, "state=%u", r.stateAfterRun);
}

// SoundFont（版 9）は et_instance_stream_configure を呼ぶまで ACTIVE にならず（PREPARING のまま・process は失敗しない）、
// 呼べば ACTIVE になって落ちない。流し込みの SFZ（版 8）は、ホストが標本のページを渡すところまで要るので D1 で見る。
ET_CASE(sf2_native_fixture_active_after_configure)
{
    Result r = admit("SoundFontPlayerPlugin", PLAYER_SF2, "payloads/sf2-native-fixture.bin", 2, 0, 1);
    ET_CHECK(r.prepStatus == 0 && r.began && r.commitStatus == 0);
    ET_CHECK_MSG(r.stateAfterRun == ET_ASSET_STATE_ACTIVE, "state=%u", r.stateAfterRun);
}

static const et_case cases[] = {
    ET_ENTRY(sfz_two_samples_admitted),
    ET_ENTRY(sfz_plain_admitted),
    ET_ENTRY(sfz_v6_goldens_admitted),
    ET_ENTRY(sfz_v7_goldens_admitted),
    ET_ENTRY(sfz_effects_admitted),
    ET_ENTRY(sfz_effects_channel_mismatch_fails),
    ET_ENTRY(sfz_effects_channels_match_active),
    ET_ENTRY(sfz_footprint_one_byte_short_rejected),
    ET_ENTRY(sfz_legacy_v2_payload_rejected),
    ET_ENTRY(sf2_native_fixture_admitted),
    ET_ENTRY(sf2_native_fixture_active_after_configure),
};

int main(int argc, char **argv) { return et_run(argc, argv, cases, ET_COUNT(cases)); }
