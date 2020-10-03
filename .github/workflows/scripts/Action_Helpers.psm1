$ghContext = $null

# we use the gh cli that is installed on the workers by default
# this is way faster than installing the PowerShellForGitHub PowerShell module
$gh = Get-Command -CommandType Application -Name gh -ErrorAction SilentlyContinue
if ($null -eq $gh) {
  throw 'Application gh not installed or not found on PATH'
}

function Set-GHContext {
  param (
    [Parameter(Mandatory)]
    [string] $Owner,

    [Parameter(Mandatory)]
    [string] $Repository,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $APIToken
  )

  $env:GITHUB_TOKEN = $APIToken

  $script:ghContext = @{
    Repository = "$Owner/$Repository"
  }
}

function Enable-GHCLIDebugMode {
  $env:DEBUG = 'api'
}

function Disable-GHCLIDebugMode {
  $env:DEBUG = $null
}

function Invoke-GHAPI {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory, Position = 0)]
    [string] $UriFragment,

    [ValidateSet(
      'GET',
      'POST',
      'DELETE'
    )]
    [string] $Method = 'GET',

    [string] $Body,

    [switch] $Paginate,

    [uint16] $DeserializeDepth = 10,

    [hashtable] $Headers
  )

  if ($null -eq $script:ghContext) {
    throw 'Run Set-GHContext first!'
  }

  $commandArgs = [System.Collections.Generic.List[string]]::new()
  $commandArgs.Add($UriFragment)
  $commandArgs.Add('--method')
  $commandArgs.Add($Method)

  if ($Paginate) {
    $commandArgs.Add('--paginate')
  }

  if ($PSBoundParameters.ContainsKey('Headers')) {
    $commandArgs.Add('--header')
    $headerNormalized = ($Headers.GetEnumerator() | ForEach-Object -Process {
        "$($_.Name):$($_.Value)"
      }) -join ','
    $commandArgs.Add($headerNormalized)
  }

  if ($PSBoundParameters.ContainsKey('Body') -and $Method -ne 'GET') {
    $commandArgs.Add('--input')
    $commandArgs.Add('-')
    $commandString = $commandArgs -join ' '
    Write-Verbose -Message "Running call: $commandString"
    Write-Verbose -Message "Using body:`n$Body"
    $result = $Body | & $gh api $commandArgs | ConvertFrom-Json -Depth $DeserializeDepth
  } else {
    $commandString = $commandArgs -join ' '
    Write-Verbose -Message "Running call: $commandString"
    $result = & $gh api $commandArgs | ConvertFrom-Json -Depth $DeserializeDepth
  }

  if ($LASTEXITCODE -ne 0) {
    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
      ([System.Exception]$result.message),
      '',
      [System.Management.Automation.ErrorCategory]::InvalidOperation,
      $result
    )
    $PSCmdlet.WriteError($errorRecord)
  } else {
    $result
  }
}

function Send-GHReaction {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)]
    [ValidateSet(
      '+1',
      '-1',
      'laugh',
      'confused',
      'heart',
      'hooray',
      'rocket',
      'eyes'
    )]
    [string] $Reaction,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $CommentId
  )

  if ($null -eq $script:ghContext) {
    throw 'Run Set-GHContext first!'
  }

  $uriFragment = 'repos/{0}/issues/comments/{1}/reactions' -f $script:ghContext.Repository, $CommentId
  $Reaction = $Reaction.ToLower()

  $ghRestArgs = @{
    UriFragment = $uriFragment
    Method      = 'POST'
    Body        = (ConvertTo-Json -InputObject @{ content = $Reaction })
    Headers     = @{ Accept = 'application/vnd.github.squirrel-girl-preview+json' }
    ErrorAction = 'Stop'
  }

  try {
    $null = Invoke-GHAPI @ghRestArgs
  } catch {
    $PSCmdlet.WriteError($_)
  }
}

function Get-GHDeployment {
  [CmdletBinding()]
  param (
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Ref,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Environment
  )

  if ($null -eq $script:ghContext) {
    throw 'Run Set-GHContext first!'
  }

  $uriFragment = '/repos/{0}/deployments' -f $script:ghContext.Repository

  $queryStringArguments = [System.Collections.Generic.Dictionary[string, string]]::new()
  if ($PSBoundParameters.ContainsKey('Ref')) {
    [void] $queryStringArguments.Add('ref', $Ref)
  }

  if ($PSBoundParameters.ContainsKey('Environment')) {
    [void] $queryStringArguments.Add('environment', $Environment)
  }

  if ($queryStringArguments.Count -ge 1) {
    $queryString = $queryStringArguments.GetEnumerator().ForEach{
      "$($_.key)=$($_.value)"
    } -join '&'
    $uriFragment += "?$queryString"
  }

  try {
    Invoke-GHAPI -UriFragment $uriFragment -Method GET -Headers @{
      accept = 'application/vnd.github.v3+json'
    } -ErrorAction Stop
  } catch {
    $PSCmdlet.WriteError($_)
  }
}

function New-GHDeployment {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Ref,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Environment
  )

  if ($null -eq $script:ghContext) {
    throw 'Run Set-GHContext first!'
  }

  $uriFragment = '/repos/{0}/deployments' -f $script:ghContext.Repository

  $body = @{
    ref         = $Ref
    auto_merge  = $false
    environment = $Environment
  } | ConvertTo-Json -Compress

  try {
    Invoke-GHAPI -UriFragment $uriFragment -Method POST -Body $body -Headers @{
      accept = 'application/vnd.github.v3+json'
    } -ErrorAction Stop
  } catch {
    $PSCmdlet.WriteError($_)
  }
}

function Remove-GHDeployment {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $DeploymentId
  )

  if ($null -eq $script:ghContext) {
    throw 'Run Set-GHContext first!'
  }

  $uriFragment = '/repos/{0}/deployments/{1}' -f $script:ghContext.Repository, $DeploymentId

  try {
    $null = Invoke-GHAPI -UriFragment $uriFragment -Method DELETE -Headers @{
      accept = 'application/vnd.github.v3+json'
    } -ErrorAction Stop
  } catch {
    $PSCmdlet.WriteError($_)
  }
}

function Update-GHDeploymentStatus {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $DeploymentId,

    [Parameter(Mandatory)]
    [ValidateSet(
      'in_progress',
      'success',
      'failure'
    )]
    [string] $Status,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $LogUrl
  )

  if ($null -eq $script:ghContext) {
    throw 'Run Set-GHContext first!'
  }

  $uriFragment = 'repos/{0}/deployments/{1}/statuses' -f $script:ghContext.Repository, $DeploymentId

  # update deployment status
  $body = @{
    state   = $Status
    log_url = $LogUrl
  } | ConvertTo-Json -Compress

  $acceptHeader = 'application/vnd.github.ant-man-preview+json'
  if ($Status -eq 'in_progress') {
    $acceptHeader += ';application/vnd.github.flash-preview+json'
  }

  try {
    $null = Invoke-GHAPI -UriFragment $uriFragment -Method POST -Headers @{
      accept = $acceptHeader
    } -Body $body -ErrorAction Stop
  } catch {
    $PSCmdlet.WriteError($_)
  }
}

function Get-GHDeploymentStatus {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $DeploymentId,

    [switch] $All
  )

  if ($null -eq $script:ghContext) {
    throw 'Run Set-GHContext first!'
  }

  $uriFragment = '/repos/{0}/deployments/{1}/statuses' -f $script:ghContext.Repository, $DeploymentId

  try {
    $deploymentStatus = Invoke-GHAPI -UriFragment $uriFragment -Method GET -Headers @{
      accept = 'application/vnd.github.flash-preview+json;application/vnd.github.ant-man-preview+json '
    } -ErrorAction Stop

    if ($All) {
      $deploymentStatus
    } else {
      # by default only output last
      $deploymentStatus | Select-Object -First 1
    }
  } catch {
    $PSCmdlet.WriteError($_)
  }
}


function Send-GHComment {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [Alias('PRId')]
    [string] $IssueId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Message
  )

  if ($null -eq $script:ghContext) {
    throw 'Run Set-GHContext first!'
  }

  $uriFragment = 'repos/{0}/issues/{1}/comments' -f $script:ghContext.Repository, $IssueId

  try {
    $body = @{
      body = $Message
    } | ConvertTo-Json -Compress

    $null = Invoke-GHAPI -UriFragment $uriFragment -Method POST -Body $body -ErrorAction Stop
  } catch {
    $PSCmdlet.WriteError($_)
  }
}

function Get-GHPullRequest {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $PRId
  )

  if ($null -eq $script:ghContext) {
    throw 'Run Set-GHContext first!'
  }

  $uriFragment = 'repos/{0}/pulls/{1}' -f $script:ghContext.Repository, $PRId

  try {
    Invoke-GHAPI -UriFragment $uriFragment -Method GET -ErrorAction Stop
  } catch {
    $PSCmdlet.WriteError($_)
  }
}

function Get-GHActionsRunJob {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $RunId
  )

  if ($null -eq $script:ghContext) {
    throw 'Run Set-GHContext first!'
  }

  $uriFragment = 'repos/{0}/actions/runs/{1}/jobs' -f $script:ghContext.Repository, $RunId

  try {
    Invoke-GHAPI -UriFragment $uriFragment -Method GET -ErrorAction Stop
  } catch {
    $PSCmdlet.WriteError($_)
  }
}

function New-GHRelease {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Name,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $TagName = $Name,

    [Parameter()]
    [string] $Body,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Commitish,

    [Parameter()]
    [switch] $Draft,

    [Parameter()]
    [switch] $PreRelease
  )

  if ($null -eq $script:ghContext) {
    throw 'Run Set-GHContext first!'
  }

  $uriFragment = '/repos/{0}/releases' -f $script:ghContext.Repository

  $postBody = @{
    tag_name         = $TagName
    target_commitish = $Commitish
    name             = $Name
    draft            = $Draft.IsPresent
    prerelease       = $PreRelease.IsPresent
  }

  if ($PSBoundParameters.ContainsKey('Body')) {
    $postBody.Add('body', $Body)
  }

  $postBody = $postBody | ConvertTo-Json -Compress

  try {
    Invoke-GHAPI -UriFragment $uriFragment -Method POST -Body $postBody -ErrorAction Stop
  } catch {
    $PSCmdlet.WriteError($_)
  }
}
