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
    Three optional columns let each row override -PortBinding,
    -PortAllocation and -NumPorts individually; when a column is missing
    or blank for a row, the corresponding script parameter is used as
    the default. Quote any VLANID value that contains a comma (e.g. a
    multi-range trunk), otherwise the CSV parser will silently drop
    everything after the first comma.
    Example content:
        PGName,VLANID,PortBinding,PortAllocation,NumPorts
        PG-Server-Web,101,Static,Elastic,
        PG-Server-DB,102,Static,Fixed,16
        PG-Trunk-Full,TRUNK,,,
        PG-Trunk-Partial,"10-20,30-40",,,
        PG-Ephemeral-Web,104,Ephemeral,,

.PARAMETER PortBinding
    Default port binding for every port group. Valid values: 'Static'
    (recommended) or 'Ephemeral'. Default 'Static'. Can be overridden per
    row via the CSV 'PortBinding' column.

.PARAMETER PortAllocation
    Default port allocation for every port group, only meaningful when
    port binding is 'Static' (ignored for 'Ephemeral'). Valid values:
    'Elastic' (the port group grows automatically, vCenter's own default)
    or 'Fixed'. Default 'Elastic'. Can be overridden per row via the CSV
    'PortAllocation' column.

.PARAMETER NumPorts
    Default number of ports for every port group (only meaningful when
    port binding is 'Static'; ignored for 'Ephemeral'). If omitted,
    New-VDPortgroup's own default (128) is used. Can be overridden per
    row via the CSV 'NumPorts' column.

.EXAMPLE
    .\New-VDPortgroupFromVlanList.ps1 -vCenter vcenter.lab.local -Username 'lab\administrator' -VDSwitchName 'vDS-Prod' -VlanIds 10,20,30

.EXAMPLE
    .\New-VDPortgroupFromVlanList.ps1 -vCenter vcenter.lab.local -Username 'administrator@vsphere.local' -VDSwitchName 'vDS-Prod' -VlanIds (100..110) -NamePrefix 'APP-VLAN-'

.EXAMPLE
    .\New-VDPortgroupFromVlanList.ps1 -vCenter vcenter.lab.local -Username 'administrator@vsphere.local' -VDSwitchName 'vDS-Prod' -CsvPath '.\portgroups.csv'

.EXAMPLE
    .\New-VDPortgroupFromVlanList.ps1 -vCenter vcenter.lab.local -Username 'administrator@vsphere.local' -VDSwitchName 'vDS-Prod' -VlanIds 10,20 -PortBinding Static -PortAllocation Fixed -NumPorts 16

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
    [string]  $CsvPath,

    [ValidateSet('Static', 'Ephemeral')]
    [string]  $PortBinding = 'Static',

    [ValidateSet('Elastic', 'Fixed')]
    [string]  $PortAllocation = 'Elastic',

    [ValidateRange(1, 8192)]
    [int]     $NumPorts = 0
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

# --- Resolves and validates PortBinding/PortAllocation/NumPorts for a ----
# --- port group, applying script-level defaults when a value is blank ---
function Resolve-PortGroupOptions {
    param(
        [string] $PGName,
        [string] $RawPortBinding,
        [string] $RawPortAllocation,
        [string] $RawNumPorts,
        [string] $DefaultPortBinding,
        [string] $DefaultPortAllocation,
        [int]    $DefaultNumPorts
    )

    $binding = if ($RawPortBinding) { $RawPortBinding } else { $DefaultPortBinding }
    switch -Regex ($binding) {
        '^Static$'    { $binding = 'Static' }
        '^Ephemeral$' { $binding = 'Ephemeral' }
        default {
            Write-Warning "Invalid PortBinding ('$binding') for '$PGName': use Static or Ephemeral. Row skipped."
            return $null
        }
    }

    $allocation = if ($RawPortAllocation) { $RawPortAllocation } else { $DefaultPortAllocation }
    switch -Regex ($allocation) {
        '^Elastic$' { $allocation = 'Elastic' }
        '^Fixed$'   { $allocation = 'Fixed' }
        default {
            Write-Warning "Invalid PortAllocation ('$allocation') for '$PGName': use Elastic or Fixed. Row skipped."
            return $null
        }
    }

    $numPorts = $DefaultNumPorts
    if ($RawNumPorts) {
        if (-not ([int]::TryParse($RawNumPorts, [ref] $numPorts)) -or $numPorts -lt 1 -or $numPorts -gt 8192) {
            Write-Warning "Invalid NumPorts ('$RawNumPorts') for '$PGName': must be an integer between 1 and 8192. Row skipped."
            return $null
        }
    }

    if ($binding -eq 'Ephemeral') {
        if ($RawPortAllocation) { Write-Warning "PortAllocation is ignored for '$PGName' because PortBinding is Ephemeral." }
        if ($RawNumPorts) { Write-Warning "NumPorts is ignored for '$PGName' because PortBinding is Ephemeral." }
    }

    return [pscustomobject]@{
        PortBinding    = $binding
        PortAllocation = $allocation
        NumPorts       = $numPorts
    }
}

# --- Ensure PowerCLI is available. Checked by cmdlet, not by module ------
# --- name: PowerCLI packaging varies (VMware.PowerCLI, VCF.PowerCLI, or ---
# --- per-component modules such as VMware.PowerCLI.vCenter), so a fixed --
# --- module-name check would fail even when PowerCLI is installed. -------
if (-not (Get-Command -Name Connect-VIServer -ErrorAction SilentlyContinue)) {
    foreach ($candidate in 'VCF.PowerCLI', 'VMware.PowerCLI') {
        if (Get-Module -ListAvailable -Name $candidate -ErrorAction SilentlyContinue) {
            Import-Module $candidate -ErrorAction SilentlyContinue
            break
        }
    }
}
if (-not (Get-Command -Name Connect-VIServer -ErrorAction SilentlyContinue)) {
    throw "PowerCLI not found (Connect-VIServer is unavailable). Install it with: Install-Module VMware.PowerCLI"
}

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

            $vlanInfo = if ($rawVlan -match '^(TRUNK|ALL)$') {
                @{ Mode = 'Trunk'; Vlan = $null; TrunkRange = '0-4094' }
            }
            elseif ($rawVlan -match '^\d{1,4}$') {
                @{ Mode = 'Access'; Vlan = [int]$rawVlan; TrunkRange = $null }
            }
            elseif ((Test-VlanTrunkRange -Range $rawVlan)) {
                @{ Mode = 'Trunk'; Vlan = $null; TrunkRange = ($rawVlan -replace '\s', '') }
            }
            else {
                Write-Warning "Invalid VLANID ('$rawVlan') for '$pgNameCsv': use a number, a range (e.g. 10-20 or 10-20,30-40) or TRUNK/ALL. Row skipped."
                $null
            }
            if (-not $vlanInfo) { continue }

            $opts = Resolve-PortGroupOptions -PGName $pgNameCsv `
                        -RawPortBinding "$($row.PortBinding)".Trim() -RawPortAllocation "$($row.PortAllocation)".Trim() -RawNumPorts "$($row.NumPorts)".Trim() `
                        -DefaultPortBinding $PortBinding -DefaultPortAllocation $PortAllocation -DefaultNumPorts $NumPorts
            if (-not $opts) { continue }

            $portGroups += [pscustomobject]@{
                Name = $pgNameCsv; Mode = $vlanInfo.Mode; Vlan = $vlanInfo.Vlan; TrunkRange = $vlanInfo.TrunkRange
                PortBinding = $opts.PortBinding; PortAllocation = $opts.PortAllocation; NumPorts = $opts.NumPorts
            }
        }
    }
    else {
        $opts = Resolve-PortGroupOptions -PGName '<VlanIds>' -RawPortBinding '' -RawPortAllocation '' -RawNumPorts '' `
                    -DefaultPortBinding $PortBinding -DefaultPortAllocation $PortAllocation -DefaultNumPorts $NumPorts

        foreach ($vlan in $VlanIds) {
            $portGroups += [pscustomobject]@{
                Name = "$NamePrefix$vlan"; Mode = 'Access'; Vlan = $vlan; TrunkRange = $null
                PortBinding = $opts.PortBinding; PortAllocation = $opts.PortAllocation; NumPorts = $opts.NumPorts
            }
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
        $bindingLabel = if ($item.PortBinding -eq 'Static') { "Static/$($item.PortAllocation)" } else { 'Ephemeral' }

        try {
            # --- Create the port group with a single VLAN or trunk ------------
            $ngParams = @{
                VDSwitch    = $vds
                Name        = $pgName
                PortBinding = $item.PortBinding
                Notes       = "Created via script - $vlanLabel, $bindingLabel"
                ErrorAction = 'Stop'
            }
            if ($item.Mode -eq 'Trunk') { $ngParams['VlanTrunkRange'] = $item.TrunkRange }
            else { $ngParams['VlanId'] = $item.Vlan }
            if ($item.PortBinding -eq 'Static' -and $item.NumPorts -gt 0) { $ngParams['NumPorts'] = $item.NumPorts }

            $pg = New-VDPortgroup @ngParams

            # --- Port allocation (Elastic/Fixed): only settable via the raw ---
            # --- vSphere API, no dedicated PowerCLI cmdlet parameter exists ---
            if ($item.PortBinding -eq 'Static') {
                $view = Get-View -Id $pg.Id -ErrorAction Stop
                $spec = New-Object VMware.Vim.DVPortgroupConfigSpec
                $spec.ConfigVersion = $view.Config.ConfigVersion
                $spec.AutoExpand = ($item.PortAllocation -eq 'Elastic')
                $view.ReconfigureDVPortgroup($spec)
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

            Write-Host "OK  -> '$pgName' ($vlanLabel, $bindingLabel): security Reject x3, teaming LBT." -ForegroundColor Green
            $created += $pg
        }
        catch {
            Write-Host "ERR -> '$pgName' ($vlanLabel, $bindingLabel): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # --- Final summary with read-back of applied settings --------------------
    if ($created) {
        Write-Host "`n=== Created port groups summary ===" -ForegroundColor Cyan
        $created | ForEach-Object {
            $sec       = $_ | Get-VDSecurityPolicy
            $team      = $_ | Get-VDUplinkTeamingPolicy
            $vlanCfg   = $_.VlanConfiguration
            $vlan      = if ($vlanCfg.PSObject.Properties['Ranges']) { "Trunk $($vlanCfg.Ranges)" } else { "VLAN $($vlanCfg.VlanId)" }
            $allocation = if ($_.PortBinding -eq 'Static') {
                if ((Get-View -Id $_.Id).Config.AutoExpand) { 'Elastic' } else { 'Fixed' }
            } else { 'N/A' }
            [pscustomobject]@{
                PortGroup       = $_.Name
                Vlan            = $vlan
                PortBinding     = $_.PortBinding
                PortAllocation  = $allocation
                NumPorts        = $_.NumPorts
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
