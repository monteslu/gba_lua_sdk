/* gt_api.h — the GameTank runtime surface that gtlua-generated C links
 * against. Register protocol and constants proven by clydeshaffer/gametank_sdk
 * and fetchingcat/gametank_basic_sdk (both MIT); this is a minimal direct-draw
 * runtime (no draw queue).
 *
 * The two hardware timing traps live INSIDE these functions and never reach
 * user code: the draw_busy drain-before-touch protocol, and the register
 * setup dances for box/sprite/CPU-write modes.
 */
#ifndef GT_API_H
#define GT_API_H

/* --- frame/tick state (interrupt.s writes these; see interrupt.s) --- */
extern char gt_frameflag;
extern char gt_draw_busy;
extern unsigned int gt_ticks;

/* --- button masks: 16-bit word = ~((hi << 8) | lo), per the C SDK --- */
#define GT_UP     2056
#define GT_DOWN   1028
#define GT_LEFT   512
#define GT_RIGHT  256
#define GT_A      16
#define GT_B      4096
#define GT_C      8192
#define GT_START  32

extern int gt_p1_buttons, gt_p1_prev, gt_p1_pressed;
extern int gt_p2_buttons, gt_p2_prev, gt_p2_pressed;

/* --- lifecycle --- */
void gt_init(void);            /* power-on graphics init; enables IRQs */
void gt_endframe(void);        /* drain blitter, vsync, flip pages     */

/* --- input (harness calls gt_update_inputs once per frame) --- */
void gt_update_inputs(void);
unsigned char gt_btn(int mask);   /* held this frame (player 1)  */
unsigned char gt_btnp(int mask);  /* newly pressed this frame    */
unsigned char gt_btn2(int mask);
unsigned char gt_btnp2(int mask);

/* --- drawing (direct blitter, draws to the offscreen page) --- */
void gt_cls(unsigned char color);
void gt_box(unsigned char x, unsigned char y,
            unsigned char w, unsigned char h, unsigned char color);

#endif
