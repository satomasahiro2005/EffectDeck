// ETVMBytecode.h — WDL の portable のバイトコード（glue_port.h の EEL_BC_*）の写しと読み方。
//
// 番号は glue_port.h の enum と同じでなければならない。ETVMGlueCheck.c が glue_port.h を読んで
// 1 つずつ _Static_assert で確かめる（ずれたら建たない）。
// 命令は int（4 バイト）、続く即値は 8 バイト（ポインタ）か 4 バイト（跳び先・量）で、4 バイト境界に並ぶ
// （8 バイト境界とは限らないので memcpy で読む）。
#pragma once

#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    ETBC_NOP = 1,
    ETBC_RET,
    ETBC_JMP_NC,
    ETBC_JMP_IF_P1_Z,
    ETBC_JMP_IF_P1_NZ,

    ETBC_MOV_FPTOP_DV,
    ETBC_MOV_P1_DV,
    ETBC_MOV_P2_DV,
    ETBC_MOV_P3_DV,
    ETBC__RESET_WTP,

    ETBC_PUSH_P1,
    ETBC_PUSH_P1PTR_AS_VALUE,
    ETBC_POP_P1,
    ETBC_POP_P2,
    ETBC_POP_P3,
    ETBC_POP_VALUE_TO_ADDR,

    ETBC_MOVE_STACK,
    ETBC_STORE_P1_TO_STACK_AT_OFFS,
    ETBC_MOVE_STACKPTR_TO_P1,
    ETBC_MOVE_STACKPTR_TO_P2,
    ETBC_MOVE_STACKPTR_TO_P3,

    ETBC_SET_P2_FROM_P1,
    ETBC_SET_P3_FROM_P1,
    ETBC_COPY_VALUE_AT_P1_TO_ADDR,
    ETBC_SET_P1_FROM_WTP,
    ETBC_SET_P2_FROM_WTP,
    ETBC_SET_P3_FROM_WTP,

    ETBC_POP_FPSTACK_TO_PTR,
    ETBC_POP_FPSTACK_TOSTACK,

    ETBC_PUSH_VAL_AT_P1_TO_FPSTACK,
    ETBC_PUSH_VAL_AT_P2_TO_FPSTACK,
    ETBC_PUSH_VAL_AT_P3_TO_FPSTACK,
    ETBC_POP_FPSTACK_TO_WTP,
    ETBC_SET_P1_Z,
    ETBC_SET_P1_NZ,

    ETBC_LOOP_LOADCNT,
    ETBC_LOOP_END,

    ETBC_WHILE_SETUP, // NSEEL_LOOPFUNC_SUPPORT_MAXLEN > 0（ysfx はそう建てる。ETVMGlueCheck.c が確かめる）

    ETBC_WHILE_BEGIN,
    ETBC_WHILE_END,
    ETBC_WHILE_CHECK_RV,

    ETBC_BNOT,
    ETBC_EQUAL,
    ETBC_EQUAL_EXACT,
    ETBC_NOTEQUAL,
    ETBC_NOTEQUAL_EXACT,
    ETBC_ABOVE,
    ETBC_BELOWEQ,

    ETBC_ADD,
    ETBC_SUB,
    ETBC_MUL,
    ETBC_DIV,
    ETBC_AND,
    ETBC_OR,
    ETBC_OR0,
    ETBC_XOR,

    ETBC_ADD_OP,
    ETBC_SUB_OP,
    ETBC_ADD_OP_FAST,
    ETBC_SUB_OP_FAST,
    ETBC_MUL_OP,
    ETBC_DIV_OP,
    ETBC_MUL_OP_FAST,
    ETBC_DIV_OP_FAST,
    ETBC_AND_OP,
    ETBC_OR_OP,
    ETBC_XOR_OP,

    ETBC_UMINUS,

    ETBC_ASSIGN,
    ETBC_ASSIGN_FAST,
    ETBC_ASSIGN_FAST_FROMFP,
    ETBC_ASSIGN_FROMFP,
    ETBC_MOD,
    ETBC_MOD_OP,
    ETBC_SHR,
    ETBC_SHL,

    ETBC_SQR,
    ETBC_MIN,
    ETBC_MAX,
    ETBC_MIN_FP,
    ETBC_MAX_FP,
    ETBC_ABS,
    ETBC_SIGN,
    ETBC_INVSQRT,

    ETBC_FXCH,
    ETBC_POP_FPSTACK,

    ETBC_FCALL,
    ETBC_BOOLTOFP,
    ETBC_FPTOBOOL,
    ETBC_FPTOBOOL_REV,

    ETBC_CFUNC_1PDD,
    ETBC_CFUNC_2PDD,
    ETBC_CFUNC_2PDDS,

    ETBC_MEGABUF,
    ETBC_GMEGABUF,

    ETBC_GENERIC1PARM,
    ETBC_GENERIC2PARM,
    ETBC_GENERIC3PARM,
    ETBC_GENERIC1PARM_RETD,
    ETBC_GENERIC2PARM_RETD,
    ETBC_GENERIC2XPARM_RETD,
    ETBC_GENERIC3PARM_RETD,

    ETBC_USERSTACK_PUSH,
    ETBC_USERSTACK_POP,
    ETBC_USERSTACK_POPFAST,
    ETBC_USERSTACK_PEEK,
    ETBC_USERSTACK_PEEK_INT,
    ETBC_USERSTACK_PEEK_TOP,
    ETBC_USERSTACK_EXCH,

    ETBC_DBG_GETSTACKPTR,

    ETBC_COUNT
};

/// 命令の後ろの即値のバイト数（GLUE_CALL_CODE が iptr を進める量）。知らない番号は -1。
static inline int etbc_imm_bytes(int op)
{
    switch (op) {
    case ETBC_JMP_NC: case ETBC_JMP_IF_P1_Z: case ETBC_JMP_IF_P1_NZ:
    case ETBC_LOOP_LOADCNT: case ETBC_LOOP_END: case ETBC_WHILE_END: case ETBC_WHILE_CHECK_RV:
    case ETBC_MOVE_STACK: case ETBC_STORE_P1_TO_STACK_AT_OFFS:
        return 4;
    case ETBC_MOV_FPTOP_DV: case ETBC_MOV_P1_DV: case ETBC_MOV_P2_DV: case ETBC_MOV_P3_DV:
    case ETBC__RESET_WTP: case ETBC_POP_VALUE_TO_ADDR: case ETBC_COPY_VALUE_AT_P1_TO_ADDR:
    case ETBC_POP_FPSTACK_TO_PTR: case ETBC_FCALL:
    case ETBC_CFUNC_1PDD: case ETBC_CFUNC_2PDD: case ETBC_CFUNC_2PDDS:
    case ETBC_USERSTACK_PEEK_TOP: case ETBC_USERSTACK_EXCH:
        return 8;
    case ETBC_GMEGABUF:
    case ETBC_GENERIC1PARM: case ETBC_GENERIC2PARM: case ETBC_GENERIC3PARM:
    case ETBC_GENERIC1PARM_RETD: case ETBC_GENERIC2PARM_RETD: case ETBC_GENERIC3PARM_RETD:
        return 16;
    case ETBC_GENERIC2XPARM_RETD:
    case ETBC_USERSTACK_PUSH: case ETBC_USERSTACK_POP: case ETBC_USERSTACK_POPFAST: case ETBC_USERSTACK_PEEK:
        return 24;
    case ETBC_USERSTACK_PEEK_INT:
        return 32;
    default:
        return (op >= ETBC_NOP && op < ETBC_COUNT) ? 0 : -1;
    }
}

static inline int32_t etbc_read_i32(const unsigned char *p) { int32_t v; memcpy(&v, p, 4); return v; }
static inline uint64_t etbc_read_u64(const unsigned char *p) { uint64_t v; memcpy(&v, p, 8); return v; }

const char *etbc_name(int op);

#ifdef __cplusplus
}
#endif
