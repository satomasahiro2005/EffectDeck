//  ETSampleStream.h
//  SFZ・SoundFont の標本を、再生しながらページ単位で engine へ渡す口（EffeTune 2.17.0）。
//
//  **なぜ要るか。**流し込み（streamed）の bank（SF2・SF3・load_* を持つ SFZ・予算を超える SFZ）は、
//  標本の PCM を engine が持たず、必要なページ（4096 フレーム）を要求してくる。ホストが
//  et_instance_stream_take_requests で要求を受け取り、et_instance_stream_publish でページを返す。
//  上流は AudioWorklet のスレッドで「描画の合間」にそれをしている（plugins/audio-processor.js:801-842）。
//  こちらの「描画の合間」は ETPipeline_Process の前と後。
//
//  **ホストの責務は 4 つ。**
//    1. 描画の前に、用意できたページを ET_STREAM_PUBLISH_PER_BLOCK 枚まで publish する
//    2. 描画の後に、要求を take_requests で受け取って要求の輪へ積む
//    3. Note Player は、いまの音色の先頭ページを先読みする（SELECTED_PRESETS の予測。
//       audio-processor.js:5054-5130 の移植。flags 13 → 6、窓 1.5 s → 1 s → 0.25 s、0.5 s ごとに更新）
//    4. 読み出した結果（readiness）を画面が見られるようにする
//  音のスレッドの側（1〜3）は確保も待ちもしない。ページの中身を作るのは別のスレッド（ETSFZPageSource）で、
//  輪と置き場（page pool）だけで音のスレッドとやり取りする。
//
//  **これは audio thread の上で engine の stream 関数を呼ぶ。**abi.h は prefetch と readiness を
//  CONTROL 専用としているが、描画の合間なら process と同じスレッドなので競合しない。確保が
//  起きないことは Tests/Native/sample_stream.c が本物の engine の allocation guard で確かめる。
//  publish が確保しうるのは、効果つきの bank で最初のページを受けた 1 回だけ（prepareSfzEffects）で、
//  resident ページは control 側（ETSampleStream_PublishDirect）で先に渡すので音のスレッドには来ない。
//
//  **スレッドは 3 つ。**
//    音（R）   BeforeProcess / AfterProcess。ETPipeline_Process が呼ぶ。
//    control（C）  Attach / Detach / PublishDirect / Snapshot。
//                 **Attach と PublishDirect は AssetUpload.holdOffAudioThread の中で呼ぶ**
//                 （master bypass の間は BeforeProcess / AfterProcess が何もしないので、engine に触るのは control だけ）。
//    供給（S） TakeRequests / AcquirePage / SubmitPage / ReleasePage / Abandon / IsCurrent。
//  輪は 1 本あたり 1 生産者・1 消費者（SPSC）で、ロックは無い。

#ifndef ETSampleStream_h
#define ETSampleStream_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    /// 同時に流せる instance の数。SFZ Note Player が 1〜2 本入る程度を見ている。
    ET_STREAM_MAX_SLOTS = 4,
    /// 1 ページのフレーム数（上流の SFZ_SAMPLE_PAGE_FRAMES、dsp の kStorageCachePageFrames）。
    ET_STREAM_PAGE_FRAMES = 4096,
    ET_STREAM_PAGE_MAX_CHANNELS = 2,
    /// 供給側へ渡すページの置き場の枚数（1 枚 4096×2×4 B = 32 KiB。slot ごとに 2 MiB）。
    ET_STREAM_POOL_PAGES = 64,
    /// 要求の輪の大きさ。engine 側の上限（kStorageCacheRequestCapacity）と同じ 2 の冪。
    ET_STREAM_REQUEST_RING = 4096,
    /// 1 ブロックで publish するページの数の上限（全 slot の合計）。
    /// 1 枚 32 KiB なので、8 枚で 256 KiB。GUESS: 実機で xrun が出るなら下げる。
    ET_STREAM_PUBLISH_PER_BLOCK = 8,
    /// take_requests に渡す一度の容量。音のスレッドの stack に 6 KiB だけ使う。
    ET_STREAM_TAKE_CHUNK = 256,
};

/// 供給が要求に応えられなかった理由（ETStreamStatus.failed）。上流の sfzStreamFailed（→ clearPluginAsset）に当たる。
/// 置き場が空のあいだは失敗にしない（音のスレッドが進めば空く。待ち続ける）。失敗はこの 3 つだけ。
enum {
    ET_STREAM_FAIL_NONE = 0,
    ET_STREAM_FAIL_READ = 1,      ///< 標本を読めなかった・変わっていた
    ET_STREAM_FAIL_RANGE = 2,     ///< 要求の標本の番号が表の外
    ET_STREAM_FAIL_SUBMIT = 3,    ///< 作ったページを engine へ渡す形にできなかった
};

enum {
    /// Note Player の SELECTED_PRESETS 予測を回す（ET_STREAM_FORECAST_SELECTED_PRESETS）。
    ET_STREAM_ATTACH_FORECAST = 1,
};

/// engine が要求したページ。generation は et_instance_stream_configure に渡した世代。
typedef struct {
    uint64_t generation;
    uint64_t page;
    uint32_t sample;
    uint32_t reserved;
} ETStreamRequest;

/// 置き場の 1 枚。供給側は AcquirePage で借り、pcm に書いて SubmitPage か ReleasePage で返す。
/// pcm は frames × channels の f32（インターリーブ）。1 枚の容量は 4096×2。
typedef struct ETStreamPage {
    float *pcm;
    uint64_t generation;
    uint64_t page;
    uint32_t sample;
    uint32_t frames;
    uint32_t channels;
    uint32_t flags;        ///< 1 = resident（et_instance_stream_publish の flags と同じ）
    uint32_t slot;
    uint32_t index;
    void *owner;           ///< 内部。触らない。
} ETStreamPage;

/// 画面が読む状態。値は音のスレッドが書いて control が読む（relaxed の atomic。互いに少しずれうる）。
typedef struct {
    uint64_t generation;          ///< Attach で渡した世代
    uint64_t requestsTaken;       ///< engine から受け取った要求
    uint64_t pagesPublished;      ///< engine が受け取ったページ
    uint64_t pagesStale;          ///< 世代が古くて捨てたページ（供給側の SubmitPage と publish の両方）
    uint64_t publishErrors;       ///< engine が断ったページ（ET_ERR_STATE 以外）
    uint64_t requestsAbandoned;   ///< 片付けた数に入れた、ページを渡さなかった要求（止めたときの残りと、失敗の分）
    uint64_t requestsFailed;      ///< 供給が作れなかった要求（requestsAbandoned の内数）
    uint64_t requestOverflows;    ///< 要求が engine の上限を超えた回数（ET_ERR_OOM）
    uint64_t forecastRuns;        ///< 先読みを進めた回数
    uint64_t forecastErrors;      ///< 先読みの失敗
    uint32_t failed;              ///< 0 = 無事。0 以外は最初の失敗の理由（ET_STREAM_FAIL_*）。立ったら読み直しが要る
    uint32_t outstanding;         ///< 受け取ったが、まだ publish も断念もしていない要求
    uint32_t maxPublishPerBlock;  ///< 1 ブロックで publish した最大
    uint32_t forecastReady;       ///< 先読みが完了している（SELECTED_PRESETS の先頭が揃っている）
    uint32_t forecastLimited;     ///< 圧に負けて窓を縮めた（上流の stream.limited）
    uint32_t readinessScope;      ///< et_stream_readiness の値
    uint32_t readinessPlanned;
    uint32_t readinessPending;
    uint32_t readinessAdmitted;
    uint32_t readinessReadyAhead;
} ETStreamStatus;

// MARK: - control（holdOffAudioThread の中で呼ぶ）

/// instance を流しの対象にする。et_instance_stream_configure(generation) を呼んでから slot を立てる。
/// 戻りは et_status（configure の結果。slot が無い・置き場が取れないときは ET_ERR_STATE / ET_ERR_OOM）。
/// 同じ instance に再度呼ぶと前の slot を畳んで世代を替える（バンクを読み直したとき）。
/// **generation は ETSampleStream_NextGeneration で取る。**プロセス全体で増え続ける 1 以上の値で、
/// Attach は最後に受けた世代以下を ET_ERR_ARGS で断る。供給の栅は (slot, 世代) しか見ないので、壊した
/// instance の供給が残っていても、同じ世代で別の instance が同じ slot に付くことが無いようにするため。
/// sampleRate は engine の rate（先読みの窓に使う）。
/// 確保はここだけ（輪と置き場を 1 回で取る）。
int32_t ETSampleStream_Attach(uint32_t engine, uint32_t instance, uint64_t generation,
                              double sampleRate, uint32_t flags, uint32_t *slotOut);

/// 解放を延ばしてある確保の数（診断・試験用。何もしない）。
uint32_t ETSampleStream_Parked(void);

/// 次に使う世代。これまでに Attach が受けた世代も、ここで渡した世代も超える。control から呼ぶ。
uint64_t ETSampleStream_NextGeneration(void);

/// 試験用。世代の下限を 0 に戻す。slot が 1 つも無く、供給のスレッドが 1 本も残っていないときだけ。
void ETSampleStream_ResetGenerationsForTesting(void);

/// instance の先読みを進めるか。無効（node か Section が無い）のあいだは先読みをしない。
/// ETPipeline_Publish が node ごとに合わせる。slot が無ければ何もしない。新しい slot は有効から始まる。
void ETSampleStream_SetEnabled(uint32_t engine, uint32_t instance, int enabled);

/// 流しをやめる。**et_instance_destroy の前**（ETPipeline_DestroyInstances が呼ぶ）か、資産を外すときに。
/// 戻りは畳んだ slot の数（0 か 1）。供給側がまだページを持っていれば、解放は Reap まで延ばす。
int ETSampleStream_Detach(uint32_t engine, uint32_t instance);

/// 全 slot を畳む。engine を替えるとき（ETPipeline_SetEngine）。
void ETSampleStream_DetachAll(void);

/// 延ばしてある解放を試す。まだ残っている数を返す。
/// Attach / Detach / DetachAll は先頭でこれを呼ぶ。供給が抜けたあと（ETSFZPageSource.stop() の最後）にも呼ぶこと。
uint32_t ETSampleStream_Reap(void);

/// resident ページ（preload）を control から直に渡す。et_instance_stream_publish の薄い包み。
/// **holdOffAudioThread の中で**呼ぶ。channels は 1 か 2、frames は 1〜4096。
int32_t ETSampleStream_PublishDirect(uint32_t engine, uint32_t instance, uint64_t generation,
                                     uint32_t sample, uint64_t page, const float *pcm,
                                     uint32_t frames, uint32_t channels, int resident);

/// 状態を読む。slot が生きていれば 1。
int ETSampleStream_Snapshot(uint32_t slot, ETStreamStatus *out);

/// instance が使っている slot。無ければ -1。
int ETSampleStream_SlotFor(uint32_t engine, uint32_t instance);

// MARK: - 音のスレッド（ETPipeline_Process が呼ぶ。確保も待ちも無い）

/// 描画の前。用意できたページを publish する（全 slot で ET_STREAM_PUBLISH_PER_BLOCK 枚まで）。
void ETSampleStream_BeforeProcess(void);

/// 描画の後。frames は今のブロックの長さ。要求を受け取って輪へ積み、Note Player なら先読みを進める。
void ETSampleStream_AfterProcess(uint32_t frames);

// MARK: - 供給（ページを作るスレッド）

/// 要求を最大 capacity 件取り出す。slot が終わっていれば（世代が合わなければ）0 を返す。
uint32_t ETSampleStream_TakeRequests(uint32_t slot, uint64_t generation,
                                     ETStreamRequest *out, uint32_t capacity);

/// 置き場から 1 枚借りる。空きが無い・slot が終わっていれば NULL。
/// 空きが無いのは失敗ではない（音のスレッドが止まっている間は publish が進まない）。IsCurrent が 1 のあいだは借り直す。
ETStreamPage *ETSampleStream_AcquirePage(uint32_t slot, uint64_t generation);

/// 借りたページを渡す。request の generation を見て、いまの世代と違えば捨てて 0 を返す。
/// 戻りが 1 のとき、次の BeforeProcess で publish される。
int ETSampleStream_SubmitPage(ETStreamPage *page, const ETStreamRequest *request,
                              uint32_t frames, uint32_t channels);

/// 借りたページを使わずに返す。
void ETSampleStream_ReleasePage(ETStreamPage *page);

/// 止めるときに、取ったまま渡さなかった要求を片付けた数に入れる（失敗ではない）。
void ETSampleStream_Abandon(uint32_t slot, uint64_t generation, uint32_t count);

/// 要求に応えられなかった。**黙って捨てない。**engine は一度出した要求を再送しない（取った要求は
/// ページを publish するまで inFlight のまま）ので、捨てた分のページは bank を読み直すまで欠け続ける。
/// 理由（ET_STREAM_FAIL_*）を slot に残し、ETStreamStatus.failed で見えるようにする。供給は手を止め、
/// 読み込む側が資産を外すか読み直す（上流の sfzStreamFailed → clearPluginAsset と同じ）。
/// count 件を片付けた数にも入れる。
void ETSampleStream_Fail(uint32_t slot, uint64_t generation, uint32_t reason, uint32_t count);

/// slot がまだこの世代で生きているか。長い読み出しの途中で見て、終わっていれば手を止める。
int ETSampleStream_IsCurrent(uint32_t slot, uint64_t generation);

#ifdef __cplusplus
}
#endif

#endif /* ETSampleStream_h */
