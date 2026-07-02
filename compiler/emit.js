// gtlua C emitter — lowers the checked AST to cc65-flavored C89.
//
// Emission rules that matter:
//  - fully parenthesized expressions (no C-precedence surprises)
//  - a `local` mid-block opens a nested C block, because C89 requires
//    declarations before statements; the nesting matches Lua scoping
//  - `//` and `%` by a power-of-two constant lower to >> and & — cc65's
//    arithmetic right shift and mask both match Lua's floor semantics
//  - user identifiers get the gtl_ prefix (no keyword/runtime collisions)

import { GT_FUNCTIONS, GT_CONSTANTS } from "./gt_api.js";

/**
 * @param {{stmts: object[]}} chunk
 * @param {{globals: Map<string, object>, functions: Map<string, object>}} symbols
 * @param {string} file source name, for the header comment
 * @returns {string} C source
 */
export function emit(chunk, symbols, file) {
  const out = [];
  let indent = 1;
  let tempCounter = 0;
  const line = (s) => out.push("    ".repeat(s === "" ? 0 : indent) + s);

  const mangle = (name) => `gtl_${name}`;

  // ---- expressions ----------------------------------------------------------

  function expr(e) {
    switch (e.kind) {
      case "number": return String(e.value);
      case "bool": return e.value ? "1" : "0";
      case "name": return mangle(e.name);
      case "member": {
        // checked: only gt.CONSTANT reaches here
        return GT_CONSTANTS[e.field] ?? "0";
      }
      case "neg": return `(-${expr(e.expr)})`;
      case "not": return `(!${expr(e.expr)})`;
      case "call": return call(e);
      case "binop": return binop(e);
      default: return "0";
    }
  }

  function binop(e) {
    const map = {
      "+": "+", "-": "-", "*": "*",
      "<": "<", ">": ">", "<=": "<=", ">=": ">=",
      "==": "==", "~=": "!=",
      "and": "&&", "or": "||",
    };
    if (e.op === "//") return `(${expr(e.left)} >> ${Math.log2(e.divConst ?? 1)})`;
    if (e.op === "%") return `(${expr(e.left)} & ${(e.divConst ?? 1) - 1})`;
    return `(${expr(e.left)} ${map[e.op] ?? e.op} ${expr(e.right)})`;
  }

  function call(e) {
    const callee = e.callee;
    if (callee.kind === "member" && callee.object.kind === "name" && callee.object.name === "gt") {
      const sig = GT_FUNCTIONS[callee.field];
      if (sig.isValue) return sig.c; // e.g. gt.ticks() -> (int)gt_ticks
      return `${sig.c}(${e.args.map(expr).join(", ")})`;
    }
    return `${mangle(callee.name)}(${e.args.map(expr).join(", ")})`;
  }

  // ---- statements -----------------------------------------------------------

  function block(b) {
    let opened = 0;
    for (const s of b.stmts) {
      if (s.kind === "local") {
        // C89: declarations start a block. Open a nested block whose extent
        // (rest of this Lua block) matches the local's Lua scope.
        line(`{ int ${mangle(s.name)} = ${s.init ? expr(s.init) : "0"};`);
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
        const t = mangle(s.target.name);
        if (s.op === "=") line(`${t} = ${expr(s.value)};`);
        else if (s.op === "//=") {
          const d = constOf(s.value);
          line(`${t} >>= ${Math.log2(d)};`);
        } else if (s.op === "%=") {
          const d = constOf(s.value);
          line(`${t} &= ${d - 1};`);
        } else {
          line(`${t} ${s.op.slice(0, 1)}= ${expr(s.value)};`); // += -= *=
        }
        break;
      }
      case "callstmt": line(`${call(s.call)};`); break;
      case "if": {
        s.clauses.forEach((cl, i) => {
          line(`${i === 0 ? "if" : "} else if"} (${expr(cl.cond)}) {`);
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
        line(`while (${expr(s.cond)}) {`);
        indent++; block(s.body); indent--;
        line("}");
        break;
      }
      case "repeat": {
        line("do {");
        indent++; block(s.body); indent--;
        line(`} while (!(${expr(s.cond)}));`);
        break;
      }
      case "fornum": {
        const v = mangle(s.name);
        const lim = `L_lim${tempCounter++}`;
        const step = s.stepConst ?? 1;
        const cmp = step > 0 ? "<=" : ">=";
        const inc = step === 1 ? `++${v}` : step === -1 ? `--${v}` : `${v} += ${step}`;
        line(`{ int ${v} = ${expr(s.from)}; int ${lim} = ${expr(s.to)};`);
        indent++;
        line(`for (; ${v} ${cmp} ${lim}; ${inc}) {`);
        indent++; block(s.body); indent--;
        line("}");
        indent--;
        line("}");
        break;
      }
      case "return": line(s.value ? `return ${expr(s.value)};` : "return;"); break;
      case "break": line("break;"); break;
      case "do": {
        line("{");
        indent++; block(s.body); indent--;
        line("}");
        break;
      }
      default: break;
    }
  }

  function constOf(e) {
    if (e.kind === "number") return e.value;
    if (e.kind === "binop" && e.divConst) return e.divConst;
    // checker guarantees constant power of two; re-derive simple cases
    if (e.kind === "neg" && e.expr.kind === "number") return -e.expr.value;
    return e.value ?? 1;
  }

  // ---- module layout --------------------------------------------------------

  const { globals, functions } = symbols;

  out.push(`/* generated by gtlua from ${file} — edit the .lua, not this file */`);
  out.push(`#include "gt_api.h"`);
  out.push("");

  // prototypes
  for (const [name, fn] of functions) {
    const params = fn.params.length
      ? fn.params.map((p) => `int ${mangle(p)}`).join(", ")
      : "void";
    out.push(`static ${fn.ret === "void" ? "void" : "int"} ${mangle(name)}(${params});`);
  }
  out.push("");

  // module variables — deliberately NOT static so they land in the linker
  // map as _gtl_<name>: tests and debuggers assert on them by address
  for (const [name, g] of globals) {
    out.push(`int ${mangle(name)} = ${g.init};`);
  }
  if (globals.size) out.push("");

  // function bodies
  for (const s of chunk.stmts) {
    if (s.kind !== "function") continue;
    const fn = functions.get(s.name);
    const params = s.params.length
      ? s.params.map((p) => `int ${mangle(p)}`).join(", ")
      : "void";
    out.push(`static ${fn.ret === "void" ? "void" : "int"} ${mangle(s.name)}(${params})`);
    out.push("{");
    indent = 1;
    block(s.body);
    out.push("}");
    out.push("");
  }

  // the frame harness
  out.push("void main(void)");
  out.push("{");
  out.push("    gt_init();");
  if (functions.has("init")) out.push(`    ${mangle("init")}();`);
  out.push("    for (;;) {");
  out.push("        gt_update_inputs();");
  out.push(`        ${mangle("update")}();`);
  out.push("        gt_endframe();");
  out.push("    }");
  out.push("}");
  out.push("");

  return out.join("\n");
}
