// frames.js - .gsi frame-table primitives, split out of gfx.mjs so the build
// pipeline can use them WITHOUT pulling in gfx.mjs's node:zlib PNG codec (which
// isn't browser-safe). These are pure: byte arrays in, byte arrays out. gfx.mjs
// re-exports them for the CLI's `gtlua gfx` tooling.
//
// A .gsi is the official GameTank sprite-metadata format (sprite_metadata.js):
// a packed array of 8-byte Frame records
//   { vxo:int8, vyo:int8, w:uint8, h:uint8, gx:uint8, gy:uint8, 0, 0 }
// where gx/gy are the frame's pixel coordinates WITHIN THE SHEET, w/h its pixel
// size, and vxo/vyo the draw offset from the sprite's anchor. gtlua reads the
// first 6 bytes per frame; bytes 6-7 are ignored (kept for byte-for-byte
// compatibility with the official converter's output).
export const FRAME_BYTES = 8;

// Parse a .gsi blob into an array of {vxo,vyo,w,h,gx,gy} frames.
export function parseGsi(buf) {
  if (buf.length % FRAME_BYTES !== 0) {
    throw new Error(`.gsi length ${buf.length} is not a multiple of ${FRAME_BYTES}`);
  }
  const frames = [];
  for (let i = 0; i < buf.length; i += FRAME_BYTES) {
    frames.push({
      vxo: (buf[i] << 24) >> 24,      // int8
      vyo: (buf[i + 1] << 24) >> 24,  // int8
      w: buf[i + 2],
      h: buf[i + 3],
      gx: buf[i + 4],
      gy: buf[i + 5],
    });
  }
  return frames;
}

// Serialize frames back to a .gsi blob (8 bytes/frame, official layout).
// Uint8Array (not Buffer) so it works in the browser too.
export function encodeGsi(frames) {
  const buf = new Uint8Array(frames.length * FRAME_BYTES);
  frames.forEach((f, i) => {
    const o = i * FRAME_BYTES;
    buf[o] = f.vxo & 255;
    buf[o + 1] = f.vyo & 255;
    buf[o + 2] = f.w & 255;
    buf[o + 3] = f.h & 255;
    buf[o + 4] = f.gx & 255;
    buf[o + 5] = f.gy & 255;
    // o+6, o+7 stay 0
  });
  return buf;
}

// Build a Frame table for the runtime, with the QUADRANT bit baked into gx/gy so
// the blit asm needs no quadrant logic. `quadOf(frameIndex)` returns which
// 128x128 quadrant (0=NW 1=NE 2=SW 3=SE) that frame's sheet lives in; the frame's
// gx/gy (0..127 within its quadrant) get bit7 OR'd on (GX bit7 = right column,
// GY bit7 = bottom row) so they become final GRAM source coords. Returns a
// flat Uint8Array of frames.length*6 bytes: {vxo,vyo,w,h,gx',gy'} per frame,
// which is what gt_frames_register / gt_gspr_frame consume.
export function bakeFrameTable(frames, quadOf = () => 0) {
  const out = new Uint8Array(frames.length * 6);
  frames.forEach((f, i) => {
    const q = quadOf(i) & 3;
    const o = i * 6;
    out[o] = f.vxo & 255;
    out[o + 1] = f.vyo & 255;
    out[o + 2] = f.w & 255;
    out[o + 3] = f.h & 255;
    out[o + 4] = (f.gx & 127) | ((q & 1) ? 0x80 : 0);   // GX bit7 = right quad
    out[o + 5] = (f.gy & 127) | ((q & 2) ? 0x80 : 0);   // GY bit7 = bottom quad
  });
  return out;
}
