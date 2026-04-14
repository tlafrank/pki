# PKI Control Plane

This repository now includes:

- Existing PKI shell scripts (`scripts/`) for root/intermediate CA and leaf certificate workflows.
- A new API service (`api/`) that wraps those scripts into asynchronous jobs.
- A new web app (`web/`) for submitting jobs and checking status.

## Architecture

- `api`: FastAPI service with in-memory queue + background worker thread.
- `web`: static HTML/JS app hosted by NGINX in Docker.
  - supports downloading a blank CSV batch template, importing populated CSV rows, and downloading a ZIP of generated certificate packages.

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
- `GET /templates/leaf-batch.csv`
- `POST /batch/create-leaf-p12`
- `GET /downloads/{artifact_id}`

## Key handling

- `create_sign_package_leaf.sh` now deletes the generated leaf private key after successful PKCS#12 packaging by default.
- `create_sign_package_leaf.sh` emits a per-certificate Java keystore output for `server` profile certificates by default:
  - `server-<common-name>.keystore.jks` (private key + certificate chain)
- `sign_intermediate_csr.sh` emits the shared CA truststore once per CA chain:
  - `ca-chain.truststore.jks` (stored in `root_ca/exports/`)
- To retain private keys on disk, set `DELETE_LEAF_PRIVATE_KEY_AFTER_PACKAGING=0` before running the workflow.
- To skip JKS generation, set `CREATE_JKS_OUTPUT=0` before running the workflow.
- To skip truststore generation during intermediate signing, set `CREATE_JKS_TRUSTSTORE=0`.

## Dependency check

Run the dependency checker script to verify required command-line tools and Python packages:

```bash
./scripts/check_dependencies.sh
```

## Test API

```bash
pip install -r api/requirements-dev.txt
pytest api/tests/test_api.py
```
