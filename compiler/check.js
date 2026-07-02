// gtlua semantic checker — scopes, arity, and the numeric-kind system.
//
// Numbers are PICO-8 16.16 fixed point semantically. The compiler tracks two
// KINDS underneath: "int" (provably integral, 16-bit C int — fast on the
// 6502) and "fixed" (32-bit 16.16, C long). Kinds are inferred to a fixpoint:
// a slot (global, local, param, return) starts int and widens to fixed if any
// fractional value flows into it. int arithmetic wraps at the same boundaries
// as PICO-8's 16 integer bits, so the optimization is semantically invisible.
//
// Conditions must be boolean (deliberate wall: Lua's 0 is truthy, C's is not).

import { BUILTINS, GT_MEMBERS, CALLBACKS } from "./builtins.js";

const join = (a, b) => (a === "fixed" || b === "fixed") ? "fixed" : "int";

export function check(chunk, file) {
  const diagnostics = [];
  const globals = new Map();   // name -> {kind, fixedInit, node}
  const functions = new Map(); // name -> {params:[names], paramKinds:[], ret, retKind, node}
  let reporting = true;        // pass 1 runs once: report; fixpoint passes: quiet
  let changed = false;         // fixpoint tracker

  const err = (node, msg) => {
    if (reporting) diagnostics.push({ file, line: node?.line ?? 0, col: node?.col ?? 0, severity: "error", message: msg });
  };
  const warn = (node, msg) => {
    if (reporting) diagnostics.push({ file, line: node?.line ?? 0, col: node?.col ?? 0, severity: "warning", message: msg });
  };

  const isPow2 = (n) => Number.isInteger(n) && n > 0 && (n & (n - 1)) === 0;

  // Constant folding over VALUES (JS numbers, may be fractional).
  function constEval(e) {
    if (!e) return null;
    switch (e.kind) {
      case "number": return e.value;
      case "bool": return null;
      case "neg": {
        const v = constEval(e.expr);
        return v === null ? null : -v;
      }
      case "binop": {
        const l = constEval(e.left), r = constEval(e.right);
        if (l === null || r === null) return null;
        switch (e.op) {
          case "+": return l + r;
          case "-": return l - r;
          case "*": return l * r;
          case "/": return r === 0 ? null : l / r;
          case "\\": return r === 0 ? null : Math.floor(l / r);
          case "%": return r === 0 ? null : l - Math.floor(l / r) * r;
          default: return null;
        }
      }
      default: return null;
    }
  }

  // ---- pass 1: collect top-level declarations -------------------------------
  for (const s of chunk.stmts) {
    if (s.kind === "function") {
      if (functions.has(s.name) || globals.has(s.name)) { err(s, `'${s.name}' is already defined`); continue; }
      if (BUILTINS[s.name]) { /* allowed to shadow? no */ }
      functions.set(s.name, {
        params: s.params,
        paramKinds: s.params.map(() => "int"),
        retKind: "int",
        hasReturnValue: false,
        node: s,
      });
    } else if (s.kind === "local") {
      s.names.forEach((name, idx) => {
        if (globals.has(name) || functions.has(name)) { err(s, `'${name}' is already defined`); return; }
        const init = s.inits[idx] ?? null;
        // fixed-capacity array: local pool = array(N [, initValue])
        if (init && init.kind === "call" && init.callee.kind === "name" && init.callee.name === "array") {
          const size = constEval(init.args[0]);
          const iv = init.args[1] ? constEval(init.args[1]) : 0;
          if (size === null || !Number.isInteger(size) || size < 1 || size > 4096) {
            err(s, "array(n) needs a constant capacity between 1 and 4096");
          }
          if (init.args[1] && iv === null) {
            err(s, "array(n, v) initial value must be a constant");
          }
          const ivv = iv ?? 0;
          globals.set(name, {
            kind: "array",
            elemKind: Number.isInteger(ivv) ? "int" : "fixed",
            size: size ?? 1,
            initVal: ivv,
            node: s,
          });
          return;
        }
        const cv = init === null ? 0 : constEval(init);
        if (init !== null && cv === null) {
          err(s, `top-level 'local ${name}' must be initialized with a constant expression ` +
                 `(runtime init belongs in function _init())`);
        }
        const value = cv ?? 0;
        const isInt = Number.isInteger(value) && value >= -32768 && value <= 32767;
        globals.set(name, {
          kind: isInt ? "int" : "fixed",
          value,
          node: s,
        });
      });
    } else {
      err(s, "only 'local' declarations and function definitions are allowed at top level " +
             "(put runtime statements in function _init())");
    }
  }

  // callback contract
  for (const cb of CALLBACKS) {
    const f = functions.get(cb);
    if (f && f.params.length > 0) err(f.node, `${cb}() takes no parameters`);
  }
  if (!functions.has("_update") && !functions.has("_update60") && !functions.has("_draw")) {
    diagnostics.push({
      file, line: 1, col: 1, severity: "error",
      message: "define _update60() (60fps) or _update() (30fps), and _draw() — the PICO-8 callback contract",
    });
  }
  if (functions.has("_update") && functions.has("_update60")) {
    err(functions.get("_update").node, "define _update() OR _update60(), not both");
  }

  // ---- kind inference to fixpoint, then a reporting pass --------------------
  function widen(slot, kind) {
    if (kind === "fixed" && slot.kind !== "fixed") { slot.kind = "fixed"; changed = true; }
  }

  function checkFunctionBodies() {
    for (const [, fn] of functions) checkFunction(fn);
  }

  reporting = false;
  for (let iter = 0; iter < 20; iter++) {
    changed = false;
    checkFunctionBodies();
    if (!changed) break;
  }
  reporting = true;
  checkFunctionBodies();

  function checkFunction(fn) {
    const scopes = [new Map()];
    fn.params.forEach((p, i) => {
      if (scopes[0].has(p)) err(fn.node, `duplicate parameter '${p}'`);
      scopes[0].set(p, { param: fn, paramIndex: i, get kind() { return fn.paramKinds[i]; } });
    });
    // stable local slots across fixpoint iterations: keyed on the AST decl node
    fn.localSlots = fn.localSlots || new Map();

    let loopDepth = 0;

    function slotFor(node, name) {
      const key = node; // decl AST node identity
      if (!fn.localSlots.has(key)) fn.localSlots.set(key, { kind: "int" });
      return fn.localSlots.get(key);
    }

    function declare(node, name, slot) {
      const top = scopes[scopes.length - 1];
      if (top.has(name)) err(node, `'${name}' is already declared in this scope`);
      top.set(name, slot);
    }

    function lookup(name) {
      for (let i = scopes.length - 1; i >= 0; i--) {
        if (scopes[i].has(name)) return scopes[i].get(name);
      }
      if (globals.has(name)) return globals.get(name);
      return null;
    }

    function widenSlot(sym, kind) {
      if (kind !== "fixed") return;
      if (sym.param) {
        if (sym.param.paramKinds[sym.paramIndex] !== "fixed") {
          sym.param.paramKinds[sym.paramIndex] = "fixed";
          changed = true;
        }
      } else if (sym.kind !== "fixed") {
        sym.kind = "fixed";
        changed = true;
      }
    }

    function checkBlock(b) {
      scopes.push(new Map());
      for (const s of b.stmts) checkStmt(s);
      scopes.pop();
    }

    function checkStmt(s) {
      switch (s.kind) {
        case "local": {
          s.slots = s.slots || [];
          s.names.forEach((name, idx) => {
            const init = s.inits[idx] ?? null;
            let kind = "int";
            if (init) {
              const t = typeOf(init);
              if (t === "bool") err(init, "cannot store a boolean in a number variable");
              kind = t === "fixed" ? "fixed" : "int";
            }
            const slot = slotFor(s, name + "#" + idx);
            widen(slot, kind);
            s.slots[idx] = slot;
            declare(s, name, slot);
          });
          break;
        }
        case "assign": {
          if (s.target.kind === "index") {
            // element store: a[i] = v (or compound)
            const arr = arrayOf(s.target);
            if (!arr) break;
            const it = typeOf(s.target.index);
            if (it === "bool") err(s.target.index, "array index must be a number");
            const vt = typeOf(s.value);
            if (vt === "bool") { err(s.value, "cannot store a boolean in a number array"); break; }
            let rk = vt;
            if (s.op === "/=") rk = "fixed";
            if (s.op !== "=" && s.op !== "\\=") rk = join(rk, arr.elemKind);
            if (rk === "fixed" && arr.elemKind !== "fixed") { arr.elemKind = "fixed"; changed = true; }
            s.targetKind = arr.elemKind;
            s.valueKind = vt;
            if (s.op === "\\=" || s.op === "%=") {
              const d = constEval(s.value);
              s.divConst = d !== null && isPow2(d) ? d : null;
            }
            typeOf(s.target); // annotate target node kinds for the emitter
            break;
          }
          if (s.target.kind !== "name") {
            err(s, "cannot assign to this expression");
            break;
          }
          const sym = lookup(s.target.name);
          if (!sym) {
            err(s, `'${s.target.name}' is not declared — gtlua has no implicit globals; ` +
                   `declare it with 'local ${s.target.name} = ...'`);
            break;
          }
          const vt = typeOf(s.value);
          if (vt === "bool") { err(s.value, "cannot assign a boolean to a number variable"); break; }
          if (s.op === "..=") { err(s, "string concatenation is not supported yet"); break; }
          let resultKind = vt;
          if (s.op === "/=") resultKind = "fixed";
          if (s.op === "\\=") resultKind = "int";
          if (s.op !== "=") resultKind = join(resultKind, symKind(sym));
          if (s.op === "\\=") resultKind = "int";
          widenSlot(sym, resultKind);
          s.targetKind = symKind(sym);
          s.valueKind = vt;
          if (s.op === "\\=" || s.op === "%=") {
            const d = constEval(s.value);
            s.divConst = d !== null && isPow2(d) ? d : null;
          }
          break;
        }
        case "multiassign": {
          s.targetSyms = [];
          const kinds = s.values.map((v) => {
            const t = typeOf(v);
            if (t === "bool") err(v, "cannot assign a boolean to a number variable");
            return t;
          });
          s.targets.forEach((t2, i) => {
            if (t2.kind !== "name") return;
            const sym = lookup(t2.name);
            if (!sym) {
              err(s, `'${t2.name}' is not declared — declare it with 'local ${t2.name} = ...'`);
              return;
            }
            widenSlot(sym, kinds[i] ?? "int");
            s.targetSyms[i] = sym;
          });
          s.valueKinds = kinds;
          s.targetKinds = s.targets.map((t2, i) => s.targetSyms[i] ? symKind(s.targetSyms[i]) : "int");
          break;
        }
        case "callstmt": callType(s.call, true); break;
        case "if": {
          for (const cl of s.clauses) { condType(cl.cond); checkBlock(cl.body); }
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
          scopes.push(new Map());
          for (const st of s.body.stmts) checkStmt(st);
          condType(s.cond);
          scopes.pop();
          loopDepth--;
          break;
        }
        case "fornum": {
          const fk = typeOf(s.from), tk = typeOf(s.to);
          let sk = "int";
          if (s.step) {
            sk = typeOf(s.step);
            const sv = constEval(s.step);
            if (sv === null) err(s.step, "for-loop step must be a nonzero constant");
            else if (sv === 0) err(s.step, "for-loop step cannot be 0");
            s.stepConst = sv;
          } else {
            s.stepConst = 1;
          }
          const loopKind = join(join(fk, tk), sk);
          const slot = slotFor(s, s.name);
          widen(slot, loopKind);
          s.slot = slot;
          scopes.push(new Map());
          scopes[scopes.length - 1].set(s.name, slot);
          loopDepth++;
          for (const st of s.body.stmts) checkStmt(st);
          loopDepth--;
          scopes.pop();
          break;
        }
        case "return": {
          if (s.value) {
            const t = typeOf(s.value);
            if (t === "bool") err(s.value, "returning booleans is not supported yet; return 0/1 or restructure");
            fn.hasReturnValue = true;
            if (t === "fixed" && fn.retKind !== "fixed") { fn.retKind = "fixed"; changed = true; }
            s.valueKind = t;
          }
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
        default: break;
      }
    }

    function symKind(sym) {
      if (sym.param) return sym.param.paramKinds[sym.paramIndex];
      return sym.kind;
    }

    // resolve `name[...]` to its top-level array symbol (or error)
    function arrayOf(indexNode) {
      const obj = indexNode.object;
      if (obj.kind !== "name") {
        err(indexNode, "only top-level arrays can be indexed");
        return null;
      }
      const sym = globals.get(obj.name);
      if (!sym || sym.kind !== "array") {
        err(indexNode, `'${obj.name}' is not an array — declare one at top level with ` +
                       `'local ${obj.name} = array(16)'`);
        return null;
      }
      indexNode.arraySym = sym;
      return sym;
    }

    function condType(e) {
      const t = typeOf(e);
      if (t !== "bool") {
        err(e, "conditions must be boolean — PICO-8 Lua treats 0 as true but compiled C does not, " +
               "so gtlua requires an explicit comparison (write 'x ~= 0' or 'x > 0')");
      }
    }

    // returns "int" | "fixed" | "bool" | "void"
    function callType(call, asStatement = false) {
      const callee = call.callee;

      // gt.* extras
      if (callee.kind === "member" && callee.object.kind === "name" && callee.object.name === "gt") {
        const sig = GT_MEMBERS[callee.field];
        if (!sig) { err(call, `unknown gt function 'gt.${callee.field}'`); return "int"; }
        checkArgs(call, sig.params, `gt.${callee.field}`);
        call.sig = sig;
        return sig.ret;
      }

      if (callee.kind !== "name") {
        err(call, "only plain function calls are supported");
        return "int";
      }

      // builtins
      const b = BUILTINS[callee.name];
      if (b && b.special === "array") {
        err(call, "array(n) is only allowed as a top-level initializer: 'local pool = array(16)'");
        return "int";
      }
      if (b) {
        checkArgs(call, b.params, callee.name);
        call.sig = b;
        call.argKinds = call.args.map((a) => typeOf(a));
        if (b.ret === "same") return call.argKinds.some((k) => k === "fixed") ? "fixed" : "int";
        return b.ret;
      }

      // user functions
      const fn2 = functions.get(callee.name);
      if (!fn2) {
        err(call, `'${callee.name}' is not a function`);
        return "int";
      }
      if (CALLBACKS.includes(callee.name)) {
        err(call, `${callee.name}() is called by the runtime; do not call it yourself`);
      }
      if (call.args.length !== fn2.params.length) {
        err(call, `${callee.name}() takes ${fn2.params.length} argument(s), got ${call.args.length}`);
      }
      call.args.forEach((a, i) => {
        const t = typeOf(a);
        if (t === "bool") err(a, "cannot pass a boolean as a number argument");
        if (i < fn2.paramKinds.length && t === "fixed" && fn2.paramKinds[i] !== "fixed") {
          fn2.paramKinds[i] = "fixed";
          changed = true;
        }
      });
      call.userFn = fn2;
      if (!asStatement && !fn2.hasReturnValue) {
        err(call, `${callee.name}() returns nothing and cannot be used in an expression`);
      }
      return fn2.hasReturnValue ? fn2.retKind : "void";
    }

    function checkArgs(call, params, name) {
      const required = params.filter(([, opt]) => !opt).length;
      if (call.args.length < required || call.args.length > params.length) {
        err(call, `${name}() takes ${required === params.length ? required : `${required}-${params.length}`} argument(s), got ${call.args.length}`);
      }
      call.args.forEach((a) => {
        const t = typeOf(a);
        if (t === "bool") err(a, `cannot pass a boolean as a number argument to ${name}()`);
      });
    }

    function typeOf(e) {
      const t = typeOfInner(e);
      e.tk = t; // annotate for the emitter
      return t;
    }

    function typeOfInner(e) {
      switch (e.kind) {
        case "number": return e.isInt ? "int" : "fixed";
        case "bool": return "bool";
        case "name": {
          const sym = lookup(e.name);
          if (!sym) {
            if (functions.has(e.name)) {
              err(e, `'${e.name}' is a function — functions are not values in gtlua (no closures); call it`);
            } else if (BUILTINS[e.name]) {
              err(e, `'${e.name}' is a builtin function — call it: ${e.name}(...)`);
            } else if (e.name === "gt") {
              err(e, "'gt' is the hardware module; use gt.<function>(...)");
            } else {
              err(e, `'${e.name}' is not declared`);
            }
            return "int";
          }
          e.sym = sym;
          return symKind(sym);
        }
        case "member": {
          if (e.object.kind === "name" && e.object.name === "gt") {
            if (GT_MEMBERS[e.field]) {
              err(e, `gt.${e.field} must be called: gt.${e.field}(...)`);
              return "int";
            }
            err(e, `unknown gt member 'gt.${e.field}'`);
            return "int";
          }
          err(e, "field access is not supported yet (structs land in the next release)");
          return "int";
        }
        case "index": {
          const arr = arrayOf(e);
          if (!arr) return "int";
          const it = typeOf(e.index);
          if (it === "bool") err(e.index, "array index must be a number");
          return arr.elemKind;
        }
        case "len": {
          if (e.expr.kind === "name") {
            const sym = globals.get(e.expr.name);
            if (sym && sym.kind === "array") { e.arraySym = sym; return "int"; }
          }
          err(e, "'#' works on top-level arrays only");
          return "int";
        }
        case "call": return callType(e);
        case "neg": {
          const t = typeOf(e.expr);
          if (t === "bool") err(e, "cannot negate a boolean");
          return t;
        }
        case "bnot": {
          // PICO-8 ~x flips all 32 bits including the fraction -> always fixed
          const t = typeOf(e.expr);
          if (t === "bool") err(e, "'~' needs a number");
          return "fixed";
        }
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
          err(e, `'${op}' needs boolean operands (PICO-8's 'x or default' value idiom needs nil, which gtlua doesn't have)`);
        }
        return "bool";
      }
      if (["<", ">", "<=", ">="].includes(op)) {
        const lt = typeOf(e.left), rt = typeOf(e.right);
        if (lt === "bool" || rt === "bool") err(e, "cannot compare booleans with <");
        e.cmpKind = join(lt === "bool" ? "int" : lt, rt === "bool" ? "int" : rt);
        return "bool";
      }
      if (op === "==" || op === "~=") {
        const lt = typeOf(e.left), rt = typeOf(e.right);
        if ((lt === "bool") !== (rt === "bool")) err(e, "cannot compare a number with a boolean");
        e.cmpKind = lt === "bool" ? "bool" : join(lt, rt);
        return "bool";
      }
      if (op === "..") {
        err(e, "string concatenation is not supported yet");
        return "int";
      }

      const lt = typeOf(e.left), rt = typeOf(e.right);
      if (lt === "bool" || rt === "bool") {
        err(e, `'${op}' needs number operands`);
        return "int";
      }

      if (op === "/") {
        const d = constEval(e.right);
        e.divConst = d !== null && isPow2(d) ? d : null;
        if (d === 0) warn(e, "division by constant zero saturates to ±32767.99998 (PICO-8 semantics)");
        return "fixed";
      }
      if (op === "\\") {
        const d = constEval(e.right);
        e.divConst = d !== null && isPow2(d) ? d : null;
        e.operandKind = join(lt, rt);
        return "int";
      }
      if (op === "%") {
        const d = constEval(e.right);
        e.divConst = d !== null && isPow2(d) ? d : null;
        return join(lt, rt);
      }
      if (["&", "|", "^^", "<<", ">>", ">>>"].includes(op)) {
        return join(lt, rt);
      }
      // + - *
      return join(lt, rt);
    }

    checkBlock(fn.node.body);
  }

  return { diagnostics, symbols: { globals, functions } };
}
