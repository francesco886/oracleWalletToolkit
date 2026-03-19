#!/usr/bin/env pwsh

# =========================================================================================
# SCRIPT NAME: oracleWalletToolkit.ps1
# VERSION:     2.0
#
# DESCRIPTION:
#    Oracle Wallet toolkit with Vault Integration - PowerShell port of oracleWalletToolkit.sh
# =========================================================================================
# Usage: .\oracleWalletToolkit.ps1 -DbUser <db_user> -OracleInstance <oracle_instance>
#                     -Environment <environment> -DbAlias <db_alias>
#                     -TnsAdmin <tns_admin> -OsUser <os_user>
#                     -MasterWallet <master_wallet> -VaultUsername <vault_user>
#                     -VaultPassword <vault_pass>
#                     [-CreateWallet] [-ListWallet] [-TestWallet] [-AutoLoginLocal]
#                     [-DeleteCredential] [-DryRun] [-Bare] [-LogFile <logfile>]
#
# Parameters:
#   -DbUser           Database user name
#   -OracleInstance   Oracle instance name
#   -Environment      Environment code (svi, int, tst, pre, prd, amm)
#   -DbAlias          TNS alias for the connection
#   -TnsAdmin         Path to TNS_ADMIN directory (wallet location)
#   -OsUser           OS user that owns the wallet files (informational on Windows)
#   -MasterWallet     Master wallet password
#   -VaultUsername    Vault username for authentication
#   -VaultPassword    Vault password for authentication
#   -CreateWallet     Create wallet if it doesn't exist
#   -ListWallet       List wallet credentials and exit
#   -TestWallet       Test all wallet credentials and show report
#   -AutoLoginLocal   Convert wallet to auto-login-local (CIS compliant)
#   -DeleteCredential Delete a credential entry from the wallet (requires -DbAlias)
#   -DryRun           Show what would be done without doing it
#   -Bare             Minimal output, disables coloring
#   -LogFile          Optional log file path
#
# NOTE: Oracle tools (mkstore, sqlplus, orapki) must be in PATH (ORACLE_HOME\bin).
# =========================================================================================

<#
.SYNOPSIS
    Oracle Wallet toolkit with Vault Integration (PowerShell v2.0)

.PARAMETER DbUser
    Database user name (required)

.PARAMETER OracleInstance
    Oracle instance name (required)

.PARAMETER Environment
    Environment code: svi, int, tst, pre, prd (required)

.PARAMETER DbAlias
    TNS alias for the connection (required)

.PARAMETER TnsAdmin
    Path to TNS_ADMIN directory/wallet location (required)

.PARAMETER MasterWallet
    Master wallet password (required)

.PARAMETER VaultUsername
    Vault username for authentication (required)

.PARAMETER VaultPassword
    Vault password for authentication (required)

.PARAMETER VaultLibPath
    Path to vault_lib.ps1 module (default: .\vault_lib.ps1)

.PARAMETER OracleBinPath
    Oracle client bin directory added to PATH if tools not found (optional)

.PARAMETER DryRun
    Dry-run mode - show what would be done without making changes (switch)

.EXAMPLE
    # Configure wallet credentials
    .\oracleWalletToolkit.ps1 -DbUser "A_IDL" -OracleInstance "svi0" -Environment "svi" `
        -DbAlias "SVI0_A_IDL" -TnsAdmin "C:\app\user\SVI0\conf\base\service\tns_admin" `
        -MasterWallet "wallet_pass" -VaultUsername "vault_user" -VaultPassword "vault_pass"

.EXAMPLE
    # Create wallet only (standalone mode)
    .\oracleWalletToolkit.ps1 -TnsAdmin "C:\app\user\SVI0\conf\base\service\tns_admin" `
        -MasterWallet "wallet_pass" -CreateWallet

.NOTES
    Version: 2.0
    Date: 2026-02-24
    Requires: Oracle Client tools (mkstore, sqlplus, orapki) in PATH or via -OracleBinPath, vault_lib.ps1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Database user name")]
    [string]$DbUser = "",
    
    [Parameter(Mandatory = $false, HelpMessage = "Oracle instance name")]
    [string]$OracleInstance = "",
    
    [Parameter(Mandatory = $false, HelpMessage = "Environment code (svi, int, tst, pre, prd)")]
    [string]$Environment = "",
    
    [Parameter(Mandatory = $false, HelpMessage = "TNS alias for connection")]
    [string]$DbAlias = "",
    
    [Parameter(Mandatory = $false, HelpMessage = "Path to TNS_ADMIN directory")]
    [string]$TnsAdmin = "",
    
    [Parameter(Mandatory = $false, HelpMessage = "OS user that owns the wallet (informational on Windows)")]
    [string]$OsUser = "",
    
    [Parameter(Mandatory = $false, HelpMessage = "Master wallet password")]
    [string]$MasterWallet = "",
    
    [Parameter(Mandatory = $false, HelpMessage = "Vault username")]
    [string]$VaultUsername = "",
    
    [Parameter(Mandatory = $false, HelpMessage = "Vault password")]
    [string]$VaultPassword = "",
    
    [Parameter(Mandatory = $false, HelpMessage = "Path to vault_lib.ps1 (auto-discovered if not specified)")]
    [string]$VaultLibPath = "",

    [Parameter(Mandatory = $false, HelpMessage = "Oracle client bin directory (added to PATH if tools not found)")]
    [string]$OracleBinPath = "",

    [Parameter(Mandatory = $false, HelpMessage = "Path to vault_create_tnsnames.ps1 (auto-discovered if not specified)")]
    [string]$VaultCreateTnsnamesPath = "",
    
    [Parameter(Mandatory = $false, HelpMessage = "Create wallet if it doesn't exist")]
    [switch]$CreateWallet,
    
    [Parameter(Mandatory = $false, HelpMessage = "List wallet credentials and exit")]
    [switch]$ListWallet,
    
    [Parameter(Mandatory = $false, HelpMessage = "Test all wallet credentials and show report")]
    [switch]$TestWallet,
    
    [Parameter(Mandatory = $false, HelpMessage = "Convert wallet to auto-login-local")]
    [switch]$AutoLoginLocal,

    [Parameter(Mandatory = $false, HelpMessage = "Delete a credential entry from the wallet (requires -DbAlias)")]
    [switch]$DeleteCredential,

    [Parameter(Mandatory = $false, HelpMessage = "Reset ACL on TnsAdmin folder and all its contents (Windows only)")]
    [switch]$FixPermissions,

    [Parameter(Mandatory = $false, HelpMessage = "Generate TNS entries in failover mode (FAILOVER=true with FAILOVER_MODE)")]
    [switch]$Failover,
    
    [Parameter(Mandatory = $false, HelpMessage = "Dry-run mode (no changes)")]
    [switch]$DryRun,
    
    [Parameter(Mandatory = $false, HelpMessage = "Minimal output, disables coloring")]
    [switch]$Bare,
    
    [Parameter(Mandatory = $false, HelpMessage = "Optional log file path")]
    [string]$LogFile = ""
)

# Set strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Configuration
$SecretEngine = "database"
$TempCredFile = "$env:TEMP\temp_cred_$PID.txt"

# Globals (mirroring .sh counterparts)
$myHostname = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { hostname }
$WarnCount  = 0
$ErrCount   = 0

# Color map (populated by Set-OutputColors; empty strings when -Bare)
$Colors = @{
    Red    = ""
    Green  = ""
    Yellow = ""
    Blue   = ""
    Cyan   = ""
    NC     = ""   # reset — unused in PS but kept for symmetry
}

# =========================================================================================
# UTILITIES
# =========================================================================================

# Equivalent of setColor() in .sh — populates $Colors based on -Bare flag.
function Set-OutputColors {
    if (-not $Bare) {
        $script:Colors = @{
            Red    = "Red"
            Green  = "Green"
            Yellow = "Yellow"
            Blue   = "Cyan"
            Cyan   = "Cyan"
            NC     = ""
        }
    }
    # In Bare mode the hashtable stays all-empty (no colour output).
}

# Equivalent of putMsg() in .sh.
# Severity: INFO | WARN | ERROR | OK | DRY
# Prints:  "<hostname> <timestamp> <SEV>: <message>"
# Also appends a plain-text line to $LogFile when set.
function Write-Msg {
    param(
        [ValidateSet("INFO","WARN","ERROR","OK","DRY")]
        [string]$Severity,
        [string]$Message = ""
    )

    switch ($Severity) {
        "WARN"  { $script:WarnCount++;  $color = $script:Colors.Yellow }
        "ERROR" { $script:ErrCount++;   $color = $script:Colors.Red    }
        "OK"    {                        $color = $script:Colors.Green  }
        "DRY"   {                        $color = $script:Colors.Blue   }
        default {                        $color = $script:Colors.Cyan   }   # INFO
    }

    $timestamp    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $formattedMsg = "$script:myHostname $timestamp ${Severity}: $Message"

    if ($color) {
        Write-Host $formattedMsg -ForegroundColor $color
    } else {
        Write-Host $formattedMsg
    }

    if ($LogFile) {
        Add-Content -Path $LogFile -Value $formattedMsg
    }
}

# Check Oracle commands availability (equivalent to checkOracleCommands in .sh)
function Test-OracleCommands {
    param([string]$BinPath = "")
    # If tools not in PATH yet, try adding the provided bin directory
    if ($BinPath -and (Test-Path $BinPath) -and ($env:PATH -notlike "*$BinPath*")) {
        $env:PATH = "$BinPath;$env:PATH"
    }
    $missing = @()
    foreach ($cmd in @('mkstore', 'sqlplus', 'orapki')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            $missing += $cmd
        }
    }
    if ($missing.Count -gt 0) {
        throw "Required Oracle commands not found in PATH: $($missing -join ', '). Ensure ORACLE_HOME\bin is in your PATH."
    }
}

# Ensures tnsnames.ora and sqlnet.ora exist in $TnsAdminDir.
# If tnsnames.ora is missing, generates it via vault_create_tnsnames.ps1 with a user filter.
# Equivalent to ensureTnsFiles() in oracleWalletToolkit.sh.
# Returns $true on success, $false on failure (non-fatal — caller logs a warning).
function Invoke-EnsureTnsFiles {
    param(
        [string]$TnsAdminDir,
        [string]$EnvCode,
        [string]$InstanceName,
        [string]$User,
        [string]$VaultUser,
        [string]$VaultPass,
        [string]$CreateTnsnamesScript,
        [switch]$Failover
    )

    $tnsnamesFile = Join-Path $TnsAdminDir 'tnsnames.ora'

    if (-not (Test-Path $tnsnamesFile)) {
        Write-Msg INFO "tnsnames.ora not found in $TnsAdminDir"

        if (-not $CreateTnsnamesScript -or -not (Test-Path $CreateTnsnamesScript)) {
            Write-Msg WARN "vault_create_tnsnames.ps1 not found at: $CreateTnsnamesScript"
            Write-Msg WARN "Creating empty tnsnames.ora placeholder."
            Set-Content -Path $tnsnamesFile -Value "# tnsnames.ora - add TNS entries here" -Encoding ASCII
            return $false
        }

        Write-Msg INFO "Creating tnsnames.ora using vault_create_tnsnames.ps1..."
        $scriptDir     = Split-Path $CreateTnsnamesScript -Parent
        $generatedFile = Join-Path (Join-Path $scriptDir "tnsnames_wallet") "tnsnames.ora.$EnvCode"

        try {
            & $CreateTnsnamesScript -Environment $EnvCode -Instance $InstanceName -Wallet -Filter "_${User}=" `
                -VaultUsername $VaultUser -VaultPassword $VaultPass -Failover:$Failover
        } catch {
            Write-Msg WARN "vault_create_tnsnames.ps1 failed: $($_.Exception.Message)"
            return $false
        }

        if (Test-Path $generatedFile) {
            Copy-Item $generatedFile $tnsnamesFile -Force
            Write-Msg OK "✓ tnsnames.ora created with entries for '$User'"
            return $true
        } else {
            Write-Msg WARN "Generated tnsnames.ora not found at: $generatedFile"
            return $false
        }
    }

    return $true
}

# Ensures that $Alias exists in tnsnames.ora.
# If the alias is missing, runs vault_create_tnsnames.ps1 and appends the generated entries.
# Equivalent to ensureTnsAlias() in oracleWalletToolkit.sh.
# Returns $true if alias exists or was added, $false on failure (non-fatal).
function Invoke-EnsureTnsAlias {
    param(
        [string]$TnsAdminDir,
        [string]$EnvCode,
        [string]$InstanceName,
        [string]$User,
        [string]$Alias,
        [string]$VaultUser,
        [string]$VaultPass,
        [string]$CreateTnsnamesScript,
        [switch]$Failover
    )

    $tnsnamesFile = Join-Path $TnsAdminDir 'tnsnames.ora'

    if (-not (Test-Path $tnsnamesFile)) {
        Write-Msg WARN "tnsnames.ora not found in $TnsAdminDir"
        return $false
    }

    # Alias already present — nothing to do
    if (Select-String -Path $tnsnamesFile -Pattern "^\s*$([regex]::Escape($Alias))\s*=" -Quiet) {
        Write-Msg OK "✓ Alias '$Alias' already exists in tnsnames.ora"
        return $true
    }

    Write-Msg INFO "Alias '$Alias' not found in tnsnames.ora, adding it..."

    if (-not $CreateTnsnamesScript -or -not (Test-Path $CreateTnsnamesScript)) {
        Write-Msg WARN "vault_create_tnsnames.ps1 not found at: $CreateTnsnamesScript"
        return $false
    }

    $scriptDir     = Split-Path $CreateTnsnamesScript -Parent
    $generatedFile = Join-Path (Join-Path $scriptDir "tnsnames_wallet") "tnsnames.ora.$EnvCode"

    try {
        & $CreateTnsnamesScript -Environment $EnvCode -Instance $InstanceName -Wallet -Filter "_${User}=" `
            -VaultUsername $VaultUser -VaultPassword $VaultPass -Failover:$Failover
    } catch {
        Write-Msg WARN "vault_create_tnsnames.ps1 failed: $($_.Exception.Message)"
        return $false
    }

    if (-not (Test-Path $generatedFile)) {
        Write-Msg WARN "Generated tnsnames.ora not found at: $generatedFile"
        return $false
    }

    $newEntries = @(Get-Content $generatedFile | Where-Object { $_ -notmatch '^#' -and $_.Trim() -ne '' })
    if ($newEntries.Count -gt 0) {
        Add-Content -Path $tnsnamesFile -Value ""
        Add-Content -Path $tnsnamesFile -Value "# Added by oracleWalletToolkit.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        $newEntries | Add-Content -Path $tnsnamesFile
        Write-Msg OK "✓ Alias(es) for '$User' added to tnsnames.ora"
        return $true
    }

    Write-Msg WARN "No entries generated for '$User'"
    return $false
}

# Invoke mkstore feeding stdin directly as raw bytes via System.Diagnostics.Process.
# This bypasses both PowerShell's string pipeline (adds CRLF) and cmd.exe's text-mode file
# redirect (unreliable through nested .bat layers). We connect a raw binary pipe directly
# to the process stdin handle, which Java inherits through the cmd.exe -> mkstore.bat chain.
function Invoke-MkstoreWithStdin {
    param(
        [string]$MkstorePath,
        [string]$StdinText,
        [string[]]$MkArgs
    )
    # Build cmd line: "mkstore.bat" arg1 arg2 ...
    $argParts = @("`"$($MkstorePath.Replace('"', '""'))`"") + ($MkArgs | ForEach-Object {
        if ($_ -match '\s') { "`"$_`"" } else { $_ }
    })
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName          = 'cmd.exe'
    $psi.Arguments         = '/v:off /c ' + ($argParts -join ' ')
    $psi.WorkingDirectory  = (Get-Location).Path   # inherit PowerShell cwd so relative paths resolve
    $psi.UseShellExecute   = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow    = $true

    $proc = [System.Diagnostics.Process]::Start($psi)

    # Write passwords as raw ASCII bytes with CRLF line endings.
    # mkstore on Windows uses a reader that requires \r\n as line terminator;
    # sending LF-only causes it to read all remaining bytes as the password (wrong password error).
    # Split into lines and re-join with CRLF — this preserves intentional trailing empty lines
    # (e.g. when sending an empty string for the wallet password because mkstore 11g on Windows
    # ignores stdin during -create and sets an empty wallet password).
    $lines = $StdinText.Replace("`r`n", "`n").Replace("`r", "`n") -split "`n"
    $normalized = ($lines | ForEach-Object { "$_`r`n" }) -join ""
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($normalized)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.BaseStream.Flush()
    $proc.StandardInput.Close()

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    return (($stdout + "`n" + $stderr).Trim() -split "`r?`n")
}

# Check mkstore output for error indicators.
# mkstore.bat always returns exit -1 on Windows (Oracle bug), so exit code cannot be trusted.
# Errors are detected via Java exception class names or explicit error keywords in output.
function Test-MkstoreError {
    param([string[]]$Output)
    foreach ($line in $Output) {
        if ($line -match 'Exception|^Error|^ERROR|oracle\.security\.pki\.|PKI-|non valida|invalid password|invalid wallet|Unable to save') { return $true }
    }
    return $false
}

# Cleanup function
function Invoke-Cleanup {
    if (Test-Path $TempCredFile) {
        Remove-Item -Path $TempCredFile -Force -ErrorAction SilentlyContinue
    }
}

# Finds a helper script by name, mirroring the bash 'find /products/software/sysadm -name ... | head -1' pattern.
# Search order:
#   1. The given path (resolved relative to PS cwd) — used when an explicit path was passed.
#   2. Recursively under the OS sysadm root: C:\products\software\sysadm (Windows) or /products/software/sysadm (Linux/Mac).
# Returns the full path when found; returns the original resolved path as fallback (for informative error messages).
function Find-SysadmFile {
    param([string]$Name, [string]$GivenPath)

    # 1. Explicit path given — resolve relative to cwd; if it exists, use it directly
    if ($GivenPath) {
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($GivenPath)
        if (Test-Path $resolved) { return $resolved }
    }

    # 2. Search recursively from the directory where this script lives ($PSScriptRoot).
    #    All three scripts (oracleWalletToolkit.ps1, vault_lib.ps1, vault_create_tnsnames.ps1)
    #    are expected to reside in the same folder (or a sub-folder of it).
    if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) {
        $found = Get-ChildItem -Path $PSScriptRoot -Filter $Name -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            Write-Msg INFO "Found $Name at: $($found.FullName)"
            return $found.FullName
        }
    }

    # Not found — return original path so error messages are informative
    return if ($GivenPath) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($GivenPath) } else { $Name }
}

# Sets hardened ACL on the TNS_ADMIN directory (Windows only):
#   - Inheritance disabled (no inherited ACEs)
#   - BUILTIN\Administrators : FullControl  — This folder, subfolders and files
#   - NT AUTHORITY\SYSTEM    : FullControl  — This folder, subfolders and files
#   - BUILTIN\Users          : Modify       — This folder, subfolders and files
function Set-TnsAdminPermissions {
    param([string]$Path)
    if ($env:OS -ne 'Windows_NT') { return }

    $acl = Get-Acl -Path $Path

    # Disable inheritance; do NOT copy existing inherited rules
    $acl.SetAccessRuleProtection($true, $false)

    # Remove any explicit rules that may already be present
    @($acl.Access) | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }

    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $prop    = [System.Security.AccessControl.PropagationFlags]::None
    $allow   = [System.Security.AccessControl.AccessControlType]::Allow

    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        'BUILTIN\Administrators', 'FullControl', $inherit, $prop, $allow))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        'NT AUTHORITY\SYSTEM',    'FullControl', $inherit, $prop, $allow))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        'BUILTIN\Users',          'Modify',      $inherit, $prop, $allow))

    Set-Acl -Path $Path -AclObject $acl
    Write-Msg INFO "ACL set on: $Path (Administrators:FullControl, SYSTEM:FullControl, Users:Modify — inheritance disabled)"
}

# Register cleanup on exit
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Invoke-Cleanup }

# Initialize colors (mirrors setColor after arg parsing in .sh)
Set-OutputColors

# Initialize log file if specified (mirrors .sh behaviour)
if ($LogFile) {
    $null = New-Item -Path $LogFile -ItemType File -Force
    Write-Msg INFO "Log file initialized: $LogFile"
}

try {
    # ---- Parameter validation ----
    if (-not $TnsAdmin)     { throw "Parameter -TnsAdmin is required" }
    if (-not $MasterWallet) { throw "Parameter -MasterWallet is required" }

    # Resolve TnsAdmin to absolute path using PowerShell's working directory.
    # [IO.Path]::GetFullPath() uses .NET's Environment.CurrentDirectory which PowerShell
    # sets to the user home, not the PS cwd. GetUnresolvedProviderPathFromPSPath uses Get-Location.
    $TnsAdmin = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TnsAdmin)

    # Resolve helper scripts dynamically (mirrors bash 'find /products/software/sysadm -name ...' pattern).
    $VaultLibPath             = Find-SysadmFile -Name 'vault_lib.ps1'              -GivenPath $VaultLibPath
    $VaultCreateTnsnamesPath  = Find-SysadmFile -Name 'vault_create_tnsnames.ps1'  -GivenPath $VaultCreateTnsnamesPath

    # Standalone wallet creation mode: -CreateWallet without -DbUser
    $standaloneCreate = $CreateWallet -and (-not $DbUser)

    # Wallet-only modes: only need -TnsAdmin and -MasterWallet (no Vault/DbUser required)
    $walletOnlyMode = $ListWallet -or $TestWallet -or $AutoLoginLocal -or $DeleteCredential

    if (-not $standaloneCreate -and -not $walletOnlyMode) {
        # Full configure mode: validate all required params
        $validEnvs = @("svi", "int", "tst", "pre", "prd", "amm")
        if (-not $DbUser)         { throw "Parameter -DbUser is required" }
        if (-not $OracleInstance) { throw "Parameter -OracleInstance is required" }
        if (-not $Environment)    { throw "Parameter -Environment is required" }
        if ($validEnvs -notcontains $Environment) { throw "Invalid -Environment '$Environment'. Must be one of: $($validEnvs -join ', ')" }
        if (-not $DbAlias)        { throw "Parameter -DbAlias is required" }
        if (-not $VaultUsername)  { throw "Parameter -VaultUsername is required" }
        if (-not $VaultPassword)  { throw "Parameter -VaultPassword is required" }
    }

    # Display dry-run mode if enabled
    if ($DryRun) {
        Write-Host ""
        Write-Msg DRY "======================================="
        Write-Msg DRY "DRY-RUN MODE ENABLED - No changes will be made"
        Write-Msg DRY "======================================="
        Write-Host ""
    }

    # ---- Standalone wallet creation mode ----
    if ($standaloneCreate) {
        Write-Msg INFO "======================================="
        Write-Msg INFO "Standalone Wallet Creation"
        Write-Msg INFO "TnsAdmin: $TnsAdmin"
        Write-Msg INFO "======================================="

        Test-OracleCommands -BinPath $OracleBinPath
        $mkstoreCmd = (Get-Command 'mkstore').Source

        # Check if wallet already exists
        if ((Test-Path (Join-Path $TnsAdmin 'cwallet.sso')) -or (Test-Path (Join-Path $TnsAdmin 'ewallet.p12'))) {
            Write-Msg WARN "Wallet already exists in: $TnsAdmin"
            Write-Msg OK "✓ No action needed - wallet is already present"
            exit 0
        }

        if ($DryRun) {
            Write-Msg DRY "Would create wallet at: $TnsAdmin"
            Write-Msg DRY "  Command: orapki wallet create -wallet $TnsAdmin -pwd <password> -auto_login_local"
            Write-Msg DRY "  Would set ACL: Administrators:FullControl, SYSTEM:FullControl, Users:Modify (inheritance disabled)"
        }
        else {
            if (-not (Test-Path $TnsAdmin)) {
                New-Item -ItemType Directory -Path $TnsAdmin -Force | Out-Null
                Write-Msg INFO "Created directory: $TnsAdmin"
                Set-TnsAdminPermissions -Path $TnsAdmin
            }
            # Create wallet with auto-login-local: mkstore creates both ewallet.p12 and cwallet.sso.
            # With cwallet.sso present, subsequent mkstore operations (createCredential etc.) open the
            # wallet automatically without prompting for wallet password — avoids Oracle 11g stdin bug.
            $mkCreateOut = Invoke-MkstoreWithStdin -MkstorePath $mkstoreCmd `
                -StdinText "$MasterWallet`n$MasterWallet" `
                -MkArgs @('-wrl', $TnsAdmin, '-create', '-auto_login_local')
            Write-Msg INFO "mkstore create output: $($mkCreateOut -join ' | ')"
            if (Test-MkstoreError $mkCreateOut) {
                throw "mkstore wallet create failed: $($mkCreateOut -join "`n")"
            }
            if (-not (Test-Path (Join-Path $TnsAdmin 'ewallet.p12'))) {
                throw "mkstore wallet create succeeded but ewallet.p12 not found in: $TnsAdmin"
            }
            Write-Msg OK "✓ Wallet created (ewallet.p12$(if (Test-Path (Join-Path $TnsAdmin 'cwallet.sso')) { ' + cwallet.sso' } else { '' })) at: $TnsAdmin"

            # Create sqlnet.ora if missing
            $sqlnetFile = Join-Path $TnsAdmin 'sqlnet.ora'
            if (-not (Test-Path $sqlnetFile)) {
                $sqlnetContent = @"
# sqlnet.ora Network Configuration File:
# Application User connection using Secure External Password Store

NAMES.DIRECTORY_PATH= (TNSNAMES)

WALLET_LOCATION =
  (SOURCE =
    (METHOD = FILE)
    (METHOD_DATA =
      (DIRECTORY = $TnsAdmin)
    )
   )

SQLNET.WALLET_OVERRIDE = TRUE
SSL_CLIENT_AUTHENTICATION = FALSE
SSL_VERSION = 0
"@
                Set-Content -Path $sqlnetFile -Value $sqlnetContent -Encoding ASCII
                Write-Msg OK "✓ sqlnet.ora created"
            }

            # Create empty tnsnames.ora if missing
            $tnsnamesFile = Join-Path $TnsAdmin 'tnsnames.ora'
            if (-not (Test-Path $tnsnamesFile)) {
                Set-Content -Path $tnsnamesFile -Value "# tnsnames.ora - add TNS entries here" -Encoding ASCII
                Write-Msg OK "✓ tnsnames.ora created (empty placeholder)"
            }
        }

        Write-Msg INFO "======================================="
        exit 0
    }

    # ---- Fix permissions mode ----
    if ($FixPermissions) {
        if (-not $TnsAdmin) { throw "Parameter -TnsAdmin is required for -FixPermissions" }
        Write-Msg INFO "======================================="
        Write-Msg INFO "Fix Permissions on TnsAdmin"
        Write-Msg INFO "Path: $TnsAdmin"
        Write-Msg INFO "======================================="

        if (-not (Test-Path $TnsAdmin)) { throw "TnsAdmin directory not found: $TnsAdmin" }

        if ($env:OS -ne 'Windows_NT') {
            Write-Msg WARN "-FixPermissions is a Windows-only operation — skipping"
            exit 0
        }

        if ($DryRun) {
            Write-Msg DRY "Would reset ACL on: $TnsAdmin (folder + all contents)"
            Write-Msg DRY "  Administrators: FullControl"
            Write-Msg DRY "  SYSTEM:         FullControl"
            Write-Msg DRY "  Users:          Modify"
            Write-Msg DRY "  Inheritance:    disabled (explicit rules only)"
        } else {
            # Fix the directory itself
            Set-TnsAdminPermissions -Path $TnsAdmin

            # Fix every file and subdirectory explicitly (they don't inherit because
            # inheritance is disabled on the parent — e.g. .lck files created by sqlplus)
            $inherit = [System.Security.AccessControl.InheritanceFlags]::None
            $prop    = [System.Security.AccessControl.PropagationFlags]::None
            $allow   = [System.Security.AccessControl.AccessControlType]::Allow
            $rules   = @(
                [System.Security.AccessControl.FileSystemAccessRule]::new('BUILTIN\Administrators', 'FullControl', $inherit, $prop, $allow),
                [System.Security.AccessControl.FileSystemAccessRule]::new('NT AUTHORITY\SYSTEM',    'FullControl', $inherit, $prop, $allow),
                [System.Security.AccessControl.FileSystemAccessRule]::new('BUILTIN\Users',          'Modify',      $inherit, $prop, $allow)
            )
            Get-ChildItem -Path $TnsAdmin -Recurse -Force | ForEach-Object {
                $acl = Get-Acl -Path $_.FullName
                $acl.SetAccessRuleProtection($true, $false)
                @($acl.Access) | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
                $rules | ForEach-Object { $acl.AddAccessRule($_) }
                Set-Acl -Path $_.FullName -AclObject $acl
            }
            Write-Msg OK "✓ Permissions reset on: $TnsAdmin (folder + $((Get-ChildItem $TnsAdmin -Recurse -Force).Count) item(s))"
        }
        Write-Msg INFO "======================================="
        exit 0
    }

    # ---- List wallet mode ----
    if ($ListWallet) {
        Write-Msg INFO "======================================="
        Write-Msg INFO "Wallet Credentials List"
        Write-Msg INFO "Wallet Location: $TnsAdmin"
        Write-Msg INFO "======================================="

        Test-OracleCommands -BinPath $OracleBinPath
        $mkstorePath = (Get-Command 'mkstore').Source

        if (-not (Test-Path $TnsAdmin)) { throw "TNS_ADMIN directory not found: $TnsAdmin" }
        if (-not (Test-Path (Join-Path $TnsAdmin 'cwallet.sso')) -and -not (Test-Path (Join-Path $TnsAdmin 'ewallet.p12'))) {
            throw "Oracle wallet not found in: $TnsAdmin (expected cwallet.sso or ewallet.p12)"
        }

        if ($DryRun) {
            Write-Msg DRY "Would list credentials from wallet at: $TnsAdmin"
            Write-Msg DRY "Command: mkstore -wrl $TnsAdmin -listCredential"
        }
        else {
            $env:TNS_ADMIN = $TnsAdmin
            $output = Invoke-MkstoreWithStdin -MkstorePath $mkstorePath -StdinText $MasterWallet -MkArgs @('-wrl', $TnsAdmin, '-listCredential')
            if (Test-MkstoreError $output) { throw "mkstore listCredential failed:`n$($output -join "`n")" }
            Write-Host ($output -join "`n")
        }
        Write-Msg INFO "======================================="
        exit 0
    }

    # ---- Delete credential mode ----
    if ($DeleteCredential) {
        if (-not $DbAlias) { throw "Parameter -DbAlias is required for -DeleteCredential" }

        Write-Msg INFO "======================================="
        Write-Msg INFO "Delete Wallet Credential"
        Write-Msg INFO "Wallet Location: $TnsAdmin"
        Write-Msg INFO "DB Alias:        $DbAlias"
        Write-Msg INFO "======================================="

        Test-OracleCommands -BinPath $OracleBinPath
        $mkstorePath = (Get-Command 'mkstore').Source

        if (-not (Test-Path $TnsAdmin)) { throw "TNS_ADMIN directory not found: $TnsAdmin" }
        if (-not (Test-Path (Join-Path $TnsAdmin 'cwallet.sso')) -and -not (Test-Path (Join-Path $TnsAdmin 'ewallet.p12'))) {
            throw "Oracle wallet not found in: $TnsAdmin (expected cwallet.sso or ewallet.p12)"
        }

        if ($DryRun) {
            Write-Msg DRY "Would delete credential '$DbAlias' from wallet at: $TnsAdmin"
            Write-Msg DRY "Command: mkstore -wrl $TnsAdmin -deleteCredential $DbAlias"
        }
        else {
            $env:TNS_ADMIN = $TnsAdmin
            $output = Invoke-MkstoreWithStdin -MkstorePath $mkstorePath -StdinText $MasterWallet `
                -MkArgs @('-wrl', $TnsAdmin, '-deleteCredential', $DbAlias)
            if (Test-MkstoreError $output) {
                throw "mkstore deleteCredential failed:`n$($output -join "`n")"
            }
            Write-Msg OK "✓ Credential '$DbAlias' deleted successfully"
        }
        Write-Msg INFO "======================================="
        exit 0
    }

    # ---- Auto-login-local conversion mode ----
    if ($AutoLoginLocal) {
        Write-Msg INFO "======================================="
        Write-Msg INFO "Converting Wallet to Auto-Login-Local"
        Write-Msg INFO "Wallet Location: $TnsAdmin"
        Write-Msg INFO "======================================="

        Test-OracleCommands -BinPath $OracleBinPath
        $orapkiPath = (Get-Command 'orapki').Source

        if (-not (Test-Path (Join-Path $TnsAdmin 'ewallet.p12'))) {
            throw "ewallet.p12 not found in: $TnsAdmin - password-protected wallet is required for conversion"
        }

        if ($DryRun) {
            Write-Msg DRY "Would convert wallet to auto-login-local at: $TnsAdmin"
            Write-Msg DRY "Command: orapki wallet create -wallet $TnsAdmin -pwd <password> -auto_login_local"
        }
        else {
            $output = & $orapkiPath wallet create -wallet $TnsAdmin -pwd $MasterWallet -auto_login_local 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "orapki wallet create failed (exit $LASTEXITCODE): $output"
            }
            Write-Msg OK "✓ Wallet converted to auto-login-local successfully"
        }
        Write-Msg INFO "======================================="
        exit 0
    }

    # ---- Test wallet mode ----
    if ($TestWallet) {
        Write-Msg INFO "======================================="
        Write-Msg INFO "Testing Wallet Credentials"
        Write-Msg INFO "Wallet Location: $TnsAdmin"
        Write-Msg INFO "======================================="

        Test-OracleCommands -BinPath $OracleBinPath
        $mkstorePath = (Get-Command 'mkstore').Source
        $sqlplusPath = (Get-Command 'sqlplus').Source

        if (-not (Test-Path $TnsAdmin)) { throw "TNS_ADMIN directory not found: $TnsAdmin" }
        if (-not (Test-Path (Join-Path $TnsAdmin 'cwallet.sso')) -and -not (Test-Path (Join-Path $TnsAdmin 'ewallet.p12'))) {
            throw "Oracle wallet not found in: $TnsAdmin (expected cwallet.sso or ewallet.p12)"
        }
        if (-not (Test-Path (Join-Path $TnsAdmin 'tnsnames.ora'))) {
            throw "tnsnames.ora not found in: $TnsAdmin - required for connection testing"
        }

        if ($DryRun) {
            Write-Msg DRY "Would test all credentials from wallet at: $TnsAdmin"
        }
        else {
            $env:TNS_ADMIN = $TnsAdmin
            $listOutput = Invoke-MkstoreWithStdin -MkstorePath $mkstorePath -StdinText $MasterWallet -MkArgs @('-wrl', $TnsAdmin, '-listCredential')
            if (Test-MkstoreError $listOutput) { throw "mkstore listCredential failed:`n$($listOutput -join "`n")" }

            $aliases = @()
            foreach ($line in $listOutput) {
                if ($line -match 'oracle\.security\.client\.connect_string\d+=([A-Za-z0-9_]+)') {
                    $aliases += $Matches[1]
                } elseif ($line -match '^\d+:\s+([A-Za-z0-9_]+)') {
                    $aliases += $Matches[1]
                }
            }

            if ($aliases.Count -eq 0) {
                Write-Msg WARN "No credentials found in wallet"
                Write-Msg INFO "Raw output:"
                Write-Host ($listOutput -join "`n")
            }
            else {
                Write-Msg INFO "Found $($aliases.Count) credential(s) in wallet"

                $successAliases = @()
                $failedAliases  = @()
                $i = 0

                foreach ($alias in $aliases) {
                    $i++
                    Write-Msg INFO "[$i/$($aliases.Count)] Testing connection: $alias"

                    $sqlTest = "connect /@$alias`nselect 'TEST_OK', sysdate from dual;`nexit;"
                    $testResult = $sqlTest | & $sqlplusPath -S /nolog 2>&1

                    if ($testResult -match "TEST_OK") {
                        Write-Msg OK "  ✓ Connection test successful"
                        $successAliases += $alias
                    } else {
                        $errorLine = ($testResult | Select-String -Pattern 'error|ORA-' -CaseSensitive:$false | Select-Object -First 1)
                        Write-Msg ERROR "  ✗ Connection test failed"
                        if ($errorLine) { Write-Msg ERROR "    Error: $errorLine" }
                        $failedAliases += $alias
                    }
                }

                Write-Msg INFO "======================================="
                Write-Msg INFO "Test Summary Report"
                Write-Msg INFO "======================================="
                Write-Msg INFO "Total credentials tested: $($aliases.Count)"
                Write-Msg OK   "Successful connections:   $($successAliases.Count)"
                if ($failedAliases.Count -gt 0) {
                    Write-Msg ERROR "Failed connections:       $($failedAliases.Count)"
                } else {
                    Write-Msg OK "Failed connections:       0"
                }
                Write-Msg INFO "======================================="

                if ($failedAliases.Count -gt 0) {
                    Write-Msg ERROR "Failed aliases:"
                    foreach ($fa in $failedAliases) { Write-Msg ERROR "  ✗ $fa" }
                    exit 1
                }
            }
        }
        Write-Msg INFO "======================================="
        exit 0
    }

    # Display header
    Write-Msg INFO "======================================="
    Write-Msg INFO "Oracle Wallet Configuration"
    Write-Msg INFO "======================================="
    Write-Msg INFO "Database User:   $DbUser"
    Write-Msg INFO "Oracle Instance: $OracleInstance"
    Write-Msg INFO "Environment:     $Environment"
    Write-Msg INFO "DB Alias:        $DbAlias"
    Write-Msg INFO "TNS_ADMIN:       $TnsAdmin"
    Write-Msg INFO "======================================="
    
    # Normalize environment to lowercase
    $Environment = $Environment.ToLower()
    $OracleInstanceLower = $OracleInstance.ToLower()
    
    # Check if vault_lib.ps1 exists
    if (-not (Test-Path $VaultLibPath)) {
        throw "vault_lib.ps1 not found at: $VaultLibPath"
    }
    
    # Import vault library (dot-sourcing: vault_lib.ps1 is a script, not a module)
    Write-Msg INFO "Loading Vault library..."
    . $VaultLibPath
    Write-Msg OK "✓ Vault library loaded"
    
    # Check Oracle commands in PATH (like checkOracleCommands in .sh)
    Test-OracleCommands -BinPath $OracleBinPath
    $mkstorePath = (Get-Command 'mkstore').Source
    $sqlplusPath = (Get-Command 'sqlplus').Source
    $orapkiPath  = (Get-Command 'orapki').Source
    Write-Msg OK "✓ Oracle tools verified"

    # Check wallet existence; create if -CreateWallet is set (mirrors .sh full configure mode)
    $walletExists = (Test-Path (Join-Path $TnsAdmin 'cwallet.sso')) -or (Test-Path (Join-Path $TnsAdmin 'ewallet.p12'))

    if (-not $walletExists) {
        if (-not $CreateWallet) {
            throw "Oracle wallet not found in TNS_ADMIN directory: $TnsAdmin`nExpected cwallet.sso or ewallet.p12. Use -CreateWallet to create a new wallet."
        }

        Write-Msg INFO "Wallet not found. Creating new wallet..."
        if ($DryRun) {
            Write-Msg DRY "Would create wallet at: $TnsAdmin"
            Write-Msg DRY "  Command: orapki wallet create -wallet $TnsAdmin -pwd <password> -auto_login_local"
            Write-Msg DRY "  Would set ACL: Administrators:FullControl, SYSTEM:FullControl, Users:Modify (inheritance disabled)"
        }
        else {
            if (-not (Test-Path $TnsAdmin)) {
                New-Item -ItemType Directory -Path $TnsAdmin -Force | Out-Null
                Write-Msg INFO "Created directory: $TnsAdmin"
                Set-TnsAdminPermissions -Path $TnsAdmin
            }
            # Create wallet with auto-login-local: mkstore creates both ewallet.p12 and cwallet.sso.
            # With cwallet.sso present, subsequent mkstore operations (createCredential etc.) open the
            # wallet automatically without prompting for wallet password — avoids Oracle 11g stdin bug.
            $mkCreateOut = Invoke-MkstoreWithStdin -MkstorePath $mkstorePath `
                -StdinText "$MasterWallet`n$MasterWallet" `
                -MkArgs @('-wrl', $TnsAdmin, '-create', '-auto_login_local')
            Write-Msg INFO "mkstore create output: $($mkCreateOut -join ' | ')"
            if (Test-MkstoreError $mkCreateOut) {
                throw "mkstore wallet create failed: $($mkCreateOut -join "`n")"
            }
            if (-not (Test-Path (Join-Path $TnsAdmin 'ewallet.p12'))) {
                throw "mkstore wallet create succeeded but ewallet.p12 not found in: $TnsAdmin"
            }
            Write-Msg OK "✓ Wallet created (ewallet.p12$(if (Test-Path (Join-Path $TnsAdmin 'cwallet.sso')) { ' + cwallet.sso' } else { '' })) at: $TnsAdmin"
        }

        # Create sqlnet.ora if missing (static content, same as .sh ensureTnsFiles)
        $sqlnetFile = Join-Path $TnsAdmin 'sqlnet.ora'
        if (-not (Test-Path $sqlnetFile)) {
            if ($DryRun) {
                Write-Msg DRY "Would create sqlnet.ora in: $TnsAdmin"
            }
            else {
                $sqlnetContent = @"
# sqlnet.ora Network Configuration File:
# Application User connection using Secure External Password Store

NAMES.DIRECTORY_PATH= (TNSNAMES)

WALLET_LOCATION =
  (SOURCE =
    (METHOD = FILE)
    (METHOD_DATA =
      (DIRECTORY = $TnsAdmin)
    )
   )

SQLNET.WALLET_OVERRIDE = TRUE
SSL_CLIENT_AUTHENTICATION = FALSE
SSL_VERSION = 0
"@
                Set-Content -Path $sqlnetFile -Value $sqlnetContent -Encoding ASCII
                Write-Msg OK "✓ sqlnet.ora created"
            }
        }

        # Ensure tnsnames.ora exists — generate it from vault_create_tnsnames.ps1 if possible
        if ($DryRun) {
            Write-Msg DRY "Would create tnsnames.ora using vault_create_tnsnames.ps1"
        } else {
            $null = Invoke-EnsureTnsFiles -TnsAdminDir $TnsAdmin -EnvCode $Environment -InstanceName $OracleInstanceLower `
                -User $DbUser -VaultUser $VaultUsername -VaultPass $VaultPassword `
                -CreateTnsnamesScript $VaultCreateTnsnamesPath -Failover:$Failover
        }
    }

    # Validate TNS_ADMIN path (must exist by now)
    if (-not (Test-Path $TnsAdmin)) {
        throw "TNS_ADMIN directory not found at: $TnsAdmin"
    }

    # Set TNS_ADMIN env var for sqlplus
    $env:TNS_ADMIN = $TnsAdmin
    
    # Construct vault path
    $PathSecret = "$Environment/paas/oracle/$OracleInstanceLower"
    Write-Msg INFO "Vault path: $PathSecret/$DbUser"
    
    # Check Vault status
    if ($DryRun) {
        Write-Msg DRY "Would check Vault status"
        Write-Msg DRY "Assuming Vault is unsealed"
    }
    else {
        Write-Msg INFO "Checking Vault status..."
        $isSealed = Test-VaultSealed
        
        if ($isSealed) {
            Write-Msg WARN "Vault is sealed. Please unseal it manually."
            Write-Msg WARN "This script does not handle vault unsealing for security reasons."
            throw "Vault is sealed"
        }
        
        Write-Msg OK "✓ Vault is unsealed"
    }
    
    # Login to Vault
    if ($DryRun) {
        Write-Msg DRY "Would login to Vault with user: $VaultUsername"
        $token = "dry-run-token-12345"
    }
    else {
        Write-Msg INFO "Logging into Vault..."
        $token = Invoke-VaultLogin -Username $VaultUsername -Password $VaultPassword
        
        if (-not $token) {
            throw "Failed to login to Vault"
        }
        
        Write-Msg OK "✓ Vault login successful"
    }
    
    # Retrieve credentials from Vault
    if ($DryRun) {
        Write-Msg DRY "Would retrieve credentials from Vault"
        Write-Msg DRY "  Path: $PathSecret/$DbUser"
        Write-Msg DRY "  Key: $DbUser"
        $dbPassword = "DryRunPassword1234567890ab"
        Set-Content -Path $TempCredFile -Value $dbPassword -NoNewline
    }
    else {
        Write-Msg INFO "Retrieving credentials from Vault..."
        $secretData = Get-VaultSecret -SecretEngine $SecretEngine -PathSecret "$PathSecret/$DbUser" -Token $token
        
        if (-not $secretData -or -not $secretData.$DbUser) {
            throw "Failed to retrieve credentials from Vault. Path: $PathSecret/$DbUser"
        }
        
        $dbPassword = $secretData.$DbUser
        
        # Save password to temp file
        Set-Content -Path $TempCredFile -Value $dbPassword -NoNewline
        Write-Msg OK "✓ Credentials retrieved successfully"
    }
    
    # Configure wallet credentials
    if ($DryRun) {
        Write-Msg DRY "Would configure wallet credentials"
        Write-Msg DRY "  Wallet path: $TnsAdmin"
        Write-Msg DRY "  DB alias: $DbAlias"
        Write-Msg DRY "  DB user: $DbUser"
        Write-Msg DRY "  Command: mkstore.exe -wrl $TnsAdmin -createCredential $DbAlias $DbUser"
        Write-Msg DRY "  If exists: mkstore.exe -wrl $TnsAdmin -modifyCredential $DbAlias $DbUser"
    }
    else {
        Write-Msg INFO "Configuring wallet credentials..."
        
        # Prepare input for mkstore: db password twice (create/confirm), then wallet password.
        # Wallet was created with -auto_login_local: mkstore -create reads stdin correctly and sets
        # the wallet password to $MasterWallet. Subsequent operations (createCredential etc.) on
        # Oracle 11g still prompt for wallet password even with cwallet.sso present.
        $mkstoreInput = "$dbPassword`n$dbPassword`n$MasterWallet"

        # Try to create credential first; if output contains "already exists" → update instead
        $createOut = Invoke-MkstoreWithStdin -MkstorePath $mkstorePath -StdinText $mkstoreInput -MkArgs @('-wrl', $TnsAdmin, '-createCredential', $DbAlias, $DbUser)
        $createOutText = $createOut -join "`n"
        Write-Msg INFO "mkstore createCredential output: $($createOut -join ' | ')"
        if (-not (Test-MkstoreError $createOut)) {
            Write-Msg OK "✓ Credential created successfully"
        }
        elseif ($createOutText -match 'already exist|duplicate|modifyCredential') {
            Write-Msg WARN "Credential already exists, updating..."
            $modifyOut = Invoke-MkstoreWithStdin -MkstorePath $mkstorePath -StdinText $mkstoreInput -MkArgs @('-wrl', $TnsAdmin, '-modifyCredential', $DbAlias, $DbUser)
            Write-Msg INFO "mkstore modifyCredential output: $($modifyOut -join ' | ')"
            if (Test-MkstoreError $modifyOut) {
                throw "Failed to configure wallet credential:`n$($modifyOut -join "`n")"
            }
            Write-Msg OK "✓ Credential updated successfully"
        }
        else {
            throw "Failed to create wallet credential:`n$createOutText"
        }
    }
    
    # Ensure TNS alias exists in tnsnames.ora (mirrors ensureTnsAlias / ensureTnsFiles in .sh)
    Write-Msg INFO "Checking TNS configuration..."
    $tnsnamesFile = Join-Path $TnsAdmin 'tnsnames.ora'
    if ($DryRun) {
        Write-Msg DRY "Would ensure alias '$DbAlias' exists in tnsnames.ora"
    } elseif (Test-Path $tnsnamesFile) {
        if (-not (Invoke-EnsureTnsAlias -TnsAdminDir $TnsAdmin -EnvCode $Environment -InstanceName $OracleInstanceLower `
                -User $DbUser -Alias $DbAlias -VaultUser $VaultUsername -VaultPass $VaultPassword `
                -CreateTnsnamesScript $VaultCreateTnsnamesPath -Failover:$Failover)) {
            Write-Msg WARN "Could not ensure TNS alias exists - connection test may fail"
        }
    } else {
        Write-Msg WARN "tnsnames.ora not found in $TnsAdmin - attempting to create..."
        if (-not (Invoke-EnsureTnsFiles -TnsAdminDir $TnsAdmin -EnvCode $Environment -InstanceName $OracleInstanceLower `
                -User $DbUser -VaultUser $VaultUsername -VaultPass $VaultPassword `
                -CreateTnsnamesScript $VaultCreateTnsnamesPath -Failover:$Failover)) {
            Write-Msg WARN "Failed to create TNS configuration files - connection test may fail"
        }
    }

    # Test connection
    $tnsnamesFile = Join-Path $TnsAdmin 'tnsnames.ora'
    if (-not (Test-Path $tnsnamesFile)) {
        Write-Msg WARN "tnsnames.ora not found in $TnsAdmin - skipping connection test"
    } elseif (-not (Select-String -Path $tnsnamesFile -Pattern "^\s*$([regex]::Escape($DbAlias))\s*=" -Quiet)) {
        Write-Msg WARN "Alias '$DbAlias' not found in tnsnames.ora - skipping connection test"
        Write-Msg WARN "Please add a '$DbAlias' entry manually to $tnsnamesFile"
    } elseif ($DryRun) {
        Write-Msg DRY "Would test connection"
        Write-Msg DRY "  Command: sqlplus /@$DbAlias"
        Write-Msg DRY "  SQL: select 'TEST_OK', sysdate from dual"
    }
    else {
        Write-Msg INFO "Testing connection..."
        
        $sqlTest = @"
connect /@$DbAlias
select 'TEST_OK', sysdate from dual;
exit;
"@
        
        $testResult = $sqlTest | & $sqlplusPath -S /nolog 2>&1
        
        if ($testResult -match "TEST_OK") {
            Write-Msg OK "✓ Connection test: OK"
        }
        else {
            Write-Msg ERROR "Connection test failed"
            Write-Msg ERROR "Output: $testResult"
            throw "Connection test failed"
        }

        # Re-apply ACL after connection test: sqlplus may create .lck and other files
        # in TnsAdmin that won't inherit permissions because inheritance is disabled on the directory.
        Set-TnsAdminPermissions -Path $TnsAdmin
    }
    
    # Update metadata in Vault
    $hostname = $env:COMPUTERNAME
    $metadata = "host=$hostname,environment=$Environment,instance=$OracleInstance,alias=$DbAlias,tns_admin=$TnsAdmin"
    
    if ($DryRun) {
        Write-Msg DRY "Would update metadata in Vault"
        Write-Msg DRY "  Metadata: $metadata"
        Write-Msg DRY "  Method: oracleWalletToolkit"
    }
    else {
        Write-Msg INFO "Updating metadata in Vault..."
        
        $metadataResult = Set-VaultSecretMetadata -SecretEngine $SecretEngine -PathSecret "$PathSecret/$DbUser" `
            -Message $metadata -Token $token -ServiceMethod "oracleWalletToolkit"
        
        if ($metadataResult) {
            Write-Msg OK "✓ Metadata updated in Vault"
        }
        else {
            Write-Msg WARN "Failed to update metadata in Vault (non-critical)"
        }
    }
    
    # Summary
    Write-Host ""
    if ($DryRun) {
        Write-Msg DRY "======================================="
        Write-Msg DRY "DRY-RUN Summary"
        Write-Msg DRY "======================================="
        Write-Msg DRY "The following operations would be performed:"
        Write-Msg DRY "  Database User:   $DbUser"
        Write-Msg DRY "  Oracle Instance: $OracleInstance"
        Write-Msg DRY "  Environment:     $Environment"
        Write-Msg DRY "  DB Alias:        $DbAlias"
        Write-Msg DRY "  Vault Path:      $PathSecret/$DbUser"
        Write-Msg DRY "  TNS_ADMIN:       $TnsAdmin"
        Write-Msg DRY "Operations:"
        Write-Msg DRY "  1. Check Vault status (unsealed)"
        Write-Msg DRY "  2. Login to Vault"
        Write-Msg DRY "  3. Retrieve credentials from Vault"
        Write-Msg DRY "  4. Configure wallet with mkstore"
        Write-Msg DRY "  5. Test connection with sqlplus"
        Write-Msg DRY "  6. Update metadata in Vault"
        Write-Msg DRY "======================================="
        Write-Msg WARN "No actual changes were made"
        Write-Msg DRY "======================================="
    }
    else {
        Write-Msg OK "======================================="
        Write-Msg OK "Wallet configuration completed!"
        Write-Msg OK "  Database User:   $DbUser"
        Write-Msg OK "  Oracle Instance: $OracleInstance"
        Write-Msg OK "  Environment:     $Environment"
        Write-Msg OK "  DB Alias:        $DbAlias"
        Write-Msg OK "  Vault Path:      $PathSecret/$DbUser"
        Write-Msg OK "  TNS_ADMIN:       $TnsAdmin"
        Write-Msg OK "======================================="
    }
    
    exit 0
}
catch {
    Write-Host ""
    Write-Msg ERROR "======================================="
    Write-Msg ERROR "$($_.Exception.Message)"
    Write-Msg ERROR "======================================="
    
    # Cleanup on error
    Invoke-Cleanup
    
    exit 1
}
finally {
    # Final cleanup
    Invoke-Cleanup
}
