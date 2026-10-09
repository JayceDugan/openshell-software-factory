# Fleet build/run targets.
#   make list          personas + harnesses
#   make providers     push every providers/provider-*.yaml (unchanged behavior)
#   make harnesses     rebuild harness images only
#   make personas      build harness images + all persona images
#   make pi-web-dev            build one persona
#   make run-pi-web-dev        launch it (add MOUNT=/path or ARGS="-- ..." )
#   make dry-pi-planner        print the exact openshell command, run nothing

OPENSELL ?= openshell
ROOT     := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

PERSONA_NAMES := $(sort $(notdir $(patsubst %/,%,$(dir $(wildcard personas/*/persona.json)))))
HARNESS_NAMES := $(sort $(basename $(notdir $(wildcard harnesses/*.json))))

MOUNT  ?= $(CURDIR)
ARGS   ?=

# NOTE: run-%/dry-% are pattern rules; listing them in .PHONY without a recipe makes
# make report "Nothing to be done", so they are marked phony per-name below instead.
.PHONY: all list personas harnesses providers $(PERSONA_NAMES)
.PHONY: $(addprefix run-,$(PERSONA_NAMES))

all: personas

list:
	@echo "harnesses: $(HARNESS_NAMES)"
	@echo "personas:  $(PERSONA_NAMES)"
	@$(MAKE) --no-print-directory -C providers list | sed 's/^/providers: /'

harnesses:
	@$(ROOT)build.sh --harnesses

personas:
	@$(ROOT)build.sh

# Bare persona name = build it.
$(PERSONA_NAMES):
	@$(ROOT)build.sh $@

# Explicit per-persona recipes (see .PHONY note above).
$(addprefix run-,$(PERSONA_NAMES)): run-%:
	@$(ROOT)launch.sh $* --mount $(MOUNT) $(ARGS)

$(addprefix dry-,$(PERSONA_NAMES)): dry-%:
	@$(ROOT)launch.sh $* --mount $(MOUNT) --dry-run $(ARGS)

# ---------- provider profiles: delegate to the existing providers/Makefile ----------
providers:
	@$(MAKE) --no-print-directory -C providers all

help:
	@echo "targets:"
	@echo "  list                 list harnesses, personas, providers"
	@echo "  harnesses            build harness images only"
	@echo "  personas             build all persona images"
	@echo "  <persona>            build one persona image"
	@echo "  run-<persona>        launch a sandbox (MOUNT=/host/repo ARGS='-- ...')"
	@echo "  dry-<persona>        print the openshell command without running it"
	@echo "  providers            update every provider profile"
	@echo "vars:"
	@echo "  MOUNT   host directory bind-mounted at /sandbox/work (default: cwd)"
	@echo "  ARGS    extra launch.sh flags, e.g. ARGS='--ro --provider github'"
	@echo "  OPENSELL openshell binary"
