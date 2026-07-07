; ---------------------------------------------------------------------------
; gt_stars — the starfield's two per-frame loops in 65C02.
;
; The C loops in gt_api.c cost ~86 cycles/star (advance) + ~69 (draw) —
; 15.5k/frame on cherry-bomb's 100-star field, the single biggest SDK item
; in its profile. These do the same byte math at ~30 and ~24: 5.4k total.
;
; State = the byte arrays in gt_api.c (RAM, bank-independent). The C
; wrappers stay the public surface; their impls call these.
;   advance: A = mode (0 drift ~0.375x, 1 = 1x, 2 = 2x)
;   draw: pokes vram (the caller already entered CPU mode; frame start =
;   empty queue = the drain is free)
; ---------------------------------------------------------------------------
.export _gt_sf_adv_z, _gt_sf_draw_z
.import _star_x, _star_row, _star_frac, _star_s, _star_col, _star_n
.PC02

.segment "ZEROPAGE" : zeropage
sf_mode: .res 1
sf_ptr:  .res 2

.segment "CODE"

; void __fastcall__ gt_sf_adv_z(unsigned char mode)
_gt_sf_adv_z:
        sta     sf_mode
        ldy     _star_n
        beq     @done
@loop:  dey
        lda     _star_s,y
        ldx     sf_mode
        beq     @drift
        dex
        beq     @adv            ; mode 1: 1x
        asl     a               ; mode 2: 2x
        bra     @adv
@drift: lsr     a               ; ~0.375x = (s>>2)+(s>>3)
        lsr     a
        sta     sf_ptr
        lsr     a
        clc
        adc     sf_ptr
@adv:   clc
        adc     _star_frac,y    ; f = frac + adv (<= 77, fits a byte)
        pha
        lsr     a
        lsr     a
        lsr     a
        lsr     a               ; f >> 4 = whole rows
        clc
        adc     _star_row,y
        and     #$7F            ; row wrap at 128
        sta     _star_row,y
        pla
        and     #$0F
        sta     _star_frac,y
        cpy     #0
        bne     @loop
@done:  rts

; void gt_sf_draw_z(void) — CPU-mode pokes; vram = $4000 | (row<<7) | x
; X walks the stars so Y stays free for the (zp),y poke.
_gt_sf_draw_z:
        ldx     _star_n
        beq     @done
@loop:  dex
        lda     _star_row,x
        lsr     a               ; row>>1 -> page
        ora     #$40
        sta     sf_ptr+1
        lda     #0
        ror     a               ; (row&1)<<7
        sta     sf_ptr
        ldy     _star_x,x
        lda     _star_col,x
        sta     (sf_ptr),y
        cpx     #0
        bne     @loop
@done:  rts
