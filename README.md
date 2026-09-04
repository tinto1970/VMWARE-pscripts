# VMWARE-pscripts

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Various scripts.

## Available scripts

### [New-VDPortgroupFromVlanList](New-VDPortgroupFromVlanList/New-VDPortgroupFromVlanList.ps1)

Creates distributed port groups on a vDS from a list of VLAN IDs or from a
CSV file (`PGName,VLANID`), automatically applying:

- the most restrictive security policy (Reject on Promiscuous, MAC Changes, Forged Transmits)
- load-based teaming on the physical NIC (Route based on physical NIC load, LBT)

Handles vCenter connection and disconnection on its own (requires the
VMware PowerCLI module). The password is requested interactively and
should never be passed as a parameter.

In the CSV, the `VLANID` column accepts:

| Format                        | Result                                     |
|--------------------------------|---------------------------------------------|
| `101`                           | Access port group on VLAN 101               |
| `TRUNK` or `ALL`                | trunk port group on all VLANs (0-4094)      |
| `10-20` or `10-20,30-40`        | trunk port group on the given range         |

```powershell
# from a list of VLANs
.\New-VDPortgroupFromVlanList.ps1 -vCenter vcenter.lab.local -Username 'administrator@vsphere.local' -VDSwitchName 'vDS-Prod' -VlanIds 10,20,30

# from a CSV file (columns: PGName,VLANID) - also supports trunk (TRUNK/ALL or range)
.\New-VDPortgroupFromVlanList.ps1 -vCenter vcenter.lab.local -Username 'administrator@vsphere.local' -VDSwitchName 'vDS-Prod' -CsvPath .\portgroups-example.csv
```

## License

Distributed under the [MIT](LICENSE) license.
