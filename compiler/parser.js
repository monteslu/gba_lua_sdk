// gtlua parser — recursive descent over the token stream, producing a plain
// object AST. Cut Lua features fail HERE with the diagnostic the spec
// promises, not with a generic syntax error, wherever we can see them coming.

/**
 * @typedef {import('./lexer.js').Token} Token
 * @typedef {{file:string,line:number,col:number,severity:string,message:string}} Diagnostic
 */

export function parse(tokens, file) {
  let pos = 0;
  /** @type {Diagnostic[]} */
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

  // Skip tokens until one of the given types (error recovery).
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
      if (pos === before) pos++; // never wedge
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
        if (!at("end") && !at("eof") && !at("else") && !at("elseif") && !at("until")) {
          value = expression();
          if (at(",")) error("multiple return values are not supported yet");
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
        error("goto is not supported");
        sync(["end", "eof"]);
        return null;
      default:
        return exprStatement();
    }
  }

  function localStmt() {
    const tok = expect("local");
    if (at("function")) {
      // `local function f()` — accept, same as `function f()` in our model
      next();
      return functionBody(expect("name", "function name"), tok);
    }
    const name = expect("name", "variable name");
    if (at(",")) {
      error("multiple assignment is not supported yet; declare one variable per 'local'");
      sync(["=", "local", "function", "eof"]);
    }
    let init = null;
    if (at("=")) { next(); init = expression(); }
    return { kind: "local", name: name.value, init, line: tok.line, col: tok.col };
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
        if (at(".")) { // `...`
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
    return {
      kind: "function", name: nameTok.value, params, body,
      line: tok.line, col: tok.col,
    };
  }

  function ifStmt() {
    const tok = expect("if");
    const clauses = [];
    let cond = expression();
    expect("then");
    let body = block(["elseif", "else", "end"]);
    clauses.push({ cond, body });
    let elseBody = null;
    for (;;) {
      if (at("elseif")) {
        next();
        cond = expression();
        expect("then");
        body = block(["elseif", "else", "end"]);
        clauses.push({ cond, body });
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
    const cond = expression();
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

  function exprStatement() {
    const tok = peek();
    const target = expression();
    if (at("=") || at("+=") || at("-=") || at("*=") || at("//=") || at("/=") || at("%=")) {
      const op = next();
      if (op.type === "/=") {
        error("'/=' is not supported (no general division); use '//=' with a power-of-two constant");
      }
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

  // ---- expressions (precedence climbing) -----------------------------------

  const BINARY = [
    { ops: ["or"], },
    { ops: ["and"], },
    { ops: ["<", ">", "<=", ">=", "~=", "=="], },
    { ops: [".."], },
    { ops: ["+", "-"], },
    { ops: ["*", "/", "//", "%"], },
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
    if (at("#")) {
      next();
      error("'#' (length) is not supported yet", tok);
      return { kind: "number", value: 0, line: tok.line, col: tok.col };
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
      case "number": next(); return { kind: "number", value: tok.value, line: tok.line, col: tok.col };
      case "true": next(); return { kind: "bool", value: true, line: tok.line, col: tok.col };
      case "false": next(); return { kind: "bool", value: false, line: tok.line, col: tok.col };
      case "nil":
        next();
        error("nil is not supported (no dynamic typing); initialize with a value", tok);
        return { kind: "number", value: 0, line: tok.line, col: tok.col };
      case "string":
        next();
        error("strings are not supported yet (the text API lands in a later release)", tok);
        return { kind: "number", value: 0, line: tok.line, col: tok.col };
      case "name": next(); return { kind: "name", name: tok.value, line: tok.line, col: tok.col };
      case "(": {
        next();
        const e = expression();
        expect(")");
        return e;
      }
      case "{":
        error("table constructors are not supported yet (structs/arrays land in a later release)", tok);
        sync(["}", "eof"]);
        if (at("}")) next();
        return { kind: "number", value: 0, line: tok.line, col: tok.col };
      case "function":
        error("anonymous functions are not supported (no closures); define a named function at top level", tok);
        sync(["end", "eof"]);
        if (at("end")) next();
        return { kind: "number", value: 0, line: tok.line, col: tok.col };
      default:
        error(`unexpected '${tok.value || tok.type}' in expression`, tok);
        next();
        return { kind: "number", value: 0, line: tok.line, col: tok.col };
    }
  }

  const chunk = block(["eof"]);
  return { chunk, diagnostics };
}
