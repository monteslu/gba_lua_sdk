// gtlua compiler entry — source text in, C text (or diagnostics) out.

import { lex } from "./lexer.js";
import { parse } from "./parser.js";
import { check } from "./check.js";
import { emit } from "./emit.js";

/**
 * @typedef {{file:string,line:number,col:number,severity:"error"|"warning",message:string}} Diagnostic
 */

/**
 * Compile gtlua source to C.
 * @param {string} source
 * @param {string} file name used in diagnostics
 * @returns {{ok: boolean, c: string|null, diagnostics: Diagnostic[]}}
 */
export function compile(source, file = "main.lua") {
  const { tokens, diagnostics: lexDiags } = lex(source, file);
  const { chunk, diagnostics: parseDiags } = parse(tokens, file);
  const diagnostics = [...lexDiags, ...parseDiags];

  // Don't typecheck a broken parse — the errors would be noise.
  if (diagnostics.some((d) => d.severity === "error")) {
    return { ok: false, c: null, diagnostics };
  }

  const { diagnostics: checkDiags, symbols } = check(chunk, file);
  diagnostics.push(...checkDiags);
  if (diagnostics.some((d) => d.severity === "error")) {
    return { ok: false, c: null, diagnostics };
  }

  return { ok: true, c: emit(chunk, symbols, file), diagnostics };
}

/** Render diagnostics the way compilers do: file:line:col: severity: message */
export function formatDiagnostics(diagnostics) {
  return diagnostics
    .map((d) => `${d.file}:${d.line}:${d.col}: ${d.severity}: ${d.message}`)
    .join("\n");
}
