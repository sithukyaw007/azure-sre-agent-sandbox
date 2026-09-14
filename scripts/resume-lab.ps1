<#
.SYNOPSIS
    Resumes the Azure SRE Agent Demo Lab after suspend-lab.ps1.

.DESCRIPTION
    Restores the lab to a demo-ready state in roughly 10 minutes:

      1. Starts the AKS cluster and waits for nodes and pods to become Ready.
      2. Redeploys the Bicep template, which recreates whatever was deleted
         (SRE Agent, Managed Grafana). The deployment is idempotent - resources
         that already exist are left alone.
      3. Reloads the SRE Agent configuration: knowledge base, custom agents,
         connectors, scheduled tasks, and the incident response plan.
      4. Reprovisions the Grafana dashboard.
      5. Re-enables the scheduled-query alert rules.
      6. Verifies and reports the new endpoint URLs.

    Step order matters. AKS is started first because the Bicep redeploy updates the
    AKS resource, and ARM updates against a stopped cluster can fail or force an
    implicit start.

    Note the LoadBalancer public IPs are reassigned on restart, so the store front
    URL will differ from the previous session. The final summary prints the new one.

.PARAMETER ResourceGroupName
    Resource group containing the lab.

.PARAMETER WorkloadName
    Workload name used when the lab was deployed. Default: srelab

.PARAMETER Location
    Azure region of the lab. Inferred from the resource group when omitted.

.PARAMETER SubscriptionId
    Subscription containing the lab. Strongly recommended: every Azure CLI call is
    pinned to this value, so the script is unaffected if the active CLI subscription
    is changed elsewhere. Defaults to the current CLI subscription.

.PARAMETER SkipInfrastructure
    Skip the Bicep redeploy. Use when only the cluster was stopped and neither the
    SRE Agent nor Grafana was deleted.

.PARAMETER SkipSreAgentConfig
    Skip reloading the SRE Agent knowledge base, agents, and connectors.

.PARAMETER SkipAlerts
    Leave the alert rules disabled.

.EXAMPLE
    .\resume-lab.ps1 -ResourceGroupName rg-srelab-swedencentral

.EXAMPLE
    # Cluster was stopped but nothing was deleted - just bring compute back
    .\resume-lab.ps1 -ResourceGroupName rg-srelab-swedencentral -SkipInfrastructure
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter()]
    [ValidateLength(3, 10)]
    [string]$WorkloadName = 'srelab',

    [Parameter()]
    [ValidateSet('eastus2', 'swedencentral', 'australiaeast', 'southeastasia')]
    [string]$Location,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [switch]$SkipInfrastructure,

    [Parameter()]
    [switch]$SkipSreAgentConfig,

    [Parameter()]
    [switch]$SkipAlerts
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
$alertNames = @(
    "alert-$WorkloadName-pod-restarts",
    "alert-$WorkloadName-http-5xx",
    "alert-$WorkloadName-pod-failures",
    "alert-$WorkloadName-crashloop-oom"
)
$bicepFile = Join-Path $PSScriptRoot '..' 'infra' 'bicep' 'main.bicep'
$bicepParams = Join-Path $PSScriptRoot '..' 'infra' 'bicep' 'main.bicepparam'

$failures = [System.Collections.Generic.List[string]]::new()

# Child scripts (configure-sre-agent.ps1, configure-grafana.ps1) do not accept a
# subscription parameter, so they inherit the ambient Azure CLI subscription. If that
# points elsewhere - easy to do when working across projects - they fail with
# ResourceGroupNotFound even though the resources exist. Switch the CLI context for
# the duration of this run and restore the original on exit.
$originalSubscription = az account show --query id --output tsv 2>$null
$subscriptionSwitched = $false
if ($originalSubscription -ne $SubscriptionId) {
    az account set --subscription $SubscriptionId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not set the active Azure CLI subscription to $SubscriptionId."
    }
    $subscriptionSwitched = $true
}

function Restore-OriginalSubscription {
    if ($subscriptionSwitched -and -not [string]::IsNullOrWhiteSpace($originalSubscription)) {
        az account set --subscription $originalSubscription 2>&1 | Out-Null
        $script:subscriptionSwitched = $false
    }
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n$Message" -ForegroundColor Yellow
}

# Child scripts can emit non-terminating errors that would fire a trap and restore the
# subscription mid-run, breaking every later step. Instead, re-assert the context
# immediately before each child invocation and restore only at the real exit points.
function Assert-LabSubscription {
    $current = az account show --query id --output tsv 2>$null
    if ($current -ne $SubscriptionId) {
        az account set --subscription $SubscriptionId 2>&1 | Out-Null
    }
}

Write-Host @"

+------------------------------------------------------------------------------+
|                    Azure SRE Agent Demo Lab - RESUME                         |
|                                                                              |
|  Restores compute, recreates deleted services, and reloads agent config.     |
|  Takes roughly 10 minutes.                                                   |
+------------------------------------------------------------------------------+

"@ -ForegroundColor Cyan

$subName = az account show @subArgs --query name --output tsv 2>$null
Write-Host "  Subscription:   $subName ($SubscriptionId)" -ForegroundColor White
Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor White

$rgLocation = az group show --name $ResourceGroupName @subArgs --query location --output tsv 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($rgLocation)) {
    throw "Resource group '$ResourceGroupName' was not found in subscription $SubscriptionId."
}
if (-not $Location) { $Location = $rgLocation }
Write-Host "  Location:       $Location" -ForegroundColor White

# ---------------------------------------------------------------------------
# 1. Start AKS  (must precede the Bicep redeploy)
# ---------------------------------------------------------------------------
Write-Step '[1/6] Starting AKS cluster...'

$powerState = az aks show --resource-group $ResourceGroupName --name $aksName @subArgs `
    --query 'powerState.code' --output tsv 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($powerState)) {
    throw "AKS cluster '$aksName' was not found. If the lab was fully destroyed, run deploy.ps1 instead."
}

if ($powerState -eq 'Running') {
    Write-Host '  Already running.' -ForegroundColor Gray
}
elseif ($PSCmdlet.ShouldProcess($aksName, 'Start AKS cluster')) {
    Write-Host '  Starting (this takes 3-5 minutes)...' -ForegroundColor Gray
    az aks start --resource-group $ResourceGroupName --name $aksName @subArgs --output none 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'AKS start failed. Resolve this before continuing - later steps depend on a running cluster.'
    }
    Write-Host '  Started.' -ForegroundColor Green
}

if (-not $WhatIfPreference) {
    az aks get-credentials --resource-group $ResourceGroupName --name $aksName @subArgs `
        --overwrite-existing --output none 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host '  kubectl context updated.' -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 2. Recreate deleted infrastructure
# ---------------------------------------------------------------------------
Write-Step '[2/6] Recreating deleted resources (SRE Agent, Grafana)...'

if ($SkipInfrastructure) {
    Write-Host '  Skipped by request.' -ForegroundColor Gray
}
else {
    $agentCount = az resource list --resource-group $ResourceGroupName @subArgs `
        --query "[?type=='Microsoft.App/agents'] | length(@)" --output tsv 2>$null
    $grafanaCount = az resource list --resource-group $ResourceGroupName @subArgs `
        --query "[?type=='Microsoft.Dashboard/grafana'] | length(@)" --output tsv 2>$null

    if ($agentCount -eq '1' -and $grafanaCount -eq '1') {
        Write-Host '  SRE Agent and Grafana already present - skipping redeploy.' -ForegroundColor Gray
    }
    elseif ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Redeploy Bicep template')) {
        Write-Host '  Deploying (this takes 3-5 minutes)...' -ForegroundColor Gray
        $deploymentName = "sre-resume-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        az deployment sub create `
            --location $Location `
            --template-file $bicepFile `
            --parameters $bicepParams location=$Location workloadName=$WorkloadName deploySreAgent=true `
            --name $deploymentName `
            @subArgs `
            --only-show-errors --output none 2>&1 | Out-Null

        if ($LASTEXITCODE -ne 0) {
            $failures.Add('Bicep redeploy failed')
            Write-Host '  Redeploy failed. Inspect with:' -ForegroundColor Red
            Write-Host "    az deployment sub show --name $deploymentName --subscription $SubscriptionId" -ForegroundColor Gray
        }
        else {
            Write-Host '  Resources recreated.' -ForegroundColor Green

            # A freshly created agent needs its RBAC to propagate before the
            # dataplane accepts writes, and Grafana reports provisioningState
            # 'None' until it finishes. Without this wait, step 3 fails scheduled
            # tasks with HTTP 403 and step 4 cannot find the workspace.
            Write-Host '  Waiting for resources to become ready...' -ForegroundColor Gray
            $deadline = (Get-Date).AddMinutes(5)
            $grafanaReady = $false
            while ((Get-Date) -lt $deadline) {
                $state = az resource list --resource-group $ResourceGroupName @subArgs `
                    --resource-type 'Microsoft.Dashboard/grafana' `
                    --query '[0].provisioningState' --output tsv 2>$null
                if ($state -eq 'Succeeded') { $grafanaReady = $true; break }
                Start-Sleep -Seconds 15
            }
            if ($grafanaReady) {
                Write-Host '  Grafana workspace ready.' -ForegroundColor Green
            }
            else {
                Write-Host '  Grafana still provisioning; dashboard step may need a rerun.' -ForegroundColor Yellow
            }

            # Allow agent role assignments to replicate before dataplane calls.
            Start-Sleep -Seconds 60
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Reload SRE Agent configuration
# ---------------------------------------------------------------------------
Write-Step '[3/6] Reloading SRE Agent configuration...'

$agentPresent = (az resource list --resource-group $ResourceGroupName @subArgs `
        --query "[?type=='Microsoft.App/agents'] | length(@)" --output tsv 2>$null) -eq '1'

if ($SkipSreAgentConfig) {
    Write-Host '  Skipped by request.' -ForegroundColor Gray
}
elseif (-not $agentPresent) {
    Write-Host '  No SRE Agent present - skipping configuration.' -ForegroundColor Gray
}
elseif ($PSCmdlet.ShouldProcess('SRE Agent', 'Reload configuration')) {
    $configureScript = Join-Path $PSScriptRoot 'configure-sre-agent.ps1'
    if (-not (Test-Path $configureScript)) {
        $failures.Add('configure-sre-agent.ps1 not found')
        Write-Host '  configure-sre-agent.ps1 not found.' -ForegroundColor Red
    }
    else {
        # Dataplane writes can return HTTP 403 while role assignments replicate on a
        # freshly created agent. Retry once after a pause before reporting failure.
        Assert-LabSubscription
        & $configureScript -ResourceGroupName $ResourceGroupName
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  Some configuration steps failed (often RBAC propagation). Retrying in 90s...' -ForegroundColor Yellow
            Start-Sleep -Seconds 90
            Assert-LabSubscription
            & $configureScript -ResourceGroupName $ResourceGroupName
        }
        if ($LASTEXITCODE -ne 0) {
            $failures.Add('SRE Agent configuration failed')
            Write-Host '  Configuration returned a non-zero exit code.' -ForegroundColor Red
        }
        else {
            Write-Host '  Knowledge base, agents, connectors, and tasks restored.' -ForegroundColor Green
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Grafana dashboard
# ---------------------------------------------------------------------------
Write-Step '[4/6] Provisioning Grafana dashboard...'

$grafanaPresent = (az resource list --resource-group $ResourceGroupName @subArgs `
        --query "[?type=='Microsoft.Dashboard/grafana'] | length(@)" --output tsv 2>$null) -eq '1'

if (-not $grafanaPresent) {
    Write-Host '  No Grafana workspace present - skipping.' -ForegroundColor Gray
}
elseif ($PSCmdlet.ShouldProcess('Grafana', 'Provision dashboard')) {
    # A recreated Grafana workspace has no data-plane role assignments, so the
    # dashboard API returns HTTP 401. Ensure the current user holds Grafana Admin.
    $grafanaId = az resource list --resource-group $ResourceGroupName @subArgs `
        --resource-type 'Microsoft.Dashboard/grafana' --query '[0].id' --output tsv 2>$null
    $userObjectId = az ad signed-in-user show --query id --output tsv 2>$null
    if (-not [string]::IsNullOrWhiteSpace($grafanaId) -and -not [string]::IsNullOrWhiteSpace($userObjectId)) {
        $existing = az role assignment list --scope $grafanaId --assignee $userObjectId @subArgs `
            --query "[?roleDefinitionName=='Grafana Admin'] | length(@)" --output tsv 2>$null
        if ($existing -ne '1') {
            Write-Host '  Granting Grafana Admin for data-plane access...' -ForegroundColor Gray
            az role assignment create --assignee $userObjectId --role 'Grafana Admin' `
                --scope $grafanaId @subArgs --output none 2>&1 | Out-Null
            # Role assignments need a moment to reach the data plane.
            Start-Sleep -Seconds 45
        }
    }

    $grafanaScript = Join-Path $PSScriptRoot 'configure-grafana.ps1'
    if (-not (Test-Path $grafanaScript)) {
        $failures.Add('configure-grafana.ps1 not found')
        Write-Host '  configure-grafana.ps1 not found.' -ForegroundColor Red
    }
    else {
        Assert-LabSubscription
        & $grafanaScript -ResourceGroupName $ResourceGroupName
        if ($LASTEXITCODE -ne 0) {
            $failures.Add('Grafana dashboard provisioning failed')
            Write-Host '  Dashboard provisioning failed.' -ForegroundColor Red
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Re-enable alert rules
# ---------------------------------------------------------------------------
Write-Step '[5/6] Re-enabling alert rules...'

if ($SkipAlerts) {
    Write-Host '  Skipped by request.' -ForegroundColor Gray
}
else {
    foreach ($alert in $alertNames) {
        $enabled = az monitor scheduled-query show --resource-group $ResourceGroupName --name $alert @subArgs `
            --query 'enabled' --output tsv 2>$null

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($enabled)) {
            Write-Host "  $alert - not found, skipping." -ForegroundColor Gray
            continue
        }
        if ($enabled -eq 'true') {
            Write-Host "  $alert - already enabled." -ForegroundColor Gray
            continue
        }
        if ($PSCmdlet.ShouldProcess($alert, 'Enable alert rule')) {
            # The flag is --disabled false. '--enabled true' is not valid for this
            # command and exits by printing help rather than raising an error.
            az monitor scheduled-query update --resource-group $ResourceGroupName --name $alert @subArgs `
                --disabled false --output none 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $failures.Add("Alert '$alert' could not be enabled")
                Write-Host "  $alert - failed to enable." -ForegroundColor Red
            }
            else {
                Write-Host "  $alert - enabled." -ForegroundColor Green
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 6. Wait for the application and report endpoints
# ---------------------------------------------------------------------------
Write-Step '[6/6] Waiting for the application...'

$storeUrl = $null
if (-not $WhatIfPreference) {
    $deployments = kubectl get deployment -n pets -o jsonpath='{.items[*].metadata.name}' 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($deployments)) {
        foreach ($d in ($deployments -split '\s+' | Where-Object { $_ })) {
            kubectl rollout status "deployment/$d" -n pets --timeout=300s 2>&1 | Out-Null
        }
    }

    $pods = kubectl get pods -n pets --no-headers 2>$null
    if ($LASTEXITCODE -eq 0 -and $pods) {
        $total = ($pods | Measure-Object).Count
        $running = ($pods | Where-Object { $_ -match '\sRunning\s' } | Measure-Object).Count
        $color = if ($running -eq $total) { 'Green' } else { 'Yellow' }
        Write-Host "  Pods: $running/$total Running" -ForegroundColor $color
        if ($running -ne $total) {
            Write-Host '  If pods remain unready, run: kubectl rollout restart deployment -n pets' -ForegroundColor Gray
        }
    }

    # The LoadBalancer IP is reassigned on restart, so always re-read it.
    for ($i = 0; $i -lt 24; $i++) {
        $ip = kubectl get svc store-front -n pets -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
        if (-not [string]::IsNullOrWhiteSpace($ip)) { $storeUrl = "http://$ip"; break }
        Start-Sleep -Seconds 5
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host '  RESUME SUMMARY' -ForegroundColor Cyan
Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan

if ($WhatIfPreference) {
    Write-Host "`n  What-if mode: no changes were made.`n" -ForegroundColor Yellow
    Restore-OriginalSubscription
    exit 0
}

if ($storeUrl) {
    Write-Host "`n  Store front:  $storeUrl" -ForegroundColor Green
    Write-Host '  NOTE: this IP changes on every stop/start. Update your runbook.' -ForegroundColor Yellow
}
else {
    Write-Host "`n  Store front:  pending - check with: kubectl get svc store-front -n pets" -ForegroundColor Yellow
}

$grafanaEndpoint = az resource list --resource-group $ResourceGroupName @subArgs `
    --resource-type 'Microsoft.Dashboard/grafana' --query '[0].id' --output tsv 2>$null
if (-not [string]::IsNullOrWhiteSpace($grafanaEndpoint)) {
    $ep = az resource show --ids $grafanaEndpoint @subArgs --query 'properties.endpoint' --output tsv 2>$null
    if ($ep) { Write-Host "  Grafana:      $ep/d/sre-aks-overview" -ForegroundColor Green }
}
if ($agentPresent) {
    Write-Host '  SRE Agent:    https://sre.azure.com' -ForegroundColor Green
}

if ($failures.Count -gt 0) {
    Write-Host "`n  Failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    Write-Host "`nResume completed with $($failures.Count) failure(s)." -ForegroundColor Red
    Restore-OriginalSubscription
    exit 1
}

Write-Host "`n  Reminders:" -ForegroundColor White
Write-Host '    - Container Insights telemetry takes ~5 minutes to repopulate.' -ForegroundColor Gray
Write-Host '    - Re-authorize the Outlook connector in the portal for email delivery.' -ForegroundColor Gray
Write-Host "`n  Verify with:" -ForegroundColor White
Write-Host "    ./scripts/validate-deployment.ps1 -ResourceGroupName $ResourceGroupName" -ForegroundColor Cyan
Write-Host "`n  Suspend again with:" -ForegroundColor White
Write-Host "    ./scripts/suspend-lab.ps1 -ResourceGroupName $ResourceGroupName" -ForegroundColor Cyan
Write-Host ''

Restore-OriginalSubscription
