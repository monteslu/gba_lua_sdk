/* gt_music.c — PICO-8-style sfx()/music() for the GameTank audio coprocessor.
 *
 * The GameTank has a second 65C02 (the ACP) running a fixed 4-operator FM
 * firmware (uploaded by gt_audio_init() in gt_audio.c). Each of its 4 channels
 * is a 4-op FM voice; the main CPU drives it by poking parameters into ACP
 * shared RAM ($3000-$3FFF, the `aram` window) and pulsing the audio NMI.
 *
 * This is a SLIMMED port of the upstream gametank_sdk tracker
 * (src/gt/audio/music.c). What we kept, verbatim in spirit:
 *   - the FM Instrument model (per-op env_initial/decay/sustain + op_transpose
 *     + feedback), and the built-in instrument voices (instruments.c).
 *   - the per-frame envelope advance in tick_music(): every active operator
 *     decays from env_initial toward env_sustain by env_decay, exactly like
 *     upstream, so notes have real FM attack/decay shape (not flat tones).
 *   - the sound-effect-over-music priority idea (an sfx grabs a channel and
 *     the tune's notes on that channel are muted until the sfx finishes).
 *
 * What we DROPPED / reimagined for gtlua's audience (young Lua devs):
 *   - No ROM-bank-switched .gtm song files or asset-index tables. Authoring a
 *     tracker file is not Lua-idiomatic. Instead sfx/music are triggered BY
 *     INDEX and the data lives in plain C arrays the compiler emits (either
 *     the built-in bank below, or user-defined sound()/song() tables). This
 *     keeps everything in the flat address space — no banking gymnastics.
 *   - SFX are a simple list of {note,duration} steps on one channel (upstream
 *     packs 4 amplitudes + 4 notes per frame — powerful but nobody hand-writes
 *     it). A step here holds forever/for `dur` frames, then the next step.
 *   - Songs are per-channel note+duration events (see the SongEvent format in
 *     gt_music.h). music(-1) stops, like PICO-8.
 *
 * The whole thing costs one tick_music() call per frame on the MAIN CPU
 * (wired into gt_endframe()); it early-outs to almost nothing when nothing is
 * playing. Offloading the sequencer to the ACP is a later task.
 */
#include "gametank.h"
#include "gt_api.h"
#include "gt_music.h"

#define FEEDBACK_AMT 0x04
#define PITCH_MSB    0x10
#define PITCH_LSB    0x20
#define AMPLITUDE    0x30
#define NUM_FM_CH    4
#define NUM_FM_OPS   16

/* FLASH2M banked build (-DGT_BANKED, passed by bin/gtlua.js): this whole unit
 * — the ~2.4 KB sequencer code AND its instrument/sfx/song tables — lives in
 * PRIVATE BANK 3 with the rest of the audio unit (see gt_audio.c). The public
 * entry points are renamed with an _impl suffix; fixed-bank far-call stubs
 * (gt_music_stubs.s) own the plain names and bank-switch there around each
 * call.
 *
 * The sequencer MUST share the firmware's bank: set_note() reads
 * gt_pitch_table, which gt_audio.c homes next to the firmware blob. The old
 * layout (music in bank 2, table in bank 0) had every gt_sfx()-keyed note
 * fetch its frequency pair from whatever bank-2 bytes sat at the table's
 * address — audibly musical garbage, caught by comparing converted-sfx
 * recordings against the cart data. Co-locating also frees bank 2 (sheet +
 * compose) for the converted sfx/music blobs the hexdata emitter homes here.
 *
 * gt_music_init() is NOT renamed: it stays a fixed-bank thunk that installs
 * the (stub) hook then calls the banked real init, so the frame hook points
 * at the fixed-bank stub, not the banked impl (which would be unreachable
 * when another bank is mapped). */
#ifdef GT_BANKED
#pragma code-name ("B3CODE")
#pragma rodata-name ("B3RODATA")
#define GT_MB(name) name##_impl
#else
#define GT_MB(name) name
#endif

#define gt_music_tick GT_MB(gt_music_tick)
#define gt_sfx        GT_MB(gt_sfx)
#define gt_sfx_bank   GT_MB(gt_sfx_bank)
#define gt_music_bank GT_MB(gt_music_bank)
#define gt_music      GT_MB(gt_music)
#define gt_sfx_run    GT_MB(gt_sfx_run)
#define gt_music_play GT_MB(gt_music_play)
#define gt_music_stop GT_MB(gt_music_stop)
#define gt_music_run_init GT_MB(gt_music_run_init)

/* the MIDI pitch table lives in gt_audio.c (108 notes, 2 bytes each). */
extern const unsigned char gt_pitch_table[216];

/* --- built-in instruments (ported from upstream instruments.c) --------------
 * Layout per op index: env_initial[4], env_decay[4], env_sustain[4],
 * op_transpose[4], then feedback + channel transpose. */
/* Voicing note (measured, not theoretical): the synth's per-channel output
 * caps at ~1/4 of the DAC swing so four channels sum without clipping, and
 * the carrier amplitude curve peaks near 0xE0 — 0xFF WRAPS TO SILENCE.
 * The old carriers (0x10-0x6f, upstream tracker mix levels) reached only
 * ~40% of the usable range and decayed to nothing in ~100ms: "quiet
 * clicks". Carriers now sit at the measured sweet spot with decays slow
 * enough to leave a body. */
static const Instrument gt_instr[GT_NUM_INSTR] = {
    /* 0 PIANO */   { {0x30,0x40,0x40,0xc0},{0x04,0x02,0x10,0x03},{0x04,0x02,0x10,0x60},{0,0,0,0},   0,   0 },
    /* 1 GUITAR */  { {0x6f,0x40,0x68,0xc0},{0x00,0xFF,0x02,0x08},{0x00,0x00,0x40,0x10},{12,36,0,24},8, -12 },
    /* 2 BASS */    { {0x58,0x88,0x58,0xc0},{0x18,0x08,0x04,0x03},{0x18,0x08,0x04,0x04},{28,12,0,12}, 0, -24 },
    /* 3 SNARE */   { {0x88,0x8f,0x8f,0xe0},{0x18,0x02,0x04,0x05},{0x18,0x08,0x08,0x00},{36,0,0,0},   8,  -8 },
    /* 4 SITAR */   { {0x60,0x40,0x01,0x60},{0x00,0xFF,0xF8,0xFF},{0x00,0x60,0x60,0x60},{12,36,12,24},4, -24 },
    /* 5 HORN */    { {0x00,0x00,0x40,0xe0},{0x00,0x00,0x04,0x06},{0x00,0x00,0x00,0x40},{12,36,12,24},0, -12 },
    /* 6 BELL */    { {0x50,0x30,0x50,0xe0},{0x02,0x03,0x01,0x04},{0x00,0x00,0x00,0x00},{0,24,0,19},  2,   0 },
    /* 7 BLIP */    { {0x00,0x00,0x00,0xe0},{0x00,0x00,0x00,0x12},{0x00,0x00,0x00,0x00},{0,0,0,0},    0,   0 },
};

/* per-op live state (mirrors upstream music.c) */
static unsigned char env_initial[NUM_FM_OPS];
static unsigned char env_decay[NUM_FM_OPS];
static unsigned char env_sustain[NUM_FM_OPS];
static unsigned char op_transpose[NUM_FM_OPS];
static unsigned char amps[NUM_FM_OPS];        /* current op output level */
static const unsigned char ch_mask[NUM_FM_CH] = {1, 2, 4, 8};
static signed char ch_note_offset[NUM_FM_CH];

/* which channels a live note is decaying on (music path) */
static unsigned char note_held_mask;
static unsigned char music_ch_mask;           /* channels not grabbed by an sfx */

/* --- sound-effect layer (one active sfx per channel) --- */
static const SfxStep *sfx_step[NUM_FM_CH];     /* current step */
static const SfxStep *sfx_end[NUM_FM_CH];      /* one-past-last step */
static unsigned char  sfx_left[NUM_FM_CH];     /* frames left in this step */
static unsigned char  sfx_instr[NUM_FM_CH];    /* instrument index for this sfx */

/* --- song layer (one active song) --- */
static const SongEvent *song_cursor;
static const SongEvent *song_start;
static const SongEvent *song_end;
static unsigned char song_delay;               /* frames until next event */
static unsigned char song_loop;                /* 1 = loop at end */
static unsigned char song_playing;

static unsigned char audio_on;                 /* gt_audio_init() ran? */

/* --- pattern-music layer (converted PICO-8 __music__; bodies below) --- */
static const unsigned char *mus_bank;
static unsigned char mus_active;
static unsigned char mus_pat;
static unsigned char mus_first;
static unsigned char mus_loop;
static unsigned int  mus_left;
static void advance_pattern(void);

/* upload one instrument's per-op envelope + transpose to a channel's 4 ops */
static void apply_instrument(unsigned char ch, unsigned char idx) {
    unsigned char op = (unsigned char)(ch << 2);
    unsigned char i;
    const Instrument *ins = &gt_instr[idx];
    ch_note_offset[ch] = ins->transpose;
    aram[FEEDBACK_AMT + ch] = (unsigned char)((ins->feedback << 3) + 128);
    for (i = 0; i < 4; ++i) {
        env_initial[op + i]  = ins->env_initial[i];
        env_decay[op + i]    = ins->env_decay[i];
        env_sustain[op + i]  = ins->env_sustain[i];
        op_transpose[op + i] = ins->op_transpose[i];
    }
}

/* set the 4 operator pitches for a note on channel `ch` (upstream set_note) */
static void set_note(unsigned char ch, unsigned char note) {
    unsigned char op = (unsigned char)(ch << 2);
    unsigned char i, nn, idx;
    for (i = 0; i < 4; ++i) {
        nn = (unsigned char)(op_transpose[op + i] + note);
        if (nn > 107) nn = 107;
        idx = (unsigned char)(nn << 1);
        aram[PITCH_MSB + op + i] = gt_pitch_table[idx];
        aram[PITCH_LSB + op + i] = gt_pitch_table[idx + 1];
    }
}

/* trigger a note: reset every op's amplitude to its env_initial (attack) */
static void key_on(unsigned char ch, unsigned char note) {
    unsigned char op = (unsigned char)(ch << 2);
    unsigned char i;
    set_note(ch, (unsigned char)(note + ch_note_offset[ch]));
    for (i = 0; i < 4; ++i) {
        amps[op + i] = env_initial[op + i];
        aram[AMPLITUDE + op + i] = (unsigned char)((amps[op + i] >> 1) + 128);
    }
    note_held_mask |= ch_mask[ch];
}

/* silence a channel's carrier (release) */
static void key_off(unsigned char ch) {
    unsigned char op = (unsigned char)(ch << 2);
    amps[op + 3] = 0;
    aram[AMPLITUDE + op + 3] = 128;
    note_held_mask &= (unsigned char)~ch_mask[ch];
}

/* state reset — banked into bank 2 (renamed _impl) alongside the sequencer. */
void gt_music_run_init(void) {
    unsigned char i;
    for (i = 0; i < NUM_FM_OPS; ++i) {
        env_initial[i] = 0; env_decay[i] = 0; env_sustain[i] = 0;
        op_transpose[i] = 0; amps[i] = 0;
    }
    for (i = 0; i < NUM_FM_CH; ++i) {
        sfx_left[i] = 0; sfx_step[i] = 0;
        ch_note_offset[i] = 0;
    }
    note_held_mask = 0;
    music_ch_mask = 15;
    song_playing = 0;
    song_cursor = 0;
    audio_on = 1;
}

/* start built-in or user sfx `steps`[0..count) on channel `ch` (0-3) with
 * instrument `instr`. The sfx grabs the channel from the tune until it ends. */
void gt_sfx_run(const SfxStep *steps, unsigned char count,
                unsigned char instr, unsigned char ch) {
    if (!audio_on) return;
    ch &= 3;
    if (instr >= GT_NUM_INSTR) instr = 0;
    sfx_instr[ch] = instr;
    apply_instrument(ch, instr);
    sfx_step[ch] = steps;
    sfx_end[ch]  = steps + count;
    sfx_left[ch] = 0;                 /* advance to step 0 on the first tick */
    music_ch_mask &= (unsigned char)~ch_mask[ch];   /* mute the tune here */
    *audio_nmi = 1;
}

void gt_music_play(const SongEvent *events, unsigned char count,
                   const unsigned char *instr4, unsigned char loop) {
    unsigned char i;
    if (!audio_on) return;
    /* silence everything and load the song's 4 channel instruments */
    for (i = 0; i < NUM_FM_OPS; ++i) { amps[i] = 0; aram[AMPLITUDE + i] = 128; }
    note_held_mask = 0;
    music_ch_mask = 15;
    for (i = 0; i < NUM_FM_CH; ++i) apply_instrument(i, instr4[i]);
    song_start  = events;
    song_cursor = events;
    song_end    = events + count;
    song_delay  = 0;
    song_loop   = loop;
    song_playing = 1;
    *audio_nmi = 1;
}

void gt_music_stop(void) {
    unsigned char i;
    if (!audio_on) return;
    song_playing = 0;
    song_cursor = 0;
    if (mus_active) {
        mus_active = 0;
        for (i = 0; i < NUM_FM_CH; ++i) sfx_step[i] = 0;
    }
    for (i = 0; i < NUM_FM_OPS; ++i) { amps[i] = 0; aram[AMPLITUDE + i] = 128; }
    note_held_mask = 0;
    music_ch_mask = 15;
    *audio_nmi = 1;
}

/* advance the sfx layer for one channel; returns nothing. */
static void tick_sfx(unsigned char ch) {
    const SfxStep *s;
    if (!sfx_step[ch]) return;
    if (sfx_left[ch] > 1) { --sfx_left[ch]; return; }
    /* current step expired (or first frame): load the next one */
    s = sfx_step[ch];
    if (s >= sfx_end[ch]) {
        /* sfx finished: release the channel back to the tune */
        key_off(ch);
        sfx_step[ch] = 0;
        music_ch_mask |= ch_mask[ch];
        return;
    }
    if (s->note == 0) {
        key_off(ch);
    } else {
        key_on(ch, (unsigned char)(s->note - 1));  /* note is 1-based (0=rest) */
    }
    sfx_left[ch] = s->dur ? s->dur : 1;
    sfx_step[ch] = s + 1;
}

/* the once-per-frame sequencer. Slim port of upstream tick_music():
 *   1. advance each channel's sfx step
 *   2. decay every held operator toward its sustain level (FM envelope)
 *   3. step the song when its delay runs out
 * Early-outs cheaply when nothing is playing. */
void gt_music_tick(void) {
    unsigned char ch, op, i;
    if (!audio_on) return;

    /* 1. sound effects */
    for (ch = 0; ch < NUM_FM_CH; ++ch) tick_sfx(ch);

    /* 1b. pattern music: advance when the longest line has played out */
    if (mus_active) {
        if (mus_left > 1) --mus_left;
        else advance_pattern();
    }

    /* 2. envelope advance for every operator whose channel holds a note.
     * (upstream: amps -= decay, clamped at sustain via the sign trick.) */
    if (note_held_mask) {
        op = 0;
        for (ch = 0; ch < NUM_FM_CH; ++ch) {
            if (note_held_mask & ch_mask[ch]) {
                for (i = 0; i < 4; ++i) {
                    /* Upstream's sign-XOR step trick computes (sustain-amps)
                     * in 8 bits: any level more than 128 ABOVE its sustain
                     * wraps positive and snapped to sustain on the first
                     * tick — instant mute. Upstream never ran carriers past
                     * 0x6f so it never tripped; our measured-loud voices
                     * (0xC0-0xE0 over sustain 0) always did. Explicit
                     * unsigned clamping, both directions: */
                    if (env_decay[op] & 0x80) {          /* rising attack */
                        unsigned char step = (unsigned char)(0 - env_decay[op]);
                        unsigned char nv = (unsigned char)(amps[op] + step);
                        if (nv < amps[op] || nv > env_sustain[op]) nv = env_sustain[op];
                        amps[op] = nv;
                    } else if (amps[op] > env_sustain[op]) {
                        unsigned char d = (unsigned char)(amps[op] - env_sustain[op]);
                        amps[op] = (unsigned char)(d > env_decay[op]
                            ? amps[op] - env_decay[op] : env_sustain[op]);
                    } else {
                        amps[op] = env_sustain[op];
                    }
                    aram[AMPLITUDE + op] = (unsigned char)((amps[op] >> 1) + 128);
                    ++op;
                }
            } else {
                op = (unsigned char)(op + 4);
            }
        }
    }

    /* 3. song sequencer */
    if (song_playing) {
        if (song_delay > 0) {
            --song_delay;
        } else {
            while (song_cursor < song_end && song_cursor->delay == 0) {
                /* zero-delay events fire this frame; note events carry delay>0
                 * to the NEXT event, so we place a note then read its delay. */
                unsigned char ev_ch = song_cursor->ch & 3;
                if (music_ch_mask & ch_mask[ev_ch]) {
                    if (song_cursor->note == 0) key_off(ev_ch);
                    else key_on(ev_ch, (unsigned char)(song_cursor->note - 1));
                }
                ++song_cursor;
            }
            if (song_cursor < song_end) {
                unsigned char ev_ch = song_cursor->ch & 3;
                if (music_ch_mask & ch_mask[ev_ch]) {
                    if (song_cursor->note == 0) key_off(ev_ch);
                    else key_on(ev_ch, (unsigned char)(song_cursor->note - 1));
                }
                song_delay = song_cursor->delay;
                ++song_cursor;
            } else {
                /* end of song */
                if (song_loop) {
                    song_cursor = song_start;
                    song_delay = 0;
                } else {
                    song_playing = 0;
                    for (i = 0; i < NUM_FM_OPS; ++i) { amps[i] = 0; aram[AMPLITUDE + i] = 128; }
                    note_held_mask = 0;
                }
            }
        }
    }

    *audio_nmi = 1;
}

/* ===========================================================================
 * Built-in sound effects and songs (the zero-authoring PICO-8 path). A kid
 * calls sfx(0) for a jump, music(0) for a tune — no data to write.
 * Notes are 1-based MIDI (0 = rest); see gt_music.h for the step format.
 * GT_NO_BUILTIN_SFX (set by bin/gtlua.js when the cart registers converted
 * PICO-8 banks) compiles the whole zero-authoring layer out — a cart playing
 * its own cart data never falls through to these, and the ~700 bytes of
 * tables matter in a full bank.
 * ========================================================================= */
#ifndef GT_NO_BUILTIN_SFX

/* MIDI helpers for readability (Cn4 = middle-ish). +1 because note is 1-based. */
#define N(m) ((unsigned char)((m) + 1))
#define REST 0

static const SfxStep sfx0[] = {  /* 0 JUMP: quick upward blip */
    { N(60), 2 }, { N(64), 2 }, { N(67), 2 }, { N(72), 3 },
};
static const SfxStep sfx1[] = {  /* 1 PICKUP: two bright notes */
    { N(72), 3 }, { N(79), 5 },
};
static const SfxStep sfx2[] = {  /* 2 SHOOT: high down-chirp */
    { N(84), 2 }, { N(76), 2 }, { N(69), 3 },
};
static const SfxStep sfx3[] = {  /* 3 EXPLODE: low noisy hit (snare instr) */
    { N(40), 4 }, { N(36), 6 }, { N(31), 8 },
};
static const SfxStep sfx4[] = {  /* 4 BLIP: single short tick */
    { N(72), 3 },
};
static const SfxStep sfx5[] = {  /* 5 POWERUP: rising arpeggio */
    { N(60), 2 }, { N(64), 2 }, { N(67), 2 }, { N(72), 2 }, { N(76), 4 },
};
static const SfxStep sfx6[] = {  /* 6 HURT: down two-note */
    { N(55), 3 }, { N(48), 5 },
};
static const SfxStep sfx7[] = {  /* 7 SELECT: neutral double-blip */
    { N(69), 2 }, REST_STEP, { N(69), 3 },
};

/* index -> {steps, count, default instrument} */
static const BuiltinSfx builtin_sfx[GT_NUM_BUILTIN_SFX] = {
    { sfx0, 4, GT_INSTR_BLIP },
    { sfx1, 2, GT_INSTR_BELL },
    { sfx2, 3, GT_INSTR_BLIP },
    { sfx3, 3, GT_INSTR_SNARE },
    { sfx4, 1, GT_INSTR_BLIP },
    { sfx5, 5, GT_INSTR_BELL },
    { sfx6, 2, GT_INSTR_HORN },
    { sfx7, 3, GT_INSTR_BLIP },
};

#endif /* !GT_NO_BUILTIN_SFX */

/* auto channel: round-robin over the 4 FM channels for un-specified sfx() */
static unsigned char next_sfx_ch = 0;

/* converted PICO-8 sfx bank (tools/p8sfx.mjs): u8 n; n x u16le offsets;
 * per sfx: u8 instr, u8 count, count x {u8 note, u8 dur} (= SfxStep).
 * Registered by the port from a hexdata blob (fixed RODATA, so this bank-2
 * code can read it from any mapping). A registered bank REPLACES the
 * builtin table for ids it covers; count 0 falls through to the builtins. */
static const unsigned char *sfx_bank = 0;

void gt_sfx_bank(const unsigned char *bank) { sfx_bank = bank; }

/* converted PICO-8 music bank (bin/p8sfx.mjs --music): u8 n; n x 5 bytes
 * { flags, ch0..ch3 } — flags bit0 = loop start, bit1 = loop end, bit2 =
 * stop-after; chN = an sfx-bank id or 0xFF for a silent channel. A pattern
 * plays its channels' converted sfx simultaneously through the normal
 * per-channel step machinery and advances when the longest one ends —
 * PICO-8's music IS 4-channel sfx playback, so the engine mirrors that. */
void gt_music_bank(const unsigned char *bank) { mus_bank = bank; }

/* start bank sfx `id` on channel `ch`; returns its total frame count (0 if
 * the id is empty/out of range — the channel just stays silent) */
static void scale_carrier(unsigned char ch, unsigned char vol) {
    unsigned char op = (unsigned char)((ch << 2) + 3);
    env_initial[op] = (unsigned char)(((unsigned int)env_initial[op] * vol) >> 7);
    env_sustain[op] = (unsigned char)(((unsigned int)env_sustain[op] * vol) >> 7);
}

static unsigned int start_bank_sfx(unsigned char id, unsigned char ch) {
    unsigned int off, total;
    unsigned char count, i;
    const SfxStep *steps;
    if (!sfx_bank || id >= sfx_bank[0]) return 0;
    off = (unsigned int)sfx_bank[1 + id * 2] | ((unsigned int)sfx_bank[2 + id * 2] << 8);
    count = sfx_bank[off + 1];
    if (!count) return 0;
    steps = (const SfxStep *)(sfx_bank + off + 3);
    apply_instrument(ch, sfx_bank[off] >= GT_NUM_INSTR ? 0 : sfx_bank[off]);
    scale_carrier(ch, sfx_bank[off + 2]);
    sfx_instr[ch] = sfx_bank[off];
    sfx_step[ch] = steps;
    sfx_end[ch]  = steps + count;
    sfx_left[ch] = 0;
    total = 0;
    for (i = 0; i < count; ++i) total += steps[i].dur ? steps[i].dur : 1;
    return total;
}

static void start_pattern(unsigned char p) {
    const unsigned char *e;
    unsigned char c;
    unsigned int t, longest = 0;
    if (!mus_bank || p >= mus_bank[0]) { mus_active = 0; return; }
    e = mus_bank + 1 + p * 5;
    for (c = 0; c < 4; ++c) {
        if (e[1 + c] == 0xFF) continue;
        t = start_bank_sfx(e[1 + c], c);
        if (t > longest) longest = t;
    }
    if (!longest) { mus_active = 0; return; }  /* empty pattern: stop */
    mus_pat = p;
    mus_left = longest;
    mus_active = 1;
    *audio_nmi = 1;
}

/* the current pattern finished: honor its flags, else fall through */
static void advance_pattern(void) {
    const unsigned char *e = mus_bank + 1 + mus_pat * 5;
    unsigned char p;
    if (e[0] & 4) { mus_active = 0; return; }          /* stop-after */
    if (e[0] & 2) {                                     /* loop end */
        p = mus_pat;
        while (p > 0 && !(mus_bank[1 + p * 5] & 1)) --p; /* nearest loop start */
        start_pattern(p);
        return;
    }
    p = (unsigned char)(mus_pat + 1);
    if (p >= mus_bank[0]) {
        if (mus_loop) start_pattern(mus_first);
        else mus_active = 0;
        return;
    }
    start_pattern(p);
}

void gt_sfx(int n, int ch) {
#ifndef GT_NO_BUILTIN_SFX
    const BuiltinSfx *b;
#endif
    unsigned char c;
    if (!audio_on) return;
    if (n < 0) return;
    if (ch < 0) { c = next_sfx_ch; next_sfx_ch = (unsigned char)((next_sfx_ch + 1) & 3); }
    else c = (unsigned char)(ch & 3);
    if (sfx_bank && n < sfx_bank[0]) {
        unsigned int off = (unsigned int)sfx_bank[1 + n * 2]
                         | ((unsigned int)sfx_bank[2 + n * 2] << 8);
        unsigned char count = sfx_bank[off + 1];
        if (count) {
            gt_sfx_run((const SfxStep *)(sfx_bank + off + 3), count,
                       sfx_bank[off], c);
            scale_carrier(c, sfx_bank[off + 2]);
            return;
        }
    }
#ifndef GT_NO_BUILTIN_SFX
    if (n >= GT_NUM_BUILTIN_SFX) return;
    b = &builtin_sfx[n];
    gt_sfx_run(b->steps, b->count, b->instr, c);
#endif
}

#ifndef GT_NO_BUILTIN_SFX
/* --- built-in songs ---------------------------------------------------------
 * A song is a flat list of {ch, note, delay} events. `delay` is frames until
 * the NEXT event fires; a note plays until its channel is re-keyed or the
 * decay silences it. Kept short + loopable. */

/* 0: a simple 4-bar lead over a bass pulse (bell lead ch0, bass ch1) */
static const SongEvent song0[] = {
    { 1, N(36), 0 }, { 0, N(72), 16 },
    { 0, N(76), 16 },
    { 1, N(38), 0 }, { 0, N(79), 16 },
    { 0, N(76), 16 },
    { 1, N(41), 0 }, { 0, N(72), 16 },
    { 0, N(74), 16 },
    { 1, N(36), 0 }, { 0, N(67), 16 },
    { 0, N(72), 16 },
};
/* 1: gentle two-note bassline loop */
static const SongEvent song1[] = {
    { 1, N(40), 24 }, { 1, N(43), 24 },
    { 1, N(45), 24 }, { 1, N(43), 24 },
};

/* index -> {events, count, instrument-per-channel[4]} */
static const unsigned char song0_instr[4] = { GT_INSTR_BELL, GT_INSTR_BASS, GT_INSTR_PIANO, GT_INSTR_PIANO };
static const unsigned char song1_instr[4] = { GT_INSTR_PIANO, GT_INSTR_BASS, GT_INSTR_PIANO, GT_INSTR_PIANO };

static const BuiltinSong builtin_song[GT_NUM_BUILTIN_SONG] = {
    { song0, 14, song0_instr },
    { song1, 4,  song1_instr },
};

#endif /* !GT_NO_BUILTIN_SFX */

void gt_music(int n, int loop) {
#ifndef GT_NO_BUILTIN_SFX
    const BuiltinSong *s;
#endif
    if (!audio_on) return;
    if (n < 0) { gt_music_stop(); return; }
    if (mus_bank) {
        mus_first = (unsigned char)n;
        mus_loop = (unsigned char)(loop ? 1 : 0);
        start_pattern((unsigned char)n);
        return;
    }
#ifndef GT_NO_BUILTIN_SFX
    if (n >= GT_NUM_BUILTIN_SONG) return;
    s = &builtin_song[n];
    gt_music_play(s->events, s->count, s->instr4, (unsigned char)(loop ? 1 : 0));
#endif
}

/* ---- fixed-bank init thunk -------------------------------------------------
 * gt_music_init() must live in the always-mapped fixed bank: main() calls it
 * once, and it installs gt_frame_hook to point at the PLAIN gt_music_tick
 * symbol. In banked builds that plain symbol is the fixed-bank stub (which
 * banks in bank 2 around the real _impl); pointing the hook at the bank-2
 * impl directly would jump into unmapped ROM whenever another bank is live.
 * The #undef restores the plain names so this thunk references the stubs. */
#ifdef GT_BANKED
#pragma code-name ("CODE")
#pragma rodata-name ("RODATA")
#undef gt_music_tick
#undef gt_music_run_init
void gt_music_tick(void);        /* fixed-bank stub (gt_music_stubs.s) */
void gt_music_run_init(void);    /* fixed-bank stub (gt_music_stubs.s) */
#endif

void gt_music_init(void) {
    gt_frame_hook = gt_music_tick;   /* gt_endframe() now advances the tracker */
    gt_music_run_init();             /* reset sequencer state (bank 2 in FLASH2M) */
}
