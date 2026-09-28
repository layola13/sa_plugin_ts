# sa_plugin_ts 进度（TheAlgorithms/TypeScript 数据结构库）

> 目标：`sa ts lower` 零诊断 + `sa check` 通过，跑通 Talgo 数据结构库。
> 基线：2026-09-28，commit `43a8bab` + 未提交的 parser.zig 半截工程（pending_arrow_bind / class_parent / default_src）。
> 判定标准：`PASS` = lower 零诊断且 check 通过；其余为失败并附首个错误。

## 总览（19 文件）

| # | Talgo 源文件 | sweep 输入 / 输出 | 状态 | 首个错误 / 备注 |
|---|---|---|---|---|
| 1 | /tmp/talgo/data_structures/map/map.ts | /tmp/talgo_sweep/map.nolink.ts → /tmp/talgo_sweep/map.sai | PASS | — |
| 2 | /tmp/talgo/data_structures/map/hash_map.ts | /tmp/talgo_sweep/hash_map.nolink.ts → /tmp/talgo_sweep/hash_map.sai | PASS | — |
| 3 | /tmp/talgo/data_structures/queue/queue.ts | /tmp/talgo_sweep/queue.nolink.ts → /tmp/talgo_sweep/queue.sai | PASS | — |
| 4 | /tmp/talgo/data_structures/set/set.ts | /tmp/talgo_sweep/set.nolink.ts → /tmp/talgo_sweep/set.sai | PASS | — |
| 5 | /tmp/talgo/data_structures/list/linked_list.ts | /tmp/talgo_sweep/linked_list.nolink.ts → /tmp/talgo_sweep/linked_list.sai | PASS | — |
| 6 | /tmp/talgo/data_structures/queue/array_queue.ts | /tmp/talgo_sweep/array_queue.nolink.ts → /tmp/talgo_sweep/array_queue.sai | PASS | — |
| 7 | /tmp/talgo/data_structures/list/singly_linked_list.ts | /tmp/talgo_sweep/singly_linked_list.nolink.ts → /tmp/talgo_sweep/singly_linked_list.sai | PASS | — |
| 8 | /tmp/talgo/data_structures/queue/linked_queue.ts | /tmp/talgo_sweep/linked_queue.nolink.ts → /tmp/talgo_sweep/linked_queue.sai | PASS | — |
| 9 | /tmp/talgo/data_structures/list/doubly_linked_list.ts | /tmp/talgo_sweep/doubly_linked_list.nolink.ts → /tmp/talgo_sweep/doubly_linked_list.sai | CHECK-FAIL | `CapabilityMismatch` in `@DoublyLinkedList_push` |
| 10 | /tmp/talgo/data_structures/set/map_set.ts | /tmp/talgo_sweep/map_set.nolink.ts → /tmp/talgo_sweep/map_set.sai | CHECK-FAIL | `UnknownRegister: callee is not declared` in `@MapSet_ctor` |
| 11 | /tmp/talgo/data_structures/stack/stack.ts | /tmp/talgo_sweep/stack.nolink.ts → /tmp/talgo_sweep/stack.sai | PASS | prologue 改 emitMove 后通过 |
| 12 | /tmp/talgo/data_structures/tries/tries.ts | /tmp/talgo_sweep/tries.nolink.ts → /tmp/talgo_sweep/tries.sai | CHECK-FAIL | `FallthroughForbidden` 在 `@export sa_btree_map_range`（extern 声明被当函数体 lower？） |
| 13 | /tmp/talgo/data_structures/tree/binary_search_tree.ts | /tmp/talgo_sweep/binary_search_tree.nolink.ts → /tmp/talgo_sweep/binary_search_tree.sai | PASS | 箭头参数 `[]` 后缀 + self_call 免释放 + 短调用补0 + panic(1) + while(true) + prologue move |
| 14 | /tmp/talgo/data_structures/queue/circular_queue.ts | /tmp/talgo_sweep/circular_queue.nolink.ts → /tmp/talgo_sweep/circular_queue.sai | PASS | 动态 `new Array(size)` 经 mem_set 补齐 |
| 15 | /tmp/talgo/data_structures/disjoint_set/disjoint_set.ts | /tmp/talgo_sweep/disjoint_set.nolink.ts → /tmp/talgo_sweep/disjoint_set.sai | LOWER-ERR | `Array.from`/`Array(n).fill` 已通；残留 `;[a,b]=[b,a]` 解构、`arr[i] +=`、裸 `return` 后 `if` |
| 16 | /tmp/talgo/data_structures/set/hash_map_set.ts | /tmp/talgo_sweep/hash_map_set.nolink.ts → /tmp/talgo_sweep/hash_map_set.sai | LOWER-ERR | `class extends is not supported yet`（`extends MapSet` 跨文件父类 + `protected` + 抽象 `initMap`） |
| 17 | /tmp/talgo/data_structures/heap/heap.ts | /tmp/talgo_sweep/heap.nolink.ts → /tmp/talgo_sweep/heap.sai | LOWER-ERR | `class extends is not supported yet` ×3（Min/MaxHeap/PriorityQueue + `super()`/`super.m()` + fn 字段 `this.compare` 间接调用） |
| 18 | /tmp/talgo/data_structures/stack/linked_list_stack.ts | /tmp/talgo_sweep/linked_list_stack.nolink.ts → /tmp/talgo_sweep/linked_list_stack.sai | LOWER-ERR | `new of unknown type 'SinglyLinkedList'`（跨文件 import 类）+ `26:10` 泛型 colon |
| 19 | /tmp/talgo/data_structures/queue/stack_queue.ts | /tmp/talgo_sweep/stack_queue.nolink.ts → /tmp/talgo_sweep/stack_queue.sai | LOWER-ERR | `new of unknown type 'Stack'`（同上跨文件 new）+ `property access on undefined variable 'this'` |

## PASS：11/19；lower 通过：14/19

## 修复优先级（JEV jev_rank，ROI）

1. BST 方法内自递归箭头 + 可选参数/默认参数（`const traverse = (node?: TreeNode<T>, array: T[] = []) =>`，pending-bind 预注册半截子工程在 parser.zig 未提交部分）。
2. 动态 `new Array(n)`（`array_elem_hint` 已有字段，需让 alloc 接受寄存器尺寸；抄 `sa_plugin_sla` 对应逻辑）。
3. `Array.from` / `Array(n).fill` / `_` 占位参数。
4. `extends` copy-down（布局前缀父字段 + 方法体 slice 重解析，`body_src` 字段已加；`super()` 内联父 ctor；`super.m()` 静态调父版本）。
5. 跨文件 import 类的 `new`（whole-program rel-import 已有，需查类注册表）。
6. CHECK-FAIL 七件套（多为 check 端能力/调用约定问题：ForbiddenSyntax、CapabilityMismatch、UnknownRegister、RegisterRedefinition、FallthroughForbidden）。

## 已定设计（勿推翻）

- 缺省参数：`saveBalancedDefault()` 存 slice → 被调者 prologue 用 `emitDefaultPrologue` 回放；调用点补 `0`（`0` 即 missing 近似）。
- `extends`：copy-down + `super()` 内联 + `super.m()` 静态调父版本。
- fn 值：`r = @func` 合法；`call_indirect` 间接调用；捕获箭头流入 fn 槽位 loud refuse（`captureless_cb` 表）。
- `new` 降级 trait；全盘抄 `sa_plugin_sla`（类/`extends`/`?.` 自研部分除外）。
- 优先级：new > async > try/catch；有困难找 JEV（`jev_rank`/`jev_diagnose`）。

## 复现

```bash
export SA_PLUGINS_PATH=/content/sa_all/sa_plugin_ts/zig-out/lib SA_PLUGIN_DEV=1
SA=/content/sa_all/sci/zig-out/bin/sa
timeout 25 $SA ts lower /tmp/talgo_sweep/<base>.nolink.ts -o /tmp/talgo_sweep/<base>.sai
timeout 30 $SA check /tmp/talgo_sweep/<base>.sai
bash /tmp/talgo_sweep/full.sh <file>   # lower only
bash /tmp/talgo_sweep/check.sh <base>  # check only
```
