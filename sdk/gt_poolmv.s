; ---------------------------------------------------------------------------
; gt.pool_move — bulk pool integration: x[i] += sx[i], y[i] += sy[i] for
; every used slot, optionally with the shift-damping cherry-bomb's particles
; use (v -= v>>3 + v>>5, i.e. *0.84375). ~35 cycles per live entity vs ~250
; through the compiler; a shmup frame moves 80-100 entities.
;   pm_x/pm_y/pm_sx/pm_sy: int arrays (pool SoA fields, stride 2)
;   pm_used: byte array (pool used[] flags)   pm_n: slot count (hi watermark)
;   pm_mode: 0 plain, 1 damp velocities after the move
; ---------------------------------------------------------------------------
.export _gt_poolmv_z
.export _pm_x, _pm_y, _pm_sx, _pm_sy, _pm_used, _pm_n, _pm_mode
.PC02

.segment "ZEROPAGE" : zeropage
_pm_x:    .res 2
_pm_y:    .res 2
_pm_sx:   .res 2
_pm_sy:   .res 2
_pm_used: .res 2
_pm_n:    .res 1
_pm_mode: .res 1
pm_i:     .res 1
pm_o:     .res 1                ; element byte offset (i*2)
pm_t:     .res 2

.segment "CODE"

.proc _gt_poolmv_z
        stz     pm_i
loop:   lda     pm_i
        cmp     _pm_n
        bne     :+
        rts
:       tay
        lda     (_pm_used),y
        bne     live
        bra     next
live:   tya
        asl     a
        sta     pm_o
        tay
        ; x += sx
        lda     (_pm_sx),y
        sta     pm_t
        clc
        adc     (_pm_x),y
        sta     (_pm_x),y
        iny
        lda     (_pm_sx),y
        sta     pm_t+1
        adc     (_pm_x),y
        sta     (_pm_x),y
        ; y += sy
        ldy     pm_o
        lda     (_pm_sy),y
        sta     pm_t
        clc
        adc     (_pm_y),y
        sta     (_pm_y),y
        iny
        lda     (_pm_sy),y
        sta     pm_t+1
        adc     (_pm_y),y
        sta     (_pm_y),y
        ; damp?
        lda     _pm_mode
        beq     next
        ; sx -= (sx >> 3) + (sx >> 5)   (arithmetic shifts, 16-bit)
        ldy     pm_o
        lda     (_pm_sx),y
        sta     pm_t
        iny
        lda     (_pm_sx),y
        sta     pm_t+1
        jsr     damp16
        ldy     pm_o
        lda     pm_t
        sta     (_pm_sx),y
        iny
        lda     pm_t+1
        sta     (_pm_sx),y
        ldy     pm_o
        lda     (_pm_sy),y
        sta     pm_t
        iny
        lda     (_pm_sy),y
        sta     pm_t+1
        jsr     damp16
        ldy     pm_o
        lda     pm_t
        sta     (_pm_sy),y
        iny
        lda     pm_t+1
        sta     (_pm_sy),y
next:   inc     pm_i
        bra     loop
.endproc

; pm_t (s16) -= (pm_t>>3) + (pm_t>>5), arithmetic. Uses pm_d scratch.
.segment "ZEROPAGE" : zeropage
pm_d:   .res 2
pm_e:   .res 2

.segment "CODE"
.proc damp16
        ; d = t >> 3
        lda     pm_t
        sta     pm_d
        lda     pm_t+1
        sta     pm_d+1
        ldx     #3
:       cmp     #$80            ; A holds hi; carry = sign
        ror     pm_d+1
        ror     pm_d
        lda     pm_d+1
        dex
        bne     :-
        ; e = t >> 5 = d >> 2
        lda     pm_d
        sta     pm_e
        lda     pm_d+1
        sta     pm_e+1
        ldx     #2
:       cmp     #$80
        ror     pm_e+1
        ror     pm_e
        lda     pm_e+1
        dex
        bne     :-
        ; t -= d + e
        clc
        lda     pm_d
        adc     pm_e
        sta     pm_d
        lda     pm_d+1
        adc     pm_e+1
        sta     pm_d+1
        sec
        lda     pm_t
        sbc     pm_d
        sta     pm_t
        lda     pm_t+1
        sbc     pm_d+1
        sta     pm_t+1
        rts
.endproc
