#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
: "${GRAFANA_ADMIN_PASSWORD:?Export the Grafana admin password used to start the profile}"

for dependency in curl docker jq; do
  if ! command -v "$dependency" >/dev/null; then
    printf 'Required command not found: %s\n' "$dependency" >&2
    exit 1
  fi
done

prometheus=http://127.0.0.1:9090
grafana=http://127.0.0.1:3001
http=(curl --fail --silent --show-error --max-time 5)

wait_for() {
  local description=$1 deadline=$((SECONDS + 120))
  shift
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      printf 'Timed out waiting for %s\n' "$description" >&2
      return 1
    fi
    sleep 2
  done
  printf 'OK: %s\n' "$description"
}

targets_up() {
  "${http[@]}" "$prometheus/api/v1/targets?state=active" | jq -e '
    .status == "success" and (.data.activeTargets |
      any(.labels.job == "sorolens-api" and .scrapeUrl == "http://api:8080/metrics" and .health == "up") and
      any(.labels.job == "sorolens-indexer" and .scrapeUrl == "http://indexer:9100/metrics" and .health == "up"))'
}

rules_healthy() {
  "${http[@]}" "$prometheus/api/v1/rules" | jq -e '
    .status == "success" and (.data.groups |
      any(.name == "sorolens-api" and (.rules | length > 0)) and
      any(.name == "sorolens-indexer" and (.rules | length > 0)) and
      all(.[] | .rules[]; .health == "ok"))'
}

grafana_healthy() {
  "${http[@]}" "$grafana/api/health" | jq -e '.database == "ok"'
}

wait_for 'Prometheus readiness' "${http[@]}" "$prometheus/-/ready"
# Preserve the in-container config path when run from Git Bash on Windows.
MSYS_NO_PATHCONV=1 docker compose --profile observability exec -T prometheus \
  promtool check config /etc/prometheus/prometheus.yml
wait_for 'both Prometheus scrape targets to be up' targets_up
wait_for 'Prometheus alert rules to evaluate successfully' rules_healthy
wait_for 'Grafana database health' grafana_healthy

grafana_request=("${http[@]}" --user "admin:$GRAFANA_ADMIN_PASSWORD")
if ! "${grafana_request[@]}" "$grafana/api/datasources/uid/sorolens-prometheus/health" \
  | jq -e '.status == "OK"' >/dev/null; then
  echo 'Grafana Prometheus datasource health check failed' >&2
  exit 1
fi
echo 'OK: Grafana can query the provisioned Prometheus datasource'

for dashboard in docs/dashboards/*.json; do
  uid=$(jq -ej '.uid | strings | select(length > 0)' "$dashboard")
  if ! "${grafana_request[@]}" "$grafana/api/dashboards/uid/$uid" \
    | jq -e --arg uid "$uid" '.dashboard.uid == $uid and .meta.provisioned == true' >/dev/null; then
    printf 'Grafana dashboard provisioning check failed for %s\n' "$uid" >&2
    exit 1
  fi
  printf 'OK: Grafana provisioned dashboard %s\n' "$uid"
done
