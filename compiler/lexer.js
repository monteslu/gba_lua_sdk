// gtlua lexer — Lua 5.4 surface tokens for the gtlua subset, plus the
// PICO-8 compound-assignment sugar (+= -= *= //=).

const KEYWORDS = new Set([
  "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
  "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
  "true", "until", "while", "goto",
]);

/**
 * @typedef {{type: string, value: string|number, line: number, col: number}} Token
 */

/**
 * Tokenize gtlua source.
 * @param {string} src
 * @param {string} file file name used in diagnostics
 * @returns {{tokens: Token[], diagnostics: import('./diagnostics.js').Diagnostic[]}}
 */
export function lex(src, file) {
  const tokens = [];
  const diagnostics = [];
  let i = 0, line = 1, col = 1;

  const err = (msg) => diagnostics.push({ file, line, col, severity: "error", message: msg });
  const push = (type, value, l = line, c = col) => tokens.push({ type, value, line: l, col: c });

  const isDigit = (ch) => ch >= "0" && ch <= "9";
  const isHex = (ch) => isDigit(ch) || (ch >= "a" && ch <= "f") || (ch >= "A" && ch <= "F");
  const isNameStart = (ch) => /[A-Za-z_]/.test(ch);
  const isName = (ch) => /[A-Za-z0-9_]/.test(ch);

  function advance(n = 1) {
    while (n-- > 0) {
      if (src[i] === "\n") { line++; col = 1; } else { col++; }
      i++;
    }
  }

  while (i < src.length) {
    const ch = src[i];

    if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n") { advance(); continue; }

    // comments: -- line, --[[ block ]]
    if (ch === "-" && src[i + 1] === "-") {
      if (src[i + 2] === "[" && src[i + 3] === "[") {
        const end = src.indexOf("]]", i + 4);
        if (end === -1) { err("unterminated block comment"); i = src.length; break; }
        advance(end + 2 - i);
      } else {
        while (i < src.length && src[i] !== "\n") advance();
      }
      continue;
    }

    const startLine = line, startCol = col;

    if (isDigit(ch)) {
      let text = "";
      if (ch === "0" && (src[i + 1] === "x" || src[i + 1] === "X")) {
        advance(2);
        while (i < src.length && isHex(src[i])) { text += src[i]; advance(); }
        if (text === "") err("malformed hex literal");
        push("number", parseInt(text || "0", 16), startLine, startCol);
      } else {
        while (i < src.length && isDigit(src[i])) { text += src[i]; advance(); }
        if (src[i] === ".") {
          // fractional literal — fixed-point is v0.2; refuse loudly, not silently
          while (i < src.length && (isDigit(src[i]) || src[i] === ".")) advance();
          diagnostics.push({
            file, line: startLine, col: startCol, severity: "error",
            message: "fractional numbers (16.16 fixed point) are not supported yet; use integers",
          });
          push("number", 0, startLine, startCol);
        } else {
          push("number", parseInt(text, 10), startLine, startCol);
        }
      }
      continue;
    }

    if (isNameStart(ch)) {
      let text = "";
      while (i < src.length && isName(src[i])) { text += src[i]; advance(); }
      push(KEYWORDS.has(text) ? text : "name", text, startLine, startCol);
      continue;
    }

    if (ch === '"' || ch === "'") {
      const quote = ch;
      advance();
      let text = "";
      while (i < src.length && src[i] !== quote && src[i] !== "\n") { text += src[i]; advance(); }
      if (src[i] !== quote) err("unterminated string");
      else advance();
      push("string", text, startLine, startCol);
      continue;
    }

    // multi-char operators, longest first
    const three = src.slice(i, i + 3);
    const two = src.slice(i, i + 2);
    if (three === "//=") { push("//=", three, startLine, startCol); advance(3); continue; }
    if (["==", "~=", "<=", ">=", "..", "//", "+=", "-=", "*=", "/=", "%="].includes(two)) {
      push(two, two, startLine, startCol); advance(2); continue;
    }
    if ("+-*/%^#<>=(){}[];:,.".includes(ch)) {
      push(ch, ch, startLine, startCol); advance(); continue;
    }

    err(`unexpected character '${ch}'`);
    advance();
  }

  push("eof", "", line, col);
  return { tokens, diagnostics };
}
