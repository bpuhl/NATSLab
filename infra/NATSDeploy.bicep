@description('Deployment location')
param location string = resourceGroup().location

@description('Admin username for all VMs')
param adminUsername string

@description('SSH public key for admin user')
@secure()
param adminSshPublicKey string

@description('VM size for all nodes')
param vmSize string = 'Standard_B2ts_v2'

@description('DNS zone name for your domain (hosted in Azure)')
param dnsZoneName string = 'lab.imav8n.com'

@description('Host name for the NATS lab (will become <host>.<zone>)')
param natsHostName string = 'nats'

@description('Key Vault name that holds the PFX certificate')
param keyVaultName string = 'kv-natslab'

@description('Secret name of the PFX certificate in Key Vault')
param pfxSecretName string = 'natslab-tls'

@description('NATS node count (fixed at 4 for this lab)')
param natsNodeCount int = 4

@description('Client node count')
param clientNodeCount int = 2

var vnetName = 'natslab-vnet'
var subnetName = 'natslab-subnet'
var nsgName = 'natslab-nsg'
var lbName = 'natslab-lb'
var publicIpName = 'natslab-lb-pip'
var dnsZoneResourceName = dnsZoneName
var natsVmPrefix = 'nats-node'
var clientVmPrefix = 'nats-client'
var addressSpace = '10.0.0.0/16'
var subnetPrefix = '10.0.1.0/24'
var lbFrontendName = 'natsFrontend'
var lbBackendPoolName = 'natsBackendPool'
var lbProbeName = 'natsProbe'
var lbRuleName = 'natsTlsRule'

/* -------------------------
   Networking
-------------------------- */

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-NATS-TLS-From-Internet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '4222'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-NATS-Cluster-Ports-From-Internet'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: [
            '6222'
            '8222'
          ]
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-SSH-From-Internet'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-VNet-Inbound'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressSpace
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

/* -------------------------
   Public IP + Load Balancer
-------------------------- */

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource lb 'Microsoft.Network/loadBalancers@2023-05-01' = {
  name: lbName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: lbFrontendName
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: lbBackendPoolName
      }
    ]
    probes: [
      {
        name: lbProbeName
        properties: {
          protocol: 'Tcp'
          port: 4222
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: lbRuleName
        properties: {
          protocol: 'Tcp'
          frontendPort: 4222
          backendPort: 4222
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
          loadDistribution: 'Default'
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, lbFrontendName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, lbBackendPoolName)
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, lbProbeName)
          }
        }
      }
    ]
  }
}

/* -------------------------
   DNS Zone + A record
-------------------------- */

resource dnsZone 'Microsoft.Network/dnsZones@2023-07-01' existing = {
  name: dnsZoneResourceName
}

resource natsARecord 'Microsoft.Network/dnsZones/A@2023-07-01' = {
  name: '${dnsZone.name}/${natsHostName}'
  properties: {
    TTL: 60
    ARecords: [
      {
        ipv4Address: publicIp.properties.ipAddress
      }
    ]
  }
}

/* -------------------------
   NATS Node Public IPs (for SSH management from bphost)
-------------------------- */

resource natsPublicIp 'Microsoft.Network/publicIPAddresses@2023-05-01' = [for i in range(0, natsNodeCount): {
  name: '${natsVmPrefix}${i}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}]

/* -------------------------
   NATS Node NICs & VMs
-------------------------- */

resource natsNic 'Microsoft.Network/networkInterfaces@2023-05-01' = [for i in range(0, natsNodeCount): {
  name: '${natsVmPrefix}${i}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: natsPublicIp[i].id
          }
          loadBalancerBackendAddressPools: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, lbBackendPoolName)
            }
          ]
        }
      }
    ]
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}]

resource natsVm 'Microsoft.Compute/virtualMachines@2023-09-01' = [for i in range(0, natsNodeCount): {
  name: '${natsVmPrefix}${i}'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: '${natsVmPrefix}${i}'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 30
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: natsNic[i].id
        }
      ]
    }
  }
}]

/* -------------------------
   Client NICs & VMs
-------------------------- */

resource clientPublicIp 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: '${clientVmPrefix}0-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource clientNic 'Microsoft.Network/networkInterfaces@2023-05-01' = [for i in range(0, clientNodeCount): {
  name: '${clientVmPrefix}${i}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          publicIPAddress: i == 0 ? {
            id: clientPublicIp.id
          } : null
        }
      }
    ]
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}]

resource clientVm 'Microsoft.Compute/virtualMachines@2023-09-01' = [for i in range(0, clientNodeCount): {
  name: '${clientVmPrefix}${i}'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: '${clientVmPrefix}${i}'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 30
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: clientNic[i].id
        }
      ]
    }
  }
}]

/* -------------------------
   Outputs (consumed by ansible/inventory.yml.j2 via scripts/deploy.sh)
-------------------------- */

output natsHostName string = natsHostName
output dnsZoneName string = dnsZoneName
output natsPublicFqdn string = '${natsHostName}.${dnsZoneName}'
output loadBalancerPublicIp string = publicIp.properties.ipAddress
output adminUsername string = adminUsername
output keyVaultName string = keyVaultName
output pfxSecretName string = pfxSecretName

output natsNodeNames array = [for i in range(0, natsNodeCount): '${natsVmPrefix}${i}']
output natsNodePublicIps array = [for i in range(0, natsNodeCount): natsPublicIp[i].properties.ipAddress]
output natsNodePrivateIps array = [for i in range(0, natsNodeCount): natsNic[i].properties.ipConfigurations[0].properties.privateIPAddress]

output clientNames array = [for i in range(0, clientNodeCount): '${clientVmPrefix}${i}']
output clientPrivateIps array = [for i in range(0, clientNodeCount): clientNic[i].properties.ipConfigurations[0].properties.privateIPAddress]
output client0PublicIp string = clientPublicIp.properties.ipAddress
