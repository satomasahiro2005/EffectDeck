// jsfx_source_gate.cpp（Tests/Fuzz/Native）
// 的 jsfxgate: JSFX をコンパイルする前にソースの字を見る門（ETJSFX_Create が最初に通す 3 つ）。
//   forbiddenSource      import / filename: / data: / include( を断る
//   sourceWithinBudgets  括弧の深さ・文字列の長さ・<? ?> の数の上限
//   sourceUsesTrigger    本文に trigger が出るか
//
// **3 つとも ETJSFXHost.cpp の無名の名前空間にあるので、実装を丸ごとこの翻訳単位へ読み込む。**
// ETJSFXHost.cpp には手を入れない。ysfx の関数は宣言だけ見えればよく、門は呼ばないので、
// リンクは未定義の参照を無視させる（Tests/Fuzz/run.sh の -Wl,--unresolved-symbols=ignore-all）。
// 門のどれかが ysfx を呼ぶようになったら、ここは実行時に落ちて知らせる。
//
// 約束:
//   - 断ったときは理由が付き、理由の行番号はソースの行数を超えない
//   - 通したときは理由を書かない
//   - ASan / UBSan が何も言わない

#include "ETJSFXHost.cpp"

// **変数は無視させられない。**関数は呼ばれるまで解決されない（遅延束縛）が、変数の参照は
// 起動時に解決されるので、無いと "undefined symbol: NSEEL_RAM_limitmem" で 1 回も回らない
// （ETJSFXHost.cpp の初期化が書く。門は読まない）。ysfx の変数を増やしたらここにも足す。
// ns-eel.h の宣言（extern "C" の中）と同じ型で定義だけ置く。
unsigned int NSEEL_RAM_limitmem = 0;

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

namespace {
[[noreturn]] void broken(const char *what, const std::string &reason)
{
    std::fprintf(stderr, "fuzz oracle: %s (%s)\n", what, reason.c_str());
    std::abort();
}

size_t lineCount(const std::string &source)
{
    size_t lines = 1;
    for (char c : source) lines += c == '\n';
    return lines;
}

/// "… at line 12." の 12。無ければ 0。
size_t reportedLine(const std::string &reason)
{
    const std::string marker = "at line ";
    const size_t at = reason.rfind(marker);
    if (at == std::string::npos) return 0;
    return std::strtoull(reason.c_str() + at + marker.size(), nullptr, 10);
}
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    const std::string source(reinterpret_cast<const char *>(data), size);

    std::string reason;
    if (forbiddenSource(source, reason)) {
        if (reason.empty()) broken("forbiddenSource が理由なしで断った", reason);
        const size_t line = reportedLine(reason);
        if (line == 0 || line > lineCount(source)) broken("forbiddenSource の行番号がソースの外", reason);
    } else if (!reason.empty()) {
        broken("forbiddenSource が通したのに理由を書いた", reason);
    }

    reason.clear();
    if (!sourceWithinBudgets(source, reason)) {
        if (reason.empty()) broken("sourceWithinBudgets が理由なしで断った", reason);
    } else if (!reason.empty()) {
        broken("sourceWithinBudgets が通したのに理由を書いた", reason);
    }

    (void)sourceUsesTrigger(source);
    return 0;
}
