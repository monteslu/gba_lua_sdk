; ---------------------------------------------------------------------------
; gt_circ — circle fill/outline staging in 65C02.
;
; cherry-bomb's explosion discs and shockwave rings spent ~26k/frame going
; through the C midpoint loop + per-span/per-point staging calls (circfill_z
; 6.2k + hspan 7.2k + circ_z 5.1k + pset_raw 7.7k in the fire profile).
; Same algorithm here, staged straight into the blit ring: ~45 cycles a
; span/point instead of ~300. The BLITTER still fills the pixels.
;
; zp contract (set by the C wrappers in gt_api.c):
;   cc_x (s16) = screen cx (camera applied)   cc_y (s16) = screen cy
;   cc_r (u8)  = radius 1..127                cc_c (u8) = ~color (staged form)
; Fill overdraws the 45-degree crossover rows like the C version did —
; harmless (same pixels, still one blit each).
; ---------------------------------------------------------------------------
.export _gt_circf_z, _gt_circo_z
.export _cc_x, _cc_y, _cc_r, _cc_c
.import _gt_q, _gt_qhead, _gt_qtail, _gt_q_pump, _gt_draw_mode
.PC02

QF_RECT = $CD                  ; NMI|ENABLE|IRQ|COLORFILL|OPAQUE

.segment "ZEROPAGE" : zeropage
_cc_x:  .res 2
_cc_y:  .res 2
_cc_r:  .res 1
_cc_c:  .res 1
cc_bx:  .res 1                  ; bresenham x (starts at r)
cc_by:  .res 1                  ; bresenham y (starts at 0)
cc_d:   .res 2                  ; decision (s16)
cc_t:   .res 2                  ; scratch s16
cc_x0:  .res 1                  ; clipped span left
cc_w:   .res 1                  ; clipped span width
cc_row: .res 1                  ; clipped row

.segment "CODE"

; ---- span helper: stage [cx-A, cx+A] on row (cc_y + Y-as-signed-offset) --
; in: A = half-width (0..127), X = row offset sign/value: we pass the row
; as cc_t2... simpler contract: caller sets cc_row (already validated) and
; calls with A = half-width. Uses cc_x0/cc_w.
span:   ; x0 = cc_x - A ; x1 = cc_x + A -> clip to 0..127, skip when outside
        sta     cc_w            ; borrow: half-width
        ; x1 = cc_x + hw
        clc
        adc     _cc_x
        sta     cc_t
        lda     _cc_x+1
        adc     #0
        bmi     @skip           ; x1 < 0: fully left
        bne     @xr             ; x1 > 255: clamp right edge
        lda     cc_t
        bpl     @x1ok
@xr:    lda     #127
@x1ok:  sta     cc_t+1          ; cc_t+1 = clipped x1 (0..127)
        ; x0 = cc_x - hw
        sec
        lda     _cc_x
        sbc     cc_w
        sta     cc_t
        lda     _cc_x+1
        sbc     #0
        bmi     @xl             ; x0 < 0: clamp to 0
        bne     @skip           ; x0 > 255: fully right
        lda     cc_t
        bmi     @skip           ; 128..255: fully right
        bra     @x0ok
@xl:    lda     #0
@x0ok:  sta     cc_x0
        ; width = x1 - x0 + 1
        sec
        lda     cc_t+1
        sbc     cc_x0
        bmi     @skip
        inc     a
        sta     cc_w
        ; ---- claim + stage ----
@slot:  lda     _gt_qhead
        clc
        adc     #8
        cmp     _gt_qtail
        bne     @free
        jsr     _gt_q_pump
        bra     @slot
@free:  ldx     _gt_qhead
        lda     #QF_RECT
        sta     _gt_q+0,x
        lda     cc_x0
        sta     _gt_q+1,x
        lda     cc_row
        sta     _gt_q+2,x
        stz     _gt_q+3,x
        stz     _gt_q+4,x
        lda     cc_w
        sta     _gt_q+5,x
        lda     #1
        sta     _gt_q+6,x
        lda     _cc_c
        sta     _gt_q+7,x
        txa
        clc
        adc     #8
        sta     _gt_qhead
        jsr     _gt_q_pump
@skip:  rts

; ---- row validate: A = signed offset from cy (as s8 in A with X=sign? --
; contract: cc_t holds the s16 row; returns C set + cc_row when visible
rowok:  ; cc_t = row (s16) -> cc_row when 0..127
        lda     cc_t+1
        bne     @no
        lda     cc_t
        bmi     @no
        sta     cc_row
        sec
        rts
@no:    clc
        rts

; row = cy + A (A unsigned 0..127)
rowadd: clc
        adc     _cc_y
        sta     cc_t
        lda     _cc_y+1
        adc     #0
        sta     cc_t+1
        bra     rowok
; row = cy - A
rowsub: sta     cc_t
        sec
        lda     _cc_y
        sbc     cc_t
        sta     cc_t
        lda     _cc_y+1
        sbc     #0
        sta     cc_t+1
        bra     rowok

; ---------------------------------------------------------------------------
; filled circle: spans at (±bx, ±by) and (±by, ±bx)
; ---------------------------------------------------------------------------
.proc _gt_circf_z
        stz     _gt_draw_mode
        lda     _cc_r
        sta     cc_bx
        stz     cc_by
        ; d = 1 - r
        sec
        lda     #1
        sbc     _cc_r
        sta     cc_d
        lda     #0
        sbc     #0
        sta     cc_d+1
loop:   ; while (by <= bx)
        lda     cc_by
        cmp     cc_bx
        beq     :+
        bcc     :+
        jmp     done
:       ; spans: row cy+by width bx ; row cy-by (if by) width bx
        lda     cc_by
        jsr     rowadd
        bcc     :+
        lda     cc_bx
        jsr     span
:       lda     cc_by
        beq     @mid
        lda     cc_by
        jsr     rowsub
        bcc     @mid
        lda     cc_bx
        jsr     span
@mid:   ; d < 0 ? d += 2y+3 : (crossover spans; d += 2(y-x)+5; --x)
        lda     cc_d+1
        bmi     @grow
        ; crossover: rows cy+bx / cy-bx with width by (skip when bx==by:
        ; those rows are the ones just drawn)
        lda     cc_bx
        cmp     cc_by
        beq     @adj
        lda     cc_bx
        jsr     rowadd
        bcc     :+
        lda     cc_by
        jsr     span
:       lda     cc_bx
        jsr     rowsub
        bcc     @adj
        lda     cc_by
        jsr     span
@adj:   ; d += ((by - bx) << 1) + 5 ; --bx
        sec
        lda     cc_by
        sbc     cc_bx           ; s8, negative
        sta     cc_t
        lda     #$FF            ; sign-extend (by < bx always here)
        sta     cc_t+1
        asl     cc_t
        rol     cc_t+1
        clc
        lda     cc_t
        adc     #5
        sta     cc_t
        lda     cc_t+1
        adc     #0
        sta     cc_t+1
        clc
        lda     cc_d
        adc     cc_t
        sta     cc_d
        lda     cc_d+1
        adc     cc_t+1
        sta     cc_d+1
        dec     cc_bx
        bra     @next
@grow:  ; d += (by << 1) + 3
        lda     cc_by
        asl     a               ; by <= 63 in practice; 2*by fits a byte
        clc
        adc     #3
        clc
        adc     cc_d
        sta     cc_d
        lda     cc_d+1
        adc     #0
        sta     cc_d+1
@next:  inc     cc_by
        jmp     loop
done:   rts
.endproc

; ---------------------------------------------------------------------------
; circle outline: 1x1 spans at the 8 octant points
; ---------------------------------------------------------------------------
.proc _gt_circo_z
        stz     _gt_draw_mode
        lda     _cc_r
        sta     cc_bx
        stz     cc_by
        sec
        lda     #1
        sbc     _cc_r
        sta     cc_d
        lda     #0
        sbc     #0
        sta     cc_d+1
loop:   lda     cc_by
        cmp     cc_bx
        beq     :+
        bcc     :+
        jmp     done
:       ; points (±bx, ±by): rows cy±by, dots at cx±bx
        lda     cc_by
        jsr     rowadd
        bcc     :+
        lda     cc_bx
        jsr     dots
:       lda     cc_by
        beq     @swap
        lda     cc_by
        jsr     rowsub
        bcc     @swap
        lda     cc_bx
        jsr     dots
@swap:  ; points (±by, ±bx): rows cy±bx, dots at cx±by (skip when bx==by)
        lda     cc_bx
        cmp     cc_by
        beq     @adj
        lda     cc_bx
        jsr     rowadd
        bcc     :+
        lda     cc_by
        jsr     dots
:       lda     cc_bx
        jsr     rowsub
        bcc     @adj
        lda     cc_by
        jsr     dots
@adj:   lda     cc_d+1
        bmi     @grow
        sec
        lda     cc_by
        sbc     cc_bx
        sta     cc_t
        lda     #$FF
        sta     cc_t+1
        asl     cc_t
        rol     cc_t+1
        clc
        lda     cc_t
        adc     #5
        sta     cc_t
        lda     cc_t+1
        adc     #0
        sta     cc_t+1
        clc
        lda     cc_d
        adc     cc_t
        sta     cc_d
        lda     cc_d+1
        adc     cc_t+1
        sta     cc_d+1
        dec     cc_bx
        bra     @next
@grow:  lda     cc_by
        asl     a
        clc
        adc     #3
        clc
        adc     cc_d
        sta     cc_d
        lda     cc_d+1
        adc     #0
        sta     cc_d+1
@next:  inc     cc_by
        jmp     loop
done:   rts

; two 1px dots on cc_row at cx±A (A in accumulator)
dots:   sta     cc_t
        ; right dot: x = cx + A
        clc
        adc     _cc_x
        tax
        lda     _cc_x+1
        adc     #0
        bne     @left           ; offscreen right (or <0 via hi)
        txa
        bmi     @left
        jsr     dot
@left:  ; left dot: x = cx - A (skip the duplicate when A == 0)
        lda     cc_t
        beq     @done
        sec
        lda     _cc_x
        sbc     cc_t
        tax
        lda     _cc_x+1
        sbc     #0
        bne     @done
        txa
        bmi     @done
        jsr     dot
@done:  rts

; stage a 1x1 at column A on cc_row
dot:    sta     cc_x0
@slot:  lda     _gt_qhead
        clc
        adc     #8
        cmp     _gt_qtail
        bne     @free
        jsr     _gt_q_pump
        bra     @slot
@free:  ldx     _gt_qhead
        lda     #QF_RECT
        sta     _gt_q+0,x
        lda     cc_x0
        sta     _gt_q+1,x
        lda     cc_row
        sta     _gt_q+2,x
        stz     _gt_q+3,x
        stz     _gt_q+4,x
        lda     #1
        sta     _gt_q+5,x
        sta     _gt_q+6,x
        lda     _cc_c
        sta     _gt_q+7,x
        txa
        clc
        adc     #8
        sta     _gt_qhead
        jmp     _gt_q_pump
.endproc
