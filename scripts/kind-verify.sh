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

  require kind kubectl docker
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

  check_replicas
  check_security_context
  check_probes_are_distinct
  check_traffic
  check_networkpolicy
  check_pdb

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
  log "the service actually serves"
  local code
  code=$(kubectl -n "${NAMESPACE}" run curl-test --rm -i --restart=Never \
    --image=curlimages/curl:8.11.1 --quiet -- \
    -s -o /dev/null -w '%{http_code}' \
    -X POST http://demo-app/shorten \
    -H 'content-type: application/json' \
    -d '{"url":"https://example.com/k8s"}' 2>/dev/null | tr -d '\r')

  if [[ "${code}" == "201" ]]; then
    pass "created a short link through the Service (HTTP ${code})"
  else
    fail "expected 201 from the Service, got '${code}'"
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
