#!/usr/bin/env bash
# Authore Pedrotti Francesco francesco.pedrotti.88@gmail.com
# =========================================================================================
# SCRIPT NAME: oracleWalletToolkit.sh
# VERSION:     2.0
#
# DESCRIPTION:
#    Oracle Wallet toolkit with Vault Integration
# =========================================================================================
# Usage: oracleWalletToolkit.sh -u <db_user> -i <oracle_instance> -e <environment>
#                     -a <db_alias> -t <tns_admin> -o <os_user>
#                     -w <master_wallet> -U <vault_user> -P <vault_pass>
#                     [-c] [-L] [-T] [-A] [-D] [-d] [-b] [-l <logfile>]
#
# Parameters:
#   -u db_user        - Database user name
#   -i oracle_instance - Oracle instance name
#   -e environment    - Environment code (svi, int, tst, pre, prd)
#   -a db_alias       - TNS alias for the connection
#   -t tns_admin      - Path to TNS_ADMIN directory (wallet location)
#   -o os_user        - OS user that owns the wallet files
#   -w master_wallet  - Master wallet password
#   -U vault_username - Vault username for authentication
#   -P vault_password - Vault password for authentication
#   -c                - Create wallet if it doesn't exist
#   -L                - List wallet credentials and exit
#   -T                - Test all wallet credentials and show report
#   -A                - Convert wallet to auto-login-local (CIS compliant)
#   -D                - Delete a credential entry from the wallet (requires -a <db_alias>)
#   -d                - Dry-run mode (show what would be done without doing it)
#   -b                - Bare mode (minimal output, disables coloring)
#   -l logfile        - Optional log file path
#   -h                - Show this help message
# =========================================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# =========================================================================================
# DEFAULTS & GLOBALS
# =========================================================================================
SCRIPT_VERSION="2.0"
myHOSTNAME="$(hostname -f 2>/dev/null || hostname)"

# Directory where this script lives — all companion scripts are expected here (or below).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find vault_lib.sh dynamically
VAULT_LIB=$(find "$SCRIPT_DIR" -name "vault_lib.sh" -type f 2>/dev/null | head -1)

# Find vault_create_tnsnames.sh dynamically
VAULT_CREATE_TNSNAMES=$(find "$SCRIPT_DIR" -name "vault_create_tnsnames.sh" -type f 2>/dev/null | head -1)

SECRET_ENGINE="database"
TEMP_CRED="/tmp/temp_cred_$$.txt"
DRY_RUN=false
BARE_MODE=0
LOG_FILE=""
CREATE_WALLET=false
LIST_WALLET=false
TEST_WALLET=false
AUTO_LOGIN_LOCAL=false
DELETE_CREDENTIAL=false

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

# Check Oracle commands availability
checkOracleCommands() {
    local missing_cmds=()
    
    for cmd in orapki mkstore sqlplus; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_cmds+=("$cmd")
        fi
    done
    
    if [ ${#missing_cmds[@]} -gt 0 ]; then
        putMsg ERROR "Required Oracle commands not found in PATH: ${missing_cmds[*]}"
        putMsg ERROR "Please ensure ORACLE_HOME/bin is in your PATH or source the Oracle environment"
        exit 1
    fi
    
    putMsg INFO "Oracle commands verified: orapki, mkstore, sqlplus"
}

# =========================================================================================
# WALLET MANAGEMENT
# =========================================================================================

createWallet() {
    local wallet_dir="$1"
    local wallet_pwd="$2"
    local os_user="$3"
    
    if [ "$DRY_RUN" = true ]; then
        putMsg DRY "Would create new wallet at: $wallet_dir"
        return 0
    fi
    
    putMsg INFO "Creating new auto-login wallet..."
    
    CREATE_WALLET_SCRIPT=$(cat <<'WALLET_EOF'
#!/bin/bash
set -e
WALLET_DIR="$1"
WALLET_PWD="$2"

# Create wallet directory if it doesn't exist
mkdir -p "${WALLET_DIR}"

# Create wallet with auto-login
orapki wallet create -wallet "${WALLET_DIR}" -pwd "${WALLET_PWD}" -auto_login_local

echo "Wallet created successfully"
WALLET_EOF
)
    
    if sudo -u "$os_user" env PATH="$PATH" ORACLE_HOME="${ORACLE_HOME:-}" bash -c "$CREATE_WALLET_SCRIPT" bash "$wallet_dir" "$wallet_pwd"; then
        putMsg OK "✓ Wallet created successfully at: $wallet_dir"
        return 0
    else
        putMsg ERROR "Failed to create wallet"
        return 1
    fi
}

ensureTnsFiles() {
    local tns_admin="$1"
    local environment="$2"
    local db_instance="$3"
    local db_user="$4"
    local os_user="$5"
    local db_alias="${6:-}"  # Optional parameter
    
    local tnsnames_file="${tns_admin}/tnsnames.ora"
    local sqlnet_file="${tns_admin}/sqlnet.ora"
    local vault_script="$VAULT_CREATE_TNSNAMES"
    
    putMsg INFO "Checking TNS configuration files..."
    
    # Check and create tnsnames.ora
    if [ ! -f "$tnsnames_file" ]; then
        putMsg INFO "tnsnames.ora not found in $tns_admin"
        
        # Extract database name from alias if provided
        local db_name="$db_user"
        if [ -n "$db_alias" ] && [[ "$db_alias" =~ ^([A-Z0-9_]+)_(U|A)_ ]]; then
            db_name="${BASH_REMATCH[1]}"
            putMsg INFO "Extracted database name from alias: $db_name"
        fi
        
        if [ "$DRY_RUN" = true ]; then
            putMsg DRY "Would create tnsnames.ora using vault_create_tnsnames.sh"
            putMsg DRY "  Command: $vault_script -e $environment -i $db_instance -w -r '_${db_user}='"
            putMsg DRY "  Would move from tnsnames_wallet/tnsnames.ora.$environment to $tnsnames_file"
        else
            if [ ! -f "$vault_script" ]; then
                putMsg ERROR "vault_create_tnsnames.sh not found at: $vault_script"
                return 1
            fi
            
            putMsg INFO "Creating tnsnames.ora using vault_create_tnsnames.sh..."
            
            # Execute the vault_create_tnsnames.sh script
            local vault_script_dir
            vault_script_dir="$(dirname "$vault_script")"
            local temp_tnsnames="${vault_script_dir}/tnsnames_wallet/tnsnames.ora.${environment}"
            
            # Run the script to generate tnsnames.ora with exact user filter (match _USER= pattern)
            # Using _U_SINIS2= instead of just U_SINIS2 to avoid matching U_SINIS2I, U_SINIS2I_MIG, etc.
            local filter_pattern="_${db_user}="
            local failover_flag=""
            [[ "$FAILOVER" == true ]] && failover_flag="-f"
            if bash "$vault_script" -e "$environment" -i "$db_instance" -w -r "$filter_pattern" $failover_flag >/dev/null 2>&1; then
                # Check if the generated file exists
                if [ -f "$temp_tnsnames" ]; then
                    # Copy the filtered file (already contains only entries for this user)
                    if sudo -u "$os_user" cp "$temp_tnsnames" "$tnsnames_file"; then
                        sudo -u "$os_user" chmod 640 "$tnsnames_file"
                        putMsg OK "✓ tnsnames.ora created with entries for '$db_user'"
                    else
                        putMsg ERROR "Failed to copy tnsnames.ora to $tns_admin"
                        return 1
                    fi
                else
                    putMsg ERROR "Generated tnsnames.ora not found at: $temp_tnsnames"
                    return 1
                fi
            else
                putMsg ERROR "Failed to generate tnsnames.ora"
                return 1
            fi
        fi
    else
        putMsg OK "✓ tnsnames.ora already exists"
    fi
    
    # Check and create sqlnet.ora
    if [ ! -f "$sqlnet_file" ]; then
        putMsg INFO "sqlnet.ora not found in $tns_admin"
        
        if [ "$DRY_RUN" = true ]; then
            putMsg DRY "Would create sqlnet.ora with standard configuration"
        else
            putMsg INFO "Creating sqlnet.ora..."
            
            # Create sqlnet.ora with the provided content
            local sqlnet_content="# sqlnet.ora Network Configuration File:
# Application User connection using Secure External Password Store

NAMES.DIRECTORY_PATH= (TNSNAMES)

WALLET_LOCATION =
  (SOURCE =
    (METHOD = FILE)
    (METHOD_DATA =
      (DIRECTORY = \$TNS_ADMIN)
    )
   )

SQLNET.WALLET_OVERRIDE = TRUE
SSL_CLIENT_AUTHENTICATION = FALSE
SSL_VERSION = 0
"
            
            if sudo -u "$os_user" bash -c "cat > '$sqlnet_file'" <<< "$sqlnet_content"; then
                sudo -u "$os_user" chmod 640 "$sqlnet_file"
                putMsg OK "✓ sqlnet.ora created successfully"
            else
                putMsg ERROR "Failed to create sqlnet.ora"
                return 1
            fi
        fi
    else
        putMsg OK "✓ sqlnet.ora already exists"
    fi
    
    return 0
}

ensureTnsAlias() {
    local tns_admin="$1"
    local environment="$2"
    local db_instance="$3"
    local db_user="$4"
    local db_alias="$5"
    local os_user="$6"
    
    local tnsnames_file="${tns_admin}/tnsnames.ora"
    local vault_script="$VAULT_CREATE_TNSNAMES"
    
    # Check if tnsnames.ora exists
    if [ ! -f "$tnsnames_file" ]; then
        putMsg WARN "tnsnames.ora does not exist at $tns_admin"
        return 1
    fi
    
    # Check if alias already exists in tnsnames.ora
    if grep -qi "^[[:space:]]*${db_alias}[[:space:]]*=" "$tnsnames_file"; then
        putMsg OK "✓ Alias '$db_alias' already exists in tnsnames.ora"
        return 0
    fi
    
    putMsg INFO "Alias '$db_alias' not found in tnsnames.ora, adding it..."
    
    # Extract database name from alias (e.g., DB_ASIA_U_SINIS2 -> DB_ASIA)
    # User comes from -u parameter, no need to extract it from alias
    local db_name=""
    if [[ "$db_alias" =~ ^([A-Z0-9_]+)_(U|A)_ ]]; then
        db_name="${BASH_REMATCH[1]}"
        putMsg INFO "Extracted database name from alias: $db_name"
    else
        # Fallback: use db_user
        putMsg WARN "Could not parse alias '$db_alias', using db_user as fallback"
        db_name="$db_user"
    fi
    
    if [ "$DRY_RUN" = true ]; then
        putMsg DRY "Would add alias '$db_alias' to tnsnames.ora"
        putMsg DRY "  Database name: $db_name"
        putMsg DRY "  User: $db_user (from -u parameter)"
        putMsg DRY "  Command: $vault_script -e $environment -i $db_instance -w -r '_${db_user}='"
        putMsg DRY "  Would append generated entry to $tnsnames_file"
        return 0
    fi
    
    # Check if vault script exists
    if [ ! -f "$vault_script" ]; then
        putMsg ERROR "vault_create_tnsnames.sh not found at: $vault_script"
        return 1
    fi
    
    # Generate tnsnames entry using vault_create_tnsnames.sh
    local vault_script_dir
    vault_script_dir="$(dirname "$vault_script")"
    local temp_tnsnames="${vault_script_dir}/tnsnames_wallet/tnsnames.ora.${environment}"
    
    # Run the script to generate tnsnames.ora with exact user filter (match _USER= pattern)
    # Using _U_SINIS2= instead of just U_SINIS2 to avoid matching U_SINIS2I, U_SINIS2I_MIG, etc.
    local filter_pattern="_${db_user}="
    local failover_flag=""
    [[ "$FAILOVER" == true ]] && failover_flag="-f"
    if bash "$vault_script" -e "$environment" -i "$db_instance" -w -r "$filter_pattern" $failover_flag >/dev/null 2>&1; then
        # Check if the generated file exists
        if [ -f "$temp_tnsnames" ]; then
            # The generated file should already contain only filtered entries
            # Append content to tnsnames.ora
            if sudo -u "$os_user" bash -c "echo '' >> '$tnsnames_file' && echo '# Added by oracleWalletToolkit.sh on $(date)' >> '$tnsnames_file' && cat '$temp_tnsnames' | grep -v '^#' | grep -v '^[[:space:]]*$' >> '$tnsnames_file'"; then
                putMsg OK "✓ Alias(es) for '$db_user' added to tnsnames.ora"
                return 0
            else
                putMsg ERROR "Failed to append entries to tnsnames.ora"
                return 1
            fi
        else
            putMsg ERROR "Generated tnsnames.ora not found at: $temp_tnsnames"
            return 1
        fi
    else
        putMsg ERROR "Failed to generate tnsnames entry for user '$db_user'"
        return 1
    fi
}

ensureAutoLoginLocal() {
    local wallet_dir="$1"
    local wallet_pwd="$2"
    local os_user="$3"
    
    # Convert to absolute path if relative
    if [[ ! "$wallet_dir" = /* ]]; then
        wallet_dir="$(cd "$wallet_dir" 2>/dev/null && pwd)" || {
            putMsg ERROR "Cannot access wallet directory: $1"
            return 1
        }
    fi
    
    putMsg INFO "========================================"
    putMsg INFO "Converting Wallet to Auto-Login-Local"
    putMsg INFO "========================================"
    putMsg INFO "Wallet Location: $wallet_dir"
    putMsg INFO "========================================"
    
    if [ "$DRY_RUN" = true ]; then
        putMsg DRY "Would convert wallet to auto-login-local at: $wallet_dir"
        putMsg DRY "Command: orapki wallet create_autologin_local -wallet ${wallet_dir} -pwd <password>"
        putMsg DRY "Executed as user: ${os_user}"
        putMsg INFO "========================================"
        return 0
    fi
    
    # Check if ewallet.p12 exists (required for conversion)
    if [ ! -f "$wallet_dir/ewallet.p12" ]; then
        putMsg ERROR "ewallet.p12 not found in: $wallet_dir"
        putMsg ERROR "Cannot convert wallet - password-protected wallet file is required"
        return 1
    fi
    
    putMsg INFO "Converting wallet to auto-login-local (CIS compliant)..."
    
    # Convert wallet to auto-login-local
    CONVERT_WALLET_SCRIPT=$(cat <<'CONVERT_EOF'
#!/bin/bash
set -e
WALLET_DIR="$1"
WALLET_PWD="$2"

# Create/regenerate auto-login-local wallet (overwrites cwallet.sso if it exists)
orapki wallet create -wallet "${WALLET_DIR}" -pwd "${WALLET_PWD}" -auto_login_local

echo "Wallet converted to auto-login-local successfully"
CONVERT_EOF
)
    
    if sudo -u "$os_user" env PATH="$PATH" ORACLE_HOME="${ORACLE_HOME:-}" bash -c "$CONVERT_WALLET_SCRIPT" bash "$wallet_dir" "$wallet_pwd"; then
        putMsg OK "✓ Wallet converted to auto-login-local successfully"
        putMsg INFO "========================================"
        return 0
    else
        putMsg ERROR "Failed to convert wallet to auto-login-local"
        putMsg ERROR "Check: wallet password, wallet files integrity, and permissions"
        return 1
    fi
}

listWalletEntries() {
    local wallet_dir="$1"
    local wallet_pwd="$2"
    local os_user="$3"
    
    # Convert to absolute path if relative
    if [[ ! "$wallet_dir" = /* ]]; then
        wallet_dir="$(cd "$wallet_dir" 2>/dev/null && pwd)" || {
            putMsg ERROR "Cannot access wallet directory: $1"
            return 1
        }
    fi
    
    putMsg INFO "========================================"
    putMsg INFO "Wallet Credentials List"
    putMsg INFO "========================================"
    putMsg INFO "Wallet Location: $wallet_dir"
    putMsg INFO "========================================"
    
    if [ "$DRY_RUN" = true ]; then
        putMsg DRY "Would list credentials from wallet at: $wallet_dir"
        putMsg DRY "Command: echo '<password>' | mkstore -wrl ${wallet_dir} -listCredential"
        putMsg DRY "Executed as user: ${os_user}"
        putMsg INFO "========================================"
        return 0
    fi
    
    # Note: -listCredential always requires the master password via stdin,
    # even for auto-login wallets (cwallet.sso). Auto-login only works for
    # Oracle connections, not for wallet management operations.
    LIST_WALLET_SCRIPT=$(cat <<'LIST_EOF'
#!/bin/bash
set -e
WALLET_DIR="$1"
WALLET_PWD="$2"

export TNS_ADMIN="${WALLET_DIR}"

# List credentials - password required even for auto-login wallets
echo "${WALLET_PWD}" | mkstore -wrl "${WALLET_DIR}" -listCredential
LIST_EOF
)
    
    if sudo -u "$os_user" env PATH="$PATH" ORACLE_HOME="${ORACLE_HOME:-}" bash -c "$LIST_WALLET_SCRIPT" bash "$wallet_dir" "$wallet_pwd" 2>&1; then
        putMsg INFO "========================================"
        return 0
    else
        putMsg ERROR "Failed to list wallet credentials"
        putMsg ERROR "Check: wallet password, wallet files integrity, and permissions"
        return 1
    fi
}

testWalletEntries() {
    local wallet_dir="$1"
    local wallet_pwd="$2"
    local os_user="$3"
    
    # Convert to absolute path if relative
    if [[ ! "$wallet_dir" = /* ]]; then
        wallet_dir="$(cd "$wallet_dir" 2>/dev/null && pwd)" || {
            putMsg ERROR "Cannot access wallet directory: $1"
            return 1
        }
    fi
    
    putMsg INFO "========================================"
    putMsg INFO "Testing Wallet Credentials"
    putMsg INFO "========================================"
    putMsg INFO "Wallet Location: $wallet_dir"
    putMsg INFO "========================================"
    
    if [ "$DRY_RUN" = true ]; then
        putMsg DRY "Would test all credentials from wallet at: $wallet_dir"
        putMsg DRY "Would list credentials and test each connection"
        putMsg INFO "========================================"
        return 0
    fi
    
    # Get list of credentials from wallet
    LIST_WALLET_SCRIPT=$(cat <<'LIST_EOF'
#!/bin/bash
set -e
WALLET_DIR="$1"
WALLET_PWD="$2"

export TNS_ADMIN="${WALLET_DIR}"

# List credentials and extract TNS aliases
echo "${WALLET_PWD}" | mkstore -wrl "${WALLET_DIR}" -listCredential 2>&1
LIST_EOF
)
    
    local list_output
    list_output=$(sudo -u "$os_user" env PATH="$PATH" ORACLE_HOME="${ORACLE_HOME:-}" bash -c "$LIST_WALLET_SCRIPT" bash "$wallet_dir" "$wallet_pwd" 2>&1)
    
    if [ $? -ne 0 ]; then
        putMsg ERROR "Failed to list wallet credentials"
        putMsg ERROR "Output: $list_output"
        return 1
    fi
    
    # Extract TNS aliases from the output
    # The output format is typically:
    # Oracle Secret Store entries: 
    # 1: oracle.security.client.connect_string1=ALIAS1
    # 2: oracle.security.client.connect_string2=ALIAS2
    local aliases=()
    while IFS= read -r line; do
        # Match lines like "oracle.security.client.connect_string1=ALIAS1"
        if [[ "$line" =~ oracle\.security\.client\.connect_string[0-9]+=([A-Za-z0-9_]+) ]]; then
            aliases+=("${BASH_REMATCH[1]}")
        elif [[ "$line" =~ ^[0-9]+:[[:space:]]*([A-Za-z0-9_]+) ]]; then
            # Alternative format: "1: ALIAS1"
            aliases+=("${BASH_REMATCH[1]}")
        fi
    done <<< "$list_output"
    
    if [ ${#aliases[@]} -eq 0 ]; then
        putMsg WARN "No credentials found in wallet"
        putMsg INFO "Raw output:"
        echo "$list_output"
        putMsg INFO "========================================"
        return 0
    fi
    
    putMsg INFO "Found ${#aliases[@]} credential(s) in wallet"
    echo ""
    
    # Arrays to track success and failures
    local success_aliases=()
    local failed_aliases=()
    local test_count=0
    
    # Test each alias
    for alias in "${aliases[@]}"; do
        ((test_count++))
        putMsg INFO "[$test_count/${#aliases[@]}] Testing connection: $alias"
        
        TEST_SCRIPT=$(cat <<TEST_EOF
#!/bin/bash
export TNS_ADMIN="${wallet_dir}"

# Test connection with timeout
timeout 10 bash -c 'echo -e "connect /@${alias}\\nselect '"'"'TEST_OK'"'"', sysdate from dual;\\nexit;" | sqlplus -S /nolog' 2>&1
TEST_EOF
)
        
        local test_output
        test_output=$(sudo -u "$os_user" env PATH="$PATH" ORACLE_HOME="${ORACLE_HOME:-}" bash -c "$TEST_SCRIPT" 2>&1)
        local test_rc=$?
        
        if [ $test_rc -eq 0 ] && echo "$test_output" | grep -q "TEST_OK"; then
            putMsg OK "  ✓ Connection test successful"
            success_aliases+=("$alias")
        else
            putMsg ERROR "  ✗ Connection test failed"
            # Show only the first error line (not all output)
            local error_msg
            error_msg=$(echo "$test_output" | grep -i "error\|ora-" | head -1 || echo "Connection failed")
            if [ -n "$error_msg" ]; then
                putMsg ERROR "    Error: $error_msg"
            fi
            failed_aliases+=("$alias")
        fi
        echo ""
    done
    
    # Print summary report
    putMsg INFO "========================================"
    putMsg INFO "Test Summary Report"
    putMsg INFO "========================================"
    putMsg INFO "Total credentials tested: ${#aliases[@]}"
    putMsg OK "Successful connections: ${#success_aliases[@]}"
    
    # Show failed connections with ERROR only if there are failures
    if [ ${#failed_aliases[@]} -gt 0 ]; then
        putMsg ERROR "Failed connections: ${#failed_aliases[@]}"
    else
        putMsg OK "Failed connections: 0"
    fi
    
    putMsg INFO "========================================"
    
    if [ ${#success_aliases[@]} -gt 0 ]; then
        putMsg OK "Successful aliases:"
        for alias in "${success_aliases[@]}"; do
            putMsg OK "  ✓ $alias"
        done
        echo ""
    fi
    
    if [ ${#failed_aliases[@]} -gt 0 ]; then
        putMsg ERROR "Failed aliases:"
        for alias in "${failed_aliases[@]}"; do
            putMsg ERROR "  ✗ $alias"
        done
        echo ""
    fi
    
    putMsg INFO "========================================"
    
    # Return non-zero if any test failed
    if [ ${#failed_aliases[@]} -gt 0 ]; then
        return 1
    fi
    
    return 0
}

# =========================================================================================
# CLEANUP & SETUP
# =========================================================================================

# Cleanup function
cleanup() {
    if [ -f "$TEMP_CRED" ]; then
        rm -f "$TEMP_CRED"
    fi
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Usage function
usage() {
    cat <<EOF
Usage: $0 -u <db_user> -i <oracle_instance> -e <environment> -a <db_alias> -t <tns_admin> -o <os_user> -w <master_wallet> -U <vault_user> -P <vault_pass> [-c] [-L] [-T] [-A] [-d] [-b] [-l <logfile>]

Parameters:
  -u db_user        - Database user name (required for config mode)
  -i oracle_instance - Oracle instance name (required for config mode)
  -e environment    - Environment code: svi, int, tst, pre, prd (required for config mode)
  -a db_alias       - TNS alias for the connection (required for config mode)
  -t tns_admin      - Path to TNS_ADMIN directory/wallet location (required)
  -o os_user        - OS user that owns the wallet files (required)
  -w master_wallet  - Master wallet password (required)
  -U vault_username - Vault username for authentication (required for config mode)
  -P vault_password - Vault password for authentication (required for config mode)
  -c                - Create wallet if it doesn't exist (standalone: only requires -t, -o, -w; or with config mode)
  -L                - List wallet credentials and exit (only requires -t, -o, -w)
  -T                - Test all wallet credentials and show report (only requires -t, -o, -w)
  -A                - Convert wallet to auto-login-local/CIS compliant (only requires -t, -o, -w)
  -d                - Dry-run mode (show what would be done without doing it)
  -f                - Generate TNS entries in failover mode (FAILOVER=true, with FAILOVER_MODE)
  -b                - Bare mode (minimal output, disables coloring)
  -l logfile        - Optional log file path
  -h                - Show this help message

Examples:
  # Configure credentials in existing wallet
  $0 -u A_IDL -i svi0 -e svi -a SVI0_A_IDL -t /app/user/SVI0/conf/base/service/tns_admin \
-o appuser -w 'wallet_pass' -U vault_user -P 'vault_pass'

  # Create empty wallet only (no Vault credentials required)
  $0 -t /app/user/SVI0/conf/base/service/tns_admin -o appuser -w 'wallet_pass' -c

  # Create wallet if it doesn't exist, then configure
  $0 -u U_BATCH -i prd1 -e prd -a PRD1_U_BATCH -t /app/user/PRD1/conf/base/service/tns_admin \
-o oracle -w 'wallet_pass' -U vault_user -P 'vault_pass' -c

  # With logging
  $0 -u A_IDL -i svi0 -e svi -a SVI0_A_IDL -t /app/user/SVI0/conf/base/service/tns_admin \
-o appuser -w 'wallet_pass' -U vault_user -P 'vault_pass' -l /var/log/configpwd.log

  # List wallet credentials
  $0 -t /app/user/SVI0/conf/base/service/tns_admin -o appuser -w 'wallet_pass' -L

  # Test all wallet credentials
  $0 -t /app/user/SVI0/conf/base/service/tns_admin -o appuser -w 'wallet_pass' -T

  # Convert wallet to auto-login-local (CIS compliant)
  $0 -t /app/user/SVI0/conf/base/service/tns_admin -o appuser -w 'wallet_pass' -A

Description:
  This script configures credentials in an Oracle wallet by retrieving them from
  HashiCorp Vault. It performs the following steps:
  1. Checks Vault status and unseals if necessary
  2. Retrieves credentials from Vault for the specified database user
  3. Adds or updates credentials in the Oracle wallet using mkstore
  4. Tests the connection using the wallet credentials
  5. Updates metadata information in Vault

Note:
  - This script must be run with privileges to switch to the wallet owner user (sudo)
  - The os_user is the OS user that owns the wallet files (e.g., oracle, appuser)
  - The db_user is the database username stored in the wallet (e.g., A_IDL, U_BATCH)
  - Oracle commands (orapki, mkstore, sqlplus) must be available in PATH
  - Use -c option to create wallet if it doesn't exist in TNS_ADMIN directory
  - The vault_lib.sh must be available at: $VAULT_LIB
EOF
    exit 0
}

# Parse command line arguments (must be done before setColor)
DB_USER=""
ORACLE_INSTANCE=""
ENVIRONMENT=""
DB_ALIAS=""
TNS_ADMIN=""
OS_USER=""
MASTER_WALLET=""
VAULT_USERNAME=""
VAULT_PASSWORD=""
FAILOVER=false

while getopts "u:i:e:a:t:o:w:U:P:l:cLTADdbfh" opt; do
    case ${opt} in
        u)
            DB_USER=$OPTARG
            ;;
        i)
            ORACLE_INSTANCE=$OPTARG
            ;;
        e)
            ENVIRONMENT=$OPTARG
            ;;
        a)
            DB_ALIAS=$OPTARG
            ;;
        t)
            TNS_ADMIN=$OPTARG
            ;;
        o)
            OS_USER=$OPTARG
            ;;
        w)
            MASTER_WALLET=$OPTARG
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
        c)
            CREATE_WALLET=true
            ;;
        L)
            LIST_WALLET=true
            ;;
        T)
            TEST_WALLET=true
            ;;
        A)
            AUTO_LOGIN_LOCAL=true
            ;;
        D)
            DELETE_CREDENTIAL=true
            ;;
        d)
            DRY_RUN=true
            ;;
        f)
            FAILOVER=true
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

# Handle LIST_WALLET mode (special case with different required parameters)
if [ "$LIST_WALLET" = true ]; then
    # Validate required parameters for list mode
    if [ -z "$TNS_ADMIN" ] || [ -z "$OS_USER" ] || [ -z "$MASTER_WALLET" ]; then
        putMsg ERROR "List mode requires: -t <tns_admin> -o <os_user> -w <master_wallet>"
        usage
    fi
    
    # Convert TNS_ADMIN to absolute path if relative
    if [[ ! "$TNS_ADMIN" = /* ]]; then
        TNS_ADMIN_ABS="$(cd "$TNS_ADMIN" 2>/dev/null && pwd)" || {
            putMsg ERROR "Cannot access TNS_ADMIN directory: $TNS_ADMIN"
            exit 1
        }
        TNS_ADMIN="$TNS_ADMIN_ABS"
    fi
    
    # Check Oracle commands availability
    checkOracleCommands
    
    # Check if wallet directory exists
    if [ ! -d "$TNS_ADMIN" ]; then
        putMsg ERROR "TNS_ADMIN directory not found: $TNS_ADMIN"
        exit 1
    fi
    
    # Check if wallet exists
    if [ ! -f "$TNS_ADMIN/cwallet.sso" ] && [ ! -f "$TNS_ADMIN/ewallet.p12" ]; then
        putMsg ERROR "Oracle wallet not found in: $TNS_ADMIN"
        putMsg ERROR "Expected cwallet.sso or ewallet.p12 file"
        exit 1
    fi
    
    # List wallet entries and exit
    if listWalletEntries "$TNS_ADMIN" "$MASTER_WALLET" "$OS_USER"; then
        exit 0
    else
        exit 1
    fi
fi

# Handle TEST_WALLET mode (special case with different required parameters)
if [ "$TEST_WALLET" = true ]; then
    # Validate required parameters for test mode
    if [ -z "$TNS_ADMIN" ] || [ -z "$OS_USER" ] || [ -z "$MASTER_WALLET" ]; then
        putMsg ERROR "Test mode requires: -t <tns_admin> -o <os_user> -w <master_wallet>"
        usage
    fi
    
    # Convert TNS_ADMIN to absolute path if relative
    if [[ ! "$TNS_ADMIN" = /* ]]; then
        TNS_ADMIN_ABS="$(cd "$TNS_ADMIN" 2>/dev/null && pwd)" || {
            putMsg ERROR "Cannot access TNS_ADMIN directory: $TNS_ADMIN"
            exit 1
        }
        TNS_ADMIN="$TNS_ADMIN_ABS"
    fi
    
    # Check Oracle commands availability
    checkOracleCommands
    
    # Check if wallet directory exists
    if [ ! -d "$TNS_ADMIN" ]; then
        putMsg ERROR "TNS_ADMIN directory not found: $TNS_ADMIN"
        exit 1
    fi
    
    # Check if wallet exists
    if [ ! -f "$TNS_ADMIN/cwallet.sso" ] && [ ! -f "$TNS_ADMIN/ewallet.p12" ]; then
        putMsg ERROR "Oracle wallet not found in: $TNS_ADMIN"
        putMsg ERROR "Expected cwallet.sso or ewallet.p12 file"
        exit 1
    fi
    
    # Check if tnsnames.ora exists
    if [ ! -f "$TNS_ADMIN/tnsnames.ora" ]; then
        putMsg ERROR "tnsnames.ora not found in: $TNS_ADMIN"
        putMsg ERROR "TNS configuration file is required for connection testing"
        exit 1
    fi
    
    # Test wallet entries and exit
    if testWalletEntries "$TNS_ADMIN" "$MASTER_WALLET" "$OS_USER"; then
        exit 0
    else
        exit 1
    fi
fi

# Handle DELETE_CREDENTIAL mode
if [ "$DELETE_CREDENTIAL" = true ]; then
    # Validate required parameters
    if [ -z "$TNS_ADMIN" ] || [ -z "$OS_USER" ] || [ -z "$MASTER_WALLET" ] || [ -z "$DB_ALIAS" ]; then
        putMsg ERROR "Delete credential mode requires: -t <tns_admin> -o <os_user> -w <master_wallet> -a <db_alias>"
        usage
    fi

    # Convert TNS_ADMIN to absolute path if relative
    if [[ ! "$TNS_ADMIN" = /* ]]; then
        TNS_ADMIN_ABS="$(cd "$TNS_ADMIN" 2>/dev/null && pwd)" || {
            putMsg ERROR "Cannot access TNS_ADMIN directory: $TNS_ADMIN"
            exit 1
        }
        TNS_ADMIN="$TNS_ADMIN_ABS"
    fi

    # Check Oracle commands availability
    checkOracleCommands

    # Check if wallet directory exists
    if [ ! -d "$TNS_ADMIN" ]; then
        putMsg ERROR "TNS_ADMIN directory not found: $TNS_ADMIN"
        exit 1
    fi

    # Check if wallet exists
    if [ ! -f "$TNS_ADMIN/cwallet.sso" ] && [ ! -f "$TNS_ADMIN/ewallet.p12" ]; then
        putMsg ERROR "Oracle wallet not found in: $TNS_ADMIN"
        putMsg ERROR "Expected cwallet.sso or ewallet.p12 file"
        exit 1
    fi

    if [ "$DRY_RUN" = true ]; then
        putMsg DRY "Would delete credential '$DB_ALIAS' from wallet at: $TNS_ADMIN"
        putMsg DRY "  Command: mkstore -wrl $TNS_ADMIN -deleteCredential $DB_ALIAS"
        exit 0
    fi

    putMsg INFO "Deleting credential '$DB_ALIAS' from wallet..."
    DELETE_SCRIPT=$(cat <<'DELETE_EOF'
#!/bin/bash
set -e
WALLET_DIR="$1"
WALLET_PWD="$2"
DB_ALIAS="$3"
mkstore -wrl "${WALLET_DIR}" -deleteCredential "${DB_ALIAS}" <<< "${WALLET_PWD}"
DELETE_EOF
)
    if sudo -u "$OS_USER" env PATH="$PATH" ORACLE_HOME="${ORACLE_HOME:-}" \
        bash -c "$DELETE_SCRIPT" bash "$TNS_ADMIN" "$MASTER_WALLET" "$DB_ALIAS"; then
        putMsg OK "✓ Credential '$DB_ALIAS' deleted successfully"
        exit 0
    else
        putMsg ERROR "Failed to delete credential '$DB_ALIAS'"
        exit 1
    fi
fi

# Handle AUTO_LOGIN_LOCAL mode (special case with different required parameters)
if [ "$AUTO_LOGIN_LOCAL" = true ]; then
    # Validate required parameters for auto-login-local mode
    if [ -z "$TNS_ADMIN" ] || [ -z "$OS_USER" ] || [ -z "$MASTER_WALLET" ]; then
        putMsg ERROR "Auto-login-local mode requires: -t <tns_admin> -o <os_user> -w <master_wallet>"
        usage
    fi
    
    # Convert TNS_ADMIN to absolute path if relative
    if [[ ! "$TNS_ADMIN" = /* ]]; then
        TNS_ADMIN_ABS="$(cd "$TNS_ADMIN" 2>/dev/null && pwd)" || {
            putMsg ERROR "Cannot access TNS_ADMIN directory: $TNS_ADMIN"
            exit 1
        }
        TNS_ADMIN="$TNS_ADMIN_ABS"
    fi
    
    # Check Oracle commands availability
    checkOracleCommands
    
    # Check if wallet directory exists
    if [ ! -d "$TNS_ADMIN" ]; then
        putMsg ERROR "TNS_ADMIN directory not found: $TNS_ADMIN"
        exit 1
    fi
    
    # Check if wallet exists
    if [ ! -f "$TNS_ADMIN/ewallet.p12" ]; then
        putMsg ERROR "Oracle wallet (ewallet.p12) not found in: $TNS_ADMIN"
        putMsg ERROR "Password-protected wallet file is required for conversion"
        exit 1
    fi
    
    # Convert wallet to auto-login-local and exit
    if ensureAutoLoginLocal "$TNS_ADMIN" "$MASTER_WALLET" "$OS_USER"; then
        exit 0
    else
        exit 1
    fi
fi

# Handle CREATE_WALLET standalone mode (special case with different required parameters)
if [ "$CREATE_WALLET" = true ] && [ -z "$DB_USER" ]; then
    # Validate required parameters for create-only mode
    if [ -z "$TNS_ADMIN" ] || [ -z "$OS_USER" ] || [ -z "$MASTER_WALLET" ]; then
        putMsg ERROR "Create wallet mode requires: -t <tns_admin> -o <os_user> -w <master_wallet>"
        usage
    fi
    
    # Convert TNS_ADMIN to absolute path if relative
    if [[ ! "$TNS_ADMIN" = /* ]]; then
        TNS_ADMIN_ABS="$(cd "$TNS_ADMIN" 2>/dev/null && pwd)" || {
            putMsg ERROR "Cannot access TNS_ADMIN directory: $TNS_ADMIN"
            exit 1
        }
        TNS_ADMIN="$TNS_ADMIN_ABS"
    fi
    
    # Check Oracle commands availability
    checkOracleCommands
    
    # Check if wallet already exists
    if [ -f "$TNS_ADMIN/cwallet.sso" ] || [ -f "$TNS_ADMIN/ewallet.p12" ]; then
        putMsg INFO "Wallet already exists in: $TNS_ADMIN"
        putMsg OK "No action needed - wallet is already present"
        exit 0
    fi
    
    # Create wallet and exit
    if createWallet "$TNS_ADMIN" "$MASTER_WALLET" "$OS_USER"; then
        putMsg OK "Empty wallet created successfully"
        putMsg INFO "You can now add credentials using mkstore or configure them with this script"
        exit 0
    else
        exit 1
    fi
fi

# Validate required parameters for normal configuration mode
if [ -z "$DB_USER" ] || [ -z "$ORACLE_INSTANCE" ] || [ -z "$ENVIRONMENT" ] || [ -z "$DB_ALIAS" ] || \
   [ -z "$TNS_ADMIN" ] || [ -z "$OS_USER" ] || [ -z "$MASTER_WALLET" ] || \
   [ -z "$VAULT_USERNAME" ] || [ -z "$VAULT_PASSWORD" ]; then
    putMsg ERROR "Missing required parameters"
    usage
fi

# Check Oracle commands availability
checkOracleCommands

# Convert TNS_ADMIN to absolute path if relative
if [[ ! "$TNS_ADMIN" = /* ]]; then
    TNS_ADMIN_ABS="$(cd "$TNS_ADMIN" 2>/dev/null && pwd)" || {
        putMsg ERROR "Cannot access TNS_ADMIN directory: $TNS_ADMIN"
        exit 1
    }
    TNS_ADMIN="$TNS_ADMIN_ABS"
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

# Normalize oracle instance to lowercase
ORACLE_INSTANCE_LOWER=$(echo "$ORACLE_INSTANCE" | tr '[:upper:]' '[:lower:]')

# Check if TNS_ADMIN directory exists
if [ ! -d "$TNS_ADMIN" ]; then
    if [ "$CREATE_WALLET" = true ]; then
        putMsg INFO "TNS_ADMIN directory will be created: $TNS_ADMIN"
    else
        putMsg ERROR "TNS_ADMIN directory not found at: $TNS_ADMIN"
        exit 1
    fi
fi

# Check if Oracle wallet exists in TNS_ADMIN directory
if [ ! -f "$TNS_ADMIN/cwallet.sso" ] && [ ! -f "$TNS_ADMIN/ewallet.p12" ]; then
    if [ "$CREATE_WALLET" = true ]; then
        putMsg INFO "Wallet not found. Will create new wallet."
        if ! createWallet "$TNS_ADMIN" "$MASTER_WALLET" "$OS_USER"; then
            exit 1
        fi
        
        # Ensure TNS files exist after wallet creation
        putMsg INFO "Ensuring TNS configuration files are present..."
        if ! ensureTnsFiles "$TNS_ADMIN" "$ENVIRONMENT" "$ORACLE_INSTANCE_LOWER" "$DB_USER" "$OS_USER" "$DB_ALIAS"; then
            putMsg ERROR "Failed to create TNS configuration files"
            exit 1
        fi
    else
        putMsg ERROR "Oracle wallet not found in TNS_ADMIN directory: $TNS_ADMIN"
        putMsg ERROR "Expected cwallet.sso or ewallet.p12 file"
        putMsg ERROR "Use -c option to create a new wallet"
        exit 1
    fi
fi

# Source vault library (only needed for normal configuration mode)
# Check if vault_lib.sh exists
if [ -z "$VAULT_LIB" ] || [ ! -f "$VAULT_LIB" ]; then
    putMsg ERROR "vault_lib.sh not found in $SCRIPT_DIR"
	VAULT_LIB=$(find "/products/software/sysadm" -name "vault_lib.sh" -type f 2>/dev/null | head -1)
	
	if [ -z "$VAULT_LIB" ]; then
		putMsg ERROR "vault_lib.sh not found in /products/software/sysadm"
		putMsg ERROR "vault_lib.sh is required for Vault operations"
    	exit 1
	fi
fi

# Check if vault_create_tnsnames.sh exists
if [ -z "$VAULT_CREATE_TNSNAMES" ] || [ ! -f "$VAULT_CREATE_TNSNAMES" ]; then
    putMsg ERROR "vault_create_tnsnames.sh not found in $SCRIPT_DIR"
    exit 1
fi

# Source vault library
# shellcheck source=vault_lib.sh
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

putMsg OK "========================================"
putMsg OK "Oracle Wallet Configuration v${SCRIPT_VERSION}"
putMsg OK "========================================"
putMsg INFO "Database User    : $DB_USER"
putMsg INFO "Oracle Instance  : $ORACLE_INSTANCE"
putMsg INFO "Environment      : $ENVIRONMENT"
putMsg INFO "DB Alias         : $DB_ALIAS"
putMsg INFO "TNS_ADMIN        : $TNS_ADMIN"
putMsg INFO "Wallet Owner     : $OS_USER"
putMsg OK "========================================="

# Construct vault path
PATH_SECRET="${ENVIRONMENT}/paas/oracle/${ORACLE_INSTANCE_LOWER}"
putMsg INFO "Vault path: $PATH_SECRET/$DB_USER"

# Check Vault status
if [ "$DRY_RUN" = true ]; then
    putMsg DRY "Would check Vault status"
    putMsg DRY "Assuming Vault is unsealed"
else
    putMsg INFO "Checking Vault status..."
    hc_vault_is_sealed
    if [ $? -eq 1 ]; then
        putMsg WARN "Vault is sealed. Please unseal it manually."
        putMsg WARN "This script does not handle vault unsealing for security reasons."
        exit 1
    fi
    putMsg OK "✓ Vault is unsealed"
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

# Retrieve credentials from Vault
if [ "$DRY_RUN" = true ]; then
    putMsg DRY "Would retrieve credentials from Vault"
    putMsg DRY "  Path: ${PATH_SECRET}/${DB_USER}"
    putMsg DRY "  Key: ${DB_USER}"
    response="DryRunPassword1234567890ab"
    echo "$response" > "$TEMP_CRED"
else
    putMsg INFO "Retrieving credentials from Vault..."
    # Temporarily disable unbound variable check for vault_lib.sh compatibility
    set +u
    response=$(hc_vault_read "$SECRET_ENGINE" "${PATH_SECRET}/${DB_USER}" "${token}" | jq -r ".${DB_USER}")
    set -u
    
    if [ -z "$response" ] || [ "$response" == "null" ]; then
        putMsg ERROR "Failed to retrieve credentials from Vault"
        putMsg ERROR "Path: ${PATH_SECRET}/${DB_USER}"
        exit 1
    fi
    
    echo "$response" > "$TEMP_CRED"
    putMsg OK "✓ Credentials retrieved successfully"
fi

# Ensure TNS alias exists in tnsnames.ora
if [ -f "$TNS_ADMIN/tnsnames.ora" ]; then
    putMsg INFO "Checking if TNS alias exists in tnsnames.ora..."
    if ! ensureTnsAlias "$TNS_ADMIN" "$ENVIRONMENT" "$ORACLE_INSTANCE_LOWER" "$DB_USER" "$DB_ALIAS" "$OS_USER"; then
        putMsg WARN "Could not ensure TNS alias exists - connection test may fail"
    fi
else
    putMsg WARN "tnsnames.ora not found in $TNS_ADMIN"
    putMsg WARN "Creating tnsnames.ora and sqlnet.ora..."
    if ! ensureTnsFiles "$TNS_ADMIN" "$ENVIRONMENT" "$ORACLE_INSTANCE_LOWER" "$DB_USER" "$OS_USER" "$DB_ALIAS"; then
        putMsg WARN "Failed to create TNS configuration files - connection test may fail"
    fi
fi

# Add or update credentials in wallet
if [ "$DRY_RUN" = true ]; then
    putMsg DRY "Would configure wallet credentials"
    putMsg DRY "  Wallet path: ${TNS_ADMIN}"
    putMsg DRY "  DB alias: ${DB_ALIAS}"
    putMsg DRY "  DB user: ${DB_USER}"
    putMsg DRY "  Command: mkstore -wrl ${TNS_ADMIN} -createCredential ${DB_ALIAS} ${DB_USER}"
    putMsg DRY "  If exists: mkstore -wrl ${TNS_ADMIN} -modifyCredential ${DB_ALIAS} ${DB_USER}"
    putMsg DRY "  Executed as user: ${OS_USER}"
else
    putMsg INFO "Configuring wallet credentials..."
    
    # Create the mkstore command script
    MKSTORE_SCRIPT=$(cat <<MKSTORE_EOF
#!/bin/bash
set -e
export TNS_ADMIN=${TNS_ADMIN}

# Try to create credential
if mkstore -wrl ${TNS_ADMIN} -createCredential ${DB_ALIAS} ${DB_USER} <<CREATE_EOF
\$(cat ${TEMP_CRED})
\$(cat ${TEMP_CRED})
${MASTER_WALLET}
CREATE_EOF
then
    echo "Credential created successfully"
else
    RC=\$?
    if [ \$RC -ne 0 ]; then
        echo "Credential already exists, updating..."
        mkstore -wrl ${TNS_ADMIN} -modifyCredential ${DB_ALIAS} ${DB_USER} <<MODIFY_EOF
\$(cat ${TEMP_CRED})
\$(cat ${TEMP_CRED})
${MASTER_WALLET}
MODIFY_EOF
        echo "Credential updated successfully"
    else
        exit \$RC
    fi
fi
MKSTORE_EOF
)
    
    # Execute as the wallet owner user
    if sudo -u "$OS_USER" env PATH="$PATH" ORACLE_HOME="${ORACLE_HOME:-}" bash -c "$MKSTORE_SCRIPT"; then
        putMsg OK "✓ Wallet configured successfully"
    else
        putMsg ERROR "Failed to configure wallet"
        exit 1
    fi
fi

# Test connection
# Check if tnsnames.ora exists before attempting connection test
if [ ! -f "$TNS_ADMIN/tnsnames.ora" ]; then
    putMsg WARN "tnsnames.ora not found in $TNS_ADMIN - skipping connection test"
    putMsg WARN "Please ensure you create/copy tnsnames.ora and sqlnet.ora to configure TNS aliases"
    putMsg INFO "Wallet has been configured successfully but connection cannot be verified"
elif [ "$DRY_RUN" = true ]; then
    putMsg DRY "Would test connection"
    putMsg DRY "  Command: sqlplus /@${DB_ALIAS}"
    putMsg DRY "  SQL: select 'TEST_OK', sysdate from dual"
    putMsg DRY "  Executed as user: ${OS_USER}"
else
    # Verify that the DB alias exists in tnsnames.ora
    if ! grep -qi "^[[:space:]]*${DB_ALIAS}[[:space:]]*=" "$TNS_ADMIN/tnsnames.ora"; then
        putMsg WARN "DB alias '${DB_ALIAS}' not found in tnsnames.ora - skipping connection test"
        putMsg WARN "Please add TNS entry for '${DB_ALIAS}' in $TNS_ADMIN/tnsnames.ora"
        putMsg INFO "Wallet has been configured successfully but connection cannot be verified"
    else
        putMsg INFO "Testing connection..."
        
        TEST_SCRIPT=$(cat <<TEST_EOF
#!/bin/bash
set -e
export TNS_ADMIN=${TNS_ADMIN}

echo -e "connect /@${DB_ALIAS}\\nselect 'TEST_OK', sysdate from dual;\\nexit;" | sqlplus -S /nolog
TEST_EOF
)
        
        TEST_OUTPUT=$(sudo -u "$OS_USER" env PATH="$PATH" ORACLE_HOME="${ORACLE_HOME:-}" bash -c "$TEST_SCRIPT" 2>&1)
        if echo "$TEST_OUTPUT" | grep -q "TEST_OK"; then
            putMsg OK "✓ Connection test: OK"
        else
            putMsg ERROR "Connection test failed"
            putMsg ERROR "SQL*Plus output: $TEST_OUTPUT"
            exit 1
        fi
    fi
fi

# Update metadata in Vault
HOSTNAME=$(hostname)
METADATA="host=${HOSTNAME},environment=${ENVIRONMENT},instance=${ORACLE_INSTANCE},method=oracleWalletToolkit,tns_admin=${TNS_ADMIN}"

if [ "$DRY_RUN" = true ]; then
    putMsg DRY "Would update metadata in Vault"
    putMsg DRY "  Metadata: ${METADATA}"
    putMsg DRY "  Method: oracleWalletToolkit"
else
    putMsg INFO "Updating metadata in Vault..."
    if hc_vault_create_info_metadata "$SECRET_ENGINE" "${PATH_SECRET}/${DB_USER}" "$METADATA" "$token" "oracleWalletToolkit"; then
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
    putMsg INFO "Database User    : $DB_USER"
    putMsg INFO "Oracle Instance  : $ORACLE_INSTANCE"
    putMsg INFO "Environment      : $ENVIRONMENT"
    putMsg INFO "DB Alias         : $DB_ALIAS"
    putMsg INFO "Vault Path       : $PATH_SECRET/$DB_USER"
    putMsg INFO "TNS_ADMIN        : $TNS_ADMIN"
    echo ""
    putMsg DRY "Operations:"
    putMsg DRY "  1. Check Vault status (unsealed)"
    putMsg DRY "  2. Login to Vault"
    putMsg DRY "  3. Retrieve credentials from Vault"
    putMsg DRY "  4. Configure wallet with mkstore"
    putMsg DRY "  5. Test connection with sqlplus"
    putMsg DRY "  6. Update metadata in Vault"
    echo ""
    putMsg DRY "========================================"
    putMsg WARN "No actual changes were made"
    putMsg DRY "========================================"
else
    putMsg OK "========================================"
    putMsg OK "Wallet configuration completed!"
    putMsg OK "========================================"
    putMsg INFO "Database User    : $DB_USER"
    putMsg INFO "Oracle Instance  : $ORACLE_INSTANCE"
    putMsg INFO "Environment      : $ENVIRONMENT"
    putMsg INFO "DB Alias         : $DB_ALIAS"
    putMsg INFO "Vault Path       : $PATH_SECRET/$DB_USER"
    putMsg INFO "TNS_ADMIN        : $TNS_ADMIN"
    putMsg OK "========================================"
    putMsg INFO "Warnings: $WARN_COUNT | Errors: $ERR_COUNT"
    putMsg OK "========================================"
fi

[[ $ERR_COUNT -gt 0 ]] && exit 8 || exit 0
