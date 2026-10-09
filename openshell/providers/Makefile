OPENSELL ?= openshell

PROFILES  := $(sort $(basename $(notdir $(wildcard provider-*.yaml))))
PROVIDERS := $(addprefix update-,$(PROFILES))

.PHONY: all help $(PROVIDERS)

all: $(PROVIDERS)

# make update-context7 | make update-unsloth | make langfuse...
# Import is create-only and update fails on an unknown id, so pick whichever applies.
# Every update bumps the gateway's resource_version, so the file's copy goes stale; update
# submits a temp copy carrying the gateway's current version instead of the file's.
update-%: provider-%.yaml
	@if $(OPENSELL) profile describe $* >/dev/null 2>&1; then \
		rv=$$($(OPENSELL) profile export $* -o yaml | sed -n 's/^resource_version: *//p'); \
		dir=$$(mktemp -d); tmp=$$dir/$<; \
		sed "s/^resource_version:.*/resource_version: $$rv/" $< > $$tmp; \
		echo "update $* (gateway resource_version $$rv)"; \
		$(OPENSELL) profile update $* -f $$tmp; status=$$?; rm -rf $$dir; exit $$status; \
	else \
		echo "import $* (new profile)"; $(OPENSELL) profile import -f $<; \
	fi

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
