; gt_music_stubs.s - FLASH2M fixed-bank far-call stubs for the gt_music unit.
;
; The banked build exiles gt_music.c (the sfx/music sequencer + its
; instrument/sfx/song tables, ~2.7 KB) out of the always-mapped FIXED bank into
; game bank 2 ($8000-$BFFF, with the firmware + sheet), reclaiming fixed-bank
; RODATA/CODE the near-full runtime needs. These stubs live in the FIXED bank
; and own the plain public symbol names, so every caller - game code in any
; bank, and gt_api's gt_endframe -> (*gt_frame_hook)() - links to the stub
; transparently. Each stub switches to bank 2, jsr's the real _impl function,
; restores the caller's bank, and returns. Same shape as gt_math_stubs.s.
;
; ABI: cc65 __fastcall__/__near__ - the last argument (and return value) ride
; in A/X (high word in sreg); earlier arguments sit on the cc65 C-stack in RAM.
; The stub touches only A/X and one BSS byte (via gt_bank_raw); it never
; disturbs c_sp, sreg, or the C-stack RAM, and the bank switch only remaps the
; $8000-$BFFF window, so stacked arguments pass through untouched.
;
; Callee bank = PRIVATE BANK 3, the audio unit's home (see gt_audio.c).

.PC02
.importzp c_sp, sreg, regsave, ptr1, ptr2, ptr3, ptr4, tmp1, tmp2, tmp3, tmp4
.import gt_bank_raw, gt_cur_bank, _gt_bank_busy
.import _gt_music_tick_impl, _gt_music_run_init_impl
.import _gt_sfx_impl, _gt_music_impl, _gt_sfx_bank_impl, _gt_music_bank_impl
.import _gt_sfx_run_impl, _gt_music_play_impl, _gt_music_stop_impl
.import _gt_gtm2_play_impl, _gt_gtm2_stop_impl, _gt_song_bank_impl
.export _gt_music_tick, _gt_music_run_init
.export _gt_sfx, _gt_music, _gt_sfx_bank, _gt_music_bank
.export _gt_sfx_run, _gt_music_play, _gt_music_stop
.export _gt_gtm2_play, _gt_gtm2_stop, _gt_song_bank

GT_MUSIC_BANK = 3

.segment "BSS"
gtmus_sav_a: .res 1
gtmus_sav_x: .res 1
_gt_audio_lock: .res 1            ; nonzero while the main thread is inside
                                  ; an audio call: the NMI tick skips that
                                  ; vsync instead of racing the same state
.export _gt_audio_lock
zpsave:      .res 20              ; cc65 zp scratch of the interrupted code
isr_cstack:  .res 96              ; private C stack for the ISR-side tick
ISR_CSTACK_TOP = isr_cstack + 96
tick_debt:   .res 1               ; vsync ticks skipped while locked/busy

.segment "CODE"

.macro  GT_MUSIC_STUB label, impl
label:
        sta     gtmus_sav_a
        stx     gtmus_sav_x
        inc     _gt_audio_lock    ; the vblank tick must not interleave
        lda     gt_cur_bank
        pha
        lda     #GT_MUSIC_BANK
        jsr     gt_bank_raw
        lda     gtmus_sav_a
        ldx     gtmus_sav_x
        jsr     impl
        sta     gtmus_sav_a
        stx     gtmus_sav_x
        pla
        jsr     gt_bank_raw
        stz     _gt_audio_lock
        lda     gtmus_sav_a
        ldx     gtmus_sav_x
        rts
.endmacro

; ---------------------------------------------------------------------------
; gt_music_nmi_shim - the vblank-driven sequencer tick (installed into
; gt_nmi_hook by gt_music_init). Runs the bank-3 tick from INSIDE the NMI:
; wall-clock spacing no matter how long the game's frame runs, which is what
; a separate sound CPU feels like even though the sequencing stays on the
; main core. Skips (a) while the main thread is inside an audio call, and
; (b) re-entry into itself. cc65 code can't be interrupted and re-entered
; safely, so the interrupted thread's zp scratch (sp/sreg/regsave/ptr/tmp)
; is saved and the tick runs on a private C stack.
; ---------------------------------------------------------------------------
.export _gt_music_nmi_shim
_gt_music_nmi_shim:
        lda     _gt_audio_lock
        bne     @defer            ; main thread owns the audio state
        lda     _gt_bank_busy
        beq     @go
@defer: inc     tick_debt         ; make the time up next vblank
        rts
@go:    inc     _gt_audio_lock
        ; save cc65 zp scratch explicitly (layout isn't guaranteed contiguous)
        lda     c_sp
        sta     zpsave+0
        lda     c_sp+1
        sta     zpsave+1
        lda     sreg
        sta     zpsave+2
        lda     sreg+1
        sta     zpsave+3
        lda     ptr1
        sta     zpsave+4
        lda     ptr1+1
        sta     zpsave+5
        lda     ptr2
        sta     zpsave+6
        lda     ptr2+1
        sta     zpsave+7
        lda     ptr3
        sta     zpsave+8
        lda     ptr3+1
        sta     zpsave+9
        lda     ptr4
        sta     zpsave+10
        lda     ptr4+1
        sta     zpsave+11
        lda     tmp1
        sta     zpsave+12
        lda     tmp2
        sta     zpsave+13
        lda     tmp3
        sta     zpsave+14
        lda     tmp4
        sta     zpsave+15
        lda     regsave
        sta     zpsave+16
        lda     regsave+1
        sta     zpsave+17
        lda     regsave+2
        sta     zpsave+18
        lda     regsave+3
        sta     zpsave+19
        ; private C stack for the tick
        lda     #<ISR_CSTACK_TOP
        sta     c_sp
        lda     #>ISR_CSTACK_TOP
        sta     c_sp+1
        ; bank dance + tick (1 + any debt from skipped vsyncs, capped)
        lda     gt_cur_bank
        pha
        lda     #GT_MUSIC_BANK
        jsr     gt_bank_raw
        ldx     tick_debt
        stz     tick_debt
        inx                       ; this vsync's tick
        cpx     #4
        bcc     @tl
        ldx     #3                ; cap the catch-up burst
@tl:    phx
        jsr     _gt_music_tick_impl
        plx
        dex
        bne     @tl
        pla
        jsr     gt_bank_raw
        ; restore the interrupted thread's world
        lda     zpsave+0
        sta     c_sp
        lda     zpsave+1
        sta     c_sp+1
        lda     zpsave+2
        sta     sreg
        lda     zpsave+3
        sta     sreg+1
        lda     zpsave+4
        sta     ptr1
        lda     zpsave+5
        sta     ptr1+1
        lda     zpsave+6
        sta     ptr2
        lda     zpsave+7
        sta     ptr2+1
        lda     zpsave+8
        sta     ptr3
        lda     zpsave+9
        sta     ptr3+1
        lda     zpsave+10
        sta     ptr4
        lda     zpsave+11
        sta     ptr4+1
        lda     zpsave+12
        sta     tmp1
        lda     zpsave+13
        sta     tmp2
        lda     zpsave+14
        sta     tmp3
        lda     zpsave+15
        sta     tmp4
        lda     zpsave+16
        sta     regsave
        lda     zpsave+17
        sta     regsave+1
        lda     zpsave+18
        sta     regsave+2
        lda     zpsave+19
        sta     regsave+3
        stz     _gt_audio_lock
        rts


        GT_MUSIC_STUB _gt_music_tick,     _gt_music_tick_impl
        GT_MUSIC_STUB _gt_music_run_init, _gt_music_run_init_impl
        GT_MUSIC_STUB _gt_sfx,            _gt_sfx_impl
        GT_MUSIC_STUB _gt_sfx_bank,       _gt_sfx_bank_impl
        GT_MUSIC_STUB _gt_music_bank,     _gt_music_bank_impl
        GT_MUSIC_STUB _gt_music,          _gt_music_impl
        GT_MUSIC_STUB _gt_sfx_run,        _gt_sfx_run_impl
        GT_MUSIC_STUB _gt_music_play,     _gt_music_play_impl
        GT_MUSIC_STUB _gt_music_stop,     _gt_music_stop_impl
        GT_MUSIC_STUB _gt_gtm2_play,      _gt_gtm2_play_impl
        GT_MUSIC_STUB _gt_gtm2_stop,      _gt_gtm2_stop_impl
        GT_MUSIC_STUB _gt_song_bank,      _gt_song_bank_impl
