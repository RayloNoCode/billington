#!/usr/bin/env bash
# Cloud Run deployment script for Billington.
#
# Run from the bill-ling repo root. First run takes ~5 minutes; subsequent
# runs are ~2 minutes (just the deploy step).
#
# Usage:
#   ./deploy.sh setup    # one-time: install/auth gcloud, enable APIs, push secrets
#   ./deploy.sh deploy   # build + deploy (use this for every redeploy)
#   ./deploy.sh logs     # tail the Cloud Run logs
#   ./deploy.sh status   # show service URL + revision
#   ./deploy.sh secrets  # re-sync secrets from local .env to Secret Manager

set -euo pipefail

PROJECT="raylo-production"
REGION="europe-west2"
SERVICE="bill-ling"
SA="billington-bq-viewer@${PROJECT}.iam.gserviceaccount.com"

# Secrets — values pulled from .env, names are also the env var names exposed
# to the container.
SECRETS=(SLACK_BOT_TOKEN SLACK_APP_TOKEN ANTHROPIC_API_KEY MAKE_API_KEY STANNP_API_KEY BILLINGTON_NOTION_TOKEN)
# Note: NOTION_TOKEN (the "IT Security Bot" integration) was the previous
# Notion auth path. Replaced by BILLINGTON_NOTION_TOKEN (dedicated "Billington"
# integration). Code reads BILLINGTON_NOTION_TOKEN first, falls back to
# NOTION_TOKEN for safety during the rollout. Once verified, the NOTION_TOKEN
# binding to billington-bq-viewer@ should be revoked (Stephen, step 4).

# GCP_SERVICE_ACCOUNT_JSON is set up out-of-band (the contents of
# raylo-service-account.json, stored in Secret Manager). It's mounted as
# an env var so the bot's startup hook writes it to disk and points
# GOOGLE_APPLICATION_CREDENTIALS at it — which Gmail DWD needs to read
# the SA's private key for the JWT impersonation handshake.
EXTRA_SECRETS=(GCP_SERVICE_ACCOUNT_JSON)

# Plain (non-secret) env vars set inline on the service.
PLAIN_ENV="NODE_ENV=production,STUART_USER_ID=U025HCYHVDH,RICHARD_USER_ID=UCS7EBDJM,DENTON_USER_ID=U0AJSCHV6MN"

# Non-secret env vars whose VALUES live in .env (gitignored) and are read at
# deploy time — so the value never lives in this tracked file. GOCARDLESS_ACCESS_TOKEN
# is shipped as a plain env var (not a Secret Manager secret) because the bot's
# service account can't be granted secret access without an org admin. Trade-off
# accepted by Hargo (14/07/2026): the token is readable by anyone with Cloud Run
# viewer access on the project. Move it to SECRETS once the IAM grant is in place.
PLAIN_ENV_FROM_DOTENV=(GOCARDLESS_ACCESS_TOKEN ANCHOR_PASSWORD)

cmd_setup() {
  echo "==> Installing gcloud (skipped if already present)..."
  if ! command -v gcloud >/dev/null 2>&1; then
    brew install --cask google-cloud-sdk
  fi

  echo "==> Logging in (browser will open)..."
  gcloud auth login
  gcloud config set project "$PROJECT"
  gcloud config set run/region "$REGION"

  echo "==> Enabling required APIs..."
  gcloud services enable \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    secretmanager.googleapis.com

  echo "==> Pushing secrets from .env to Secret Manager..."
  cmd_secrets

  echo "==> Setup complete. Run './deploy.sh deploy' next."
}

cmd_secrets() {
  if [[ ! -f .env ]]; then
    echo "ERROR: .env not found in $(pwd). Run from the bill-ling repo root." >&2
    exit 1
  fi
  for var in "${SECRETS[@]}"; do
    val=$(grep "^${var}=" .env | head -1 | cut -d= -f2- | sed 's/^"//; s/"$//')
    if [[ -z "$val" ]]; then
      echo "  ! $var is empty in .env, skipping"
      continue
    fi
    if gcloud secrets describe "$var" >/dev/null 2>&1; then
      printf "%s" "$val" | gcloud secrets versions add "$var" --data-file=- >/dev/null
      echo "  ↻ $var (new version added)"
    else
      printf "%s" "$val" | gcloud secrets create "$var" --data-file=- >/dev/null
      echo "  + $var (created)"
    fi
  done

  # Grant the bot's service account read access to ALL secrets in the project
  # in one go. Per-secret bindings can fail silently if the running user
  # lacks IAM-admin rights on individual secrets but has it project-wide.
  echo "==> Granting Secret Manager Secret Accessor to $SA at project level..."
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:$SA" \
    --role="roles/secretmanager.secretAccessor" \
    --condition=None >/dev/null
  echo "==> Secrets synced."
}

cmd_deploy() {
  local secrets_flag=""
  for var in "${SECRETS[@]}" "${EXTRA_SECRETS[@]}"; do
    secrets_flag+="${var}=${var}:latest,"
  done
  secrets_flag="${secrets_flag%,}"

  # Start from the static plain env, then append any .env-sourced plain vars
  # (values read at deploy time so they never live in this tracked file).
  local env_vars="$PLAIN_ENV"
  for var in "${PLAIN_ENV_FROM_DOTENV[@]}"; do
    val=$(grep "^${var}=" .env | head -1 | cut -d= -f2- | sed 's/^"//; s/"$//')
    if [[ -z "$val" ]]; then
      echo "  ! $var is empty/absent in .env — skipping (that feature stays disabled)"
      continue
    fi
    env_vars+=",${var}=${val}"
    echo "  → $var set as plain env var (from .env)"
  done

  echo "==> Deploying $SERVICE to Cloud Run ($REGION)..."
  gcloud run deploy "$SERVICE" \
    --source=. \
    --region="$REGION" \
    --service-account="$SA" \
    --min-instances=1 \
    --max-instances=1 \
    --cpu=1 \
    --memory=1Gi \
    --no-cpu-throttling \
    --port=8080 \
    --timeout=3600 \
    --no-allow-unauthenticated \
    --set-env-vars="$env_vars" \
    --set-secrets="$secrets_flag"
  echo "==> Deploy complete."
  cmd_status
}

cmd_logs() {
  echo "==> Last 100 log lines for $SERVICE (re-run to refresh)..."
  gcloud run services logs read "$SERVICE" --region="$REGION" --limit=100
}

cmd_status() {
  gcloud run services describe "$SERVICE" --region="$REGION" \
    --format='value(status.url,status.latestReadyRevisionName,status.conditions[0].message)'
}

case "${1:-deploy}" in
  setup)   cmd_setup ;;
  secrets) cmd_secrets ;;
  deploy)  cmd_deploy ;;
  logs)    cmd_logs ;;
  status)  cmd_status ;;
  *)
    echo "Usage: $0 {setup|secrets|deploy|logs|status}"
    exit 1
    ;;
esac
