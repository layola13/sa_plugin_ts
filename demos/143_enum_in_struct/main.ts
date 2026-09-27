enum State { Idle, Busy }
interface Ctx { state: i32; id: i32; }
function main(): i32 {
  const c: Ctx = { state: 1, id: 2 };
  return c.state;
}
