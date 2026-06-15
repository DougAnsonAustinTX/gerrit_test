#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Gerrit basic performance lab for Ubuntu 24.04
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
#   chmod +x gerrit_perf_lab_v14.sh
#   sudo ./gerrit_perf_lab_v14.sh
#
# Optional:
#   sudo GERRIT_VERSION=3.11.2 TEST_DURATION_SECONDS=180 ./gerrit_perf_lab_v14.sh
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

SYNTH_PROJECTS="${SYNTH_PROJECTS:-3}"
SYNTH_INITIAL_FILES="${SYNTH_INITIAL_FILES:-80}"
SYNTH_INITIAL_COMMITS="${SYNTH_INITIAL_COMMITS:-20}"
SYNTH_CHANGES_PER_PROJECT="${SYNTH_CHANGES_PER_PROJECT:-15}"

TEST_DURATION_SECONDS="${TEST_DURATION_SECONDS:-120}"
REST_CONCURRENCY="${REST_CONCURRENCY:-6}"
GIT_CONCURRENCY="${GIT_CONCURRENCY:-3}"
PUSH_CONCURRENCY="${PUSH_CONCURRENCY:-2}"

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

capture_prometheus_snapshot() {
  local label="$1"
  local file="${RUN_DIR}/prometheus_${label}.json"

  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson cpu "$(prom_query '100 - avg(rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100' | jq '.data.result // []' 2>/dev/null || echo '[]')" \
    --argjson mem "$(prom_query '100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))' | jq '.data.result // []' 2>/dev/null || echo '[]')" \
    --argjson diskio "$(prom_query 'rate(node_disk_io_time_seconds_total[1m])' | jq '.data.result // []' 2>/dev/null || echo '[]')" \
    --argjson gerrit_up "$(prom_query 'up{job="gerrit"}' | jq '.data.result // []' 2>/dev/null || echo '[]')" \
    --argjson node_up "$(prom_query 'up{job="node"}' | jq '.data.result // []' 2>/dev/null || echo '[]')" \
    '{
      timestamp: $ts,
      cpu_percent: $cpu,
      memory_used_percent: $mem,
      disk_io_time_rate: $diskio,
      gerrit_up: $gerrit_up,
      node_up: $node_up
    }' > "$file"
}

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
    bearerToken = ${PROM_BEARER_TOKEN}
EOF_CONFIG

  chown -R "$GERRIT_USER:$GERRIT_USER" "$GERRIT_SITE"
}

install_prometheus_plugin() {
  log "Attempting to install metrics-reporter-prometheus plugin."

  local plugin_target="${GERRIT_SITE}/plugins/metrics-reporter-prometheus.jar"

  if [[ -f "$plugin_target" ]]; then
    log "Prometheus plugin already present."
    chown "$GERRIT_USER:$GERRIT_USER" "$plugin_target"
    return
  fi

  local gerrit_minor="${GERRIT_VERSION%.*}"
  local candidates=(
    "https://gerrit-ci.gerritforge.com/job/plugin-metrics-reporter-prometheus-bazel-stable-${gerrit_minor}/lastSuccessfulBuild/artifact/bazel-bin/plugins/metrics-reporter-prometheus/metrics-reporter-prometheus.jar"
    "https://gerrit-ci.gerritforge.com/job/plugin-metrics-reporter-prometheus-bazel-master/lastSuccessfulBuild/artifact/bazel-bin/plugins/metrics-reporter-prometheus/metrics-reporter-prometheus.jar"
  )

  local downloaded="false"
  for url in "${candidates[@]}"; do
    log "Trying plugin URL: $url"
    if curl -fL "$url" -o "$plugin_target"; then
      downloaded="true"
      break
    fi
  done

  if [[ "$downloaded" != "true" ]]; then
    warn "Could not download metrics-reporter-prometheus plugin automatically."
    warn "The test will still collect node_exporter and client-side metrics."
    warn "You can manually place metrics-reporter-prometheus.jar at: ${plugin_target}"
    rm -f "$plugin_target"
    return
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
state: invalid
EOF_PROM

  # Rewrite in two steps to avoid partially written YAML if an edit is interrupted.
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
    authorization:
      type: "Bearer"
      credentials: "${PROM_BEARER_TOKEN}"
    static_configs:
      - targets: ["127.0.0.1:${GERRIT_HTTP_PORT}"]

global:
  scrape_interval: 5s
  evaluation_interval: 5s
EOF_PROM

  systemctl restart prometheus-node-exporter
  systemctl restart prometheus

  if ! wait_for_http "${PROM_URL}/-/ready" 120; then
    systemctl status prometheus --no-pager || true
    journalctl -u prometheus -n 120 --no-pager || true
    die "Timed out waiting for Prometheus at ${PROM_URL}"
  fi
}

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
  local worker="$1"
  local end_epoch="$2"
  local out_file="$3"

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
      --arg worker "$worker" \
      --arg status "$status" \
      --argjson duration_ms "$duration_ms" \
      --argjson bytes "$bytes" \
      '{timestamp:$ts, type:"rest_change_query", worker:$worker, status:$status, duration_ms:$duration_ms, bytes:$bytes}' >> "$out_file"
  done
}

run_git_clone_worker() {
  local worker="$1"
  local end_epoch="$2"
  local out_file="$3"

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
      --arg worker "$worker" \
      --arg project "$project" \
      --arg status "$status" \
      --argjson duration_ms "$duration_ms" \
      '{timestamp:$ts, type:"git_clone", worker:$worker, project:$project, status:$status, duration_ms:$duration_ms}' >> "$out_file"
  done
}

run_git_push_worker() {
  local worker="$1"
  local end_epoch="$2"
  local out_file="$3"

  local project_num=$(( (worker % SYNTH_PROJECTS) + 1 ))
  local project="perf/project-${project_num}"
  local repo_dir="${WORK_DIR}/load/push-${worker}"

  rm -rf "$repo_dir"
  if ! git clone --quiet "${GERRIT_AUTH_BASE_URL}/${project}" "$repo_dir" >/dev/null 2>&1; then
    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg worker "$worker" \
      --arg project "$project" \
      '{timestamp:$ts, type:"git_push_refs_for", worker:$worker, project:$project, status:"clone_setup_fail", duration_ms:0}' >> "$out_file"
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
      --arg worker "$worker" \
      --arg project "$project" \
      --arg status "$status" \
      --argjson duration_ms "$duration_ms" \
      '{timestamp:$ts, type:"git_push_refs_for", worker:$worker, project:$project, status:$status, duration_ms:$duration_ms}' >> "$out_file"

    sleep 1
  done

  popd >/dev/null
  rm -rf "$repo_dir"
}

run_performance_test() {
  log "Running performance test for ${TEST_DURATION_SECONDS} seconds."

  mkdir -p "$RUN_DIR" "${WORK_DIR}/load"
  chown -R "$GERRIT_USER:$GERRIT_USER" "$TEST_ROOT"

  local raw_events="${RUN_DIR}/events.ndjson"
  : > "$raw_events"

  capture_prometheus_snapshot "before"

  local end_epoch=$(( $(date +%s) + TEST_DURATION_SECONDS ))
  local pids=()

  for w in $(seq 1 "$REST_CONCURRENCY"); do
    run_rest_load_worker "$w" "$end_epoch" "$raw_events" &
    pids+=("$!")
  done

  for w in $(seq 1 "$GIT_CONCURRENCY"); do
    run_git_clone_worker "$w" "$end_epoch" "$raw_events" &
    pids+=("$!")
  done

  for w in $(seq 1 "$PUSH_CONCURRENCY"); do
    run_git_push_worker "$w" "$end_epoch" "$raw_events" &
    pids+=("$!")
  done

  sleep "$(( TEST_DURATION_SECONDS / 2 ))"
  capture_prometheus_snapshot "during"

  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done

  capture_prometheus_snapshot "after"

  log "Performance test completed."
}

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

  local gerrit_metrics_probe_status="unknown"
  if curl -fsS -H "Authorization: Bearer ${PROM_BEARER_TOKEN}" "$GERRIT_METRICS_URL" -o "${RUN_DIR}/gerrit_metrics_sample.txt"; then
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
    --argjson test_duration_seconds "$TEST_DURATION_SECONDS" \
    --argjson rest_concurrency "$REST_CONCURRENCY" \
    --argjson git_concurrency "$GIT_CONCURRENCY" \
    --argjson push_concurrency "$PUSH_CONCURRENCY" \
    --argjson synth_projects "$SYNTH_PROJECTS" \
    --argjson synth_initial_files "$SYNTH_INITIAL_FILES" \
    --argjson synth_initial_commits "$SYNTH_INITIAL_COMMITS" \
    --argjson synth_changes_per_project "$SYNTH_CHANGES_PER_PROJECT" \
    --slurpfile summary "${RUN_DIR}/summary_by_operation.json" \
    --slurpfile prom_before "${RUN_DIR}/prometheus_before.json" \
    --slurpfile prom_during "${RUN_DIR}/prometheus_during.json" \
    --slurpfile prom_after "${RUN_DIR}/prometheus_after.json" \
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
        gerrit_metrics_probe_status: $gerrit_metrics_probe_status
      },
      workload: {
        test_duration_seconds: $test_duration_seconds,
        rest_concurrency: $rest_concurrency,
        git_clone_concurrency: $git_concurrency,
        git_push_concurrency: $push_concurrency,
        synthetic_projects: $synth_projects,
        synthetic_initial_files_per_project: $synth_initial_files,
        synthetic_initial_commits_per_project: $synth_initial_commits,
        synthetic_review_changes_per_project: $synth_changes_per_project
      },
      operation_summary: $summary[0],
      prometheus_snapshots: {
        before: $prom_before[0],
        during: $prom_during[0],
        after: $prom_after[0]
      },
      raw_files: {
        event_ndjson: "events.ndjson",
        summary_by_operation_json: "summary_by_operation.json",
        gerrit_metrics_sample_txt: "gerrit_metrics_sample.txt",
        prometheus_before_json: "prometheus_before.json",
        prometheus_during_json: "prometheus_during.json",
        prometheus_after_json: "prometheus_after.json"
      }
    }' > "$JSON_OUT"

  log "JSON report written to: ${JSON_OUT}"
}

###############################################################################
# Main
###############################################################################

main() {
  log "Starting Gerrit performance lab setup."

  install_packages
  create_gerrit_user
  download_gerrit
  init_gerrit
  install_prometheus_plugin
  create_gerrit_service
  configure_prometheus
  start_gerrit
  setup_git_identity
  validate_gerrit_http_credentials
  configure_test_permissions
  validate_http_git_push_permissions
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
