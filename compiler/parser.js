// gtlua parser — recursive descent, PICO-8-flavored Lua.
//
// Dialect (PICO8.md): one-line `if (cond) stmt [else stmt]` / `while (cond)
// stmt` shorthand (parens required, newline ends the body), `\` floor
// division, `!=`, multiple assignment, bitwise operators. Cut Lua features
// fail here with the diagnostic the spec promises.

export function parse(tokens, file) {
  let pos = 0;
  const diagnostics = [];

  const peek = (o = 0) => tokens[Math.min(pos + o, tokens.length - 1)];
  const at = (type) => peek().type === type;

  function error(msg, tok = peek()) {
    diagnostics.push({ file, line: tok.line, col: tok.col, severity: "error", message: msg });
  }

  function next() { return tokens[pos++]; }

  function expect(type, what) {
    if (at(type)) return next();
    error(`expected ${what ?? `'${type}'`} but found '${peek().value || peek().type}'`);
    return peek();
  }

  function sync(types) {
    while (!at("eof") && !types.includes(peek().type)) pos++;
  }

  // ---- statements ----------------------------------------------------------

  function block(enders) {
    const stmts = [];
    while (!at("eof") && !enders.includes(peek().type)) {
      const before = pos;
      const s = statement();
      if (s) stmts.push(s);
      if (pos === before) pos++;
    }
    return { kind: "block", stmts };
  }

  // statements until end-of-line `line` (for the one-line if/while shorthand)
  function lineBlock(line, extraEnders = []) {
    const stmts = [];
    while (!at("eof") && peek().line === line && !extraEnders.includes(peek().type)) {
      const before = pos;
      const s = statement();
      if (s) stmts.push(s);
      if (pos === before) pos++;
    }
    return { kind: "block", stmts };
  }

  function statement() {
    const tok = peek();
    switch (tok.type) {
      case ";": next(); return null;
      case "local": return localStmt();
      case "function": return functionStmt();
      case "if": return ifStmt();
      case "while": return whileStmt();
      case "for": return forStmt();
      case "repeat": return repeatStmt();
      case "return": {
        next();
        let value = null;
        if (!at("end") && !at("eof") && !at("else") && !at("elseif") && !at("until") &&
            peek().line === tok.line || (peek().line !== tok.line &&
            !at("end") && !at("eof") && !at("else") && !at("elseif") && !at("until") && !isStatementStart(peek()))) {
          if (!at("end") && !at("eof") && !at("else") && !at("elseif") && !at("until")) {
            value = expression();
            if (at(",")) error("multiple return values are not supported yet");
          }
        }
        return { kind: "return", value, line: tok.line, col: tok.col };
      }
      case "break": next(); return { kind: "break", line: tok.line, col: tok.col };
      case "do": {
        next();
        const body = block(["end"]);
        expect("end");
        return { kind: "do", body, line: tok.line, col: tok.col };
      }
      case "goto":
        error("goto is not supported (the runtime owns the main loop; use _draw())");
        sync(["end", "eof"]);
        return null;
      default:
        return exprStatement();
    }
  }

  function isStatementStart(tok) {
    return ["local", "function", "if", "while", "for", "repeat", "return",
            "break", "do", "goto", "name", ";"].includes(tok.type);
  }

  function localStmt() {
    const tok = expect("local");
    if (at("function")) {
      next();
      return functionBody(expect("name", "function name"), tok);
    }
    const names = [expect("name", "variable name").value];
    while (at(",")) {
      next();
      names.push(expect("name", "variable name").value);
    }
    const inits = [];
    if (at("=")) {
      next();
      inits.push(expression());
      while (at(",")) { next(); inits.push(expression()); }
    }
    if (inits.length > names.length) {
      error(`${names.length} variable(s) but ${inits.length} value(s)`);
    }
    return { kind: "local", names, inits, line: tok.line, col: tok.col };
  }

  function functionStmt() {
    const tok = expect("function");
    const name = expect("name", "function name");
    if (at(".") || at(":")) {
      error("method definitions (function a.b / a:b) are not supported; use a plain function name");
      sync(["end", "eof"]);
      if (at("end")) next();
      return null;
    }
    return functionBody(name, tok);
  }

  function functionBody(nameTok, tok) {
    expect("(");
    const params = [];
    if (!at(")")) {
      for (;;) {
        if (at(".")) {
          error("variadic functions (...) are not supported");
          next(); if (at(".")) next(); if (at(".")) next();
        } else {
          params.push(expect("name", "parameter name").value);
        }
        if (at(",")) { next(); continue; }
        break;
      }
    }
    expect(")");
    const body = block(["end"]);
    expect("end");
    return { kind: "function", name: nameTok.value, params, body, line: tok.line, col: tok.col };
  }

  function ifStmt() {
    const tok = expect("if");
    const parenCond = at("(");
    const cond = expression();

    // PICO-8 one-line shorthand: `if (cond) stmt [else stmt]` — parenthesized
    // condition, no `then`, body ends at end of line.
    if (parenCond && !at("then")) {
      if (peek().line !== tok.line || at("eof")) {
        error("expected 'then' (or a same-line statement for the `if (cond) stmt` shorthand)");
        return { kind: "if", clauses: [{ cond, body: { kind: "block", stmts: [] } }], elseBody: null, line: tok.line, col: tok.col };
      }
      const body = lineBlock(tok.line, ["else", "elseif", "end", "until"]);
      let elseBody = null;
      if (at("else") && peek().line === tok.line) {
        next();
        elseBody = lineBlock(tok.line, ["end", "until"]);
      }
      if (at("elseif") && peek().line === tok.line) {
        error("'elseif' is not allowed in the one-line if shorthand; use a full if/then/end");
      }
      if (body.stmts.length === 0 && !elseBody) {
        error("the one-line if shorthand needs a statement on the same line", tok);
      }
      return { kind: "if", clauses: [{ cond, body }], elseBody, line: tok.line, col: tok.col };
    }

    const clauses = [];
    expect("then");
    let body = block(["elseif", "else", "end"]);
    clauses.push({ cond, body });
    let elseBody = null;
    for (;;) {
      if (at("elseif")) {
        next();
        const c = expression();
        expect("then");
        body = block(["elseif", "else", "end"]);
        clauses.push({ cond: c, body });
        continue;
      }
      if (at("else")) {
        next();
        elseBody = block(["end"]);
      }
      break;
    }
    expect("end");
    return { kind: "if", clauses, elseBody, line: tok.line, col: tok.col };
  }

  function whileStmt() {
    const tok = expect("while");
    const parenCond = at("(");
    const cond = expression();
    if (parenCond && !at("do")) {
      // one-line shorthand: `while (cond) stmt`
      if (peek().line !== tok.line || at("eof")) {
        error("expected 'do' (or a same-line statement for the `while (cond) stmt` shorthand)");
        return { kind: "while", cond, body: { kind: "block", stmts: [] }, line: tok.line, col: tok.col };
      }
      const body = lineBlock(tok.line, ["end", "until", "else", "elseif"]);
      return { kind: "while", cond, body, line: tok.line, col: tok.col };
    }
    expect("do");
    const body = block(["end"]);
    expect("end");
    return { kind: "while", cond, body, line: tok.line, col: tok.col };
  }

  function repeatStmt() {
    const tok = expect("repeat");
    const body = block(["until"]);
    expect("until");
    const cond = expression();
    return { kind: "repeat", body, cond, line: tok.line, col: tok.col };
  }

  function forStmt() {
    const tok = expect("for");
    const name = expect("name", "loop variable");
    if (at(",") || at("in")) {
      error("generic 'for ... in' loops are not supported yet; use a numeric for");
      sync(["end", "eof"]);
      if (at("end")) next();
      return null;
    }
    expect("=");
    const from = expression();
    expect(",");
    const to = expression();
    let step = null;
    if (at(",")) { next(); step = expression(); }
    expect("do");
    const body = block(["end"]);
    expect("end");
    return { kind: "fornum", name: name.value, from, to, step, body, line: tok.line, col: tok.col };
  }

  const ASSIGN_OPS = ["=", "+=", "-=", "*=", "/=", "\\=", "%=", "..=", "^="];

  function exprStatement() {
    const tok = peek();
    const target = expression();

    // multiple assignment: a, b = e1, e2
    if (at(",")) {
      const targets = [target];
      while (at(",")) {
        next();
        targets.push(expression());
      }
      const eq = expect("=", "'=' in multiple assignment");
      const values = [expression()];
      while (at(",")) { next(); values.push(expression()); }
      if (values.length !== targets.length) {
        error(`${targets.length} target(s) but ${values.length} value(s)`, eq);
      }
      for (const t of targets) {
        if (t.kind !== "name") error("cannot assign to this expression", eq);
      }
      return { kind: "multiassign", targets, values, line: tok.line, col: tok.col };
    }

    if (ASSIGN_OPS.includes(peek().type)) {
      const op = next();
      if (op.type === "^=") error("'^=' (exponent) is not supported");
      const value = expression();
      if (target.kind !== "name" && target.kind !== "index") {
        error("cannot assign to this expression", op);
      }
      return { kind: "assign", op: op.type, target, value, line: tok.line, col: tok.col };
    }
    if (target.kind === "call") {
      return { kind: "callstmt", call: target, line: tok.line, col: tok.col };
    }
    error("expected a statement (assignment or call)", tok);
    return null;
  }

  // ---- expressions (precedence climbing, Lua 5.3 ladder + P8 ops) ----------

  const BINARY = [
    { ops: ["or"] },
    { ops: ["and"] },
    { ops: ["<", ">", "<=", ">=", "~=", "=="] },
    { ops: ["|"] },
    { ops: ["^^"] },
    { ops: ["&"] },
    { ops: ["<<", ">>", ">>>"] },
    { ops: [".."] },
    { ops: ["+", "-"] },
    { ops: ["*", "/", "\\", "%"] },
  ];

  function expression(level = 0) {
    if (level >= BINARY.length) return unary();
    let left = expression(level + 1);
    while (BINARY[level].ops.includes(peek().type)) {
      const op = next();
      const right = expression(level + 1);
      left = { kind: "binop", op: op.type, left, right, line: op.line, col: op.col };
    }
    return left;
  }

  function unary() {
    const tok = peek();
    if (at("not")) { next(); return { kind: "not", expr: unary(), line: tok.line, col: tok.col }; }
    if (at("-")) { next(); return { kind: "neg", expr: unary(), line: tok.line, col: tok.col }; }
    if (at("~")) { next(); return { kind: "bnot", expr: unary(), line: tok.line, col: tok.col }; }
    if (at("#")) {
      next();
      return { kind: "len", expr: unary(), line: tok.line, col: tok.col };
    }
    if (at("@") || at("$")) {
      error(`'${tok.type}' (memory peek) is not supported`, tok);
      next();
      unary();
      return { kind: "number", value: 0, fixed: 0, isInt: true, line: tok.line, col: tok.col };
    }
    return power();
  }

  function power() {
    const base = suffixed();
    if (at("^")) {
      error("'^' (exponent) is not supported; multiply explicitly or use shifts");
      next();
      unary();
    }
    return base;
  }

  function suffixed() {
    let expr = primary();
    for (;;) {
      if (at(".")) {
        const dot = next();
        const field = expect("name", "field name");
        expr = { kind: "member", object: expr, field: field.value, line: dot.line, col: dot.col };
        continue;
      }
      if (at("(")) {
        const paren = next();
        const args = [];
        if (!at(")")) {
          for (;;) {
            args.push(expression());
            if (at(",")) { next(); continue; }
            break;
          }
        }
        expect(")");
        expr = { kind: "call", callee: expr, args, line: paren.line, col: paren.col };
        continue;
      }
      if (at("[")) {
        const brk = next();
        const index = expression();
        expect("]");
        expr = { kind: "index", object: expr, index, line: brk.line, col: brk.col };
        continue;
      }
      if (at(":")) {
        error("method calls (a:b()) are not supported");
        next();
        if (at("name")) next();
        continue;
      }
      break;
    }
    return expr;
  }

  function primary() {
    const tok = peek();
    switch (tok.type) {
      case "number":
        next();
        return { kind: "number", value: tok.value, fixed: tok.fixed, isInt: tok.isInt, line: tok.line, col: tok.col };
      case "true": next(); return { kind: "bool", value: true, line: tok.line, col: tok.col };
      case "false": next(); return { kind: "bool", value: false, line: tok.line, col: tok.col };
      case "nil":
        next();
        error("nil is not supported (no dynamic typing); initialize with a value", tok);
        return { kind: "number", value: 0, fixed: 0, isInt: true, line: tok.line, col: tok.col };
      case "string":
        next();
        error("strings are not supported yet (print/strings land in a later release)", tok);
        return { kind: "number", value: 0, fixed: 0, isInt: true, line: tok.line, col: tok.col };
      case "name": next(); return { kind: "name", name: tok.value, line: tok.line, col: tok.col };
      case "(": {
        next();
        const e = expression();
        expect(")");
        e.parenthesized = true;
        return e;
      }
      case "{":
        error("table constructors are not supported yet (structs/arrays land in the next release)", tok);
        sync(["}", "eof"]);
        if (at("}")) next();
        return { kind: "number", value: 0, fixed: 0, isInt: true, line: tok.line, col: tok.col };
      case "function":
        error("anonymous functions are not supported (no closures); define a named function at top level", tok);
        sync(["end", "eof"]);
        if (at("end")) next();
        return { kind: "number", value: 0, fixed: 0, isInt: true, line: tok.line, col: tok.col };
      case "?":
        error("'?' print shorthand is not supported yet (print lands with strings)", tok);
        next();
        sync(["eof"]);
        return { kind: "number", value: 0, fixed: 0, isInt: true, line: tok.line, col: tok.col };
      default:
        error(`unexpected '${tok.value || tok.type}' in expression`, tok);
        next();
        return { kind: "number", value: 0, fixed: 0, isInt: true, line: tok.line, col: tok.col };
    }
  }

  const chunk = block(["eof"]);
  return { chunk, diagnostics };
}
