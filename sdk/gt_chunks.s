; ---------------------------------------------------------------------------
; gt.chunks_draw — 24px atlas-chunk grid renderer (driftmania's track), asm.
;
; Walks a cell window of a packed int grid: each cell cg holds
;   road  = cg & 31          -> ckd LUT -> k: k>=16 atlas chunk, else flat
;   decal = (cg >> 5) & 31   -> ckd LUT (with a caller offset added by Lua
;                               convention inside the LUT copy passed here)
;   prop  = cg >> 10         -> collected to a byte list for the Lua pass
; Flat runs of the same color merge into one wide fill (the row scan keeps
; a run open while consecutive cells are plain same-color solids).
; The compiled loop measured ~62k/frame; this stages ring entries directly.
;
; zp contract (C wrapper):
;   ck_grid : int grid ptr, positioned at row cy0, stride ck_stride cells
;   ck_lut  : road ckd LUT (bytes);  ck_lut2: decal ckd LUT (bytes)
;   ck_w/ck_h: window cells;  ck_x0/ck_y0: world px of the window origin
;             (24*cx0 - cam_x etc, precomputed screen-space by the caller)
;   ck_props: byte list out — triples (propidx, cellx, celly), 0-terminated
;   gt_qbank in entry+7 for atlas blits; fills pre-invert via p8pal.
; ---------------------------------------------------------------------------
.export _gt_chunks_z
.export _ck_grid, _ck_lut, _ck_lut2, _ck_w, _ck_h, _ck_stride
.export _ck_x0, _ck_y0, _ck_props
.import _gt_q, _gt_qhead, _gt_qtail, _gt_q_pump, _gt_qbank, _gt_draw_mode
.import _p8pal
.PC02

QF_RECT = $CD
QF_COPY = $57

.segment "ZEROPAGE" : zeropage
_ck_grid:   .res 2
_ck_lut:    .res 2
_ck_lut2:   .res 2
_ck_w:      .res 1
_ck_h:      .res 1
_ck_stride: .res 1              ; cells to skip to next row (stride - w)*2 bytes
_ck_x0:     .res 1              ; screen x of window origin
_ck_y0:     .res 1
_ck_props:  .res 2
ck_i:       .res 1              ; cells left in row
ck_sx:      .res 1              ; current cell screen x
ck_cg:      .res 2              ; current cell value
ck_runc:    .res 1              ; open run color byte (inverted); 0 = none
ck_runx:    .res 1              ; run start x
ck_runw:    .res 1              ; run width px
ck_pi:      .res 1              ; props write index
ck_t:       .res 1

.segment "CODE"

; stage a flat fill: x=ck_runx w=ck_runw color=ck_runc at row ck_y0, 24 tall
.proc flushrun
        lda     ck_runc
        bne     :+
        rts
:
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
        lda     ck_runx
        sta     _gt_q+1,x
        lda     _ck_y0
        sta     _gt_q+2,x
        stz     _gt_q+3,x
        stz     _gt_q+4,x
        lda     ck_runw
        sta     _gt_q+5,x
        lda     #24
        sta     _gt_q+6,x
        lda     ck_runc
        sta     _gt_q+7,x
        txa
        clc
        adc     #8
        sta     _gt_qhead
        phy
        jsr     _gt_q_pump
        ply
        stz     ck_runc
        rts
.endproc

; stage an atlas chunk blit: A = k (16..), at ck_sx/ck_y0
.proc chunkblit
        pha
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
        lda     #QF_COPY
        sta     _gt_q+0,x
        lda     ck_sx
        sta     _gt_q+1,x
        lda     _ck_y0
        sta     _gt_q+2,x
        pla
        sec
        sbc     #16             ; atlas index
        pha
        and     #7
        sta     ck_t            ; *24 = *16 + *8
        asl     a
        asl     a
        asl     a               ; *8
        sta     _gt_q+3,x
        lda     ck_t
        asl     a
        asl     a
        asl     a
        asl     a               ; *16
        clc
        adc     _gt_q+3,x
        sta     _gt_q+3,x       ; GX = (k&7)*24
        pla
        lsr     a
        lsr     a
        lsr     a               ; row = idx>>3
        sta     ck_t
        asl     a
        asl     a
        asl     a
        sta     _gt_q+4,x
        lda     ck_t
        asl     a
        asl     a
        asl     a
        asl     a
        clc
        adc     _gt_q+4,x
        sta     _gt_q+4,x       ; GY = (idx>>3)*24
        lda     #24
        sta     _gt_q+5,x
        sta     _gt_q+6,x
        lda     _gt_qbank
        ora     #1              ; BG_GROUP: the atlas lives on the bg canvas
        sta     _gt_q+7,x
        txa
        clc
        adc     #8
        sta     _gt_qhead
        phy
        jsr     _gt_q_pump
        ply
        rts
.endproc

.proc _gt_chunks_z
        stz     _gt_draw_mode
        stz     ck_pi
row:    lda     _ck_w
        sta     ck_i
        lda     _ck_x0
        sta     ck_sx
        stz     ck_runc
cell:   ldy     #0
        lda     (_ck_grid),y
        sta     ck_cg
        iny
        lda     (_ck_grid),y
        sta     ck_cg+1
        ora     ck_cg
        bne     :+
        jmp     empty           ; cg == 0: nothing (breaks any run)
:
        ; ---- road layer: r = cg & 31 ----
        lda     ck_cg
        and     #31
        bne     :+
        jmp     roaddone        ; no road part
:
        tay
        lda     (_ck_lut),y     ; k = ckd[r]
        cmp     #16
        bcs     atlas
        ; flat color k: run-merge. Only when NO decal/prop on this cell.
        tay
        lda     ck_cg+1
        bne     flatsolo        ; ANY hi bit: decal(8,9)/prop present
        lda     ck_cg
        and     #%11100000
        bne     flatsolo
        ; pure flat: extend or start the run
        lda     _p8pal,y
        eor     #$FF
        cmp     ck_runc
        beq     extend
        phy
        jsr     flushrun        ; different color: flush, start new
        ply
        lda     _p8pal,y
        eor     #$FF
        sta     ck_runc
        lda     ck_sx
        sta     ck_runx
        stz     ck_runw
extend: lda     ck_runw
        clc
        adc     #24
        sta     ck_runw
        bra     roaddone2
flatsolo:
        phy
        jsr     flushrun
        ply
        ; single flat fill for this cell (has decal/prop on top)
        lda     _p8pal,y
        eor     #$FF
        sta     ck_runc
        lda     ck_sx
        sta     ck_runx
        lda     #24
        sta     ck_runw
        jsr     flushrun
        bra     roaddone
atlas:  pha
        jsr     flushrun
        pla
        jsr     chunkblit
roaddone:
roaddone2:
        ; ---- decal layer: d = (cg >> 5) & 31 ----
        lda     ck_cg+1
        asl     ck_cg
        rol     a
        asl     ck_cg
        rol     a
        asl     ck_cg
        rol     a               ; a = cg >> 5 (low 8 of it)
        and     #31
        beq     decaldone
        tay
        lda     (_ck_lut2),y    ; k2 = ckd[d + decb] via the offset LUT
        cmp     #16
        bcc     decalflat
        jsr     chunkblit
        bra     decaldone
decalflat:
        ; flat decal: full-cell fill in color k2
        tay
        lda     _p8pal,y
        eor     #$FF
        pha
        lda     ck_runc         ; (no open run can exist here — flushed)
        pla
        sta     ck_runc
        lda     ck_sx
        sta     ck_runx
        lda     #24
        sta     ck_runw
        jsr     flushrun
decaldone:
        ; ---- prop: p = cg >> 10 -> props list (propidx, sx, y0) ----
        lda     ck_cg+1
        lsr     a
        lsr     a               ; cg >> 10
        beq     empty2
        ldy     ck_pi
        sta     (_ck_props),y
        iny
        lda     ck_sx
        sta     (_ck_props),y
        iny
        lda     _ck_y0
        sta     (_ck_props),y
        iny
        cpy     #45
        bcs     empty2
        sty     ck_pi
        bra     next
empty:  ; cg==0 breaks any open flat run
        jsr     flushrun
empty2:
next:   ; advance cell
        lda     _ck_grid
        clc
        adc     #2
        sta     _ck_grid
        bcc     :+
        inc     _ck_grid+1
:       lda     ck_sx
        clc
        adc     #24
        sta     ck_sx
        dec     ck_i
        beq     rowdone
        jmp     cell
rowdone:
        jsr     flushrun
        ; next row: skip stride cells
        lda     _ck_stride
        asl     a               ; *2 bytes
        clc
        adc     _ck_grid
        sta     _ck_grid
        bcc     :+
        inc     _ck_grid+1
:       lda     _ck_y0
        clc
        adc     #24
        sta     _ck_y0
        dec     _ck_h
        beq     done
        jmp     row
done:   ; terminate props
        ldy     ck_pi
        lda     #0
        sta     (_ck_props),y
        rts
.endproc
