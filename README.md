# Billington

Billington is an AI operations assistant for Raylo's
billing, collections, and regulatory-compliance team. It runs as a Slack bot
(Socket Mode) on Google Cloud Run and helps the team monitor BACS/GoCardless
activity, reconcile bounces, track refunds, run the daily late-fee process, and
answer billing questions from live systems.

It is a single Node.js service (`index.js`) owned by the billing ops team.

## What it does

- **Monitoring & reporting**: daily BACS batch forecasts, ARUDD bounce
  reconciliation, late-fee readiness checks, Stannp and GoCardless balance
  checks, NODS/NOSIA notice tracking, and scheduled Slack channel summaries.
- **Answering questions**: reads BigQuery (analytics) and the Aryza Lend
  ("Anchor") API (per-agreement ledger) to answer operational questions.
- **Actioning defined workflows**: a fixed set of billing actions (see Controls
  below), always through deterministic, gated code paths.

## Systems it connects to

| System | Access | Purpose |
|---|---|---|
| Slack | Bot token (Socket Mode) | The interface; reads/writes the billing channels it is a member of |
| BigQuery (`raylo-production`) | Read-only | Analytics and reconciliation queries |
| Aryza Lend / Anchor (SOAP) | Read + a fixed set of writes | Per-agreement ledger; posting the defined transaction types below |
| GoCardless API | Read-only | Payment-account balance and trade-in payment schedule |
| Gmail (`billingoperations@`) | Domain-wide delegation (IT approved) | Reads/labels the billing ops inbox for notice + Aryza-ticket tracking |
| Make.com | API | Triggers the existing Apply Late Fees scenario |

## Controls and governance

Billington performs a **fixed, known set of financial actions** and only ever
does so through deterministic code, never from free-form model output.

**1. The model never posts anything financial.** All Anchor write actions
(GOGW `TypeId 61`, refund `TypeId 149`, closures `26/30/46`, rebate `33`,
team-status `532`) run only from explicit command handlers or button presses.
The conversational LLM cannot post transactions; if it ever claims to, that is a
bug, and the code is written so it physically cannot call the write paths.

**2. Authorised operators only.** Each action is gated to named people:

| Action | Authorised |
|---|---|
| Post GOGW / auto-post refund | Hargo, Charlotte Platt, Ciaran Dobbin |
| Close account + refund (composite) | Hargo only |
| Apply late fees (manual trigger) | Hargo, Charlotte Platt, Omer Toker |
| Remediate missing NODS | Hargo, Charlotte Platt, Omer Toker |

**3. Confirmation and approval gates.**
- High-trust actions are surfaced as Slack **buttons with a confirm dialog**;
  nothing posts on a single stray message.
- A **lead-approval limit** (`LEAD_APPROVAL_LIMIT_GBP = £100`) governs which
  refunds/GOGW can be actioned without further sign-off.
- Refunds refuse unless preconditions hold (for example the account must clear to
  `TotalArrears <= £0.01`, and net cash must be a whole multiple of the monthly
  instalment), and refuse if the transaction category cannot be determined.

**4. Idempotency.** Every write checks whether it has already been posted before
acting, so retries, restarts, and re-presses do not double-post.

**5. Audit trail.** Every posted transaction carries a description recording how
it was raised (e.g. "posted via Slack auto-approval on A00…"), and the operator
who triggered it is captured. Anchor's own `CreatedByName` is used when reporting
who posted a transaction, never a guess.

**6. Late-fee automation.** The daily Apply Late Fees run auto-triggers only when
all readiness criteria are green (ARUDD reconciled, source tables fresh, volume
in line with estimate) and stops at a 12:30 cutoff. It can be put on manual hold
so an authorised operator presses a button instead.

## Secrets

No secrets are stored in this repository. All credentials (Slack, Anthropic,
Make, Stannp, GoCardless, the GCP service-account key) are held in Google Secret
Manager and injected at deploy time. `.env` and key files are gitignored and have
never been committed. The Gmail impersonation subject is hardcoded so a leaked
key or code change can never widen it to another mailbox.

## Deployment

Deployed to Google Cloud Run from a developer machine:

```
./deploy.sh deploy
```

The deploy builds from source and mounts secrets from Secret Manager. It does not
pull from GitHub, so the repository location does not affect the running service.

## Persona

Billington has a light, defined character used only for casual chat. It lives in
a separate file (`billington-persona.js`) and is kept entirely out of the
operational logic and financial controls above.

## Data handling

Billington reads live billing data to answer questions but does not store
customer personal data in this repository. Identifiers used in code and comments
are internal agreement references (e.g. `A00…`) and colleague Slack IDs.
