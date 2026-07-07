; gt_fixed8_asm.s — hand-tuned 65C02 8.8 fixed multiply for --num8 builds.
; Linked INSTEAD of gt_fixed_asm.s (the 16.16 unit) when GT_NUM8 is set; the
; C gt_fmul in gt_fixed.c is compiled out (GT_NUM8_ASM), everything else
; (fdiv/fsqrt/ffmod) stays C — division is rare, multiplies are everywhere.
;
; SEMANTICS: bit-identical to the C v1 `(int)(((long)a * b) >> 8)` — i.e.
; FLOOR (arithmetic shift), not truncate-toward-zero. Computed sign-magnitude:
;   mag = |a| * |b|            (32-bit; only bits 0..23 matter for the result)
;   res = mag >> 8, wrapped to 16 bits
;   if sign: res = (mag low byte == 0) ? -res : ~res
; The one's complement IS the floor adjust: -(x+1) == ~x, so an inexact
; negative product floors one step down. |−32768| (= −128.0) works unsigned.
;
; TWO calling conventions, one body (mirroring the 16.16 unit):
;   cdecl  int gt_fmul(int a, int b):  b in A/X, a on the C stack (popped here)
;   zp     int gt_fmul_zp(void):       operands pre-stored in _fa/_fb (ints)
;
; Each 8x8 partial is a quarter-square lookup (identical mul8 + tables as the
; 16.16 core — proven code, copied verbatim). Tier T (both |v| < 1.0, the
; velocity/decay case): ONE partial. General: four partials, the a1*b1 one
; low-byte-only (bits 24+ fall outside the wrapped 16-bit result).

        .setcpu "65C02"
        .export _gt_fmul
        .export _gt_fmul_zp
        .export _gt_fdiv
        .export _gt_fdiv_zp
        .export _fa
        .export _fb
        .importzp c_sp
        .import   incsp2

; ---------------------------------------------------------------------------
; zero page — the 16.16 unit's slice is not linked under --num8, so this is
; a net shrink (16 bytes vs its ~30).
; ---------------------------------------------------------------------------
        .segment "ZEROPAGE" : zeropage
_fa:    .res 2          ; operand a (raw, signed) — fastcall slot / cdecl target
_fb:    .res 2          ; operand b (raw, signed)
aa:     .res 2          ; |a|
bb:     .res 2          ; |b|
pr0:    .res 1          ; product byte 0 (discarded fraction — floor stickiness)
pr1:    .res 1          ; product byte 1 = result lo
pr2:    .res 1          ; product byte 2 = result hi (byte 3 wraps away)
mneg:   .res 1          ; result sign (1 = negate+floor)
mptr:   .res 2          ; mul8: indirect pointer into sqlo/sqhi
mx:     .res 1          ; mul8 operand x
my:     .res 1          ; mul8 operand y
m16:    .res 2          ; mul8 result (16-bit product)

        .segment "CODE"

; ===========================================================================
; 8.8 fixed divide: q = (a << 8) / b, truncated toward zero (C semantics of
; the reference ((long)a << 8) / b, which routed through cc65's 32-bit
; division runtime at ~1.5k cycles per call — and the num8 sqrt runs EIGHT
; of them per Newton pass). This is a classic restoring divide: 24 dividend
; bits (|a| << 8) streamed MSB-first through a 16-bit remainder, 24
; iterations, ~500 cycles worst case. Quotient bits beyond 16 saturate to
; P8's +/-0x7FFF. b == 0 saturates by sign of a (P8 rule).
; Reuses the mul unit's zp: aa=|a|, bb=|b|, pr0/pr1=quotient, mneg=sign.
; ===========================================================================
.proc _gt_fdiv
        sta     _fb+0
        stx     _fb+1
        ldy     #0
        lda     (c_sp),y
        sta     _fa+0
        iny
        lda     (c_sp),y
        sta     _fa+1
        jsr     incsp2
        ; falls through
.endproc
.proc _gt_fdiv_zp
        stz     mneg
        ; |a| -> aa, sign folded into mneg
        lda     _fa+1
        bpl     apos
        inc     mneg
        sec
        lda     #0
        sbc     _fa+0
        sta     aa+0
        lda     #0
        sbc     _fa+1
        sta     aa+1
        bra     bsign
apos:   lda     _fa+0
        sta     aa+0
        lda     _fa+1
        sta     aa+1
bsign:  ; |b| -> bb, sign folded
        lda     _fb+1
        bpl     bpos
        inc     mneg
        sec
        lda     #0
        sbc     _fb+0
        sta     bb+0
        lda     #0
        sbc     _fb+1
        sta     bb+1
        bra     bzchk
bpos:   lda     _fb+0
        sta     bb+0
        lda     _fb+1
        sta     bb+1
bzchk:  lda     bb+0
        ora     bb+1
        beq     sat             ; div by zero: saturate by sign
        ; ---- restoring divide, one 24-bit register: pr0:aa = (|a| << 8)
        ; with pr0 the LOW byte (zeroed = the << 8). Dividend bits exit
        ; aa+1's top straight into the remainder (my lo / pr2 hi); quotient
        ; bits fill the vacated bottom of pr0. After 24 rounds the register
        ; holds Q23..Q0 as aa+1:aa+0:pr0 — aa+1 nonzero means the quotient
        ; needs >16 bits: saturate.
        stz     pr0
        stz     my
        stz     pr2
        ldx     #24
bitlp:  asl     pr0
        rol     aa+0
        rol     aa+1
        rol     my
        rol     pr2             ; remainder <<= 1 | next dividend bit
        lda     my
        sec
        sbc     bb+0
        tay
        lda     pr2
        sbc     bb+1
        bcc     nobit           ; rem < b: quotient bit stays 0
        sta     pr2
        sty     my
        inc     pr0             ; quotient bit (bit0 just vacated)
nobit:  dex
        bne     bitlp
        lda     aa+1
        bne     sat             ; quotient > 16 bits
        ; result sign: mneg odd -> negate (truncation toward zero holds:
        ; we divided magnitudes)
        lda     mneg
        lsr
        bcs     qneg
        lda     aa+0
        bmi     sat             ; +0x8000.. not representable: saturate
        tax
        lda     pr0
        rts
qneg:   sec
        lda     #0
        sbc     pr0
        tay
        lda     #0
        sbc     aa+0
        tax
        tya
        rts
sat:    lda     mneg
        lsr
        bcs     satn
        lda     #$FF
        ldx     #$7F            ; +0x7FFF
        rts
satn:   lda     #$01
        ldx     #$80            ; -0x7FFF (P8's 0x8001)
        rts
.endproc

; ===========================================================================
; cdecl wrapper: b (A/X) -> _fb, a (C stack) -> _fa, pop, fall into the body.
; ===========================================================================
.proc _gt_fmul
        sta     _fb+0
        stx     _fb+1
        ldy     #0
        lda     (c_sp),y
        sta     _fa+0
        iny
        lda     (c_sp),y
        sta     _fa+1
        jsr     incsp2
        ; falls through
.endproc
.proc _gt_fmul_zp
        ; ---- magnitudes + sign ----
        stz     mneg
        lda     _fa+0
        sta     aa+0
        lda     _fa+1
        sta     aa+1
        bpl     @a_pos
        inc     mneg
        sec
        lda     #0
        sbc     aa+0
        sta     aa+0
        lda     #0
        sbc     aa+1
        sta     aa+1
@a_pos:
        lda     _fb+0
        sta     bb+0
        lda     _fb+1
        sta     bb+1
        bpl     @b_pos
        lda     mneg
        eor     #1
        sta     mneg
        sec
        lda     #0
        sbc     bb+0
        sta     bb+0
        lda     #0
        sbc     bb+1
        sta     bb+1
@b_pos:
        ; ---- partial a0*b0 (always needed) ----
        lda     aa+0
        sta     mx
        lda     bb+0
        sta     my
        jsr     mul8
        lda     m16+0
        sta     pr0
        lda     m16+1
        sta     pr1

        ; ---- tier: both magnitudes < 1.0? one partial was the whole product
        lda     aa+1
        ora     bb+1
        bne     @general
        stz     pr2
        bra     @sign

@general:
        stz     pr2
        ; ---- a0*b1 at offset 1 ----
        lda     aa+0
        sta     mx
        lda     bb+1
        sta     my
        jsr     mul8
        clc
        lda     pr1
        adc     m16+0
        sta     pr1
        lda     pr2
        adc     m16+1
        sta     pr2             ; carry out = product bit 24+: wraps away
        ; ---- a1*b0 at offset 1 ----
        lda     aa+1
        sta     mx
        lda     bb+0
        sta     my
        jsr     mul8
        clc
        lda     pr1
        adc     m16+0
        sta     pr1
        lda     pr2
        adc     m16+1
        sta     pr2
        ; ---- a1*b1 at offset 2: low byte only ----
        lda     aa+1
        sta     mx
        lda     bb+1
        sta     my
        jsr     mul8
        clc
        lda     pr2
        adc     m16+0
        sta     pr2

@sign:
        ldy     mneg
        bne     @neg
        lda     pr1             ; result lo
        ldx     pr2             ; result hi
        rts
@neg:
        lda     pr0
        beq     @exact
        ; inexact negative: floor = -(mag>>8) - 1 = ~(mag>>8)
        lda     pr1
        eor     #$FF
        pha
        lda     pr2
        eor     #$FF
        tax
        pla
        rts
@exact: ; exact negative: plain two's-complement negate
        sec
        lda     #0
        sbc     pr1
        pha
        lda     #0
        sbc     pr2
        tax
        pla
        rts
.endproc

; ---------------------------------------------------------------------------
; mul8: 16-bit unsigned product of mx * my via quarter squares — copied
; VERBATIM from the proven 16.16 unit (gt_fixed_asm.s). Clobbers A,Y.
; ---------------------------------------------------------------------------
.export mul8            ; label the hot helper: profiles symbolicate honestly
.proc mul8
        lda     #<sqlo
        sta     mptr+0
        lda     #>sqlo
        sta     mptr+1          ; mptr -> sqlo
        clc
        lda     mx
        adc     my              ; A = (mx+my) low 8 bits; C = bit8 of the sum
        tay
        bcc     @s_lo
        inc     mptr+1          ; sum >= 256: point one page higher
@s_lo:
        lda     (mptr),y        ; sqlo[s]
        sta     m16+0
        lda     mptr+1
        clc
        adc     #2
        sta     mptr+1          ; rebase sqlo -> sqhi (+2 pages)
        lda     (mptr),y        ; sqhi[s]
        sta     m16+1           ; m16 = sq[mx+my]

        sec
        lda     mx
        sbc     my
        bcs     @d_pos
        eor     #$FF
        adc     #1              ; A = |mx-my|
@d_pos:
        tay
        sec
        lda     m16+0
        sbc     sqlo,y
        sta     m16+0
        lda     m16+1
        sbc     sqhi,y
        sta     m16+1           ; m16 -= sq[|mx-my|]
        rts
.endproc

; ===========================================================================
; quarter-square tables — identical to the 16.16 unit's (that unit is not
; linked under --num8, so no duplication in any build).
; ===========================================================================
        .segment "RODATA"
sqlo:
        .byte $00,$00,$01,$02,$04,$06,$09,$0c,$10,$14,$19,$1e,$24,$2a,$31,$38
        .byte $40,$48,$51,$5a,$64,$6e,$79,$84,$90,$9c,$a9,$b6,$c4,$d2,$e1,$f0
        .byte $00,$10,$21,$32,$44,$56,$69,$7c,$90,$a4,$b9,$ce,$e4,$fa,$11,$28
        .byte $40,$58,$71,$8a,$a4,$be,$d9,$f4,$10,$2c,$49,$66,$84,$a2,$c1,$e0
        .byte $00,$20,$41,$62,$84,$a6,$c9,$ec,$10,$34,$59,$7e,$a4,$ca,$f1,$18
        .byte $40,$68,$91,$ba,$e4,$0e,$39,$64,$90,$bc,$e9,$16,$44,$72,$a1,$d0
        .byte $00,$30,$61,$92,$c4,$f6,$29,$5c,$90,$c4,$f9,$2e,$64,$9a,$d1,$08
        .byte $40,$78,$b1,$ea,$24,$5e,$99,$d4,$10,$4c,$89,$c6,$04,$42,$81,$c0
        .byte $00,$40,$81,$c2,$04,$46,$89,$cc,$10,$54,$99,$de,$24,$6a,$b1,$f8
        .byte $40,$88,$d1,$1a,$64,$ae,$f9,$44,$90,$dc,$29,$76,$c4,$12,$61,$b0
        .byte $00,$50,$a1,$f2,$44,$96,$e9,$3c,$90,$e4,$39,$8e,$e4,$3a,$91,$e8
        .byte $40,$98,$f1,$4a,$a4,$fe,$59,$b4,$10,$6c,$c9,$26,$84,$e2,$41,$a0
        .byte $00,$60,$c1,$22,$84,$e6,$49,$ac,$10,$74,$d9,$3e,$a4,$0a,$71,$d8
        .byte $40,$a8,$11,$7a,$e4,$4e,$b9,$24,$90,$fc,$69,$d6,$44,$b2,$21,$90
        .byte $00,$70,$e1,$52,$c4,$36,$a9,$1c,$90,$04,$79,$ee,$64,$da,$51,$c8
        .byte $40,$b8,$31,$aa,$24,$9e,$19,$94,$10,$8c,$09,$86,$04,$82,$01,$80
        .byte $00,$80,$01,$82,$04,$86,$09,$8c,$10,$94,$19,$9e,$24,$aa,$31,$b8
        .byte $40,$c8,$51,$da,$64,$ee,$79,$04,$90,$1c,$a9,$36,$c4,$52,$e1,$70
        .byte $00,$90,$21,$b2,$44,$d6,$69,$fc,$90,$24,$b9,$4e,$e4,$7a,$11,$a8
        .byte $40,$d8,$71,$0a,$a4,$3e,$d9,$74,$10,$ac,$49,$e6,$84,$22,$c1,$60
        .byte $00,$a0,$41,$e2,$84,$26,$c9,$6c,$10,$b4,$59,$fe,$a4,$4a,$f1,$98
        .byte $40,$e8,$91,$3a,$e4,$8e,$39,$e4,$90,$3c,$e9,$96,$44,$f2,$a1,$50
        .byte $00,$b0,$61,$12,$c4,$76,$29,$dc,$90,$44,$f9,$ae,$64,$1a,$d1,$88
        .byte $40,$f8,$b1,$6a,$24,$de,$99,$54,$10,$cc,$89,$46,$04,$c2,$81,$40
        .byte $00,$c0,$81,$42,$04,$c6,$89,$4c,$10,$d4,$99,$5e,$24,$ea,$b1,$78
        .byte $40,$08,$d1,$9a,$64,$2e,$f9,$c4,$90,$5c,$29,$f6,$c4,$92,$61,$30
        .byte $00,$d0,$a1,$72,$44,$16,$e9,$bc,$90,$64,$39,$0e,$e4,$ba,$91,$68
        .byte $40,$18,$f1,$ca,$a4,$7e,$59,$34,$10,$ec,$c9,$a6,$84,$62,$41,$20
        .byte $00,$e0,$c1,$a2,$84,$66,$49,$2c,$10,$f4,$d9,$be,$a4,$8a,$71,$58
        .byte $40,$28,$11,$fa,$e4,$ce,$b9,$a4,$90,$7c,$69,$56,$44,$32,$21,$10
        .byte $00,$f0,$e1,$d2,$c4,$b6,$a9,$9c,$90,$84,$79,$6e,$64,$5a,$51,$48
        .byte $40,$38,$31,$2a,$24,$1e,$19,$14,$10,$0c,$09,$06,$04,$02,$01,$00
sqhi:
        .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        .byte $01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$02,$02
        .byte $02,$02,$02,$02,$02,$02,$02,$02,$03,$03,$03,$03,$03,$03,$03,$03
        .byte $04,$04,$04,$04,$04,$04,$04,$04,$05,$05,$05,$05,$05,$05,$05,$06
        .byte $06,$06,$06,$06,$06,$07,$07,$07,$07,$07,$07,$08,$08,$08,$08,$08
        .byte $09,$09,$09,$09,$09,$09,$0a,$0a,$0a,$0a,$0a,$0b,$0b,$0b,$0b,$0c
        .byte $0c,$0c,$0c,$0c,$0d,$0d,$0d,$0d,$0e,$0e,$0e,$0e,$0f,$0f,$0f,$0f
        .byte $10,$10,$10,$10,$11,$11,$11,$11,$12,$12,$12,$12,$13,$13,$13,$13
        .byte $14,$14,$14,$15,$15,$15,$15,$16,$16,$16,$17,$17,$17,$18,$18,$18
        .byte $19,$19,$19,$19,$1a,$1a,$1a,$1b,$1b,$1b,$1c,$1c,$1c,$1d,$1d,$1d
        .byte $1e,$1e,$1e,$1f,$1f,$1f,$20,$20,$21,$21,$21,$22,$22,$22,$23,$23
        .byte $24,$24,$24,$25,$25,$25,$26,$26,$27,$27,$27,$28,$28,$29,$29,$29
        .byte $2a,$2a,$2b,$2b,$2b,$2c,$2c,$2d,$2d,$2d,$2e,$2e,$2f,$2f,$30,$30
        .byte $31,$31,$31,$32,$32,$33,$33,$34,$34,$35,$35,$35,$36,$36,$37,$37
        .byte $38,$38,$39,$39,$3a,$3a,$3b,$3b,$3c,$3c,$3d,$3d,$3e,$3e,$3f,$3f
        .byte $40,$40,$41,$41,$42,$42,$43,$43,$44,$44,$45,$45,$46,$46,$47,$47
        .byte $48,$48,$49,$49,$4a,$4a,$4b,$4c,$4c,$4d,$4d,$4e,$4e,$4f,$4f,$50
        .byte $51,$51,$52,$52,$53,$53,$54,$54,$55,$56,$56,$57,$57,$58,$59,$59
        .byte $5a,$5a,$5b,$5c,$5c,$5d,$5d,$5e,$5f,$5f,$60,$60,$61,$62,$62,$63
        .byte $64,$64,$65,$65,$66,$67,$67,$68,$69,$69,$6a,$6a,$6b,$6c,$6c,$6d
        .byte $6e,$6e,$6f,$70,$70,$71,$72,$72,$73,$74,$74,$75,$76,$76,$77,$78
        .byte $79,$79,$7a,$7b,$7b,$7c,$7d,$7d,$7e,$7f,$7f,$80,$81,$82,$82,$83
        .byte $84,$84,$85,$86,$87,$87,$88,$89,$8a,$8a,$8b,$8c,$8d,$8d,$8e,$8f
        .byte $90,$90,$91,$92,$93,$93,$94,$95,$96,$96,$97,$98,$99,$99,$9a,$9b
        .byte $9c,$9d,$9d,$9e,$9f,$a0,$a0,$a1,$a2,$a3,$a4,$a4,$a5,$a6,$a7,$a8
        .byte $a9,$a9,$aa,$ab,$ac,$ad,$ad,$ae,$af,$b0,$b1,$b2,$b2,$b3,$b4,$b5
        .byte $b6,$b7,$b7,$b8,$b9,$ba,$bb,$bc,$bd,$bd,$be,$bf,$c0,$c1,$c2,$c3
        .byte $c4,$c4,$c5,$c6,$c7,$c8,$c9,$ca,$cb,$cb,$cc,$cd,$ce,$cf,$d0,$d1
        .byte $d2,$d3,$d4,$d4,$d5,$d6,$d7,$d8,$d9,$da,$db,$dc,$dd,$de,$df,$e0
        .byte $e1,$e1,$e2,$e3,$e4,$e5,$e6,$e7,$e8,$e9,$ea,$eb,$ec,$ed,$ee,$ef
        .byte $f0,$f1,$f2,$f3,$f4,$f5,$f6,$f7,$f8,$f9,$fa,$fb,$fc,$fd,$fe,$ff

; ---------------------------------------------------------------------------
; _gt_fsqrt — 8.8 square root, restoring (division-free).
;
; The C version seeds from a LUT and runs two Newton steps = two ~1k-cycle
; divides; racing carts take a sqrt every frame for |v|. This is the classic
; two-bits-per-iteration restoring root on the 24-bit radicand (x << 8):
; 12 iterations, ~550 cycles, exact integer sqrt (the Newton version was
; already within 1 lsb of it).
;   int gt_fsqrt(int x)  — cdecl-in-A/X fastcall single arg (cc65 fastcall:
;   arg in A/X), returns A/X. x <= 0 returns 0.
; ---------------------------------------------------------------------------
        .export _gt_fsqrt
sq_v:   .res 0
.segment "ZEROPAGE" : zeropage
sq_v0:  .res 1          ; radicand, little-endian (x << 8: v0 = 0 initially)
sq_v1:  .res 1
sq_v2:  .res 1
sq_rem: .res 2
sq_rt:  .res 2
sq_i:   .res 1

.segment "CODE"
.proc _gt_fsqrt
        cpx     #$80
        bcc     :+
        lda     #0
        tax
        rts                     ; x < 0 -> 0
:       sta     sq_v1           ; v = x << 8
        stx     sq_v2
        stz     sq_v0
        stz     sq_rem
        stz     sq_rem+1
        stz     sq_rt
        stz     sq_rt+1
        lda     #12
        sta     sq_i
loop:   ; rem = (rem << 2) | (v >> 22); v <<= 2   (24-bit v: top bits from v2)
        asl     sq_v0
        rol     sq_v1
        rol     sq_v2
        rol     sq_rem
        rol     sq_rem+1
        asl     sq_v0
        rol     sq_v1
        rol     sq_v2
        rol     sq_rem
        rol     sq_rem+1
        ; root <<= 1
        asl     sq_rt
        rol     sq_rt+1
        ; if root < rem: rem -= root + 1; root += 2
        lda     sq_rt+1
        cmp     sq_rem+1
        bcc     take
        bne     skip
        lda     sq_rt
        cmp     sq_rem
        bcs     skip
take:   ; rem -= root + 1
        sec
        lda     sq_rem
        sbc     sq_rt
        sta     sq_rem
        lda     sq_rem+1
        sbc     sq_rt+1
        sta     sq_rem+1
        ; the +1: one more off rem
        lda     sq_rem
        bne     :+
        dec     sq_rem+1
:       dec     sq_rem
        ; root += 2
        lda     sq_rt
        clc
        adc     #2
        sta     sq_rt
        bcc     skip
        inc     sq_rt+1
skip:   dec     sq_i
        bne     loop
        ; result = root >> 1
        lsr     sq_rt+1
        ror     sq_rt
        lda     sq_rt
        ldx     sq_rt+1
        rts
.endproc
