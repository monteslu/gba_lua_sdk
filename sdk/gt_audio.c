/* gt_audio.c — GameTank audio coprocessor (a second 65C02 driving a DAC).
 * Init/upload protocol and the MIDI pitch table adapted from the
 * MIT-licensed gametank_sdk (audio_coprocessor.c). v1 voice model: one
 * sine operator per channel — clean tones for game sfx; the FM instrument
 * and tracker layers come with the sfx converter. */
#include "gametank.h"
#include "gt_api.h"

/* FLASH2M builds (GT_BANKED, passed by bin/gtlua.js with GT_FW_BANK): the
 * 4 KB firmware blob is the SDK's biggest RODATA and overflows the fixed
 * bank, so it rides in a game bank instead — and gt_audio_init() must map
 * that bank in BEFORE the upload loop reads it (mirrors the sheet loader's
 * gt_bank(2)-then-read pattern; a linked-but-unmapped blob uploads garbage
 * and plays silence, which a clean link does NOT catch). */
#ifdef GT_BANKED
#pragma rodata-name ("B2RODATA")
#endif
#include "gt_acp_fw.h"
#ifdef GT_BANKED
#pragma rodata-name ("RODATA")
#endif

#define PITCH_MSB 0x10
#define PITCH_LSB 0x20
#define AMPLITUDE 0x30
#define AUDIO_PARAMS ((volatile unsigned char *) 0x3070)
/* ACP zero page $02/$03 is WavePTR: the firmware's reset code points it at
 * the sine table ($0600). The LOW byte stays $00 forever (the table is
 * page-aligned!) so the boot handshake must poll the HIGH byte at $3003 —
 * upstream gets this right by reading a 16-bit int at $3002. Polling the
 * single byte at $3002 hangs the console forever. */
#define WAVE_TABLE_PAGE ((volatile unsigned char *) 0x3003)

/* 108 MIDI notes, 2 bytes each (MSB, LSB) — from the MIT gametank_sdk */
static const unsigned char pitch_table[216] = {
    0x00,0x4D,0x00,0x51,0x00,0x56,0x00,0x5B,0x00,0x61,0x00,0x66,0x00,0x6C,0x00,0x73,0x00,0x7A,0x00,0x81,0x00,0x89,0x00,0x91,
    0x00,0x99,0x00,0xA2,0x00,0xAC,0x00,0xB6,0x00,0xC1,0x00,0xCD,0x00,0xD9,0x00,0xE6,0x00,0xF3,0x01,0x02,0x01,0x11,0x01,0x21,
    0x01,0x33,0x01,0x45,0x01,0x58,0x01,0x6D,0x01,0x82,0x01,0x99,0x01,0xB2,0x01,0xCB,0x01,0xE7,0x02,0x04,0x02,0x22,0x02,0x43,
    0x02,0x65,0x02,0x8A,0x02,0xB0,0x02,0xD9,0x03,0x04,0x03,0x32,0x03,0x63,0x03,0x97,0x03,0xCD,0x04,0x07,0x04,0x44,0x04,0x85,
    0x04,0xCA,0x05,0x13,0x05,0x60,0x05,0xB2,0x06,0x09,0x06,0x65,0x06,0xC6,0x07,0x2D,0x07,0x9A,0x08,0x0E,0x08,0x89,0x09,0x0B,
    0x09,0x94,0x0A,0x26,0x0A,0xC1,0x0B,0x64,0x0C,0x12,0x0C,0xCA,0x0D,0x8C,0x0E,0x5B,0x0F,0x35,0x10,0x1D,0x11,0x12,0x12,0x16,
    0x13,0x29,0x14,0x4D,0x15,0x82,0x16,0xC9,0x18,0x24,0x19,0x93,0x1B,0x19,0x1C,0xB5,0x1E,0x6A,0x20,0x39,0x22,0x24,0x24,0x2B,
    0x26,0x52,0x28,0x99,0x2B,0x03,0x2D,0x92,0x30,0x48,0x33,0x27,0x36,0x31,0x39,0x6A,0x3C,0xD4,0x40,0x72,0x44,0x47,0x48,0x57,
    0x4C,0xA4,0x51,0x32,0x56,0x06,0x5B,0x24,0x60,0x8F,0x66,0x4D,0x6C,0x62,0x72,0xD4,0x79,0xA8,0x80,0xE4,0x88,0x8E,0x90,0xAD,
};

#define FEEDBACK_AMT 0x04
static unsigned char audio_ready = 0;

void gt_audio_init(void) {
    unsigned int i;
    unsigned char op;
    *audio_rate = 0x7F;
#ifdef GT_BANKED
    gt_bank(GT_FW_BANK);         /* map the firmware's bank in FIRST */
#endif
    for (i = 0; i < 4096; ++i) aram[i] = gt_acp_fw[i];
    AUDIO_PARAMS[0] = 0;
    *audio_reset = 0;
    *audio_rate = 255;
    /* wait for the ACP reset handler to run (it writes the sine-table page
     * into WavePTR high). Bounded so a dead coprocessor can't brick boot. */
    for (i = 0; i < 60000u; ++i) { if (*WAVE_TABLE_PAGE) break; }
    /* sane default state: no feedback per channel, every operator silent */
    for (op = 0; op < 4; ++op) aram[FEEDBACK_AMT + op] = 128;
    for (op = 0; op < 16; ++op) aram[AMPLITUDE + op] = 128;
    *audio_nmi = 1;
    audio_ready = 1;
}

/* play a MIDI note (0-107) on channel 0-3 at volume 0-127.
 *
 * Voice model: the firmware renders each channel as a 4-operator FM chain
 * (audio_fw.asm doChannel). An amplitude byte scales an operator via
 * sin(p)+sin(p+amp) — so 128 (=half the sine period) is SILENT and values
 * away from 128 get louder; music.c encodes level L as (L>>1)+128. Only the
 * 4th operator (index op+3) reaches the DAC; ops 1-3 are phase modulators.
 * Keeping the modulators at 128 zeroes their stages out of the chain and
 * yields a clean sine from the carrier. */
void gt_note(int ch, int note, int vol) {
    unsigned char op, i, idx;
    if (!audio_ready) return;
    op = (unsigned char)((ch & 3) << 2);
    if (note < 0) note = 0;
    if (note > 107) note = 107;
    idx = (unsigned char)(note << 1);
    for (i = 0; i < 4; ++i) {
        aram[PITCH_MSB + op + i] = pitch_table[idx];
        aram[PITCH_LSB + op + i] = pitch_table[idx + 1];
        aram[AMPLITUDE + op + i] = 128;          /* modulators off */
    }
    aram[AMPLITUDE + op + 3] = (unsigned char)(((vol & 0x7F) >> 1) + 128);
    *audio_nmi = 1;
}

void gt_noteoff(int ch) {
    unsigned char op, i;
    if (!audio_ready) return;
    op = (unsigned char)((ch & 3) << 2);
    for (i = 0; i < 4; ++i) aram[AMPLITUDE + op + i] = 128;
    *audio_nmi = 1;
}
