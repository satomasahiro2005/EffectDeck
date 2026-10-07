// ETVMIR.h — JSFX のレジスタ型 VM の中間表現（SSA）。docs/jsfx-regvm-design.md §7。
//
// - 値は f64・ptr（EEL_F の番地）・bool（portable の p1 が NULL か）・i32（loop の数）。
// - 変数・定数・関数の局所・作業表の一時はどれも「番地の決まった升（cell）」のまま。読み書きは
//   LoadCell / StoreCell として、バイトコードと同じ順に並ぶ。SSA になるのは浮動小数の積み場と p1〜p3 だけ。
// - 定数（PtrConst・BoolConst・I32Const）は Function::consts に置き、入口で 1 回だけ作る（全部を支配する）。
// - 各ブロックは phi の列 → 命令の列 → 終わり（Br・CondBr・Ret）。
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace etvm {

enum class Ty : uint8_t { Void, F64, Ptr, Bool, I32 };

enum class Op : uint8_t {
    // 定数（Function::consts だけ）
    PtrConst,  // imm[0] = 番地（そのまま。varparm の数も来る）
    BoolConst, // imm[0] = 0 / 1
    I32Const,  // imm[0]
    // 升・番地
    LoadCell,  // imm[0] = 升 -> f64
    StoreCell, // imm[0] = 升, a0 = f64
    Load,      // a0 = ptr -> f64
    Store,     // a0 = ptr, a1 = f64
    // f64
    FAdd, FSub, FMul, FDiv, // a0 op a1（a0 は先に積んだ方）
    FNeg, FAbs, FSqr, FSign, InvSqrt,
    FMin2, FMax2, // MIN_FP / MAX_FP: a0 = 残る方（top2）, a1 = 降ろす方
    Filter,       // denormal_filter_double2
    IAnd, IOr, IXor, // (EEL_F)(((int64)a0) op (int64)a1)
    IOr0,
    IMod, // a0 = 割られる数, a1 = 割る数
    IShl, IShr, // a0 = 値, a1 = 量
    CallF1, // imm[0] = double (*)(double), a0
    CallF2, // imm[0] = double (*)(double,double), a0, a1
    // bool
    CmpEqClose, CmpNeClose, CmpEq, CmpNe, // a0 = top, a1 = top2
    CmpLt, // ABOVE: a0 < a1（a0 = top, a1 = top2）
    CmpGe, // BELOWEQ: a0 >= a1
    Truthy, Falsy,
    BNot, BoolToF, PtrNonNull, BoolToPtr,
    // ptr
    PtrMin, PtrMax, // a0 = p1, a1 = p2: (*p1 > *p2) ? p2 : p1（MAX は <）
    MemAddr,  // imm[0] = ram の塊の表, a0 = f64 -> ptr（足りなければ確保する）
    GMemAddr, // imm[0] = gram の表を指す場所, a0 = f64 -> ptr
    // API
    CallG,        // imm[0] = fn, imm[1] = opaque, args = ptr（1〜3、C の引数の順） -> ptr
    CallGD,       // 同じ -> f64
    CallGXD,      // imm[0] = fn, imm[1] = ctx1, imm[2] = ctx2, args = ptr（2） -> f64
    CallVarparm,  // imm[0] = fn, imm[1] = opaque, imm[2] = 数, args = ptr[数] -> f64
    CallVarparmX, // imm[0] = fn, imm[1] = ctx1, imm[2] = ctx2, imm[3] = 数, args = ptr[数] -> f64
    // ユーザーの積み場（imm[0] = 頭を持つ場所, 以下 glue_port.h の即値の順）
    UStackPush,    // imm = sptr, mask, or; a0 = ptr（値を読む）
    UStackPop,     // imm = sptr, mask, or; a0 = ptr（書く）
    UStackPopFast, // imm = sptr, mask, or -> ptr
    UStackPeek,    // imm = sptr, mask, or; a0 = f64 -> ptr
    UStackPeekInt, // imm = sptr, sub, mask, or -> ptr
    UStackPeekTop, // imm = sptr -> ptr
    UStackExch,    // imm = sptr; a0 = ptr
    // loop の数
    LoopCount, // a0 = f64 -> i32
    ILt1,      // a0 = i32 -> bool（< 1）
    IDec,      // a0 = i32 -> i32（- 1）
    IGt0,      // a0 = i32 -> bool（> 0）
    Phi,       // args[k] は preds[k] から
    Count
};

enum class Term : uint8_t { None, Br, CondBr, Ret };

constexpr uint32_t kNoValue = 0xffffffffu;

struct Ins {
    Op op = Op::Count;
    Ty ty = Ty::Void;
    uint32_t res = kNoValue;          // 作る値（Void は kNoValue）
    std::vector<uint32_t> args;
    uint64_t imm[4] = {0, 0, 0, 0};
    uint32_t pc = 0;                  // もとの命令の位置（コードの先頭からのバイト。関数の中なら 0x80000000 + 関数の頭から）
};

struct Block {
    std::vector<Ins> phis;
    std::vector<Ins> ins;
    Term term = Term::None;
    uint32_t cond = kNoValue;         // CondBr: 真なら succ[0]
    uint32_t succ[2] = {kNoValue, kNoValue};
    uint32_t succPredIdx[2] = {0, 0}; // 行き先の preds の中で自分が何番目か（phi の引数の番号）
    std::vector<uint32_t> preds;
    uint64_t pc = 0;                  // 頭の命令の番地（表示だけ）
};

struct ValueInfo {
    Ty ty = Ty::Void;
    int32_t block = -1;               // -1 は consts
    uint32_t index = 0;               // block の中の位置（phi は phis、ほかは ins）
    bool phi = false;
};

struct Function {
    std::vector<Ins> consts;
    std::vector<Block> blocks;        // blocks[0] が入口
    std::vector<ValueInfo> values;
    uint64_t codeBase = 0;            // 表示のため

    uint32_t newValue(Ty ty) { values.push_back(ValueInfo{ty}); return (uint32_t)values.size() - 1; }
    /// 値が PtrConst なら番地を返す。
    bool constAddr(uint32_t v, uint64_t &addr) const;
    size_t instructionCount() const;
    /// succPredIdx と values[].block/index を作り直す（phi・命令を動かしたあと）。
    void finalize();
};

const char *opName(Op op);
const char *tyName(Ty ty);
/// 命令の型の約束（引数の数と型・返す型）。可変長（Phi・Call*）は -1。
struct OpSig { int nargs; Ty arg; Ty ret; int nimm; };
OpSig opSig(Op op);
bool opHasMemoryEffect(Op op);

/// 形と SSA を確かめる。だめなら false と理由。
bool verify(const Function &fn, std::string &why);

/// 番地に名前を付ける口（表示だけ）。空を返せば番地のまま。
using CellNamer = std::string (*)(uint64_t addr, void *user);
std::string print(const Function &fn, CellNamer namer = nullptr, void *user = nullptr);

/// 参照の解釈（遅い。照合のためだけ）。Function を 1 回回す。値の置き場は state（中で大きさを合わせる）。
struct InterpState { std::vector<uint64_t> vals; std::vector<void *> scratch; };
void interpret(const Function &fn, InterpState &state);

} // namespace etvm
