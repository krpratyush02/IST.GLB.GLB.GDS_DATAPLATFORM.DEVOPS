param(
    [ValidateNotNullOrEmpty()]
    [string] $RepositoryPath,

    [ValidateNotNullOrEmpty()]
    [string] $ChangelogRef = "main",

    [ValidateNotNullOrEmpty()]
    [string] $OutputFilePath = "CHANGELOG.md",

    [ValidateNotNullOrEmpty()]
    [string] $OrganizationName = "sdxcloud",

    [ValidateNotNullOrEmpty()]
    [string] $PAT
)

# set authentication
$env:AZURE_DEVOPS_EXT_PAT = $PAT

# dot source common scripts
Get-ChildItem -Path $PSScriptRoot/common -Filter "*.ps1" | ForEach-Object { . $_.FullName }

# set default organization
Run-CliCommand "az config set extension.use_dynamic_install=yes_without_promp"
Run-CliCommand "az devops configure --defaults organization=https://dev.azure.com/$OrganizationName/"

# get most recent tag, exclude the changelog ref if it's a tag
Write-Output "Getting latest tag"
$tags = Run-CliCommand "git tag --sort=committerdate" | Where-Object { $_ -ne $ChangelogRef }
$latestTag = $tags[$tags.Count-1]

# List commit hashes in between changelog ref and latest tag
if($latestTag -ne $null){
    Write-Output "Latest tag found, it's $latestTag"
    $commitList = Run-CliCommand "git log --pretty=format:%s $latestTag..$ChangelogRef"
}
else{
    Write-Output "Latest tag not found, proceeding with changelog for all commits"
    $commitList = Run-CliCommand "git log --pretty=format:%s $ChangelogRef"
}

# get commit messages from merge commits
Write-Output "Processing commit messages"
$listOfMergeCommits = $commitList | Where-Object { $_.StartsWith("Merged PR") }
Write-Output "Found $($listOfMergeCommits.Count) commit messages matching message 'Merged PR'"

$listOfPRIds = $listOfMergeCommits | ForEach-Object { $_.Split(" ")[2].Replace(":", "") }
Write-Output "Extracted following PR ids:\n$listOfPrIds"

$PRDetails = @()

# get PR details and work items for each ID
foreach($id in $listOfPRIds){
    $PRDetailsEntry = @{}
    Write-Output "Fetching details of PR no. $id"
    $output = Run-CliCommand "az repos pr show --id $id" | ConvertFrom-Json

    $PRDetailsEntry.ID = $id
    $PRDetailsEntry.WorkItems = $output.workItemRefs.id

    $PRDetails += $PRDetailsEntry
}

$changelogItems = @()
# get all user stories
foreach($workItem in $($PRDetails.WorkItems | Select-Object -Unique)){
    Write-Output "Processing linked work item no. $workItem"
    $workItemDetails = Run-CliCommand "az boards work-item relation show --id $workItem" | ConvertFrom-Json
    # if work item is task/issue get parent user story details
    if($workItemDetails.fields.'System.WorkItemType' -ne "User Story"){
        Write-Output "Work item is not an user story, searching for parent"
        $parent = $workItemDetails.relations | Where-Object { $_.attributes.name -eq "Parent" }

        # if there's no parent, skip this work item
        if($parent -ne $null){
            $parentSplitted = $parent.url.Split("/")
        }
        else{
            Write-Output "Parent not found for work item $workItem, skipping."
            continue;
        }

        Write-Output "Found parent for $workItem, it's $($parentSplitted[$parentSplitted.Count-1])"
        $workItemDetails = Run-CliCommand "az boards work-item relation show --id $($parentSplitted[$parentSplitted.Count-1])" | ConvertFrom-Json
    }

    # if parent was not user story as well, skip this work item.
    if($workItemDetails.fields.'System.WorkItemType' -ne "User Story"){
        Write-Output "Parent is not an user story, skipping $workItem"
        continue;
    }

    # get required properties
    $changelogItem = @{}
    $changelogItem.Iteration = $workItemDetails.fields.'System.IterationPath'
    $changelogItem.UserStoryID = $workItemDetails.fields.'System.Id'
    $changelogItem.Assignee = $workItemDetails.fields.'System.AssignedTo'.DisplayName
    $changelogItem.Tasks = @()
    $childObjects = $workItemDetails.relations | Where-Object { $_.attributes.name -eq "Child" }
    
    # if there're children
    if($childObjects -ne $null){
        Write-Output "Extracting children work items for user story $($changelogItem.UserStoryID)"
        $splittedChildObjects = $childObjects.url.Split("/")

        # get every 8th element from array which is child ID
        0..($splittedChildObjects.Count) | ForEach-Object {
            if((($_+1) % 8 ) -eq 0){
                $changelogItem.Tasks += $splittedChildObjects[$_]
            }
        }
    }

    Write-Output "Found $($changelogItem.Tasks.Count) children items"
    if($changelogItems.UserStoryID -notcontains $changelogItem.UserStoryID){
        $changelogItems += $changelogItem
    }
}

# prepare md table rows
Write-Output "Processing changelog template.."
$mdTableRows = ""
foreach($item in $changelogItems){
    $line = ""
    $line += "#$($item.UserStoryID) |"
    $line += " $(($item.Tasks | ForEach-Object { $_.Insert(0, "#") }) -join ' <br /> ') |"
    $line += " $((($PRDetails | Where-Object { $_.WorkItems -in $item.Tasks -or $_.WorkItems -in $item.UserStoryId }).ID | `
        ForEach-Object { if ($_ -ne $null) { $_.Insert(0, "!") }}) -join ' <br /> ') |"
    $line += "$($item.Assignee)|"
    $line += "$($item.Iteration)|`n"
    $mdTableRows += $line
}

$changelogDate = Get-Date
$templatePath = "$PSScriptRoot/resources/CHANGELOG.md"
$templateContent = Get-Content $templatePath -Raw

# replace placeholders
$templateContent = $templateContent.replace("#{DATE}#", $changelogDate)
$templateContent = $templateContent.replace("#{OLD_VERSION}#", $latestTag)
$templateContent = $templateContent.replace("#{NEW_VERSION}#", $ChangelogRef)
$templateContent = $templateContent.replace("#{CHANGELOG_ROWS}#", $mdTableRows)

# save changelog in destination
$templateContent | Out-File -FilePath $OutputFilePath
