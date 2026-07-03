; gt_math_stubs.s — FLASH2M fixed-bank far-call stubs for the cold gt_math unit.
;
; The banked build exiles gt_math.c (gt_fsin/gt_fcos/gt_fatan2/gt_p8_rnd/
; gt_p8_srand/gt_p8_time/gt_time_tick + the 1 KB sine table) out of the
; always-mapped FIXED bank into game bank 1 ($8000-$BFFF), reclaiming ~2.2 KB
; the quarter-square multiply tables need. These stubs live in the FIXED bank
; and own the plain public symbol names, so every caller — game code in any
; bank AND fixed-bank SDK code (gt_api's gt_endframe -> gt_time_tick,
; gt_starfield_init -> gt_p8_rnd) — links to the stub transparently. Each stub
; switches to bank 1, jsr's the real _impl function, restores the caller's
; bank, and returns.
;
; ABI: these are cc65 __fastcall__ / __near__ functions. The last argument (and
; the return value) ride in A/X, its high word in sreg; any earlier arguments
; sit on the cc65 C-stack (c_sp) in RAM. The stub touches only A/X and one BSS
; byte (via gt_bank_raw) — it never disturbs c_sp, sreg, or the C-stack RAM,
; and the bank switch only remaps the $8000-$BFFF window, so a stacked argument
; (gt_fatan2's first `long`) is preserved untouched across the switch. This is
; the same stub shape gtlua generates for cross-bank user-function calls.
;
; Callee bank is hard-wired to 1: bin/gtlua.js always compiles gt_math into
; B1CODE/B1RODATA. If that ever changes, update GT_MATH_BANK below.

.PC02
.import gt_bank_raw, gt_cur_bank
.import _gt_fsin_impl, _gt_fcos_impl, _gt_fatan2_impl
.import _gt_p8_rnd_impl, _gt_p8_srand_impl, _gt_p8_time_impl, _gt_time_tick_impl
.export _gt_fsin, _gt_fcos, _gt_fatan2
.export _gt_p8_rnd, _gt_p8_srand, _gt_p8_time, _gt_time_tick

GT_MATH_BANK = 1

.segment "BSS"
gtms_sav_a: .res 1
gtms_sav_x: .res 1

.segment "CODE"

; A stub: save A/X, push the caller's current bank, switch to bank 1, restore
; A/X, call the impl, save the return A/X, restore the caller's bank, restore
; the return A/X, rts. sreg and c_sp pass through untouched.
.macro  GT_MATH_STUB label, impl
label:
        sta     gtms_sav_a
        stx     gtms_sav_x
        lda     gt_cur_bank
        pha
        lda     #GT_MATH_BANK
        jsr     gt_bank_raw
        lda     gtms_sav_a
        ldx     gtms_sav_x
        jsr     impl
        sta     gtms_sav_a
        stx     gtms_sav_x
        pla
        jsr     gt_bank_raw
        lda     gtms_sav_a
        ldx     gtms_sav_x
        rts
.endmacro

        GT_MATH_STUB _gt_fsin,      _gt_fsin_impl
        GT_MATH_STUB _gt_fcos,      _gt_fcos_impl
        GT_MATH_STUB _gt_fatan2,    _gt_fatan2_impl
        GT_MATH_STUB _gt_p8_rnd,    _gt_p8_rnd_impl
        GT_MATH_STUB _gt_p8_srand,  _gt_p8_srand_impl
        GT_MATH_STUB _gt_p8_time,   _gt_p8_time_impl
        GT_MATH_STUB _gt_time_tick, _gt_time_tick_impl
