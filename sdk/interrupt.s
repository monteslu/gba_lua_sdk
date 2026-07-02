; ---------------------------------------------------------------------------
; GameTank interrupt handlers (single-bank runtime, no draw queue).
; Modeled on clydeshaffer/gametank_sdk src/gt/interrupt.s (MIT).
;
; NMI  = vblank: release the vsync spin (gt_frameflag) and bump the tick
;        counter. $1FFF is the boot guard the startup code zeroes.
; IRQ  = blit complete: acknowledge DMA (write 0 to $4006) and clear
;        gt_draw_busy, releasing every drain-spin in the runtime.
;        STZ touches no registers, so nothing needs saving.
; ---------------------------------------------------------------------------
.import   _gt_frameflag
.import   _gt_draw_busy
.import   _gt_ticks
.export   _irq_int, _nmi_int

DMA_Start = $4006

.PC02                             ; W65C02 assembly mode

.segment  "CODE"

_nmi_int:
        PHA
        LDA $1FFF
        BNE nmi_done
        STZ _gt_frameflag
        INC _gt_ticks
        BNE nmi_done
        INC _gt_ticks+1
nmi_done:
        PLA
        RTI

_irq_int:
        STZ DMA_Start
        STZ _gt_draw_busy
        RTI
