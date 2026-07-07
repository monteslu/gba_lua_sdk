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
fd_lo:   .res 1                 ; range draw: first index

.segment "CODE"

; void __fastcall__ gt_flakes_draw2(int first, int count, int camdx8, int camdy8)
; camdy8 in A/X; stack (top first): camdx8, count, first. Draws flakes
; [first, first+count) — layered fields (clouds behind the map, snow in
; front) share the one state.
_gt_flakes_draw2:
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
        bcs     next            ; not drawn yet, still live
        bra     resp            ; px < -4: respawn
posx:   cmp     #129            ; px >= 129: past the right edge
        bcc     vis
resp:   lda     _fl_rxl,y       ; per-flake respawn x
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

; void __fastcall__ gt_flakes_draw(int camdx8, int camdy8) — all flakes
_gt_flakes_draw:
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
