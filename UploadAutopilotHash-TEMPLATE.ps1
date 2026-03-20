<#
Purpose:
  Upload hardware hash from OOBE, wait for Autopilot import completion,
  wait for Autopilot device creation, wait for profile assignment,
  then reset back into OOBE so Windows Autopilot self-deploying can start.

Notes:
  - Designed for use from a PPKG during OOBE
  - Uses Graph v1.0 for import/device discovery
  - Uses Graph beta only for profile assignment confirmation
  - Uses Sysprep /oobe /reboot (not /generalize) to re-enter OOBE
#>

$ErrorActionPreference = "Stop"

# ---------------------------
# CONFIG
# ---------------------------
$TenantId      = "YOUR_TENANT_ID"
$ClientId      = "YOUR_CLIENT_ID"
$ClientSecret  = "YOUR_CLIENT_SECRET_VALUE"


$ImportPollSeconds            = 30
$DevicePollSeconds            = 30
$AssignmentPollSeconds        = 30
$MaxImportWaitMinutes         = 20
$MaxDeviceWaitMinutes         = 20
$MaxAssignmentWaitMinutes     = 45
$PostAssignmentBufferSeconds  = 120

# ---------------------------
# LOGGING
# ---------------------------
$LogDir  = "C:\Temp\Autopilot"
$LogFile = Join-Path $LogDir "Autopilotlog.log"

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

Start-Transcript -Path $LogFile -Append | Out-Null

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] $Message"
}

# ---------------------------
# HELPERS
# ---------------------------
function Ensure-MsalModule {
    if (-not (Get-Module -ListAvailable -Name MSAL.ps)) {
        Write-Log "MSAL.ps not found. Installing prerequisites."
        Install-PackageProvider -Name NuGet -Force | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Install-Module -Name MSAL.ps -Force -Scope AllUsers
    }

    Import-Module MSAL.ps -Force
}

function Get-GraphErrorText {
    param(
        [Parameter(Mandatory = $true)]
        $ErrorRecord
    )

    try {
        if ($ErrorRecord.Exception.Response) {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $body = $reader.ReadToEnd()
                if ($body) {
                    return $body
                }
            }
        }
    }
    catch {
    }

    return $ErrorRecord.Exception.Message
}

function Get-GraphAccessToken {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ClientSecret
    )

    $secureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force

    $authParams = @{
        TenantId     = $TenantId
        ClientId     = $ClientId
        ClientSecret = $secureSecret
    }

    $token = Get-MsalToken @authParams
    return $token.AccessToken
}

function Invoke-GraphRequest {
    param(
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][ValidateSet("GET","POST","PATCH","DELETE")][string]$Method,
        [Parameter(Mandatory = $false)]$Body = $null
    )

    $headers = @{
        "Authorization" = "Bearer $AccessToken"
        "Accept"        = "application/json"
        "Content-Type"  = "application/json"
    }

    try {
        if ($null -ne $Body) {
            $jsonBody = $Body | ConvertTo-Json -Depth 10
            return Invoke-RestMethod -Headers $headers -Uri $Uri -Method $Method -Body $jsonBody
        }
        else {
            return Invoke-RestMethod -Headers $headers -Uri $Uri -Method $Method
        }
    }
    catch {
        $detail = Get-GraphErrorText -ErrorRecord $_
        Write-Log "Graph request failed: $Method $Uri"
        Write-Log "Graph error detail: $detail"
        throw
    }
}

function Get-AutopilotHardwareInfo {
    $session = $null

    try {
        $session = New-CimSession

        $serial = (Get-CimInstance -CimSession $session -ClassName Win32_BIOS).SerialNumber

        $devDetail = Get-CimInstance `
            -CimSession $session `
            -Namespace "root/cimv2/mdm/dmmap" `
            -ClassName "MDM_DevDetail_Ext01" `
            -Filter "InstanceID='Ext' AND ParentID='./DevDetail'"

        if (-not $devDetail) {
            throw "MDM_DevDetail_Ext01 was not returned."
        }

        if (-not $devDetail.DeviceHardwareData) {
            throw "DeviceHardwareData was empty."
        }

        [PSCustomObject]@{
            SerialNumber       = $serial
            HardwareIdentifier = $devDetail.DeviceHardwareData
        }
    }
    finally {
        if ($session) {
            $session | Remove-CimSession
        }
    }
}

# ---------------------------
# MAIN
# ---------------------------
try {
    Write-Log "===== Autopilot import script started ====="

    Ensure-MsalModule

    try {
        Write-Log "Authenticating to Microsoft Graph"
        $AccessToken = Get-GraphAccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
        Write-Log "Successfully acquired Graph token"
    }
    catch {
        Write-Log "Authentication failed: $($_.Exception.Message)"
        throw
    }

    Write-Log "Collecting hardware information"
    $hw = Get-AutopilotHardwareInfo
    $Serial = $hw.SerialNumber
    $Hash   = $hw.HardwareIdentifier

    Write-Log "Serial Number: $Serial"

    # 1) Create imported Autopilot device record
    $importUri = "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities"

    $importBody = @{
        serialNumber       = $Serial
        hardwareIdentifier = $Hash
    }

    if (-not [string]::IsNullOrWhiteSpace($GroupTag)) {
        $importBody.groupTag = $GroupTag
        Write-Log "Using Group Tag: $GroupTag"
    }

    Write-Log "Uploading hardware hash to importedWindowsAutopilotDeviceIdentities"
    $importResponse = Invoke-GraphRequest -AccessToken $AccessToken -Uri $importUri -Method POST -Body $importBody

    if (-not $importResponse.id) {
        throw "Graph import response did not include an imported device ID."
    }

    $ImportedDeviceId = $importResponse.id
    Write-Log "Imported device record created. Imported ID: $ImportedDeviceId"

    # 2) Wait for import processing to finish
    $importElapsed = 0
    $importComplete = $false

    while ($importElapsed -lt ($MaxImportWaitMinutes * 60)) {
        Start-Sleep -Seconds $ImportPollSeconds
        $importElapsed += $ImportPollSeconds

        $importCheckUri = "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/$ImportedDeviceId"
        $importCheck = Invoke-GraphRequest -AccessToken $AccessToken -Uri $importCheckUri -Method GET

        $importState        = $importCheck.state
        $deviceImportStatus = $importState.deviceImportStatus
        $deviceErrorCode    = $importState.deviceErrorCode
        $deviceErrorName    = $importState.deviceErrorName

        Write-Log "Import status after $importElapsed sec: status='$deviceImportStatus' errorCode='$deviceErrorCode' errorName='$deviceErrorName'"

        if ($null -ne $deviceErrorCode -and [int]$deviceErrorCode -ne 0) {
            throw "Autopilot import failed. ErrorCode=$deviceErrorCode ErrorName=$deviceErrorName"
        }

        if ($deviceImportStatus -eq "complete") {
            $importComplete = $true
            break
        }
    }

    if (-not $importComplete) {
        throw "Timed out waiting for Autopilot import to complete."
    }

    Write-Log "Autopilot import completed successfully."

    # 3) Wait for actual windowsAutopilotDeviceIdentity to appear
    $deviceElapsed = 0
    $apDevice = $null

    while ($deviceElapsed -lt ($MaxDeviceWaitMinutes * 60)) {
        Start-Sleep -Seconds $DevicePollSeconds
        $deviceElapsed += $DevicePollSeconds

        $deviceUri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities"
        $deviceResult = Invoke-GraphRequest -AccessToken $AccessToken -Uri $deviceUri -Method GET

        $apDevice = $deviceResult.value | Where-Object { $_.serialNumber -eq $Serial } | Select-Object -First 1

        if ($apDevice) {
            Write-Log "Autopilot device object found after $deviceElapsed sec. Device ID: $($apDevice.id)"
            break
        }

        Write-Log "Autopilot device object not present yet after $deviceElapsed sec."
    }

    if (-not $apDevice) {
        throw "Timed out waiting for windowsAutopilotDeviceIdentity to appear."
    }

    # 4) Wait for deployment profile assignment using beta
    $assignmentElapsed = 0
    $profileAssigned = $false

    while ($assignmentElapsed -lt ($MaxAssignmentWaitMinutes * 60)) {
        Start-Sleep -Seconds $AssignmentPollSeconds
        $assignmentElapsed += $AssignmentPollSeconds

        $betaUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/$($apDevice.id)"
        $betaResult = Invoke-GraphRequest -AccessToken $AccessToken -Uri $betaUri -Method GET

        $assignmentStatus = $betaResult.deploymentProfileAssignmentStatus
        $assignedDateTime = $betaResult.deploymentProfileAssignedDateTime

        Write-Log "Assignment check after $assignmentElapsed sec: status='$assignmentStatus' assignedDateTime='$assignedDateTime'"

        if (
            ($assignmentStatus -and $assignmentStatus -match "assigned") -or
            (-not [string]::IsNullOrWhiteSpace([string]$assignedDateTime))
        ) {
            $profileAssigned = $true
            break
        }
    }

    if (-not $profileAssigned) {
        throw "Timed out waiting for deployment profile assignment."
    }

    Write-Log "Autopilot ready. Waiting $PostAssignmentBufferSeconds more seconds before resetting to OOBE."
    Start-Sleep -Seconds $PostAssignmentBufferSeconds

    # 5) Reset back into OOBE so Autopilot can evaluate on next boot
    $sysprepPath = "C:\Windows\System32\Sysprep\sysprep.exe"

    if (-not (Test-Path $sysprepPath)) {
        throw "Sysprep executable not found at $sysprepPath"
    }

    Write-Log "Launching Sysprep with /oobe /reboot to restart OOBE and trigger Autopilot."
    Stop-Transcript | Out-Null

    Start-Process -FilePath $sysprepPath -ArgumentList "/oobe /reboot" -Wait
    exit 0
}
catch {
    Write-Log "Fatal error: $($_.Exception.Message)"
    Stop-Transcript | Out-Null
    exit 1
}