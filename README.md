# k8s-deploy

[![verify](https://github.com/keerthikondisetty/k8s-deploy/actions/workflows/verify.yml/badge.svg)](https://github.com/keerthikondisetty/k8s-deploy/actions/workflows/verify.yml) [![licence](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)

Kubernetes manifests and a Helm chart for
[devops-demo-app](https://github.com/keerthikondisetty/devops-demo-app),
verified by actually deploying them to a cluster rather than by linting the
YAML.

```bash
./scripts/kind-verify.sh
```

Creates a kind cluster, applies everything, runs twelve checks against the
running workload, and deletes the cluster.

```
   PASS postgres is ready
   PASS all replicas rolled out
   PASS the worker rolled out
   PASS 3 replicas ready
   PASS running as uid 10001
   PASS the root filesystem rejects writes
   PASS liveness /healthz, readiness /readyz
   PASS signed delivery accepted (202), unsigned refused (401)
   PASS 1 delivery/deliveries processed by a worker
   PASS the application can resolve postgres
   PASS 1 disruption(s) allowed, so a node can be drained
   PASS the worker logged a clean shutdown
```

## Why a cluster and not just kubeconform

`kubeconform` proves the YAML matches a schema. It cannot tell you whether the
pods start, whether the probes point at endpoints that exist, or whether the
NetworkPolicy you wrote lets the application reach its own database. Every
check in that script exists because the corresponding mistake is easy to make
and invisible to a linter.

The uid check is the clearest example. It asks the *running container*:

```bash
uid=$(kubectl -n demo exec deploy/demo-app -- id -u)
```

Reading `runAsUser` back out of my own manifest would only prove I can grep a
file I just wrote.

## Two Deployments, one image

The receiver and the worker are separate Deployments running the same image
with different commands. That is the decision I would lead with.

They scale on completely different signals: the receiver on request rate, the
worker on how far behind the queue is. In one pod, scaling for a burst of
webhooks also scales the thing consuming them, and neither number is ever
right.

It also changes what "healthy" means for each. The receiver has liveness and
readiness over HTTP. The worker has **no readiness probe at all**, because
readiness controls Service endpoints and nothing routes traffic to a worker.
Its liveness is an exec probe asking the only question that matters for that
process: can it reach the queue.

The `terminationGracePeriodSeconds: 60` on the worker is what makes graceful
shutdown real. Kubernetes sends SIGTERM, waits, then SIGKILLs. The worker
finishes the delivery in its hands and exits; set it too low and it gets
killed mid-delivery, leaving a row in `processing` that only the stuck-reclaim
recovers.

The verification script deletes a worker pod and greps its log for the
clean-shutdown line, because that behaviour is invisible until the day it
matters.

## The decisions worth asking me about

**Three probes, three different questions.**

| Probe | Path | Asks |
|---|---|---|
| `startupProbe` | `/healthz` | has it finished booting? |
| `livenessProbe` | `/healthz` | is the process wedged? |
| `readinessProbe` | `/readyz` | can it serve traffic? |

Liveness and readiness point at *different endpoints*, and that is the whole
point. `/healthz` does not touch the database. If liveness checked Postgres, a
database blip would fail the check on every pod at once, Kubernetes would
restart all of them, and that does nothing for the database while throwing away
every warm process. `/readyz` does check, so an affected pod leaves the Service
and returns on its own.

The startup probe is what stops a slow boot being mistaken for a crash loop:
while it is failing, the other two do not run at all.

The verification script asserts the two paths differ, because collapsing them
back into one is an easy and quiet regression.

**A memory limit but no CPU limit.** Deliberate, and the one people argue with
me about. Exceeding a memory limit gets the process OOMKilled, so the limit
protects the node from a leak. A CPU limit only throttles, and throttling a
latency-sensitive service to protect a node that is not under pressure makes
the incident worse, not better. Requests are set for both, so the scheduler
still packs correctly.

**`maxUnavailable: 0`.** With three replicas and the default of 1, a third of
capacity disappears the instant a deploy starts. Surge instead: bring up the
new pod, wait for it to pass readiness, then retire an old one.

**A PodDisruptionBudget, and the chart refuses a broken one.** Without a PDB,
draining a node for an upgrade can evict every replica at once, which is a
self-inflicted outage during routine maintenance. But a PDB whose
`minAvailable` equals the replica count blocks *every* drain forever, and you
discover that mid-upgrade at the worst moment. So the chart fails the render:

```
minAvailable (3) must be below minReplicas (3), or no node can ever be drained
```

`minAvailable` rather than `maxUnavailable`, because it keeps meaning the same
thing when the HPA changes the replica count.

**Default-deny NetworkPolicy.** Without one, every pod in the cluster can reach
every other pod. This is the highest-value file here and the one most often
missing. The application may reach Postgres and DNS; Postgres may be reached by
the application and has no egress rules at all.

The DNS rule is the part everyone forgets on their first NetworkPolicy. Miss
it and every name lookup fails, which presents as "the application is broken"
rather than "the network policy is wrong". The verification script resolves a
hostname from inside a pod specifically to catch that.

The worker's policy has `ingress: []`, meaning none at all. Nothing should
ever connect to it, and saying so explicitly means an accidental Service
pointing at it does not quietly start working.

The policy also caught a mistake in my own test. The traffic check originally
ran `curl` from a throwaway pod in the same namespace, and it hung: the
default-deny rule correctly refuses anything that is not ingress-nginx. The
policy was right and the test was wrong. It now uses `kubectl port-forward`,
which goes through the API server and exercises the Service selector, the pod
and the application without crossing the pod network.

Note that enforcement depends on the CNI. kind's default does not implement
NetworkPolicy, so on a kind cluster these objects are accepted and inert;
Calico or Cilium enforce them. That is worth knowing before you rely on a
green local run as proof the policy works.

**`topologySpreadConstraints` with `ScheduleAnyway`.** Spread replicas across
nodes, because three replicas on one node buys you nothing when that node goes
away. `ScheduleAnyway` rather than `DoNotSchedule` so a single-node cluster,
like kind or a small dev environment, does not leave two pods `Pending`
forever.

**Pod Security Admission on the namespace, enforcing `restricted`.** Without
the label the namespace has no baseline and a privileged pod is admitted
without comment. `warn` and `audit` are set too, so a manifest that would be
rejected shows up in review rather than at apply time.

## Manifests or the chart

Both, on purpose. The plain manifests are readable top to bottom and are what
I would point at in an interview. The chart is what you would actually run
across environments.

The chart adds two things worth noting:

```yaml
{{- if not .Values.autoscaling.enabled }}
replicas: {{ .Values.replicaCount }}
{{- end }}
```

`replicas` is omitted entirely when the HPA is on. Set both and every
`helm upgrade` resets the count to the chart's value, the HPA scales it back,
and you get pods cycling for no visible reason.

```yaml
checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

Without that annotation, a `helm upgrade` that changes the ConfigMap updates
the object and leaves every pod running the old values.

## The secret

`manifests/10-config.yaml` contains a plain `Secret`. It is a throwaway for a
local kind cluster and is not used anywhere else.

In a real cluster this is an ExternalSecret pointing at Secrets Manager, or a
sealed secret. A Kubernetes `Secret` is base64, which is encoding, not
encryption, and anyone with `get` on the namespace reads it. The chart takes
`existingSecret` and never templates a value, because a chart's values end up
in git, in CI logs and in `helm get values`.

## Loading the image into kind

One line that took three attempts:

```bash
docker save --platform "linux/$(docker version --format '{{.Server.Arch}}')" ...
```

`kind load docker-image` imports with `--all-platforms`. The published image is
multi-arch, and Docker's containerd store keeps the whole index, so both that
and a plain `docker save` fail with `content digest ...: not found` for the
platform this machine never pulled. `docker save --platform` exports only the
one the cluster is going to run.

That is also why the app repository builds `linux/amd64,linux/arm64`. The
first run of this script failed with `no matching manifest for linux/arm64/v8`
because CI had published amd64 only.

## Postgres here, RDS in production

The StatefulSet is a single replica with a PVC. That is right for a demo and
wrong for production: no replication, no failover. Production uses RDS, see
[terraform-aws-infra](https://github.com/keerthikondisetty/terraform-aws-infra),
because running a database well is a full-time job, and managed Postgres costs
less than doing it badly.

## CI

Two jobs. `static` validates the manifests against real API schemas, renders
the chart and validates the output (a chart can lint cleanly and still produce
an object the API server rejects), and asserts the PDB guard actually fires.
`cluster` spins up kind and runs the same script this README opens with.

## Layout

```
manifests/          namespace, config, postgres, receiver Deployment,
                    worker Deployment, service, ingress, HPA, PDBs,
                    network policies
chart/              the same objects, parameterised
scripts/kind-verify.sh   create a cluster, deploy, prove it works
```

## Licence

MIT.
