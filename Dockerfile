# Billington — Cloud Run-ready container.
#
# Notes for this workload:
#  - Slack Socket Mode means the bot maintains a persistent WebSocket. Cloud
#    Run must be configured with min-instances >= 1 AND CPU "always
#    allocated" so the connection survives idle periods.
#  - node-cron schedules fire in-process, so the same always-on config is
#    needed for them to run.
#  - Express health server listens on PORT (default 3048 locally; Cloud Run
#    injects PORT, usually 8080). The code already reads process.env.PORT.

FROM node:20-slim

WORKDIR /app

# Install only production deps first (better layer caching).
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev --no-audit --no-fund

# Copy source.
COPY . .

# Cloud Run injects PORT; default to 8080 if running locally.
ENV NODE_ENV=production \
    PORT=8080

EXPOSE 8080

# Note: do NOT use `npm start` here — it spawns an extra process which
# complicates signal handling (SIGTERM from Cloud Run during scale-down).
CMD ["node", "index.js"]
