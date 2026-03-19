<#
.SYNOPSIS
    Generates tnsnames.ora files from HashiCorp Vault connection data.

.DESCRIPTION
    PowerShell port of vault_create_tnsnames.sh.
    Reads Oracle connection data (host, port, service name) from Vault and writes
    per-environment tnsnames.ora files into sub-directories next to the script.

    NOTE: Save this file with UTF-8 BOM encoding for full PowerShell 5.1 compatibility.

.PARAMETER Environment
    Environment code, MANDATORY (amm | svi | int | tst | pre | prd).

.PARAMETER Wallet
    Generate wallet-style aliases with the DB username embedded in the alias.

.PARAMETER AddEnvSuffix
    Append the environment code to each alias name (non-idempotent / cross-env mode).

.PARAMETER Failover
    Emit FAILOVER=true connection descriptors.

.PARAMETER Instance
    Comma-separated list of instance names to process.
    When omitted the full list is fetched from Vault.

.PARAMETER NoUser
    Generate connection aliases without any user name (-a in the shell).

.PARAMETER Filter
    Filter generated aliases by regexp pattern.
    E.g. "U_ASIA" keeps only entries whose alias contains _U_ASIA=,
    avoiding partial matches like U_ASIAI, U_ASIA2.
    The anchor is added automatically when the pattern is a plain username.

.PARAMETER UserList
    Comma-separated list of DB users to include (wallet mode only).

.PARAMETER DebugConnections
    Generate debug aliases featuring INSTANCE_NAME for each RAC node (-D in shell).

.PARAMETER Versions
    By default version-specific aliases (_11, _12, _19) are skipped.
    Specify this switch to include them.

.PARAMETER Push
    Commit the generated files to the SVN repository (requires svn CLI).

.PARAMETER SecretEngine
    Vault KV engine containing DB user credentials (default: database).

.PARAMETER OracleDatabaseSecretEngine
    Vault KV engine containing DB connection data (default: oracle_database).

.PARAMETER VaultUsername
    Vault username for authentication.

.PARAMETER VaultPassword
    Vault password for authentication.

.PARAMETER VaultLibPath
    Path to vault_lib.ps1 (default: .\vault_lib.ps1).

.EXAMPLE
    # DB_ASIA_U_ASIA_PRD - wallet alias with env suffix and user filter
    .\vault_create_tnsnames.ps1 -Environment PRD -Instance prd1 -Wallet -AddEnvSuffix -Filter U_ASIA `
        -VaultUsername vault_user -VaultPassword vault_pass

.EXAMPLE
    # DB_ASIA - basic alias
    .\vault_create_tnsnames.ps1 -Environment SVI -Instance svi1 `
        -VaultUsername vault_user -VaultPassword vault_pass

.EXAMPLE
    # DB_ASIA_SVI, DB_ASIA_SVI_12 - nouser alias with env suffix
    .\vault_create_tnsnames.ps1 -Environment SVI -Instance svi1 -NoUser -AddEnvSuffix `
        -VaultUsername vault_user -VaultPassword vault_pass
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Environment = "",

    [switch]$Wallet,
    [switch]$AddEnvSuffix,
    [switch]$Failover,

    [Parameter(Mandatory = $false)]
    [string]$Instance = "",

    [switch]$NoUser,

    [Parameter(Mandatory = $false)]
    [string]$Filter = "",

    [Parameter(Mandatory = $false)]
    [string]$UserList = "",

    [switch]$DebugConnections,
    [switch]$Versions,
    [switch]$Push,

    [string]$SecretEngine = "database",
    [string]$OracleDatabaseSecretEngine = "oracle_database",

    [Parameter(Mandatory = $false)]
    [string]$VaultUsername = "",

    [Parameter(Mandatory = $false)]
    [string]$VaultPassword = "",

    [string]$VaultLibPath = ".\vault_lib.ps1"
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

# ==============================================================================
# Constants
# ==============================================================================

$ENVIRONMENT_LIST = @("amm", "svi", "int", "tst", "pre", "prd")
$SVN_SERVICE_USER = "service_vault"
$SVN_BASE_URL     = ""

# ==============================================================================
# Output helpers
# ==============================================================================

function Write-Info  ([string]$msg) { Write-Host "[INFO]    $msg" -ForegroundColor Green  }
function Write-Warn  ([string]$msg) { Write-Host "[WARNING] $msg" -ForegroundColor Yellow }
function Write-Err   ([string]$msg) { Write-Host "[ERROR]   $msg" -ForegroundColor Red    }

# ==============================================================================
# File helpers
# ==============================================================================

$script:utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function New-TnsFile ([string]$path) {
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    if (Test-Path $path) {
        Write-Warn "$path already exists, recreating..."
        Remove-Item $path
    }
    [System.IO.File]::WriteAllText($path, "", $script:utf8NoBom)
    [System.IO.File]::AppendAllText($path, "# Generated from vault_create_tnsnames.ps1`r`n`r`n", $script:utf8NoBom)
}

function Add-TnsLine ([string]$path, [string]$line) {
    [System.IO.File]::AppendAllText($path, "$line`r`n", $script:utf8NoBom)
}

# Returns $true when $line matches the active filter regexp (case-insensitive).
# An empty filter always passes.
function Test-FilterMatch ([string]$line) {
    if ([string]::IsNullOrEmpty($script:Filter)) { return $true }
    return ($line -imatch $script:Filter)
}

# ==============================================================================
# TNS entry builders
# ==============================================================================

function Build-TnsEntry ([string]$alias, [string]$dbHost, [string]$port, [string]$svc) {
    return "${alias}=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${dbHost})(PORT=${port}))(CONNECT_DATA=(SERVICE_NAME=${svc}.domain.local)))"
}

function Build-FailoverTnsEntry ([string]$alias, [string]$dbHost, [string]$port, [string]$svc) {
    return "${alias}=(DESCRIPTION=(FAILOVER=true)(LOAD_BALANCE=true)(ADDRESS=(PROTOCOL=TCP)(HOST=${dbHost})(PORT=${port}))(CONNECT_DATA=(SERVICE_NAME=${svc}.domain.local)(FAILOVER_MODE=(TYPE=select)(METHOD=preconnect)(RETRIES=20)(DELAY=3))))"
}

function Build-DebugTnsEntry ([string]$alias, [string]$dbHost, [string]$port, [string]$svc, [string]$instName, [bool]$failover) {
    if ($failover) {
        return "${alias}=(DESCRIPTION=(FAILOVER=true)(LOAD_BALANCE=true)(ADDRESS=(PROTOCOL=TCP)(HOST=${dbHost})(PORT=${port}))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=${svc})(INSTANCE_NAME=${instName})(UR=A)(FAILOVER_MODE=(TYPE=select)(METHOD=preconnect)(RETRIES=20)(DELAY=3))))"
    }
    return "${alias}=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${dbHost})(PORT=${port}))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=${svc})(INSTANCE_NAME=${instName})(UR=A)))"
}

# ==============================================================================
# Alias name builders
# ==============================================================================

# Wallet alias: embeds DB user, optionally the env suffix, preserves _11/_12/_19.
function Get-WalletAlias ([string]$conn, [string]$user, [string]$envUp, [bool]$addEnv) {
    if ($addEnv) {
        if ($conn -match '_11') { return $conn -replace '_11', "_${user}_${envUp}_11" }
        if ($conn -match '_12') { return $conn -replace '_12', "_${user}_${envUp}_12" }
        if ($conn -match '_19') { return $conn -replace '_19', "_${user}_${envUp}_19" }
        return "${conn}_${user}_${envUp}"
    }
    if ($conn -match '_11') { return $conn -replace '_11', "_${user}_11" }
    if ($conn -match '_12') { return $conn -replace '_12', "_${user}_12" }
    if ($conn -match '_19') { return $conn -replace '_19', "_${user}_19" }
    return "${conn}_${user}"
}

# Nouser alias: optionally adds env suffix, preserves _12/_19 (no _11 in nouser mode).
function Get-NoUserAlias ([string]$conn, [string]$envUp, [bool]$addEnv) {
    if ($addEnv) {
        if ($conn -match '_12') { return $conn -replace '_12', "_${envUp}_12" }
        if ($conn -match '_19') { return $conn -replace '_19', "_${envUp}_19" }
        return "${conn}_${envUp}"
    }
    return $conn
}

# ==============================================================================
# SVN helper
# ==============================================================================

function Invoke-SvnPush ([string]$folder, [string]$svnUrl, [string]$svnPass) {
    if (-not (Get-Command svn -ErrorAction SilentlyContinue)) {
        Write-Warn "svn command not found. Skipping SVN push for $folder."
        return
    }
    Push-Location $folder
    try {
        Write-Info "Pushing to SVN: $svnUrl ..."
        & svn add --force * --auto-props --parents --depth infinity -q
        & svn commit -m "Aggiornamento dati da vault_create_tnsnames.ps1" `
            --username $SVN_SERVICE_USER --password $svnPass
    }
    finally {
        Pop-Location
    }
}

# ==============================================================================
# Alias generator functions
# ==============================================================================

function Invoke-DebugAlias {
    param(
        [string[]]$DbInstances,
        [string]$PathSecret,
        [string]$Token,
        [string]$EnvCode,
        [string]$OutFile
    )

    Write-Info "Generating DEBUG_ALIAS tnsnames.ora.$EnvCode..."
    New-TnsFile $OutFile
    Add-TnsLine $OutFile "# Function: Invoke-DebugAlias()"
    Add-TnsLine $OutFile ""

    foreach ($dbInstance in $DbInstances) {
        $dbInstance  = $dbInstance.ToLower()
        $connections = Get-VaultSecretList -SecretEngine $OracleDatabaseSecretEngine `
            -PathSecret "/$PathSecret/$dbInstance" -Token $Token

        foreach ($dbConn in $connections) {
            $secret = Get-VaultSecret -SecretEngine $OracleDatabaseSecretEngine `
                -PathSecret "/$PathSecret/$dbInstance/$dbConn" -Token $Token
            if ($null -eq $secret) { continue }

            $dbHost    = $secret.host
            $dbPort    = $secret.port
            $instance1 = $secret.instance1
            $instance2 = $secret.instance2

            if ([string]::IsNullOrEmpty($dbHost) -or [string]::IsNullOrEmpty($dbPort)) {
                Write-Err "${dbConn}: db_host or db_port missing in vault!"; exit 1
            }

            $nullInst1 = [string]::IsNullOrEmpty($instance1) -or $instance1 -eq "null"
            $nullInst2 = [string]::IsNullOrEmpty($instance2) -or $instance2 -eq "null"

            if ($nullInst1 -and $nullInst2) {
                Write-Warn "${dbConn}: instance1 and instance2 missing in vault, skipping."
                continue
            }

            if (-not $Versions -and $dbConn -match '_\d\d$') { continue }

            if (-not $nullInst1) {
                $entry = Build-DebugTnsEntry "${dbConn}_1" $dbHost $dbPort $dbInstance $instance1 $Failover.IsPresent
                if (Test-FilterMatch $entry) { Add-TnsLine $OutFile $entry }
            }
            if (-not $nullInst2) {
                $entry = Build-DebugTnsEntry "${dbConn}_2" $dbHost $dbPort $dbInstance $instance2 $Failover.IsPresent
                if (Test-FilterMatch $entry) { Add-TnsLine $OutFile $entry }
            }
        }
    }

    Write-Info "Done!"
}

function Invoke-BasicAlias {
    param(
        [string[]]$DbInstances,
        [string]$PathSecret,
        [string]$Token,
        [string]$EnvUpper,
        [string]$OutFile
    )

    Write-Info "Generating BASIC_ALIAS tnsnames.ora.$($EnvUpper.ToLower())..."
    New-TnsFile $OutFile
    Add-TnsLine $OutFile "# Function: Invoke-BasicAlias()"
    Add-TnsLine $OutFile ""

    foreach ($dbInstance in $DbInstances) {
        $dbInstance  = $dbInstance.ToLower()
        $connections = Get-VaultSecretList -SecretEngine $OracleDatabaseSecretEngine `
            -PathSecret "/$PathSecret/$dbInstance" -Token $Token

        foreach ($dbConn in $connections) {
            $secret = Get-VaultSecret -SecretEngine $OracleDatabaseSecretEngine `
                -PathSecret "/$PathSecret/$dbInstance/$dbConn" -Token $Token
            if ($null -eq $secret) { continue }

            $dbHost = $secret.host
            $dbPort = $secret.port

            if ([string]::IsNullOrEmpty($dbHost) -or [string]::IsNullOrEmpty($dbPort)) {
                Write-Err "db_host or db_port missing in vault!"; exit 1
            }

            if (-not $Versions -and $dbConn -match '_\d\d$') { continue }

            $alias = if ($AddEnvSuffix) { "${dbConn}_${EnvUpper}" } else { $dbConn }
            $entry = if ($Failover) {
                Build-FailoverTnsEntry $alias $dbHost $dbPort $dbInstance
            } else {
                Build-TnsEntry $alias $dbHost $dbPort $dbInstance
            }

            if (Test-FilterMatch $entry) { Add-TnsLine $OutFile $entry }
        }
    }

    Write-Info "Done!"
}

function Invoke-WalletAlias {
    param(
        [string[]]$DbInstances,
        [string]$PathSecret,
        [string]$Token,
        [string]$EnvUpper,
        [string[]]$UserListFilter,
        [string]$OutFile
    )

    Write-Info "Generating WALLET_ALIAS tnsnames.ora.$($EnvUpper.ToLower())..."
    New-TnsFile $OutFile
    Add-TnsLine $OutFile "# Function: Invoke-WalletAlias()"
    Add-TnsLine $OutFile ""

    foreach ($dbInstance in $DbInstances) {
        $dbInstance       = $dbInstance.ToLower()
        $credentials      = Get-VaultSecretList -SecretEngine $SecretEngine `
            -PathSecret "/$PathSecret/$dbInstance" -Token $Token
        $connections      = Get-VaultSecretList -SecretEngine $OracleDatabaseSecretEngine `
            -PathSecret "/$PathSecret/$dbInstance" -Token $Token

        foreach ($dbUser in $credentials) {
            if ($dbUser -match '404') {
                Write-Warn "User in instance ${dbInstance}: $dbUser"
                continue
            }
            if ($UserListFilter.Count -gt 0 -and $UserListFilter -notcontains $dbUser) { continue }

            foreach ($dbConn in $connections) {
                $secret = Get-VaultSecret -SecretEngine $OracleDatabaseSecretEngine `
                    -PathSecret "/$PathSecret/$dbInstance/$dbConn" -Token $Token
                if ($null -eq $secret) { continue }

                $dbHost = $secret.host
                $dbPort = $secret.port

                if ([string]::IsNullOrEmpty($dbHost) -or [string]::IsNullOrEmpty($dbPort)) {
                    Write-Err "db_host or db_port missing in vault!"; exit 1
                }

                if (-not $Versions -and $dbConn -match '_\d\d$') { continue }

                $alias = Get-WalletAlias $dbConn $dbUser $EnvUpper $AddEnvSuffix.IsPresent
                $entry = if ($Failover) {
                    Build-FailoverTnsEntry $alias $dbHost $dbPort $dbInstance
                } else {
                    Build-TnsEntry $alias $dbHost $dbPort $dbInstance
                }

                if (Test-FilterMatch $entry) { Add-TnsLine $OutFile $entry }
            }
        }
    }

    Write-Info "Done!"
}

function Invoke-NoUserAllAlias {
    param(
        [string[]]$DbInstances,
        [string]$Token,
        [string]$EnvCode,
        [string]$EnvUpper,
        [string]$OutFile
    )

    Write-Info "Generating NOUSER_ALIAS for $EnvCode..."
    New-TnsFile $OutFile
    Add-TnsLine $OutFile "# Function: Invoke-NoUserAllAlias()"
    Add-TnsLine $OutFile ""

    foreach ($env in $ENVIRONMENT_LIST) {
        # When $EnvCode is set (it always is, since -Environment is required),
        # process only the matching environment.
        if ($EnvCode -ne "" -and $EnvCode -ne $env) { continue }

        $pathSecret = "$env/paas/oracle"
        $envUp      = $env.ToUpper()

        if ($DbInstances -contains '404') {
            Write-Warn "No instances found for $env"
            continue
        }

        Add-TnsLine $OutFile ""
        Add-TnsLine $OutFile "#-----${envUp}-----"

        foreach ($dbInstance in $DbInstances) {
            $dbInstance  = $dbInstance.ToLower()
            $connections = Get-VaultSecretList -SecretEngine $OracleDatabaseSecretEngine `
                -PathSecret "/$pathSecret/$dbInstance" -Token $Token

            foreach ($dbConn in $connections) {
                $secret = Get-VaultSecret -SecretEngine $OracleDatabaseSecretEngine `
                    -PathSecret "/$pathSecret/$dbInstance/$dbConn" -Token $Token
                if ($null -eq $secret) { continue }

                $dbHost = $secret.host
                $dbPort = $secret.port

                if ([string]::IsNullOrEmpty($dbHost) -or [string]::IsNullOrEmpty($dbPort)) {
                    Write-Err "db_host or db_port missing in vault!"; exit 1
                }

                if (-not $Versions -and $dbConn -match '_\d\d$') { continue }

                $alias = Get-NoUserAlias $dbConn $envUp $AddEnvSuffix.IsPresent
                $entry = if ($Failover) {
                    Build-FailoverTnsEntry $alias $dbHost $dbPort $dbInstance
                } else {
                    Build-TnsEntry $alias $dbHost $dbPort $dbInstance
                }

                if (Test-FilterMatch $entry) { Add-TnsLine $OutFile $entry }
            }
        }
    }

    Write-Info "Done!"
}

# ==============================================================================
# Main
# ==============================================================================

# ---- Usage / parameter validation --------------------------------------------

if ([string]::IsNullOrEmpty($Environment)) {
    Write-Host ""
    Write-Host "Usage: vault_create_tnsnames.ps1 -Environment ENV [-Wallet] [-AddEnvSuffix]" -ForegroundColor Cyan
    Write-Host "           [-Failover] [-NoUser] [-DebugConnections] [-Versions]"
    Write-Host "           [-Instance inst1,inst2] [-Filter REGEXP] [-UserList user1,user2]"
    Write-Host "           [-Push] -VaultUsername USER -VaultPassword PASS"
    Write-Host "           [-VaultLibPath PATH] [-SecretEngine ENGINE]"
    Write-Host "           [-OracleDatabaseSecretEngine ENGINE]"
    Write-Host ""
    Write-Host "  -Environment      MANDATORY environment code (amm|svi|int|tst|pre|prd)"
    Write-Host "  -Wallet           alias with DB user embedded  (e.g. DB_ASIA_U_ASIA)"
    Write-Host "  -AddEnvSuffix     append env to alias          (e.g. DB_ASIA_U_ASIA_PRD)"
    Write-Host "  -Instance         comma-separated instance names (default: all from Vault)"
    Write-Host "  -NoUser           alias without user name"
    Write-Host "  -Failover         FAILOVER=true connection descriptor"
    Write-Host "  -Filter REGEXP    keep only entries matching the pattern"
    Write-Host "  -UserList         comma-separated users to include (wallet mode only)"
    Write-Host "  -DebugConnections debug aliases with INSTANCE_NAME per RAC node"
    Write-Host "  -Versions         include _11/_12/_19 version aliases (default: skip)"
    Write-Host "  -Push             commit generated files to SVN (requires svn CLI)"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  DB_ASIA_U_ASIA_PRD : .\vault_create_tnsnames.ps1 -Env PRD -Instance prd1 -Wallet -AddEnvSuffix -Filter U_ASIA"
    Write-Host "  DB_ASIA            : .\vault_create_tnsnames.ps1 -Env SVI -Instance svi1"
    Write-Host "  DB_ASIA_1 (debug)  : .\vault_create_tnsnames.ps1 -Env SVI -Instance svi1 -DebugConnections"
    Write-Host ""
    exit 1
}

if ([string]::IsNullOrEmpty($VaultUsername) -or [string]::IsNullOrEmpty($VaultPassword)) {
    Write-Err "-VaultUsername and -VaultPassword are required."
    exit 1
}

# ---- Load vault_lib.ps1 ------------------------------------------------------

$VaultLibPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($VaultLibPath)
if (-not (Test-Path $VaultLibPath)) {
    Write-Err "vault_lib.ps1 not found at: $VaultLibPath"
    Write-Err "Trying to find vault_lib.ps1 in the script directory..."
    $VaultLibPath = Get-ChildItem -Path $PSScriptRoot -Filter 'vault_lib.ps1' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $VaultLibPath -or -not (Test-Path $VaultLibPath)) {
        Write-Err "vault_lib.ps1 not found in the script directory: $PSScriptRoot"
        exit 1
    }
    Write-Host "Found vault_lib.ps1 at: $VaultLibPath"
}
. $VaultLibPath

# ---- Determine alias type ----------------------------------------------------

$AliasType = "b"   # basic (default)
if ($Wallet)           { $AliasType = "w" }
if ($NoUser)           { $AliasType = "a" }
if ($DebugConnections) { $AliasType = "D" }

# ---- Normalise env -----------------------------------------------------------

$script:ENV = $Environment.ToLower()
$EnvUpper   = $script:ENV.ToUpper()

# ---- Normalise filter regexp (mirrors the shell logic) -----------------------
# A plain username like "U_ASIA" becomes "_U_ASIA=" to avoid partial matches.

if (-not [string]::IsNullOrEmpty($Filter)) {
    if ($Filter -notmatch '^_' -and $Filter -notmatch '[=$]$') {
        $script:Filter = "_${Filter}="
    } else {
        $script:Filter = $Filter
    }
} else {
    $script:Filter = ""
}

# ---- Output paths ------------------------------------------------------------

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

$TNSNAMES_BASIC_FOLDER  = Join-Path $scriptDir "tnsnames_basic"
$TNSNAMES_DEBUG_FOLDER  = Join-Path $scriptDir "tnsnames_debug"
$TNSNAMES_WALLET_FOLDER = Join-Path $scriptDir "tnsnames_wallet"
$TNSNAMES_ALL_FOLDER    = Join-Path $scriptDir "tnsnames_nouser"

$TNSNAMES_BASIC         = Join-Path $TNSNAMES_BASIC_FOLDER  "tnsnames.ora.$($script:ENV)"
$TNSNAMES_DEBUG         = Join-Path $TNSNAMES_DEBUG_FOLDER  "tnsnames.ora.$($script:ENV)"
$TNSNAMES_WALLET        = Join-Path $TNSNAMES_WALLET_FOLDER "tnsnames.ora.$($script:ENV)"
$TNSNAMES_ALL_ENV       = if ($script:ENV) {
    Join-Path $TNSNAMES_ALL_FOLDER "tnsnames.ora.nouser.$($script:ENV)"
} else {
    Join-Path $TNSNAMES_ALL_FOLDER "tnsnames.ora.nouser"
}

$pathSecret = "$($script:ENV)/paas/oracle"

# ---- Parse instance and user lists -------------------------------------------

$dbInstances   = @()
if (-not [string]::IsNullOrEmpty($Instance)) {
    $dbInstances = $Instance.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
}

$userListArray = @()
if (-not [string]::IsNullOrEmpty($UserList)) {
    $userListArray = $UserList.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
}

# ---- Vault authentication ----------------------------------------------------

Write-Info "Checking Vault seal status..."
$isSealed = Test-VaultSealed
if ($isSealed) {
    Write-Err "Vault is sealed. Please unseal it before running this script."
    exit 1
}

Write-Info "Authenticating to Vault as '$VaultUsername'..."
$token = Invoke-VaultLogin -Username $VaultUsername -Password $VaultPassword
if (-not $token) {
    Write-Err "Failed to obtain Vault token."
    exit 1
}

# ---- Retrieve instance list from Vault if not specified ---------------------

if ($dbInstances.Count -eq 0) {
    Write-Info "Listing instances from Vault: $OracleDatabaseSecretEngine/$pathSecret ..."
    $dbInstances = Get-VaultSecretList -SecretEngine $OracleDatabaseSecretEngine `
        -PathSecret "/$pathSecret" -Token $token
    if (-not $dbInstances -or $dbInstances.Count -eq 0) {
        Write-Err "No instances found in Vault at $OracleDatabaseSecretEngine/$pathSecret."
        exit 1
    }
}

# ---- Retrieve SVN password if push is requested ------------------------------

$svnPassword = ""
if ($Push) {
    Write-Info "Reading SVN credentials from Vault..."
    $svnData = Get-VaultSecret -SecretEngine "web" -PathSecret "/svn/$SVN_SERVICE_USER" -Token $token
    if ($svnData -and $svnData.$SVN_SERVICE_USER) {
        $svnPassword = $svnData.$SVN_SERVICE_USER
    } else {
        Write-Warn "Could not retrieve SVN password from Vault. Push may fail."
    }
}

# ---- Invoke the selected alias generator ------------------------------------

switch ($AliasType) {

    "D" {
        Invoke-DebugAlias -DbInstances $dbInstances -PathSecret $pathSecret -Token $token `
            -EnvCode $script:ENV -OutFile $TNSNAMES_DEBUG
        if ($Push) { Invoke-SvnPush $TNSNAMES_DEBUG_FOLDER "$SVN_BASE_URL/tnsnames_debug" $svnPassword }
    }

    "w" {
        Invoke-WalletAlias -DbInstances $dbInstances -PathSecret $pathSecret -Token $token `
            -EnvUpper $EnvUpper -UserListFilter $userListArray -OutFile $TNSNAMES_WALLET
        if ($Push) { Invoke-SvnPush $TNSNAMES_WALLET_FOLDER "$SVN_BASE_URL/tnsnames_wallet" $svnPassword }
    }

    "a" {
        Invoke-NoUserAllAlias -DbInstances $dbInstances -Token $token `
            -EnvCode $script:ENV -EnvUpper $EnvUpper -OutFile $TNSNAMES_ALL_ENV
        if ($Push) { Invoke-SvnPush $TNSNAMES_ALL_FOLDER "$SVN_BASE_URL/tnsnames_nouser" $svnPassword }
    }

    default {
        Invoke-BasicAlias -DbInstances $dbInstances -PathSecret $pathSecret -Token $token `
            -EnvUpper $EnvUpper -OutFile $TNSNAMES_BASIC
        if ($Push) { Invoke-SvnPush $TNSNAMES_BASIC_FOLDER "$SVN_BASE_URL/tnsnames_basic" $svnPassword }
    }
}

# ---- Print summary -----------------------------------------------------------

Write-Host ""
Write-Info "Generated tnsnames aliases:"

foreach ($f in @($TNSNAMES_BASIC, $TNSNAMES_DEBUG, $TNSNAMES_WALLET, $TNSNAMES_ALL_ENV)) {
    if (Test-Path $f) {
        Write-Host ""
        Write-Host "--- $f ---" -ForegroundColor Cyan
        Get-Content $f | Where-Object { $_ -notmatch '^#' -and $_ -ne '' }
    }
}

exit 0
