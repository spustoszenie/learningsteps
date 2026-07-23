# LearningSteps — Evolution

A FastAPI application deployed to Azure Kubernetes Service, with infrastructure defined as code and a security-gated CI/CD pipeline.

This README is the onboarding guide: follow it to reproduce the whole deployment on **your own** Azure subscription.

---

## What this is

| Layer | What it does | Where |
|---|---|---|
| **App** | FastAPI app, packaged as a container image | `Dockerfile`, `api/` |
| **Infrastructure** | Network, cluster, registry, database, secrets — as Terraform | `infra-terraform/` |
| **Pipeline** | Build → security scan → push image to the registry | `.github/workflows/` |
| **Orchestration** | Runs the app on Kubernetes, exposes it publicly | `k8s-manifests/` |

**Flow:** `git push` → GitHub Actions builds the image → Trivy scans it (build fails on CRITICAL) → image is pushed to Azure Container Registry → Kubernetes pulls it and runs it, reading its database password from Key Vault.

```
                    ┌──────────────── Resource Group ────────────────┐
                    │                                                │
   git push ──► CI/CD ──► ACR ──────┐                                │
                    │               ▼                                │
                    │   ┌── VNet ───────────────────────────────┐    │
                    │   │  aks-subnet ──► AKS ──► pods ──► LB ──┼────┼──► public IP
                    │   │                         │            │    │
                    │   │  db-subnet  ──► PostgreSQL (private)  │    │
                    │   └───────────────────────────────────────┘    │
                    │                         ▲                      │
                    │        Key Vault ───────┘ (connection string)  │
                    └────────────────────────────────────────────────┘
```

---

## Prerequisites

- An **Azure subscription** where you can create resources *and* role assignments (Owner or User Access Administrator — role assignments fail with `403` on Contributor alone)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), [Terraform](https://developer.hashicorp.com/terraform/downloads) ≥ 1.9, [kubectl](https://kubernetes.io/docs/tasks/tools/), Git
- A GitHub account (to fork this repo and run the pipeline)

---

## Setup

### 1. Get the code

**Fork** this repo on GitHub, then clone **your fork** — you need push access and your own pipeline:

```bash
git clone https://github.com/<YOU>/learningsteps.git
cd learningsteps
git remote -v      # must show YOUR username
```

Two things do not come with a fork: open the **Actions** tab and enable workflows, and add your own secrets (step 4) — secrets are never copied.

<details>
<summary>Already have your own Terraform and only want the Kubernetes manifests?</summary>

Don't fork — pull the single folder into your existing repo:

```bash
git remote add upstream https://github.com/spustoszenie/learningsteps.git
git fetch upstream
git checkout upstream/main -- k8s-manifests/
```

Avoid `git pull` here — if the repos grew separately, Git refuses ("unrelated histories"), and even when it works it merges everything and collides with your own `variables.tf`.
</details>

### 2. Configure your variables

Create `infra-terraform/terraform.tfvars` (git-ignored — never commit it):

```hcl
subscription_id = "<your-subscription-id>"
acr_name        = "acrlearn<yourinitials>"    # globally unique, letters+numbers only, 5-50
kv_name         = "learn-kv-<yourinitials>"   # globally unique, 3-24 chars, letters/numbers/dashes
db_password     = "<a strong password>"
```

Then set your own prefix in `infra-terraform/variables.tf`:

```hcl
variable "prefix" {
  default = "learnsteps<yourinitials>"
}
```

> **Why the prefix matters:** the database server name is built from it and becomes a public DNS name (`<prefix>-pg.postgres.database.azure.com`). DNS is global, so two people using the same prefix collide with `ServerNameAlreadyExists`.

**Globally unique names in this stack:** the container registry, the Key Vault, and the PostgreSQL server.

### 3. Build the infrastructure

```bash
az login
az account set --subscription <your-subscription-id>

cd infra-terraform
terraform init
terraform plan          # read it before you apply
terraform apply         # ~10-15 min (cluster and database are slow)
```

When it finishes:

```bash
terraform output        # acr_server, aks_name, key_vault_uri
```

### 4. Point the pipeline at your registry

Get the registry credentials:

```bash
az acr credential show -n <your_acr_name> --query "{u:username, p:passwords[0].value}" -o table
```

In **your fork** → Settings → Secrets and variables → Actions, add:

| Secret | Value |
|---|---|
| `ACR_SERVER` | from `terraform output acr_server` |
| `ACR_USERNAME` | `u` from the command above |
| `ACR_PASSWORD` | `p` from the command above |

Then trigger the pipeline so it builds and pushes the image:

```bash
git commit --allow-empty -m "trigger CD"
git push

# after ~1 min — newest tag first; the tag is the full commit SHA
az acr repository show-tags -n <your_acr_name> --repository learningsteps --orderby time_desc -o table
```

> Terraform creates the *empty* registry; the pipeline puts images in it. A push before `terraform apply` will fail at the login step — that's expected.

### 5. Deploy to Kubernetes

Connect `kubectl` to your cluster (needed again after every rebuild — a new cluster means new credentials):

```bash
az aks get-credentials --resource-group <your_rg> --name <your_aks>
kubectl get nodes       # expect 2 nodes, Ready
```

Copy the database connection string from Key Vault into a Kubernetes secret — the value never touches a file in the repo:

```powershell
$KV   = "<your_kv_name>"
$CONN = az keyvault secret show --vault-name $KV --name db-connection-string --query value -o tsv
kubectl create secret generic learningsteps-secrets --from-literal=DATABASE_URL="$CONN"
```

Edit `k8s-manifests/deployment.yaml` to point at **your** registry and **your** tag:

```yaml
image: <your_acr_server>/learningsteps:<full-SHA-tag-from-step-4>
```

Apply everything:

```bash
kubectl apply -f k8s-manifests/
kubectl get pods -w                           # goal: Running, and it stays Running
kubectl get service learningsteps --watch     # EXTERNAL-IP: <pending> → public IP
```

### 6. Verify

Open `http://<EXTERNAL-IP>/docs` — the FastAPI docs page should load.

```bash
kubectl get hpa         # TARGETS shows a CPU %, not <unknown>
```

---

## What's in `infra-terraform/`

Terraform loads every `.tf` file in the folder; the split is for humans.

| File | Creates |
|---|---|
| `versions.tf` | Provider (`azurerm ~> 4.0`) and version pinning |
| `variables.tf` | Input declarations |
| `main.tf` | Resource group |
| `network.tf` | VNet, `aks-subnet` (`/22`), `db-subnet` (delegated to PostgreSQL) |
| `acr.tf` | Container registry (`admin_enabled = true`, used by CD) |
| `aks.tf` | AKS cluster + `AcrPull` role assignment so it can pull images |
| `postgres.tf` | Private DNS zone + link, PostgreSQL Flexible Server, database |
| `keyvault.tf` | Key Vault, secrets-officer role, DB connection string secret |
| `outputs.tf` | `acr_server`, `aks_name`, `key_vault_uri` |

**Ordering is automatic.** Resources reference each other (a subnet points at the VNet, the role assignment points at the cluster and registry), and Terraform builds a dependency graph from those references. The two exceptions are `depends_on` in `postgres.tf` (DNS link before the server) and `keyvault.tf` (role before writing the secret) — order matters there but no reference exists.

**Region:** `westeurope`. PostgreSQL Flexible Server is not offered in every region on every subscription — verify before changing it:

```bash
az postgres flexible-server list-skus --location <region> -o table   # empty = not available
```

---

## Troubleshooting

### Kubernetes toolbox

```bash
kubectl get pods                     # 1. what's the status?
kubectl describe pod <pod-name>      # 2. why? — read the Events at the bottom
kubectl logs <pod-name>              # 3. what did the app say?
kubectl logs <pod-name> --previous   #    ...if it already restarted
kubectl get secret learningsteps-secrets -o yaml   # 4. is the secret there?
kubectl exec -it <pod-name> -- /bin/bash           # 5. go inside and look
```

`describe` is Kubernetes' view from the outside; `logs` is the app's own voice from the inside.

> `kubectl get secret -o yaml` shows **base64**, which is encoding, not encryption. Anyone who can read it can decode it — don't paste that output into chat or screenshots.

### Common errors

| Symptom | Cause | Fix |
|---|---|---|
| `ImagePullBackOff` | Wrong image tag, or no pull permission | Use the real SHA from `az acr repository show-tags`; check the `AcrPull` role exists |
| `CrashLoopBackOff` after reaching Running | Image pulled fine; the app exits — usually the DB connection | `kubectl logs <pod> --previous`; verify `DATABASE_URL` reached the pod |
| `kubectl` says `localhost:8080 connection refused` | kubeconfig doesn't know the cluster | `az aks get-credentials ...` |
| `ServerNameAlreadyExists` | Another subscription took the database name | Change `prefix` in `variables.tf` |
| `InsufficientVCPUQuota` / `VM size not allowed` | Burstable (`B*`) is often zeroed on sandbox subscriptions | Use `Standard_D2s_v3` |
| PostgreSQL `LocationIsOfferRestricted` | Service not sold in that region/subscription | Check `list-skus`; use `westeurope` |
| `403` on a role assignment or Key Vault secret | Role propagation takes up to ~10 min | Re-run `terraform apply` |
| `Provider produced inconsistent result` | Transient Azure 404 — the resource usually exists | Verify with `az ... list`, then `terraform import` — **don't** destroy |
| CD fails at ACR login | Secrets don't match the current registry | Refresh `ACR_SERVER` / `ACR_USERNAME` / `ACR_PASSWORD` |
| HPA shows `<unknown>` | Deployment has no `resources.requests` | Add CPU requests |

### Push rejected: file over 100 MB

`terraform init` downloads a ~240 MB provider binary into `.terraform/`. If it was committed before `.gitignore` covered it, GitHub rejects the push — `.gitignore` only stops Git from *starting* to track a file.

```bash
git fetch origin
git reset --soft origin/main                    # rewind to remote; your changes stay staged
git rm -r --cached infra-terraform/.terraform   # stop tracking it (stays on disk)
git commit -m "providers ignored"
git status                                      # .terraform/ must not appear
git push
```

> If a **secret** was already pushed, removing it does not un-leak it. Rotate the credential and treat the old one as compromised.

---

## Secrets & Git hygiene

- `terraform.tfvars` holds your subscription ID and database password — it is git-ignored. The committed template is `terraform.tfvars.example`.
- `.terraform/` (provider binaries) is ignored; `.terraform.lock.hcl` **is** committed — it pins the provider version for everyone. Commit the recipe, not the ingredients.
- `*.tfstate` is ignored — state files can contain secrets in plain text.
- Key Vault is the source of truth for the database connection string. It is never written into a YAML file.

---

## Tear down

```bash
cd infra-terraform
terraform destroy
```

Everything is code, so bringing it back is `terraform apply` plus a `git push`.
