// ETVMExec.h — 中間表現から速い実行系（threaded code、段 S2）のプログラムを作る・回す・放す。
// docs/jsfx-regvm-design.md §9。中身は ETVMSelect.cpp（並べ方・升の割り当て）と ETVMHandlers.cpp（ハンドラ）。
#pragma once

#include "ETVMIR.h"

#include <cstddef>
#include <cstdint>
#include <string>

namespace etvm {

struct ThreadedProgram;

/// 作ったプログラムの数え（表示・JSON 用）。
struct ThreadedStats {
    size_t irInstructions = 0; // 中間表現の命令（consts を除く）
    size_t handlers = 0;       // 並べたハンドラ（phi の写し・跳びを含む）
    size_t words = 0;          // 語（8 バイト）
    size_t slots = 0;          // 枠の升（SSA の値・定数・写しの一時）
    size_t dead = 0;           // 使われない純な値（出さない）
    size_t foldedLoads = 0;    // LoadCell をオペランドの升へ畳んだ
    size_t directDest = 0;     // 演算が StoreCell の升へじかに書く（設計 §8.1 の 9）
    size_t fused = 0;          // 演算 + フィルタ、megabuf + 読み書きを 1 つに
    size_t coalesced = 0;      // phi と引数を同じ升にした（写しが消えた）
    size_t copies = 0;         // phi の写し（Mov）
    // 段 S3（ETVM_PASS_*）
    size_t loopFused = 0;      // loop の入口・次の周を 1 つに（LoopInitJ・DecJ）
    size_t whileFused = 0;     // while の次を 1 つに（WhileJ）
    size_t cmpBr = 0;          // 比べ + 分かれ道
    size_t constBr = 0;        // 条件が定数の分かれ道（跳ぶだけ）
    size_t opImm = 0;          // 定数のオペランドを命令の中に
    size_t opTo = 0;           // 行き先 = 左のオペランド
    size_t memBI = 0;          // megabuf の 頭 + 添字
    size_t fuse2 = 0;          // 続いた四則 2 つ
    size_t loopKernel = 0;     // loop を回し切るハンドラ（lkern）
    size_t multiDirect = 0;    // じかに書いた升を、あとの使う所も読む（fwd・cse で増えた使う所）
};

/// だめなら nullptr と理由（中間表現に知らない命令がある、など）。fn は verify を通ったもの。
/// passes は ETVM_PASS_*（並べる段だけを見る。中間表現の段は ETVMOpt.h の optimize が先にする）。
ThreadedProgram *buildThreaded(const Function &fn, std::string &why, ThreadedStats *stats = nullptr,
                               uint32_t passes = 0xffffffffu);
using ThreadedFrameCallback = void (*)(void *ctx, unsigned int frame);
/// pre(ctx, i) → プログラム → post(ctx, i) を i = 0..nframes-1（NSEEL_code_execute_frames と同じ約束）。
void runThreaded(const ThreadedProgram *p, unsigned int nframes, ThreadedFrameCallback pre, ThreadedFrameCallback post,
                 void *ctx);
void freeThreaded(ThreadedProgram *p);
const ThreadedStats &threadedStats(const ThreadedProgram *p);
/// 並べたハンドラの表示（升は namer の名前・枠の番号・定数で）。
std::string disassembleThreaded(const ThreadedProgram *p, CellNamer namer = nullptr, void *user = nullptr);

} // namespace etvm
