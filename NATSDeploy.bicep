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
   Custom Script Extension for NATS nodes
-------------------------- */

resource natsExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [for i in range(0, natsNodeCount): {
  // FIX: use parent + plain name instead of slash-concatenation in a loop
  parent: natsVm[i]
  name: 'natsInstall'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: []
      // FIX: commandToExecute is a single valid Bicep string.
      //      Shell single-quoted. jq filter uses --arg to avoid quoting the pattern.
      //      Config files written via base64-encoded blobs to avoid all shell quoting.
      commandToExecute: 'bash -c \'set -e; apt-get update -y; apt-get install -y curl unzip jq openssl ca-certificates apt-transport-https lsb-release gnupg; if ! command -v az >/dev/null 2>&1; then curl -sL https://aka.ms/InstallAzureCLIDeb | bash; fi; az login --identity >/dev/null; mkdir -p /tmp/natscert; cd /tmp/natscert; az keyvault secret download --vault-name ${keyVaultName} --name ${pfxSecretName} --file cert.pfx; openssl pkcs12 -in cert.pfx -out cert.pem -clcerts -nokeys -nodes -passin pass:; openssl pkcs12 -in cert.pfx -out key.pem -nocerts -nodes -passin pass:; mkdir -p /etc/nats/certs; cp cert.pem /etc/nats/certs/cert.pem; cp key.pem /etc/nats/certs/key.pem; chmod 600 /etc/nats/certs/key.pem; chmod 644 /etc/nats/certs/cert.pem; cd /tmp; NATS_DL=$(curl -s https://api.github.com/repos/nats-io/nats-server/releases/latest | jq -r --arg p linux-amd64.zip \'.assets[] | select(.name | test($p)) | .browser_download_url\'); curl -L $NATS_DL -o nats-server.zip; unzip nats-server.zip; mv nats-server /usr/local/bin/nats-server; chmod +x /usr/local/bin/nats-server; mkdir -p /etc/nats; echo cG9ydDogNDIyMgpodHRwX3BvcnQ6IDgyMjIKdGxzIHsKICBjZXJ0X2ZpbGU6IC9ldGMvbmF0cy9jZXJ0cy9jZXJ0LnBlbQogIGtleV9maWxlOiAvZXRjL25hdHMvY2VydHMva2V5LnBlbQp9CmNsdXN0ZXIgewogIG5hbWU6IGxhYgogIHBvcnQ6IDYyMjIKICByb3V0ZXM6IFsKICAgIG5hdHMtcm91dGU6Ly9uYXRzLW5vZGUwOjYyMjIKICAgIG5hdHMtcm91dGU6Ly9uYXRzLW5vZGUxOjYyMjIKICAgIG5hdHMtcm91dGU6Ly9uYXRzLW5vZGUyOjYyMjIKICAgIG5hdHMtcm91dGU6Ly9uYXRzLW5vZGUzOjYyMjIKICBdCiAgdGxzIHsKICAgIGNlcnRfZmlsZTogL2V0Yy9uYXRzL2NlcnRzL2NlcnQucGVtCiAgICBrZXlfZmlsZTogL2V0Yy9uYXRzL2NlcnRzL2tleS5wZW0KICB9Cn0K | base64 -d > /etc/nats/nats.conf; echo W1VuaXRdCkRlc2NyaXB0aW9uPU5BVFMgU2VydmVyCkFmdGVyPW5ldHdvcmsudGFyZ2V0CgpbU2VydmljZV0KRXhlY1N0YXJ0PS91c3IvbG9jYWwvYmluL25hdHMtc2VydmVyIC1jIC9ldGMvbmF0cy9uYXRzLmNvbmYKUmVzdGFydD1vbi1mYWlsdXJlClVzZXI9cm9vdApMaW1pdE5PRklMRT02NTUzNgoKW0luc3RhbGxdCldhbnRlZEJ5PW11bHRpLXVzZXIudGFyZ2V0Cg== | base64 -d > /etc/systemd/system/nats-server.service; systemctl daemon-reload; systemctl enable nats-server; systemctl start nats-server\''
    }
  }
}]

/* -------------------------
   Client NICs & VMs
-------------------------- */

resource clientPublicIp 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: '${clientVmPrefix}-0-pip'
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    publicIPAllocationMethod: 'Dynamic'
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
   Custom Script Extension for client VMs
   (install NATS CLI + test pub/sub)
-------------------------- */

resource clientExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [for i in range(0, clientNodeCount): {
  // FIX: use parent + plain name instead of slash-concatenation in a loop
  parent: clientVm[i]
  name: 'natsCliTest'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: []
      // FIX: commandToExecute is a single valid Bicep string.
      //      FIX: NATS CLI installed via official GitHub release binary, not the
      //           broken pipe-to-bash URL used previously.
      //      FIX: closing quote was mismatched ("' -> "); corrected to '"'
      commandToExecute: 'bash -c \'set -e; apt-get update -y; apt-get install -y curl unzip jq; NATS_CLI_URL=$(curl -s https://api.github.com/repos/nats-io/natscli/releases/latest | jq -r --arg p linux-amd64.zip \'.assets[] | select(.name | test($p)) | .browser_download_url\'); curl -L $NATS_CLI_URL -o nats-cli.zip; unzip nats-cli.zip; mv nats/nats /usr/local/bin/nats; chmod +x /usr/local/bin/nats; NATS_URL=tls://${natsHostName}.${dnsZoneName}:4222; nats sub lab.test --server $NATS_URL > /tmp/sub.txt 2>&1 & SUB_PID=$!; sleep 2; nats pub lab.test hello --server $NATS_URL; sleep 2; kill $SUB_PID 2>/dev/null; grep -q hello /tmp/sub.txt && echo NATS OK || { echo NATS FAIL; exit 1; }\''
    }
  }
}]

/* -------------------------
   Outputs
-------------------------- */

output natsPublicFqdn string = '${natsHostName}.${dnsZoneName}'
output loadBalancerPublicIp string = publicIp.properties.ipAddress
output client0Ssh string = 'ssh ${adminUsername}@${clientPublicIp.properties.ipAddress}'
