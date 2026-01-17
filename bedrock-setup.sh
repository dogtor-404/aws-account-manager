#!/bin/bash

################################################################################
# Bedrock Access Setup Script
#
# Manages Bedrock model access setup and IAM User creation for Cursor integration
#
# Usage:
#   ./bedrock-setup.sh setup --config CONFIG_FILE
#   ./bedrock-setup.sh create-user --username NAME --config CONFIG_FILE
#   ./bedrock-setup.sh show-credentials --username NAME
#   ./bedrock-setup.sh list-users
#   ./bedrock-setup.sh delete-user --username NAME
#
################################################################################

set -e
set -o pipefail

################################################################################
# Configuration and Variables
################################################################################

# Color codes for output
readonly COLOR_RESET='\033[0m'
readonly COLOR_INFO='\033[0;34m'
readonly COLOR_SUCCESS='\033[0;32m'
readonly COLOR_ERROR='\033[0;31m'
readonly COLOR_WARNING='\033[0;33m'

# Global variables
COMMAND=""
CONFIG_FILE=""
USERNAME=""
ADMIN_PROFILE=""
REGION=""
ACCOUNT_ID=""
MODEL_IDS=()
INF_PROFILE_IDS=()
TARGET_REGIONS=()
SKIP_ACCESS_KEY=false
POLICY_NAME_PREFIX=""

################################################################################
# Helper Functions
################################################################################

log_info() {
    echo -e "${COLOR_INFO}[INFO]$(date '+%Y-%m-%d %H:%M:%S')${COLOR_RESET} $*" >&2
}

log_success() {
    echo -e "${COLOR_SUCCESS}[SUCCESS]$(date '+%Y-%m-%d %H:%M:%S')${COLOR_RESET} $*" >&2
}

log_error() {
    echo -e "${COLOR_ERROR}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${COLOR_RESET} $*" >&2
}

log_warning() {
    echo -e "${COLOR_WARNING}[WARNING]$(date '+%Y-%m-%d %H:%M:%S')${COLOR_RESET} $*" >&2
}

usage() {
    cat << EOF
Bedrock Access Setup Script

Usage:
  # One-time setup (admin only)
  $(basename "$0") setup --config CONFIG_FILE

  # Create IAM User for Cursor
  $(basename "$0") create-user --username NAME --config CONFIG_FILE

  # Show credentials
  $(basename "$0") show-credentials --username NAME

  # List all Bedrock IAM Users
  $(basename "$0") list-users

  # Delete IAM User
  $(basename "$0") delete-user --username NAME

Commands:
  setup              One-time setup: submit use case, accept agreement, trigger subscription
  create-user        Create IAM User with minimal Bedrock Invoke permissions
  show-credentials   Show Access Key credentials for a user
  list-users         List all Bedrock IAM Users
  delete-user        Delete IAM User and associated policies

Options:
  --config FILE         Path to Bedrock configuration file (JSON)
  --username NAME       IAM User name
  --skip-access-key     Skip creating new access key (for updating existing users)

Examples:
  # One-time setup
  $(basename "$0") setup --config bedrock-config.json

  # Create IAM User
  $(basename "$0") create-user \\
    --username cursor-bedrock-sonnet45 \\
    --config bedrock-config.json

  # Show credentials
  $(basename "$0") show-credentials --username cursor-bedrock-sonnet45

  # List all users
  $(basename "$0") list-users

  # Delete user
  $(basename "$0") delete-user --username cursor-bedrock-sonnet45

EOF
}

################################################################################
# Prerequisite Checks
################################################################################

check_prerequisites() {
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed"
        exit 1
    fi
}

check_profile() {
    local profile="$1"
    
    if [[ -z "${profile}" ]]; then
        log_error "Admin profile is required"
        exit 1
    fi
    
    if ! aws sts get-caller-identity --profile "${profile}" &> /dev/null; then
        log_error "AWS credentials for profile '${profile}' are not configured or invalid"
        exit 1
    fi
}

validate_model_id() {
    local model_id="$1"
    
    if [[ ! "${model_id}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]+:[0-9]+$ ]]; then
        log_error "Invalid model_id format: ${model_id}"
        log_error "Expected format: provider.model-name:version"
        exit 1
    fi
}

validate_inference_profile_id() {
    local profile_id="$1"
    
    # Inference profile ID format: region.provider.model-name-version:revision
    # Example: us.anthropic.claude-sonnet-4-5-20250929-v1:0
    # Allow alphanumeric, dots, hyphens, underscores, and colons
    if [[ ! "${profile_id}" =~ ^[a-z0-9][a-z0-9._:-]+$ ]]; then
        log_error "Invalid inference_profile_id format: ${profile_id}"
        log_error "Expected format: region.provider.model-name-version:revision"
        exit 1
    fi
}

validate_region() {
    local region="$1"
    
    # Basic region format validation (aws format: us-east-1, eu-west-1, etc.)
    if [[ ! "${region}" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
        log_error "Invalid region format: ${region}"
        log_error "Expected format: us-east-1, eu-west-1, etc."
        exit 1
    fi
}

check_bedrock_permissions() {
    log_info "Checking Bedrock permissions..."
    
    # Check if we can list foundation models
    if ! aws bedrock list-foundation-models \
        --profile "${ADMIN_PROFILE}" \
        --region "${REGION}" \
        --output json > /dev/null 2>&1; then
        log_error "No permission to access Bedrock in region ${REGION}"
        log_error "Please ensure your admin profile has bedrock:ListFoundationModels permission"
        exit 1
    fi
    
    log_success "Bedrock permissions verified"
}

load_config() {
    local config_file="$1"
    
    if [[ ! -f "${config_file}" ]]; then
        log_error "Config file not found: ${config_file}"
        exit 1
    fi
    
    if ! jq empty "${config_file}" 2>/dev/null; then
        log_error "Invalid JSON in config file: ${config_file}"
        exit 1
    fi
    
    ADMIN_PROFILE=$(jq -r '.admin_profile // empty' "${config_file}")
    REGION=$(jq -r '.region // empty' "${config_file}")
    POLICY_NAME_PREFIX=$(jq -r '.policy_name_prefix // "CursorBedrockInvokePolicy"' "${config_file}")
    local model_id_single
    local inf_profile_id_single
    model_id_single=$(jq -r '.model_id // empty' "${config_file}")
    inf_profile_id_single=$(jq -r '.inference_profile_id // empty' "${config_file}")
    
    # Read model_ids and inference_profile_ids as arrays (fallback to single values)
    MODEL_IDS=()
    while IFS= read -r model_id; do
        [[ -n "${model_id}" ]] && MODEL_IDS+=("${model_id}")
    done < <(jq -r '.model_ids[]? // empty' "${config_file}")
    
    INF_PROFILE_IDS=()
    while IFS= read -r profile_id; do
        [[ -n "${profile_id}" ]] && INF_PROFILE_IDS+=("${profile_id}")
    done < <(jq -r '.inference_profile_ids[]? // empty' "${config_file}")
    
    if [[ ${#MODEL_IDS[@]} -eq 0 ]] && [[ -n "${model_id_single}" ]]; then
        MODEL_IDS=("${model_id_single}")
    fi
    if [[ ${#INF_PROFILE_IDS[@]} -eq 0 ]] && [[ -n "${inf_profile_id_single}" ]]; then
        INF_PROFILE_IDS=("${inf_profile_id_single}")
    fi
    
    # Read target_regions as array
    TARGET_REGIONS=()
    while IFS= read -r region; do
        [[ -n "${region}" ]] && TARGET_REGIONS+=("${region}")
    done < <(jq -r '.target_regions[]?' "${config_file}")
    
    # Validate required fields
    if [[ -z "${ADMIN_PROFILE}" ]]; then
        log_error "Missing required field: admin_profile"
        exit 1
    fi
    
    if [[ -z "${REGION}" ]]; then
        log_error "Missing required field: region"
        exit 1
    fi
    
    if [[ ${#MODEL_IDS[@]} -eq 0 ]]; then
        log_error "Missing required field: model_id or model_ids"
        exit 1
    fi
    
    if [[ ${#INF_PROFILE_IDS[@]} -eq 0 ]]; then
        log_error "Missing required field: inference_profile_id or inference_profile_ids"
        exit 1
    fi
    
    if [[ ${#MODEL_IDS[@]} -ne ${#INF_PROFILE_IDS[@]} ]]; then
        log_error "model_ids and inference_profile_ids must have the same length"
        exit 1
    fi
    
    # Validate formats
    validate_region "${REGION}"
    for model_id in "${MODEL_IDS[@]}"; do
        validate_model_id "${model_id}"
    done
    for profile_id in "${INF_PROFILE_IDS[@]}"; do
        validate_inference_profile_id "${profile_id}"
    done
    
    # Validate target regions
    for region in "${TARGET_REGIONS[@]}"; do
        validate_region "${region}"
    done
    
    if [[ ${#TARGET_REGIONS[@]} -eq 0 ]]; then
        log_warning "No target_regions specified, using source region: ${REGION}"
        TARGET_REGIONS=("${REGION}")
    fi
    
    check_profile "${ADMIN_PROFILE}"
    
    # Get Account ID
    ACCOUNT_ID=$(aws sts get-caller-identity \
        --profile "${ADMIN_PROFILE}" \
        --query Account \
        --output text 2>/dev/null)
    
    if [[ -z "${ACCOUNT_ID}" ]] || [[ "${ACCOUNT_ID}" == "None" ]]; then
        log_error "Failed to get Account ID. Please check your AWS credentials."
        exit 1
    fi
    
    log_info "Configuration loaded:"
    log_info "  Admin Profile: ${ADMIN_PROFILE}"
    log_info "  Region: ${REGION}"
    log_info "  Model IDs: ${MODEL_IDS[*]}"
    log_info "  Inference Profile IDs: ${INF_PROFILE_IDS[*]}"
    log_info "  Policy Name Prefix: ${POLICY_NAME_PREFIX}"
    log_info "  Account ID: ${ACCOUNT_ID}"
    log_info "  Target Regions: ${TARGET_REGIONS[*]}"
    
    # Check Bedrock permissions
    check_bedrock_permissions
}

################################################################################
# Core Functions
################################################################################

# Setup command functions will be implemented here
setup_bedrock_access() {
    log_info "Starting Bedrock one-time setup..."
    
    # Step 1: Submit use case
    submit_use_case
    
    # Step 2: Accept agreement
    for model_id in "${MODEL_IDS[@]}"; do
        accept_agreement "${model_id}"
    done
    
    # Step 3: Trigger first invocation
    for profile_id in "${INF_PROFILE_IDS[@]}"; do
        trigger_first_invocation "${profile_id}"
    done
    
    log_success "Bedrock setup completed successfully!"
}

submit_use_case() {
    log_info "Step 1: Submitting Model Access Use Case..."
    
    local use_case_file
    use_case_file=$(mktemp)
    trap "rm -f '${use_case_file}'" EXIT
    
    # Create use case JSON from config
    if ! jq -n \
        --arg company_name "$(jq -r '.use_case.company_name // "YOUR_COMPANY_NAME"' "${CONFIG_FILE}")" \
        --arg company_website "$(jq -r '.use_case.company_website // "https://example.com"' "${CONFIG_FILE}")" \
        --arg intended_users "$(jq -r '.use_case.intended_users // "internal developers"' "${CONFIG_FILE}")" \
        --arg industry_option "$(jq -r '.use_case.industry_option // "Software"' "${CONFIG_FILE}")" \
        --arg other_industry_option "$(jq -r '.use_case.other_industry_option // ""' "${CONFIG_FILE}")" \
        --arg use_cases "$(jq -r '.use_case.use_cases // "Coding assistant in Cursor via Amazon Bedrock"' "${CONFIG_FILE}")" \
        '{
            companyName: $company_name,
            companyWebsite: $company_website,
            intendedUsers: $intended_users,
            industryOption: $industry_option,
            otherIndustryOption: $other_industry_option,
            useCases: $use_cases
        }' > "${use_case_file}" 2>/dev/null; then
        log_error "Failed to create use case JSON"
        rm -f "${use_case_file}"
        exit 1
    fi
    
    log_info "Submitting use case..."
    log_info "Note: If this hangs, the API may require Console access"
    log_info "Console: https://console.aws.amazon.com/bedrock -> Model access -> Request model access"
    
    # Try to submit use case (may fail due to form-data format issues)
    local submit_output
    submit_output=$(aws bedrock put-use-case-for-model-access \
        --profile "${ADMIN_PROFILE}" \
        --region "${REGION}" \
        --cli-binary-format raw-in-base64-out \
        --form-data "fileb://${use_case_file}" \
        --cli-read-timeout 30 \
        --cli-connect-timeout 10 \
        2>&1)
    local submit_exit_code=$?
    
    if [[ ${submit_exit_code} -eq 0 ]]; then
        log_success "Use case submitted successfully"
    elif echo "${submit_output}" | grep -qi "already exists\|AlreadyExists"; then
        log_warning "Use case already submitted (this is OK)"
    elif echo "${submit_output}" | grep -qi "ValidationException\|Invalid form data"; then
        log_warning "CLI form-data format may not be supported for this API"
        log_warning "Error: ${submit_output}"
        log_warning "Please submit use case via AWS Console:"
        log_warning "  1. Go to https://console.aws.amazon.com/bedrock"
        log_warning "  2. Navigate to 'Model access' -> 'Request model access'"
        log_warning "  3. Fill in the use case information"
        log_warning ""
        echo -n "Have you already submitted the use case via Console? (y/N): "
        read -r response
        if [[ "${response}" != "y" && "${response}" != "Y" ]]; then
            log_error "Please submit use case via Console first, then re-run this script"
            rm -f "${use_case_file}"
            exit 1
        else
            log_info "Skipping use case submission (assuming already done via Console)"
        fi
    else
        log_warning "Failed to submit use case via CLI"
        log_warning "Error: ${submit_output}"
        log_warning "You may need to submit use case via AWS Console"
        echo -n "Continue anyway? (y/N): "
        read -r response
        if [[ "${response}" != "y" && "${response}" != "Y" ]]; then
            rm -f "${use_case_file}"
            exit 1
        else
            log_info "Skipping use case submission"
        fi
    fi
    
    rm -f "${use_case_file}"
    trap - EXIT
}

accept_agreement() {
    local model_id="$1"
    log_info "Step 2: Accepting Model Agreement..."
    
    log_info "Fetching agreement offers for model: ${model_id}"
    
    local offers
    offers=$(aws bedrock list-foundation-model-agreement-offers \
        --profile "${ADMIN_PROFILE}" \
        --region "${REGION}" \
        --model-id "${model_id}" \
        --offer-type PUBLIC \
        --output json 2>&1)
    local offers_exit_code=$?
    
    if [[ ${offers_exit_code} -ne 0 ]]; then
        # Check if error is due to model not requiring agreement
        if echo "${offers}" | grep -qi "does not require\|not found"; then
            log_warning "Model ${model_id} does not require an agreement"
            return 0
        fi
        log_warning "Could not fetch agreement offers: ${offers}"
        log_warning "This may mean the model doesn't require an agreement, or it's already accepted"
        return 0
    fi
    
    local offer_count
    offer_count=$(echo "${offers}" | jq -r '.offers | length // 0')
    
    if [[ "${offer_count}" -eq 0 ]] || [[ "${offer_count}" == "null" ]]; then
        log_warning "No agreement offers found for model ${model_id}"
        log_warning "This may mean the model doesn't require an agreement, or it's already accepted"
        return 0
    fi
    
    local offer_token
    offer_token=$(echo "${offers}" | jq -r '.offers[0].offerToken // empty')
    
    if [[ -z "${offer_token}" ]] || [[ "${offer_token}" == "null" ]]; then
        log_warning "Could not extract offer token"
        return 0
    fi
    
    log_info "Creating agreement with offer token: ${offer_token}"
    
    local agreement_output
    agreement_output=$(aws bedrock create-foundation-model-agreement \
        --profile "${ADMIN_PROFILE}" \
        --region "${REGION}" \
        --model-id "${model_id}" \
        --offer-token "${offer_token}" \
        --output json 2>&1)
    local agreement_exit_code=$?
    
    if [[ ${agreement_exit_code} -eq 0 ]]; then
        log_success "Agreement accepted successfully"
    elif echo "${agreement_output}" | grep -qi "already exists\|AlreadyExists"; then
        log_warning "Agreement already exists (this is OK)"
    else
        log_warning "Failed to create agreement: ${agreement_output}"
        log_warning "This may be OK if agreement was already accepted"
    fi
}

trigger_first_invocation() {
    local profile_id="$1"
    log_info "Step 3: Triggering first invocation to complete subscription..."
    
    log_info "Sending test message to: ${profile_id}"
    
    local invoke_output
    invoke_output=$(aws bedrock-runtime converse \
        --profile "${ADMIN_PROFILE}" \
        --region "${REGION}" \
        --model-id "${profile_id}" \
        --messages '[{"role":"user","content":[{"text":"ping"}]}]' \
        --output json 2>&1)
    local invoke_exit_code=$?
    
    if [[ ${invoke_exit_code} -eq 0 ]]; then
        log_success "First invocation successful - subscription triggered"
    else
        # Check for specific error types
        if echo "${invoke_output}" | grep -qi "AccessDenied\|UnauthorizedOperation"; then
            log_error "Access denied. Please check your permissions."
            log_error "Error: ${invoke_output}"
            exit 1
        elif echo "${invoke_output}" | grep -qi "Throttling\|Rate exceeded"; then
            log_warning "Rate limit exceeded. Waiting 5 seconds and retrying..."
            sleep 5
            if aws bedrock-runtime converse \
                --profile "${ADMIN_PROFILE}" \
                --region "${REGION}" \
                --model-id "${profile_id}" \
                --messages '[{"role":"user","content":[{"text":"ping"}]}]' \
                --output json > /dev/null 2>&1; then
                log_success "First invocation successful after retry"
            else
                log_warning "First invocation failed after retry - this may be OK if subscription was already active"
            fi
        else
            log_warning "First invocation failed - this may be OK if subscription was already active"
            log_warning "Error: ${invoke_output}"
            log_warning "You can proceed to create IAM User"
        fi
    fi
}

# Create user command functions will be implemented here
validate_username() {
    local username="$1"
    
    # IAM username validation: 1-64 characters, alphanumeric and +=,.@_-
    if [[ ! "${username}" =~ ^[a-zA-Z0-9+=,.@_-]{1,64}$ ]]; then
        log_error "Invalid username format: ${username}"
        log_error "Username must be 1-64 characters and contain only: a-z, A-Z, 0-9, and +=,.@_-"
        exit 1
    fi
}

check_iam_permissions() {
    log_info "Checking IAM permissions..."
    
    # Check if we can list users
    if ! aws iam list-users \
        --profile "${ADMIN_PROFILE}" \
        --output json > /dev/null 2>&1; then
        log_error "No permission to access IAM"
        log_error "Please ensure your admin profile has iam:ListUsers permission"
        exit 1
    fi
    
    log_success "IAM permissions verified"
}

create_bedrock_user() {
    local username="$1"
    
    validate_username "${username}"
    check_iam_permissions
    
    log_info "Creating IAM User: ${username}"
    
    # Check if user already exists
    if aws iam get-user --profile "${ADMIN_PROFILE}" --user-name "${username}" &> /dev/null; then
        log_warning "User '${username}' already exists"
        echo -n "Continue to create/update policy and access key? (y/N): "
        read -r response
        if [[ "${response}" != "y" && "${response}" != "Y" ]]; then
            log_info "Aborted"
            exit 0
        fi
    else
        # Create user
        log_info "Creating IAM User..."
        if ! aws iam create-user \
            --profile "${ADMIN_PROFILE}" \
            --user-name "${username}" \
            --output json > /dev/null 2>&1; then
            log_error "Failed to create IAM User"
            exit 1
        fi
        log_success "IAM User created: ${username}"
    fi
    
    # Generate policy
    local policy_doc
    policy_doc=$(generate_policy_document)
    
    local policy_name="${POLICY_NAME_PREFIX}"
    policy_name=$(echo "${policy_name}" | sed 's/[^a-zA-Z0-9+=,.@_-]//g')
    
    # Check if policy exists
    local policy_arn
    if policy_arn=$(aws iam get-policy \
        --profile "${ADMIN_PROFILE}" \
        --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${policy_name}" \
        --query 'Policy.Arn' \
        --output text 2>/dev/null); then
        log_warning "Policy '${policy_name}' already exists"
        log_info "Updating policy..."
        
        # List existing policy versions
        local versions
        versions=$(aws iam list-policy-versions \
            --profile "${ADMIN_PROFILE}" \
            --policy-arn "${policy_arn}" \
            --output json 2>/dev/null || echo '{"Versions":[]}')
        
        local version_count
        version_count=$(echo "${versions}" | jq '.Versions | length')
        
        # IAM policy can have max 5 versions, need to delete old non-default versions
        if [[ ${version_count} -ge 5 ]]; then
            log_info "Policy has ${version_count} versions (max 5), cleaning up old versions..."
            
            # Get default version ID
            local default_version
            default_version=$(echo "${versions}" | jq -r '.Versions[] | select(.IsDefaultVersion == true) | .VersionId')
            
            # Delete all non-default versions
            echo "${versions}" | jq -r '.Versions[] | select(.IsDefaultVersion == false) | .VersionId' | while read -r version_id; do
                [[ -z "${version_id}" ]] && continue
                log_info "Deleting old policy version: ${version_id}"
                aws iam delete-policy-version \
                    --profile "${ADMIN_PROFILE}" \
                    --policy-arn "${policy_arn}" \
                    --version-id "${version_id}" \
                    --output json > /dev/null 2>&1 || true
            done
        fi
        
        # Create new policy version
        local policy_file
        policy_file=$(mktemp)
        echo "${policy_doc}" > "${policy_file}"
        
        aws iam create-policy-version \
            --profile "${ADMIN_PROFILE}" \
            --policy-arn "${policy_arn}" \
            --policy-document "file://${policy_file}" \
            --set-as-default \
            --output json > /dev/null
        
        rm -f "${policy_file}"
        log_success "Policy updated"
    else
        # Create new policy
        log_info "Creating IAM Policy: ${policy_name}"
        
        local policy_file
        policy_file=$(mktemp)
        echo "${policy_doc}" > "${policy_file}"
        
        policy_arn=$(aws iam create-policy \
            --profile "${ADMIN_PROFILE}" \
            --policy-name "${policy_name}" \
            --policy-document "file://${policy_file}" \
            --query 'Policy.Arn' \
            --output text)
        
        rm -f "${policy_file}"
        log_success "Policy created: ${policy_arn}"
    fi
    
    # Attach policy to user
    log_info "Attaching policy to user..."
    
    if aws iam attach-user-policy \
        --profile "${ADMIN_PROFILE}" \
        --user-name "${username}" \
        --policy-arn "${policy_arn}" \
        --output json > /dev/null 2>&1; then
        log_success "Policy attached to user"
    else
        log_warning "Policy may already be attached (this is OK)"
    fi
    
    # Skip access key creation if requested
    if [[ "${SKIP_ACCESS_KEY}" == "true" ]]; then
        log_success "Policy updated successfully for user '${username}'"
        log_info "Skipping access key creation as requested"
        log_info "Use 'show-credentials' command to view existing access keys"
        return 0
    fi
    
    # Check existing access keys (limit is 2 per user)
    local existing_keys
    existing_keys=$(aws iam list-access-keys \
        --profile "${ADMIN_PROFILE}" \
        --user-name "${username}" \
        --output json 2>/dev/null || echo '{"AccessKeyMetadata":[]}')
    
    local key_count
    key_count=$(echo "${existing_keys}" | jq '.AccessKeyMetadata | length')
    
    if [[ "${key_count}" -ge 2 ]]; then
        log_warning "User already has 2 access keys (maximum allowed)"
        log_warning "Please delete an existing key first, or use show-credentials to view existing keys"
        echo ""
        echo "Existing access keys:"
        echo "${existing_keys}" | jq -r '.AccessKeyMetadata[] | 
            "  Access Key ID: \(.AccessKeyId) (Status: \(.Status))"
        '
        echo ""
        echo -n "Delete an existing key and create a new one? (y/N): "
        read -r response
        if [[ "${response}" == "y" || "${response}" == "Y" ]]; then
            echo "Enter the Access Key ID to delete: "
            read -r key_to_delete
            if [[ -n "${key_to_delete}" ]]; then
                log_info "Deleting access key: ${key_to_delete}"
                aws iam delete-access-key \
                    --profile "${ADMIN_PROFILE}" \
                    --user-name "${username}" \
                    --access-key-id "${key_to_delete}" \
                    --output json > /dev/null 2>&1
                log_success "Access key deleted"
            fi
        else
            log_info "Aborted"
            exit 0
        fi
    fi
    
    # Create access key
    log_info "Creating Access Key..."
    
    local key_result
    key_result=$(aws iam create-access-key \
        --profile "${ADMIN_PROFILE}" \
        --user-name "${username}" \
        --output json 2>&1)
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to create access key"
        log_error "Error: ${key_result}"
        exit 1
    fi
    
    local access_key_id
    access_key_id=$(echo "${key_result}" | jq -r '.AccessKey.AccessKeyId // empty')
    local secret_access_key
    secret_access_key=$(echo "${key_result}" | jq -r '.AccessKey.SecretAccessKey // empty')
    
    if [[ -z "${access_key_id}" ]] || [[ -z "${secret_access_key}" ]]; then
        log_error "Failed to extract access key credentials"
        exit 1
    fi
    
    log_success "Access Key created successfully"
    echo ""
    echo "=========================================="
    echo "IMPORTANT: Save these credentials now!"
    echo "=========================================="
    echo ""
    echo "Access Key ID:     ${access_key_id}"
    echo "Secret Access Key: ${secret_access_key}"
    echo "Region:            ${REGION}"
    echo "Inference Profile IDs:"
    for profile_id in "${INF_PROFILE_IDS[@]}"; do
        echo "  - ${profile_id}"
    done
    echo "Model IDs:"
    for model_id in "${MODEL_IDS[@]}"; do
        echo "  - ${model_id}"
    done
    echo ""
    echo "=========================================="
    echo "These credentials will NOT be shown again!"
    echo "=========================================="
    echo ""
}

generate_policy_document() {
    # Generate policy with inference profile and foundation model resources
    # Note: foundation-model ARN format: arn:aws:bedrock:<region>::foundation-model/<model-id>
    # (two colons, not three - the empty account ID is represented by two colons)
    local policy
    policy=$(jq -n \
        --arg region "${REGION}" \
        --arg account_id "${ACCOUNT_ID}" \
        --argjson model_ids "$(printf '%s\n' "${MODEL_IDS[@]}" | jq -R . | jq -s .)" \
        --argjson inf_profile_ids "$(printf '%s\n' "${INF_PROFILE_IDS[@]}" | jq -R . | jq -s .)" \
        --argjson target_regions "$(printf '%s\n' "${TARGET_REGIONS[@]}" | jq -R . | jq -s .)" \
        'def profile_arn($inf): "arn:aws:bedrock:\($region):\($account_id):inference-profile/\($inf)";
         def model_arns($model): $target_regions | map("arn:aws:bedrock:\(.)::foundation-model/\($model)");
         {
            Version: "2012-10-17",
            Statement: (
                ([range(0; ($inf_profile_ids | length)) as $i | {
                    Sid: "InvokeInferenceProfile\($i)",
                    Effect: "Allow",
                    Action: [
                        "bedrock:InvokeModel",
                        "bedrock:InvokeModelWithResponseStream"
                    ],
                    Resource: [profile_arn($inf_profile_ids[$i])]
                }]
                +
                [range(0; ($model_ids | length)) as $i | {
                    Sid: "InvokeUnderlyingFoundationModelOnlyViaThatProfile\($i)",
                    Effect: "Allow",
                    Action: [
                        "bedrock:InvokeModel",
                        "bedrock:InvokeModelWithResponseStream"
                    ],
                    Resource: model_arns($model_ids[$i]),
                    Condition: {
                        StringLike: {
                            "bedrock:InferenceProfileArn": profile_arn($inf_profile_ids[$i])
                        }
                    }
                }])
            )
        }')
    
    echo "${policy}"
}

show_credentials() {
    local username="$1"
    
    log_info "Retrieving credentials for user: ${username}"
    
    # Check if user exists
    if ! aws iam get-user --profile "${ADMIN_PROFILE}" --user-name "${username}" &> /dev/null; then
        log_error "User '${username}' not found"
        exit 1
    fi
    
    # List access keys
    local keys
    keys=$(aws iam list-access-keys \
        --profile "${ADMIN_PROFILE}" \
        --user-name "${username}" \
        --output json)
    
    local key_count
    key_count=$(echo "${keys}" | jq '.AccessKeyMetadata | length')
    
    if [[ "${key_count}" -eq 0 ]]; then
        log_warning "No access keys found for user '${username}'"
        return 0
    fi
    
    echo ""
    echo "Access Keys for user '${username}':"
    echo "${keys}" | jq -r '.AccessKeyMetadata[] | 
        "  Access Key ID: \(.AccessKeyId)",
        "  Status: \(.Status)",
        "  Created: \(.CreateDate)",
        ""
    '
    
    log_warning "Secret Access Keys are not retrievable after creation"
    log_warning "If you need new credentials, delete and recreate the access key"
}

list_users() {
    log_info "Listing all Bedrock IAM Users..."
    
    # List all users with policies containing "Bedrock" or "bedrock"
    local all_users
    all_users=$(aws iam list-users --profile "${ADMIN_PROFILE}" --output json)
    
    echo ""
    echo "IAM Users (checking for Bedrock-related policies):"
    echo ""
    
    local found_users=false
    while IFS= read -r username; do
        [[ -z "${username}" ]] && continue
        
        local user_policies
        user_policies=$(aws iam list-attached-user-policies \
            --profile "${ADMIN_PROFILE}" \
            --user-name "${username}" \
            --output json 2>/dev/null || echo '{"AttachedPolicies":[]}')
        
        local inline_policies
        inline_policies=$(aws iam list-user-policies \
            --profile "${ADMIN_PROFILE}" \
            --user-name "${username}" \
            --output json 2>/dev/null || echo '{"PolicyNames":[]}')
        
        # Check if any policy name contains "Bedrock" or "bedrock"
        local has_bedrock=false
        if echo "${user_policies}" | jq -r '.AttachedPolicies[].PolicyName' | grep -qi "bedrock\|cursor"; then
            has_bedrock=true
        fi
        if echo "${inline_policies}" | jq -r '.PolicyNames[]' | grep -qi "bedrock\|cursor"; then
            has_bedrock=true
        fi
        
        if [[ "${has_bedrock}" == "true" ]]; then
            found_users=true
            echo "  - ${username}"
            echo "${user_policies}" | jq -r '.AttachedPolicies[] | "    Policy: \(.PolicyName) (ARN: \(.PolicyArn))"'
        fi
    done < <(echo "${all_users}" | jq -r '.Users[].UserName')
    
    if [[ "${found_users}" == "false" ]]; then
        log_info "No Bedrock-related IAM Users found"
    fi
}

delete_user() {
    local username="$1"
    
    log_info "Deleting IAM User: ${username}"
    
    # Check if user exists
    if ! aws iam get-user --profile "${ADMIN_PROFILE}" --user-name "${username}" &> /dev/null; then
        log_error "User '${username}' not found"
        exit 1
    fi
    
    # Delete access keys
    log_info "Deleting access keys..."
    local keys
    keys=$(aws iam list-access-keys \
        --profile "${ADMIN_PROFILE}" \
        --user-name "${username}" \
        --output json)
    
    echo "${keys}" | jq -r '.AccessKeyMetadata[].AccessKeyId' | while read -r key_id; do
        [[ -z "${key_id}" ]] && continue
        log_info "Deleting access key: ${key_id}"
        aws iam delete-access-key \
            --profile "${ADMIN_PROFILE}" \
            --user-name "${username}" \
            --access-key-id "${key_id}" \
            --output json > /dev/null
    done
    
    # Detach policies
    log_info "Detaching policies..."
    local attached_policies
    attached_policies=$(aws iam list-attached-user-policies \
        --profile "${ADMIN_PROFILE}" \
        --user-name "${username}" \
        --output json)
    
    echo "${attached_policies}" | jq -r '.AttachedPolicies[].PolicyArn' | while read -r policy_arn; do
        [[ -z "${policy_arn}" ]] && continue
        log_info "Detaching policy: ${policy_arn}"
        aws iam detach-user-policy \
            --profile "${ADMIN_PROFILE}" \
            --user-name "${username}" \
            --policy-arn "${policy_arn}" \
            --output json > /dev/null
    done
    
    # Delete inline policies
    log_info "Deleting inline policies..."
    local inline_policies
    inline_policies=$(aws iam list-user-policies \
        --profile "${ADMIN_PROFILE}" \
        --user-name "${username}" \
        --output json)
    
    echo "${inline_policies}" | jq -r '.PolicyNames[]' | while read -r policy_name; do
        [[ -z "${policy_name}" ]] && continue
        log_info "Deleting inline policy: ${policy_name}"
        aws iam delete-user-policy \
            --profile "${ADMIN_PROFILE}" \
            --user-name "${username}" \
            --policy-name "${policy_name}" \
            --output json > /dev/null
    done
    
    # Delete user
    log_info "Deleting IAM User..."
    aws iam delete-user \
        --profile "${ADMIN_PROFILE}" \
        --user-name "${username}" \
        --output json > /dev/null
    
    log_success "User '${username}' deleted successfully"
    
    # Note: We don't delete the managed policy itself, as it might be used by other users
    log_info "Note: Managed policies were detached but not deleted"
    log_info "If you want to delete unused policies, do it manually"
}

################################################################################
# Main Execution
################################################################################

parse_arguments() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi
    
    COMMAND="$1"
    shift
    
    case "${COMMAND}" in
        setup|create-user|show-credentials|list-users|delete-user)
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown command: ${COMMAND}"
            usage
            exit 1
            ;;
    esac
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --username)
                USERNAME="$2"
                shift 2
                ;;
            --skip-access-key)
                SKIP_ACCESS_KEY=true
                shift
                ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

validate_inputs() {
    case "${COMMAND}" in
        setup|create-user)
            if [[ -z "${CONFIG_FILE}" ]]; then
                log_error "--config is required for ${COMMAND} command"
                exit 1
            fi
            ;;
        show-credentials|delete-user)
            if [[ -z "${USERNAME}" ]]; then
                log_error "--username is required for ${COMMAND} command"
                exit 1
            fi
            ;;
        list-users)
            # No arguments required
            ;;
    esac
}

main() {
    parse_arguments "$@"
    validate_inputs
    check_prerequisites
    
    case "${COMMAND}" in
        setup)
            load_config "${CONFIG_FILE}"
            setup_bedrock_access
            ;;
        create-user)
            if [[ -z "${USERNAME}" ]]; then
                log_error "--username is required for create-user command"
                exit 1
            fi
            load_config "${CONFIG_FILE}"
            create_bedrock_user "${USERNAME}"
            ;;
        show-credentials)
            # For show-credentials, we need to detect profile from environment or use default
            if [[ -z "${ADMIN_PROFILE}" ]]; then
                ADMIN_PROFILE="${AWS_PROFILE:-default}"
            fi
            check_profile "${ADMIN_PROFILE}"
            show_credentials "${USERNAME}"
            ;;
        list-users)
            # For list-users, we need to detect profile from environment or use default
            if [[ -z "${ADMIN_PROFILE}" ]]; then
                ADMIN_PROFILE="${AWS_PROFILE:-default}"
            fi
            check_profile "${ADMIN_PROFILE}"
            list_users
            ;;
        delete-user)
            # For delete-user, we need to detect profile from environment or use default
            if [[ -z "${ADMIN_PROFILE}" ]]; then
                ADMIN_PROFILE="${AWS_PROFILE:-default}"
            fi
            check_profile "${ADMIN_PROFILE}"
            delete_user "${USERNAME}"
            ;;
    esac
}

main "$@"

