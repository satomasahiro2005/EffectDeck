//  et_test.h
//  Tests/Native の小さな試験の枠。依存は C の標準だけ（MSVC でも建つ）。
//
//  書き方:
//    ET_CASE(dc_roundtrip) { ... ET_CHECK(x == 1); ... }
//    static const et_case cases[] = { ET_ENTRY(dc_roundtrip), ... };
//    int main(int argc, char **argv) { return et_run(argc, argv, cases, ET_COUNT(cases)); }
//
//  CMakeLists.txt がソースの表の `ET_ENTRY(名前)` を拾って 1 件ずつ ctest に登録する
//  （ctest からは `実行ファイル 名前` で 1 件だけ走る。静的な状態は 1 件ごとに新しい）。
//  名前が cb_ で始まるものは外部コールバックのある版だけ、legacy_ で始まるものは
//  無い版だけに登録する（pipeline_cb / pipeline_legacy）。表に無い名前を渡すと失敗する。
//  引数なしで走らせると表の全件を 1 つのプロセスで順に回す。

#ifndef ET_TEST_H
#define ET_TEST_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*et_case_fn)(void);
typedef struct {
    const char *name;
    et_case_fn fn;
} et_case;

#define ET_CASE(name) static void name(void)
#define ET_ENTRY(name) { #name, name }
#define ET_COUNT(a) (sizeof(a) / sizeof((a)[0]))

#define ET_CHECK(cond)                                                          \
    do {                                                                        \
        if (!(cond)) {                                                          \
            fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #cond);      \
            fflush(stderr);                                                     \
            exit(1);                                                            \
        }                                                                       \
    } while (0)

/// 失敗したときに値も出す。測った数字を見ないと何がずれたか分からないので。
#define ET_CHECK_MSG(cond, ...)                                                 \
    do {                                                                        \
        if (!(cond)) {                                                          \
            fprintf(stderr, "FAIL %s:%d %s: ", __FILE__, __LINE__, #cond);      \
            fprintf(stderr, __VA_ARGS__);                                       \
            fprintf(stderr, "\n");                                              \
            fflush(stderr);                                                     \
            exit(1);                                                            \
        }                                                                       \
    } while (0)

static int et_run(int argc, char **argv, const et_case *cases, size_t count)
{
    // LSan は終わりぎわに落とすので、行を溜めていると ok の行が消える。
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc > 1 && strcmp(argv[1], "--list") == 0) {
        for (size_t i = 0; i < count; i++) printf("%s\n", cases[i].name);
        return 0;
    }
    if (argc > 1) {
        for (int a = 1; a < argc; a++) {
            size_t i = 0;
            while (i < count && strcmp(cases[i].name, argv[a]) != 0) i++;
            if (i == count) {
                fprintf(stderr, "FAIL unknown case %s\n", argv[a]);
                return 1;
            }
            cases[i].fn();
            printf("ok %s\n", cases[i].name);
        }
        return 0;
    }
    for (size_t i = 0; i < count; i++) {
        cases[i].fn();
        printf("ok %s\n", cases[i].name);
    }
    return 0;
}

#endif /* ET_TEST_H */
