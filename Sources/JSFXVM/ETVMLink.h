// ETVMLink.h — VM 全体のつなぎ（docs/jsfx-regvm-design.md §5.3）と、照合・数えるための口。
//
// 1 つの effect の全部の handle（@gfx・@serialize も）を持ち上げ、バイトコードに出てくる番地（升）を
//   Var（登録した変数）・Temp（handle の作業表）・Static（どれかの handle の data の塊・VM の塊）・
//   Volatile（それ以外: _global.*・nseel_ramalloc_onfail など）
// に分ける。Static のうち、どの handle も直に書かず・ポインタ越しに書きうる先に入らず・API へ渡さない
// （外へ漏れない）ものを Const とする。持ち上げられない handle が 1 つでもあれば Const は無し。
#pragma once

#include "ETVMIR.h"
#include "ETVMLift.h"
#include "ETVMOpt.h"

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace etvm {

enum class CellClass : uint8_t { Var, Const, Static, Temp, Volatile };
const char *cellClassName(CellClass c);

struct CellInfo {
    CellClass cls = CellClass::Volatile;
    bool loaded = false, storedDirect = false, storedIndirect = false, escaped = false;
    bool loadedIndirect = false; // ポインタ越しに読まれうる（Load・min/max の参照・ユーザーの積み場の push）
    std::string name;     // Var の名前
};

struct HandleReport {
    int section = 0;      // ysfx_section_type_t（1 = @init … 6 = @serialize）
    int index = 0;        // @init は import ごとに 0, 1, …
    bool present = false; // handle が在って中身が在る
    LiftResult lift;
};

struct LinkReport {
    std::vector<HandleReport> handles;
    std::map<uint64_t, CellInfo> cells;
    std::vector<uint64_t> cellOrder;  // 初めて出てきた順（handle の順・命令の順。番地に依らない）
    bool allAnalysed = true;
    size_t unknownStores = 0;         // 出所の分からないポインタ越しの書き込み
};

/// vm は NSEEL_VMCTX、handles[i] は NSEEL_CODEHANDLE（NULL 可）、sections[i] は ysfx_section_type_t。
LinkReport link(void *vm, void *const *handles, const int *sections, uint32_t count,
                const LiftOptions &opt = LiftOptions());

/// 表示用の升の名前（変数名・const(値)・tmp+n・static・volatile）。
std::string describeCell(const LinkReport &rep, uint64_t addr);

/// ysfx の口から見えない VM の状態の指紋: 持ち上げた全部の handle に出てくる Static 升（定数・関数の
/// 局所・#字）の値（初めて出てきた順）と、各 handle のユーザーの積み場の位置。portable どうしでも
/// 一致する（作業表とユーザーの積み場の中身は書く前の値が不定なので入れない）。
uint64_t stateHash(void *vm, void *const *handles, const int *sections, uint32_t count);

/// ETVM_Install した実行系が作ったプログラムの数え（節ごと。1..6）。
struct Coverage {
    uint64_t handles[8] = {};
    uint64_t lifted[8] = {};
    uint64_t attached[8] = {};
    uint64_t reasons[8][(size_t)Fallback::Count] = {};
    uint64_t buildFailed[8] = {};      // threaded code を並べられなかった（vm-goto-fpreg で回る）
    uint64_t irInstructions[8] = {};   // threaded にした handle の中間表現の命令
    uint64_t threadedHandlers[8] = {}; // 並べたハンドラ
    OptStats opt[8];                   // 段 S3 の中間表現の最適化
    std::string firstBuildError;
};
Coverage coverage();
void resetCoverage();

} // namespace etvm
