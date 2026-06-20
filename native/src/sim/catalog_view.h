#pragma once
// Native mirror of CompiledCatalog (src/data/compiled_catalog.gd). Marshalled
// once at construction from the GDScript object; the sim then reads it purely
// native-side (keyed Dictionary lookups, no boundary crossings, no
// state-affecting iteration). This is plain compiled data — using
// godot::Dictionary/Array as the container does not violate the determinism
// wall (no engine RNG/physics/nodes/time), and every access is a deterministic
// keyed lookup that mirrors the GDScript sim_of(...)["field"] pattern 1:1.

#include <cstdint>
#include <string>
#include <vector>

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace mrts {

// CatalogSchema enums the sim references by name (catalog_schema.gd). Ordinals
// must match exactly.
namespace schema {
enum AbilityKind { AURA = 0, TOGGLE_MORPH = 1, BLINK = 2, BUILD = 3 };
enum ResourceKind { RK_ALLOY = 0, RK_FLUX = 1 };
enum BuildMechanic { BM_CAPSULE = 0, BM_WORKER = 1 };
enum Affects { OWN_STRUCTURES = 0 };
enum Allocation { ALLOC_IDLE = 0, ALLOC_ALLOY = 1, ALLOC_FLUX = 2, ALLOC_ASSIST = 3 };
enum Stance { BALANCED = 0, DEFENSIVE = 1, RECKLESS = 2, SKIRMISH = 3 };
enum TacticFlag { HOLD_POSITION = 1, FOCUS_FIRE = 2 };
} // namespace schema

struct CatalogView {
	std::vector<std::string> kinds; // type_key -> kind string
	godot::Array sim_blocks;        // type_key -> Dictionary
	godot::Dictionary globals;
	godot::PackedStringArray attack_classes;
	godot::PackedStringArray armor_classes;
	godot::PackedInt64Array matrix;
	godot::Dictionary flag_abilities;
	int64_t hash_value = 0;

	void from_object(godot::Object *cat) {
		godot::Array k = cat->get("kinds");
		kinds.clear();
		kinds.reserve(k.size());
		for (int i = 0; i < k.size(); i++) {
			kinds.push_back(std::string(godot::String(k[i]).utf8().get_data()));
		}
		sim_blocks = cat->get("sim_blocks");
		globals = cat->get("globals");
		attack_classes = cat->get("attack_classes");
		armor_classes = cat->get("armor_classes");
		matrix = cat->get("matrix");
		flag_abilities = cat->get("flag_abilities");
		hash_value = (int64_t)cat->get("hash_value");
	}

	inline const std::string &kind_of(int64_t key) const { return kinds[(int)key]; }

	inline godot::Dictionary sim_of(int64_t key) const {
		return sim_blocks[(int)key];
	}

	// Damage multiplier (fixed) for an attack/armor class pair; unset (-1) => ONE.
	inline int64_t class_mul(int64_t attack, int64_t armor) const {
		if (attack < 0 || armor < 0) {
			return (int64_t)1 << 16; // Fixed::ONE
		}
		return matrix[attack * armor_classes.size() + armor];
	}

	inline godot::PackedInt32Array abilities_with_flag(const godot::String &flag) const {
		if (flag_abilities.has(flag)) {
			return flag_abilities[flag];
		}
		return godot::PackedInt32Array();
	}

	// armor_classes index of "construction" (-1 if absent).
	inline int64_t construction_armor() const {
		return armor_classes.find("construction");
	}
};

} // namespace mrts
