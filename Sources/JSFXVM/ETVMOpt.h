// ETVMOpt.h — 中間表現の上の最適化（段 S3。docs/jsfx-regvm-design.md §8.1 の 2〜8、§17）。
//
// どれも portable と 1 ビットも違わない範囲だけ: 升の読み書きの順・番地は変えず、同じ値と分かるものだけを
// 置き換える。升の性質（Const・Volatile・外へ漏れない作業表）はつなぎ（ETVMLink.cpp）が VM 全体を見て決める。
// 1 つずつ ETVM_PASS_* で切れる（ETVM.h）。
#pragma once

#include "ETVMIR.h"

#include <cstdint>
#include <string>
#include <unordered_map>

namespace etvm {

struct LinkReport;

/// 升ごとの性質（無い升は Volatile 扱い: 読み直しも置き換えもしない）。
struct CellFacts {
    enum : uint8_t {
        Cacheable = 1,   // Var・Static・Const・Temp（Volatile でない）: ブロックの中で読み直しを省ける
        Const = 2,       // どの handle も書かず外へ漏れない（いまの値を建てるときに読んでよい）
        PrivateTemp = 4, // 作業表の升で、番地が外へ漏れず、ポインタ越しにも読み書きされない
    };
    std::unordered_map<uint64_t, uint8_t> cells;
    uint8_t of(uint64_t a) const
    {
        auto it = cells.find(a);
        return it == cells.end() ? 0 : it->second;
    }
};
CellFacts cellFacts(const LinkReport &rep);

struct OptStats {
    size_t constCells = 0;  // LoadCell(Const) を定数に
    size_t folded = 0;      // 定数だけの演算を畳んだ
    size_t cseLoads = 0;    // 同じ升の読み直しを省いた
    size_t csePure = 0;     // 同じ演算を 1 つに
    size_t forwarded = 0;   // 書いた値をそのまま使った（読み直さない）
    size_t deadStores = 0;  // 読まれない作業表の書き込みを消した
    size_t verifyFailed = 0; // 最適化した形が verifier を通らず、元に戻した（起きてはいけない）
    OptStats &operator+=(const OptStats &o)
    {
        constCells += o.constCells; folded += o.folded; cseLoads += o.cseLoads; csePure += o.csePure;
        forwarded += o.forwarded; deadStores += o.deadStores; verifyFailed += o.verifyFailed;
        return *this;
    }
};

/// passes は ETVM_PASS_*（中間表現の段だけを見る）。verifier を通らなければ fn を元に戻して false。
bool optimize(Function &fn, uint32_t passes, const CellFacts &facts, OptStats *stats = nullptr,
              std::string *why = nullptr);

/// いまの ETVM_PASS_*（ETVM_SetPasses・環境変数 ETVM_PASSES）。
uint32_t currentPasses();

} // namespace etvm
