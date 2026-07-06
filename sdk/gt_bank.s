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

; DATA (not BSS): starts at $FF — an impossible bank — so the FIRST switch
; always programs the hardware shifter. The same-bank early-out below would
; otherwise no-op the boot-time gt_bank(0) against a zeroed tracker while
; the cart's power-on shifter state is random.
.segment "DATA"
gt_cur_bank:
_gt_cur_bank: .byte $FF           ; C-visible alias (extern unsigned char gt_cur_bank)

.segment "BSS"
.export _gt_bank_switches
_gt_bank_switches: .res 4         ; diagnostic: real hardware switches (u32)

.segment "CODE"

; void __fastcall__ gt_bank(unsigned char b);
_gt_bank := gt_bank_raw

; The generic path shifts 7 bits through a carry dance: ~235 cycles per
; switch — and every cross-bank stub switches TWICE (call + restore). A
; profiled combat frame spent ~30% of its cycles in here. gtlua only ever
; switches to banks 0/1/2, whose bit sequences are constants: straight-
; lined below at ~105 cycles (~2.2x). Same-bank requests return in 9.
gt_bank_raw:
        cmp     gt_cur_bank
        bne     @go
        rts
@go:    sta     gt_cur_bank
        inc     _gt_bank_switches
        bne     @cnt
        inc     _gt_bank_switches+1
        bne     @cnt
        inc     _gt_bank_switches+2
@cnt:
        ldx     #$07            ; CLK/MOSI/CS as outputs
        stx     VIA_DDRA
        cmp     #0
        beq     @b0
        cmp     #1
        beq     @b1
        cmp     #2
        beq     @b2
        ; ---- general fallback (any bank number) ----
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
        jmp     @latch
        ; ---- bank 0: seven 0-bits ----
@b0:    stz     VIA_ORA
        inc     VIA_ORA
        stz     VIA_ORA
        inc     VIA_ORA
        stz     VIA_ORA
        inc     VIA_ORA
        stz     VIA_ORA
        inc     VIA_ORA
        stz     VIA_ORA
        inc     VIA_ORA
        stz     VIA_ORA
        inc     VIA_ORA
        stz     VIA_ORA
        inc     VIA_ORA
        jmp     @latch
        ; ---- bank 1: six 0-bits then a 1-bit ----
@b1:    stz     VIA_ORA
        inc     VIA_ORA
        stz     VIA_ORA
        inc     VIA_ORA
        stz     VIA_ORA
        inc     VIA_ORA
        stz     VIA_ORA
        inc     VIA_ORA
        stz     VIA_ORA
        inc     VIA_ORA
        stz     VIA_ORA
        inc     VIA_ORA
        lda     #$02            ; MOSI high, CLK low
        sta     VIA_ORA
        inc     VIA_ORA
        jmp     @latch
        ; ---- bank 2: five 0-bits, a 1-bit, a 0-bit ----
@b2:    stz     VIA_ORA
        inc     VIA_ORA
        stz     VIA_ORA
        inc     VIA_ORA
        stz     VIA_ORA
        inc     VIA_ORA
        stz     VIA_ORA
        inc     VIA_ORA
        stz     VIA_ORA
        inc     VIA_ORA
        lda     #$02
        sta     VIA_ORA
        inc     VIA_ORA
        stz     VIA_ORA
        inc     VIA_ORA
@latch: stz     VIA_ORA         ; CS low, CLK low
        lda     #$04
        sta     VIA_ORA         ; CS rise: latch the new bank
        stz     VIA_ORA
        rts
