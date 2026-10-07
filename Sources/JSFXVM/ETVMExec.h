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
};

/// だめなら nullptr と理由（中間表現に知らない命令がある、など）。fn は verify を通ったもの。
ThreadedProgram *buildThreaded(const Function &fn, std::string &why, ThreadedStats *stats = nullptr);
using ThreadedFrameCallback = void (*)(void *ctx, unsigned int frame);
/// pre(ctx, i) → プログラム → post(ctx, i) を i = 0..nframes-1（NSEEL_code_execute_frames と同じ約束）。
void runThreaded(const ThreadedProgram *p, unsigned int nframes, ThreadedFrameCallback pre, ThreadedFrameCallback post,
                 void *ctx);
void freeThreaded(ThreadedProgram *p);
const ThreadedStats &threadedStats(const ThreadedProgram *p);
/// 並べたハンドラの表示（升は namer の名前・枠の番号・定数で）。
std::string disassembleThreaded(const ThreadedProgram *p, CellNamer namer = nullptr, void *user = nullptr);

} // namespace etvm
