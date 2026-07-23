# terraform/cluster-addons — Kyverno, ALB controller, Metrics Server, External Secrets

A separate Terraform stack (own state, own `terraform init`) from `../`
(the root stack that creates the VPC/EKS cluster/ECR/IAM/Jenkins/
SonarQube), applied as its own step **after** the root stack for the same
environment. It installs everything that has to talk to the live cluster:
Kyverno and its six `../../k8s-policies/kyverno/*.yaml` ClusterPolicies,
the AWS Load Balancer Controller, Metrics Server, and External Secrets
Operator + its `ClusterSecretStore`.

## Why this is a separate stack

The root stack used to install all of this itself, with the
`kubernetes`/`helm`/`kubectl` providers configured from `module.eks`'s
own outputs (`cluster_endpoint`, `cluster_certificate_authority_data`, an
`aws_eks_cluster_auth` token). That doesn't work reliably on a brand new
environment: Terraform has to resolve provider configuration before it
can plan *anything* using that provider, and on a first apply
`module.eks`'s outputs aren't known yet (`depends_on` sequences resource
*creation*, not provider *configuration*) — producing "Kubernetes
cluster unreachable: invalid configuration: no configuration has been
provided."

This stack's `providers.tf` instead looks the cluster up by name with
`data "aws_eks_cluster"`/`data "aws_eks_cluster_auth"` — a live AWS API
call, not a same-apply resource reference. A data source requires the
thing it's looking up to already exist, which the cluster always does by
the time you run this stack, because it's a separate `terraform apply`
that only makes sense to run after the root stack's. No two-phase
`-target` apply needed here, or in the root stack anymore either.

## Usage

Run this **after** `../` has been applied for the environment you want
(the root stack's `README.md` covers that). Same backend bucket/table,
same workspace-per-environment model:

```bash
cd terraform/cluster-addons
terraform init \
  -backend-config="bucket=<state_bucket>" \
  -backend-config="dynamodb_table=<lock_table>" \
  -backend-config="region=ap-south-1"

terraform workspace new dev      # first time only — must match the
terraform workspace select dev   # workspace you applied in ../ for dev

cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: tfstate_bucket (same bucket as above)

terraform plan  -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

Repeat for `staging`/`prod` once you've applied the root stack for those
environments too — same commands, just a different workspace selected in
both this stack and the root stack.

## Destroy

Reverse order from apply — this stack first, then the root stack (see
`../README.md`'s "Destroy" section for why: the ALB controller's own ENIs
can strand in the VPC and block it from deleting if you tear down the
root stack first while this one's `aws_load_balancer_controller` release
is still installed):

```bash
terraform workspace select dev
terraform destroy -var-file=terraform.tfvars

cd ..
terraform workspace select dev
terraform destroy -var-file=environments/dev.tfvars
```
