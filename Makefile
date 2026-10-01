# #61: the lab node's lifecycle, one command each. The logic lives in scripts/lab.sh.
#
# Every target runs against the personal AWS account. `override` wins even over a
# command-line `make ... AWS_PROFILE=x`, and lab.sh still refuses any account but the lab's.
override AWS_PROFILE := personal
override AWS_REGION := eu-central-1
export AWS_PROFILE AWS_REGION

# Minutes until the session lease stops the node: make start LEASE_MINUTES=60
LEASE_MINUTES ?= 180
export LEASE_MINUTES

.PHONY: help start stop extend status plan up down kubeconfig lint test run image

help:
	@echo 'make start       start the node, stop it again in $$LEASE_MINUTES min (default 180)'
	@echo 'make extend      push the stop time back to $$LEASE_MINUTES min from now'
	@echo 'make stop        stop the node now and remove the lease'
	@echo 'make status      node state, address, lease, nightly stop, tailnet'
	@echo 'make plan        read-only terraform plan of the instance stack'
	@echo 'make up          build the node from nothing (terraform, Tailscale, Ansible)'
	@echo 'make down        destroy the instance stack; the platform stack stays'
	@echo 'make kubeconfig  fetch the admin kubeconfig into ~/.kube (a credential: run it yourself)'
	@echo 'make lint        terraform fmt/validate, tflint, trivy (no AWS access; same as CI)'
	@echo 'make test        app: ruff check, ruff format --check, pytest'
	@echo 'make run         app: serve on http://localhost:8000 (reload on change)'
	@echo 'make image       app: build the container image lab-api:dev (linux/arm64)'

start stop extend status plan up down kubeconfig:
	@scripts/lab.sh $@

lint:
	@scripts/lint-terraform.sh

test:
	@cd app && uv run --frozen ruff check . && uv run --frozen ruff format --check . && uv run --frozen pytest

run:
	@cd app && uv run --frozen uvicorn lab_api.main:app --reload --port 8000

image:
	@docker build --platform linux/arm64 -t lab-api:dev app
