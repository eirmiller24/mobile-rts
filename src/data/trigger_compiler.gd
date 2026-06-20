class_name TriggerCompiler
extends RefCounted
## Compiles a Lua-flavored trigger script to the flat interned TriggerProgram the
## C++ VM walks (design_m5.md §3.9, docs/trigger_ir.md). Runs entirely outside the
## determinism wall, at load time: lex -> parse -> resolve -> typecheck+emit. It
## refuses bad input loudly (unknown call, type mismatch, float literal in int
## math, undefined name, cyclic types) with a line-tagged error, never mid-match.
##
## Pipeline:
##   var prog := TriggerCompiler.compile(source, catalog, regions)
##   if not prog.ok(): push the errors
## `regions` is { name: int region_id } resolved from the map's objects.json.

const I := preload("res://src/data/trigger_ir.gd")
const Reg := preload("res://src/data/trigger_registry.gd")
const Lex := preload("res://src/data/trigger_lexer.gd")

# null's internal "compatible with any ref type" sentinel (not a real T_*).
const NULL_T := -2

var _tok: Array[Dictionary] = []
var _p := 0
var _errors := PackedStringArray()

var _catalog: CompiledCatalog
var _regions := {}
var _builtins := {}

# Resolved decl tables (filled by the resolve pass).
var _globals := {}    # name -> {id, type}
var _funcs := {}      # name -> {id, params:Array[int], ret:int}
var _ast_globals: Array = []
var _ast_funcs: Array = []
var _ast_events: Array = []

# Program-under-construction.
var _prog: TriggerProgram


static func compile(source: String, catalog: CompiledCatalog,
		regions: Dictionary = {}) -> TriggerProgram:
	var c := TriggerCompiler.new()
	return c._compile(source, catalog, regions)


func _compile(source: String, catalog: CompiledCatalog, regions: Dictionary) -> TriggerProgram:
	_catalog = catalog
	_regions = regions
	_builtins = Reg.builtins()
	_prog = TriggerProgram.new()

	var lex := Lex.tokenize(source)
	if not lex.errors.is_empty():
		_prog.errors = lex.errors
		return _prog
	_tok = lex.tokens

	_parse_program()
	if not _errors.is_empty():
		_prog.errors = _errors
		return _prog

	_resolve()
	if not _errors.is_empty():
		_prog.errors = _errors
		return _prog

	_emit()
	_prog.errors = _errors
	if _errors.is_empty():
		_prog.rehash()
	return _prog


# ---------------------------------------------------------------------------
# Token helpers
# ---------------------------------------------------------------------------
func _cur() -> Dictionary:
	return _tok[_p]


func _line() -> int:
	return _tok[_p]["line"]


func _err(msg: String) -> void:
	_errors.append("line %d: %s" % [_line(), msg])


func _at_eof() -> bool:
	return _tok[_p]["t"] == Lex.T_EOF


func _is_kw(w: String) -> bool:
	var t: Dictionary = _tok[_p]
	return t["t"] == Lex.T_KEYWORD and t["v"] == w


func _is_op(o: String) -> bool:
	var t: Dictionary = _tok[_p]
	return t["t"] == Lex.T_OP and t["v"] == o


func _advance() -> Dictionary:
	var t: Dictionary = _tok[_p]
	if _p < _tok.size() - 1:
		_p += 1
	return t


func _expect_op(o: String) -> void:
	if _is_op(o):
		_advance()
	else:
		_err("expected '%s'" % o)
		_advance()


func _expect_kw(w: String) -> void:
	if _is_kw(w):
		_advance()
	else:
		_err("expected '%s'" % w)


func _expect_name() -> String:
	var t: Dictionary = _tok[_p]
	if t["t"] == Lex.T_NAME:
		_advance()
		return t["v"]
	_err("expected a name")
	_advance()
	return ""


func _parse_type() -> int:
	var t: Dictionary = _tok[_p]
	if t["t"] == Lex.T_NAME and I.TYPE_KEYWORDS.has(t["v"]):
		_advance()
		return I.TYPE_KEYWORDS[t["v"]]
	_err("expected a type name, got '%s'" % t["v"])
	_advance()
	return I.T_VOID


# ---------------------------------------------------------------------------
# Parser — top level
# ---------------------------------------------------------------------------
func _parse_program() -> void:
	while not _at_eof() and _errors.is_empty():
		if _is_kw("globals"):
			_parse_globals_block()
		elif _is_kw("function"):
			_parse_function()
		elif _is_kw("on"):
			_parse_event()
		else:
			_err("expected 'globals', 'function', or 'on', got '%s'" % str(_cur()["v"]))
			return


func _parse_globals_block() -> void:
	_expect_kw("globals")
	while not _is_kw("end") and not _at_eof() and _errors.is_empty():
		var name := _expect_name()
		_expect_op(":")
		var type := _parse_type()
		var init = null
		if _is_op("="):
			_advance()
			init = _parse_expr()
		_ast_globals.append({"name": name, "type": type, "init": init})
	_expect_kw("end")


func _parse_function() -> void:
	_expect_kw("function")
	var name := _expect_name()
	var params := _parse_params()
	var ret := I.T_VOID
	if _is_op("->"):
		_advance()
		ret = _parse_type()
	var body := _parse_block()
	_expect_kw("end")
	_ast_funcs.append({"name": name, "params": params, "ret": ret,
			"body": body, "line": _line()})


func _parse_params() -> Array:
	var params: Array = []
	_expect_op("(")
	if not _is_op(")"):
		while true:
			var pname := _expect_name()
			_expect_op(":")
			var ptype := _parse_type()
			params.append({"name": pname, "type": ptype})
			if _is_op(","):
				_advance()
			else:
				break
	_expect_op(")")
	return params


func _parse_event() -> void:
	_expect_kw("on")
	var ev_name := _expect_name()
	if not I.EVENT_KEYWORDS.has(ev_name):
		_err("unknown event '%s'" % ev_name)
		return
	var kind: int = I.EVENT_KEYWORDS[ev_name]
	var p0 := 0
	var p1 := 0
	# Static operand: every(duration) | region events(region name).
	if _is_op("("):
		_advance()
		if kind == I.EV_EVERY:
			var t: Dictionary = _tok[_p]
			if t["t"] == Lex.T_DURATION or t["t"] == Lex.T_INT:
				p0 = t["v"]
				_advance()
			else:
				_err("every(...) needs a duration like 30s")
		elif kind == I.EV_UNIT_ENTERS_REGION or kind == I.EV_UNIT_LEAVES_REGION:
			var rname := _expect_name()
			if _regions.has(rname):
				p0 = _regions[rname]
			else:
				_err("unknown region '%s'" % rname)
		_expect_op(")")
	var body := _parse_block()
	_expect_kw("end")
	_ast_events.append({"kind": kind, "p0": p0, "p1": p1, "body": body,
			"index": _ast_events.size()})


# ---------------------------------------------------------------------------
# Parser — statements
# ---------------------------------------------------------------------------
func _block_terminator() -> bool:
	return _is_kw("end") or _is_kw("elseif") or _is_kw("else") or _at_eof()


func _parse_block() -> Array:
	var stmts: Array = []
	while not _block_terminator() and _errors.is_empty():
		stmts.append(_parse_statement())
	return stmts


func _parse_statement() -> Dictionary:
	var line := _line()
	if _is_kw("local"):
		return _parse_local()
	if _is_kw("if"):
		return _parse_if()
	if _is_kw("while"):
		return _parse_while()
	if _is_kw("for"):
		return _parse_for()
	if _is_kw("break"):
		_advance()
		return {"k": "break", "line": line}
	if _is_kw("return"):
		_advance()
		var e = null
		if not _block_terminator():
			e = _parse_expr()
		return {"k": "return", "e": e, "line": line}
	if _is_kw("wait"):
		_advance()
		_expect_op("(")
		var d := _parse_expr()
		_expect_op(")")
		return {"k": "wait", "e": d, "line": line}
	# assignment or bare call
	if _cur()["t"] == Lex.T_NAME:
		# look ahead: NAME '=' -> assignment (but not NAME '(' ... which is a call,
		# and not NAME '.' which is a qualified name used only as an expression).
		var save := _p
		var name: String = _cur()["v"]
		_advance()
		if _is_op("="):
			_advance()
			var rhs := _parse_expr()
			return {"k": "assign", "name": name, "e": rhs, "line": line}
		_p = save
	var expr := _parse_expr()
	return {"k": "expr", "e": expr, "line": line}


func _parse_local() -> Dictionary:
	var line := _line()
	_expect_kw("local")
	var name := _expect_name()
	_expect_op(":")
	var type := _parse_type()
	var init = null
	if _is_op("="):
		_advance()
		init = _parse_expr()
	return {"k": "local", "name": name, "type": type, "init": init, "line": line}


func _parse_if() -> Dictionary:
	var line := _line()
	_expect_kw("if")
	var arms: Array = []
	var cond := _parse_expr()
	_expect_kw("then")
	var body := _parse_block()
	arms.append({"cond": cond, "body": body})
	while _is_kw("elseif"):
		_advance()
		var c := _parse_expr()
		_expect_kw("then")
		var b := _parse_block()
		arms.append({"cond": c, "body": b})
	var else_body = null
	if _is_kw("else"):
		_advance()
		else_body = _parse_block()
	_expect_kw("end")
	return {"k": "if", "arms": arms, "else_body": else_body, "line": line}


func _parse_while() -> Dictionary:
	var line := _line()
	_expect_kw("while")
	var cond := _parse_expr()
	_expect_kw("do")
	var body := _parse_block()
	_expect_kw("end")
	return {"k": "while", "cond": cond, "body": body, "line": line}


func _parse_for() -> Dictionary:
	var line := _line()
	_expect_kw("for")
	var var_name := _expect_name()
	if _is_kw("in"):
		_advance()
		var group := _parse_expr()
		_expect_kw("do")
		var body := _parse_block()
		_expect_kw("end")
		return {"k": "foreach", "var": var_name, "group": group, "body": body, "line": line}
	_expect_op("=")
	var start := _parse_expr()
	_expect_op(",")
	var stop := _parse_expr()
	var step = null
	if _is_op(","):
		_advance()
		step = _parse_expr()
	_expect_kw("do")
	var body := _parse_block()
	_expect_kw("end")
	return {"k": "fornum", "var": var_name, "start": start, "stop": stop,
			"step": step, "body": body, "line": line}


# ---------------------------------------------------------------------------
# Parser — expressions (precedence climbing)
# ---------------------------------------------------------------------------
func _parse_expr() -> Dictionary:
	return _parse_or()


func _parse_or() -> Dictionary:
	var l := _parse_and()
	while _is_kw("or"):
		_advance()
		var r := _parse_and()
		l = {"k": "binop", "op": I.BIN_OR, "l": l, "r": r, "line": _line()}
	return l


func _parse_and() -> Dictionary:
	var l := _parse_cmp()
	while _is_kw("and"):
		_advance()
		var r := _parse_cmp()
		l = {"k": "binop", "op": I.BIN_AND, "l": l, "r": r, "line": _line()}
	return l


const _CMP_OPS := {
	"==": I.BIN_EQ, "!=": I.BIN_NE, "<": I.BIN_LT, "<=": I.BIN_LE,
	">": I.BIN_GT, ">=": I.BIN_GE,
}


func _parse_cmp() -> Dictionary:
	var l := _parse_add()
	var t: Dictionary = _tok[_p]
	if t["t"] == Lex.T_OP and _CMP_OPS.has(t["v"]):
		var op: int = _CMP_OPS[t["v"]]
		_advance()
		var r := _parse_add()
		return {"k": "binop", "op": op, "l": l, "r": r, "line": _line()}
	return l


func _parse_add() -> Dictionary:
	var l := _parse_mul()
	while _is_op("+") or _is_op("-"):
		var op := I.BIN_ADD if _cur()["v"] == "+" else I.BIN_SUB
		_advance()
		var r := _parse_mul()
		l = {"k": "binop", "op": op, "l": l, "r": r, "line": _line()}
	return l


func _parse_mul() -> Dictionary:
	var l := _parse_unary()
	while _is_op("*") or _is_op("/") or _is_op("%"):
		var op := I.BIN_MUL
		if _cur()["v"] == "/":
			op = I.BIN_DIV
		elif _cur()["v"] == "%":
			op = I.BIN_MOD
		_advance()
		var r := _parse_unary()
		l = {"k": "binop", "op": op, "l": l, "r": r, "line": _line()}
	return l


func _parse_unary() -> Dictionary:
	if _is_kw("not"):
		_advance()
		return {"k": "unop", "op": I.UN_NOT, "e": _parse_unary(), "line": _line()}
	if _is_op("-"):
		_advance()
		return {"k": "unop", "op": I.UN_NEG, "e": _parse_unary(), "line": _line()}
	return _parse_primary()


func _parse_primary() -> Dictionary:
	var t: Dictionary = _tok[_p]
	var line: int = t["line"]
	match t["t"]:
		Lex.T_INT:
			_advance()
			return {"k": "int", "v": t["v"], "line": line}
		Lex.T_FIXED:
			_advance()
			return {"k": "fixed", "v": t["v"], "line": line}
		Lex.T_DURATION:
			_advance()
			return {"k": "int", "v": t["v"], "line": line}
		Lex.T_STRING:
			_advance()
			return {"k": "str", "v": t["v"], "line": line}
		Lex.T_KEYWORD:
			if t["v"] == "true":
				_advance()
				return {"k": "bool", "v": true, "line": line}
			if t["v"] == "false":
				_advance()
				return {"k": "bool", "v": false, "line": line}
			if t["v"] == "null":
				_advance()
				return {"k": "null", "line": line}
			_err("unexpected keyword '%s' in expression" % t["v"])
			_advance()
			return {"k": "int", "v": 0, "line": line}
		Lex.T_OP:
			if t["v"] == "(":
				_advance()
				var e := _parse_expr()
				_expect_op(")")
				return e
			_err("unexpected '%s' in expression" % t["v"])
			_advance()
			return {"k": "int", "v": 0, "line": line}
		Lex.T_NAME:
			return _parse_name_primary()
	_err("unexpected token in expression")
	_advance()
	return {"k": "int", "v": 0, "line": line}


func _parse_name_primary() -> Dictionary:
	var line := _line()
	var name: String = _advance()["v"]
	# qualified catalog key: NAME '.' NAME (a unittype/abilitytype literal)
	if _is_op("."):
		_advance()
		var tail := _expect_name()
		return {"k": "qname", "v": "%s.%s" % [name, tail], "line": line}
	# call: NAME '(' args ')'
	if _is_op("("):
		_advance()
		var args: Array = []
		if not _is_op(")"):
			while true:
				args.append(_parse_expr())
				if _is_op(","):
					_advance()
				else:
					break
		_expect_op(")")
		return {"k": "call", "name": name, "args": args, "line": line}
	return {"k": "name", "v": name, "line": line}


# ---------------------------------------------------------------------------
# Resolve pass — collect global/function declarations and assign ids.
# ---------------------------------------------------------------------------
func _resolve() -> void:
	for g in _ast_globals:
		if _globals.has(g["name"]) or _funcs.has(g["name"]) or Reg.CONSTANTS.has(g["name"]):
			_errors.append("duplicate name '%s'" % g["name"])
			continue
		_globals[g["name"]] = {"id": _globals.size(), "type": g["type"]}
	for f in _ast_funcs:
		if _funcs.has(f["name"]) or _globals.has(f["name"]) or _builtins.has(f["name"]):
			_errors.append("duplicate function '%s'" % f["name"])
			continue
		var ptypes: Array = []
		for p in f["params"]:
			ptypes.append(p["type"])
		_funcs[f["name"]] = {"id": _funcs.size(), "params": ptypes, "ret": f["ret"]}


# ---------------------------------------------------------------------------
# Emit pass
# ---------------------------------------------------------------------------
func _emit() -> void:
	# globals table: [type, init_node] per id, in id order.
	var n_globals := _globals.size()
	var init_nodes := {}
	for g in _ast_globals:
		if not _globals.has(g["name"]):
			continue
		if g["init"] != null:
			var ctx := _new_ctx(I.T_VOID, false)
			var r := _emit_expr(g["init"], ctx)
			var node := _coerce(r, _globals[g["name"]]["type"], g["init"])
			init_nodes[_globals[g["name"]]["id"]] = node
	# Build globals array ordered by id.
	var gtypes := {}
	for name in _globals:
		gtypes[_globals[name]["id"]] = _globals[name]["type"]
	for gid in range(n_globals):
		_prog.globals.append(gtypes[gid])
		_prog.globals.append(init_nodes.get(gid, -1))

	# functions: reserve, then emit bodies.
	var n_funcs := _ast_funcs.size()
	# pre-size with placeholders so ids line up.
	for i in range(n_funcs * I.FUNC_STRIDE):
		_prog.functions.append(0)
	for f in _ast_funcs:
		if not _funcs.has(f["name"]):
			continue
		var fid: int = _funcs[f["name"]]["id"]
		var ctx := _new_ctx(f["ret"], false)
		for p in f["params"]:
			_declare_local(ctx, p["name"], p["type"])
		var body_node := _emit_body(f["body"], ctx)
		var base := fid * I.FUNC_STRIDE
		_prog.functions[base + 0] = f["params"].size()
		_prog.functions[base + 1] = ctx["max_locals"]
		_prog.functions[base + 2] = f["ret"]
		_prog.functions[base + 3] = body_node

	# events: emit in source order (declaration order == ascending index).
	for ev in _ast_events:
		var ctx := _new_ctx(I.T_VOID, true)
		var body_node := _emit_body(ev["body"], ctx)
		_prog.events.append(ev["kind"])
		_prog.events.append(ev["p0"])
		_prog.events.append(ev["p1"])
		_prog.events.append(-1)  # filter (none in slice)
		_prog.events.append(body_node)
		_prog.events.append(ctx["max_locals"])


# --- ctx: the per-function/per-event local allocator + scope stack ---
func _new_ctx(ret_type: int, allow_wait: bool) -> Dictionary:
	return {
		"scopes": [{}],
		"count": 0,
		"max_locals": 0,
		"ret": ret_type,
		"allow_wait": allow_wait,
		"in_loop": 0,
	}


func _push_scope(ctx: Dictionary) -> void:
	ctx["scopes"].append({})


func _pop_scope(ctx: Dictionary) -> void:
	var scope: Dictionary = ctx["scopes"].pop_back()
	ctx["count"] -= scope.size()


func _declare_local(ctx: Dictionary, name: String, type: int) -> int:
	var scope: Dictionary = ctx["scopes"][-1]
	if scope.has(name):
		_err("duplicate local '%s'" % name)
	var slot: int = ctx["count"]
	scope[name] = {"slot": slot, "type": type}
	ctx["count"] += 1
	if ctx["count"] > ctx["max_locals"]:
		ctx["max_locals"] = ctx["count"]
	return slot


func _lookup_local(ctx: Dictionary, name: String) -> Variant:
	var scopes: Array = ctx["scopes"]
	for i in range(scopes.size() - 1, -1, -1):
		if scopes[i].has(name):
			return scopes[i][name]
	return null


# ---------------------------------------------------------------------------
# Node emission helpers
# ---------------------------------------------------------------------------
func _node(op: int, t: int, a := 0, b := 0, c := 0, d := 0) -> int:
	var idx := _prog.nodes.size() / I.NODE_STRIDE
	_prog.nodes.append(op)
	_prog.nodes.append(t)
	_prog.nodes.append(a)
	_prog.nodes.append(b)
	_prog.nodes.append(c)
	_prog.nodes.append(d)
	return idx


func _add_list(node_indices: Array) -> int:
	var off := _prog.lists.size()
	for n in node_indices:
		_prog.lists.append(n)
	return off


func _intern_int(v: int) -> int:
	var idx := _prog.ints.size()
	_prog.ints.append(v)
	return idx


func _intern_str(s: String) -> int:
	var idx := _prog.strings.size()
	_prog.strings.append(s)
	return idx


# ---------------------------------------------------------------------------
# Statement emission
# ---------------------------------------------------------------------------
func _emit_body(stmts: Array, ctx: Dictionary) -> int:
	# A body is a BLOCK node over its statement node indices (own scope).
	_push_scope(ctx)
	var nodes: Array = []
	for s in stmts:
		nodes.append(_emit_stmt(s, ctx))
	_pop_scope(ctx)
	var off := _add_list(nodes)
	return _node(I.OP_BLOCK, I.T_VOID, off, nodes.size())


func _emit_stmt(s: Dictionary, ctx: Dictionary) -> int:
	match s["k"]:
		"local":
			var slot := _declare_local(ctx, s["name"], s["type"])
			var init_node := -1
			if s["init"] != null:
				var r := _emit_expr(s["init"], ctx)
				init_node = _coerce(r, s["type"], s["init"])
			# operand c carries the declared type so the VM zero-inits the slot.
			return _node(I.OP_LOCAL_DECL, I.T_VOID, slot, init_node, s["type"])
		"assign":
			return _emit_assign(s, ctx)
		"if":
			return _emit_if(s, ctx)
		"while":
			var cond := _emit_expr(s["cond"], ctx)
			_expect_bool(cond, "while condition")
			ctx["in_loop"] += 1
			var body := _emit_body(s["body"], ctx)
			ctx["in_loop"] -= 1
			return _node(I.OP_WHILE, I.T_VOID, cond["node"], body)
		"fornum":
			return _emit_fornum(s, ctx)
		"foreach":
			return _emit_foreach(s, ctx)
		"break":
			if ctx["in_loop"] <= 0:
				_errors.append("line %d: 'break' outside a loop" % s["line"])
			return _node(I.OP_BREAK, I.T_VOID)
		"return":
			return _emit_return(s, ctx)
		"wait":
			if not ctx["allow_wait"]:
				_errors.append("line %d: 'wait' is only allowed inside an event handler" % s["line"])
			var r := _emit_expr(s["e"], ctx)
			var dn := _coerce(r, I.T_INT, s["e"])
			return _node(I.OP_WAIT, I.T_VOID, dn)
		"expr":
			var er := _emit_expr(s["e"], ctx)
			return _node(I.OP_EXPR_STMT, I.T_VOID, er["node"])
	_errors.append("line %d: bad statement" % s["line"])
	return _node(I.OP_BLOCK, I.T_VOID, 0, 0)


func _emit_assign(s: Dictionary, ctx: Dictionary) -> int:
	var name: String = s["name"]
	var local = _lookup_local(ctx, name)
	if local != null:
		var r := _emit_expr(s["e"], ctx)
		var node := _coerce(r, local["type"], s["e"])
		return _node(I.OP_ASSIGN_LOCAL, I.T_VOID, local["slot"], node)
	if _globals.has(name):
		var g: Dictionary = _globals[name]
		var r := _emit_expr(s["e"], ctx)
		var node := _coerce(r, g["type"], s["e"])
		return _node(I.OP_ASSIGN_GLOBAL, I.T_VOID, g["id"], node)
	_errors.append("line %d: assignment to undefined variable '%s'" % [s["line"], name])
	return _node(I.OP_BLOCK, I.T_VOID, 0, 0)


func _emit_if(s: Dictionary, ctx: Dictionary) -> int:
	# Lower elseif chains into nested IF nodes.
	return _emit_if_arms(s["arms"], 0, s["else_body"], ctx)


func _emit_if_arms(arms: Array, i: int, else_body, ctx: Dictionary) -> int:
	var arm: Dictionary = arms[i]
	var cond := _emit_expr(arm["cond"], ctx)
	_expect_bool(cond, "if condition")
	var then_node := _emit_body(arm["body"], ctx)
	var else_node := -1
	if i + 1 < arms.size():
		else_node = _emit_if_arms(arms, i + 1, else_body, ctx)
	elif else_body != null:
		else_node = _emit_body(else_body, ctx)
	return _node(I.OP_IF, I.T_VOID, cond["node"], then_node, else_node)


func _emit_fornum(s: Dictionary, ctx: Dictionary) -> int:
	var start := _emit_expr(s["start"], ctx)
	var stop := _emit_expr(s["stop"], ctx)
	var start_n := _coerce(start, I.T_INT, s["start"])
	var stop_n := _coerce(stop, I.T_INT, s["stop"])
	var step_n: int
	if s["step"] != null:
		var step := _emit_expr(s["step"], ctx)
		step_n = _coerce(step, I.T_INT, s["step"])
	else:
		step_n = _node(I.OP_LIT_INT, I.T_INT, _intern_int(1))
	_push_scope(ctx)
	var slot := _declare_local(ctx, s["var"], I.T_INT)
	ctx["in_loop"] += 1
	var body := _emit_body(s["body"], ctx)
	ctx["in_loop"] -= 1
	_pop_scope(ctx)
	var off := _add_list([start_n, stop_n, step_n, body])
	return _node(I.OP_FOR_NUM, I.T_VOID, slot, off, 4)


func _emit_foreach(s: Dictionary, ctx: Dictionary) -> int:
	var group := _emit_expr(s["group"], ctx)
	if group["type"] != I.T_GROUP:
		_errors.append("line %d: 'for ... in' needs a group, got %s" %
				[s["line"], I.type_name(group["type"])])
	_push_scope(ctx)
	var slot := _declare_local(ctx, s["var"], I.T_UNIT)
	ctx["in_loop"] += 1
	var body := _emit_body(s["body"], ctx)
	ctx["in_loop"] -= 1
	_pop_scope(ctx)
	return _node(I.OP_FOR_EACH, I.T_VOID, group["node"], slot, body)


func _emit_return(s: Dictionary, ctx: Dictionary) -> int:
	if s["e"] == null:
		if ctx["ret"] != I.T_VOID:
			_errors.append("line %d: 'return' needs a %s value" %
					[s["line"], I.type_name(ctx["ret"])])
		return _node(I.OP_RETURN, I.T_VOID, -1)
	if ctx["ret"] == I.T_VOID:
		_errors.append("line %d: 'return' with a value in a void function" % s["line"])
	var r := _emit_expr(s["e"], ctx)
	var node := _coerce(r, ctx["ret"], s["e"])
	return _node(I.OP_RETURN, I.T_VOID, node)


# ---------------------------------------------------------------------------
# Expression emission + typechecking. Returns {node:int, type:int}.
# ---------------------------------------------------------------------------
func _emit_expr(e: Dictionary, ctx: Dictionary) -> Dictionary:
	match e["k"]:
		"int":
			return {"node": _node(I.OP_LIT_INT, I.T_INT, _intern_int(e["v"])), "type": I.T_INT}
		"fixed":
			return {"node": _node(I.OP_LIT_FIXED, I.T_FIXED, _intern_int(e["v"])), "type": I.T_FIXED}
		"bool":
			return {"node": _node(I.OP_LIT_BOOL, I.T_BOOL, 1 if e["v"] else 0), "type": I.T_BOOL}
		"str":
			return {"node": _node(I.OP_LIT_STR, I.T_STRING, _intern_str(e["v"])), "type": I.T_STRING}
		"null":
			return {"node": _node(I.OP_LIT_NULL, I.T_UNIT), "type": NULL_T}
		"name":
			return _emit_name(e, ctx)
		"qname":
			return _emit_qname(e)
		"unop":
			return _emit_unop(e, ctx)
		"binop":
			return _emit_binop(e, ctx)
		"call":
			return _emit_call(e, ctx)
	_errors.append("line %d: bad expression" % e["line"])
	return {"node": _node(I.OP_LIT_INT, I.T_INT, _intern_int(0)), "type": I.T_INT}


func _emit_name(e: Dictionary, ctx: Dictionary) -> Dictionary:
	var name: String = e["v"]
	var local = _lookup_local(ctx, name)
	if local != null:
		return {"node": _node(I.OP_LOCAL_GET, local["type"], local["slot"]), "type": local["type"]}
	if _globals.has(name):
		var g: Dictionary = _globals[name]
		return {"node": _node(I.OP_GLOBAL_GET, g["type"], g["id"]), "type": g["type"]}
	if Reg.CONSTANTS.has(name):
		var c: Array = Reg.CONSTANTS[name]
		return {"node": _node(I.OP_CONST, c[1], c[0]), "type": c[1]}
	if _regions.has(name):
		return {"node": _node(I.OP_CONST, I.T_REGION, _regions[name]), "type": I.T_REGION}
	_errors.append("line %d: undefined name '%s'" % [e["line"], name])
	return {"node": _node(I.OP_LIT_INT, I.T_INT, _intern_int(0)), "type": I.T_INT}


func _emit_qname(e: Dictionary) -> Dictionary:
	var key: String = e["v"]
	var tk := _catalog.key_of(key) if _catalog != null else -1
	if tk < 0:
		_errors.append("line %d: unknown catalog entry '%s'" % [e["line"], key])
		return {"node": _node(I.OP_CONST, I.T_UNITTYPE, 0), "type": I.T_UNITTYPE}
	var kind := _catalog.kind_of(tk)
	var type := I.T_ABILITYTYPE if kind == "ability" else I.T_UNITTYPE
	return {"node": _node(I.OP_CONST, type, tk), "type": type}


func _emit_unop(e: Dictionary, ctx: Dictionary) -> Dictionary:
	var r := _emit_expr(e["e"], ctx)
	if e["op"] == I.UN_NOT:
		if r["type"] != I.T_BOOL:
			_errors.append("line %d: 'not' needs a bool" % e["line"])
		return {"node": _node(I.OP_UNOP, I.T_BOOL, r["node"], I.UN_NOT), "type": I.T_BOOL}
	# NEG
	if r["type"] != I.T_INT and r["type"] != I.T_FIXED:
		_errors.append("line %d: unary '-' needs a number" % e["line"])
	return {"node": _node(I.OP_UNOP, r["type"], r["node"], I.UN_NEG), "type": r["type"]}


func _emit_binop(e: Dictionary, ctx: Dictionary) -> Dictionary:
	var op: int = e["op"]
	var l := _emit_expr(e["l"], ctx)
	var r := _emit_expr(e["r"], ctx)
	# Boolean
	if op == I.BIN_AND or op == I.BIN_OR:
		if l["type"] != I.T_BOOL or r["type"] != I.T_BOOL:
			_errors.append("line %d: 'and'/'or' need bools" % e["line"])
		return {"node": _node(I.OP_BINOP, I.T_BOOL, l["node"], r["node"], op), "type": I.T_BOOL}
	# Equality (any matching type, or null vs ref)
	if op == I.BIN_EQ or op == I.BIN_NE:
		var lt: int = l["type"]
		var rt: int = r["type"]
		var ln: int = l["node"]
		var rn: int = r["node"]
		if lt == NULL_T and _is_ref(rt):
			ln = _retype_null(ln, rt); lt = rt
		elif rt == NULL_T and _is_ref(lt):
			rn = _retype_null(rn, lt); rt = lt
		if lt != rt:
			_errors.append("line %d: cannot compare %s and %s" %
					[e["line"], I.type_name(l["type"]), I.type_name(r["type"])])
		return {"node": _node(I.OP_BINOP, I.T_BOOL, ln, rn, op), "type": I.T_BOOL}
	# Arithmetic + comparison on numbers: promote int->fixed if mixed.
	var lt2: int = l["type"]
	var rt2: int = r["type"]
	if not _is_num(lt2) or not _is_num(rt2):
		_errors.append("line %d: arithmetic needs numbers, got %s and %s" %
				[e["line"], I.type_name(lt2), I.type_name(rt2)])
		return {"node": _node(I.OP_BINOP, I.T_INT, l["node"], r["node"], op), "type": I.T_INT}
	var result_num := I.T_INT
	var ln2: int = l["node"]
	var rn2: int = r["node"]
	if lt2 == I.T_FIXED or rt2 == I.T_FIXED:
		result_num = I.T_FIXED
		if lt2 == I.T_INT:
			ln2 = _promote(ln2)
		if rt2 == I.T_INT:
			rn2 = _promote(rn2)
	var is_cmp := op >= I.BIN_LT and op <= I.BIN_GE
	var result_type := I.T_BOOL if is_cmp else result_num
	return {"node": _node(I.OP_BINOP, result_type, ln2, rn2, op), "type": result_type}


func _emit_call(e: Dictionary, ctx: Dictionary) -> Dictionary:
	var name: String = e["name"]
	if _builtins.has(name):
		return _emit_builtin_call(e, ctx, _builtins[name])
	if _funcs.has(name):
		return _emit_user_call(e, ctx, _funcs[name])
	_errors.append("line %d: unknown function '%s'" % [e["line"], name])
	return {"node": _node(I.OP_LIT_INT, I.T_INT, _intern_int(0)), "type": I.T_INT}


func _emit_builtin_call(e: Dictionary, ctx: Dictionary, sig: Dictionary) -> Dictionary:
	var params: Array = sig["params"]
	var args: Array = e["args"]
	if args.size() != params.size():
		_errors.append("line %d: '%s' takes %d arg(s), got %d" %
				[e["line"], e["name"], params.size(), args.size()])
	var arg_nodes: Array = []
	for i in range(min(args.size(), params.size())):
		var r := _emit_expr(args[i], ctx)
		arg_nodes.append(_coerce(r, params[i], args[i]))
	var off := _add_list(arg_nodes)
	return {"node": _node(I.OP_BUILTIN, sig["ret"], sig["id"], off, arg_nodes.size()),
			"type": sig["ret"]}


func _emit_user_call(e: Dictionary, ctx: Dictionary, sig: Dictionary) -> Dictionary:
	var params: Array = sig["params"]
	var args: Array = e["args"]
	if args.size() != params.size():
		_errors.append("line %d: '%s' takes %d arg(s), got %d" %
				[e["line"], e["name"], params.size(), args.size()])
	var arg_nodes: Array = []
	for i in range(min(args.size(), params.size())):
		var r := _emit_expr(args[i], ctx)
		arg_nodes.append(_coerce(r, params[i], args[i]))
	var off := _add_list(arg_nodes)
	return {"node": _node(I.OP_CALL, sig["ret"], sig["id"], off, arg_nodes.size()),
			"type": sig["ret"]}


# ---------------------------------------------------------------------------
# Type helpers
# ---------------------------------------------------------------------------
func _is_num(t: int) -> bool:
	return t == I.T_INT or t == I.T_FIXED


func _is_ref(t: int) -> bool:
	return t in [I.T_UNIT, I.T_PLAYER, I.T_REGION, I.T_TRIGGER, I.T_TIMER,
			I.T_UNITTYPE, I.T_ABILITYTYPE, I.T_GROUP]


# Promote an int-typed node to fixed (value << 16) via the to_fixed builtin.
func _promote(node: int) -> int:
	var off := _add_list([node])
	return _node(I.OP_BUILTIN, I.T_FIXED, 5, off, 1)  # builtin id 5 == to_fixed


func _retype_null(node: int, t: int) -> int:
	# Patch a LIT_NULL node's result type to the expected ref type.
	_prog.nodes[node * I.NODE_STRIDE + 1] = t
	return node


# Coerce an emitted expression result to `expected`, inserting an int->fixed
# promotion or fixing a null's type. Records an error on a real mismatch.
func _coerce(r: Dictionary, expected: int, src_ast) -> int:
	var t: int = r["type"]
	if t == expected:
		return r["node"]
	if t == NULL_T and _is_ref(expected):
		return _retype_null(r["node"], expected)
	if t == I.T_INT and expected == I.T_FIXED:
		return _promote(r["node"])
	var line: int = src_ast["line"] if (src_ast is Dictionary and src_ast.has("line")) else 0
	_errors.append("line %d: expected %s, got %s" %
			[line, I.type_name(expected), I.type_name(t)])
	return r["node"]


func _expect_bool(r: Dictionary, what: String) -> void:
	if r["type"] != I.T_BOOL:
		_errors.append("%s must be a bool, got %s" % [what, I.type_name(r["type"])])
