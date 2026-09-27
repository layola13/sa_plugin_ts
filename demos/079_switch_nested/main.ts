function main(): i32 {
  let t: i32 = 0;
  switch (1) {
    case 1: {
      switch (2) {
        case 2: { t = 5; break; }
        default: { t = 6; }
      }
      break;
    }
    default: { t = 0; }
  }
  return t;
}
