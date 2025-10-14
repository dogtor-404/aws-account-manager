#!/bin/bash

################################################################################
# Budget Management Script
#
# Manages AWS Budgets with LinkedAccount cost tracking
#
# Usage:
#   ./budget.sh create-linked --account-id ID --name NAME --amount AMOUNT --email EMAIL
#   ./budget.sh create-global --name NAME --amount AMOUNT --email EMAIL
#   ./budget.sh check --name NAME
#   ./budget.sh list
#   ./budget.sh show --name NAME
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
BUDGET_NAME=""
BUDGET_AMOUNT=""
EMAIL_ADDRESS=""
LINKED_ACCOUNT_ID=""
MANAGEMENT_ACCOUNT_ID=""

# Default alert thresholds
readonly DEFAULT_THRESHOLDS="80,90,100"

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
Budget Management Script - LinkedAccount Cost Tracking

Usage:
  $(basename "$0") create-linked --account-id ID --name NAME --amount AMOUNT --email EMAIL
  $(basename "$0") create-global --name NAME --amount AMOUNT --email EMAIL
  $(basename "$0") check --name NAME
  $(basename "$0") list
  $(basename "$0") show --name NAME

Commands:
  create-linked    Create budget for a specific member account (LinkedAccount filter)
  create-global    Create budget for entire organization (no filter)
  check            Check if a budget exists
  list             List all budgets
  show             Show budget details

Options:
  --account-id ID   Member account ID to track (for create-linked)
  --name NAME       Budget name
  --amount AMOUNT   Monthly budget amount in USD
  --email EMAIL     Email address for budget alerts

Examples:
  # Create budget for member account
  $(basename "$0") create-linked \\
    --account-id 123456789012 \\
    --name "alice-dev-budget" \\
    --amount 100 \\
    --email alice@company.com

  # Create global budget for entire organization
  $(basename "$0") create-global \\
    --name "org-monthly-budget" \\
    --amount 1000 \\
    --email admin@company.com
  
  # Check if budget exists
  $(basename "$0") check --name "alice-dev-budget"
  
  # List all budgets
  $(basename "$0") list

  # Show budget details
  $(basename "$0") show --name "alice-dev-budget"

Note: Budgets are created in the management account and track costs via LinkedAccount filter.
      No resource tagging required - costs are automatically tracked by account!

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

get_management_account_id() {
    log_info "Getting management account ID..."
    MANAGEMENT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    log_success "Management Account ID: ${MANAGEMENT_ACCOUNT_ID}"
}

################################################################################
# Core Functions
################################################################################

check_budget_exists() {
    local name="$1"
    
    local existing_budget
    existing_budget=$(aws budgets describe-budget \
        --account-id "${MANAGEMENT_ACCOUNT_ID}" \
        --budget-name "${name}" \
        --output json 2>/dev/null || echo '{}')
    
    if [[ "$(echo "${existing_budget}" | jq -r '.Budget.BudgetName // ""')" == "${name}" ]]; then
        return 0
    else
        return 1
    fi
}

create_linked_account_budget() {
    local account_id="$1"
    local name="$2"
    local amount="$3"
    local email="$4"
    
    log_info "Creating LinkedAccount budget: ${name}"
    log_info "  Tracking Account: ${account_id}"
    log_info "  Amount: \$${amount}/month"
    log_info "  Email: ${email}"
    
    # Check if already exists
    if check_budget_exists "${name}"; then
        log_warning "Budget '${name}' already exists"
        return 0
    fi
    
    # Create budget with LinkedAccount filter
    log_info "Creating budget with automatic cost tracking..."
    
    # Create budget JSON
    local budget_json
    budget_json=$(cat <<EOF
{
  "BudgetName": "${name}",
  "BudgetLimit": {
    "Amount": "${amount}",
    "Unit": "USD"
  },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST",
  "CostFilters": {
    "LinkedAccount": ["${account_id}"]
  },
  "CostTypes": {
    "IncludeTax": true,
    "IncludeSubscription": true,
    "UseAmortized": true
  }
}
EOF
)
    
    # Create budget with notifications
    aws budgets create-budget \
        --account-id "${MANAGEMENT_ACCOUNT_ID}" \
        --budget "${budget_json}" \
        --notifications-with-subscribers \
            "Notification={NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=80,ThresholdType=PERCENTAGE},Subscribers=[{SubscriptionType=EMAIL,Address=${email}}]" \
            "Notification={NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=90,ThresholdType=PERCENTAGE},Subscribers=[{SubscriptionType=EMAIL,Address=${email}}]" \
            "Notification={NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=100,ThresholdType=PERCENTAGE},Subscribers=[{SubscriptionType=EMAIL,Address=${email}}]" \
        2>&1 | grep -v "^$" || true
    
    log_success "Budget created successfully"
    log_success "Budget: ${name} - \$${amount}/month"
    log_success "Tracking: Account ${account_id} (automatic)"
    log_success "Alert thresholds: 80%, 90%, 100%"
    echo ""
    log_info "✨ No resource tagging required!"
    log_info "All costs in account ${account_id} are automatically tracked"
    echo ""
    log_info "IMPORTANT: Check ${email} for 3 confirmation emails from AWS Notifications"
    log_info "You must click 'Confirm subscription' in each email to receive alerts"
}

create_global_budget() {
    local name="$1"
    local amount="$2"
    local email="$3"
    
    log_info "Creating global budget: ${name}"
    log_info "  Amount: \$${amount}/month"
    log_info "  Email: ${email}"
    
    # Check if already exists
    if check_budget_exists "${name}"; then
        log_warning "Budget '${name}' already exists"
        return 0
    fi
    
    # Create budget without filters (tracks all costs)
    log_info "Creating global budget (tracks all organization costs)..."
    
    aws budgets create-budget \
        --account-id "${MANAGEMENT_ACCOUNT_ID}" \
        --budget "BudgetName=${name},BudgetLimit={Amount=${amount},Unit=USD},TimeUnit=MONTHLY,BudgetType=COST" \
        --notifications-with-subscribers \
            "Notification={NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=80,ThresholdType=PERCENTAGE},Subscribers=[{SubscriptionType=EMAIL,Address=${email}}]" \
            "Notification={NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=90,ThresholdType=PERCENTAGE},Subscribers=[{SubscriptionType=EMAIL,Address=${email}}]" \
            "Notification={NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=100,ThresholdType=PERCENTAGE},Subscribers=[{SubscriptionType=EMAIL,Address=${email}}]" \
        2>&1 | grep -v "^$" || true
    
    log_success "Global budget created successfully"
    log_success "Budget: ${name} - \$${amount}/month"
    log_success "Scope: All organization costs"
    log_success "Alert thresholds: 80%, 90%, 100%"
    echo ""
    log_info "IMPORTANT: Check ${email} for 3 confirmation emails from AWS Notifications"
    log_info "You must click 'Confirm subscription' in each email to receive alerts"
}

check_command() {
    local name="$1"
    
    log_info "Checking if budget '${name}' exists..."
    
    if check_budget_exists "${name}"; then
        log_success "Budget exists"
        return 0
    else
        log_error "Budget '${name}' not found"
        return 1
    fi
}

show_budget() {
    local name="$1"
    
    log_info "Getting budget details: ${name}"
    
    if ! check_budget_exists "${name}"; then
        log_error "Budget '${name}' not found"
        exit 1
    fi
    
    local budget_details
    budget_details=$(aws budgets describe-budget \
        --account-id "${MANAGEMENT_ACCOUNT_ID}" \
        --budget-name "${name}" \
        --output json)
    
    echo ""
    echo "Budget Details:"
    echo "${budget_details}" | jq -r '
        "  Name: \(.Budget.BudgetName)",
        "  Amount: $\(.Budget.BudgetLimit.Amount) \(.Budget.BudgetLimit.Unit)",
        "  Type: \(.Budget.BudgetType)",
        "  Time Unit: \(.Budget.TimeUnit)"
    '
    
    # Show cost filters if they exist
    local linked_accounts
    linked_accounts=$(echo "${budget_details}" | jq -r '.Budget.CostFilters.LinkedAccount[]? // empty')
    
    if [[ -n "${linked_accounts}" ]]; then
        echo "  Tracking: LinkedAccount"
        for account in ${linked_accounts}; do
            echo "    - Account ID: ${account}"
        done
    else
        echo "  Tracking: All organization costs (no filter)"
    fi
}

list_budgets() {
    log_info "Listing all budgets..."
    
    local budgets
    budgets=$(aws budgets describe-budgets \
        --account-id "${MANAGEMENT_ACCOUNT_ID}" \
        --output json)
    
    local budget_count
    budget_count=$(echo "${budgets}" | jq '.Budgets | length')
    
    if [[ "${budget_count}" -eq 0 ]]; then
        log_info "No budgets found"
        return 0
    fi
    
    echo ""
    echo "Budgets (Total: ${budget_count}):"
    echo "${budgets}" | jq -r '.Budgets[] | 
        "  - \(.BudgetName): $\(.BudgetLimit.Amount)/\(.TimeUnit) (\(.BudgetType))"
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
        create-linked|create-global|check|list|show)
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
            --account-id)
                LINKED_ACCOUNT_ID="$2"
                shift 2
                ;;
            --name)
                BUDGET_NAME="$2"
                shift 2
                ;;
            --amount)
                BUDGET_AMOUNT="$2"
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
        create-linked)
            if [[ -z "${LINKED_ACCOUNT_ID}" ]]; then
                log_error "--account-id is required for create-linked command"
                exit 1
            fi
            if [[ -z "${BUDGET_NAME}" ]]; then
                log_error "--name is required for create-linked command"
                exit 1
            fi
            if [[ -z "${BUDGET_AMOUNT}" ]]; then
                log_error "--amount is required for create-linked command"
                exit 1
            fi
            if [[ -z "${EMAIL_ADDRESS}" ]]; then
                log_error "--email is required for create-linked command"
                exit 1
            fi
            if ! [[ "${BUDGET_AMOUNT}" =~ ^[0-9]+$ ]]; then
                log_error "Budget amount must be a positive integer"
                exit 1
            fi
            ;;
        create-global)
            if [[ -z "${BUDGET_NAME}" ]]; then
                log_error "--name is required for create-global command"
                exit 1
            fi
            if [[ -z "${BUDGET_AMOUNT}" ]]; then
                log_error "--amount is required for create-global command"
                exit 1
            fi
            if [[ -z "${EMAIL_ADDRESS}" ]]; then
                log_error "--email is required for create-global command"
                exit 1
            fi
            if ! [[ "${BUDGET_AMOUNT}" =~ ^[0-9]+$ ]]; then
                log_error "Budget amount must be a positive integer"
                exit 1
            fi
            ;;
        check|show)
            if [[ -z "${BUDGET_NAME}" ]]; then
                log_error "--name is required for ${COMMAND} command"
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
    get_management_account_id
    
    case "${COMMAND}" in
        create-linked)
            create_linked_account_budget "${LINKED_ACCOUNT_ID}" "${BUDGET_NAME}" "${BUDGET_AMOUNT}" "${EMAIL_ADDRESS}"
            ;;
        create-global)
            create_global_budget "${BUDGET_NAME}" "${BUDGET_AMOUNT}" "${EMAIL_ADDRESS}"
            ;;
        check)
            check_command "${BUDGET_NAME}"
            ;;
        show)
            show_budget "${BUDGET_NAME}"
            ;;
        list)
            list_budgets
            ;;
    esac
}

main "$@"
