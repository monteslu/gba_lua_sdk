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
void gt_p8_rect(int x0, int y0, int x1, int y1, int c);
void gt_p8_rectfill(int x0, int y0, int x1, int y1, int c);
void gt_p8_circ(int cx, int cy, int r, int c);
void gt_p8_circfill(int cx, int cy, int r, int c);
void gt_p8_line(int x0, int y0, int x1, int y1, int c);
void gt_p8_border(int c);
void gt_p8_sset(int x, int y, int c);
void gt_sheet_load(const unsigned char *packed);
void gt_sheet_init(void);   /* generated per-build: loads the sheet or no-op */
void gt_p8_spr(int n, int x, int y, int w, int h);

#endif
