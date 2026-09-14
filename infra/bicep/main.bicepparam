// =============================================================================
// Bicep Parameters File - SRE Agent Sandbox
// =============================================================================
// Deploy with: az deployment sub create --location eastus2 --template-file main.bicep
// =============================================================================

using 'main.bicep'

// Core parameters are passed by scripts/deploy.ps1 via --parameters

// Observability stack (Grafana + Prometheus)
param deployObservability = true

// Baseline alert rules
param deployAlerts = true

// Deploy Azure SRE Agent (programmatic deployment now supported)
param deploySreAgent = true

// Default action group for incident routing (add webhook at deploy time)
param deployActionGroup = true

// AKS Configuration - cost-optimized for demo
// NOTE: some subscriptions/offers restrict general-purpose SKUs per region
// (reported as NotAvailableForSubscription). If D2s_v5 is unavailable in your
// target region, the v7 equivalents are also accepted by main.bicep.
param systemNodeVmSize = 'Standard_D2s_v5'
param userNodeVmSize = 'Standard_D2s_v5'
param systemNodeCount = 2
param userNodeCount = 3

// Tags
param tags = {
  workload: 'sre-agent-demo'
  environment: 'sandbox'
  managedBy: 'bicep'
  purpose: 'demonstration'
  costCenter: 'demo-lab'
}
