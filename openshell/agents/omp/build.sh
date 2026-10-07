#!/bin/bash

set -uex

podman build -t omp-agent:local -f Containerfile.pi .
#podman build -t omp-agent:local -f Containerfile.pi . --no-cache
