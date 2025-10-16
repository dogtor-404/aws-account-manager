#!/bin/bash

################################################################################
# Check AWS SSO Session Expiry Time
#
# This script checks the expiry time of the current AWS SSO session
# and displays it in the local timezone.
#
# Usage:
#   ./check-session-expiry.sh [--profile <profile-name>]
################################################################################

set -e

# Color codes
readonly COLOR_RESET='\033[0m'
readonly COLOR_INFO='\033[0;34m'
readonly COLOR_SUCCESS='\033[0;32m'
readonly COLOR_WARNING='\033[0;33m'
readonly COLOR_ERROR='\033[0;31m'

usage() {
    cat << EOF
Usage: $(basename "$0") [--profile <profile-name>]

Check AWS SSO session expiry time and display in local timezone.

Options:
  --profile <name>    Specify AWS profile to check
  -h, --help          Show this help message

If no profile is specified, uses (in order of priority):
  1. AWS_PROFILE environment variable
  2. default profile

Examples:
  $(basename "$0")                          # Use AWS_PROFILE or default
  $(basename "$0") --profile neozhang.dev   # Use specific profile
  AWS_PROFILE=my-profile $(basename "$0")   # Use environment variable

EOF
}

# Parse arguments
PROFILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo -e "${COLOR_ERROR}Error: --profile requires a profile name${COLOR_RESET}"
                echo ""
                usage
                exit 1
            fi
            PROFILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo -e "${COLOR_ERROR}Error: Unknown option: $1${COLOR_RESET}"
            echo ""
            usage
            exit 1
            ;;
    esac
done

# Determine which profile to use
if [[ -z "${PROFILE}" ]]; then
    # No --profile argument, try to use default profile
    if [[ -n "${AWS_PROFILE}" ]]; then
        PROFILE="${AWS_PROFILE}"
        echo -e "${COLOR_INFO}Using AWS_PROFILE environment variable: ${PROFILE}${COLOR_RESET}"
    else
        # Try to get default profile from config
        PROFILE=$(aws configure get profile 2>/dev/null || echo "default")
        if [[ "${PROFILE}" == "default" ]]; then
            echo -e "${COLOR_WARNING}Using default profile${COLOR_RESET}"
            echo -e "${COLOR_INFO}Tip: Set AWS_PROFILE environment variable or use --profile option${COLOR_RESET}"
        else
            echo -e "${COLOR_INFO}Using configured default profile: ${PROFILE}${COLOR_RESET}"
        fi
    fi
fi

echo -e "${COLOR_INFO}=== AWS SSO Session Expiry Check ===${COLOR_RESET}"
echo ""
echo "Profile: ${PROFILE}"
echo ""

# Find the credentials cache file
CACHE_FILE=$(find ~/.aws/cli/cache -name "*.json" -type f -exec grep -l "AccessKeyId" {} \; 2>/dev/null | head -1)

if [[ -z "${CACHE_FILE}" ]]; then
    echo -e "${COLOR_WARNING}No active session found${COLOR_RESET}"
    echo "Please login first: aws sso login --profile ${PROFILE}"
    exit 1
fi

# Extract expiration time
EXPIRY_UTC=$(cat "${CACHE_FILE}" | jq -r '.Credentials.Expiration // empty' 2>/dev/null)

if [[ -z "${EXPIRY_UTC}" ]]; then
    echo -e "${COLOR_WARNING}Could not find expiration time in cache${COLOR_RESET}"
    exit 1
fi

echo "Expiration time (UTC): ${EXPIRY_UTC}"
echo ""

# Convert to local timezone and calculate remaining time
python3 << PYTHON_EOF
from datetime import datetime, timezone
import sys

try:
    # Parse UTC time
    expiry_utc = datetime.fromisoformat("${EXPIRY_UTC}".replace('Z', '+00:00'))
    
    # Convert to local timezone
    expiry_local = expiry_utc.astimezone()
    
    # Calculate remaining time
    now = datetime.now(timezone.utc)
    remaining = expiry_utc - now
    
    if remaining.total_seconds() < 0:
        print("${COLOR_WARNING}⚠ Session has expired${COLOR_RESET}")
        print()
        print(f"Expired at: {expiry_local.strftime('%Y-%m-%d %H:%M:%S %Z')}")
        print(f"Expired {abs(remaining.total_seconds() / 3600):.1f} hours ago")
        sys.exit(1)
    else:
        hours = remaining.total_seconds() / 3600
        minutes = int((remaining.total_seconds() % 3600) / 60)
        
        print("${COLOR_SUCCESS}✓ Session is active${COLOR_RESET}")
        print()
        print(f"Expires at: {expiry_local.strftime('%Y-%m-%d %H:%M:%S %Z')}")
        print(f"Time remaining: {hours:.1f} hours ({int(remaining.total_seconds() / 60)} minutes)")
        print()
        
        # Show percentage of session used (assuming 12h session)
        session_duration = 12 * 3600  # 12 hours in seconds
        used_time = session_duration - remaining.total_seconds()
        percentage = (used_time / session_duration) * 100
        
        if percentage < 0:
            percentage = 0
        elif percentage > 100:
            percentage = 100
            
        print(f"Session usage: {percentage:.0f}%")
        
        # Visual progress bar
        bar_length = 40
        filled = int(bar_length * percentage / 100)
        bar = '█' * filled + '░' * (bar_length - filled)
        print(f"[{bar}]")

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF

echo ""
echo "Current role:"
aws sts get-caller-identity --profile "${PROFILE}" 2>/dev/null | jq -r '.Arn' || echo "  (unable to get role info)"

