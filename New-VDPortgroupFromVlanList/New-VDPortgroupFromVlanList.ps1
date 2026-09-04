<#
.SYNOPSIS
    Creates distributed port groups on a vDS from a list of VLAN IDs,
    applying the most restrictive security policy (Reject on all three
    settings) and load-based teaming on the physical NIC (LBT).

.PARAMETER vCenter
    Name (or FQDN) of the vCenter Server to connect to.

.PARAMETER Username
    User to authenticate to vCenter with. The password is requested
    interactively during execution (never pass it as a parameter).

.PARAMETER VDSwitchName
    Name of the vDS on which to create the port groups.

.PARAMETER VlanIds
    List of VLAN IDs (e.g. 10,20,30 or 100..110). PG names are generated
    as '<NamePrefix><VlanId>'. Alternative to -CsvPath.

.PARAMETER NamePrefix
    Prefix for the PG name when using -VlanIds. Default 'PG-VLAN-' ->
    'PG-VLAN-10', 'PG-VLAN-20', ...

.PARAMETER CsvPath
    Path to a CSV file with columns 'PGName' and 'VLANID' (one row per
    port group, free-form name not derived from the VLAN). Alternative
    to -VlanIds. The VLANID column accepts three formats:
      - a single number (0-4094)             -> port group in Access mode
      - the keyword TRUNK or ALL              -> full trunk, range 0-4094
      - an explicit range (e.g. 10-20 or 10-20,30-40) -> trunk on that range
    Example content:
        PGName,VLANID
        PG-Server-Web,101
        PG-Server-DB,102
        PG-Trunk-Full,TRUNK
        PG-Trunk-Partial,10-20,30-40

.EXAMPLE
    .\New-VDPortgroupFromVlanList.ps1 -vCenter vcenter.lab.local -Username 'lab\administrator' -VDSwitchName 'vDS-Prod' -VlanIds 10,20,30

.EXAMPLE
    .\New-VDPortgroupFromVlanList.ps1 -vCenter vcenter.lab.local -Username 'administrator@vsphere.local' -VDSwitchName 'vDS-Prod' -VlanIds (100..110) -NamePrefix 'APP-VLAN-'

.EXAMPLE
    .\New-VDPortgroupFromVlanList.ps1 -vCenter vcenter.lab.local -Username 'administrator@vsphere.local' -VDSwitchName 'vDS-Prod' -CsvPath '.\portgroups.csv'

.NOTES
    Requires VMware PowerCLI. The script handles vCenter connection and
    disconnection on its own (Connect-VIServer / Disconnect-VIServer).
    LBT (LoadBalanceLoadBased) keeps all uplinks inherited from the vDS
    active and does NOT require any physical switch configuration
    (no EtherChannel/LACP).
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

# --- Validates a VLAN range/list for trunk mode (e.g. "10-20,30-40") ----
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

# --- Connect to vCenter (password requested interactively) --------------
if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI -ErrorAction SilentlyContinue)) {
    throw "VMware.PowerCLI module not found. Install it with: Install-Module VMware.PowerCLI"
}
Import-Module VMware.PowerCLI -ErrorAction Stop

$securePassword = Read-Host -Prompt "Password for $Username" -AsSecureString
$credential = New-Object System.Management.Automation.PSCredential ($Username, $securePassword)

try {
    $viConnection = Connect-VIServer -Server $vCenter -Credential $credential -ErrorAction Stop
    Write-Host "Connected to '$vCenter' as '$Username'." -ForegroundColor Green
}
catch {
    throw "Connection to '$vCenter' failed: $($_.Exception.Message)"
}

try {
    # --- Retrieve the vDS -------------------------------------------------
    $vds = Get-VDSwitch -Name $VDSwitchName -ErrorAction Stop

    # --- Build the list of port groups to create ---------------------------
    $portGroups = @()

    if ($PSCmdlet.ParameterSetName -eq 'ByCsv') {
        if (-not (Test-Path -Path $CsvPath -PathType Leaf)) {
            throw "CSV file not found: $CsvPath"
        }

        $rows = Import-Csv -Path $CsvPath -ErrorAction Stop
        foreach ($row in $rows) {
            if (-not $row.PSObject.Properties['PGName'] -or -not $row.PSObject.Properties['VLANID']) {
                throw "The CSV must have the columns 'PGName' and 'VLANID'."
            }

            $pgNameCsv = "$($row.PGName)".Trim()
            if (-not $pgNameCsv) {
                Write-Warning "CSV row with empty PGName: skipped."
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
                Write-Warning "Invalid VLANID ('$rawVlan') for '$pgNameCsv': use a number, a range (e.g. 10-20 or 10-20,30-40) or TRUNK/ALL. Row skipped."
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

        # --- VLAN range validation (Access mode only) -----------------------
        if ($item.Mode -eq 'Access' -and ($item.Vlan -lt 0 -or $item.Vlan -gt 4094)) {
            Write-Warning "VLAN $($item.Vlan) out of range (0-4094) for '$pgName': skipped."
            continue
        }

        # --- Idempotency: skip if the PG already exists ---------------------
        if (Get-VDPortgroup -VDSwitch $vds -Name $pgName -ErrorAction SilentlyContinue) {
            Write-Warning "Port group '$pgName' already exists: skipped."
            continue
        }

        $vlanLabel = if ($item.Mode -eq 'Trunk') { "Trunk $($item.TrunkRange)" } else { "VLAN $($item.Vlan)" }

        try {
            # --- Create the port group with a single VLAN or trunk ------------
            if ($item.Mode -eq 'Trunk') {
                $pg = New-VDPortgroup -VDSwitch $vds -Name $pgName -VlanTrunkRange $item.TrunkRange `
                                      -Notes "Created via script - $vlanLabel" -ErrorAction Stop
            }
            else {
                $pg = New-VDPortgroup -VDSwitch $vds -Name $pgName -VlanId $item.Vlan `
                                      -Notes "Created via script - $vlanLabel" -ErrorAction Stop
            }

            # --- Security policy: Reject on all three settings -----------------
            $pg | Get-VDSecurityPolicy |
                  Set-VDSecurityPolicy -AllowPromiscuous $false `
                                       -MacChanges       $false `
                                       -ForgedTransmits  $false `
                                       -ErrorAction Stop | Out-Null

            # --- Teaming: Route based on physical NIC load (LBT) ---------------
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

    # --- Final summary with read-back of applied settings --------------------
    if ($created) {
        Write-Host "`n=== Created port groups summary ===" -ForegroundColor Cyan
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
    # --- Disconnect from vCenter (always, even on error) -----------------
    if ($viConnection) {
        Disconnect-VIServer -Server $viConnection -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "Disconnected from '$vCenter'." -ForegroundColor Cyan
    }
}
