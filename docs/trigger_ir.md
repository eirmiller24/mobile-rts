# Trigger IR — the compiled-program contract

*The wire format between the GDScript `TriggerCompiler` (outside the sim wall)
and the C++ trigger VM (inside it).* design_m5.md §3.1–3.2: a map ships a
Lua-flavored script, compiled to a **flat, interned, typed program** — arrays of
tagged int records plus constant pools, *not* a pointer graph — that the C++ VM
walks. This doc freezes the encoding so the two implementations stay in lockstep.

The program is produced as a `TriggerProgram` (GDScript RefCounted, plain-data
fields below) and handed to the native sim at construction, exactly like the
compiled catalog and map data. Its `hash_value` folds into the initial state
hash (design_m5.md §3.9, §4.1), so a tampered program desyncs at tick 0.

## Enums (mirrored byte-for-byte in `trigger_ir.gd` and `native/src/sim/trigger_ir.h`)

### TriggerType — the typed value kinds (§3.6)
```
0  VOID       8  REGION        16 RELATION
1  INT        9  GROUP         17 BUILD_STATE
2  FIXED      10 TRIGGER       18 COMPARE_DIR
3  BOOL       11 TIMER         19 FILTER
4  STRING     12 UNITTYPE
5  UNIT       13 ABILITYTYPE
6  PLAYER     14 STANCE
7  POINT      15 RESOURCE
```
`INT`/`FIXED` are the only numeric types — there is no float (the constitution).
`UNIT`/`PLAYER`/`REGION`/`TRIGGER`/`TIMER` are ids (a dead `UNIT` reads `null`,
i.e. id 0). `STANCE`/`RESOURCE`/`RELATION`/`BUILD_STATE`/`COMPARE_DIR` are int
enums kept distinct for typechecking. `POINT` carries two `FIXED` (x, y).
`GROUP` is an ordered id list. `STRING` is a constant-pool index, presentation
only, never hashed.

### NodeOp — the AST node tags
Expressions (produce a value):
```
LIT_INT    a=ints[] index                       -> INT
LIT_FIXED  a=ints[] index                        -> FIXED
LIT_BOOL   a=0|1                                  -> BOOL
LIT_NULL   (type in t)                            -> ref type / null
LIT_STR    a=strings[] index                      -> STRING
CONST      a=int value (enums, players)           -> t
GLOBAL_GET a=global id                            -> t
LOCAL_GET  a=local slot                           -> t
UNOP       a=operand node, b=UnOp                 -> t
BINOP      a=lhs node, b=rhs node, c=BinOp        -> t   (AND/OR short-circuit)
CALL       a=function id, b=list off, c=count     -> t   (user function)
BUILTIN    a=builtin id, b=list off, c=count      -> t   (registry call)
```
Statements (produce an effect):
```
BLOCK         a=list off, b=count                 (statement sequence)
LOCAL_DECL    a=slot, b=init node|-1
ASSIGN_LOCAL  a=slot, b=value node
ASSIGN_GLOBAL a=global id, b=value node
IF            a=cond node, b=then node, c=else node|-1
WHILE         a=cond node, b=body node
FOR_NUM       a=loop slot, b=list off, c=4  (list=[start,end,step,body])
FOR_EACH      a=group node, b=loop slot, c=body node
BREAK
RETURN        a=value node|-1
EXPR_STMT     a=expr node                          (call used for effect)
WAIT          a=duration node (INT ticks)          (suspends; event bodies only)
```

`UnOp`: `0 NEG`, `1 NOT`.
`BinOp`: `0 ADD 1 SUB 2 MUL 3 DIV 4 MOD 5 EQ 6 NE 7 LT 8 LE 9 GT 10 GE 11 AND 12 OR`.

### EventKind — what registers a handler (§5, catalog §3)
```
0 MATCH_START      3 TIMER_EXPIRES        6 UNIT_DIES
1 MAP_INIT         4 UNIT_ENTERS_REGION   7 STRUCTURE_COMPLETES
2 EVERY            5 UNIT_LEAVES_REGION    8 UNIT_CREATED
```
Event record fields `p0`/`p1` carry the event's static operands: `EVERY` uses
`p0`=period in ticks; region events use `p0`=region id; the rest are 0. A
`filter` (builtin filter id or -1) lives in its own slot.

## TriggerProgram fields (plain data, read by the native loader via `Object.get`)

| Field | Type | Meaning |
|---|---|---|
| `nodes` | `PackedInt32Array` | node table, stride 6: `[op, type, a, b, c, d]` |
| `lists` | `PackedInt32Array` | pooled node-index lists (arg lists, block bodies) |
| `ints` | `PackedInt64Array` | int + fixed literal constants (64-bit preserved) |
| `strings` | `PackedStringArray` | string constant pool (presentation only) |
| `globals` | `PackedInt32Array` | stride 2: `[type, init_node\|-1]`; index = global id |
| `functions` | `PackedInt32Array` | stride 4: `[param_count, local_count, ret_type, body_node]` |
| `events` | `PackedInt32Array` | stride 6: `[kind, p0, p1, filter, body_node, local_count]` |
| `hash_value` | `int` | SimHash over the compiled program (folds into state) |

A node reference is an index into `nodes` (×6 gives the record base), or -1 for
"none". A list reference is `(off, count)` into `lists`; each entry there is a
node index. Globals are zero-initialized by type at construction, then any
`init_node` runs once during `MAP_INIT` setup order (ascending global id).

## Execution model recap (design_m5.md §3.7), as the VM honors it

- One **event activation** = a frame of `local_count` typed slots (params first)
  plus an explicit continuation stack, so a `WAIT` can suspend it mid-control-flow
  with locals hashed and resume on a future tick.
- **User functions** run synchronously (recursive), bounded by a call-depth cap;
  they may not contain `WAIT` (compiler-enforced) — so no host-stack frame is ever
  live across a suspension.
- **Op budget**: every node evaluation/step decrements a per-tick op counter;
  overrun kills the running trigger with a diagnostic, never hangs.
- **Ordering**: handlers for one event run in ascending event index; one event
  firing for many entities runs ascending entity id; same-tick `WAIT` resumes run
  ascending suspended-id. All trigger state (globals, frames/locals, instance
  data, timers, on/off flags, wait context) is in `state_hash()`.
