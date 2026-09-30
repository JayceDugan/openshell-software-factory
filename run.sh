#!/bin/bash

#run with hot-reload

podman run -it --rm \
  -v $(pwd)/assembly-line:/app:Z \
  -v cargo-registry:/usr/local/cargo/registry \
  -v cargo-target:/app/target \
  -w /app \
  -p 9080:8080 \
  rust-dev \
  cargo watch -x run
