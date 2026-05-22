# AIOps Kubernetes Automation Platform

Production-ready AIOps platform for Kubernetes that combines Prometheus, Alertmanager, Grafana, n8n, a HuggingFace-powered AI incident analyst, FAISS-backed runbook retrieval, Gradio for engineer self-service, Jenkins for deployment automation, and GitHub Actions for validation and promotion workflows.

## Architecture

```text
                               +----------------------+
                               |  GitHub Actions      |
                               |  lint/test/build     |
                               +----------+-----------+
                                          |
                                          v
                               +----------------------+
                               | Jenkins              |
                               | docker + deploy      |
                               +----------+-----------+
                                          |
                                          v
+-------------------+         +-----------+------------+         +--------------------+
| Kubernetes Apps   |         | Prometheus +           |         | Grafana            |
| sample app,       +---------> Alertmanager           +---------> dashboards         |
| ai-agent, n8n     | metrics  | alert rules, routing  | alerts  | visualisation      |
+---------+---------+         +-----------+------------+         +--------------------+
          |                                 |
          |                                 v
          |                     +-----------+------------+
          |                     | n8n orchestration      |
          |                     | triage, scaling,       |
          |                     | rollback, ticketing    |
          |                     +-----------+------------+
          |                                 |
          |                                 v
          |                     +-----------+------------+
          +---------------------> AI Agent               |
 logs, alert context             | FastAPI + Gradio      |
                                 | HF Mistral + FAISS    |
                                 +-----------+-----------+
                                             |
                                             v
                                 +-----------+-----------+
                                 | Remediation +         |
                                 | Slack + Jira          |
                                 +-----------------------+
```

## Repository Layout

```text
aiops-kubernetes/
├── ci-cd/
│   ├── Jenkinsfile
│   └── .github/workflows/build-deploy.yml
├── k8s/
│   ├── namespace.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── hpa.yaml
├── monitoring/
│   ├── prometheus/
│   │   ├── values.yaml
│   │   └── alert-rules.yaml
│   ├── alertmanager/
│   │   └── alertmanager.yaml
│   └── grafana/
│       └── dashboards/aiops-dashboard.json
├── n8n/
│   ├── helm-values.yaml
│   └── workflows/
│       ├── alert-triage.json
│       ├── crash-loop.json
│       ├── cpu-scale.json
│       └── incident-ticket.json
├── ai-agent/
│   ├── app.py
│   ├── rag_pipeline.py
│   ├── ingest_runbooks.py
│   ├── requirements.txt
│   └── Dockerfile
├── remediation/
│   └── scripts/
│       ├── restart_pod.sh
│       ├── rollback_helm.sh
│       └── scale_deployment.sh
└── README.md
```

## Prerequisites

- Docker
- kubectl
- Helm 3
- minikube for local development
- Python 3.11+
- Access to a Kubernetes cluster
- A container registry referenced by `DOCKER_REGISTRY`
- Slack bot credentials and Jira API credentials
- HuggingFace Inference API access
- Jenkins instance reachable from GitHub Actions

## Environment Variables

| Variable | Required | Default | Purpose |
| --- | --- | --- | --- |
| `HF_API_TOKEN` | Yes | None | HuggingFace Inference API token |
| `HF_MODEL_ID` | Yes | `mistralai/Mistral-7B-Instruct-v0.2` | Model used by the AI agent |
| `N8N_WEBHOOK_SECRET` | Yes | None | Bearer token used by Alertmanager when posting to n8n |
| `PROMETHEUS_URL` | Yes | `http://prometheus-operated:9090` | Internal Prometheus API endpoint |
| `GRAFANA_URL` | Yes | `http://monitoring-grafana:80` | Internal or external Grafana base URL |
| `SLACK_BOT_TOKEN` | Yes | None | Slack OAuth token for notifications |
| `SLACK_CHANNEL_ID` | Yes | None | Target Slack channel for alerts |
| `JIRA_API_TOKEN` | Yes | None | Jira API token |
| `JIRA_BASE_URL` | Yes | None | Jira instance base URL |
| `JIRA_PROJECT_KEY` | Yes | None | Jira incident project key |
| `DOCKER_REGISTRY` | Yes | None | Docker registry used by CI/CD |
| `KUBECONFIG` | Yes | None | Path to kubeconfig used by scripts and Jenkins |
| `FAISS_INDEX_PATH` | Yes | `/data/faiss-index` | Persistent FAISS index path |
| `RUNBOOKS_PATH` | Yes | `/data/runbooks` | Markdown runbook directory |

## Local Setup With Minikube

1. Start minikube and enable useful addons.

```bash
minikube start --cpus=4 --memory=8192 --kubernetes-version=v1.30.0
minikube addons enable metrics-server
minikube addons enable ingress
```

2. Create namespaces and secrets for platform dependencies.

```bash
kubectl apply -f k8s/namespace.yaml

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace n8n --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic aiops-platform-secrets -n aiops \
  --from-literal=HF_API_TOKEN="$HF_API_TOKEN" \
  --from-literal=HF_MODEL_ID="${HF_MODEL_ID:-mistralai/Mistral-7B-Instruct-v0.2}" \
  --from-literal=N8N_WEBHOOK_SECRET="$N8N_WEBHOOK_SECRET" \
  --from-literal=PROMETHEUS_URL="${PROMETHEUS_URL:-http://prometheus-operated:9090}" \
  --from-literal=GRAFANA_URL="${GRAFANA_URL:-http://monitoring-grafana:80}" \
  --from-literal=SLACK_BOT_TOKEN="$SLACK_BOT_TOKEN" \
  --from-literal=SLACK_CHANNEL_ID="$SLACK_CHANNEL_ID" \
  --from-literal=JIRA_API_TOKEN="$JIRA_API_TOKEN" \
  --from-literal=JIRA_BASE_URL="$JIRA_BASE_URL" \
  --from-literal=JIRA_PROJECT_KEY="$JIRA_PROJECT_KEY"
```

3. Install kube-prometheus-stack and apply the platform alerting assets.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f monitoring/prometheus/values.yaml

kubectl apply -f monitoring/prometheus/alert-rules.yaml
kubectl create secret generic aiops-alertmanager-config -n monitoring \
  --from-file=alertmanager.yaml=monitoring/alertmanager/alertmanager.yaml \
  --dry-run=client -o yaml | kubectl apply -f -
```

4. Install n8n via Helm and import the workflows from `n8n/workflows/`.

```bash
helm repo add 8gears https://8gears.container-registry.com/chartrepo/library
helm repo update

helm upgrade --install n8n 8gears/n8n \
  --namespace n8n \
  -f n8n/helm-values.yaml
```

5. Build and deploy the AI agent.

```bash
docker build -t "${DOCKER_REGISTRY}/aiops-agent:local" ai-agent
docker push "${DOCKER_REGISTRY}/aiops-agent:local"
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/hpa.yaml
```

6. Seed the FAISS index by mounting runbooks under `RUNBOOKS_PATH` and running ingestion.

```bash
cd ai-agent
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
python ingest_runbooks.py
```

7. Import dashboards and n8n workflows.

- Grafana: import [`monitoring/grafana/dashboards/aiops-dashboard.json`](/Users/sahilmane/Documents/GitHub/aiops_kubernetes/monitoring/grafana/dashboards/aiops-dashboard.json)
- n8n: import all JSON files under [`n8n/workflows`](/Users/sahilmane/Documents/GitHub/aiops_kubernetes/n8n/workflows)

## Production Setup On EKS

1. Create an EKS cluster and attach managed node groups with IAM permissions for ECR, CloudWatch, and Kubernetes administration.
2. Authenticate `kubectl` to the cluster and create the `aiops`, `monitoring`, and `n8n` namespaces.
3. Create `aiops-platform-secrets` in the `aiops` namespace and mirror any required secrets in `n8n` if you use separate credentials.
4. Install kube-prometheus-stack using [`monitoring/prometheus/values.yaml`](/Users/sahilmane/Documents/GitHub/aiops_kubernetes/monitoring/prometheus/values.yaml), then apply [`monitoring/prometheus/alert-rules.yaml`](/Users/sahilmane/Documents/GitHub/aiops_kubernetes/monitoring/prometheus/alert-rules.yaml).
5. Install n8n using [`n8n/helm-values.yaml`](/Users/sahilmane/Documents/GitHub/aiops_kubernetes/n8n/helm-values.yaml).
6. Build and push the AI agent image to your production registry.
7. Apply the manifests in `k8s/` after substituting `DOCKER_REGISTRY` with your registry.
8. Configure an ingress or service mesh route for Grafana, n8n, and the AI agent if engineers need external access.
9. Point GitHub Actions at your Jenkins instance and ensure Jenkins has cluster credentials for `helm`, `kubectl`, and registry access.

## How The Full Pipeline Works

1. Prometheus evaluates the rules in [`monitoring/prometheus/alert-rules.yaml`](/Users/sahilmane/Documents/GitHub/aiops_kubernetes/monitoring/prometheus/alert-rules.yaml).
2. Alertmanager groups and forwards alerts to n8n at the cluster-internal webhook.
3. n8n workflows fetch logs, call the AI agent, and choose notification or remediation actions.
4. The AI agent retrieves similar runbook context from FAISS, calls HuggingFace Mistral, and returns structured JSON.
5. n8n posts Slack updates, creates Jira incidents, or runs remediation commands.
6. Grafana shows live alerting, traffic, and remediation views.

## Test The End-To-End Flow

Use this sample request to exercise the AI service directly:

```bash
curl -X POST http://localhost:8000/analyse \
  -H "Content-Type: application/json" \
  -d '{
    "alertname": "PodCrashLoopBackOff",
    "pod": "payments-api-7f654d4f5b-x8kzs",
    "namespace": "aiops",
    "severity": "critical",
    "logs": "Error: database connection timeout\\nRetrying startup\\nProcess exiting with code 1",
    "description": "Container restarts exceeded 5 in the last 10 minutes."
  }'
```

To simulate the Alertmanager to n8n handoff:

```bash
curl -X POST http://localhost:5678/webhook/aiops-alerts \
  -H "Authorization: Bearer ${N8N_WEBHOOK_SECRET}" \
  -H "Content-Type: application/json" \
  -d '{
    "alerts": [
      {
        "labels": {
          "alertname": "HighCPUUsage",
          "pod": "aiops-sample-app-84f79b6dd7-q6h7x",
          "namespace": "aiops",
          "severity": "warning",
          "deployment": "aiops-sample-app"
        },
        "annotations": {
          "description": "CPU usage is above 80% for 5 minutes."
        }
      }
    ]
  }'
```

## Adding New Alert Rules

1. Add a new rule to [`monitoring/prometheus/alert-rules.yaml`](/Users/sahilmane/Documents/GitHub/aiops_kubernetes/monitoring/prometheus/alert-rules.yaml).
2. Keep the `severity`, `summary`, and `description` annotations consistent so n8n receives predictable fields.
3. Apply the updated rule set.

```bash
kubectl apply -f monitoring/prometheus/alert-rules.yaml
```

## Adding New n8n Workflows

1. Create a new workflow in the n8n UI using the existing workflow JSON files as templates.
2. Export the workflow JSON into [`n8n/workflows`](/Users/sahilmane/Documents/GitHub/aiops_kubernetes/n8n/workflows).
3. Re-import it into the target n8n environment and ensure all credentials are mapped.
4. If the workflow introduces a new endpoint or secret, add it to the Kubernetes secret and update Helm values if needed.

## CI/CD

- GitHub Actions workflow: [`ci-cd/.github/workflows/build-deploy.yml`](/Users/sahilmane/Documents/GitHub/aiops_kubernetes/ci-cd/.github/workflows/build-deploy.yml)
- Jenkins pipeline: [`ci-cd/Jenkinsfile`](/Users/sahilmane/Documents/GitHub/aiops_kubernetes/ci-cd/Jenkinsfile)

The GitHub workflow lints, tests, and builds on `push` and `pull_request` to `main`. On a direct merge to `main`, it triggers Jenkins by API. Jenkins builds the AI agent image, pushes it to `DOCKER_REGISTRY`, deploys the updated workload, and verifies rollout health.

## Troubleshooting

1. Alerts are not reaching n8n.
   Check the Alertmanager secret, verify the webhook URL resolves inside the cluster, and confirm `N8N_WEBHOOK_SECRET` matches the token expected by n8n.

2. The AI agent returns `502` or HuggingFace errors.
   Verify `HF_API_TOKEN`, confirm the model ID is valid, and inspect the AI agent pod logs for timeout or response-format errors.

3. FAISS retrieval returns no context.
   Confirm markdown runbooks exist under `RUNBOOKS_PATH`, rerun `python ingest_runbooks.py`, and ensure the index volume persists at `FAISS_INDEX_PATH`.

4. Remediation workflows fail to restart, scale, or roll back workloads.
   Ensure the service account or execution layer used by n8n has RBAC permissions for `pods`, `deployments`, and Helm-related operations.

5. Grafana panels are empty.
   Verify Prometheus scrape annotations are present, confirm the app exports the metrics used by the dashboard queries, and check that the dashboard is connected to the correct Prometheus datasource UID.
