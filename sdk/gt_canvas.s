; ---------------------------------------------------------------------------
; gt_canvas — the canvas window blit, standalone.
;
; Extracted from gt_flakes.s: carts that use the composed canvas but not
; the flake fields must not link ~700B of flake BSS — combo-pool's RAM was
; tight enough that doing so pushed BSS under the C stack and corrupted
; game state (instant sudden-death from trashed counters).
; ---------------------------------------------------------------------------
.import _gt_q, _gt_qhead, _gt_qtail, _gt_q_pump, _gt_qbank

.PC02

; gt_canvas_view — the 4-piece 128x128 canvas window blit (newleste's map):
; the 256px canvas strip splits at most once in x (two pieces of <=127) and
; always twice in y (the blitter's 7-bit height), colorkey-transparent.
; Replaces ~7k of Lua wrap math + four 6-arg gspr calls with ~1.5k.
;   cv_dx (16-bit world x), cv_dy (byte world y) — the screen origin is the
;   camera itself, so VX/VY are 0/64; canvas rows: crow = (dx>>8)*128 + dy.
; ---------------------------------------------------------------------------
.export _gt_canvas_view_z, _cv_dx, _cv_dy, _cv_fl, _cv_h
.import _gt_qbank

QF_COPYV = $57

.segment "ZEROPAGE" : zeropage
_cv_dx:  .res 2
_cv_dy:  .res 1
_cv_fl:  .res 1                 ; entry flags: $57 colorkey, $D7 opaque
_cv_h:   .res 1                 ; visible height (0 -> 128 full); caps band 2 so
                                ; a caller can leave a static HUD band untouched
cv_coff: .res 1                 ; dx & 255
cv_crow: .res 1                 ; (dx>>8)*128 + dy
cv_w0:   .res 1
cv_t:    .res 1
cv_h2:   .res 1                 ; band-2 height (visible height - 64)

.segment "CODE"

; stage one QF_COPY: A=GX X=GY, cv_t=W, Y=VX; VY passed in cv_crow? use
; explicit: helper args via zp cv2_*
.segment "ZEROPAGE" : zeropage
cv_gx:  .res 1
cv_gy:  .res 1
cv_w:   .res 1
cv_vx:  .res 1
cv_vy:  .res 1
cv_vh:  .res 1                  ; this piece's height (rows)

.segment "CODE"
.proc cvpiece
        lda     cv_vh
        beq     done            ; zero-height band: skip
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
        lda     cv_vh
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
        ; resolve visible height -> band-1 height (in cv_t, <=64) and band-2
        ; height (cv_h2). _cv_h==0 means "full 128" (both bands 64).
        lda     _cv_h
        bne     :+
        lda     #128            ; 0 -> full height
:       cmp     #64
        bcc     @short          ; h < 64: band1=h, band2=0
        sec
        sbc     #64
        sta     cv_h2           ; band2 = h - 64
        lda     #64
        sta     cv_t            ; band1 = 64
        bra     @hset
@short: sta     cv_t            ; band1 = h (<64)
        stz     cv_h2           ; band2 = 0
@hset:
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
        lda     cv_t            ; band-1 height
        sta     cv_vh
        jsr     cvpiece
        lda     cv_crow
        clc
        adc     #64
        sta     cv_gy
        lda     #64
        sta     cv_vy
        lda     cv_h2           ; band-2 height (0 -> cvpiece skips)
        sta     cv_vh
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
        lda     cv_t            ; band-1 height
        sta     cv_vh
        jsr     cvpiece
        lda     cv_gy
        clc
        adc     #64
        sta     cv_gy
        lda     #64
        sta     cv_vy
        lda     cv_h2           ; band-2 height
        sta     cv_vh
        jsr     cvpiece
doneall:
        rts
.endproc
