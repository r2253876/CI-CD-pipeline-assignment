# Terraform — devops-assignment infrastructure

Two separate Terraform stacks, applied in order:

1. **This stack (`terraform/`)** provisions the VPC, EKS cluster + managed
   node group, ECR repository, IAM roles (instance profile for Jenkins,
   IRSA roles for the ALB controller, External Secrets Operator, and
   Kyverno), the app's Secrets Manager secret, both KMS keys (app
   secrets, cosign image signing), and the Jenkins and SonarQube EC2
   hosts — no eksctl, no manual console clicking, no IAM user with a
   static access key.
2. **`terraform/cluster-addons/`** (a separate stack, own state) installs
   everything that has to talk to the *live* cluster on top of it:
   Kyverno and its ClusterPolicies, the AWS Load Balancer Controller,
   Metrics Server, and External Secrets Operator. See
   `cluster-addons/README.md` for why this is a second stack rather than
   part of this one — short version: a `helm_release`/`kubectl_manifest`
   resource needs a provider that's configured from a *real, already
   existing* cluster, and this stack's own cluster doesn't exist yet the
   first time you apply it. Splitting the stacks means neither one ever
   needs a two-phase `-target` apply — a plain `terraform apply` always
   works, in both stacks, on every run including the first.

**Running these commands on Windows:** every multi-line command in this
README (and in the End-to-End Runbook / Production-Grade Security
Runbook) uses a trailing backslash `\` to continue onto the next line —
that's bash/zsh syntax. It does nothing useful in `cmd.exe` (each line
runs as its own command, and a line starting with `-backend-config=...`
gets interpreted as a program name, which is the
`'-backend-config' is not recognized...` error you'd see) and PowerShell
uses a backtick `` ` `` instead. The reliable fix is to run these
commands from **Git Bash** (installed alongside Git for Windows, which
you already have — right-click any folder > "Git Bash Here") or WSL,
rather than `cmd.exe` or PowerShell. If you'd rather stay in `cmd.exe`,
paste each multi-line command as a single line instead, e.g.:
`terraform init -backend-config="bucket=<value>" -backend-config="dynamodb_table=<value>" -backend-config="region=ap-south-1"`
— note the `bucket=` and `dynamodb_table=` key names are required
before each value; `-backend-config="<value>"` alone (no key name) is a
different, invalid form of the flag.

| File | Provisions |
|---|---|
| `vpc.tf`, `eks.tf`, `ecr.tf` | The VPC, EKS cluster + managed node group, and ECR repository. |
| `iam.tf` | The Jenkins EC2 instance role, EKS access entry, and the IRSA roles for the ALB controller, External Secrets Operator, and Kyverno — all created here rather than in `cluster-addons/`, since they only need `module.eks.oidc_provider_arn`, not live cluster access. |
| `jenkins.tf`, `sonarqube.tf` | The two EC2 hosts, fully bootstrapped via `user_data` — nothing to install by hand on either. |
| `secrets.tf` | The app's `API_KEY`, randomly generated and stored in Secrets Manager — never typed into a file or committed. |
| `signing.tf` | The asymmetric AWS KMS key (`ECC_NIST_P256`, `SIGN_VERIFY`) that cosign signs and verifies container images with. |
| `locals.tf` | Per-environment naming and the `check` block that stops you from applying against the wrong Terraform workspace. See "Environments," below. |
| `cluster-addons/` | A separate stack: Kyverno, the six `k8s-policies/kyverno/*.yaml` ClusterPolicies, the AWS Load Balancer Controller, Metrics Server, and External Secrets Operator. Applied after this stack — see `cluster-addons/README.md`. |

`iam.tf` also gives the Jenkins instance role a `CosignImageSigning`
statement (KMS `Sign`/`GetPublicKey`/`DescribeKey`, scoped to the
`signing.tf` key only) — sign-only, mirroring Kyverno's verify-only
grant, so no single identity in this stack can both sign an image and
skip verifying one.

**One secret this stack does not eliminate:** SonarQube has no
IAM-based auth path, so `withSonarQubeEnv('sonarqube')` in the
Jenkinsfile still depends on a Jenkins-side "Secret text" credential
holding a SonarQube user token, configured once by hand under *Manage
Jenkins → System → SonarQube servers* (name it `sonarqube` to match the
Jenkinsfile) after you log into the `sonarqube_url` output and generate
a token for a dedicated CI user. Every other credential in this project
is either an IAM instance profile/IRSA role or a KMS key — this token is
the one deliberate exception, and it's worth rotating it periodically
since it's a static bearer credential.


## Environments: fully separate infrastructure, selected by workspace

`dev`, `staging`, and `prod` are not namespaces carved out of one shared
cluster — each is its **own VPC, EKS cluster, ECR repository, Jenkins
host, SonarQube host, KMS keys, and Secrets Manager secret**, selected by
picking a Terraform workspace before every `plan`/`apply`, **in both
stacks** (this one and `cluster-addons/` — pick the same environment in
each):

```bash
terraform workspace new dev      # first time only
terraform workspace select dev
terraform apply -var-file=environments/dev.tfvars

cd cluster-addons
terraform workspace new dev && terraform workspace select dev
terraform apply -var-file=terraform.tfvars
```

**Only `dev` has actually been applied and tested by this project.**
`staging` and `prod` are fully wired up — `environments/staging.tfvars.example`,
`environments/prod.tfvars.example`, and the sizing defaults in
`variables.tf`'s `environment_config` map all exist — but deliberately
left uncreated until you're ready for them. See "Adding another
environment" below.

### Why full separation, and why it needed more than just `terraform workspace new`

Terraform workspaces isolate **state** for you automatically — same S3
backend, a separate state file per workspace via the built-in
`env:/<workspace>/...` key prefix (see `backend.tf`) — but they do
nothing about resource **names**. Left alone, `dev` and `staging` would
both try to create an IAM role, ECR repository, KMS alias, and Secrets
Manager secret with the exact same name in the exact same AWS account —
all four of those are account-and-region-unique, so the second
`terraform apply` would fail outright, or worse, silently start fighting
the first workspace over the same resource.

`locals.tf` is what actually makes full separation work: every resource
in this stack is named from `local.name_prefix`
(`"${var.project_name}-${terraform.workspace}"`, e.g.
`devops-assignment-dev`) instead of `var.project_name` directly, and a
`check` block fails `plan`/`apply` immediately — with an actionable
message — if you forget to select a workspace first, rather than letting
you provision resources under Terraform's implicit `default` workspace.
`cluster-addons/` has its own, simpler version of the same guard.

### What this buys you, beyond "the state files don't collide"

A compromised or misconfigured `dev` Jenkins host cannot touch
`staging`'s or `prod`'s cluster, ECR repo, or secrets at all — not just
"shouldn't, per an IAM policy," but structurally can't, because those
resources don't exist in `dev`'s AWS API calls' reach in the first
place. `iam.tf`'s EKS access entry for Jenkins is scoped to exactly one
namespace, `devops-sample-api-<environment>`, on exactly one cluster —
the one belonging to that same environment. Compare this to the
namespace-per-environment-on-one-shared-cluster model, where a single
compromised Jenkins host with "edit" on all three namespaces is one bad
`kubectl` command away from touching every environment.

### What it costs

Every environment you bring up is a second (or third) full copy of: one
EKS control plane, 2+ worker nodes, a NAT gateway, and two more EC2
instances (Jenkins, SonarQube). Bringing up all three environments
roughly triples the AWS bill of running just `dev`. `variables.tf`'s
`environment_config` map sizes `staging` a little larger and `prod`
meaningfully larger (`t3.large` nodes, min 3/max 10) than `dev`'s
minimum-viable sizing — reflect on whether you actually need that before
running `terraform apply -var-file=environments/prod.tfvars` against a
real bill.

### Adding another environment

1. Read `environments/staging.tfvars.example` (or `prod.tfvars.example`)
   top to bottom — it explains what's environment-specific and what
   isn't.
2. `cp environments/staging.tfvars.example environments/staging.tfvars`
   and fill in `admin_cidr`, `eks_public_access_cidrs`, and
   `jenkins_key_pair_name` (create the EC2 key pair first if it doesn't
   exist yet).
3. Review `variables.tf`'s `environment_config["staging"]` — the
   defaults are a starting point, not something this project has
   load-tested.
4. `terraform workspace new staging && terraform workspace select staging`
5. `terraform apply -var-file=environments/staging.tfvars`
6. `cd cluster-addons && terraform workspace new staging && terraform workspace select staging && terraform apply -var-file=terraform.tfvars` — same `tfvars` file as `dev` used (see `cluster-addons/README.md`; the only value in it, `tfstate_bucket`, doesn't vary per environment).
7. Repeat for this new environment's own Jenkins host — it needs its own GitHub deploy key,
   its own SonarQube token, and its own `release-approvers` group, since
   nothing about Jenkins' internal configuration is shared between
   environments (only the Terraform code that provisions the
   infrastructure underneath them is).
8. Update `helm/devops-sample-api/values-staging.yaml`'s
   `secret.externalSecrets.remoteRefKey` if you rename anything — it
   must read `devops-sample-api/staging/api-key`, matching
   `locals.tf`'s `local.app_secret_name` for that workspace.

## Quick start (dev)

```bash
# 0. Authenticate (no static access keys)
aws configure sso --profile devops-assignment
aws sso login --profile devops-assignment
export AWS_PROFILE=devops-assignment

# 1. One-time: create the remote state backend (shared across every environment)
cd bootstrap
terraform init
terraform apply
terraform output   # note state_bucket and lock_table

# 2. Select the dev workspace
cd ..
terraform init \
  -backend-config="bucket=<state_bucket from step 1>" \
  -backend-config="dynamodb_table=<lock_table from step 1>" \
  -backend-config="region=ap-south-1"

terraform workspace new dev      # first time only
terraform workspace select dev

cp environments/dev.tfvars.example environments/dev.tfvars
# edit dev.tfvars: admin_cidr, eks_public_access_cidrs, jenkins_key_pair_name

# 3. Apply this stack (VPC, EKS, ECR, IAM, Jenkins, SonarQube)
terraform plan -var-file=environments/dev.tfvars
terraform apply -var-file=environments/dev.tfvars

# 4. Apply cluster-addons/ (Kyverno, ALB controller, Metrics Server,
#    External Secrets) — a separate stack, run after this one:
cd cluster-addons
terraform init \
  -backend-config="bucket=<state_bucket from step 1>" \
  -backend-config="dynamodb_table=<lock_table from step 1>" \
  -backend-config="region=ap-south-1"
terraform workspace new dev && terraform workspace select dev
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: tfstate_bucket = <state_bucket from step 1>
terraform plan  -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
cd ..

# 5. Outputs you need next
terraform output jenkins_public_ip
terraform output sonarqube_url        # log in, generate a token, add it to Jenkins (see note above)
terraform output cosign_kms_key_arn
```

Every apply above — in both stacks, every time, including the very first
run against a brand new workspace — is a plain `terraform plan`/`apply`.
Neither stack's provider configuration depends on a resource created in
the same apply: this stack has no `kubernetes`/`helm`/`kubectl` providers
at all anymore, and `cluster-addons/`'s providers look the cluster up by
name with a data source, which only ever runs after the cluster genuinely
exists (because you always apply this stack first). See
`cluster-addons/README.md` for the full story, including the
"Kubernetes cluster unreachable: invalid configuration: no configuration
has been provided" error this split was written to eliminate for good.

## Destroy

Reverse order from apply — `cluster-addons/` first (its ALB controller's
own ENIs can strand in the VPC and block it from deleting if you tear
this stack down first), then this stack:

```bash
helm uninstall devops-sample-api-dev -n devops-sample-api-dev
kubectl delete ns devops-sample-api-dev

cd cluster-addons
terraform workspace select dev
terraform destroy -var-file=terraform.tfvars
cd ..

terraform workspace select dev
terraform destroy -var-file=environments/dev.tfvars

# only once EVERY environment (dev, and staging/prod if you created them)
# has been destroyed, in both stacks:
cd bootstrap && terraform destroy
```
