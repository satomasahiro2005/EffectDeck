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

/// portable（GLUE_CALL_CODE）の + * が機械の命令のどちらのオペランドを 1 つめにしたか。2 つとも NaN のときに
/// 残るペイロードがこれで決まる（ETVMOps.h の etvm_fadd の注、設計 §15.2 の 9）。パッチの glue_port.h は式の左
/// （top2・升の値）に決めているが、パッチの無い建て方では C のコンパイラが決めるので、建てたものごとに 1 度、
/// portable で NaN を 2 つ足して・掛けて調べる（どのスレッドからでもよい）。持ち上げは中間表現の FAdd・FMul の
/// 左を portable の 1 つめにする。
struct PortableNaNOrder {
    bool addTopFirst = false;     // EEL_BC_ADD: top（後から積んだ方）が 1 つめ
    bool mulTopFirst = false;     // EEL_BC_MUL
    bool addOpValueFirst = false; // EEL_BC_ADD_OP_FAST: 降ろした値が 1 つめ（升の値が 2 つめ）
    bool mulOpValueFirst = false; // EEL_BC_MUL_OP_FAST
    bool probed = false;          // 調べた（portable の建て方だけ。JIT の建て方では portable が無い）
    std::string note;             // どちらの NaN でもなかった命令（既定の NaN を返す機械なら順は効かない）
};
const PortableNaNOrder &portableNaNOrder();

} // namespace etvm
