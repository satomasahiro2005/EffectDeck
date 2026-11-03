//  et_check.h
//  Tests/Native/link と driver の検査の書き方。
//
//  枠（ET_CASE・ET_ENTRY・et_run）は Tests/Native/et_test.h をそのまま使う。
//  ctest への登録も親の CMakeLists.txt の et_native_test がやる。
//  ここで足すのは、外れたときに両辺の値を出す CHECK_EQ・CHECK_FEQ と、決まった列の乱数だけ。
//  外れたら et_test.h の ET_CHECK と同じく、その場で FAIL を出して止まる。

#ifndef ET_CHECK_H
#define ET_CHECK_H

#include "et_test.h"

#define CHECK(cond) ET_CHECK(cond)

#define CHECK_EQ(a, b)                                                              \
    do {                                                                            \
        unsigned long long et_a_ = (unsigned long long)(a);                         \
        unsigned long long et_b_ = (unsigned long long)(b);                         \
        if (et_a_ != et_b_) {                                                       \
            fprintf(stderr, "FAIL %s:%d CHECK_EQ(%s, %s): %llu != %llu\n",          \
                    __FILE__, __LINE__, #a, #b, et_a_, et_b_);                      \
            fflush(stderr);                                                         \
            exit(1);                                                                \
        }                                                                           \
    } while (0)

#define CHECK_FEQ(a, b)                                                             \
    do {                                                                            \
        double et_a_ = (double)(a);                                                 \
        double et_b_ = (double)(b);                                                 \
        if (!(et_a_ == et_b_)) {                                                    \
            fprintf(stderr, "FAIL %s:%d CHECK_FEQ(%s, %s): %.17g != %.17g\n",       \
                    __FILE__, __LINE__, #a, #b, et_a_, et_b_);                      \
            fflush(stderr);                                                         \
            exit(1);                                                                \
        }                                                                           \
    } while (0)

/// 決まった列を出す乱数（線形合同）。検査が毎回同じ入力で走るように。
static unsigned et_lcg_state = 12345u;
static inline unsigned et_lcg(void) {
    et_lcg_state = et_lcg_state * 1103515245u + 12345u;
    return (et_lcg_state >> 16) & 0x7fffu;
}

#endif /* ET_CHECK_H */
