class_name SimHash
extends RefCounted
## Byte-level hashing the sim owns, replacing Godot's built-in hash() in
## desync detection. The engine's hash internals may change between Godot
## versions; ours may not — peers on different builds, replays, and the
## planned C++ port (design.md "The GDExtension port") all compare these
## values, so the definition has to be ours.
##
## FNV-1a, 32-bit variant: every intermediate fits in 64-bit signed ints,
## so nothing here depends on integer overflow semantics (same rule DRng
## follows).

const FNV_OFFSET := 0x811C9DC5
const FNV_PRIME := 0x01000193
const MASK32 := 0xFFFFFFFF


static func fnv_bytes(bytes: PackedByteArray) -> int:
	var h := FNV_OFFSET
	for b in bytes:
		h = ((h ^ b) * FNV_PRIME) & MASK32
	return h


static func fnv_string(s: String) -> int:
	return fnv_bytes(s.to_utf8_buffer())


## Canonical byte serialization for hashing structured data (catalogs,
## maps): engine-independent and stable across Godot versions and the
## planned C++ port. Dictionaries fold in sorted key order; ints are 8
## little-endian bytes; strings are utf8 + NUL.
static func fold_value(buf: PackedByteArray, v: Variant) -> void:
	match typeof(v):
		TYPE_INT:
			for i in 8:
				buf.append((v >> (i * 8)) & 0xFF)
		TYPE_BOOL:
			buf.append(1 if v else 0)
		TYPE_STRING:
			buf.append_array((v as String).to_utf8_buffer())
			buf.append(0)
		TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
			fold_value(buf, v.size())
			for item: int in v:
				fold_value(buf, item)
		TYPE_PACKED_STRING_ARRAY:
			fold_value(buf, (v as PackedStringArray).size())
			for s: String in v:
				fold_value(buf, s)
		TYPE_DICTIONARY:
			var keys: Array = (v as Dictionary).keys()
			keys.sort()
			fold_value(buf, keys.size())
			for k: Variant in keys:
				fold_value(buf, k)
				fold_value(buf, v[k])
		TYPE_ARRAY:
			fold_value(buf, (v as Array).size())
			for item: Variant in v:
				fold_value(buf, item)
		_:
			assert(false, "unhashable value type %d" % typeof(v))
