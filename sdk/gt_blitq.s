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
.export   _gt_rng_next
.export   _gt_rng_state
.exportzp _gt_a0, _gt_a1, _gt_a2, _gt_a3, _gt_a4, _gt_a5
.export   _gt_cam_x, _gt_cam_y
.export   _gt_pad0, _gt_pad1, _gt_rpt0, _gt_rpt1
.export   _gt_qhead, _gt_qtail, _gt_qbank, _gt_push_waits
.exportzp _gt_frames
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
_gt_frames: .res 2              ; monotonic game-frame counter (endframe++)
_gt_qhead: .res 1               ; producer index (multiples of 8)
_gt_qtail: .res 1               ; consumer index (advanced by the pump)
_gt_qbank: .res 1               ; this frame's $2005 byte for blits
_gt_push_waits: .res 2          ; ring-full poll count (diagnostic)
_gt_ent:   .res 8               ; entry staging: C fills, gt_q_push commits
_gt_p0:    .res 2               ; zp-fastcall USER-function arg slots: the
_gt_p1:    .res 2               ;   emitter passes 1-5 int params here instead
_gt_p2:    .res 2               ;   of cc65's C stack (see emit.js zpCall)
_gt_p3:    .res 2
_gt_p4:    .res 2
rf_x0:     .res 1               ; rectfill_z scratch: cam-adjusted coords
rf_y0:     .res 1
rf_x1:     .res 1
q_xov:  .res 1               ; left-edge clip: source columns skipped
q_yov:  .res 1               ; top-edge clip: source rows skipped
q_pwh:     .res 1               ; spr_z scratch: pixel-width high byte
q_phl:     .res 1               ;                pixel-height low
q_phh:     .res 1               ;                pixel-height high
q_t:       .res 1               ;                clip-sum low byte
q_s:       .res 1               ;                clip high-byte scratch

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
        ; ---- direct fast path: blitter idle AND ring empty (the common case
        ; for sprite streams — a 64px cell drains in 64 cycles, faster than
        ; the CPU stages the next one). Poke the registers straight from the
        ; staged entry: no ring copy, no head/tail bookkeeping, ~125 cycles
        ; saved per blit. Big fills keep the buffered path below.
        LDA _gt_draw_busy
        BNE @full
        LDA _gt_qhead
        CMP _gt_qtail
        BNE @full               ; entries queued: keep FIFO order
        LDA VDMA_Base           ; dummy read: force emulator catch-up FIRST
        LDA _gt_ent+0
        ORA _frameflip          ; live page bit — never scan the draw page
        STA DMA_Flags
        AND #$08                ; DMA_COLORFILL_ENABLE?
        BNE @dfill
        LDA _gt_ent+7
        BRA @dbank
@dfill: LDA _gt_qbank
@dbank: STA Bank_Reg
        LDA _gt_ent+1
        STA VDMA_Base
        LDA _gt_ent+2
        STA VDMA_Base+1
        LDA _gt_ent+3
        STA VDMA_Base+2
        LDA _gt_ent+4
        STA VDMA_Base+3
        LDA _gt_ent+5
        STA VDMA_W
        LDA _gt_ent+6
        STA VDMA_H
        LDA _gt_ent+7
        STA VDMA_Col
        LDA #1
        STA _gt_draw_busy       ; busy BEFORE start: the IRQ can fire fast
        STA DMA_Start
        RTS

@full:  LDA _gt_qhead
        CLC
        ADC #8
        CMP _gt_qtail
        BNE @room
        INC _gt_push_waits      ; diagnostic: ring-full poll (u16)
        BNE @nw
        INC _gt_push_waits+1
@nw:    JSR _gt_q_pump          ; ring full: start/advance the drain, retry
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
; gt_rng_next: 16-bit xorshift (7,9,8) — returns the next state in A/X
; (lo/hi, cc65 int return). An explosion spawns ~250 rnd() calls in one
; frame; the old 32-bit xorshift walked cc65's long-shift loops for ~700
; cycles per call. This is ~40. Never yields 0 (nonzero seed cycles the
; full 65535-value orbit).
; ---------------------------------------------------------------------------
.bss
_gt_rng_state: .res 2

.code
_gt_rng_next:
        ; s ^= s << 7:
        ;   (s<<7).hi = (hi&1)<<7 | lo>>1   (bits 8..1 of s)
        ;   (s<<7).lo = (lo&1)<<7
        LDA _gt_rng_state+1
        LSR A                   ; carry = hi bit0
        LDA _gt_rng_state
        ROR A                   ; A = (hi&1)<<7 | lo>>1
        EOR _gt_rng_state+1
        STA _gt_rng_state+1     ; hi'
        LDA _gt_rng_state
        LSR A                   ; carry = lo bit0
        LDA #0
        ROR A                   ; A = (lo&1)<<7
        EOR _gt_rng_state
        STA _gt_rng_state       ; lo'
        ; s ^= s >> 9: lo ^= hi' >> 1
        LDA _gt_rng_state+1
        LSR A
        EOR _gt_rng_state
        STA _gt_rng_state       ; lo''
        ; s ^= s << 8: hi ^= lo''  (A holds lo'')
        EOR _gt_rng_state+1
        STA _gt_rng_state+1     ; hi''
        TAX                     ; X = hi (cc65 int return = A lo, X hi)
        LDA _gt_rng_state
        RTS

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
        JMP @cam                ; (the clip block below pushed @cam far)
@ckeep: LDA _draw_color
        BRA @cinv

@cam:   ; ---- x0 - cam_x, edge-clipped in place. Partially-offscreen fills
        ; used to punt to the C slow path (bank round-trip + full clip,
        ; ~1.7k a call — the celeste2 scarf paid it ~5x a frame); now each
        ; edge clamps here and only swapped coords or 128+ spans punt. ----
        SEC
        LDA _gt_a0
        SBC _gt_cam_x
        STA rf_x0
        LDA _gt_a0+1
        SBC _gt_cam_x+1
        BEQ @x0in
        BPL @offj               ; x0 >= 256: fully right-off
        STZ rf_x0               ; x0 < 0: clamp to the left edge
        BRA @y0
@offj:  JMP @off
@x0in:  LDA rf_x0
        BPL @y0
        BRA @offj               ; 128..255: fully right-off
@y0:    ; ---- y0 - cam_y ----
        SEC
        LDA _gt_a1
        SBC _gt_cam_y
        STA rf_y0
        LDA _gt_a1+1
        SBC _gt_cam_y+1
        BEQ @y0in
        BPL @offj               ; y0 >= 256: below
        STZ rf_y0               ; y0 < 0: clamp to the top
        BRA @x1
@y0in:  LDA rf_y0
        BPL @x1
        BRA @offj
@x1:    ; ---- x1 - cam_x ----
        SEC
        LDA _gt_a2
        SBC _gt_cam_x
        STA rf_x1
        LDA _gt_a2+1
        SBC _gt_cam_x+1
        BEQ @x1in
        BMI @off                ; x1 < 0: fully left-off
        LDA #$7F
        STA rf_x1               ; x1 > 255: clamp to the right edge
        BRA @y1
@x1in:  LDA rf_x1
        BPL @y1
        LDA #$7F                ; 128..255: clamp
        STA rf_x1
@y1:    ; ---- y1 - cam_y (result in A) ----
        SEC
        LDA _gt_a3
        SBC _gt_cam_y
        TAX
        LDA _gt_a3+1
        SBC _gt_cam_y+1
        BEQ @y1in
        BMI @off                ; y1 < 0: above
        LDX #$7F                ; y1 > 255: clamp to the bottom
@y1in:  TXA
        BPL @hcalc
        LDA #$7F                ; 128..255: clamp
@hcalc: ; ---- height = y1 - y0 + 1 (reject if ordered wrong post-clip) ----
        SEC
        SBC rf_y0
        BCC @slow               ; y1 < y0: swapped corners -> the C path
                                ; (P8 rectfill accepts either corner order)
        CMP #$7F
        BCS @slow               ; span 128 needs the split path
        INC A
        STA _gt_ent+6
        ; ---- width = x1 - x0 + 1 ----
        LDA rf_x1
        SEC
        SBC rf_x0
        BCC @slow               ; swapped: the C path handles it
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
@off:   RTS                     ; fully offscreen: no entry

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
        ; ---- claim a ring slot NOW and stage into it directly: push's
        ; 8-byte gt_ent->ring copy (+ its checks) disappears per sprite.
        ; X = slot base for the whole staging path (clip scratch moved to
        ; zp q_s so nothing clobbers it).
@slot:  LDA _gt_qhead
        CLC
        ADC #8
        CMP _gt_qtail
        BNE @free
        JSR _gt_q_pump          ; ring full (measured ~never): drain, retry
        BRA @slot
@free:  LDX _gt_qhead
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
        STA _gt_q+5,X         ; entry WIDTH (low byte, matches C truncation)
        ; ---- x = gt_a1 - cam_x (16-bit signed) ----
        SEC
        LDA _gt_a1
        SBC _gt_cam_x
        STA _gt_q+1,X         ; entry VX candidate
        LDA _gt_a1+1
        SBC _gt_cam_x+1
        BMI @xneg
        BNE @rejn               ; x >= 256: off right
        BIT _gt_q+1,X
        BMI @rejn               ; 128..255: off right
        ; right overhang: the blitter's counters are 7-bit and a run past
        ; x=127 wraps onto the next row (the edge-garbage bug) — trim W
        STZ q_xov
        SEC
        LDA #128
        SBC _gt_q+1,X           ; 128 - x = max visible width
        CMP _gt_q+5,X
        BCS @xok                ; pw fits
        STA _gt_q+5,X           ; W = 128 - x
        BRA @xok
@rejn:  RTS                     ; near reject trampoline (offscreen clip)
@xneg:  ; x < 0: clip the left overhang (reject only when fully off)
        STA q_s                 ; x high (X holds the ring slot)
        CLC
        LDA _gt_q+1,X
        ADC _gt_q+5,X
        STA q_t                 ; sum lo = visible width when hi lands on 0
        LDA q_s
        ADC q_pwh
        BMI @rejn               ; sum < 0: fully off left
        BNE @xok0               ; sum >= 256 can't happen for pw<=128 unless
                                ; x > 127 already rejected; treat as full
        LDA q_t
        BEQ @rejn               ; right edge exactly at 0: nothing visible
        ; ov = pw - visible; VX = 0; W = visible; GX += ov (applied later)
        SEC
        LDA _gt_q+5,X
        SBC q_t
        STA q_xov
        LDA q_t
        STA _gt_q+5,X
@xok0:  STZ _gt_q+1,X           ; VX = 0
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
        STA _gt_q+6,X         ; entry HEIGHT
        ; ---- y = gt_a2 - cam_y (16-bit signed) ----
        SEC
        LDA _gt_a2
        SBC _gt_cam_y
        STA _gt_q+2,X         ; entry VY candidate
        LDA _gt_a2+1
        SBC _gt_cam_y+1
        BMI @yneg
        BNE @rejn
        BIT _gt_q+2,X
        BMI @rejn
        STZ q_yov
        SEC
        LDA #128
        SBC _gt_q+2,X           ; 128 - y = max visible height
        CMP _gt_q+6,X
        BCS @yok
        STA _gt_q+6,X           ; H = 128 - y
        BRA @yok
@yneg:  STA q_s
        CLC
        LDA _gt_q+2,X
        ADC _gt_q+6,X
        STA q_t
        LDA q_s
        ADC q_phh
        BMI @rejn
        BNE @yok0
        LDA q_t
        BEQ @rejn
        SEC
        LDA _gt_q+6,X
        SBC q_t
        STA q_yov
        LDA q_t
        STA _gt_q+6,X
@yok0:  STZ _gt_q+2,X           ; VY = 0
@yok:
        ; ---- stage the rest: flags, GX=(n&15)<<3, GY=(n&0xF0)>>1 ----
        LDA #QF_SPR
        STA _gt_q+0,X
        LDA _gt_a0
        AND #$0F
        ASL A
        ASL A
        ASL A
        CLC
        ADC q_xov               ; skip the left-clipped source columns
        STA _gt_q+3,X           ; GX = cell col * 8 + clip
        LDA _gt_a0
        AND #$F0
        LSR A
        CLC
        ADC q_yov               ; skip the top-clipped source rows
        STA _gt_q+4,X           ; GY = cell row * 8 + clip
        LDA _gt_qbank           ; copy blits carry their bank in the color slot
        STA _gt_q+7,X           ; (sheet sprites: the frame's write bank)
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
        SBC _gt_q+3,X
        SBC _gt_q+5,X
        STA _gt_q+3,X
        LDA _gt_q+5,X           ; WIDTH |= $80  (XDIR)
        ORA #$80
        STA _gt_q+5,X
@noflipx:
        LDA _gt_a5
        AND #$02
        BEQ @noflipy
        SEC                     ; GY = 0 - GY - ph
        LDA #$00
        SBC _gt_q+4,X
        SBC _gt_q+6,X
        STA _gt_q+4,X
        LDA _gt_q+6,X           ; HEIGHT |= $80  (YDIR)
        ORA #$80
        STA _gt_q+6,X
@noflipy:
        STZ _gt_draw_mode       ; MODE_NONE: flags register now queue-owned
        TXA                     ; commit: head += 8, then drain-check
        CLC
        ADC #8
        STA _gt_qhead
        JMP _gt_q_pump

; ---------------------------------------------------------------------------
; IRQ = blit complete: acknowledge and mark the blitter idle. Nothing else —
; the main-thread pump advances the queue. STZ touches no registers, so
; nothing needs saving (the proven pre-queue handler shape).
; ---------------------------------------------------------------------------
_irq_int:
        STZ DMA_Start           ; acknowledge the DMA interrupt
        STZ _gt_draw_busy
        RTI

.ifdef GT_DBAR
; ---------------------------------------------------------------------------
; gt_dbar_z — the HUD stamina/life bar: up to four small fills staged raw.
;   pe = px + (v*77 >> 8), pe2 = px + (m*77 >> 8)   (v,m are 0..100 ints)
;   entries: bg strip (px..px+28, 3 rows; skipped when db_bg >= 16), value
;   fill (px..pe, 3 rows), highlight (px..pe-1, 2 rows), deficit
;   (pe+1..pe2, 3 rows, color 6) when m > v.
; The compiled version made 4 rectfill() calls (~400 each with glue); this
; stages the same entries in ~450 total. Colors resolve via p8pal ^ $FF.
;   zp args: db_px db_py db_v db_m db_c db_c2 db_bg (bytes)
; ---------------------------------------------------------------------------
.export _gt_dbar_z
.export _db_px, _db_py, _db_v, _db_m, _db_c, _db_c2, _db_bg
.import mul8, mx, my, m16

.segment "ZEROPAGE" : zeropage
_db_px: .res 1
_db_py: .res 1
_db_v:  .res 1
_db_m:  .res 1
_db_c:  .res 1
_db_c2: .res 1
_db_bg: .res 1
db_pe:  .res 1
db_pe2: .res 1
db_x:   .res 1
db_w:   .res 1
db_h:   .res 1
db_col: .res 1

.segment "CODE"

; stage one fill: db_x, _db_py, db_w x db_h, db_col (pico index -> resolved)
.proc dbfill
        ldy     db_col
        lda     _p8pal,y
        eor     #$FF
        sta     db_col
slot:   lda     _gt_qhead
        clc
        adc     #8
        cmp     _gt_qtail
        bne     free
        jsr     _gt_q_pump
        bra     slot
free:   ldx     _gt_qhead
        lda     #QF_RECT
        sta     _gt_q+0,x
        lda     db_x
        sta     _gt_q+1,x
        lda     _db_py
        sta     _gt_q+2,x
        stz     _gt_q+3,x
        stz     _gt_q+4,x
        lda     db_w
        sta     _gt_q+5,x
        lda     db_h
        sta     _gt_q+6,x
        lda     db_col
        sta     _gt_q+7,x
        txa
        clc
        adc     #8
        sta     _gt_qhead
        jsr     _gt_q_pump
        rts
.endproc

.proc _gt_dbar_z
        stz     _gt_draw_mode
        ; pe = px + (v*77 >> 8); pe2 = px + (m*77 >> 8)
        lda     _db_v
        sta     mx
        lda     #77
        sta     my
        jsr     mul8
        lda     m16+1
        clc
        adc     _db_px
        sta     db_pe
        lda     _db_m
        sta     mx
        lda     #77
        sta     my
        jsr     mul8
        lda     m16+1
        clc
        adc     _db_px
        sta     db_pe2
        ; bg strip: (px, 29 wide, 3 tall, db_bg) unless bg >= 16
        lda     _db_bg
        cmp     #16
        bcs     nobg
        sta     db_col
        lda     _db_px
        sta     db_x
        lda     #29
        sta     db_w
        lda     #3
        sta     db_h
        jsr     dbfill
nobg:   ; value fill: px..pe (w = pe-px+1), 3 tall, c2
        lda     _db_c2
        sta     db_col
        lda     _db_px
        sta     db_x
        lda     db_pe
        sec
        sbc     _db_px
        inc     a
        sta     db_w
        lda     #3
        sta     db_h
        jsr     dbfill
        ; highlight: px..max(px, pe-1), 2 tall, c
        lda     _db_c
        sta     db_col
        lda     db_pe
        sec
        sbc     _db_px          ; pe-px
        beq     :+              ; pe == px -> width 1 (max(px, pe-1) = px)
        ; width = pe-1 - px + 1 = pe - px
        bra     :++
:       lda     #1
:       sta     db_w
        lda     #2
        sta     db_h
        jsr     dbfill
        ; deficit: m > v -> (pe+1 .. pe2), 3 tall, color 6
        lda     _db_v
        cmp     _db_m
        bcs     done
        lda     #6
        sta     db_col
        lda     db_pe
        inc     a
        sta     db_x
        lda     db_pe2
        sec
        sbc     db_pe           ; pe2 - (pe+1) + 1 = pe2 - pe
        beq     done            ; zero width: skip
        sta     db_w
        lda     #3
        sta     db_h
        jsr     dbfill
done:   rts
.endproc
.endif ; GT_DBAR
