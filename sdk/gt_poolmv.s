; ---------------------------------------------------------------------------
; gt.pool_move — bulk pool integration: x[i] += sx[i], y[i] += sy[i] for
; every used slot, optionally with the shift-damping cherry-bomb's particles
; use (v -= v>>3 + v>>5, i.e. *0.84375). ~35 cycles per live entity vs ~250
; through the compiler; a shmup frame moves 80-100 entities.
;   pm_x/pm_y/pm_sx/pm_sy: int arrays (pool SoA fields, stride 2)
;   pm_used: byte array (pool used[] flags)   pm_n: slot count (hi watermark)
;   pm_mode: 0 plain, 1 damp velocities after the move
; ---------------------------------------------------------------------------
.export _gt_poolmv_z, _gt_poolan_z
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
_pm_ox:   .res 1                ; pool_sprs: pixel offset subtracted from x
_pm_oy:   .res 1                ;            and y (sprite centering)

; Pure per-routine scratch — never used for indirect (zp),y addressing, so it
; costs only +1 cycle/access in RAM but keeps zeropage under the 256B ceiling
; (combo-pool's SDK stack is a tight fit). Do NOT move the _pm_* array pointers
; above or the (zp),y ball loops break.
.segment "BSS"
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
        jmp     loop            ; jmp (not bra): moving scratch to BSS grew the
                                ; body's absolute accesses past bra's ±127 reach
.endproc

; pm_t (s16) -= (pm_t>>3) + (pm_t>>5), arithmetic. Uses pm_d scratch.
; RAM scratch (no indirect use) — kept out of zeropage for headroom.
.segment "BSS"
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

; ---------------------------------------------------------------------------
; gt.pool_sprs — bulk 8x8 sprite pass for a pool: every used slot with a
; nonzero cell byte stages a QF_SPR ring entry at (x>>4, y>>4) (the 1/16th-
; pixel convention). ~80 cycles per sprite vs ~570 through spr()'s zp call.
;   reuses pm_x/pm_y/pm_used/pm_n; pm_cells = cell byte array.
; ---------------------------------------------------------------------------
.export _gt_pool_sprs_z
.export _pm_ox, _pm_oy, _pm_cells
.import _gt_q, _gt_qhead, _gt_qtail, _gt_q_pump, _gt_qbank, _gt_draw_mode

QF_SPR2 = $55

.segment "ZEROPAGE" : zeropage
_pm_cells: .res 2               ; MUST stay zp — read via (_pm_cells),y

.segment "BSS"
ps_t:      .res 1               ; plain scratch, no indirect use

.segment "CODE"

.proc _gt_pool_sprs_z
        stz     _gt_draw_mode
        stz     pm_i
loop:   lda     pm_i
        cmp     _pm_n
        bne     :+
        rts
:       tay
        lda     (_pm_used),y
        bne     :+
        jmp     next
:       lda     (_pm_cells),y
        bne     :+
        jmp     next
:       sta     ps_t            ; cell
        ; x>>4 from the int at offset i*2: (lo>>4)|(hi<<4)
        tya
        asl     a
        tay
        lda     (_pm_x),y
        sta     pm_t
        iny
        lda     (_pm_x),y
        sta     pm_t+1
        ; screen x = (x16 >> 4) low byte; negative/large clip via hw bits
        lda     pm_t
        lsr     pm_t+1
        ror     a
        lsr     pm_t+1
        ror     a
        lsr     pm_t+1
        ror     a
        lsr     pm_t+1
        ror     a
        sec
        sbc     _pm_ox
        sta     pm_t            ; px (minus the centering offset)
        dey
        ; y>>4
        lda     (_pm_y),y
        sta     pm_d
        iny
        lda     (_pm_y),y
        sta     pm_d+1
        lda     pm_d
        lsr     pm_d+1
        ror     a
        lsr     pm_d+1
        ror     a
        lsr     pm_d+1
        ror     a
        lsr     pm_d+1
        ror     a
        sec
        sbc     _pm_oy
        sta     pm_d            ; py (minus the centering offset)
        ; stage
slot:   lda     _gt_qhead
        clc
        adc     #8
        cmp     _gt_qtail
        bne     free
        jsr     _gt_q_pump
        bra     slot
free:   ldx     _gt_qhead
        lda     #QF_SPR2
        sta     _gt_q+0,x
        lda     pm_t
        sta     _gt_q+1,x
        lda     pm_d
        sta     _gt_q+2,x
        lda     ps_t
        and     #$0F
        asl     a
        asl     a
        asl     a
        sta     _gt_q+3,x       ; GX = (c & 15) * 8
        lda     ps_t
        and     #$F0
        lsr     a
        sta     _gt_q+4,x       ; GY = (c >> 4) * 8
        lda     #8
        sta     _gt_q+5,x
        sta     _gt_q+6,x
        lda     _gt_qbank
        sta     _gt_q+7,x
        txa
        clc
        adc     #8
        sta     _gt_qhead
        jsr     _gt_q_pump
next:   inc     pm_i
        jmp     loop
.endproc

; ---------------------------------------------------------------------------
; gt.pool_anim — bulk sprite animation: for every used slot,
;   frame[i] += spd[i]; if frame[i] > maxf[i] then frame[i] = 16
; (frames in 16ths, reset-to-first like cherry's animate()). The compiled
; per-enemy version cost ~450 cycles a slot every frame; this is ~22.
; ALL THREE FIELDS ARE BYTE ARRAYS (the pool narrows small fields to
; bytes — an int field here indexes as garbage; frame values stay <= 96
; by construction: maxf < 240 and spd small).
; Reuses pm_x (frame), pm_sx (speed), pm_sy (max), pm_used, pm_n.
; ---------------------------------------------------------------------------
.proc _gt_poolan_z
        ldy     _pm_n
        beq     done
loop:   dey
        lda     (_pm_used),y
        beq     next
        ; frame += spd (bytes)
        lda     (_pm_sx),y
        clc
        adc     (_pm_x),y
        sta     (_pm_x),y
        ; reset when frame > maxf
        cmp     (_pm_sy),y
        bcc     next
        beq     next
        lda     #16
        sta     (_pm_x),y
next:   cpy     #0
        bne     loop
done:   rts
.endproc

; ---------------------------------------------------------------------------
; gt.pool_edraw — the whole per-enemy sprite pass in one walk: derive the
; sheet cell from (aniframe, type, flash) through a per-type descriptor
; table, apply the shake nudge, clip against the 7-bit blit registers, and
; stage the sprite. cherry-bomb's compiled loop cost ~450 cycles an enemy
; before the staging; this is ~90 with clipping.
;
; desc: 3 bytes per type (1-based), (type-1)*3:
;   +0 base cell (the f=1 frame), +1 flash-variant base, +2 mode:
;   0 = skip (the port draws it — cherry's boss), 1 = 8x8, cell = base+f-1,
;   2 = 16x16, cell = base+(f-1)*2 (frames are 2 cells apart on the sheet).
; Field arrays: aniframe/type/flash/shake are BYTES (pool-narrowed);
; x/y are ints in 16ths. flash and shake decrement in here (the compiled
; loop did the same). pe_nudge = 1 on shake-nudge frames (tick%4<2).
; ---------------------------------------------------------------------------
.export _gt_pool_edraw_z
.export _pe_ani, _pe_type, _pe_flash, _pe_shake, _pe_desc, _pe_nudge

; Array pointers stay in zeropage — dereferenced via (zp),y. _pe_nudge also
; MUST stay zp: the C side (gt_api.c) imports it as an extern and cc65 emits a
; zeropage `sta` for it; a BSS address there is a link-time range error.
.segment "ZEROPAGE" : zeropage
_pe_ani:   .res 2
_pe_type:  .res 2
_pe_flash: .res 2
_pe_shake: .res 2
_pe_desc:  .res 2
_pe_nudge: .res 1

; Per-slot scratch: internal to this module, never indirect, so it lives in RAM
; (BSS) to keep the whole SDK zeropage stack under 256 bytes.
.segment "BSS"
pe_f:      .res 1               ; animation frame (1..6)
pe_cell:   .res 1               ; resolved sheet cell
pe_sz:     .res 1               ; sprite size in px (8 or 16)
pe_px:     .res 2               ; screen x (s16 -> s8 range)
pe_py:     .res 2
pe_vx:     .res 1               ; clipped VX
pe_vy:     .res 1
pe_w:      .res 1
pe_h:      .res 1
pe_gxo:    .res 1               ; source offset from left/top clip
pe_gyo:    .res 1
pe_mode:   .res 1               ; desc mode for this slot

.segment "CODE"

.proc _gt_pool_edraw_z
        stz     _gt_draw_mode
        stz     pm_i
loop:   lda     pm_i
        cmp     _pm_n
        bne     :+
        rts
:       tay
        lda     (_pm_used),y
        bne     :+
        jmp     next
:       ; ---- desc lookup: (type-1)*3 into (pe_desc) ----
        lda     (_pe_type),y
        dec     a
        sta     pe_f            ; scratch: type-1
        asl     a
        clc
        adc     pe_f            ; *3
        tax                     ; X = desc offset (types <= 8: fits)
        phy
        txa
        tay
        lda     (_pe_desc),y    ; base
        sta     pe_cell
        iny
        iny
        lda     (_pe_desc),y    ; mode
        sta     pe_mode
        ply
        lda     pe_mode
        bne     :+
        jmp     next            ; mode 0: the port draws this type
:       ; ---- f = aniframe >> 4 ----
        lda     (_pe_ani),y
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        sta     pe_f
        ; ---- flash override ----
        lda     (_pe_flash),y
        beq     @noflash
        dec     a
        sta     (_pe_flash),y
        phy
        txa
        inc     a               ; desc +1 = flash base
        tay
        lda     (_pe_desc),y
        sta     pe_cell
        ply
@noflash:
        ; ---- cell = base + (f-1) [*2 for 16x16] ; size ----
        lda     pe_mode
        cmp     #2
        beq     @m2
        lda     #8
        sta     pe_sz
        lda     pe_f
        dec     a
        bra     @cadd
@m2:    lda     #16
        sta     pe_sz
        lda     pe_f
        dec     a
        asl     a
@cadd:  clc
        adc     pe_cell
        sta     pe_cell

havecell:
        ; ---- px = x >> 4 (arithmetic), py = y >> 4 ----
        tya
        asl     a
        tay
        lda     (_pm_x),y
        sta     pe_px
        iny
        lda     (_pm_x),y
        sta     pe_px+1
        ldx     #4
:       cmp     #$80
        ror     pe_px+1
        ror     pe_px
        lda     pe_px+1
        dex
        bne     :-
        dey
        lda     (_pm_y),y
        sta     pe_py
        iny
        lda     (_pm_y),y
        sta     pe_py+1
        ldx     #4
:       cmp     #$80
        ror     pe_py+1
        ror     pe_py
        lda     pe_py+1
        dex
        bne     :-
        ; ---- shake nudge ----
        ldy     pm_i
        lda     (_pe_shake),y
        beq     @noshake
        dec     a
        sta     (_pe_shake),y
        lda     _pe_nudge
        beq     @noshake
        inc     pe_px
        bne     @noshake
        inc     pe_px+1
@noshake:
        ; ---- clip x: pe_px s16, sprite pe_sz wide ----
        stz     pe_gxo
        lda     pe_sz
        sta     pe_w
        sta     pe_h
        lda     pe_px+1
        beq     @xin
        cmp     #$FF
        bne     @offs           ; |x| large: fully off
        ; negative: ov = -px; skip when ov >= sz
        lda     #0
        sec
        sbc     pe_px
        cmp     pe_sz
        bcs     @offs
        sta     pe_gxo
        lda     pe_sz
        sec
        sbc     pe_gxo
        sta     pe_w
        stz     pe_vx
        bra     @ydo
@offs:  jmp     next
@xin:   lda     pe_px
        bmi     @offs           ; 128..255: off right
        sta     pe_vx
        ; right trim: if px + sz > 128 -> w = 128 - px
        clc
        adc     pe_sz
        cmp     #129
        bcc     @ydo
        lda     #128
        sec
        sbc     pe_vx
        sta     pe_w
@ydo:   ; ---- clip y ----
        stz     pe_gyo
        lda     pe_py+1
        beq     @yin
        cmp     #$FF
        bne     @offs
        lda     #0
        sec
        sbc     pe_py
        cmp     pe_sz
        bcs     @offs
        sta     pe_gyo
        lda     pe_sz
        sec
        sbc     pe_gyo
        sta     pe_h
        stz     pe_vy
        bra     @stage
@yin:   lda     pe_py
        bmi     @offs
        sta     pe_vy
        clc
        adc     pe_sz
        cmp     #129
        bcc     @stage
        lda     #128
        sec
        sbc     pe_vy
        sta     pe_h
@stage: ; ---- ring entry ----
slot:   lda     _gt_qhead
        clc
        adc     #8
        cmp     _gt_qtail
        bne     free
        jsr     _gt_q_pump
        bra     slot
free:   ldx     _gt_qhead
        lda     #QF_SPR2
        sta     _gt_q+0,x
        lda     pe_vx
        sta     _gt_q+1,x
        lda     pe_vy
        sta     _gt_q+2,x
        lda     pe_cell
        and     #$0F
        asl     a
        asl     a
        asl     a
        clc
        adc     pe_gxo
        sta     _gt_q+3,x       ; GX = (c & 15) * 8 + left clip
        lda     pe_cell
        and     #$F0
        lsr     a
        clc
        adc     pe_gyo
        sta     _gt_q+4,x       ; GY = (c >> 4) * 8 + top clip
        lda     pe_w
        sta     _gt_q+5,x
        lda     pe_h
        sta     _gt_q+6,x
        lda     _gt_qbank
        sta     _gt_q+7,x
        txa
        clc
        adc     #8
        sta     _gt_qhead
        jsr     _gt_q_pump
next:   inc     pm_i
        jmp     loop
.endproc

; ---------------------------------------------------------------------------
; gt.cost_decay — combo-pool's per-frame life-cost sum + combo-cooldown
; decay in one walk:  for every slot with act[i] != 0:
;   sum += cost[act[i] - 1];  lm[i] = max(0, lm[i] - 5)
; act is an INT array (stride 2, low byte tested — the ball color/tier),
; lm and cost are BYTE arrays. Returns the sum (int in A/X). ~30 cycles a
; slot against ~350 through the compiled loop.
; Reuses pm_x (act), pm_sx (lm), pm_sy (cost), pm_n.
; ---------------------------------------------------------------------------
.export _gt_cost_decay_z

.segment "ZEROPAGE" : zeropage
cd_sum: .res 2

.segment "CODE"
.proc _gt_cost_decay_z
        stz     cd_sum
        stz     cd_sum+1
        ldx     _pm_n
        dex
loop:   txa
        asl     a
        tay
        lda     (_pm_x),y       ; act low byte (tier 1..7, 0 = free)
        beq     next
        dec     a               ; tier - 1
        tay
        lda     (_pm_sy),y      ; cost[tier-1]
        clc
        adc     cd_sum
        sta     cd_sum
        bcc     :+
        inc     cd_sum+1
:       txa
        tay
        lda     (_pm_sx),y      ; lm[i]
        sec
        sbc     #5
        bcs     :+
        lda     #0
:       sta     (_pm_sx),y
next:   dex
        bpl     loop
        lda     cd_sum
        ldx     cd_sum+1
        rts
.endproc

; ---------------------------------------------------------------------------
; gt.trail_stamp — combo-pool's ball motion trails in one walk. Per slot
; with act[i] != 0 (int array, stride 2, low byte = tier 1..7):
;   px = int(x[i]); py = int(y[i])            (fixed arrays)
;   if |px - tx[i]| + |py - ty[i]| >= 2: stage an 8x8 of sprs[tier-1]
;   at (tx-3, ty-3) with edge clip; if pe_nudge: tx[i]=px, ty[i]=py
; tx/ty/sprs are BYTE arrays. ~60 cycles a slot vs ~250 compiled.
; Reuses pm_x(x) pm_y(y) pm_sx(tx) pm_sy(ty) pe_type(act) pe_desc(sprs)
; pe_nudge(update flag) pm_n.
; ---------------------------------------------------------------------------
.export _gt_trail_z

.segment "ZEROPAGE" : zeropage
tz_px:  .res 1
tz_py:  .res 1
tz_c:   .res 1

.segment "CODE"
.proc _gt_trail_z
        stz     _gt_draw_mode
        stz     pm_i
@loop:  lda     pm_i
        cmp     _pm_n
        bne     :+
        rts
:       asl     a
        tay
        lda     (_pe_type),y    ; act low byte
        bne     :+
        jmp     @next
:       ; cell = sprs[tier-1]
        dec     a
        phy
        tay
        lda     (_pe_desc),y
        sta     tz_c
        ply
        ; px/py = int parts of the fixed positions
.ifdef GT_NUM8
        iny                     ; hi byte of the 8.8 int
        lda     (_pm_x),y
        sta     tz_px
        lda     (_pm_y),y
        sta     tz_py
        dey
.else
        ; 16.16: int lo at element*2 + 2 -> recompute offset i*4+2
        lda     pm_i
        asl     a
        asl     a
        inc     a
        inc     a
        tay
        lda     (_pm_x),y
        sta     tz_px
        lda     (_pm_y),y
        sta     tz_py
.endif
        ; moved? |px - tx| + |py - ty| >= 2
        ldy     pm_i
        lda     tz_px
        sec
        sbc     (_pm_sx),y
        bcs     :+
        eor     #$FF
        inc     a
:       sta     pe_f            ; |dx| (scratch)
        lda     tz_py
        sec
        sbc     (_pm_sy),y
        bcs     :+
        eor     #$FF
        inc     a
:       clc
        adc     pe_f
        cmp     #2
        bcs     :+
        jmp     @upd            ; not moved enough: no stamp
:       ; ---- stamp 8x8 at (tx-3, ty-3) with edge clip ----
        stz     pe_gxo
        stz     pe_gyo
        lda     #8
        sta     pe_w
        sta     pe_h
        lda     (_pm_sx),y
        sec
        sbc     #3
        bcs     @xin            ; >= 0
        ; left overhang: ov = 3 - tx (tx 0..2)
        eor     #$FF
        inc     a               ; ov
        cmp     #8
        bcc     :+
        jmp     @upd            ; fully off (can't: ov<=3) safety
:
        sta     pe_gxo
        lda     #8
        sec
        sbc     pe_gxo
        sta     pe_w
        lda     #0
        bra     @xs
@xin:
@xs:    sta     pe_vx
        ; right trim: if vx + 8 > 128, w = 128 - vx
        clc
        adc     pe_w
        cmp     #129
        bcc     @ydo
        lda     #128
        sec
        sbc     pe_vx
        sta     pe_w
@ydo:   lda     (_pm_sy),y
        sec
        sbc     #3
        bcs     @yin
        eor     #$FF
        inc     a
        sta     pe_gyo
        lda     #8
        sec
        sbc     pe_gyo
        sta     pe_h
        lda     #0
        bra     @ys
@yin:
@ys:    sta     pe_vy
        lda     pe_vy
        clc
        adc     pe_h
        cmp     #129
        bcc     @stage
        lda     #128
        sec
        sbc     pe_vy
        sta     pe_h
@stage: ; ring entry
@slot:  lda     _gt_qhead
        clc
        adc     #8
        cmp     _gt_qtail
        bne     @free
        jsr     _gt_q_pump
        bra     @slot
@free:  ldx     _gt_qhead
        lda     #QF_SPR2
        sta     _gt_q+0,x
        lda     pe_vx
        sta     _gt_q+1,x
        lda     pe_vy
        sta     _gt_q+2,x
        lda     tz_c
        and     #$0F
        asl     a
        asl     a
        asl     a
        clc
        adc     pe_gxo
        sta     _gt_q+3,x
        lda     tz_c
        and     #$F0
        lsr     a
        clc
        adc     pe_gyo
        sta     _gt_q+4,x
        lda     pe_w
        sta     _gt_q+5,x
        lda     pe_h
        sta     _gt_q+6,x
        lda     _gt_qbank
        sta     _gt_q+7,x
        txa
        clc
        adc     #8
        sta     _gt_qhead
        jsr     _gt_q_pump
@upd:   ; update the anchors on flagged frames
        lda     _pe_nudge
        beq     @next
        ldy     pm_i
        lda     tz_px
        sta     (_pm_sx),y
        lda     tz_py
        sta     (_pm_sy),y
@next:  inc     pm_i
        jmp     @loop
.endproc
