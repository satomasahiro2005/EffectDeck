// ETVMLift.h — 出来上がった code handle の portable のバイトコードを SSA の中間表現へ持ち上げる。
// docs/jsfx-regvm-design.md §6。分からない形は推し量らず、理由（Fallback）を付けて断る。
#pragma once

#include "ETVMIR.h"

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace etvm {

enum class Fallback : uint8_t {
    None,
    NoCode,          // handle が無い・中身が空
    UnknownOpcode,   // 表に無い番号（portable は黙って飛ばす）
    Opcode0,         // GLUE_POP_STACK_TO_FPSTACK の置き場（portable では何もしない＝積み場が崩れる）
    DbgGetStackPtr,  // __dbg_getstackptr()（解釈の積み場の深さ）
    JumpOutside,     // 跳び先・関数がこの handle のコードの外
    CallDepth,       // FCALL の入れ子が深すぎる（再帰）
    NodeBudget,      // 展開した命令が多すぎる
    IRBudget,        // 中間表現が多すぎる
    FpUnderflow,     // 浮動小数の積み場が空なのに降ろす
    FpOverflow,      // 64 段を超える（portable は表の外へ書く）
    StackUnderflow,  // 解釈の積み場が空なのに降ろす
    StackOverflow,   // 64 KiB を超える（portable は溢れる）
    ShapeMismatch,   // 合流で積み場の形が違う
    WtpMismatch,     // 合流で作業表の位置が違う・保存した位置と違う
    Undefined,       // 書いていない積み場の段を読む
    TypeConfusion,   // 値をポインタとして・ポインタを値として使う、など
    NullDeref,       // 番地 0 を読み書きする
    BoolDeref,       // 比べた結果（portable の p1 = 1 / NULL）を番地として読み書きする
    StackAddrMisuse, // 積み場の番地（MOVE_STACKPTR_TO_Px）を varparm の呼び出しの外で使う
    VarparmShape,    // varparm の引数の並びが読めない
    RetMismatch,     // RET が戻る先と積み場の戻り先が違う、頭の RET で積み場が空でない
    VerifyFailed,    // 持ち上げた中間表現が verifier を通らない（持ち上げの不具合）
    Count
};
const char *fallbackName(Fallback f);

struct LiftInput {
    const unsigned char *code = nullptr; // 入口
    uint64_t workTable = 0;              // 作業表の頭（GLUE_CALL_CODE の bp）
    uint64_t ramPtr = 0;                 // megabuf の塊の表（rt）
    std::vector<std::pair<uint64_t, uint64_t>> codeRanges; // 読んでよい [頭, 終わり)
};
/// NSEEL_CODEHANDLE から（ns-eel-int.h の codeHandleType を読む）。中身が無ければ false。
bool liftInputFromHandle(void *handle, LiftInput &in);

struct LiftOptions {
    size_t maxNodes = 1u << 20;   // 展開した命令（FCALL は呼ぶ所ごとに展開する）
    size_t maxIns = 1u << 18;     // 中間表現の命令
    int maxCallDepth = 32;
};

struct LiftResult {
    Fallback reason = Fallback::None;
    std::string detail;
    uint64_t pc = 0;        // 断った命令（code からのバイト。外なら番地）
    Function fn;
    size_t nodes = 0;       // 展開した命令の数
    size_t bytecodeBytes = 0;
    bool ok() const { return reason == Fallback::None; }
};

LiftResult lift(const LiftInput &in, const LiftOptions &opt = LiftOptions());

} // namespace etvm
