class_name TriggerLexer
extends RefCounted
## Lexer for the Lua-flavored trigger language (design_m5.md §3.9). Turns source
## text into a flat token list the parser consumes. Float-free: a bare decimal
## literal (`1.5`) lexes to a 16.16 Fixed *integer* and a duration (`30s`) to an
## integer tick count, both computed with integer math so no float ever appears.
##
## Tokens: { t: Type, v: Variant, line: int }. `v` is the lexeme for NAME/KEYWORD/
## OP, the interned int for INT/FIXED/DURATION, the raw String for STRING.

const TICK_RATE := 20  # Sim.TICK_RATE — durations compile to ticks (M3 seconds->ticks)

enum {
	T_NAME, T_KEYWORD, T_INT, T_FIXED, T_DURATION, T_STRING, T_OP, T_EOF,
}

const KEYWORDS := {
	"globals": true, "function": true, "on": true, "end": true, "local": true,
	"if": true, "then": true, "elseif": true, "else": true, "while": true,
	"do": true, "for": true, "in": true, "break": true, "return": true,
	"wait": true, "and": true, "or": true, "not": true,
	"true": true, "false": true, "null": true,
}

# Multi-char operators, longest first so the scanner is greedy.
const OPS2 := ["==", "!=", "<=", ">=", "->"]
const OPS1 := ["(", ")", ",", ":", "=", "<", ">", "+", "-", "*", "/", "%", "."]

var _src := ""
var _i := 0
var _line := 1
var tokens: Array[Dictionary] = []
var errors := PackedStringArray()


static func tokenize(src: String) -> TriggerLexer:
	var lex := TriggerLexer.new()
	lex._run(src)
	return lex


func _run(src: String) -> void:
	_src = src
	_i = 0
	_line = 1
	while _i < _src.length():
		var c := _src[_i]
		if c == "\n":
			_line += 1
			_i += 1
		elif c == " " or c == "\t" or c == "\r":
			_i += 1
		elif c == "-" and _peek(1) == "-":
			# line comment to end of line
			while _i < _src.length() and _src[_i] != "\n":
				_i += 1
		elif c == "\"":
			_lex_string()
		elif _is_digit(c):
			_lex_number()
		elif _is_alpha(c):
			_lex_name()
		else:
			_lex_op()
	_push(T_EOF, "")


func _peek(off: int) -> String:
	var j := _i + off
	return _src[j] if j < _src.length() else ""


func _is_digit(c: String) -> bool:
	return c >= "0" and c <= "9"


func _is_alpha(c: String) -> bool:
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"


func _is_alnum(c: String) -> bool:
	return _is_alpha(c) or _is_digit(c)


func _push(t: int, v: Variant) -> void:
	tokens.append({"t": t, "v": v, "line": _line})


func _err(msg: String) -> void:
	errors.append("line %d: %s" % [_line, msg])


func _lex_name() -> void:
	var start := _i
	while _i < _src.length() and _is_alnum(_src[_i]):
		_i += 1
	var word := _src.substr(start, _i - start)
	if KEYWORDS.has(word):
		_push(T_KEYWORD, word)
	else:
		_push(T_NAME, word)


func _lex_string() -> void:
	_i += 1  # opening quote
	var out := ""
	while _i < _src.length() and _src[_i] != "\"":
		var c := _src[_i]
		if c == "\\":
			var n := _peek(1)
			match n:
				"n": out += "\n"
				"t": out += "\t"
				"\"": out += "\""
				"\\": out += "\\"
				_: out += n
			_i += 2
		elif c == "\n":
			_err("unterminated string")
			_push(T_STRING, out)
			return
		else:
			out += c
			_i += 1
	if _i >= _src.length():
		_err("unterminated string")
	_i += 1  # closing quote
	_push(T_STRING, out)


# Numbers: INT (123), FIXED (1.5), or DURATION (30s / 0.5s). All produce an
# already-interned integer value computed without floats.
func _lex_number() -> void:
	var start := _i
	while _i < _src.length() and _is_digit(_src[_i]):
		_i += 1
	var int_part := _src.substr(start, _i - start)
	var frac_part := ""
	var is_decimal := false
	if _i < _src.length() and _src[_i] == "." and _is_digit(_peek(1)):
		is_decimal = true
		_i += 1
		var fstart := _i
		while _i < _src.length() and _is_digit(_src[_i]):
			_i += 1
		frac_part = _src.substr(fstart, _i - fstart)
	# duration suffix?
	if _i < _src.length() and _src[_i] == "s" and not _is_alnum(_peek(1)):
		_i += 1
		var seconds_fixed := _to_fixed(int_part, frac_part)
		# ticks = round(seconds * TICK_RATE), integer math.
		var ticks := (seconds_fixed * TICK_RATE + Fixed.HALF) >> Fixed.SHIFT
		_push(T_DURATION, ticks)
		return
	if is_decimal:
		_push(T_FIXED, _to_fixed(int_part, frac_part))
	else:
		_push(T_INT, int_part.to_int())


# Convert an unsigned decimal (int_part, frac_part strings) to 16.16 Fixed,
# rounding the fraction with integer arithmetic (no float).
func _to_fixed(int_part: String, frac_part: String) -> int:
	var whole := int_part.to_int() << Fixed.SHIFT
	if frac_part.is_empty():
		return whole
	var denom := 1
	for n in frac_part.length():
		denom *= 10
	var num := frac_part.to_int()
	# frac_fixed = round(num * ONE / denom)
	var frac_fixed := (num * Fixed.ONE + denom / 2) / denom
	return whole + frac_fixed


func _lex_op() -> void:
	var two := _src.substr(_i, 2)
	if OPS2.has(two):
		_push(T_OP, two)
		_i += 2
		return
	var one := _src[_i]
	if OPS1.has(one):
		_push(T_OP, one)
		_i += 1
		return
	_err("unexpected character '%s'" % one)
	_i += 1
