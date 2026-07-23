# OPA policy, evaluated by Conftest — enforces that the Node.js version is
# pinned to the SAME exact version in two independent places that could
# otherwise silently drift apart: the Dockerfile's base image and
# package.json's engines field. .npmrc's engine-strict=true enforces the
# package.json half at install time; this policy enforces both halves at
# CI time, before an image is even built.
#
# Invoked as two separate Conftest runs (see Jenkinsfile "OPA Policy
# Check" stage):
#   conftest test --policy policy app/Dockerfile     (auto-detected as the docker parser)
#   conftest test --policy policy app/package.json   (auto-detected as the json parser)
package main

# Single source of truth for the approved Node.js version. If you bump
# Node versions, this is the one line to change — then update
# app/Dockerfile's two FROM lines and app/package.json's engines.node to
# match, and this policy proves you did all three.
approved_node_version := "20.15.1"
approved_alpine_version := "3.19"
approved_node_image := sprintf("node:%s-alpine%s", [approved_node_version, approved_alpine_version])

# --- Dockerfile: every FROM must reference the approved Node image ---
deny[msg] {
	instruction := input[_]
	lower(instruction.Cmd) == "from"
	image := instruction.Value[0]
	not startswith(image, approved_node_image)
	msg := sprintf(
		"Dockerfile: FROM '%s' is not the approved Node base image '%s'",
		[image, approved_node_image],
	)
}

# --- package.json: engines.node must be pinned to the exact approved version ---
deny[msg] {
	input.engines.node
	input.engines.node != approved_node_version
	msg := sprintf(
		"package.json: engines.node is '%s', expected the approved exact version '%s'",
		[input.engines.node, approved_node_version],
	)
}

deny[msg] {
	not input.engines.node
	input.name == "devops-sample-api"
	msg := "package.json: engines.node is missing — must pin the exact approved Node.js version"
}
