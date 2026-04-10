from __future__ import annotations

import os
import shlex
import subprocess
import threading
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from queue import Queue
from typing import Any, Dict, List, Literal, Optional
from zipfile import ZIP_DEFLATED, ZipFile

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, PlainTextResponse
from pydantic import BaseModel, Field

BASE_DIR = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = BASE_DIR / "scripts"
ARTIFACTS_DIR = Path(os.environ.get("PKI_ARTIFACTS_DIR", "/tmp/pki-control-plane-artifacts"))
ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)


class CreateIntermediateRequest(BaseModel):
    intermediate_ca_output_dir: Optional[str] = None
    days: Optional[int] = Field(default=None, ge=1)
    org: Optional[str] = None
    ou: Optional[str] = None
    cn: Optional[str] = None
    intermediate_ca_config_file: Optional[str] = None


class SignIntermediateRequest(BaseModel):
    csr_path: str
    root_ca_output_dir: Optional[str] = None
    root_ca_config_file: Optional[str] = None
    days: Optional[int] = Field(default=None, ge=1)
    org: Optional[str] = None
    ou: Optional[str] = None
    cn: Optional[str] = None


class CreateLeafP12Request(BaseModel):
    profile: Literal["server", "admin", "client"]
    common_name: str = Field(min_length=1)
    p12_password: str = Field(min_length=1)
    intermediate_ca_output_dir: Optional[str] = None
    leaf_output_dir: Optional[str] = None
    leaf_config_file: Optional[str] = None
    days: Optional[int] = Field(default=None, ge=1)
    org: Optional[str] = None
    san_dns: List[str] = Field(default_factory=list)
    san_ips: List[str] = Field(default_factory=list)


class SignLeafCSRRequest(BaseModel):
    csr_path: str
    intermediate_ca_output_dir: Optional[str] = None
    days: Optional[int] = Field(default=None, ge=1)
    intermediate_ca_config_file: Optional[str] = None


class JobResponse(BaseModel):
    id: str
    type: str
    status: str
    created_at: str
    started_at: Optional[str]
    finished_at: Optional[str]
    command: List[str]
    return_code: Optional[int]
    stdout: str
    stderr: str


class LeafBatchItem(BaseModel):
    profile: Literal["server", "admin", "client"]
    common_name: str = Field(min_length=1)
    p12_password: str = Field(min_length=1)
    san_dns: List[str] = Field(default_factory=list)
    san_ips: List[str] = Field(default_factory=list)


class CreateLeafBatchRequest(BaseModel):
    items: List[LeafBatchItem] = Field(min_length=1, max_length=250)
    intermediate_ca_output_dir: Optional[str] = None
    leaf_output_dir: Optional[str] = None
    leaf_config_file: Optional[str] = None
    days: Optional[int] = Field(default=None, ge=1)
    org: Optional[str] = None


class BatchCreateLeafResponse(BaseModel):
    artifact_id: str
    filename: str
    download_url: str
    generated_count: int
    failed_count: int
    failures: List[str]


@dataclass
class Job:
    id: str
    type: str
    command: List[str]
    env: Dict[str, str]
    status: str = "queued"
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    started_at: Optional[str] = None
    finished_at: Optional[str] = None
    return_code: Optional[int] = None
    stdout: str = ""
    stderr: str = ""


class JobManager:
    def __init__(self) -> None:
        self._jobs: Dict[str, Job] = {}
        self._lock = threading.Lock()
        self._queue: Queue[str] = Queue()
        self._thread = threading.Thread(target=self._worker_loop, daemon=True)
        self._thread.start()

    def enqueue(self, job_type: str, command: List[str], env: Dict[str, str]) -> Job:
        job = Job(id=str(uuid.uuid4()), type=job_type, command=command, env=env)
        with self._lock:
            self._jobs[job.id] = job
        self._queue.put(job.id)
        return job

    def get(self, job_id: str) -> Optional[Job]:
        with self._lock:
            return self._jobs.get(job_id)

    def _worker_loop(self) -> None:
        while True:
            job_id = self._queue.get()
            job = self.get(job_id)
            if job is None:
                continue

            job.status = "running"
            job.started_at = datetime.now(timezone.utc).isoformat()
            try:
                completed = subprocess.run(
                    job.command,
                    env=job.env,
                    cwd=BASE_DIR,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                job.return_code = completed.returncode
                job.stdout = completed.stdout
                job.stderr = completed.stderr
                job.status = "succeeded" if completed.returncode == 0 else "failed"
            except Exception as exc:  # defensive catch for worker stability
                job.status = "failed"
                job.stderr = f"Unhandled worker exception: {exc}"
            finally:
                job.finished_at = datetime.now(timezone.utc).isoformat()
                self._queue.task_done()


job_manager = JobManager()
artifact_files: Dict[str, Path] = {}

app = FastAPI(title="PKI Control Plane API", version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def _script_path(script_name: str) -> str:
    path = SCRIPTS_DIR / script_name
    if not path.exists():
        raise HTTPException(status_code=500, detail=f"Script not found: {script_name}")
    return str(path)


def _base_env() -> Dict[str, str]:
    env = os.environ.copy()
    env.setdefault("PATH", os.environ.get("PATH", ""))
    return env


def _job_response(job: Job) -> JobResponse:
    return JobResponse(
        id=job.id,
        type=job.type,
        status=job.status,
        created_at=job.created_at,
        started_at=job.started_at,
        finished_at=job.finished_at,
        command=job.command,
        return_code=job.return_code,
        stdout=job.stdout,
        stderr=job.stderr,
    )


def _sanitize_filename(value: str) -> str:
    keep = [c if c.isalnum() or c in ("-", "_", ".") else "-" for c in value.strip()]
    sanitized = "".join(keep).strip("-._")
    return sanitized or "artifact"


def _validate_server_sans(profile: str, san_dns: List[str], san_ips: List[str]) -> None:
    if profile == "server" and not san_dns and not san_ips:
        raise HTTPException(
            status_code=400,
            detail="Server profile requires at least one SAN entry in san_dns or san_ips.",
        )


@app.get("/health")
def health() -> Dict[str, str]:
    return {"status": "ok"}


@app.get("/templates/leaf-batch.csv", response_class=PlainTextResponse)
def leaf_batch_template() -> str:
    # SAN columns use semicolon-delimited values inside the CSV cell.
    return (
        "profile,common_name,p12_password,san_dns,san_ips\n"
        ",,,,\n"
        ",,,,\n"
        ",,,,\n"
        ",,,,\n"
        ",,,,\n"
    )


@app.post("/jobs/create-intermediate-ca", response_model=JobResponse)
def create_intermediate_ca(req: CreateIntermediateRequest) -> JobResponse:
    env = _base_env()
    if req.intermediate_ca_output_dir:
        env["INTERMEDIATE_CA_OUTPUT_DIR"] = req.intermediate_ca_output_dir
    if req.days:
        env["DAYS"] = str(req.days)
    if req.org:
        env["ORG"] = req.org
    if req.ou:
        env["OU"] = req.ou
    if req.cn:
        env["CN"] = req.cn
    if req.intermediate_ca_config_file:
        env["INTERMEDIATE_CA_CONFIG_FILE"] = req.intermediate_ca_config_file

    job = job_manager.enqueue(
        "create-intermediate-ca",
        ["bash", _script_path("create_intermediate_ca.sh")],
        env,
    )
    return _job_response(job)


@app.post("/jobs/sign-intermediate-csr", response_model=JobResponse)
def sign_intermediate_csr(req: SignIntermediateRequest) -> JobResponse:
    env = _base_env()
    if req.root_ca_output_dir:
        env["ROOT_CA_OUTPUT_DIR"] = req.root_ca_output_dir
    if req.root_ca_config_file:
        env["ROOT_CA_CONFIG_FILE"] = req.root_ca_config_file
    if req.days:
        env["DAYS"] = str(req.days)
    if req.org:
        env["ORG"] = req.org
    if req.ou:
        env["OU"] = req.ou
    if req.cn:
        env["CN"] = req.cn

    job = job_manager.enqueue(
        "sign-intermediate-csr",
        ["bash", _script_path("sign_intermediate_csr.sh"), req.csr_path],
        env,
    )
    return _job_response(job)


@app.post("/jobs/create-leaf-p12", response_model=JobResponse)
def create_leaf_p12(req: CreateLeafP12Request) -> JobResponse:
    _validate_server_sans(req.profile, req.san_dns, req.san_ips)

    env = _base_env()
    if req.intermediate_ca_output_dir:
        env["INTERMEDIATE_CA_OUTPUT_DIR"] = req.intermediate_ca_output_dir
    if req.leaf_output_dir:
        env["LEAF_OUTPUT_DIR"] = req.leaf_output_dir
    if req.leaf_config_file:
        env["LEAF_CONFIG_FILE"] = req.leaf_config_file
    if req.days:
        env["DAYS"] = str(req.days)
    if req.org:
        env["ORG"] = req.org
    if req.san_dns:
        env["SAN_DNS_LIST"] = ",".join(req.san_dns)
    if req.san_ips:
        env["SAN_IP_LIST"] = ",".join(req.san_ips)

    job = job_manager.enqueue(
        "create-leaf-p12",
        [
            "bash",
            _script_path("create_sign_package_leaf.sh"),
            req.profile,
            req.common_name,
            req.p12_password,
        ],
        env,
    )
    return _job_response(job)


@app.post("/batch/create-leaf-p12", response_model=BatchCreateLeafResponse)
def batch_create_leaf_p12(req: CreateLeafBatchRequest) -> BatchCreateLeafResponse:
    env_base = _base_env()
    if req.intermediate_ca_output_dir:
        env_base["INTERMEDIATE_CA_OUTPUT_DIR"] = req.intermediate_ca_output_dir
    if req.leaf_output_dir:
        env_base["LEAF_OUTPUT_DIR"] = req.leaf_output_dir
    if req.leaf_config_file:
        env_base["LEAF_CONFIG_FILE"] = req.leaf_config_file
    if req.days:
        env_base["DAYS"] = str(req.days)
    if req.org:
        env_base["ORG"] = req.org

    intermediate_dir = env_base.get("INTERMEDIATE_CA_OUTPUT_DIR", "/opt/pki/intermediate-ca")
    leaf_base_dir = env_base.get("LEAF_OUTPUT_DIR", f"{intermediate_dir}/leaf")
    failures: List[str] = []
    generated: List[tuple[LeafBatchItem, Path]] = []

    for item in req.items:
        _validate_server_sans(item.profile, item.san_dns, item.san_ips)
        env = env_base.copy()
        if item.san_dns:
            env["SAN_DNS_LIST"] = ",".join(item.san_dns)
        if item.san_ips:
            env["SAN_IP_LIST"] = ",".join(item.san_ips)

        command = [
            "bash",
            _script_path("create_sign_package_leaf.sh"),
            item.profile,
            item.common_name,
            item.p12_password,
        ]
        completed = subprocess.run(
            command,
            env=env,
            cwd=BASE_DIR,
            capture_output=True,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            message = completed.stderr.strip() or completed.stdout.strip() or "unknown script error"
            failures.append(f"{item.common_name} ({item.profile}): {message}")
            continue

        expected_p12 = Path(leaf_base_dir) / item.profile / "export" / f"{item.common_name}.p12"
        if not expected_p12.exists():
            failures.append(
                f"{item.common_name} ({item.profile}): expected output not found: {expected_p12}"
            )
            continue
        generated.append((item, expected_p12))

    if not generated:
        raise HTTPException(
            status_code=400,
            detail={
                "message": "No certificate packages were generated.",
                "failures": failures,
            },
        )

    artifact_id = str(uuid.uuid4())
    zip_filename = f"leaf-packages-{artifact_id}.zip"
    zip_path = ARTIFACTS_DIR / zip_filename

    with ZipFile(zip_path, mode="w", compression=ZIP_DEFLATED) as archive:
        for item, p12_path in generated:
            arcname = f"{_sanitize_filename(item.profile)}/{_sanitize_filename(p12_path.name)}"
            archive.write(p12_path, arcname=arcname)

        manifest_lines = ["profile,common_name,p12_filename"]
        for item, p12_path in generated:
            manifest_lines.append(f"{item.profile},{item.common_name},{p12_path.name}")
        archive.writestr("manifest.csv", "\n".join(manifest_lines) + "\n")

    artifact_files[artifact_id] = zip_path
    return BatchCreateLeafResponse(
        artifact_id=artifact_id,
        filename=zip_filename,
        download_url=f"/downloads/{artifact_id}",
        generated_count=len(generated),
        failed_count=len(failures),
        failures=failures,
    )


@app.get("/downloads/{artifact_id}")
def download_artifact(artifact_id: str) -> FileResponse:
    path = artifact_files.get(artifact_id)
    if path is None or not path.exists():
        raise HTTPException(status_code=404, detail="Artifact not found")
    return FileResponse(path, media_type="application/zip", filename=path.name)


@app.post("/jobs/sign-leaf-csr", response_model=JobResponse)
def sign_leaf_csr(req: SignLeafCSRRequest) -> JobResponse:
    env = _base_env()
    if req.intermediate_ca_output_dir:
        env["INTERMEDIATE_CA_OUTPUT_DIR"] = req.intermediate_ca_output_dir
    if req.days:
        env["DAYS"] = str(req.days)
    if req.intermediate_ca_config_file:
        env["INTERMEDIATE_CA_CONFIG_FILE"] = req.intermediate_ca_config_file

    job = job_manager.enqueue(
        "sign-leaf-csr",
        ["bash", _script_path("sign_leaf_csr.sh"), req.csr_path],
        env,
    )
    return _job_response(job)


@app.get("/jobs/{job_id}", response_model=JobResponse)
def get_job(job_id: str) -> JobResponse:
    job = job_manager.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Job not found")
    return _job_response(job)


@app.get("/jobs/{job_id}/command")
def get_job_command(job_id: str) -> Dict[str, Any]:
    job = job_manager.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Job not found")
    return {
        "id": job.id,
        "command": " ".join(shlex.quote(part) for part in job.command),
    }
