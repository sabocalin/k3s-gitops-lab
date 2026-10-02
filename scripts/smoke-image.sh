#!/bin/sh
# #22: smoke-test a built lab-api image from the outside, as the cluster will use it.
# CI runs this before pushing; locally: scripts/smoke-image.sh lab-api:dev dev
#
#   scripts/smoke-image.sh <image> <expected APP_VERSION>
#
# Optional: SMOKE_RUN_ARGS (extra docker run flags), SMOKE_PORT (default 18089).
#
# Checks: /health 200 at once, /ready 503 during warm-up then 200, `/` reports the
# expected version, the process runs as UID 65532, there is no shell, and all of it with
# a read-only root filesystem.
set -eu

image=${1:?usage: $0 <image> <expected version>}
version=${2:?usage: $0 <image> <expected version>}
name=lab-api-smoke-$$
port=${SMOKE_PORT:-18089}

fail() {
  printf 'smoke: FAIL: %s\n' "$*" >&2
  docker logs "$name" 2>&1 | tail -20 >&2 || true
  exit 1
}
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

code() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port$1" || true; }

# 5 s warm-up: wide enough to see /ready say 503 after /health is already up.
# SMOKE_RUN_ARGS adds docker run flags, e.g. "--user 0" to prove the UID check fails.
# shellcheck disable=SC2086 # word splitting of SMOKE_RUN_ARGS is intended
docker run -d --name "$name" --read-only -p "127.0.0.1:$port:8000" \
  -e STARTUP_DELAY_SECONDS=5 ${SMOKE_RUN_ARGS:-} "$image" >/dev/null

i=0
until [ "$(code /health)" = 200 ]; do
  i=$((i + 1))
  [ "$i" -lt 50 ] || fail "/health never answered 200"
  sleep 0.2
done
echo "ok: /health 200"

[ "$(code /ready)" = 503 ] || fail "/ready should be 503 during warm-up, got $(code /ready)"
echo "ok: /ready 503 during warm-up"

i=0
until [ "$(code /ready)" = 200 ]; do
  i=$((i + 1))
  [ "$i" -lt 100 ] || fail "/ready never became 200"
  sleep 0.2
done
echo "ok: /ready 200 after warm-up"

body=$(curl -s "http://127.0.0.1:$port/")
case $body in
  *"\"version\":\"$version\""*) echo "ok: / reports version $version" ;;
  *) fail "/ should report version $version, got: $body" ;;
esac

[ "$(code /metrics)" = 200 ] || fail "/metrics did not answer 200"
echo "ok: /metrics 200"

# `docker top` needs a pid column alongside the ones asked for.
uid=$(docker top "$name" -eo uid,pid | awk 'NR == 2 { print $1 }')
[ "$uid" = 65532 ] || fail "process should run as UID 65532, got '$uid'"
echo "ok: runs as UID 65532"

if docker exec "$name" sh -c true >/dev/null 2>&1; then
  fail "the image contains a shell"
fi
echo "ok: no shell in the image"

echo "smoke: all checks passed for $image"
