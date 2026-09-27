interface Bundle { version: i32; files: i32; }
function main(): i32 {
  const b: Bundle = { version: 2, files: 12 };
  let t: i32 = 0;
  for (let i: i32 = 0; i < b.files; i = i + 2) { t = t + 1; }
  return t + b.version;
}
