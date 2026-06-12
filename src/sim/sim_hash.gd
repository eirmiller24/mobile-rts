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
