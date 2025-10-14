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

# Load environment variables if .env exists
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    source "${SCRIPT_DIR}/.env"
fi

# Default values (with fallback if not set in .env)
DEFAULT_PERMISSION_SET_CONFIG="${DEFAULT_PERMISSION_SET_CONFIG:-dev}"
DEFAULT_BUDGET="${DEFAULT_BUDGET:-100}"
DEFAULT_NOTIFICATION_EMAILS="${DEFAULT_NOTIFICATION_EMAILS:-}"

# Global variables
COMMAND=""
USERNAME=""
USER_EMAIL=""
PERMISSION_SET_CONFIGS=""  # Comma-separated permission set names (e.g., "terraform-deployer,administrator")
BUDGET_AMOUNT="${DEFAULT_BUDGET}"
NOTIFICATION_EMAILS="${DEFAULT_NOTIFICATION_EMAILS}"  # Extra notification emails (comma-separated, optional)
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
  --permission-sets NAMES      Permission Set names, comma-separated (default: ${DEFAULT_PERMISSION_SET_CONFIG})
                               
                               ⚠️  Permission Set Assignment Rules:
                               • 'admin' → Management Account (organization-wide access)
                               • Others (dev, terraform-deployer, etc.) → Member Account
                               
                               Examples:
                               • admin              → Management Account only
                               • dev                → Member Account only
                               • "admin,dev"        → BOTH accounts (dual assignment)
                               
  --budget AMOUNT              Monthly budget in USD (default: ${DEFAULT_BUDGET})
                               Note: Only applies to member account (not management)
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

  # Create with multiple permission sets
  $(basename "$0") create \\
    --username charlie \\
    --email charlie@company.com \\
    --permission-sets "terraform-deployer,administrator"

  # User will have both TerraformDeployerPermissions and AdministratorPermissions permissions

  # Create organization administrator (NO dedicated account)
  $(basename "$0") create \\
    --username org-admin \\
    --email admin@company.com \\
    --permission-sets admin

  # User assigned to Management Account only, no budget tracking

  # Create dual-access user (organization admin + sandbox account)
  $(basename "$0") create \\
    --username power-user \\
    --email power@company.com \\
    --permission-sets "admin,dev" \\
    --budget 200

  # User has BOTH: Management Account access + dedicated sandbox with budget

  # List all user environments
  $(basename "$0") list

  # Show user details
  $(basename "$0") show --username alice

  # Delete user environment
  $(basename "$0") delete --username alice

Workflow:
  1. Parse and classify permission sets:
     • 'admin' → management account category
     • Others → member account category
  2. Create member account (if non-admin permission sets exist)
  3. Create Identity Center user
  4. Assign admin permissions to Management Account (if admin specified)
  5. Assign other permissions to member account (if created)
  6. Create budget for member account (if created)

Permission Assignment Examples:
  • --permission-sets admin
    → User to Management Account only (no member account)
  
  • --permission-sets dev
    → Create member account, assign dev to it
  
  • --permission-sets "admin,dev"
    → Create member account, assign admin to Management, dev to member account

Note: Account email is automatically generated from user email using + notation
      Example: user@domain.com → user+username-aws@domain.com
      All emails will be received at the user's email address.
      (Not applicable for admin users - no dedicated account created)

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

################################################################################
# Permission Set Classification and Utility Functions
################################################################################

# Classify permission sets into management account and member account categories
# Sets global arrays: mgmt_ps_configs, member_ps_configs
classify_permission_sets() {
    local ps_config_files=("$@")
    
    mgmt_ps_configs=()
    member_ps_configs=()
    
    for ps_config in "${ps_config_files[@]}"; do
        local ps_name
        ps_name=$(jq -r '.name' "${ps_config}")
        
        # Admin permission set goes to management account
        if [[ "${ps_name}" == "AdministratorPermissions" ]]; then
            mgmt_ps_configs+=("${ps_config}")
        else
            member_ps_configs+=("${ps_config}")
        fi
    done
}

# Determine if member account should be created based on permission sets
should_create_member_account() {
    local member_ps_count=$1
    [[ ${member_ps_count} -gt 0 ]]
}

################################################################################
# User Environment Creation - Sub-functions
################################################################################

ensure_permission_sets_exist() {
    local all_ps_configs=("${mgmt_ps_configs[@]}" "${member_ps_configs[@]}")
    
    log_info "STEP 0: Checking ${#all_ps_configs[@]} Permission Set(s)..."
    
    local ps_name
    for ps_config in "${all_ps_configs[@]}"; do
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
    done
    echo ""
}

create_member_account_step() {
    log_info "STEP 1: Creating AWS member account..."
    
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
    
    local account_id
    if ! account_id=$("${SCRIPT_DIR}/org-account.sh" create \
        --name "${username}" \
        --email "${account_email}"); then
        log_error "Failed to create account"
        exit 1
    fi
    
    log_success "Account created: ${account_id}"
    echo "${account_id}"
}

create_identity_center_user_step() {
    log_info "STEP 2: Creating Identity Center user..."
    
    local user_id
    if ! user_id=$("${SCRIPT_DIR}/identity-user.sh" create \
        --username "${username}" \
        --email "${user_email}"); then
        log_error "Failed to create user"
        exit 1
    fi
    
    log_success "User created: ${user_id}"
    echo "${user_id}"
}

assign_admin_permission_to_management_account() {
    log_info "STEP 3: Assigning ${#mgmt_ps_configs[@]} admin permission(s) to Management Account..."
    
    local mgmt_account_id
    mgmt_account_id=$(aws organizations describe-organization --query 'Organization.MasterAccountId' --output text)
    
    local ps_name
    for ps_config in "${mgmt_ps_configs[@]}"; do
        ps_name=$(jq -r '.name' "${ps_config}")
        if ! "${SCRIPT_DIR}/permission-set.sh" assign \
            --user-id "${user_id}" \
            --account-id "${mgmt_account_id}" \
            --permission-set "${ps_name}"; then
            log_error "Failed to assign permission set '${ps_name}' to management account"
            exit 1
        fi
        log_success "Permission Set '${ps_name}' assigned to Management Account"
    done
    echo ""
}

assign_permissions_to_member_account() {
    log_info "STEP 4: Assigning ${#member_ps_configs[@]} permission(s) to member account..."
    
    local ps_name
    for ps_config in "${member_ps_configs[@]}"; do
        ps_name=$(jq -r '.name' "${ps_config}")
        if ! "${SCRIPT_DIR}/permission-set.sh" assign \
            --user-id "${user_id}" \
            --account-id "${account_id}" \
            --permission-set "${ps_name}"; then
            log_error "Failed to assign permission set '${ps_name}' to member account"
            exit 1
        fi
        log_success "Permission Set '${ps_name}' assigned to member account"
    done
    echo ""
}

create_budget_step() {
    log_info "STEP 5: Creating budget with automatic cost tracking..."
    
    local budget_name="${username}-budget"
    
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
}

print_configuration_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    
    if [[ ${#mgmt_ps_configs[@]} -gt 0 && ${#member_ps_configs[@]} -gt 0 ]]; then
        echo "    Creating Dual-Access Environment for ${username}"
    elif [[ ${#mgmt_ps_configs[@]} -gt 0 ]]; then
        echo "    Creating Organization Administrator: ${username}"
    else
        echo "    Creating Multi-Account Environment for ${username}"
    fi
    
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    
    log_info "Configuration:"
    log_info "  Username:         ${username}"
    log_info "  User Email:       ${user_email}"
    
    if [[ ${#mgmt_ps_configs[@]} -gt 0 ]]; then
        log_info "  Management Access: YES (${#mgmt_ps_configs[@]} permission set(s))"
        for ps_config in "${mgmt_ps_configs[@]}"; do
            local ps_name
            ps_name=$(jq -r '.name' "${ps_config}")
            log_info "    • ${ps_name} → Management Account"
        done
    fi
    
    if [[ "${create_member_account}" == "true" ]]; then
        log_info "  Member Account:   ${username}"
        log_info "  Member Permissions: ${#member_ps_configs[@]} permission set(s)"
        for ps_config in "${member_ps_configs[@]}"; do
            local ps_name
            ps_name=$(jq -r '.name' "${ps_config}")
            log_info "    • ${ps_name} → Member Account"
        done
        log_info "  Budget:           \$${budget}/month"
    else
        log_warning "  Member Account:   NONE (management account only)"
        log_warning "  Budget:           NONE (no dedicated account)"
    fi
    
    echo ""
}

print_final_summary() {
    echo "═══════════════════════════════════════════════════════════════════"
    echo "    ✅ Environment Ready!"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "User Details:"
    echo "  Username:          ${username}"
    echo "  Email:             ${user_email}"
    echo "  User ID:           ${user_id}"
    echo ""
    
    if [[ ${#mgmt_ps_configs[@]} -gt 0 ]]; then
        local mgmt_account_id
        mgmt_account_id=$(aws organizations describe-organization --query 'Organization.MasterAccountId' --output text)
        
        echo "Management Account Access:"
        echo "  Account ID:        ${mgmt_account_id}"
        echo "  Permissions:"
        for ps_config in "${mgmt_ps_configs[@]}"; do
            local ps_name
            ps_name=$(jq -r '.name' "${ps_config}")
            echo "    • ${ps_name}"
        done
        echo "  Capabilities:"
        echo "    ✅ Manage AWS Organizations"
        echo "    ✅ Create/delete member accounts"
        echo "    ✅ Manage IAM Identity Center"
        echo "    ✅ Run account-manager.sh script"
        echo ""
    fi
    
    if [[ "${create_member_account}" == "true" ]]; then
        echo "Member Account:"
        echo "  Account Name:      ${username}"
        echo "  Account ID:        ${account_id}"
        echo "  Permissions:"
        for ps_config in "${member_ps_configs[@]}"; do
            local ps_name
            ps_name=$(jq -r '.name' "${ps_config}")
            echo "    • ${ps_name}"
        done
        echo ""
        echo "Budget:"
        echo "  Name:              ${username}-budget"
        echo "  Amount:            \$${budget}/month"
        echo "  Tracking:          LinkedAccount (automatic)"
        echo "  Alerts:            80%, 90%, 100%"
        echo ""
    fi
    
    echo "Next Steps for User:"
    echo "  1. Check email (${user_email}) for:"
    echo "     • IAM Identity Center activation link"
    if [[ "${create_member_account}" == "true" ]]; then
        echo "     • Budget alert confirmation emails"
    fi
    echo "  2. Click activation link and set password"
    echo "  3. Enable MFA (REQUIRED)"
    echo "  4. Get SSO portal URL:"
    echo "     aws sso-admin list-instances --query 'Instances[0].[AccessUrl]' --output text"
    echo "  5. Login and select account:"
    if [[ ${#mgmt_ps_configs[@]} -gt 0 ]]; then
        echo "     • 'Management' account (organization admin)"
    fi
    if [[ "${create_member_account}" == "true" ]]; then
        echo "     • '${username}' account (dedicated sandbox)"
    fi
    echo ""
    
    if [[ "${create_member_account}" == "true" ]]; then
        echo "✨ All costs in account ${account_id} are automatically tracked!"
        echo "   No resource tagging required!"
        echo ""
    fi
    
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    
    log_success "User environment creation completed successfully!"
}

create_user_environment() {
    local username="$1"
    local user_email="$2"
    local budget="$3"
    local permission_sets="$4"  # Comma-separated permission set names
    
    # Parse comma-separated permission sets and build config file paths
    IFS=',' read -ra ps_names <<< "${permission_sets}"
    local ps_config_files=()
    for ps_name in "${ps_names[@]}"; do
        # Trim whitespace
        ps_name=$(echo "${ps_name}" | xargs)
        ps_config_files+=("permission-sets/${ps_name}.json")
    done
    
    # Classify permission sets into management and member categories
    classify_permission_sets "${ps_config_files[@]}"
    
    # Determine if we need to create a member account
    local create_member_account=false
    if should_create_member_account "${#member_ps_configs[@]}"; then
        create_member_account=true
    fi
    
    # Print configuration summary
    print_configuration_summary
    
    # Step 0: Ensure all permission sets exist
    ensure_permission_sets_exist
    
    # Step 1: Create member account (if needed)
    local account_id=""
    if [[ "${create_member_account}" == "true" ]]; then
        account_id=$(create_member_account_step)
        echo ""
    fi
    
    # Step 2: Create Identity Center user
    local user_id
    user_id=$(create_identity_center_user_step)
    echo ""
    
    # Step 3: Assign admin permissions to management account (if applicable)
    if [[ ${#mgmt_ps_configs[@]} -gt 0 ]]; then
        assign_admin_permission_to_management_account
    fi
    
    # Step 4: Assign permissions to member account (if created)
    if [[ "${create_member_account}" == "true" ]]; then
        assign_permissions_to_member_account
    fi
    
    # Step 5: Create budget (if member account was created)
    if [[ "${create_member_account}" == "true" ]]; then
        create_budget_step
    fi
    
    # Print final summary
    print_final_summary
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
    
    # Get user ID
    local user_id
    user_id=$("${SCRIPT_DIR}/identity-user.sh" get-id --username "${username}" 2>/dev/null || echo "")
    
    if [[ -z "${user_id}" ]]; then
        echo ""
        log_error "User '${username}' not found"
        return 1
    fi
    
    # Get management account ID
    local mgmt_account_id
    mgmt_account_id=$(aws organizations describe-organization --query 'Organization.MasterAccountId' --output text 2>/dev/null)
    
    # Check for management account assignments
    local has_mgmt_assignment=false
    if [[ -n "${mgmt_account_id}" ]]; then
        if "${SCRIPT_DIR}/permission-set.sh" list-assignments --account-id "${mgmt_account_id}" 2>&1 | grep "${user_id}" > /dev/null 2>&1; then
            has_mgmt_assignment=true
        fi
    fi
    
    # Check for member account
    local account_id
    account_id=$("${SCRIPT_DIR}/org-account.sh" get-id --name "${account_name}" 2>/dev/null || echo "")
    local has_member_account=false
    if [[ -n "${account_id}" ]]; then
        has_member_account=true
    fi
    
    # Show management account access (if exists)
    if [[ "${has_mgmt_assignment}" == "true" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Management Account Access"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Account ID:        ${mgmt_account_id}"
        echo "  Role:              Organization Administrator"
        echo ""
        echo "  Permission Assignments:"
        local mgmt_assignments
        mgmt_assignments=$("${SCRIPT_DIR}/permission-set.sh" list-assignments --account-id "${mgmt_account_id}" 2>&1)
        if echo "${mgmt_assignments}" | grep "${user_id}" > /dev/null 2>&1; then
            echo "${mgmt_assignments}" | grep -B 2 "${user_id}" | sed 's/^/    /'
        else
            echo "    (none found)"
        fi
    fi
    
    # Show member account (if exists)
    if [[ "${has_member_account}" == "true" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Member Account"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Account Name:      ${account_name}"
        echo "  Account ID:        ${account_id}"
        
        # Get permission assignments
        echo ""
        echo "  Permission Assignments:"
        local member_assignments
        member_assignments=$("${SCRIPT_DIR}/permission-set.sh" list-assignments --account-id "${account_id}" 2>&1)
        if echo "${member_assignments}" | grep "${user_id}" > /dev/null 2>&1; then
            echo "${member_assignments}" | grep -B 2 "${user_id}" | sed 's/^/    /'
        else
            echo "    (none found)"
        fi
        
        # Get budget details
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Budget"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        "${SCRIPT_DIR}/budget.sh" show --name "${account_name}-budget" 2>/dev/null || log_warning "Budget not found"
    fi
    
    # Summary
    if [[ "${has_mgmt_assignment}" == "false" && "${has_member_account}" == "false" ]]; then
        echo ""
        log_warning "User '${username}' has no account assignments"
    fi
    
    echo ""
}

delete_user_environment() {
    local username="$1"
    local account_name="${username}"
    local budget_name="${account_name}-budget"
    
    # Get user ID
    local user_id
    user_id=$("${SCRIPT_DIR}/identity-user.sh" get-id --username "${username}" 2>/dev/null || echo "")
    
    if [[ -z "${user_id}" ]]; then
        log_error "User '${username}' not found"
        return 1
    fi
    
    # Get management account ID
    local mgmt_account_id
    mgmt_account_id=$(aws organizations describe-organization --query 'Organization.MasterAccountId' --output text 2>/dev/null)
    
    # Check for management account assignments
    local has_mgmt_assignment=false
    if [[ -n "${mgmt_account_id}" ]]; then
        if "${SCRIPT_DIR}/permission-set.sh" list-assignments --account-id "${mgmt_account_id}" 2>&1 | grep "${user_id}" > /dev/null 2>&1; then
            has_mgmt_assignment=true
        fi
    fi
    
    # Check for member account
    local account_id
    account_id=$("${SCRIPT_DIR}/org-account.sh" get-id --name "${account_name}" 2>/dev/null || echo "")
    local has_member_account=false
    if [[ -n "${account_id}" ]]; then
        has_member_account=true
    fi
    
    echo ""
    log_warning "═══════════════════════════════════════════════════════════════════"
    log_warning "  ⚠️  DELETE USER ENVIRONMENT"
    log_warning "═══════════════════════════════════════════════════════════════════"
    echo ""
    log_warning "This will delete the following for user: ${username}"
    echo ""
    echo "  • Identity Center user"
    
    if [[ "${has_mgmt_assignment}" == "true" ]]; then
        echo "  • Management account permission assignments (auto-cleaned)"
        log_warning "    ⚠️  User has organization-wide administrative access!"
    fi
    
    if [[ "${has_member_account}" == "true" ]]; then
        echo "  • Member account budget (${budget_name})"
        echo "  • Member AWS account (${account_name}) - OPTIONAL"
    fi
    
    echo ""
    echo -n "Are you sure you want to continue? Type 'yes' to confirm: "
    read -r confirm
    
    if [[ "${confirm}" != "yes" ]]; then
        log_info "Deletion cancelled"
        return 0
    fi
    
    echo ""
    log_info "Starting deletion process..."
    
    # Delete budget (if member account exists)
    if [[ "${has_member_account}" == "true" ]]; then
        log_info "Deleting budget..."
        aws budgets delete-budget \
            --account-id "$(aws sts get-caller-identity --query Account --output text)" \
            --budget-name "${budget_name}" 2>/dev/null || log_warning "Budget not found or already deleted"
    fi
    
    # Delete user (AWS will automatically clean up ALL permission set assignments)
    log_info "Deleting Identity Center user..."
    if [[ "${has_mgmt_assignment}" == "true" ]]; then
        log_info "  → Management account assignments will be auto-cleaned"
    fi
    if [[ "${has_member_account}" == "true" ]]; then
        log_info "  → Member account assignments will be auto-cleaned"
    fi
    
    aws identitystore delete-user \
        --identity-store-id "$(aws sso-admin list-instances --query 'Instances[0].IdentityStoreId' --output text)" \
        --user-id "${user_id}" 2>/dev/null || log_warning "User not found or already deleted"
    
    # Ask about member account deletion (if exists)
    if [[ "${has_member_account}" == "true" ]]; then
        echo ""
        log_warning "⚠️  AWS Member Account Deletion"
        log_warning "Account: ${account_name} (${account_id})"
        echo ""
        log_warning "Note: AWS account deletion is a sensitive operation that:"
        log_warning "  • Requires the account to be in good standing"
        log_warning "  • Takes 90 days to complete"
        log_warning "  • Cannot be undone"
        echo ""
        echo -n "Delete AWS member account? (yes/no): "
        read -r confirm_account
        
        if [[ "${confirm_account}" == "yes" ]]; then
            log_warning "AWS account deletion not implemented in this script"
            log_warning "To manually delete account ${account_id}:"
            log_warning "  1. Go to: AWS Console → Organizations → Accounts"
            log_warning "  2. Select account '${account_name}'"
            log_warning "  3. Click 'Close account'"
        else
            log_info "Keeping AWS member account ${account_name}"
        fi
    fi
    
    echo ""
    log_success "User environment deletion completed"
    
    if [[ "${has_member_account}" == "true" ]]; then
        log_info "Remaining resources:"
        log_info "  • AWS Member Account: ${account_name} (if not manually deleted)"
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
            --permission-sets)
                PERMISSION_SET_CONFIGS="$2"
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
    
    # Set default permission sets if none specified
    if [[ -z "${PERMISSION_SET_CONFIGS}" ]]; then
        PERMISSION_SET_CONFIGS="${DEFAULT_PERMISSION_SET_CONFIG}"
    fi
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
            # Validate permission set config files exist
            IFS=',' read -ra ps_names <<< "${PERMISSION_SET_CONFIGS}"
            for ps_name in "${ps_names[@]}"; do
                ps_name=$(echo "${ps_name}" | xargs)
                local config_file="permission-sets/${ps_name}.json"
                if [[ ! -f "${config_file}" ]]; then
                    log_error "Permission Set config file not found: ${config_file}"
                    exit 1
                fi
            done
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
            create_user_environment "${USERNAME}" "${USER_EMAIL}" "${BUDGET_AMOUNT}" "${PERMISSION_SET_CONFIGS}"
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
