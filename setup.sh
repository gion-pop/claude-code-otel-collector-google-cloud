#!/bin/bash

set -e  # Exit on error

log_info() {
    echo -e "\033[32m[INFO]\033[0m $1"
}

log_warn() {
    echo -e "\033[33m[WARN]\033[0m $1"
}

log_error() {
    echo -e "\033[31m[ERROR]\033[0m $1"
}

log_info "Setting environment variables..."
export REGION="${REGION:-asia-northeast1}"
export SERVICE_NAME="${SERVICE_NAME:-claude-code-otel-collector}"
export REPOSITORY_NAME="${REPOSITORY_NAME:-claude-code-otel-collector}"
export SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-claude-code-otel-collector}"
export PROJECT_ID="${PROJECT_ID:-}"
if [[ -z "$PROJECT_ID" ]]; then
    read -p "Enter Google Cloud Project ID: " PROJECT_ID
    export PROJECT_ID
fi

log_info "Configuration values:"
log_info "  PROJECT_ID: ${PROJECT_ID}"
log_info "  REGION: ${REGION}"
log_info "  SERVICE_NAME: ${SERVICE_NAME}"
log_info "  REPOSITORY_NAME: ${REPOSITORY_NAME}"
log_info "  SERVICE_ACCOUNT_NAME: ${SERVICE_ACCOUNT_NAME}"

read -p "Continue with this configuration? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_error "Setup cancelled"
    exit 1
fi

# Enable required APIs
log_info "Enabling required APIs..."
gcloud services enable \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    run.googleapis.com \
    monitoring.googleapis.com \
    logging.googleapis.com \
    secretmanager.googleapis.com \
    --project=${PROJECT_ID}

# Create Artifact Registry repository
log_info "Creating Artifact Registry repository..."
if gcloud artifacts repositories describe ${REPOSITORY_NAME} --location=${REGION} --project=${PROJECT_ID} &>/dev/null; then
    log_warn "Repository ${REPOSITORY_NAME} already exists"
else
    gcloud artifacts repositories create ${REPOSITORY_NAME} \
        --repository-format=docker \
        --location=${REGION} \
        --description="Docker repository for Cloud Run deployments" \
        --project=${PROJECT_ID}
    log_info "Created repository ${REPOSITORY_NAME}"
fi

# Create service account
log_info "Creating service account..."
if gcloud iam service-accounts describe ${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com --project=${PROJECT_ID} &>/dev/null; then
    log_warn "Service account ${SERVICE_ACCOUNT_NAME} already exists"
else
    gcloud iam service-accounts create ${SERVICE_ACCOUNT_NAME} \
        --display-name="OpenTelemetry Collector Service Account" \
        --project=${PROJECT_ID}
    log_info "Created service account ${SERVICE_ACCOUNT_NAME}"
fi

# Grant necessary IAM roles
log_info "Granting IAM roles..."

# Monitoring Metric Writer
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/monitoring.metricWriter" \
    --condition=None \
    --quiet

# Logging Log Writer
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/logging.logWriter" \
    --condition=None \
    --quiet

# Grant necessary permissions for Cloud Build
log_info "Setting up Cloud Build permissions..."

# Get project number
PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format="value(projectNumber)" --project=${PROJECT_ID})

# Cloud Run Admin
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --role="roles/run.admin" \
    --condition=None \
    --quiet

# Service Account User (specific service account only)
gcloud iam service-accounts add-iam-policy-binding ${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com \
    --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --role="roles/iam.serviceAccountUser" \
    --project=${PROJECT_ID} \
    --quiet

# Create Secret Manager secret
log_info "Creating Bearer token in Secret Manager..."

# Generate or input Bearer token
read -p "Generate Bearer token? (y: auto-generate, n: manual input) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Generate secure random token
    BEARER_TOKEN=$(openssl rand -base64 32 | tr -d '=' | tr -d '\n')
    log_info "Auto-generated Bearer token: ${BEARER_TOKEN}"
else
    read -s -p "Enter Bearer token: " BEARER_TOKEN
    echo
fi

# Create secret in Secret Manager
SECRET_NAME="claude_code_otel_collector_bearer_token"
if gcloud secrets describe ${SECRET_NAME} --project=${PROJECT_ID} &>/dev/null; then
    log_warn "Secret ${SECRET_NAME} already exists"
    read -p "Update it? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -n "$BEARER_TOKEN" | gcloud secrets versions add ${SECRET_NAME} --data-file=- --project=${PROJECT_ID}
        log_info "Updated secret ${SECRET_NAME}"
    fi
else
    gcloud secrets create ${SECRET_NAME} --data-file=- --project=${PROJECT_ID} <<< "$BEARER_TOKEN"
    log_info "Created secret ${SECRET_NAME}"
fi

# Grant access permissions to Secret Manager
gcloud secrets add-iam-policy-binding ${SECRET_NAME} \
    --member="serviceAccount:${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor" \
    --condition=None \
    --project=${PROJECT_ID} \
    --quiet

log_info ""
log_info "🎉 Initial setup completed!"
log_info "Run deployment with the following command:"
log_info "   gcloud builds submit --config=cloudbuild.yaml --substitutions=_PROJECT_ID=\"${PROJECT_ID}\" --project=${PROJECT_ID}"
