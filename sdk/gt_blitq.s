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
.export   _gt_a0, _gt_a1, _gt_a2, _gt_a3, _gt_a4, _gt_a5
.export   _gt_cam_x, _gt_cam_y
.export   _gt_pad0, _gt_pad1, _gt_rpt0, _gt_rpt1
.export   _gt_qhead, _gt_qtail, _gt_qbank
.export   _gt_q
.export   _gt_ent
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
q_pwh:     .res 1               ; spr_z scratch: pixel-width high byte
q_phl:     .res 1               ;                pixel-height low
q_phh:     .res 1               ;                pixel-height high
q_t:       .res 1               ;                clip-sum low byte

.segment "BSS"

_gt_q:     .res 256             ; 32 entries x 8 bytes

.segment "CODE"

; ---------------------------------------------------------------------------
; gt_q_kick: if the queue has an entry, program + start it (does NOT ack).
; Called ONLY from the main thread, under SEI, when the blitter is idle
; (the "pump": every enqueue and the drain loop advance the chain). The IRQ
; handler deliberately does NOT touch the queue or the blitter registers —
; chaining blits from interrupt context while the emulator materializes the
; finished blit lazily proved to be a timing-sensitive crash (runaway after
; a variable number of frames); the pump keeps every VDMA access on the
; main thread, the pattern the runtime always used. Clobbers A,X. When the
; queue is empty, the blitter is done working: clear _gt_draw_busy.
; ---------------------------------------------------------------------------
_gt_q_kick:
        LDA VDMA_Base           ; dummy read: force emulator catch-up FIRST
        LDX _gt_qtail
        CPX _gt_qhead
        BEQ @empty
        LDA _gt_q+0,x           ; per-blit dma flags
        STA DMA_Flags
        ; bank: colorfill entries use the frame's write bank; COPY entries
        ; carry their own bank byte in the (otherwise unused) color slot, so
        ; one queue can mix sheet sprites with blits from other GRAM groups
        ; (gt.gspr's composed-canvas sprites).
        AND #$08                ; DMA_COLORFILL_ENABLE?
        BNE @fill
        LDA _gt_q+7,x           ; copy: bank rides in the color slot
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
        STA DMA_Start           ; kick
        TXA
        CLC
        ADC #8
        STA _gt_qtail
        RTS
@empty:
        STZ _gt_draw_busy
        RTS

; ---------------------------------------------------------------------------
; gt_q_push: commit the staged entry (_gt_ent) into the ring and pump.
; The producer fast path: callers do 8 zp stores + JSR — no C-stack args.
; If the ring is full, pump until the blitter frees a slot (never a blind
; spin). Clobbers A,X.
; ---------------------------------------------------------------------------
_gt_q_push:
@full:  LDA _gt_qhead
        CLC
        ADC #8
        CMP _gt_qtail
        BNE @room
        JSR _gt_q_pump          ; ring full: advance the chain, retry
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

; ---------------------------------------------------------------------------
; gt_q_pump: if the blitter is idle and work is queued, start the next blit.
; The ONLY place blits start. Interrupt-state preserved (php/sei/plp) so it
; is safe from any context; the completion IRQ only clears _gt_draw_busy.
; Clobbers A,X.
; ---------------------------------------------------------------------------
_gt_q_pump:
        PHP
        SEI
        LDA _gt_draw_busy
        BNE @out
        LDA _gt_qtail
        CMP _gt_qhead
        BEQ @out
        INC _gt_draw_busy       ; 0 -> 1
        JSR _gt_q_kick
@out:   PLP
        RTS

; ---------------------------------------------------------------------------
; gt_p8_spr_z: the hot per-entity draw call, fully in asm.
;   gt_a0=n  gt_a1=x  gt_a2=y  gt_a3=w  gt_a4=h   (P8 spr semantics)
; Camera-adjust (16-bit), reject fully-offscreen, stage a QF_SPR entry,
; fall into gt_q_push. w/h use their low bytes (P8 cells are 1..16; 0 -> 1).
; Clobbers A,X.
; ---------------------------------------------------------------------------
QF_SPR = $55                    ; DMA_NMI|DMA_ENABLE|DMA_IRQ|DMA_GCARRY

_gt_p8_spr_z:
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
