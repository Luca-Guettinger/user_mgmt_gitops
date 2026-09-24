#!/usr/bin/env bash
#
# Run the k6 load test in the cluster and follow it.
#
#   ./k6/run.sh                          # prod, the default target
#   ./k6/run.sh --staging                # staging instead
#   ./k6/run.sh -s assign-test.js        # load the module assignment path instead
#   ./k6/run.sh -p 25                    # stress: 25 VUs at the peak (default 9)
#
# What it does: rebuilds the ConfigMap from the chosen script, replaces the Job,
# and tails its logs. Watch the "k6 Load Test" dashboard in Grafana while it
# runs - that is where the HPA reaction shows up.
#
# Notes
#   * The target is production, on purpose: that is where Aufgabe 2 was
#     demonstrated, and where the HPA has four replicas to work with. The run
#     only registers users, so the cost of pointing it there is test rows.
#   * The Job talks to the backend ClusterIP Service from inside the cluster,
#     so kube-proxy spreads the requests over every ready replica. The old
#     local/load-test.sh used kubectl port-forward, which pinned all traffic
#     to one pod.
#   * The run takes 10 minutes by design: hpa.yaml waits 60s of sustained load
#     before scaling up and 300s of quiet before scaling back down.
#   * load-test.js registers one user per iteration, so the rows add up - clean
#     up with the DELETE in the runbook. assign-test.js creates one user in
#     setup() and then only assigns, so it adds nothing.
#   * -s only changes which file is read. The ConfigMap key stays load-test.js,
#     because that is the path k6-job.yaml runs.

set -euo pipefail

NAMESPACE_K6="k6"
NAMESPACE_APP="user-mgmt"
TARGET="http://user-mgmt-prod-backend.user-mgmt.svc.cluster.local:8080"
SCRIPT="load-test.js"
TEST_ID="$(date +%Y%m%d-%H%M%S)"
PEAK_VUS=9
FOLLOW=1

usage() { sed -n '2,28p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --staging)
      NAMESPACE_APP="user-mgmt-staging"
      TARGET="http://user-mgmt-staging-backend.user-mgmt-staging.svc.cluster.local:8080"
      shift ;;
    -u|--url)          TARGET="$2"; shift 2 ;;
    # Only used for the HPA readout at the end, so -u can point anywhere.
    -n|--namespace)    NAMESPACE_APP="$2"; shift 2 ;;
    -s|--script)       SCRIPT="$2"; shift 2 ;;
    -t|--test-id)      TEST_ID="$2"; shift 2 ;;
    -p|--peak-vus)     PEAK_VUS="$2"; shift 2 ;;
    --no-follow)       FOLLOW=0; shift ;;
    -h|--help)         usage ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found"
cd "$(dirname "$0")/.."

case "$TARGET" in
  *user-mgmt-prod*|*tf.nightnode.io*) echo "!!  PRODUCTION target: $TARGET" ;;
esac

echo "==> context:   $(kubectl config current-context)"
echo "==> target:    $TARGET"
echo "==> namespace: $NAMESPACE_APP"
echo "==> test id:   $TEST_ID"

# The namespace has to exist before the ConfigMaps go into it.
kubectl get namespace "$NAMESPACE_K6" >/dev/null 2>&1 \
  || kubectl create namespace "$NAMESPACE_K6"

# The script is a real file, so it stays readable and lintable; the ConfigMap
# is generated from it rather than the other way round.
kubectl -n "$NAMESPACE_K6" create configmap k6-script \
  --from-file=load-test.js=k6/"$SCRIPT" \
  --dry-run=client -o yaml | kubectl apply -f -

# Per-run settings. They live here rather than in k6-job.yaml because a Job's
# pod template cannot be changed after the Job is created.
kubectl -n "$NAMESPACE_K6" create configmap k6-config \
  --from-literal=BASE_URL="$TARGET" \
  --from-literal=TEST_ID="$TEST_ID" \
  --from-literal=PEAK_VUS="$PEAK_VUS" \
  --dry-run=client -o yaml | kubectl apply -f -

# Same reason: a re-run means deleting the old Job first.
kubectl -n "$NAMESPACE_K6" delete job k6-load-test --ignore-not-found --wait=true

kubectl apply -f k6/k6-job.yaml

echo "==> waiting for the pod to start"
kubectl -n "$NAMESPACE_K6" wait --for=condition=Ready pod \
  -l job-name=k6-load-test --timeout=120s

if [ "$FOLLOW" -eq 1 ]; then
  kubectl -n "$NAMESPACE_K6" logs -f job/k6-load-test
  echo
  echo "==> HPA afterwards (scale-down takes ~5 more minutes):"
  kubectl -n "$NAMESPACE_APP" get hpa,deploy -l app.kubernetes.io/component=backend
fi
