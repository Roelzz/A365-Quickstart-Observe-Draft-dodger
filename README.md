# Draft Dodger

Email risk advisor. Analyses draft emails before you send them — scores passive aggression, emotional temperature, and formality match, flags risky phrases with rewrites, and returns a verdict (SEND / TONE DOWN / DELETE AND WALK AWAY) with a confidence score.

## Quick Start

```bash
uv sync
cp .env.example .env  # fill in AZURE_OPENAI_ENDPOINT and AZURE_OPENAI_DEPLOYMENT
uv run python start_with_generic_host.py
curl http://localhost:3978/api/health
```

## Docker

```bash
uv export --no-hashes 2>/dev/null > requirements.txt
docker build -t draft-dodger .
docker run -p 3978:3978 --env-file .env draft-dodger
```

## Deployment

See `deployment script/` for Azure Container Apps deployment scripts and manifest templates.
