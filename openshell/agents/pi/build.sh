#!/bin/bash

podman build -t pi-agent:local -f Containerfile.pi .
#podman build -t pi-agent:local -f Containerfile.pi . --no-cache
