# Makefile — Podman workflow for openshell-app

.DEFAULT_GOAL := help

.PHONY: help build run dev exec build-run clean

## Update the local openshell app with the latest changes from the agent.
download:
	openshell sandbox download pi /sandbox/openshell-app ./openshell-app/

help:
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-12s %s\n", $$1, $$2}'
