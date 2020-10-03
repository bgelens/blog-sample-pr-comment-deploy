[CmdletBinding()]
param (
  [Parameter(Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string] $DeploymentId,

  [Parameter(Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string[]] $RequiredSuccessJobs
)

$eventObject = Get-Content -Path $env:GITHUB_EVENT_PATH | ConvertFrom-Json -AsHashtable

$actionHelperModule = Join-Path -Path $PSScriptRoot -ChildPath 'Action_Helpers.psm1' -Resolve -ErrorAction Stop
Import-Module -Name $actionHelperModule -Verbose:$false -DisableNameChecking -Force

$owner, $repo = $env:GITHUB_REPOSITORY -split '\/'
Set-GHContext -Owner $owner -Repository $repo -APIToken $env:GITHUB_TOKEN

# fetch run result
$runResult = Get-GHActionsRunJob -RunId $env:GITHUB_RUN_ID

# determine outcome of deployment
$success = $true
:outer foreach ($job in $RequiredSuccessJobs) {
  $checkJob = $runResult.jobs | Where-Object -FilterScript { $_.name -like $job }
  if ($null -eq $checkJob) {
    Write-Host -Object "Job to check: $job is not in the Job result. Skipping conclusion check"
    continue
  }

  if ($checkJob.Count -gt 1) {
    # wildcard provided
    foreach ($matchingJob in $checkJob) {
      if ($matchingJob.conclusion -ne 'success') {
        Write-Host -Object "Job: $($matchingJob.name) was not successfull but has conclusion: $($matchingJob.conclusion). Skipping conclusion check for remaining jobs and setting deployment to failure"
        $success = $false
        break outer
      }
    }
  }

  if ($checkJob.conclusion -ne 'success') {
    Write-Host -Object "Job: $job was not successfull but has conclusion: $($checkJob.conclusion). Skipping conclusion check for remaining jobs and setting deployment to failure"
    $success = $false
    break
  }
}

$reactionArgs = @{
  CommentId = $eventObject['comment']['id']
  Reaction  = $success ? 'hooray' : 'confused'
}
Send-GHReaction @reactionArgs

$updateStatusArgs = @{
  DeploymentId = $DeploymentId
  Status       = $success ? 'success' : 'failure'
  LogUrl       = "https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
  ErrorAction  = 'Stop'
}
Update-GHDeploymentStatus @updateStatusArgs
