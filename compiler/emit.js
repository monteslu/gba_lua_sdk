// gtlua C emitter — lowers the checked AST to cc65-flavored C89.
//
// Numeric kinds map to C types: int -> `int` (16-bit), fixed -> `long`
// (32-bit 16.16). Conversions are explicit and single-evaluation:
//   promote int->fixed:  ((long)(x) << 16)
//   floor  fixed->int:   (int)((x) >> 16)     (arithmetic shift = flr)
// Fixed multiply/divide/mod go through the gt_f* runtime; power-of-two
// divisors fold to shifts/masks at compile time (exact for 16.16).

import { BUILTINS, GT_MEMBERS, CALLBACKS } from "./builtins.js";
import { nearestColorByte } from "./gt_palette.js";

// constant-fold a numeric node (literals + neg/binops over literals). Used for
// gt.rgb(r,g,b), whose args the checker already proved constant.
function constFold(e) {
  if (!e) return null;
  if (e.kind === "number") return e.value;
  if (e.kind === "neg") { const v = constFold(e.expr); return v === null ? null : -v; }
  if (e.kind === "binop") {
    const l = constFold(e.left), r = constFold(e.right);
    if (l === null || r === null) return null;
    switch (e.op) {
      case "+": return l + r; case "-": return l - r; case "*": return l * r;
      case "/": return r === 0 ? null : l / r;
      case "\\": return r === 0 ? null : Math.floor(l / r);
      case "%": return r === 0 ? null : l - Math.floor(l / r) * r;
      default: return null;
    }
  }
  return null;
}

// AST annotation keys that point OUT of the tree (symbols, fn infos, pool
// records). The call-graph walker must not follow them (they contain cycles).
const WALK_SKIP = new Set([
  "sym", "poolField", "poolSym", "arraySym", "binding", "bindingSym",
  "slot", "slots", "targetSyms", "sig", "userFn", "forall", "poolBinding",
  "param", "localSlots",
]);

function collectCallees(root, functions) {
  const callees = new Set();
  const seen = new Set();
  const walk = (node) => {
    if (!node || typeof node !== "object" || seen.has(node)) return;
    seen.add(node);
    if (Array.isArray(node)) { for (const n of node) walk(n); return; }
    if (node.kind === "call" && node.callee?.kind === "name" && functions.has(node.callee.name)) {
      callees.add(node.callee.name);
    }
    for (const [k, v] of Object.entries(node)) {
      if (!WALK_SKIP.has(k)) walk(v);
    }
  };
  walk(root);
  return callees;
}

const BANK_SEGMENTS = {
  b0: ["B0CODE", "B0RODATA"],
  b1: ["B1CODE", "B1RODATA"],
  b2: ["B2CODE", "B2RODATA"],
};
const BANK_NUMBER = { b0: 0, b1: 1, b2: 2 };

// Draw builtins with a zero-page fastcall entry point (sdk/gt_blitq.s owns
// the gt_a* slots; gt_api.h declares the _z functions).
const ZP_BUILTINS = {
  pset: "gt_p8_pset_z", rectfill: "gt_p8_rectfill_z", rect: "gt_p8_rect_z",
  circfill: "gt_p8_circfill_z", circ: "gt_p8_circ_z", line: "gt_p8_line_z",
  spr: "gt_p8_spr_z", sset: "gt_p8_sset_z",
};

// P8 button index -> pad-word mask (mirror of btn_mask[] in gt_api.c)
const BTN_MASKS = [512, 256, 2056, 1028, 16, 4096, 8192, 32];

// Does this expression contain a user-function call? One could draw, which
// would clobber the gt_a* slots mid-store-sequence — such call sites fall
// back to the cdecl wrappers. (Annotation keys skipped: they cycle.)
function hasUserCall(node) {
  if (!node || typeof node !== "object") return false;
  if (Array.isArray(node)) return node.some(hasUserCall);
  if (node.kind === "call" && node.userFn) return true;
  for (const [k, v] of Object.entries(node)) {
    if (WALK_SKIP.has(k)) continue;
    if (hasUserCall(v)) return true;
  }
  return false;
}

// Can this expression subtree touch the shared zp slots fa/fb at runtime?
// The zp-fastcall multiply/divide stages operands into fa/fb and then calls
// the argless entry, so an operand that ITSELF reaches the fixed runtime would
// clobber fa/fb between the stage and the call and corrupt the result. This is
// deliberately conservative: not just literal fixed `*`/`/`, but `%`/`\`
// (which lower to gt_ffmod/gt_fdiv), AND any fixed-typed call (sqrt/atan2/rnd
// transitively call gt_fmul/gt_fdiv; the cdecl wrappers write fa/fb too). Such
// sites fall back to the cdecl gt_fmul/gt_fdiv, which is always correct — the
// fallback is rare, so the conservatism is nearly free. (If a genuinely pure
// fixed builtin is ever added, it can be whitelisted here.)
function touchesFixedRuntime(node) {
  if (!node || typeof node !== "object") return false;
  if (Array.isArray(node)) return node.some(touchesFixedRuntime);
  if (node.kind === "binop") {
    if (node.op === "*" && node.tk === "fixed"
        && node.left.tk !== "int" && node.right.tk !== "int") return true;
    if ((node.op === "/" || node.op === "\\" || node.op === "%") && !node.divConst) {
      // fixed operands -> gt_fdiv/gt_ffmod; int `\`/`%` stay native (no fa/fb)
      if (node.op === "/" || node.tk === "fixed" || node.operandKind === "fixed") return true;
    }
  }
  // any call producing a fixed value may reach gt_fmul/gt_fdiv internally
  if (node.kind === "call" && node.tk === "fixed") return true;
  for (const [k, v] of Object.entries(node)) {
    if (WALK_SKIP.has(k)) continue;
    if (touchesFixedRuntime(v)) return true;
  }
  return false;
}

export function emit(chunk, symbols, file, opts = {}) {
  const banked = opts.banked === true;
  const placement = opts.placement ?? {};
  const bankOf = (name) => (banked ? (placement[name] ?? "fixed") : "fixed");
  const out = [];
  let indent = 1;
  let tempCounter = 0;
  let currentFnName = null; // for cross-bank call rewriting
  const stubbed = new Set(); // callee names reached through a far-call stub
  const line = (s) => out.push("    ".repeat(s === "" ? 0 : indent) + s);
  const mangle = (name) => `gtl_${name}`;
  const { globals, functions } = symbols;

  // user-function call graph (also returned for the CLI's bank solver)
  const callGraph = new Map();
  for (const [name, fn] of functions) {
    callGraph.set(name, collectCallees(fn.node.body, functions));
  }

  const ctype = (kind) => (kind === "fixed" ? "long" : "int");

  // ---- conversions -----------------------------------------------------------

  function cv(text, from, to) {
    if (from === to || to === "any") return text;
    if (from === "int" && to === "fixed") return `((long)${text} << 16)`;
    if (from === "fixed" && to === "int") return `(int)(${text} >> 16)`;
    return text;
  }

  function fixedLit(node) {
    const bits = node.fixed | 0;
    const frac = !Number.isInteger(node.value);
    return frac ? `${bits}L /* ${node.value} */` : `${bits}L`;
  }

  // emit expression at the requested kind ("int" | "fixed" | "bool" | "any")
  function expr(e, want = "any") {
    switch (e.kind) {
      case "number": {
        if (want === "fixed" || (want === "any" && e.tk === "fixed")) return fixedLit(e);
        if (e.tk === "fixed") return cv(`(${fixedLit(e)})`, "fixed", "int");
        return String(Math.trunc(e.value));
      }
      case "bool": return e.value ? "1" : "0";
      case "name": return cv(mangle(e.name), e.tk, want);
      case "index": {
        const arr = e.arraySym;
        if (!arr) return "0";
        return cv(`${mangle(e.object.name)}[${expr(e.index, "int")} - 1]`, arr.elemKind, want);
      }
      case "len": {
        if (e.poolSym) return cv(`${mangle(e.expr.name)}_n`, "int", want);
        return String(e.arraySym?.size ?? 0);
      }
      case "member": {
        if (e.poolField) {
          const pf = e.poolField;
          const fl = pf.pool.fields.get(pf.field);
          return cv(`${pf.pool.cname}_${pf.field}[${pf.forall.slotVar}]`, fl.kind, want);
        }
        return "0";
      }
      case "neg": {
        const k = e.tk;
        return cv(`(-${expr(e.expr, k)})`, k, want);
      }
      case "bnot": return cv(`(~${expr(e.expr, "fixed")})`, "fixed", want);
      case "not": return `(!${expr(e.expr, "bool")})`;
      case "call": return cv(call(e), e.tk === "void" ? "int" : e.tk, want);
      case "binop": return binop(e, want);
      // (pool member handled above)
      default: return "0";
    }
  }

  function binop(e, want) {
    const { op } = e;
    const k = e.tk; // result kind from the checker

    if (op === "and") return `(${expr(e.left, "bool")} && ${expr(e.right, "bool")})`;
    if (op === "or") return `(${expr(e.left, "bool")} || ${expr(e.right, "bool")})`;
    if (["<", ">", "<=", ">=", "==", "~="].includes(op)) {
      const ck = e.cmpKind ?? "int";
      const c = op === "~=" ? "!=" : op;
      return `(${expr(e.left, ck)} ${c} ${expr(e.right, ck)})`;
    }

    const lg = Math.log2(e.divConst ?? 1);
    switch (op) {
      case "+": case "-":
        return cv(`(${expr(e.left, k)} ${op} ${expr(e.right, k)})`, k, want);
      case "*": {
        if (k === "int") return cv(`(${expr(e.left, "int")} * ${expr(e.right, "int")})`, "int", want);
        // fixed result: (v<<16)*i == (v*i)<<16, so fixed*int needs only ONE
        // long multiply (or a shift for power-of-two ints) — far cheaper
        // than the 4-partial-product gt_fmul.
        const intSide = e.left.tk === "int" ? e.left : (e.right.tk === "int" ? e.right : null);
        const fixSide = intSide === e.left ? e.right : e.left;
        if (intSide) {
          if (intSide.kind === "number" && intSide.isInt) {
            const v = Math.trunc(intSide.value);
            if (v > 0 && (v & (v - 1)) === 0) {
              return cv(`(${expr(fixSide, "fixed")} << ${Math.log2(v)})`, "fixed", want);
            }
          }
          return cv(`(${expr(fixSide, "fixed")} * ${expr(intSide, "int")})`, "fixed", want);
        }
        return cv(fixedCall("gt_fmul", e.left, e.right), "fixed", want);
      }
      case "/": {
        if (e.divConst) {
          if (e.left.tk === "int" && 16 - lg >= 0) {
            return cv(`((long)${expr(e.left, "int")} << ${16 - lg})`, "fixed", want);
          }
          return cv(`(${expr(e.left, "fixed")} >> ${lg})`, "fixed", want);
        }
        return cv(fixedCall("gt_fdiv", e.left, e.right), "fixed", want);
      }
      case "\\": {
        const ok = e.operandKind ?? "int";
        if (e.divConst) {
          if (ok === "int") return cv(`(${expr(e.left, "int")} >> ${lg})`, "int", want);
          return cv(`(int)(${expr(e.left, "fixed")} >> ${16 + lg})`, "int", want);
        }
        if (ok === "int") return cv(`gt_ifdiv(${expr(e.left, "int")}, ${expr(e.right, "int")})`, "int", want);
        return cv(`(int)(${fixedCall("gt_fdiv", e.left, e.right)} >> 16)`, "int", want);
      }
      case "%": {
        if (e.divConst) {
          if (k === "int") return cv(`(${expr(e.left, "int")} & ${e.divConst - 1})`, "int", want);
          return cv(`(${expr(e.left, "fixed")} & ${(e.divConst * 65536) - 1}L)`, "fixed", want);
        }
        if (k === "int") return cv(`gt_ifmod(${expr(e.left, "int")}, ${expr(e.right, "int")})`, "int", want);
        return cv(`gt_ffmod(${expr(e.left, "fixed")}, ${expr(e.right, "fixed")})`, "fixed", want);
      }
      case "&": case "|":
        return cv(`(${expr(e.left, k)} ${op} ${expr(e.right, k)})`, k, want);
      case "^^":
        return cv(`(${expr(e.left, k)} ^ ${expr(e.right, k)})`, k, want);
      case "<<":
        return cv(`(${expr(e.left, k)} << ${expr(e.right, "int")})`, k, want);
      case ">>":
        return cv(`(${expr(e.left, k)} >> ${expr(e.right, "int")})`, k, want);
      case ">>>": {
        if (k === "int") return cv(`(int)((unsigned int)${expr(e.left, "int")} >> ${expr(e.right, "int")})`, "int", want);
        return cv(`(long)((unsigned long)${expr(e.left, "fixed")} >> ${expr(e.right, "int")})`, "fixed", want);
      }
      default:
        return "0";
    }
  }

  // Lower a fixed multiply/divide. Fast path: when neither operand can touch
  // the fixed runtime (which owns the zp slots fa/fb), store both operands into
  // fa/fb and call the argless zp entry — no cc65 stack marshalling. Otherwise
  // an operand's own fixed-runtime call would clobber fa/fb between the stage
  // and the call, so fall back to the cdecl form. `fn` is "gt_fmul"|"gt_fdiv";
  // the zp entry is `<fn>_zp`.
  function fixedCall(fn, left, right) {
    const L = expr(left, "fixed");
    const R = expr(right, "fixed");
    if (!touchesFixedRuntime(left) && !touchesFixedRuntime(right)) {
      return `(fa = ${L}, fb = ${R}, ${fn}_zp())`;
    }
    return `${fn}(${L}, ${R})`;
  }

  // ---- calls -----------------------------------------------------------------

  function argAt(call, i, pkind, dflt) {
    const a = call.args[i];
    if (!a) return dflt;
    switch (pkind) {
      case "coord": return expr(a, a.tk === "fixed" ? "int" : "int");
      case "int": return expr(a, "int");
      case "num": return expr(a, "fixed");
      case "color": return expr(a, "int");
      // pass an array global by pointer: the bare mangled name decays to
      // int*/long* (the checker validated it's an array reference).
      case "array": return a.kind === "name" ? mangle(a.name) : "0";
      // a flip flag: any truthy value -> 1, else 0 (packed by the caller).
      case "flip": return `((${expr(a, "int")}) ? 1 : 0)`;
      default: return expr(a, "any");
    }
  }

  function call(e) {
    const callee = e.callee;

    // gt.* extras
    if (callee.kind === "member" && callee.object.kind === "name" && callee.object.name === "gt") {
      const sig = GT_MEMBERS[callee.field];
      if (sig.special === "rgb") {
        // gt.rgb(r,g,b): resolve to the nearest palette byte at COMPILE time
        // (zero runtime cost) — the checker proved the 3 args constant.
        if (e.args.length === 3) {
          const r = Math.round(constFold(e.args[0]) ?? 0);
          const g = Math.round(constFold(e.args[1]) ?? 0);
          const b = Math.round(constFold(e.args[2]) ?? 0);
          return `0x${(0x100 | nearestColorByte(r, g, b)).toString(16)}`;
        }
        return `(0x100 | (${argAt(e, 0, "int", "0")} & 0xFF))`;
      }
      if (sig.isValue) return sig.c;
      return `${sig.c}(${sig.params.map((p, i) => argAt(e, i, p[0], defaultFor(callee.field, i))).join(", ")})`;
    }

    // user function — cross-bank calls go through a fixed-bank far-call stub
    if (e.userFn) {
      const fn = e.userFn;
      const args = e.args.map((a, i) => expr(a, fn.paramKinds[i] ?? "int"));
      let target = mangle(callee.name);
      if (banked) {
        const kb = bankOf(callee.name);
        if (kb !== "fixed" && kb !== bankOf(currentFnName)) {
          target = `stub_${mangle(callee.name)}`;
          stubbed.add(callee.name);
        }
      }
      return `${target}(${args.join(", ")})`;
    }

    const b = e.sig;
    const name = callee.name;
    if (!b) return "0";

    if (b.special === "print") {
      const x = expr(e.args[1], "int");
      const y = expr(e.args[2], "int");
      const c = e.args[3] ? expr(e.args[3], "int") : "-1";
      if (e.printKind === "str") {
        const esc = String(e.args[0].value).replace(/\\/g, "\\\\").replace(/"/g, '\\"');
        return `gt_p8_print("${esc}", ${x}, ${y}, ${c})`;
      }
      return `gt_p8_print_num(${expr(e.args[0], "fixed")}, ${x}, ${y}, ${c})`;
    }
    if (b.special === "add") return emitAdd(e);
    if (b.special === "del") {
      const pl = e.poolSym;
      const sv = e.args[1].sym?.forall?.slotVar ?? e.bindingSym?.forall?.slotVar;
      // snap the high-water mark back to 0 the moment the pool empties, so a
      // one-shot burst (an explosion's particles) doesn't leave every later
      // frame scanning the whole capacity.
      return `(${pl.cname}_used[${sv}] = 0, (--${pl.cname}_n == 0 ? (${pl.cname}_hi = 0) : 0), (void)0)`;
    }
    if (b.special) return specialCall(e, b, name);

    // plain builtin
    const args = b.params.map((p, i) => argAt(e, i, p[0], defaultFor(name, i)));

    // The zero-page fastcall ABI: draw builtins store their args into the
    // zp slots gt_a0.. (two sta's each) and call the argless _z entry point,
    // instead of paying cc65's C-stack push per argument. Skipped when an
    // argument expression could itself draw (a user-function call would
    // clobber the slots mid-sequence) — those sites use the cdecl wrapper.
    if (ZP_BUILTINS[name] && !e.args.some(hasUserCall)) {
      // spr has 7 params (n,x,y,w,h,flip_x,flip_y) but only 6 zp slots — pack
      // the two flip flags into gt_a5 as a bitmask (bit0 = X, bit1 = Y). The
      // asm reads gt_a5 to set WIDTH/HEIGHT bit7 + flip the GX/GY source edge.
      if (name === "spr") {
        const stores = [0, 1, 2, 3, 4].map((i) => `gt_a${i} = ${args[i]}`);
        stores.push(`gt_a5 = ${args[5]} | (${args[6]} << 1)`);
        return `(${stores.join(", ")}, ${ZP_BUILTINS[name]}())`;
      }
      const stores = args.map((a, i) => `gt_a${i} = ${a}`);
      return `(${stores.join(", ")}, ${ZP_BUILTINS[name]}())`;
    }
    if (name === "camera" && !e.args.some(hasUserCall)) {
      return `(gt_cam_x = ${args[0]}, gt_cam_y = ${args[1]})`;
    }
    // btn/btnp with constant button + player 0/1: an inline bit test on the
    // zp pad word — no call at all (233 measured cycles down to a handful).
    if ((name === "btn" || name === "btnp") && e.args[0]?.kind === "number") {
      const idx = e.args[0].value | 0;
      const plArg = e.args[1];
      const plConst = !plArg ? 0 : (plArg.kind === "number" ? plArg.value | 0 : -1);
      if (idx >= 0 && idx <= 7 && (plConst === 0 || plConst === 1)) {
        const word = (name === "btn" ? "gt_pad" : "gt_rpt") + plConst;
        return `((${word} & ${BTN_MASKS[idx]}u) != 0)`;
      }
    }
    // spr's cdecl fallback (used when an arg contains a user call): pack the
    // two flip flags into one int so the 7-param builtin reaches the 6-param C.
    if (name === "spr") {
      return `${b.c}(${args[0]}, ${args[1]}, ${args[2]}, ${args[3]}, ${args[4]}, ${args[5]} | (${args[6]} << 1))`;
    }
    return `${b.c}(${args.join(", ")})`;
  }

  function defaultFor(name, i) {
    if (name === "cls") return "0";
    if (name === "camera") return "0";
    if (name === "bg_draw") return "0";      // bg_draw() -> source offset 0,0
    if (name === "rnd") return "65536L";     // rnd() == rnd(1.0)
    if (name === "btn" || name === "btnp") return "0"; // player 0
    if (name === "pal") return "-1";          // pal() == reset
    if (name === "note") return "127";        // default volume
    if (name === "sfx") return "-1";          // sfx(n) -> auto channel
    if (name === "music") return "1";         // music(n) -> loop by default
    if (name === "spr") return i >= 5 ? "0" : "1";  // w,h default 1 cell; flips default off
    return "-1";                              // optional color -> current
  }

  function specialCall(e, b, name) {
    const a0 = e.args[0];
    const kinds = e.argKinds ?? e.args.map((a) => a.tk);
    const anyFixed = kinds.some((k) => k === "fixed");
    switch (b.special) {
      case "flr":
        return a0.tk === "int" ? expr(a0, "int") : `(int)(${expr(a0, "fixed")} >> 16)`;
      case "ceil":
        return a0.tk === "int" ? expr(a0, "int") : `(int)((${expr(a0, "fixed")} + 0xFFFFL) >> 16)`;
      case "abs":
        return anyFixed ? `gt_absf(${expr(a0, "fixed")})` : `gt_absi(${expr(a0, "int")})`;
      case "sgn":
        return a0.tk === "int" ? `gt_sgni(${expr(a0, "int")})` : `gt_sgnf(${expr(a0, "fixed")})`;
      case "min": case "max": {
        const fn = `gt_${b.special}${anyFixed ? "f" : "i"}`;
        const second = e.args[1] ? expr(e.args[1], anyFixed ? "fixed" : "int") : (anyFixed ? "0L" : "0");
        return `${fn}(${expr(a0, anyFixed ? "fixed" : "int")}, ${second})`;
      }
      case "mid": {
        const fn = `gt_mid${anyFixed ? "f" : "i"}`;
        const k = anyFixed ? "fixed" : "int";
        return `${fn}(${expr(e.args[0], k)}, ${expr(e.args[1], k)}, ${expr(e.args[2], k)})`;
      }
      default: return "0";
    }
  }

  // ---- statements -------------------------------------------------------------

  function block(b) {
    let opened = 0;
    for (const s of b.stmts) {
      if (s.kind === "local") {
        // C89: declarations open a block; extent matches the Lua scope
        const decls = s.names.map((n, i) => {
          const kind = s.slots?.[i]?.kind ?? "int";
          const init = s.inits[i] ? expr(s.inits[i], kind) : (kind === "fixed" ? "0L" : "0");
          return `${ctype(kind)} ${mangle(n)} = ${init};`;
        });
        line(`{ ${decls.join(" ")}`);
        indent++;
        opened++;
        continue;
      }
      stmt(s);
    }
    while (opened-- > 0) { indent--; line("}"); }
  }

  function stmt(s) {
    switch (s.kind) {
      case "assign": {
        const isElem = s.target.kind === "index";
        const isField = s.target.kind === "member" && s.target.poolField;
        const t = isField
          ? `${s.target.poolField.pool.cname}_${s.target.poolField.field}[${s.target.poolField.forall.slotVar}]`
          : isElem
            ? `${mangle(s.target.object.name)}[${expr(s.target.index, "int")} - 1]`
            : mangle(s.target.name);
        const tk = s.targetKind ?? "int";
        if (s.op === "=") {
          line(`${t} = ${expr(s.value, tk)};`);
          break;
        }
        // compound: rebuild as t = t OP value with kind-correct lowering.
        // For array elements the index expression is evaluated twice —
        // same as PICO-8's own compound-assignment expansion.
        const left = (isElem || isField) ? { ...s.target, tk } : { kind: "name", name: s.target.name, tk };
        const fake = {
          kind: "binop",
          op: s.op.slice(0, s.op.length - 1),
          left,
          right: s.value,
          tk: s.op === "/=" ? "fixed" : (s.op === "\\=" ? "int" : tk),
          divConst: s.divConst,
          operandKind: tk,
          cmpKind: tk,
        };
        line(`${t} = ${expr(fake, tk)};`);
        break;
      }
      case "multiassign": {
        // evaluate all RHS first (Lua semantics), then store
        const temps = s.values.map((v, i) => {
          const k = s.targetKinds[i] ?? "int";
          const tn = `L_t${tempCounter++}`;
          return { tn, k, v };
        });
        line(`{ ${temps.map(({ tn, k, v }) => `${ctype(k)} ${tn} = ${expr(v, k)};`).join(" ")}`);
        indent++;
        s.targets.forEach((t2, i) => {
          if (t2.kind === "name") line(`${mangle(t2.name)} = ${temps[i].tn};`);
        });
        indent--;
        line("}");
        break;
      }
      case "callstmt": {
        const txt = call(s.call);
        line(txt.startsWith("{") ? txt : `${txt};`);
        break;
      }
      case "if": {
        s.clauses.forEach((cl, i) => {
          line(`${i === 0 ? "if" : "} else if"} (${expr(cl.cond, "bool")}) {`);
          indent++; block(cl.body); indent--;
        });
        if (s.elseBody) {
          line("} else {");
          indent++; block(s.elseBody); indent--;
        }
        line("}");
        break;
      }
      case "while": {
        line(`while (${expr(s.cond, "bool")}) {`);
        indent++; block(s.body); indent--;
        line("}");
        break;
      }
      case "repeat": {
        line("do {");
        indent++; block(s.body); indent--;
        line(`} while (!(${expr(s.cond, "bool")}));`);
        break;
      }
      case "fornum": {
        const kind = s.slot?.kind ?? "int";
        const v = mangle(s.name);
        const lim = `L_lim${tempCounter++}`;
        const step = s.stepConst ?? 1;
        const cmp = step > 0 ? "<=" : ">=";
        let inc;
        if (kind === "int") {
          inc = step === 1 ? `++${v}` : step === -1 ? `--${v}` : `${v} += ${Math.trunc(step)}`;
        } else {
          inc = `${v} += ${(Math.round(step * 65536) | 0)}L`;
        }
        line(`{ ${ctype(kind)} ${v} = ${expr(s.from, kind)}; ${ctype(kind)} ${lim} = ${expr(s.to, kind)};`);
        indent++;
        line(`for (; ${v} ${cmp} ${lim}; ${inc}) {`);
        indent++; block(s.body); indent--;
        line("}");
        indent--;
        line("}");
        break;
      }
      case "return": {
        if (!s.value) { line("return;"); break; }
        const fn = currentFn;
        line(`return ${expr(s.value, fn?.retKind ?? "int")};`);
        break;
      }
      case "break": line("break;"); break;
      case "forall": {
        const sv = `L_p${tempCounter++}`;
        s.slotVar = sv;
        if (s.binding) s.binding.forallSlot = sv;
        // annotate: member nodes reference s (the forall) for slotVar
        // (unsigned char index: pools cap at 64, and cc65 emits far tighter
        // indexing code for 8-bit induction variables)
        const pl = s.poolSym;
        line(`{ unsigned char ${sv};`);
        indent++;
        line(`for (${sv} = 0; ${sv} < ${pl.cname}_hi; ++${sv}) {`);
        indent++;
        line(`if (!${pl.cname}_used[${sv}]) continue;`);
        block(s.body);
        indent--;
        line("}");
        indent--;
        line("}");
        break;
      }
      case "do": {
        line("{");
        indent++; block(s.body); indent--;
        line("}");
        break;
      }
      default: break;
    }
  }

  function emitAdd(e) {
    const pl = e.poolSym;
    const sv = `L_s${tempCounter++}`;
    const t = e.args[1];
    const sets = t.fields.map((f) => {
      const fl = pl.fields.get(f.name);
      return `${pl.cname}_${f.name}[${sv}] = ${expr(f.expr, fl.kind)};`;
    }).join(" ");
    // statement-expression shape via a helper block emitted inline by callstmt.
    // The free slot is the first hole in [0.._hi); if that scan reaches _hi the
    // slot at _hi is free (still within capacity) and _hi grows by one.
    return `{ unsigned char ${sv}; for (${sv} = 0; ${sv} < ${pl.cname}_hi; ++${sv}) if (!${pl.cname}_used[${sv}]) break; ` +
           `if (${sv} < ${pl.size}) { ${pl.cname}_used[${sv}] = 1; ++${pl.cname}_n; ` +
           `if (${sv} >= ${pl.cname}_hi) ${pl.cname}_hi = ${sv} + 1; ${sets} } }`;
  }

  // ---- module layout -----------------------------------------------------------

  let currentFn = null;

  out.push(`/* generated by gtlua from ${file} — edit the .lua, not this file */`);
  out.push(`#include "gt_api.h"`);
  out.push("");

  // banked builds: functions get external linkage (the far-call stubs in
  // stubs.s must reach them) and cross-bank callees get a stub prototype.
  const linkage = banked ? "" : "static ";
  const signatureOf = (name, fn) => {
    const params = fn.params.length
      ? fn.params.map((p, i) => `${ctype(fn.paramKinds[i])} ${mangle(p)}`).join(", ")
      : "void";
    const ret = fn.hasReturnValue ? ctype(fn.retKind) : "void";
    return { params, ret };
  };

  // prototypes
  for (const [name, fn] of functions) {
    const { params, ret } = signatureOf(name, fn);
    out.push(`${linkage}${ret} ${mangle(name)}(${params});`);
  }
  if (banked) {
    // a stub prototype for every callee some other bank might reach
    // (superset is fine: unreferenced externs cost nothing)
    const candidates = new Set();
    for (const [caller, callees] of callGraph) {
      for (const cn of callees) {
        const kb = bankOf(cn);
        if (kb !== "fixed" && kb !== bankOf(caller)) candidates.add(cn);
      }
    }
    for (const cn of candidates) {
      const { params, ret } = signatureOf(cn, functions.get(cn));
      out.push(`${ret} stub_${mangle(cn)}(${params});`);
    }
  }
  out.push("");

  // module variables — non-static so they land in the symbol table for
  // RAM-level assertions in tests and debuggers
  for (const [name, g] of globals) {
    if (g.kind === "pool") {
      g.cname = mangle(name);
      for (const [fname, fl] of g.fields) {
        out.push(`${ctype(fl.kind)} ${g.cname}_${fname}[${g.size}];`);
      }
      out.push(`unsigned char ${g.cname}_used[${g.size}];`);
      out.push(`int ${g.cname}_n;`);
      // high-water mark: 1 + the highest ever-occupied slot since the pool
      // last emptied. Loops scan [0.._hi) instead of the full capacity, so a
      // pool that spends most of the frame near-empty (particles between
      // explosions, bullets when not firing) costs a short scan, not a full
      // one. add() grows it; del() snaps it back to 0 when the pool empties
      // (all used indices stay < _hi, so no live slot is ever skipped).
      out.push(`unsigned char ${g.cname}_hi;`);
      continue;
    }
    if (g.kind === "array") {
      const ct = g.elemKind === "fixed" ? "long" : "int";
      if (g.initVal === 0) {
        out.push(`${ct} ${mangle(name)}[${g.size}];`);
      } else {
        const v = g.elemKind === "fixed"
          ? `${Math.round(g.initVal * 65536) | 0}L`
          : String(Math.trunc(g.initVal));
        out.push(`${ct} ${mangle(name)}[${g.size}] = { ${Array(g.size).fill(v).join(", ")} };`);
      }
    } else if (g.kind === "fixed") {
      const bits = (Math.round(g.value * 65536) | 0);
      out.push(`long ${mangle(name)} = ${bits}L; /* ${g.value} */`);
    } else {
      out.push(`int ${mangle(name)} = ${Math.trunc(g.value)};`);
    }
  }
  if (globals.size) out.push("");

  // function bodies, grouped by bank (fixed first, then each banked group
  // inside #pragma code-name/rodata-name so code AND string literals land
  // in that bank's segments)
  const emitFunction = (s) => {
    const fn = functions.get(s.name);
    currentFn = fn;
    currentFnName = s.name;
    const { params, ret } = signatureOf(s.name, fn);
    out.push(`${linkage}${ret} ${mangle(s.name)}(${params})`);
    out.push("{");
    indent = 1;
    block(s.body);
    out.push("}");
    out.push("");
    currentFn = null;
    currentFnName = null;
  };

  const fnStmts = chunk.stmts.filter((s) => s.kind === "function");
  for (const s of fnStmts) {
    if (bankOf(s.name) === "fixed") emitFunction(s);
  }
  if (banked) {
    for (const bank of ["b0", "b1", "b2"]) {
      const group = fnStmts.filter((s) => bankOf(s.name) === bank);
      if (!group.length) continue;
      const [codeSeg, rodataSeg] = BANK_SEGMENTS[bank];
      out.push(`#pragma code-name (push, "${codeSeg}")`);
      out.push(`#pragma rodata-name (push, "${rodataSeg}")`);
      out.push("");
      for (const s of group) emitFunction(s);
      out.push(`#pragma code-name (pop)`);
      out.push(`#pragma rodata-name (pop)`);
      out.push("");
    }
  }

  // the PICO-8 frame harness. main() lives in the fixed bank; in banked
  // builds it selects each callback's bank before the call.
  const has = (n) => functions.has(n);
  const thirty = has("_update") && !has("_update60");
  const callCb = (name, ind) => {
    if (banked) {
      const b = bankOf(name);
      if (b !== "fixed") out.push(`${ind}gt_bank(${BANK_NUMBER[b]});`);
    }
    out.push(`${ind}${mangle(name)}();`);
  };
  out.push("void main(void)");
  out.push("{");
  out.push("    gt_init();");
  out.push("    gt_sheet_init();");
  if (symbols.usesAudio) out.push("    gt_audio_init();");
  if (symbols.usesMusic) out.push("    gt_music_init();");
  if (thirty) out.push("    gt_p8_fps30();");
  if (has("_init")) callCb("_init", "    ");
  out.push("    for (;;) {");
  out.push("        gt_update_inputs();");
  if (has("_update60")) callCb("_update60", "        ");
  if (thirty) callCb("_update", "        ");
  if (has("_draw")) callCb("_draw", "        ");
  out.push("        gt_endframe();");
  out.push("    }");
  out.push("}");
  out.push("");

  // far-call stubs (assembled separately, linked into the FIXED bank).
  // A stub forwards the cc65 fastcall registers blindly: A/X carry the last
  // argument (sreg its high word for longs) and the return value comes back
  // the same way — the stub saves A/X around the bank switches and never
  // touches sreg, so it works for every signature.
  let stubs = null;
  if (banked && stubbed.size) {
    const st = [];
    st.push("; generated by gtlua — FLASH2M cross-bank far-call stubs");
    st.push(".PC02");
    st.push(".import gt_bank_raw, gt_cur_bank");
    for (const cn of stubbed) st.push(`.import _${mangle(cn)}`);
    for (const cn of stubbed) st.push(`.export _stub_${mangle(cn)}`);
    st.push("");
    st.push('.segment "BSS"');
    st.push("stub_sav_a: .res 1");
    st.push("stub_sav_x: .res 1");
    st.push("");
    st.push('.segment "CODE"');
    for (const cn of stubbed) {
      const bank = BANK_NUMBER[bankOf(cn)];
      st.push(`_stub_${mangle(cn)}:`);
      st.push("        sta stub_sav_a");
      st.push("        stx stub_sav_x");
      st.push("        lda gt_cur_bank");
      st.push("        pha");
      st.push(`        lda #${bank}`);
      st.push("        jsr gt_bank_raw");
      st.push("        lda stub_sav_a");
      st.push("        ldx stub_sav_x");
      st.push(`        jsr _${mangle(cn)}`);
      st.push("        sta stub_sav_a");
      st.push("        stx stub_sav_x");
      st.push("        pla");
      st.push("        jsr gt_bank_raw");
      st.push("        lda stub_sav_a");
      st.push("        ldx stub_sav_x");
      st.push("        rts");
      st.push("");
    }
    stubs = st.join("\n");
  }

  // Banked builds: cc65 emits the string-literal pool at END-OF-UNIT under
  // whatever rodata-name is active THEN — after every scoped pragma has
  // popped — so print() literals would land in the near-full fixed bank.
  // A tail pragma routes the pool into bank 1 with the draw-path code.
  if (banked) out.push(`#pragma rodata-name ("B1RODATA")`, "");

  return { c: out.join("\n"), callGraph, stubs };
}
