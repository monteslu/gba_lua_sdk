; ---------------------------------------------------------------------------
; FLASH2M cartridge bank switching (2 MB carts: 128 x 16 KB banks).
;
; $8000-$BFFF is a banked 16 KB window; $C000-$FFFF is fixed to the LAST
; bank (127). The active bank is a 7-bit shift register on the cartridge,
; bit-banged over VIA port A ($2801): bit0 = CLK, bit1 = MOSI, bit2 = CS.
; A rising CLK edge shifts in the MOSI level that was set BEFORE the edge
; (the cart samples the pre-edge pin state); a rising CS edge latches the
; shifter as the active bank. MSB first, 7 bits.
;
; gt_bank_raw: A = bank number. Clobbers A,X. Tracks gt_cur_bank for the
; cross-bank call stubs. Must live in the FIXED bank (it runs while the
; window is mid-switch).
; ---------------------------------------------------------------------------
.export _gt_bank, gt_bank_raw, gt_cur_bank, _gt_cur_bank
.PC02

VIA_ORA  = $2801
VIA_DDRA = $2803

.segment "BSS"
gt_cur_bank:
_gt_cur_bank: .res 1              ; C-visible alias (extern unsigned char gt_cur_bank)

.segment "CODE"

; void __fastcall__ gt_bank(unsigned char b);
_gt_bank := gt_bank_raw

gt_bank_raw:
        sta     gt_cur_bank
        lda     #$07            ; CLK/MOSI/CS as outputs
        sta     VIA_DDRA
        lda     gt_cur_bank
        asl     a               ; discard bit 7: bits 6..0 now sit in 7..1
        ldx     #7
@bit:   asl     a               ; next data bit (bit 6 first) -> carry
        pha
        lda     #0
        rol     a               ; A = carry (the data bit)
        asl     a               ; -> bit1 (MOSI)
        sta     VIA_ORA         ; present MOSI, CLK low
        inc     VIA_ORA         ; CLK rise: cart shifts in the presented bit
        pla
        dex
        bne     @bit
        stz     VIA_ORA         ; CS low, CLK low
        lda     #$04
        sta     VIA_ORA         ; CS rise: latch the new bank
        stz     VIA_ORA
        rts
