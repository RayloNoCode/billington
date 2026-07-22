# Billington — Cloud Run-ready container.
#  - Slack Socket Mode = persistent WebSocket -> min-instances>=1 + CPU always allocated.
#  - node-cron in-process schedules need the same always-on config.
#  - Express health server listens on PORT (Cloud Run injects it).
FROM node:22-trixie-slim

WORKDIR /app

# Patch OS base packages (clears GnuTLS criticals + libc/dpkg highs).
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*

# Prod deps first (layer caching).
COPY package.json package-lock.json* ./
# Strip npm/npx/corepack after install — not needed at runtime (CMD is `node index.js`) and
# it drops their vendored tar/minimatch/cross-spawn/brace-expansion/sigstore CVEs.
RUN npm ci --omit=dev --no-audit --no-fund \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
              /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack

COPY . .

ENV NODE_ENV=production \
    PORT=8080

EXPOSE 8080

# Do NOT use `npm start` (extra process complicates SIGTERM handling on scale-down).
CMD ["node", "index.js"]
