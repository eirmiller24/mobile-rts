# Mobile RTS — build & test convenience targets.
#
# The native sim is a godot-cpp GDExtension under native/ (SConstruct there);
# built libraries land in bin/ next to the committed .gdextension manifest.
#
# IMPORTANT: every C++ change must rebuild BOTH template_debug and
# template_release per platform — the editor's Play button and an exported /
# host run can load different targets, so building only one leaves the other
# stale (that's how the `trigger_presentation` missing-method bug happened).
# `make desktop` and `make android` each build both targets for you.
#
# Common use:
#   make            # desktop debug+release (the everyday rebuild)
#   make all        # desktop + all four android variants
#   make test       # run every headless check in tests/
#   make clean      # drop built libraries and scons artifacts

# Parallelism for scons. Override: make JOBS=8
JOBS ?= 4
# Android SDK root. godot-cpp needs ANDROID_HOME (not just ANDROID_NDK_ROOT);
# it resolves the NDK at $(ANDROID_HOME)/ndk/<ndk_version>. Override if needed.
ANDROID_HOME ?= $(HOME)/Android/Sdk
# Godot binary for the headless test target.
GODOT ?= godot

SCONS := scons -C native -j$(JOBS)

.PHONY: default all desktop desktop-debug desktop-release \
	android android-arm64 android-arm32 android-arm64-debug \
	android-arm64-release android-arm32-debug android-arm32-release \
	models rig-mite test clean help

default: desktop

# --- Desktop (Linux x86_64) -------------------------------------------------
desktop: desktop-debug desktop-release

desktop-debug:
	$(SCONS) platform=linux target=template_debug

desktop-release:
	$(SCONS) platform=linux target=template_release

# --- Android (all four manifest variants) -----------------------------------
android: android-arm64 android-arm32

android-arm64: android-arm64-debug android-arm64-release
android-arm32: android-arm32-debug android-arm32-release

android-arm64-debug:
	ANDROID_HOME=$(ANDROID_HOME) $(SCONS) platform=android arch=arm64 target=template_debug

android-arm64-release:
	ANDROID_HOME=$(ANDROID_HOME) $(SCONS) platform=android arch=arm64 target=template_release

android-arm32-debug:
	ANDROID_HOME=$(ANDROID_HOME) $(SCONS) platform=android arch=arm32 target=template_debug

android-arm32-release:
	ANDROID_HOME=$(ANDROID_HOME) $(SCONS) platform=android arch=arm32 target=template_release

# --- Everything -------------------------------------------------------------
all: desktop android

# --- Tests (headless checks; one Godot run per script) ----------------------
# Every tests/*.gd except the shared test_support.gd helper.
TESTS := $(filter-out tests/test_support.gd,$(wildcard tests/*.gd))

test:
	@fail=0; \
	for t in $(TESTS); do \
		echo "=== $$t ==="; \
		$(GODOT) --headless --path . -s "res://$$t" 2>&1 | tail -1 || fail=1; \
	done; \
	exit $$fail

# --- Art pipeline (Blender -> glTF) -----------------------------------------
# `models` is the everyday step: it re-exports the committed .blend sources,
# so hand-edits made in the Blender GUI ship without regenerating anything.
#
# `rig-mite` REBUILDS the rig from the raw Tripo OBJ and overwrites the .blend,
# discarding hand work — that is why it needs --force and is not part of
# `models`. Edit tools/blender/*.py and run it only when you want the
# generated rig back.
BLENDER ?= blender

MODEL_SOURCES := assets/source/hive_mite.blend
assets/models/Hive/hive_mite.glb: assets/source/hive_mite.blend \
		tools/blender/export_glb.py
	$(BLENDER) --background $< --python tools/blender/export_glb.py -- $@

models: assets/models/Hive/hive_mite.glb

rig-mite:
	$(BLENDER) --background --python tools/blender/rig_swarmer.py -- --force
	$(MAKE) models

# --- Housekeeping -----------------------------------------------------------
clean:
	rm -f bin/libmobile_rts_sim.*.so
	rm -rf native/.sconsign.dblite
	find native/src -name '*.o' -delete 2>/dev/null || true

help:
	@echo "Targets:"
	@echo "  make / make desktop   Linux debug+release"
	@echo "  make android          all four android variants"
	@echo "  make all              desktop + android"
	@echo "  make models           re-export .blend sources to .glb"
	@echo "  make rig-mite         REBUILD the mite rig from the OBJ (clobbers the .blend)"
	@echo "  make test             run every headless check in tests/"
	@echo "  make clean            remove built libs + scons artifacts"
	@echo "Vars: JOBS=$(JOBS)  ANDROID_HOME=$(ANDROID_HOME)  GODOT=$(GODOT)"
