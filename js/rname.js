const SYNTACTIC = /^((([A-Za-z]|[.][A-Za-z._])[A-Za-z0-9._]*)|[.])$/;
const RESERVED = new Set([
  'if', 'else', 'repeat', 'while', 'function', 'for', 'in', 'next', 'break', 'TRUE', 'FALSE',
  'NULL', 'Inf', 'NaN', 'NA', 'NA_integer_', 'NA_real_', 'NA_character_', 'NA_complex_',
]);

/** An R object name as code: backquoted unless it is syntactic. */
export function rName(name) {
  if (SYNTACTIC.test(name) && !RESERVED.has(name)) return name;
  return `\`${name.replace(/\\/g, '\\\\').replace(/`/g, '\\`')}\``;
}
