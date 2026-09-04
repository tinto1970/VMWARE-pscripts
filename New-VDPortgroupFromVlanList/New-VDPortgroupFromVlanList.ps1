<#
.SYNOPSIS
    Crea distributed port group su un vDS a partire da una lista di VLAN ID,
    applicando la security policy piu' restrittiva (Reject su tutti e tre i
    settaggi) e il teaming basato sul carico della NIC fisica (LBT).

.PARAMETER vCenter
    Nome (o FQDN) del vCenter Server a cui connettersi.

.PARAMETER Username
    Utente con cui autenticarsi al vCenter. La password viene richiesta
    interattivamente durante l'esecuzione (non va passata come parametro).

.PARAMETER VDSwitchName
    Nome del vDS su cui creare i port group.

.PARAMETER VlanIds
    Lista di VLAN ID (es. 10,20,30 oppure 100..110). I nomi dei PG vengono
    generati come '<NamePrefix><VlanId>'. Alternativo a -CsvPath.

.PARAMETER NamePrefix
    Prefisso del nome dei PG quando si usa -VlanIds. Default 'PG-VLAN-' ->
    'PG-VLAN-10', 'PG-VLAN-20', ...

.PARAMETER CsvPath
    Percorso di un file CSV con le colonne 'nomePG' e 'VLANID' (una riga per
    port group, nome libero non derivato dalla VLAN). Alternativo a -VlanIds.
    Esempio di contenuto:
        nomePG,VLANID
        PG-Server-Web,101
        PG-Server-DB,102

.EXAMPLE
    .\New-VDPortgroupFromVlanList.ps1 -vCenter vcenter.lab.local -Username 'lab\amministratore' -VDSwitchName 'vDS-Prod' -VlanIds 10,20,30

.EXAMPLE
    .\New-VDPortgroupFromVlanList.ps1 -vCenter vcenter.lab.local -Username 'administrator@vsphere.local' -VDSwitchName 'vDS-Prod' -VlanIds (100..110) -NamePrefix 'APP-VLAN-'

.EXAMPLE
    .\New-VDPortgroupFromVlanList.ps1 -vCenter vcenter.lab.local -Username 'administrator@vsphere.local' -VDSwitchName 'vDS-Prod' -CsvPath '.\portgroups.csv'

.NOTES
    Richiede VMware PowerCLI. Lo script gestisce autonomamente connessione e
    disconnessione al vCenter (Connect-VIServer / Disconnect-VIServer).
    LBT (LoadBalanceLoadBased) mantiene attivi tutti gli uplink ereditati dal vDS
    e NON richiede configurazione lato switch fisico (no EtherChannel/LACP).
#>

[CmdletBinding(DefaultParameterSetName = 'ByVlanList')]
param(
    [Parameter(Mandatory = $true)]
    [string]  $vCenter,

    [Parameter(Mandatory = $true)]
    [string]  $Username,

    [Parameter(Mandatory = $true)]
    [string]  $VDSwitchName,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByVlanList')]
    [int[]]   $VlanIds,

    [Parameter(ParameterSetName = 'ByVlanList')]
    [string]  $NamePrefix = 'PG-VLAN-',

    [Parameter(Mandatory = $true, ParameterSetName = 'ByCsv')]
    [string]  $CsvPath
)

# --- Connessione a vCenter (password richiesta interattivamente) --------
if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI -ErrorAction SilentlyContinue)) {
    throw "Modulo VMware.PowerCLI non trovato. Installalo con: Install-Module VMware.PowerCLI"
}
Import-Module VMware.PowerCLI -ErrorAction Stop

$securePassword = Read-Host -Prompt "Password per $Username" -AsSecureString
$credential = New-Object System.Management.Automation.PSCredential ($Username, $securePassword)

try {
    $viConnection = Connect-VIServer -Server $vCenter -Credential $credential -ErrorAction Stop
    Write-Host "Connesso a '$vCenter' come '$Username'." -ForegroundColor Green
}
catch {
    throw "Connessione a '$vCenter' fallita: $($_.Exception.Message)"
}

try {
    # --- Recupero del vDS ------------------------------------------------
    $vds = Get-VDSwitch -Name $VDSwitchName -ErrorAction Stop

    # --- Costruzione della lista port group da creare ---------------------
    $portGroups = @()

    if ($PSCmdlet.ParameterSetName -eq 'ByCsv') {
        if (-not (Test-Path -Path $CsvPath -PathType Leaf)) {
            throw "File CSV non trovato: $CsvPath"
        }

        $rows = Import-Csv -Path $CsvPath -ErrorAction Stop
        foreach ($row in $rows) {
            if (-not $row.PSObject.Properties['nomePG'] -or -not $row.PSObject.Properties['VLANID']) {
                throw "Il CSV deve avere le colonne 'nomePG' e 'VLANID'."
            }

            $pgNameCsv = "$($row.nomePG)".Trim()
            if (-not $pgNameCsv) {
                Write-Warning "Riga CSV con nomePG vuoto: saltata."
                continue
            }

            $vlanCsv = 0
            if (-not [int]::TryParse("$($row.VLANID)".Trim(), [ref] $vlanCsv)) {
                Write-Warning "VLANID non numerico ('$($row.VLANID)') per '$pgNameCsv': riga saltata."
                continue
            }

            $portGroups += [pscustomobject]@{ Name = $pgNameCsv; Vlan = $vlanCsv }
        }
    }
    else {
        foreach ($vlan in $VlanIds) {
            $portGroups += [pscustomobject]@{ Name = "$NamePrefix$vlan"; Vlan = $vlan }
        }
    }

    $created = @()

    foreach ($item in $portGroups) {
        $pgName = $item.Name
        $vlan   = $item.Vlan

        # --- Validazione range VLAN ---------------------------------------
        if ($vlan -lt 0 -or $vlan -gt 4094) {
            Write-Warning "VLAN $vlan fuori range (0-4094) per '$pgName': saltata."
            continue
        }

        # --- Idempotenza: salta se il PG esiste gia' -----------------------
        if (Get-VDPortgroup -VDSwitch $vds -Name $pgName -ErrorAction SilentlyContinue) {
            Write-Warning "Port group '$pgName' gia' esistente: saltato."
            continue
        }

        try {
            # --- Creazione del port group con la VLAN -----------------------
            $pg = New-VDPortgroup -VDSwitch $vds -Name $pgName -VlanId $vlan `
                                  -Notes "Creato via script - VLAN $vlan" -ErrorAction Stop

            # --- Security policy: Reject su tutti e tre i settaggi -----------
            $pg | Get-VDSecurityPolicy |
                  Set-VDSecurityPolicy -AllowPromiscuous $false `
                                       -MacChanges       $false `
                                       -ForgedTransmits  $false `
                                       -ErrorAction Stop | Out-Null

            # --- Teaming: Route based on physical NIC load (LBT) ------------
            $pg | Get-VDUplinkTeamingPolicy |
                  Set-VDUplinkTeamingPolicy -LoadBalancingPolicy LoadBalanceLoadBased `
                                            -ErrorAction Stop | Out-Null

            Write-Host "OK  -> '$pgName' (VLAN $vlan): security Reject x3, teaming LBT." -ForegroundColor Green
            $created += $pg
        }
        catch {
            Write-Host "ERR -> '$pgName' (VLAN $vlan): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # --- Riepilogo finale con read-back dei settaggi applicati --------------
    if ($created) {
        Write-Host "`n=== Riepilogo port group creati ===" -ForegroundColor Cyan
        $created | ForEach-Object {
            $sec  = $_ | Get-VDSecurityPolicy
            $team = $_ | Get-VDUplinkTeamingPolicy
            [pscustomobject]@{
                PortGroup       = $_.Name
                VlanId          = $_.VlanConfiguration.VlanId
                Promiscuous     = $sec.AllowPromiscuous
                MacChanges      = $sec.MacChanges
                ForgedTransmits = $sec.ForgedTransmits
                LoadBalancing   = $team.LoadBalancingPolicy
            }
        } | Format-Table -AutoSize
    }
}
finally {
    # --- Disconnessione dal vCenter (sempre, anche in caso di errore) ---
    if ($viConnection) {
        Disconnect-VIServer -Server $viConnection -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "Disconnesso da '$vCenter'." -ForegroundColor Cyan
    }
}
