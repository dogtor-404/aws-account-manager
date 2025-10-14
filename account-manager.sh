#!/bin/bash

################################################################################
# Account Manager - Multi-Account Orchestrator
#
# Main entry point for IAM Identity Center multi-account user environment management.
# Orchestrates: org-account.sh, identity-user.sh, permission-set.sh, budget.sh
#
# Usage:
#   ./account-manager.sh create --username NAME --email EMAIL [OPTIONS]
#   ./account-manager.sh list
#   ./account-manager.sh show --username NAME
#   ./account-manager.sh delete --username NAME
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
USER_EMAIL=""
PERMISSION_SET_CONFIG=""
BUDGET_AMOUNT="${DEFAULT_BUDGET}"
NOTIFICATION_EMAILS=""  # Extra notification emails (comma-separated, optional)
ADMIN_EMAIL=""  # Will be auto-detected from management account

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
Account Manager - Multi-Account Orchestrator

Simplified user environment creation: one command creates dedicated AWS account,
Identity Center user, permissions, and budget with automatic cost tracking.

Usage:
  $(basename "$0") create --username NAME --email EMAIL [OPTIONS]
  $(basename "$0") list
  $(basename "$0") show --username NAME
  $(basename "$0") delete --username NAME

Commands:
  create    Create complete user environment (account + user + permissions + budget)
  list      List all user environments
  show      Show details for a user environment
  delete    Delete user environment (with confirmation)

Options for 'create':
  --username NAME              Username for Identity Center user (e.g., alice)
  --email EMAIL                User's email (also used to auto-generate account email)
  --permission-set-config FILE Permission Set config (default: ${DEFAULT_PERMISSION_SET_CONFIG})
  --budget AMOUNT              Monthly budget in USD (default: ${DEFAULT_BUDGET})
  --notification-emails EMAILS Additional emails for budget alerts (comma-separated, optional)
                               Note: User and admin emails are always included

Examples:
  # Create user environment with defaults
  $(basename "$0") create \\
    --username alice \\
    --email alice@company.com

  # Account email auto-generated: alice+alice-aws@company.com

  # Create with custom budget
  $(basename "$0") create \\
    --username bob \\
    --email bob@company.com \\
    --budget 150

  # Account email auto-generated: bob+bob-aws@company.com

  # Create with additional notification emails
  $(basename "$0") create \\
    --username bob \\
    --email bob@company.com \\
    --notification-emails "finance@company.com,cto@company.com"

  # Notifications will be sent to: bob@company.com, admin@org.com, finance@company.com, cto@company.com

  # List all user environments
  $(basename "$0") list

  # Show user details
  $(basename "$0") show --username alice

  # Delete user environment
  $(basename "$0") delete --username alice

Workflow:
  1. Auto-generate unique account email using + notation
  2. Create AWS member account (e.g., alice)
  3. Create Identity Center user (alice)
  4. Create/verify Permission Set
  5. Assign Permission Set to user + account
  6. Create budget with LinkedAccount filter (automatic cost tracking)

Note: Account email is automatically generated from user email using + notation
      Example: user@domain.com → user+username-aws@domain.com
      All emails will be received at the user's email address.

EOF
}

################################################################################
# Core Functions
################################################################################

ensure_root_user() {
    log_info "Checking AWS identity..."
    
    local identity
    identity=$(aws sts get-caller-identity --output json 2>/dev/null)
    
    if [[ -z "${identity}" ]]; then
        log_error "Failed to get AWS identity. Please configure AWS credentials."
        exit 1
    fi
    
    local arn account_id
    arn=$(echo "${identity}" | jq -r '.Arn')
    account_id=$(echo "${identity}" | jq -r '.Account')
    
    # Check if running from management account (for Organizations)
    local org_info
    if ! org_info=$(aws organizations describe-organization --output json 2>&1); then
        log_error "Not running from AWS Organizations management account"
        log_error "This script requires Organizations management account access"
        exit 1
    fi
    
    local mgmt_account_id
    mgmt_account_id=$(echo "${org_info}" | jq -r '.Organization.MasterAccountId')
    
    if [[ "${account_id}" != "${mgmt_account_id}" ]]; then
        log_error "Must run from management account ${mgmt_account_id}"
        log_error "Currently using account ${account_id}"
        exit 1
    fi
    
    log_success "Running from management account: ${account_id}"
    
    # Auto-detect management account email for budget notifications
    local mgmt_email
    mgmt_email=$(echo "${org_info}" | jq -r '.Organization.MasterAccountEmail // empty')
    
    if [[ -n "${mgmt_email}" ]]; then
        ADMIN_EMAIL="${mgmt_email}"
        log_success "Management account email: ${mgmt_email}"
        log_info "Budget alerts will include admin email: ${mgmt_email}"
    else
        log_warning "Could not detect management account email"
    fi
}

ensure_scripts_executable() {
    local scripts=("org-account.sh" "identity-user.sh" "permission-set.sh" "budget.sh")
    
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

create_user_environment() {
    local username="$1"
    local user_email="$2"
    local budget="$3"
    local ps_config="$4"
    
    # Auto-generate account email from user email using + notation
    local account_email
    local email_user email_domain
    
    if [[ "${user_email}" =~ ^([^@]+)@(.+)$ ]]; then
        email_user="${BASH_REMATCH[1]}"
        email_domain="${BASH_REMATCH[2]}"
        account_email="${email_user}+${username}-aws@${email_domain}"
    else
        log_error "Invalid email format: ${user_email}"
        exit 1
    fi
    
    local account_name="${username}"
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "    Creating Multi-Account Environment for ${username}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    log_info "Configuration:"
    log_info "  Username:         ${username}"
    log_info "  User Email:       ${user_email}"
    log_info "  Account Name:     ${account_name}"
    log_info "  Account Email:    ${account_email} (auto-generated)"
    log_info "  Permission Set:   ${ps_config}"
    log_info "  Budget:           \$${budget}/month"
    echo ""
    
    # Step 0: Ensure Permission Set exists
    log_info "STEP 0/5: Checking Permission Set..."
    
    local ps_name
    ps_name=$(jq -r '.name' "${ps_config}")
    
    if "${SCRIPT_DIR}/permission-set.sh" check --name "${ps_name}" &>/dev/null; then
        log_success "Permission Set '${ps_name}' exists"
    else
        log_info "Permission Set '${ps_name}' not found, creating..."
        if ! "${SCRIPT_DIR}/permission-set.sh" create --config "${ps_config}"; then
            log_error "Failed to create Permission Set"
            exit 1
        fi
        log_success "Permission Set created"
    fi
    echo ""
    
    # Step 1: Create member account
    log_info "STEP 1/5: Creating AWS member account..."
    local account_id
    if ! account_id=$("${SCRIPT_DIR}/org-account.sh" create \
        --name "${account_name}" \
        --email "${account_email}"); then
        log_error "Failed to create account"
        exit 1
    fi
    log_success "Account created: ${account_id}"
    echo ""
    
    # Step 2: Create Identity Center user
    log_info "STEP 2/5: Creating Identity Center user..."
    local user_id
    if ! user_id=$("${SCRIPT_DIR}/identity-user.sh" create \
        --username "${username}" \
        --email "${user_email}"); then
        log_error "Failed to create user"
        exit 1
    fi
    log_success "User created: ${user_id}"
    echo ""
    
    # Step 3: Assign Permission Set
    log_info "STEP 3/5: Assigning Permission Set to account..."
    if ! "${SCRIPT_DIR}/permission-set.sh" assign \
        --user-id "${user_id}" \
        --account-id "${account_id}" \
        --permission-set "${ps_name}"; then
        log_error "Failed to assign permissions"
        exit 1
    fi
    log_success "Permissions assigned"
    echo ""
    
    # Step 4: Create budget
    log_info "STEP 4/5: Creating budget with automatic cost tracking..."
    local budget_name="${account_name}-budget"
    
    # Build notification emails list: user + admin + extras
    local notification_emails="${user_email}"
    if [[ -n "${ADMIN_EMAIL}" ]]; then
        notification_emails="${notification_emails},${ADMIN_EMAIL}"
    fi
    if [[ -n "${NOTIFICATION_EMAILS}" ]]; then
        notification_emails="${notification_emails},${NOTIFICATION_EMAILS}"
    fi
    
    log_info "Budget alerts will be sent to:"
    IFS=',' read -ra email_array <<< "${notification_emails}"
    for email in "${email_array[@]}"; do
        log_info "  • ${email}"
    done
    
    if ! "${SCRIPT_DIR}/budget.sh" create-linked \
        --account-id "${account_id}" \
        --name "${budget_name}" \
        --amount "${budget}" \
        --notification-emails "${notification_emails}"; then
        log_error "Failed to create budget"
        exit 1
    fi
    log_success "Budget created"
    echo ""
    
    # Final summary
    echo "═══════════════════════════════════════════════════════════════════"
    echo "    ✅ Environment Ready!"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "User Details:"
    echo "  Username:          ${username}"
    echo "  Email:             ${user_email}"
    echo "  User ID:           ${user_id}"
    echo ""
    echo "AWS Account:"
    echo "  Account Name:      ${account_name}"
    echo "  Account ID:        ${account_id}"
    echo "  Account Email:     ${account_email}"
    echo ""
    echo "Permissions:"
    echo "  Permission Set:    ${ps_name}"
    echo "  Status:            Assigned to account ${account_id}"
    echo ""
    echo "Budget:"
    echo "  Name:              ${budget_name}"
    echo "  Amount:            \$${budget}/month"
    echo "  Tracking:          LinkedAccount (automatic)"
    echo "  Alerts:            80%, 90%, 100%"
    echo ""
    echo "Next Steps for User:"
    echo "  1. Check email (${user_email}) for:"
    echo "     • IAM Identity Center activation link"
    echo "     • 3 budget alert confirmation emails"
    echo "  2. Click activation link and set password"
    echo "  3. Enable MFA (REQUIRED)"
    echo "  4. Confirm 3 budget alert subscriptions"
    echo "  5. Get SSO portal URL:"
    echo "     aws sso-admin list-instances --query 'Instances[0].[AccessUrl]' --output text"
    echo "  6. Login and select '${account_name}' account"
    echo ""
    echo "✨ All costs in account ${account_id} are automatically tracked!"
    echo "   No resource tagging required!"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    
    log_success "User environment creation completed successfully!"
}

list_user_environments() {
    log_info "Listing user environments..."
    
    # Get all Identity Center users
    local users
    if ! users=$("${SCRIPT_DIR}/identity-user.sh" list 2>/dev/null); then
        log_error "Failed to list users"
        exit 1
    fi
    
    echo ""
    echo "User Environments:"
    echo ""
    
    # Parse user list and find corresponding accounts
    # This is a simplified approach - assumes username naming convention
    local account_list
    account_list=$("${SCRIPT_DIR}/org-account.sh" list 2>/dev/null || echo "")
    
    if [[ -z "${account_list}" ]]; then
        log_warning "No accounts found"
        return 0
    fi
    
    echo "${account_list}"
}

show_user_environment() {
    local username="$1"
    local account_name="${username}"
    
    log_info "Getting details for user: ${username}"
    echo ""
    
    # Get user details
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Identity Center User"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    "${SCRIPT_DIR}/identity-user.sh" show --username "${username}" || log_warning "User not found"
    
    # Get account details
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  AWS Account"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local account_id
    if account_id=$("${SCRIPT_DIR}/org-account.sh" get-id --name "${account_name}" 2>/dev/null); then
        echo "  Account Name: ${account_name}"
        echo "  Account ID:   ${account_id}"
        
        # Get budget details
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Budget"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        "${SCRIPT_DIR}/budget.sh" show --name "${account_name}-budget" || log_warning "Budget not found"
        
        # Get permission assignments
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Permission Assignments"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        "${SCRIPT_DIR}/permission-set.sh" list-assignments --account-id "${account_id}" || log_warning "No assignments found"
    else
        log_warning "Account '${account_name}' not found"
    fi
    
    echo ""
}

delete_user_environment() {
    local username="$1"
    local account_name="${username}"
    local budget_name="${account_name}-budget"
    
    echo ""
    log_warning "═══════════════════════════════════════════════════════════════════"
    log_warning "  ⚠️  DELETE USER ENVIRONMENT"
    log_warning "═══════════════════════════════════════════════════════════════════"
    echo ""
    log_warning "This will delete the following for user: ${username}"
    echo "  • Identity Center user"
    echo "  • Permission Set assignments"
    echo "  • Budget (${budget_name})"
    echo "  • AWS Account (${account_name}) - OPTIONAL"
    echo ""
    echo -n "Are you sure you want to continue? Type 'yes' to confirm: "
    read -r confirm
    
    if [[ "${confirm}" != "yes" ]]; then
        log_info "Deletion cancelled"
        return 0
    fi
    
    echo ""
    log_info "Starting deletion process..."
    
    # Get IDs first
    local user_id account_id
    user_id=$("${SCRIPT_DIR}/identity-user.sh" get-id --username "${username}" 2>/dev/null || echo "")
    account_id=$("${SCRIPT_DIR}/org-account.sh" get-id --name "${account_name}" 2>/dev/null || echo "")
    
    # Delete budget
    if [[ -n "${account_id}" ]]; then
        log_info "Deleting budget..."
        aws budgets delete-budget \
            --account-id "$(aws sts get-caller-identity --query Account --output text)" \
            --budget-name "${budget_name}" 2>/dev/null || log_warning "Budget not found or already deleted"
    fi
    
    # Revoke permissions (get Permission Set name first)
    if [[ -n "${user_id}" ]] && [[ -n "${account_id}" ]]; then
        log_info "Revoking permissions..."
        local ps_name
        ps_name=$(jq -r '.name' "${PERMISSION_SET_CONFIG}")
        "${SCRIPT_DIR}/permission-set.sh" revoke \
            --user-id "${user_id}" \
            --account-id "${account_id}" \
            --permission-set "${ps_name}" 2>/dev/null || log_warning "Permissions not found or already revoked"
    fi
    
    # Delete user (this is safe as user can only access the one account)
    if [[ -n "${user_id}" ]]; then
        log_info "Deleting Identity Center user..."
        aws identitystore delete-user \
            --identity-store-id "$(aws sso-admin list-instances --query 'Instances[0].IdentityStoreId' --output text)" \
            --user-id "${user_id}" 2>/dev/null || log_warning "User not found or already deleted"
    fi
    
    # Ask about account deletion
    echo ""
    log_warning "⚠️  AWS Account Deletion"
    log_warning "Account: ${account_name} (${account_id})"
    echo ""
    log_warning "Note: AWS account deletion is a sensitive operation that:"
    log_warning "  • Requires the account to be in good standing"
    log_warning "  • Takes 90 days to complete"
    log_warning "  • Cannot be undone"
    echo ""
    echo -n "Delete AWS account? (yes/no): "
    read -r confirm_account
    
    if [[ "${confirm_account}" == "yes" ]]; then
        log_warning "AWS account deletion not implemented in this script"
        log_warning "To manually delete account ${account_id}:"
        log_warning "  1. Go to: AWS Console → Organizations → Accounts"
        log_warning "  2. Select account '${account_name}'"
        log_warning "  3. Click 'Close account'"
    else
        log_info "Keeping AWS account ${account_name}"
    fi
    
    echo ""
    log_success "User environment deletion completed"
    log_info "Remaining resources:"
    log_info "  • AWS Account: ${account_name} (if not manually deleted)"
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
        create|list|show|delete)
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
                USER_EMAIL="$2"
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
            --notification-emails)
                NOTIFICATION_EMAILS="$2"
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
            if [[ -z "${USER_EMAIL}" ]]; then
                log_error "--email is required for create command"
                exit 1
            fi
            # Validate email format
            if ! [[ "${USER_EMAIL}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                log_error "Invalid email format: ${USER_EMAIL}"
                exit 1
            fi
            if ! [[ "${BUDGET_AMOUNT}" =~ ^[0-9]+$ ]]; then
                log_error "Budget amount must be a positive integer"
                exit 1
            fi
            if [[ ! -f "${PERMISSION_SET_CONFIG}" ]]; then
                log_error "Permission Set config file not found: ${PERMISSION_SET_CONFIG}"
                exit 1
            fi
            ;;
        show|delete)
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
    ensure_root_user
    ensure_scripts_executable
    
    case "${COMMAND}" in
        create)
            create_user_environment "${USERNAME}" "${USER_EMAIL}" "${BUDGET_AMOUNT}" "${PERMISSION_SET_CONFIG}"
            ;;
        list)
            list_user_environments
            ;;
        show)
            show_user_environment "${USERNAME}"
            ;;
        delete)
            delete_user_environment "${USERNAME}"
            ;;
    esac
}

main "$@"
