#!/bin/bash

################################################################################
# AWS Organizations Account Management Script
#
# Manages AWS Organizations member accounts creation and lifecycle
#
# Usage:
#   ./org-account.sh create --name NAME --email EMAIL
#   ./org-account.sh get-id --name NAME
#   ./org-account.sh list
#   ./org-account.sh check --account-id ID
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
ACCOUNT_NAME=""
ACCOUNT_EMAIL=""
ACCOUNT_ID=""
MANAGEMENT_ACCOUNT_ID=""

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
AWS Organizations Account Management Script

Usage:
  $(basename "$0") create --name NAME --email EMAIL
  $(basename "$0") get-id --name NAME
  $(basename "$0") list
  $(basename "$0") check --account-id ID

Commands:
  create    Create a new member account
  get-id    Get account ID by name
  list      List all member accounts
  check     Check if an account exists by ID

Options for 'create':
  --name NAME       Account name (e.g., alice)
  --email EMAIL     Unique email for the account (e.g., alice-aws@company.com)

Options for 'get-id':
  --name NAME       Account name to lookup

Options for 'check':
  --account-id ID   AWS account ID

Examples:
  # Create member account
  $(basename "$0") create --name alice --email alice-aws@company.com
  
  # Get account ID by name
  $(basename "$0") get-id --name alice
  
  # List all accounts
  $(basename "$0") list
  
  # Check if account exists
  $(basename "$0") check --account-id 123456789012

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

check_organizations_enabled() {
    log_info "Checking AWS Organizations status..."
    
    local org_info
    if ! org_info=$(aws organizations describe-organization --output json 2>&1); then
        if echo "${org_info}" | grep -q "AWSOrganizationsNotInUseException"; then
            log_error "AWS Organizations is not enabled"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ⚠️  AWS Organizations Required"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "This script requires AWS Organizations to be enabled."
            echo ""
            echo "To enable:"
            echo "1. Go to: https://console.aws.amazon.com/organizations/"
            echo "2. Click: 'Create Organization'"
            echo "3. Choose: 'Enable All Features'"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            exit 2
        else
            log_error "Failed to check Organizations: ${org_info}"
            exit 1
        fi
    fi
    
    MANAGEMENT_ACCOUNT_ID=$(echo "${org_info}" | jq -r '.Organization.MasterAccountId')
    log_success "Organizations enabled. Management account: ${MANAGEMENT_ACCOUNT_ID}"
}

################################################################################
# Core Functions
################################################################################

create_member_account() {
    local name="$1"
    local email="$2"
    
    log_info "Creating member account: ${name}"
    log_info "  Email: ${email}"
    
    # Check if account with same name already exists
    log_info "Checking for existing account..."
    local existing_id
    existing_id=$(aws organizations list-accounts \
        --query "Accounts[?Name=='${name}' && Status=='ACTIVE'].Id" \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "${existing_id}" ]]; then
        log_warning "Account '${name}' already exists"
        log_success "Account ID: ${existing_id}"
        echo "${existing_id}"
        return 0
    fi
    
    # Create new account
    log_info "Initiating account creation..."
    local result
    result=$(aws organizations create-account \
        --email "${email}" \
        --account-name "${name}" \
        --output json)
    
    local request_id
    request_id=$(echo "${result}" | jq -r '.CreateAccountStatus.Id')
    
    log_info "Request ID: ${request_id}"
    log_info "Waiting for account creation (typically 2-5 minutes)..."
    
    # Poll for completion
    local max_attempts=60
    local attempt=0
    
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        local status_result
        status_result=$(aws organizations describe-create-account-status \
            --create-account-request-id "${request_id}" \
            --output json)
        
        local status account_id
        status=$(echo "${status_result}" | jq -r '.CreateAccountStatus.State')
        
        case "${status}" in
            "SUCCEEDED")
                account_id=$(echo "${status_result}" | jq -r '.CreateAccountStatus.AccountId')
                echo "" >&2
                log_success "Account created successfully!"
                log_success "Account Name: ${name}"
                log_success "Account ID: ${account_id}"
                log_success "Email: ${email}"
                echo "${account_id}"
                return 0
                ;;
            "FAILED")
                local failure_reason
                failure_reason=$(echo "${status_result}" | jq -r '.CreateAccountStatus.FailureReason // "Unknown"')
                echo "" >&2
                log_error "Account creation failed: ${failure_reason}"
                exit 2
                ;;
            "IN_PROGRESS")
                echo -n "." >&2
                sleep 5
                ((attempt++))
                ;;
            *)
                echo -n "?" >&2
                sleep 5
                ((attempt++))
                ;;
        esac
    done
    
    echo "" >&2
    log_error "Account creation timed out after 5 minutes"
    exit 2
}

get_account_id_by_name() {
    local name="$1"
    
    local account_id
    account_id=$(aws organizations list-accounts \
        --query "Accounts[?Name=='${name}' && Status=='ACTIVE'].Id" \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "${account_id}" ]]; then
        echo "${account_id}"
        return 0
    else
        log_error "Account '${name}' not found" >&2
        return 1
    fi
}

list_accounts() {
    log_info "Listing all member accounts..."
    
    local accounts
    accounts=$(aws organizations list-accounts --output json)
    
    local account_count
    account_count=$(echo "${accounts}" | jq '[.Accounts[] | select(.Status == "ACTIVE")] | length')
    
    if [[ "${account_count}" -eq 0 ]]; then
        log_info "No active member accounts found"
        return 0
    fi
    
    echo ""
    echo "Active Accounts (Total: ${account_count}):"
    echo "${accounts}" | jq -r '.Accounts[] | select(.Status == "ACTIVE") | 
        "  - \(.Name) [\(.Id)]",
        "    Email: \(.Email)"
    '
}

check_account_exists() {
    local account_id="$1"
    
    log_info "Checking account ${account_id}..."
    
    local account_info
    account_info=$(aws organizations describe-account \
        --account-id "${account_id}" \
        --output json 2>/dev/null || echo '{}')
    
    local status
    status=$(echo "${account_info}" | jq -r '.Account.Status // ""')
    
    if [[ "${status}" == "ACTIVE" ]]; then
        log_success "Account exists and is active"
        echo ""
        echo "Account Details:"
        echo "${account_info}" | jq -r '
            "  Account ID: \(.Account.Id)",
            "  Name: \(.Account.Name)",
            "  Email: \(.Account.Email)",
            "  Status: \(.Account.Status)"
        '
        return 0
    else
        log_error "Account not found or not active"
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
        create|get-id|list|check)
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
            --name)
                ACCOUNT_NAME="$2"
                shift 2
                ;;
            --email)
                ACCOUNT_EMAIL="$2"
                shift 2
                ;;
            --account-id)
                ACCOUNT_ID="$2"
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
            if [[ -z "${ACCOUNT_NAME}" ]]; then
                log_error "--name is required for create command"
                exit 1
            fi
            if [[ -z "${ACCOUNT_EMAIL}" ]]; then
                log_error "--email is required for create command"
                exit 1
            fi
            # Validate email format
            if ! [[ "${ACCOUNT_EMAIL}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                log_error "Invalid email format: ${ACCOUNT_EMAIL}"
                exit 1
            fi
            ;;
        get-id)
            if [[ -z "${ACCOUNT_NAME}" ]]; then
                log_error "--name is required for get-id command"
                exit 1
            fi
            ;;
        check)
            if [[ -z "${ACCOUNT_ID}" ]]; then
                log_error "--account-id is required for check command"
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
    check_organizations_enabled
    
    case "${COMMAND}" in
        create)
            create_member_account "${ACCOUNT_NAME}" "${ACCOUNT_EMAIL}"
            ;;
        get-id)
            get_account_id_by_name "${ACCOUNT_NAME}"
            ;;
        list)
            list_accounts
            ;;
        check)
            check_account_exists "${ACCOUNT_ID}"
            ;;
    esac
}

main "$@"

