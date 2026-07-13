/* gt_music.h - PICO-8-style sfx()/music() runtime surface (see gt_music.c).
 *
 * Data model for the BUILT-IN SfxStep/SongEvent tables (1-based table indices,
 * 0 = rest - an internal convention; the N() macro bakes the +1):
 *   SfxStep  { note, dur }      - one step of a sound effect on one channel;
 *                                 `note` plays (or rests) for `dur` frames.
 *   SongEvent{ ch, note, delay }- key channel `ch` (0-3) to `note`; `delay` is
 *                                 the number of frames before the NEXT event.
 * .gtm2 streams are DIFFERENT: their note bytes are the official format's raw
 * pitch-table indices, keyed unshifted (A4/440 = 57 = MIDI - 12).
 * The FM Instrument struct is byte-compatible with the upstream tracker. */
#ifndef GT_MUSIC_H
#define GT_MUSIC_H

/* 4-operator FM instrument (ported from gametank_sdk instruments.h) */
typedef struct {
    unsigned char env_initial[4];
    unsigned char env_decay[4];
    unsigned char env_sustain[4];
    unsigned char op_transpose[4];
    unsigned char feedback;
    signed char   transpose;
} Instrument;

/* built-in instrument indices */
#define GT_INSTR_PIANO  0
#define GT_INSTR_GUITAR 1
#define GT_INSTR_BASS   2
#define GT_INSTR_SNARE  3
#define GT_INSTR_SITAR  4
#define GT_INSTR_HORN   5
#define GT_INSTR_BELL   6
#define GT_INSTR_BLIP   7
#define GT_INSTR_CHIP   8
#define GT_INSTR_CHIP2  9
#define GT_NUM_INSTR    10

typedef struct { unsigned char note; unsigned char dur; } SfxStep;
typedef struct { unsigned char ch; unsigned char note; unsigned char delay; } SongEvent;

#define REST_STEP { 0, 1 }

typedef struct {
    const SfxStep *steps;
    unsigned char  count;
    unsigned char  instr;
} BuiltinSfx;

typedef struct {
    const SongEvent    *events;
    unsigned char       count;
    const unsigned char *instr4;
} BuiltinSong;

#define GT_NUM_BUILTIN_SFX  8
#define GT_NUM_BUILTIN_SONG 2

/* lifecycle: gt_music_init() runs right after gt_audio_init() */
void gt_music_init(void);
void gt_music_tick(void);   /* called once per frame by gt_endframe() */

/* PICO-8-shaped entry points (what the compiler emits for sfx()/music()) */
void gt_sfx(int n, int ch);     /* ch < 0 = auto-assign a channel */
void gt_sfx_bank(const unsigned char *bank); /* converted PICO-8 sfx (p8sfx.mjs) */
void gt_music_bank(const unsigned char *bank); /* converted __music__ patterns */
void gt_music(int n, int loop); /* n < 0 = stop */

/* lower-level: run an explicit step list / event list (for user-defined data) */
void gt_sfx_run(const SfxStep *steps, unsigned char count,
                unsigned char instr, unsigned char ch);
void gt_music_play(const SongEvent *events, unsigned char count,
                   const unsigned char *instr4, unsigned char loop);
void gt_music_stop(void);

/* .gtm2 - Clyde's official linear FM song format (the one midiconvert.js makes
 * and src/gt/audio/music.c plays). Plays alongside the PICO-8 sfx/pattern path. */
void gt_gtm2_play(const unsigned char *song, unsigned char loop);
void gt_gtm2_stop(void);

/* Project song bank: register the build's .gtm2 songs; music(n) then plays
 * project song n (the composer's tune), not a built-in. The compiler emits the
 * table + this call when the project carries songs. */
void gt_song_bank(const unsigned char* const* songs, unsigned char count);

#endif
