# =============================================================================
# app-sample/Dockerfile
#
# Multi-stage build:
#   Stage 1 (deps)   — install production dependencies only
#   Stage 2 (runner) — copy from deps, add app source, run as non-root
#
# Build args injected by Jenkinsfile.build Stage 3:
#   BUILD_NUMBER — Jenkins build number (stored as /app/.build-info)
#   GIT_COMMIT   — full commit SHA (stored as /app/.build-info)
#
# Image is pushed to ACR as:
#   <acr>.azurecr.io/platform-sample-app:<commit-sha>
#   <acr>.azurecr.io/platform-sample-app:latest
# =============================================================================

# ── Stage 1: install dependencies ────────────────────────────────────────────
FROM node:18-alpine AS deps
WORKDIR /app

# Copy only manifest files first to leverage Docker layer caching.
# npm ci installs exact versions from package-lock.json.
# --omit=dev excludes devDependencies (mocha, eslint, etc.) from the image.
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev --prefer-offline --no-audit

# ── Stage 2: runtime image ────────────────────────────────────────────────────
FROM node:18-alpine AS runner
WORKDIR /app

# Build metadata — useful for debugging running pods.
ARG BUILD_NUMBER=local
ARG GIT_COMMIT=unknown
RUN echo "{\"buildNumber\":\"${BUILD_NUMBER}\",\"gitCommit\":\"${GIT_COMMIT}\"}" \
    > /app/.build-info

# Copy dependencies from the deps stage (no devDependencies).
COPY --from=deps /app/node_modules ./node_modules

# Copy application source code.
COPY src/ ./src/
COPY package.json ./

# Run as non-root for security.
# node:18-alpine includes a built-in `node` user (uid 1000).
USER node

EXPOSE 3000

# Use SIGTERM for graceful shutdown (handled in src/index.js).
STOPSIGNAL SIGTERM

CMD ["node", "src/index.js"]
