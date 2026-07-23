// Jenkinsfile — CI/CD pipeline for devops-sample-api
//
// Flow: checkout -> build -> dependency/vuln scan -> unit test -> SonarQube
//       analysis -> quality gate -> OPA policy check -> docker build ->
//       image vuln scan -> push to ECR -> sign image (cosign/KMS) ->
//       [manual approval for staging/prod] -> verify signature -> deploy
//       -> smoke test -> (manual) rollback hook
//
// ONE ENVIRONMENT, FULLY SEPARATE INFRASTRUCTURE: terraform/ provisions
// dev/staging/prod as entirely independent stacks (own VPC, EKS cluster,
// ECR repo, Jenkins host, SonarQube host — selected via Terraform
// workspace, see terraform/locals.tf), not namespaces carved out of one
// shared cluster. This Jenkinsfile is the same file checked into git for
// every environment; what makes a given Jenkins host only able to affect
// its own environment is the scoped IAM role below, not anything in this
// file. Running a build with DEPLOY_ENV set to a different environment
// than the one this host was provisioned for is expected to fail cleanly
// at "Push to ECR" or "Deploy to Kubernetes" with an AWS access-denied
// error. Only "dev" has actually been provisioned and run end to end so
// far — see terraform/README.md, "Adding another environment," for
// staging/prod.
//
// PRODUCTION-GRADE AUTH MODEL — no AWS access keys anywhere in this file
// or in Jenkins' credential store:
//   - Jenkins runs on the EC2 instance provisioned by terraform/jenkins.tf,
//     launched with an IAM INSTANCE PROFILE (terraform/iam.tf:
//     aws_iam_role.jenkins). The AWS CLI/SDK picks up short-lived,
//     auto-rotating credentials from the instance metadata service
//     automatically — no `aws configure`, no stored access key. That role
//     is scoped to: push/pull ONE ECR repo, describe ONE EKS cluster —
//     both belonging to this host's own environment only —
//     kms:Sign/GetPublicKey/DescribeKey on ONE signing key (signing.tf).
//   - Kubernetes-level authorization comes from the EKS access entry in
//     terraform/iam.tf ("edit", scoped to just this environment's own
//     devops-sample-api-<env> namespace — not cluster-admin, and not the
//     other environments' namespaces, since they're not even on this
//     cluster).
//   - Source checkout uses a read-only SSH deploy key (Jenkins credential
//     ID "github-deploy-key"), scoped to this one repository.
//   - Image signing uses cosign against an AWS KMS asymmetric key — no
//     private key file ever exists on disk.
//   - The ONE credential that IS stored in Jenkins: a SonarQube analysis
//     token (System Config, "SonarQube servers" > installation named
//     "sonarqube", credential ID "sonarqube-token"). SonarQube has no
//     IAM-style federation, so a token is unavoidable here — scope it to
//     "Execute Analysis" only in SonarQube's own token settings, and
//     rotate it periodically. Documented, not hidden.
//
// Required Jenkins plugins: Pipeline, Docker Pipeline, Git, SonarQube
// Scanner. (No AWS Credentials plugin — nothing to bind.)
//
// Required Jenkins system config:
//   - Manage Jenkins > System > SonarQube servers: name "sonarqube",
//     Server URL = http://<sonarqube_public_ip from terraform output>:9000,
//     Server authentication token = credential "sonarqube-token"
//   - SonarQube itself, Administration > Webhooks: add
//     http://<jenkins_public_ip>:8080/sonarqube-webhook/ so
//     waitForQualityGate doesn't have to poll
//   - Approvers for staging/prod deploys: a Jenkins user/group named
//     "release-approvers" (see APPROVAL_SUBMITTERS below) — configure via
//     Manage Jenkins > Users, and Role-Based Authorization Strategy (or
//     Matrix Authorization) if you want a real group rather than a
//     comma-separated username list.
//
// AGENT NOTE: there is no pipeline-level "agent any" — agent is declared
// PER STAGE (still "any", i.e. still the single Jenkins host in this
// simple setup) specifically so the Approval Gate stage can omit an
// agent entirely. With a single top-level agent, a 24-hour input-step
// wait would hold this pipeline's only executor the whole time, blocking
// every other build on the same host; releasing the agent during that
// wait and re-acquiring it once approved avoids that. One consequence:
// the AWS_ACCOUNT_ID lookup can no longer live in the top-level
// "environment" block (that block has no agent to run `sh` on) — it's
// computed in the first stage's steps instead, see "Initialize".
//
// See "Production-Grade Security & Terraform Runbook" and "Adding
// DevSecOps Controls" for the full setup and rationale.

pipeline {
    agent none

    options {
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        disableConcurrentBuilds()
        ansiColor('xterm')
    }

    parameters {
        choice(name: 'DEPLOY_ENV', choices: ['dev', 'staging', 'prod'], description: 'Target environment / Helm values file')
        booleanParam(name: 'SKIP_DEPLOY', defaultValue: false, description: 'Build, scan, sign and push only — skip the Kubernetes deploy step entirely')
    }

    environment {
        // Static values only — anything requiring a shell command
        // (AWS_ACCOUNT_ID, ECR_REGISTRY, IMAGE_URI) is computed in the
        // "Initialize" stage below instead, since this block has no agent.
        AWS_REGION        = 'ap-south-1'

        // Each environment now provisions FULLY SEPARATE infrastructure —
        // its own VPC, EKS cluster, ECR repo, and Jenkins host, selected
        // by Terraform workspace (terraform/locals.tf). This Jenkins host
        // therefore only ever HAS credentials for the one environment it
        // was provisioned for (its IAM instance profile is scoped to that
        // environment's ECR repo/EKS cluster only — see terraform/iam.tf).
        // ECR_REPO/EKS_CLUSTER_NAME are still derived from params.DEPLOY_ENV
        // (rather than hardcoded per-host) so this one Jenkinsfile, checked
        // into git once, works unmodified on every environment's Jenkins —
        // but running a build with DEPLOY_ENV set to a DIFFERENT
        // environment than the one this host was provisioned for is
        // expected to fail cleanly at "Push to ECR" or "Deploy to
        // Kubernetes" with an AWS access-denied error, not silently touch
        // the wrong environment. See terraform/README.md, "Adding another
        // environment."
        ECR_REPO          = "devops-sample-api-${params.DEPLOY_ENV}"
        EKS_CLUSTER_NAME  = "devops-assignment-cluster-${params.DEPLOY_ENV}"
        K8S_NAMESPACE     = "devops-sample-api-${params.DEPLOY_ENV}"
        HELM_RELEASE      = "devops-sample-api-${params.DEPLOY_ENV}"

        // KMS alias, not an ARN — deterministic across accounts/regions
        // without having to hardcode an ARN here after every `terraform
        // apply`. Matches signing.tf's aws_kms_alias name (also
        // per-environment now — see terraform/locals.tf's name_prefix).
        COSIGN_KEY_REF    = "awskms:///alias/devops-assignment-${params.DEPLOY_ENV}-cosign-signing"

        // Comma-separated Jenkins usernames, OR a single group name if
        // Role-Based Authorization Strategy is installed and configured
        // with a "release-approvers" role. dev deploys never hit this —
        // only staging/prod do (see the "Approval Gate" stage).
        APPROVAL_SUBMITTERS = 'release-approvers'

        // Trivy/Conftest exit non-zero (failing the stage) on findings at
        // or above this severity. Anything accepted as risk goes in
        // .trivyignore WITH a reason, never a threshold bump.
        TRIVY_SEVERITY    = 'HIGH,CRITICAL'
    }

    stages {

        stage('Checkout') {
            agent any
            steps {
                // This job is configured as "Pipeline script from SCM" with
                // a git@github.com:... SSH repository URL and the
                // "github-deploy-key" credential selected in the Jenkins
                // job UI (not referenced here) — a read-only deploy key
                // scoped to this one repository, not an account-wide PAT.
                checkout scm
                script {
                    env.IMAGE_TAG = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
                }
            }
        }

        stage('Initialize') {
            agent any
            steps {
                script {
                    // Derived at runtime via the instance profile's own
                    // identity — nothing stored in Jenkins, nothing that
                    // can drift from the account this box actually lives in.
                    env.AWS_ACCOUNT_ID = sh(script: 'aws sts get-caller-identity --query Account --output text', returnStdout: true).trim()
                    env.ECR_REGISTRY   = "${env.AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
                    env.IMAGE_URI      = "${env.ECR_REGISTRY}/${ECR_REPO}:${env.IMAGE_TAG}"
                }
            }
        }

stage('Build') {
    agent any

    steps {
        dir('app') {
            sh '''
                set -e

                node -v
                npm -v

                npm config set engine-strict false

                if [ -f package-lock.json ]; then
                    npm ci --no-fund --no-audit
                else
                    npm install --no-fund --no-audit
                fi

                npm run build --if-present
            '''
        }
    }
}

        stage('Dependency & Filesystem Scan') {
            agent any
            steps {
                dir('app') {
                    // Fails the stage itself on any HIGH/CRITICAL npm
                    // advisory — no separate error handling needed, `npm
                    // audit --audit-level` already exits non-zero.
                    sh 'npm audit --audit-level=high'
                }
                // Broader than npm audit alone: catches vulnerable binaries/
                // libraries Trivy's DB knows about that npm's advisory feed
                // might not, plus accidentally-committed secrets.
                sh "trivy fs --scanners vuln,secret --severity ${TRIVY_SEVERITY} --ignorefile .trivyignore --exit-code 1 app"
            }
        }

        stage('Unit Test') {
            agent any
            steps {
                dir('app') {
                    sh 'npm test'
                }
            }
            post {
                always {
                    // If you later add a JUnit-formatted reporter (e.g. node-tap junit output),
                    // publish it here, e.g.:
                    // junit 'app/test-results/*.xml'
                    echo 'Unit tests complete (see console output above).'
                }
            }
        }

stage('SonarQube Analysis') {
    agent any

    steps {
        script {
            def scannerHome = tool 'SonarScanner'

            withSonarQubeEnv('sonarqube') {
                sh """
                    ${scannerHome}/bin/sonar-scanner \
                      -Dsonar.projectKey=devops-sample-api \
                      -Dsonar.projectName=devops-sample-api \
                      -Dsonar.projectVersion=${IMAGE_TAG} \
                      -Dsonar.sources=app
                """
            }
        }
    }
}

        stage('Quality Gate') {
            agent any
            steps {
                // Requires the SonarQube-side webhook (see header comment)
                // so this call returns as soon as analysis completes
                // instead of blocking for SonarQube's default poll timeout.
                timeout(time: 5, unit: 'MINUTES') {
                    script {
                        def qg = waitForQualityGate()
                        if (qg.status != 'OK') {
                            error "SonarQube Quality Gate failed: ${qg.status} — see the SonarQube project dashboard for details"
                        }
                    }
                }
            }
        }

        stage('OPA Policy Check') {
            agent any
            steps {
                // Node version pin: Dockerfile FROM vs package.json
                // engines.node vs policy/node_version.rego's single
                // source-of-truth constant — all three must agree.
                sh 'conftest test --policy policy app/Dockerfile'
                sh 'conftest test --policy policy app/package.json'

                // Rendered Kubernetes manifests for the ACTUAL target
                // environment/image this run would deploy — catches
                // resource-limit/probe/privilege regressions before any
                // image is even built, and independently of what Kyverno
                // would also catch at admission time in-cluster. Not yet
                // pushed/signed at this point, so this renders with the
                // tag only (no digest yet) — still exercises every other
                // policy (resources, probes, security context, no-:latest).
                // The Deploy stage further down additionally pins by
                // digest once one exists.
                sh """
                    helm template ${HELM_RELEASE} ./helm/devops-sample-api \
                      --values ./helm/devops-sample-api/values.yaml \
                      --values ./helm/devops-sample-api/values-${params.DEPLOY_ENV}.yaml \
                      --set image.repository=${env.ECR_REGISTRY}/${ECR_REPO} \
                      --set image.tag=${env.IMAGE_TAG} \
                      > rendered-${params.DEPLOY_ENV}.yaml
                    conftest test --policy policy rendered-${params.DEPLOY_ENV}.yaml
                """
            }
        }

        stage('Docker Build') {
            agent any
            steps {
                dir('app') {
                    sh """
                        docker build -t ${ECR_REPO}:${env.IMAGE_TAG} .
                        docker tag ${ECR_REPO}:${env.IMAGE_TAG} ${env.IMAGE_URI}
                        docker tag ${ECR_REPO}:${env.IMAGE_TAG} ${env.ECR_REGISTRY}/${ECR_REPO}:latest
                    """
                }
            }
        }

        stage('Docker Image Scan') {
            agent any
            steps {
                // Scans the LOCAL image, before it's ever pushed — a
                // vulnerable image never reaches ECR in the first place.
                sh "trivy image --severity ${TRIVY_SEVERITY} --ignorefile .trivyignore --exit-code 1 ${ECR_REPO}:${env.IMAGE_TAG}"
            }
            post {
                // Lives here (an "agent any" stage) rather than in the
                // pipeline-level post block, which has no agent to run sh
                // on (pipeline-level agent is "none" — see the AGENT NOTE
                // at the top of this file). "always" so a scan failure
                // still cleans up dangling layers from this build.
                always {
                    sh 'docker image prune -f || true'
                }
            }
        }

        stage('Push to ECR') {
            agent any
            steps {
                // No withCredentials block — the AWS CLI resolves
                // credentials from the EC2 instance profile automatically.
                // The Jenkins IAM role (terraform/iam.tf) is scoped to
                // exactly this one ECR repository; it cannot push/pull any
                // other repo in the account, and Terraform, not this
                // pipeline, owns repository creation, so no
                // create-if-missing fallback is needed or attempted here.
                sh """
                    aws ecr get-login-password --region ${AWS_REGION} \
                      | docker login --username AWS --password-stdin ${env.ECR_REGISTRY}

                    docker push ${env.IMAGE_URI}
                    docker push ${env.ECR_REGISTRY}/${ECR_REPO}:latest
                """
                script {
                    // Sign by DIGEST, not by mutable tag — this is what
                    // Kyverno's verifyImages policy checks against later.
                    env.IMAGE_DIGEST = sh(
                        script: "aws ecr describe-images --repository-name ${ECR_REPO} --image-ids imageTag=${env.IMAGE_TAG} --region ${AWS_REGION} --query 'imageDetails[0].imageDigest' --output text",
                        returnStdout: true
                    ).trim()
                }
            }
        }

        stage('Sign Image') {
            agent any
            steps {
                // cosign calls kms:Sign via the instance profile — no
                // private key file exists anywhere in this pipeline.
                // --yes skips the interactive "upload to a public log?"
                // prompt cosign shows by default (non-interactive in CI).
                sh "cosign sign --key ${COSIGN_KEY_REF} --yes ${env.ECR_REGISTRY}/${ECR_REPO}@${env.IMAGE_DIGEST}"
            }
        }

        stage('Approval Gate') {
            // Deliberately NO agent here — see the AGENT NOTE at the top
            // of this file. This is the whole reason pipeline-level agent
            // is "none" instead of "any".
            when {
                allOf {
                    expression { return !params.SKIP_DEPLOY }
                    expression { return params.DEPLOY_ENV != 'dev' }
                }
            }
            steps {
                timeout(time: 24, unit: 'HOURS') {
                    input(
                        message: "Deploy ${env.IMAGE_TAG} (image digest ${env.IMAGE_DIGEST}) to ${params.DEPLOY_ENV}?",
                        ok: 'Deploy',
                        submitter: "${APPROVAL_SUBMITTERS}",
                        submitterParameter: 'APPROVED_BY'
                    )
                }
                echo "Deployment to ${params.DEPLOY_ENV} approved by ${env.APPROVED_BY}"
            }
        }

        stage('Verify Image Signature') {
            agent any
            when {
                expression { return !params.SKIP_DEPLOY }
            }
            steps {
                // Runs for every environment, including dev — cheap, and
                // proves the sign/verify chain end-to-end on every build,
                // not just the ones that hit the approval gate. Kyverno
                // (k8s-policies/kyverno/verify-image-signature.yaml)
                // re-checks the same signature independently, in-cluster,
                // at admission time — this is defense in depth, not the
                // only gate.
                sh "cosign verify --key ${COSIGN_KEY_REF} ${env.ECR_REGISTRY}/${ECR_REPO}@${env.IMAGE_DIGEST}"
            }
        }

        stage('Deploy to Kubernetes') {
            agent any
            when {
                expression { return !params.SKIP_DEPLOY }
            }
            steps {
                // Same instance-profile credentials authenticate to EKS.
                // Kubernetes-level authorization is enforced separately by
                // the EKS access entry (terraform/iam.tf) that maps this
                // role to "edit" rights scoped to the devops-sample-api-*
                // namespaces only. Deploys by DIGEST, matching what was
                // scanned, signed, and verified above — not by the
                // mutable :IMAGE_TAG tag.
                sh """
                    aws eks update-kubeconfig --name ${EKS_CLUSTER_NAME} --region ${AWS_REGION}
                    kubectl get ns ${K8S_NAMESPACE} || kubectl create ns ${K8S_NAMESPACE}

                    helm upgrade --install ${HELM_RELEASE} ./helm/devops-sample-api \
                      --namespace ${K8S_NAMESPACE} \
                      --values ./helm/devops-sample-api/values.yaml \
                      --values ./helm/devops-sample-api/values-${params.DEPLOY_ENV}.yaml \
                      --set image.repository=${env.ECR_REGISTRY}/${ECR_REPO} \
                      --set image.tag=${env.IMAGE_TAG} \
                      --set image.digest=${env.IMAGE_DIGEST} \
                      --wait --timeout 5m
                """
            }
        }

        stage('Smoke Test') {
            agent any
            when {
                expression { return !params.SKIP_DEPLOY }
            }
            steps {
                sh """
                    kubectl rollout status deployment/${HELM_RELEASE}-devops-sample-api -n ${K8S_NAMESPACE} --timeout=120s
                    kubectl run smoke-test-${BUILD_NUMBER} --rm -i --restart=Never --image=curlimages/curl:8.8.0 -n ${K8S_NAMESPACE} -- \
                      curl -sf http://${HELM_RELEASE}-devops-sample-api/health
                """
            }
        }
    }

    post {
        success {
            echo "Deployed ${env.IMAGE_URI} (digest ${env.IMAGE_DIGEST}) to ${K8S_NAMESPACE} (release: ${HELM_RELEASE})"
        }
        failure {
            echo '''
                Build/deploy failed.
                Rollback (manual trigger, see README "Rollback" section):
                    helm rollback ${HELM_RELEASE} 0 -n ${K8S_NAMESPACE}
                (0 = previous successfully deployed revision; Helm keeps revision history
                 so this is a single command, typically completing in seconds.)
            '''
        }
    }
}
