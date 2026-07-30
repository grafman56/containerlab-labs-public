NETLAB ?= netlab

.PHONY: check create up validate status inventory collect down telemetry-up telemetry-down

check:
	$(NETLAB) create

create:
	$(NETLAB) create

up:
	$(NETLAB) up

validate:
	$(NETLAB) validate

status:
	$(NETLAB) status
	$(NETLAB) report mgmt

inventory:
	ansible-inventory -i hosts.yml --graph

collect:
	$(NETLAB) collect

down:
	$(NETLAB) down --cleanup

telemetry-up:
	docker compose -f observability/compose.yml up -d

telemetry-down:
	docker compose -f observability/compose.yml down
