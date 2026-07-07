; gt_music_stubs.s — FLASH2M fixed-bank far-call stubs for the gt_music unit.
;
; The banked build exiles gt_music.c (the sfx/music sequencer + its
; instrument/sfx/song tables, ~2.7 KB) out of the always-mapped FIXED bank into
; game bank 2 ($8000-$BFFF, with the firmware + sheet), reclaiming fixed-bank
; RODATA/CODE the near-full runtime needs. These stubs live in the FIXED bank
; and own the plain public symbol names, so every caller — game code in any
; bank, and gt_api's gt_endframe -> (*gt_frame_hook)() — links to the stub
; transparently. Each stub switches to bank 2, jsr's the real _impl function,
; restores the caller's bank, and returns. Same shape as gt_math_stubs.s.
;
; ABI: cc65 __fastcall__/__near__ — the last argument (and return value) ride
; in A/X (high word in sreg); earlier arguments sit on the cc65 C-stack in RAM.
; The stub touches only A/X and one BSS byte (via gt_bank_raw); it never
; disturbs c_sp, sreg, or the C-stack RAM, and the bank switch only remaps the
; $8000-$BFFF window, so stacked arguments pass through untouched.
;
; Callee bank = PRIVATE BANK 3, the audio unit's home (see gt_audio.c).

.PC02
.import gt_bank_raw, gt_cur_bank
.import _gt_music_tick_impl, _gt_music_run_init_impl
.import _gt_sfx_impl, _gt_music_impl, _gt_sfx_bank_impl, _gt_music_bank_impl
.import _gt_sfx_run_impl, _gt_music_play_impl, _gt_music_stop_impl
.export _gt_music_tick, _gt_music_run_init
.export _gt_sfx, _gt_music, _gt_sfx_bank, _gt_music_bank
.export _gt_sfx_run, _gt_music_play, _gt_music_stop

GT_MUSIC_BANK = 3

.segment "BSS"
gtmus_sav_a: .res 1
gtmus_sav_x: .res 1

.segment "CODE"

.macro  GT_MUSIC_STUB label, impl
label:
        sta     gtmus_sav_a
        stx     gtmus_sav_x
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
        lda     gtmus_sav_a
        ldx     gtmus_sav_x
        rts
.endmacro

        GT_MUSIC_STUB _gt_music_tick,     _gt_music_tick_impl
        GT_MUSIC_STUB _gt_music_run_init, _gt_music_run_init_impl
        GT_MUSIC_STUB _gt_sfx,            _gt_sfx_impl
        GT_MUSIC_STUB _gt_sfx_bank,       _gt_sfx_bank_impl
        GT_MUSIC_STUB _gt_music_bank,     _gt_music_bank_impl
        GT_MUSIC_STUB _gt_music,          _gt_music_impl
        GT_MUSIC_STUB _gt_sfx_run,        _gt_sfx_run_impl
        GT_MUSIC_STUB _gt_music_play,     _gt_music_play_impl
        GT_MUSIC_STUB _gt_music_stop,     _gt_music_stop_impl
