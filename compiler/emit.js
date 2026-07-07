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

// Split an index expression into (base, constant offset): `x + 3` -> [x, 3],
// `x - 2` -> [x, -2], `5` -> [null, 5], anything else -> [expr, 0]. Lets the
// 1-based array fold collapse the ubiquitous arr[x + 1] to a plain arr[x]
// instead of runtime arithmetic (cc65 folds symbol+const at link time).
function peelIndex(e) {
  if (e.kind === "number" && Number.isInteger(e.value)) return [null, Math.trunc(e.value)];
  if (e.kind === "binop" && (e.op === "+" || e.op === "-") &&
      e.right.kind === "number" && Number.isInteger(e.right.value) &&
      e.right.tk !== "fixed") {
    return [e.left, e.op === "+" ? Math.trunc(e.right.value) : -Math.trunc(e.right.value)];
  }
  if (e.kind === "binop" && e.op === "+" &&
      e.left.kind === "number" && Number.isInteger(e.left.value) &&
      e.left.tk !== "fixed") {
    return [e.right, Math.trunc(e.left.value)];
  }
  return [e, 0];
}

// Decompose a small positive constant into <=3 signed power-of-two terms
// ([shift, sign] pairs) for multiply strength-reduction, or null. 16-bit
// wrap semantics are identical for shift-adds, so the rewrite is exact.
function shiftTerms(c) {
  if (c < 2 || c > 255) return null;
  const bits = [];
  for (let k = 7; k >= 0; k--) if (c & (1 << k)) bits.push([k, 1]);
  if (bits.length <= 3) return bits;
  // difference form: c = 2^a - r where r has <=2 bits (e.g. 15 = 16 - 1)
  for (let a = 8; a >= 0; a--) {
    const r = (1 << a) - c;
    if (r < 0) continue;
    const rb = [];
    for (let k = 7; k >= 0; k--) if (r & (1 << k)) rb.push([k, -1]);
    if (rb.length <= 2) return [[a, 1], ...rb];
  }
  return null;
}

// Pure and small enough to duplicate per shift term: names, numbers, and
// call-free operator trees of a few nodes (re-evaluating one costs a few
// cycles; the runtime multiply it replaces costs hundreds).
function purelyDup(e, budget = 4) {
  if (budget <= 0 || !e) return false;
  switch (e.kind) {
    case "number": case "name": return true;
    case "unop": return purelyDup(e.operand ?? e.expr, budget - 1);
    case "binop": return purelyDup(e.left, budget - 1) && purelyDup(e.right, budget - 1);
    default: return false;
  }
}

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

// Every name DECLARED inside a function: params, locals, loop vars, forall
// bindings. Used by the inliner's capture guard.
function declaredNames(fn) {
  const out = new Set(fn.params);
  (function walk(node) {
    if (!node || typeof node !== "object") return;
    if (Array.isArray(node)) { for (const n of node) walk(n); return; }
    if (node.kind === "local") for (const n of node.names) out.add(n);
    if (node.kind === "fornum") out.add(node.name);
    if (node.kind === "forall" && node.binding?.name) out.add(node.binding.name);
    for (const [k, v] of Object.entries(node)) {
      if (!WALK_SKIP.has(k)) walk(v);
    }
  })(fn.node.body);
  return out;
}

// Free names of a function body: references that aren't its own declarations.
// If any of these collides with a name declared in the CALLER, inlining the
// body there would capture the caller's local instead of the global — skip.
function freeNames(fn) {
  const own = declaredNames(fn);
  const out = new Set();
  (function walk(node) {
    if (!node || typeof node !== "object") return;
    if (Array.isArray(node)) { for (const n of node) walk(n); return; }
    if (node.kind === "name" && !own.has(node.name)) out.add(node.name);
    for (const [k, v] of Object.entries(node)) {
      if (!WALK_SKIP.has(k)) walk(v);
    }
  })(fn.node.body);
  return out;
}

// How many times does the named variable appear in this expression tree?
function countUses(node, name) {
  if (!node || typeof node !== "object") return 0;
  if (Array.isArray(node)) return node.reduce((a, n) => a + countUses(n, name), 0);
  let c = node.kind === "name" && node.name === name ? 1 : 0;
  for (const [k, v] of Object.entries(node)) {
    if (!WALK_SKIP.has(k)) c += countUses(v, name);
  }
  return c;
}

// A function body made of `if <cond> then return <e> end` steps and a bare
// trailing `return <e>` converts to nested ternaries at the call site
// (sign0, tile_solid, mget-class helpers). Returns [{cond, value}...,
// {value}] or null. Conditions/values evaluate lazily in the ternary, so the
// caller must only paste args that are safe to evaluate zero-or-more times.
function returnChain(body) {
  const steps = [];
  for (let i = 0; i < body.stmts.length; i++) {
    const st = body.stmts[i];
    if (st.kind === "return" && st.value) {
      if (i !== body.stmts.length - 1) return null;   // dead code after
      steps.push({ value: st.value });
      return steps;
    }
    if (st.kind === "if" && st.clauses.length === 1 && !st.elseBody &&
        st.clauses[0].body.stmts.length === 1 &&
        st.clauses[0].body.stmts[0].kind === "return" &&
        st.clauses[0].body.stmts[0].value) {
      steps.push({ cond: st.clauses[0].cond, value: st.clauses[0].body.stmts[0].value });
      continue;
    }
    return null;
  }
  return null;                                        // no trailing return
}

// Does this statement tree assign to the named variable? (loop-var narrowing
// must not fire if the body mutates the induction variable.)
function assignsTo(node, name) {
  if (!node || typeof node !== "object") return false;
  if (Array.isArray(node)) return node.some((n) => assignsTo(n, name));
  if (node.kind === "assign" && node.target?.kind === "name" &&
      node.target.name === name) return true;
  for (const [k, v] of Object.entries(node)) {
    if (WALK_SKIP.has(k)) continue;
    if (assignsTo(v, name)) return true;
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
  const narrowedVars = new Set(); // u8 fornum counters currently in scope
  let inlineMap = null;           // inlined callee: param name -> rendered arg
  let inlineSeq = 0;              // unique suffix for statement-inline bindings
  const hasReturn = (node, seen = new WeakSet()) => {
    if (!node || typeof node !== "object") return false;
    if (seen.has(node)) return false;             // AST back-references
    seen.add(node);
    if (Array.isArray(node)) return node.some((n) => hasReturn(n, seen));
    if (node.kind === "return") return true;
    if (node.kind === "function") return false;
    return Object.values(node).some((v) => typeof v === "object" && v !== null && hasReturn(v, seen));
  };
  let zpParamMap = null;          // leaf zp-fastcall fns: param -> gt_pN
  const inlineStack = new Set();  // fns currently being inlined (recursion guard)
  const declaredCache = new Map(); // fn name -> Set of names declared inside it
  const freeCache = new Map();     // fn name -> Set of free (outer) names it uses
  const declaredOf = (n) => {
    if (!declaredCache.has(n)) declaredCache.set(n, declaredNames(functions.get(n)));
    return declaredCache.get(n);
  };
  const freeOf = (n) => {
    if (!freeCache.has(n)) freeCache.set(n, freeNames(functions.get(n)));
    return freeCache.get(n);
  };
  // capture guard: safe to paste callee's body text into the current fn?
  const noCapture = (calleeName) => {
    if (!currentFnName || !functions.has(currentFnName)) return false;
    const callerDecls = declaredOf(currentFnName);
    for (const f of freeOf(calleeName)) {
      if (callerDecls.has(f)) return false;
    }
    return true;
  };
  // opts.inliner === false disables function inlining: like the min/max/mid
  // ternaries it trades size for speed, and a cart at the bank-capacity cliff
  // needs the compact call form to link (the build driver retries with it off)
  const inliner = opts.inliner !== false;
  // opts.num8: the fixed kind is 8.8 in a 16-bit int (range +-127.996,
  // steps of 1/256) instead of PICO-8's 16.16 in a long. Every fixed op
  // halves (or better); semantics are approximate, not bit-exact — a
  // per-cart choice, verified per-game. See docs/performance.md.
  const N8 = !!opts.num8;
  const FSH = N8 ? 8 : 16;             // fraction bits
  const FONE = N8 ? 256 : 65536;       // 1.0
  const FL = N8 ? "" : "L";            // literal suffix
  const stubbed = new Set(); // callee names reached through a far-call stub
  const line = (s) => out.push("    ".repeat(s === "" ? 0 : indent) + s);
  const mangle = (name) => `gtl_${name}`;
  const { globals, functions } = symbols;

  // user-function call graph (also returned for the CLI's bank solver)
  const callGraph = new Map();
  for (const [name, fn] of functions) {
    callGraph.set(name, collectCallees(fn.node.body, functions));
  }

  // ---- zp-fastcall for user functions ---------------------------------------
  // Functions with 1-3 all-int params take them in the gt_p0..2 zero-page
  // slots (the ABI that makes the draw builtins cheap) instead of cc65's
  // C-stack convention. LEAF fns (no user calls in the body) read the slots
  // directly — zero copies, zero BSS; non-leaf fns copy the slots into their
  // static locals first thing so nested zp calls can't clobber them. A call
  // site with one call-bearing arg stores it first; a fn ever called with
  // TWO+ call-bearing args stays cdecl (order hazards). Re-landed on top of
  // the inliner: the tiny fns that previously dominated this path now inline
  // away entirely, and the original driftmania anomaly's subject
  // (draw_tiles) no longer exists as a call.
  const zpCall = new Set();
  for (const [name, fn] of functions) {
    // params <= 3 ONLY: extending to 5 was measured a net loss — combo-pool
    // gameplay 4.99 -> 5.50 (a hot 4-5 param physics fn is slower through
    // the slots) vs celeste2's -0.07 win. gt_p3/gt_p4 stay reserved for a
    // future per-shape gate.
    // under --num8 a fixed param IS int-width, so fixed-taking functions
    // (positions, speeds — the hot physics helpers) are zp-eligible too;
    // newleste's profile showed 18% of the frame in incsp2 stack cleanup
    // from exactly these calls
    const zpKindOk = (k) => k === "int" || (N8 && k === "fixed");
    if (fn.params.length >= 1 && fn.params.length <= 5 &&
        fn.params.every((_, i) => zpKindOk(fn.paramKinds[i] ?? "int")) &&
        (!fn.hasReturnValue || fn.retKind === "int" || (N8 && fn.retKind === "fixed"))) {
      zpCall.add(name);
    }
  }
  {
    const disqualify = (node) => {
      if (!node || typeof node !== "object") return;
      if (Array.isArray(node)) { for (const n of node) disqualify(n); return; }
      if (node.kind === "call" && node.userFn && node.callee?.kind === "name" &&
          zpCall.has(node.callee.name)) {
        if (node.args.filter((a) => hasUserCall(a)).length >= 2) {
          zpCall.delete(node.callee.name);
        }
      }
      for (const [k, v] of Object.entries(node)) {
        if (!WALK_SKIP.has(k)) disqualify(v);
      }
    };
    for (const [, fn] of functions) disqualify(fn.node.body);
  }

  // ---- dead-function elimination -------------------------------------------
  // Functions unreachable from the lifecycle callbacks are never emitted:
  // ports carry sliced-out helpers (celeste2's draw_clouds, print2) that
  // otherwise burn fixed-bank CODE/RODATA. gtlua has no function pointers, so
  // the AST call graph is the complete truth.
  const liveFns = new Set();
  {
    const stack = ["_init", "_update", "_update60", "_draw"].filter((n) => functions.has(n));
    while (stack.length) {
      const n = stack.pop();
      if (liveFns.has(n)) continue;
      liveFns.add(n);
      for (const c of callGraph.get(n) ?? []) stack.push(c);
    }
  }

  const ctype = (kind) => (kind === "fixed" ? (N8 ? "int" : "long") : "int");

  // ---- conversions -----------------------------------------------------------

  function cv(text, from, to) {
    if (from === to || to === "any") return text;
    if (from === "int" && to === "fixed") {
      return N8 ? `(${text} << 8)` : `((long)${text} << 16)`;
    }
    if (from === "fixed" && to === "int") {
      return N8 ? `(${text} >> 8)` : `(int)(${text} >> 16)`;
    }
    return text;
  }

  function fixedLit(node) {
    const bits = N8 ? (Math.round(node.value * 256) | 0) : (node.fixed | 0);
    const frac = !Number.isInteger(node.value);
    return frac ? `${bits}${FL} /* ${node.value} */` : `${bits}${FL}`;
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
      case "name":
        if (inlineMap && inlineMap.has(e.name)) return cv(inlineMap.get(e.name), e.tk, want);
        if (zpParamMap && zpParamMap.has(e.name)) return cv(zpParamMap.get(e.name), e.tk, want);
        return cv(mangle(e.name), e.tk, want);
      case "index": {
        const arr = e.arraySym;
        if (!arr) return "0";
        return cv(indexRef(mangle(e.object.name), e.index, true), arr.elemKind, want);
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
      case "call": {
        if (want === "int") {
          const ri = rndIntForm(e);
          if (ri) return ri;    // int-context rnd(n): skip the fixed multiply
        }
        return cv(call(e), e.tk === "void" ? "int" : e.tk, want);
      }
      case "binop": return binop(e, want);
      // (pool member handled above)
      default: return "0";
    }
  }

  // provably 0..255: narrowed u8 loop counters, 0..255 int literals, and
  // array8 element reads. Conservative — anything else compares wide.
  function byteish(e) {
    if (!e) return false;
    if (e.kind === "number" && e.isInt) return e.value >= 0 && e.value <= 255;
    if (e.kind === "name") return narrowedVars.has(e.name);
    if (e.kind === "index") return !!e.arraySym?.elemBytes;
    return false;
  }

  function binop(e, want) {
    const { op } = e;
    const k = e.tk; // result kind from the checker

    if (op === "and") return `(${expr(e.left, "bool")} && ${expr(e.right, "bool")})`;
    if (op === "or") return `(${expr(e.left, "bool")} || ${expr(e.right, "bool")})`;
    if (["<", ">", "<=", ">=", "==", "~="].includes(op)) {
      const ck = e.cmpKind ?? "int";
      const c = op === "~=" ? "!=" : op;
      // BYTE COMPARES: a var<=var int comparison goes through cc65's
      // tosicmp at ~127 cycles (measured; the constant form is ~15). When
      // both sides are provably 0..255 — narrowed loop counters, byte
      // constants, array8 reads — compare as unsigned char: lda/cmp.
      if (ck === "int" && byteish(e.left) && byteish(e.right)) {
        return `((unsigned char)${expr(e.left, "int")} ${c} (unsigned char)${expr(e.right, "int")})`;
      }
      return `(${expr(e.left, ck)} ${c} ${expr(e.right, ck)})`;
    }

    const lg = Math.log2(e.divConst ?? 1);
    switch (op) {
      case "+": case "-":
        return cv(`(${expr(e.left, k)} ${op} ${expr(e.right, k)})`, k, want);
      case "*": {
        if (k === "int") {
          // strength-reduce x * C: cc65 lowers non-power-of-two constant
          // multiplies to the generic runtime (~250+ cycles); a 2-3 term
          // shift-add is ~10x cheaper and bit-exact under 16-bit wrap
          const lc = constFold(e.left), rc = constFold(e.right);
          const c = Number.isInteger(rc) ? rc : (Number.isInteger(lc) ? lc : null);
          const base = Number.isInteger(rc) ? e.left : e.right;
          if (c !== null && purelyDup(base)) {
            const terms = shiftTerms(Math.abs(c));
            if (terms) {
              const b = expr(base, "int");
              const t = terms.map(([sh, sg], i) => {
                const piece = sh === 0 ? `(${b})` : `((${b}) << ${sh})`;
                return i === 0 ? piece : (sg > 0 ? ` + ${piece}` : ` - ${piece}`);
              }).join("");
              const body = `(${t})`;
              return cv(c < 0 ? `(0 - ${body})` : body, "int", want);
            }
          }
          return cv(`(${expr(e.left, "int")} * ${expr(e.right, "int")})`, "int", want);
        }
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
          if (e.left.tk === "int" && FSH - lg >= 0) {
            const sh = FSH - lg;
            const body = N8 ? `(${expr(e.left, "int")} << ${sh})`
                            : `((long)${expr(e.left, "int")} << ${sh})`;
            return cv(body, "fixed", want);
          }
          return cv(`(${expr(e.left, "fixed")} >> ${lg})`, "fixed", want);
        }
        return cv(fixedCall("gt_fdiv", e.left, e.right), "fixed", want);
      }
      case "\\": {
        const ok = e.operandKind ?? "int";
        if (e.divConst) {
          if (ok === "int") return cv(`(${expr(e.left, "int")} >> ${lg})`, "int", want);
          return cv(N8 ? `(${expr(e.left, "fixed")} >> ${8 + lg})`
                       : `(int)(${expr(e.left, "fixed")} >> ${16 + lg})`, "int", want);
        }
        if (ok === "int") return cv(`gt_ifdiv(${expr(e.left, "int")}, ${expr(e.right, "int")})`, "int", want);
        return cv(N8 ? `(${fixedCall("gt_fdiv", e.left, e.right)} >> 8)`
                     : `(int)(${fixedCall("gt_fdiv", e.left, e.right)} >> 16)`, "int", want);
      }
      case "%": {
        if (e.divConst) {
          if (k === "int") return cv(`(${expr(e.left, "int")} & ${e.divConst - 1})`, "int", want);
          return cv(`(${expr(e.left, "fixed")} & ${(e.divConst * FONE) - 1}${FL})`, "fixed", want);
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
        return cv(N8 ? `(int)((unsigned)${expr(e.left, "fixed")} >> ${expr(e.right, "int")})`
                     : `(long)((unsigned long)${expr(e.left, "fixed")} >> ${expr(e.right, "int")})`, "fixed", want);
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
    const zpOk = true;   // both num8 mul AND div have asm zp entries now
    if (zpOk && !touchesFixedRuntime(left) && !touchesFixedRuntime(right)) {
      return `(fa = ${L}, fb = ${R}, ${fn}_zp())`;
    }
    return `${fn}(${L}, ${R})`;
  }

  // 1-based array access with the -1 folded to link time. arr[x + 1] (the
  // ubiquitous 0-based-math pattern) collapses to arr[x]; arr[7] folds
  // numerically; the general arr[i] becomes (arr - 1)[i] — the -1 rides the
  // symbol's address, not a runtime subtract.
  function indexRef(sym, idxNode, byteElems) {
    const [base, c] = peelIndex(idxNode);
    const off = c - 1;
    if (base === null) return `${sym}[${off}]`;
    const b = expr(base, "int");
    if (off === 0) return `${sym}[${b}]`;
    // The pointer-fold form pays ONLY for BYTE-element arrays with a
    // narrowed (u8) counter, where cc65 emits `lda _arr-1,y` direct
    // (measured +30%). For INT/fixed arrays the fold breaks cc65's
    // known-global indexed addressing and every access goes through the
    // computed-pointer path — STORES land in jsr staspidx at ~90 cycles
    // apiece (measured: 2065 cycles per snow flake in newleste, 6x the
    // instruction-count estimate, via 25->10 count scaling). Int arrays
    // keep the explicit subtract: (i-1) stays u8, cc65 does asl/tay/
    // lda _arr,y direct.
    if (byteElems && base.kind === "name" && narrowedVars.has(base.name)) {
      return `(${sym} ${off > 0 ? "+" : "-"} ${Math.abs(off)})[${b}]`;
    }
    return `${sym}[${b} ${off > 0 ? "+" : "-"} ${Math.abs(off)}]`;
  }

  // Safe to evaluate more than once AND cheap: a literal, a plain variable, or
  // a small tree of simple arithmetic over those (no calls, no draws, no
  // fixed-runtime ops). Used to inline min/max/mid as ternaries — the win is
  // only real when re-evaluating the operand costs less than a cdecl call.
  // opts.midInline === false turns the inlining off entirely: it's a
  // speed-for-size trade, and a game at the bank-capacity cliff needs the
  // smaller call form to link. The build driver retries with it off when
  // FLASH2M placement can't converge.
  const midInline = opts.midInline !== false;
  function cheapPure(e, budget = 3) {
    if (!midInline) return false;
    if (budget <= 0 || !e || typeof e !== "object") return false;
    switch (e.kind) {
      case "number": case "bool": return true;
      case "name": return true;                       // globals + locals: plain loads
      case "paren": return cheapPure(e.expr, budget);
      case "neg": case "not": case "bnot":
        return cheapPure(e.expr, budget - 1);
      case "index":                                    // array read: one indexed load
        return cheapPure(e.object, budget - 1) && cheapPure(e.index, budget - 1);
      case "binop":
        // int arithmetic/shifts/masks only; fixed *, /, %, \ can reach the
        // runtime (touchesFixedRuntime) — leave anything like that alone.
        if (touchesFixedRuntime(e)) return false;
        return cheapPure(e.left, budget - 1) && cheapPure(e.right, budget - 1);
      default: return false;
    }
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
      case "array":
      case "array8": return a.kind === "name" ? mangle(a.name) : "0";
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
      // INLINER: a body that is exactly `return <expr>` (no user calls inside)
      // substitutes at the call site — the cc65 calling convention measured
      // ~1,200 cycles per invocation on a 4-line helper. Args paste in only
      // when pure (safe to duplicate) or used at most once; otherwise the
      // call stays. Kind conversion mirrors a real call (body at retKind,
      // outer cv handles the rest).
      {
        const body = inliner ? functions.get(callee.name)?.node?.body : null;
        if (body && !inlineStack.has(callee.name) &&
            e.args.length === fn.params.length && body.stmts.length > 1) {
          const chain = returnChain(body);
          if (chain && fn.params.every((_, i) => cheapPure(e.args[i])) &&
              noCapture(callee.name)) {
            const rendered = new Map(fn.params.map((pname, i) =>
              [pname, `(${expr(e.args[i], fn.paramKinds[i] ?? "int")})`]));
            const saved = inlineMap;
            inlineMap = rendered;
            inlineStack.add(callee.name);
            const rk = fn.retKind ?? "int";
            let out = expr(chain[chain.length - 1].value, rk);
            for (let i = chain.length - 2; i >= 0; i--) {
              out = `(${expr(chain[i].cond, "bool")} ? ${expr(chain[i].value, rk)} : ${out})`;
            }
            inlineStack.delete(callee.name);
            inlineMap = saved;
            return `(${out})`;
          }
        }
        const st = body && body.stmts.length === 1 ? body.stmts[0] : null;
        if (st && st.kind === "return" && st.value &&
            !inlineStack.has(callee.name) &&
            e.args.length === fn.params.length && noCapture(callee.name)) {
          // side-effecting args (user calls) must be pasted EXACTLY once —
          // zero uses would drop the effect, two would double it — and at
          // most ONE such arg may inline (pasting reorders evaluation from
          // call-order to body-order; with a single effectful arg the pure
          // ones can't observe the difference)
          const effectful = e.args.map((a) => hasUserCall(a));
          const ok = effectful.filter(Boolean).length <= 1 &&
            fn.params.every((pname, i) => effectful[i]
              ? countUses(st.value, pname) === 1
              : (cheapPure(e.args[i]) || countUses(st.value, pname) <= 1));
          if (ok) {
            // args render OUTSIDE the callee's substitution scope (they are
            // caller-context expressions); user calls inside the body inline
            // recursively, guarded by inlineStack against cycles
            const rendered = new Map(fn.params.map((pname, i) =>
              [pname, `(${expr(e.args[i], fn.paramKinds[i] ?? "int")})`]));
            const saved = inlineMap;
            inlineMap = rendered;
            inlineStack.add(callee.name);
            const out = expr(st.value, fn.retKind ?? "int");
            inlineStack.delete(callee.name);
            inlineMap = saved;
            return `(${out})`;
          }
        }
      }
      const args = e.args.map((a, i) => expr(a, fn.paramKinds[i] ?? "int"));
      let target = mangle(callee.name);
      if (banked) {
        const kb = bankOf(callee.name);
        if (kb !== "fixed" && kb !== bankOf(currentFnName)) {
          target = `stub_${mangle(callee.name)}`;
          stubbed.add(callee.name);
        }
      }
      if (zpCall.has(callee.name)) {
        const bearing = e.args.map((a) => hasUserCall(a));
        const order = [...args.keys()].sort((x, y) =>
          (bearing[y] ? 1 : 0) - (bearing[x] ? 1 : 0));
        const stores = order.map((i) => `gt_p${i} = ${args[i]}`);
        return `(${stores.join(", ")}, ${target}())`;
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
      // int-typed values skip the fixed widening + long digit path
      if (e.args[0].tk === "int") {
        return `gt_p8_print_int(${expr(e.args[0], "int")}, ${x}, ${y}, ${c})`;
      }
      return `gt_p8_print_num(${expr(e.args[0], "fixed")}, ${x}, ${y}, ${c})`;
    }
    if (b.special === "add") return emitAdd(e);
    if (b.special === "del") {
      const pl = e.poolSym;
      const sv = e.args[1].sym?.forall?.slotVar ?? e.bindingSym?.forall?.slotVar;
      const f0 = `${pl.cname}_${pl.fields.keys().next().value}`;
      // Free slots chain through the FIRST field array (dead storage) with
      // +1-encoded links so a BSS-zeroed head means "empty chain" — add()
      // pops in O(1) instead of scanning for a hole (an explosion's 51
      // adds used to walk the pool per particle). The high-water mark still
      // snaps to 0 when the pool empties (short all() scans), which also
      // resets the chain.
      return `(${pl.cname}_used[${sv}] = 0, ${f0}[${sv}] = ${pl.cname}_free, ${pl.cname}_free = (unsigned char)(${sv} + 1), ` +
             `(--${pl.cname}_n == 0 ? (${pl.cname}_hi = 0, ${pl.cname}_free = 0) : 0), (void)0)`;
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

  // rnd(x) with an integral range, consumed as an integer: emit the cheap
  // int-range form (an explosion spawns ~250 rnd calls in one frame; the
  // 16.16 multiply inside each was a third of the measured kill-frame cost)
  function rndIntForm(e) {
    if (opts.rndInt === false) return null;   // size-relief ladder rung
    if (!e || e.kind !== "call") return null;
    const c = e.callee;
    if (!c || c.kind !== "name" || c.name !== "rnd") return null;
    if (!e.args || e.args.length !== 1) return null;
    const a = e.args[0];
    if (a.tk === "int") return `gt_p8_rnd_int(${expr(a, "int")})`;
    if (a.kind === "number" && Number.isInteger(a.value)) return `gt_p8_rnd_int(${Math.trunc(a.value)})`;
    return null;
  }

  function defaultFor(name, i) {
    if (name === "cls") return "0";
    if (name === "camera") return "0";
    if (name === "bg_draw") return "0";      // bg_draw() -> source offset 0,0
    if (name === "rnd") return `${FONE}${FL}`;   // rnd() == rnd(1.0)
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
      case "flr": {
        const ri = rndIntForm(a0);
        if (ri) return ri;      // flr(rnd(n)) -> gt_p8_rnd_int(n), bit-identical
        return a0.tk === "int" ? expr(a0, "int")
          : (N8 ? `(${expr(a0, "fixed")} >> 8)` : `(int)(${expr(a0, "fixed")} >> 16)`);
      }
      case "ceil":
        return a0.tk === "int" ? expr(a0, "int")
          : (N8 ? `((${expr(a0, "fixed")} + 0xFF) >> 8)` : `(int)((${expr(a0, "fixed")} + 0xFFFFL) >> 16)`);
      case "abs":
        return anyFixed ? `gt_abs${N8 ? "i" : "f"}(${expr(a0, "fixed")})` : `gt_absi(${expr(a0, "int")})`;
      case "sgn":
        return a0.tk === "int" ? `gt_sgni(${expr(a0, "int")})` : `gt_sgn${N8 ? "i" : "f"}(${expr(a0, "fixed")})`;
      case "min": case "max": {
        // int min/max of cheap PURE args inline as a ternary: a cc65 cdecl
        // call (3 pushes + jsr + compare) is ~250 cycles for what is 2
        // compares — and min/max/mid sit in the hottest loops of every game
        // (collision clamps, camera). Multi-eval is safe because cheapPure()
        // admits only literals, plain variables, and simple arithmetic.
        const second = e.args[1] ?? { kind: "number", value: 0, isInt: true };
        const mk = anyFixed ? "fixed" : "int";
        if ((!anyFixed || N8) && cheapPure(a0) && cheapPure(second)) {
          const A = expr(a0, mk), B = expr(second, mk);
          const op = b.special === "min" ? "<" : ">";
          return `((${A}) ${op} (${B}) ? (${A}) : (${B}))`;
        }
        const fn = `gt_${b.special}${anyFixed && !N8 ? "f" : "i"}`;
        const sec = e.args[1] ? expr(e.args[1], anyFixed ? "fixed" : "int") : (anyFixed ? "0L" : "0");
        return `${fn}(${expr(a0, anyFixed ? "fixed" : "int")}, ${sec})`;
      }
      case "mid": {
        // median-of-3 inline (each arg evaluated at most twice) — same
        // rationale as min/max above.
        if ((!anyFixed || N8) && e.args.every((a) => cheapPure(a))) {
          const mk = anyFixed ? "fixed" : "int";
          const A = expr(e.args[0], mk), B = expr(e.args[1], mk), C = expr(e.args[2], mk);
          return `((${A}) < (${B}) ? ((${B}) < (${C}) ? (${B}) : ((${A}) < (${C}) ? (${C}) : (${A})))` +
                 ` : ((${A}) < (${C}) ? (${A}) : ((${B}) < (${C}) ? (${C}) : (${B}))))`;
        }
        const fn = `gt_mid${anyFixed && !N8 ? "f" : "i"}`;
        const k = anyFixed ? "fixed" : "int";
        return `${fn}(${expr(e.args[0], k)}, ${expr(e.args[1], k)}, ${expr(e.args[2], k)})`;
      }
      default: return "0";
    }
  }

  // ---- statements -------------------------------------------------------------

  // ---- literal-run packing: N consecutive `arr[k]=lit; arr[k+1]=lit; ...`
  // statements each cost ~10-14 bytes of cc65 code; as a const table + copy
  // loop they cost the data + ~30 bytes. Big _init data blocks (sfx tables,
  // palettes, level data) shrink by ~70%. The table rides the function's
  // bank via the surrounding rodata-name pragma.
  function matchLitAssign(st) {
    if (!st || st.kind !== "assign" || st.op !== "=") return null;
    if (st.target.kind !== "index" || st.target.object?.kind !== "name") return null;
    const idx = st.target.index;
    if (idx.kind !== "number" || !Number.isInteger(idx.value)) return null;
    if (st.value.kind !== "number") return null;
    return { name: st.target.object.name, tk: st.targetKind ?? "int",
             index: Math.trunc(idx.value), value: st.value };
  }
  let runSeq = 0;
  function literalRun(stmts, i) {
    const m = matchLitAssign(stmts[i]);
    if (!m) return null;
    const vals = [m.value];
    let k = m.index, j = i + 1;
    while (j < stmts.length) {
      const n = matchLitAssign(stmts[j]);
      if (!n || n.name !== m.name || n.tk !== m.tk || n.index !== k + 1) break;
      vals.push(n.value); k++; j++;
    }
    if (vals.length < 6) return null;
    return { name: m.name, tk: m.tk, start: m.index, vals, len: j - i };
  }

  function block(b) {
    let opened = 0;
    for (let bi = 0; bi < b.stmts.length; bi++) {
      const s = b.stmts[bi];
      const run = literalRun(b.stmts, bi);
      if (run) {
        const id = `gtl__lit${runSeq++}`;
        const ct = run.tk === "fixed" ? ctype("fixed") : "int";
        const lits = run.vals.map((v) => expr(v, run.tk)).join(", ");
        line(`{ static const ${ct} ${id}[${run.vals.length}] = { ${lits} };`);
        indent++;
        line(`unsigned char ${id}_i;`);
        line(`for (${id}_i = 0; ${id}_i < ${run.vals.length}; ++${id}_i) ` +
             `${mangle(run.name)}[${run.start - 1} + ${id}_i] = ${id}[${id}_i];`);
        indent--;
        line("}");
        bi += run.len - 1;
        continue;
      }
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
            ? indexRef(mangle(s.target.object.name), s.target.index, !!s.target.arraySym?.elemBytes)
            : (zpParamMap && zpParamMap.has(s.target.name)
                ? zpParamMap.get(s.target.name) : mangle(s.target.name));
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
        // Statement-level inlining for FAT calls: a >=6-param user function
        // called as a statement pastes as a block that binds every argument
        // to a local FIRST (evaluation order — including rnd() state — is
        // exactly a call's), then emits the body with params mapped to the
        // bindings. With --static-locals each binding is an absolute store
        // (~8 cycles) instead of cc65's pusha marshalling (~40/arg) plus
        // (sp),y parameter reads in the callee: a 9-arg particle spawner
        // drops ~450 cycles per call. Gates: no return value (retKind
        // defaults to "int" — use hasReturnValue), no own locals (the
        // emitter hoists local decls to the prologue, a pasted body would
        // reference undeclared names), tiny body, capture-safe.
        const c = s.call;
        if (inliner && c.userFn && c.callee?.kind === "name" &&
            !inlineStack.has(c.callee.name) && functions.has(c.callee.name)) {
          const ifn = functions.get(c.callee.name);
          const ibody = ifn?.node?.body;
          const ownDecls = ibody ? declaredOf(c.callee.name) : null;
          const declaresLocals = ownDecls ? ownDecls.size > ifn.params.length : true;
          if (ibody && ifn.params.length >= 6 && ibody.stmts.length <= 2 &&
              c.args.length === ifn.params.length &&
              !ifn.hasReturnValue && !declaresLocals &&
              !hasReturn(ibody) && noCapture(c.callee.name)) {
            const bind = ifn.params.map((pname, i) =>
              [`L_i${inlineSeq}_${i}`, expr(c.args[i], ifn.paramKinds[i] ?? "int"), ifn.paramKinds[i] ?? "int"]);
            inlineSeq++;
            line("{");
            indent++;
            for (const [ln, ex, k] of bind) line(`${ctype(k)} ${ln} = ${ex};`);
            const rendered = new Map(ifn.params.map((pname, i) => [pname, bind[i][0]]));
            const saved = inlineMap;
            inlineMap = rendered;
            inlineStack.add(c.callee.name);
            block(ibody);
            inlineStack.delete(c.callee.name);
            inlineMap = saved;
            indent--;
            line("}");
            break;
          }
        }
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
          inc = `${v} += ${(Math.round(step * FONE) | 0)}${FL}`;
        }
        // 8-bit narrowing: a counting loop whose bounds are compile-time
        // constants in [0, 254] (255 would wrap the ++ and never terminate),
        // stepping +1, whose variable is never assigned in the body, fits an
        // unsigned char. cc65's char ops are roughly half the cost of int
        // (single-register loads, 8-bit compare), and C's integer promotions
        // make every USE of the variable identical in value — PICO-8
        // semantics are untouched because the value provably stays in range.
        let cty = ctype(kind);
        if (kind === "int" && step === 1) {
          const lo = constFold(s.from), hi = constFold(s.to);
          if (lo !== null && hi !== null &&
              Number.isInteger(lo) && Number.isInteger(hi) &&
              lo >= 0 && lo <= 254 && hi >= 0 && hi <= 254 &&
              !assignsTo(s.body, s.name)) {
            cty = "unsigned char";
          }
        }
        line(`{ ${cty} ${v} = ${expr(s.from, kind)}; ${cty} ${lim} = ${expr(s.to, kind)};`);
        indent++;
        line(`for (; ${v} ${cmp} ${lim}; ${inc}) {`);
        indent++;
        const wasNarrow = narrowedVars.has(s.name);
        if (cty === "unsigned char") narrowedVars.add(s.name);
        block(s.body);
        if (cty === "unsigned char" && !wasNarrow) narrowedVars.delete(s.name);
        indent--;
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
    // O(1) allocation: pop the free chain (links ride the first field array
    // of dead slots, +1-encoded) or take the fresh slot at the watermark.
    const f0 = `${pl.cname}_${pl.fields.keys().next().value}`;
    return `{ unsigned char ${sv}; ` +
           `if (${pl.cname}_free) { ${sv} = (unsigned char)(${pl.cname}_free - 1); ${pl.cname}_free = (unsigned char)${f0}[${sv}]; } ` +
           `else ${sv} = ${pl.cname}_hi; ` +
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
    const params = (fn.params.length && !zpCall.has(name))
      ? fn.params.map((p, i) => `${ctype(fn.paramKinds[i])} ${mangle(p)}`).join(", ")
      : "void";
    const ret = fn.hasReturnValue ? ctype(fn.retKind) : "void";
    return { params, ret };
  };

  // prototypes (dead functions are eliminated entirely)
  for (const [name, fn] of functions) {
    if (!liveFns.has(name)) continue;
    const { params, ret } = signatureOf(name, fn);
    out.push(`${linkage}${ret} ${mangle(name)}(${params});`);
  }
  if (banked) {
    // a stub prototype for every banked function: the INLINER can graft a
    // callee's body (with its calls) into any caller, creating cross-bank
    // edges the AST call graph never had — so the superset is simply every
    // non-fixed function (unreferenced externs cost nothing)
    const candidates = new Set();
    for (const name of functions.keys()) {
      if (bankOf(name) !== "fixed") candidates.add(name);
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
        // constant-byte-only fields (state ids, sprite numbers, colors) store
        // as bytes: half the RAM, and the u8 forall index + u8 element is the
        // fast entity-access shape
        const ct = (fl.kind === "int" && (fl.forceByte || !fl.notByte)) ? "unsigned char" : ctype(fl.kind);
        out.push(`${ct} ${g.cname}_${fname}[${g.size}];`);
      }
      out.push(`unsigned char ${g.cname}_used[${g.size}];`);
      out.push(`unsigned char ${g.cname}_free;   /* free-chain head, +1-encoded (0 = empty) */`);
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
      const ct = g.elemKind === "fixed" ? ctype("fixed") : (g.elemBytes ? "unsigned char" : "int");
      if (g.initVal === 0) {
        out.push(`${ct} ${mangle(name)}[${g.size}];`);
      } else {
        const v = g.elemKind === "fixed"
          ? `${Math.round(g.initVal * FONE) | 0}${FL}`
          : String(Math.trunc(g.initVal));
        out.push(`${ct} ${mangle(name)}[${g.size}] = { ${Array(g.size).fill(v).join(", ")} };`);
      }
    } else if (g.kind === "fixed") {
      const bits = (Math.round(g.value * FONE) | 0);
      out.push(`${ctype("fixed")} ${mangle(name)} = ${bits}${FL}; /* ${g.value} */`);
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
    if (zpCall.has(s.name)) {
      const leaf = (callGraph.get(s.name) ?? new Set()).size === 0;
      if (leaf) {
        zpParamMap = new Map(fn.params.map((p, i) => [p, `gt_p${i}`]));
      } else {
        for (let i = 0; i < fn.params.length; i++) {
          out.push(`    ${ctype(fn.paramKinds[i])} ${mangle(fn.params[i])} = gt_p${i};`);
        }
      }
    }
    block(s.body);
    zpParamMap = null;
    out.push("}");
    out.push("");
    currentFn = null;
    currentFnName = null;
  };

  const fnStmts = chunk.stmts.filter((s) => s.kind === "function" && liveFns.has(s.name));
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
