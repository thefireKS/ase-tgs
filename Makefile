ASEPRITE ?= /Applications/Aseprite.app/Contents/MacOS/aseprite
PYTHON   ?= .venv/bin/python
ART      ?= $(HOME)/projects/art
SPRITES  ?= Lexa-Messi Mirana-Cat-Bob Denis-Objection Yarik-Nerd Maga-Papakha Sanya-Techies Pray-Team-Spirit
SCALE    ?= 16

.PHONY: all test unit export validate rlottie ref venv clean

all: test

## Full regression suite, cheapest checks first.
test: unit export validate rlottie

## Contour tracer invariants, frame selection, levers, limit enforcement.
unit:
	@$(ASEPRITE) -b --script tests/trace_test.lua
	@$(ASEPRITE) -b --script tests/levers_test.lua

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

clean:
	rm -rf out ref
