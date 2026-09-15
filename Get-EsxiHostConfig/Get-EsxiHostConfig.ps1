<#
.SYNOPSIS
    Estrae la configurazione completa di un host ESXi collegandosi a un vCenter e la salva
    in un report testuale leggibile.

.DESCRIPTION
    Lo script si collega al vCenter Server specificato (credenziali richieste in modo
    interattivo e sicuro), individua l'host ESXi indicato e raccoglie in un unico report
    tutte le informazioni di configurazione disponibili: hardware, rete, storage, servizi,
    sicurezza, impostazioni avanzate, macchine virtuali ospitate, ecc.

.PARAMETER vCenter
    FQDN o indirizzo IP del vCenter Server a cui collegarsi.

.PARAMETER EsxiHost
    Nome (FQDN come mostrato in vCenter) dell'host ESXi di cui estrarre la configurazione.

.PARAMETER OutputFolder
    Cartella in cui salvare il report. Default: cartella corrente.

.EXAMPLE
    .\Get-EsxiHostConfig.ps1 -vCenter vcenter01.dominio.local -EsxiHost esxi01.dominio.local

.EXAMPLE
    .\Get-EsxiHostConfig.ps1 -vCenter 10.0.0.10 -EsxiHost esxi02.dominio.local -OutputFolder C:\Report
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
# Funzioni di supporto per la scrittura del report
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
        $script:ReportLines.Add('(nessun dato disponibile)')
        return
    }

    if ($FormatAs -eq 'Table') {
        $text = $InputObject | Format-Table -AutoSize -Wrap | Out-String -Width 200
        $script:ReportLines.Add($text.TrimEnd())
    }
    elseif ($FormatAs -eq 'KeyValue') {
        # Formato compatto "Nome : Valore", una riga per elemento: a differenza di
        # Format-Table -AutoSize non allarga tutte le righe in base al valore piu' lungo
        # dell'intero elenco, quindi resta leggibile anche con centinaia di impostazioni.
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
        Esegue uno scriptblock che raccoglie i dati di una sezione e li scrive nel report.
        Se lo scriptblock fallisce, l'errore viene annotato nel report senza interrompere
        l'esecuzione dello script.
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
        Write-ReportText "ERRORE durante la raccolta di questa sezione: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------------
# Verifica / caricamento modulo PowerCLI
# ----------------------------------------------------------------------------------

Write-Host "Verifica disponibilita' di PowerCLI..." -ForegroundColor Cyan

# Il controllo si basa sul cmdlet Connect-VIServer e non su un nome di modulo fisso:
# PowerCLI puo' essere pacchettizzato come VMware.PowerCLI o VCF.PowerCLI a seconda
# della versione, quindi un controllo sul solo nome del modulo fallirebbe anche quando
# PowerCLI e' effettivamente installato.
if (-not (Get-Command -Name Connect-VIServer -ErrorAction SilentlyContinue)) {
    foreach ($candidate in 'VCF.PowerCLI', 'VMware.PowerCLI') {
        if (Get-Module -ListAvailable -Name $candidate -ErrorAction SilentlyContinue) {
            Import-Module $candidate -ErrorAction SilentlyContinue
            break
        }
    }
}

if (-not (Get-Command -Name Connect-VIServer -ErrorAction SilentlyContinue)) {
    Write-Host "PowerCLI non risulta installato (cmdlet Connect-VIServer non disponibile)." -ForegroundColor Yellow
    Write-Host "Installalo con: Install-Module -Name VMware.PowerCLI -Scope CurrentUser" -ForegroundColor Yellow
    throw "PowerCLI mancante."
}

# Evita prompt di conferma per certificati non attendibili (comune con vCenter self-signed)
# e disabilita la partecipazione al CEIP senza chiedere conferma interattiva.
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -Scope Session -Confirm:$false | Out-Null

# ----------------------------------------------------------------------------------
# Credenziali e connessione al vCenter
# ----------------------------------------------------------------------------------

Write-Host "Connessione a vCenter '$vCenter'..." -ForegroundColor Cyan
$cred = Get-Credential -Message "Credenziali per la connessione a $vCenter"

if (-not $cred) {
    throw "Nessuna credenziale fornita. Script interrotto."
}

$viConnection = Connect-VIServer -Server $vCenter -Credential $cred -ErrorAction Stop
Write-Host "Connesso a $($viConnection.Name) (versione $($viConnection.Version) build $($viConnection.Build))" -ForegroundColor Green

try {
    # ------------------------------------------------------------------------------
    # Recupero dell'host ESXi
    # ------------------------------------------------------------------------------

    Write-Host "Ricerca host ESXi '$EsxiHost'..." -ForegroundColor Cyan
    $vmhost = Get-VMHost -Name $EsxiHost -ErrorAction Stop
    $hostView = $vmhost | Get-View

    Write-Host "Host trovato. Avvio raccolta configurazione..." -ForegroundColor Green

    Write-ReportText "REPORT DI CONFIGURAZIONE HOST ESXI"
    Write-ReportText "Host ESXi     : $($vmhost.Name)"
    Write-ReportText "vCenter       : $vCenter"
    Write-ReportText "Data raccolta : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-ReportText "Utente        : $($cred.UserName)"

    # ------------------------------------------------------------------------------
    # 1. Informazioni generali / hardware
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "INFORMAZIONI GENERALI" -Collector {
        $vmhost | Select-Object Name, Parent, ConnectionState, PowerState,
            Version, Build, Manufacturer, Model,
            @{N = 'ProcessorType'; E = { $_.ProcessorType } },
            NumCpu, CpuTotalMhz, CpuUsageMhz,
            @{N = 'MemoryTotalGB'; E = { [math]::Round($_.MemoryTotalGB, 2) } },
            @{N = 'MemoryUsageGB'; E = { [math]::Round($_.MemoryUsageGB, 2) } },
            @{N = 'Uptime (giorni)'; E = { [math]::Round(((Get-Date) - $_.ExtensionData.Runtime.BootTime).TotalDays, 1) } },
            @{N = 'BootTime'; E = { $_.ExtensionData.Runtime.BootTime } }
    }

    Invoke-ReportSection -Title "BIOS / Hardware dettagliato" -SubSection -Collector {
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

    Invoke-ReportSection -Title "Stato manutenzione / Lockdown / Fault Tolerance" -SubSection -Collector {
        [PSCustomObject]@{
            InMaintenanceMode = $vmhost.ExtensionData.Runtime.InMaintenanceMode
            LockdownMode      = $hostView.Config.LockdownMode
            StandaloneMode    = $vmhost.ExtensionData.Summary.Config.VmotionEnabled
        }
    }

    # ------------------------------------------------------------------------------
    # 2. Licenza
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "LICENSING" -Collector {
        $vmhost | Select-Object Name,
            @{N = 'LicenseKey'; E = { $_.LicenseKey } }
    }

    # ------------------------------------------------------------------------------
    # 3. Data / Ora / NTP
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "DATA, ORA E NTP" -Collector {
        $tz = $hostView.Config.DateTimeInfo.TimeZone
        $dateTimeSystem = Get-View -Id $vmhost.ExtensionData.ConfigManager.DateTimeSystem -ErrorAction SilentlyContinue
        $oraCorrente = if ($dateTimeSystem) { $dateTimeSystem.QueryDateTime() } else { $null }

        [PSCustomObject]@{
            TimeZone     = "$($tz.Name) - $($tz.Description) (offset GMT: $($tz.GmtOffset)s)"
            OraCorrente  = $oraCorrente
            NtpServers   = (($vmhost | Get-VMHostNtpServer -ErrorAction SilentlyContinue) -join ', ')
        }
    }

    Invoke-ReportSection -Title "Servizio NTP (stato)" -SubSection -Collector {
        $vmhost | Get-VMHostService -ErrorAction SilentlyContinue |
            Where-Object { $_.Key -eq 'ntpd' } |
            Select-Object Label, Key, Running, Policy
    }

    # ------------------------------------------------------------------------------
    # 4. Rete
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "RETE" -Collector { "Dettaglio nelle sottosezioni seguenti." }

    Invoke-ReportSection -Title "Configurazione di rete host (DNS/Gateway/Hostname)" -SubSection -Collector {
        $netInfo = $vmhost | Get-VMHostNetwork -ErrorAction SilentlyContinue
        $netInfo | Select-Object HostName, DomainName, DnsAddress, SearchDomain,
            VMKernelGateway, ConsoleGateway
    }

    Invoke-ReportSection -Title "Virtual Switch Standard" -SubSection -FormatAs Table -Collector {
        $vmhost | Get-VirtualSwitch -Standard -ErrorAction SilentlyContinue |
            Select-Object Name, NumPorts, Mtu, @{N = 'NIC'; E = { ($_.Nic -join ', ') } }
    }

    Invoke-ReportSection -Title "Virtual Switch Distribuiti (associati)" -SubSection -FormatAs Table -Collector {
        $vmhost | Get-VDSwitch -ErrorAction SilentlyContinue |
            Select-Object Name, NumUplinkPorts, Mtu, Version
    }

    Invoke-ReportSection -Title "Port Group" -SubSection -FormatAs Table -Collector {
        $vmhost | Get-VirtualPortGroup -ErrorAction SilentlyContinue |
            Select-Object Name, VirtualSwitch, VLanId
    }

    Invoke-ReportSection -Title "Adattatori di rete fisici (vmnic)" -SubSection -FormatAs Table -Collector {
        $vmhost | Get-VMHostNetworkAdapter -Physical -ErrorAction SilentlyContinue |
            Select-Object Name, Mac, BitRatePerSec, FullDuplex, Status
    }

    Invoke-ReportSection -Title "Adattatori VMkernel (vmk)" -SubSection -FormatAs Table -Collector {
        $vmhost | Get-VMHostNetworkAdapter -VMKernel -ErrorAction SilentlyContinue |
            Select-Object Name, PortGroupName, IP, SubnetMask, Mac, Mtu,
                VMotionEnabled, ManagementTrafficEnabled, FaultToleranceLoggingEnabled, VsanTrafficEnabled
    }

    Invoke-ReportSection -Title "Routing statico" -SubSection -FormatAs Table -Collector {
        $hostView.Config.Network.RouteTableInfo.IpRoute |
            Select-Object @{N = 'Network'; E = { $_.Network } },
                @{N = 'PrefixLength'; E = { $_.PrefixLength } },
                @{N = 'Gateway'; E = { $_.Gateway.IpAddress } }
    }

    # ------------------------------------------------------------------------------
    # 5. Storage
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "STORAGE" -Collector { "Dettaglio nelle sottosezioni seguenti." }

    Invoke-ReportSection -Title "Datastore" -SubSection -FormatAs Table -Collector {
        $vmhost | Get-Datastore -ErrorAction SilentlyContinue |
            Select-Object Name, Type,
                @{N = 'CapacityGB'; E = { [math]::Round($_.CapacityGB, 1) } },
                @{N = 'FreeSpaceGB'; E = { [math]::Round($_.FreeSpaceGB, 1) } }
    }

    Invoke-ReportSection -Title "Adattatori Storage (HBA)" -SubSection -FormatAs Table -Collector {
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

    Invoke-ReportSection -Title "Multipathing (esempio primi 20 path)" -SubSection -FormatAs Table -Collector {
        $vmhost | Get-ScsiLun -ErrorAction SilentlyContinue |
            Get-ScsiLunPath -ErrorAction SilentlyContinue |
            Select-Object -First 20 SanID, State, Preferred
    }

    # ------------------------------------------------------------------------------
    # 6. Servizi e Sicurezza
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "SERVIZI" -FormatAs Table -Collector {
        $vmhost | Get-VMHostService -ErrorAction SilentlyContinue |
            Select-Object Label, Key, Running, Policy
    }

    Invoke-ReportSection -Title "FIREWALL (regole abilitate)" -FormatAs Table -Collector {
        $vmhost | Get-VMHostFirewallException -ErrorAction SilentlyContinue |
            Where-Object { $_.Enabled } |
            Select-Object Name, Enabled, Protocols,
                @{N = 'PortRange'; E = { $_.Port } }
    }

    Invoke-ReportSection -Title "Profilo di sicurezza account locali" -SubSection -FormatAs Table -Collector {
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
    # 8. VIB installati (pacchetti software)
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "VIB INSTALLATI (software packages)" -FormatAs Table -Collector {
        $esxcli = Get-EsxCli -VMHost $vmhost -V2 -ErrorAction Stop
        $esxcli.software.vib.list.Invoke() |
            Select-Object Name, Version, Vendor, AcceptanceLevel, InstallDate, Status |
            Sort-Object Name
    }

    # ------------------------------------------------------------------------------
    # 9. Certificati host
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "CERTIFICATO HOST (HTTPS/vpxd)" -Collector {
        $certBytes = $hostView.Config.Certificate

        if (-not $certBytes) {
            [PSCustomObject]@{ Info = 'Certificato non esposto dalle API per questo host/permessi.' }
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
    # 10. Impostazioni avanzate (dump completo)
    # ------------------------------------------------------------------------------

    Invoke-ReportSection -Title "IMPOSTAZIONI AVANZATE (Advanced System Settings) - dump completo" -FormatAs KeyValue -Collector {
        $vmhost | Get-AdvancedSetting -ErrorAction SilentlyContinue |
            Select-Object Name, Value |
            Sort-Object Name
    }

    # ------------------------------------------------------------------------------
    # Scrittura del file di report
    # ------------------------------------------------------------------------------

    if (-not (Test-Path -Path $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $safeHostName = ($EsxiHost -replace '[\\/:*?"<>|]', '_')
    $reportFile = Join-Path -Path $OutputFolder -ChildPath "EsxiConfig_${safeHostName}_${timestamp}.txt"

    $script:ReportLines | Set-Content -Path $reportFile -Encoding UTF8

    Write-Host ""
    Write-Host "Report completato: $reportFile" -ForegroundColor Green
}
finally {
    Disconnect-VIServer -Server $viConnection -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Disconnesso da vCenter." -ForegroundColor Cyan
}
