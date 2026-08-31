# TLS setup (LoadBalancer route → `https://kube.nightnode.io`)

Clean URL, real ports 80/443, simple HTTP-01 certs. Costs ~$12/month for the DO
Load Balancer (auto-provisioned when the ingress controller is installed).

> ⚠️ Nothing here has been applied to the cluster. These are the steps **you** run when
> ready. Commands assume your kubeconfig context is `do-fra1-kube`.

## Why this is simpler than the NodePort route
The Load Balancer opens **port 80**, so cert-manager can use the easy **HTTP-01**
challenge (Let's Encrypt fetches a token over http). No DNS API, no OVH webhook, no
credentials — that whole layer is gone.

## Files in this folder for TLS
| File | What it is |
|---|---|
| `ingress.yaml` | Routing + TLS (replaces old `traefik/dynamic.yml`) |
| `cluster-issuer.yaml` | How cert-manager gets the cert (HTTP-01) |
| `frontend-config.yaml` | `NEXT_PUBLIC_API_URL` = `https://kube.nightnode.io/backend` (⚠️ needs image rebuild) |

---

## Steps

### 1. Install the ingress controller (cloud / LoadBalancer variant)
This asks DigitalOcean to create a Load Balancer automatically.

    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/cloud/deploy.yaml

### 2. Get the Load Balancer's public IP (wait ~1-2 min for it to provision)
    kubectl -n ingress-nginx get svc ingress-nginx-controller
    # copy the EXTERNAL-IP

### 3. Add the DNS record (at OVH)
Add an A record for the `kube` subdomain pointing at the LB IP from step 2:

    Type: A   Name: kube   Value: <LOAD_BALANCER_IP>   TTL: 300

(Stable IP — unlike a node IP, this survives nodes being replaced.)

### 4. Install cert-manager
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml

### 5. Apply the TLS manifests
    kubectl apply -f kubernetes/cluster-issuer.yaml
    kubectl apply -f kubernetes/ingress.yaml

### 6. Rebuild the frontend image  ⚠️ important
`NEXT_PUBLIC_API_URL` is baked in at **build time** for Next.js. Rebuild & push the
`auth-portal` image with `NEXT_PUBLIC_API_URL=https://kube.nightnode.io/backend`, then:

    kubectl apply -f kubernetes/frontend-config.yaml
    kubectl rollout restart deploy/frontend

### 7. Watch the cert get issued (a minute or two after DNS resolves)
    kubectl get certificate
    kubectl describe certificate kube-nightnode-tls
    # READY=True means the cert is live

### 8. Test
    https://kube.nightnode.io

---

## Optional cleanup
Once traffic goes through the Ingress, the app Services no longer need to be `NodePort` —
you can switch `backend` and `frontend` Services to `type: ClusterIP` (drop the
`nodePort:` lines) so they're only reachable internally via the ingress.
