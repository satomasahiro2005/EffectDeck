# EffectDeck JSFX register VM (stage 2/3) — design

Status: **S0 (hook surface only), S1 and S2 implemented** (2026-10-07; §15 = S0/S1, §16 = S2: what exists, the
deviations from this design and their reasons, oracle/fuzz results and measured numbers). S3+ not started. The design
text below is the original one; where S0–S2 deviate, §15.2 / §16.2 say so.
Written against worktree `EffectDeck.jsfx-vm`, branch `perf/jsfx-vm`
(HEAD 0915106 + the uncommitted stage-1 work: `NSEEL_code_execute_frames`, `NSEEL_EXEC_*`, `glue_port_vm.h`,
`ysfx_set_eel_exec_mode`, `ETJSFX_SetEELExecutor`, `Tools/jsfx-bench/diff.cpp`).
Line numbers refer to `Vendor/ysfx/thirdparty/WDL/source/WDL/eel2/*` with `Patches/ysfx-effectdeck-ios.diff` applied.

---

## 0. Summary of decisions

| Question | Decision |
|---|---|
| Where to hook | **Translate the portable bytecode of each finished code handle** (post-`NSEEL_code_compile_ex`), not the opcodeRec trees. WDL's frontend *and* its code generator stay authoritative; the backend is a lifter + optimiser + emitter that runs after `ysfx_compile`. |
| IR | SSA over basic blocks. Values: f64, ptr (address of an `EEL_F` cell), bool, i32 (loop counters). Memory stays memory: every VM variable, static local, constant slot and worktable temp is a *cell with a fixed absolute address*; loads/stores of cells are explicit IR ops in exactly the order the bytecode performs them. Only fp-stack values / p-registers become SSA values. |
| Execution | Direct-threaded handlers chained with `[[clang::musttail]]`, every operand an absolute `double *` (vars, const pool, frame slots alike) → one handler per *shape*, no operand-kind explosion. Three tiers of superinstructions: generic 3-address ops, generated 2-level arithmetic trees, corpus-mined statement kernels; plus fused compare-branch, loop-end, megabuf base+index access. Whole @sample block in one entry. |
| Fallback | Per code handle. A handle the lifter cannot prove it understands keeps running on WDL portable (or the stage-1 goto interpreter, which is bit-identical). Because all state lives in WDL's own cells, VM and portable handles interoperate freely, and the executor can be switched at any block boundary. |
| Verification | Two-level differential: (1) lifted IR run by a slow reference IR interpreter vs portable, (2) threaded VM vs reference IR interpreter and vs portable. Bench `Check::exact`, fixtures with full state hashes, fuzz-corpus replay on **arm64 and x86-64**, plus a libFuzzer lockstep differential target with global-state snapshot/restore. |
| Gains (estimates, M1 -Os, µs/256-frame block) | filter_drive 43 → ~5–8, biquad 96 → ~9–15, fir 954 → ~60–110, math 104 → ~25–35, slow 357 → ~50–130. Roughly 4–10× portable and 1.5–3× WDL JIT; still ~2–6× slower than the hand-written `cpp` port except where libm dominates. Shipped scripts can additionally get AOT C++ from the same IR (optional step S7) to reach ~cpp speed. |

---

## 1. Goals, non-goals, constraints

Goals
- Replace the stack bytecode *execution* (not the language) with a register form that is optimised at load time, for
  all sections that matter for audio (@sample, @block, @slider, @init).
- Bit-exact with `NSEEL_EXEC_PORTABLE` for every script, every input, including NaN payloads, -0.0, denormals,
  out-of-range conversions, loop caps and stale-register quirks.
- No runtime machine code (iOS): the output is data — handler pointers + operand pointers — over handlers compiled into
  the app.
- Approach the `cpp` bench variant, not only WDL JIT.

Non-goals
- Changing EEL2 semantics, error messages, variable registration, string handling, or anything the frontend does.
- Speeding up @gfx / @serialize (they stay on portable; they are still *analysed*, see §5.3).
- Reproducing portable's crashes / UB (64 KB interpreter stack overflow, garbage-reading opcode 0) — such handles
  fall back.

Constraints
- `Vendor/*` is never committed; any change there goes into `Patches/ysfx-effectdeck-ios.diff` (marker + `.old.diff`
  procedure, §10.4). The backend itself lives in EffectDeck sources (normal commits), so the patch delta is small.
- Release builds: no bench harness; the VM becomes a product feature only after the gates in §12.

---

## 2. What WDL EEL2 does today (study notes)

### 2.1 Pipeline per code handle (`NSEEL_code_compile_ex`, nseel-compiler.c:4548)
1. Split the section into top-level segments at `;` (tokenizer). `//#eel-no-optimize:N` in a segment sets
   `ctx->optimizeDisableFlags` (OPTFLAG_NO_OPTIMIZE 1, NO_FPSTACK 2, NO_INLINEFUNC 4, FULL_DENORMAL_CHECKS 8,
   NO_DENORMAL_CHECKS 16) for that segment.
2. `function name(params) local(..) static(..) instance(..) globals(..) ( body )` segments are parsed into
   `_codeHandleFunctionRec` (opcodes kept, *not* compiled yet). With `NSEEL_CODE_COMPILE_FLAG_COMMONFUNCS` (ysfx uses it
   for every section) they go to `ctx->functions_common`, visible to later sections.
3. Every other segment: parse → opcodeRec tree (`nseel_createSimpleCompiledFunction`, `nseel_createMemoryAccess`
   (`x[y]` ⇒ `FN_MEMORY(FN_ADD(x,y))`, `gmem[y]` ⇒ `FN_GMEMORY`), `nseel_createIfElse`,
   `nseel_setCompiledFunctionCallParameters` (`while(c)(body)` ⇒ `while(c ? (body;1) : 0)`), `nseel_resolve_named_symbol`).
4. `optimizeOpcodes` (1975) unless OPTFLAG_NO_OPTIMIZE.
5. `compileOpcodes` twice (size pass with `bufOut=NULL`, then emit). Code generation also *resolves* things with side
   effects: variables are registered (`nseel_int_register_var`), namespaced function instances are created
   (`eel_createFunctionNamespacedInstance`), constant cells are allocated and cached.
6. Segments are concatenated with `RESET_WTP` before a segment whenever the worktable budget (32) is used up; one final
   `RET`. `handle->code`, `workTable`, `ramPtr = ram_state->blocks`, `blocks_data` (constants, function storage)
   belong to the handle.

### 2.2 `optimizeOpcodes` (1975–2683) — transforms that are already baked into the bytecode
Value-changing (non-IEEE) rewrites WDL performs; the backend must **not** undo or redo them, it simply inherits them:
- statement-level: drop joins whose left side has no effect; drop const pure calls whose result is unused.
- folding of literals: `!`, `!!`, unary minus, `+ - * / % & | ^ << >>` (patched shifts: `&31`, unsigned `<<`),
  `pow`, comparisons (closefactor for `==`/`!=`), `&&`/`||`, `sin cos tan asin acos atan sqrt(|x|) exp log log10`,
  `atan2`, `?:` with literal condition.
- `x+0`, `0+x`, `x-0` → x; `0-x` → `-x`; `x*1`, `x/1` → x; `x*0`, `0*x`, `x&0`, `0/x` → 0 (or `(x;0)` if x has effects);
  `x/c` → `x*(1/c)` only when `1/c` has a zero mantissa (exact); `x/0` → `x*0`; `x|0`, `x^0` → `or0(x)`;
  `x*x` (same var/ptr) → `sqr(x)`; `x^0` → 1; `x^1` → x; `1^x` → 1; `e^x` (|log c − 1| < 1e-9) → `exp(x)`;
  `(a^b)^c` → `a^(b*c)`; `x%0` → 0; `x==0` → `!x`; `x!=0` → `!!x`; `!(a<b)` → `a>=b` etc. (NaN-unsound);
  `!!`/`-` removed under `!`; `!!` removed under `&&`, `||`, `?:`; `c&&x`/`x&&c`, `c||x`/`x||c` simplifications.
- Not done by WDL: CSE, copy propagation, load forwarding, LICM, strength reduction (other than the above),
  dead-store elimination, register allocation (values live on the 64-entry fp stack or in memory).

### 2.3 Code generation facts that define semantics (`compileOpcodesInternal` 3783, `compileNativeFunctionCall` 2799)
- **Return-value negotiation.** Each node is asked for a set of acceptable forms (NORMAL = pointer in p1, FPSTACK,
  BOOL/BOOL_REVERSED in p1, IGNORE) and converts with `PUSH_VAL_AT_P1_TO_FPSTACK`, `FPTOBOOL(_REV)`, `BOOLTOFP`,
  `POP_FPSTACK_TO_WTP` (+`SET_Px_FROM_WTP`) (4360–4512). *When* a variable's value is read is therefore decided here:
  a pointer result is dereferenced only when the consumer runs.
- **Evaluation order.** For builtin calls, non-trivial parameters are evaluated left→right first (results kept on the
  fp stack or pushed pointers), **trivial parameters (vars/constants) are loaded last** (3215–3320). So
  `a + (a = 5)` is 10. For `TWOPARMSONFPSTACK_LAZY` ops (`+ * & | ^ == != ===`, min2/max2) WDL does not `fxch`, so the
  operand order seen by the handler can be the reverse of source order (matters for NaN payloads).
- **Assignment target first**: `buf[i] = expr` computes the megabuf address (which may allocate) before `expr`.
- **Denormal filtering on store** (`denormal_filter_double2`, WDL/denormal.h:109: exponent 0 or 0x7ff ⇒ +0.0, i.e.
  ±0→+0, denormals→0, ±Inf→0, NaN→0):
  - `=`: ASSIGN / ASSIGN_FROMFP (filtered) vs ASSIGN_FAST / ASSIGN_FAST_FROMFP. FAST unless FULL_DENORMAL_CHECKS, or the
    source is non-trivial *and* `canHaveDenormalOutput` (propagated from `BIF_CLEARDENORMAL`/`BIF_WONTMAKEDENORMAL`,
    `__denormal_likely/unlikely`, NO_DENORMAL_CHECKS) (3121–3141, 3279–3297). Plain copies `a = b` are FAST.
  - `+= -=` filtered unless the right side is a literal with |c| ≥ 1e-50; `*=` FAST if |c| ≥ 1; `/=` FAST if |c| ≤ 1
    (3330–3350). `%= &= |= ^=` produce int-derived values (no filter). `^=` is `CFUNC_2PDDS(pow)` (no filter).
  - EEL-function parameters are copied unfiltered (`COPY_VALUE_AT_P1_TO_ADDR`, `POP_FPSTACK_TO_PTR`).
  - Constants are stored **filtered** into their cells (2752): a literal `0/0` or `1e-310` reads as +0.
- **Constants are memory.** Every literal operand is a pointer to an `EEL_F` cell (`generateValueToReg` 2686),
  cached per compile (`directValueCache`, last 50) and cached in the opcodeRec (`dv.valuePtr`), so one cell can be
  shared by several uses — and, for common functions, by several *sections*. Constant cells are writable: a cell can
  be overwritten via `(c ? x : 1) = 5`, `min(1,x) = 5`, or by an API function that writes through its argument
  (`midirecv(0, 0, m2)` writes into the cell of `0`).
- **User functions** (`nseel_getEELFunctionAddress` 1778, `compileEelFunctionCall` 3407):
  - inlined (bytecode copied) when the compiled body is ≤ `NSEEL_MAX_FUNCTION_SIZE_FOR_INLINE` = 2048 bytes and not
    NO_INLINEFUNC; otherwise compiled once per handle into a separate block with `RET`, called via `FCALL`.
  - parameters and `local()`/`static()` variables are **static cells** (`localstorage[]`), not a stack: values
    persist between calls, all call sites and all namespace instances of the function share them *within one code
    handle*. For common functions the storage pointers are reset at the start of every section compile (4580), so
    each section gets its own copy. No recursion is possible.
  - `instance()` / `this.` / `ns.f()` resolve to ordinary named VM variables (`l1.b0`) through
    `combineNamespaceFields`; each namespace gets its own compiled copy (`derivedCopies`).
  - parameter passing: non-trivial args are evaluated in order (pushed as *values*), then popped into the param cells,
    then trivial args copied; return value is FPSTACK or NORMAL (pointer, possibly to a local cell).
- **Loops** (glue_port.h:610–680, `GLUE_INLINE_LOOPS`): `loop(n, body)`: n evaluated once, `(int)n`; `< 1` skips;
  clamped to `NSEEL_LOOPFUNC_SUPPORT_MAXLEN` = 1048576; wtp saved and restored every iteration.
  `while(cond)`: counter initialised to 1048576; after every evaluation of `cond` the counter is decremented and the loop
  exits when it reaches 0 regardless of `cond`; otherwise `cond` true ⇒ repeat. Both have BOOL "value" = whatever p1
  holds afterwards (possibly a stale pointer from *before* the loop if `loop` ran 0 times).
- **Memory**: `MEGABUF`: `idx = (unsigned)(v + 1e-5)`; fast path if `idx < 2048*65536` and block present, else
  `__NSEEL_RAMAlloc` (allocates under a mutex if below maxblocks, else returns `&nseel_ramalloc_onfail`, a single
  process-global cell shared by all VMs). `GMEGABUF`: `__NSEEL_RAMAllocGMEM(gram, (int)(v+1e-5))` (shared across
  instances and threads). `freembuf` only sets a flag; ysfx never calls `NSEEL_VM_freeRAMIfCodeRequested`, so blocks only
  go NULL → allocated during a run.
- **C functions**: `CFUNC_1PDD` (sin, cos, tan, sqrt_fabs, log, log10, asin, acos, atan, exp, floor, ceil, rand),
  `CFUNC_2PDD` (pow, atan2), `CFUNC_2PDDS` (`^=`), inline ops `ABS SQR SIGN MIN MAX MIN_FP MAX_FP INVSQRT`, mem ops via
  `GENERIC*` (`memcpy memset freembuf __memtop mem_set_values mem_get_values mem_multiply_sum mem_insert_shuffle`),
  user stack `USERSTACK_*` (per-handle 4096-entry ring).
- **ysfx API** (`ysfx_api_*.cpp`, eel_strings.h, eel_fft.h, eel_mdct.h …): all through `GENERIC1/2/3PARM(_RETD)`,
  `GENERIC2PARM_RETD` varparm (pointer array built on the interpreter stack), `GENERIC2XPARM_RETD`. Arguments are
  pointers to cells; callees may read *and write* them (midirecv, file_var, mem_get_values, strcpy …), may access any
  variable through `fx->var` or by name, and may return a pointer to any cell (`spl(n)`, `slider(n)`, `stack_*`).
  Strings are EEL_F indices; literals/`#names` are constant cells created at compile time.
- **Global/shared state**: `_global.*` variables (process-wide list, not in `enumallvars`), gmem, the Mersenne
  twister in `nseel_int_rand` (static in nseel-cfunc.c), `nseel_ramalloc_onfail`.
- **Machine model of the portable interpreter** (`GLUE_CALL_CODE`, glue_port.h:460): p1/p2/p3 (pointers or bool),
  wtp, 64-entry fp stack, 64 KB byte stack (pointers, values, loop ints, saved wtp, return addresses, varparm arrays).
  Opcodes are `int`, immediates are 8-byte pointers at 4-byte alignment.

### 2.4 What the sections share (ysfx.cpp 466–540, 1535–1625)
- One NSEEL VM per effect: all variables, megabuf, gmem attachment, string table, function *definitions* are shared by
  @init (one handle per import + main), @slider, @block, @sample, @gfx, @serialize.
- Per handle: bytecode, worktable, user stack, the compiled copies of common functions and their local/param storage.
- Constant cells and `#string` cells of common functions may be shared across handles (opcodeRec `valuePtr` reuse).
- ysfx writes `spl*`, `samplesblock`, `num_ch`, `trigger`, `srate`, sliders between executions; the @sample loop writes
  `spl[ch] = (double)in + denorm` (denorm = 1e-16 unless `ext_nodenorm`), runs, reads `spl[ch]` back as `Real`.
- `_global.`, gmem and rand are shared between *effects* (and threads).

---

## 3. Semantic inventory the backend must reproduce bit-exactly

"How": **B** = baked into the bytecode, preserved automatically by lifting; **R** = re-implemented in handlers/folder
(must use the *same C expression* as glue_port.h, ideally from a shared header, §9.8); **F** = fallback.

| # | Semantic | Source | How |
|---|---|---|---|
| S1 | Evaluation order incl. "trivial operands read last", assignment target first, lazy operand order of `+ * & \| ^ ==` | compileNativeFunctionCall | B |
| S2 | Read timing through pointers (NORMAL results dereferenced at consumption; `min(a, a=5)`) | compileOpcodes | B (explicit Load in IR at the consuming point) |
| S3 | All WDL constant folding / algebraic rewrites of §2.2 | optimizeOpcodes | B |
| S4 | FAST vs filtered store choice; `denormal_filter_double2` semantics (±0→+0, denorm→0, Inf/NaN→0) | §2.3 | B (choice) + R (filter) |
| S5 | Constants are filtered writable cells; cell sharing between uses and sections | generateValueToReg | B + VM-wide cell analysis (§5.3) |
| S6 | `==`/`!=` with closefactor `fabs(b-a) < 1e-5`; truthiness `fabs(x) >= 1e-5`; `===`/`!==` exact; `< > <= >=` with NaN false, exact operand order (`ABOVE` is `top < top2`, `BELOWEQ` is `top >= top2`) | glue_port.h | R |
| S7 | `+ - * /` as single IEEE ops, no FMA contraction, operand order preserved (NaN payload) | glue_port.h | R (`fp contract(off)`, never commute) |
| S8 | `& \| ^` via `(WDL_INT64)` truncation, `x\|0` = or0; `%`: `(int)fabs(b)`, `(WDL_INT64)fabs(a) % b`, 0 if b==0; `<< >>` via `(int)`, amount `&31`, `<<` on unsigned | glue_port.h + patch | R |
| S9 | Out-of-range / NaN double→int conversions: arm64 `fcvtzs/fcvtzu` saturation (NaN→0); fuzz x86 built with `-fno-strict-float-cast-overflow` to match | run.sh | R (same flags, §9.8) |
| S10 | `min/max` pointer versions (`if (*p1 > *p2) p1 = p2`, returns *reference*) vs `MIN_FP/MAX_FP` value versions; different NaN/-0 winners | glue_port.h | B (choice) + R |
| S11 | `sign` (NaN and ±0 unchanged), `abs`=fabs, `-x` negation, `sqr`=x*x, `sqrt`=sqrt(fabs) | | R |
| S12 | `invsqrt` float hack with patched unsigned subtraction; possible FMA contraction in the portable TU | glue_port.h:846 | R via shared helper (§9.8) |
| S13 | libm functions called through the exact function pointer in the bytecode (no vector/fast variants) | CFUNC_* | R (same pointer) |
| S14 | `rand`: process-global MT state, call order | nseel-cfunc.c | B (call stays in order) |
| S15 | megabuf index `(unsigned)(v+1e-5)`, block fast path, allocation side effect, `onfail` global cell | glue_port.h:896, nseel-ram.c:139 | R (same expression; slow path = same function) |
| S16 | gmem via `__NSEEL_RAMAllocGMEM`, shared, volatile | | R (always call; never cache) |
| S17 | `loop`: `(int)n`, skip `< 1`, clamp 1048576; `while`: ≤ 1048576 condition evaluations | glue_port.h:610–680 | B (structure) + R (counters) |
| S18 | p1 value of `loop`/`while` (BOOL of stale p1 when the body ran 0 times) | | B (p1 tracked as SSA) |
| S19 | Static local/param cells of user functions (persist across calls; shared by instances) | §2.3 | B (cells) |
| S20 | Worktable temps (`(a+b) = 3` stores into a temp; pointers to temps escape into API calls) | | B (temps are cells) |
| S21 | API calls: same function pointer, same opaque, same argument *pointers*, same order, may read/write any escaped cell or variable, may return arbitrary pointers | GENERIC* | R (call handler) + memory model §7.3 |
| S22 | varparm arrays (pointer arrays; counts up to 32768) | | R; F if > ~7000 (portable overflows its 64 KB stack) |
| S23 | User stack ops with handle-local ring and masks | USERSTACK_* | R (same arithmetic) |
| S24 | `_global.*`, gmem, rand, onfail are shared with other instances/threads: order of every access preserved, no caching | | memory model §7.3 |
| S25 | `__dbg_getstackptr()` (interpreter stack depth) | | F |
| S26 | Opcode 0 (`GLUE_POP_STACK_TO_FPSTACK` placeholder, emitted at fp-stack depth ≥ 63 or `//#eel-no-optimize:2`) is a silent NOP that leaves the stack inconsistent | glue_port.h | F |
| S27 | ysfx @sample framing: `(double)in + denorm`, padding channels = denorm, `(Real)spl` out, channel counts clamped per block | ysfx.cpp | R (frame-begin/end handlers) |
| S28 | Variables written by the host between executions; sliders aliases via var resolver | | memory model (always load) |

---

## 4. Where to hook

### Option A — compile from opcodeRec (replace `compileOpcodes`)
Pros: structured trees, names and function info available, easy statement shapes.
Cons:
- Must re-implement every decision of §2.3 exactly (return-value negotiation ⇒ read timing; trivial-last order; lazy
  operand order; fp-stack spill at depth 63; denormal FAST/filtered propagation incl. `__denormal_*` and
  `//#eel-no-optimize`; constant-cell allocation and caching; inlining threshold measured in *portable bytecode bytes*).
  Every mismatch is a silent bit-exactness bug.
- Code generation has side effects (variable registration, namespace instance creation, constant cells) and WDL's own
  compile must still run for the fallback ⇒ two code generators that must agree on side effects.
- opcodeRec trees live in `tmpblocks` and are freed at the end of `NSEEL_code_compile_ex` ⇒ deep hooks inside
  nseel-compiler.c ⇒ large, fragile vendor patch.
### Option B — translate the portable bytecode of each handle (chosen)
Pros:
- The bytecode *is* the reference semantics: S1–S5, S10, S17–S20 come for free; we only re-implement ~110 small,
  well-defined opcode semantics, each testable in isolation.
- Zero changes to WDL's frontend or code generator. The lifter reads `codeHandleType` (in `ns-eel-int.h`) and the opcode
  enum (`glue_port.h`), both pinned by the reviewed submodule revision. The backend lives in EffectDeck sources.
- Fallback is trivial and fine-grained (per handle), and the bytecode stays untouched for stage-1 executors.
- Works unchanged whether or not the stage-1 goto interpreter is in use (stage 1 keeps the bytecode identical).
Cons:
- Structure must be recovered (stack→SSA, CFG from relative jumps). Standard technique; WDL's output is strictly
  structured (if/else, &&/||, loop, while, FCALL/RET), so stack depths are static.
- Names are lost (debug dumps map addresses back via `NSEEL_VM_enumallvars`).
- Constant cells look like any other static cell ⇒ need a VM-wide store/escape analysis (§5.3) before folding.
- Coupled to the portable encoding (int opcodes + 8-byte immediates). Mitigated by a static check of the enum values
  and "unknown opcode ⇒ fallback".
### Option C — hybrid (capture opcodeRec for hints, generate from bytecode)
Only buys statement-shape hints that tree reconstruction from SSA recovers anyway. Not worth the vendor patch.

**Decision: B.** The program is built after all sections of an effect are compiled (VM-wide link step), off the audio
thread, and attached to each handle.

---

## 5. Architecture

```
 ysfx_compile ──► WDL compile (unchanged) ──► handles: init[], slider, block, sample, gfx, serialize
                                                   │
 ysfx_set_eel_exec_mode(fx, NSEEL_EXEC_REG)  or  end of ysfx_compile when mode == REG
                                                   ▼
   Link (VM-wide):  enumerate vars · data-block address ranges · lift every handle (analysis mode)
                    → cell classes (Var / Const / Static / Temp / Volatile)              §5.3
                                                   ▼
   Per handle (@init/@slider/@block/@sample):  lift → SSA IR → verify → passes → select kernels
                    → regalloc frame slots → emit threaded program → attach to handle    §6–9
                                                   ▼
   NSEEL_code_execute_frames(handle, REG, n, pre, post, io):
        handle has program ? run program (whole block in one entry) : best stage-1 mode
```

### 5.1 Components (new files, EffectDeck sources, e.g. `Sources/Shared/JSFXVM/`)
- `ETVMLift.cpp` — bytecode reader + abstract interpreter → IR (+ fallback reasons).
- `ETVMIR.h/.cpp` — IR, verifier, printer, **reference IR interpreter** (oracle, never shipped hot).
- `ETVMOpt.cpp` — passes (§8).
- `ETVMSelect.cpp` — tree reconstruction + kernel covering + frame slot allocation + emission.
- `ETVMHandlers.cpp` (+ generated `ETVMKernels.inc`, `ETVMKernelMatch.inc`) — handlers, compiled with
  `-ffp-contract=off` and the same float-cast flags as YSFX.
- `ETVMOps.h` — single source of truth for opcode semantics (shared with glue_port.h via the patch, §9.8).
- `Tools/jsfx-vm/gen_kernels.py`, `Tools/jsfx-vm/mine_shapes.py` — kernel generator and corpus shape miner.

### 5.2 Hook surface in Vendor (via the patch; builds on stage 1)
- `ns-eel.h`: `#define NSEEL_EXEC_REG 4` (COUNT 5) and a backend registration:
  ```c
  typedef struct {
    int  (*run)(void *prog, unsigned nframes, NSEEL_FRAME_CALLBACK pre, NSEEL_FRAME_CALLBACK post, void *ctx);
    void (*free)(void *prog);
  } NSEEL_exec_backend;
  void NSEEL_set_exec_backend(const NSEEL_exec_backend *);      /* once, by ETJSFXHost */
  void NSEEL_code_attach_program(NSEEL_CODEHANDLE, void *prog); /* NULL detaches */
  ```
- `codeHandleType` gains `void *backend_prog` (freed by `NSEEL_code_free` through `backend->free`). Program lifetime
  therefore equals handle lifetime — no side tables, nothing dangling after recompile/unload.
- `NSEEL_code_execute_frames(h, NSEEL_EXEC_REG, …)`: `h->backend_prog ? backend->run(...) : <best stage-1 mode>`.
- ysfx: `ysfx_set_eel_exec_mode(fx, NSEEL_EXEC_REG)` calls a registered builder
  `bool (*build)(NSEEL_VMCTX vm, NSEEL_CODEHANDLE *handles, int n, const ysfx_vm_io_desc *io)` on the caller's thread,
  attaches programs, then publishes the mode (release store; the audio thread already loads it per block). The same
  builder runs at the end of `ysfx_compile` when the mode is REG. Programs are only built/freed while the effect is not
  processing (ETJSFXHost already serialises create/reconfigure against the audio thread; must be re-checked).
- Optional (S4+): ysfx passes a typed io descriptor (spl pointers, counts, denorm, Real type) instead of `pre/post`
  callbacks so frame-begin/end are inline handlers (saves two indirect calls per frame, ≈0.5–1 µs/block on M1).

### 5.3 Link step: VM-wide cell classification
Every address that appears as an immediate (`MOV_Px_DV`, `MOV_FPTOP_DV`, `POP_VALUE_TO_ADDR`, `COPY_VALUE_AT_P1_TO_ADDR`,
`POP_FPSTACK_TO_PTR`, `RESET_WTP`, stack-ops' state pointers) is classified:
- **Var**: address of a registered variable (`NSEEL_VM_enumallvars`).
- **Temp**: inside the handle's worktable `[workTable, workTable + (workTable_size + 32 + 16))`.
- **Static**: inside a data block of *any* handle of this VM (`codeHandleType::blocks_data` llBlock chains) or the
  VM's `ctx_pblocks`, and not a Var. These are constant cells, user-function locals/params, `#string` cells.
- **Volatile**: anything else (`_global.*` cells, `nseel_ramalloc_onfail`, unknown) — never cached, never folded.

Lift **every** handle (including @gfx/@serialize, analysis-only) and mark a Static cell *mutable* if any handle
(a) stores to it directly, (b) may store to it through a pointer whose may-point-to set contains it (phis, `min/max`
pointer results, assignment results), or (c) lets its address escape (argument to an API/mem/stack call, stored into a
varparm array, returned from a non-inlined function as NORMAL and then escaping). A Static cell that is never mutable is
**Const** and its current value (already filtered) may be folded. If *any* handle cannot be analysed, no cell is Const
(still correct, just less folding). Values are read at link time; Const cells never change afterwards.

---

## 6. Lifter (bytecode → IR)

Abstract interpretation of the portable machine over the handle's code, following jumps structurally.

State per program point: `p1, p2, p3` (SSA values typed ptr | bool | null), `fp[]` (SSA f64 values; depth ≤ 64),
`stk[]` (entries typed ptr | f64 | i32 counter | saved-wtp | return address | varparm area), `wtp` (= worktable base +
static offset). Entry state: p-regs = null, stacks empty, wtp = undefined until `RESET_WTP`.

- **Straight-line ops** become IR instructions (mapping table in Appendix A). Example: `MOV_FPTOP_DV c` ⇒
  `v = LoadCell(c)` pushed on `fp`; `ADD` ⇒ `v = FAdd(top2, top)`; `ASSIGN_FAST_FROMFP` ⇒ `StoreCell(p2, pop)` or
  `Store(p2, …)` and `p1 = p2`.
- **Pointers**: a pointer is either a known cell (constant address) or an SSA ptr value (megabuf result, API result,
  user-stack, `PtrMin/PtrMax`, phi). Loads/stores through a known-cell pointer become `LoadCell/StoreCell`.
- **Control flow**: `JMP_IF_P1_Z/NZ`, `JMP_NC` create blocks; at merge points the shapes of `fp`/`stk` must agree
  (they do for WDL output); differing SSA values become phis (including pointer phis — `(c ? a : b) = 5` stores through
  a phi of two cells). `LOOP_LOADCNT/LOOP_END` and `WHILE_SETUP/BEGIN/END/CHECK_RV` become canonical loops with an i32
  counter; saved/restored `wtp` is checked to be the same static offset.
- **FCALL** (non-inlined functions, >2048 bytes): the callee is lifted *inline* with the current abstract state (exact
  by construction: the callee sees the same p-regs/fp stack). A total IR budget (e.g. 64 k instructions per handle)
  ⇒ fallback; subroutine emission is a later refinement (S6).
- **varparm calls**: `MOVE_STACK(-n)` … `STORE_P1_TO_STACK_AT_OFFS` … `MOV_P2_DV(count)` `MOVE_STACKPTR_TO_P1`
  `GENERIC2PARM_RETD` `MOVE_STACK(+n)` is recognised as one `CallVarparm(fn, opaque, [ptr…])`.
- **Fallback reasons** (recorded, counted in dumps/telemetry): unknown opcode or opcode 0 (S26), `DBG_GETSTACKPTR`
  (S25), stack shape mismatch at a merge, use of an undefined p-reg/fp slot, type confusion (bool used as pointer
  address, pointer used as value), varparm > 7000 args, IR budget exceeded, wtp not statically known, jump outside the
  code block.

The lifter never guesses: anything it cannot model precisely is a fallback.

---

## 7. IR

### 7.1 Types and values
`f64`, `ptr` (address of an EEL_F), `bool` (portable's p1 null/non-null), `i32` (loop counters), `void`.
SSA values have a definition, uses, and (after selection) a frame slot. Cells are *not* SSA values; they are memory
locations named by absolute address and class.

### 7.2 Instructions (all with exact portable semantics)
- Memory: `LoadCell(c)`, `StoreCell(c, v)`, `StoreCellF(c, v)` (filtered; returns the stored value), `Load(p)`,
  `Store(p, v)`, `StoreF(p, v)`; `MemAddr(idx)` (megabuf, may allocate), `GMemAddr(idx)` (volatile),
  `UStackPush/Pop/PopFast/Peek/PeekInt/PeekTop/Exch` (per-handle ring).
- Arithmetic: `FAdd FSub FMul FDiv FNeg FAbs FSqr FSign FMin2 FMax2` (MIN_FP/MAX_FP semantics),
  `PtrMin PtrMax` (reference versions, perform their own loads), `IAnd IOr IXor IOr0 IMod IShl IShr` (S8),
  `InvSqrt`, `CallF1(fnptr, x)`, `CallF2(fnptr, a, b)` (libm/rand/pow/atan2 — fnptr from the bytecode).
- Compare/bool: `CmpEqClose CmpNeClose CmpEq CmpNe CmpTopLtTop2 CmpTopGeTop2` (+ derived forms only when bit-identical),
  `Truthy(x)` (`fabs(x) >= 1e-5`), `Falsy(x)`, `BNot(b)`, `BoolToF(b)`, `PtrNonNull(p)`.
- Op-assign: expressed as `Load` + arithmetic + `Store`/`StoreF` (no special ops needed; the selector re-fuses them).
- Calls: `CallG1/2/3(fn, opaque, ptr…) → ptr`, `CallG1/2/3D(...) → f64`, `CallVarparm(fn, opaque, ptr[]) → f64`,
  `CallVarparmX(fn, ctx1, ctx2, ptr[]) → f64`, `CallMem*` (memcpy/memset/… are just `CallG3` with known fn).
- Control: `Br`, `CondBr(bool)`, `LoopInit(f64) → i32` (skip / clamp), `LoopNext(i32) → i32,bool`,
  `WhileInit → i32`, `WhileNext(i32) → i32,bool`, `Ret`. Plus `FrameBegin/FrameEnd` for the block-level @sample loop.

### 7.3 Memory model and effects (what passes may assume)
Classes: **Frame** (SSA values, never addressable from outside), **Const** (immutable), **Var**, **Static** (mutable
statics), **Temp-private** (worktable cells whose address never escapes), **Temp-escaped**, **Volatile**, **RAM**
(megabuf), **GMEM**, **UStack**, **Unknown** (pointer of unknown origin).

| Effect | Clobbers (for load-CSE / forwarding facts) |
|---|---|
| `StoreCell(c)` | c only |
| `Store(p)` with p = phi/PtrMin of known cells | those cells |
| `Store(p)` with p from MemAddr | RAM facts (not cells: RAM blocks and the onfail cell cannot alias VM cells) |
| `Store(p)` with p Unknown (API/user-stack result) | Var, Static, Temp-escaped, RAM, UStack (everything but Const, Frame, Temp-private) |
| Any API / mem / rand / ustack call | same as Unknown store, plus it is an ordering point for Volatile/GMEM/rand |
| `MemAddr` | ordered w.r.t. other MemAddr, stores, calls (allocation side effect); free w.r.t. pure arithmetic |

Volatile and GMEM accesses are never CSE'd, forwarded, hoisted or removed (they may race with other instances exactly
as portable does). Var cells are never kept in registers *across* any instruction that may observe them; within the
VM they are simply always memory (§9.2), which is what makes interop with portable sections, host writes and API
callbacks trivially exact.

---

## 8. Optimisation passes

### 8.1 Safe (bit-exact) passes, in order
1. **Stack elimination** — inherent in lifting (no push/pop/fxch/p-reg shuffles remain).
2. **Const-cell folding** — `LoadCell(Const)` ⇒ literal.
3. **Constant folding** of IR ops whose inputs are literals, evaluated by the *same* functions as the handlers
   (`ETVMOps.h`), at load time. Guard: do not fold if any input or the result is subnormal (load thread and audio thread
   may differ in FPCR.FZ; EffectDeck does not set FTZ today, but the guard makes it irrelevant). libm calls may be folded
   through the same function pointer (same process, same rounding mode). Branches on constant conditions are folded.
4. **Copy propagation / SSA cleanup** (phis of identical values, trivial blocks).
5. **Load CSE and store→load forwarding** for Var/Static/Temp cells under §7.3 (block-local first, then dominator-based
   with memory-SSA). Forwarding through `StoreCellF` forwards the *filtered* value.
6. **Pure value numbering (CSE)** of arithmetic on identical SSA operands (IEEE ops are deterministic). Operand order is
   part of the key — never canonicalise commutative ops (NaN payload, S7).
7. **DCE** of unused pure values and of stores to Temp-private cells that are dead; `MemAddr` is never removed (it may
   allocate) but its unused *load* is.
8. **Temp promotion** — Temp-private cells become SSA (mem2reg). Temp-escaped cells keep their original worktable
   address (identical observable behaviour to portable).
9. **Direct destination** — the last op before `StoreCell(c, v)` (FAST) writes c directly when v has no other use;
   filtered stores use the filtered-store kernel variants.
10. **Speculation into selects** for `x = c ? a : b` when both arms are pure arithmetic over cells/literals
    (no MemAddr, no calls, no Volatile/GMEM): becomes a select kernel.
11. **Loops (S5)**: LICM of pure ops whose inputs are loop-invariant (no store to their cells in the loop, no calls);
    counted-loop canonicalisation; unrolling of tiny bodies (pure replication, cap semantics preserved);
    **megabuf induction strength reduction with a guard**: for `base[k]` where `k` is a cell stepped by ±1.0 and
    `base` invariant, compute `idx = (unsigned)((base + k) + 1e-5)` exactly at loop entry, then advance a raw pointer
    while a guard proves equivalence (both `base + k` exactly integer-valued and in `[0, 2^31)`, same 65536-entry block,
    block present); otherwise use the general per-iteration path. The guard is checked at loop entry and at block
    boundaries, never assumed.
12. **Dead-store elimination for Static/Var cells** — only stores overwritten on every path before any read, call,
    unknown store or program exit (cells persist across executions). Low priority.

### 8.2 Unsafe transformations (must not be done) and why
| Transformation | Why unsafe |
|---|---|
| `a*b+c` → FMA (any contraction) | different rounding; handlers must be compiled with contraction off |
| Reassociation `(a+b)+c ↔ a+(b+c)`, distributing, factoring | rounding |
| Swapping operands of `+ * == min max` | NaN payload propagation (first NaN operand wins on arm64 with FPCR.DN=0) and MIN/MAX NaN/-0 winners |
| `x*0 → 0`, `x-x → 0`, `x+0 → x`, `x*1 → x` (beyond what WDL baked) | NaN/Inf/-0 |
| `x/c → x*(1/c)` for inexact reciprocals; `pow(x,2) → x*x`, `pow(x,.5) → sqrt`, `exp(x*log c)` for `c^x`, vectorised/approximate libm | not correctly rounded the same way |
| Inverting comparisons (`!(a<b) → a>=b`), `x==0 → !x`, replacing closefactor compares by exact ones | NaN, closefactor |
| Dropping or adding `denormal_filter` on a store (e.g. "x is never denormal") | ±0, NaN, Inf mapping; only provable for literal +0.0/1.0 or a normal non-zero literal, or results of `BoolToF` |
| `x = x` removal for filtered stores | filter changes -0/denormal/NaN/Inf |
| Keeping Var/Static values in registers across calls, unknown-pointer stores or section boundaries | API callbacks and host read/write cells; other sections run on portable |
| Caching megabuf block pointers across executions, or across a call | allocation/free policies; `freembuf` (future) |
| Caching or reordering gmem, `_global.*`, rand, onfail accesses | shared with other instances/threads |
| Hoisting `MemAddr` out of loops or speculating it | allocation side effect, onfail cell |
| Reordering stores relative to calls, or loads across stores that may alias | API functions read/write through pointers and by name |
| Changing loop trip count semantics (`(int)n`, `<1`, clamp 1048576; while cap) | infinite-loop protection is observable (results, time) |
| Merging constant cells / giving escaped temps or constants new addresses | the same cell may be written through by API calls and seen by other uses |
| Folding with the loader thread's FPCR when subnormals are involved | FZ may differ between threads |
| Assuming p1 is "dead" after loop/while | stale p1 is the loop's value (S18) |

---

## 9. Execution model

### 9.1 Instruction encoding
```c
typedef struct VMIns VMIns;
typedef void (*VMHandler)(const VMIns *ip, VMCtx *cx);   // musttail chain
struct VMIns { VMHandler h; /* followed by k operands, 8 bytes each */ };
```
Operands are `double *` (cells, const-pool entries, frame slots), `void *` (fn, opaque), branch targets
(`const VMIns *`), or small ints packed in 8 bytes. One handler per shape; instruction size `8 + 8k`. Literals live in a
per-program constant pool (cells) so "immediate" and "memory" operands are the same kind. Frame slots are a per-program
static array (EEL code is not re-entrant per handle; WDL's worktable already assumes this).

### 9.2 Operand model: everything is an absolute pointer
- A frame slot and a VM variable cost the same in an interpreter (pointer from the instruction + one load), so values
  are not cached in "registers" at all: Var/Static/Temp cells are used in place. This keeps every observable memory
  effect identical to portable for free (S20, S21, S24, S28) and makes VM and portable sections interoperable.
- Frame slots hold SSA values; slot allocation is linear-scan over the linearised IR (minimise footprint; < ~64 slots
  for typical @sample).

### 9.3 Dispatch
- Direct threading with `[[clang::musttail]] return next->h(next, cx);` (clang ≥ 13 on Apple and Linux; guaranteed even
  at -O0, so Debug works). Each handler is a small independent function: good register allocation at -Os, easy to
  generate. A `while ((ip = ip->h(ip, cx)))` call-loop variant behind a macro serves sanitizer/debug builds and
  compilers without musttail.
- Optional (S5 experiment): pass one or two `double` "pinned registers" through the musttail signature (stay in d0/d1
  across handlers, à la wasm3) and generate accumulator forms for chains the kernel library does not cover.

### 9.4 Superinstructions (three tiers)
1. **Generic 3-address ops** for every IR op (binary op with dest, filtered/unfiltered stores, loads/stores via pointer,
   calls, compares, branches). This is S2's executor.
2. **Generated 2-level arithmetic trees** over `+ - * /` (and `abs`, unary minus at leaves): `d = (a op b) op c`,
   `d = a op (b op c)`, `d = (a op b) op (c op e)` × {plain, filtered store} ≈ 200 handlers. Covers most DSP arithmetic.
3. **Corpus-mined statement kernels**: `mine_shapes.py` runs the lifter over a JSFX corpus (bench, fixtures, fuzz corpus,
   plus an *external, uncommitted* corpus such as the Cockos/ReaTeam effect collections — only the derived shape list
   is committed) and counts expression-tree shapes rooted at stores; the top N (e.g. 100–200) become generated kernels,
   e.g. one-pole `z = a + c*(z - a)`, biquad `y = b0*x + s1`, `s1 = b1*x - a1*y + s2`, `s2 = b2*x - a2*y`,
   smoothing `c += (t - c)*k`, MAC `acc += c * mem[base + j]`, lerp/mix `(a*d + b*w)*o`.
   Special-purpose fusions: compare+branch (`if (*a < *b)`, truthiness of a cell), `cell OP= literal`,
   `loop-next & branch`, megabuf `mem[base + idx]` load/store (computes `(unsigned)((*base + *idx) + 1e-5)` exactly,
   inline block-table fast path, slow path calls `__NSEEL_RAMAlloc`).
- **Selection**: after passes, rebuild expression trees: a single-use pure value defined in the same block is folded
  into its user if no instruction between them may clobber any cell it loads (§7.3). Trees are covered by kernels with
  a BURS-style dynamic program (cost = handler count, tie-break on operand count). Leaves are cells, frame slots or
  pool literals — all pointers. Kernels perform their loads in any order (loads of non-volatile cells with no
  intervening store are order-independent) but compute exactly the tree, without contraction.
- Generated C++ (example, filtered store variant):
  ```cpp
  ET_VM_HANDLER(k_add_mul_sub_F) {  // *d = filt(*a + *b * (*c - *e))
    const double *const *o = ops(ip);
    double t = *o[3] - *o[4]; t = *o[2] * t; t = *o[1] + t;
    *(double *)o[0] = eel_denormal_filter2(t);
    ET_VM_NEXT(ip, 6);
  }
  ```

### 9.5 Control flow and loops
- Basic-block threading: branch handlers jump to absolute `const VMIns *` targets; fall-through is the next instruction.
- `loop`: `LoopInit` handler computes `(int)n` (S9 semantics), skips when `< 1`, clamps to 1048576, stores the counter
  in a frame slot; `LoopNext` is a fused decrement-and-branch. `while`: counter in a frame slot initialised to
  1048576, decremented after every condition evaluation exactly as `WHILE_END`.
- S5 "loop kernels": tiny bodies (e.g. `loop(n, i += c)`, a single MAC) get a handler that runs the whole loop in C
  with the cell value in a local and one store per iteration-visible point (only when no other access to that cell
  exists inside the loop and no calls) — still bit-exact because the sequence of IEEE ops is unchanged.

### 9.6 Block-level @sample loop
`FrameBegin` (writes `spl[ch] = (double)in[ch][i] + denorm` for `ch < num_ins`, `denorm` for the padding channels) →
body → `FrameEnd` (writes `out[ch][i] = (Real)spl[ch]`, `++i`, branch to FrameBegin or return). S2 may call stage 1's
`pre/post` callbacks instead; S4 switches to the typed io descriptor (float and double variants). @slider/@block/@init
run with `nframes = 1` and no framing.

### 9.7 API callbacks
`CallG*`, `CallVarparm*` handlers call the exact function pointer and opaque from the bytecode with the exact argument
pointers (cells; escaped temps keep their worktable address; frame values never escape, because a value whose pointer
is passed is a Temp-escaped cell by construction). varparm arrays are built in a per-program scratch array (sized at
build time from the max count) — no alloca on the audio thread. Returned pointers go to a frame slot (Unknown).
No spill/reload is needed around calls because nothing VM-observable is cached (§9.2).

### 9.8 Numeric hygiene (compile flags and shared semantics)
- Handler TUs: `-ffp-contract=off` **and** `#pragma clang fp contract(off)` at the top; no `-ffast-math`;
  `-fno-strict-float-cast-overflow` (clang then emits saturating conversions = arm64 `fcvtzs/fcvtzu`; fuzz x86 already
  builds ysfx with it).
- `ETVMOps.h` holds the semantics of every non-trivial op as `static inline` functions with a local
  `#pragma clang fp contract(off)`: filter, closefactor compares, truthiness, int64 bitops, mod, shifts, invsqrt,
  megabuf index, loop count. The patch makes `glue_port.h`/`glue_port_vm.h` call the same functions, so portable, the
  stage-1 interpreters, the folder and the VM share one definition. Note: `invsqrt` in the portable TU is currently
  compiled with default contraction (`1.5F - t*y` may become `fmsub` on arm64); after the shared header it is
  explicitly unfused — a one-time change of portable's own output for `invsqrt` only, to be called out in the commit and
  re-baselined on the bench (no bench script uses it).
- The VM TU is compiled with the same optimisation level as YSFX by default; measure -O2 for `ETVMHandlers.cpp` via a
  per-file flag in project.yml (handlers are tiny; dispatch quality matters more than size).

---

## 10. Integration

### 10.1 Selection and rollout
- `ETJSFX_SetEELExecutor(host, NSEEL_EXEC_REG)` (stage-1 API) builds programs and switches; the bench adds one line:
  `{"vm-reg", true, Check::exact, 0, hostVariant<selectReg>}` and `Tools/jsfx-bench/diff.cpp` compares it like the stage-1
  modes.
- Beta: hidden setting / launch arg `-ETJSFXExec reg`. Default stays portable/stage-1 until the gates of §12 pass.
- Telemetry in Beta logs: per effect, which handles run on REG and the fallback reason of the others.

### 10.2 Building cost
Lifting and passes are linear-ish; budget the build (e.g. < 20 ms for a typical effect on iPhone; IR size cap per handle).
Built on the loader/host thread before the processor is published; never on the audio thread.

### 10.3 Lifetime
Programs are attached to handles (`backend_prog`) and freed in `NSEEL_code_free`; rebuilt after `ysfx_compile` if the
mode is REG. Because state lives in WDL cells, switching REG ↔ portable at a block boundary is exact.

### 10.4 Vendor patch procedure (keep setup.sh and the fuzz/bench builds working)
- Stage 1 already extends `Patches/ysfx-effectdeck-ios.diff`. Stage 2 adds only §5.2 + the shared-ops calls (§9.8).
  Prefer landing those as **one** patch revision right after stage 1's, or fold them into stage 1's revision if it is not
  yet committed, to limit patch churn.
- When the patch changes: copy the previously committed diff to `Patches/ysfx-effectdeck-ios.old.diff`; choose a new
  marker that only the new revision adds (e.g. `NSEEL_exec_backend`) and update all three greps:
  `Scripts/setup.sh` (line 49), `Tests/Fuzz/run.sh` (line 191), `Tools/jsfx-bench/run.sh` (line 87). The `.old.diff`
  path only knows one previous revision: a Mac tree two revisions behind must be re-sent.
- New EffectDeck sources must be added to: project.yml (target that links YSFX: app + extension; Sources/Shared is
  picked up wholesale), `Tests/Fuzz/run.sh` source lists, `Tools/jsfx-bench/run.sh`, and excluded/kept consistently with
  `check_release_binary` if any part is bench-only.

---

## 11. Fallback policy
- Unit: code handle. Reasons are explicit (§6) and visible in dumps.
- Analysis failure of any handle ⇒ no Const cells VM-wide (programs still built, with less folding).
- Policy knob per section: default translate @init/@slider/@block/@sample; @gfx/@serialize always portable.
- Performance guard: if a handle's program is estimated not to beat stage-1 (e.g. dominated by API calls), keep stage-1.
- No mid-execution fallback; correctness comes from construction + testing.

---

## 12. Verification plan

1. **Op semantics table tests** (Tests/Native): every portable opcode and every IR op/handler/kernel on a value grid:
   ±0, ±min/max subnormal, ±DBL_MIN, ±1e-5 ± ulp (closefactor), 0.5, 1, 2^31±1, ±2^63, 2^53+1, ±Inf, qNaN with two
   payloads, -NaN. Reference = single-op bytecode run through `GLUE_CALL_CODE`; compare bit patterns.
2. **Lifter oracle**: lifted IR executed by the reference IR interpreter vs portable, per handle. Localises lifter bugs.
3. **Threaded VM vs reference IR interpreter** (same IR, after passes) and vs portable. Localises pass/selection bugs.
   Every pass can be disabled individually (`ETVM_PASSES=-cse,-lsr`) to bisect.
4. **Bench corpus**: `vm-reg` with `Check::exact` in `kVariants` and in `diff.cpp`, Mac CLI -Os and -O3 and iPhone Beta.
5. **Fixtures** (`Tests/Fixtures/JSFX`, 30 scripts): run both executors from identical state with deterministic inputs,
   slider sweeps, triggers and state save/load; compare outputs and a **state hash** after every block: all vars
   (`enumallvars`), all allocated RAM blocks, all Static cells, user stack, MIDI out, slider-change masks.
6. **Fuzz corpus replay** (`Tests/Fuzz/Corpus/jsfxexec` + accumulated crashes/timeouts): a non-libFuzzer `main()` that
   replays the corpus through the differential checker, built with **Apple clang on arm64** (FMA, `fcvtzs` behaviour)
   and with Linux clang on x86-64. arm64 replay is mandatory because x86-64 has no FMA by default and can't catch
   contraction mistakes.
7. **libFuzzer differential target `jsfxvmdiff`** (Tests/Fuzz/Native):
   - Input = JSFX source (existing corpus/dict), FNV-derived sample rate, block sizes, slider values, NaN/Inf/denormal
     inputs as in `jsfx_exec.cpp`.
   - Two effects from the same source: A (portable), B (REG). Per step (each @init/@slider/@block/@sample block, state
     load): snapshot the **global** state G = {MT rand state, `nseel_ramalloc_onfail`, gmem blocks, `_global.*`
     values}, run A, capture G_A, restore G, run B, compare G_B with G_A and A/B state hashes and outputs bit-for-bit;
     continue from A's G. The MT state needs a tiny test-only accessor in the patch
     (`nseel_rand_state_save/restore` under `#ifdef NSEEL_TEST_HOOKS`).
   - Oracle extras: lifter must either succeed or name a fallback reason; ASan/UBSan clean (same suppressions as
     jsfxexec for nseel-*.c); timeouts are not failures.
   - Structure-aware mutation: an EEL expression grammar mutator (operators, nested loops/while, op-assigns, megabuf with
     fractional/negative/huge indices, `?:` lvalues, min/max as lvalues, user functions with namespaces/instances,
     varparm calls) to reach the corner cases of §3 quickly.
8. **Coverage metrics** reported per run: fraction of handles translated, fraction of IR covered by tier-2/3 kernels,
   fallback reasons histogram.
9. **Gates** for enabling by default in Beta: bench/fixtures/replay exact on Mac and iPhone; ≥ 24 CPU-hours of
   `jsfxvmdiff` without findings after the last semantic change; no script slower than the stage-1 default by > 5 %.
   For Release: one Beta cycle without JSFX regressions reported.

---

## 13. Staging (each step small, measurable, mergeable to `perf/jsfx-vm`, default-off)

Numbers: median µs per 256-frame block, **estimates** (to be replaced by bench JSON). Baselines: M1 -Os portable /
wdl-jit / cpp: filter_drive 43.1/16.1/1.2, biquad 96.0/21.6/2.0, fir 954/125/45.6, math 104/36.5/15.5,
slow 357/184/31; iPhone 16 Beta portable: 21.7, 47.4, 374.7, 57.2, 130.5, gain 2.2.

| Step | Content | Expected (M1 -Os) | Effort (agent-days) | Risk |
|---|---|---|---|---|
| S0 | Agree hook surface with stage 1 (§5.2), `ETVMOps.h` shared semantics in the patch, marker/.old.diff update | ±0 (invsqrt note) | 0.5–1 | low |
| S1 | Lifter + IR + verifier + printer + reference IR interpreter + link-step analysis; `jsfx-vm-dump` CLI; oracle tests (12.1–12.2) on bench/fixtures/corpus | none (infrastructure); coverage report | 5–7 | medium (stack→SSA corner cases: stale p1, varparm, while caps) |
| S2 | Threaded executor, tier-1 handlers, frame allocation, block @sample loop (stage-1 pre/post), megabuf inline fast path, `vm-reg` bench line, `jsfxvmdiff` target | fd ~15–20, bq ~30–40, fir ~250–350, math ~45–55, slow ~120–170, gain ~1–2 (≈ WDL JIT; 2–3× portable). **Measured (§16.4)**: fd 14.3, bq 31.8, fir 230.9, math 50.4, slow 177.0, gain 1.9 (2.0–4.1× portable; JIT is still faster on bq/fir/math) | 5–7 | medium-low |
| S3 | Passes 2–9 (const cells, folding, copy-prop, load CSE/forwarding, CSE, DCE, temp promotion, direct dest), fused compare-branch, loop-next, `cell OP= lit`, megabuf base+index | fd ~10–12, bq ~18–25, fir ~180–220, math ~35–40, slow ~100–130 | 4–6 | medium (alias rules — guarded by differential) |
| S4 | Tier-2 generated trees + tier-3 corpus kernels + BURS selection + select speculation; typed io descriptor for framing | fd ~5–8, bq ~9–15, fir ~110–150, math ~25–35, slow ~100–120 | 6–9 | medium (generator/matcher bugs, code size ~50–150 KB) |
| S5 | Loops: LICM, megabuf induction with guards, loop kernels, unrolling; pinned-register experiment | fir ~60–100, slow ~50–80, others −10–20 % | 5–8 | medium-high (guards) |
| S6 | Coverage & rollout: subroutines for huge functions instead of inline budget, @init/@slider/@block on by default, telemetry, Beta default after gates | — | 3–5 + soak | low-medium |
| S7 (optional) | AOT: emit C++ from the same IR for scripts shipped with the app (keyed by source hash), compiled into the app, verified by the same differential | ≈ cpp for those scripts | 4–6 | low-medium (build integration) |

iPhone expectation follows the M1 ratios approximately: at S4 roughly filter_drive 21.7 → 3–4.5, biquad 47.4 → 5–8,
fir 374.7 → 40–60 (S5), math 57.2 → 14–19, slow 130.5 → 40–60, gain 2.2 → 0.4–0.7.
Where the remaining gap to cpp comes from: one indirect dispatch per kernel (~1–3 cycles), memory round-trips for
loop-carried variables (store-forward ~4–5 cycles on the dependency chain), and calls out for megabuf slow paths and
libm. S5's loop kernels and S7's AOT are the only ways to close most of it without JIT.

Merge criteria per step: all §12 layers that exist at that step are green; bench JSON for M1 CLI (-Os, -O3) and iPhone
Beta committed under `docs/bench/`; never report -O0 numbers.

---

## 14. Risks and open questions
- **Stage-1 coordination**: the hook surface and patch revisions must be sequenced (§10.4). Stage 1 keeps the bytecode
  bit-identical (good); if it ever rewrites code in place (e.g. label addresses), the lifter must read the pristine
  encoding.
- **Hidden semantics** not yet listed in §3 would surface as differential failures — the reason the lifter only accepts
  patterns it fully models and the fuzz target is structure-aware.
- **FPCR / thread differences**: guarded in folding; handlers run on the same thread as portable would.
- **Code size and build time** of generated kernels: cap tier-3 by measured benefit; keep the generator deterministic.
- **musttail at -Os on Apple clang**: verify codegen (no frame setup in hot handlers) with `objdump` in S2.
- **Real-world fallback rate** unknown until S1's coverage report on an external corpus; expected low (opcode 0 and
  `__dbg_getstackptr` are rare; IR budget mostly hit by huge @gfx which is excluded).
- **Thread-safety of build vs processing** in ETJSFXHost reconfigure paths must be re-audited when wiring S2.
- Open: should REG also replace stage-1 for @init (large table loops at load time)? Measure in S6.

---

## 15. Implemented: S0 (hook surface) and S1 (lifter, IR, oracles) — 2026-10-07

Commits on `perf/jsfx-vm`: a700e2a (S0 patch revision), 0558811 (Sources/JSFXVM), f3dc530 (oracles and tools),
0d4f643 (`vm_lift.jsfx`), 75adc74 (link timing). The backend is **default-off**: nothing in the app calls
`ETVM_Install`; only the bench (`vm-reg` variant, opt-in), the CLI tools and the fuzz harness do.

### 15.1 What exists
- **Patch (S0 subset of §5.2)**, marker `NSEEL_exec_backend`, previous revision in `.old.diff`:
  `NSEEL_EXEC_REG` (= 5, name `vm-reg`), `NSEEL_exec_backend {run, free_prog}`, `NSEEL_set_exec_backend`,
  `NSEEL_code_attach_program` / `NSEEL_code_get_program`, `codeHandleType::backend_prog` (freed in `NSEEL_code_free`
  before the handle's data blocks). A handle without a program runs on `NSEEL_EXEC_GOTO_FPREG`.
  `NSEEL_code_exec_mode_available(REG)` is true only when a backend is registered. ysfx:
  `ysfx_set_eel_program_builder` (called by `ysfx_set_eel_exec_mode(fx, REG)` and at the end of `ysfx_compile` when the
  mode is REG), `ysfx_get_eel_handles` (vm + all handles + their sections), and @init runs through
  `NSEEL_code_execute_frames(h, REG, 1, …)` when the mode is REG.
- **`Sources/JSFXVM/`** (YSFX target in project.yml, per-file `-fno-strict-float-cast-overflow`; not in the extension):
  `ETVMBytecode.h` (opcode mirror + immediate widths; `ETVMGlueCheck.c` `_Static_assert`s every value against
  `glue_port.h`), `ETVMOps.h` (op semantics = copies of the `glue_port.h` expressions), `ETVMIR.h/.cpp` (IR, verifier,
  printer), `ETVMLift.h/.cpp` (lifter, fallback reasons), `ETVMInterp.cpp` (reference IR interpreter),
  `ETVMLink.h/.cpp` (link step / cell classes, state hash, the S1 backend = "run the reference interpreter per frame",
  coverage counters), `ETVM.h` (C API: `ETVM_Install`, `ETVM_SetSectionMask`).
- **Tools**: `Tools/jsfx-bench/run.sh --vm-opgrid` (§12.1), `--vm-dump [--vm-ir] [paths]` (coverage, per-handle
  fallback reason and pc, cell classes, link time, JSON), `--diff` now includes `vm-reg` (§12.2) and on a vm-reg
  mismatch re-runs with one section at a time. The diff also compares MIDI out (MIDI is now fed in every 3rd block),
  slider change/automation/visibility masks per block and `etvm::stateHash` (Static/Const cells referenced by any
  handle, in first-reference order, plus each handle's user-stack position). The jsfxexec fuzz target's differential
  has a third pass on `vm-reg`. `jsfx-bench --variants portable,vm-reg` (and `-ETBenchVariants` in the app) runs it in
  the bench with `Check::exact`.

### 15.2 Deviations from this design (and why)
1. `NSEEL_EXEC_REG` is 5, not 4: stage 1 already used 4 for `GOTO_FPREG_MASK`. `run` returns `void`.
2. Sources live in `Sources/JSFXVM/`, not `Sources/Shared/JSFXVM/`: the app and the extension both pick up
   `Sources/Shared` wholesale, and the backend reads WDL internals (`ns-eel-int.h`), so it belongs in YSFX only. A
   separate directory keeps the extension's exclude list and `DEVICE_SHARED_EXCLUDES` unchanged
   (`Tools/check_release_binary.py` got one `SOURCE_ROLES` line).
3. `ETVMOps.h` is **not yet** shared with `glue_port.h` (§9.8 / S0 item): doing so changes portable's own `invsqrt`
   (contraction), which needs a re-baseline. Instead `ETVMOps.h` copies the expressions; `invsqrt` keeps the portable
   TU's default contraction (`#pragma clang fp contract(on)` locally) and the §12.1 grid proves identity on x86-64 and
   arm64 at -Os and -O3. Move to a shared header in S2 when handlers are added.
4. IR spelling: filtered stores are `Filter` + `StoreCell`/`Store` (no `StoreCellF`/`StoreF`); loops are `LoopCount`,
   `ILt1`, `IDec`, `IGt0` (no `LoopInit/LoopNext/WhileInit/WhileNext`); `CallGXD` for non-varparm
   `GENERIC2XPARM_RETD`; constants (`PtrConst`, `BoolConst`, `I32Const`) live in `Function::consts` (they dominate
   everything, so merges of the same address need no phi).
5. Entry state is not "undefined": `GLUE_CALL_CODE` starts with p1 = p2 = p3 = NULL and wtp = the worktable, and the
   lifter models exactly that (a later dereference of NULL is the `null-deref` fallback).
6. **wtp is part of the path context**, not a merge-time check: the discovery key is (pc, FCALL return stack, wtp,
   saved-wtp stack). `c ? (expr using a temp) : x` advances wtp on one arm only; the code after the merge is then
   lifted once per wtp, so every temp keeps portable's address (design said "wtp not statically known ⇒ fallback";
   `opcodes.jsfx` @block needs this).
7. p-registers whose kind differs at a merge (value on one path, interpreter-stack address after a varparm call on the
   other) become "undefined" and only fail (`undefined`) if read later — WDL never reads them.
8. Varparm callees are called with their declared type `EEL_F (*)(void *, INT_PTR, EEL_F **)` (portable passes the
   same register values through a two-pointer type; UBSan `-fsanitize=function` flagged the cast).
9. **NaN + NaN payloads are not bit-exact by construction**: for `+` and `*` (and `+=`/`*=` FAST) the C compiler
   chooses the operand order in the portable TU (it commutes), so when *both* operands are NaNs with different
   payloads, which payload survives is a property of the compiled `glue_port.h`, not of the source. The stage-1 vm-*
   interpreters have the same exposure. The IR keeps source order; the grid counts these cases separately
   (x86-64: 40, arm64: 24 of 75,825) and does not call them mismatches. A single NaN operand, NaN vs number, and all
   other ops are bit-exact.
10. The state hash leaves out worktable and user-stack *contents*: both are `malloc`ed and never initialised, so
    portable-vs-portable already differs there. Static cells (constants, function locals, `#strings`) are
    initialised at compile time and are hashed.
11. §12.1 lives in the bench CLI (`--vm-opgrid`), not `Tests/Native`; the reference is a hand-assembled bytecode run
    through the real `NSEEL_code_execute` (fake `codeHandleType` with code/workTable/ramPtr), i.e. the compiled
    `GLUE_CALL_CODE` of the YSFX TU.
12. The x86-64 bench/CLI builds now use `-fno-strict-float-cast-overflow` for ysfx too (as the fuzz build and arm64
    hardware already behave), so out-of-range/NaN double→int conversions saturate identically in both TUs.

### 15.3 Oracle results (all with the S1 backend = reference IR interpreter)
| Layer | Linux x86-64, clang 21.0.0 (swiftlang), -Os / -O3 | Mac M1 arm64, Apple clang 21.0.0 (2100.3.34.2), -Os / -O3 | iPhone 16 Beta (-Os) |
|---|---|---|---|
| §12.1 op grid (`--vm-opgrid`, 45 values, 57 op shapes incl. op-assign, assign±filter, min/max refs, libm, loop/while caps, branch merges, megabuf incl. onfail) | 75,825 cases, 0 mismatched, 0 not lifted (40 NaN+NaN choices) | 75,825 cases, 0 mismatched, 0 not lifted (24 NaN+NaN choices) | — |
| §12.2 `--diff` (Tests/Fixtures/JSFX, Tests/Fuzz/Corpus/jsfxexec, Debug/JSFXBench, Tools/jsfx-bench/diff; 66 files, 62 compile): out, vars, RAM, @serialize, MIDI, slider masks, VM cells | 62/62 bit-exact for vm-reg and all stage-1 modes, both opt levels and the profile build | same, 62/62 | bench 7 scripts `portable,vm-goto-fpreg,vm-reg`: all `bit-exact ok` (`docs/bench/2026-10-07-s1-iphone16-beta-vmreg.json`) |
| fuzz `jsfxexec` (vm-reg as 3rd differential pass, ASan/UBSan) | 300 s, 67,533 runs, no finding | — | — |

### 15.4 Coverage (`--vm-dump`, same corpus; `docs/bench/2026-10-07-s1-vm-coverage-mac-m1-Os.json`)
| section | handles | lifted | blocks | IR insns |
|---|---:|---:|---:|---:|
| @init | 42 | 42 (100%) | 52 | 617 |
| @slider | 29 | 29 (100%) | 33 | 947 |
| @block | 20 | 20 (100%) | 60 | 536 |
| @sample | 31 | 30 (96.8%) | 166 | 5,522 |
| @gfx (analysis only) | 9 | 9 (100%) | 46 | 1,210 |
| @serialize (analysis only) | 14 | 14 (100%) | 24 | 154 |
| all | 145 | 144 (99.3%) | | |

Fallback histogram: `dbg-getstackptr` 1 (`opcodes.jsfx` @sample, deliberate). Cells referenced: var 543, const 618,
static (mutable) 648, temp 66, volatile 3. Link (lift every handle + classify) for a whole effect: max 1.1 ms on M1
(`vm_lift.jsfx`, 4,103 IR insns in @sample), 1.3 ms on WSL; well inside the §10.2 budget.
x86-64 and arm64 produce identical coverage.

### 15.5 Known gaps (carry into S2)
- No external corpus yet (Cockos/ReaTeam): the real-world fallback rate is still unknown (§14).
- Opcodes that WDL never emitted for the corpus, so the lifter's handling of them is untested end-to-end:
  `PUSH_P1PTR_AS_VALUE`, `POP_P1`, `MOVE_STACKPTR_TO_P2/P3`, `SET_P2/P3_FROM_WTP`, `PUSH_VAL_AT_P2/P3_TO_FPSTACK`,
  `GENERIC2PARM`, `GENERIC2XPARM_RETD` (the stage-1 profile build reports the same list). The grid does not cover
  `GMEGABUF`, the user-stack ops, API calls or `FCALL`; those are covered by the corpus and the fuzz differential only.
- §12.7 `jsfxvmdiff` (lockstep libFuzzer target with global-state snapshot, structure-aware mutator) is not built;
  the jsfxexec differential compares the float outputs only.
- Building programs in `ysfx_set_eel_exec_mode` is not audited against a running audio thread (§14); fine for the
  bench/CLI, required before S2 ships anything.
- The reference interpreter is 0.2–0.8× portable (iPhone 16 Beta, 1 s runs); it is an oracle, not an executor.

---

## 16. Implemented: S2 (threaded executor, `jsfxvmdiff`) — 2026-10-07

Commits on `perf/jsfx-vm`: 2084258 (executor), d6b26a0 (`jsfxvmdiff`, fork-mode crash detection, megabuf slow path;
the measured build), 80c8f36 (portable-UB skip, debug knobs), plus the docs/bench commit (run.sh exit 70). `vm-reg` is still **default-off in the app** (nothing in the app calls `ETVM_Install`);
in the bench it is now a default variant (no longer opt-in). The patch is unchanged (S0's hook surface was enough).

### 16.1 What exists
- `ETVMThreaded.h` (word/slot/context types, handler kinds), `ETVMHandlers.cpp` (73 handlers),
  `ETVMSelect.cpp` (IR → handler stream), `ETVMExec.h` (`buildThreaded` / `runThreaded` / `freeThreaded` /
  `disassembleThreaded`). `ETVMLink.cpp`'s backend builds a threaded program per handle by default;
  `ETVM_SetEngine(ETVM_ENGINE_REFERENCE)` builds S1's reference-interpreter programs instead (oracle).
- **Dispatch**: `[[clang::musttail]] return next->h(next, cx)`; `ETVM_THREADED_LOOP` (automatic when the compiler has
  no `clang::musttail`) switches every handler to "return the next word" + a `while` driver. Instruction = handler
  pointer + 8-byte operands; f64 operands are `double *` (cell, frame slot or pool), ptr/bool/i32 operands are frame
  slots, branch targets are word addresses. Handlers read every operand before writing (slot reuse relies on it).
- **Block-level @sample loop**: the `Ret` handler calls `post(i)`, then `pre(i+1)` and tail-jumps to the entry, so a
  whole block is one entry into the chain (stage-1 `pre/post` callbacks, §9.6).
- **Selection (tier 1, one handler per IR op)**, all exactness-preserving:
  dead pure values are not emitted (mark-live from stores/calls/allocations/branch conditions, so p1-tracking phis
  and `booltoptr` vanish); `LoadCell` is folded into the consuming operand when nothing between the load and the use
  may write the cell; an f64 op whose only use is the next `StoreCell(c, v)` writes `c` directly when nothing in
  between may read or write `c`; `+ - * /` immediately followed by `Filter` become one `*F` handler; `MemAddr`
  immediately followed by its `Load`/`Store` becomes `MemLoad`/`MemStore`. "May read/write" uses the pointer's origin:
  a constant address is that cell only, megabuf/gmem/`booltoptr` pointers never alias VM cells, everything else
  (API results, phis, min/max references, user stack) may alias any cell; API calls read and write every cell.
- **Frame slots**: values used outside their block and phis get dedicated slots; block-local values reuse slots after
  their last use. A phi and the incoming value from block X share a slot when that value is defined in X after the
  phi's last use (loop counters: `idec` writes the phi's slot, no copy). Remaining phi copies are sequentialised
  parallel copies (cycles through one temp slot); copies on conditional edges go to stubs after the code.
- **megabuf**: the handler computes `(unsigned)(v + 1e-5)` and uses the block table inline; a missing block or an
  out-of-range index tail-calls a separate slow handler (`__NSEEL_RAMAlloc`, same index), so the fast path stays a
  leaf.
- **Oracles**: `--vm-opgrid` runs portable vs reference IR vs threaded; `--diff` runs `vm-reg` (threaded) and
  `vm-reg-ref` (reference) against portable; `--vm-dump --vm-ir` prints the handler stream and per-section counts
  (handlers per IR instruction, folded loads, direct destinations, fusions, coalesced phis, copies).
- **`jsfxvmdiff`** (`Tests/Fuzz/Native/jsfx_vmdiff.cpp`, `Tests/Fuzz/run.sh --target jsfxvmdiff`): §12.7 as designed
  (A = portable, B = vm-reg, ysfx directly, lockstep over @init / blocks / state save / state load with global-state
  snapshot and restore; compares G, outputs, MIDI, slider masks, all vars, all RAM blocks, static cells, user-stack
  positions, @serialize bytes) plus a grammar mutator (`LLVMFuzzerCustomMutator`, 1/3 of mutations) that inserts EEL
  statements into a section: all operators, op-assigns, nested `loop`/`while`, megabuf with fractional/negative/huge
  indices, `?:` and `min/max` lvalues, user functions with `local`/`instance`/namespaces, varparm `mem_*_values`,
  user stack, `spl()`/`slider()`, gmem, `_global.*`.

### 16.2 Deviations from the design (and why)
1. **Pulled forward from S3**: LoadCell operand folding, direct destination (pass 9), DCE of unused pure values (part
   of pass 7) and the two fusions (op + filter, megabuf + load/store). Without them a tier-1 executor issues one
   dispatch per IR `LoadCell`/`StoreCell` and runs *more* handlers than vm-goto-fpreg runs bytecodes. They are
   emission rules with a local alias check, not IR passes; each is counted in `--vm-dump`. Still S3: const-cell
   folding, CSE, load forwarding, temp promotion, fused compare-branch, loop-next, `cell OP= literal`,
   megabuf base+index.
2. **Slot allocation** is "dedicated for cross-block values + reuse inside a block + phi coalescing", not linear scan
   over the linearised IR. Frames stay small: over the corpus at most 32 dedicated and 4 reused slots per handle
   (the largest frame, 133 slots, is 130 constant-pool entries: every `PtrConst`/`BoolConst`/`I32Const` gets one).
3. **rand in `jsfxvmdiff`**: instead of a test-only MT accessor in the patch, every step starts both sides with
   `NSEEL_rand_reset()` (same state for A and B; no new patch revision). The harness also zeroes each handle's user
   stack after compile (it is `malloc`ed and never initialised: `stack_exch`/`stack_peek` before a push differ even
   portable vs portable).
4. **Inputs on which portable itself may be undefined are skipped** by `jsfxvmdiff`: if any handle falls back with
   `undefined`, `type-confusion`, fp/interpreter stack over/underflow, `opcode0`, `null-deref`, `bool-deref`,
   `unknown-opcode` or `jump-outside`, portable can read outside its own stacks, and vm-reg runs that handle on
   vm-goto-fpreg, whose stack layout differs (§1 non-goal). The skip is decided from the lifter's reason before
   anything runs (conservative: some `undefined` refusals are benign, e.g. p1 after a varparm call inside `loop` is an
   interpreter-stack address that portable only tests for non-null). Two inputs made ASan stop in portable's
   `GLUE_CALL_CODE` (reads past the fp stack): one after a merge with differing p-registers, one where WDL left
   **uninitialised bytes in the @block bytecode** where an inlined user-function body belongs (the bytes differ from
   run to run in the ASan build; the -Os build happens to hold valid code there). The second is a WDL code-generator
   bug that portable and the stage-1 executors (the app default) share; vm-reg does not change the exposure (the
   lifter refuses the handle, which then runs on vm-goto-fpreg). Not investigated further in S2; the inputs are kept
   under `build/fuzz/` only (not committed).
5. **API calls are `no_sanitize("function")`** in the handlers and the reference interpreter: WDL registers API
   functions whose first parameter is `void *`, `EEL_F **`, `ysfx_t *`… and calls all of them as
   `(void *, EEL_F *…)` (same registers); UBSan's `function` check flagged `eel_fft`. `nseel-*.c` is already built
   without that check for the same reason.
6. `ETVMOps.h` is still a copy of the `glue_port.h` expressions (shared header = re-baseline of portable's `invsqrt`;
   moved to S3 together with const folding, which is where the folder needs it).
7. Handlers are compiled at the YSFX level (-Os); no per-file -O2 (the -O3 CLI column shows what a higher level buys).
8. `Tests/Fuzz/run.sh` now fails a run when new `crash-*` files appear: with `-fork`, a child stopped by UBSan/ASan
   writes its crash file but the parent kept going and exited 0 (seen with `jsfxvmdiff`; `jsfxexec` has the same
   exposure).

### 16.3 Oracle and fuzz results (vm-reg = threaded code)
| Layer | Linux x86-64, clang 21.0.0 (swiftlang), -Os / -O3 | Mac M1 arm64, Apple clang 21.0.0, -Os / -O3 | iPhone 16 Beta |
|---|---|---|---|
| §12.1 op grid, 3-way (portable / reference IR / threaded) | 75,825 cases, 0 mismatched (40 NaN+NaN choices, same cases for both) | 75,825 cases, 0 mismatched (24 NaN+NaN choices) | — |
| §12.2–12.4 `--diff` (62 files; vm-reg, vm-reg-ref and all stage-1 modes; profile build too) | 62/62 bit-exact | 62/62 bit-exact | bench 7 scripts `portable,vm-goto-fpreg,vm-reg,cpp`, 2 runs: all `bit-exact ok` |
| §12.7 `jsfxvmdiff` (ASan + UBSan, `-fork=6`) | 7 runs, ~1.6 h wall ≈ 9.5 CPU-hours, ~0.63 M executions, coverage 8,655 edges, corpus 3,372. Since the last executor change (d6b26a0): 1,806 s + 2,420 s (≈ 7 CPU-hours, 502,798 executions), **no vm-reg/portable mismatch**; the only finding in that window was a portable-UB input (deviation 4) | — | — |
| `musttail` codegen (Apple clang -Os, `objdump -d` of `ETVMHandlers.o`) | — | every arithmetic / filtered-store / `Mov` / `Filt` / branch / loop-counter / compare handler and the megabuf fast paths are frameless leaves ending in `ldr x2, [x0, #k]!; br x2`; only handlers that call out (libm, API, gmem, megabuf slow paths, `Ret`) set up a frame | — |

Findings and fixes during the fuzz runs (each fixed in the executor/harness, the oracle unchanged): UBSan `function`
on API calls (deviation 5); harness non-determinism from uninitialised user stacks (deviation 3); two portable-UB
inputs, one of them uninitialised WDL bytecode (deviation 4); fork-mode crash files not failing the run, and fork
mode exiting 70 when its last job timed out although timeouts are ignored (deviation 8; run.sh now treats 70 without
new crash files as success). No mismatch between vm-reg and portable was found. Timeouts (72 in the last run) are
nested loops at the 1,048,576 cap under ASan; replaying 8 of them with a 180 s limit, 7 finished bit-exact, the
longest spends its time in a `while` running to the cap every frame (portable 1.9 s, vm-reg 9.9 s per block under
ASan, but vm-reg 2.4× faster than portable on the same loop without sanitizers).

### 16.4 Measured numbers (median µs per 256-frame block)
Speedups are portable / vm-reg, vm-goto-fpreg / vm-reg and wdl-jit / vm-reg (> 1 = vm-reg faster); `x cpp` =
vm-reg / cpp. JSON: `docs/bench/2026-10-07-s2-*` (Mac: `cli-{Os,O3}-{portable,jit}`; iPhone: `iphone16-beta-run{1,2}`;
coverage: `s2-vm-coverage-mac-m1-Os`). During the Mac runs a macOS service (`ANECompilerService`) kept one core busy;
the bench interleaves variants every 16 blocks, so ratios are unaffected.

**M1 CLI -Os** (git d6b26a0)

| script | portable | vm-goto-fpreg | vm-reg | vs portable | vs fpreg | x cpp | cpp | wdl-jit | vs jit |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| gain | 4.2 | 2.3 | 1.9 | 2.22× | 1.24× | 5.0 | 0.4 | 9.4 | 5.00× |
| filter_drive | 42.5 | 27.8 | 14.3 | 2.97× | 1.94× | 12.2 | 1.2 | 16.1 | 1.13× |
| stereo_delay | 37.3 | 26.5 | 10.6 | 3.52× | 2.50× | 7.9 | 1.3 | 15.3 | 1.44× |
| slow | 356.6 | 174.2 | 177.0 | 2.01× | 0.98× | 5.9 | 30.1 | 184.1 | 1.04× |
| biquad | 96.0 | 67.6 | 31.8 | 3.02× | 2.13× | 15.9 | 2.0 | 21.7 | 0.68× |
| fir | 938.8 | 573.0 | 230.9 | 4.07× | 2.48× | 5.1 | 45.7 | 125.0 | 0.54× |
| math | 104.2 | 66.3 | 50.4 | 2.07× | 1.31× | 3.2 | 15.6 | 36.7 | 0.73× |
| sum of 7 | 1579.6 | 937.7 | 516.8 | 3.06× | 1.81× | | 96.3 | | |

**M1 CLI -O3**: vm-reg within −7…+2 % of -Os per script (−7 % is gain, 1.9 → 1.8 µs; stereo_delay −4 %; the rest ±2 %; gain 1.8, fd 14.6, sd 10.1, slow 176.8, bq 31.6,
fir 231.5, math 49.7; sum 516.0); portable gains more from -O3 (sum 1466.7), so vs portable drops to 1.66–3.93×.
YSFX stays at -Os.

**iPhone 16 Beta (-Os), run 2** (run 1 in parentheses for vm-reg; run 2 is up to 18 % slower for every variant
on the long scripts (fir, math), the speedup ratios of the two runs agree within ±0.1)

| script | portable | vm-goto-fpreg | vm-reg | vs portable | vs fpreg | x cpp | cpp |
|---|---:|---:|---:|---:|---:|---:|---:|
| gain | 2.1 | 1.7 | 1.2 (1.2) | 1.70× | 1.33× | 4.3 | 0.3 |
| filter_drive | 22.5 | 16.1 | 8.2 (8.0) | 2.76× | 1.97× | 10.3 | 0.8 |
| stereo_delay | 19.3 | 13.2 | 6.6 (6.2) | 2.91× | 2.00× | 6.9 | 1.0 |
| slow | 158.2 | 114.8 | 140.4 (130.8) | 1.13× | **0.82×** | 5.7 | 24.7 |
| biquad | 58.7 | 40.5 | 19.8 (17.9) | 2.96× | 2.04× | 11.3 | 1.8 |
| fir | 479.8 | 340.3 | 210.4 (183.5) | 2.28× | 1.62× | 5.6 | 37.3 |
| math | 72.2 | 52.9 | 40.7 (34.6) | 1.77× | 1.30× | 3.1 | 13.3 |
| sum of 7 | 812.8 | 579.5 | 427.4 (382.2) | 1.90× | 1.36× | | 79.1 |

Against the S2 estimates (M1 -Os): fd 14.3 (est. 15–20), bq 31.8 (30–40), fir 230.9 (250–350), math 50.4 (45–55),
gain 1.9 (1–2) are in or better than the range; **slow 177.0 misses (120–170)**, and on the iPhone `slow` is 18 %
slower than vm-goto-fpreg. Cause: `loop(n, i += 1)` is 4 handlers per iteration (`FAdd` writing `i`, then
`IDec` → `IGt0` → `BrT`), and the last three form a dependent chain through frame slots (store → load per handler);
vm-goto-fpreg's `LOOP_END` decrements and branches in one opcode. S3's fused loop-next (and compare-branch) removes
two of the four handlers and the slot round trips. WDL JIT is still 1.4–1.9× faster than vm-reg on biquad, fir and
math (memory round trips per IR value, one dispatch per op), as the staging table expected for S2.

### 16.5 What remains (S3/S4)
- S3: fused loop-next and compare-branch (fixes `slow`, the iPhone regression vs vm-goto-fpreg), `cell OP= literal`,
  megabuf base+index, const-cell folding + constant folding (with `ETVMOps.h` shared with `glue_port.h`, the
  `invsqrt` re-baseline), load CSE / store→load forwarding, temp promotion, pure CSE; passes switchable for bisecting
  (`ETVM_PASSES`).
- S4: tier-2 generated arithmetic trees and tier-3 corpus kernels with BURS selection (needs the external corpus for
  `mine_shapes.py`), select speculation, typed io descriptor for framing (removes the two `pre/post` calls per frame;
  `gain` is mostly that).
- Still open from S1: external corpus (real fallback rate), untested opcodes (§15.5), and the audit of building
  programs in `ysfx_set_eel_exec_mode` against a running audio thread — required before vm-reg can be a user-visible
  option; the §12.9 gate (24 CPU-hours of `jsfxvmdiff` after the last semantic change, no script > 5 % slower than
  the stage-1 default) is not met (`slow` on iPhone).

### 16.6 Review of S1+S2 (2026-10-07, after 764d161)
Read the lifter, selector and handlers against `GLUE_CALL_CODE` (operand order of every op, `p1 = p2` before the
read in `*_OP`, MIN/MAX by reference, varparm array order, loop/while counter and wtp save/restore, top-level vs FCALL
`RET`, user-stack arithmetic, MEGABUF/GMEGABUF immediates and slow path, denormal filter placement incl. the `_FAST`
forms). Selector invariants checked by hand: a folded `LoadCell` is read where its user executes (a fused head reads at
its tail; only non-executing instructions lie between); a direct destination is rejected when the cell is read (also by
a folded user) or written between the producer and the store; fusion never crosses an executing instruction; a phi is
coalesced only with a latch value defined after the phi's last use in that block (EEL CFGs are structured, so no
inner-loop path re-reads the phi); local slots are freed at the last use and every handler reads all operands before
writing. No defect found.

Added `Tools/jsfx-bench/diff/vm_edge.jsfx`: in-expression read-then-write of the same variable (assign, `op=`,
`?:`/`min`/`max` lvalues, by-reference user functions, FCALL'd big functions, user stack and API writes such as
`mem_get_values`/`stack_pop`/`stack_exch`), loop/while counts (negative, fractional, NaN, capped), out-of-range
megabuf, denormal/NaN/Inf into filtered stores, out-of-range shifts / `%` / bit ops, and four opcodes the corpus never
reached (`DIV_OP_FAST`, `BNOT`, `PUSH_P1PTR_AS_VALUE`, `GENERIC2PARM`). `--diff`: bit-exact for every mode on Linux
x86-64 (-Os, -O3, profile) and M1 (-O3, profile, and an **app-like -Os build** where ysfx/WDL is compiled without
`-fno-strict-float-cast-overflow` and only Sources/JSFXVM has it, as in project.yml; its §12.1 grid is also 0 mismatched,
24 NaN+NaN). `jsfxvmdiff` with the new seed, 915 s × 6 jobs: 104,138 runs, no mismatch. `jsfxexec` (default / portable / vm-reg, with the
run.sh crash-file check of deviation 8), 432 s × 6 jobs: 265,087 runs, no crash or mismatch. Fresh `ysfx` clone at the
pinned revision: the patch applies with `git apply` and with `patch`, and the `.old.diff` → new path of `setup.sh`
works both ways. Release: `Sources/JSFXVM` is reached only from `ETJSFXBench.cpp` (empty unless `ET_JSFX_BENCH`), the
extension does not list it; `test_check_release_binary`/`test_release_config` pass (71). The S2 tables match the
committed JSON (the executor did not change after d6b26a0); the -O3 sentence above was corrected (it said ±3 %).

Residual: (1) NaN+NaN payload choice for `+`/`*` differs from portable (§15.2; filtered stores turn NaN into 0, so it
survives only through `_FAST` stores, outputs and API arguments). (2) A program's frame is per handle: executing the
same handle from two threads at once, or rebuilding programs (`ysfx_set_eel_exec_mode(REG)` twice, `ysfx_compile`)
while the audio thread runs it, is unsafe — still the open audit of §16.5. (3) `jsfxvmdiff` skips whole inputs that
have a handle portable may run into undefined bytes (deviation 4), so those inputs' other handles are not compared.
(4) Still not executed by any corpus: `POP_P1`, `MOVE_STACKPTR_TO_P2/P3`, `SET_P2/P3_FROM_WTP`,
`PUSH_VAL_AT_P2/P3_TO_FPSTACK` (WDL only emits index 0 for the last one) and `GENERIC2XPARM_RETD` (only
`NSEEL_addfunc_varparm_ctxptr2`, which ysfx does not use).

---

## Appendix A — portable opcode → IR mapping


| Opcode | IR |
|---|---|
| NOP | — |
| RET | end of FCALL body (inline return) or program exit |
| JMP_NC / JMP_IF_P1_Z / JMP_IF_P1_NZ | Br / CondBr(PtrNonNull or bool p1) |
| MOV_FPTOP_DV c | fp.push(LoadCell(c)) |
| MOV_P1/P2/P3_DV x | pX = cell(x) (or integer count for varparm, or literal for stack ops) |
| _RESET_WTP p | wtp = p (must be the worktable base) |
| PUSH_P1 / PUSH_P1PTR_AS_VALUE | stk.push(p1) / stk.push(Load(p1)) |
| POP_P1/P2/P3 | pX = stk.pop() (must be ptr) |
| POP_VALUE_TO_ADDR c | StoreCell(c, stk.pop()) |
| MOVE_STACK / STORE_P1_TO_STACK_AT_OFFS / MOVE_STACKPTR_TO_Px | varparm area construction (pattern-matched) |
| SET_P2_FROM_P1 / SET_P3_FROM_P1 | copy |
| COPY_VALUE_AT_P1_TO_ADDR c | StoreCell(c, Load(p1)) |
| SET_Px_FROM_WTP / POP_FPSTACK_TO_WTP | pX = cell(wtp); StoreCell(wtp, fp.pop()); wtp += 8 |
| POP_FPSTACK_TO_PTR c | StoreCell(c, fp.pop()) |
| POP_FPSTACK_TOSTACK | stk.push(fp.pop()) |
| PUSH_VAL_AT_Px_TO_FPSTACK | fp.push(Load(pX)) |
| SET_P1_Z / SET_P1_NZ | p1 = false / true |
| LOOP_LOADCNT / LOOP_END | LoopInit / LoopNext (+ wtp save/restore check) |
| WHILE_SETUP / WHILE_BEGIN / WHILE_END / WHILE_CHECK_RV | WhileInit / (wtp save) / WhileNext / CondBr(p1) |
| BNOT | p1 = BNot(p1) |
| EQUAL / NOTEQUAL | CmpEqClose / CmpNeClose(top2, top) |
| EQUAL_EXACT / NOTEQUAL_EXACT | CmpEq / CmpNe |
| ABOVE / BELOWEQ | CmpTopLtTop2 / CmpTopGeTop2 (exact operand roles) |
| ADD SUB MUL DIV | FAdd/FSub/FMul/FDiv(top2, top) |
| AND OR XOR / OR0 | IAnd/IOr/IXor(top, top2) per handler expression / IOr0(top) |
| ADD_OP SUB_OP MUL_OP DIV_OP (+_FAST) | StoreF/Store(p2, op(Load(p2), fp.pop())); p1 = p2 |
| AND_OP OR_OP XOR_OP MOD_OP | Store(p2, intop(Load(p2), fp.pop())); p1 = p2 |
| UMINUS ABS SQR SIGN INVSQRT | FNeg/FAbs/FSqr/FSign/InvSqrt |
| ASSIGN / ASSIGN_FAST / ASSIGN_FROMFP / ASSIGN_FAST_FROMFP | StoreF(p2, Load(p1)) / Store(p2, Load(p1)) / StoreF(p2, pop) / Store(p2, pop); p1 = p2 |
| MOD SHL SHR | IMod / IShl / IShr |
| MIN MAX | p1 = PtrMin/PtrMax(p1, p2) |
| MIN_FP MAX_FP | FMin2/FMax2 |
| FXCH / POP_FPSTACK | symbolic swap / drop |
| FCALL | inline callee (§6) |
| BOOLTOFP / FPTOBOOL / FPTOBOOL_REV | BoolToF / Truthy / Falsy |
| CFUNC_1PDD / 2PDD / 2PDDS | CallF1 / CallF2 / Store(p2, CallF2(Load(p2), pop)); p1 = p2 |
| MEGABUF / GMEGABUF | p1 = MemAddr(pop) / GMemAddr(pop) |
| GENERIC1/2/3PARM(_RETD), GENERIC2XPARM_RETD | CallG* / CallG*D / CallVarparm(X) |
| USERSTACK_* | UStack* |
| DBG_GETSTACKPTR, opcode 0, unknown | fallback |
