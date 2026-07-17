// gba_sound.c — audio via maxmod. Module music + sample SFX.
//
// maxmod plays tracker modules (.mod/.xm/.s3m/.it) and sample effects from a
// SOUNDBANK (built offline by mmutil from the audio assets). The SDK ships a
// default multi-channel chiptune soundbank so music(0) works out of the box; a
// game can bring its own soundbank.bin (+ its generated IDs) for custom audio.
//
// Requirements maxmod imposes (handled here):
//   * mmInitDefault(soundbank, nchannels) once at boot.
//   * mmVBlank() must run in the VBlank IRQ (we add it to libtonc's irq table).
//   * mmFrame() must run every frame (called from gba_endframe).

#include "gba_api.h"
#include <maxmod.h>

// The soundbank blob. romdev auto-emits an asm stub that .incbins the
// build-provided soundbank.bin under this symbol (see the build wiring).
extern const mm_byte soundbank_bin[];

static int sound_ready;

// Reentrancy guard: mmFrame() runs from the VCOUNT IRQ (see gba_api.c) so it
// keeps mixing even when a slow _draw() overruns the frame. But maxmod is NOT
// reentrant — if the IRQ fired while the main thread is inside mmStart/mmEffect/
// mmStop, state would corrupt. Main-thread maxmod calls raise this flag; the
// IRQ skips mmFrame while it's set. (volatile: shared with the ISR.)
volatile int gba_sound_busy;

// Maxmod working memory — STATICALLY allocated (no heap). WHY not mmInitDefault:
// mmInitDefault() calloc()s these buffers, and on this toolchain the heap returned
// a block that OVERLAPPED libtonc's `vid_page` global (both at 0x03001F70). The
// mixer writes audio samples into its wave buffer every frame → corrupts vid_page →
// in BITMAP mode (Mode 4) the next cls/m4_fill reads the corrupt vid_page and blasts
// 0x01010101 across IWRAM, clobbering mm_vblank_function → mmVBlank `bx`es to garbage
// → crash (~frame 60-1000, "cls + music" only). Static, linker-placed buffers can't
// alias vid_page. Sizes are the maxmod GBA ABI (mm_init_default.s): 40/28/24 bytes
// per module/active/mixing channel + MM_MIXLEN for the wave + mix buffers.
#define SND_CHANNELS  16
#define SND_MIXLEN    MM_MIXLEN_31KHZ    // 2112 bytes — 31536 Hz mix (was 16KHz/15768: gritty/aliased on square chiptunes)
#define MM_SIZEOF_MODCH 40
#define MM_SIZEOF_ACTCH 28
#define MM_SIZEOF_MIXCH 24
static mm_byte mm_mod_channels[SND_CHANNELS * MM_SIZEOF_MODCH] __attribute__((aligned(4)));
static mm_byte mm_act_channels[SND_CHANNELS * MM_SIZEOF_ACTCH] __attribute__((aligned(4)));
static mm_byte mm_mix_channels[SND_CHANNELS * MM_SIZEOF_MIXCH] __attribute__((aligned(4)));
static mm_byte mm_mix_memory[SND_MIXLEN] __attribute__((aligned(4)));
static mm_byte mm_wave_memory[SND_MIXLEN] __attribute__((aligned(4)));

void gba_sound_init(void)
{
    // NOTE: mmVBlank is installed in the VBlank IRQ by gba_init() (before this),
    // matching maxmod's required order: hook mmVBlank, THEN mmInit.
    mm_gba_system sys;
    sys.mixing_mode       = MM_MIX_31KHZ;   // highest maxmod rate — cleanest, least aliasing
    sys.mod_channel_count = SND_CHANNELS;
    sys.mix_channel_count = SND_CHANNELS;
    sys.module_channels   = (mm_addr)mm_mod_channels;
    sys.active_channels   = (mm_addr)mm_act_channels;
    sys.mixing_channels   = (mm_addr)mm_mix_channels;
    sys.mixing_memory     = (mm_addr)mm_mix_memory;
    sys.wave_memory       = (mm_addr)mm_wave_memory;
    sys.soundbank         = (mm_addr)soundbank_bin;
    mmInit(&sys);
    sound_ready = 1;
}

// The maxmod mixer step. Called from the VCOUNT IRQ (gba_api.c vcount_isr) at a
// true 60 Hz — NOT from the main loop — so heavy _draw() frames can't starve it.
void gba_sound_frame(void)
{
    if (sound_ready) mmFrame();
}

// music(n, [loop]): start module n from the soundbank. loop defaults on;
// music(-1) stops. (n indexes the soundbank's MOD_* ids.)
void gba_music(int n, int loop)
{
    if (!sound_ready) return;
    gba_sound_busy = 1;   // block the IRQ's mmFrame while we touch maxmod state
    if (n < 0) mmStop();
    else mmStart((mm_word)n, loop ? MM_PLAY_LOOP : MM_PLAY_ONCE);
    gba_sound_busy = 0;
}
void gba_music_stop(void) { if (sound_ready) { gba_sound_busy = 1; mmStop(); gba_sound_busy = 0; } }
void gba_music_volume(int vol) { if (sound_ready) mmSetModuleVolume((mm_word)(vol < 0 ? 0 : vol > 1024 ? 1024 : vol)); }

// sfx(n): play sample effect n (a soundbank SFX_* id) at defaults. maxmod picks
// the channel itself.
void gba_sfx(int n, int ch)
{
    (void)ch;
    if (sound_ready) { gba_sound_busy = 1; mmEffect((mm_word)n); gba_sound_busy = 0; }
}

// sfx_ex(n, vol, pan, pitch): play effect n with per-shot volume (0..255),
// panning (0..255, 128=center), and pitch (16.16, 1.0 = normal — so a game can
// vary hits/pitch-shift a coin ping). vol<0/pan<0 use defaults; pitch<=0 = 1.0.
void gba_sfx_ex(int n, int vol, int pan, long pitch)
{
    if (!sound_ready) return;
    mm_sound_effect fx;
    fx.id      = (mm_word)n;
    // rate is 10.6 fixed (0x400 = 1.0). Our pitch is 16.16 → >>10 gives 6-bit frac.
    fx.rate    = (pitch > 0) ? (mm_hword)(pitch >> 10) : 0x400;
    fx.handle  = 0;
    fx.volume  = (mm_byte)((vol < 0) ? 255 : vol > 255 ? 255 : vol);
    fx.panning = (mm_byte)((pan < 0) ? 128 : pan > 255 ? 255 : pan);
    gba_sound_busy = 1; mmEffectEx(&fx); gba_sound_busy = 0;
}

// sfx_volume(vol): master volume for ALL sample effects (0..1024).
void gba_sfx_volume(int vol)
{
    if (sound_ready) mmSetEffectsVolume((mm_word)(vol < 0 ? 0 : vol > 1024 ? 1024 : vol));
}
