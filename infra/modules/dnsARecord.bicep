@description('Parent DNS zone name')
param dnsZoneName string

@description('A-record short name (the host part)')
param recordName string

@description('IPv4 address to point the A record at')
param ipv4Address string

@description('TTL in seconds')
param ttl int = 60

resource dnsZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: dnsZoneName
}

resource aRecord 'Microsoft.Network/dnsZones/A@2018-05-01' = {
  parent: dnsZone
  name: recordName
  properties: {
    TTL: ttl
    ARecords: [
      {
        ipv4Address: ipv4Address
      }
    ]
  }
}
