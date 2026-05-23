#!/bin/bash
set -e

echo "Starting Minikube..."
minikube start --cpus=4 --memory=6144 --kubernetes-version=v1.35.1
minikube addons enable metrics-server
minikube addons enable ingress

echo "Setting up namespaces..."
kubectl apply -f k8s/namespace.yaml
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace n8n --dry-run=client -o yaml | kubectl apply -f -

echo "Creating secrets..."
# Providing default dummy values for secrets to allow the stack to start successfully
kubectl create secret generic aiops-platform-secrets -n aiops \
  --from-literal=HF_API_TOKEN="dummy_token" \
  --from-literal=HF_MODEL_ID="mistralai/Mistral-7B-Instruct-v0.2" \
  --from-literal=N8N_WEBHOOK_SECRET="dummy_secret" \
  --from-literal=PROMETHEUS_URL="http://prometheus-operated:9090" \
  --from-literal=GRAFANA_URL="http://monitoring-grafana:80" \
  --from-literal=SLACK_BOT_TOKEN="dummy_slack" \
  --from-literal=SLACK_CHANNEL_ID="dummy_channel" \
  --from-literal=JIRA_API_TOKEN="dummy_jira" \
  --from-literal=JIRA_BASE_URL="https://dummy.atlassian.net" \
  --from-literal=JIRA_PROJECT_KEY="INC" --dry-run=client -o yaml | kubectl apply -f -

echo "Installing Prometheus stack..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f monitoring/prometheus/values.yaml

echo "Applying Alertmanager Config..."
kubectl apply -f monitoring/prometheus/alert-rules.yaml
kubectl create secret generic aiops-alertmanager-config -n monitoring \
  --from-file=alertmanager.yaml=monitoring/alertmanager/alertmanager.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Installing n8n..."
helm repo add 8gears https://8gears.container-registry.com/chartrepo/library
helm repo update
helm upgrade --install n8n 8gears/n8n \
  --namespace n8n \
  -f n8n/helm-values.yaml

echo "Building and deploying AI agent to Minikube..."
# Point your terminal to use the docker daemon inside minikube
eval $(minikube docker-env)

# Build the image directly inside the minikube docker daemon
docker build -t local/aiops-agent:latest ai-agent

# Apply the manifests for the AI Agent
# We need to update deployment to use the local image and not pull from a registry
sed -i.bak 's/image: .*/image: local\/aiops-agent:latest\n        imagePullPolicy: Never/g' k8s/deployment.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/hpa.yaml

echo ""
echo "======================================================"
echo "Deployment initiated!"
echo "To view the AI Agent dashboard, run:"
echo "  minikube service aiops-ai-agent -n aiops"
echo ""
echo "To view the Grafana dashboard, run:"
echo "  kubectl port-forward svc/kube-prometheus-stack-grafana 8080:80 -n monitoring"
echo "  (Then open http://localhost:8080 in your browser - default login is usually admin/prom-operator)"
echo "======================================================"
