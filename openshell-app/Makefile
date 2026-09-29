# Makefile — Podman workflow for openshell-app

IMAGE := openshell-app
TAG   := latest
SRC   := $(PWD)

.DEFAULT_GOAL := help

.PHONY: help build run dev exec build-run clean

## Build the base image (golang + OpenShell SDK pre-fetched)
build:
	podman build -t $(IMAGE):$(TAG) .

## Drop into an interactive dev shell with source mounted at /src
run:
	podman run --rm -it -v $(SRC):/src $(IMAGE):$(TAG) bash

## Alias for `make run`
dev: run

## Run a command in the container, e.g.: make exec CMD="go build ./..."
exec:
	@test -n "$(CMD)" || { echo 'usage: make exec CMD="go build ./..."'; exit 1; }
	podman run --rm -it -v $(SRC):/src $(IMAGE):$(TAG) bash -c '$(CMD)'

## Build the image, then drop into a dev shell
build-run: build run

## Remove the local image
clean:
	-podman rmi -f $(IMAGE):$(TAG)

help:
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-12s %s\n", $$1, $$2}'
