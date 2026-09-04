# VMWARE-pscripts

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

scripts vari

## Script disponibili

### [New-VDPortgroupFromVlanList](New-VDPortgroupFromVlanList/New-VDPortgroupFromVlanList.ps1)

Crea distributed port group su un vDS a partire da una lista di VLAN ID oppure
da un file CSV (`nomePG,VLANID`), applicando automaticamente:

- security policy piu' restrittiva (Reject su Promiscuous, MAC Changes, Forged Transmits)
- teaming basato sul carico della NIC fisica (Route based on physical NIC load, LBT)

Gestisce in autonomia connessione e disconnessione al vCenter (richiede il
modulo VMware PowerCLI). La password viene richiesta interattivamente,
non va mai passata come parametro.

Nel CSV la colonna `VLANID` accetta:

| Formato                  | Risultato                                   |
|---------------------------|----------------------------------------------|
| `101`                      | port group Access sulla VLAN 101              |
| `TRUNK` oppure `ALL`       | port group trunk su tutte le VLAN (0-4094)    |
| `10-20` oppure `10-20,30-40` | port group trunk sul range indicato        |

```powershell
# da lista di VLAN
.\New-VDPortgroupFromVlanList.ps1 -vCenter vcenter.lab.local -Username 'administrator@vsphere.local' -VDSwitchName 'vDS-Prod' -VlanIds 10,20,30

# da file CSV (colonne: nomePG,VLANID) - supporta anche trunk (TRUNK/ALL o range)
.\New-VDPortgroupFromVlanList.ps1 -vCenter vcenter.lab.local -Username 'administrator@vsphere.local' -VDSwitchName 'vDS-Prod' -CsvPath .\portgroups-example.csv
```

## License

Distribuito sotto licenza [MIT](LICENSE).
