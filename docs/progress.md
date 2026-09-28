# sa_plugin_ts 进度（TheAlgorithms/TypeScript 数据结构库）

> 目标：`sa ts lower` 零诊断 + `sa check` 通过，跑通 Talgo 数据结构库。
> 基线：2026-09-28，commit `43a8bab` + 未提交的 parser.zig 半截工程（pending_arrow_bind / class_parent / default_src）。
> 判定标准：`PASS` = lower 零诊断且 check 通过；其余为失败并附首个错误。

## 总览（20 文件：19 数据结构 + stack_queue）

| # | 文件 | 状态 | 首个错误 / 备注 |
|---|------|------|-----------------|
| 1 | map/map.ts | PASS | — |
| 2 | map/hash_map.ts | PASS | — |
| 3 | queue/queue.ts | PASS | — |
| 4 | set/set.ts | PASS | — |
| 5 | list/linked_list.ts | PASS | — |
| 6 | queue/array_queue.ts | CHECK-FAIL | `ForbiddenSyntax: invalid call syntax` in `@ArrayQueue_dequeue` |
| 7 | list/singly_linked_list.ts | CHECK-FAIL | `ForbiddenSyntax: invalid call syntax` in `@SinglyLinkedList_pop` |
| 8 | queue/linked_queue.ts | CHECK-FAIL | `ForbiddenSyntax: invalid call syntax` in `@LinkedQueue_dequeue` |
| 9 | list/doubly_linked_list.ts | CHECK-FAIL | `CapabilityMismatch` in `@DoublyLinkedList_push` |
| 10 | set/map_set.ts | CHECK-FAIL | `UnknownRegister: callee is not declared` in `@MapSet_ctor` |
| 11 | stack/stack.ts | CHECK-FAIL | `RegisterRedefinition` in `@Stack_ctor(limit)`（默认参数 prologue 重复定义？） |
| 12 | tries/tries.ts | CHECK-FAIL | `FallthroughForbidden` 在 `@export sa_btree_map_range`（extern 声明被当函数体 lower？） |
| 13 | tree/binary_search_tree.ts | LOWER-ERR | `179:26 unexpected colon`：`preOrderTraversal(array: T[] = [])` 方法声明冒号（inOrder 同形却只报 179/206，需查前文箭头/三元恢复） |
| 14 | queue/circular_queue.ts | LOWER-ERR | `17:28 new 'Array' length must be an integer literal`（`new Array(size)` 动态长度）+ `28:15 colon`（`enqueue(item: T)`） |
| 15 | disjoint_set/disjoint_set.ts | LOWER-FAIL | `26:44 unexpected '_'`：`Array.from({length:n}, (_, index) => index)` 回调 `_` 参数 + `Array(n).fill(1)` |
| 16 | set/hash_map_set.ts | LOWER-ERR | `class extends is not supported yet`（`extends MapSet` 跨文件父类 + `protected` + 抽象 `initMap`） |
| 17 | heap/heap.ts | LOWER-ERR | `class extends is not supported yet` ×3（Min/MaxHeap/PriorityQueue + `super()`/`super.m()` + fn 字段 `this.compare` 间接调用） |
| 18 | stack/linked_list_stack.ts | LOWER-ERR | `new of unknown type 'SinglyLinkedList'`（跨文件 import 类）+ `26:10` 泛型 colon |
| 19 | queue/stack_queue.ts | LOWER-ERR | `new of unknown type 'Stack'`（同上跨文件 new）+ `property access on undefined variable 'this'` |
| 20 | tree/binary_search_tree.ts | 见 #13 | — |

## PASS：5/20；lower 通过：13/20

## 修复优先级（JEV jev_rank，ROI）

1. BST 方法内自递归箭头 + 可选参数/默认参数（`const traverse = (node?: TreeNode<T>, array: T[] = []) =>`，pending-bind 预注册半截子工程在 parser.zig 未提交部分）。
2. 动态 `new Array(n)`（`array_elem_hint` 已有字段，需让 alloc 接受寄存器尺寸；抄 `sa_plugin_sla` 对应逻辑）。
3. `Array.from` / `Array(n).fill` / `_` 占位参数。
4. `extends` copy-down（布局前缀父字段 + 方法体 slice 重解析，`body_src` 字段已加；`super()` 内联父 ctor；`super.m()` 静态调父版本）。
5. 跨文件 import 类的 `new`（whole-program rel-import 已有，需查类注册表）。
6. CHECK-FAIL 六件套（多为 check 端能力/调用约定问题：ForbiddenSyntax、CapabilityMismatch、UnknownRegister、RegisterRedefinition、FallthroughForbidden）。

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
