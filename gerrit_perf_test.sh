#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Gerrit basic performance lab for Ubuntu 24.04
#
# v21 changes:
#   - Fixes v20 fresh-install diagnostic path by removing an accidental call to
#     an undefined section helper before Gerrit has been initialized. The initial
#     Gerrit process/port diagnostic banner is now printed directly, preserving
#     the v20 stale-process cleanup behavior.
#
# v20 changes:
#   - Fixes fresh-install startup detection/cleanup when a stale or manually
#     started Gerrit process is listening on the configured Gerrit ports before
#     the script-created systemd unit exists. v20 stops matching Gerrit processes
#     by service, gerrit.sh, configured ports, site path, and GerritCodeReview
#     command line before continuing.
#
# v19 changes:
#   - Fixes Prometheus snapshot collection so large Gerrit metric query results
#     are written to temporary JSON files and loaded with jq --slurpfile instead
#     of being passed through --argjson command-line arguments. This avoids
#     "Argument list too long" when Gerrit metrics are enabled.
#
# v18 changes:
#   - Fixes metrics-reporter-prometheus bearer token key to prometheusBearerToken
#     and adds stronger diagnostics around metrics auth probing.
#
# v17 changes:
#   - Makes Gerrit Prometheus metrics required by default and verifies the scrape
#     before running load. Captures JVM, GC, Jetty, cache, queue, and Gerrit timing
#     metric snapshots alongside node metrics.
#   - Runs stepwise concurrency stages by default instead of a single jump in load.
#   - Adds a production-like synthetic repository profile with more projects,
#     changes, and larger packfile input data.
#   - If Gerrit is already running when the script starts, stops it first and then
#     starts it cleanly through this script before the workload.
#
# v14 changes:
#   - Creates the HTTP ACL validation project through Gerrit REST first, so Gerrit
#     registers the project before the seed-push permission check.
#   - Adds Gerrit diagnostics and installed All-Projects project.config output when
#     validation seed or refs/for pushes fail with 403.
#
# v13 changes:
#   - Internal iteration based on v12.
#
# v12 changes:
#   - Fixes invalid author rejection by using a Git author email registered
#     to the authenticated Gerrit account. Defaults admin to admin@example.com.
#   - Keeps v10 ACL fixes and HTTP Git validation.
#
# v10 changes:
#   - Fixes Gerrit ACL group mapping for built-in groups.
#   - Grants test-only Git push permissions to both Anonymous Users and Registered Users.
#   - Grants createProject capability for test REST project creation when credentials allow it.
#   - Adds an explicit HTTP Git seed-push validation before synthetic workload creation.
#
# v9 changes:
#   - Uses Gerrit dev-mode documented default HTTP token: admin / secret.
#   - Validates authenticated REST before creating projects or running Git traffic.
#   - Keeps Git prompts disabled so bad credentials fail fast.
#
# v8 changes:
#   - Fixes interactive Git username prompts by using explicit test HTTP credentials.
#   - Sets GIT_TERMINAL_PROMPT=0 and GIT_ASKPASS=/bin/false so Git fails fast.
#   - Uses authenticated Git URLs for clone, seed push, and refs/for push.
#
# v7 changes:
#   - Fixes silent exit during All-Projects ACL setup.
#   - Adds error trap with failing line/command.
#   - Ensures TEST_ROOT / WORK_DIR are writable by the Gerrit system user where
#     sudo -u gerrit2 commands need to create files.
#   - Makes local All-Projects.git ACL setup more defensive and verbose.
#   - Keeps systemd-safe Gerrit startup and Prometheus setup.
#
# Run:
#   chmod +x gerrit_perf_test_v21.sh
#   sudo ./gerrit_perf_test_v21.sh
#
# Optional:
#   sudo GERRIT_VERSION=3.11.2 TEST_DURATION_SECONDS=180 ./gerrit_perf_test_v21.sh
#   sudo SYNTH_PROFILE=production_like ./gerrit_perf_test_v21.sh
#   sudo CONCURRENCY_STEPS="2,1,1 4,2,1 6,3,2 8,4,2" ./gerrit_perf_test_v21.sh
#
# WARNING:
#   This is intentionally permissive for local lab testing only.
#   Do not use this ACL model on a production Gerrit.
###############################################################################

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root, for example: sudo $0"
  exit 1
fi

trap 'rc=$?; echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: command failed at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2; exit ${rc}' ERR

###############################################################################
# Configurable inputs
###############################################################################

GERRIT_VERSION="${GERRIT_VERSION:-3.11.2}"
GERRIT_USER="${GERRIT_USER:-gerrit2}"
GERRIT_HOME="${GERRIT_HOME:-/var/gerrit}"
GERRIT_SITE="${GERRIT_SITE:-/var/gerrit/review_site}"
GERRIT_WAR="${GERRIT_WAR:-/opt/gerrit/gerrit.war}"

GERRIT_HTTP_PORT="${GERRIT_HTTP_PORT:-8080}"
GERRIT_SSH_PORT="${GERRIT_SSH_PORT:-29418}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-9100}"

PROM_BEARER_TOKEN="${PROM_BEARER_TOKEN:-gerrit-perf-lab-token-change-me}"

TEST_ROOT="${TEST_ROOT:-/var/tmp/gerrit-perf-lab}"
RESULT_DIR="${RESULT_DIR:-${TEST_ROOT}/results}"
WORK_DIR="${WORK_DIR:-${TEST_ROOT}/work}"

SYNTH_PROFILE="${SYNTH_PROFILE:-standard}"
case "$SYNTH_PROFILE" in
  standard)
    SYNTH_PROJECTS="${SYNTH_PROJECTS:-3}"
    SYNTH_INITIAL_FILES="${SYNTH_INITIAL_FILES:-80}"
    SYNTH_INITIAL_COMMITS="${SYNTH_INITIAL_COMMITS:-20}"
    SYNTH_CHANGES_PER_PROJECT="${SYNTH_CHANGES_PER_PROJECT:-15}"
    SYNTH_LARGE_FILES_PER_PROJECT="${SYNTH_LARGE_FILES_PER_PROJECT:-0}"
    SYNTH_LARGE_FILE_KB="${SYNTH_LARGE_FILE_KB:-0}"
    ;;
  production_like|large)
    SYNTH_PROJECTS="${SYNTH_PROJECTS:-8}"
    SYNTH_INITIAL_FILES="${SYNTH_INITIAL_FILES:-300}"
    SYNTH_INITIAL_COMMITS="${SYNTH_INITIAL_COMMITS:-50}"
    SYNTH_CHANGES_PER_PROJECT="${SYNTH_CHANGES_PER_PROJECT:-40}"
    SYNTH_LARGE_FILES_PER_PROJECT="${SYNTH_LARGE_FILES_PER_PROJECT:-8}"
    SYNTH_LARGE_FILE_KB="${SYNTH_LARGE_FILE_KB:-1024}"
    ;;
  *)
    echo "Unknown SYNTH_PROFILE=${SYNTH_PROFILE}; expected standard or production_like." >&2
    exit 1
    ;;
esac

TEST_DURATION_SECONDS="${TEST_DURATION_SECONDS:-120}"
REST_CONCURRENCY="${REST_CONCURRENCY:-6}"
GIT_CONCURRENCY="${GIT_CONCURRENCY:-3}"
PUSH_CONCURRENCY="${PUSH_CONCURRENCY:-2}"
CONCURRENCY_STEPS="${CONCURRENCY_STEPS:-2,1,1 4,2,1 6,3,2 8,4,2}"
REQUIRE_GERRIT_METRICS="${REQUIRE_GERRIT_METRICS:-true}"
GERRIT_PROMETHEUS_PLUGIN_JAR="${GERRIT_PROMETHEUS_PLUGIN_JAR:-}"

INITIAL_GERRIT_WAS_RUNNING="false"
GERRIT_METRICS_AUTH_MODE="unknown"
GERRIT_METRICS_PROMETHEUS_AUTH_CONFIG=""

GERRIT_BASE_URL="http://127.0.0.1:${GERRIT_HTTP_PORT}"
GERRIT_TEST_HTTP_USER="${GERRIT_TEST_HTTP_USER:-admin}"
GERRIT_TEST_HTTP_PASSWORD="${GERRIT_TEST_HTTP_PASSWORD:-secret}"
GERRIT_TEST_EMAIL="${GERRIT_TEST_EMAIL:-admin@example.com}"
GERRIT_AUTH_BASE_URL="http://${GERRIT_TEST_HTTP_USER}:${GERRIT_TEST_HTTP_PASSWORD}@127.0.0.1:${GERRIT_HTTP_PORT}"
GERRIT_METRICS_PATH="/plugins/metrics-reporter-prometheus/metrics"
GERRIT_METRICS_URL="${GERRIT_BASE_URL}${GERRIT_METRICS_PATH}"
PROM_URL="http://127.0.0.1:${PROMETHEUS_PORT}"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${RESULT_DIR}/${RUN_ID}"
JSON_OUT="${RUN_DIR}/gerrit_perf_result.json"

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false

###############################################################################
# Helpers
###############################################################################

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

warn() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARNING: $*" >&2
}

die() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

wait_for_http() {
  local url="$1"
  local max_wait="${2:-120}"
  local waited=0

  until curl -fsS "$url" >/dev/null 2>&1; do
    sleep 2
    waited=$((waited + 2))
    if [[ "$waited" -ge "$max_wait" ]]; then
      return 1
    fi
  done
}

wait_for_tcp_port() {
  local host="$1"
  local port="$2"
  local max_wait="${3:-120}"
  local waited=0

  until timeout 1 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1; do
    sleep 2
    waited=$((waited + 2))
    if [[ "$waited" -ge "$max_wait" ]]; then
      return 1
    fi
  done
}

print_gerrit_diagnostics() {
  echo
  echo "==================== Gerrit systemd status ===================="
  systemctl status gerrit-perf-lab.service --no-pager || true

  echo
  echo "==================== Gerrit journal ===================="
  journalctl -u gerrit-perf-lab.service -n 180 --no-pager || true

  echo
  echo "==================== Gerrit error_log ===================="
  tail -n 180 "${GERRIT_SITE}/logs/error_log" 2>/dev/null || true

  echo
  echo "==================== Gerrit gc_log ===================="
  tail -n 80 "${GERRIT_SITE}/logs/gc_log" 2>/dev/null || true

  echo
}

prom_query() {
  local query="$1"
  curl -fsS --get "${PROM_URL}/api/v1/query" --data-urlencode "query=${query}" || true
}

capture_prometheus_query_result() {
  local query="$1"
  local file="$2"

  local tmp="${file}.tmp"
  if prom_query "$query" | jq '.data.result // []' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    printf '%s\n' '[]' > "$file"
  fi
}

capture_prometheus_snapshot() {
  local label="$1"
  local file="${RUN_DIR}/prometheus_${label}.json"
  local snap_dir="${RUN_DIR}/prometheus_${label}_parts"

  rm -rf "$snap_dir"
  mkdir -p "$snap_dir"

  # Do not pass Prometheus result arrays via jq --argjson. When Gerrit metrics
  # are enabled, the metric payload can be large enough to exceed the kernel
  # argv/env limit and abort the script with "Argument list too long". Store
  # each query result in a file and load it with jq --slurpfile instead.
  capture_prometheus_query_result '100 - avg(rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100' "${snap_dir}/cpu.json"
  capture_prometheus_query_result '100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))' "${snap_dir}/mem.json"
  capture_prometheus_query_result 'rate(node_disk_io_time_seconds_total[1m])' "${snap_dir}/diskio.json"
  capture_prometheus_query_result 'up{job="gerrit"}' "${snap_dir}/gerrit_up.json"
  capture_prometheus_query_result 'up{job="node"}' "${snap_dir}/node_up.json"
  capture_prometheus_query_result '{job="gerrit",__name__=~".*jvm.*memory.*|.*jvm.*heap.*"}' "${snap_dir}/jvm_heap.json"
  capture_prometheus_query_result '{job="gerrit",__name__=~".*jvm.*thread.*"}' "${snap_dir}/jvm_threads.json"
  capture_prometheus_query_result '{job="gerrit",__name__=~".*gc.*|.*garbage.*"}' "${snap_dir}/gc.json"
  capture_prometheus_query_result '{job="gerrit",__name__=~".*jetty.*|.*http.*server.*"}' "${snap_dir}/jetty.json"
  capture_prometheus_query_result '{job="gerrit",__name__=~".*cache.*"}' "${snap_dir}/caches.json"
  capture_prometheus_query_result '{job="gerrit",__name__=~".*queue.*|.*executor.*|.*thread.*pool.*"}' "${snap_dir}/queues.json"
  capture_prometheus_query_result '{job="gerrit",__name__=~".*gerrit.*|.*git.*|.*review.*|.*change.*|.*latency.*|.*duration.*"}' "${snap_dir}/gerrit_timers.json"

  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile cpu "${snap_dir}/cpu.json" \
    --slurpfile mem "${snap_dir}/mem.json" \
    --slurpfile diskio "${snap_dir}/diskio.json" \
    --slurpfile gerrit_up "${snap_dir}/gerrit_up.json" \
    --slurpfile node_up "${snap_dir}/node_up.json" \
    --slurpfile jvm_heap "${snap_dir}/jvm_heap.json" \
    --slurpfile jvm_threads "${snap_dir}/jvm_threads.json" \
    --slurpfile gc "${snap_dir}/gc.json" \
    --slurpfile jetty "${snap_dir}/jetty.json" \
    --slurpfile caches "${snap_dir}/caches.json" \
    --slurpfile queues "${snap_dir}/queues.json" \
    --slurpfile gerrit_timers "${snap_dir}/gerrit_timers.json" \
    '{
      timestamp: $ts,
      cpu_percent: ($cpu[0] // []),
      memory_used_percent: ($mem[0] // []),
      disk_io_time_rate: ($diskio[0] // []),
      gerrit_up: ($gerrit_up[0] // []),
      node_up: ($node_up[0] // []),
      gerrit_server_metrics: {
        jvm_heap: ($jvm_heap[0] // []),
        jvm_threads: ($jvm_threads[0] // []),
        gc: ($gc[0] // []),
        jetty: ($jetty[0] // []),
        caches: ($caches[0] // []),
        queues: ($queues[0] // []),
        gerrit_timers: ($gerrit_timers[0] // [])
      }
    }' > "${file}.tmp"

  mv "${file}.tmp" "$file"
}

port_open_local() {
  local port="$1"
  timeout 1 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1
}

list_gerrit_like_processes() {
  pgrep -af 'GerritCodeReview|gerrit.*daemon|gerrit[.-].*war|com.google.gerrit' 2>/dev/null || true
}

list_port_owners() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print}' || true
  fi
}

gerrit_like_process_exists() {
  [[ -n "$(list_gerrit_like_processes)" ]]
}

is_gerrit_running_now() {
  if systemctl is-active --quiet gerrit-perf-lab.service 2>/dev/null; then
    return 0
  fi

  if [[ -x "${GERRIT_SITE}/bin/gerrit.sh" ]] && "${GERRIT_SITE}/bin/gerrit.sh" status >/dev/null 2>&1; then
    return 0
  fi

  # On a fresh host the systemd unit may not exist yet, but a previous failed
  # run can leave GerritCodeReview running under the invoking user. Treat that
  # as an initially running Gerrit only when a Gerrit-like process is present or
  # one of the configured Gerrit ports is open.
  if gerrit_like_process_exists; then
    return 0
  fi

  if port_open_local "$GERRIT_HTTP_PORT" || port_open_local "$GERRIT_SSH_PORT"; then
    return 0
  fi

  return 1
}

terminate_matching_gerrit_processes() {
  local signal="${1:-TERM}"

  # Prefer exact site path matches when available. This catches java command
  # lines that include "-d ${GERRIT_SITE}".
  pkill -"${signal}" -f "${GERRIT_SITE}" >/dev/null 2>&1 || true

  # Fresh-install failures can leave argv[0] as GerritCodeReview without the
  # site path visible in ps output. This lab host is dedicated, so stop those too.
  pkill -"${signal}" -f 'GerritCodeReview|com.google.gerrit.server.GerritServer|gerrit.*daemon|gerrit[.-].*war' >/dev/null 2>&1 || true
}

stop_initial_or_stale_gerrit() {
  log "Stopping any initially running or stale Gerrit instance."

  if systemctl list-unit-files gerrit-perf-lab.service >/dev/null 2>&1 || systemctl status gerrit-perf-lab.service >/dev/null 2>&1; then
    systemctl stop gerrit-perf-lab.service >/dev/null 2>&1 || true
  fi

  if [[ -x "${GERRIT_SITE}/bin/gerrit.sh" ]]; then
    "${GERRIT_SITE}/bin/gerrit.sh" stop >/dev/null 2>&1 || true
  fi

  terminate_matching_gerrit_processes TERM

  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if ! gerrit_like_process_exists && ! port_open_local "$GERRIT_HTTP_PORT" && ! port_open_local "$GERRIT_SSH_PORT"; then
      rm -f "${GERRIT_SITE}/logs/gerrit.pid" "${GERRIT_SITE}/gerrit.pid"
      return 0
    fi
    sleep 1
  done

  log "Gerrit did not stop after TERM; sending KILL to matching Gerrit processes."
  terminate_matching_gerrit_processes KILL
  sleep 2
  rm -f "${GERRIT_SITE}/logs/gerrit.pid" "${GERRIT_SITE}/gerrit.pid"

  if gerrit_like_process_exists || port_open_local "$GERRIT_HTTP_PORT" || port_open_local "$GERRIT_SSH_PORT"; then
    return 1
  fi

  return 0
}

print_initial_gerrit_state() {
  echo "==================== Initial Gerrit process/port state ===================="
  echo "Configured HTTP port: ${GERRIT_HTTP_PORT}"
  list_port_owners "$GERRIT_HTTP_PORT" || true
  echo
  echo "Configured SSH port: ${GERRIT_SSH_PORT}"
  list_port_owners "$GERRIT_SSH_PORT" || true
  echo
  echo "Gerrit-like processes:"
  list_gerrit_like_processes || true
}

handle_initial_gerrit_state() {
  if is_gerrit_running_now; then
    INITIAL_GERRIT_WAS_RUNNING="true"
    log "Gerrit appears to already be running at script start; stopping it before setup."
    print_initial_gerrit_state

    if ! stop_initial_or_stale_gerrit; then
      print_initial_gerrit_state
      print_gerrit_diagnostics
      die "Gerrit was running initially and did not stop cleanly. Refusing to continue."
    fi

    log "Initial Gerrit instance stopped. The script will start a clean Gerrit instance later."
  else
    log "No initially running Gerrit instance detected."
  fi
}

###############################################################################
# Install dependencies
###############################################################################
# Install dependencies
###############################################################################

install_packages() {
  log "Installing OS packages."

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    openjdk-21-jdk \
    git \
    curl \
    wget \
    jq \
    unzip \
    ca-certificates \
    openssh-client \
    apache2-utils \
    prometheus \
    prometheus-node-exporter \
    lsof \
    psmisc \
    python3 \
    python3-venv \
    procps \
    net-tools \
    moreutils \
    lsb-release \
    sudo

  require_cmd java
  require_cmd git
  require_cmd curl
  require_cmd jq
  require_cmd ab
  require_cmd sudo
}

###############################################################################
# Gerrit install/config
###############################################################################

create_gerrit_user() {
  if ! id "$GERRIT_USER" >/dev/null 2>&1; then
    log "Creating Gerrit system user: $GERRIT_USER"
    useradd --system --create-home --home-dir "$GERRIT_HOME" --shell /bin/bash "$GERRIT_USER"
  fi

  mkdir -p /opt/gerrit "$GERRIT_HOME" "$GERRIT_SITE" "$TEST_ROOT" "$RESULT_DIR" "$WORK_DIR"
  chown -R "$GERRIT_USER:$GERRIT_USER" "$GERRIT_HOME"
  chown -R "$GERRIT_USER:$GERRIT_USER" "$TEST_ROOT"
  chmod 0755 "$TEST_ROOT" "$RESULT_DIR" "$WORK_DIR"
}

download_gerrit() {
  if [[ -f "$GERRIT_WAR" ]]; then
    log "Using existing Gerrit WAR: $GERRIT_WAR"
    return
  fi

  log "Downloading Gerrit ${GERRIT_VERSION}."
  mkdir -p "$(dirname "$GERRIT_WAR")"

  local url="https://gerrit-releases.storage.googleapis.com/gerrit-${GERRIT_VERSION}.war"
  curl -fL "$url" -o "$GERRIT_WAR"
  chmod 0644 "$GERRIT_WAR"
}

stop_any_gerrit() {
  systemctl stop gerrit-perf-lab.service >/dev/null 2>&1 || true

  if [[ -x "${GERRIT_SITE}/bin/gerrit.sh" ]]; then
    "${GERRIT_SITE}/bin/gerrit.sh" stop >/dev/null 2>&1 || true
  fi

  pkill -u "$GERRIT_USER" -f "gerrit.*${GERRIT_SITE}" >/dev/null 2>&1 || true
  terminate_matching_gerrit_processes TERM
  sleep 1

  if gerrit_like_process_exists || port_open_local "$GERRIT_HTTP_PORT" || port_open_local "$GERRIT_SSH_PORT"; then
    terminate_matching_gerrit_processes KILL
    sleep 1
  fi

  rm -f "${GERRIT_SITE}/logs/gerrit.pid" "${GERRIT_SITE}/gerrit.pid"
}

init_gerrit() {
  stop_any_gerrit

  if [[ -f "${GERRIT_SITE}/etc/gerrit.config" ]]; then
    log "Gerrit site already exists at ${GERRIT_SITE}."
  else
    log "Initializing Gerrit site."

    sudo -H -u "$GERRIT_USER" java -jar "$GERRIT_WAR" init \
      -d "$GERRIT_SITE" \
      --batch \
      --dev \
      --no-auto-start \
      --install-plugin download-commands || true

    stop_any_gerrit
  fi

  log "Writing Gerrit config."

  mkdir -p "${GERRIT_SITE}/etc" "${GERRIT_SITE}/plugins"

  cat > "${GERRIT_SITE}/etc/gerrit.config" <<EOF_CONFIG
[gerrit]
    basePath = git
    canonicalWebUrl = ${GERRIT_BASE_URL}/
    serverId = gerrit-perf-lab-${RUN_ID}

[index]
    type = LUCENE

[auth]
    type = DEVELOPMENT_BECOME_ANY_ACCOUNT
    gitBasicAuthPolicy = HTTP

[receive]
    enableSignedPush = false

[sendemail]
    enable = false

[container]
    user = ${GERRIT_USER}
    javaHome = /usr/lib/jvm/java-21-openjdk-amd64
    javaOptions = -Xms1g
    javaOptions = -Xmx2g
    javaOptions = -XX:+UseG1GC
    javaOptions = -Djava.net.preferIPv4Stack=true

[sshd]
    listenAddress = *:${GERRIT_SSH_PORT}

[httpd]
    listenUrl = http://*:${GERRIT_HTTP_PORT}/

[cache]
    directory = cache

[plugins]
    allowRemoteAdmin = true

[plugin "metrics-reporter-prometheus"]
    # metrics-reporter-prometheus expects this exact key.
    # v17 used bearerToken, which the plugin ignored and caused HTTP 403.
    prometheusBearerToken = ${PROM_BEARER_TOKEN}
EOF_CONFIG

  chown -R "$GERRIT_USER:$GERRIT_USER" "$GERRIT_SITE"
}

install_prometheus_plugin() {
  log "Installing metrics-reporter-prometheus plugin."

  local plugin_target="${GERRIT_SITE}/plugins/metrics-reporter-prometheus.jar"
  mkdir -p "${GERRIT_SITE}/plugins"

  if [[ -n "$GERRIT_PROMETHEUS_PLUGIN_JAR" ]]; then
    [[ -f "$GERRIT_PROMETHEUS_PLUGIN_JAR" ]] || die "GERRIT_PROMETHEUS_PLUGIN_JAR does not exist: ${GERRIT_PROMETHEUS_PLUGIN_JAR}"
    cp -f "$GERRIT_PROMETHEUS_PLUGIN_JAR" "$plugin_target"
  elif [[ -f "$plugin_target" ]]; then
    log "Prometheus plugin already present at ${plugin_target}."
  else
    local gerrit_minor="${GERRIT_VERSION%.*}"
    local candidates=(
      "https://gerrit-ci.gerritforge.com/job/plugin-metrics-reporter-prometheus-bazel-stable-${gerrit_minor}/lastSuccessfulBuild/artifact/bazel-bin/plugins/metrics-reporter-prometheus/metrics-reporter-prometheus.jar"
      "https://gerrit-ci.gerritforge.com/job/plugin-metrics-reporter-prometheus-bazel-stable-${GERRIT_VERSION}/lastSuccessfulBuild/artifact/bazel-bin/plugins/metrics-reporter-prometheus/metrics-reporter-prometheus.jar"
      "https://gerrit-ci.gerritforge.com/job/plugin-metrics-reporter-prometheus-bazel-master/lastSuccessfulBuild/artifact/bazel-bin/plugins/metrics-reporter-prometheus/metrics-reporter-prometheus.jar"
    )

    local downloaded="false"
    for url in "${candidates[@]}"; do
      log "Trying plugin URL: $url"
      if curl -fL --retry 2 --connect-timeout 20 "$url" -o "${plugin_target}.tmp"; then
        mv -f "${plugin_target}.tmp" "$plugin_target"
        downloaded="true"
        break
      fi
      rm -f "${plugin_target}.tmp"
    done

    if [[ "$downloaded" != "true" ]]; then
      if [[ "$REQUIRE_GERRIT_METRICS" == "true" ]]; then
        die "Could not download metrics-reporter-prometheus plugin. Provide GERRIT_PROMETHEUS_PLUGIN_JAR=/path/to/metrics-reporter-prometheus.jar or set REQUIRE_GERRIT_METRICS=false."
      fi
      warn "Could not download metrics-reporter-prometheus plugin automatically. Continuing because REQUIRE_GERRIT_METRICS=false."
      rm -f "$plugin_target"
      return
    fi
  fi

  if ! unzip -tq "$plugin_target" >/dev/null 2>&1; then
    rm -f "$plugin_target"
    die "Downloaded Prometheus plugin is not a valid jar: ${plugin_target}"
  fi

  chown "$GERRIT_USER:$GERRIT_USER" "$plugin_target"
  chmod 0644 "$plugin_target"
}

create_gerrit_service() {
  log "Creating systemd service for Gerrit."

  cat > /etc/systemd/system/gerrit-perf-lab.service <<EOF_SERVICE
[Unit]
Description=Gerrit Performance Lab
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${GERRIT_USER}
Group=${GERRIT_USER}
WorkingDirectory=${GERRIT_SITE}
Environment=GERRIT_SITE=${GERRIT_SITE}
ExecStart=/usr/bin/java -jar ${GERRIT_WAR} daemon -d ${GERRIT_SITE} --console-log
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=10
TimeoutStartSec=180
TimeoutStopSec=60
SuccessExitStatus=143
LimitNOFILE=65536
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  systemctl daemon-reload
  systemctl enable prometheus >/dev/null 2>&1 || true
  systemctl enable prometheus-node-exporter >/dev/null 2>&1 || true
  systemctl enable gerrit-perf-lab >/dev/null 2>&1 || true
}

start_gerrit() {
  log "Starting Gerrit."

  stop_any_gerrit

  rm -f "${GERRIT_SITE}/logs/gerrit.pid" "${GERRIT_SITE}/gerrit.pid"
  chown -R "$GERRIT_USER:$GERRIT_USER" "$GERRIT_SITE"

  systemctl daemon-reload
  systemctl restart gerrit-perf-lab.service

  sleep 5

  if ! systemctl is-active --quiet gerrit-perf-lab.service; then
    print_gerrit_diagnostics
    die "Gerrit failed to start."
  fi

  if ! wait_for_http "${GERRIT_BASE_URL}" 180; then
    print_gerrit_diagnostics
    die "Timed out waiting for Gerrit HTTP at ${GERRIT_BASE_URL}"
  fi

  if ! wait_for_tcp_port "127.0.0.1" "$GERRIT_SSH_PORT" 180; then
    print_gerrit_diagnostics
    die "Timed out waiting for Gerrit SSH port ${GERRIT_SSH_PORT}"
  fi

  log "Gerrit is running."
}

restart_gerrit() {
  log "Restarting Gerrit."

  systemctl restart gerrit-perf-lab.service

  if ! wait_for_http "${GERRIT_BASE_URL}" 180; then
    print_gerrit_diagnostics
    die "Timed out waiting for Gerrit HTTP after restart."
  fi

  if ! wait_for_tcp_port "127.0.0.1" "$GERRIT_SSH_PORT" 180; then
    print_gerrit_diagnostics
    die "Timed out waiting for Gerrit SSH after restart."
  fi
}

###############################################################################
# Prometheus config
###############################################################################

configure_prometheus() {
  log "Configuring Prometheus."

  cp -a /etc/prometheus/prometheus.yml "/etc/prometheus/prometheus.yml.bak.${RUN_ID}" 2>/dev/null || true

  cat > /etc/prometheus/prometheus.yml <<EOF_PROM
scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["127.0.0.1:${PROMETHEUS_PORT}"]

  - job_name: "node"
    static_configs:
      - targets: ["127.0.0.1:${NODE_EXPORTER_PORT}"]

  - job_name: "gerrit"
    metrics_path: "${GERRIT_METRICS_PATH}"
    scheme: "http"
${GERRIT_METRICS_PROMETHEUS_AUTH_CONFIG}    static_configs:
      - targets: ["127.0.0.1:${GERRIT_HTTP_PORT}"]

global:
  scrape_interval: 5s
  evaluation_interval: 5s
EOF_PROM

  if command -v promtool >/dev/null 2>&1; then
    if ! promtool check config /etc/prometheus/prometheus.yml >/dev/null 2>&1; then
      promtool check config /etc/prometheus/prometheus.yml || true
      die "Prometheus configuration validation failed."
    fi
  else
    warn "promtool not found; skipping Prometheus config validation."
  fi

  systemctl restart prometheus-node-exporter
  systemctl restart prometheus

  if ! wait_for_http "${PROM_URL}/-/ready" 120; then
    systemctl status prometheus --no-pager || true
    journalctl -u prometheus -n 120 --no-pager || true
    die "Timed out waiting for Prometheus at ${PROM_URL}"
  fi
}

probe_gerrit_metrics() {
  local mode="$1"
  local out_file="$2"

  case "$mode" in
    bearer)
      curl -fsS -H "Authorization: Bearer ${PROM_BEARER_TOKEN}" "$GERRIT_METRICS_URL" -o "$out_file"
      ;;
    basic)
      curl -fsS -u "${GERRIT_TEST_HTTP_USER}:${GERRIT_TEST_HTTP_PASSWORD}" "$GERRIT_METRICS_URL" -o "$out_file"
      ;;
    none)
      curl -fsS "$GERRIT_METRICS_URL" -o "$out_file"
      ;;
    *)
      return 1
      ;;
  esac
}

select_gerrit_metrics_auth_mode() {
  log "Verifying Gerrit Prometheus metrics endpoint."

  mkdir -p "$RUN_DIR"
  local sample="${RUN_DIR}/gerrit_metrics_startup_sample.txt"
  : > "$sample"

  local mode
  for mode in bearer none basic; do
    if probe_gerrit_metrics "$mode" "$sample"; then
      if grep -Eq '(^# HELP|^# TYPE|^[a-zA-Z_:][a-zA-Z0-9_:]*[{ ]|^plugins_|^proc_|^jvm_|^jetty_|^caches_|^git_|^http_)' "$sample"; then
        GERRIT_METRICS_AUTH_MODE="$mode"
        case "$mode" in
          bearer)
            printf -v GERRIT_METRICS_PROMETHEUS_AUTH_CONFIG '    bearer_token: "%s"\n' "$PROM_BEARER_TOKEN"
            ;;
          basic)
            printf -v GERRIT_METRICS_PROMETHEUS_AUTH_CONFIG '    basic_auth:\n      username: "%s"\n      password: "%s"\n' "$GERRIT_TEST_HTTP_USER" "$GERRIT_TEST_HTTP_PASSWORD"
            ;;
          none)
            GERRIT_METRICS_PROMETHEUS_AUTH_CONFIG=""
            ;;
        esac
        log "Gerrit metrics endpoint is reachable using auth mode: ${GERRIT_METRICS_AUTH_MODE}."
        cp -f "$sample" "${RUN_DIR}/gerrit_metrics_sample.txt"
        return 0
      fi
    fi
  done

  print_gerrit_diagnostics
  echo "==================== Prometheus plugin files ===================="
  ls -l "${GERRIT_SITE}/plugins" || true
  echo "==================== Gerrit metrics endpoint probe ===================="
  echo "-- bearer token probe --"
  curl -sv -H "Authorization: Bearer ${PROM_BEARER_TOKEN}" "$GERRIT_METRICS_URL" -o /tmp/gerrit-metrics-probe.out 2>&1 || true
  sed -n '1,160p' /tmp/gerrit-metrics-probe.out || true
  echo "-- anonymous probe --"
  curl -sv "$GERRIT_METRICS_URL" -o /tmp/gerrit-metrics-probe-none.out 2>&1 || true
  sed -n '1,120p' /tmp/gerrit-metrics-probe-none.out || true
  echo "-- basic auth probe --"
  curl -sv -u "${GERRIT_TEST_HTTP_USER}:${GERRIT_TEST_HTTP_PASSWORD}" "$GERRIT_METRICS_URL" -o /tmp/gerrit-metrics-probe-basic.out 2>&1 || true
  sed -n '1,120p' /tmp/gerrit-metrics-probe-basic.out || true
  echo "-- configured plugin stanza --"
  sed -n '/\[plugin "metrics-reporter-prometheus"\]/,/^\[/p' "${GERRIT_SITE}/etc/gerrit.config" | sed -e 's/prometheusBearerToken = .*/prometheusBearerToken = REDACTED/' || true
  rm -f /tmp/gerrit-metrics-probe.out /tmp/gerrit-metrics-probe-none.out /tmp/gerrit-metrics-probe-basic.out

  if [[ "$REQUIRE_GERRIT_METRICS" == "true" ]]; then
    die "Gerrit Prometheus metrics endpoint is unavailable. v18 writes plugin.metrics-reporter-prometheus.prometheusBearerToken; if this still fails, inspect the plugin stanza and target status printed above."
  fi

  warn "Gerrit metrics endpoint unavailable, continuing because REQUIRE_GERRIT_METRICS=false."
  GERRIT_METRICS_AUTH_MODE="unavailable"
  GERRIT_METRICS_PROMETHEUS_AUTH_CONFIG=""
}

verify_prometheus_gerrit_scrape() {
  log "Verifying Prometheus can scrape Gerrit."

  local waited=0
  local val=""
  while [[ "$waited" -lt 90 ]]; do
    val="$(prom_query 'up{job="gerrit"}' | jq -r '.data.result[0].value[1] // empty' 2>/dev/null || true)"
    if [[ "$val" == "1" ]]; then
      log "Prometheus Gerrit scrape is up."
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done

  echo "==================== Prometheus target status ===================="
  curl -fsS "${PROM_URL}/api/v1/targets" | jq '.data.activeTargets[]? | select(.labels.job == "gerrit")' || true
  echo "==================== Last metrics endpoint sample ===================="
  sed -n '1,80p' "${RUN_DIR}/gerrit_metrics_sample.txt" 2>/dev/null || true

  if [[ "$REQUIRE_GERRIT_METRICS" == "true" ]]; then
    die "Prometheus reports up{job="gerrit"}=${val:-empty}; Gerrit server-side metrics are not being scraped."
  fi

  warn "Prometheus Gerrit scrape is not up, continuing because REQUIRE_GERRIT_METRICS=false."
}

###############################################################################
# Gerrit admin setup and synthetic data
###############################################################################
# Gerrit admin setup and synthetic data
###############################################################################

setup_git_identity() {
  git config --global user.email "$GERRIT_TEST_EMAIL"
  git config --global user.name "Gerrit Perf Lab"
  git config --global init.defaultBranch "main"
  git config --global credential.helper ""

  sudo -H -u "$GERRIT_USER" git config --global user.email "$GERRIT_TEST_EMAIL" || true
  sudo -H -u "$GERRIT_USER" git config --global user.name "Gerrit Perf Lab" || true
  sudo -H -u "$GERRIT_USER" git config --global init.defaultBranch "main" || true
}

validate_gerrit_http_credentials() {
  log "Validating Gerrit HTTP credentials for ${GERRIT_TEST_HTTP_USER}."

  local status
  status="$(curl -sS -o /tmp/gerrit-auth-check.$$ -w "%{http_code}" \
    -u "${GERRIT_TEST_HTTP_USER}:${GERRIT_TEST_HTTP_PASSWORD}" \
    "${GERRIT_BASE_URL}/a/accounts/self" || echo "000")"

  rm -f /tmp/gerrit-auth-check.$$

  if [[ "$status" != "200" ]]; then
    die "Gerrit HTTP credentials failed. Expected dev-mode default admin:secret, got HTTP ${status}. If this site was not initialized with --dev, set GERRIT_TEST_HTTP_USER and GERRIT_TEST_HTTP_PASSWORD to a real Gerrit HTTP token."
  fi

  log "Gerrit HTTP credentials are valid."
}

gerrit_api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"

  # Prefer authenticated REST. In DEVELOPMENT_BECOME_ANY_ACCOUNT mode this may
  # still be rejected on some Gerrit versions; callers keep a direct local-git
  # fallback for project creation.
  if [[ -n "$data" ]]; then
    curl -fsS       -u "${GERRIT_TEST_HTTP_USER}:${GERRIT_TEST_HTTP_PASSWORD}"       -X "$method"       -H "Content-Type: application/json"       --data "$data"       "${GERRIT_BASE_URL}/a${path}"
  else
    curl -fsS       -u "${GERRIT_TEST_HTTP_USER}:${GERRIT_TEST_HTTP_PASSWORD}"       -X "$method"       "${GERRIT_BASE_URL}/a${path}"
  fi
}

configure_test_permissions() {
  log "Configuring permissive test-only Gerrit ACLs via local All-Projects.git."

  local all_projects_git="${GERRIT_SITE}/git/All-Projects.git"

  if [[ ! -d "$all_projects_git" ]]; then
    print_gerrit_diagnostics
    die "All-Projects.git not found at ${all_projects_git}"
  fi

  mkdir -p "$WORK_DIR"
  chown -R "$GERRIT_USER:$GERRIT_USER" "$WORK_DIR"

  local acl_work="${WORK_DIR}/all-projects-acl"
  rm -rf "$acl_work"

  log "Cloning local All-Projects repo for ACL update."
  sudo -H -u "$GERRIT_USER" git clone "$all_projects_git" "$acl_work"

  pushd "$acl_work" >/dev/null

  sudo -H -u "$GERRIT_USER" git config user.email "$GERRIT_TEST_EMAIL"
  sudo -H -u "$GERRIT_USER" git config user.name "Gerrit Perf Lab"

  log "Fetching and checking out refs/meta/config."
  if sudo -H -u "$GERRIT_USER" git fetch origin refs/meta/config:refs/remotes/origin/meta/config; then
    sudo -H -u "$GERRIT_USER" git checkout -B meta-config refs/remotes/origin/meta/config
  else
    warn "refs/meta/config was not fetchable; creating it from an orphan branch."
    sudo -H -u "$GERRIT_USER" git checkout --orphan meta-config
    sudo -H -u "$GERRIT_USER" git rm -rf . >/dev/null 2>&1 || true
  fi

  # Gerrit's groups file maps stable UUIDs to display names. The display
  # names must match the names used in project.config. Earlier script versions
  # incorrectly used the UUID-like strings as display names, causing the ACL
  # rules not to resolve correctly and Git-over-HTTP pushes to fail with 403.
  cat > groups <<'EOF_GROUPS'
global:Anonymous-Users	Anonymous Users
global:Registered-Users	Registered Users
global:Administrators	Administrators
EOF_GROUPS

  cat > project.config <<'EOF_PROJECT'
[access "refs/*"]
	read = group Anonymous Users
	read = group Registered Users

[access "refs/heads/*"]
	create = group Anonymous Users
	create = group Registered Users
	push = +force group Anonymous Users
	push = +force group Registered Users

[access "refs/for/refs/heads/*"]
	push = group Anonymous Users
	push = group Registered Users

[access "refs/meta/config"]
	read = group Anonymous Users
	read = group Registered Users

[capability]
	administrateServer = group Administrators
	viewMetrics = group Anonymous Users
	viewMetrics = group Registered Users
	createProject = group Anonymous Users
	createProject = group Registered Users

[project]
	description = Access inherited by all projects.
	state = active
EOF_PROJECT

  chown "$GERRIT_USER:$GERRIT_USER" groups project.config

  sudo -H -u "$GERRIT_USER" git add groups project.config

  if sudo -H -u "$GERRIT_USER" git diff --cached --quiet; then
    log "All-Projects ACLs already up to date."
  else
    log "Committing test ACL update."
    sudo -H -u "$GERRIT_USER" git commit -m "Configure permissive local performance test ACLs"
    sudo -H -u "$GERRIT_USER" git push origin HEAD:refs/meta/config
  fi

  popd >/dev/null
  rm -rf "$acl_work"

  restart_gerrit
  log "Test ACLs configured."
}

validate_http_git_push_permissions() {
  log "Validating HTTP Git seed-push permissions."

  local validation_project="perf/acl-validation-${RUN_ID}"
  local encoded_validation_project
  encoded_validation_project="$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("${validation_project}", safe=""))
PY
)"

  # Create the validation project through Gerrit first. Directly initializing a
  # bare repository under review_site/git can leave Gerrit unaware of the
  # project on some machines until a cache reload/restart, which makes the
  # immediate HTTP Git validation fail with 403 even though the repo exists.
  if ! gerrit_api PUT "/projects/${encoded_validation_project}" \
    '{"description":"ACL validation project","submit_type":"MERGE_IF_NECESSARY","create_empty_commit":false}' \
    >/dev/null; then
    warn "REST validation project creation failed for ${validation_project}; creating bare repo directly."

    local validation_git="${GERRIT_SITE}/git/${validation_project}.git"
    local validation_parent
    validation_parent="$(dirname "$validation_git")"

    mkdir -p "$validation_parent"
    chown -R "$GERRIT_USER:$GERRIT_USER" "${GERRIT_SITE}/git/perf"

    if [[ ! -d "$validation_git" ]]; then
      sudo -H -u "$GERRIT_USER" git init --bare "$validation_git" >/dev/null
    fi
    chown -R "$GERRIT_USER:$GERRIT_USER" "$validation_git"

    restart_gerrit
  fi

  local validation_work="${WORK_DIR}/acl-validation-push-${RUN_ID}"
  rm -rf "$validation_work"
  mkdir -p "$validation_work"

  pushd "$validation_work" >/dev/null
  git init >/dev/null
  git config user.email "$GERRIT_TEST_EMAIL"
  git config user.name "$GERRIT_TEST_HTTP_USER"
  git checkout -B main >/dev/null 2>&1
  echo "ACL validation ${RUN_ID}" > README.md
  git add README.md
  git commit -q -m "Validate HTTP Git push permissions"
  git remote add origin "${GERRIT_AUTH_BASE_URL}/${validation_project}"

  if ! git push --force origin HEAD:refs/heads/main; then
    popd >/dev/null
    rm -rf "$validation_work"
    print_gerrit_diagnostics
    echo "==================== Installed All-Projects project.config ===================="
    sudo -H -u "$GERRIT_USER" git --git-dir="${GERRIT_SITE}/git/All-Projects.git" \
      show refs/meta/config:project.config || true
    die "HTTP Git push is still forbidden after ACL setup."
  fi

  # Gerrit rejects pushing the exact same commit to refs/for/main after it
  # already exists on refs/heads/main with: "no new changes". Create a second
  # unique commit so this validation specifically tests refs/for/main permission.
  echo "Review validation ${RUN_ID} $(date -u +%s%N)" >> REVIEW_VALIDATION.md
  git add REVIEW_VALIDATION.md
  git commit -q -m "Validate HTTP Git review push permissions"

  if ! git push origin HEAD:refs/for/main; then
    popd >/dev/null
    rm -rf "$validation_work"
    print_gerrit_diagnostics
    echo "==================== Installed All-Projects project.config ===================="
    sudo -H -u "$GERRIT_USER" git --git-dir="${GERRIT_SITE}/git/All-Projects.git" \
      show refs/meta/config:project.config || true
    die "HTTP Git push to refs/for/main failed after ACL setup."
  fi

  popd >/dev/null
  rm -rf "$validation_work"
  log "HTTP Git push permissions validated."
}

create_synthetic_projects() {
  log "Creating synthetic Gerrit projects and changes."

  rm -rf "${WORK_DIR}/synthetic"
  mkdir -p "${WORK_DIR}/synthetic"
  chown -R "$GERRIT_USER:$GERRIT_USER" "$WORK_DIR"

  for p in $(seq 1 "$SYNTH_PROJECTS"); do
    local_project="perf/project-${p}"
    encoded_project="$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("${local_project}", safe=""))
PY
)"

    log "Creating project ${local_project}."

    if ! gerrit_api PUT "/projects/${encoded_project}" \
      '{"description":"Synthetic performance test project","submit_type":"MERGE_IF_NECESSARY","create_empty_commit":false}' \
      >/dev/null; then
      warn "REST project creation failed for ${local_project}; creating bare repo directly."

      local project_git="${GERRIT_SITE}/git/${local_project}.git"
      local project_parent
      project_parent="$(dirname "$project_git")"

      # The parent directory must be owned by the Gerrit OS user before
      # running git init as that user. Earlier versions created this parent
      # as root, causing: fatal: cannot mkdir ... Permission denied.
      mkdir -p "$project_parent"
      chown -R "$GERRIT_USER:$GERRIT_USER" "${GERRIT_SITE}/git/perf"

      if [[ ! -d "$project_git" ]]; then
        sudo -H -u "$GERRIT_USER" git init --bare "$project_git" >/dev/null
      fi
      chown -R "$GERRIT_USER:$GERRIT_USER" "$project_git"
    fi

    repo_dir="${WORK_DIR}/synthetic/project-${p}"
    rm -rf "$repo_dir"
    mkdir -p "$repo_dir"
    pushd "$repo_dir" >/dev/null

    git init
    git config user.email "$GERRIT_TEST_EMAIL"
    git config user.name "$GERRIT_TEST_HTTP_USER"
    git checkout -B main

    for f in $(seq 1 "$SYNTH_INITIAL_FILES"); do
      mkdir -p "src/module-$((f % 10))"
      {
        echo "Synthetic file ${f}"
        echo "Project ${p}"
        echo "Generated at ${RUN_ID}"
        seq 1 40 | sed "s/^/line /"
      } > "src/module-$((f % 10))/file-${f}.txt"
    done

    if [[ "$SYNTH_LARGE_FILES_PER_PROJECT" -gt 0 && "$SYNTH_LARGE_FILE_KB" -gt 0 ]]; then
      mkdir -p large-packfiles
      log "Adding ${SYNTH_LARGE_FILES_PER_PROJECT} large packfile inputs of ${SYNTH_LARGE_FILE_KB} KiB to ${local_project}."
      python3 - <<PYLARGE
from pathlib import Path
import os
root = Path("large-packfiles")
count = int("${SYNTH_LARGE_FILES_PER_PROJECT}")
size = int("${SYNTH_LARGE_FILE_KB}") * 1024
project = "${p}".encode()
run_id = "${RUN_ID}".encode()
for i in range(1, count + 1):
    path = root / f"payload-{i:03d}.bin"
    remaining = size
    with path.open("wb") as fh:
        fh.write(b"gerrit-perf-large-payload\n")
        fh.write(b"project=" + project + b"\n")
        fh.write(b"run_id=" + run_id + b"\n")
        remaining -= fh.tell()
        while remaining > 0:
            chunk = os.urandom(min(1024 * 1024, remaining))
            fh.write(chunk)
            remaining -= len(chunk)
PYLARGE
    fi

    git add .
    git commit -m "Initial synthetic content for project ${p}"

    for c in $(seq 1 "$SYNTH_INITIAL_COMMITS"); do
      file="src/module-$((c % 10))/file-$(((c % SYNTH_INITIAL_FILES) + 1)).txt"
      echo "baseline commit ${c} $(date -u +%s%N)" >> "$file"
      git add "$file"
      git commit -m "Synthetic baseline commit ${c}"
    done

    git remote remove origin >/dev/null 2>&1 || true
    git remote add origin "${GERRIT_AUTH_BASE_URL}/${local_project}"

    if ! git push --force origin HEAD:refs/heads/main; then
      die "Failed to seed ${local_project}. Check Gerrit ACLs and HTTP Git permissions."
    fi

    git fetch origin main || true
    git checkout -B main origin/main 2>/dev/null || git checkout -B main

    for c in $(seq 1 "$SYNTH_CHANGES_PER_PROJECT"); do
      git checkout -B "change-${c}" main
      file="src/module-$((c % 10))/change-${c}.txt"
      {
        echo "Synthetic change ${c}"
        echo "Project ${p}"
        echo "Timestamp $(date -u +%s%N)"
        seq 1 20 | sed "s/^/change-line /"
      } > "$file"
      git add "$file"
      git commit -m "Synthetic review change ${c} for project ${p}"

      if ! git push origin HEAD:refs/for/main; then
        die "Failed to push review change ${c} for ${local_project}. Check Gerrit ACLs."
      fi
    done

    popd >/dev/null
  done
}

###############################################################################
# Performance test
###############################################################################

run_rest_load_worker() {
  local step_name="$1"
  local worker="$2"
  local end_epoch="$3"
  local out_file="$4"

  while [[ "$(date +%s)" -lt "$end_epoch" ]]; do
    local start_ns end_ns duration_ms status bytes tmp
    start_ns="$(date +%s%N)"

    tmp="$(mktemp)"
    status="$(curl -sS \
      -o "$tmp" \
      -w "%{http_code}" \
      "${GERRIT_BASE_URL}/changes/?q=status:open&n=25" || echo "000")"

    end_ns="$(date +%s%N)"
    duration_ms="$(( (end_ns - start_ns) / 1000000 ))"
    bytes="$(wc -c < "$tmp" | tr -d ' ')"
    rm -f "$tmp"

    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg step "$step_name" \
      --arg worker "$worker" \
      --arg status "$status" \
      --argjson duration_ms "$duration_ms" \
      --argjson bytes "$bytes" \
      '{timestamp:$ts, step:$step, type:"rest_change_query", worker:$worker, status:$status, duration_ms:$duration_ms, bytes:$bytes}' >> "$out_file"
  done
}

run_git_clone_worker() {
  local step_name="$1"
  local worker="$2"
  local end_epoch="$3"
  local out_file="$4"

  local idx=0
  while [[ "$(date +%s)" -lt "$end_epoch" ]]; do
    idx=$((idx + 1))
    local project_num=$(( (idx % SYNTH_PROJECTS) + 1 ))
    local project="perf/project-${project_num}"
    local clone_dir="${WORK_DIR}/load/clone-${worker}-${idx}"
    rm -rf "$clone_dir"

    local start_ns end_ns duration_ms status
    start_ns="$(date +%s%N)"
    if git clone --quiet "${GERRIT_AUTH_BASE_URL}/${project}" "$clone_dir" >/dev/null 2>&1; then
      status="ok"
    else
      status="fail"
    fi
    end_ns="$(date +%s%N)"
    duration_ms="$(( (end_ns - start_ns) / 1000000 ))"

    rm -rf "$clone_dir"

    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg step "$step_name" \
      --arg worker "$worker" \
      --arg project "$project" \
      --arg status "$status" \
      --argjson duration_ms "$duration_ms" \
      '{timestamp:$ts, step:$step, type:"git_clone", worker:$worker, project:$project, status:$status, duration_ms:$duration_ms}' >> "$out_file"
  done
}

run_git_push_worker() {
  local step_name="$1"
  local worker="$2"
  local end_epoch="$3"
  local out_file="$4"

  local project_num=$(( (worker % SYNTH_PROJECTS) + 1 ))
  local project="perf/project-${project_num}"
  local repo_dir="${WORK_DIR}/load/push-${worker}"

  rm -rf "$repo_dir"
  if ! git clone --quiet "${GERRIT_AUTH_BASE_URL}/${project}" "$repo_dir" >/dev/null 2>&1; then
    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg step "$step_name" \
      --arg worker "$worker" \
      --arg project "$project" \
      '{timestamp:$ts, step:$step, type:"git_push_refs_for", worker:$worker, project:$project, status:"clone_setup_fail", duration_ms:0}' >> "$out_file"
    return 0
  fi

  pushd "$repo_dir" >/dev/null

  local idx=0
  while [[ "$(date +%s)" -lt "$end_epoch" ]]; do
    idx=$((idx + 1))
    git fetch origin main >/dev/null 2>&1 || true
    git checkout -B "perf-push-${worker}-${idx}" origin/main >/dev/null 2>&1 || git checkout -B "perf-push-${worker}-${idx}" main >/dev/null 2>&1

    local file="perf-push-${worker}-${idx}.txt"
    {
      echo "Synthetic perf push"
      echo "worker=${worker}"
      echo "idx=${idx}"
      echo "ts=$(date -u +%s%N)"
    } > "$file"

    git add "$file"
    git commit -q -m "Perf push worker ${worker} iteration ${idx}" || true

    local start_ns end_ns duration_ms status
    start_ns="$(date +%s%N)"
    if git push --quiet origin HEAD:refs/for/main >/dev/null 2>&1; then
      status="ok"
    else
      status="fail"
    fi
    end_ns="$(date +%s%N)"
    duration_ms="$(( (end_ns - start_ns) / 1000000 ))"

    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg step "$step_name" \
      --arg worker "$worker" \
      --arg project "$project" \
      --arg status "$status" \
      --argjson duration_ms "$duration_ms" \
      '{timestamp:$ts, step:$step, type:"git_push_refs_for", worker:$worker, project:$project, status:$status, duration_ms:$duration_ms}' >> "$out_file"

    sleep 1
  done

  popd >/dev/null
  rm -rf "$repo_dir"
}

run_load_step() {
  local step_name="$1"
  local rest_concurrency="$2"
  local git_concurrency="$3"
  local push_concurrency="$4"
  local raw_events="$5"

  log "Running load step ${step_name}: REST=${rest_concurrency}, clone=${git_concurrency}, push=${push_concurrency}, duration=${TEST_DURATION_SECONDS}s."

  capture_prometheus_snapshot "${step_name}_before"

  local end_epoch=$(( $(date +%s) + TEST_DURATION_SECONDS ))
  local pids=()

  for w in $(seq 1 "$rest_concurrency"); do
    run_rest_load_worker "$step_name" "$w" "$end_epoch" "$raw_events" &
    pids+=("$!")
  done

  for w in $(seq 1 "$git_concurrency"); do
    run_git_clone_worker "$step_name" "$w" "$end_epoch" "$raw_events" &
    pids+=("$!")
  done

  for w in $(seq 1 "$push_concurrency"); do
    run_git_push_worker "$step_name" "$w" "$end_epoch" "$raw_events" &
    pids+=("$!")
  done

  sleep "$(( TEST_DURATION_SECONDS / 2 ))"
  capture_prometheus_snapshot "${step_name}_during"

  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done

  capture_prometheus_snapshot "${step_name}_after"
}

run_performance_test() {
  log "Running stepwise performance test."

  mkdir -p "$RUN_DIR" "${WORK_DIR}/load"
  chown -R "$GERRIT_USER:$GERRIT_USER" "$TEST_ROOT"

  local raw_events="${RUN_DIR}/events.ndjson"
  : > "$raw_events"

  local idx=0
  local step rest git_clone push
  for step in $CONCURRENCY_STEPS; do
    idx=$((idx + 1))
    IFS=',' read -r rest git_clone push <<< "$step"
    [[ "$rest" =~ ^[0-9]+$ ]] || die "Invalid REST concurrency in CONCURRENCY_STEPS entry: ${step}"
    [[ "$git_clone" =~ ^[0-9]+$ ]] || die "Invalid clone concurrency in CONCURRENCY_STEPS entry: ${step}"
    [[ "$push" =~ ^[0-9]+$ ]] || die "Invalid push concurrency in CONCURRENCY_STEPS entry: ${step}"
    run_load_step "step${idx}_r${rest}_c${git_clone}_p${push}" "$rest" "$git_clone" "$push" "$raw_events"
  done

  log "Stepwise performance test completed."
}

###############################################################################
# JSON report
###############################################################################
# JSON report
###############################################################################

build_json_report() {
  log "Building JSON report: ${JSON_OUT}"

  local raw_events="${RUN_DIR}/events.ndjson"

  if [[ ! -s "$raw_events" ]]; then
    die "No events were captured."
  fi

  jq -s '
    def pct($p):
      if length == 0 then null
      else sort | .[((length - 1) * $p / 100 | floor)]
      end;

    group_by(.type) |
    map({
      type: .[0].type,
      count: length,
      ok_count: map(select(.status == "ok" or .status == "200")) | length,
      fail_count: map(select(.status != "ok" and .status != "200")) | length,
      min_ms: map(.duration_ms) | min,
      avg_ms: ((map(.duration_ms) | add) / length),
      p50_ms: (map(.duration_ms) | pct(50)),
      p90_ms: (map(.duration_ms) | pct(90)),
      p95_ms: (map(.duration_ms) | pct(95)),
      p99_ms: (map(.duration_ms) | pct(99)),
      max_ms: map(.duration_ms) | max
    })
  ' "$raw_events" > "${RUN_DIR}/summary_by_operation.json"

  jq -s '
    def pct($p):
      if length == 0 then null
      else sort | .[((length - 1) * $p / 100 | floor)]
      end;

    group_by(.step) |
    map({
      step: .[0].step,
      operations: (
        group_by(.type) |
        map({
          type: .[0].type,
          count: length,
          ok_count: map(select(.status == "ok" or .status == "200")) | length,
          fail_count: map(select(.status != "ok" and .status != "200")) | length,
          min_ms: map(.duration_ms) | min,
          avg_ms: ((map(.duration_ms) | add) / length),
          p50_ms: (map(.duration_ms) | pct(50)),
          p90_ms: (map(.duration_ms) | pct(90)),
          p95_ms: (map(.duration_ms) | pct(95)),
          p99_ms: (map(.duration_ms) | pct(99)),
          max_ms: map(.duration_ms) | max
        })
      )
    })
  ' "$raw_events" > "${RUN_DIR}/summary_by_step.json"

  local gerrit_metrics_probe_status="unknown"
  if probe_gerrit_metrics "$GERRIT_METRICS_AUTH_MODE" "${RUN_DIR}/gerrit_metrics_sample.txt"; then
    gerrit_metrics_probe_status="ok"
  else
    gerrit_metrics_probe_status="unavailable"
    : > "${RUN_DIR}/gerrit_metrics_sample.txt"
  fi

  local java_version
  java_version="$(java -version 2>&1 | tr '\n' ' ')"

  local gerrit_version_report
  gerrit_version_report="$(java -jar "$GERRIT_WAR" version 2>/dev/null || echo "unknown")"

  local os_name
  os_name="$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"

  local prometheus_snapshots_json="${RUN_DIR}/prometheus_snapshots.json"
  jq -n 'reduce inputs as $i ({}; . + {($i[0]): $i[1]})' < <(
    for f in "${RUN_DIR}"/prometheus_*.json; do
      [[ -f "$f" ]] || continue
      b=$(basename "$f" .json)
      [[ "$b" == "prometheus_snapshots" ]] && continue
      jq -c --arg k "${b#prometheus_}" '[ $k, . ]' "$f"
    done
  ) > "$prometheus_snapshots_json"

  jq -n \
    --arg run_id "$RUN_ID" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg host "$(hostname -f 2>/dev/null || hostname)" \
    --arg os "$os_name" \
    --arg java_version "$java_version" \
    --arg gerrit_version "$gerrit_version_report" \
    --arg gerrit_base_url "$GERRIT_BASE_URL" \
    --arg gerrit_test_http_user "$GERRIT_TEST_HTTP_USER" \
    --arg prometheus_url "$PROM_URL" \
    --arg gerrit_metrics_url "$GERRIT_METRICS_URL" \
    --arg gerrit_metrics_probe_status "$gerrit_metrics_probe_status" \
    --arg gerrit_metrics_auth_mode "$GERRIT_METRICS_AUTH_MODE" \
    --arg initial_gerrit_was_running "$INITIAL_GERRIT_WAS_RUNNING" \
    --arg synth_profile "$SYNTH_PROFILE" \
    --arg concurrency_steps "$CONCURRENCY_STEPS" \
    --argjson test_duration_seconds "$TEST_DURATION_SECONDS" \
    --argjson rest_concurrency "$REST_CONCURRENCY" \
    --argjson git_concurrency "$GIT_CONCURRENCY" \
    --argjson push_concurrency "$PUSH_CONCURRENCY" \
    --argjson synth_projects "$SYNTH_PROJECTS" \
    --argjson synth_initial_files "$SYNTH_INITIAL_FILES" \
    --argjson synth_initial_commits "$SYNTH_INITIAL_COMMITS" \
    --argjson synth_changes_per_project "$SYNTH_CHANGES_PER_PROJECT" \
    --argjson synth_large_files_per_project "$SYNTH_LARGE_FILES_PER_PROJECT" \
    --argjson synth_large_file_kb "$SYNTH_LARGE_FILE_KB" \
    --slurpfile summary "${RUN_DIR}/summary_by_operation.json" \
    --slurpfile step_summary "${RUN_DIR}/summary_by_step.json" \
    --slurpfile prometheus_snapshots "$prometheus_snapshots_json" \
    '{
      run: {
        run_id: $run_id,
        timestamp_utc: $timestamp,
        host: $host,
        os: $os
      },
      software: {
        java_version: $java_version,
        gerrit_version: $gerrit_version,
        gerrit_base_url: $gerrit_base_url,
        gerrit_test_http_user: $gerrit_test_http_user,
        prometheus_url: $prometheus_url,
        gerrit_metrics_url: $gerrit_metrics_url,
        gerrit_metrics_probe_status: $gerrit_metrics_probe_status,
        gerrit_metrics_auth_mode: $gerrit_metrics_auth_mode
      },
      workload: {
        test_duration_seconds_per_step: $test_duration_seconds,
        concurrency_steps: $concurrency_steps,
        legacy_single_step_defaults: {
          rest_concurrency: $rest_concurrency,
          git_clone_concurrency: $git_concurrency,
          git_push_concurrency: $push_concurrency
        },
        synthetic_profile: $synth_profile,
        synthetic_projects: $synth_projects,
        synthetic_initial_files_per_project: $synth_initial_files,
        synthetic_initial_commits_per_project: $synth_initial_commits,
        synthetic_review_changes_per_project: $synth_changes_per_project,
        synthetic_large_files_per_project: $synth_large_files_per_project,
        synthetic_large_file_kb: $synth_large_file_kb
      },
      startup_state: {
        initial_gerrit_was_running: $initial_gerrit_was_running
      },
      operation_summary: $summary[0],
      step_operation_summary: $step_summary[0],
      prometheus_snapshots: ($prometheus_snapshots[0] // {}),
      raw_files: {
        event_ndjson: "events.ndjson",
        summary_by_operation_json: "summary_by_operation.json",
        summary_by_step_json: "summary_by_step.json",
        gerrit_metrics_sample_txt: "gerrit_metrics_sample.txt",
        prometheus_snapshot_json_glob: "prometheus_*.json"
      }
    }' > "$JSON_OUT"

  log "JSON report written to: ${JSON_OUT}"
}

###############################################################################
# Main
###############################################################################

main() {
  log "Starting Gerrit performance lab setup (v20)."

  install_packages
  create_gerrit_user
  handle_initial_gerrit_state
  download_gerrit
  init_gerrit
  install_prometheus_plugin
  create_gerrit_service
  start_gerrit
  select_gerrit_metrics_auth_mode
  configure_prometheus
  verify_prometheus_gerrit_scrape
  setup_git_identity
  validate_gerrit_http_credentials
  configure_test_permissions
  validate_http_git_push_permissions
  verify_prometheus_gerrit_scrape
  create_synthetic_projects
  run_performance_test
  build_json_report

  echo
  echo "Done."
  echo
  echo "Primary JSON result:"
  echo "  ${JSON_OUT}"
  echo
  echo "Raw event stream:"
  echo "  ${RUN_DIR}/events.ndjson"
  echo
  echo "Result directory:"
  echo "  ${RUN_DIR}"
  echo
  echo "Gerrit:"
  echo "  ${GERRIT_BASE_URL}"
  echo
  echo "Prometheus:"
  echo "  ${PROM_URL}"
  echo
  echo "Send me this file for analysis:"
  echo "  ${JSON_OUT}"
}

main "$@"
