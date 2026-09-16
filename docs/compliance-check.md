# VSC Orchestrierung — Compliance Check

Audit of the **User Management Service** deployment against the six tasks in
`VSC_Orchestrierung.pdf` (TEKO, *Verteilte Systeme, Containerisierung*).

Every acceptance criterion is quoted **verbatim in German** from the PDF, with the English
reading underneath, so each row maps one-to-one onto the assignment.

| | |
|---|---|
| **Ops repo** | `github.com/Luca-Guettinger/user_mgmt_gitops` @ `0c65e8a` — local path `kubernetes/user_mgmt_gitops/` |
| **App repo** | `github.com/Luca-Guettinger/user_mgmt_service` @ `598187d4e42157993a1f4ef8baea3347343fd7af` (`main`) |
| **Checked on** | 2026-09-06 |
| **Result** | **6 of 6 tasks fulfilled** |

All file paths below are relative to `user_mgmt_gitops/`, except in Aufgabe 4, which lives in the
application repository and was read from `main` on GitHub.

---

## Verdict at a glance

| # | Aufgabe | Task | Status | Where it is solved |
|---|---|---|---|---|
| 1 | Kubernetes Manifests | Kubernetes Manifests | ✅ | `charts/user-mgmt/templates/` (originally `kubernetes/*.yaml`, commit `775f712`) |
| 2 | Helm Chart | Helm Chart | ✅ | `charts/user-mgmt/` — `helm lint` clean on all four value sets |
| 3 | ArgoCD | ArgoCD | ✅ | `argocd/application-prod.yaml`, `application-staging.yaml`, `project.yaml` |
| 4 | Pipeline | Pipeline | ✅ | app repo `.github/workflows/deploy.yml` @ `main` — `bump` job |
| 5 | Namespaces | Namespaces | ✅ | `values-staging.yaml` / `values-prod.yaml`, `templates/namespace/` |
| 6 | Horizontal Scaling | Horizontal Scaling *(40 % der Endnote)* | ✅ | `templates/scaling/hpa.yaml`, `pdb.yaml`, probes + resources in every Deployment |

---

## Aufgabe 1 — Kubernetes Manifests

> **Ziel (DE):** Ihr erweitert eure bestehende Anwendung und migriert das Docker Compose Setup auf
> Kubernetes. Es gilt sämtliche Komponenten mittels Kubernetes Manifests bereitzustellen und im
> Cluster auszuführen.
>
> **Goal (EN):** Migrate the Docker Compose setup to Kubernetes and run every component in the
> cluster via Kubernetes manifests.

The static manifests from this task were replaced by the Helm chart in Aufgabe 2 (that is exactly
what Aufgabe 2 asks for), so they live in git history. Both are cited.

| Akzeptanzkriterium / Criterion                                                                                                                                                        | File                                                                                                                                              | Code                                                                                                              |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| **DE:** Die Docker Images sind in einer für den Kubernetes Cluster zugänglichen Container Registry gespeichert<br>**EN:** Images stored in a container registry the cluster can reach | `charts/user-mgmt/values.yaml:23, 99`                                                                                                             | `repository: ghcr.io/luca-guettinger/user-mgmt-backend` / `.../auth-portal` — public GHCR, pushed by the pipeline |
| **DE:** Service sowie Deployment für Next Frontend, Spring Boot Backend und PostgreSQL Datenbank vorhanden<br>**EN:** Service + Deployment for frontend, backend and PostgreSQL       | `templates/backend/{deployment,service}.yaml`<br>`templates/frontend/{deployment,service}.yaml`<br>`templates/postgres/{deployment,service}.yaml` | 6 files, one Deployment + one Service per component                                                               |
| **DE:** ConfigMap für die nicht sensitive Konfiguration vorhanden<br>**EN:** ConfigMap for non-sensitive configuration                                                                | `templates/backend/configmap.yaml`<br>`templates/frontend/configmap.yaml`<br>`templates/postgres/configmap.yaml`                                  | `SPRING_DATASOURCE_URL`, `JWT_ISSUER`, `NEXT_PUBLIC_API_URL`, `POSTGRES_DB`                                       |
| **DE:** Secret für die sensitive Konfiguration vorhanden<br>**EN:** Secret for sensitive configuration                                                                                | `templates/backend/secret.yaml`<br>`templates/postgres/secret.yaml`                                                                               | `JWT_SECRET`; `username` / `password`                                                                             |
| **DE:** Die Datenbank verwendet eine persistente Speicherung mittels PersistentVolumeClaim<br>**EN:** Database uses persistent storage via a PVC                                      | `templates/postgres/pvc.yaml`<br>`templates/postgres/deployment.yaml:56-67`                                                                       | PVC `user-mgmt-<env>-postgres-data`, mounted at `/var/lib/postgresql/data` with `subPath: pgdata`                 |
| **DE:** Backend kommuniziert ausschliesslich über den Kubernetes Service mit der Datenbank<br>**EN:** Backend talks to the DB only through the Service                                | `templates/_helpers.tpl:102-105`<br>`templates/backend/configmap.yaml:12`                                                                         | see below                                                                                                         |
| **DE:** Ingress für den Zugriff auf das Frontend vorhanden und erreichbar<br>**EN:** Ingress for frontend access, reachable                                                           | `templates/ingress/ingress.yaml`<br>`values-prod.yaml`                                                                                            | `host: vsc.notenverwaltung.ch`, TLS via cert-manager                                                              |

The sixth criterion is the interesting one — the JDBC host is *derived*, so it can never be a pod
IP and can never drift from the Service name:

```gotemplate
{{/* templates/_helpers.tpl:102-105 */}}
{{- define "user-mgmt.datasourceUrl" -}}
{{- $host := include "user-mgmt.componentFqdn" (dict "root" . "component" "postgres") -}}
{{- printf "jdbc:postgresql://%s:%v/%s" $host .Values.postgres.service.port .Values.postgres.auth.database -}}
{{- end -}}
```

```gotemplate
{{/* templates/backend/configmap.yaml:11-12 */}}
# Built from the postgres values so it always points at the Postgres Service.
SPRING_DATASOURCE_URL: {{ include "user-mgmt.datasourceUrl" . | quote }}
```

Rendered for prod this becomes
`jdbc:postgresql://user-mgmt-prod-postgres.user-mgmt.svc.cluster.local:5432/userdb`.

**Historical evidence for the plain-manifest stage:** commit `775f712`
(*"move the kubernetes manifests into this ops repo and give postgres a persistentvolumeclaim"*)
contains `kubernetes/backend.yaml`, `frontend.yaml`, `postgres.yaml`, `ingress.yaml`,
`cluster-issuer.yaml`, `backend-config.yaml`, `frontend-config.yaml`, `postgres-config.yaml`,
`backend-secret.yaml`, `postgres-secret.yaml`. They were removed in `e7584f7`
(*"replace the static manifests with a templated helm chart"*).

---

## Aufgabe 2 — Helm Chart

> **Ziel (DE):** Ihr ersetzt die statischen Kubernetes Manifests durch einen Helm Chart. Sämtliche
> Kubernetes Manifests sollen als Helm Templates definiert werden, sodass die Anwendung über das
> values.yaml für verschiedene Umgebungen konfiguriert und deployt werden kann.
>
> **Goal (EN):** Replace the static manifests with a chart whose templates are configured per
> environment through `values.yaml`.

| Akzeptanzkriterium / Criterion | File | Code |
|---|---|---|
| **DE:** Helm Chart erstellt, Kubernetes Manifests templatisiert<br>**EN:** Chart created, manifests templated | `charts/user-mgmt/Chart.yaml` + `templates/` | `apiVersion: v2`, `name: user-mgmt`, `version: 0.1.0`; 18 manifest templates + `_helpers.tpl` + `NOTES.txt` |
| **DE:** Sämtliche Konfigurationswerte werden zentral über die values.yaml verwaltet, kein Hardcodings<br>**EN:** All config values central in `values.yaml`, nothing hardcoded | `charts/user-mgmt/values.yaml` (257 lines) | Images, ports, replicas, probes, resources, quotas, ingress host and credentials are all values. Environment files carry **only the deltas**. |
| **DE:** Wiederverwendbare Template Funktionen werden mittels _helpers.tpl definiert<br>**EN:** Reusable template functions in `_helpers.tpl` | `templates/_helpers.tpl` | 15 helpers (see below) |
| **DE:** Das Chart lässt sich mittels helm lint ohne Fehler validieren<br>**EN:** `helm lint` validates without errors | — | verified, see *Verification* |

The helpers in `templates/_helpers.tpl`:

| Helper | Line | What it removes duplication of |
|---|---|---|
| `user-mgmt.name` | 7 | chart name / `nameOverride` |
| `user-mgmt.fullname` | 12 | release prefix |
| `user-mgmt.componentName` | 29 | `user-mgmt-prod-backend` style names, used by *every* object and cross-reference |
| `user-mgmt.namespace` | 38 | `namespaceOverride` → release namespace → ArgoCD destination |
| `user-mgmt.componentFqdn` | 46 | in-cluster DNS name of a Service |
| `user-mgmt.chart` | 52 | `helm.sh/chart` label |
| `user-mgmt.labels` | 60 | the full label block on every object |
| `user-mgmt.selectorLabels` | 76 | Service selectors + Deployment `matchLabels` |
| `user-mgmt.image` | 86 | `repo:tag` with fallback to `global.imageTag` |
| `user-mgmt.imagePullPolicy` | 92 | pull policy with global fallback |
| `user-mgmt.datasourceUrl` | 102 | the JDBC URL (Aufgabe 1) |
| `user-mgmt.postgresSecretName` | 108 | the DB Secret name |
| `user-mgmt.dbCredentialEnv` | 118 | the `secretKeyRef` env block, used by backend **and** postgres under different variable names |
| `user-mgmt.httpProbe` | 136 | the probe body, shared by startup / readiness / liveness so they cannot drift |
| `user-mgmt.replicas` | 152 | see Aufgabe 3 — omits `replicas:` when an HPA owns the Deployment |

Example of the reuse — one helper, two different variable names:

```gotemplate
{{/* templates/backend/deployment.yaml:34 */}}
{{- include "user-mgmt.dbCredentialEnv" (dict "root" . "userVar" "SPRING_DATASOURCE_USERNAME" "passwordVar" "SPRING_DATASOURCE_PASSWORD") | nindent 12 }}

{{/* templates/postgres/deployment.yaml:34 */}}
{{- include "user-mgmt.dbCredentialEnv" (dict "root" . "userVar" "POSTGRES_USER" "passwordVar" "POSTGRES_PASSWORD") | nindent 12 }}
```

---

## Aufgabe 3 — ArgoCD

> **Ziel (DE):** Ihr automatisiert das Deployment eurer Anwendung nach dem GitOps Prinzip mittels
> ArgoCD. Der Zustand eurer Anwendung im Kubernetes Cluster soll dabei kontinuierlich mit der
> Deklaration in eurem Ops Repository synchronisiert werden.
>
> **Goal (EN):** Automate deployment by the GitOps principle; cluster state is continuously
> reconciled against the ops repository.

| Akzeptanzkriterium / Criterion                                                                                                                                                                               | File                                                                      | Code                                                                                                                                                                |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **DE:** Auf GitHub ist ein Ops Repository angelegt, welches den Helm Chart sowie das ArgoCD Application Manifest enthält<br>**EN:** Ops repo on GitHub containing the chart **and** the Application manifest | repo `Luca-Guettinger/user_mgmt_gitops`                                   | `charts/user-mgmt/` + `argocd/application-prod.yaml`, `argocd/application-staging.yaml`, `argocd/project.yaml`                                                      |
| **DE:** ArgoCD ist im Kubernetes Cluster in einem dedizierten Namespace installiert und konfiguriert<br>**EN:** ArgoCD installed and configured in a dedicated namespace                                     | `argocd/application-prod.yaml:7`<br>`README.md` §4 step 0, §5             | `namespace: argocd` on the `Application` and `AppProject`; install + `scale --replicas=0` of the unused dex / applicationset / notifications controllers documented |
| **DE:** Das Deployment des Helm Charts erfolgt in einen eigenen, von ArgoCD getrennten Namespace<br>**EN:** Chart deployed into its own namespace, separate from ArgoCD                                      | `argocd/application-prod.yaml:26`<br>`argocd/application-staging.yaml:23` | `destination.namespace: user-mgmt` / `user-mgmt-staging`, with `CreateNamespace=true`                                                                               |
| **DE:** Änderungen am values.yaml oder am Helm Chart im Ops Repository werden von ArgoCD erkannt und in den Cluster übernommen<br>**EN:** Changes to values/chart are detected and applied                   | `argocd/application-prod.yaml:28-33`                                      | see below                                                                                                                                                           |
| **DE:** Das Argo CD Dashboard ist zugänglich<br>**EN:** The ArgoCD dashboard is accessible                                                                                                                   | `README.md` §5                                                            | `kubectl -n argocd get secret argocd-initial-admin-secret …` + `port-forward svc/argocd-server 8080:443`                                                            |

```yaml
# argocd/application-prod.yaml:16-33
  source:
    repoURL: https://github.com/Luca-Guettinger/user_mgmt_gitops.git
    targetRevision: main
    path: charts/user-mgmt
    helm:
      valueFiles:
        - values.yaml
        - values-prod.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: user-mgmt
  syncPolicy:
    automated:
      prune: true      # delete resources removed from Git
      selfHeal: true   # revert manual changes made in the cluster
```

`argocd/project.yaml` scopes the project: only this Git repo as a source, only the `user-mgmt*`
namespaces as destinations, and exactly two cluster-scoped kinds (`Namespace`, cert-manager
`ClusterIssuer`).

One detail that makes GitOps and autoscaling coexist — without it `selfHeal` would reset the
replica count on every sync and fight the HPA:

```gotemplate
{{/* templates/_helpers.tpl:152-156 */}}
{{- define "user-mgmt.replicas" -}}
{{- if not .autoscaling.enabled -}}
replicas: {{ .replicaCount }}
{{- end -}}
{{- end -}}
```

---

## Aufgabe 4 — Pipeline

> **Ziel (DE):** Ihr refaktoriert die bestehende GitHub Actions Pipeline aus der
> Containerisierungsphase. Der bisherige imperative Deployment Prozess wird entfernt und durch
> einen automatisierten Build-, Registry- und Promotion Prozess abgelöst, welcher die
> Konfiguration im Ops Repository deklarativ aktualisiert.
>
> **Goal (EN):** Remove the imperative deployment; build, publish and promote the image tag
> declaratively into the ops repository.

**This task is solved in the application repository:**
`Luca-Guettinger/user_mgmt_service` → `.github/workflows/deploy.yml` on `main` (`598187d4`).
Jobs: `test` → `build` → `bump` → `verify`.

| Akzeptanzkriterium / Criterion                                                                                                                                                                                                                              | Location                         | Code                                                                                                                                                             |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **DE:** Die Pipeline wird bei einem Push auf den main Branch des Applikations Repositories initiiert<br>**EN:** Triggered on push to `main`                                                                                                                 | `deploy.yml:3-6`                 | `on: push: branches: [main]` (+ `workflow_dispatch`)                                                                                                             |
| **DE:** Das Docker Image wird fehlerfrei gebaut und mit einem eindeutigen, dynamischen Tag (z. B. Git-Commit-Hash) versioniert<br>**EN:** Image built and versioned with a unique, dynamic tag                                                              | `deploy.yml:70-76`               | `docker/metadata-action@v5` with `tags: type=sha,format=long` → `sha-<full commit hash>`                                                                         |
| **DE:** Das versionierte Image wird erfolgreich in eine für den Kubernetes Cluster autorisierte Container Registry publiziert<br>**EN:** Published to an authorized registry                                                                                | `deploy.yml:62-86`               | `docker/login-action@v3` to `ghcr.io`, then `docker/build-push-action@v6` with `push: true`; matrix builds both `user-mgmt-backend` and `auth-portal`            |
| **DE:** Die Pipeline führt einen automatisierten Commit auf das Ops Repository aus, welcher den Image Tag in der values.yaml des Helm Charts aktualisiert (sog. Promotion)<br>**EN:** Automated commit into the ops repo updating the image tag (promotion) | `deploy.yml:92-133` — job `bump` | see below                                                                                                                                                        |
| **DE:** Sämtliche imperativen Deployment Schritte (bspw. ssh und docker compose) sind aus der Pipeline entfernt<br>**EN:** All imperative deployment steps removed                                                                                          | `deploy.yml`                     | No `ssh`, no `docker compose`, no `appleboy/ssh-action`. The former `deploy` job is gone; `verify` only polls the public URL over HTTPS.                         |
| **DE:** Alle benötigten Secrets werden über GitHub Secrets verwaltet<br>**EN:** All secrets managed via GitHub Secrets                                                                                                                                      | `deploy.yml:68, 106`             | `secrets.GITHUB_TOKEN` (GHCR push), `secrets.GITOPS_PAT` (push to the ops repo). Non-secret config via `vars.NEXT_PUBLIC_API_URL`. No SSH key material anywhere. |

```yaml
# .github/workflows/deploy.yml:92-133
  bump:
    name: Point GitOps at this commit
    needs: build
    runs-on: ubuntu-latest
    environment: production
    permissions: {}
    steps:
      - name: Check out the ops repo
        uses: actions/checkout@v4
        with:
          repository: Luca-Guettinger/user_mgmt_gitops
          ref: main
          token: ${{ secrets.GITOPS_PAT }}      # fine-grained PAT, Contents: RW, that repo only

      - name: Set the production image tag
        env:
          NEW_TAG: sha-${{ github.sha }}
        run: |
          set -euo pipefail
          f=charts/user-mgmt/values-prod.yaml
          sed -i -E "s|^([[:space:]]{2}imageTag:).*|\1 ${NEW_TAG}|" "$f"
          # If the key is renamed or re-indented the sed silently does nothing, which
          # would give a green deploy that shipped no code. Fail here instead.
          grep -qx "  imageTag: ${NEW_TAG}" "$f"

      - name: Commit and push
        run: |
          set -euo pipefail
          if git diff --quiet; then echo "Already pointing at ${GITHUB_SHA}."; exit 0; fi
          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git commit -am "deploy user_mgmt_service@${GITHUB_SHA}"
          git push
```

**Proof the promotion actually runs.** The most recent commit in the ops repo was made by the
pipeline, not by a human:

```
0c65e8a | github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>
        | 2026-09-05 11:18:36 +0000
        | deploy user_mgmt_service@598187d4e42157993a1f4ef8baea3347343fd7af

 charts/user-mgmt/values-prod.yaml | 2 +-
```

and `values-prod.yaml:6` now reads
`imageTag: sha-598187d4e42157993a1f4ef8baea3347343fd7af`, which is exactly the current `main` of
the application repository. The full loop — push → build → promote → ArgoCD sync — is closed.

---

## Aufgabe 5 — Namespaces

> **Ziel (DE):** Die Applikation ist für den parallelen Betrieb in verschiedenen Umgebungen
> (bspw. Staging und Production) innerhalb desselben Clusters zu konfigurieren. Die logische
> Trennung erfolgt über Kubernetes Namespaces, ergänzt durch strikte Ressourcenlimitierungen und
> Netzwerkrestriktionen.
>
> **Goal (EN):** Run staging and production side by side in one cluster, isolated by namespace,
> resource quota and network policy.

| Akzeptanzkriterium / Criterion | File | Code |
|---|---|---|
| **DE:** Der Helm Chart ist umgebungsspezifisch via separater values-staging.yaml und values-prod.yaml parametrisierbar<br>**EN:** Chart parametrisable per environment via separate values files | `charts/user-mgmt/values-staging.yaml`<br>`charts/user-mgmt/values-prod.yaml` | Each contains only the differences from `values.yaml` (`values-dev.yaml` additionally covers a local kind cluster) |
| **DE:** ArgoCD verwaltet zwei eigenständige Application Manifests, welche den Helm Chart automatisiert in separate Namespaces deployen<br>**EN:** Two independent Applications deploying into separate namespaces | `argocd/application-prod.yaml`<br>`argocd/application-staging.yaml` | `user-mgmt-prod` → namespace `user-mgmt`; `user-mgmt-staging` → namespace `user-mgmt-staging`. Different release names, so object names cannot collide. |
| **DE:** Für jeden Namespace sind maximale Ressourcenlimits (CPU und Memory) mittels ResourceQuota verbindlich definiert<br>**EN:** ResourceQuota with CPU and memory ceilings per namespace | `templates/namespace/quota.yaml:5-15` | prod: `requests.cpu 1`, `requests.memory 1536Mi`, `limits.cpu 4`, `limits.memory 4Gi`, `pods 15`, `pvc 2`<br>staging: `500m` / `768Mi` / `2` / `2Gi` / `10` / `2` |
| **DE:** Die netzwerktechnische Isolation zwischen den Namespaces ist durch NetworkPolicies sichergestellt<br>**EN:** Network isolation between namespaces via NetworkPolicies | `templates/namespace/networkpolicy.yaml` | 4 policies, see below |

```yaml
# templates/namespace/networkpolicy.yaml:15-25 — default deny
kind: NetworkPolicy
metadata:
  name: {{ include "user-mgmt.fullname" . }}-default-deny
spec:
  podSelector: {}          # every pod in the namespace
  policyTypes:
    - Ingress              # ...receives nothing unless a policy below allows it
```

The three allow rules then re-open exactly what the app needs:

| Policy | Line | Allows |
|---|---|---|
| `-allow-ingress-controller` | 30-45 | anything in namespace `ingress-nginx` → any pod here (empty `podSelector` so it also covers cert-manager's short-lived ACME solver pods) |
| `-allow-backend-to-postgres` | 48-68 | backend pods → postgres, TCP 5432 only |
| `-allow-frontend-to-backend` | 71-91 | frontend pods → backend, TCP 8080 only |

Nothing else matches, so a pod in `user-mgmt-staging` cannot reach anything in `user-mgmt`.
Egress is deliberately unrestricted (DNS, ACME) — that is documented in the file header and does
not weaken the isolation, which is enforced on the receiving side.

`quota.yaml:22-35` additionally renders a `LimitRange`. Once a `ResourceQuota` constrains
`requests`/`limits`, Kubernetes rejects any pod that declares neither. The chart's own pods
declare them; foreign pods (the cert-manager solver) do not, so the `LimitRange` supplies
defaults instead of letting certificate renewal fail.

---

## Aufgabe 6 — Horizontal Scaling  *(Bewertung: 40 % der Endnote)*

> **Ziel (DE):** Die Systemarchitektur ist auf Hochverfügbarkeit und elastische Lastverteilung
> auszulegen. Die Applikation muss in der Lage sein, sich bei schwankender Auslastung dynamisch
> horizontal zu skalieren und bei Ausfällen oder Wartungsarbeiten eine definierte
> Mindestverfügbarkeit zu garantieren.
>
> **Goal (EN):** High availability and elastic load distribution; dynamic horizontal scaling plus
> a guaranteed minimum availability during failures and maintenance.

| Akzeptanzkriterium / Criterion | File | Code |
|---|---|---|
| **DE:** Ein Horizontal Pod Autoscaler (HPA) skaliert die Backend Replicas dynamisch anhand definierter Schwellenwerte<br>**EN:** HPA scales backend replicas on defined thresholds | `templates/scaling/hpa.yaml:11-49`<br>`values-prod.yaml:29-35` | `autoscaling/v2`, `minReplicas: 2`, `maxReplicas: 3`, `targetCPUUtilizationPercentage: 70` |
| **DE:** Für sämtliche Pods sind requests und limits verbindlich deklariert, um die Funktion des HPA sicherzustellen und Ressourcen Konflikte auf dem Node zu vermeiden<br>**EN:** `requests` **and** `limits` declared for all pods | `values-prod.yaml:17-27, 44-50, 69-75` | backend `100m/224Mi → 500m/640Mi`; frontend `50m/128Mi → 300m/256Mi`; postgres `50m/128Mi → 500m/256Mi`. Applied through `resources:` in all three Deployments. |
| **DE:** Konfigurierte livenessProbe und readinessProbe stellen sicher, dass Traffic nur an bereite Instanzen geroutet und fehlerhafte Pods terminiert werden<br>**EN:** liveness + readiness probes route traffic only to ready pods and kill broken ones | `templates/backend/deployment.yaml:40-54`<br>`templates/frontend/deployment.yaml:34-46`<br>`templates/postgres/deployment.yaml:38-51` | HTTP probes via the shared `user-mgmt.httpProbe` helper: the backend on Boot's health groups (`/actuator/health/liveness`, `/actuator/health/readiness`), the frontend on `/`; `pg_isready` exec probes for Postgres |
| **DE:** Der Ingress Controller verteilt den externen Traffic dynamisch mittels internem Round Robin Load Balancing ausschliesslich auf alle als "ready" validierten Pod Replicas<br>**EN:** Ingress round-robins external traffic across ready replicas only | `values.yaml:244`<br>`templates/ingress/ingress.yaml` | `nginx.ingress.kubernetes.io/load-balance: round_robin`; ingress-nginx forwards to Service *endpoints*, and readiness is what puts a pod into the endpoint list |
| **DE:** Es ist eine RollingUpdate Strategie definiert, um Service Unterbrüche bei Aktualisierungen auszuschliessen<br>**EN:** RollingUpdate strategy, no interruption on updates | `values.yaml:30-35, 106-110`<br>`templates/{backend,frontend}/deployment.yaml:12-13` | `type: RollingUpdate`, `maxSurge: 1`, `maxUnavailable: 0` — a new pod must be **Ready** before an old one is removed |
| **DE:** Ein Pod Disruption Budget (PDB) ist definiert, um bei Wartungsvorgängen oder Re-Schedulings auf dem Node eine minimale Anzahl aktiver Replikate sicherzustellen<br>**EN:** PDB guaranteeing a minimum of active replicas | `templates/scaling/pdb.yaml:11-22`<br>`values-prod.yaml:37-38` | `policy/v1` PDB for the backend, `minAvailable: 1` |

```yaml
# templates/scaling/hpa.yaml:23-49 (rendered for prod)
  minReplicas: 2
  maxReplicas: 3
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60    # react quickly to load
    scaleDown:
      stabilizationWindowSeconds: 300   # do not drop capacity on a brief dip
```

Three design decisions worth pointing out, because each looks like a gap until you read the
comment next to it:

- **`requests` are mandatory, not cosmetic.** The HPA computes utilisation *against the CPU
  request*. `templates/scaling/hpa.yaml:1-5` says so, and that is why no component may omit them.
- **Postgres uses `Recreate`, not `RollingUpdate`** (`templates/postgres/deployment.yaml:12-17`).
  Its `ReadWriteOnce` volume can only attach to one node at a time, so a rolling update would
  deadlock waiting for the volume. The stateless components are the ones that roll.
- **The PDB is off wherever `minReplicas: 1`** (`values.yaml:88-92`, `values-staging.yaml:30-33`).
  With a single replica, `minAvailable: 1` permits *zero* voluntary disruptions and blocks node
  drains entirely. Prod runs `minReplicas: 2`, which is what makes the PDB meaningful.

A **startupProbe** on the backend (`templates/backend/deployment.yaml:40-44`,
`failureThreshold: 30` → up to 5 minutes) holds readiness and liveness off while the JVM boots
(~110 s on a 1-vCPU node), so a slow start is not mistaken for a hang and restarted in a loop.

---

## Verification performed

Everything below was executed against the working tree during this audit.

**`helm lint` — clean on all four value sets (Aufgabe 2 criterion):**

```
helm lint charts/user-mgmt                                        → 0 failed
helm lint charts/user-mgmt -f charts/user-mgmt/values-prod.yaml    → 0 failed
helm lint charts/user-mgmt -f charts/user-mgmt/values-staging.yaml → 0 failed
helm lint charts/user-mgmt -f charts/user-mgmt/values-dev.yaml     → 0 failed
```

Only informational output: `[INFO] Chart.yaml: icon is recommended`.

**`helm template` — rendered object inventory:**

| Environment | Objects rendered |
|---|---|
| **prod** (`-n user-mgmt`, 22 objects) | 3 Deployment, 3 Service, 3 ConfigMap, 2 Secret, 1 PVC, 1 Ingress, 1 HorizontalPodAutoscaler, 1 PodDisruptionBudget, 1 ResourceQuota, 1 LimitRange, 4 NetworkPolicy, 1 ClusterIssuer |
| **staging** (`-n user-mgmt-staging`, 19 objects) | 3 Deployment, 3 Service, 3 ConfigMap, 2 Secret, 1 PVC, 1 HorizontalPodAutoscaler, 1 ResourceQuota, 1 LimitRange, 4 NetworkPolicy *(no Ingress, no PDB — both intentional and commented)* |

Every object carries `namespace: user-mgmt` / `user-mgmt-staging` respectively — nothing lands in
`default`, nothing lands in `argocd`.

**Pipeline end-to-end:** ops-repo commit `0c65e8a` by `github-actions[bot]` updates
`values-prod.yaml` to `sha-598187d4…`, matching `git ls-remote origin refs/heads/main` of the
application repository. Promotion demonstrably works.

---

## Observations

None of these block a criterion — the assignment is fulfilled without them. They are noted
because they are worth knowing.

1. **Plaintext credentials in a public repository.** `values-prod.yaml:59` contains the real
   Postgres password and `values.yaml:43` the `JWT_SECRET`. The file already carries the right
   `# TODO: replace with a real secret (Sealed Secrets / SOPS / External Secrets)`. Since the
   repo is public, rotating the password and moving both to Sealed Secrets or SOPS is the
   natural next step.
2. **The frontend runs a single replica in prod and has no PDB.** Aufgabe 6 asks for *a* PDB and
   the backend has one, so the criterion is met. Enabling `frontend.autoscaling` with
   `minReplicas: 2` plus a PDB would extend the same guarantee to the portal — it needs a third
   node to schedule.
3. **`docs/tls-setup.md` is outdated.** It still references `kubernetes/ingress.yaml`,
   `frontend-config.yaml` and an OVH DNS record; the chart and `README.md` §4 replaced that
   procedure (Cloudflare, chart-managed ClusterIssuer). Harmless, but it contradicts the README.
