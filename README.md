# PKI Control Plane

This repository now includes:

- Existing PKI shell scripts (`scripts/`) for root/intermediate CA and leaf certificate workflows.
- A new API service (`api/`) that wraps those scripts into asynchronous jobs.
- A new web app (`web/`) for submitting jobs and checking status.

## Architecture

- `api`: FastAPI service with in-memory queue + background worker thread.
- `web`: static HTML/JS app hosted by NGINX in Docker.

## Run locally with Docker

```bash
docker compose up --build
```

- Web UI: `http://localhost:8080`
- API docs: `http://localhost:8000/docs`
- API health: `http://localhost:8000/health`

## API endpoints

- `POST /jobs/create-intermediate-ca`
- `POST /jobs/sign-intermediate-csr`
- `POST /jobs/create-leaf-p12`
- `POST /jobs/sign-leaf-csr`
- `GET /jobs/{job_id}`

## Test API

```bash
pip install -r api/requirements-dev.txt
pytest api/tests/test_api.py
```
