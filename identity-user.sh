#!/bin/bash

################################################################################
# IAM Identity Center User Management Script
#
# Manages IAM Identity Center users (identity only, no permission assignment)
#
# Usage:
#   ./identity-user.sh create --username NAME --email EMAIL
#   ./identity-user.sh get-id --username NAME
#   ./identity-user.sh list
#   ./identity-user.sh show --username NAME
#   ./identity-user.sh check --username NAME
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
SSO_INSTANCE_ARN=""
IDENTITY_STORE_ID=""

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
  $(basename "$0") create --username NAME --email EMAIL
  $(basename "$0") get-id --username NAME
  $(basename "$0") list
  $(basename "$0") show --username NAME
  $(basename "$0") check --username NAME

Commands:
  create    Create a new Identity Center user
  get-id    Get user ID by username
  list      List all users
  show      Show user details
  check     Check if a user exists

Options:
  --username NAME   Username for the IAM Identity Center user
  --email EMAIL     Email address for user activation

Examples:
  # Create user
  $(basename "$0") create --username alice --email alice@company.com
  
  # Get user ID
  $(basename "$0") get-id --username alice
  
  # List all users
  $(basename "$0") list
  
  # Show user details
  $(basename "$0") show --username alice

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

get_identity_center_resources() {
    log_info "Discovering Identity Center resources..."
    
    # Get IAM Identity Center instance
    local instances
    instances=$(aws sso-admin list-instances --output json 2>/dev/null)
    
    if [[ -z "${instances}" ]] || [[ "$(echo "${instances}" | jq '.Instances | length')" -eq 0 ]]; then
        log_error "No IAM Identity Center instance found"
        log_error "Please enable IAM Identity Center first"
        exit 2
    fi
    
    SSO_INSTANCE_ARN=$(echo "${instances}" | jq -r '.Instances[0].InstanceArn')
    IDENTITY_STORE_ID=$(echo "${instances}" | jq -r '.Instances[0].IdentityStoreId')
    
    log_success "Identity Store ID: ${IDENTITY_STORE_ID}"
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

create_identity_center_user() {
    local username="$1"
    local email="$2"
    
    log_info "Creating Identity Center user: ${username}..."
    log_info "  Email: ${email}"
    
    # Check if user already exists
    if user_id=$(check_user_exists "${username}"); then
        log_warning "User '${username}' already exists"
        log_success "User ID: ${user_id}"
        echo "${user_id}"
        return 0
    fi
    
    # Extract given name and family name from username
    local given_name family_name
    if [[ "${username}" =~ ^([^-]+)-(.+)$ ]]; then
        given_name="${BASH_REMATCH[1]}"
        family_name="${BASH_REMATCH[2]}"
    else
        given_name="${username}"
        family_name="User"
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
    
    log_success "User created successfully"
    log_success "User ID: ${user_id}"
    log_success "Activation email will be sent to: ${email}"
    
    echo "${user_id}"
}

get_user_id_by_username() {
    local username="$1"
    
    if user_id=$(check_user_exists "${username}"); then
        echo "${user_id}"
        return 0
    else
        log_error "User '${username}' not found" >&2
        return 1
    fi
}

list_users() {
    log_info "Listing all Identity Center users..."
    
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
    echo "Identity Center Users (Total: ${user_count}):"
    echo "${users}" | jq -r '.Users[] | 
        "  - \(.UserName)",
        "    Name: \(.DisplayName)",
        "    Email: \(.Emails[0].Value)",
        "    User ID: \(.UserId)"
    '
}

show_user() {
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
        "  Username:      \(.UserName)",
        "  User ID:       \(.UserId)",
        "  Display Name:  \(.DisplayName)",
        "  Email:         \(.Emails[0].Value)",
        "  Created:       \(.Meta.CreatedTimestamp)"
    '
}

check_user_command() {
    local username="$1"
    
    if user_id=$(check_user_exists "${username}"); then
        log_success "User '${username}' exists" >&2
        log_success "User ID: ${user_id}" >&2
        return 0
    else
        log_error "User '${username}' not found" >&2
        return 1
    fi
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
        create|get-id|list|show|check)
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
            ;;
        get-id|show|check)
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
    get_identity_center_resources
    
    case "${COMMAND}" in
        create)
            create_identity_center_user "${USERNAME}" "${EMAIL_ADDRESS}"
            ;;
        get-id)
            get_user_id_by_username "${USERNAME}"
            ;;
        list)
            list_users
            ;;
        show)
            show_user "${USERNAME}"
            ;;
        check)
            check_user_command "${USERNAME}"
            ;;
    esac
}

main "$@"

