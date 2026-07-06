; ---------------------------------------------------------------------------
; gt_blitq.s — the async blit queue + the zero-page fastcall ABI.
;
; WHY (measured, SPEED_PLAN.md): the old runtime spin-waited on the blitter
; and re-programmed modes inside EVERY primitive call — spr() cost 932
; cycles, rectfill() 1,864, before drawing a pixel. Here a primitive just
; appends an 8-byte descriptor and returns; the blit-complete IRQ programs
; the next descriptor the moment the previous blit finishes. Drawing
; overlaps game logic completely; the CPU cost of a blit is the enqueue.
;
; Queue entry (8 bytes, X-indexed so the 8-bit index wraps the 256-byte
; ring for free):
;   +0 dma_flags byte for this blit (RECT: colorfill+opaque; SPR: gcarry)
;   +1 VX  +2 VY  +3 GX  +4 GY  +5 WIDTH  +6 HEIGHT
;   +7 COLOR (pre-inverted by the producer; ignored by SPR blits)
;
; EMULATOR RULE (the flicker fix, now load-bearing): the emulator
; materializes a finished blit's pixels lazily using the LIVE registers, so
; gt_q_kick touches $4000 with a dummy read BEFORE writing new flags/regs —
; that forces the catch-up under the state the blit actually ran with.
; Harmless on hardware.
;
; The zero-page ABI: the compiler stores builtin args into _gt_a0.._gt_a5
; (sta zp) instead of pushing cc65 stack words, and the runtime reads them
; the same way. Camera and pad state live here too so btn()/camera() emit
; as inline zp ops.
; ---------------------------------------------------------------------------
.import   _gt_draw_busy
.import   _gt_draw_mode
.import   _frameflip
.import   _p8pal
.import   _draw_color
.import   _gt_p8_rectfill_slow
.import   _gt_p8_spr_wide
.export   _gt_p8_rectfill_z
.export   _gt_a0, _gt_a1, _gt_a2, _gt_a3, _gt_a4, _gt_a5
.export   _gt_cam_x, _gt_cam_y
.export   _gt_pad0, _gt_pad1, _gt_rpt0, _gt_rpt1
.export   _gt_qhead, _gt_qtail, _gt_qbank
.export   _gt_q
.export   _gt_ent
.export   _gt_p0, _gt_p1, _gt_p2, _gt_p3, _gt_p4
.export   _gt_q_kick, _gt_q_push, _gt_q_pump
.export   _gt_p8_spr_z
.export   _irq_int

DMA_Flags = $2007
Bank_Reg  = $2005
VDMA_Base = $4000               ; VX $4000 VY $4001 GX $4002 GY $4003
VDMA_W    = $4004
VDMA_H    = $4005
DMA_Start = $4006
VDMA_Col  = $4007

.PC02

.segment "ZEROPAGE" : zeropage

_gt_a0:    .res 2               ; fastcall arg slots (ints)
_gt_a1:    .res 2
_gt_a2:    .res 2
_gt_a3:    .res 2
_gt_a4:    .res 2
_gt_a5:    .res 2
_gt_cam_x: .res 2               ; camera offset (P8 camera())
_gt_cam_y: .res 2
_gt_pad0:  .res 2               ; held-button word, player 0 (btn masks)
_gt_pad1:  .res 2
_gt_rpt0:  .res 2               ; newpress+repeat word (btnp masks)
_gt_rpt1:  .res 2
_gt_qhead: .res 1               ; producer index (multiples of 8)
_gt_qtail: .res 1               ; consumer index (advanced by the pump)
_gt_qbank: .res 1               ; this frame's $2005 byte for blits
_gt_ent:   .res 8               ; entry staging: C fills, gt_q_push commits
_gt_p0:    .res 2               ; zp-fastcall USER-function arg slots: the
_gt_p1:    .res 2               ;   emitter passes 1-5 int params here instead
_gt_p2:    .res 2               ;   of cc65's C stack (see emit.js zpCall)
_gt_p3:    .res 2
_gt_p4:    .res 2
rf_x0:     .res 1               ; rectfill_z scratch: cam-adjusted coords
rf_y0:     .res 1
rf_x1:     .res 1
q_pwh:     .res 1               ; spr_z scratch: pixel-width high byte
q_phl:     .res 1               ;                pixel-height low
q_phh:     .res 1               ;                pixel-height high
q_t:       .res 1               ;                clip-sum low byte

.segment "BSS"

_gt_q:     .res 256             ; 32 entries x 8 bytes

.segment "CODE"

; ---------------------------------------------------------------------------
; The HYBRID blit pipeline: ring buffering with a lean direct kick.
;
; MEASURED HISTORY: the pre-queue runtime cost 932/spr (mode churn); the
; IRQ-chained ring cost ~600/spr of bureaucracy; a pure depth-1 direct path
; cost ~185/spr but SERIALIZED big fills — a 16k-pixel cls stalls the very
; next push for 16k cycles, which is exactly the overlap the ring existed to
; buy (celeste-like: floor 2.0, yet 3.0 vsyncs either way — ring lost on
; setup, direct lost on stalls). This hybrid takes both wins:
;   push: copy the staged entry into the 32-deep ring (~70 cyc), then pump.
;   pump: if the blitter is idle, kick the ring head straight into the
;         registers (~70 cyc) — no IRQ-chained consumer, no mode churn.
;   IRQ:  ack + clear busy only (chaining from the IRQ crashed the emulator's
;         lazy materializer; every VDMA access stays on the main thread).
; Big fills drain while the CPU stages the following blits; the ring only
; stalls when 32 entries are already pending.
;
; EMULATOR RULE (load-bearing): the dummy $4000 read BEFORE writing new
; flags/registers forces the lazy materializer to draw the finished blit
; under the state it actually ran with. Harmless on hardware.
; ---------------------------------------------------------------------------
_gt_q_push:
@full:  LDA _gt_qhead
        CLC
        ADC #8
        CMP _gt_qtail
        BNE @room
        JSR _gt_q_pump          ; ring full: start/advance the drain, retry
        BRA @full
@room:  LDX _gt_qhead
        LDA _gt_ent+0
        STA _gt_q+0,x
        LDA _gt_ent+1
        STA _gt_q+1,x
        LDA _gt_ent+2
        STA _gt_q+2,x
        LDA _gt_ent+3
        STA _gt_q+3,x
        LDA _gt_ent+4
        STA _gt_q+4,x
        LDA _gt_ent+5
        STA _gt_q+5,x
        LDA _gt_ent+6
        STA _gt_q+6,x
        LDA _gt_ent+7
        STA _gt_q+7,x
        TXA
        CLC
        ADC #8
        STA _gt_qhead
        ; FALLS THROUGH into the pump

; gt_q_pump: if the blitter is idle and work is queued, kick the ring head.
; Safe from any main-thread context; the IRQ only clears _gt_draw_busy.
_gt_q_pump:
        LDA _gt_draw_busy
        BNE @out                ; still draining — the next push re-pumps
        LDX _gt_qtail
        CPX _gt_qhead
        BEQ @out                ; nothing queued
        LDA VDMA_Base           ; dummy read: force emulator catch-up FIRST
        LDA _gt_q+0,x           ; per-blit dma flags...
        ORA _frameflip          ; ...plus the LIVE page bit: the video scans
        STA DMA_Flags           ; from $2007 — never point it at the draw page
        ; bank: colorfill blits use the frame's write bank; COPY blits carry
        ; their own bank byte in the (otherwise unused) color slot
        AND #$08                ; DMA_COLORFILL_ENABLE?
        BNE @fill
        LDA _gt_q+7,x
        BRA @bank
@fill:  LDA _gt_qbank
@bank:  STA Bank_Reg
        LDA _gt_q+1,x
        STA VDMA_Base
        LDA _gt_q+2,x
        STA VDMA_Base+1
        LDA _gt_q+3,x
        STA VDMA_Base+2
        LDA _gt_q+4,x
        STA VDMA_Base+3
        LDA _gt_q+5,x
        STA VDMA_W
        LDA _gt_q+6,x
        STA VDMA_H
        LDA _gt_q+7,x
        STA VDMA_Col
        LDA #1
        STA _gt_draw_busy       ; busy BEFORE start: the IRQ can fire fast
        STA DMA_Start           ; kick
        TXA
        CLC
        ADC #8
        STA _gt_qtail
@out:   RTS

; kept as an alias for any external kick callers
_gt_q_kick = _gt_q_pump

; ---------------------------------------------------------------------------
; gt_p8_rectfill_z: the hot fill call, fast path fully in asm.
;   gt_a0=x0 gt_a1=y0 gt_a2=x1 gt_a3=y1 gt_a4=color
; Resolve the color (p8pal lookup / raw 0x1xx byte / negative = keep current),
; camera-adjust all four coordinates, and when everything is on-screen,
; ordered, and under the 7-bit span limit — the overwhelmingly common case —
; stage the entry and fall into the push (~90 cycles vs ~300 through the C
; chain). Anything else jumps to the C fallback, which redoes the resolve
; (idempotent) and handles swap/clip/128-splits. Clobbers A,X.
; ---------------------------------------------------------------------------
QF_RECT = $CD                   ; NMI|ENABLE|IRQ|COLORFILL|OPAQUE

_gt_p8_rectfill_z:
        ; ---- color: negative keeps draw_color; 0x1xx is a raw byte ----
        LDA _gt_a4+1
        BMI @ckeep
        BNE @craw
        LDA _gt_a4
        AND #$0F
        TAX
        LDA _p8pal,x
        BRA @cstore
@craw:  LDA _gt_a4
@cstore:
        STA _draw_color
@cinv:  EOR #$FF
        STA _gt_ent+7
        BRA @cam
@ckeep: LDA _draw_color
        BRA @cinv

@cam:   ; ---- x0 - cam_x: must land in 0..127 ----
        SEC
        LDA _gt_a0
        SBC _gt_cam_x
        STA rf_x0
        LDA _gt_a0+1
        SBC _gt_cam_x+1
        BNE @slow               ; <0 or >255
        LDA rf_x0
        BMI @slow               ; 128..255
        ; ---- y0 - cam_y ----
        SEC
        LDA _gt_a1
        SBC _gt_cam_y
        STA rf_y0
        LDA _gt_a1+1
        SBC _gt_cam_y+1
        BNE @slow
        LDA rf_y0
        BMI @slow
        ; ---- x1 - cam_x ----
        SEC
        LDA _gt_a2
        SBC _gt_cam_x
        STA rf_x1
        LDA _gt_a2+1
        SBC _gt_cam_x+1
        BNE @slow
        LDA rf_x1
        BMI @slow
        ; ---- y1 - cam_y (kept in A) ----
        SEC
        LDA _gt_a3
        SBC _gt_cam_y
        TAX
        LDA _gt_a3+1
        SBC _gt_cam_y+1
        BNE @slow
        TXA
        BMI @slow
        ; ---- height = y1 - y0 + 1 (ordered, < 128) ----
        SEC
        SBC rf_y0
        BCC @slow               ; y1 < y0
        CMP #$7F
        BCS @slow               ; span 128 needs the split path
        INC A
        STA _gt_ent+6
        ; ---- width = x1 - x0 + 1 ----
        LDA rf_x1
        SEC
        SBC rf_x0
        BCC @slow
        CMP #$7F
        BCS @slow
        INC A
        STA _gt_ent+5
        ; ---- stage the rest + commit ----
        LDA #QF_RECT
        STA _gt_ent+0
        LDA rf_x0
        STA _gt_ent+1
        LDA rf_y0
        STA _gt_ent+2
        STZ _gt_ent+3
        STZ _gt_ent+4
        STZ _gt_draw_mode       ; MODE_NONE: flags register now queue-owned
        JMP _gt_q_push
@slow:  JMP _gt_p8_rectfill_slow

; ---------------------------------------------------------------------------
; gt_p8_spr_z: the hot per-entity draw call, fully in asm.
;   gt_a0=n  gt_a1=x  gt_a2=y  gt_a3=w  gt_a4=h   (P8 spr semantics)
; Camera-adjust (16-bit), reject fully-offscreen, stage a QF_SPR entry,
; fall into gt_q_push. w/h use their low bytes (P8 cells are 1..16; 0 -> 1).
; Clobbers A,X.
; ---------------------------------------------------------------------------
QF_SPR = $55                    ; DMA_NMI|DMA_ENABLE|DMA_IRQ|DMA_GCARRY

_gt_p8_spr_z:
        ; ---- 16-cell (128px) spans overflow the 7-bit blit counters and the
        ; hardware wraps them to zero-width garbage: punt to the C splitter,
        ; which redraws as two 64px halves through this same path. ----
        LDA _gt_a3
        CMP #16
        BCS @wide
        LDA _gt_a4
        CMP #16
        BCC @norm
@wide:  JMP _gt_p8_spr_wide
@norm:
        ; ---- pw = max(w,1) << 3 (16-bit result: A=lo, q_pwh=hi) ----
        LDA _gt_a3
        BNE :+
        LDA #1
:       STZ q_pwh
        ASL A
        ROL q_pwh
        ASL A
        ROL q_pwh
        ASL A
        ROL q_pwh
        STA _gt_ent+5           ; entry WIDTH (low byte, matches C truncation)
        ; ---- x = gt_a1 - cam_x (16-bit signed) ----
        SEC
        LDA _gt_a1
        SBC _gt_cam_x
        STA _gt_ent+1           ; entry VX candidate
        LDA _gt_a1+1
        SBC _gt_cam_x+1
        BMI @xneg
        BNE @rejn               ; x >= 256: off right
        BIT _gt_ent+1
        BMI @rejn               ; 128..255: off right
        BRA @xok
@rejn:  RTS                     ; near reject trampoline (offscreen clip)
@xneg:  ; x < 0: reject when x + pw <= 0
        TAX                     ; X = x high
        CLC
        LDA _gt_ent+1
        ADC _gt_ent+5
        STA q_t
        TXA
        ADC q_pwh
        BMI @rejn               ; sum < 0
        BNE @xok                ; sum >= 256: on screen
        LDA q_t
        BEQ @rejn               ; sum == 0: right edge exactly at 0
@xok:
        ; ---- ph = max(h,1) << 3 ----
        LDA _gt_a4
        BNE :+
        LDA #1
:       STZ q_phh
        ASL A
        ROL q_phh
        ASL A
        ROL q_phh
        ASL A
        ROL q_phh
        STA _gt_ent+6           ; entry HEIGHT
        ; ---- y = gt_a2 - cam_y (16-bit signed) ----
        SEC
        LDA _gt_a2
        SBC _gt_cam_y
        STA _gt_ent+2           ; entry VY candidate
        LDA _gt_a2+1
        SBC _gt_cam_y+1
        BMI @yneg
        BNE @rejn
        BIT _gt_ent+2
        BMI @rejn
        BRA @yok
@yneg:  TAX
        CLC
        LDA _gt_ent+2
        ADC _gt_ent+6
        STA q_t
        TXA
        ADC q_phh
        BMI @rejn
        BNE @yok
        LDA q_t
        BEQ @rejn
@yok:
        ; ---- stage the rest: flags, GX=(n&15)<<3, GY=(n&0xF0)>>1 ----
        LDA #QF_SPR
        STA _gt_ent+0
        LDA _gt_a0
        AND #$0F
        ASL A
        ASL A
        ASL A
        STA _gt_ent+3           ; GX = cell col * 8 (left edge of source cell)
        LDA _gt_a0
        AND #$F0
        LSR A
        STA _gt_ent+4           ; GY = cell row * 8 (top edge)
        LDA _gt_qbank           ; copy blits carry their bank in the color slot
        STA _gt_ent+7           ; (sheet sprites: the frame's write bank)
        ; ---- hardware flip (gt_a5: bit0 = flip X, bit1 = flip Y) ----
        ; The blitter mirrors when WIDTH/HEIGHT bit7 is set: it one's-complements
        ; the source counter, and picks the GRAM quadrant from the INVERTED bit7.
        ; So the RAW GX counter must sweep [128..255] (bit7 set) for the whole
        ; blit, so ~counter lands in [0..127] (quadrant 0, the sheet). Solving
        ; ~(GX+col) = sx0 + pw-1 - col gives  GX_flip = (256 - sx0 - pw) & $FF
        ; = -(sx0 + pw). Same for GY/ph.
        LDA _gt_a5
        AND #$01
        BEQ @noflipx
        SEC                     ; GX = 0 - GX - pw   (= 256 - GX - pw)
        LDA #$00
        SBC _gt_ent+3
        SBC _gt_ent+5
        STA _gt_ent+3
        LDA _gt_ent+5           ; WIDTH |= $80  (XDIR)
        ORA #$80
        STA _gt_ent+5
@noflipx:
        LDA _gt_a5
        AND #$02
        BEQ @noflipy
        SEC                     ; GY = 0 - GY - ph
        LDA #$00
        SBC _gt_ent+4
        SBC _gt_ent+6
        STA _gt_ent+4
        LDA _gt_ent+6           ; HEIGHT |= $80  (YDIR)
        ORA #$80
        STA _gt_ent+6
@noflipy:
        STZ _gt_draw_mode       ; MODE_NONE: flags register now queue-owned
        JMP _gt_q_push

; ---------------------------------------------------------------------------
; IRQ = blit complete: acknowledge and mark the blitter idle. Nothing else —
; the main-thread pump advances the queue. STZ touches no registers, so
; nothing needs saving (the proven pre-queue handler shape).
; ---------------------------------------------------------------------------
_irq_int:
        STZ DMA_Start           ; acknowledge the DMA interrupt
        STZ _gt_draw_busy
        RTI
