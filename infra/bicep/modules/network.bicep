// =============================================================================
// Virtual Network Module
// =============================================================================
// Creates a VNet with subnets for AKS and other services. Network configuration
// is important for SRE Agent - ensure the cluster is not completely isolated
// from inbound traffic to allow SRE Agent access.
// =============================================================================

@description('Name of the virtual network')
param vnetName string

@description('Azure region for deployment')
param location string

@description('Tags to apply to resources')
param tags object

@description('Address prefix for the VNet')
param addressPrefix string = '10.20.0.0/16'

@description('Address prefix for the AKS subnet')
param aksSubnetPrefix string = '10.20.0.0/22'

@description('Address prefix for services subnet (private endpoints)')
param servicesSubnetPrefix string = '10.20.4.0/24'

@description('Address prefix for the SRE Agent VNet-integration subnet. Must be /27 or larger and dedicated to the agent.')
param sreAgentSubnetPrefix string = '10.20.5.0/27'

@description('Create the delegated subnet used by SRE Agent VNet integration')
param deploySreAgentSubnet bool = true

// =============================================================================
// VARIABLES
// =============================================================================

// SRE Agent VNet integration requires a dedicated subnet that is /27 or larger and
// delegated to Microsoft.App/environments. The subnet is appended last so the
// existing snet-aks (index 0) and snet-services (index 1) output indices stay stable.
var baseSubnets = [
  {
    name: 'snet-aks'
    properties: {
      addressPrefix: aksSubnetPrefix
      privateEndpointNetworkPolicies: 'Disabled'
      privateLinkServiceNetworkPolicies: 'Enabled'
    }
  }
  {
    name: 'snet-services'
    properties: {
      addressPrefix: servicesSubnetPrefix
      privateEndpointNetworkPolicies: 'Disabled'
      privateLinkServiceNetworkPolicies: 'Enabled'
    }
  }
]

var sreAgentSubnet = [
  {
    name: 'snet-sre-agent'
    properties: {
      addressPrefix: sreAgentSubnetPrefix
      delegations: [
        {
          name: 'sre-agent-delegation'
          properties: {
            serviceName: 'Microsoft.App/environments'
          }
        }
      ]
      privateEndpointNetworkPolicies: 'Disabled'
      privateLinkServiceNetworkPolicies: 'Enabled'
    }
  }
]

var allSubnets = deploySreAgentSubnet ? concat(baseSubnets, sreAgentSubnet) : baseSubnets

// =============================================================================
// RESOURCES
// =============================================================================

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: allSubnets
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

output vnetId string = vnet.id
output vnetName string = vnet.name
output aksSubnetId string = vnet.properties.subnets[0].id
output servicesSubnetId string = vnet.properties.subnets[1].id
output sreAgentSubnetId string = deploySreAgentSubnet ? vnet.properties.subnets[2].id : ''
output sreAgentSubnetName string = deploySreAgentSubnet ? 'snet-sre-agent' : ''
