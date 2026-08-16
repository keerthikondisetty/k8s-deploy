#!/usr/bin/env bash
#
# Create a kind cluster, apply the manifests, and prove they work.
#
# "kubeconform passed" means the YAML matches a schema. It says nothing about
# whether the pods start, whether the probes are pointed at endpoints that
# exist, or whether the NetworkPolicy you wrote lets the application reach its
# own database. Every check below has failed for me at least once.
#
#   ./scripts/kind-verify.sh                      # create, verify, delete
#   KEEP=1 ./scripts/kind-verify.sh               # leave the cluster up
#   ./scripts/kind-verify.sh --existing-cluster   # use the current context

set -Eeuo pipefail
IFS=$'\n\t'

readonly CLUSTER="${CLUSTER:-k8s-deploy-verify}"
readonly NAMESPACE=demo
readonly IMAGE="${IMAGE:-ghcr.io/keerthikondisetty/devops-demo-app:latest}"

PASSED=0
FAILED=0
CREATE_CLUSTER=1

log()  { printf '\n=== %s\n' "$*" >&2; }
pass() { printf '   PASS %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() { printf '   FAIL %s\n' "$*"; FAILED=$((FAILED + 1)); }
die()  { printf '[fatal] %s\n' "$*" >&2; exit 1; }

cleanup() {
  # Nothing to clean up if we did not create it. In CI the cluster belongs to
  # helm/kind-action, and deleting it here would break the steps after this
  # one.
  if (( CREATE_CLUSTER == 0 )); then
    return
  fi

  if [[ "${KEEP:-0}" == "1" ]]; then
    printf '\nCluster %s left running. Delete it with: kind delete cluster --name %s\n' \
      "${CLUSTER}" "${CLUSTER}" >&2
    return
  fi
  kind delete cluster --name "${CLUSTER}" >/dev/null 2>&1 || true
}

require() {
  for tool in "$@"; do
    command -v "${tool}" >/dev/null 2>&1 || die "${tool} is not installed"
  done
}

main() {
  while (( $# )); do
    case "$1" in
      --existing-cluster) CREATE_CLUSTER=0; shift ;;
      -h|--help) sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  require kind kubectl docker openssl
  docker info >/dev/null 2>&1 || die "the docker daemon is not running"

  trap cleanup EXIT

  if (( CREATE_CLUSTER )); then
    log "creating cluster ${CLUSTER}"
    kind create cluster --name "${CLUSTER}" --wait 120s >/dev/null
  else
    log "using the existing cluster: $(kubectl config current-context)"
  fi

  log "loading the application image"
  # Pull once on the host and side-load, rather than letting three pods each
  # pull from ghcr and rate-limit the run.
  docker pull --quiet "${IMAGE}" >/dev/null 2>&1 \
    || die "could not pull ${IMAGE}. Has the app repository published one yet?"

  # Via a single-platform tar archive, not `kind load docker-image`.
  #
  # The published image is multi-arch. kind imports with --all-platforms and
  # Docker's containerd store keeps the whole index, so both the direct load
  # and a plain `docker save` fail with "content digest ...: not found" for
  # the platform this machine never pulled. `docker save --platform` exports
  # only the one the cluster is actually going to run.
  local archive platform
  platform="linux/$(docker version --format '{{.Server.Arch}}')"
  archive="$(mktemp -t demo-app-XXXXXX.tar)"

  docker save --platform "${platform}" "${IMAGE}" -o "${archive}" \
    || die "could not export ${IMAGE} for ${platform}"
  kind load image-archive "${archive}" --name "${CLUSTER}" >/dev/null
  rm -f "${archive}"

  log "applying the manifests"
  kubectl apply -f manifests/ >/dev/null

  log "waiting for the database"
  kubectl -n "${NAMESPACE}" rollout status statefulset/postgres --timeout=180s >/dev/null \
    || die "postgres never became ready"
  pass "postgres is ready"

  log "waiting for the application"
  if kubectl -n "${NAMESPACE}" rollout status deployment/demo-app --timeout=180s >/dev/null; then
    pass "all replicas rolled out"
  else
    fail "the deployment never became ready"
    kubectl -n "${NAMESPACE}" describe pods -l app=demo-app | tail -40
    return
  fi

  log "waiting for the worker"
  if kubectl -n "${NAMESPACE}" rollout status deployment/demo-worker --timeout=180s >/dev/null; then
    pass "the worker rolled out"
  else
    fail "the worker never became ready"
  fi

  check_replicas
  check_security_context
  check_probes_are_distinct
  check_traffic
  check_worker_drains_the_queue
  check_networkpolicy
  check_pdb
  check_worker_shuts_down_gracefully

  printf '\n   %d passed, %d failed\n' "${PASSED}" "${FAILED}"
  (( FAILED == 0 )) || exit 1
}

check_replicas() {
  log "replica count"
  local ready
  ready=$(kubectl -n "${NAMESPACE}" get deployment demo-app -o jsonpath='{.status.readyReplicas}')
  if [[ "${ready}" == "3" ]]; then
    pass "3 replicas ready"
  else
    fail "expected 3 ready replicas, got ${ready:-0}"
  fi
}

check_security_context() {
  log "the container is not running as root"
  # Asked of the running container rather than read back out of the YAML.
  # Reading the manifest would only prove I can grep my own file.
  local uid
  uid=$(kubectl -n "${NAMESPACE}" exec deploy/demo-app -- id -u 2>/dev/null || echo "")
  if [[ "${uid}" == "10001" ]]; then
    pass "running as uid 10001"
  else
    fail "expected uid 10001, got '${uid}'"
  fi

  log "the root filesystem is read only"
  if kubectl -n "${NAMESPACE}" exec deploy/demo-app -- \
      sh -c 'touch /should-not-work' >/dev/null 2>&1; then
    fail "wrote to the root filesystem; readOnlyRootFilesystem is not in effect"
  else
    pass "the root filesystem rejects writes"
  fi
}

check_probes_are_distinct() {
  log "liveness and readiness point at different endpoints"
  # The mistake this catches: pointing both at the same path. Then a database
  # outage fails liveness too and every pod restarts, which fixes nothing and
  # loses the warm process.
  local liveness readiness
  liveness=$(kubectl -n "${NAMESPACE}" get deployment demo-app \
    -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}')
  readiness=$(kubectl -n "${NAMESPACE}" get deployment demo-app \
    -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}')

  if [[ "${liveness}" != "${readiness}" ]]; then
    pass "liveness ${liveness}, readiness ${readiness}"
  else
    fail "both probes point at ${liveness}; a database blip will restart every pod"
  fi
}

check_traffic() {
  log "the receiver accepts a signed delivery"

  # port-forward rather than a curl pod. The default-deny NetworkPolicy in this
  # namespace correctly refuses anything that is not ingress-nginx, so a
  # throwaway curl pod hangs. port-forward goes through the API server and
  # exercises the Service selector, the pod and the application without
  # crossing the pod network.
  local pf_pid code body signature secret="local-kind-secret"
  kubectl -n "${NAMESPACE}" port-forward service/demo-app 18080:80 >/dev/null 2>&1 &
  pf_pid=$!

  local _
  for _ in $(seq 1 20); do
    curl -sf "http://localhost:18080/healthz" >/dev/null 2>&1 && break
    sleep 1
  done

  body='{"event":"push","from":"kind-verify"}'
  signature="sha256=$(printf '%s' "${body}" \
    | openssl dgst -sha256 -hmac "${secret}" -hex | awk '{print $NF}')"

  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST http://localhost:18080/webhooks/github \
    -H 'content-type: application/json' \
    -H "X-Delivery-Id: kind-$(date +%s)-${RANDOM}" \
    -H "X-Signature-256: ${signature}" \
    --data-binary "${body}" 2>/dev/null || echo "000")

  # And an unsigned one, which must be refused. A receiver that accepts
  # anything is worse than one that is down.
  local unsigned
  unsigned=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST http://localhost:18080/webhooks/github \
    -H 'content-type: application/json' \
    -H "X-Delivery-Id: kind-unsigned" \
    -H "X-Signature-256: sha256=deadbeef" \
    --data-binary "${body}" 2>/dev/null || echo "000")

  kill "${pf_pid}" 2>/dev/null || true
  wait "${pf_pid}" 2>/dev/null || true

  if [[ "${code}" != "202" ]]; then
    fail "expected 202 for a signed delivery, got '${code}'"
  elif [[ "${unsigned}" != "401" ]]; then
    fail "expected 401 for an unsigned delivery, got '${unsigned}'"
  else
    pass "signed delivery accepted (202), unsigned refused (401)"
  fi
}

check_worker_drains_the_queue() {
  log "the worker actually processes what the receiver queued"

  # The check that proves the two Deployments are wired to the same queue.
  # The receiver returning 202 only means it wrote a row; this waits for a
  # worker to pick it up and finish it.
  local _ done_count=0
  for _ in $(seq 1 30); do
    done_count=$(kubectl -n "${NAMESPACE}" exec statefulset/postgres -- \
      psql -U hooks -d hooks -tAc "SELECT count(*) FROM deliveries WHERE status='done'" \
      2>/dev/null | tr -d '[:space:]')
    [[ "${done_count:-0}" -ge 1 ]] && break
    sleep 2
  done

  if [[ "${done_count:-0}" -ge 1 ]]; then
    pass "${done_count} delivery/deliveries processed by a worker"
  else
    fail "nothing was processed; the worker is not draining the queue"
    kubectl -n "${NAMESPACE}" logs -l app=demo-worker --tail=20 || true
  fi
}

check_worker_shuts_down_gracefully() {
  log "the worker finishes its work on SIGTERM rather than dying"

  # The behaviour terminationGracePeriodSeconds exists for. Delete a pod and
  # look for the clean-shutdown line; if the handler exited immediately, or
  # ignored the signal until SIGKILL, it is not there.
  local pod
  pod=$(kubectl -n "${NAMESPACE}" get pods -l app=demo-worker \
    -o jsonpath='{.items[0].metadata.name}')

  kubectl -n "${NAMESPACE}" delete pod "${pod}" --wait=false >/dev/null 2>&1

  local _ logs=""
  for _ in $(seq 1 20); do
    logs=$(kubectl -n "${NAMESPACE}" logs "${pod}" --tail=20 2>/dev/null || echo "")
    [[ "${logs}" == *"shut down cleanly"* ]] && break
    sleep 2
  done

  if [[ "${logs}" == *"shut down cleanly"* ]]; then
    pass "the worker logged a clean shutdown"
  else
    fail "no clean shutdown in the log; SIGTERM is being ignored or the handler exits immediately"
  fi
}

check_networkpolicy() {
  log "the NetworkPolicy allows DNS"
  # Forgetting the DNS egress rule is the classic first NetworkPolicy mistake.
  # Every lookup fails and the symptom looks like a broken application.
  if kubectl -n "${NAMESPACE}" exec deploy/demo-app -- \
      python3 -c "import socket; socket.gethostbyname('postgres')" >/dev/null 2>&1; then
    pass "the application can resolve postgres"
  else
    fail "DNS resolution failed; the egress rule for kube-system is missing or wrong"
  fi
}

check_pdb() {
  log "the disruption budget is satisfiable"
  # A PDB whose minAvailable equals the replica count blocks every drain
  # forever, and you find out during a node upgrade at the worst moment.
  local allowed
  allowed=$(kubectl -n "${NAMESPACE}" get pdb demo-app -o jsonpath='{.status.disruptionsAllowed}')
  if [[ "${allowed:-0}" -ge 1 ]]; then
    pass "${allowed} disruption(s) allowed, so a node can be drained"
  else
    fail "the PDB allows no disruptions; every node drain will hang"
  fi
}

main "$@"
