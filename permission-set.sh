#!/bin/bash

################################################################################
# Permission Set Management Script
#
# Unified management of IAM Identity Center Permission Sets:
# - Definition (create, list, show, check)
# - Assignment (assign to user + account, revoke, list assignments)
#
# Usage:
#   # Definition Management
#   ./permission-set.sh create --config CONFIG_FILE
#   ./permission-set.sh list
#   ./permission-set.sh check --name NAME
#   ./permission-set.sh show --config CONFIG_FILE
#
#   # Assignment Management
#   ./permission-set.sh assign --user-id ID --account-id ID --permission-set NAME
#   ./permission-set.sh revoke --user-id ID --account-id ID --permission-set NAME
#   ./permission-set.sh list-assignments --account-id ID
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
PERMISSION_SET_NAME=""
USER_ID=""
ACCOUNT_ID=""
SSO_INSTANCE_ARN=""

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
Permission Set Management - Unified Definition and Assignment

Usage:
  # Permission Set Definition
  $(basename "$0") create --config FILE
  $(basename "$0") list
  $(basename "$0") show --config FILE
  $(basename "$0") check --name NAME

  # Permission Assignment
  $(basename "$0") assign \\
    --user-id USER_ID \\
    --account-id ACCOUNT_ID \\
    --permission-set NAME
  
  $(basename "$0") revoke \\
    --user-id USER_ID \\
    --account-id ACCOUNT_ID \\
    --permission-set NAME
  
  $(basename "$0") list-assignments --account-id ACCOUNT_ID

Commands:
  Definition Management:
    create              Create a new Permission Set from config file
    list                List all Permission Sets
    show                Show Permission Set details
    check               Check if Permission Set exists

  Assignment Management:
    assign              Assign Permission Set to user + account
    revoke              Revoke Permission Set assignment
    list-assignments    List assignments for an account

Options:
  --config FILE         Path to Permission Set configuration file (JSON)
  --name NAME           Permission Set name
  --user-id ID          Identity Center user ID
  --account-id ID       AWS account ID
  --permission-set NAME Permission Set name for assignment

Examples:
  # Create Permission Set
  $(basename "$0") create --config permission-sets/terraform-deployer.json

  # List all Permission Sets
  $(basename "$0") list

  # Assign to user + account
  $(basename "$0") assign \\
    --user-id xxxx-xxxx-xxxx \\
    --account-id 123456789012 \\
    --permission-set TerraformDeployerPermissions

  # List assignments for an account
  $(basename "$0") list-assignments --account-id 123456789012

  # Revoke assignment
  $(basename "$0") revoke \\
    --user-id xxxx-xxxx-xxxx \\
    --account-id 123456789012 \\
    --permission-set TerraformDeployerPermissions

EOF
}

################################################################################
# Prerequisite Checks
################################################################################

check_prerequisites() {
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed"
        exit 1
    fi
    
    # Check jq
    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed"
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials are not configured"
        exit 1
    fi
}

get_sso_instance() {
    log_info "Getting IAM Identity Center instance..."
    local instances
    instances=$(aws sso-admin list-instances --output json 2>/dev/null)
    
    if [[ -z "${instances}" ]] || [[ "$(echo "${instances}" | jq '.Instances | length')" -eq 0 ]]; then
        log_error "No IAM Identity Center instance found"
        exit 2
    fi
    
    SSO_INSTANCE_ARN=$(echo "${instances}" | jq -r '.Instances[0].InstanceArn')
    log_success "Instance ARN: ${SSO_INSTANCE_ARN}"
}

################################################################################
# Core Functions
################################################################################

check_permission_set_exists() {
    local name="$1"
    
    local permission_sets
    permission_sets=$(aws sso-admin list-permission-sets \
        --instance-arn "${SSO_INSTANCE_ARN}" \
        --output json)
    
    for ps_arn in $(echo "${permission_sets}" | jq -r '.PermissionSets[]'); do
        local ps_name
        ps_name=$(aws sso-admin describe-permission-set \
            --instance-arn "${SSO_INSTANCE_ARN}" \
            --permission-set-arn "${ps_arn}" \
            --query 'PermissionSet.Name' \
            --output text)
        
        if [[ "${ps_name}" == "${name}" ]]; then
            echo "${ps_arn}"
            return 0
        fi
    done
    
    return 1
}

validate_config_file() {
    local config_file="$1"
    
    if [[ ! -f "${config_file}" ]]; then
        log_error "Config file not found: ${config_file}"
        exit 1
    fi
    
    if ! jq empty "${config_file}" 2>/dev/null; then
        log_error "Invalid JSON in config file: ${config_file}"
        exit 1
    fi
    
    # Check required fields
    local required_fields=("name" "description" "session_duration" "inline_policy_file")
    for field in "${required_fields[@]}"; do
        if [[ "$(jq -r ".${field} // empty" "${config_file}")" == "" ]]; then
            log_error "Missing required field in config: ${field}"
            exit 1
        fi
    done
    
    # Validate inline policy file exists
    local policy_file
    policy_file=$(jq -r '.inline_policy_file' "${config_file}")
    if [[ ! -f "${policy_file}" ]]; then
        log_error "Inline policy file not found: ${policy_file}"
        exit 1
    fi
    
    if ! jq empty "${policy_file}" 2>/dev/null; then
        log_error "Invalid JSON in policy file: ${policy_file}"
        exit 1
    fi
}

create_permission_set() {
    local config_file="$1"
    
    log_info "Reading configuration: ${config_file}"
    validate_config_file "${config_file}"
    
    local ps_name ps_description ps_session ps_inline_policy managed_policies
    ps_name=$(jq -r '.name' "${config_file}")
    ps_description=$(jq -r '.description' "${config_file}")
    ps_session=$(jq -r '.session_duration' "${config_file}")
    ps_inline_policy=$(jq -r '.inline_policy_file' "${config_file}")
    managed_policies=$(jq -r '.managed_policies[]' "${config_file}")
    
    log_info "Permission Set: ${ps_name}"
    
    # Check if already exists
    local existing_arn
    if existing_arn=$(check_permission_set_exists "${ps_name}"); then
        log_warning "Permission Set '${ps_name}' already exists"
        log_warning "ARN: ${existing_arn}"
        echo -n "Update existing Permission Set? (y/N): "
        read -r response
        if [[ "${response}" != "y" && "${response}" != "Y" ]]; then
            log_info "Skipping update"
            return 0
        fi
        
        log_info "Updating existing Permission Set..."
        
        # Update session duration
        log_info "Updating session duration to: ${ps_session}"
        aws sso-admin update-permission-set \
            --instance-arn "${SSO_INSTANCE_ARN}" \
            --permission-set-arn "${existing_arn}" \
            --session-duration "${ps_session}" \
            --output json > /dev/null
        log_success "Session duration updated"
        
        # Update inline policy
        log_info "Updating inline policy from: ${ps_inline_policy}"
        local policy_content
        policy_content=$(cat "${ps_inline_policy}")
        
        aws sso-admin put-inline-policy-to-permission-set \
            --instance-arn "${SSO_INSTANCE_ARN}" \
            --permission-set-arn "${existing_arn}" \
            --inline-policy "${policy_content}" \
            --output json > /dev/null
        log_success "Inline policy updated"
        
        # Update managed policies
        log_info "Updating managed policies..."
        
        # Get currently attached managed policies
        local current_policies
        current_policies=$(aws sso-admin list-managed-policies-in-permission-set \
            --instance-arn "${SSO_INSTANCE_ARN}" \
            --permission-set-arn "${existing_arn}" \
            --output json | jq -r '.AttachedManagedPolicies[].Name')
        
        # Attach new managed policies that aren't already attached
        for policy in ${managed_policies}; do
            if ! echo "${current_policies}" | grep -q "^${policy}$"; then
                log_info "Attaching managed policy: ${policy}"
                aws sso-admin attach-managed-policy-to-permission-set \
                    --instance-arn "${SSO_INSTANCE_ARN}" \
                    --permission-set-arn "${existing_arn}" \
                    --managed-policy-arn "arn:aws:iam::aws:policy/${policy}" \
                    --output json > /dev/null
                log_success "Managed policy attached: ${policy}"
            else
                log_info "Managed policy already attached: ${policy}"
            fi
        done
        
        log_success "Permission Set updated successfully!"
        
        # Provision the updated permission set to all assigned accounts
        log_info "Provisioning updated permission set to assigned accounts..."
        
        # Get all accounts assigned to this permission set
        local assigned_accounts
        assigned_accounts=$(aws sso-admin list-accounts-for-provisioned-permission-set \
            --instance-arn "${SSO_INSTANCE_ARN}" \
            --permission-set-arn "${existing_arn}" \
            --output json 2>/dev/null | jq -r '.AccountIds[]' || echo "")
        
        if [[ -z "${assigned_accounts}" ]]; then
            log_warning "No accounts currently assigned to this permission set"
        else
            local provision_count=0
            for account_id in ${assigned_accounts}; do
                log_info "Provisioning to account: ${account_id}"
                local provision_result
                provision_result=$(aws sso-admin provision-permission-set \
                    --instance-arn "${SSO_INSTANCE_ARN}" \
                    --permission-set-arn "${existing_arn}" \
                    --target-type AWS_ACCOUNT \
                    --target-id "${account_id}" \
                    --output json 2>&1)
                
                if [[ $? -eq 0 ]]; then
                    ((provision_count++))
                    log_success "Provisioned to account ${account_id}"
                else
                    log_warning "Failed to provision to account ${account_id}: ${provision_result}"
                fi
            done
            
            if [[ ${provision_count} -gt 0 ]]; then
                log_success "Provisioned to ${provision_count} account(s)"
                log_info "Waiting for provisioning to complete..."
                sleep 3
            fi
        fi
        
        echo ""
        echo "Permission Set Details:"
        echo "  Name: ${ps_name}"
        echo "  ARN: ${existing_arn}"
        echo "  Description: ${ps_description}"
        echo "  Session Duration: ${ps_session}"
        echo ""
        log_info "✓ Permission set updated and provisioned"
        log_info "✓ Users need to re-login to SSO to get updated permissions"
        return 0
    fi
    
    # Create Permission Set
    log_info "Creating Permission Set..."
    local result
    result=$(aws sso-admin create-permission-set \
        --instance-arn "${SSO_INSTANCE_ARN}" \
        --name "${ps_name}" \
        --description "${ps_description}" \
        --session-duration "${ps_session}" \
        --output json)
    
    local ps_arn
    ps_arn=$(echo "${result}" | jq -r '.PermissionSet.PermissionSetArn')
    log_success "Permission Set created: ${ps_arn}"
    
    # Attach managed policies
    for policy in ${managed_policies}; do
        log_info "Attaching managed policy: ${policy}"
        aws sso-admin attach-managed-policy-to-permission-set \
            --instance-arn "${SSO_INSTANCE_ARN}" \
            --permission-set-arn "${ps_arn}" \
            --managed-policy-arn "arn:aws:iam::aws:policy/${policy}" \
            --output json > /dev/null
        log_success "Managed policy attached: ${policy}"
    done
    
    # Put inline policy
    log_info "Adding inline policy from: ${ps_inline_policy}"
    local policy_content
    policy_content=$(cat "${ps_inline_policy}")
    
    aws sso-admin put-inline-policy-to-permission-set \
        --instance-arn "${SSO_INSTANCE_ARN}" \
        --permission-set-arn "${ps_arn}" \
        --inline-policy "${policy_content}" \
        --output json > /dev/null
    log_success "Inline policy attached"
    
    log_success "Permission Set creation completed!"
    echo ""
    echo "Permission Set Details:"
    echo "  Name: ${ps_name}"
    echo "  ARN: ${ps_arn}"
    echo "  Description: ${ps_description}"
    echo "  Session Duration: ${ps_session}"
}

check_command() {
    local name="$1"
    
    log_info "Checking if Permission Set '${name}' exists..."
    
    if existing_arn=$(check_permission_set_exists "${name}"); then
        log_success "Permission Set exists"
        echo "  Name: ${name}"
        echo "  ARN: ${existing_arn}"
        return 0
    else
        log_error "Permission Set '${name}' not found"
        return 1
    fi
}

show_command() {
    local config_file="$1"
    
    validate_config_file "${config_file}"
    
    local ps_name
    ps_name=$(jq -r '.name' "${config_file}")
    
    log_info "Getting details for Permission Set: ${ps_name}"
    
    local existing_arn
    if ! existing_arn=$(check_permission_set_exists "${ps_name}"); then
        log_error "Permission Set '${ps_name}' not found"
        exit 1
    fi
    
    local details
    details=$(aws sso-admin describe-permission-set \
        --instance-arn "${SSO_INSTANCE_ARN}" \
        --permission-set-arn "${existing_arn}" \
        --output json)
    
    echo ""
    echo "Permission Set Details:"
    echo "${details}" | jq -r '
        "  Name: \(.PermissionSet.Name)",
        "  ARN: \(.PermissionSet.PermissionSetArn)",
        "  Description: \(.PermissionSet.Description)",
        "  Session Duration: \(.PermissionSet.SessionDuration)",
        "  Created: \(.PermissionSet.CreatedDate)"
    '
    
    # Show attached policies
    log_info "Attached Managed Policies:"
    aws sso-admin list-managed-policies-in-permission-set \
        --instance-arn "${SSO_INSTANCE_ARN}" \
        --permission-set-arn "${existing_arn}" \
        --output json | jq -r '.AttachedManagedPolicies[] | "  - \(.Name)"'
    
    log_info "Inline Policy: Attached"
}

list_permission_sets_command() {
    log_info "Listing all Permission Sets..."
    
    local permission_sets
    permission_sets=$(aws sso-admin list-permission-sets \
        --instance-arn "${SSO_INSTANCE_ARN}" \
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
            --instance-arn "${SSO_INSTANCE_ARN}" \
            --permission-set-arn "${ps_arn}" \
            --output json)
        
        echo "${ps_details}" | jq -r '
            "  - \(.PermissionSet.Name)",
            "    Description: \(.PermissionSet.Description)",
            "    Session: \(.PermissionSet.SessionDuration)"
        '
    done
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
    
    return 1
}

check_assignment_exists() {
    local user_id="$1"
    local account_id="$2"
    local ps_arn="$3"
    
    local assignments
    assignments=$(aws sso-admin list-account-assignments \
        --instance-arn "${SSO_INSTANCE_ARN}" \
        --account-id "${account_id}" \
        --permission-set-arn "${ps_arn}" \
        --output json 2>/dev/null || echo '{"AccountAssignments":[]}')
    
    local exists
    exists=$(echo "${assignments}" | jq -r ".AccountAssignments[] | 
        select(.PrincipalId == \"${user_id}\" and .PrincipalType == \"USER\") | 
        .PrincipalId")
    
    [[ -n "${exists}" ]]
}

assign_permission_set() {
    local user_id="$1"
    local account_id="$2"
    local ps_name="$3"
    
    log_info "Assigning Permission Set '${ps_name}'..."
    log_info "  User ID: ${user_id}"
    log_info "  Account: ${account_id}"
    
    # Get Permission Set ARN
    local ps_arn
    if ! ps_arn=$(get_permission_set_arn "${ps_name}"); then
        log_error "Permission Set '${ps_name}' not found"
        exit 1
    fi
    
    log_success "Found Permission Set ARN: ${ps_arn}"
    
    # Check if already assigned
    if check_assignment_exists "${user_id}" "${account_id}" "${ps_arn}"; then
        log_warning "Assignment already exists"
        return 0
    fi
    
    # Create assignment
    local result
    result=$(aws sso-admin create-account-assignment \
        --instance-arn "${SSO_INSTANCE_ARN}" \
        --target-id "${account_id}" \
        --target-type AWS_ACCOUNT \
        --permission-set-arn "${ps_arn}" \
        --principal-type USER \
        --principal-id "${user_id}" \
        --output json)
    
    local request_id
    request_id=$(echo "${result}" | jq -r '.AccountAssignmentCreationStatus.RequestId')
    
    log_info "Assignment request ID: ${request_id}"
    log_info "Waiting for completion..."
    
    # Wait for completion
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
                log_success "Permission Set assigned successfully"
                return 0
                ;;
            "FAILED")
                local reason
                reason=$(echo "${status_result}" | jq -r '.AccountAssignmentCreationStatus.FailureReason // "Unknown"')
                log_error "Assignment failed: ${reason}"
                exit 2
                ;;
            "IN_PROGRESS")
                sleep 5
                ((attempt++))
                ;;
        esac
    done
    
    log_error "Assignment timed out"
    exit 2
}

revoke_permission_set() {
    local user_id="$1"
    local account_id="$2"
    local ps_name="$3"
    
    log_info "Revoking Permission Set '${ps_name}'..."
    log_info "  User ID: ${user_id}"
    log_info "  Account: ${account_id}"
    
    # Get Permission Set ARN
    local ps_arn
    if ! ps_arn=$(get_permission_set_arn "${ps_name}"); then
        log_error "Permission Set '${ps_name}' not found"
        exit 1
    fi
    
    # Delete assignment
    local result
    result=$(aws sso-admin delete-account-assignment \
        --instance-arn "${SSO_INSTANCE_ARN}" \
        --target-id "${account_id}" \
        --target-type AWS_ACCOUNT \
        --permission-set-arn "${ps_arn}" \
        --principal-type USER \
        --principal-id "${user_id}" \
        --output json)
    
    local request_id
    request_id=$(echo "${result}" | jq -r '.AccountAssignmentDeletionStatus.RequestId')
    
    log_info "Revocation request ID: ${request_id}"
    log_info "Waiting for completion..."
    
    # Wait for completion
    local max_attempts=24
    local attempt=0
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        local status_result
        status_result=$(aws sso-admin describe-account-assignment-deletion-status \
            --instance-arn "${SSO_INSTANCE_ARN}" \
            --account-assignment-deletion-request-id "${request_id}" \
            --output json)
        
        local status
        status=$(echo "${status_result}" | jq -r '.AccountAssignmentDeletionStatus.Status')
        
        case "${status}" in
            "SUCCEEDED")
                log_success "Permission Set revoked successfully"
                return 0
                ;;
            "FAILED")
                local reason
                reason=$(echo "${status_result}" | jq -r '.AccountAssignmentDeletionStatus.FailureReason // "Unknown"')
                log_error "Revocation failed: ${reason}"
                exit 2
                ;;
            "IN_PROGRESS")
                sleep 5
                ((attempt++))
                ;;
        esac
    done
    
    log_error "Revocation timed out"
    exit 2
}

list_assignments_by_account() {
    local account_id="$1"
    
    log_info "Listing assignments for account ${account_id}..."
    
    # Get all Permission Sets
    local permission_sets
    permission_sets=$(aws sso-admin list-permission-sets \
        --instance-arn "${SSO_INSTANCE_ARN}" \
        --output json)
    
    echo ""
    echo "Assignments for Account ${account_id}:"
    echo ""
    
    local found_assignments=false
    
    # Iterate through each Permission Set
    for ps_arn in $(echo "${permission_sets}" | jq -r '.PermissionSets[]'); do
        local ps_name
        ps_name=$(aws sso-admin describe-permission-set \
            --instance-arn "${SSO_INSTANCE_ARN}" \
            --permission-set-arn "${ps_arn}" \
            --query 'PermissionSet.Name' \
            --output text)
        
        # Get assignments for this Permission Set on this account
        local assignments
        assignments=$(aws sso-admin list-account-assignments \
            --instance-arn "${SSO_INSTANCE_ARN}" \
            --account-id "${account_id}" \
            --permission-set-arn "${ps_arn}" \
            --output json 2>/dev/null || echo '{"AccountAssignments":[]}')
        
        local count
        count=$(echo "${assignments}" | jq '.AccountAssignments | length')
        
        if [[ "${count}" -gt 0 ]]; then
            found_assignments=true
            echo "Permission Set: ${ps_name}"
            echo "${assignments}" | jq -r '.AccountAssignments[] | 
                "  - \(.PrincipalType): \(.PrincipalId)"
            '
            echo ""
        fi
    done
    
    if [[ "${found_assignments}" == "false" ]]; then
        log_info "No assignments found for this account"
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
        create|check|show|list|assign|revoke|list-assignments)
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
            --name)
                PERMISSION_SET_NAME="$2"
                shift 2
                ;;
            --permission-set)
                PERMISSION_SET_NAME="$2"
                shift 2
                ;;
            --user-id)
                USER_ID="$2"
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
        create|show)
            if [[ -z "${CONFIG_FILE}" ]]; then
                log_error "--config is required for ${COMMAND} command"
                exit 1
            fi
            ;;
        check)
            if [[ -z "${PERMISSION_SET_NAME}" ]]; then
                log_error "--name is required for check command"
                exit 1
            fi
            ;;
        assign|revoke)
            if [[ -z "${USER_ID}" ]]; then
                log_error "--user-id is required for ${COMMAND} command"
                exit 1
            fi
            if [[ -z "${ACCOUNT_ID}" ]]; then
                log_error "--account-id is required for ${COMMAND} command"
                exit 1
            fi
            if [[ -z "${PERMISSION_SET_NAME}" ]]; then
                log_error "--permission-set is required for ${COMMAND} command"
                exit 1
            fi
            ;;
        list-assignments)
            if [[ -z "${ACCOUNT_ID}" ]]; then
                log_error "--account-id is required for list-assignments command"
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
    get_sso_instance
    
    case "${COMMAND}" in
        create)
            create_permission_set "${CONFIG_FILE}"
            ;;
        list)
            list_permission_sets_command
            ;;
        check)
            check_command "${PERMISSION_SET_NAME}"
            ;;
        show)
            show_command "${CONFIG_FILE}"
            ;;
        assign)
            assign_permission_set "${USER_ID}" "${ACCOUNT_ID}" "${PERMISSION_SET_NAME}"
            ;;
        revoke)
            revoke_permission_set "${USER_ID}" "${ACCOUNT_ID}" "${PERMISSION_SET_NAME}"
            ;;
        list-assignments)
            list_assignments_by_account "${ACCOUNT_ID}"
            ;;
    esac
}

main "$@"

