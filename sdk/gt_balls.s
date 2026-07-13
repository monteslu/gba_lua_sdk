; ---------------------------------------------------------------------------
; gt.balls - one physics substep for a 2D ball table, in 65C02.
;
; Combo-pool's compiled movement + spatial grid + pair scan measured ~57k
; per frame (two substeps) with 45% of the frame in cc65's 32-bit fixed
; helpers. This engine runs one substep in ~4k: half-velocity integration,
; wall bounces with clamp + a per-ball bounce flag, an 8x8 spatial-grid
; rebuild, and a contact-pair scan. The branchy impulse/merge resolution
; stays in Lua (do_coll), fed from the pair list this writes - collisions
; are rare events; the scan is the every-frame cost.
;
; The port's arrays stay 16.16 fixed (4 bytes/element, little-endian:
; frac_lo, frac_hi, int_lo, int_hi). The engine reads/writes bytes 1..2 -
; the embedded 8.8 core - and zeroes byte 0 / sign-extends byte 3 on write,
; so the Lua side keeps operating on the same values seamlessly (physics
; precision 1/256 px; the lowest fraction byte truncates each step).
; GT_NUM8 builds (-D GT_NUM8): the arrays ARE 8.8 ints (stride 2, the
; whole element is the core) - offsets halve and the frac/sign fixups
; vanish; everything else is identical.
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
; Walls are PARAMETERS (gt.balls_bounds / the bp_x0..bp_vymin bytes below):
; x clamps to [x0,x1] with bounce, y bounces at <y0, and at >=y1 only while
; vy's 8.8 magnitude >= vymin (vymin=0 -> always bounce; a nonzero cutoff is
; how balls come to REST on the floor instead of micro-bouncing forever).
; Defaults (set by the C wrapper on first use) are the full 128px screen for
; a 16x16 ball: 0,0,120,120, vymin 0.
; ---------------------------------------------------------------------------
.export _gt_balls_z
.export _bp_x, _bp_y, _bp_vx, _bp_vy, _bp_act, _bp_fl, _bp_pairs, _bp_n
.export _bp_x0, _bp_y0, _bp_x1, _bp_y1, _bp_vymin
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
; wall bounds (see the header): plain BSS, zp is too scarce to spend here.
; cmp abs costs +2 cycles over an immediate = ~0.5% of a 28-ball frame.
_bp_x0:    .res 1
_bp_y0:    .res 1
_bp_x1:    .res 1
_bp_y1:    .res 1
_bp_vymin: .res 1
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
:       ; offsets: act = i*2; element = i*4+1 (the embedded 8.8) or i*2 num8
        asl     a
        sta     bz_o2
.ifdef GT_NUM8
        sta     bz_o
.else
        asl     a
        inc     a
        sta     bz_o
.endif
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
        ; ---- wall x: clamp x0..x1 int-part (SIGNED 8.8) ----
        ; The old test used bmi/bpl and a fast ball that overshot the RIGHT wall
        ; past 128 read as NEGATIVE, tripped "x<x0", and teleported to the left
        ; wall (the "balls wrap across the screen" bug). But a ball off the LEFT
        ; (negative x) ALSO has hi byte >=128, so we split by sign: bit7 set =>
        ; off the left; else an unsigned >=x1 is the right wall.
        cpx     #128
        bcs     xlow            ; hi byte >= 128 => negative x => off the left
        cpx     _bp_x1
        bcs     xhigh           ; x >= x1 (right wall, incl. overshoot)
        cpx     _bp_x0
        bcc     xlow            ; x < x0 (left)
        bra     xstore
xlow:   ; x < x0: negate vx, park just INSIDE the wall (x0+1, not x0) so a ball
        ; shoved back by a neighbour's collision push isn't re-clamped onto the
        ; exact boundary every frame - the original nudges inward (b.x += b.vx);
        ; this 1px inset is the cheap equivalent that un-pins wall/corner jams
        ; (the "balls stuck in the corner, stuck bounce sound, particle spam").
        jsr     negvx
        lda     #0
        ldx     _bp_x0
        inx
        jsr     hurt
        bra     xstore
xhigh:  ; x >= x1: negate vx, park just inside at x1-1 (see xlow)
        jsr     negvx
        lda     #0
        ldx     _bp_x1
        dex
        jsr     hurt
xstore: ; write x back (A=lo X=hi)
.ifdef GT_NUM8
        ldy     bz_o
        sta     (_bp_x),y
        iny
        pha
        txa
        sta     (_bp_x),y
        pla
.else
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
.endif
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
        ; ---- wall y: <y0 bounce; >=y1 bounce only when vy >= vymin (8.8 lo) ----
        ; The position is SIGNED 8.8. hi byte bit7 set => y is NEGATIVE => the
        ; ball punched through the TOP: clamp to the top wall (NOT ">=y1", which
        ; stranded a ball at y=-50 off-screen forever - the earlier unsigned-only
        ; fix read byte 206 as "bottom" and left it there). Then, for on-screen
        ; y, an unsigned >=y1 catches the bottom incl. a small positive overshoot.
        cpx     #128
        bcs     ylow            ; hi byte >= 128 => negative y => off the top
        cpx     _bp_y1
        bcs     ymaybe          ; y >= y1 (bottom, incl. overshoot)
        cpx     _bp_y0
        bcc     ylow            ; y < y0 (top)
        bra     ystore
ylow:   jsr     negvy
        lda     #0
        ldx     _bp_y0          ; park just inside the top wall (see xlow inset)
        inx
        jsr     hurt
        bra     ystore
ymaybe: ; y >= y1: only a wall if vy fast enough (hi>0, or hi==0 && lo>=vymin)
        ldy     bz_o
        iny
        lda     (_bp_vy),y      ; vy hi (post-negation state not yet - raw)
        bmi     ystore          ; moving up: pass
        bne     ywall
        dey
        lda     (_bp_vy),y
        cmp     _bp_vymin
        bcc     ystore
ywall:  jsr     negvy
        lda     #0
        ldx     _bp_y1          ; park just inside the bottom wall (see xlow inset)
        dex
        jsr     hurt
ystore:
.ifdef GT_NUM8
        ldy     bz_o
        sta     (_bp_y),y
        iny
        pha
        txa
        sta     (_bp_y),y
        pla
.else
        ldy     bz_o
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
.endif
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
        ; neighbor offsets: 0 (home), +1, +8, +9, -7 (right-up) - the 2x2
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
.ifndef GT_NUM8
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
.endif
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
.ifndef GT_NUM8
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
.endif
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

; ---------------------------------------------------------------------------
; gt_balls_drag - per-frame drag on the full 16.16 velocities:
;   v -= (v >> 6) + (v >> 8)   computed as   v -= (v >> 8) * 5
; ((v>>8)<<2 differs from v>>6 by at most 3/65536 per frame - imperceptible;
; the byte-shift form runs ~130 cycles/ball vs ~500 through cc65's long
; helpers). Uses bp_vx/bp_vy/bp_act/bp_n from the step contract.
; ---------------------------------------------------------------------------
.export _gt_balls_drag_z

.segment "ZEROPAGE" : zeropage
bd_d:   .res 4                  ; v >> 8 (sign-extended)
bd_s:   .res 1                  ; the sign-extension byte of d
bd_o:   .res 1                  ; element byte offset (i*4)

.segment "CODE"

; drag one velocity at (ptr),bd_o
.ifdef GT_NUM8
; 8.8: v -= (v>>6) + (v>>8) on the FULL 16-bit velocity (arithmetic shifts).
; The old code took d = the HI BYTE only (v>>8 as an int), so any velocity
; below 1.0 (hi byte 0) got ZERO drag - slow balls rolled forever. Shift the
; whole 16-bit word so the sub-integer bits decay too.  bz_t = v>>6 + v>>8.
.macro DRAG1 ptr
        ; bd_d = v (16-bit working copy)
        ldy     bd_o
        lda     (ptr),y
        sta     bd_d
        iny
        lda     (ptr),y
        sta     bd_d+1
        ; bz_t = v >> 6  (arithmetic, sign-preserving)
        lda     bd_d
        sta     bz_t
        lda     bd_d+1
        sta     bz_t+1
        ldx     #6
:       lda     bz_t+1
        cmp     #$80            ; carry = sign bit of the hi byte
        ror     bz_t+1
        ror     bz_t
        dex
        bne     :-
        ; bd_d = v >> 8  (arithmetic): hi -> lo, sign-extend hi
        lda     bd_d+1
        sta     bd_d
        bpl     :+
        lda     #$FF
        bra     :++
:       lda     #$00
:       sta     bd_d+1
        ; bz_t += bd_d
        clc
        lda     bz_t
        adc     bd_d
        sta     bz_t
        lda     bz_t+1
        adc     bd_d+1
        sta     bz_t+1
        ; v -= bz_t
        ldy     bd_o
        sec
        lda     (ptr),y
        sbc     bz_t
        sta     (ptr),y
        iny
        lda     (ptr),y
        sbc     bz_t+1
        sta     (ptr),y
.endmacro
.else
.macro DRAG1 ptr
        .local pos, sub
        ; d = v >> 8: bytes 1..3, sign-extend the top
        ldy     bd_o
        iny
        lda     (ptr),y
        sta     bd_d
        iny
        lda     (ptr),y
        sta     bd_d+1
        iny
        lda     (ptr),y
        sta     bd_d+2
        bpl     pos
        lda     #$FF
        bra     :+
pos:    lda     #0
:       sta     bd_d+3
        sta     bd_s            ; keep s for the top-byte add below
        ; d5 = (d << 2) + d
        lda     bd_d
        asl     a
        rol     bd_d+1
        rol     bd_d+2
        rol     bd_d+3
        asl     a
        rol     bd_d+1
        rol     bd_d+2
        rol     bd_d+3
        sta     bz_t            ; d<<2 low byte (hi bytes shifted in place)
        ; now add the ORIGINAL d (recompute bytes 1..3 of v):
        ldy     bd_o
        iny
        clc
        lda     bz_t
        adc     (ptr),y
        sta     bz_t
        lda     bd_d+1
        iny
        adc     (ptr),y
        sta     bd_d+1
        lda     bd_d+2
        iny
        adc     (ptr),y
        sta     bd_d+2
        lda     bd_d+3
        adc     bd_s            ; top byte: d<<2 top + s + carry
        sta     bd_d+3
sub:    ; v -= d5   (d5 = bz_t, bd_d+1, bd_d+2, bd_d+3)
        ldy     bd_o
        sec
        lda     (ptr),y
        sbc     bz_t
        sta     (ptr),y
        iny
        lda     (ptr),y
        sbc     bd_d+1
        sta     (ptr),y
        iny
        lda     (ptr),y
        sbc     bd_d+2
        sta     (ptr),y
        iny
        lda     (ptr),y
        sbc     bd_d+3
        sta     (ptr),y
.endmacro
.endif

.proc _gt_balls_drag_z
        stz     bz_i
loop:   lda     bz_i
        cmp     _bp_n
        bne     :+
        rts
:       asl     a
        tay
        lda     (_bp_act),y
        bne     act
        jmp     next
act:    lda     bz_i
        asl     a
.ifndef GT_NUM8
        asl     a
.endif
        sta     bd_o
        DRAG1   _bp_vx
        DRAG1   _bp_vy
next:   inc     bz_i
        jmp     loop
.endproc

; ---------------------------------------------------------------------------
; gt_parts_step - particle pool integrator for 16.16 SoA pools:
;   for every used slot: x += vx; y += vy; v *= (1 - 1/32 - 1/64)
; The damping is v -= (v>>6)*3 == (v>>5)+(v>>6) exactly (both = floor terms
; summed; ~2 lsb of 1/65536 units apart from the compiled form per frame).
; A merge burst runs ~20 live particles x ~2.5k cycles through the long
; helpers; this is ~350 per particle.
;   pp_x/pp_y/pp_vx/pp_vy: long arrays; pp_u: used bytes; pp_n: slots
; ---------------------------------------------------------------------------
.export _gt_parts_step_z
.export _pp_x, _pp_y, _pp_vx, _pp_vy, _pp_u, _pp_n

.segment "ZEROPAGE" : zeropage
_pp_x:  .res 2
_pp_y:  .res 2
_pp_vx: .res 2
_pp_vy: .res 2
_pp_u:  .res 2
_pp_n:  .res 1
pp_o:   .res 1

.segment "CODE"

; element add: (dst),pp_o += (src),pp_o
.ifdef GT_NUM8
.macro ADD32 dst, src
        ldy     pp_o
        clc
        lda     (dst),y
        adc     (src),y
        sta     (dst),y
        iny
        lda     (dst),y
        adc     (src),y
        sta     (dst),y
.endmacro
.else
.macro ADD32 dst, src
        ldy     pp_o
        clc
        lda     (dst),y
        adc     (src),y
        sta     (dst),y
        iny
        lda     (dst),y
        adc     (src),y
        sta     (dst),y
        iny
        lda     (dst),y
        adc     (src),y
        sta     (dst),y
        iny
        lda     (dst),y
        adc     (src),y
        sta     (dst),y
.endmacro
.endif

; damp the velocity at (ptr),pp_o: v -= (v>>6)*3
; (>>6 = byte-shift >>8 then <<2; d3 = (d<<1) + d)
.ifdef GT_NUM8
; 8.8: d = (v>>8)<<2 in 16 bits, v -= d + (d<<1)
.macro DAMP32 ptr
        ldy     pp_o
        iny
        lda     (ptr),y         ; v >> 8, signed
        sta     bd_d
        bpl     :+
        lda     #$FF
        bra     :++
:       lda     #0
:       sta     bd_d+1
        asl     bd_d
        rol     bd_d+1
        asl     bd_d
        rol     bd_d+1          ; d = v>>6
        lda     bd_d
        sta     bz_t
        lda     bd_d+1
        sta     bz_t+1
        asl     bd_d
        rol     bd_d+1          ; d<<1
        clc
        lda     bd_d
        adc     bz_t
        sta     bd_d
        lda     bd_d+1
        adc     bz_t+1
        sta     bd_d+1          ; d3 = 3*(v>>6)
        ldy     pp_o
        sec
        lda     (ptr),y
        sbc     bd_d
        sta     (ptr),y
        iny
        lda     (ptr),y
        sbc     bd_d+1
        sta     (ptr),y
.endmacro
.else
.macro DAMP32 ptr
        ; d = v >> 8 (bytes 1..3, sign-extended) -> bd_d, s -> bd_s
        ldy     pp_o
        iny
        lda     (ptr),y
        sta     bd_d
        iny
        lda     (ptr),y
        sta     bd_d+1
        iny
        lda     (ptr),y
        sta     bd_d+2
        bpl     :+
        lda     #$FF
        bra     :++
:       lda     #0
:       sta     bd_d+3
        sta     bd_s
        ; d <<= 2  -> v>>6
        asl     bd_d
        rol     bd_d+1
        rol     bd_d+2
        rol     bd_d+3
        asl     bd_d
        rol     bd_d+1
        rol     bd_d+2
        rol     bd_d+3
        ; d3 = d + (d >> 1)?? NO: v>>5 + v>>6 = (v>>6)*3 = d + d>>?? d IS v>>6;
        ; d*3 = (d<<1) + d - shift a copy left once into bz_t/bd extras
        lda     bd_d
        sta     bz_t
        lda     bd_d+1
        sta     bz_t+1
        lda     bd_d+2
        sta     bd_o            ; borrow zp bytes for the copy's high half
        lda     bd_d+3
        sta     bz_i
        asl     bd_d
        rol     bd_d+1
        rol     bd_d+2
        rol     bd_d+3
        clc
        lda     bd_d
        adc     bz_t
        sta     bd_d
        lda     bd_d+1
        adc     bz_t+1
        sta     bd_d+1
        lda     bd_d+2
        adc     bd_o
        sta     bd_d+2
        lda     bd_d+3
        adc     bz_i
        sta     bd_d+3
        ; v -= d3
        ldy     pp_o
        sec
        lda     (ptr),y
        sbc     bd_d
        sta     (ptr),y
        iny
        lda     (ptr),y
        sbc     bd_d+1
        sta     (ptr),y
        iny
        lda     (ptr),y
        sbc     bd_d+2
        sta     (ptr),y
        iny
        lda     (ptr),y
        sbc     bd_d+3
        sta     (ptr),y
.endmacro
.endif

.proc _gt_parts_step_z
        ldx     #0
loop:   cpx     _pp_n
        bne     :+
        rts
:       txa
        tay
        lda     (_pp_u),y
        bne     live
        jmp     next
live:   txa
        asl     a
.ifndef GT_NUM8
        asl     a
.endif
        sta     pp_o
        phx
        ADD32   _pp_x, _pp_vx
        ADD32   _pp_y, _pp_vy
        DAMP32  _pp_vx
        DAMP32  _pp_vy
        plx
next:   inx
        jmp     loop
.endproc

; ---------------------------------------------------------------------------
; gt_balls_draw - one 16x16 QF_SPR per nonzero cell byte, positions from the
; 16.16 fixed arrays' integer bytes, centered at (-8, -7) like the port's
; draw_ball_spr. ~80 cycles per ball vs ~700 through flr + the spr() C path.
;   bp_x/bp_y: fixed arrays; bp_fl reused as the cells byte array; bp_n count
; ---------------------------------------------------------------------------
.export _gt_balls_draw_z
.import _gt_q, _gt_qhead, _gt_qtail, _gt_q_pump, _gt_qbank, _gt_draw_mode

QF_SPRB = $55

.segment "ZEROPAGE" : zeropage
bq_c:   .res 1

.segment "CODE"
.proc _gt_balls_draw_z
        stz     _gt_draw_mode
        stz     bz_i
loop:   lda     bz_i
        cmp     _bp_n
        bne     :+
        rts
:       tay
        lda     (_bp_fl),y      ; cell byte (0 = skip)
        bne     live
        jmp     next
live:   sta     bq_c
        ; element byte offset of the INT part: i*4+2, or i*2+1 in 8.8
        tya
        asl     a
.ifdef GT_NUM8
        inc     a
.else
        asl     a
        inc     a
        inc     a
.endif
        sta     bz_o
slot:   lda     _gt_qhead
        clc
        adc     #8
        cmp     _gt_qtail
        bne     free
        jsr     _gt_q_pump
        bra     slot
free:   ldx     _gt_qhead
        lda     #QF_SPRB
        sta     _gt_q+0,x
        ; defaults: full 16x16 cell, no clip
        lda     #16
        sta     _gt_q+5,x
        sta     _gt_q+6,x
        lda     bq_c
        and     #$0F
        asl     a
        asl     a
        asl     a
        sta     _gt_q+3,x       ; GX
        lda     bq_c
        and     #$F0
        lsr     a
        sta     _gt_q+4,x       ; GY
        ; ---- x: the blit registers are 7-bit, so edge overhang must CLIP
        ; (a negative or >112 VX byte aliases across the screen - the
        ; combo-pool edge-garbage bug) ----
        ldy     bz_o
        lda     (_bp_x),y
        sec
        sbc     #8              ; vx = int(x) - 8
        cmp     #128
        bcc     bxin            ; 0..127: maybe right-trim
        ; negative (byte 248..255 for balls clamped >= 4): left overhang
        eor     #$FF
        inc     a               ; ov = -vx (1..8)
        pha
        clc
        adc     _gt_q+3,x
        sta     _gt_q+3,x       ; GX += ov
        pla
        eor     #$FF
        sec
        adc     #16             ; W = 16 - ov  (A = 16 - ov)
        sta     _gt_q+5,x
        stz     _gt_q+1,x       ; VX = 0
        bra     bxdone
bxin:   sta     _gt_q+1,x
        ; right trim: if vx > 112, W = 128 - vx
        cmp     #113
        bcc     bxdone
        eor     #$FF
        sec
        adc     #128            ; A = 128 - vx
        sta     _gt_q+5,x
bxdone: ; ---- y: same treatment ----
        ldy     bz_o
        lda     (_bp_y),y
        sec
        sbc     #7              ; vy = int(y) - 7
        cmp     #128
        bcc     byin
        eor     #$FF
        inc     a               ; ov = -vy
        pha
        clc
        adc     _gt_q+4,x
        sta     _gt_q+4,x       ; GY += ov
        pla
        eor     #$FF
        sec
        adc     #16
        sta     _gt_q+6,x       ; H = 16 - ov
        stz     _gt_q+2,x
        bra     bydone
byin:   sta     _gt_q+2,x
        cmp     #113
        bcc     bydone
        eor     #$FF
        sec
        adc     #128
        sta     _gt_q+6,x
bydone:
        lda     _gt_qbank
        sta     _gt_q+7,x
        txa
        clc
        adc     #8
        sta     _gt_qhead
        jsr     _gt_q_pump
next:   inc     bz_i
        jmp     loop
.endproc
