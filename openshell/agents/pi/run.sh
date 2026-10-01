#!/bin/bash

set -uex

openshell sandbox create --name pi --from pi-agent:local --provider unsloth --no-keep
