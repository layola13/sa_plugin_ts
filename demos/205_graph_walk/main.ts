function main(): i32 {
  const nodes: i32[] = [0, 1, 2, 3];
  let visited: i32 = 0;
  for (const n of nodes) { visited = visited + 1; }
  return visited;
}
