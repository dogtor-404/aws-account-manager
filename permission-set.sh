#!/bin/bash

################################################################################
# Permission Set Management Script
#
# Manages IAM Identity Center Permission Sets including creation, validation,
# and policy attachment.
#
# Usage:
#   ./permission-set.sh create --config CONFIG_FILE
#   ./permission-set.sh check --name NAME
#   ./permission-set.sh show --config CONFIG_FILE
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
Permission Set Management Script

Usage:
  $(basename "$0") create --config CONFIG_FILE
  $(basename "$0") check --name NAME
  $(basename "$0") show --config CONFIG_FILE

Commands:
  create    Create a new Permission Set from config file
  check     Check if a Permission Set exists by name
  show      Show details of a Permission Set

Options:
  --config FILE    Path to Permission Set configuration file (JSON)
  --name NAME      Permission Set name to check

Examples:
  # Create Permission Set
  $(basename "$0") create --config permission-sets/terraform-deployer.json
  
  # Check if exists
  $(basename "$0") check --name TerraformDeployerPermissionSet
  
  # Show details
  $(basename "$0") show --config permission-sets/terraform-deployer.json

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
            log_info "Skipping creation"
            return 0
        fi
        log_info "Updating existing Permission Set..."
        # For now, just skip update logic
        log_warning "Update not implemented yet, skipping"
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
        create|check|show)
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
        check)
            check_command "${PERMISSION_SET_NAME}"
            ;;
        show)
            show_command "${CONFIG_FILE}"
            ;;
    esac
}

main "$@"

