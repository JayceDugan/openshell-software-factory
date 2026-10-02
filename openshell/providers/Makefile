OPENSELL ?= openshell

PROFILES  := $(sort $(basename $(notdir $(wildcard provider-*.yaml))))
PROVIDERS := $(addprefix update-,$(PROFILES))

.PHONY: all help $(PROVIDERS)

all: $(PROVIDERS)

# make update-context7 | make update-unsloth | make langfuse...
update-%: provider-%.yaml
	$(OPENSELL) provider profile update $* -f $<

# Bare provider names as aliases: make context7
.PHONY: $(PROFILES)
$(PROFILES):
	@$(MAKE) --no-print-directory update-$@

list:
	@echo $(PROFILES)

help:
	@echo "targets:"
	@echo "  all          update every provider-*.yaml profile"
	@echo "  update-<id>  update one profile, e.g. make update-context7"
	@echo "  list         list available provider profiles"
	@echo "vars:"
	@echo "  OPENSELL     openshell binary (default: openshell)"
