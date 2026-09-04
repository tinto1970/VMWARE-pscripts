# VMWARE-pscripts
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

```powershell
# da lista di VLAN
.\New-VDPortgroupFromVlanList.ps1 -vCenter vcenter.lab.local -Username 'administrator@vsphere.local' -VDSwitchName 'vDS-Prod' -VlanIds 10,20,30

# da file CSV (colonne: nomePG,VLANID)
.\New-VDPortgroupFromVlanList.ps1 -vCenter vcenter.lab.local -Username 'administrator@vsphere.local' -VDSwitchName 'vDS-Prod' -CsvPath .\portgroups-example.csv
```
