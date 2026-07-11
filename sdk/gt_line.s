; ---------------------------------------------------------------------------
; gt_line — diagonal line CPU-poke walk in 65C02.
;
; The C run-based path (gt_api.c GT_LINE_DIAG) is optimal for near-axis-aligned
; lines (few long fill blits) but a true diagonal degenerates to one 1px blit
; per pixel (~370 cyc each -> a 40px diagonal was ~47k cyc). The C CPU-poke
; fallback cut that to ~22k but cc65 spends ~540 cyc/pixel: ~16 instructions for
; the vram_row[y][x] double-index + 16-bit Bresenham int math. This does the
; same walk in asm at ~30 cyc/pixel.
;
; VRAM is linear: pixel (x,y) lives at $4000 + (y<<7) + x, x,y in [0,127]. So
;   ptr_hi = $40 + (y >> 1)          ptr_lo = ((y & 1) << 7) | x
; recomputed fresh per pixel.
;
; This mirrors the WORKING C loop's signed Bresenham EXACTLY (dy kept negative):
;   e2 = 2*err
;   if (e2 >= dy_neg) { err += dy_neg; x += sx; }   // dy_neg = -ln_dy
;   if (e2 <= dx)     { err += dx;     y += sy; }
; It draws ln_n+1 pixels (ln_n = max span), instead of testing x1/y1.
;
; Caller must be in CPU-to-VRAM draw mode; all coords 0..127 (the C wrapper
; only takes this path when both endpoints are on-screen, so the whole line is
; in-box and the inner loop needs no clip).
;
; zp arg block (set by gt_line_poke's C caller):
;   ln_x,ln_y   (u8)  start coords            ln_dx (u8) abs dx  ln_dy (u8) abs dy
;   ln_sx,ln_sy (s8)  step $01/$FF            ln_err(s16) = dx - dy_abs
;   ln_col      (u8)  raw hw color            ln_n  (u8) pixel count - 1
; ---------------------------------------------------------------------------
.export _gt_line_poke
.export _ln_x, _ln_y, _ln_dx, _ln_dy, _ln_sx, _ln_sy, _ln_err, _ln_col, _ln_n
.importzp _gt_draw_scratch    ; shared draw-op zp scratch (defined in gt_circ.s)
.PC02

; The whole Bresenham state lives in ZERO PAGE (fast) but OVERLAID on gt_circ's
; shared draw scratch — circ/circfill and line are synchronous blocking draws, so
; only one runs at a time and they can share the same 15 zp bytes. This gives line
; the fast zp inner loop (7,985 cyc, vs 9,321 in abs-addressed BSS) at ZERO net zp
; or RAM cost: neither the zp-tight carts (combo-pool) nor the RAM-tight ones
; (driftmania, which then keeps its blit font) pay for it. Only ln_ptr is private
; (the shared block is 15 bytes; line's 13 state bytes + a 2-byte pointer = 15).
_ln_x   = _gt_draw_scratch + 0
_ln_y   = _gt_draw_scratch + 1
_ln_dx  = _gt_draw_scratch + 2
_ln_dy  = _gt_draw_scratch + 3   ; ABS dy (positive); the loop negates it on use
_ln_sx  = _gt_draw_scratch + 4
_ln_sy  = _gt_draw_scratch + 5
_ln_err = _gt_draw_scratch + 6   ; signed 16-bit (2 bytes)
_ln_col = _gt_draw_scratch + 8
_ln_n   = _gt_draw_scratch + 9
ln_e2   = _gt_draw_scratch + 10  ; 2*err (signed 16, 2 bytes)
ptmp    = _gt_draw_scratch + 12  ; scratch

.segment "ZEROPAGE" : zeropage
ln_ptr:  .res 2          ; VRAM write pointer (MUST be zp — indirect plot)

.segment "CODE"

.proc _gt_line_poke
plot:
        ; --- VRAM pointer for (ln_x, ln_y): $4000 + (y<<7) + x ---
        ; ptr_lo = ((y & 1) << 7) | x ;  ptr_hi = $40 + (y >> 1)
        ldx     #$00
        lda     _ln_y
        and     #$01
        beq     :+
        ldx     #$80            ; y odd -> +$80 in ptr_lo
:       txa
        ora     _ln_x
        sta     ln_ptr+0        ; ptr_lo = (y&1?$80:0) | x
        lda     _ln_y
        lsr     a               ; y >> 1
        clc
        adc     #$40
        sta     ln_ptr+1        ; ptr_hi = $40 + (y>>1)
        lda     _ln_col
        sta     (ln_ptr)        ; plot

        ; --- drew ln_n+1 pixels? ---
        lda     _ln_n
        beq     endp
        dec     _ln_n

        ; --- e2 = 2*err (signed) ---
        lda     _ln_err
        asl     a
        sta     ln_e2
        lda     _ln_err+1
        rol     a
        sta     ln_e2+1

        ; --- if (e2 >= dy_neg) { err += dy_neg; x += sx }  where dy_neg = -ln_dy ---
        ; e2 >= -ln_dy  <=>  e2 + ln_dy >= 0
        clc
        lda     ln_e2
        adc     _ln_dy
        sta     ptmp            ; low(e2 + ln_dy)
        lda     ln_e2+1
        adc     #$00            ; ln_dy is 0..127 -> high add is carry only
        ; A:ptmp = e2 + ln_dy (signed). >= 0 ?  (bit7 of high clear)
        bmi     skipx           ; negative -> e2 < dy_neg -> skip
        ; err += dy_neg  (== err - ln_dy)
        sec
        lda     _ln_err
        sbc     _ln_dy
        sta     _ln_err
        lda     _ln_err+1
        sbc     #$00
        sta     _ln_err+1
        ; x += sx
        lda     _ln_x
        clc
        adc     _ln_sx
        sta     _ln_x
skipx:
        ; --- if (e2 <= dx) { err += dx; y += sy }  where dx = ln_dx (0..127) ---
        ; e2 <= dx  <=>  dx - e2 >= 0  <=>  NOT (e2 > dx)
        ; e2 is signed; if e2 high byte negative -> e2 < 0 <= dx -> take it
        lda     ln_e2+1
        bmi     doy             ; e2 < 0 -> e2 <= dx
        bne     skipy           ; e2 >= 256 > dx -> skip
        ; e2 in 0..255 (high=0): take when e2 <= dx  <=>  dx >= e2  <=> !(e2 > dx)
        lda     _ln_dx
        cmp     ln_e2           ; C set if dx >= e2  (dx - e2 >= 0)
        bcc     skipy           ; dx < e2 -> e2 > dx -> skip
doy:
        ; err += dx
        clc
        lda     _ln_err
        adc     _ln_dx
        sta     _ln_err
        lda     _ln_err+1
        adc     #$00
        sta     _ln_err+1
        ; y += sy
        lda     _ln_y
        clc
        adc     _ln_sy
        sta     _ln_y
skipy:
        jmp     plot
endp:
        rts
.endproc
