#!/usr/bin/env bash

# =========================================================================================
# SCRIPT NAME: changepwd.sh
# VERSION:     2.0
#
# DESCRIPTION:
#    Oracle Database User Password Change with Vault Integration
#    Generates secure passwords, updates Oracle users, and stores in HashiCorp Vault
# =========================================================================================
# Usage: changepwd.sh -u <db_user> -i <service_instance> -e <environment>
#                     -U <vault_user> -P <vault_pass> [-d] [-b] [-l <logfile>]
#
# Parameters:
#   -u db_user           - Database user name
#   -i service_instance  - Oracle service instance name
#   -e environment       - Environment code (svi, int, tst, pre, prd)
#   -U vault_username    - Vault username for authentication
#   -P vault_password    - Vault password for authentication
#   -d                   - Dry-run mode (show what would be done without doing it)
#   -b                   - Bare mode (minimal output, disables coloring)
#   -l logfile           - Optional log file path
#   -h                   - Show this help message
# =========================================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# =========================================================================================
# DEFAULTS & GLOBALS
# =========================================================================================
SCRIPT_VERSION="2.0"
myHOSTNAME="$(hostname -f 2>/dev/null || hostname)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_LIB=$(find /products/software/sysadm/ -name "vault_lib.sh" 2>/dev/null | head -n 1)
SECRET_ENGINE="database"
DRY_RUN=false
BARE_MODE=0
LOG_FILE=""

WARN_COUNT=0
ERR_COUNT=0

# Color variables (will be set by setColor function)
RED=""
YELLOW=""
CYAN=""
GREEN=""
BLUE=""
NC=""

# =========================================================================================
# UTILITIES
# =========================================================================================

setColor() {
    if [[ "$BARE_MODE" -eq 0 && -t 1 ]]; then
        RED=$(tput setaf 1)
        YELLOW=$(tput setaf 3)
        CYAN=$(tput setaf 6)
        GREEN=$(tput setaf 2)
        BLUE=$(tput setaf 4)
        NC=$(tput sgr0)
    else
        RED=""
        YELLOW=""
        CYAN=""
        GREEN=""
        BLUE=""
        NC=""
    fi
}

putMsg() {
    local sev="$1"; shift
    local msg="${*:-}"
    local color="$NC"
    
    case "$sev" in
        INFO)  color="$CYAN" ;;
        WARN)  color="$YELLOW"; ((WARN_COUNT += 1)) ;;
        ERROR) color="$RED";    ((ERR_COUNT += 1)) ;;
        OK)    color="$GREEN" ;;
        DRY)   color="$BLUE" ;;
    esac
    
    local timestamp
    timestamp="$(date +'%F %T')"
    local formatted_msg="${myHOSTNAME} ${timestamp} ${sev}: ${msg}"

    # Standard Output
    echo -e "${color}${formatted_msg}${NC}"

    # Log File Output (Clean, no colors)
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "$formatted_msg" >> "$LOG_FILE"
    fi
}

errTrap() {
    set +e
    putMsg ERROR "Fatal error at line $1: '$2'"
    exit 12
}

# Set error trap
trap 'errTrap ${LINENO} "$BASH_COMMAND"' ERR

# =========================================================================================

# Usage function
usage() {
    cat <<EOF
Usage: $0 -u <db_user> -i <service_instance> -e <environment> -U <vault_user> -P <vault_pass> [-d] [-b] [-l <logfile>]

Parameters:
  -u db_user           - Database user name (required)
  -i service_instance  - Oracle service instance name (required)
  -e environment       - Environment code: svi, int, tst, pre, prd (required)
  -U vault_username    - Vault username for authentication (required)
  -P vault_password    - Vault password for authentication (required)
  -d                   - Dry-run mode (show what would be done without doing it)
  -b                   - Bare mode (minimal output, disables coloring)
  -l logfile           - Optional log file path
  -h                   - Show this help message

Examples:
  $0 -u A_IDL -i SVI0 -e svi -U vault_user -P 'vault_password'
  $0 -u U_BATCH -i PRD1 -e prd -U vault_user -P 'vault_password' -l /var/log/changepwd.log

Description:
  This script changes the password of an Oracle database user and stores
  the new credentials in HashiCorp Vault. It performs the following steps:
  1. Generates a secure random password
  2. Changes the user password in the Oracle database
  3. Stores the new credentials in Vault
  4. Updates metadata information in Vault

Note:
  - This script must be run as a user with sudo privileges to switch to oracle user
  - The vault_lib.sh must be available at: $VAULT_LIB
EOF
    exit 0
}

# Parse command line arguments (must be done before setColor)
DB_USER=""
SERVICE_INSTANCE=""
ENVIRONMENT=""
VAULT_USERNAME=""
VAULT_PASSWORD=""

while getopts "u:i:e:U:P:l:dbh" opt; do
    case ${opt} in
        u)
            DB_USER=$OPTARG
            ;;
        i)
            SERVICE_INSTANCE=$OPTARG
            ;;
        e)
            ENVIRONMENT=$OPTARG
            ;;
        U)
            VAULT_USERNAME=$OPTARG
            ;;
        P)
            VAULT_PASSWORD=$OPTARG
            ;;
        l)
            LOG_FILE=$OPTARG
            ;;
        d)
            DRY_RUN=true
            ;;
        b)
            BARE_MODE=1
            ;;
        h)
            usage
            ;;
        \?)
            echo "ERROR: Invalid option: -$OPTARG" >&2
            usage
            ;;
        :)
            echo "ERROR: Option -$OPTARG requires an argument" >&2
            usage
            ;;
    esac
done

# Initialize colors after parsing BARE_MODE
setColor

# Initialize log file if specified
if [[ -n "$LOG_FILE" ]]; then
    : > "$LOG_FILE"
    putMsg INFO "Log file initialized: $LOG_FILE"
fi

# Validate required parameters
if [ -z "$DB_USER" ] || [ -z "$SERVICE_INSTANCE" ] || [ -z "$ENVIRONMENT" ] || [ -z "$VAULT_USERNAME" ] || [ -z "$VAULT_PASSWORD" ]; then
    putMsg ERROR "Missing required parameters"
    usage
fi

# Validate environment
case "$ENVIRONMENT" in
    svi|int|tst|pre|prd|amm)
        ENVIRONMENT=$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]')
        ;;
    *)
        putMsg ERROR "Invalid environment. Must be one of: svi, int, tst, pre, prd, amm"
        exit 1
        ;;
esac

# Check if vault_lib.sh exists
if [ ! -f "$VAULT_LIB" ]; then
    putMsg ERROR "vault_lib.sh not found at: $VAULT_LIB"
    exit 1
fi

# Source vault library
# shellcheck source=/products/software/sysadm/vault_lib.sh
source "$VAULT_LIB"

# Check if jq is available
f_check_command jq
if [ $? -eq 1 ]; then
    if [ "$DRY_RUN" = true ]; then
        putMsg DRY "Would check/install jq"
    else
        putMsg WARN "jq not found. Attempting to install..."
        if command -v yum &> /dev/null; then
            sudo yum install jq -y
        elif command -v apt-get &> /dev/null; then
            sudo apt-get install jq -y
        else
            putMsg ERROR "Cannot install jq. Please install it manually."
            exit 1
        fi
    fi
fi

# Display dry-run mode if enabled
if [ "$DRY_RUN" = true ]; then
    echo ""
    putMsg DRY "========================================"
    putMsg DRY "DRY-RUN MODE ENABLED"
    putMsg DRY "No changes will be made"
    putMsg DRY "========================================"
    echo ""
fi

putMsg OK "======================================="
putMsg OK "Password Change Tool v${SCRIPT_VERSION}"
putMsg OK "========================================"

# Generate secure random password
if [ "$DRY_RUN" = true ]; then
    putMsg DRY "Would generate secure random password (28 chars)"
    DB_USER_PASSWORD="DryRunPassword1234567890ab"
    putMsg DRY "Example password: ${DB_USER_PASSWORD}"
else
    putMsg INFO "Generating secure random password..."
    DB_USER_PASSWORD=$(openssl rand -base64 21 | tr -d '/+=' | cut -c1-28)
    
    if [ -z "$DB_USER_PASSWORD" ]; then
        putMsg ERROR "Failed to generate password"
        exit 1
    fi
    putMsg OK "✓ Generated password for user: $DB_USER"
fi

# Construct vault path
SERVICE_INSTANCE_LOWER=$(echo "$SERVICE_INSTANCE" | tr '[:upper:]' '[:lower:]')
PATH_SECRET="${ENVIRONMENT}/paas/oracle/${SERVICE_INSTANCE_LOWER}"

putMsg INFO "Vault path: $PATH_SECRET"

# Change password in Oracle database
if [ "$DRY_RUN" = true ]; then
    putMsg DRY "Would change password in Oracle database"
    putMsg DRY "  Command: sudo -u oracle bash -c '. ${ORAENV_FILE} && ${ALTER_USER_SCRIPT} ${DB_USER} <password> ${ORAENV_FILE}'"
    putMsg DRY "  SQL: ALTER USER ${DB_USER} IDENTIFIED BY <new_password>"
else
    putMsg INFO "Changing password in Oracle database..."
    ALTER_USER_SCRIPT="${SCRIPT_DIR}/alter_user.sh"
    
    if [ ! -f "$ALTER_USER_SCRIPT" ]; then
        putMsg ERROR "alter_user.sh not found at: $ALTER_USER_SCRIPT"
        exit 1
    fi
    
    # Run alter_user.sh as oracle user
    ORAENV_FILE="/usr/local/bin/oraenv_${SERVICE_INSTANCE}"
    if sudo -u oracle bash -c ". ${ORAENV_FILE} 2>/dev/null && ${ALTER_USER_SCRIPT} ${DB_USER} '${DB_USER_PASSWORD}' ${ORAENV_FILE}"; then
        putMsg OK "✓ Password changed successfully in database"
    else
        putMsg ERROR "Failed to change password in database"
        exit 1
    fi
fi

# Login to Vault
if [ "$DRY_RUN" = true ]; then
    putMsg DRY "Would login to Vault with user: ${VAULT_USERNAME}"
    token="dry-run-token-12345"
else
    putMsg INFO "Logging into Vault..."
    token=$(hc_vault_login "${VAULT_USERNAME}" "${VAULT_PASSWORD}")
    
    if [ -z "$token" ]; then
        putMsg ERROR "Failed to login to Vault"
        exit 1
    fi
    putMsg OK "✓ Vault login successful"
fi

# Save credentials to Vault
if [ "$DRY_RUN" = true ]; then
    putMsg DRY "Would save credentials to Vault"
    putMsg DRY "  Path: ${PATH_SECRET}/${DB_USER}"
    putMsg DRY "  Key: ${DB_USER}"
    putMsg DRY "  Value: <generated_password>"
    putMsg DRY "  Secret Engine: ${SECRET_ENGINE}"
else
    putMsg INFO "Saving credentials to Vault..."
    if hc_vault_create "$DB_USER" "$DB_USER_PASSWORD" "$SECRET_ENGINE" "${PATH_SECRET}/${DB_USER}" "$token"; then
        putMsg OK "✓ Credentials saved to Vault"
    else
        putMsg ERROR "Failed to save credentials to Vault"
        exit 1
    fi
fi

# Update metadata in Vault
HOSTNAME=$(hostname)
METADATA="host=${HOSTNAME},environment=${ENVIRONMENT},instance=${SERVICE_INSTANCE},user=${DB_USER}"

if [ "$DRY_RUN" = true ]; then
    putMsg DRY "Would update metadata in Vault"
    putMsg DRY "  Metadata: ${METADATA}"
    putMsg DRY "  Method: changepwd"
else
    putMsg INFO "Updating metadata in Vault..."
    if hc_vault_create_info_metadata "$SECRET_ENGINE" "${PATH_SECRET}/${DB_USER}" "$METADATA" "$token" "changepwd"; then
        putMsg OK "✓ Metadata updated in Vault"
    else
        putMsg WARN "Failed to update metadata in Vault (non-critical)"
    fi
fi

# Summary
echo ""
if [ "$DRY_RUN" = true ]; then
    putMsg DRY "========================================"
    putMsg DRY "DRY-RUN Summary"
    putMsg DRY "========================================"
    putMsg DRY "The following operations would be performed:"
    echo ""
    putMsg INFO "User         : $DB_USER"
    putMsg INFO "Instance     : $SERVICE_INSTANCE"
    putMsg INFO "Environment  : $ENVIRONMENT"
    putMsg INFO "Vault Path   : $PATH_SECRET/$DB_USER"
    echo ""
    putMsg DRY "Operations:"
    putMsg DRY "  1. Generate new secure password (28 chars)"
    putMsg DRY "  2. Execute ALTER USER in Oracle database"
    putMsg DRY "  3. Save credentials to Vault"
    putMsg DRY "  4. Update metadata in Vault"
    echo ""
    putMsg DRY "========================================"
    putMsg WARN "No actual changes were made"
    putMsg DRY "========================================"
else
    putMsg OK "========================================"
    putMsg OK "Password change completed successfully!"
    putMsg OK "========================================"
    putMsg INFO "User         : $DB_USER"
    putMsg INFO "Instance     : $SERVICE_INSTANCE"
    putMsg INFO "Environment  : $ENVIRONMENT"
    putMsg INFO "Vault Path   : $PATH_SECRET/$DB_USER"
    putMsg OK "========================================"
    putMsg INFO "Warnings: $WARN_COUNT | Errors: $ERR_COUNT"
    putMsg OK "========================================"
fi

[[ $ERR_COUNT -gt 0 ]] && exit 8 || exit 0
