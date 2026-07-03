// gtlua C emitter — lowers the checked AST to cc65-flavored C89.
//
// Numeric kinds map to C types: int -> `int` (16-bit), fixed -> `long`
// (32-bit 16.16). Conversions are explicit and single-evaluation:
//   promote int->fixed:  ((long)(x) << 16)
//   floor  fixed->int:   (int)((x) >> 16)     (arithmetic shift = flr)
// Fixed multiply/divide/mod go through the gt_f* runtime; power-of-two
// divisors fold to shifts/masks at compile time (exact for 16.16).

import { BUILTINS, GT_MEMBERS, CALLBACKS } from "./builtins.js";

export function emit(chunk, symbols, file) {
  const out = [];
  let indent = 1;
  let tempCounter = 0;
  const line = (s) => out.push("    ".repeat(s === "" ? 0 : indent) + s);
  const mangle = (name) => `gtl_${name}`;
  const { globals, functions } = symbols;

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
        return cv(`gt_fmul(${expr(e.left, "fixed")}, ${expr(e.right, "fixed")})`, "fixed", want);
      }
      case "/": {
        if (e.divConst) {
          if (e.left.tk === "int" && 16 - lg >= 0) {
            return cv(`((long)${expr(e.left, "int")} << ${16 - lg})`, "fixed", want);
          }
          return cv(`(${expr(e.left, "fixed")} >> ${lg})`, "fixed", want);
        }
        return cv(`gt_fdiv(${expr(e.left, "fixed")}, ${expr(e.right, "fixed")})`, "fixed", want);
      }
      case "\\": {
        const ok = e.operandKind ?? "int";
        if (e.divConst) {
          if (ok === "int") return cv(`(${expr(e.left, "int")} >> ${lg})`, "int", want);
          return cv(`(int)(${expr(e.left, "fixed")} >> ${16 + lg})`, "int", want);
        }
        if (ok === "int") return cv(`gt_ifdiv(${expr(e.left, "int")}, ${expr(e.right, "int")})`, "int", want);
        return cv(`(int)(gt_fdiv(${expr(e.left, "fixed")}, ${expr(e.right, "fixed")}) >> 16)`, "int", want);
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

  // ---- calls -----------------------------------------------------------------

  function argAt(call, i, pkind, dflt) {
    const a = call.args[i];
    if (!a) return dflt;
    switch (pkind) {
      case "coord": return expr(a, a.tk === "fixed" ? "int" : "int");
      case "int": return expr(a, "int");
      case "num": return expr(a, "fixed");
      case "color": return expr(a, "int");
      default: return expr(a, "any");
    }
  }

  function call(e) {
    const callee = e.callee;

    // gt.* extras
    if (callee.kind === "member" && callee.object.kind === "name" && callee.object.name === "gt") {
      const sig = GT_MEMBERS[callee.field];
      if (sig.special === "rgb") return `(0x100 | (${argAt(e, 0, "int", "0")} & 0xFF))`;
      if (sig.isValue) return sig.c;
      return `${sig.c}(${sig.params.map((p, i) => argAt(e, i, p[0], defaultFor(callee.field, i))).join(", ")})`;
    }

    // user function
    if (e.userFn) {
      const fn = e.userFn;
      const args = e.args.map((a, i) => expr(a, fn.paramKinds[i] ?? "int"));
      return `${mangle(callee.name)}(${args.join(", ")})`;
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
      return `(${pl.cname}_used[${sv}] = 0, --${pl.cname}_n, (void)0)`;
    }
    if (b.special) return specialCall(e, b, name);

    // plain builtin
    const args = b.params.map((p, i) => argAt(e, i, p[0], defaultFor(name, i)));
    return `${b.c}(${args.join(", ")})`;
  }

  function defaultFor(name, i) {
    if (name === "cls") return "0";
    if (name === "camera") return "0";
    if (name === "rnd") return "65536L";     // rnd() == rnd(1.0)
    if (name === "btn" || name === "btnp") return "0"; // player 0
    if (name === "pal") return "-1";          // pal() == reset
    if (name === "note") return "127";        // default volume
    if (name === "spr") return "1";           // w,h default 1 cell
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
        const pl = s.poolSym;
        line(`{ int ${sv};`);
        indent++;
        line(`for (${sv} = 0; ${sv} < ${pl.size}; ++${sv}) {`);
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
    // statement-expression shape via a helper block emitted inline by callstmt
    return `{ int ${sv}; for (${sv} = 0; ${sv} < ${pl.size}; ++${sv}) if (!${pl.cname}_used[${sv}]) break; ` +
           `if (${sv} < ${pl.size}) { ${pl.cname}_used[${sv}] = 1; ++${pl.cname}_n; ${sets} } }`;
  }

  // ---- module layout -----------------------------------------------------------

  let currentFn = null;

  out.push(`/* generated by gtlua from ${file} — edit the .lua, not this file */`);
  out.push(`#include "gt_api.h"`);
  out.push("");

  // prototypes
  for (const [name, fn] of functions) {
    const params = fn.params.length
      ? fn.params.map((p, i) => `${ctype(fn.paramKinds[i])} ${mangle(p)}`).join(", ")
      : "void";
    const ret = fn.hasReturnValue ? ctype(fn.retKind) : "void";
    out.push(`static ${ret} ${mangle(name)}(${params});`);
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

  // function bodies
  for (const s of chunk.stmts) {
    if (s.kind !== "function") continue;
    const fn = functions.get(s.name);
    currentFn = fn;
    const params = s.params.length
      ? s.params.map((p, i) => `${ctype(fn.paramKinds[i])} ${mangle(p)}`).join(", ")
      : "void";
    const ret = fn.hasReturnValue ? ctype(fn.retKind) : "void";
    out.push(`static ${ret} ${mangle(s.name)}(${params})`);
    out.push("{");
    indent = 1;
    block(s.body);
    out.push("}");
    out.push("");
    currentFn = null;
  }

  // the PICO-8 frame harness
  const has = (n) => functions.has(n);
  const thirty = has("_update") && !has("_update60");
  out.push("void main(void)");
  out.push("{");
  out.push("    gt_init();");
  out.push("    gt_sheet_init();");
  if (symbols.usesAudio) out.push("    gt_audio_init();");
  if (thirty) out.push("    gt_p8_fps30();");
  if (has("_init")) out.push(`    ${mangle("_init")}();`);
  out.push("    for (;;) {");
  out.push("        gt_update_inputs();");
  if (has("_update60")) out.push(`        ${mangle("_update60")}();`);
  if (thirty) out.push(`        ${mangle("_update")}();`);
  if (has("_draw")) out.push(`        ${mangle("_draw")}();`);
  out.push("        gt_endframe();");
  out.push("    }");
  out.push("}");
  out.push("");

  return out.join("\n");
}
