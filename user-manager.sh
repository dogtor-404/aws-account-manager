#!/bin/bash

################################################################################
# User Manager - Main Orchestrator
#
# Main entry point for IAM Identity Center user lifecycle management.
# Orchestrates permission-set.sh, iam-user.sh, and budget.sh to provide
# complete user management workflows.
#
# Usage:
#   ./user-manager.sh create --username NAME --email EMAIL [OPTIONS]
#   ./user-manager.sh list-users
#   ./user-manager.sh list-permission-sets  
#   ./user-manager.sh list-budgets
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

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
DEFAULT_PERMISSION_SET_CONFIG="permission-sets/terraform-deployer.json"
DEFAULT_BUDGET=100

# Global variables
COMMAND=""
USERNAME=""
EMAIL_ADDRESS=""
PERMISSION_SET_CONFIG=""
BUDGET_AMOUNT="${DEFAULT_BUDGET}"

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
User Manager - IAM Identity Center Orchestrator

Usage:
  $(basename "$0") create --username NAME --email EMAIL [OPTIONS]
  $(basename "$0") list-users
  $(basename "$0") list-permission-sets
  $(basename "$0") list-budgets

Commands:
  create                 Create complete user setup (user + Permission Set + budget)
  list-users            List all IAM Identity Center users
  list-permission-sets  List all Permission Sets
  list-budgets          List all budgets

Options for 'create':
  --username NAME                Username for the IAM Identity Center user
  --email EMAIL                  Email address for user activation and notifications
  --permission-set-config FILE   Permission Set config file (default: ${DEFAULT_PERMISSION_SET_CONFIG})
  --budget AMOUNT                Monthly budget amount in USD (default: ${DEFAULT_BUDGET})

Examples:
  # Create user with defaults
  $(basename "$0") create \\
    --username Affyned-dev-user \\
    --email neoztcl@gmail.com

  # Create user with custom Permission Set and budget
  $(basename "$0") create \\
    --username dev-alice \\
    --email alice@company.com \\
    --permission-set-config permission-sets/custom.json \\
    --budget 150

  # List resources
  $(basename "$0") list-users
  $(basename "$0") list-permission-sets
  $(basename "$0") list-budgets

Workflow:
  1. Reads Permission Set configuration file
  2. Checks if Permission Set exists
     - If not exists: Creates Permission Set automatically
     - If exists: Skips creation
  3. Creates IAM Identity Center user
  4. Assigns Permission Set to user
  5. Creates budget with alerts

EOF
}

################################################################################
# Core Functions
################################################################################

ensure_root_user() {
    log_info "Checking AWS identity..."
    
    # Get current caller identity
    local identity
    identity=$(aws sts get-caller-identity --output json 2>/dev/null)
    
    if [[ -z "${identity}" ]]; then
        log_error "Failed to get AWS identity. Please configure AWS credentials."
        exit 1
    fi
    
    local arn user_id account_id
    arn=$(echo "${identity}" | jq -r '.Arn')
    user_id=$(echo "${identity}" | jq -r '.UserId')
    account_id=$(echo "${identity}" | jq -r '.Account')
    
    # Check if current user is root user
    # Root user ARN format: arn:aws:iam::ACCOUNT_ID:root
    if [[ "${arn}" =~ arn:aws:iam::[0-9]+:root ]]; then
        log_success "Running as AWS root user"
        log_success "Account ID: ${account_id}"
        return 0
    fi
    
    # Not root user - show error and guidance
    log_error "This script must be run by the AWS root user"
    log_error "Current identity: ${arn}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ⚠️  Root User Access Required"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "This script creates IAM Identity Center resources and requires"
    echo "root user (AWS account owner) permissions."
    echo ""
    echo "How to switch to root user:"
    echo ""
    echo "1. Sign out of current AWS session:"
    echo "   aws sso logout"
    echo ""
    echo "2. Login to AWS Console as root user:"
    echo "   - Go to: https://console.aws.amazon.com/"
    echo "   - Click: 'Sign in as Root user'"
    echo "   - Use: Account email and password"
    echo ""
    echo "3. Create root user access keys (if not exists):"
    echo "   - Console → IAM → My Security Credentials"
    echo "   - Create Access Key"
    echo ""
    echo "4. Configure AWS CLI with root credentials:"
    echo "   aws configure --profile root"
    echo "   # Enter root user access key and secret key"
    echo ""
    echo "5. Run this script with root profile:"
    echo "   AWS_PROFILE=root ./user-manager.sh create ..."
    echo ""
    echo "Or set as default:"
    echo "   export AWS_PROFILE=root"
    echo "   ./user-manager.sh create ..."
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    exit 1
}

ensure_scripts_executable() {
    local scripts=("permission-set.sh" "iam-user.sh" "budget.sh")
    
    for script in "${scripts[@]}"; do
        local script_path="${SCRIPT_DIR}/${script}"
        if [[ ! -f "${script_path}" ]]; then
            log_error "Required script not found: ${script}"
            exit 1
        fi
        
        if [[ ! -x "${script_path}" ]]; then
            log_info "Making ${script} executable..."
            chmod +x "${script_path}"
        fi
    done
}

create_user_command() {
    local username="$1"
    local email="$2"
    local ps_config_file="$3"
    local budget="$4"
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "           IAM User Creation Workflow"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    log_info "Configuration:"
    log_info "  Username: ${username}"
    log_info "  Email: ${email}"
    log_info "  Permission Set Config: ${ps_config_file}"
    log_info "  Budget: \$${budget}/month"
    echo ""
    
    # Validate config file exists
    if [[ ! -f "${ps_config_file}" ]]; then
        log_error "Permission Set config file not found: ${ps_config_file}"
        exit 1
    fi
    
    # Read Permission Set configuration
    log_info "Reading Permission Set configuration..."
    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed. Please install jq."
        exit 1
    fi
    
    local ps_name
    ps_name=$(jq -r '.name' "${ps_config_file}" 2>/dev/null)
    
    if [[ -z "${ps_name}" ]] || [[ "${ps_name}" == "null" ]]; then
        log_error "Failed to read Permission Set name from config file"
        exit 1
    fi
    
    log_success "Permission Set Name: ${ps_name}"
    echo ""
    
    # Step 1: Check and create Permission Set if needed
    log_info "STEP 1: Checking Permission Set..."
    if "${SCRIPT_DIR}/permission-set.sh" check --name "${ps_name}" &>/dev/null; then
        log_success "Permission Set '${ps_name}' already exists"
    else
        log_info "Permission Set '${ps_name}' not found, creating..."
        "${SCRIPT_DIR}/permission-set.sh" create --config "${ps_config_file}"
    fi
    echo ""
    
    # Step 2: Check and create user, then assign Permission Set
    log_info "STEP 2: Checking user..."
    if "${SCRIPT_DIR}/iam-user.sh" check --username "${username}" &>/dev/null; then
        log_success "User '${username}' already exists"
    else
        log_info "User '${username}' not found, creating and assigning Permission Set..."
        "${SCRIPT_DIR}/iam-user.sh" create \
            --username "${username}" \
            --email "${email}" \
            --permission-set-name "${ps_name}"
    fi
    echo ""
    
    # Step 3: Check and create budget
    log_info "STEP 3: Checking budget..."
    local budget_name="${username}-monthly-budget"
    if "${SCRIPT_DIR}/budget.sh" check --name "${budget_name}" &>/dev/null; then
        log_success "Budget '${budget_name}' already exists"
    else
        log_info "Budget '${budget_name}' not found, creating..."
        "${SCRIPT_DIR}/budget.sh" create \
            --name "${budget_name}" \
            --amount "${budget}" \
            --email "${email}"
    fi
    echo ""
    
    # Final summary
    echo "═══════════════════════════════════════════════════════════════════"
    echo "           Complete User Setup Summary"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "✅ All components created successfully!"
    echo ""
    echo "User Details:"
    echo "  Username:      ${username}"
    echo "  Email:         ${email}"
    echo ""
    echo "Permission Set:"
    echo "  Name:          ${ps_name}"
    echo "  Status:        Assigned"
    echo ""
    echo "Budget:"
    echo "  Name:          ${budget_name}"
    echo "  Amount:        \$${budget}/month"
    echo "  Alerts:        80%, 90%, 100%"
    echo ""
    echo "Next Steps for User (${email}):"
    echo "  1. Check email for AWS activation link"
    echo "  2. Set password via activation link"
    echo "  3. Enable MFA (REQUIRED) using authenticator app"
    echo "  4. Configure AWS CLI with SSO profile"
    echo "  5. Confirm 3 budget alert email subscriptions"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    
    log_success "User creation workflow completed successfully!"
}

list_users_command() {
    "${SCRIPT_DIR}/iam-user.sh" list
}

list_permission_sets_command() {
    log_info "Listing all Permission Sets..."
    
    # Get IAM Identity Center instance
    local instances
    instances=$(aws sso-admin list-instances --output json 2>/dev/null)
    
    if [[ -z "${instances}" ]] || [[ "$(echo "${instances}" | jq '.Instances | length')" -eq 0 ]]; then
        log_error "No IAM Identity Center instance found"
        exit 2
    fi
    
    local instance_arn
    instance_arn=$(echo "${instances}" | jq -r '.Instances[0].InstanceArn')
    
    local permission_sets
    permission_sets=$(aws sso-admin list-permission-sets \
        --instance-arn "${instance_arn}" \
        --output json)
    
    local ps_count
    ps_count=$(echo "${permission_sets}" | jq '.PermissionSets | length')
    
    if [[ "${ps_count}" -eq 0 ]]; then
        log_info "No Permission Sets found"
        return 0
    fi
    
    echo ""
    echo "Permission Sets (Total: ${ps_count}):"
    
    for ps_arn in $(echo "${permission_sets}" | jq -r '.PermissionSets[]'); do
        local ps_details
        ps_details=$(aws sso-admin describe-permission-set \
            --instance-arn "${instance_arn}" \
            --permission-set-arn "${ps_arn}" \
            --output json)
        
        echo "${ps_details}" | jq -r '
            "  - \(.PermissionSet.Name)",
            "    Description: \(.PermissionSet.Description)",
            "    Session: \(.PermissionSet.SessionDuration)"
        '
    done
}

list_budgets_command() {
    "${SCRIPT_DIR}/budget.sh" list
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
        create|list-users|list-permission-sets|list-budgets)
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
    
    # Set default for permission set config
    PERMISSION_SET_CONFIG="${DEFAULT_PERMISSION_SET_CONFIG}"
    
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
            --permission-set-config)
                PERMISSION_SET_CONFIG="$2"
                shift 2
                ;;
            --budget)
                BUDGET_AMOUNT="$2"
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
            if ! [[ "${BUDGET_AMOUNT}" =~ ^[0-9]+$ ]]; then
                log_error "Budget amount must be a positive integer"
                exit 1
            fi
            ;;
        list-users|list-permission-sets|list-budgets)
            # No arguments required
            ;;
    esac
}

main() {
    parse_arguments "$@"
    validate_inputs
    ensure_root_user
    ensure_scripts_executable
    
    case "${COMMAND}" in
        create)
            create_user_command "${USERNAME}" "${EMAIL_ADDRESS}" "${PERMISSION_SET_CONFIG}" "${BUDGET_AMOUNT}"
            ;;
        list-users)
            list_users_command
            ;;
        list-permission-sets)
            list_permission_sets_command
            ;;
        list-budgets)
            list_budgets_command
            ;;
    esac
}

main "$@"

