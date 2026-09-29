# openshell-app

Base Go project for building against the [OpenShell SDK](https://github.com/NVIDIA/OpenShell/sdk/go), developed inside a Podman container.

## Quick start (Makefile)

```sh
make build       # podman build -t openshell-app:latest .
make run         # interactive dev shell, source mounted at /src
make exec CMD="go build ./..."   # run any command in the container
make build-run   # build, then drop into a dev shell
make clean       # remove the local image
make help        # list all targets
```

The Containerfile uses `golang:1.24` and runs `go get github.com/NVIDIA/OpenShell/sdk/go@latest` during the build, so the SDK is pre-fetched into the module cache.

## Develop inside the container (raw podman)

```sh
podman run --rm -it -v "$(pwd)":/src openshell-app:latest bash
# inside the container:
go build ./...
go run .
```

## Notes

- `go.mod` intentionally has no pinned version of the SDK; the Containerfile resolves `@latest` at image-build time. If you want a pinned, reproducible version on your host, run `go get github.com/NVIDIA/OpenShell/sdk/go@latest` locally once and commit the resulting `go.mod`/`go.sum`.
- For production builds, add a multi-stage `builder` stage that compiles with `CGO_ENABLED=0 go build -o /out/app .` and copies the binary into a minimal runtime image.
