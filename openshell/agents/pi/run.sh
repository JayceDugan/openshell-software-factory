#!/bin/bash

set -uex

openshell sandbox create --from pi-agent:local --provider unsloth --no-keep
