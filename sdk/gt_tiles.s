; ---------------------------------------------------------------------------
; gt.tiles_draw — the visible-window tile scan in 65C02.
;
; The compiled scan (celeste2 draw_tiles: 17x17 cells x bget + flag checks +
; spr calls) measured ~38k/frame; this is ~8-10k: byte map walked with a
; zp pointer, flags via (ptr),y, QF_SPR ring entries staged in place with
; incremental screen coordinates (one 16-bit camera subtract per frame,
; +8 per cell/row after that). Cells with flag bit0 clear are SKIPPED —
; the port draws its special tiles (animated checkpoints, edge variants)
; from a small precomputed list on top.
;
; zp contract (set by the C wrapper):
;   _tp_map = &map[j0*lvlw + i0]  (byte tiles, row-major)
;   _tp_fl  = flags array base
;   _tp_w   = i1-i0+1 (cells per row, 1..17)
;   _tp_h   = j1-j0+1 (rows, 1..17)
;   _tp_stride = lvlw - _tp_w (bytes to skip to the next row start)
;   _tp_sx  = i0*8 - cam_x (starting screen x, s16 low byte kept)
;   _tp_sy  = j0*8 - cam_y
;   gt_qbank provides the entry+7 byte (sheet bank + hw clips).
; ---------------------------------------------------------------------------
.export _gt_tiles_z
.export _tp_map, _tp_fl, _tp_w, _tp_h, _tp_stride, _tp_sx, _tp_sy
.import _gt_q, _gt_qhead, _gt_qtail, _gt_q_pump, _gt_qbank, _gt_draw_mode
.PC02

QF_SPR = $55

.segment "ZEROPAGE" : zeropage
_tp_map:    .res 2
_tp_fl:     .res 2
_tp_w:      .res 1
_tp_h:      .res 1
_tp_stride: .res 1
_tp_sx:     .res 1               ; current cell screen x (low byte; hw clips)
_tp_sy:     .res 1               ; current row screen y
tp_x0:     .res 1               ; row-start screen x
tp_i:      .res 1               ; cells left in this row

.segment "CODE"

.proc _gt_tiles_z
        stz     _gt_draw_mode
        lda     _tp_sx
        sta     tp_x0
row:    lda     _tp_w
        sta     tp_i
        lda     tp_x0
        sta     _tp_sx
cell:   lda     (_tp_map)
        beq     skip            ; empty
        bmi     skip            ; t >= 128
        tay
        lda     (_tp_fl),y
        lsr     a
        bcc     skip            ; flag bit0 clear: special/undrawn
        ; ---- stage a QF_SPR entry for tile Y ----
slot:   lda     _gt_qhead
        clc
        adc     #8
        cmp     _gt_qtail
        bne     free
        jsr     _gt_q_pump
        bra     slot
free:   ldx     _gt_qhead
        lda     #QF_SPR
        sta     _gt_q+0,x
        lda     _tp_sx
        sta     _gt_q+1,x       ; VX (hw clip handles partial edges)
        lda     _tp_sy
        sta     _gt_q+2,x       ; VY
        tya
        and     #$0F
        asl     a
        asl     a
        asl     a
        sta     _gt_q+3,x       ; GX = (t & 15) * 8
        tya
        and     #$F0
        lsr     a
        sta     _gt_q+4,x       ; GY = (t >> 4) * 8
        lda     #8
        sta     _gt_q+5,x       ; W
        sta     _gt_q+6,x       ; H
        lda     _gt_qbank
        sta     _gt_q+7,x
        txa
        clc
        adc     #8
        sta     _gt_qhead
        jsr     _gt_q_pump
skip:   ; ---- next cell ----
        inc     _tp_map
        bne     :+
        inc     _tp_map+1
:       lda     _tp_sx
        clc
        adc     #8
        sta     _tp_sx
        dec     tp_i
        beq     rowend
        jmp     cell
rowend:
        ; ---- next row ----
        lda     _tp_map
        clc
        adc     _tp_stride
        sta     _tp_map
        bcc     :+
        inc     _tp_map+1
:       lda     _tp_sy
        clc
        adc     #8
        sta     _tp_sy
        dec     _tp_h
        beq     alldone
        jmp     row
alldone:
        rts
.endproc
