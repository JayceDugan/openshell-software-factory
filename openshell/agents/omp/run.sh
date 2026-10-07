#!/bin/bash

set -uex

openshell sandbox create --from omp-agent:local --provider unsloth --no-keep
