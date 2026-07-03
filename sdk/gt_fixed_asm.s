; gt_fixed_asm.s — hand-tuned 65C02 implementations of the 16.16 hot ops.
;
; TWO calling conventions, one shared body each:
;
;  * cdecl (long gt_fmul(long a,long b)):  b in EAX, a on the C stack. Kept for
;    call sites the emitter can't fast-path (an argument that itself contains a
;    fixed multiply/divide — the zp slots would collide mid-sequence).
;
;  * zp-fastcall (long gt_fmul_zp(void)):  both operands pre-stored by the
;    emitter into the exported zero-page longs _fa (=a) and _fb (=b); result in
;    EAX. This drops cc65's per-call marshalling — the `jsr pusheax` that spills
;    `a` to the C stack, plus the ldeaxysp/incsp juggling around it (~1K cycles
;    on the fmul microbench). The emitter stores globals straight to _fa/_fb
;    (memory->zp copies) and calls the argless entry; see compiler/emit.js.
;
; Both conventions funnel into fmul_body / fdiv_body, which read _fa/_fb. PICO-8
; semantics are preserved bit-for-bit (the closed forms are locked by
; test/fixed_asm.test.js; a ~1300-vector on-emulator brute test is the gate).
;
; cc65 cdecl ABI for `long f(long a, long b)`:
;   entry:  b is in EAX  (A=b.0 lo, X=b.1, sreg=b.2, sreg+1=b.3 hi)
;           a is on the C stack: (c_sp),0..3 = a.0..a.3
;   exit:   return long in EAX (A=lo .. sreg+1=hi); the callee pops a (incsp4)
;
; fmul uses a quarter-square lookup (two 512-byte RODATA tables, sqlo/sqhi,
; holding floor(k*k/4) split into low/high bytes). Each 8x8 product becomes two
; table lookups + a 16-bit subtract via the identity x*y = f(x+y) - f(x-y),
; f(k)=k^2/4 (exact for integers of equal parity). fdiv stays a shift-subtract
; loop (tableless).
;
; fmul:  res = neg( ( |a| * |b| ) >> 16 ), truncated to 32 bits.
;        Two paths, both bit-identical to the old shift-add core:
;          - fast: both magnitudes' hi word == 0 (the common game case:
;            velocities / trig / sub-few-unit fixed values). Then |a|,|b| are
;            16-bit, the product is 32-bit, and the 16.16 result is P>>16 built
;            from four 8x8 quarter-square products.
;          - slow: some hi word nonzero (large operands, rare). Full 32x32,
;            summing the ten 8x8 partials that reach product bits 16..47.
; fdiv:  q = neg( floor( (|a| << 16) / |b| ) ), truncated to 32 bits.
;        /0 saturates: a<0 -> $80000001, else $7FFFFFFF (P8 manual).
;        Restoring long division: 48 shift-subtract steps.

        .setcpu "65C02"
        .export _gt_fmul
        .export _gt_fdiv
        .export _gt_fmul_zp
        .export _gt_fdiv_zp
        .export _fa
        .export _fb
        .importzp c_sp, sreg
        .import   incsp4

; ---------------------------------------------------------------------------
; zero-page: _fa/_fb are the fastcall ABI slots (the emitter stores here);
; the rest is internal scratch (leaf routines; linker allocates after the cc65
; runtime zp).
; ---------------------------------------------------------------------------
        .segment "ZEROPAGE" : zeropage
_fa:    .res 4          ; operand a (raw, signed) — fastcall slot / cdecl target
_fb:    .res 4          ; operand b (raw, signed) — fastcall slot / cdecl target
aa:     .res 4          ; |a| magnitude  — fmul multiplicand / div dividend
bb:     .res 4          ; |b| magnitude  — fmul multiplier   / div divisor
pr:     .res 8          ; 64-bit product accumulator (fmul): pr[0..7], byte0 = bit0
mneg:   .res 1          ; result sign (1 = negate result)
rem:    .res 4          ; division remainder
qq:     .res 4          ; division quotient
dtmp:   .res 4          ; trial-subtract scratch (division)
; --- quarter-square multiply scratch (fmul) ---
mptr:   .res 2          ; indirect pointer into sqlo (mul8 rebases it to sqhi)
mx:     .res 1          ; mul8 operand x
my:     .res 1          ; mul8 operand y
m16:    .res 2          ; mul8 result (16-bit product of mx*my)

        .segment "CODE"

; ===========================================================================
; cdecl wrappers: copy the cc65-ABI args into _fa/_fb, pop the stack arg, then
; fall through to the shared body. (b is in EAX, a is on the C stack.)
; ===========================================================================
.proc _gt_fmul
        jsr     load_cdecl_args         ; _fa=a, _fb=b; a popped
        ; falls through
.endproc
.proc _gt_fmul_zp
        jmp     fmul_body
.endproc

.proc _gt_fdiv
        jsr     load_cdecl_args         ; _fa=a, _fb=b; a popped
        ; falls through
.endproc
.proc _gt_fdiv_zp
        jmp     fdiv_body
.endproc

; ---------------------------------------------------------------------------
; load_cdecl_args: b (EAX) -> _fb, a (C stack) -> _fa, pop a. Clobbers A,X,Y
; (X survives: not touched here). Preserves nothing else; the body reloads
; everything from _fa/_fb. Returns to the wrapper so it can fall into the body.
; ---------------------------------------------------------------------------
.proc load_cdecl_args
        sta     _fb+0
        stx     _fb+1
        lda     sreg
        sta     _fb+2
        lda     sreg+1
        sta     _fb+3
        ldy     #0
        lda     (c_sp),y
        sta     _fa+0
        iny
        lda     (c_sp),y
        sta     _fa+1
        iny
        lda     (c_sp),y
        sta     _fa+2
        iny
        lda     (c_sp),y
        sta     _fa+3
        jsr     incsp4                  ; pops a; returns here
        rts
.endproc

; ===========================================================================
; fmul_body: reads _fa/_fb, returns (|a|*|b|)>>16 with the sign of a^b in EAX.
; ===========================================================================
.proc fmul_body
        jsr     mags_and_sign           ; aa=|a|, bb=|b|, mneg=(a<0)^(b<0)

        ; clear the 8-byte product accumulator
        stz     pr+0
        stz     pr+1
        stz     pr+2
        stz     pr+3
        stz     pr+4
        stz     pr+5
        stz     pr+6
        stz     pr+7

        ; --- pick tier by operand magnitude ---
        ;   Tier A (16x16): both hi words zero  -> aa+2|aa+3==0 and bb+2|bb+3==0.
        ;   Tier B (24x24): both byte3 zero     -> aa+3==0 and bb+3==0  (|v|<256).
        ;   Tier C (32x32): otherwise.
        ; The common game case (velocities/trig, |v| a few units) is A or B.
        lda     aa+2
        ora     aa+3
        bne     @notA
        lda     bb+2
        ora     bb+3
        beq     @tierA                  ; both hi16 == 0
@notA:
        lda     aa+3
        ora     bb+3
        beq     @tierB                  ; both byte3 == 0 (< 256.0)
        jmp     @slow                   ; some byte3 nonzero -> Tier C

@tierA:
        ; ============================ TIER A: 16x16 ============================
        ; 16x16 -> 32-bit product in pr[0..3]; 16.16 result = pr>>16 (bytes 2,3),
        ; hi 16 bits are 0. Four 8x8 partials at byte offsets 0,1,1,2.
        lda     aa+0
        sta     mx
        lda     bb+0
        sta     my
        jsr     mul8                    ; a0*b0 -> offset 0
        jsr     acc0

        lda     aa+0
        sta     mx
        lda     bb+1
        sta     my
        jsr     mul8                    ; a0*b1 -> offset 1
        jsr     acc1

        lda     aa+1
        sta     mx
        lda     bb+0
        sta     my
        jsr     mul8                    ; a1*b0 -> offset 1
        jsr     acc1

        lda     aa+1
        sta     mx
        lda     bb+1
        sta     my
        jsr     mul8                    ; a1*b1 -> offset 2
        jsr     acc2

        ; result = product >> 16 : lo=pr+2, hi=pr+3, sreg/sreg+1 = 0
        lda     pr+2
        ldx     pr+3
        stz     sreg
        stz     sreg+1
        jmp     @fixsign

        ; ============================ TIER B: 24x24 ============================
        ; Both operands < 256.0 (byte3 == 0). The 48-bit product needs only the
        ; nine partials mul8(aa[i],bb[j]) with i,j in 0..2 (i+j = 0..4, reaching
        ; bits 0..47). Result = pr>>16 = bytes 2..5.
@tierB:
        ; i+j = 0
        lda     aa+0
        sta     mx
        lda     bb+0
        sta     my
        jsr     mul8
        jsr     acc0
        ; i+j = 1  (a0*b1, a1*b0)
        lda     aa+0
        sta     mx
        lda     bb+1
        sta     my
        jsr     mul8
        jsr     acc1
        lda     aa+1
        sta     mx
        lda     bb+0
        sta     my
        jsr     mul8
        jsr     acc1
        ; i+j = 2  (a0*b2, a1*b1, a2*b0)
        lda     aa+0
        sta     mx
        lda     bb+2
        sta     my
        jsr     mul8
        jsr     acc2
        lda     aa+1
        sta     mx
        lda     bb+1
        sta     my
        jsr     mul8
        jsr     acc2
        lda     aa+2
        sta     mx
        lda     bb+0
        sta     my
        jsr     mul8
        jsr     acc2
        ; i+j = 3  (a1*b2, a2*b1)
        lda     aa+1
        sta     mx
        lda     bb+2
        sta     my
        jsr     mul8
        jsr     acc3
        lda     aa+2
        sta     mx
        lda     bb+1
        sta     my
        jsr     mul8
        jsr     acc3
        ; i+j = 4  (a2*b2)
        lda     aa+2
        sta     mx
        lda     bb+2
        sta     my
        jsr     mul8
        jsr     acc4

        ; result = product >> 16 = bytes 2..5
        lda     pr+4
        sta     sreg
        lda     pr+5
        sta     sreg+1
        lda     pr+2
        ldx     pr+3
        jmp     @fixsign

        ; ============================ TIER C: 32x32 ===========================
        ; Full 32x32; accumulate the ten partials mul8(aa[i],bb[j]) at byte
        ; offset (i+j) for i+j <= 5 (i+j>=6 lands at bits >=48, above the
        ; 16..47 result window). Result = pr>>16 = bytes 2..5.
@slow:
        ; i+j = 0
        lda     aa+0
        sta     mx
        lda     bb+0
        sta     my
        jsr     mul8
        jsr     acc0
        ; i+j = 1  (a0*b1, a1*b0)
        lda     aa+0
        sta     mx
        lda     bb+1
        sta     my
        jsr     mul8
        jsr     acc1
        lda     aa+1
        sta     mx
        lda     bb+0
        sta     my
        jsr     mul8
        jsr     acc1
        ; i+j = 2  (a0*b2, a1*b1, a2*b0)
        lda     aa+0
        sta     mx
        lda     bb+2
        sta     my
        jsr     mul8
        jsr     acc2
        lda     aa+1
        sta     mx
        lda     bb+1
        sta     my
        jsr     mul8
        jsr     acc2
        lda     aa+2
        sta     mx
        lda     bb+0
        sta     my
        jsr     mul8
        jsr     acc2
        ; i+j = 3  (a0*b3, a1*b2, a2*b1, a3*b0)
        lda     aa+0
        sta     mx
        lda     bb+3
        sta     my
        jsr     mul8
        jsr     acc3
        lda     aa+1
        sta     mx
        lda     bb+2
        sta     my
        jsr     mul8
        jsr     acc3
        lda     aa+2
        sta     mx
        lda     bb+1
        sta     my
        jsr     mul8
        jsr     acc3
        lda     aa+3
        sta     mx
        lda     bb+0
        sta     my
        jsr     mul8
        jsr     acc3
        ; i+j = 4  (a1*b3, a2*b2, a3*b1)
        lda     aa+1
        sta     mx
        lda     bb+3
        sta     my
        jsr     mul8
        jsr     acc4
        lda     aa+2
        sta     mx
        lda     bb+2
        sta     my
        jsr     mul8
        jsr     acc4
        lda     aa+3
        sta     mx
        lda     bb+1
        sta     my
        jsr     mul8
        jsr     acc4
        ; i+j = 5  (a2*b3, a3*b2)
        lda     aa+2
        sta     mx
        lda     bb+3
        sta     my
        jsr     mul8
        jsr     acc5
        lda     aa+3
        sta     mx
        lda     bb+2
        sta     my
        jsr     mul8
        jsr     acc5

        ; result = product >> 16 = bytes 2..5
        lda     pr+4
        sta     sreg
        lda     pr+5
        sta     sreg+1
        lda     pr+2
        ldx     pr+3

@fixsign:
        ldy     mneg
        beq     @done
        jmp     negeax
@done:
        rts
.endproc

; ---------------------------------------------------------------------------
; acc0..acc5: add the 16-bit m16 product into the pr accumulator at byte
; offset 0..5, then propagate any carry up through pr+7 via `ripple`.
; Clobbers A,Y; preserves X.
; ---------------------------------------------------------------------------
.proc acc0
        clc
        lda     pr+0
        adc     m16+0
        sta     pr+0
        lda     pr+1
        adc     m16+1
        sta     pr+1
        bcc     :+
        ldy     #2
        jsr     ripple
:       rts
.endproc
.proc acc1
        clc
        lda     pr+1
        adc     m16+0
        sta     pr+1
        lda     pr+2
        adc     m16+1
        sta     pr+2
        bcc     :+
        ldy     #3
        jsr     ripple
:       rts
.endproc
.proc acc2
        clc
        lda     pr+2
        adc     m16+0
        sta     pr+2
        lda     pr+3
        adc     m16+1
        sta     pr+3
        bcc     :+
        ldy     #4
        jsr     ripple
:       rts
.endproc
.proc acc3
        clc
        lda     pr+3
        adc     m16+0
        sta     pr+3
        lda     pr+4
        adc     m16+1
        sta     pr+4
        bcc     :+
        ldy     #5
        jsr     ripple
:       rts
.endproc
.proc acc4
        clc
        lda     pr+4
        adc     m16+0
        sta     pr+4
        lda     pr+5
        adc     m16+1
        sta     pr+5
        bcc     :+
        ldy     #6
        jsr     ripple
:       rts
.endproc
.proc acc5
        clc
        lda     pr+5
        adc     m16+0
        sta     pr+5
        lda     pr+6
        adc     m16+1
        sta     pr+6
        bcc     :+
        ldy     #7
        jsr     ripple
:       rts
.endproc

; ripple: propagate a pending carry (C=1 on entry) into pr[Y..7]. Y is the
; first byte to bump. Preserves X; clobbers A,Y. Stops early when carry clears.
.proc ripple
@lp:    lda     pr,y
        adc     #0
        sta     pr,y
        bcc     @out
        iny
        cpy     #8
        bne     @lp
@out:   rts
.endproc

; ---------------------------------------------------------------------------
; mul8: 16-bit unsigned product of mx * my, returned in m16 (m16+0 lo, m16+1
; hi), via quarter squares:  mx*my = sq[mx+my] - sq[mx-my],  sq[k]=k^2/4.
; Uses the pair of 512-byte tables sqlo/sqhi. Clobbers A,Y; preserves X.
; ---------------------------------------------------------------------------
.proc mul8
        ; --- s = mx + my (0..510), look up sq[s] into m16 ---
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
        ; rebase mptr from sqlo -> sqhi (sqhi = sqlo + 512 = +2 pages), keeping
        ; the +1 page bump if it was applied above.
        lda     mptr+1
        clc
        adc     #2
        sta     mptr+1
        lda     (mptr),y        ; sqhi[s]
        sta     m16+1           ; m16 = sq[mx+my]

        ; --- d = |mx - my| (0..255), subtract sq[d] from m16 ---
        sec
        lda     mx
        sbc     my              ; mx - my
        bcs     @d_pos          ; C set: mx >= my, A = mx-my
        eor     #$FF
        adc     #1              ; negate: A = my - mx  (C was clear)
@d_pos:
        tay                     ; Y = |mx-my|  (0..255)
        sec
        lda     m16+0
        sbc     sqlo,y
        sta     m16+0
        lda     m16+1
        sbc     sqhi,y
        sta     m16+1           ; m16 -= sq[d]
        rts
.endproc

; ===========================================================================
; fdiv_body: reads _fa/_fb, returns floor((|a|<<16)/|b|) with sign a^b in EAX.
; /0 saturates by the sign of a.
; ===========================================================================
.proc fdiv_body
        ; --- divide by zero? (_fb == 0) -> saturate by sign of a ---
        lda     _fb+0
        ora     _fb+1
        ora     _fb+2
        ora     _fb+3
        bne     @nonzero
        bit     _fa+3           ; a<0 -> $80000001, else $7FFFFFFF
        bpl     @sat_pos
        lda     #$00
        sta     sreg
        lda     #$80
        sta     sreg+1
        ldx     #$00
        lda     #$01
        rts
@sat_pos:
        lda     #$FF
        sta     sreg
        lda     #$7F
        sta     sreg+1
        ldx     #$FF
        lda     #$FF
        rts

@nonzero:
        jsr     mags_and_sign           ; aa=|a|, bb=|b|, mneg=(a<0)^(b<0)
        ; --- restoring division: dividend = |a| << 16 (48-bit), divisor |b| ---
        stz     rem+0
        stz     rem+1
        stz     rem+2
        stz     rem+3
        stz     qq+0
        stz     qq+1
        stz     qq+2
        stz     qq+3

        ldx     #48
@dloop:
        asl     aa+0
        rol     aa+1
        rol     aa+2
        rol     aa+3            ; C = old bit31 of aa = the dividend bit
        rol     rem+0
        rol     rem+1
        rol     rem+2
        rol     rem+3
        asl     qq+0
        rol     qq+1
        rol     qq+2
        rol     qq+3
        ; trial rem - bb
        lda     rem+0
        sec
        sbc     bb+0
        sta     dtmp+0
        lda     rem+1
        sbc     bb+1
        sta     dtmp+1
        lda     rem+2
        sbc     bb+2
        sta     dtmp+2
        lda     rem+3
        sbc     bb+3
        bcc     @norestore      ; rem < bb -> keep remainder, q bit stays 0
        sta     rem+3
        lda     dtmp+2
        sta     rem+2
        lda     dtmp+1
        sta     rem+1
        lda     dtmp+0
        sta     rem+0
        inc     qq+0            ; bit0 is 0 after the asl above
@norestore:
        dex
        bne     @dloop

        lda     qq+2
        sta     sreg
        lda     qq+3
        sta     sreg+1
        lda     qq+0
        ldx     qq+1

        ldy     mneg
        beq     @dived
        jmp     negeax
@dived:
        rts
.endproc

; ===========================================================================
; helpers
; ===========================================================================

; mags_and_sign: aa=|_fa|, bb=|_fb|, mneg = (_fa<0) ^ (_fb<0). Clobbers A,Y.
.proc mags_and_sign
        lda     _fa+0
        sta     aa+0
        lda     _fa+1
        sta     aa+1
        lda     _fa+2
        sta     aa+2
        lda     _fa+3
        sta     aa+3
        lda     _fb+0
        sta     bb+0
        lda     _fb+1
        sta     bb+1
        lda     _fb+2
        sta     bb+2
        lda     _fb+3
        sta     bb+3

        stz     mneg
        bit     aa+3
        bpl     @a_pos
        inc     mneg
        jsr     neg_aa
@a_pos:
        bit     bb+3
        bpl     @b_pos
        lda     mneg
        eor     #1
        sta     mneg
        jsr     neg_bb
@b_pos:
        rts
.endproc

; neg_aa / neg_bb: 32-bit two's-complement negate in place.
.proc neg_aa
        sec
        lda     #0
        sbc     aa+0
        sta     aa+0
        lda     #0
        sbc     aa+1
        sta     aa+1
        lda     #0
        sbc     aa+2
        sta     aa+2
        lda     #0
        sbc     aa+3
        sta     aa+3
        rts
.endproc

.proc neg_bb
        sec
        lda     #0
        sbc     bb+0
        sta     bb+0
        lda     #0
        sbc     bb+1
        sta     bb+1
        lda     #0
        sbc     bb+2
        sta     bb+2
        lda     #0
        sbc     bb+3
        sta     bb+3
        rts
.endproc

; negeax: negate the 32-bit value in EAX (A/X/sreg/sreg+1), return in EAX.
.proc negeax
        clc
        eor     #$FF
        adc     #1
        pha                     ; new A (lo)
        txa
        eor     #$FF
        adc     #0
        tax                     ; new X
        lda     sreg
        eor     #$FF
        adc     #0
        sta     sreg
        lda     sreg+1
        eor     #$FF
        adc     #0
        sta     sreg+1
        pla                     ; restore A (lo)
        rts
.endproc

; ===========================================================================
; quarter-square tables:  sq[k] = floor(k*k/4), split into low/high bytes.
; k = 0..511 (a+b tops out at 255+255=510; index 511 is unused padding).
; 512 bytes each, 1 KB total, in RODATA (the fixed bank has ample room).
; Used by mul8 to turn each 8x8 product into two lookups + a 16-bit subtract.
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
