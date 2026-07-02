; ---------------------------------------------------------------------------
; GameTank startup for single-bank (EEPROM32K, flat 32 KB) carts.
; Adapted from clydeshaffer/gametank_sdk src/gt/crt0.s (MIT). Stripped for the
; single-bank path: no flash bank shift-out (the whole game maps at boot),
; no _sdk_init, no audio-firmware incbin. Interrupt handlers live in
; interrupt.s (not here).
; ---------------------------------------------------------------------------
.export   _init, _exit
.import   _main
.export   __STARTUP__ : absolute = 1
.import   __RAM_START__, __RAM_SIZE__
.import   copydata, zerobss, initlib, donelib

.PC02                                 ; W65C02 opcode set (stz/bra/phx/...)

BankReg = $2005
VIA     = $2800
DDRA    = 3
ORAr    = 1

.include "zeropage.inc"

.segment "STARTUP"

_init:    LDX     #$FF                ; init stack pointer to $01FF
          TXS
          CLD

          LDX     #0                  ; brief VIA wakeup delay
viaWakeup:
          INX
          BNE     viaWakeup

          ; Park the banking register at a known state. With a single 32 KB
          ; cart the active bank is fixed at boot; no flash bank shift needed.
          STZ     BankReg
          STZ     $1FFF

          LDA     #%00000111          ; VIA DDRA: low 3 bits output (bank pins)
          STA     VIA+DDRA
          LDA     #$FF
          STA     VIA+ORAr

; ---------------------------------------------------------------------------
; cc65 C argument-stack pointer = top of work RAM
          LDA     #<(__RAM_START__ + __RAM_SIZE__)
          STA     c_sp
          LDA     #>(__RAM_START__ + __RAM_SIZE__)
          STA     c_sp+1

; ---------------------------------------------------------------------------
          JSR     zerobss             ; clear BSS
          JSR     copydata            ; copy initialized DATA to RAM
          JSR     initlib             ; run constructors

          JSR     _main

_exit:    JSR     donelib             ; run destructors
          BRK
