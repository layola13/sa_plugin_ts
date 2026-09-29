function main(): i32 {
  const s = String.fromCharCode(65);
  const t = String.fromCharCode(66);
  return s.charCodeAt(0) * 100 + t.charCodeAt(0) + s.length + t.length;
}
