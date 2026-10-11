IMAGE := factory-orchestrator:local

.PHONY: image dev typecheck

# Build the image (npm install happens here), then copy the lockfile back so it gets committed.
image:
	podman build -t $(IMAGE) -f Containerfile .
	podman run --rm --entrypoint cat $(IMAGE) /sandbox/work/package-lock.json > package-lock.json.tmp
	mv package-lock.json.tmp package-lock.json

# langgraph dev in the sandbox; Studio API on localhost:2024.
dev:
	./run.sh

typecheck:
	./run.sh -- npx tsc --noEmit
