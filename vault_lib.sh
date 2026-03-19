#!/usr/bin/env bash

URL_VAULT=""
RED="\\e[31m[ERROR]"
GREEN="\\e[32m[INFO]"
PURPLE="\\e[35m"
NC="\\e[39m" # No Color

f_check_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo >&2
        return 1
    }
}
export -f f_check_command

hc_vault_login() {
    #**********************************************************************
    # info: retrive user token
    # method: POST
    # path: /auth/userpass/login/:USER
    # parameters: USER,password
    #**********************************************************************

    if [[ -z $1 || -z $2 ]]; then
        printf "${RED} - hc_vault_login: missing parameters USER,password${NC}"
        return 1
    fi

    local USERNAME
    local PASSWORD
    local ENDPOINT
    USER=$1
    PASSWORD=$2
    ENDPOINT="v1/auth/userpass/login/${USER}"

    RESPONSE=$(curl --silent -w "%{http_code}" -d '{"password":"'"${PASSWORD}"'"}' -X POST ${URL_VAULT}/${ENDPOINT})
    HTTP_STATUS=$(tail -n1 <<<"$RESPONSE")
    HTTP_RESPONSE=$(sed '$ d' <<<"$RESPONSE")

    if [[ ${HTTP_STATUS} != "200" ]]; then
        RC=1
        printf "${RED} - $HTTP_RESPONSE${NC}"
        return $RC
    fi

    TOKEN=$(echo $HTTP_RESPONSE | jq '.auth.client_token')

    echo $TOKEN | sed 's/"//g'

    return 0
}
export -f hc_vault_login

hc_vault_is_sealed() {
    #**********************************************************************
    # info: check status seal ( return true | false )
    # method: GET
    # path: /sys/seal-status
    # parameters: key
    #**********************************************************************

    local ENDPOINT
    local STATUS
    ENDPOINT="v1/sys/seal-status"
    RESPONSE=$(curl --silent -w "%{http_code}" ${URL_VAULT}/${ENDPOINT})

    HTTP_STATUS=$(tail -n1 <<<"$RESPONSE")
    HTTP_RESPONSE=$(sed '$ d' <<<"$RESPONSE")

    if [[ ${HTTP_STATUS} != "200" ]]; then
        RC=1
        printf "${RED} - $HTTP_RESPONSE${NC}"
        return $RC
    fi

    STATUS=$(echo "$HTTP_RESPONSE" | jq .sealed)

    RC=1
    if [[ $STATUS == "false" ]]; then
        RC=0
    fi

    return $RC

}

export -f hc_vault_is_sealed

hc_vault_unseal() {
    #**********************************************************************
    # info: unseal the vault
    # method: POST
    # path: /sys/unseal
    # parameters: key
    #**********************************************************************

    if [[ -z $1 ]]; then
        printf "${RED} - hc_vault_unseal: missing parameters key${NC}"
        return 1
    fi

    local KEY
    local ENDPOINT
    KEY=$1

    ENDPOINT="v1/sys/unseal"
    RESPONSE=$(curl --silent -w "%{http_code}" -d '{"key":"'"${KEY}"'"}' -X POST ${URL_VAULT}/${ENDPOINT})

    HTTP_STATUS=$(tail -n1 <<<"$RESPONSE")
    HTTP_RESPONSE=$(sed '$ d' <<<"$RESPONSE")

    if [[ ${HTTP_STATUS} != "200" ]]; then
        RC=1
        printf "${RED} - $HTTP_RESPONSE${NC}"
        return $RC
    fi

    echo "$HTTP_RESPONSE"
    return 0
}
export -f hc_vault_unseal

hc_vault_renew_self() {
    #**********************************************************************
    # info: renew self token sent as header for time sent as data
    # method: POST
    # path: /auth/token/renew-self
    # parameters: lease(express in hour),token
    #**********************************************************************

    if [[ -z $1 || -z $2 ]]; then
        printf "${RED} - hc_vault_renew_self: missing parameters lease(express in hours),token${NC}"
        return 1
    fi

    local TOKEN
    local LEASE
    local ENDPOINT
    LEASE=$1
    TOKEN=$2

    ENDPOINT="v1/auth/token/renew-self"
    RESPONSE=$(curl --silent -w "%{http_code}" --header "X-VAULT-TOKEN: ${TOKEN}" -d '{"increment":"'"${LEASE}h"'"}' -X POST ${URL_VAULT}/${ENDPOINT})

    HTTP_STATUS=$(tail -n1 <<<"$RESPONSE")
    HTTP_RESPONSE=$(sed '$ d' <<<"$RESPONSE")

    if [[ ${HTTP_STATUS} != "200" ]]; then
        RC=1
        printf "${RED} - $HTTP_RESPONSE${NC}"
        return $RC
    fi

    echo "$HTTP_RESPONSE"
    return 0
}
export -f hc_vault_renew_self

hc_vault_revoke_self() {
    #**********************************************************************
    # info: revoke self token sent as header for time sent as data
    # method: POST
    # path: /auth/token/revoke-self
    # parameters: token
    #**********************************************************************

    if [[ -z $1 || -z $2 ]]; then
        printf "${RED} - hc_vault_revoke_self: missing parameters token${NC}"
        return 1
    fi

    local TOKEN
    local ENDPOINT
    TOKEN=$1

    ENDPOINT="v1/auth/token/revoke-self"
    RESPONSE=$(curl --silent -w "%{http_code}" --header "X-VAULT-TOKEN: ${TOKEN}" -X POST ${URL_VAULT}/${ENDPOINT})

    HTTP_STATUS=$(tail -n1 <<<"$RESPONSE")
    HTTP_RESPONSE=$(sed '$ d' <<<"$RESPONSE")

    if [[ ${HTTP_STATUS} != "200" ]]; then
        RC=1
        printf "${RED} - $HTTP_RESPONSE${NC}"
        return $RC
    fi

    echo "$HTTP_RESPONSE"
    return 0
}
export -f hc_vault_revoke_self

hc_vault_create() {
    #**********************************************************************
    # info: creates a new version of a secret or append at the specified location
    # method: POST
    # path: /secret/data/:path
    # parameters: key,value,secret_eng,path_secret,token,nooverride(optional)
    #**********************************************************************

    if [[ -z $1 || -z $2 || -z $3 || -z $4 || -z $5 ]]; then
        printf "${RED} - hc_vault_create: missing parameters key,value,secret_eng,path_secret,token${NC}"
        return 1
    fi

    local CREDENTIAL_EXISTS
    local KEY
    local NOOVERRIDE
    local VALUE
    local PATH_FOLDER
    local TOKEN
    local ENDPOINT
    local SECRET_ENGINE

    CREDENTIAL_EXISTS=false
    NOOVERRIDE=""
    KEY=$(echo "$1" | xargs)
    VALUE=$(echo "$2" | xargs)
    SECRET_ENGINE=$(echo "${3}" | sed 's/^\/\?/\//')
    PATH_FOLDER=$(echo "${4}" | sed 's/^\/\?/\//')
    TOKEN=$5
    ENDPOINT="v1${SECRET_ENGINE}/data${PATH_FOLDER}"
    [[ $6 == true ]] && NOOVERRIDE=$6

    # Get current metadata
    hc_vault_read $SECRET_ENGINE $PATH_FOLDER $TOKEN >/dev/null
    RC=$? # If 4 no records found at path_secret
    [[ $RC == 0 ]] && CREDENTIAL_EXISTS=true || CREDENTIAL_EXISTS=false

    [[ $CREDENTIAL_EXISTS == true && $NOOVERRIDE == true ]] && {
        printf "${YELLOW}Credential $PATH_FOLDER skipped due to nooverride option!${NC}"
        return 0
    }

    # No records found at path_folder
    if [[ $RC -eq 4 ]]; then
        RESPONSE=$(curl --silent -w "%{http_code}" --header "Content-Type: application/merge-patch+json" --header "X-VAULT-TOKEN: ${TOKEN}" -d '{"data":{"'"$KEY"'":"'"${VALUE}"'"}}' -X POST ${URL_VAULT}/${ENDPOINT})
    else
        APPEND_VALUE=$(hc_vault_read $SECRET_ENGINE $PATH_FOLDER $TOKEN | jq '. + {"'"$KEY"'":"'"${VALUE}"'"}' | tr -d '[:space:]')
        RESPONSE=$(curl --silent -w "%{http_code}" --header "Content-Type: application/merge-patch+json" --header "X-VAULT-TOKEN: ${TOKEN}" -d '{"data":'$APPEND_VALUE'}' -X POST ${URL_VAULT}/${ENDPOINT})
    fi

    HTTP_STATUS=$(tail -n1 <<<"$RESPONSE")
    HTTP_RESPONSE=$(sed '$ d' <<<"$RESPONSE")

    if [[ ${HTTP_STATUS} != "200" ]]; then
        RC=1
        printf "${RED} - $HTTP_STATUS${NC}"
        return $RC
    fi

    echo "$HTTP_RESPONSE"
    return 0
}
export -f hc_vault_create

hc_vault_create_data_file() {
    #**********************************************************************
    # info: creates a new version of a secret or update with data kept from a file json
    # method: POST/PATCH
    # path: /secret/data/:path
    # parameters: path_file,secret_eng,path_secret,token
    #**********************************************************************

    if [[ -z $1 || -z $2 || -z $3 || -z $4 ]]; then
        printf "${RED} - hc_vault_create_data_file: missing parameters path_file,secret_eng,path_secret,token${NC}"
        return 1
    fi

    local FILE_PATH
    local PATH_SECRET
    local TOKEN
    local ENDPOINT
    local SECRET_ENGINE

    FILE_PATH=$1
    [[ ! -f $FILE_PATH ]] && {
        printf "${RED} - $FILE_PATH doen't exist!${NC}"
        return 1
    }

    SECRET_ENGINE=$(echo ${2} | sed 's/^\/\?/\//')
    PATH_SECRET=$(echo $3 | sed 's/^\/\?/\//')
    TOKEN=$4
    ENDPOINT="v1${SECRET_ENGINE}/data${PATH_SECRET}"

    # Get current metadata
    hc_vault_read $SECRET_ENGINE $PATH_SECRET $TOKEN >/dev/null

    # No records found at path_secret
    if [[ $? -eq 4 ]]; then
        RESPONSE=$(curl --silent -w "%{http_code}" --header "Content-Type: application/merge-patch+json" --header "X-VAULT-TOKEN: ${TOKEN}" -d @${FILE_PATH} -X POST ${URL_VAULT}/${ENDPOINT})
    else
        RESPONSE=$(curl --silent -w "%{http_code}" --header "Content-Type: application/merge-patch+json" --header "X-VAULT-TOKEN: ${TOKEN}" -d @${FILE_PATH} -X PATCH ${URL_VAULT}/${ENDPOINT})
    fi

    HTTP_STATUS=$(tail -n1 <<<"$RESPONSE")
    HTTP_RESPONSE=$(sed '$ d' <<<"$RESPONSE")

    if [[ ${HTTP_STATUS} != "200" ]]; then
        RC=1
        printf "${RED} - $HTTP_STATUS${NC}"
        return $RC
    fi

    echo "$HTTP_RESPONSE"
    return 0
}
export -f hc_vault_create_data_file

hc_vault_create_multiple_key_value() {
    #**********************************************************************
    # info: creates a new version of a secret or update with multiple credentials
    # method: POST/PATCH
    # path: /secret/data/:path
    # parameters: alias,host,port,instance1,instance2,service_name,secret_eng,path_secret,token,force
    #**********************************************************************

    if [[ -z "${10}" ]]; then
        printf "${RED} - hc_vault_create_multiple_key_value: missing parameters alias,host,port,service_name,secret_eng,path_secret,token${NC}"
        return 1
    fi

    local CREDENTIAL_EXISTS
    local FORCE
    local ALIAS
    local HOST
    local PORT
    local INSTANCE1
    local INSTANCE2
    local SERVICE_NAME
    local SECRET_ENGINE
    local PATH_SECRET
    local TOKEN
    local ENDPOINT

    CREDENTIAL_EXISTS=false
    FORCE=""
    INSTANCE1=""
    INSTANCE2=""

    ALIAS=$1
    HOST=$2
    PORT=$3
    INSTANCE1=$4
    INSTANCE2=$5
    SERVICE_NAME=$6
    SECRET_ENGINE=$(echo ${7} | sed 's/^\/\?/\//')
    PATH_SECRET=$(echo $8 | sed 's/^\/\?/\//')
    TOKEN=$9
    [[ ${10} == true ]] && FORCE=${10}

    ENDPOINT="v1${SECRET_ENGINE}/data${PATH_SECRET}"
    DATA_JSON="{\"host\":\"$HOST\",\"port\":\"$PORT\",\"service_name\":\"$SERVICE_NAME\",\"instance1\":\"$INSTANCE1\",\"instance2\":\"$INSTANCE2\"}"

    hc_vault_read $SECRET_ENGINE $PATH_SECRET $TOKEN >/dev/null
    RC=$? # If 4 no records found at path_secret

    [[ $RC == 0 ]] && CREDENTIAL_EXISTS=true || CREDENTIAL_EXISTS=false

    [[ $CREDENTIAL_EXISTS == true && $FORCE == "" ]] && {
        printf "${YELLOW}Credential $PATH_SECRET already exists! Use -f as first parameter to override ${NC}"
        return 0
    }
    
    RESPONSE=$(curl --silent -w "%{http_code}" --header "Content-Type: application/merge-patch+json" --header "X-VAULT-TOKEN: ${TOKEN}" -d '{"data":'$DATA_JSON'}' -X POST ${URL_VAULT}/${ENDPOINT})

    HTTP_STATUS=$(tail -n1 <<<"$RESPONSE")
    HTTP_RESPONSE=$(sed '$ d' <<<"$RESPONSE")

    if [[ ${HTTP_STATUS} != "200" ]]; then
        RC=1
        printf "${RED}-$HTTP_STATUS-${RESPONSE}${NC}"
        return $RC
    fi

    echo "$HTTP_RESPONSE"
    return 0
}
export -f hc_vault_create_multiple_key_value

hc_vault_read() {
    #**********************************************************************
    # info: reads a secret
    # method: GET
    # path: /secret/data/:path?version=:version-number
    # parameters: secret_eng,path_secret,token,version(optional)
    #***********************************************************************

    if [[ -z $1 || -z $2 || -z $3 ]]; then
        printf "${RED} - hc_vault_read: missing parameters secret_eng,path_secret,token,version(optional)${NC}"
        return 1
    fi

    local SECRET_ENGINE
    local PATH_SECRET
    local VERSION
    local TOKEN
    local ENDPOINT

    SECRET_ENGINE=$(echo ${1} | sed 's/^\/\?/\//')
    PATH_SECRET=$(echo $2 | sed 's/^\/\?/\//')
    TOKEN=$3
    [[ -n $4 ]] && VERSION=$4

    ENDPOINT="v1${SECRET_ENGINE}/data${PATH_SECRET}?version=$VERSION"

    RESPONSE=$(curl --silent -w "%{http_code}" --header "X-VAULT-TOKEN: ${TOKEN}" -X GET ${URL_VAULT}/${ENDPOINT})

    HTTP_STATUS=$(tail -n1 <<<"$RESPONSE")
    HTTP_RESPONSE=$(sed '$ d' <<<"$RESPONSE")

    if [[ ${HTTP_STATUS} == "404" ]]; then
        RC=4
        printf "${RED} - No records found${NC}"
        return $RC
    fi

    if [[ ${HTTP_STATUS} != "200" ]]; then
        RC=1
        printf "${RED} - $HTTP_RESPONSE${NC}"
        return $RC
    fi

    CREDENTIAL=$(echo $HTTP_RESPONSE | jq '.data.data')
    echo "$CREDENTIAL"
    return 0
}
export -f hc_vault_read

hc_vault_list() {
    #**********************************************************************
    # info: list secrets give a path directory
    # method: LIST
    # path: /secret/metadata/:path
    # parameters: secret_eng,path_secret,token
    #***********************************************************************

    if [[ -z $1 || -z $2 || -z $3 ]]; then
        printf "${RED}- hc_vault_list: missing parameters secret_eng,path_secret,token${NC}"
        return 1
    fi

    local SECRET_ENGINE
    local PATH_SECRET
    local TOKEN
    local ENDPOINT

    SECRET_ENGINE=$(echo ${1} | sed 's/^\/\?/\//')
    PATH_SECRET=$(echo $2 | sed 's/^\/\?/\//')
    TOKEN=$3

    ENDPOINT="v1${SECRET_ENGINE}/metadata${PATH_SECRET}"
    RESPONSE=$(curl --silent -w "%{http_code}" --header "X-VAULT-TOKEN: ${TOKEN}" -X LIST ${URL_VAULT}/${ENDPOINT})

    HTTP_STATUS=$(tail -n1 <<<"$RESPONSE")
    HTTP_RESPONSE=$(sed '$ d' <<<"$RESPONSE")

    if [[ ${HTTP_STATUS} == "404" ]]; then
        RC=4
        printf "${RED}-status:${HTTP_STATUS}${NC}"
        return $RC
    fi

    if [[ ${HTTP_STATUS} != "200" ]]; then
        RC=1
        printf "${RED}-status:${HTTP_STATUS}${NC}"
        return $RC
    fi

    CREDENTIALS=$(echo $HTTP_RESPONSE | jq '.data.keys' | sed -e 's/\"//g' -e 's/\///g' -e 's/\[//g' -e 's/\]//g' -e 's/\,/ /g')
    readarray CREDENTIALS_ARR <<< "$CREDENTIALS"
    echo ${CREDENTIALS_ARR[@]}
    return 0
}
export -f hc_vault_list

hc_vault_create_info_metadata() {
    #**********************************************************************
    # info: creates or updates an info metadata field of a secret at the specified location. It does not create a new version
    # method: POST
    # path: /secret/metadata/:path
    # parameters: secret_eng,path_secret,message,token
    #***********************************************************************

    if [[ -z $1 || -z $2 || -z "$3" || -z $4 ]]; then
        printf "${RED} - hc_vault_create_info_metadata: missing parameters secret_eng,path_secret,message,token${NC}"
        return 1
    fi

    local SECRET_ENGINE
    local PATH_SECRET
    local INFO_MESSAGE
    local TOKEN
    local ENDPOINT

    SECRET_ENGINE=$(echo ${1} | sed 's/^\/\?/\//')
    PATH_SECRET=$(echo $2 | sed 's/^\/\?/\//')
    INFO_MESSAGE="$3"
    TOKEN=$4
    [[ ! -z $5 ]] && SERVICE_METHOD="$5" || SERVICE_METHOD=""

    ENDPOINT="v1${SECRET_ENGINE}/metadata${PATH_SECRET}"
    CURRENT_DATE=$(date '+%Y-%m-%dT%H:%M:%S')"#$SERVICE_METHOD" #$(date '+%d-%m-%Y_%H:%M:%S')

    # Get current metadata
    #APPEND_METADATA=$(hc_vault_get_info_metadata $SECRET_ENGINE $PATH_SECRET $TOKEN | jq '.data.custom_metadata + {"'"$CURRENT_DATE"'":"'"${INFO_MESSAGE}"'"}' | tr -d '[:space:]')
    APPEND_METADATA=$(echo "{\"${CURRENT_DATE}\":\"${INFO_MESSAGE}\"}" | jq . | tr -d '[:space:]')
    RESPONSE=$(curl --silent -w "%{http_code}" --header "Content-Type: application/merge-patch+json" --header "X-VAULT-TOKEN: ${TOKEN}" -d '{"custom_metadata":'$APPEND_METADATA'}' -X PATCH ${URL_VAULT}/${ENDPOINT})

    HTTP_STATUS=$(tail -n1 <<<"$RESPONSE")
    HTTP_RESPONSE=$(sed '$ d' <<<"$RESPONSE")

    if [[ "${HTTP_STATUS}" != "204" && "${HTTP_STATUS}" != "200" ]]; then
        RC=1
        printf "${RED}-$HTTP_RESPONSE${NC}"
        return $RC
    fi

    echo "$HTTP_RESPONSE"
    return 0

}
export -f hc_vault_create_info_metadata

hc_vault_get_info_metadata() {

    #**********************************************************************
    # info: read an info metadata field of a secret at the specified location.
    # method: GET
    # path: /secret/metadata/:path
    # parameters: secret_eng,path_secret,token
    #***********************************************************************

    if [[ -z $1 || -z $2 || -z $3 ]]; then
        printf "${RED} - hc_vault_get_info_metadata: missing parameters secret_eng,path_secret,token${NC}"
        return 1
    fi

    local SECRET_ENGINE
    local PATH_SECRET
    local TOKEN
    local ENDPOINT

    SECRET_ENGINE=$(echo ${1} | sed 's/^\/\?/\//')
    PATH_SECRET=$(echo $2 | sed 's/^\/\?/\//')
    TOKEN=$3

    ENDPOINT="v1${SECRET_ENGINE}/metadata${PATH_SECRET}"

    RESPONSE=$(curl --silent -w "%{http_code}" --header "X-VAULT-TOKEN: ${TOKEN}" -X GET ${URL_VAULT}/${ENDPOINT})

    HTTP_STATUS=$(tail -n1 <<<"$RESPONSE")
    HTTP_RESPONSE=$(sed '$ d' <<<"$RESPONSE")

    if [[ ${HTTP_STATUS} != "200" ]]; then
        RC=1
        printf "${RED} - $HTTP_RESPONSE${NC}"
        return $RC
    fi

    echo "$HTTP_RESPONSE"
    return 0

}
export -f hc_vault_get_info_metadata

hc_vault_get_health() {

    #**********************************************************************
    # info: get status vault.
    # method: GET
    # path: /sys/health
    #***********************************************************************

    ENDPOINT="v1/sys/health"

    RESPONSE=$(curl --silent -w "%{http_code}" -X GET ${URL_VAULT}/${ENDPOINT})

    HTTP_STATUS=$(tail -n1 <<<"$RESPONSE")
    HTTP_RESPONSE=$(sed '$ d' <<<"$RESPONSE")

    if [[ ${HTTP_STATUS} != "200" ]]; then
        RC=1
        printf "${RED} - $HTTP_RESPONSE${NC}"
        return $RC
    fi

    echo "$HTTP_RESPONSE"
    return 0

}
export -f hc_vault_get_health
