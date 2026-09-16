#!/usr/bin/env bash
#
# Drive HTTP load at the backend and watch the HPA react.
#
# Runs entirely from your laptop: it opens a port-forward to the backend
# Service, hammers it with parallel curl workers, and prints a timeline of
# HPA target / replica count / per-pod CPU every few seconds.
#
#   ./local/load-test.sh                     # staging, 20 workers, 180s
#   ./local/load-test.sh -w 40 -d 300        # heavier and longer
#   ./local/load-test.sh --watch-down        # also watch the scale-down window
#
# Notes / caveats
#   * Defaults to the STAGING namespace. Prod serves a live site and shares the
#     same two nodes, so it is refused unless you pass --yes-really-prod.
#   * `kubectl port-forward svc/...` pins to ONE pod, so after a scale-up the
#     new replica gets no traffic. The HPA still reacts, because it averages
#     CPU across pods, but the per-pod CPU column will stay lopsided. That is
#     the tool, not your chart.
#   * /actuator/health and its liveness/readiness sub-groups are the endpoints
#     Spring Security permits here; everything else answers 403. Override with -p.
#   * Expect roughly: load starts -> CPU pegs at the container limit within
#     ~20s -> HPA reports it after a 15s sync -> a replica is added ~60s later
#     (the scaleUp stabilization window). Anything under -d 120 ends too early.

set -uo pipefail

NAMESPACE="user-mgmt-staging"
COMPONENT="backend"
PATH_="/actuator/health"
WORKERS=20
DURATION=180
INTERVAL=5
BATCH=200          # requests per curl invocation (keep-alive, one process)
LOCAL_PORT=18080
WATCH_DOWN=0
ALLOW_PROD=0

usage() { sed -n '2,26p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace)   NAMESPACE="$2"; shift 2 ;;
    -w|--workers)     WORKERS="$2"; shift 2 ;;
    -d|--duration)    DURATION="$2"; shift 2 ;;
    -p|--path)        PATH_="$2"; shift 2 ;;
    -i|--interval)    INTERVAL="$2"; shift 2 ;;
    --port)           LOCAL_PORT="$2"; shift 2 ;;
    --watch-down)     WATCH_DOWN=1; shift ;;
    --yes-really-prod) ALLOW_PROD=1; shift ;;
    -h|--help)        usage ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found"

echo "==> context: $(kubectl config current-context)   namespace: $NAMESPACE"

# ---------------------------------------------------------------- discovery
DEPLOY=$(kubectl -n "$NAMESPACE" get deploy \
  -l "app.kubernetes.io/component=$COMPONENT" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$DEPLOY" ]; then
  echo "error: no $COMPONENT deployment in namespace '$NAMESPACE'." >&2
  echo "       Note the Helm RELEASE name is not the namespace: the prod release is" >&2
  echo "       'user-mgmt-prod' but it lives in namespace 'user-mgmt'." >&2
  echo "       Namespaces that do have a $COMPONENT deployment:" >&2
  kubectl get deploy -A -l "app.kubernetes.io/component=$COMPONENT" \
    --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null \
    | awk '{printf "         -n %-20s (%s)\n", $1, $2}' >&2
  exit 1
fi

SVC=$(kubectl -n "$NAMESPACE" get svc \
  -l "app.kubernetes.io/component=$COMPONENT" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$SVC" ] || die "no $COMPONENT service found in namespace $NAMESPACE"

PORT=$(kubectl -n "$NAMESPACE" get svc "$SVC" -o jsonpath='{.spec.ports[0].port}')

# Identify prod by the Helm release label rather than the namespace string -
# the prod release is "user-mgmt-prod" but its namespace is plain "user-mgmt".
RELEASE=$(kubectl -n "$NAMESPACE" get deploy "$DEPLOY" \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/instance}' 2>/dev/null)
case "$RELEASE$NAMESPACE" in
  *prod*)
    if [ "$ALLOW_PROD" -eq 0 ]; then
      die "refusing to load-test PRODUCTION (release '$RELEASE' in namespace '$NAMESPACE').
       It serves the live site and shares nodes with staging, and port-forward
       pins the load to ONE of the pods real users are being served by.
       Pass --yes-really-prod if that is genuinely what you want."
    fi
    echo "!!  PRODUCTION target: release '$RELEASE' in namespace '$NAMESPACE'."
    echo "    Real traffic is served by these pods. Proceeding because --yes-really-prod was given."
    ;;
esac

if ! kubectl -n "$NAMESPACE" get hpa "$DEPLOY" >/dev/null 2>&1; then
  echo "!!  no HPA named $DEPLOY in $NAMESPACE - autoscaling.enabled is probably false."
  echo "    The load will still run, but nothing will scale."
else
  kubectl -n "$NAMESPACE" get hpa "$DEPLOY" \
    -o custom-columns=HPA:.metadata.name,MIN:.spec.minReplicas,MAX:.spec.maxReplicas,TARGET:'.spec.metrics[0].resource.target.averageUtilization'
  REQ=$(kubectl -n "$NAMESPACE" get deploy "$DEPLOY" \
    -o jsonpath="{.spec.template.spec.containers[0].resources.requests.cpu}")
  echo "    cpu request per pod: ${REQ:-<unset>}  (the HPA percentage is measured against this)"
fi

kubectl top pods -n "$NAMESPACE" >/dev/null 2>&1 \
  || echo "!!  kubectl top is not answering - metrics-server may be down; the HPA needs it too."

if [ "$DURATION" -lt 120 ]; then
  echo "!!  duration ${DURATION}s is short. hpa.yaml sets scaleUp.stabilizationWindowSeconds: 60,"
  echo "    so the HPA needs ~60s of *sustained* load before it adds a replica, on top of its"
  echo "    15s sync interval and the JVM startup probe. Use -d 180 or more to see a scale-up."
fi

# ------------------------------------------------------------------ cleanup
PF_PID=""
WORKER_PIDS=""
cleanup() {
  trap - INT TERM EXIT
  echo
  echo "==> stopping load"
  for p in $WORKER_PIDS; do kill "$p" 2>/dev/null; done
  wait $WORKER_PIDS 2>/dev/null
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
  echo "==> done. Final state:"
  kubectl -n "$NAMESPACE" get hpa,deploy -l "app.kubernetes.io/component=$COMPONENT" 2>/dev/null
}
trap cleanup INT TERM EXIT

# ------------------------------------------------------------- port-forward
echo "==> port-forward svc/$SVC $LOCAL_PORT:$PORT"
kubectl -n "$NAMESPACE" port-forward "svc/$SVC" "$LOCAL_PORT:$PORT" >/tmp/load-test-pf.log 2>&1 &
PF_PID=$!
disown "$PF_PID" 2>/dev/null

URL="http://127.0.0.1:$LOCAL_PORT$PATH_"
ready=0
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL" 2>/dev/null)
  if [ "$code" = "200" ]; then ready=1; break; fi
  sleep 0.5
done
[ "$ready" -eq 1 ] || die "port-forward never became usable (last code: ${code:-none}); see /tmp/load-test-pf.log"
echo "==> $URL answers 200"

# ------------------------------------------------------------------- workers
# Each worker feeds curl a batch of URLs in ONE invocation, so the requests
# share a keep-alive connection instead of paying process + TCP setup each time.
END=$(( $(date +%s) + DURATION ))
URLS=$(awk -v u="$URL" -v n="$BATCH" 'BEGIN{ for(i=0;i<n;i++) printf "%s ", u }')

echo "==> $WORKERS workers x ${DURATION}s against $PATH_"
i=0
while [ "$i" -lt "$WORKERS" ]; do
  (
    while [ "$(date +%s)" -lt "$END" ]; do
      curl -s --max-time 30 $URLS >/dev/null 2>&1
    done
  ) &
  WORKER_PIDS="$WORKER_PIDS $!"
  i=$(( i + 1 ))
done

# ------------------------------------------------------------------ timeline
printf "\n%-9s %-8s %-9s %-9s %s\n" TIME PHASE HPA-CPU REPLICAS POD-CPU
START=$(date +%s)
phase="load"
watch_until=$END
[ "$WATCH_DOWN" -eq 1 ] && watch_until=$(( END + 360 ))

while [ "$(date +%s)" -lt "$watch_until" ]; do
  now=$(date +%s)
  [ "$now" -ge "$END" ] && phase="cooldown"

  hpa=$(kubectl -n "$NAMESPACE" get hpa "$DEPLOY" \
        -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)
  des=$(kubectl -n "$NAMESPACE" get hpa "$DEPLOY" \
        -o jsonpath='{.status.desiredReplicas}' 2>/dev/null)
  rdy=$(kubectl -n "$NAMESPACE" get deploy "$DEPLOY" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  pods=$(kubectl top pods -n "$NAMESPACE" --no-headers 2>/dev/null \
        | awk -v c="$COMPONENT" '$1 ~ c {printf "%s ", $2}')

  printf "%-9s %-8s %-9s %-9s %s\n" \
    "+$(( now - START ))s" "$phase" "${hpa:-?}%" "${rdy:-0}/${des:-?}" "${pods:-n/a}"

  sleep "$INTERVAL"
done

if [ "$WATCH_DOWN" -eq 1 ]; then
  echo
  echo "note: scale-down uses a 300s stabilization window (see templates/scaling/hpa.yaml),"
  echo "      so the replica count drops a few minutes after the load stops."
fi
