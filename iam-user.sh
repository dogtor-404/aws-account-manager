#!/bin/bash

################################################################################
# IAM Identity Center User Management Script
#
# Manages IAM Identity Center users and permission assignments
#
# Usage:
#   ./iam-user.sh create --username NAME --email EMAIL --permission-set-name NAME
#   ./iam-user.sh list
#   ./iam-user.sh show --username NAME
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
USERNAME=""
EMAIL_ADDRESS=""
PERMISSION_SET_NAME=""
SSO_INSTANCE_ARN=""
IDENTITY_STORE_ID=""
ACCOUNT_ID=""

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
IAM Identity Center User Management Script

Usage:
  $(basename "$0") create --username NAME --email EMAIL --permission-set-name NAME
  $(basename "$0") check --username NAME
  $(basename "$0") list
  $(basename "$0") show --username NAME

Commands:
  create    Create a new user and assign Permission Set
  check     Check if a user exists
  list      List all users
  show      Show user details

Options:
  --username NAME              Username for the IAM Identity Center user
  --email EMAIL                Email address for user activation
  --permission-set-name NAME   Permission Set name to assign

Examples:
  # Create user
  $(basename "$0") create \\
    --username Affyned-dev-user \\
    --email neoztcl@gmail.com \\
    --permission-set-name TerraformDeployerPermissionSet
  
  # List all users
  $(basename "$0") list
  
  # Show user details
  $(basename "$0") show --username Affyned-dev-user

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
    
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials are not configured"
        exit 1
    fi
}

get_aws_resources() {
    log_info "Discovering AWS resources..."
    
    # Get IAM Identity Center instance
    local instances
    instances=$(aws sso-admin list-instances --output json 2>/dev/null)
    
    if [[ -z "${instances}" ]] || [[ "$(echo "${instances}" | jq '.Instances | length')" -eq 0 ]]; then
        log_error "No IAM Identity Center instance found"
        exit 2
    fi
    
    SSO_INSTANCE_ARN=$(echo "${instances}" | jq -r '.Instances[0].InstanceArn')
    IDENTITY_STORE_ID=$(echo "${instances}" | jq -r '.Instances[0].IdentityStoreId')
    
    log_success "Instance ARN: ${SSO_INSTANCE_ARN}"
    log_success "Identity Store ID: ${IDENTITY_STORE_ID}"
    
    # Get current account ID
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    log_success "Account ID: ${ACCOUNT_ID}"
}

################################################################################
# Core Functions
################################################################################

check_user_exists() {
    local username="$1"
    
    local existing_users
    existing_users=$(aws identitystore list-users \
        --identity-store-id "${IDENTITY_STORE_ID}" \
        --filters AttributePath=UserName,AttributeValue="${username}" \
        --output json 2>/dev/null || echo '{"Users":[]}')
    
    if [[ "$(echo "${existing_users}" | jq '.Users | length')" -gt 0 ]]; then
        local user_id
        user_id=$(echo "${existing_users}" | jq -r '.Users[0].UserId')
        
        # Validate the extracted user_id
        if [[ -z "${user_id}" ]] || [[ "${user_id}" == "null" ]]; then
            log_error "Failed to extract User ID from API response"
            return 1
        fi
        
        echo "${user_id}"
        return 0
    else
        return 1
    fi
}

create_iam_user() {
    local username="$1"
    local email="$2"
    local given_name="$3"
    local family_name="$4"
    
    log_info "Creating IAM Identity Center user: ${username}..."
    
    # Check if user already exists
    if user_id=$(check_user_exists "${username}"); then
        log_warning "User '${username}' already exists with ID: ${user_id}"
        echo "${user_id}"
        return 0
    fi
    
    # Create the user
    local result
    result=$(aws identitystore create-user \
        --identity-store-id "${IDENTITY_STORE_ID}" \
        --user-name "${username}" \
        --display-name "${given_name} ${family_name}" \
        --name GivenName="${given_name}",FamilyName="${family_name}" \
        --emails Value="${email}",Type=Work,Primary=true \
        --output json)
    
    local user_id
    user_id=$(echo "${result}" | jq -r '.UserId')
    
    if [[ -z "${user_id}" ]] || [[ "${user_id}" == "null" ]]; then
        log_error "Failed to create user or extract User ID"
        log_error "API Response: ${result}"
        exit 2
    fi
    
    # Validate User ID format
    if [[ ${#user_id} -gt 47 ]]; then
        log_error "Created User ID length (${#user_id}) exceeds AWS maximum (47)"
        log_error "User ID: ${user_id}"
        exit 2
    fi
    
    log_success "User created successfully"
    log_success "User ID: ${user_id}"
    log_success "User ID length: ${#user_id}"
    log_success "Activation email will be sent to: ${email}"
    
    echo "${user_id}"
}

get_permission_set_arn() {
    local ps_name="$1"
    
    local permission_sets
    permission_sets=$(aws sso-admin list-permission-sets \
        --instance-arn "${SSO_INSTANCE_ARN}" \
        --output json)
    
    for ps_arn in $(echo "${permission_sets}" | jq -r '.PermissionSets[]'); do
        local name
        name=$(aws sso-admin describe-permission-set \
            --instance-arn "${SSO_INSTANCE_ARN}" \
            --permission-set-arn "${ps_arn}" \
            --query 'PermissionSet.Name' \
            --output text)
        
        if [[ "${name}" == "${ps_name}" ]]; then
            echo "${ps_arn}"
            return 0
        fi
    done
    
    log_error "Permission Set '${ps_name}' not found"
    exit 2
}

assign_permission_set() {
    local user_id="$1"
    local permission_set_name="$2"
    
    log_info "Assigning Permission Set: ${permission_set_name}..."
    
    # Validate user_id format and length
    log_info "User ID to assign: ${user_id}"
    log_info "User ID length: ${#user_id}"
    
    if [[ -z "${user_id}" ]]; then
        log_error "User ID is empty"
        exit 2
    fi
    
    if [[ ${#user_id} -gt 47 ]]; then
        log_error "User ID length (${#user_id}) exceeds AWS maximum (47 characters)"
        log_error "User ID value: ${user_id}"
        exit 2
    fi
    
    # Validate UUID format (with optional 10-char prefix)
    if ! [[ "${user_id}" =~ ^([0-9a-f]{10}-)?[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]]; then
        log_error "User ID format is invalid. Expected UUID format."
        log_error "User ID value: ${user_id}"
        exit 2
    fi
    
    # Get Permission Set ARN
    local ps_arn
    ps_arn=$(get_permission_set_arn "${permission_set_name}")
    log_success "Found Permission Set ARN: ${ps_arn}"
    
    # Check if assignment already exists
    local existing_assignments
    existing_assignments=$(aws sso-admin list-account-assignments \
        --instance-arn "${SSO_INSTANCE_ARN}" \
        --account-id "${ACCOUNT_ID}" \
        --permission-set-arn "${ps_arn}" \
        --output json 2>/dev/null || echo '{"AccountAssignments":[]}')
    
    for assignment in $(echo "${existing_assignments}" | jq -r '.AccountAssignments[] | @base64'); do
        _jq() {
            echo "${assignment}" | base64 --decode | jq -r "${1}"
        }
        
        local principal_id principal_type
        principal_id=$(_jq '.PrincipalId')
        principal_type=$(_jq '.PrincipalType')
        
        if [[ "${principal_id}" == "${user_id}" ]] && [[ "${principal_type}" == "USER" ]]; then
            log_warning "Permission assignment already exists for this user"
            return 0
        fi
    done
    
    # Create the assignment
    local result
    result=$(aws sso-admin create-account-assignment \
        --instance-arn "${SSO_INSTANCE_ARN}" \
        --target-id "${ACCOUNT_ID}" \
        --target-type AWS_ACCOUNT \
        --permission-set-arn "${ps_arn}" \
        --principal-type USER \
        --principal-id "${user_id}" \
        --output json)
    
    local request_id
    request_id=$(echo "${result}" | jq -r '.AccountAssignmentCreationStatus.RequestId')
    
    log_info "Assignment request ID: ${request_id}"
    log_info "Waiting for assignment to complete..."
    
    # Poll for completion
    local max_attempts=24
    local attempt=0
    
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        local status_result
        status_result=$(aws sso-admin describe-account-assignment-creation-status \
            --instance-arn "${SSO_INSTANCE_ARN}" \
            --account-assignment-creation-request-id "${request_id}" \
            --output json)
        
        local status
        status=$(echo "${status_result}" | jq -r '.AccountAssignmentCreationStatus.Status')
        
        case "${status}" in
            "SUCCEEDED")
                log_success "Permission assignment completed successfully"
                return 0
                ;;
            "FAILED")
                local failure_reason
                failure_reason=$(echo "${status_result}" | jq -r '.AccountAssignmentCreationStatus.FailureReason // "Unknown"')
                log_error "Permission assignment failed: ${failure_reason}"
                exit 2
                ;;
            "IN_PROGRESS")
                log_info "Assignment in progress... (attempt $((attempt + 1))/${max_attempts})"
                sleep 5
                ((attempt++))
                ;;
            *)
                log_warning "Unknown status: ${status}"
                sleep 5
                ((attempt++))
                ;;
        esac
    done
    
    log_error "Permission assignment timed out after 120 seconds"
    exit 2
}

create_command() {
    local username="$1"
    local email="$2"
    local permission_set_name="$3"
    
    # Extract given name and family name from username
    local given_name family_name
    if [[ "${username}" =~ ^([^-]+)-(.+)$ ]]; then
        given_name="${BASH_REMATCH[1]}"
        family_name="${BASH_REMATCH[2]}"
    else
        given_name="${username}"
        family_name="User"
    fi
    
    # Create user
    local user_id
    user_id=$(create_iam_user "${username}" "${email}" "${given_name}" "${family_name}")
    
    # Assign Permission Set
    assign_permission_set "${user_id}" "${permission_set_name}"
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "           User Creation Summary"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "✅ User Created:"
    echo "   Username:      ${username}"
    echo "   User ID:       ${user_id}"
    echo "   Email:         ${email}"
    echo "   Display Name:  ${given_name} ${family_name}"
    echo ""
    echo "✅ Permission Assignment:"
    echo "   Permission Set: ${permission_set_name}"
    echo "   Account:        ${ACCOUNT_ID}"
    echo "   Status:         SUCCEEDED"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
}

list_command() {
    log_info "Listing all users..."
    
    local users
    users=$(aws identitystore list-users \
        --identity-store-id "${IDENTITY_STORE_ID}" \
        --output json)
    
    local user_count
    user_count=$(echo "${users}" | jq '.Users | length')
    
    if [[ "${user_count}" -eq 0 ]]; then
        log_info "No users found"
        return 0
    fi
    
    echo ""
    echo "Users (Total: ${user_count}):"
    echo "${users}" | jq -r '.Users[] | 
        "  - \(.UserName) (\(.DisplayName)) - \(.Emails[0].Value)"
    '
}

check_command() {
    local username="$1"
    
    log_info "Checking if user '${username}' exists..."
    
    if user_id=$(check_user_exists "${username}"); then
        log_success "User exists with ID: ${user_id}"
        return 0
    else
        log_error "User '${username}' not found"
        return 1
    fi
}

show_command() {
    local username="$1"
    
    log_info "Getting details for user: ${username}"
    
    local user_id
    if ! user_id=$(check_user_exists "${username}"); then
        log_error "User '${username}' not found"
        exit 1
    fi
    
    local user_details
    user_details=$(aws identitystore describe-user \
        --identity-store-id "${IDENTITY_STORE_ID}" \
        --user-id "${user_id}" \
        --output json)
    
    echo ""
    echo "User Details:"
    echo "${user_details}" | jq -r '
        "  Username: \(.UserName)",
        "  User ID: \(.UserId)",
        "  Display Name: \(.DisplayName)",
        "  Email: \(.Emails[0].Value)",
        "  Created: \(.Meta.CreatedTimestamp)"
    '
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
        create|check|list|show)
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
            --username)
                USERNAME="$2"
                shift 2
                ;;
            --email)
                EMAIL_ADDRESS="$2"
                shift 2
                ;;
            --permission-set-name)
                PERMISSION_SET_NAME="$2"
                shift 2
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
        create)
            if [[ -z "${USERNAME}" ]]; then
                log_error "--username is required for create command"
                exit 1
            fi
            if [[ -z "${EMAIL_ADDRESS}" ]]; then
                log_error "--email is required for create command"
                exit 1
            fi
            if [[ -z "${PERMISSION_SET_NAME}" ]]; then
                log_error "--permission-set-name is required for create command"
                exit 1
            fi
            ;;
        check|show)
            if [[ -z "${USERNAME}" ]]; then
                log_error "--username is required for ${COMMAND} command"
                exit 1
            fi
            ;;
        list)
            # No arguments required
            ;;
    esac
}

main() {
    parse_arguments "$@"
    validate_inputs
    check_prerequisites
    get_aws_resources
    
    case "${COMMAND}" in
        create)
            create_command "${USERNAME}" "${EMAIL_ADDRESS}" "${PERMISSION_SET_NAME}"
            ;;
        check)
            check_command "${USERNAME}"
            ;;
        list)
            list_command
            ;;
        show)
            show_command "${USERNAME}"
            ;;
    esac
}

main "$@"

