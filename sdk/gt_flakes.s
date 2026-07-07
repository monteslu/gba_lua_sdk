; ---------------------------------------------------------------------------
; gt.flakes — ambient drifting-particle field (snow / motes), pure 65C02.
;
; WHY ASM: the same loop in the Lua dialect measured ~2,500 cycles per flake
; (isolated microbench), and a C implementation compiles to the same class of
; code — cc65's 16-bit codegen on RMW-heavy bodies runs 5-10x the instruction-
; count estimate (pointer helpers, address recomputation, spills). This loop
; is ~175 cycles per flake: byte-split state arrays, Y-indexed direct
; addressing, ring entries staged in place (no gt_ent, no push copy).
;
; Semantics match the newleste reference exactly (8.8 screen space):
;   x16 += spd16 - camdx8
;   y16 = (y16 + sin[(ph >> 2) & 63] - camdy8) & 0x7FFF
;   ph  += adv            (adv = spd>>5 capped 12, PRECOMPUTED at init)
;   px = x16 >> 8 (signed): px < -4 -> respawn at x=32767, y=rnd(128)<<8
;   draw (sz+1)x(sz+1) fill at (px, (y16>>8) & 127) when 0 <= px <= 127
;
; State is byte-split and owned here; gt_api.c's GT_FLAKES init fills it
; through the exports. Colors are stored PRE-INVERTED (ring format).
; ---------------------------------------------------------------------------
.export _gt_flakes_draw, _gt_flakes_draw2
.export _fl_n, _fl_xl, _fl_xh, _fl_yl, _fl_yh, _fl_ph
.export _fl_spdl, _fl_spdh, _fl_adv, _fl_w, _fl_h, _fl_ci
.export _fl_rxl, _fl_rxh, _fl_ry
.export _fl_sinl, _fl_sinh
.import _gt_q, _gt_qhead, _gt_qtail, _gt_q_pump, _gt_rng_next
.import incsp2
.importzp c_sp
.PC02

FL_MAX = 48
QF_RECT = $CD                   ; NMI|ENABLE|IRQ|COLORFILL|OPAQUE

.segment "BSS"
_fl_n:    .res 1                ; live flake count
_fl_xl:   .res FL_MAX           ; x 8.8 lo
_fl_xh:   .res FL_MAX           ; x 8.8 hi (signed)
_fl_yl:   .res FL_MAX           ; y 8.8 lo
_fl_yh:   .res FL_MAX           ; y 8.8 hi (wrapped & $7F)
_fl_ph:   .res FL_MAX           ; wobble phase byte
_fl_spdl: .res FL_MAX           ; speed 8.8 lo
_fl_spdh: .res FL_MAX           ; speed 8.8 hi
_fl_adv:  .res FL_MAX           ; phase step (spd>>5 cap 12, init-computed)
_fl_w:    .res FL_MAX           ; blit W (1..127)
_fl_h:    .res FL_MAX           ; blit H (1..127)
_fl_ci:   .res FL_MAX           ; color, PRE-INVERTED for the ring
_fl_rxl:  .res FL_MAX           ; respawn x16 lo (snow: $FF7F; clouds: -w<<8)
_fl_rxh:  .res FL_MAX           ; respawn x16 hi
_fl_ry:   .res FL_MAX           ; nonzero: reroll y on respawn
_fl_sinl: .res 64               ; wobble table lo (s8 sine, init-filled)
_fl_sinh: .res 64               ; sign extension of each entry (0/$FF)

.segment "ZEROPAGE" : zeropage
fd_cdx:  .res 2                 ; camdx8 (this call)
fd_cdyl: .res 1                 ; camdy8 lo
fd_cdyh: .res 1                 ; camdy8 hi
fd_t:    .res 2                 ; scratch 16-bit
fd_lo:   .res 1
fd_cpu:  .res 1               ; nonzero: poke pixels (CPU mode) instead of staging
fd_ptr:  .res 2               ; CPU-poke pointer                 ; range draw: first index

.segment "CODE"

; void __fastcall__ gt_flakes_draw2(int first, int count, int camdx8, int camdy8)
; camdy8 in A/X; stack (top first): camdx8, count, first. Draws flakes
; [first, first+count) — layered fields (clouds behind the map, snow in
; front) share the one state.
_gt_flakes_draw2:
        stz     fd_cpu
        sta     fd_cdyl
        stx     fd_cdyh
        ldy     #0
        lda     (c_sp),y
        sta     fd_cdx
        iny
        lda     (c_sp),y
        sta     fd_cdx+1
        ldy     #2
        lda     (c_sp),y        ; count lo
        sta     fd_t
        ldy     #4
        lda     (c_sp),y        ; first lo
        sta     fd_lo
        clc
        adc     fd_t
        sta     fd_t            ; end = first + count
        jsr     incsp2
        jsr     incsp2
        jsr     incsp2
        ldy     fd_t
        cpy     fd_lo
        bne     loop
        rts
loop:   dey
        ; ---- x16 += (spd16 - camdx8) ----
        sec
        lda     _fl_spdl,y
        sbc     fd_cdx
        sta     fd_t
        lda     _fl_spdh,y
        sbc     fd_cdx+1
        sta     fd_t+1
        clc
        lda     _fl_xl,y
        adc     fd_t
        sta     _fl_xl,y
        lda     _fl_xh,y
        adc     fd_t+1
        sta     _fl_xh,y
        ; ---- y16 += sin[(ph>>2)&63] - camdy8 ; y16 &= $7FFF ----
        lda     _fl_ph,y
        lsr     a
        lsr     a
        and     #63
        tax
        sec
        lda     _fl_sinl,x
        sbc     fd_cdyl
        sta     fd_t
        lda     _fl_sinh,x
        sbc     fd_cdyh
        sta     fd_t+1
        clc
        lda     _fl_yl,y
        adc     fd_t
        sta     _fl_yl,y
        lda     _fl_yh,y
        adc     fd_t+1
        and     #$7F
        sta     _fl_yh,y
        ; ---- ph += adv ----
        lda     _fl_ph,y
        clc
        adc     _fl_adv,y
        sta     _fl_ph,y
        ; ---- px = x16>>8 signed; off either edge -> respawn ----
        lda     _fl_xh,y
        bpl     posx
        cmp     #$FC            ; signed: xh in $FC..$FF is -4..-1 (edging in)
        bcc     resp            ; px < -4: respawn/wrap
        jmp     next            ; not drawn yet, still live
posx:   cmp     #129            ; px >= 129: past the right edge
        bcs     resp
        jmp     vis
resp:   lda     _fl_ry,y
        cmp     #2
        bne     norm
        ; wrap mode: x += or -= 132<<8 back into range
        lda     _fl_xh,y
        bmi     wleft
        sec
        lda     _fl_xl,y
        sbc     #0
        sta     _fl_xl,y
        lda     _fl_xh,y
        sbc     #132
        sta     _fl_xh,y
        jmp     next
wleft:  clc
        lda     _fl_xl,y
        adc     #0
        sta     _fl_xl,y
        lda     _fl_xh,y
        adc     #132
        sta     _fl_xh,y
        jmp     next
norm:   lda     _fl_rxl,y       ; per-flake respawn x
        sta     _fl_xl,y
        lda     _fl_rxh,y
        sta     _fl_xh,y
        lda     _fl_ry,y
        beq     next            ; clouds keep their row
        phy
        jsr     _gt_rng_next    ; A = random lo
        ply
        and     #$7F
        sta     _fl_yh,y
        lda     #0
        sta     _fl_yl,y
        bra     next
vis:    ; on screen (0..127): stage a QF_RECT ring entry in place
        sta     fd_t            ; px
        lda     fd_cpu
        beq     slot
        ; ---- CPU mode (caller entered it): poke the pixel directly.
        ; vram = $4000 | (y << 7) | x; color un-inverts (ci is stored
        ; pre-inverted for the blitter's colorfill register). 1x1 only —
        ; the CPU entry point is gated to fields built with w = h = 1.
        lda     _fl_yh,y
        lsr     a               ; y>>1 -> high byte offset
        ora     #$40
        sta     fd_ptr+1
        lda     #0
        ror     a               ; (y&1) << 7
        ora     fd_t
        sta     fd_ptr
        lda     _fl_ci,y
        eor     #$FF
        phy
        ldy     #0
        sta     (fd_ptr),y
        ply
        jmp     next
        ; claim a slot (full is measured-never; drain if so)
slot:   lda     _gt_qhead
        clc
        adc     #8
        cmp     _gt_qtail
        bne     free
        phy
        jsr     _gt_q_pump
        ply
        bra     slot
free:   ldx     _gt_qhead
        lda     #QF_RECT
        sta     _gt_q+0,x
        lda     fd_t
        sta     _gt_q+1,x       ; VX
        lda     _fl_yh,y
        sta     _gt_q+2,x       ; VY
        stz     _gt_q+3,x
        stz     _gt_q+4,x
        lda     _fl_w,y
        sta     _gt_q+5,x       ; W
        lda     _fl_h,y
        sta     _gt_q+6,x       ; H
        lda     _fl_ci,y
        sta     _gt_q+7,x       ; color (pre-inverted)
        txa
        clc
        adc     #8
        sta     _gt_qhead
        phy
        jsr     _gt_q_pump
        ply
next:   cpy     fd_lo
        beq     done
        jmp     loop
done:   rts

; void __fastcall__ gt_flakes_draw2c(...) — draw2 but pixels poke through
; CPU mode (the caller must have entered it). For 1x1 flake fields drawn
; at the frame tail: ~35 cycles a flake vs ~130 through the ring + IRQ.
.export _gt_flakes_draw2c
_gt_flakes_draw2c:
        ldy     #1
        sty     fd_cpu
        sta     fd_cdyl
        stx     fd_cdyh
        ldy     #0
        lda     (c_sp),y
        sta     fd_cdx
        iny
        lda     (c_sp),y
        sta     fd_cdx+1
        ldy     #2
        lda     (c_sp),y
        sta     fd_t
        ldy     #4
        lda     (c_sp),y
        sta     fd_lo
        clc
        adc     fd_t
        sta     fd_t
        jsr     incsp2
        jsr     incsp2
        jsr     incsp2
        ldy     fd_t
        cpy     fd_lo
        beq     :+
        jmp     loop
:       rts

; void __fastcall__ gt_flakes_draw(int camdx8, int camdy8) — all flakes
_gt_flakes_draw:
        stz     fd_cpu
        sta     fd_cdyl
        stx     fd_cdyh
        ldy     #0
        lda     (c_sp),y
        sta     fd_cdx
        iny
        lda     (c_sp),y
        sta     fd_cdx+1
        jsr     incsp2
        stz     fd_lo
        ldy     _fl_n
        cpy     fd_lo
        bne     jl
        rts
jl:     jmp     loop

; ---------------------------------------------------------------------------
; gt.chain — follower chain (hair, tails): 5 segments ease toward a target
; with the port's integer 5/8 smoothing ((d*5+4)>>3), drawn as p8 round
; dots (radii 2,2,1,1,1) staged straight into the blit ring. The same
; update+draw measured ~11k/frame through the compiler; this is ~1.6k.
;   gt_a0 = target x (screen px)  gt_a1 = target y  gt_a2 = p8 color
; ---------------------------------------------------------------------------
.export _gt_chain_z
.importzp _gt_a0, _gt_a1, _gt_a2
.import _p8pal, _gt_draw_mode

CH_N = 5
QF_RECTC = $CD

.segment "BSS"
_ch_x:  .res CH_N
_ch_y:  .res CH_N
ch_c:   .res 1                  ; resolved + inverted color
ch_px:  .res 1                  ; current dot center x
ch_py:  .res 1                  ; current dot center y
.export _ch_x, _ch_y

.segment "ZEROPAGE" : zeropage
ce_d:   .res 2                  ; ease scratch (16-bit d*5)

.segment "CODE"

; A = current pos, ch_c-free helper: eases pos toward gt_aN. Inputs via
; caller-set zp; returns eased new pos in A. Uses ce_d. Preserves Y.
; new = pos + ((target - pos)*5 + 4) >> 3   (arithmetic shift)
.proc ease58
        ; X = target (passed in X), A = pos
        sta     ce_d            ; pos
        txa
        sec
        sbc     ce_d            ; d = target - pos (s8)
        ; sign-extend d into ce_d 16-bit, then *5 + 4 >> 3
        tax                     ; keep d
        and     #$80
        beq     :+
        lda     #$FF
:       sta     ce_d+1
        stx     ce_d
        ; d*5 = d + d<<2 (16-bit)
        lda     ce_d
        asl     a
        rol     ce_d+1          ; CAUTION: hi already sign; shifting is fine
        asl     a
        rol     ce_d+1
        ; A = d<<2 lo, ce_d+1 = running hi; add original d (sign-extended)
        clc
        adc     ce_d
        sta     ce_d
        txa                     ; recompute nothing — hi add:
        and     #$80
        beq     :+
        lda     #$FF
        bra     :++
:       lda     #$00
:       adc     ce_d+1
        sta     ce_d+1
        ; +4
        lda     ce_d
        clc
        adc     #4
        sta     ce_d
        bcc     :+
        inc     ce_d+1
:       ; arithmetic >>3
        lda     ce_d+1
        cmp     #$80            ; carry = sign for ror
        ror     ce_d+1
        ror     ce_d
        lda     ce_d+1
        cmp     #$80
        ror     ce_d+1
        ror     ce_d
        lda     ce_d+1
        cmp     #$80
        ror     ce_d+1
        ror     ce_d
        lda     ce_d            ; step (s8 in practice)
        rts
.endproc

; stage one 1-scanline fill: A=x X=w  (ch_py holds y; ch_c the color)
.proc chrow
        sta     ce_d            ; x
        stx     ce_d+1          ; w
slot:   lda     _gt_qhead
        clc
        adc     #8
        cmp     _gt_qtail
        bne     free
        phy
        jsr     _gt_q_pump
        ply
        bra     slot
free:   ldx     _gt_qhead
        lda     #QF_RECTC
        sta     _gt_q+0,x
        lda     ce_d
        sta     _gt_q+1,x
        lda     ch_py
        sta     _gt_q+2,x
        stz     _gt_q+3,x
        stz     _gt_q+4,x
        lda     ce_d+1
        sta     _gt_q+5,x
        lda     #1
        sta     _gt_q+6,x
        lda     ch_c
        sta     _gt_q+7,x
        txa
        clc
        adc     #8
        sta     _gt_qhead
        phy
        jsr     _gt_q_pump
        ply
        inc     ch_py           ; next scanline
        rts
.endproc

; void gt_chain_z(void) — gt_a0/a1 = target, gt_a2 = p8 color
.proc _gt_chain_z
        stz     _gt_draw_mode
        ldy     _gt_a2
        lda     _p8pal,y
        eor     #$FF
        sta     ch_c
        ; ---- update the chain ----
        ldy     #0
upd:    ldx     _gt_a0
        lda     _ch_x,y
        sta     ch_px           ; old pos
        jsr     ease58
        clc
        adc     ch_px
        sta     _ch_x,y
        sta     _gt_a0
        ldx     _gt_a1
        lda     _ch_y,y
        sta     ch_px
        jsr     ease58
        clc
        adc     ch_px
        sta     _ch_y,y
        sta     _gt_a1
        iny
        cpy     #CH_N
        bne     upd
        ; ---- draw: segs 0,1 radius 2; segs 2,3,4 radius 1 ----
        ldy     #0
d2:     lda     _ch_y,y
        sec
        sbc     #2
        sta     ch_py           ; top row of the r2 dot
        lda     _ch_x,y
        sec
        sbc     #1
        ldx     #3
        jsr     chrow           ; row -2: w3 at x-1
        lda     _ch_x,y
        sec
        sbc     #2
        ldx     #5
        jsr     chrow           ; row -1: w5 at x-2
        lda     _ch_x,y
        sec
        sbc     #2
        ldx     #5
        jsr     chrow           ; row 0
        lda     _ch_x,y
        sec
        sbc     #2
        ldx     #5
        jsr     chrow           ; row +1
        lda     _ch_x,y
        sec
        sbc     #1
        ldx     #3
        jsr     chrow           ; row +2
        iny
        cpy     #2
        bne     d2
d1:     lda     _ch_y,y
        sec
        sbc     #1
        sta     ch_py
        lda     _ch_x,y
        ldx     #1
        jsr     chrow           ; row -1: w1 at x
        lda     _ch_x,y
        sec
        sbc     #1
        ldx     #3
        jsr     chrow           ; row 0: w3 at x-1
        lda     _ch_x,y
        ldx     #1
        jsr     chrow           ; row +1
        iny
        cpy     #CH_N
        bne     d1
        rts
.endproc

; ---------------------------------------------------------------------------
; gt_canvas_view — the 4-piece 128x128 canvas window blit (newleste's map):
; the 256px canvas strip splits at most once in x (two pieces of <=127) and
; always twice in y (the blitter's 7-bit height), colorkey-transparent.
; Replaces ~7k of Lua wrap math + four 6-arg gspr calls with ~1.5k.
;   cv_dx (16-bit world x), cv_dy (byte world y) — the screen origin is the
;   camera itself, so VX/VY are 0/64; canvas rows: crow = (dx>>8)*128 + dy.
; ---------------------------------------------------------------------------
.export _gt_canvas_view_z, _cv_dx, _cv_dy, _cv_fl
.import _gt_qbank

QF_COPYV = $57

.segment "ZEROPAGE" : zeropage
_cv_dx:  .res 2
_cv_dy:  .res 1
_cv_fl:  .res 1                 ; entry flags: $57 colorkey, $D7 opaque
cv_coff: .res 1                 ; dx & 255
cv_crow: .res 1                 ; (dx>>8)*128 + dy
cv_w0:   .res 1
cv_t:    .res 1

.segment "CODE"

; stage one QF_COPY: A=GX X=GY, cv_t=W, Y=VX; VY passed in cv_crow? use
; explicit: helper args via zp cv2_*
.segment "ZEROPAGE" : zeropage
cv_gx:  .res 1
cv_gy:  .res 1
cv_w:   .res 1
cv_vx:  .res 1
cv_vy:  .res 1

.segment "CODE"
.proc cvpiece
        lda     cv_w
        beq     done
slot:   lda     _gt_qhead
        clc
        adc     #8
        cmp     _gt_qtail
        bne     free
        jsr     _gt_q_pump
        bra     slot
free:   ldx     _gt_qhead
        lda     _cv_fl
        sta     _gt_q+0,x
        lda     cv_vx
        sta     _gt_q+1,x
        lda     cv_vy
        sta     _gt_q+2,x
        lda     cv_gx
        sta     _gt_q+3,x
        lda     cv_gy
        sta     _gt_q+4,x
        lda     cv_w
        sta     _gt_q+5,x
        lda     #64
        sta     _gt_q+6,x
        lda     _gt_qbank
        ora     #1              ; BG_GROUP
        sta     _gt_q+7,x
        txa
        clc
        adc     #8
        sta     _gt_qhead
        jsr     _gt_q_pump
done:   rts
.endproc

.proc _gt_canvas_view_z
        lda     _cv_dx
        sta     cv_coff
        ; crow = (dx>>8)*128 + dy  (dx>>8 is 0/1 for a 2-strip canvas)
        lda     _cv_dx+1
        lsr     a               ; bit0 -> carry
        lda     #0
        ror     a               ; A = 0 or 128
        clc
        adc     _cv_dy
        sta     cv_crow
        ; w0 = 256 - coff, capped 127
        lda     #0
        sec
        sbc     cv_coff         ; 256-coff (mod 256; coff=0 -> 0 = full 256)
        beq     full
        cmp     #127
        bcc     :+
full:   lda     #127
:       sta     cv_w0
        ; piece A: (coff, crow, w0, 64) at (0,0); B at (0,64) crow+64
        lda     cv_coff
        sta     cv_gx
        lda     cv_crow
        sta     cv_gy
        lda     cv_w0
        sta     cv_w
        stz     cv_vx
        stz     cv_vy
        jsr     cvpiece
        lda     cv_crow
        clc
        adc     #64
        sta     cv_gy
        lda     #64
        sta     cv_vy
        jsr     cvpiece
        ; pieces C/D: remaining width at VX=w0
        lda     #128
        sec
        sbc     cv_w0
        beq     doneall         ; w0 == 128?? (can't: capped 127) safety
        sta     cv_w
        ; wx1 = dx + w0 -> coff1 / crow1
        lda     _cv_dx
        clc
        adc     cv_w0
        sta     cv_gx           ; coff1 (low byte)
        lda     _cv_dx+1
        adc     #0
        lsr     a
        lda     #0
        ror     a
        clc
        adc     _cv_dy
        sta     cv_gy           ; crow1
        lda     cv_w0
        sta     cv_vx
        stz     cv_vy
        jsr     cvpiece
        lda     cv_gy
        clc
        adc     #64
        sta     cv_gy
        lda     #64
        sta     cv_vy
        jsr     cvpiece
doneall:
        rts
.endproc

