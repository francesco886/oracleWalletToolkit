#!/bin/bash

# ----------------------------------------------------------------------------
# Oracle Database User Password Change Script
# ----------------------------------------------------------------------------
# Usage: alter_user.sh <db_user> <db_user_password> <oraenv_file>
#
# Parameters:
#   db_user           - Database user name
#   db_user_password  - New password for the database user
#   oraenv_file       - Full path to Oracle environment file (e.g., /usr/local/bin/oraenv_SVI0)
# ----------------------------------------------------------------------------

TRAPS="ERR INT QUIT HUP TERM"
myOUT="/tmp/outfile$$.out"

# Parse parameters
DB_USER=$1
DB_USER_PASS=$2
ORAENV_FILE=$3

# Validate parameters
if [ -z "$DB_USER" ] || [ -z "$DB_USER_PASS" ] || [ -z "$ORAENV_FILE" ]; then
  echo "ERROR: Missing required parameters"
  echo "Usage: $0 <db_user> <db_user_password> <oraenv_file>"
  echo ""
  echo "Parameters:"
  echo "  db_user           - Database user name"
  echo "  db_user_password  - New password for the database user"
  echo "  oraenv_file       - Full path to Oracle environment file (e.g., /usr/local/bin/oraenv_SVI0)"
  exit 1
fi

echo "DB User: $DB_USER"
echo "Oracle Environment File: $ORAENV_FILE"

# Source Oracle environment
# shellcheck disable=SC1090
if [ -f "$ORAENV_FILE" ]; then
  . "$ORAENV_FILE"
  echo "Oracle environment loaded: $ORAENV_FILE"
else
  echo "ERROR: Oracle environment file not found: $ORAENV_FILE"
  exit 1
fi

function trapHandler
#
# trap signals
# $1 Signal
# -------------------------------------------------------------------------------------------------------
{
  echo '================================================================================================'
  [ -f "${myOUT}" ] && cat "${myOUT}" || true
  echo '================================================================================================'
  exit 1
}
 
function alterUserFun {
  sqlplus -s /nolog <<_
whenever sqlerror exit failure
connect / as sysdba
whenever oserror exit failure
set lines 300
set trims on
  alter user $DB_USER identified by "$DB_USER_PASS";
_
}


# -------------------------------------------------------------
# MAIN
# -------------------------------------------------------------

set -o pipefail
set -e
for t in $TRAPS ; do
  trap 'trapHandler $t' $t
done

alterUserFun | tee -a ${myOUT}

# Cleanup
[ -f "${myOUT}" ] && rm "${myOUT}"

echo "Done"
