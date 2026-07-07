; ---------------------------------------------------------------------------
; gt.balls — one physics substep for a 2D ball table, in 65C02.
;
; Combo-pool's compiled movement + spatial grid + pair scan measured ~57k
; per frame (two substeps) with 45% of the frame in cc65's 32-bit fixed
; helpers. This engine runs one substep in ~4k: half-velocity integration,
; wall bounces with clamp + a per-ball bounce flag, an 8x8 spatial-grid
; rebuild, and a contact-pair scan. The branchy impulse/merge resolution
; stays in Lua (do_coll), fed from the pair list this writes — collisions
; are rare events; the scan is the every-frame cost.
;
; The port's arrays stay 16.16 fixed (4 bytes/element, little-endian:
; frac_lo, frac_hi, int_lo, int_hi). The engine reads/writes bytes 1..2 —
; the embedded 8.8 core — and zeroes byte 0 / sign-extends byte 3 on write,
; so the Lua side keeps operating on the same values seamlessly (physics
; precision 1/256 px; the lowest fraction byte truncates each step).
;
; zp contract (set by the C wrapper each call):
;   bp_x, bp_y, bp_vx, bp_vy : ptrs to the fixed arrays (element stride 4)
;   bp_act                   : ptr to the color/active INT array (stride 2,
;                              0 = inactive, low byte tested)
;   bp_fl                    : ptr to a byte array; engine writes 1 on wall
;                              bounce (Lua applies game rules + clears)
;   bp_pairs                 : ptr to a byte array; engine writes i,j pairs
;                              (1-based) terminated by 0
;   bp_n                     : ball count (<= 32)
; Walls: x clamps to [4,124], y bounces at <4 or (>112 while vy>0.1: the
; vy>0.1 nuance stays in Lua via the flag — here y>112 bounces when vy>0,
; > 0.1 in 8.8 is 25; see wall_y for the exact check).
; ---------------------------------------------------------------------------
.export _gt_balls_z
.export _bp_x, _bp_y, _bp_vx, _bp_vy, _bp_act, _bp_fl, _bp_pairs, _bp_n
.import _gt_rng_next
.PC02

.segment "ZEROPAGE" : zeropage
_bp_x:     .res 2
_bp_y:     .res 2
_bp_vx:    .res 2
_bp_vy:    .res 2
_bp_act:   .res 2
_bp_fl:    .res 2
_bp_pairs: .res 2
_bp_n:     .res 1
bz_i:      .res 1               ; ball index
bz_o:      .res 1               ; byte offset of element (i*4 + 1)
bz_o2:     .res 1               ; byte offset for act (i*2)
bz_t:      .res 2               ; scratch
bz_pi:     .res 1               ; pairs write index

.segment "BSS"
; engine-owned spatial grid: 8x8 cells, 8 members each
bg_cnt:  .res 64
bg_mem:  .res 512
bg_gx:   .res 32                ; per-ball cell coords
bg_gy:   .res 32

.segment "CODE"

.proc _gt_balls_z
        stz     bz_pi
        ; ---- clear the grid counts ----
        ldx     #63
:       stz     bg_cnt,x
        dex
        bpl     :-
        ; ---- per ball: integrate, walls, grid insert ----
        stz     bz_i
loop:   lda     bz_i
        cmp     _bp_n
        bne     :+
        jmp     scan
:       ; offsets: element byte offset = i*4+1 (8.8 lo), act = i*2
        asl     a
        sta     bz_o2
        asl     a
        inc     a
        sta     bz_o
        ; active?
        ldy     bz_o2
        lda     (_bp_act),y
        bne     act
        jmp     nextb
act:    ldy     bz_i
        lda     #0
        sta     (_bp_fl),y      ; clear the bounce flag each substep
        ; ---- x += vx/2 ----
        ldy     bz_o
        lda     (_bp_vx),y
        sta     bz_t
        iny
        lda     (_bp_vx),y
        sta     bz_t+1
        cmp     #$80            ; carry = sign bit
        ror     bz_t+1
        ror     bz_t            ; bz_t = vx/2 (arithmetic)
        ldy     bz_o
        lda     (_bp_x),y
        clc
        adc     bz_t
        pha
        iny
        lda     (_bp_x),y
        adc     bz_t+1
        tax
        pla                     ; A/X = new x
        ; ---- wall x: clamp 4..124 int-part ----
        cpx     #4
        bmi     xlow
        cpx     #124
        bpl     xhigh
        bra     xstore
xlow:   ; x < 4: negate vx, x = 4
        jsr     negvx
        lda     #0
        ldx     #4
        jsr     hurt
        bra     xstore
xhigh:  ; x >= 124: negate vx, x = 124
        jsr     negvx
        lda     #0
        ldx     #124
        jsr     hurt
xstore: ; write x back (A=lo X=hi)
        ldy     bz_o
        dey
        pha
        lda     #0
        sta     (_bp_x),y
        iny
        pla
        sta     (_bp_x),y
        iny
        txa
        sta     (_bp_x),y
        iny
        lda     #0              ; positions are always positive
        sta     (_bp_x),y
        ; keep int part for the grid
        txa
        lsr     a
        lsr     a
        lsr     a
        lsr     a               ; /16 -> 0..7
        ldx     bz_i
        sta     bg_gx,x
        ; ---- y += vy/2 ----
        ldy     bz_o
        lda     (_bp_vy),y
        sta     bz_t
        iny
        lda     (_bp_vy),y
        sta     bz_t+1
        cmp     #$80
        ror     bz_t+1
        ror     bz_t
        ldy     bz_o
        lda     (_bp_y),y
        clc
        adc     bz_t
        pha
        iny
        lda     (_bp_y),y
        adc     bz_t+1
        tax
        pla
        ; ---- wall y: <4 bounce; >112 bounce only when vy > 0.1 (25 in 8.8)
        cpx     #4
        bmi     ylow
        cpx     #112
        bpl     ymaybe
        bra     ystore
ylow:   jsr     negvy
        lda     #0
        ldx     #4
        jsr     hurt
        bra     ystore
ymaybe: ; y >= 112: only a wall if vy > 0.1 (hi>0, or hi==0 && lo>25)
        ldy     bz_o
        iny
        lda     (_bp_vy),y      ; vy hi (post-negation state not yet — raw)
        bmi     ystore          ; moving up: pass
        bne     ywall
        dey
        lda     (_bp_vy),y
        cmp     #26
        bcc     ystore
ywall:  jsr     negvy
        lda     #0
        ldx     #112
        jsr     hurt
ystore: ldy     bz_o
        dey
        pha
        lda     #0
        sta     (_bp_y),y
        iny
        pla
        sta     (_bp_y),y
        iny
        txa
        sta     (_bp_y),y
        iny
        lda     #0
        sta     (_bp_y),y
        ; grid y
        txa
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        ldx     bz_i
        sta     bg_gy,x
        ; ---- grid insert: cell = gy*8 + gx (INC abs,y doesn't exist:
        ; the cell index lives in X here) ----
        asl     a
        asl     a
        asl     a
        clc
        adc     bg_gx,x
        tax                     ; cell 0..63
        lda     bg_cnt,x
        cmp     #8
        bcs     nextb           ; cell full: skip membership
        pha
        txa
        asl     a
        asl     a
        asl     a               ; cell*8
        sta     bz_t
        pla
        inc     bg_cnt,x
        clc
        adc     bz_t
        tay
        lda     bz_i
        inc     a               ; store 1-based
        sta     bg_mem,y
nextb:  inc     bz_i
        jmp     loop

        ; ---- pair scan: for each ball, check its cell + right/down
        ; neighbors' members with higher index ----
scan:   stz     bz_i
sloop:  lda     bz_i
        cmp     _bp_n
        bne     :+
        ; terminate pairs
        ldy     bz_pi
        lda     #0
        sta     (_bp_pairs),y
        rts
:       ; active?
        asl     a
        tay
        lda     (_bp_act),y
        bne     sact
        jmp     snext
sact:   ldx     bz_i
        lda     bg_gy,x
        asl     a
        asl     a
        asl     a
        clc
        adc     bg_gx,x
        sta     bz_o            ; home cell
        ; neighbor offsets: 0 (home), +1, +8, +9, -7 (right-up) — the 2x2
        ; window the Lua scan used covered (gx-1..gx)x(gy-1..gy) per ball
        ; with i>j de-dup; equivalent coverage: home, right, down, diag,
        ; and right-up, pairing each ball with HIGHER-indexed members.
        lda     bz_o
        jsr     cellpairs
        ldx     bz_i
        lda     bg_gx,x
        cmp     #7
        beq     sdown
        lda     bz_o
        inc     a
        jsr     cellpairs
sdown:  ldx     bz_i
        lda     bg_gy,x
        cmp     #7
        beq     sup
        lda     bz_o
        clc
        adc     #8
        jsr     cellpairs
        ldx     bz_i
        lda     bg_gx,x
        cmp     #7
        beq     sup
        lda     bz_o
        clc
        adc     #9
        jsr     cellpairs
sup:    ldx     bz_i
        lda     bg_gy,x
        beq     snext
        ldx     bz_i
        lda     bg_gx,x
        cmp     #7
        beq     snext
        lda     bz_o
        sec
        sbc     #7
        jsr     cellpairs
snext:  inc     bz_i
        jmp     sloop
.endproc

; A = cell index: pair bz_i with every member of the cell whose (1-based)
; id is > bz_i+1. Clobbers A,X,Y.
.proc cellpairs
        tax
        lda     bg_cnt,x
        beq     done
        sta     bz_t+1          ; count
        txa
        asl     a
        asl     a
        asl     a
        sta     bz_t            ; base = cell*8
mloop:  ldx     bz_t
        lda     bg_mem,x
        tax                     ; member id (1-based)
        dex                     ; 0-based
        cpx     bz_i
        beq     skip
        bcc     skip            ; only pair with higher index
        ; emit pair (bz_i+1, member)
        ldy     bz_pi
        lda     bz_i
        inc     a
        sta     (_bp_pairs),y
        iny
        txa
        inc     a
        sta     (_bp_pairs),y
        iny
        cpy     #62
        bcs     full
        sty     bz_pi
skip:   inc     bz_t
        dec     bz_t+1
        bne     mloop
done:   rts
full:   sty     bz_pi
        rts
.endproc

; negate vx in place (16-bit at bytes 1..2 of element bz_o); zero byte 0,
; fix byte 3 sign
.proc negvx
        ldy     bz_o
        sec
        lda     #0
        sbc     (_bp_vx),y
        sta     (_bp_vx),y
        pha
        iny
        lda     #0
        sbc     (_bp_vx),y
        sta     (_bp_vx),y
        tax
        dey
        dey
        lda     #0
        sta     (_bp_vx),y      ; frac_lo
        iny
        iny
        iny
        txa
        bmi     :+
        lda     #0
        sta     (_bp_vx),y
        pla
        rts
:       lda     #$FF
        sta     (_bp_vx),y
        pla
        rts
.endproc

.proc negvy
        ldy     bz_o
        sec
        lda     #0
        sbc     (_bp_vy),y
        sta     (_bp_vy),y
        iny
        lda     #0
        sbc     (_bp_vy),y
        sta     (_bp_vy),y
        tax
        dey
        dey
        lda     #0
        sta     (_bp_vy),y
        iny
        iny
        iny
        txa
        bmi     :+
        lda     #0
        sta     (_bp_vy),y
        rts
:       lda     #$FF
        sta     (_bp_vy),y
        rts
.endproc

; mark the bounce flag for ball bz_i (X preserved for the caller's clamp)
.proc hurt
        phx
        pha
        ldy     bz_i
        lda     #1
        sta     (_bp_fl),y
        pla
        plx
        rts
.endproc
