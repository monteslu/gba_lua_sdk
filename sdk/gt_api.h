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
void gt_print_z(void);          /* asm glyph run over gt_a0..a4 (print) */
extern int gt_p0, gt_p1, gt_p2, gt_p3, gt_p4;   /* zp-fastcall USER-fn params */
extern char frameflip;            /* DMA_PAGE_OUT bit state (gt_api.c) */
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
#pragma zpsym ("gt_p0")
#pragma zpsym ("gt_p1")
#pragma zpsym ("gt_p2")
#pragma zpsym ("gt_p3")
#pragma zpsym ("gt_p4")
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

/* zp-ABI entry points: args in gt_a0..gt_a5 (see the block above).
 * The cdecl versions above remain as thin wrappers for call sites whose
 * argument expressions could themselves draw (user-function calls). */
void gt_p8_pset_z(void);       /* a0=x a1=y a2=c */
void gt_p8_rect_z(void);       /* a0=x0 a1=y0 a2=x1 a3=y1 a4=c */
void gt_p8_rectfill_z(void);   /* a0=x0 a1=y0 a2=x1 a3=y1 a4=c (asm fast path) */
void gt_p8_rectfill_slow(void); /* C fallback: offscreen/reversed/128-span */
void gt_p8_circ_z(void);       /* a0=cx a1=cy a2=r a3=c */
void gt_p8_circfill_z(void);   /* a0=cx a1=cy a2=r a3=c */
void gt_p8_line_z(void);       /* a0=x0 a1=y0 a2=x1 a3=y1 a4=c */
void gt_p8_spr_z(void);
void gt_p8_spr_wide(void);  /* 128px-span splitter (asm punts here) */        /* a0=n a1=x a2=y a3=w a4=h */
void gt_p8_sset_z(void);       /* a0=x a1=y a2=c */
void gt_starfield_init(int n);      /* seed n parallax stars (n<=128) */
void gt_starfield_move(int mode);   /* scroll: 0=drift 1=1x 2=2x */
void gt_starfield_draw(void);
void gt_flakes_init(int n);
void gt_flakes_draw(int camdx8, int camdy8);
void gt_flakes_draw2(int first, int count, int camdx8, int camdy8);
void gt_flakes_set(int i, int x, int y, int w, int h, int spd8, int col);
void gt_flakes_mode(int i, int m);
void gt_flakes_draw2_cpu(int first, int count, int cdx8, int cdy8);
void gt_canvas_view(int dx, int dy, int opaque, int height);
void gt_bg_coln(unsigned char *cells, int px, int py, int n);
extern unsigned char db_px, db_py, db_v, db_m, db_c, db_c2, db_bg;
void gt_dbar_z(void);
void gt_chain_step_draw(int x, int y, int col);
void gt_tiles_draw(unsigned char *map, unsigned char *flags, int lvlw,
                   int i0, int i1, int j0, int j1);
/* the ball/particle engines' element type follows the build's fixed width */
#ifdef GT_NUM8
#define GTFIX int
#else
#define GTFIX long
#endif
void gt_balls_step(GTFIX *x, GTFIX *y, GTFIX *vx, GTFIX *vy, int *act,
                   unsigned char *flags, unsigned char *pairs, int n);
void gt_trail_stamp(int *act, GTFIX *x, GTFIX *y, unsigned char *tx,
                    unsigned char *ty, const unsigned char *sprs, int n, int upd);
int gt_cost_decay(int *act, unsigned char *lm, const unsigned char *cost, int n);
void gt_pool_anim(unsigned char *frame, unsigned char *spd, unsigned char *maxf, unsigned char *used, int n);
void gt_pool_edraw(int *x, int *y, unsigned char *ani, unsigned char *type,
                   unsigned char *flash, unsigned char *shake,
                   unsigned char *used, int n,
                   const unsigned char *desc, int nudge);
void gt_pool_move(int *x, int *y, int *sx, int *sy, unsigned char *used,
                  int n, int mode);
void gt_balls_drag(GTFIX *vx, GTFIX *vy, int *act, int n);
void gt_balls_draw(GTFIX *x, GTFIX *y, unsigned char *cells, int n);
void gt_parts_step(GTFIX *x, GTFIX *y, GTFIX *vx, GTFIX *vy, unsigned char *u,
                   int n);
void gt_pool_sprs(int *x, int *y, unsigned char *used, unsigned char *cells,
                  int n, int ox, int oy);
void gt_hit_scan(int *ax, int *ay, unsigned char *aw, unsigned char *ah,
                 unsigned char *au, int an,
                 int *bx, int *by, unsigned char *bw, unsigned char *bu,
                 int bn, int bh, int sh, unsigned char *pairs);
void gt_chunks_draw(int *grid, unsigned char *lut, unsigned char *lut2,
                    unsigned char *props, int stride,
                    int cx0, int cy0, int cx1, int cy1);
void gt_chain_z(void);       /* plot the whole field (one CPU pass) */
/* offscreen-GRAM background canvas (gt_bg.c) */
void gt_bg_compose(int *map, int cols, int cx, int cy, int cw, int ch);
void gt_bg_draw(int sx, int sy);
void gt_bg_clear(void);                      /* clear the 256x256 canvas */
void gt_bg_tile(int t, int px, int py);      /* stamp one sheet tile (8px grid) */
void gt_gspr(int gx, int gy, int w, int h, int x, int y);  /* blit FROM canvas */
unsigned char gt_p8pal(unsigned char idx);   /* p8 index -> hw color (pal-aware) */
extern const unsigned char *gt_sheet_ptr;
void gt_p8_rect(int x0, int y0, int x1, int y1, int c);
void gt_p8_border(int c);
void gt_autocls_set(int c);    /* frame clear during the post-flip vsync wait */
int gt_p8_print(const char *str, int x, int y, int c);
#ifdef GT_NUM8
int gt_p8_print_num(int v, int x, int y, int c);
#else
int gt_p8_print_num(long v, int x, int y, int c);
#endif
int gt_p8_print_int(int v, int x, int y, int c);
int gt_p8_print_buf(unsigned char *buf, int off, int x, int y, int c);
void gt_sheet_load(const unsigned char *packed);
void gt_sheet_load_packed(const unsigned char *p, unsigned int plen); /* packbits */
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
void gt_sfx_bank(const unsigned char *bank);
void gt_music_bank(const unsigned char *bank);
void gt_music(int n, int loop);
void gt_p8_spr(int n, int x, int y, int w, int h, int flip);

#endif
