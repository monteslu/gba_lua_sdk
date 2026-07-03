/* gt_api.h — the GameTank runtime surface gtlua-generated C links against.
 * v0.2: the PICO-8-shaped API (see PICO8.md). Colors are PICO-8 indices 0-15
 * routed through a runtime palette table (pal() remaps it); 0x100|byte is a
 * raw GameTank palette color (gt.rgb()); -1 means "current draw color". */
#ifndef GT_API_H
#define GT_API_H

#include "gt_fixed.h"

/* --- frame/tick state (interrupt.s writes these) --- */
extern char gt_frameflag;
extern char gt_draw_busy;
extern unsigned int gt_ticks;

/* --- the zero-page fastcall ABI (gt_blitq.s owns the storage) ---
 * The compiler stores draw-builtin args into gt_a0..gt_a5 and calls the
 * argless *_z entry points: two sta's per arg instead of a cc65 stack
 * push, and the callee reads zp instead of (sp),y. Camera and pad words
 * are zp too so camera()/btn()/btnp() emit as inline zp ops. */
extern int gt_a0, gt_a1, gt_a2, gt_a3, gt_a4, gt_a5;
extern int gt_cam_x, gt_cam_y;
extern unsigned int gt_pad0, gt_pad1, gt_rpt0, gt_rpt1;
extern volatile unsigned char gt_qhead, gt_qtail;
extern unsigned char gt_qbank;
extern unsigned char gt_ent[8];   /* blit-entry staging (zp) */
extern unsigned char gt_q[256];
#pragma zpsym ("gt_a0")
#pragma zpsym ("gt_a1")
#pragma zpsym ("gt_a2")
#pragma zpsym ("gt_a3")
#pragma zpsym ("gt_a4")
#pragma zpsym ("gt_a5")
#pragma zpsym ("gt_cam_x")
#pragma zpsym ("gt_cam_y")
#pragma zpsym ("gt_pad0")
#pragma zpsym ("gt_pad1")
#pragma zpsym ("gt_rpt0")
#pragma zpsym ("gt_rpt1")
#pragma zpsym ("gt_qhead")
#pragma zpsym ("gt_qtail")
#pragma zpsym ("gt_qbank")
#pragma zpsym ("gt_ent")
void __fastcall__ gt_q_kick(void);   /* program next queued blit (SEI held) */
void __fastcall__ gt_q_push(void);   /* commit gt_ent to the ring + pump */
void __fastcall__ gt_q_pump(void);   /* start next blit if idle (any ctx) */

/* --- lifecycle --- */
void gt_init(void);
void gt_endframe(void);
void gt_p8_fps30(void);         /* _update() mode: 30 fps logic+draw */
void gt_time_tick(void);        /* advanced by gt_endframe (gt_math.c) */

/* --- input: PICO-8 button indices ---
 * 0=left 1=right 2=up 3=down 4=O(GT A) 5=X(GT B) 6=GT C 7=START */
void gt_update_inputs(void);
unsigned char gt_p8_btn(int i, int pl);
unsigned char gt_p8_btnp(int i, int pl);

/* --- drawing (PICO-8 semantics; camera offset applies to all) --- */
void gt_p8_cls(int c);
void gt_p8_camera(int x, int y);
void gt_p8_color(int c);
void gt_p8_pal(int c0, int c1);              /* (-1,-1) = reset */
void gt_p8_pset(int x, int y, int c);

/* zp-ABI entry points: args in gt_a0..gt_a5 (see the block above).
 * The cdecl versions above remain as thin wrappers for call sites whose
 * argument expressions could themselves draw (user-function calls). */
void gt_p8_pset_z(void);       /* a0=x a1=y a2=c */
void gt_p8_rect_z(void);       /* a0=x0 a1=y0 a2=x1 a3=y1 a4=c */
void gt_p8_rectfill_z(void);   /* a0=x0 a1=y0 a2=x1 a3=y1 a4=c */
void gt_p8_circ_z(void);       /* a0=cx a1=cy a2=r a3=c */
void gt_p8_circfill_z(void);   /* a0=cx a1=cy a2=r a3=c */
void gt_p8_line_z(void);       /* a0=x0 a1=y0 a2=x1 a3=y1 a4=c */
void gt_p8_spr_z(void);        /* a0=n a1=x a2=y a3=w a4=h */
void gt_p8_sset_z(void);       /* a0=x a1=y a2=c */
void gt_starfield_init(int n);      /* seed n parallax stars (n<=128) */
void gt_starfield_move(int mode);   /* scroll: 0=drift 1=1x 2=2x */
void gt_starfield_draw(void);       /* plot the whole field (one CPU pass) */
/* offscreen-GRAM background canvas (gt_bg.c) */
void gt_bg_compose(int *map, int cols, int cx, int cy, int cw, int ch);
void gt_bg_draw(int sx, int sy);
void gt_bg_clear(void);                      /* clear the 256x256 canvas */
void gt_bg_tile(int t, int px, int py);      /* stamp one sheet tile (8px grid) */
void gt_gspr(int gx, int gy, int w, int h, int x, int y);  /* blit FROM canvas */
unsigned char gt_p8pal(unsigned char idx);   /* p8 index -> hw color (pal-aware) */
extern const unsigned char *gt_sheet_ptr;
void gt_p8_rect(int x0, int y0, int x1, int y1, int c);
void gt_p8_rectfill(int x0, int y0, int x1, int y1, int c);
void gt_p8_circ(int cx, int cy, int r, int c);
void gt_p8_circfill(int cx, int cy, int r, int c);
void gt_p8_line(int x0, int y0, int x1, int y1, int c);
void gt_p8_border(int c);
void gt_p8_sset(int x, int y, int c);
int gt_p8_print(const char *str, int x, int y, int c);
int gt_p8_print_num(long v, int x, int y, int c);
void gt_sheet_load(const unsigned char *packed);
void gt_sheet_init(void);   /* generated per-build: loads the sheet or no-op */
void __fastcall__ gt_bank(unsigned char b);  /* FLASH2M: switch the $8000 window */

/* audio coprocessor (gt_audio.c) */
void gt_audio_init(void);
void gt_note(int ch, int note, int vol);
void gt_noteoff(int ch);

/* sfx()/music() tracker (gt_music.c) — only compiled/linked when the game
 * uses them. gt_api.c always ships and calls the per-frame sequencer through
 * a hook pointer (null until gt_music_init() installs gt_music_tick), so
 * gt_endframe() never references an unlinked symbol in audio-free games. */
extern void (*gt_frame_hook)(void);
void gt_music_init(void);
void gt_music_tick(void);
void gt_sfx(int n, int ch);
void gt_music(int n, int loop);
void gt_p8_spr(int n, int x, int y, int w, int h, int flip);

#endif
