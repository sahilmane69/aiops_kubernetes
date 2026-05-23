"""FastAPI and Gradio application for AIOps incident analysis."""

from __future__ import annotations

import json
import os
from typing import Any, Dict, Optional

import gradio as gr
import httpx
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from tenacity import retry, retry_if_exception_type, stop_after_attempt, wait_exponential

from rag_pipeline import retrieve


HF_API_TOKEN = os.getenv("HF_API_TOKEN", "")
HF_MODEL_ID = os.getenv("HF_MODEL_ID", "mistralai/Mistral-7B-Instruct-v0.2")
SYSTEM_PROMPT = (
    "You are an AIOps assistant specialising in Kubernetes incident management. "
    "Analyse the alert and pod logs provided. Return a JSON object with these exact fields: "
    "root_cause (string), severity_assessment (critical/high/medium/low), "
    "recommended_action (string), auto_remediation_possible (boolean), "
    "remediation_command (string or null), explanation (string), "
    "estimated_resolution_time (string)."
)


class AnalysisRequest(BaseModel):
    """Incoming alert payload for LLM analysis."""

    alertname: str
    pod: str
    namespace: str
    severity: str
    logs: str
    description: str


class AnalysisResponse(BaseModel):
    """Structured incident response returned by the AI assistant."""

    root_cause: str
    severity_assessment: str
    recommended_action: str
    auto_remediation_possible: bool
    remediation_command: Optional[str] = Field(default=None)
    explanation: str
    estimated_resolution_time: str


app = FastAPI(title="AIOps Kubernetes AI Agent", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@retry(
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=1, max=8),
    retry=retry_if_exception_type((httpx.HTTPError, ValueError)),
    reraise=True,
)
async def call_huggingface_api(payload: AnalysisRequest, retrieved_context: str) -> Dict[str, Any]:
    """Call HuggingFace Inference API with exponential backoff and parse JSON output."""
    if not HF_API_TOKEN:
        raise ValueError("HF_API_TOKEN is not configured.")

    prompt = (
        f"{SYSTEM_PROMPT}\n\n"
        f"Top 3 similar past incidents and runbook context:\n{retrieved_context}\n\n"
        f"Alert details:\n"
        f"- alertname: {payload.alertname}\n"
        f"- pod: {payload.pod}\n"
        f"- namespace: {payload.namespace}\n"
        f"- severity: {payload.severity}\n"
        f"- description: {payload.description}\n\n"
        f"Pod logs:\n{payload.logs}\n\n"
        "Return valid JSON only."
    )

    request_body = {
        "inputs": prompt,
        "parameters": {
            "max_new_tokens": 700,
            "temperature": 0.2,
            "return_full_text": False,
        },
    }
    headers = {
        "Authorization": f"Bearer {HF_API_TOKEN}",
        "Content-Type": "application/json",
    }

    async with httpx.AsyncClient(timeout=60.0) as client:
        response = await client.post(
            f"https://api-inference.huggingface.co/models/{HF_MODEL_ID}",
            json=request_body,
            headers=headers,
        )
        response.raise_for_status()
        data = response.json()

    generated_text = _extract_generated_text(data)
    parsed = _extract_json(generated_text)
    return parsed


def _extract_generated_text(data: Any) -> str:
    """Normalize various HuggingFace response shapes into a single string."""
    if isinstance(data, list) and data:
        first_item = data[0]
        if isinstance(first_item, dict) and "generated_text" in first_item:
            return str(first_item["generated_text"])
    if isinstance(data, dict):
        if "generated_text" in data:
            return str(data["generated_text"])
        if "error" in data:
            raise ValueError(str(data["error"]))
    raise ValueError("Unexpected HuggingFace response format.")


def _extract_json(raw_text: str) -> Dict[str, Any]:
    """Extract the first JSON object from model output and validate required fields."""
    start = raw_text.find("{")
    end = raw_text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError("Model response did not include a valid JSON object.")

    payload = json.loads(raw_text[start : end + 1])
    validated = AnalysisResponse(**payload)
    return validated.model_dump()


@app.get("/health")
async def health() -> JSONResponse:
    """Health endpoint for probes and service monitoring."""
    return JSONResponse({"status": "ok"})


@app.post("/analyse", response_model=AnalysisResponse)
async def analyse(request: AnalysisRequest) -> AnalysisResponse:
    """Analyse an incident with RAG context and HuggingFace LLM output."""
    query = (
        f"{request.alertname} {request.namespace} {request.pod} "
        f"{request.severity} {request.description} {request.logs}"
    )
    context = retrieve(query)

    try:
        result = await call_huggingface_api(request, context)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"HuggingFace inference failed: {exc}") from exc

    return AnalysisResponse(**result)


async def gradio_analyse(
    alertname: str,
    pod: str,
    namespace: str,
    severity: str,
    logs: str,
    description: str,
) -> str:
    """Handle interactive Gradio analysis requests."""
    response = await analyse(
        AnalysisRequest(
            alertname=alertname,
            pod=pod,
            namespace=namespace,
            severity=severity,
            logs=logs,
            description=description,
        )
    )
    return json.dumps(response.model_dump(), indent=2)


with gr.Blocks(title="AIOps Kubernetes Assistant") as gradio_app:
    gr.Markdown("# AIOps Kubernetes Assistant")
    gr.Markdown(
        "Submit alert details and recent logs to receive root cause analysis and remediation guidance."
    )
    with gr.Row():
        alertname_input = gr.Textbox(label="Alert Name", value="PodCrashLoopBackOff")
        pod_input = gr.Textbox(label="Pod", value="api-6f7b57d44f-z4nh5")
        namespace_input = gr.Textbox(label="Namespace", value="production")
    severity_input = gr.Dropdown(
        label="Severity",
        choices=["critical", "warning", "high", "medium", "low"],
        value="critical",
    )
    description_input = gr.Textbox(label="Description", lines=3)
    logs_input = gr.Textbox(label="Pod Logs", lines=12)
    output = gr.Code(label="Analysis JSON", language="json")
    submit = gr.Button("Analyse Incident")
    submit.click(
        fn=gradio_analyse,
        inputs=[
            alertname_input,
            pod_input,
            namespace_input,
            severity_input,
            logs_input,
            description_input,
        ],
        outputs=output,
    )

app = gr.mount_gradio_app(app, gradio_app, path="/")
