# OPA policy, evaluated by Conftest against `helm template` output — a
# second, independent check on top of Kyverno's in-cluster admission
# policies (k8s-policies/kyverno/). Deliberately redundant with Kyverno:
# this one runs in CI, before anything reaches the cluster, so a violation
# fails the Jenkins build fast; Kyverno is the backstop that also catches
# anything deployed by a path that skips Jenkins entirely (kubectl apply
# by hand, a different pipeline, etc).
#
# Invoked as (see Jenkinsfile "OPA Policy Check" stage):
#   helm template devops-sample-api-dev ./helm/devops-sample-api \
#     --values ./helm/devops-sample-api/values.yaml \
#     --values ./helm/devops-sample-api/values-dev.yaml \
#     > rendered.yaml
#   conftest test --policy policy rendered.yaml
package main

is_deployment {
	input.kind == "Deployment"
}

containers[c] {
	is_deployment
	c := input.spec.template.spec.containers[_]
}

# --- No floating/"latest" tags — must be an immutable, traceable reference ---
deny[msg] {
	c := containers[_]
	image := c.image
	endswith(image, ":latest")
	msg := sprintf("Deployment %s: container '%s' uses ':latest' (image=%s) — pin to a specific tag/digest", [input.metadata.name, c.name, image])
}

deny[msg] {
	c := containers[_]
	image := c.image
	not contains(image, ":")
	msg := sprintf("Deployment %s: container '%s' has no tag at all (image=%s) — Docker defaults untagged references to :latest", [input.metadata.name, c.name, image])
}

# --- Every container must declare both requests and limits ---
deny[msg] {
	c := containers[_]
	not c.resources.requests.cpu
	msg := sprintf("Deployment %s: container '%s' is missing resources.requests.cpu", [input.metadata.name, c.name])
}

deny[msg] {
	c := containers[_]
	not c.resources.requests.memory
	msg := sprintf("Deployment %s: container '%s' is missing resources.requests.memory", [input.metadata.name, c.name])
}

deny[msg] {
	c := containers[_]
	not c.resources.limits.cpu
	msg := sprintf("Deployment %s: container '%s' is missing resources.limits.cpu", [input.metadata.name, c.name])
}

deny[msg] {
	c := containers[_]
	not c.resources.limits.memory
	msg := sprintf("Deployment %s: container '%s' is missing resources.limits.memory", [input.metadata.name, c.name])
}

# --- No privileged containers, ever ---
deny[msg] {
	c := containers[_]
	c.securityContext.privileged == true
	msg := sprintf("Deployment %s: container '%s' runs privileged: true — never allowed", [input.metadata.name, c.name])
}

# --- Must run as non-root ---
deny[msg] {
	c := containers[_]
	c.securityContext.runAsNonRoot != true
	msg := sprintf("Deployment %s: container '%s' does not set securityContext.runAsNonRoot: true", [input.metadata.name, c.name])
}

# --- No privilege escalation ---
deny[msg] {
	c := containers[_]
	c.securityContext.allowPrivilegeEscalation != false
	msg := sprintf("Deployment %s: container '%s' does not set securityContext.allowPrivilegeEscalation: false", [input.metadata.name, c.name])
}

# --- Liveness and readiness probes required ---
deny[msg] {
	c := containers[_]
	not c.livenessProbe
	msg := sprintf("Deployment %s: container '%s' has no livenessProbe", [input.metadata.name, c.name])
}

deny[msg] {
	c := containers[_]
	not c.readinessProbe
	msg := sprintf("Deployment %s: container '%s' has no readinessProbe", [input.metadata.name, c.name])
}
