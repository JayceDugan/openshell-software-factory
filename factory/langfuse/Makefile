# Self-hosted Langfuse (upstream compose from the langfuse-source submodule) on podman.
#   make up | down | ps | logs | upgrade TAG=v4.57.0
COMPOSE := podman compose -p langfuse --env-file langfuse.env \
	-f ../../langfuse-source/docker-compose.yml -f compose.override.yaml

.PHONY: up down ps logs upgrade

up:
	$(COMPOSE) up -d
	@echo "Langfuse: http://localhost:3000 (first start takes a minute while migrations run)"

down:
	$(COMPOSE) down

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail 100 langfuse-web langfuse-worker

# Move the submodule to another release tag, then restart on the new images.
upgrade:
	@test -n "$(TAG)" || { echo "usage: make upgrade TAG=v4.x.y"; exit 1; }
	git -C ../../langfuse-source fetch --depth 1 origin tag $(TAG)
	git -C ../../langfuse-source checkout $(TAG)
	$(COMPOSE) pull
	$(COMPOSE) up -d
