# ==============================================================================
# HashiCorp Vault Library for PowerShell
# ==============================================================================
# Description: PowerShell library for interacting with HashiCorp Vault API
# Version: 2.0
# Date: 2026-02-24
# ==============================================================================

# Vault Configuration
$Global:URL_VAULT = ""

# Color codes for output
$Global:VaultColors = @{
    Error   = "Red"
    Info    = "Green"
    Warning = "Yellow"
    Purple  = "Magenta"
}

<#
.SYNOPSIS
    Checks if a command/executable exists in the system

.PARAMETER CommandName
    Name of the command to check

.OUTPUTS
    Returns $true if command exists, $false otherwise
#>
function Test-Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )
    
    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    return $null -ne $command
}

<#
.SYNOPSIS
    Login to HashiCorp Vault and retrieve user token

.PARAMETER Username
    Vault username

.PARAMETER Password
    Vault password

.OUTPUTS
    Returns the authentication token or $null on failure
#>
function Invoke-VaultLogin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Username,
        
        [Parameter(Mandatory = $true)]
        [string]$Password
    )
    
    if ([string]::IsNullOrEmpty($Username) -or [string]::IsNullOrEmpty($Password)) {
        Write-Host "[ERROR] - Invoke-VaultLogin: missing parameters Username, Password" -ForegroundColor $VaultColors.Error
        return $null
    }
    
    $endpoint = "v1/auth/userpass/login/$Username"
    $uri = "$Global:URL_VAULT/$endpoint"
    
    $body = @{
        password = $Password
    } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop
        
        if ($response.auth.client_token) {
            return $response.auth.client_token
        }
        else {
            Write-Host "[ERROR] - Failed to retrieve token" -ForegroundColor $VaultColors.Error
            return $null
        }
    }
    catch {
        Write-Host "[ERROR] - $($_.Exception.Message)" -ForegroundColor $VaultColors.Error
        return $null
    }
}

<#
.SYNOPSIS
    Check if Vault is sealed

.OUTPUTS
    Returns $true if Vault is sealed, $false if unsealed
#>
function Test-VaultSealed {
    $endpoint = "v1/sys/seal-status"
    $uri = "$Global:URL_VAULT/$endpoint"
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
        
        return $response.sealed
    }
    catch {
        Write-Host "[ERROR] - $($_.Exception.Message)" -ForegroundColor $VaultColors.Error
        return $true
    }
}

<#
.SYNOPSIS
    Unseal the Vault

.PARAMETER Key
    Unseal key

.OUTPUTS
    Returns response object or $null on failure
#>
function Invoke-VaultUnseal {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )
    
    if ([string]::IsNullOrEmpty($Key)) {
        Write-Host "[ERROR] - Invoke-VaultUnseal: missing parameter Key" -ForegroundColor $VaultColors.Error
        return $null
    }
    
    $endpoint = "v1/sys/unseal"
    $uri = "$Global:URL_VAULT/$endpoint"
    
    $body = @{
        key = $Key
    } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop
        return $response
    }
    catch {
        Write-Host "[ERROR] - $($_.Exception.Message)" -ForegroundColor $VaultColors.Error
        return $null
    }
}

<#
.SYNOPSIS
    Create or update a secret in Vault

.PARAMETER Key
    Secret key name

.PARAMETER Value
    Secret value

.PARAMETER SecretEngine
    Secret engine path (e.g., "database")

.PARAMETER PathSecret
    Secret path within the engine

.PARAMETER Token
    Vault authentication token

.PARAMETER NoOverride
    If $true, skip creation if credential already exists

.OUTPUTS
    Returns $true on success, $false on failure
#>
function New-VaultSecret {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        
        [Parameter(Mandatory = $true)]
        [string]$Value,
        
        [Parameter(Mandatory = $true)]
        [string]$SecretEngine,
        
        [Parameter(Mandatory = $true)]
        [string]$PathSecret,
        
        [Parameter(Mandatory = $true)]
        [string]$Token,
        
        [Parameter(Mandatory = $false)]
        [bool]$NoOverride = $false
    )
    
    # Normalize paths
    $SecretEngine = $SecretEngine.TrimStart('/').Insert(0, '/')
    $PathSecret = $PathSecret.TrimStart('/').Insert(0, '/')
    
    $endpoint = "v1$SecretEngine/data$PathSecret"
    $uri = "$Global:URL_VAULT/$endpoint"
    
    $headers = @{
        "X-VAULT-TOKEN"  = $Token
        "Content-Type"   = "application/merge-patch+json"
    }
    
    # Check if credential exists
    $existingData = Get-VaultSecret -SecretEngine $SecretEngine -PathSecret $PathSecret -Token $Token
    
    if ($existingData -and $NoOverride) {
        Write-Host "Credential $PathSecret skipped due to nooverride option!" -ForegroundColor $VaultColors.Warning
        return $true
    }
    
    # Prepare body
    if ($existingData) {
        # Append to existing data
        $existingData.$Key = $Value
        $body = @{
            data = $existingData
        } | ConvertTo-Json -Depth 10
    }
    else {
        # Create new data
        $body = @{
            data = @{
                $Key = $Value
            }
        } | ConvertTo-Json -Depth 10
    }
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host "[ERROR] - $($_.Exception.Message)" -ForegroundColor $VaultColors.Error
        return $false
    }
}

<#
.SYNOPSIS
    Read a secret from Vault

.PARAMETER SecretEngine
    Secret engine path

.PARAMETER PathSecret
    Secret path within the engine

.PARAMETER Token
    Vault authentication token

.PARAMETER Version
    Optional version number

.OUTPUTS
    Returns the secret data object or $null if not found
#>
function Get-VaultSecret {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SecretEngine,
        
        [Parameter(Mandatory = $true)]
        [string]$PathSecret,
        
        [Parameter(Mandatory = $true)]
        [string]$Token,
        
        [Parameter(Mandatory = $false)]
        [string]$Version = ""
    )
    
    # Normalize paths
    $SecretEngine = $SecretEngine.TrimStart('/').Insert(0, '/')
    $PathSecret = $PathSecret.TrimStart('/').Insert(0, '/')
    
    $endpoint = "v1$SecretEngine/data$PathSecret"
    if ($Version) {
        $endpoint += "?version=$Version"
    }
    
    $uri = "$Global:URL_VAULT/$endpoint"
    
    $headers = @{
        "X-VAULT-TOKEN" = $Token
    }
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
        
        if ($response.data.data) {
            return $response.data.data
        }
        else {
            return $null
        }
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            Write-Host "[ERROR] - No records found" -ForegroundColor $VaultColors.Error
            return $null
        }
        else {
            Write-Host "[ERROR] - $($_.Exception.Message)" -ForegroundColor $VaultColors.Error
            return $null
        }
    }
}

<#
.SYNOPSIS
    List secrets at a given path

.PARAMETER SecretEngine
    Secret engine path

.PARAMETER PathSecret
    Secret path to list

.PARAMETER Token
    Vault authentication token

.OUTPUTS
    Returns array of secret names or empty array
#>
function Get-VaultSecretList {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SecretEngine,
        
        [Parameter(Mandatory = $true)]
        [string]$PathSecret,
        
        [Parameter(Mandatory = $true)]
        [string]$Token
    )
    
    # Normalize paths
    $SecretEngine = $SecretEngine.TrimStart('/').Insert(0, '/')
    $PathSecret = $PathSecret.TrimStart('/').Insert(0, '/')
    
    $endpoint = "v1$SecretEngine/metadata$PathSecret"
    # KV v2 listing requires ?list=true (bash equivalent uses the LIST HTTP verb,
    # which Invoke-RestMethod does not support natively).
    $uri = "$Global:URL_VAULT/$endpoint`?list=true"
    
    $headers = @{
        "X-VAULT-TOKEN" = $Token
    }
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
        
        if ($response.data.keys) {
            return $response.data.keys
        }
        else {
            return @()
        }
    }
    catch {
        Write-Host "[ERROR] - $($_.Exception.Message)" -ForegroundColor $VaultColors.Error
        return @()
    }
}

<#
.SYNOPSIS
    Create or update custom metadata for a secret

.PARAMETER SecretEngine
    Secret engine path

.PARAMETER PathSecret
    Secret path

.PARAMETER Message
    Metadata message/information

.PARAMETER Token
    Vault authentication token

.PARAMETER ServiceMethod
    Optional service method identifier

.OUTPUTS
    Returns $true on success, $false on failure
#>
function Set-VaultSecretMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SecretEngine,
        
        [Parameter(Mandatory = $true)]
        [string]$PathSecret,
        
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $true)]
        [string]$Token,
        
        [Parameter(Mandatory = $false)]
        [string]$ServiceMethod = ""
    )
    
    # Normalize paths
    $SecretEngine = $SecretEngine.TrimStart('/').Insert(0, '/')
    $PathSecret = $PathSecret.TrimStart('/').Insert(0, '/')
    
    $endpoint = "v1$SecretEngine/metadata$PathSecret"
    $uri = "$Global:URL_VAULT/$endpoint"
    
    $currentDate = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    if ($ServiceMethod) {
        $currentDate += "#$ServiceMethod"
    }
    
    $headers = @{
        "X-VAULT-TOKEN"  = $Token
        "Content-Type"   = "application/merge-patch+json"
    }
    
    $customMetadata = @{
        $currentDate = $Message
    }
    
    $body = @{
        custom_metadata = $customMetadata
    } | ConvertTo-Json -Depth 10
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Patch -Headers $headers -Body $body -ErrorAction Stop
        return $true
    }
    catch {
        # Status 204 (No Content) is also a success for PATCH operations
        if ($_.Exception.Response.StatusCode -eq 204) {
            return $true
        }
        Write-Host "[ERROR] - $($_.Exception.Message)" -ForegroundColor $VaultColors.Error
        return $false
    }
}

<#
.SYNOPSIS
    Get custom metadata for a secret

.PARAMETER SecretEngine
    Secret engine path

.PARAMETER PathSecret
    Secret path

.PARAMETER Token
    Vault authentication token

.OUTPUTS
    Returns metadata object or $null on failure
#>
function Get-VaultSecretMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SecretEngine,
        
        [Parameter(Mandatory = $true)]
        [string]$PathSecret,
        
        [Parameter(Mandatory = $true)]
        [string]$Token
    )
    
    # Normalize paths
    $SecretEngine = $SecretEngine.TrimStart('/').Insert(0, '/')
    $PathSecret = $PathSecret.TrimStart('/').Insert(0, '/')
    
    $endpoint = "v1$SecretEngine/metadata$PathSecret"
    $uri = "$Global:URL_VAULT/$endpoint"
    
    $headers = @{
        "X-VAULT-TOKEN" = $Token
    }
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
        return $response
    }
    catch {
        Write-Host "[ERROR] - $($_.Exception.Message)" -ForegroundColor $VaultColors.Error
        return $null
    }
}

<#
.SYNOPSIS
    Get Vault health status

.OUTPUTS
    Returns health status object or $null on failure
#>
function Get-VaultHealth {
    $endpoint = "v1/sys/health"
    $uri = "$Global:URL_VAULT/$endpoint"
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
        return $response
    }
    catch {
        Write-Host "[ERROR] - $($_.Exception.Message)" -ForegroundColor $VaultColors.Error
        return $null
    }
}

# Export all functions (only when loaded as a module, not when dot-sourced)
if ($MyInvocation.MyCommand.ScriptBlock.Module) {
    Export-ModuleMember -Function @(
        'Test-Command',
        'Invoke-VaultLogin',
        'Test-VaultSealed',
        'Invoke-VaultUnseal',
        'New-VaultSecret',
        'Get-VaultSecret',
        'Get-VaultSecretList',
        'Set-VaultSecretMetadata',
        'Get-VaultSecretMetadata',
        'Get-VaultHealth'
    )
}
