# DevOps Assignment — CI/CD Pipeline on AWS + Kubernetes

Production-style CI/CD pipeline: Jenkins builds and tests a Node.js/Express API,
packages it as a Docker image, pushes it to Amazon ECR, and deploys it to
Amazon EKS via Helm — exposed through an AWS Application Load Balancer (ALB)
with a Horizontal Pod Autoscaler (HPA) for autoscaling.

**Infrastructure is provisioned entirely by Terraform (`terraform/`) — no
eksctl, no manual console clicking, no IAM user with a static access
key.** Jenkins authenticates via an EC2 IAM instance profile, cluster
add-ons authenticate via IRSA, and the app's secret is synced from AWS
Secrets Manager by the External Secrets Operator. `dev`, `staging`, and
`prod` are FULLY SEPARATE infrastructure (own VPC, EKS cluster, ECR
repo, Jenkins host, SonarQube host — not namespaces on one shared
cluster), selected by Terraform workspace; only `dev` has actually been
applied so far. 

## Repository layout

```
.
├── Jenkinsfile                     # CI/CD pipeline (keyless AWS auth, scanning, signing, approval gates)
├── sonar-project.properties        # SonarQube project config (SAST + Quality Gate)
├── .trivyignore                    # accepted-risk CVEs, WITH a reason each
├── app/                            # Node.js/Express sample app — DevOps Task Board
│   ├── index.js                    # /health, /api, /api/tasks CRUD, serves public/
│   ├── public/                     # static UI: index.html, style.css, app.js (no build step)
│   ├── package.json                # engines.node pinned exactly (checked by OPA + .npmrc)
│   ├── .npmrc                      # engine-strict=true
│   ├── test/health.test.js         # /health + /api tests (node --test)
│   ├── test/tasks.test.js          # task board API + UI landing page tests (node --test)
│   ├── Dockerfile                  # Node version pinned exactly, non-root, readOnlyRootFilesystem
│   └── .dockerignore
├── policy/                         # OPA policies, evaluated by Conftest IN CI (Jenkinsfile "OPA Policy Check")
│   ├── node_version.rego           # Dockerfile FROM <-> package.json engines.node must agree
│   └── kubernetes.rego             # rendered Helm manifests: no :latest, resource limits, non-root, probes
├── k8s-policies/kyverno/           # Kyverno ClusterPolicies, enforced IN-CLUSTER at admission time
│   ├── verify-image-signature.yaml.tpl   # cosign/KMS signature required (rendered by terraform/kyverno.tf)
│   ├── restrict-image-registry.yaml
│   ├── disallow-latest-tag.yaml
│   ├── require-resource-limits.yaml
│   ├── require-probes.yaml
│   └── disallow-privileged-and-root.yaml
├── k8s-policies/karpenter/         # NODE-level autoscaling rules (rendered by terraform/cluster-addons/karpenter.tf)
│   ├── ec2nodeclass.yaml.tpl       # which AMI/IAM role/subnets Karpenter is allowed to launch into
│   └── nodepool.yaml               # which instance shapes, on-demand vs. spot, size cap, consolidation
├── helm/devops-sample-api/         # Helm chart
│   ├── Chart.yaml
│   ├── values.yaml                 # shared defaults (mocked secret, for standalone use)
│   ├── values-dev.yaml             # dev overrides (real Secrets Manager secret)
│   ├── values-staging.yaml         # staging overrides (real Secrets Manager secret)
│   ├── values-prod.yaml            # prod overrides (real Secrets Manager secret)
│   └── templates/
│       ├── deployment.yaml         # rolling-update Deployment, probes, hardened securityContext
│       ├── service.yaml            # ClusterIP Service
│       ├── ingress.yaml            # ALB Ingress (AWS Load Balancer Controller)
│       ├── hpa.yaml                # HorizontalPodAutoscaler
│       ├── configmap.yaml          # non-secret config
│       ├── secret.yaml             # mocked Secret (default) + ExternalSecret (terraform envs)
│       ├── serviceaccount.yaml     # for IRSA
│       └── NOTES.txt
└── terraform/                      # VPC, EKS, ECR, IAM (instance profile + IRSA), Secrets Manager,
    ├── bootstrap/                  # KMS signing key, SonarQube host, Kyverno + cluster add-ons,
    ├── locals.tf                   # and the Jenkins EC2 host itself — see README.md, "Environments"
    ├── environments/                # dev.tfvars.example (applied/tested), staging + prod .example
    ├── sonarqube.tf                
    ├── signing.tf
    ├── kyverno.tf
    ├── *.tf
    └── README.md
```

## The application

**DevOps Task Board** — a small Express app with a real static UI (plain
HTML/CSS/JS, no build step, no framework) backed by an in-memory task list,
plus the JSON endpoints the pipeline and Kubernetes probes use:

- `GET /` — the task board UI. Add, complete, and delete tasks; a status
  bar at the top reads `GET /api` live so you can visually confirm which
  environment this pod is running in, whether the beta feature flag is on,
  and whether the Secret actually reached the container — useful during
  Part K of the End-to-End Runbook instead of only reading raw curl output.
- `GET /api/tasks`, `POST /api/tasks`, `PATCH /api/tasks/:id`,
  `DELETE /api/tasks/:id` — the task board's own CRUD API. Storage is
  deliberately in-memory (resets on pod restart/rollout) so the exercise
  doesn't need a database dependency; swapping in a real datastore would
  only touch the small block in `index.js` that owns the `tasks` array.
- `GET /health` — liveness/readiness target, returns `{status: "ok", env, version, uptimeSeconds}`.
- `GET /api` — returns a greeting plus the resolved config/secret state, so
  you can see ConfigMap/Secret values flowing through at runtime (this is
  what the UI's status bar calls).

Run locally: `cd app && npm install && npm start`, then open
`http://localhost:3000` (listens on `:3000`).
Run tests: `cd app && npm test` (Node's built-in test runner — no extra
framework needed to satisfy the "Unit Test (can be minimal)" requirement;
covers both the task board API and the `/health`/`/api` endpoints).

## Pipeline flow (step-by-step)

The `Jenkinsfile` defines a declarative pipeline with these stages, run in
order. Fail-fast: cheap checks (dependencies, tests, static analysis,
policy) all run before the expensive ones (image build, scan, push, sign),
and nothing risky (staging/prod) deploys without a human saying so.

1. **Checkout** — pulls the repo, records the short git SHA (`IMAGE_TAG`).
2. **Initialize** — resolves `AWS_ACCOUNT_ID`/`ECR_REGISTRY` via the
   instance profile's own identity (no stored credential).
3. **Build** — `npm ci`/`npm install` inside `app/`.
4. **Dependency & Filesystem Scan** — `npm audit --audit-level=high` (SCA)
   plus `trivy fs` (vulnerabilities + accidentally-committed secrets)
   against `app/`. Fails the build on HIGH/CRITICAL findings not listed in
   `.trivyignore`.
5. **Unit Test** — `npm test`.
6. **SonarQube Analysis** — `sonar-scanner` runs static analysis against
   the self-hosted SonarQube instance (`terraform/sonarqube.tf`).
7. **Quality Gate** — `waitForQualityGate()` blocks until SonarQube's
   webhook reports the gate result; a failing gate fails the build.
8. **OPA Policy Check** — `conftest` evaluates `policy/*.rego` against
   `app/Dockerfile`, `app/package.json` (Node version pin, both must
   agree), and the rendered Helm manifest for the target environment
   (resource limits, probes, security context, no `:latest`).
9. **Docker Build** — multi-stage `docker build` from `app/Dockerfile`.
10. **Docker Image Scan** — `trivy image` scans the freshly built LOCAL
    image before it's ever pushed; a vulnerable image never reaches ECR.
11. **Push to ECR** — pushes by tag, then resolves and records the
    pushed image's sha256 digest.
12. **Sign Image** — `cosign sign --key awskms:///...` signs that exact
    digest using the AWS KMS key in `terraform/signing.tf` — Jenkins calls
    `kms:Sign` via its instance profile; no private key file exists
    anywhere.
13. **Approval Gate** — *skipped for `dev`.* For `staging`/`prod`, an
    `input` step pauses (up to 24h) for a named approver
    (`release-approvers`) to click Deploy, showing the exact image tag and
    digest being promoted.
14. **Verify Image Signature** — `cosign verify` re-checks the signature
    from step 12 before deploying, for every environment.
15. **Deploy to Kubernetes** — `helm upgrade --install --wait`, deploying
    by **digest** (`image.tag@sha256:...`), not by mutable tag — the exact
    artifact that was scanned, signed, and verified.
16. **Smoke Test** — waits for `kubectl rollout status`, then runs a
    throwaway pod that curls `/health` through the in-cluster Service.

`post { failure { ... } }` prints the rollback command (see below). Docker
image pruning happens inside the "Docker Image Scan" stage's own `post`
block, not a pipeline-level one — see the Jenkinsfile's "AGENT NOTE" for
why (the Approval Gate's 24-hour wait must not hold the only executor).

## Deployment strategy + rollback

**Strategy: rolling update.** Configured in `values.yaml`:

```yaml
deploymentStrategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0   # never drop below full desired capacity
    maxSurge: 1          # add one extra pod at a time during rollout
```

Combined with the readiness probe (`GET /health`), Kubernetes only routes
traffic to a new pod once it's actually answering health checks, and never
removes an old pod until its replacement is ready — so a rollout is
zero-downtime from the client's perspective. `helm upgrade --wait` blocks
the Jenkins stage until the rollout finishes (or times out), so a bad
rollout fails the *build*, not just the cluster state.


**Rollback:** Helm keeps a revision history for every release, so rollback
is a single command:

```bash
helm rollback devops-sample-api-<env> 0 -n devops-sample-api-<env>
# 1 = the previous successfully deployed revision
```

This is called out explicitly in the Jenkinsfile's `post { failure { ... } }`
block. For a fully automated rollback-on-failure, the "Smoke Test" stage
could be extended with `catchError` to run `helm rollback` automatically
when the smoke test fails — left manual here so a human confirms *why* it
failed before reverting.

## AWS integration

### Design (what each piece does)

| Component | Role |
|---|---|
| **ECR** (Elastic Container Registry) | Private Docker registry; Jenkins pushes here, EKS pulls from here. |
| **EKS** (Elastic Kubernetes Service) | Managed Kubernetes control plane running the Deployment/Service/Ingress/HPA. |
| **AWS Load Balancer Controller** | A controller running *inside* EKS that watches `Ingress` objects with `ingressClassName: alb` and provisions/updates a real ALB + target groups to match. |
| **ALB** (Application Load Balancer) | Internet-facing entry point; forwards HTTP(S) traffic to pod IPs directly (`target-type: ip`), bypassing kube-proxy. |
| **Karpenter** | Node-level autoscaler — watches for `Pending` pods the existing nodes have no room for and launches a right-sized EC2 instance in response (and removes it again once idle). Complements the HPA below, which only scales *pod* replica count, not node capacity. |
| **IAM / IRSA** | Grants the AWS Load Balancer Controller, Karpenter, External Secrets, and Kyverno (and optionally the app itself) least-privilege AWS permissions via IAM Roles for Service Accounts, not static credentials baked into pods. |

### Actual setup 

Superseded by Terraform — `terraform/` provisions the VPC, EKS cluster,
ECR repository, IAM instance profile + IRSA roles, the AWS Load Balancer
Controller, Metrics Server, External Secrets Operator, Kyverno, Karpenter,
the KMS signing key, and both the Jenkins and SonarQube EC2 hosts, all
across two ordered `terraform apply` runs (root stack, then
`cluster-addons/`). Each environment (dev/staging/prod) gets its own full
copy of all of the above, selected via `terraform workspace select` —
see `terraform/README.md`'s "Environments" section for why. See
`terraform/README.md` for the quick version, no manual `eksctl`/console-click sequence is documented here
anymore because none of it is a manual step.

## DevSecOps controls

Layered so a failure at any one layer still gets caught by the next:

| Layer | Where | What it catches |
|---|---|---|
| **Dependency/secret scanning** | Jenkinsfile "Dependency & Filesystem Scan" (`npm audit` + `trivy fs`) | Vulnerable npm packages, accidentally-committed secrets — before any image is built |
| **Static analysis** | Jenkinsfile "SonarQube Analysis" + "Quality Gate" (`sonar-project.properties`, `terraform/sonarqube.tf`) | Code smells, bugs, security hotspots in `app/`; a failing Quality Gate blocks the build |
| **Policy-as-code (CI)** | Jenkinsfile "OPA Policy Check" (`policy/*.rego`, evaluated by Conftest) | Node version drift between Dockerfile/package.json; missing resource limits/probes/security context in rendered manifests — before any image is built |
| **Image vulnerability scanning** | Jenkinsfile "Docker Image Scan" (`trivy image`) | OS/package CVEs in the built image — scanned locally, before push |
| **Image signing** | Jenkinsfile "Sign Image"/"Verify Image Signature" (`cosign` + `terraform/signing.tf`'s KMS key) | Tampering/substitution between build and deploy; no private key file ever exists |
| **Policy-as-code (runtime)** | `k8s-policies/kyverno/*.yaml`, enforced by Kyverno as an admission controller (`terraform/kyverno.tf`) | Anything that bypasses Jenkins entirely — unsigned images, wrong registry, `:latest` tags, privileged/root containers, missing limits/probes, all re-checked at the moment a Pod is actually created |
| **Human approval** | Jenkinsfile "Approval Gate" | Any staging/prod deploy, regardless of how clean every automated check came back |

## ALB + Kubernetes traffic flow

```
Internet
   │
   ▼
Application Load Balancer (internet-facing, provisioned by the
AWS Load Balancer Controller from the Ingress object)
   │  (target-type: ip — ALB talks directly to pod IPs,
   │   bypassing kube-proxy/Service for the data path)
   ▼
Pod IPs registered in the ALB Target Group
(the AWS Load Balancer Controller keeps this group in sync with
 Ready pods behind the Service, using the same readiness probe
 Kubernetes itself uses)
   │
   ▼
Node.js/Express container (:3000) → /health or /api
```

Two independent health-check layers exist on purpose:

1. **Kubernetes readiness/liveness probes** (`values.yaml: probes.*`) —
   control whether the *Service* considers a pod a valid endpoint, and
   whether kubelet restarts a pod that's stuck.
2. **ALB target group health checks** (`ingress.annotations`, same
   `/health` path) — control whether the *ALB* forwards traffic to a given
   pod IP, independent of Kubernetes' own view.

Both point at the same `/health` endpoint so the two layers stay in
agreement, but they're enforced by different systems — a pod can be pulled
from the ALB target group slightly faster/slower than it's pulled from the
Service, which is expected and fine.

The `Service` (`ClusterIP`) still exists for in-cluster traffic (e.g. the
Jenkins smoke test, or other services calling this API internally) — the
ALB's `target-type: ip` mode means external traffic doesn't actually route
through it, but it remains the stable in-cluster DNS name and the object
the Ingress and HPA both reference.

## Autoscaling

`templates/hpa.yaml` defines a `HorizontalPodAutoscaler` targeting the
Deployment, driven by CPU and memory:

```yaml
minReplicas: 2                              # 3 in prod
maxReplicas: 10
targetCPUUtilizationPercentage: 70          # 60 in prod
targetMemoryUtilizationPercentage: 80
```

- Requires the **Metrics Server** to be running on the cluster (installed
  in the AWS setup steps above) — it's what the HPA controller queries for
  actual pod CPU/memory usage every ~15s.
- `behavior.scaleUp` reacts immediately (0s stabilization window, up to +2
  pods/min) so traffic spikes are absorbed quickly.
- `behavior.scaleDown` waits 5 minutes of sustained low usage before
  removing pods (1 pod/min max), avoiding flapping on bursty traffic.
- `resources.requests`/`resources.limits` on the container (also in
  `values.yaml`) are what "70% CPU utilization" is measured *against* —
  the HPA scales based on usage relative to the request, not an absolute
  number.
- Environment-specific thresholds live in `values-<env>.yaml` (e.g. prod
  scales more eagerly, at 60% CPU, and keeps a higher floor of 3 replicas
  for baseline redundancy across AZs).

## Node autoscaling (Karpenter)

The HPA above only scales *pod* replica count — it doesn't help if the
cluster's existing nodes have no room left to schedule those extra pods.
That's what [Karpenter](https://karpenter.sh) adds: it watches for
`Pending` pods the current nodes can't fit, launches a right-sized EC2
instance in response, and removes it again once it's empty or
underutilized. It's node-level autoscaling; the HPA above remains
pod-level — the two work together, not in place of each other.

Installed across the same two ordered Terraform stacks as everything
else in this project:

| Stack | File | What it does |
|---|---|---|
| `terraform/` (root) | `karpenter.tf` | Karpenter's IAM side: controller IRSA role, node IAM role, SQS interruption queue + EventBridge rules, EKS access entry for nodes it launches, and `karpenter.sh/discovery` tags on the private subnets + node security group. |
| `terraform/cluster-addons/` | `karpenter.tf` | Installs the Karpenter Helm chart into `kube-system`, then applies the `EC2NodeClass`/`NodePool` from `k8s-policies/karpenter/`. |

The `standard-workers` EKS managed node group (`terraform/eks.tf`) is left
exactly as-is, not replaced — it's still where Karpenter's own controller
pod, CoreDNS, the ALB controller, Kyverno, and External Secrets run.
Karpenter needs somewhere stable to run *before* it can provision
anything, so it never schedules itself onto a node it launched.
`k8s-policies/karpenter/nodepool.yaml` picks from a flexible set of
instance families/generations rather than one hardcoded type, and is
on-demand only by default (the interruption queue for spot is already
wired up if you turn spot on later). No changes were needed in
`helm/devops-sample-api` — its `nodeSelector`/`tolerations`/`affinity`
are all empty by default, so app pods already land on whatever node
exists, including ones Karpenter launches.

## Secrets & Config

Two different mechanisms, intentionally kept separate:

**Config (non-secret)** — `ConfigMap` (`templates/configmap.yaml`), sourced
from `config.*` in `values.yaml`/`values-<env>.yaml`. Injected into the
container via `envFrom`. This is how `APP_ENV`, `APP_GREETING`,
`FEATURE_FLAG_BETA`, and `APP_VERSION` reach the app, and it's how the same
image behaves differently per environment without a rebuild.

**Secrets** — two modes, toggled by `secret.externalSecrets.enabled`:

- ** (default, `secret.create: true`)** — a plain Kubernetes `Secret`
  (`templates/secret.yaml`) with a placeholder `API_KEY`, so the whole
  chart deploys and runs standalone with zero real credentials, satisfying
  "show how secrets are handled (even if mocked)".
- **Real AWS-backed (`secret.externalSecrets.enabled: true`, used in
  `values-prod.yaml`)** — an `ExternalSecret` object instead, which the
  [External Secrets Operator](https://external-secrets.io) syncs from AWS
  Secrets Manager (or SSM Parameter Store) into a real Kubernetes `Secret`
  on a schedule (`refreshInterval: 1h`). The Operator authenticates via
  IRSA — no AWS credentials are ever stored in the cluster or in Jenkins for
  this path. The app code doesn't know or care which mode produced the
  Secret; it just reads `API_KEY` from the environment either way.

Either way, secrets are never baked into the Docker image or committed to
git — only referenced by name/ARN.
