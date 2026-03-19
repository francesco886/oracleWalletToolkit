#!/usr/bin/env bash

# Generates tnsnames files

function usage() {
    cat <<EOF
    Usage: $0 [-w] [-e ENVIRONMENT_CODE] [-i INSTANCE_NAME] [-f] [-a] secret_engine(optional) oracle_database_secret_engine(optional)

    DESCRIPTION
        -w: to write alias for oracle wallet
        -e: specify environment(MANDATORY)
        -n: add environment ad the end of wallet alias
        -i: specify one or more instance separated by comma ( MUST specify also -e option)
        -a: create alias without user
        -f: failover connection
        -r: filter the output with a regexp pattern (e.g., -r U_ASIA matches only _U_ASIA= entries, avoiding U_ASIA2, U_ASIAI, etc.)
        -l: create wallet only for user list
        -D: debug connections on first/second instance only
        -v: default skip db alias with version, if present extracts also versions connections(11,12,19)
        -p: Import in SVN repository
    EXAMPLES
        DB_ASIA_U_ASIA_PRD: ./vault_create_tnsnames.sh -e PRD -i prd1 -w -n -r U_ASIA
        DB_ASIA_U_SINIS2I_PRD_12 -> /vault_create_tnsnames.sh -e PRD -i prd1 -w -n -v
        DB_ASIA -> ./vault_create_tnsnames.sh -e SVI -i svi1
        DB_ASIA_SVI_12,DB_ASIA_SVI -> ./vault_create_tnsnames.sh -e SVI -i svi1 -a
        DB_ASIA_1(DEBUG) -> ./vault_create_tnsnames.sh -e SVI -i svi1 -D
EOF
    exit 1
}

function debug_alias {
    local RC
    RC=0

    [[ -d "$TNSNAMES_DEBUG_FOLDER" ]] && {
        cd $TNSNAMES_DEBUG_FOLDER
        rm -fr .svn tnsnames.ora.*
    }

    echo -e "${GREEN}Generating DEBUG_ALIAS tnsnames.ora.$ENV...${NC}"
    [[ ! -d "$TNSNAMES_DEBUG_FOLDER" ]] && mkdir $TNSNAMES_DEBUG_FOLDER

    [[ $PUSH == true ]] && {
        echo -e "${GREEN}Checkout from SVN repo..${NC}"
        checkout_from_svn $TNSNAMES_DEBUG_FOLDER $REPO_URL_TNSNAMES_DEBUG_FOLDER
    }

    [[ -f $TNSNAMES_DEBUG ]] && {
        echo -e "${YELLOW}$TNSNAMES_DEBUG already exists,recreating..${NC}"
        rm $TNSNAMES_DEBUG
        touch $TNSNAMES_DEBUG
    } || touch $TNSNAMES_DEBUG

    echo -e "# Generated from vault_create_tnsname.sh\n" >>$TNSNAMES_DEBUG
    echo -e "# Function: debug_alias()\n" >>$TNSNAMES_DEBUG
    for db_instance in "${db_instances[@]}"; do

        db_instance=$(echo "$db_instance" | tr '[:upper:]' '[:lower:]')

        list_cleaned_connections=($($CURRENT_DIR/vault_list.sh $oracle_database_secret_engine $path_secret/$db_instance))

        for db_connection in "${list_cleaned_connections[@]}"; do

            db_host=$(hc_vault_read "$oracle_database_secret_engine" "$path_secret/${db_instance}/${db_connection}" "$token" | jq .host | sed s/\"//g)
            db_port=$(hc_vault_read "$oracle_database_secret_engine" "$path_secret/${db_instance}/${db_connection}" "$token" | jq .port | sed s/\"//g)
            instance1=$(hc_vault_read "$oracle_database_secret_engine" "$path_secret/${db_instance}/${db_connection}" "$token" | jq .instance1 | sed s/\"//g)
            instance2=$(hc_vault_read "$oracle_database_secret_engine" "$path_secret/${db_instance}/${db_connection}" "$token" | jq .instance2 | sed s/\"//g)

            [[ -z "$db_host" || -z "$db_port" ]] && {
                echo -e "${RED}-$db_connection: db_host or db_port or instance1 missing or instance1 is null in vault!${NC}"
                RC=1
                exit $RC
            }

            [[ -z "$instance1" || "$instance1" == "null" ]] && [[ -z "$instance2" || "$instance2" == "null" ]] && {
                echo -e "${YELLOW}-$db_connection: instance1 and instance 2 missing or instance1 and instance2 is null in vault..skipping${NC}"
                continue
            }

            [[ ${INCLUDE_VERSIONS_DB_CONNECTION} == false && ${db_connection} =~ _[0-9][0-9] ]] && continue

            # Build connection string
            if [[ $FAILOVER == true ]]; then
                if [[ -n "$instance1" && "$instance1" != "null" ]]; then
                    echo "${db_connection}_1=(DESCRIPTION=(FAILOVER=true)(LOAD_BALANCE=true)(ADDRESS=(PROTOCOL=TCP)(HOST=${db_host})(PORT=${db_port}))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=${db_instance})(INSTANCE_NAME=${instance1})(UR=A)(FAILOVER_MODE=(TYPE=select)(METHOD=preconnect)(RETRIES=20)(DELAY=3))))" | grep -iE "${FILTER_REGEXP}" >>$TNSNAMES_DEBUG
                fi
                if [[ -n "$instance2" && "$instance2" != "null" ]]; then
                    echo "${db_connection}_2=(DESCRIPTION=(FAILOVER=true)(LOAD_BALANCE=true)(ADDRESS=(PROTOCOL=TCP)(HOST=${db_host})(PORT=${db_port}))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=${db_instance})(INSTANCE_NAME=${instance2})(UR=A)(FAILOVER_MODE=(TYPE=select)(METHOD=preconnect)(RETRIES=20)(DELAY=3))))" | grep -iE "${FILTER_REGEXP}" >>$TNSNAMES_DEBUG
                fi
            else
                if [[ -n "$instance1" && "$instance1" != "null" ]]; then
                    echo "${db_connection}_1=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${db_host})(PORT=${db_port}))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=${db_instance})(INSTANCE_NAME=${instance1})(UR=A)))" | grep -iE "${FILTER_REGEXP}" >>$TNSNAMES_DEBUG
                fi
                if [[ -n "$instance2" && "$instance2" != "null" ]]; then
                    echo "${db_connection}_2=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${db_host})(PORT=${db_port}))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=${db_instance})(INSTANCE_NAME=${instance2})(UR=A)))" | grep -iE "${FILTER_REGEXP}" >>$TNSNAMES_DEBUG
                fi
            fi

        done
    done

    echo -e "${GREEN}Done!${NC}"
    [[ $PUSH == true ]] && upload_to_svn $TNSNAMES_DEBUG_FOLDER $REPO_URL_TNSNAMES_DEBUG_FOLDER
    return $RC
}

function basic_alias() {
    local RC
    RC=0
    ENV_UPPER=$(echo "${ENV}" | tr '[:lower:]' '[:upper:]')

    [[ -d "$TNSNAMES_BASIC_FOLDER" ]] && {
        cd $TNSNAMES_BASIC_FOLDER
        rm -fr .svn tnsnames.ora.*
    }

    echo -e "${GREEN}Generating BASIC_ALIAS tnsnames.ora.$ENV...${NC}"
    [[ ! -d "$TNSNAMES_BASIC_FOLDER" ]] && mkdir $TNSNAMES_BASIC_FOLDER

    [[ $PUSH == true ]] && {
        echo -e "${GREEN}Checkout from SVN repo..${NC}"
        checkout_from_svn $TNSNAMES_BASIC_FOLDER $REPO_URL_TNSNAMES_BASIC_FOLDER
    }

    [[ -f $TNSNAMES_BASIC ]] && {
        echo -e "${YELLOW}$TNSNAMES_BASIC already exists,recreating..${NC}"
        rm $TNSNAMES_BASIC
        touch $TNSNAMES_BASIC
    } || touch $TNSNAMES_BASIC

    echo -e "# Generated from vault_create_tnsname.sh\n" >>$TNSNAMES_BASIC
    echo -e "# Function: basic_alias()\n" >>$TNSNAMES_BASIC
    for db_instance in "${db_instances[@]}"; do

        db_instance=$(echo "$db_instance" | tr '[:upper:]' '[:lower:]')

        list_cleaned_connections=($($CURRENT_DIR/vault_list.sh $oracle_database_secret_engine $path_secret/$db_instance))

        for db_connection in "${list_cleaned_connections[@]}"; do

            db_host=$(hc_vault_read "$oracle_database_secret_engine" "$path_secret/${db_instance}/${db_connection}" "$token" | jq .host | sed s/\"//g)
            db_port=$(hc_vault_read "$oracle_database_secret_engine" "$path_secret/${db_instance}/${db_connection}" "$token" | jq .port | sed s/\"//g)

            [[ -z "$db_host" || -z "$db_port" ]] && {
                echo "[ERROR] - db_host or db_port missing in vault!"
                RC=1
                exit $RC
            }

            [[ ${INCLUDE_VERSIONS_DB_CONNECTION} == false && ${db_connection} =~ _[0-9][0-9] ]] && continue

            # Build connection string
            if [[ $NOIDEMPOTENT == true ]]; then

                if [[ $FAILOVER == true ]]; then
                    echo "${db_connection}_${ENV_UPPER}=(DESCRIPTION=(FAILOVER=true)(LOAD_BALANCE=true)(ADDRESS=(PROTOCOL=TCP)(HOST="${db_host}")(PORT="${db_port}"))(CONNECT_DATA=(SERVICE_NAME="${db_instance}".domain.local)(FAILOVER_MODE=(TYPE=select)(METHOD=preconnect)(RETRIES=20)(DELAY=3))))" | grep -iE "${FILTER_REGEXP}" >>$TNSNAMES_BASIC
                else
                    echo "${db_connection}_${ENV_UPPER}=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST="${db_host}")(PORT="${db_port}"))(CONNECT_DATA=(SERVICE_NAME="${db_instance}".domain.local)))" | grep -iE "${FILTER_REGEXP}" >>$TNSNAMES_BASIC
                fi

            else

                if [[ $FAILOVER == true ]]; then
                    echo "${db_connection}=(DESCRIPTION=(FAILOVER=true)(LOAD_BALANCE=true)(ADDRESS=(PROTOCOL=TCP)(HOST="${db_host}")(PORT="${db_port}"))(CONNECT_DATA=(SERVICE_NAME="${db_instance}".domain.local)(FAILOVER_MODE=(TYPE=select)(METHOD=preconnect)(RETRIES=20)(DELAY=3))))" | grep -iE "${FILTER_REGEXP}" >>$TNSNAMES_BASIC
                else
                    echo "${db_connection}=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST="${db_host}")(PORT="${db_port}"))(CONNECT_DATA=(SERVICE_NAME="${db_instance}".domain.local)))" | grep -iE "${FILTER_REGEXP}" >>$TNSNAMES_BASIC
                fi

            fi
        done
    done

    [[ $PUSH == true ]] && upload_to_svn $TNSNAMES_BASIC_FOLDER $REPO_URL_TNSNAMES_BASIC_FOLDER

    echo -e "${GREEN}Done!${NC}"
    return $RC
}

function wallet_alias() {
    local RC
    RC=0

    [[ -d "$TNSNAMES_WALLET_FOLDER" ]] && {
        cd $TNSNAMES_WALLET_FOLDER
        rm -fr .svn tnsnames.ora.*
    }

    echo -e "${GREEN}Generating WALLET_ALIAS tnsnames.ora.$ENV...${NC}"
    [[ ! -d "$TNSNAMES_WALLET_FOLDER" ]] && mkdir $TNSNAMES_WALLET_FOLDER

    [[ $PUSH == true ]] && {
        echo -e "${GREEN}Checkout from SVN repo..${NC}"
        checkout_from_svn $TNSNAMES_WALLET_FOLDER $REPO_URL_TNSNAMES_WALLET_FOLDER
    }

    [[ -f $TNSNAMES_WALLET ]] && {
        echo -e "${YELLOW}$TNSNAMES_WALLET already exists,recreating..${NC}"
        rm $TNSNAMES_WALLET
        touch $TNSNAMES_WALLET
    } || touch $TNSNAMES_WALLET

    ENV_UPPER=$(echo "${ENV}" | tr '[:lower:]' '[:upper:]')
    echo -e "# Generated from vault_create_tnsname.sh\n" >>$TNSNAMES_WALLET
    echo -e "# Function: wallet_alias()\n" >>$TNSNAMES_WALLET
    for db_instance in "${db_instances[@]}"; do

        vault_list_credentials=($($CURRENT_DIR/vault_list.sh $secret_engine $path_secret/$db_instance))
        list_cleaned_connections=($($CURRENT_DIR/vault_list.sh $oracle_database_secret_engine $path_secret/$db_instance))

        for db_user in "${vault_list_credentials[@]}"; do

            [[ ! -z "${USER_LIST[@]}" && ! " ${USER_LIST[@]} " =~ " $db_user " ]] && continue

            [[ "$db_user" =~ 404 ]] && {
                echo -e "${YELLOW}User in instance $db_instance: $db_user${NC}"
                continue
            }

            for db_connection in "${list_cleaned_connections[@]}"; do

                db_host=$(hc_vault_read "$oracle_database_secret_engine" "$path_secret/${db_instance}/${db_connection}" "$token" | jq .host | sed s/\"//g)
                db_port=$(hc_vault_read "$oracle_database_secret_engine" "$path_secret/${db_instance}/${db_connection}" "$token" | jq .port | sed s/\"//g)

                [[ -z "$db_host" || -z "$db_port" ]] && {
                    echo -e "${RED} - db_host or db_port missing in vault!${NC}"
                    RC=1
                    exit $RC
                }

                [[ ${INCLUDE_VERSIONS_DB_CONNECTION} == false && ${db_connection} =~ _[0-9][0-9] ]] && {
                    continue
                }

                # Build connection string
                if [[ $NOIDEMPOTENT == true ]]; then

                    if [[ $db_connection == *"_11"* ]]; then
                        db_connection_alias=$(echo "$db_connection" | sed 's/_11/'_${db_user}'_'$ENV_UPPER'_11/')
                    elif [[ $db_connection == *"_12"* ]]; then
                        db_connection_alias=$(echo "$db_connection" | sed 's/_12/'_${db_user}'_'$ENV_UPPER'_12/')
                    elif [[ $db_connection == *"_19"* ]]; then
                        db_connection_alias=$(echo "$db_connection" | sed 's/_19/'_${db_user}'_'$ENV_UPPER'_19/')
                    else
                        db_connection_alias=$(echo "$db_connection"_"${db_user}_""${ENV_UPPER}")
                    fi

                    if [[ $FAILOVER == true ]]; then
                        echo "${db_connection_alias}=(DESCRIPTION=(FAILOVER=true)(LOAD_BALANCE=true)(ADDRESS=(PROTOCOL=TCP)(HOST="${db_host}")(PORT="${db_port}"))(CONNECT_DATA=(SERVICE_NAME="${db_instance}".domain.local)(FAILOVER_MODE=(TYPE=select)(METHOD=preconnect)(RETRIES=20)(DELAY=3))))" | grep -iE "${FILTER_REGEXP}" >>$TNSNAMES_WALLET
                    else
                        echo "${db_connection_alias}=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST="${db_host}")(PORT="${db_port}"))(CONNECT_DATA=(SERVICE_NAME="${db_instance}".domain.local)))" | grep -iE "${FILTER_REGEXP}" >>$TNSNAMES_WALLET
                    fi
                else
                    if [[ $db_connection == *"_11"* ]]; then
                        db_connection_alias=$(echo "$db_connection" | sed 's/_11/'_${db_user}'_11/')
                    elif [[ $db_connection == *"_12"* ]]; then
                        db_connection_alias=$(echo "$db_connection" | sed 's/_12/'_${db_user}'_12/')
                    elif [[ $db_connection == *"_19"* ]]; then
                        db_connection_alias=$(echo "$db_connection" | sed 's/_19/'_${db_user}'_19/')
                    else
                        db_connection_alias=$(echo "$db_connection"_"${db_user}")
                    fi

                    if [[ $FAILOVER == true ]]; then
                        echo "${db_connection_alias}=(DESCRIPTION=(FAILOVER=true)(LOAD_BALANCE=true)(ADDRESS=(PROTOCOL=TCP)(HOST="${db_host}")(PORT="${db_port}"))(CONNECT_DATA=(SERVICE_NAME="${db_instance}".domain.local)(FAILOVER_MODE=(TYPE=select)(METHOD=preconnect)(RETRIES=20)(DELAY=3))))" | grep -iE "${FILTER_REGEXP}" >>$TNSNAMES_WALLET
                    else
                        echo "${db_connection_alias}=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST="${db_host}")(PORT="${db_port}"))(CONNECT_DATA=(SERVICE_NAME="${db_instance}".domain.local)))" | grep -iE "${FILTER_REGEXP}" >>$TNSNAMES_WALLET
                    fi
                fi
            done
        done
    done

    [[ $PUSH == true ]] && upload_to_svn $TNSNAMES_WALLET_FOLDER $REPO_URL_TNSNAMES_WALLET_FOLDER

    echo -e "${GREEN}Done!${NC}"
    return $RC
}

function nouser_all_alias() {
    local RC
    RC=0

    [[ -d "$TNSNAMES_ALL_FOLDER" ]] && {
        cd $TNSNAMES_ALL_FOLDER
        rm -fr .svn tnsnames.ora.*
    }

    [[ $ENV ]] && FILE_NAME="tnsnames.ora.nouser.$ENV" || FILE_NAME="tnsnames.ora.nouser"
    echo -e "${GREEN}Generating NOUSER_ALIAS $FILE_NAME...${NC}"
    [[ ! -d "$TNSNAMES_ALL_FOLDER" ]] && mkdir $TNSNAMES_ALL_FOLDER

    [[ $PUSH == true ]] && {
        echo -e "${GREEN}Checkout from SVN repo..${NC}"
        checkout_from_svn $TNSNAMES_ALL_FOLDER $REPO_URL_TNSNAMES_ALL_FOLDER
    }

    [[ -f $TNSNAMES_ALL_ENV ]] && {
        echo -e "${YELLOW}$TNSNAMES_ALL_ENV already exists,recreating..${NC}"
        rm $TNSNAMES_ALL_ENV
        touch $TNSNAMES_ALL_ENV
    } || touch $TNSNAMES_ALL_ENV

    echo -e "# Generated from vault_create_tnsname.sh\n" >>$TNSNAMES_ALL_ENV
    echo -e "# Function: nouser_all_alias()\n" >>$TNSNAMES_ALL_ENV
    for env in ${ENVIRONMENT_LIST[@]}; do

        if [[ $ENV != "" && $ENV != $env ]]; then
            continue
        fi

        path_secret="$env/paas/oracle"
        ENV_UPPER=$(echo ${env} | tr '[:lower:]' '[:upper:]')

        #db_instances=($($CURRENT_DIR/vault_list.sh $oracle_database_secret_engine $path_secret))

        [[ "${db_instances[@]}" =~ 404 ]] && {
            echo -e "${YELLOW}No instances found for $env${NC}"
            continue
        }

        echo -e "\n#-----$ENV_UPPER-----" >>$TNSNAMES_ALL_ENV

        for db_instance in "${db_instances[@]}"; do

            list_cleaned_connections=($($CURRENT_DIR/vault_list.sh $oracle_database_secret_engine $path_secret/$db_instance))

            for db_connection in "${list_cleaned_connections[@]}"; do

                db_host=$(hc_vault_read "$oracle_database_secret_engine" "$path_secret/${db_instance}/${db_connection}" "$token" | jq .host | sed s/\"//g)
                db_port=$(hc_vault_read "$oracle_database_secret_engine" "$path_secret/${db_instance}/${db_connection}" "$token" | jq .port | sed s/\"//g)

                [[ -z "$db_host" || -z "$db_port" ]] && {
                    echo "[ERROR] - db_host or db_port missing in vault!"
                    RC=1
                    exit $RC
                }

                [[ ${INCLUDE_VERSIONS_DB_CONNECTION} == false && ${db_connection} =~ _[0-9][0-9] ]] && continue

                if [[ $NOIDEMPOTENT == true ]]; then
                    if [[ $db_connection == *"_12"* ]]; then
                        db_connection_alias=$(echo "$db_connection" | sed 's/_12/_'$ENV_UPPER'_12/')
                    elif [[ $db_connection == *"_19"* ]]; then
                        db_connection_alias=$(echo "$db_connection" | sed 's/_19/_'$ENV_UPPER'_19/')
                    else
                        db_connection_alias=$(echo "$db_connection"_"${ENV_UPPER}")
                    fi
                else
                    db_connection_alias=$(echo "$db_connection")
                fi

                # Build connection string
                if [[ $FAILOVER == true ]]; then
                    echo "${db_connection_alias}=(DESCRIPTION=(FAILOVER=true)(LOAD_BALANCE=true)(ADDRESS=(PROTOCOL=TCP)(HOST="${db_host}")(PORT="${db_port}"))(CONNECT_DATA=(SERVICE_NAME="${db_instance}".domain.local)(FAILOVER_MODE=(TYPE=select)(METHOD=preconnect)(RETRIES=20)(DELAY=3))))" | grep -iE "${FILTER_REGEXP}" >>$TNSNAMES_ALL_ENV
                else
                    echo "${db_connection_alias}=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST="${db_host}")(PORT="${db_port}"))(CONNECT_DATA=(SERVICE_NAME="${db_instance}".domain.local)))" | grep -iE "${FILTER_REGEXP}" >>$TNSNAMES_ALL_ENV
                fi
            done
        done
    done

    [[ $PUSH == true ]] && upload_to_svn $TNSNAMES_ALL_FOLDER $REPO_URL_TNSNAMES_ALL_FOLDER

    echo -e "${GREEN}Done!${NC}"
    return $RC
}

function checkout_from_svn() {
    local RC
    RC=0

    [[ -z $2 ]] && exit 1

    local folder="$1"
    local svn_url="$2"

    # Naviga nella cartella locale
    cd "$folder" || exit

    svn co --username "$SVN_USERNAME" --password "$SVN_PASSWORD" $svn_url . <<<"n"
    #rm -fr .svn tnsnames*
}

function upload_to_svn() {
    local RC
    RC=0

    [[ -z $2 ]] && exit 1

    local folder="$1"
    local svn_url="$2"

    # Naviga nella cartella locale
    cd "$folder" || exit 1

    # Aggiungi i nuovi file
    svn add --force * --auto-props --parents --depth infinity -q
    svn commit -m "Aggiornamento dati da vault_create_tnsnames.sh" --username "$SVN_USERNAME" --password "$SVN_PASSWORD"
    return $RC
}

#########################################MAIN############################################
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Find vault_lib.sh dynamically
VAULT_LIB_PATH=$(find /products/software/sysadm -name "vault_lib.sh" -type f 2>/dev/null | head -1)
[[ -z "$VAULT_LIB_PATH" || ! -f "$VAULT_LIB_PATH" ]] && {
    echo "Missing file: vault_lib.sh not found in /products/software/sysadm"
    echo "Trying to find vault_lib.sh in the current directory..."
    VAULT_LIB_PATH=$(find "$CURRENT_DIR" -name "vault_lib.sh" -type f 2>/dev/null | head -1)
    [[ -z "$VAULT_LIB_PATH" || ! -f "$VAULT_LIB_PATH" ]] && {
        echo "Missing file: vault_lib.sh not found in the current directory"
        exit 1
    }
}

ENV=""
ENVIRONMENT_LIST=("amm" "svi" "int" "tst" "pre" "prd")
FILTER_USER=""
USER_LIST=()
FILTER_INSTANCE=""
FILTER_REGEXP=""
ALIAS_TYPE="b"
PUSH=false
FAILOVER=false
NOIDEMPOTENT=false
INCLUDE_VERSIONS_DB_CONNECTION=false
jq_dir="$CURRENT_DIR/../bin"
export PATH=$PATH:"${jq_dir}"
source "$VAULT_LIB_PATH"
source "$CURRENT_DIR/1-v_global.sh"

while getopts ":he:wfi:apl:r:vDn" opt; do
    case ${opt} in
    w)
        ALIAS_TYPE="w"
        ;;
    n)
        NOIDEMPOTENT=true
        ;;
    f)
        FAILOVER=true
        ;;
    a)
        ALIAS_TYPE="a"
        ;;
    D)
        ALIAS_TYPE="D"
        ;;
    e)
        ENV=${OPTARG}
        ;;
    i)
        [[ "${OPTARG}" =~ [[:space:]] ]] && {
            echo -e "${RED}List of instances must be formatted like this: instance1,instance2..${NC}"
            exit 1
        }

        OLD_IFS=$IFS
        IFS=','
        FILTER_INSTANCE=(${OPTARG})
        IFS=$OLD_IFS
        ;;
    r)
        FILTER_REGEXP=${OPTARG}
        ;;
    l)
        [[ "${OPTARG}" =~ [[:space:]] ]] && {
            echo -e "${RED}List of user must be formatted like this: USER1,USER2..${NC}"
            exit 1
        }
        OLD_IFS=$IFS
        IFS=','
        USER_LIST=(${OPTARG})
        IFS=$OLD_IFS
        ;;
    p)
        PUSH=true
        ;;
    v)
        INCLUDE_VERSIONS_DB_CONNECTION=true
        ;;
    h)
        usage
        ;;
    *)
        usage
        ;;
    esac
done

[[ $OPTIND -eq 1 ]] && usage
shift "$((OPTIND - 1))"

[[ -z $ENV ]] && {
    usage
    exit 1
}

# Normalize FILTER_REGEXP for exact matching if it looks like a simple username
# If user passes "-r U_SINIS2", convert it to "-r _U_SINIS2=" to avoid matching U_SINIS2I, U_SINIS2I_MIG, etc.
if [[ -n "$FILTER_REGEXP" ]]; then
    # Check if FILTER_REGEXP doesn't already contain regex anchors or special chars at start/end
    if [[ ! "$FILTER_REGEXP" =~ ^[_] ]] && [[ ! "$FILTER_REGEXP" =~ [=\$]$ ]]; then
        # It looks like a simple username, make it an exact match pattern
        FILTER_REGEXP="_${FILTER_REGEXP}="
    fi
fi

ENV=$(echo $ENV | tr '[:upper:]' '[:lower:]')
path_secret="$ENV/paas/oracle"
TNSNAMES_BASIC_FOLDER="$CURRENT_DIR/tnsnames_basic"
TNSNAMES_DEBUG_FOLDER="$CURRENT_DIR/tnsnames_debug"
TNSNAMES_WALLET_FOLDER="$CURRENT_DIR/tnsnames_wallet"
TNSNAMES_ALL_FOLDER="$CURRENT_DIR/tnsnames_nouser"
TNSNAMES_BASIC="$TNSNAMES_BASIC_FOLDER/tnsnames.ora.$ENV"
TNSNAMES_DEBUG="$TNSNAMES_DEBUG_FOLDER/tnsnames.ora.$ENV"
TNSNAMES_WALLET="$TNSNAMES_WALLET_FOLDER/tnsnames.ora.$ENV"
[[ $ENV ]] && TNSNAMES_ALL_ENV="$TNSNAMES_ALL_FOLDER/tnsnames.ora.nouser.$ENV" || TNSNAMES_ALL_ENV="$TNSNAMES_ALL_FOLDER/tnsnames.ora.nouser"
REPO_URL_TNSNAMES_BASIC_FOLDER="https://bcsvn.gruppoitas.it/svn/Esercizio/EAIP/trunk/80.Documentazione/AccessoDB/Connessioni/tnsnames/vault/tnsnames_basic"
REPO_URL_TNSNAMES_DEBUG_FOLDER="https://bcsvn.gruppoitas.it/svn/Esercizio/EAIP/trunk/80.Documentazione/AccessoDB/Connessioni/tnsnames/vault/tnsnames_debug"
REPO_URL_TNSNAMES_WALLET_FOLDER="https://bcsvn.gruppoitas.it/svn/Esercizio/EAIP/trunk/80.Documentazione/AccessoDB/Connessioni/tnsnames/vault/tnsnames_wallet"
REPO_URL_TNSNAMES_ALL_FOLDER="https://bcsvn.gruppoitas.it/svn/Esercizio/EAIP/trunk/80.Documentazione/AccessoDB/Connessioni/tnsnames/vault/tnsnames_nouser"

[[ ! -z "${1}" ]] && secret_engine=$1 || secret_engine="database"                                        # Secret engine that stores the credentials
[[ ! -z "${2}" ]] && oracle_database_secret_engine=$2 || oracle_database_secret_engine="oracle_database" # Secret engine that stores the connections

hc_vault_is_sealed
[[ $? == 1 ]] && hc_vault_unseal "${vault_key}"

token=$(hc_vault_login "${vault_username}" "${vault_password}")

db_instances=($($CURRENT_DIR/vault_list.sh $oracle_database_secret_engine $path_secret))
[[ ! -z "${FILTER_INSTANCE[@]}" ]] && db_instances=(${FILTER_INSTANCE[@]})

SVN_USERNAME="service_vault"
SVN_PASSWORD=$(hc_vault_read web svn/service_vault $token | jq .$SVN_USERNAME | tr -d '"')

# tnasnames generali
case $ALIAS_TYPE in
f)
    failover_alias
    ;;
w)
    wallet_alias
    ;;
a)
    nouser_all_alias
    ;;
b)
    basic_alias
    ;;
D)
    debug_alias
    ;;
esac

printf "\n"
echo -e "${GREEN}Printing all tnsnames:${NC}"
[[ -f "${TNSNAMES_BASIC}" ]] && cat "${TNSNAMES_BASIC}"
[[ -f "${TNSNAMES_DEBUG}" ]] && cat "${TNSNAMES_DEBUG}"
[[ -f "${TNSNAMES_WALLET}" ]] && cat "${TNSNAMES_WALLET}"

exit 0
