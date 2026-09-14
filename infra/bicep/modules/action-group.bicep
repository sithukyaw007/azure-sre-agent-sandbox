// =============================================================================
// Action Group Module
// =============================================================================
// Deploys a default Azure Monitor Action Group for incident routing.
// Supports webhook/Logic App callback URL integration.
// =============================================================================

@description('Action Group name')
param name string

@description('Tags to apply to resources')
param tags object

@description('Action Group short name (max 12 chars)')
@maxLength(12)
param shortName string = 'srelabops'

@secure()
@description('Optional webhook/Logic App callback URL for incident routing')
param webhookServiceUri string = ''

var hasWebhookReceiver = !empty(webhookServiceUri)

// Action Groups are a global resource type. They are only offered in a fixed set
// of regions (plus 'global'), so pinning to 'global' keeps this module valid in
// every deployment region, including ones like southeastasia.
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: name
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    groupShortName: shortName
    webhookReceivers: hasWebhookReceiver
      ? [
          {
            name: 'incident-webhook'
            serviceUri: webhookServiceUri
            useCommonAlertSchema: true
          }
        ]
      : []
  }
}

output actionGroupId string = actionGroup.id
output hasWebhookReceiver bool = hasWebhookReceiver
