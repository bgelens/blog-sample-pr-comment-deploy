<#
  This script:
  * Checks if the pipeline is triggered by the correct event (issue_comment)
  * Checks if the comment is for a PR (if comment is for issue, the event is invalid)
  * Checks if on of the specified ActionString is found in the comment body (if it is not found, the event is invalid)
  * (Optional, when specified) Checks if the specified RequiredBaseBranch is the PR base branch (if it is not, the event is not allowed)
  * (Optional, when specified) Checks if the PR head branch is in one of the values in the specified RequiredHeadBranch. (if it is not, the event is not allowed)
  * Checks if there is an existing deployment for the specified environment and headbranch
    * Checks for status of last deployment and assert validaty based on:
      * Existing deployment in_progress (cannot proceed, send thumbsdown -1 reaction and corresponding comment)
      * Existing deployment success or failure
        * if ActionString is /deploy (cannot proceed, send thumbsdown -1 reaction and corresponding comment)
        * if ActionString is /redeploy (action is valid. Current deployment is removed and script proceeds as if new deployment)
      * Existing deployment status is not one of the above (current deployment is deleted and script proceeds as if new depoloyment)
  * Acknowlegdes the ActionString by adding a rocket to the comment
  * Starts a new deployment for the specified environment and headbranch

  Action available outputs:
  * validprcommand - values true or false - specifies if the comment is a valid pr comment or not
  * prheadref - the branchname of the PR head (so a next action can check it out with ref)
  * deploymentId = the id of the new GitHub deployment
#>
[CmdletBinding()]
param (
  [Parameter(Mandatory)]
  [ValidateSet(
    '/deploy',
    '/redeploy'
  )]
  [string[]] $ActionString,

  [Parameter(Mandatory)]
  [ValidateSet(
    'acceptance'
  )]
  [string] $Environment,

  [Parameter()]
  [string] $RequiredBaseBranch,

  [Parameter()]
  [string[]] $RequiredHeadBranch
)

$eventObject = Get-Content -Path $env:GITHUB_EVENT_PATH | ConvertFrom-Json -AsHashtable
$commentId = $eventObject['comment']['id']

$actionHelperModule = Join-Path -Path $PSScriptRoot -ChildPath 'Helpers.psm1' -Resolve -ErrorAction Stop
Import-Module -Name $actionHelperModule -Verbose:$false -DisableNameChecking -Force

$owner, $repo = $env:GITHUB_REPOSITORY -split '\/'
Set-GHContext -Owner $owner -Repository $repo -APIToken $env:GITHUB_TOKEN

if ($env:GITHUB_EVENT_NAME -ne 'issue_comment') {
  Write-Host -Object "Workflow triggered by unsupported event $env:GITHUB_EVENT_NAME"
  Write-Host -Object "::set-output name=validprcommand::false"
  return
}

if ($null -eq $eventObject['issue']['pull_request']) {
  Write-Host -Object 'Comment Detected for issue instead of PR'
  Write-Host -Object "::set-output name=validprcommand::false"
  return
}

$body = $eventObject['comment']['body']

$actionStringInScope = $false
foreach ($action in $ActionString) {
  if ($body -match $action) {
    Write-Host -Object "Comment contains one of the specified ActionString(s): '$action'"
    $userSpecifiedAction = $action
    $actionStringInScope = $true
    break
  }
}

if (-not $actionStringInScope) {
  Write-Host -Object "Comment does not contain one of the specified ActionString(s) '$($ActionString -join ', ')'"
  Write-Host -Object "::set-output name=validprcommand::false"
  return
}

Write-Host -Object 'PR Comment Detected'
$prNumber = $eventObject['issue']['number']

$pr = Get-GHPullRequest -PRId $prNumber -ErrorAction Stop
$baseBranch = $pr.base.ref
$headBranch = $pr.head.ref
Write-Host -Object "::set-output name=prheadref::$headBranch"

if ($PSBoundParameters.ContainsKey('RequiredBaseBranch') -and $baseBranch -ne $RequiredBaseBranch) {
  Write-Host -Object "PR $prNumber is targetted to branch '$baseBranch' and is not scope. ($RequiredBaseBranch branch only)"
  Write-Host -Object "::set-output name=validprcommand::false"

  $commentArgs = @{
    PRId    = $prNumber
    Message = "PR is not valid. BaseBranch should be '$RequiredBaseBranch' but is '$baseBranch'"
  }
  Send-GHComment @commentArgs
  return
}

$headBranchInScope = $false

if ($PSBoundParameters.ContainsKey('RequiredHeadBranch')) {
  foreach ($branch in $RequiredHeadBranch) {
    if ($headBranch -like $branch) {
      $headBranchInScope = $true
      break
    }
  }
} else {
  $headBranchInScope = $true
}

if (-not $headBranchInScope) {
  Write-Host -Object "PR $prNumber is sourced from branch '$headBranch' and is not scope."
  Write-Host -Object "::set-output name=validprcommand::false"

  # thumbsdown reaction
  Send-GHReaction -CommentId $commentId -Reaction '-1'

  $normalizedExpectedHeadBranchesForMarkDown = ($RequiredHeadBranch | ForEach-Object -Process {
      "'" + ($_ -replace '/', '/\') + "'"
    }) -join ' or '

  $commentArgs = @{
    PRId    = $prNumber
    Message = "Action '$userSpecifiedAction' is not executed. Headbranch should be $normalizedExpectedHeadBranchesForMarkDown but is '$headBranch'"
  }
  Send-GHComment @commentArgs

  return
}

$currentDeployment = Get-GHDeployment -Ref $headBranch -Environment $Environment -ErrorAction Stop
if ($null -ne $currentDeployment) {
  Write-Host -Object "Existing deployment found for environment '$Environment' with head branch '$headBranch': $($currentDeployment.id)"

  # fetch latest status
  $latestStatus = Get-GHDeploymentStatus -DeploymentId $currentDeployment.id
  Write-Host -Object "Existing Deployment '$($latestStatus.id)' is $($latestStatus.state)"

  if ($latestStatus.state -eq 'in_progress') {
    # cannot deploy / redeploy when current deployment is flagged as in progress
    $messageString = "Current deployment is handled by action run: $($latestStatus.target_url). No other actions are allowed at this time"
    Write-Host -Object $messageString

    # thumbsdown reaction
    Write-Host -Object "::set-output name=validprcommand::false"
    Send-GHReaction -CommentId $commentId -Reaction '-1'

    # send comment that it's not possible
    $commentArgs = @{
      PRId    = $prNumber
      Message = $messageString
    }
    Send-GHComment @commentArgs

    return
  }

  if ($latestStatus.state -in 'success', 'failure' -and -not ($userSpecifiedAction -eq '/redeploy')) {
    # cannot deploy  when current deployment is flagged as success or failure, only redeploy is allowed
    $messageString = "Requested action '($userSpecifiedAction)' is not allowed. Only '/redeploy' is allowed"
    Write-Host -Object $messageString

    # thumbsdown reaction
    Write-Host -Object "::set-output name=validprcommand::false"
    Send-GHReaction -CommentId $commentId -Reaction '-1'

    # send comment that it's not possible, only redeploy is possible
    $commentArgs = @{
      PRId    = $prNumber
      Message = $messageString
    }
    Send-GHComment @commentArgs

    return
  } elseif ($latestStatus.state -in 'success', 'failure' -and $userSpecifiedAction -eq '/redeploy') {
    $messageString = "Requested action '($userSpecifiedAction)' will be executed"
    Write-Host -Object $messageString
    $null = Remove-GHDeployment -DeploymentId $currentDeployment.id -ErrorAction Stop
  } else {
    # cleanup current deployment
    Write-Host -Object 'Unhandled state, removing current deployment'
    $null = Remove-GHDeployment -DeploymentId $currentDeployment.id -ErrorAction Stop
  }
}

Write-Host -Object "::set-output name=validprcommand::true"
Write-Host -Object "PR $prNumber is sourced from branch $headBranch and is in scope"

Send-GHReaction -CommentId $commentId -Reaction rocket

$newDeployment = New-GHDeployment -Ref $headBranch -Environment $Environment -ErrorAction Stop
Write-Host -Object "::set-output name=deploymentId::$($newDeployment.id)"

$inProgressDeployArgs = @{
  DeploymentId = $newDeployment.id
  Status       = 'in_progress'
  LogUrl       = "https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
  ErrorAction  = 'Stop'
}
Update-GHDeploymentStatus @inProgressDeployArgs
