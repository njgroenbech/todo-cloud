#!/bin/bash
# Deploys the Azure infrastructure and application using GitHub Actions.
# Run from anywhere:  bash infra/deploy.sh
# Requires: az, kubectl, gh, git, curl, Node.js, and authenticated Azure and GitHub CLI sessions.
# Works on macOS, Linux, Windows (Git Bash / WSL) and Azure Cloud Shell.
#
# Optional overrides (environment variables), e.g.  LOCATION=northeurope bash infra/deploy.sh
#   RG=todo-rg  LOCATION=norwayeast  COSMOS_LOCATION=uksouth  AKS_VM_SIZE=Standard_B2s
#   FUNCTIONS_LOCATION=norwayeast (must support Flex Consumption)
#   AKS_NODE_COUNT=2  ATTACH_ACR=true
#   COSMOS_SERVERLESS=true|false (default: auto)  GITHUB_REPO=owner/repo (default: current repo)
#   FRONTEND_ORIGIN=https://example.com (exact browser origin, no path or trailing slash)

set -euo pipefail
cd "$(dirname "$0")/.."

RG="${RG:-todo-rg}"
LOCATION="${LOCATION:-norwayeast}"
COSMOS_LOCATION="${COSMOS_LOCATION:-norwayeast}"
FUNCTIONS_LOCATION="${FUNCTIONS_LOCATION:-$LOCATION}"
AKS_VM_SIZE="${AKS_VM_SIZE:-Standard_B2s}"
AKS_NODE_COUNT="${AKS_NODE_COUNT:-2}"
ATTACH_ACR="${ATTACH_ACR:-true}"
FRONTEND_ORIGIN="${FRONTEND_ORIGIN:-}"
DB_NAME="todosDB"
DEPLOYMENT="todo-infra"

for tool in az kubectl gh git curl node; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool"; exit 1; }
done
az account show >/dev/null 2>&1 || { echo "Not logged in. Run: az login"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged in to GitHub. Run: gh auth login"; exit 1; }
REPO="${GITHUB_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
if [[ ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid GitHub repository: $REPO"
  exit 1
fi

LOCAL_COMMIT=$(git rev-parse HEAD)
REMOTE_COMMIT=$(gh api "repos/$REPO/git/ref/heads/main" --jq '.object.sha')
if [ "$LOCAL_COMMIT" != "$REMOTE_COMMIT" ]; then
  echo "The local commit must match $REPO main. Commit and push your changes before deploying."
  exit 1
fi
CONFIG_CHANGES=$(git status --porcelain --untracked-files=normal -- \
  infra kubernetes-aks .github/workflows todo-api todo-app todo-functions)
if [ -n "$CONFIG_CHANGES" ]; then
  echo "Commit and push application, infrastructure, manifest, and workflow changes before deploying."
  exit 1
fi

echo "Subscription: $(az account show --query name -o tsv)"

echo "Registering resource providers..."
for provider in Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.DocumentDB Microsoft.Storage Microsoft.Web Microsoft.ManagedIdentity; do
  az provider register --namespace "$provider" --wait
done

GROUP_EXISTS=$(az group exists -n "$RG" -o tsv)
if [ "$GROUP_EXISTS" = "true" ]; then
  echo "Using existing resource group $RG."
else
  echo "Creating resource group $RG in $LOCATION..."
  az group create -n "$RG" -l "$LOCATION" -o none
fi

# Preserve the currently allowed origin while the infrastructure is redeployed.
EXISTING_ORIGIN=""
if [ "$GROUP_EXISTS" = "true" ]; then
  EXISTING_FUNCTION=$(az deployment group list -g "$RG" \
    --query "[?name=='$DEPLOYMENT'].properties.outputs.functionsName.value | [0]" -o tsv)
  if [ -n "$EXISTING_FUNCTION" ]; then
    EXISTING_ORIGIN=$(az functionapp cors show -g "$RG" -n "$EXISTING_FUNCTION" \
      --query 'allowedOrigins[0]' -o tsv)
  fi
fi
INITIAL_ORIGIN="${FRONTEND_ORIGIN:-$EXISTING_ORIGIN}"

# Cosmos DB free tier is allowed once per subscription: use serverless if it is taken elsewhere
EXISTING_COSMOS=$(az cosmosdb list -g "$RG" --query '[0].name' -o tsv)
if [ -n "$EXISTING_COSMOS" ]; then
  COSMOS_FREE=$(az cosmosdb show -g "$RG" -n "$EXISTING_COSMOS" --query enableFreeTier -o tsv)
  COSMOS_SERVERLESS=$(az cosmosdb show -g "$RG" -n "$EXISTING_COSMOS" --query "contains(capabilities[].name, 'EnableServerless')" -o tsv)
else
  COSMOS_FREE=true
  if [ -z "${COSMOS_SERVERLESS:-}" ]; then
    FREE_ELSEWHERE=$(az cosmosdb list --query "[?enableFreeTier==\`true\` && resourceGroup!='$RG'].name" -o tsv)
    if [ -n "$FREE_ELSEWHERE" ]; then COSMOS_SERVERLESS=true; else COSMOS_SERVERLESS=false; fi
  fi
fi
COSMOS_FREE=$(echo "$COSMOS_FREE" | tr '[:upper:]' '[:lower:]')
COSMOS_SERVERLESS=$(echo "$COSMOS_SERVERLESS" | tr '[:upper:]' '[:lower:]')
echo "Locations: AKS/ACR=$LOCATION Cosmos DB=$COSMOS_LOCATION Functions=$FUNCTIONS_LOCATION"
echo "AKS: nodeCount=$AKS_NODE_COUNT vmSize=$AKS_VM_SIZE"
echo "Cosmos DB: freeTier=$COSMOS_FREE serverless=$COSMOS_SERVERLESS"
echo "Deploying Bicep template (this takes about 5-10 minutes)..."
if ! az deployment group create -g "$RG" -n "$DEPLOYMENT" -f infra/main.bicep \
  -p location="$LOCATION" cosmosLocation="$COSMOS_LOCATION" functionsLocation="$FUNCTIONS_LOCATION" aksVmSize="$AKS_VM_SIZE" \
     aksNodeCount="$AKS_NODE_COUNT" attachAcr="$ATTACH_ACR" \
     cosmosFreeTier="$COSMOS_FREE" cosmosServerless="$COSMOS_SERVERLESS" \
     frontendOrigin="$INITIAL_ORIGIN" githubRepo="$REPO" -o none; then
  echo
  echo "Deployment failed. Common fixes:"
  echo "  - AKS-to-ACR role denied:       ATTACH_ACR=false bash infra/deploy.sh"
  echo "  - Function role denied:         ask an administrator for role-assignment permission"
  echo "  - Region blocked/unavailable:   set LOCATION or COSMOS_LOCATION to an available, allowed region"
  echo "  - VM size not available:        AKS_VM_SIZE=Standard_B2ms bash infra/deploy.sh"
  echo "  - Free tier already used:       COSMOS_SERVERLESS=true bash infra/deploy.sh"
  exit 1
fi

output() { az deployment group show -g "$RG" -n "$DEPLOYMENT" --query "properties.outputs.$1.value" -o tsv; }
ACR_NAME=$(output acrName)
ACR_LOGIN=$(output acrLoginServer)
AKS_NAME=$(output aksName)
COSMOS_NAME=$(output cosmosName)
FUNCTIONS_NAME=$(output functionsName)
STATISTICS_URL=$(output statisticsUrl)
GITHUB_CLIENT_ID=$(output githubClientId)
AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)

ACR_USER=$(az acr credential show -n "$ACR_NAME" --query username -o tsv)
ACR_PASS=$(az acr credential show -n "$ACR_NAME" --query 'passwords[0].value' -o tsv)

# Cosmos connection string with the database name added
MONGO_URI=$(az cosmosdb keys list -g "$RG" -n "$COSMOS_NAME" --type connection-strings \
  --query 'connectionStrings[0].connectionString' -o tsv | sed "s#:10255/?#:10255/${DB_NAME}?#")

# Admin kubeconfig in a temp file so the secrets below go to the new cluster
KUBECONFIG_FILE=$(mktemp)
trap 'rm -f "$KUBECONFIG_FILE"' EXIT
HEADERS_FILE=$(mktemp)
trap 'rm -f "$KUBECONFIG_FILE" "$HEADERS_FILE"' EXIT
az aks get-credentials -g "$RG" -n "$AKS_NAME" --admin --file "$KUBECONFIG_FILE" --overwrite-existing >/dev/null
export KUBECONFIG="$KUBECONFIG_FILE"

echo "Creating Kubernetes secrets..."
kubectl create secret generic mongo-secret --from-literal=MONGO_URI="$MONGO_URI" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if [ "$ATTACH_ACR" != "true" ]; then
  kubectl create secret docker-registry acr-secret --docker-server="$ACR_LOGIN" \
    --docker-username="$ACR_USER" --docker-password="$ACR_PASS" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl patch serviceaccount default -p '{"imagePullSecrets":[{"name":"acr-secret"}]}' >/dev/null
fi

apply_deployment() {
  local service="$1" image
  image=$(kubectl get deployment "$service" --ignore-not-found \
    -o 'jsonpath={.spec.template.spec.containers[0].image}')
  if [ -z "$image" ]; then
    image="${ACR_LOGIN}/${service}:latest"
  fi
  sed "s#YOUR_ACR\.azurecr\.io/${service}:latest#${image}#g" \
    "kubernetes-aks/${service}-deployment.yaml" | kubectl apply -f -
  kubectl apply -f "kubernetes-aks/${service}-service.yaml"
}

wait_for_address() {
  local service="$1" address elapsed=0
  echo "Waiting for $service public address..." >&2
  while [ "$elapsed" -lt 600 ]; do
    address=$(kubectl get service "$service" \
      -o 'jsonpath={.status.loadBalancer.ingress[0].ip}')
    if [ -z "$address" ]; then
      address=$(kubectl get service "$service" \
        -o 'jsonpath={.status.loadBalancer.ingress[0].hostname}')
    fi
    if [ -n "$address" ]; then
      if [[ "$address" == *:* ]]; then address="[$address]"; fi
      printf '%s\n' "$address"
      return
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  echo "Timed out waiting for $service public address." >&2
  return 1
}

echo "Applying Kubernetes deployments and services..."
apply_deployment todo-api
apply_deployment todo-app
API_ADDRESS=$(wait_for_address todo-api)
APP_ADDRESS=$(wait_for_address todo-app)
API_URL="http://${API_ADDRESS}:5000"
APP_URL="http://${APP_ADDRESS}:3000"
ALLOWED_ORIGIN="${FRONTEND_ORIGIN:-$APP_URL}"

if [ "$ALLOWED_ORIGIN" != "$INITIAL_ORIGIN" ]; then
  az functionapp cors add -g "$RG" -n "$FUNCTIONS_NAME" --allowed-origins "$ALLOWED_ORIGIN" -o none
  if [ -n "$INITIAL_ORIGIN" ]; then
    az functionapp cors remove -g "$RG" -n "$FUNCTIONS_NAME" --allowed-origins "$INITIAL_ORIGIN" -o none
  fi
fi

echo "Setting GitHub secrets and variables in $REPO..."
printf '%s' "$ACR_USER" | gh secret set ACR_USERNAME --repo "$REPO"
printf '%s' "$ACR_PASS" | gh secret set ACR_PASSWORD --repo "$REPO"
gh secret set KUBE_CONFIG --repo "$REPO" < "$KUBECONFIG_FILE"
gh variable set ACR_LOGIN_SERVER --repo "$REPO" --body "$ACR_LOGIN"
gh variable set AZURE_FUNCTIONAPP_NAME --repo "$REPO" --body "$FUNCTIONS_NAME"
gh variable set AZURE_CLIENT_ID --repo "$REPO" --body "$GITHUB_CLIENT_ID"
gh variable set AZURE_TENANT_ID --repo "$REPO" --body "$AZURE_TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --repo "$REPO" --body "$AZURE_SUBSCRIPTION_ID"
gh variable set VITE_API_URL --repo "$REPO" --body "$API_URL"
gh variable set VITE_STATISTICS_URL --repo "$REPO" --body "$STATISTICS_URL"

run_workflow() {
  local workflow="$1" run_id state elapsed=0
  echo "Starting $workflow..."
  run_id=$(gh api --method POST -H 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/$REPO/actions/workflows/$workflow/dispatches" -f ref=main --jq '.workflow_run_id')
  if [[ ! "$run_id" =~ ^[0-9]+$ ]]; then
    echo "GitHub did not return a workflow run ID for $workflow." >&2
    return 1
  fi
  echo "Waiting for $workflow run $run_id..."
  while [ "$elapsed" -lt 1800 ]; do
    state=$(gh run view "$run_id" --repo "$REPO" --json status,conclusion \
      --jq '.status + ":" + (.conclusion // "")')
    case "$state" in
      completed:success) return 0 ;;
      completed:*) echo "$workflow run $run_id failed: $state" >&2; return 1 ;;
    esac
    sleep 10
    elapsed=$((elapsed + 10))
  done
  echo "Timed out waiting for $workflow run $run_id." >&2
  return 1
}

run_workflow todo-functions.yml
run_workflow todo-api.yml
run_workflow todo-app.yml

echo "Verifying the deployed services..."
API_RESPONSE=$(curl --fail --silent --show-error --retry 5 --retry-delay 5 \
  --retry-connrefused --max-time 20 "$API_URL/todos")
if ! printf '%s' "$API_RESPONSE" | node -e '
  try {
    if (!Array.isArray(JSON.parse(require("fs").readFileSync(0, "utf8")))) process.exit(1);
  } catch { process.exit(1); }
'; then
  echo "The API did not return a todo list; check the API and database connection." >&2
  exit 1
fi
curl --fail --silent --show-error --retry 5 --retry-delay 5 --retry-connrefused \
  --max-time 20 -o /dev/null "$APP_URL/"
STATISTICS_RESPONSE=$(curl --fail --silent --show-error --retry 5 --retry-delay 5 --retry-connrefused \
  --max-time 20 -H "Origin: $ALLOWED_ORIGIN" -D "$HEADERS_FILE" \
  "$STATISTICS_URL/api/statistics")
if ! awk -v origin="$ALLOWED_ORIGIN" \
  'tolower($1) == "access-control-allow-origin:" { gsub(/\r/, "", $2); if ($2 == origin) found=1 } END { exit !found }' "$HEADERS_FILE"; then
  echo "The Function did not allow the configured frontend origin." >&2
  exit 1
fi
if ! printf '%s' "$STATISTICS_RESPONSE" | node -e '
  try {
    const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const keys = ["total", "completed", "pending"];
    if (!data || Object.keys(data).length !== keys.length ||
        !keys.every(key => Number.isSafeInteger(data[key]) && data[key] >= 0) ||
        data.total !== data.completed + data.pending) process.exit(1);
  } catch { process.exit(1); }
'; then
  echo "The Function returned invalid statistics." >&2
  exit 1
fi

cat <<EOF

Done.
  ACR:    $ACR_LOGIN
  AKS:    $AKS_NAME (resource group $RG)
  Cosmos: $COSMOS_NAME (database $DB_NAME)
  Functions: $FUNCTIONS_NAME ($STATISTICS_URL)
  Frontend: $APP_URL
  API:      $API_URL

Remove everything when finished:  bash infra/destroy.sh
EOF
