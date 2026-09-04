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
    La colonna VLANID accetta tre formati:
      - un numero singolo (0-4094)          -> port group in modalita' Access
      - la parola chiave TRUNK oppure ALL    -> trunk completo, range 0-4094
      - un range esplicito (es. 10-20 oppure 10-20,30-40) -> trunk sul range indicato
    Esempio di contenuto:
        nomePG,VLANID
        PG-Server-Web,101
        PG-Server-DB,102
        PG-Trunk-Full,TRUNK
        PG-Trunk-Parziale,10-20,30-40

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

# --- Validazione di un range/lista di VLAN per il trunk (es. "10-20,30-40") ---
function Test-VlanTrunkRange {
    param([string] $Range)

    foreach ($segment in ($Range -split ',')) {
        $segment = $segment.Trim()
        if ($segment -match '^(\d{1,4})-(\d{1,4})$') {
            $lo = [int]$Matches[1]; $hi = [int]$Matches[2]
            if ($lo -lt 0 -or $hi -gt 4094 -or $lo -gt $hi) { return $false }
        }
        elseif ($segment -match '^(\d{1,4})$') {
            $v = [int]$Matches[1]
            if ($v -lt 0 -or $v -gt 4094) { return $false }
        }
        else {
            return $false
        }
    }
    return $true
}

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

            $rawVlan = "$($row.VLANID)".Trim()

            if ($rawVlan -match '^(TRUNK|ALL)$') {
                $portGroups += [pscustomobject]@{ Name = $pgNameCsv; Mode = 'Trunk'; Vlan = $null; TrunkRange = '0-4094' }
            }
            elseif ($rawVlan -match '^\d{1,4}$') {
                $portGroups += [pscustomobject]@{ Name = $pgNameCsv; Mode = 'Access'; Vlan = [int]$rawVlan; TrunkRange = $null }
            }
            elseif ((Test-VlanTrunkRange -Range $rawVlan)) {
                $portGroups += [pscustomobject]@{ Name = $pgNameCsv; Mode = 'Trunk'; Vlan = $null; TrunkRange = ($rawVlan -replace '\s', '') }
            }
            else {
                Write-Warning "VLANID non valido ('$rawVlan') per '$pgNameCsv': usa un numero, un range (es. 10-20 o 10-20,30-40) oppure TRUNK/ALL. Riga saltata."
            }
        }
    }
    else {
        foreach ($vlan in $VlanIds) {
            $portGroups += [pscustomobject]@{ Name = "$NamePrefix$vlan"; Mode = 'Access'; Vlan = $vlan; TrunkRange = $null }
        }
    }

    $created = @()

    foreach ($item in $portGroups) {
        $pgName = $item.Name

        # --- Validazione range VLAN (solo modalita' Access) ----------------
        if ($item.Mode -eq 'Access' -and ($item.Vlan -lt 0 -or $item.Vlan -gt 4094)) {
            Write-Warning "VLAN $($item.Vlan) fuori range (0-4094) per '$pgName': saltata."
            continue
        }

        # --- Idempotenza: salta se il PG esiste gia' -----------------------
        if (Get-VDPortgroup -VDSwitch $vds -Name $pgName -ErrorAction SilentlyContinue) {
            Write-Warning "Port group '$pgName' gia' esistente: saltato."
            continue
        }

        $vlanLabel = if ($item.Mode -eq 'Trunk') { "Trunk $($item.TrunkRange)" } else { "VLAN $($item.Vlan)" }

        try {
            # --- Creazione del port group con VLAN singola o trunk -----------
            if ($item.Mode -eq 'Trunk') {
                $pg = New-VDPortgroup -VDSwitch $vds -Name $pgName -VlanTrunkRange $item.TrunkRange `
                                      -Notes "Creato via script - $vlanLabel" -ErrorAction Stop
            }
            else {
                $pg = New-VDPortgroup -VDSwitch $vds -Name $pgName -VlanId $item.Vlan `
                                      -Notes "Creato via script - $vlanLabel" -ErrorAction Stop
            }

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

            Write-Host "OK  -> '$pgName' ($vlanLabel): security Reject x3, teaming LBT." -ForegroundColor Green
            $created += $pg
        }
        catch {
            Write-Host "ERR -> '$pgName' ($vlanLabel): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # --- Riepilogo finale con read-back dei settaggi applicati --------------
    if ($created) {
        Write-Host "`n=== Riepilogo port group creati ===" -ForegroundColor Cyan
        $created | ForEach-Object {
            $sec     = $_ | Get-VDSecurityPolicy
            $team    = $_ | Get-VDUplinkTeamingPolicy
            $vlanCfg = $_.VlanConfiguration
            $vlan    = if ($vlanCfg.PSObject.Properties['Ranges']) { "Trunk $($vlanCfg.Ranges)" } else { "VLAN $($vlanCfg.VlanId)" }
            [pscustomobject]@{
                PortGroup       = $_.Name
                Vlan            = $vlan
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
