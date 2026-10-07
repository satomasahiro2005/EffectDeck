// ETJSFXBench.h — JSFX の実行系を同じ入力・同じ測り方で比べる（docs/jsfx-bench.md）。
//
// **店の版には入れない。**中身は ET_JSFX_BENCH が 1 のときだけ建つ
// （Debug の DEBUG=1、Beta の ET_BETA=1、Tools/jsfx-bench/run.sh の -DET_JSFX_BENCH=1）。
// Release では宣言だけが残り、呼ぶ側（JSFXBench.swift）も #if DEBUG || ET_BETA で消える。
#ifndef ETJSFXBench_h
#define ETJSFXBench_h
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifndef ET_JSFX_BENCH
#  if (defined(DEBUG) && DEBUG) || (defined(ET_BETA) && ET_BETA)
#    define ET_JSFX_BENCH 1
#  else
#    define ET_JSFX_BENCH 0
#  endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ETJSFXBenchOptions {
    /// *.jsfx の在るフォルダ（Debug/JSFXBench、アプリでは DebugJSFXBench）。
    const char *scriptDir;
    /// 走らせるスクリプトの名前（拡張子なし）をカンマで。NULL か空なら全部。
    const char *scripts;
    /// 走らせる実行系をカンマで。NULL か空なら建っているもの全部。
    const char *variants;
    /// 測る長さ（音の秒）。既定 5 秒 = 938 ブロック。
    double seconds;
    /// 測る前に回す長さ（音の秒）。既定 0.5 秒。
    double warmupSeconds;
    /// 実行系を入れ替える間隔（ブロック）。既定 16。
    uint32_t chunkBlocks;
    /// 音のスレッドと同じ時間制約の方針で回すか（Apple だけ）。既定 true。
    bool realtimePolicy;
    /// 測る前に CPU を空回しする長さ（ミリ秒、壁の時計）。既定 500。周波数を上げてから測るため。
    double cpuWarmupMilliseconds;
    /// JSON に書くだけの字（NULL 可）。
    const char *buildConfig;
    const char *gitSHA;
    const char *compilerFlags;
} ETJSFXBenchOptions;

typedef struct ETJSFXBenchReport ETJSFXBenchReport;

void ETJSFXBench_DefaultOptions(ETJSFXBenchOptions *options);
/// 呼んだスレッドで回す（時間制約の方針もこのスレッドへ掛ける）。失敗しても NULL ではなく、
/// 中の error に理由が入る。
ETJSFXBenchReport *ETJSFXBench_Run(const ETJSFXBenchOptions *options);
/// 人が読む表。free は ETJSFXBench_FreeString。
char *ETJSFXBench_Table(const ETJSFXBenchReport *report);
/// JSON。extraFields は `"k":v,"k2":v2` の形（頭に足す。NULL 可）。
char *ETJSFXBench_JSON(const ETJSFXBenchReport *report, const char *extraFields);
/// 出力の照合（cpp の誤差・vm の一致）と作成が全部通ったか。
bool ETJSFXBench_Passed(const ETJSFXBenchReport *report);
void ETJSFXBench_Free(ETJSFXBenchReport *report);
void ETJSFXBench_FreeString(char *text);

#ifdef __cplusplus
}
#endif
#endif
