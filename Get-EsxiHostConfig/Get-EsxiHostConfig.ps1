<#
.SYNOPSIS
    Extracts the full configuration of an ESXi host by connecting to a vCenter and saves
    it to a readable text report.

.DESCRIPTION
    The script connects to the specified vCenter Server (credentials requested
    interactively and securely), locates the given ESXi host and collects all available
    configuration information into a single report: hardware, network, storage, services,
    security, advanced settings, hosted virtual machines, etc.

.PARAMETER vCenter
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER EsxiHost
    Name (FQDN as shown in vCenter) of the ESXi host to extract the configuration from.

.PARAMETER OutputFolder
    Folder where the report will be saved. Default: current folder.

.EXAMPLE
    .\Get-EsxiHostConfig.ps1 -vCenter vcenter01.domain.local -EsxiHost esxi01.domain.local

.EXAMPLE
    .\Get-EsxiHostConfig.ps1 -vCenter 10.0.0.10 -EsxiHost esxi02.domain.local -OutputFolder C:\Report
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$vCenter,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$EsxiHost,

    [Parameter(Mandatory = $false)]
    [string]$OutputFolder = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------------
# Helper functions for writing the report
# ----------------------------------------------------------------------------------

$script:ReportLines = New-Object System.Collections.Generic.List[string]

function Write-ReportHeader {
    param([string]$Title)
    $script:ReportLines.Add('')
    $script:ReportLines.Add('=' * 90)
    $script:ReportLines.Add(" $Title")
    $script:ReportLines.Add('=' * 90)
}

function Write-ReportSubHeader {
    param([string]$Title)
    $script:ReportLines.Add('')
    $script:ReportLines.Add("--- $Title ---")
}

function Write-ReportText {
    param([string]$Text)
    $script:ReportLines.Add($Text)
}

function Write-ReportObject {
    param($InputObject, [string]$FormatAs = 'List')

    if ($null -eq $InputObject -or ($InputObject -is [array] -and $InputObject.Count -eq 0)) {
        $script:ReportLines.Add('(no data available)')
        return
    }

    if ($FormatAs -eq 'Table') {
        $text = $InputObject | Format-Table -AutoSize -Wrap | Out-String -Width 200
        $script:ReportLines.Add($text.TrimEnd())
    }
    elseif ($FormatAs -eq 'KeyValue') {
        # Compact "Name : Value" format, one line per item: unlike Format-Table -AutoSize
        # it doesn't widen every row based on the longest value in the whole list, so it
        # stays readable even with hundreds of settings.
        foreach ($item in $InputObject) {
            $script:ReportLines.Add(("{0,-50} : {1}" -f $item.Name, $item.Value))
        }
    }
    else {
        $text = $InputObject | Format-List * | Out-String -Width 200
        $script:ReportLines.Add($text.TrimEnd())
    }
}

function Invoke-ReportSection {
    <#
        Runs a scriptblock that collects a section's data and writes it to the report.
        If the scriptblock fails, the error is noted in the report without interrupting
        the rest of the script.
    #>
    param(
        [string]$Title,
        [scriptblock]$Collector,
        [string]$FormatAs = 'List',
        [switch]$SubSection
    )

    if ($SubSection) {
        Write-ReportSubHeader -Title $Title
    }
    else {
        Write-ReportHeader -Title $Title
    }

    try {
        $data = & $Collector
        Write-ReportObject -InputObject $data -FormatAs $FormatAs
    }
    catch {
        Write-ReportText "ERROR while collecting this section: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------------
# PowerCLI module check / import
# ----------------------------------------------------------------------------------

Write-Host "Checking PowerCLI availability..." -ForegroundColor Cyan

# The check relies on the Connect-VIServer cmdlet rather than a fixed module name:
# PowerCLI can be packaged as VMware.PowerCLI or VCF.PowerCLI depending on the version,
# so checking only the module name would fail even when PowerCLI is actually installed.
if (-not (Get-Command -Name Connect-VIServer -ErrorAction SilentlyContinue)) {
    foreach ($candidate in 'VCF.PowerCLI', 'VMware.PowerCLI') {
        if (Get-Module -ListAvailable -Name $candidate -ErrorAction SilentlyContinue) {
            Import-Module $candidate -ErrorAction SilentlyContinue
            break
        }
    }
}

if (-not (Get-Command -Name Connect-VIServer -ErrorAction SilentlyContinue)) {
    Write-Host "PowerCLI does not appear to be installed (Connect-VIServer cmdlet not available)." -ForegroundColor Yellow
    Write-Host "Install it with: Install-Module -Name VMware.PowerCLI -Scope CurrentUser" -ForegroundColor Yellow
    throw "PowerCLI not found."
}

# Avoids confirmation prompts for untrusted certificates (common with self-signed vCenters)
# and disables CEIP participation without an interactive confirmation prompt.
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -Scope Session -Confirm:$false | Out-Null

# ----------------------------------------------------------------------------------
# Credentials and connection to vCenter
# ----------------------------------------------------------------------------------

Write-Host "Connecting to vCenter '$vCenter'..." -ForegroundColor Cyan
$cred = Get-Credential -Message "Credentials for connecting to $vCenter"

if (-not $cred) {
    throw "No credentials provided. Script aborted."
}

$viConnection = Connect-VIServer -Server $vCenter -Credential $cred -ErrorAction Stop
Write-Host "Connected to $($viConnection.Name) (version $($viConnection.Version) build $($viConnection.Build))" -ForegroundColor Green

try {
    # ------------------------------------------------------------------------------
    # Retrieve the ESXi host
    # ------------------------------------------------------------------------------

    Write-Host "Looking up ESXi host '$EsxiHost'..." -ForegroundColor Cyan
    $vmhost = Get-VMHost -Name $EsxiHost -ErrorAction Stop
    $hostView = $vmhost | Get-View

    Write-Host "Host found. Starting configuration collection..." -ForegroundColor Green

    Write-ReportText "ESXI HOST CONFIGURATION REPORT"
    Write-ReportText "ESXi Host     : $($vmhost.Name)"
    Write-ReportText "vCenter       : $vCenter"
    Write-ReportText "Collected on  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-ReportText "User          : $($cred.UserName)"

    # ------------------------------------------------------------------------------
    # 1. General information / hardware
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "GENERAL INFORMATION" -Collector {
        $vmhost | Select-Object Name, Parent, ConnectionState, PowerState,
            Version, Build, Manufacturer, Model,
            @{N = 'ProcessorType'; E = { $_.ProcessorType } },
            NumCpu, CpuTotalMhz, CpuUsageMhz,
            @{N = 'MemoryTotalGB'; E = { [math]::Round($_.MemoryTotalGB, 2) } },
            @{N = 'MemoryUsageGB'; E = { [math]::Round($_.MemoryUsageGB, 2) } },
            @{N = 'Uptime (days)'; E = { [math]::Round(((Get-Date) - $_.ExtensionData.Runtime.BootTime).TotalDays, 1) } },
            @{N = 'BootTime'; E = { $_.ExtensionData.Runtime.BootTime } }
    }

    Invoke-ReportSection -Title "BIOS / Detailed hardware" -SubSection -Collector {
        [PSCustomObject]@{
            BiosVersion      = $hostView.Hardware.BiosInfo.BiosVersion
            BiosReleaseDate  = $hostView.Hardware.BiosInfo.ReleaseDate
            Vendor           = $hostView.Hardware.SystemInfo.Vendor
            SystemModel      = $hostView.Hardware.SystemInfo.Model
            UUID             = $hostView.Hardware.SystemInfo.Uuid
            CpuModel         = $hostView.Hardware.CpuPkg[0].Description
            NumCpuPkgs       = $hostView.Hardware.CpuInfo.NumCpuPackages
            NumCpuCores      = $hostView.Hardware.CpuInfo.NumCpuCores
            NumCpuThreads    = $hostView.Hardware.CpuInfo.NumCpuThreads
            MemorySizeBytes  = $hostView.Hardware.MemorySize
        }
    }

    Invoke-ReportSection -Title "Maintenance / Lockdown / Fault Tolerance status" -SubSection -Collector {
        [PSCustomObject]@{
            InMaintenanceMode = $vmhost.ExtensionData.Runtime.InMaintenanceMode
            LockdownMode      = $hostView.Config.LockdownMode
            StandaloneMode    = $vmhost.ExtensionData.Summary.Config.VmotionEnabled
        }
    }

    # ------------------------------------------------------------------------------
    # 2. Licensing
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "LICENSING" -Collector {
        $vmhost | Select-Object Name,
            @{N = 'LicenseKey'; E = { $_.LicenseKey } }
    }

    # ------------------------------------------------------------------------------
    # 3. Date / Time / NTP
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "DATE, TIME AND NTP" -Collector {
        $tz = $hostView.Config.DateTimeInfo.TimeZone
        $dateTimeSystem = Get-View -Id $vmhost.ExtensionData.ConfigManager.DateTimeSystem -ErrorAction SilentlyContinue
        $currentTime = if ($dateTimeSystem) { $dateTimeSystem.QueryDateTime() } else { $null }

        [PSCustomObject]@{
            TimeZone     = "$($tz.Name) - $($tz.Description) (GMT offset: $($tz.GmtOffset)s)"
            CurrentTime  = $currentTime
            NtpServers   = (($vmhost | Get-VMHostNtpServer -ErrorAction SilentlyContinue) -join ', ')
        }
    }

    Invoke-ReportSection -Title "NTP service (status)" -SubSection -Collector {
        $vmhost | Get-VMHostService -ErrorAction SilentlyContinue |
            Where-Object { $_.Key -eq 'ntpd' } |
            Select-Object Label, Key, Running, Policy
    }

    # ------------------------------------------------------------------------------
    # 4. Network
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "NETWORK" -Collector { "See the subsections below for details." }

    Invoke-ReportSection -Title "Host network configuration (DNS/Gateway/Hostname)" -SubSection -Collector {
        $netInfo = $vmhost | Get-VMHostNetwork -ErrorAction SilentlyContinue
        $netInfo | Select-Object HostName, DomainName, DnsAddress, SearchDomain,
            VMKernelGateway, ConsoleGateway
    }

    Invoke-ReportSection -Title "Standard Virtual Switches" -SubSection -FormatAs Table -Collector {
        $vmhost | Get-VirtualSwitch -Standard -ErrorAction SilentlyContinue |
            Select-Object Name, NumPorts, Mtu, @{N = 'NIC'; E = { ($_.Nic -join ', ') } }
    }

    Invoke-ReportSection -Title "Distributed Virtual Switches (attached)" -SubSection -FormatAs Table -Collector {
        $vmhost | Get-VDSwitch -ErrorAction SilentlyContinue |
            Select-Object Name, NumUplinkPorts, Mtu, Version
    }

    Invoke-ReportSection -Title "Port Groups" -SubSection -FormatAs Table -Collector {
        $vmhost | Get-VirtualPortGroup -ErrorAction SilentlyContinue |
            Select-Object Name, VirtualSwitch, VLanId
    }

    Invoke-ReportSection -Title "Physical network adapters (vmnic)" -SubSection -FormatAs Table -Collector {
        $vmhost | Get-VMHostNetworkAdapter -Physical -ErrorAction SilentlyContinue |
            Select-Object Name, Mac, BitRatePerSec, FullDuplex, Status
    }

    Invoke-ReportSection -Title "VMkernel adapters (vmk)" -SubSection -FormatAs Table -Collector {
        $vmhost | Get-VMHostNetworkAdapter -VMKernel -ErrorAction SilentlyContinue |
            Select-Object Name, PortGroupName, IP, SubnetMask, Mac, Mtu,
                VMotionEnabled, ManagementTrafficEnabled, FaultToleranceLoggingEnabled, VsanTrafficEnabled
    }

    Invoke-ReportSection -Title "Static routing" -SubSection -FormatAs Table -Collector {
        $hostView.Config.Network.RouteTableInfo.IpRoute |
            Select-Object @{N = 'Network'; E = { $_.Network } },
                @{N = 'PrefixLength'; E = { $_.PrefixLength } },
                @{N = 'Gateway'; E = { $_.Gateway.IpAddress } }
    }

    # ------------------------------------------------------------------------------
    # 5. Storage
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "STORAGE" -Collector { "See the subsections below for details." }

    Invoke-ReportSection -Title "Datastores" -SubSection -FormatAs Table -Collector {
        $vmhost | Get-Datastore -ErrorAction SilentlyContinue |
            Select-Object Name, Type,
                @{N = 'CapacityGB'; E = { [math]::Round($_.CapacityGB, 1) } },
                @{N = 'FreeSpaceGB'; E = { [math]::Round($_.FreeSpaceGB, 1) } }
    }

    Invoke-ReportSection -Title "Storage adapters (HBA)" -SubSection -FormatAs Table -Collector {
        $vmhost | Get-VMHostHba -ErrorAction SilentlyContinue |
            Select-Object Device, Type, Model, Status, Driver
    }

    Invoke-ReportSection -Title "iSCSI Software Adapter" -SubSection -Collector {
        $vmhost | Get-VMHostHba -Type IScsi -ErrorAction SilentlyContinue |
            Select-Object Device, IScsiName, ChapType
    }

    Invoke-ReportSection -Title "LUN / SCSI Devices" -SubSection -FormatAs Table -Collector {
        $vmhost | Get-ScsiLun -ErrorAction SilentlyContinue |
            Select-Object CanonicalName, LunType, Vendor, Model,
                @{N = 'CapacityGB'; E = { [math]::Round($_.CapacityGB, 1) } },
                MultipathPolicy, IsSsd
    }

    Invoke-ReportSection -Title "Multipathing (first 20 paths as a sample)" -SubSection -FormatAs Table -Collector {
        $vmhost | Get-ScsiLun -ErrorAction SilentlyContinue |
            Get-ScsiLunPath -ErrorAction SilentlyContinue |
            Select-Object -First 20 SanID, State, Preferred
    }

    # ------------------------------------------------------------------------------
    # 6. Services and Security
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "SERVICES" -FormatAs Table -Collector {
        $vmhost | Get-VMHostService -ErrorAction SilentlyContinue |
            Select-Object Label, Key, Running, Policy
    }

    Invoke-ReportSection -Title "FIREWALL (enabled rules)" -FormatAs Table -Collector {
        $vmhost | Get-VMHostFirewallException -ErrorAction SilentlyContinue |
            Where-Object { $_.Enabled } |
            Select-Object Name, Enabled, Protocols,
                @{N = 'PortRange'; E = { $_.Port } }
    }

    Invoke-ReportSection -Title "Local account security profile" -SubSection -FormatAs Table -Collector {
        $vmhost | Get-VMHostAccount -ErrorAction SilentlyContinue |
            Select-Object Id, Description
    }

    Invoke-ReportSection -Title "Syslog" -SubSection -Collector {
        $vmhost | Get-AdvancedSetting -Name 'Syslog.global.logHost' -ErrorAction SilentlyContinue |
            Select-Object Name, Value
    }

    # ------------------------------------------------------------------------------
    # 7. Power management
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "POWER MANAGEMENT" -Collector {
        [PSCustomObject]@{
            CurrentPolicy   = $hostView.Hardware.CpuPowerManagementInfo.CurrentPolicy
            AvailablePolicy = ($hostView.Hardware.CpuPowerManagementInfo.HardwareSupport)
        }
    }

    # ------------------------------------------------------------------------------
    # 8. Installed VIBs (software packages)
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "INSTALLED VIBS (software packages)" -FormatAs Table -Collector {
        $esxcli = Get-EsxCli -VMHost $vmhost -V2 -ErrorAction Stop
        $esxcli.software.vib.list.Invoke() |
            Select-Object Name, Version, Vendor, AcceptanceLevel, InstallDate, Status |
            Sort-Object Name
    }

    # ------------------------------------------------------------------------------
    # 9. Host certificate
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "HOST CERTIFICATE (HTTPS/vpxd)" -Collector {
        $certBytes = $hostView.Config.Certificate

        if (-not $certBytes) {
            [PSCustomObject]@{ Info = 'Certificate not exposed by the API for this host/permissions.' }
        }
        else {
            $x509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([byte[]]$certBytes)
            [PSCustomObject]@{
                Subject    = $x509.Subject
                Issuer     = $x509.Issuer
                NotBefore  = $x509.NotBefore
                NotAfter   = $x509.NotAfter
                Thumbprint = $x509.Thumbprint
            }
        }
    }

    # ------------------------------------------------------------------------------
    # 10. Advanced settings (full dump)
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "ADVANCED SETTINGS (Advanced System Settings) - full dump" -FormatAs KeyValue -Collector {
        $vmhost | Get-AdvancedSetting -ErrorAction SilentlyContinue |
            Select-Object Name, Value |
            Sort-Object Name
    }

    # ------------------------------------------------------------------------------
    # Writing the report file
    # ------------------------------------------------------------------------------

    if (-not (Test-Path -Path $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $safeHostName = ($EsxiHost -replace '[\\/:*?"<>|]', '_')
    $reportFile = Join-Path -Path $OutputFolder -ChildPath "EsxiConfig_${safeHostName}_${timestamp}.txt"

    $script:ReportLines | Set-Content -Path $reportFile -Encoding UTF8

    Write-Host ""
    Write-Host "Report completed: $reportFile" -ForegroundColor Green
}
finally {
    Disconnect-VIServer -Server $viConnection -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Disconnected from vCenter." -ForegroundColor Cyan
}
