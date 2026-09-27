import { readFile } from "fs";
interface Cfg { path: string; retries: i32; }
function main(): i32 {
  const c: Cfg = { path: `x`, retries: 2 };
  const d: string = readFile(c.path);
  return c.retries;
}
