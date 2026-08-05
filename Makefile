ASEPRITE ?= /Applications/Aseprite.app/Contents/MacOS/aseprite
PYTHON   ?= .venv/bin/python
ART      ?= $(HOME)/projects/art
SPRITES  ?= Lexa-Messi Mirana-Cat-Bob Denis-Objection Yarik-Nerd Maga-Papakha Sanya-Techies Pray-Team-Spirit
SCALE    ?= 16

EXT      ?= ase-tgs
EXT_DIR  ?= $(HOME)/Library/Application Support/Aseprite/extensions/$(EXT)

.PHONY: all test unit bundle export validate rlottie ref venv clean extension install uninstall

all: test

## Full regression suite, cheapest checks first.
test: unit bundle export validate rlottie

## The packaged tree must work from its installed layout, not just from src/.
bundle: extension
	@$(ASEPRITE) -b --script tests/extension_test.lua

## Contour tracer invariants, frame selection, levers, limit enforcement.
unit:
	@$(ASEPRITE) -b --script tests/trace_test.lua
	@$(ASEPRITE) -b --script tests/levers_test.lua
	@$(ASEPRITE) -b --script tests/paths_test.lua

## Sprite -> .tgs for every test sprite, plus out/manifest.json.
## Also diffs the traced contours against the source pixels.
export:
	@$(ASEPRITE) -b --script tests/export_all.lua
	@$(ASEPRITE) -b --script tests/verify_geometry.lua

## Telegram's format limits, checked by a parser that did not write the file.
validate:
	@$(PYTHON) tests/validate_tgs.py 'out/*.tgs'

## The gate that matters: render through real rlottie and diff against the art.
rlottie: ref
	@$(PYTHON) tests/verify_rlottie.py ref

## Reference frames straight from Aseprite's own exporter.
ref:
	@mkdir -p ref
	@for s in $(SPRITES); do \
		$(ASEPRITE) -b "$(ART)/$$s.aseprite" --scale $(SCALE) --save-as "ref/$$s-1.png" >/dev/null; \
	done
	@echo "reference frames: $$(ls ref | wc -l | tr -d ' ')"

## One-time setup for the Python-side checks.
venv:
	python3 -m venv .venv
	$(PYTHON) -m pip install --quiet --upgrade pip
	$(PYTHON) -m pip install lottie rlottie-python pillow

## Bundle the installable .aseprite-extension (a zip under another name).
extension:
	@rm -rf build/$(EXT)
	@mkdir -p build/$(EXT)/src build/$(EXT)/vendor dist
	@cp extension/package.json extension/main.lua build/$(EXT)/
	@cp src/*.lua build/$(EXT)/src/
	@cp vendor/*.lua build/$(EXT)/vendor/
	@cd build/$(EXT) && zip -qr ../../dist/$(EXT).aseprite-extension .
	@echo "built dist/$(EXT).aseprite-extension ($$(du -h dist/$(EXT).aseprite-extension | cut -f1))"

## Drop the built tree straight into Aseprite's extensions folder. Faster than
## the GUI installer for development; restart Aseprite to pick it up.
install: extension
	@rm -rf "$(EXT_DIR)"
	@mkdir -p "$(EXT_DIR)"
	@cp -R build/$(EXT)/ "$(EXT_DIR)/"
	@echo "installed to $(EXT_DIR)"
	@echo "restart Aseprite to load it"

uninstall:
	@rm -rf "$(EXT_DIR)"
	@echo "removed $(EXT_DIR)"

clean:
	rm -rf out ref build dist
