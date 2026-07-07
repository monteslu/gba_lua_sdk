; ---------------------------------------------------------------------------
; gt.hit_scan — two-pool AABB overlap scan (shmup enemies x bullets), asm.
;
; Cherry-bomb's compiled scan (35 enemies x 5 bullets x 4 compares + width/
; height lookups per pair) measured ~65k/frame — nearly half its combat
; budget. Phase 1 caches each live B slot's screen box (x>>hs_sh plus the
; width byte field; B height is pool-constant hs_bh+1). Phase 2 walks A
; (the big pool) once, testing each live A box against the cached B boxes
; at ~30 cycles a pair. Overlaps land in the pairs byte list as LIVE
; ORDINALS (nth live slot in all() order, 1-based) — (a_ord, b_ord), pairs
; ascending in a_ord, 0-terminated — so the Lua handler resolves them in a
; single for-in-all() walk. Geometry only: mission ghosts etc. re-check in
; the handler (hits are rare events).
;
; Negative/offscreen coordinates: the logical downshift wraps them to large
; bytes, which inverts the box and fails every compare — same no-hit verdict
; the signed original produced offscreen.
; ---------------------------------------------------------------------------
.export _gt_hits_z
.export _hs_ax, _hs_ay, _hs_aw, _hs_ah, _hs_au, _hs_an
.export _hs_bx, _hs_by, _hs_bw, _hs_bu, _hs_bn, _hs_bh, _hs_sh, _hs_pairs
.PC02

.segment "ZEROPAGE" : zeropage
_hs_ax:    .res 2
_hs_ay:    .res 2
_hs_aw:    .res 2
_hs_ah:    .res 2
_hs_au:    .res 2
_hs_an:    .res 1
_hs_bx:    .res 2
_hs_by:    .res 2
_hs_bw:    .res 2
_hs_bu:    .res 2
_hs_bn:    .res 1
_hs_bh:    .res 1               ; B height - 1 (px)
_hs_sh:    .res 1               ; coord >> shift
_hs_pairs: .res 2
hs_i:      .res 1
hs_pi:     .res 1
hs_aord:   .res 1               ; live ordinal of the current A
hs_x0:     .res 1               ; current A box
hs_x1:     .res 1
hs_y0:     .res 1
hs_y1:     .res 1
hs_t:      .res 2
hs_nb:     .res 1               ; cached live-B count

.segment "BSS"
hb_x0: .res 16                  ; cached live-B boxes, packed (no gaps)
hb_x1: .res 16
hb_y0: .res 16
hb_y1: .res 16
hb_or: .res 16                  ; live ordinal of each cached B

.segment "CODE"

; A <- low byte of (int at (ptr),(2*hs_i)) >> hs_sh
.macro RDSH ptr
        lda     hs_i
        asl     a
        tay
        lda     (ptr),y
        sta     hs_t
        iny
        lda     (ptr),y
        sta     hs_t+1
        ldx     _hs_sh
        beq     :++
:       lsr     hs_t+1
        ror     hs_t
        dex
        bne     :-
:       lda     hs_t
.endmacro

.proc _gt_hits_z
        stz     hs_pi
        stz     hs_nb
        ; ---- phase 1: cache live B boxes (packed) ----
        stz     hs_i
        stz     hs_aord         ; reuse as the B live-ordinal counter
bloop:  lda     hs_i
        cmp     _hs_bn
        beq     astart
        tay
        lda     (_hs_bu),y
        bne     :+
        jmp     bnext
:       inc     hs_aord
        RDSH    _hs_bx
        ldx     hs_nb
        sta     hb_x0,x
        ldy     hs_i
        clc
        adc     (_hs_bw),y
        dec     a
        sta     hb_x1,x
        RDSH    _hs_by
        ldx     hs_nb
        sta     hb_y0,x
        clc
        adc     _hs_bh
        sta     hb_y1,x
        lda     hs_aord
        sta     hb_or,x
        inx
        cpx     #16
        bcs     astart          ; cache full
        stx     hs_nb
bnext:  inc     hs_i
        jmp     bloop

        ; ---- phase 2: walk A once vs the cached boxes ----
astart: stz     hs_i
        stz     hs_aord
aloop:  lda     hs_i
        cmp     _hs_an
        bne     :+
        ldy     hs_pi
        lda     #0
        sta     (_hs_pairs),y
        rts
:       tay
        lda     (_hs_au),y
        bne     :+
        jmp     anext
:       inc     hs_aord
        lda     hs_nb
        bne     :+
        jmp     anext           ; no live bullets at all
:       RDSH    _hs_ax
        sta     hs_x0
        ldy     hs_i
        clc
        adc     (_hs_aw),y
        dec     a
        sta     hs_x1
        RDSH    _hs_ay
        sta     hs_y0
        ldy     hs_i
        clc
        adc     (_hs_ah),y
        dec     a
        sta     hs_y1
        ; test each cached B
        ldx     #0
scan:   cpx     hs_nb
        beq     anext
        ; overlap: ax0 <= bx1 && bx0 <= ax1 && ay0 <= by1 && by0 <= ay1
        lda     hb_x1,x
        cmp     hs_x0
        bcc     snext           ; bx1 < ax0
        lda     hs_x1
        cmp     hb_x0,x
        bcc     snext           ; ax1 < bx0
        lda     hb_y1,x
        cmp     hs_y0
        bcc     snext           ; by1 < ay0
        lda     hs_y1
        cmp     hb_y0,x
        bcc     snext           ; ay1 < by0
        ; hit: emit (a_ord, b_ord)
        ldy     hs_pi
        lda     hs_aord
        sta     (_hs_pairs),y
        iny
        lda     hb_or,x
        sta     (_hs_pairs),y
        iny
        cpy     #62
        bcs     :+
        sty     hs_pi
:
snext:  inx
        bra     scan
anext:  inc     hs_i
        jmp     aloop
.endproc
