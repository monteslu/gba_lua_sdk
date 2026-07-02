// gtlua semantic checker — scopes, arity, and the int/bool type discipline.
//
// Conditions must be boolean. That is a deliberate wall: Lua treats 0 as
// truthy and C treats it as false, so an int in a condition would silently
// mean different things to a Lua reader and to the generated C. We refuse it
// with a fix-it instead of picking a side.

import { GT_FUNCTIONS, GT_CONSTANTS } from "./gt_api.js";

/**
 * @param {{kind:string, stmts:object[]}} chunk
 * @param {string} file
 * @returns {{diagnostics: object[], symbols: {globals: Map<string, object>, functions: Map<string, object>}}}
 */
export function check(chunk, file) {
  const diagnostics = [];
  const globals = new Map();   // name -> {type:"int"}
  const functions = new Map(); // name -> {params:[...], ret:"int"|"bool"|"void"}

  const err = (node, msg) =>
    diagnostics.push({ file, line: node?.line ?? 0, col: node?.col ?? 0, severity: "error", message: msg });
  const warn = (node, msg) =>
    diagnostics.push({ file, line: node?.line ?? 0, col: node?.col ?? 0, severity: "warning", message: msg });

  const isPow2 = (n) => n > 0 && (n & (n - 1)) === 0;

  // Constant-fold integer expressions where possible (returns number or null).
  function constEval(e) {
    if (!e) return null;
    if (e.kind === "number") return e.value;
    if (e.kind === "neg") {
      const v = constEval(e.expr);
      return v === null ? null : -v;
    }
    if (e.kind === "binop") {
      const l = constEval(e.left), r = constEval(e.right);
      if (l === null || r === null) return null;
      switch (e.op) {
        case "+": return l + r;
        case "-": return l - r;
        case "*": return l * r;
        case "//": return r === 0 ? null : Math.floor(l / r);
        case "%": return r === 0 ? null : l % r;
        default: return null;
      }
    }
    if (e.kind === "member" && e.object.kind === "name" && e.object.name === "gt") {
      return null; // gt constants stay symbolic
    }
    return null;
  }

  // ---- pass 1: collect top-level declarations ------------------------------
  for (const s of chunk.stmts) {
    if (s.kind === "function") {
      if (functions.has(s.name) || globals.has(s.name)) {
        err(s, `'${s.name}' is already defined`);
        continue;
      }
      functions.set(s.name, { params: s.params, ret: null, node: s });
    } else if (s.kind === "local") {
      if (globals.has(s.name) || functions.has(s.name)) {
        err(s, `'${s.name}' is already defined`);
        continue;
      }
      const cv = s.init === null ? 0 : constEval(s.init);
      if (s.init !== null && cv === null) {
        err(s, `top-level 'local ${s.name}' must be initialized with a constant expression ` +
               `(runtime init belongs in function init())`);
      }
      if (cv !== null && (cv < -32768 || cv > 65535)) {
        err(s, `initial value ${cv} does not fit in a 16-bit integer`);
      }
      globals.set(s.name, { type: "int", init: cv ?? 0 });
    } else {
      err(s, "only 'local' declarations and function definitions are allowed at top level " +
             "(put runtime statements in function init() or function update())");
    }
  }

  if (!functions.has("update")) {
    diagnostics.push({
      file, line: 1, col: 1, severity: "error",
      message: "every gtlua program must define 'function update()' — it runs once per frame",
    });
  }
  for (const special of ["update", "init"]) {
    const f = functions.get(special);
    if (f && f.params.length > 0) err(f.node, `function ${special}() takes no parameters`);
  }

  // ---- pass 2: infer return types (int if any `return expr`, else void) ----
  function scanReturns(node, found) {
    if (!node || typeof node !== "object") return;
    if (node.kind === "return" && node.value) found.value = true;
    for (const key of Object.keys(node)) {
      const v = node[key];
      if (Array.isArray(v)) v.forEach((x) => scanReturns(x, found));
      else if (v && typeof v === "object" && v.kind) scanReturns(v, found);
      else if (v && typeof v === "object" && v.stmts) scanReturns(v, found);
      else if (key === "body" || key === "elseBody") scanReturns(v, found);
    }
  }
  for (const [, fn] of functions) {
    const found = { value: false };
    scanReturns(fn.node.body, found);
    fn.ret = found.value ? "int" : "void";
  }

  // ---- pass 3: check each function body ------------------------------------
  for (const [, fn] of functions) {
    checkFunction(fn);
  }

  function checkFunction(fn) {
    // scope: stack of Maps; params innermost-outermost lookup
    const scopes = [new Map()];
    for (const p of fn.node.params) {
      if (scopes[0].has(p)) err(fn.node, `duplicate parameter '${p}'`);
      scopes[0].set(p, { type: "int" });
    }

    let loopDepth = 0;

    function declare(node, name) {
      const top = scopes[scopes.length - 1];
      if (top.has(name)) err(node, `'${name}' is already declared in this scope`);
      top.set(name, { type: "int" });
    }

    function lookup(name) {
      for (let i = scopes.length - 1; i >= 0; i--) {
        if (scopes[i].has(name)) return scopes[i].get(name);
      }
      if (globals.has(name)) return globals.get(name);
      return null;
    }

    function checkBlock(b) {
      scopes.push(new Map());
      for (const s of b.stmts) checkStmt(s);
      scopes.pop();
    }

    function checkStmt(s) {
      switch (s.kind) {
        case "local": {
          if (s.init) exprType(s.init, "int");
          else warn(s, `'${s.name}' has no initial value; it starts at 0`);
          declare(s, s.name);
          break;
        }
        case "assign": {
          if (s.target.kind !== "name") {
            err(s, "indexing is not supported yet; assign to a plain variable");
            break;
          }
          const sym = lookup(s.target.name);
          if (!sym) {
            err(s, `'${s.target.name}' is not declared — gtlua has no implicit globals; ` +
                   `declare it with 'local ${s.target.name} = ...'`);
          }
          if (s.op === "//=") {
            const d = constEval(s.value);
            if (d === null || !isPow2(d)) {
              err(s, "'//=' requires a constant power-of-two divisor (the 6502 has no divide hardware)");
            }
          }
          exprType(s.value, "int");
          break;
        }
        case "callstmt": {
          callType(s.call, /*asStatement*/ true);
          break;
        }
        case "if": {
          for (const cl of s.clauses) {
            condType(cl.cond);
            checkBlock(cl.body);
          }
          if (s.elseBody) checkBlock(s.elseBody);
          break;
        }
        case "while": {
          condType(s.cond);
          loopDepth++; checkBlock(s.body); loopDepth--;
          break;
        }
        case "repeat": {
          loopDepth++;
          // repeat scope covers the until condition in Lua; flatten here
          scopes.push(new Map());
          for (const st of s.body.stmts) checkStmt(st);
          condType(s.cond);
          scopes.pop();
          loopDepth--;
          break;
        }
        case "fornum": {
          exprType(s.from, "int");
          exprType(s.to, "int");
          if (s.step) {
            const sv = constEval(s.step);
            if (sv === null) err(s, "for-loop step must be a nonzero constant");
            else if (sv === 0) err(s, "for-loop step cannot be 0");
            s.stepConst = sv;
          } else {
            s.stepConst = 1;
          }
          scopes.push(new Map());
          scopes[scopes.length - 1].set(s.name, { type: "int" });
          for (const st of s.body.stmts) {
            // assignment to the loop variable is legal Lua but a footgun; warn
            if (st.kind === "assign" && st.target.kind === "name" && st.target.name === s.name) {
              warn(st, `assigning to loop variable '${s.name}' inside the loop`);
            }
            loopDepth++; checkStmt(st); loopDepth--;
          }
          scopes.pop();
          break;
        }
        case "return": {
          if (s.value) exprType(s.value, "int");
          break;
        }
        case "break": {
          if (loopDepth === 0) err(s, "'break' outside of a loop");
          break;
        }
        case "do": checkBlock(s.body); break;
        case "function":
          err(s, "functions cannot be defined inside functions (no closures); move it to top level");
          break;
        default:
          break;
      }
    }

    // condition context: must be bool
    function condType(e) {
      const t = exprType(e, null);
      if (t === "int") {
        err(e, "conditions must be boolean — Lua treats 0 as true but C does not, so gtlua " +
               "requires an explicit comparison (write 'x ~= 0' or 'x > 0')");
      }
    }

    function callType(call, asStatement = false) {
      const callee = call.callee;
      // gt.fn(...)
      if (callee.kind === "member" && callee.object.kind === "name" && callee.object.name === "gt") {
        const sig = GT_FUNCTIONS[callee.field];
        if (!sig) {
          err(call, `unknown gt function 'gt.${callee.field}'` +
                    (GT_CONSTANTS[callee.field] ? ` — gt.${callee.field} is a constant, not a function` : ""));
          return "int";
        }
        if (call.args.length !== sig.params.length) {
          err(call, `gt.${callee.field} takes ${sig.params.length} argument(s), got ${call.args.length}`);
        }
        call.args.forEach((a, idx) => exprType(a, sig.params[idx] ?? "int"));
        if (asStatement && sig.ret !== "void") {
          warn(call, `result of gt.${callee.field}() is discarded`);
        }
        return sig.ret;
      }
      // user function
      if (callee.kind === "name") {
        const fn2 = functions.get(callee.name);
        if (!fn2) {
          err(call, `'${callee.name}' is not a function`);
          return "int";
        }
        if (callee.name === "init" || callee.name === "update") {
          err(call, `${callee.name}() is called by the runtime; do not call it yourself`);
        }
        if (call.args.length !== fn2.params.length) {
          err(call, `${callee.name}() takes ${fn2.params.length} argument(s), got ${call.args.length}`);
        }
        call.args.forEach((a) => exprType(a, "int"));
        if (asStatement === false && fn2.ret === "void") {
          err(call, `${callee.name}() returns nothing and cannot be used in an expression`);
        }
        return fn2.ret === "void" ? "void" : "int";
      }
      err(call, "only plain function calls are supported");
      return "int";
    }

    // returns "int" | "bool"; if expected is non-null, mismatches are errors
    function exprType(e, expected) {
      const t = typeOf(e);
      if (expected && t !== expected && t !== "void") {
        if (expected === "int" && t === "bool") {
          err(e, "boolean used where a number is expected (there is no implicit bool→int conversion)");
        } else if (expected === "bool" && t === "int") {
          err(e, "number used where a boolean is expected; write an explicit comparison");
        }
      }
      return t;
    }

    function typeOf(e) {
      switch (e.kind) {
        case "number": return "int";
        case "bool": return "bool";
        case "name": {
          const sym = lookup(e.name);
          if (!sym) {
            if (functions.has(e.name)) {
              err(e, `'${e.name}' is a function — functions are not values in gtlua (no closures); call it`);
            } else if (e.name === "gt") {
              err(e, "'gt' is the hardware module; use gt.<function>(...) or gt.<CONSTANT>");
            } else {
              err(e, `'${e.name}' is not declared`);
            }
            return "int";
          }
          return sym.type;
        }
        case "member": {
          if (e.object.kind === "name" && e.object.name === "gt") {
            if (GT_CONSTANTS[e.field]) return "int";
            if (GT_FUNCTIONS[e.field]) {
              err(e, `gt.${e.field} must be called: gt.${e.field}(...)`);
              return "int";
            }
            err(e, `unknown gt constant 'gt.${e.field}'`);
            return "int";
          }
          err(e, "field access is not supported yet (structs land in a later release)");
          return "int";
        }
        case "index":
          err(e, "indexing is not supported yet (arrays land in a later release)");
          return "int";
        case "call": return callType(e) === "bool" ? "bool" : "int";
        case "neg": exprType(e.expr, "int"); return "int";
        case "not": {
          const t = typeOf(e.expr);
          if (t !== "bool") err(e, "'not' needs a boolean; write an explicit comparison");
          return "bool";
        }
        case "binop": return binopType(e);
        default: return "int";
      }
    }

    function binopType(e) {
      const { op } = e;
      if (op === "and" || op === "or") {
        const lt = typeOf(e.left), rt = typeOf(e.right);
        if (lt !== "bool" || rt !== "bool") {
          err(e, `'${op}' needs boolean operands (Lua's 'x or default' idiom is not supported)`);
        }
        return "bool";
      }
      if (["<", ">", "<=", ">="].includes(op)) {
        exprType(e.left, "int");
        exprType(e.right, "int");
        return "bool";
      }
      if (op === "==" || op === "~=") {
        const lt = typeOf(e.left), rt = typeOf(e.right);
        if (lt !== rt) err(e, "cannot compare a number with a boolean");
        return "bool";
      }
      if (op === "..") {
        err(e, "string concatenation is not supported yet");
        return "int";
      }
      if (op === "/") {
        err(e, "'/' is not supported — the 6502 has no divide hardware; " +
               "use '//' with a power-of-two constant, or restructure with shifts/multiplies");
        return "int";
      }
      if (op === "//" || op === "%") {
        exprType(e.left, "int");
        const d = constEval(e.right);
        if (d === null || !isPow2(d)) {
          err(e, `'${op}' requires a constant power-of-two divisor (the 6502 has no divide hardware)`);
        } else {
          e.divConst = d;
        }
        return "int";
      }
      // + - *
      exprType(e.left, "int");
      exprType(e.right, "int");
      return "int";
    }

    checkBlock(fn.node.body);
  }

  return { diagnostics, symbols: { globals, functions } };
}
