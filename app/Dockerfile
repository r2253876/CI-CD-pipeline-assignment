# ---------- Build stage ----------
# Pinned to an EXACT Node.js version (not a floating major tag like
# "20-alpine") so the base image can never drift out from under the app
# between builds. Deliberately NOT parameterized via ARG — Conftest's
# Docker parser reads the literal FROM line without resolving build args,
# so a hardcoded tag here is what policy/node_version.rego actually checks
# against. Both FROM lines below AND app/package.json's "engines.node" are
# required to name this exact same version — the OPA Policy Check stage in
# the Jenkinsfile fails the build if any of the three disagree.
FROM node:20.15.1-alpine3.19 AS build

WORKDIR /usr/src/app

# Install dependencies first so Docker layer caching skips this step
# when only application code changes.
COPY package*.json ./
RUN npm install --omit=dev

COPY . .

# ---------- Runtime stage ----------
FROM node:20.15.1-alpine3.19 AS runtime

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /usr/src/app

# Run as a non-root user (also required by many Kubernetes Pod Security Standards / OPA policies).
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

COPY --from=build /usr/src/app/node_modules ./node_modules
COPY --from=build /usr/src/app/index.js ./index.js
COPY --from=build /usr/src/app/package.json ./package.json
COPY --from=build /usr/src/app/public ./public

USER appuser

EXPOSE 3000

# Container-level healthcheck (independent of the Kubernetes probes
# defined in the Helm chart) — useful when running the image standalone,
# e.g. `docker run` during local dev, outside of Kubernetes.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://127.0.0.1:3000/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

CMD ["node", "index.js"]
