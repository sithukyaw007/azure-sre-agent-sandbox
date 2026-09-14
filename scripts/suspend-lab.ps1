<#
.SYNOPSIS
    Suspends the Azure SRE Agent Demo Lab to minimize cost between demos.

.DESCRIPTION
    Stops or deletes the cost-consuming resources while preserving the AKS cluster,
    the deployed application, and all telemetry history. Cost drops from roughly
    $32-38/day to under $1/day.

    Actions performed:
      1. Stops the AKS cluster (az aks stop). Node scale sets drop to 0 capacity.
         Azure does not bill compute for a stopped cluster - nodes or control plane.
         All Kubernetes objects, the pets application, and PVC data are preserved.
      2. Deletes the SRE Agent. Per Microsoft's billing documentation, always-on flow
         bills at 4 AAUs per agent-hour and continues from agent creation until the
         agent is *deleted* - stopping an agent halts only active flow. Deletion also
         stops the scheduled tasks, which would otherwise keep firing against a
         stopped cluster. Configuration is reproducible from sre-config/ via
         configure-sre-agent.ps1.
         See https://learn.microsoft.com/azure/sre-agent/pricing-billing
      3. Deletes Managed Grafana. It has no pause state and bills continuously.
         The dashboard is reproducible via configure-grafana.ps1.
      4. Disables the scheduled-query alert rules. Their one-minute evaluation
         frequency bills per run and they would query a stopped cluster.

    Everything else (Log Analytics, App Insights, ACR, Key Vault, VNet, action group,
    data collection rules, Azure Monitor workspace) is retained. Idle cost is
    negligible, and keeping the Key Vault live avoids soft-delete name conflicts on
    the next deployment.

    Restore with resume-lab.ps1.

.PARAMETER ResourceGroupName
    Resource group containing the lab.

.PARAMETER WorkloadName
    Workload name used when the lab was deployed. Default: srelab

.PARAMETER SubscriptionId
    Subscription containing the lab. Strongly recommended: every Azure CLI call is
    pinned to this value, so the script is unaffected if the active CLI subscription
    is changed elsewhere. Defaults to the current CLI subscription.

.PARAMETER KeepSreAgent
    Keep the SRE Agent. Note this continues always-on billing (~$10-13/day).

.PARAMETER KeepGrafana
    Keep Managed Grafana (~$2.50/day).

.PARAMETER KeepAlerts
    Leave the scheduled-query alert rules enabled.

.PARAMETER WhatIf
    Show what would change without making changes.

.EXAMPLE
    .\suspend-lab.ps1 -ResourceGroupName rg-srelab-swedencentral

.EXAMPLE
    .\suspend-lab.ps1 -ResourceGroupName rg-srelab-swedencentral -WhatIf

.EXAMPLE
    # Stop compute only, keep the agent available for portal exploration
    .\suspend-lab.ps1 -ResourceGroupName rg-srelab-swedencentral -KeepSreAgent
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter()]
    [ValidateLength(3, 10)]
    [string]$WorkloadName = 'srelab',

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [switch]$KeepSreAgent,

    [Parameter()]
    [switch]$KeepGrafana,

    [Parameter()]
    [switch]$KeepAlerts
)

$ErrorActionPreference = 'Stop'

# Every az call is pinned to an explicit subscription. Without this, changing the
# active CLI subscription in another shell makes healthy resources report
# ResourceGroupNotFound mid-run.
if (-not $SubscriptionId) {
    $SubscriptionId = az account show --query id --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        throw 'Could not resolve a subscription. Run "az login", or pass -SubscriptionId.'
    }
}
$subArgs = @('--subscription', $SubscriptionId)

$aksName = "aks-$WorkloadName"
$sreAgentName = "sre-$WorkloadName"
$sreAgentApiVersion = '2025-05-01-preview'
$alertNames = @(
    "alert-$WorkloadName-pod-restarts",
    "alert-$WorkloadName-http-5xx",
    "alert-$WorkloadName-pod-failures",
    "alert-$WorkloadName-crashloop-oom"
)

$actions = [System.Collections.Generic.List[string]]::new()
$skipped = [System.Collections.Generic.List[string]]::new()
$failures = [System.Collections.Generic.List[string]]::new()

function Write-Step {
    param([string]$Message)
    Write-Host "`n$Message" -ForegroundColor Yellow
}

Write-Host @"

+------------------------------------------------------------------------------+
|                   Azure SRE Agent Demo Lab - SUSPEND                         |
|                                                                              |
|  Stops billable compute and deletes services that cannot be paused.          |
|  The cluster, application state, and telemetry history are preserved.        |
+------------------------------------------------------------------------------+

"@ -ForegroundColor Cyan

$subName = az account show @subArgs --query name --output tsv 2>$null
Write-Host "  Subscription:   $subName ($SubscriptionId)" -ForegroundColor White
Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor White

$null = az group show --name $ResourceGroupName @subArgs --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Resource group '$ResourceGroupName' was not found in subscription $SubscriptionId."
}

# ---------------------------------------------------------------------------
# 1. AKS - stop
# ---------------------------------------------------------------------------
Write-Step '[1/4] Stopping AKS cluster...'

$powerState = az aks show --resource-group $ResourceGroupName --name $aksName @subArgs `
    --query 'powerState.code' --output tsv 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($powerState)) {
    $skipped.Add("AKS '$aksName' not found")
    Write-Host "  AKS cluster '$aksName' not found - skipping." -ForegroundColor Gray
}
elseif ($powerState -eq 'Stopped') {
    $skipped.Add('AKS already stopped')
    Write-Host '  Already stopped.' -ForegroundColor Gray
}
elseif ($PSCmdlet.ShouldProcess($aksName, 'Stop AKS cluster')) {
    Write-Host '  Stopping (this takes 3-5 minutes)...' -ForegroundColor Gray
    az aks stop --resource-group $ResourceGroupName --name $aksName @subArgs --output none 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $failures.Add('AKS stop failed')
        Write-Host '  AKS stop failed.' -ForegroundColor Red
    }
    else {
        $actions.Add('AKS stopped')
        Write-Host '  Stopped. Node scale sets are at 0 capacity.' -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 2. SRE Agent - delete
# ---------------------------------------------------------------------------
Write-Step '[2/4] Removing SRE Agent...'

if ($KeepSreAgent) {
    $skipped.Add('SRE Agent kept (-KeepSreAgent)')
    Write-Host '  Kept by request. Always-on billing continues (~$10-13/day).' -ForegroundColor Yellow
}
else {
    $agentId = az resource list --resource-group $ResourceGroupName @subArgs `
        --query "[?type=='Microsoft.App/agents' && name=='$sreAgentName'].id | [0]" --output tsv 2>$null

    if ([string]::IsNullOrWhiteSpace($agentId)) {
        $skipped.Add('SRE Agent not present')
        Write-Host '  Not present - skipping.' -ForegroundColor Gray
    }
    elseif ($PSCmdlet.ShouldProcess($sreAgentName, 'Delete SRE Agent')) {
        az resource delete --ids $agentId --api-version $sreAgentApiVersion @subArgs --output none 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $failures.Add('SRE Agent deletion failed')
            Write-Host '  Deletion failed.' -ForegroundColor Red
        }
        else {
            $actions.Add('SRE Agent deleted')
            Write-Host '  Deleted. Rebuild with configure-sre-agent.ps1 after redeploy.' -ForegroundColor Green
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Managed Grafana - delete
# ---------------------------------------------------------------------------
Write-Step '[3/4] Removing Managed Grafana...'

if ($KeepGrafana) {
    $skipped.Add('Grafana kept (-KeepGrafana)')
    Write-Host '  Kept by request (~$2.50/day).' -ForegroundColor Yellow
}
else {
    $grafanaName = az resource list --resource-group $ResourceGroupName @subArgs `
        --query "[?type=='Microsoft.Dashboard/grafana'].name | [0]" --output tsv 2>$null

    if ([string]::IsNullOrWhiteSpace($grafanaName)) {
        $skipped.Add('Grafana not present')
        Write-Host '  Not present - skipping.' -ForegroundColor Gray
    }
    elseif ($PSCmdlet.ShouldProcess($grafanaName, 'Delete Managed Grafana')) {
        Write-Host "  Deleting '$grafanaName' (this takes several minutes)..." -ForegroundColor Gray
        az grafana delete --resource-group $ResourceGroupName --name $grafanaName @subArgs --yes 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $failures.Add('Grafana deletion failed')
            Write-Host '  Deletion failed.' -ForegroundColor Red
        }
        else {
            $actions.Add('Grafana deleted')
            Write-Host '  Deleted. Dashboard is restored by configure-grafana.ps1.' -ForegroundColor Green
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Alert rules - disable
# ---------------------------------------------------------------------------
Write-Step '[4/4] Disabling alert rules...'

if ($KeepAlerts) {
    $skipped.Add('Alerts kept enabled (-KeepAlerts)')
    Write-Host '  Left enabled by request.' -ForegroundColor Yellow
}
else {
    foreach ($alert in $alertNames) {
        $enabled = az monitor scheduled-query show --resource-group $ResourceGroupName --name $alert @subArgs `
            --query 'enabled' --output tsv 2>$null

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($enabled)) {
            Write-Host "  $alert - not found, skipping." -ForegroundColor Gray
            continue
        }
        if ($enabled -eq 'false') {
            Write-Host "  $alert - already disabled." -ForegroundColor Gray
            continue
        }
        if ($PSCmdlet.ShouldProcess($alert, 'Disable alert rule')) {
            # The flag is --disabled true. '--enabled false' is not valid for this
            # command and exits by printing help rather than raising an error.
            az monitor scheduled-query update --resource-group $ResourceGroupName --name $alert @subArgs `
                --disabled true --output none 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $failures.Add("Alert '$alert' could not be disabled")
                Write-Host "  $alert - failed to disable." -ForegroundColor Red
            }
            else {
                $actions.Add("Alert '$alert' disabled")
                Write-Host "  $alert - disabled." -ForegroundColor Green
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host '  SUSPEND SUMMARY' -ForegroundColor Cyan
Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan

if ($WhatIfPreference) {
    Write-Host "`n  What-if mode: no changes were made." -ForegroundColor Yellow
}

if ($actions.Count -gt 0) {
    Write-Host "`n  Changed:" -ForegroundColor Green
    $actions | ForEach-Object { Write-Host "    - $_" -ForegroundColor White }
}
if ($skipped.Count -gt 0) {
    Write-Host "`n  Skipped:" -ForegroundColor Gray
    $skipped | ForEach-Object { Write-Host "    - $_" -ForegroundColor Gray }
}
if ($failures.Count -gt 0) {
    Write-Host "`n  Failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    Write-Host "`nSuspend completed with $($failures.Count) failure(s)." -ForegroundColor Red
    exit 1
}

if (-not $WhatIfPreference) {
    Write-Host "`n  Remaining cost is roughly `$0.60/day:" -ForegroundColor White
    Write-Host '    - Public IPs held by the stopped load balancer' -ForegroundColor Gray
    Write-Host '    - Container Registry (Basic)' -ForegroundColor Gray
    Write-Host '    - MongoDB PVC managed disk (retains demo data)' -ForegroundColor Gray
    Write-Host '    - Log Analytics retention, tapering as data ages out' -ForegroundColor Gray
    Write-Host "`n  Resume with:" -ForegroundColor White
    Write-Host "    pwsh ./scripts/resume-lab.ps1 -ResourceGroupName $ResourceGroupName" -ForegroundColor Cyan
    Write-Host "`n  Tear down completely with:" -ForegroundColor White
    Write-Host "    pwsh ./scripts/destroy.ps1 -ResourceGroupName $ResourceGroupName" -ForegroundColor Cyan
}

Write-Host ''
