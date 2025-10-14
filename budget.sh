#!/bin/bash

################################################################################
# Budget Management Script
#
# Manages AWS Budgets and cost alerts
#
# Usage:
#   ./budget.sh create --name NAME --amount AMOUNT --email EMAIL
#   ./budget.sh check --name NAME
#   ./budget.sh list
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
USERNAME=""
ACCOUNT_ID=""

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
Budget Management Script

Usage:
  $(basename "$0") create --name NAME --amount AMOUNT --email EMAIL
  $(basename "$0") create --username NAME --amount AMOUNT --email EMAIL
  $(basename "$0") check --name NAME  
  $(basename "$0") list

Commands:
  create    Create a new budget with alerts
  check     Check if a budget exists
  list      List all budgets

Options for 'create':
  --name NAME       Budget name (required for account-level budget)
  --amount AMOUNT   Monthly budget amount in USD
  --email EMAIL     Email address for budget alerts
  --username NAME   Username for user-specific budget (auto-generates budget name)

Examples:
  # Create account-level budget
  $(basename "$0") create \\
    --name "account-monthly-budget" \\
    --amount 1000 \\
    --email admin@company.com

  # Create user-specific budget with tag filter
  $(basename "$0") create \\
    --username alice \\
    --amount 100 \\
    --email alice@company.com
  
  # Check if exists
  $(basename "$0") check --name user-budget
  
  # List all budgets
  $(basename "$0") list

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
    
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials are not configured"
        exit 1
    fi
}

get_account_id() {
    log_info "Getting AWS account ID..."
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    log_success "Account ID: ${ACCOUNT_ID}"
}

################################################################################
# Core Functions
################################################################################

check_budget_exists() {
    local name="$1"
    
    local existing_budget
    existing_budget=$(aws budgets describe-budget \
        --account-id "${ACCOUNT_ID}" \
        --budget-name "${name}" \
        --output json 2>/dev/null || echo '{}')
    
    if [[ "$(echo "${existing_budget}" | jq -r '.Budget.BudgetName // ""')" == "${name}" ]]; then
        return 0
    else
        return 1
    fi
}

create_budget() {
    local name="$1"
    local amount="$2"
    local email="$3"
    
    log_info "Creating budget: ${name}"
    log_info "  Amount: \$${amount}/month"
    log_info "  Email: ${email}"
    
    # Check if already exists
    if check_budget_exists "${name}"; then
        log_warning "Budget '${name}' already exists"
        return 0
    fi
    
    # Create budget with notifications
    log_info "Creating budget with alert thresholds (80%, 90%, 100%)..."
    
    aws budgets create-budget \
        --account-id "${ACCOUNT_ID}" \
        --budget "BudgetName=${name},BudgetLimit={Amount=${amount},Unit=USD},TimeUnit=MONTHLY,BudgetType=COST" \
        --notifications-with-subscribers \
            "Notification={NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=80,ThresholdType=PERCENTAGE},Subscribers=[{SubscriptionType=EMAIL,Address=${email}}]" \
            "Notification={NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=90,ThresholdType=PERCENTAGE},Subscribers=[{SubscriptionType=EMAIL,Address=${email}}]" \
            "Notification={NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=100,ThresholdType=PERCENTAGE},Subscribers=[{SubscriptionType=EMAIL,Address=${email}}]" \
        2>&1 | grep -v "^$" || true
    
    log_success "Budget created successfully"
    log_success "Budget: ${name} - \$${amount}/month"
    log_success "Alert thresholds: 80%, 90%, 100%"
    echo ""
    log_info "IMPORTANT: Check ${email} for 3 confirmation emails from AWS Notifications"
    log_info "You must click 'Confirm subscription' in each email to receive alerts"
}

create_user_budget() {
    local amount="$1"
    local email="$2"
    local username="$3"
    
    # 自动生成 budget name
    local name="${username}-monthly-budget"
    
    log_info "Creating user-specific budget: ${name}"
    log_info "  Amount: \$${amount}/month"
    log_info "  Email: ${email}"
    log_info "  Tag Filter: user=${username}"
    
    # Check if already exists
    if check_budget_exists "${name}"; then
        log_warning "Budget '${name}' already exists"
        return 0
    fi
    
    # Create budget with CostFilters for user tag
    log_info "Creating budget with user tag filter and alert thresholds (80%, 90%, 100%)..."
    
    aws budgets create-budget \
        --account-id "${ACCOUNT_ID}" \
        --budget "BudgetName=${name},BudgetLimit={Amount=${amount},Unit=USD},TimeUnit=MONTHLY,BudgetType=COST,CostFilters={TagKeyValue=[user\$${username}]}" \
        --notifications-with-subscribers \
            "Notification={NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=80,ThresholdType=PERCENTAGE},Subscribers=[{SubscriptionType=EMAIL,Address=${email}}]" \
            "Notification={NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=90,ThresholdType=PERCENTAGE},Subscribers=[{SubscriptionType=EMAIL,Address=${email}}]" \
            "Notification={NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=100,ThresholdType=PERCENTAGE},Subscribers=[{SubscriptionType=EMAIL,Address=${email}}]" \
        2>&1 | grep -v "^$" || true
    
    log_success "User budget created successfully"
    log_success "Budget: ${name} - \$${amount}/month"
    log_success "Tag Filter: user=${username}"
    log_success "Alert thresholds: 80%, 90%, 100%"
    echo ""
    
    # 尝试自动激活 cost allocation tag
    log_info "Attempting to activate cost allocation tag 'user'..."
    local activation_result
    if activation_result=$(aws ce update-cost-allocation-tags-status \
        --cost-allocation-tags-status TagKey=user,Status=Active 2>&1); then
        log_success "Cost allocation tag 'user' activated successfully"
        log_info "Tag data will appear in cost reports within 24 hours"
    else
        # 检查是否因为标签已经激活而失败
        if echo "${activation_result}" | grep -q "already active\|already activated" 2>/dev/null; then
            log_info "Cost allocation tag 'user' is already active"
        else
            log_warning "Could not activate tag automatically (may require billing permissions)"
            log_warning "Error: ${activation_result}"
            log_warning "Please activate manually: AWS Console → Billing → Cost Allocation Tags"
        fi
    fi
    echo ""
    
    log_warning "IMPORTANT: Cost Allocation Tags Configuration"
    log_warning "1. Verify tag is active: AWS Console → Billing → Cost Allocation Tags"
    log_warning "2. Wait up to 24 hours for tag data to appear in cost reports"
    log_warning "3. User MUST tag all resources with: user=${username}"
    log_warning "   Example: aws ec2 run-instances --tags Key=user,Value=${username}"
    echo ""
    log_info "Check ${email} for 3 confirmation emails from AWS Notifications"
    log_info "You must click 'Confirm subscription' in each email to receive alerts"
}

check_command() {
    local name="$1"
    
    log_info "Checking if budget '${name}' exists..."
    
    if check_budget_exists "${name}"; then
        log_success "Budget exists"
        
        local budget_details
        budget_details=$(aws budgets describe-budget \
            --account-id "${ACCOUNT_ID}" \
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
        return 0
    else
        log_error "Budget '${name}' not found"
        return 1
    fi
}

list_command() {
    log_info "Listing all budgets..."
    
    local budgets
    budgets=$(aws budgets describe-budgets \
        --account-id "${ACCOUNT_ID}" \
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
        create|check|list)
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
            --username)
                USERNAME="$2"
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
            if [[ -n "${USERNAME}" ]]; then
                # 用户级别预算：只需要 amount, email, username
                if [[ -z "${BUDGET_AMOUNT}" ]]; then
                    log_error "--amount is required for create command"
                    exit 1
                fi
                if [[ -z "${EMAIL_ADDRESS}" ]]; then
                    log_error "--email is required for create command"
                    exit 1
                fi
            else
                # 账户级别预算：需要 name, amount, email
                if [[ -z "${BUDGET_NAME}" ]]; then
                    log_error "--name is required for create command (unless --username is provided)"
                    exit 1
                fi
                if [[ -z "${BUDGET_AMOUNT}" ]]; then
                    log_error "--amount is required for create command"
                    exit 1
                fi
                if [[ -z "${EMAIL_ADDRESS}" ]]; then
                    log_error "--email is required for create command"
                    exit 1
                fi
            fi
            
            if ! [[ "${BUDGET_AMOUNT}" =~ ^[0-9]+$ ]]; then
                log_error "Budget amount must be a positive integer"
                exit 1
            fi
            ;;
        check)
            if [[ -z "${BUDGET_NAME}" ]]; then
                log_error "--name is required for check command"
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
    get_account_id
    
    case "${COMMAND}" in
        create)
            if [[ -n "${USERNAME}" ]]; then
                create_user_budget "${BUDGET_AMOUNT}" "${EMAIL_ADDRESS}" "${USERNAME}"
            else
                create_budget "${BUDGET_NAME}" "${BUDGET_AMOUNT}" "${EMAIL_ADDRESS}"
            fi
            ;;
        check)
            check_command "${BUDGET_NAME}"
            ;;
        list)
            list_command
            ;;
    esac
}

main "$@"

