# Input bindings are passed in via param block.
param($Timer)

# Get the current universal time in the default string format
$currentUTCtime = (Get-Date).ToUniversalTime()

# The 'IsPastDue' porperty is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

<#
.DESCRIPTION
An Azure Function example that automatically creates incremental backups of an Azure Files system on a customer-defined schedule and stores the backups in a separate storage account.
It does so by leveraging AzCopy with the sync parameter, which is similar to Robocopy /MIR. Only changes will be copied with every backup, and any deletions on the source will be mirrored on the target.
In this example, AzCopy is running in a Container inside an Azure Container Instance using Service Principal in Azure AD.

Required infrastructure:
- Two Azure Storage Accounts in different regions
  -  Enable Private Endpoints on both Storage Accounts and disable public access (ideally). Use a dedicated Private DNS Zone for the Private Endpoints, linked to just this VNET. 
- A dedicated resource group in the source Storage Account region for the sync automation components
- An isolated VNET in the source Storage Account region
  -  Create a subnet for the Container Instance, delegated to the Container Instance service
  -  Create a subnet for the Storage Account private endpoints (both source and destination endpoints should connect here)
  -  Create a subnet for the Function App
- Create a Function App using the Premium plan (to enable VNET integration)
  -  Use PowerShell as the runtime stack, version 7.2
  -  Enable VNET integration for the Function App
  -  Enable Managed Identity for the Function App
  -  Assign the Function App a role assignment to the Storage Account Contributor role on both Storage Accounts
  -  Assign the Function App a role assignment to the Contributor role on the file sync automation Resource Group
  -  Deploy this script in a Timer Triggered Function within the Function App
  -  In Function App requirements.ps1, add the following modules. For example:
        @{
            'Az.Storage' = '5.*'
            'Az.ContainerInstance' = '3.*'
            'Az.Accounts' = '2.11'
        }

Recommended infrastructure:
- Application Insights, configured to monitor the Function App and alert on failures
- An Activity Log Alert, configured to monitor the Container Instance for failures

.NOTES
Based on: https://github.com/Azure-Samples/azure-files-samples/blob/master/SyncBetweenTwoAzureFileSharesForDR/SyncBetweenTwoFileShares.ps1
    - Moves execution from Azure Automation to Azure Function in order to enable VNET integration and Private Endpoints on Storage Accounts
    - Uses the Managed Identity of the Function App to create the Container Instance
    - Updates the container instance commands based on current syntax
Author1  : Matthew Bratschun (Microsoft FastTrack for Azure)
Version  : 1.0
Date     : 22-March-2023
Updated  : 

.LINK
To provide feedback or for further assistance please email:
azurefiles@microsoft.com
#>

# script parameters
[String] $sourceAzureSubscriptionId = #ex: '24730882-456b-42df-a6f8-8590ca6e4e37'
[String] $sourceStorageAccountRG = #ex: 'rg-filesyncfunction'
[String] $targetStorageAccountRG = #ex: 'rg-filesyncfunction'
[String] $syncAutomationRG = #ex: 'rg-filesyncfunction' - this is where the Function App exists and Container Instance will be created
[String] $sourceStorageAccountName = #ex: 'mtbfilesyncfunction01'
[String] $targetStorageAccountName = #ex: 'mtbfilesyncfunction03'
[String] $sourceStorageFileShareName = #ex: 'sourceshare'
[String] $targetStorageFileShareName = #ex: 'destshare'
# this subnet must have access to the storage account private endpoints and should be delegated to the Microsoft.ContainerInstance/containerGroups resource provider
[String] $containerInstanceSubnetId = #ex: '/subscriptions/24730882-456b-42df-a6f8-8590ca6e4e37/resourceGroups/rg-filesyncfunction/providers/Microsoft.Network/virtualNetworks/vnet-storage/subnets/ci'

# Azure File Share maximum snapshot support limit by the Azure platform is 200
[Int]$maxSnapshots = 200

# Function Defaults to Logging in with its own Managed Identity - see profile.ps1
# SOURCE Azure Subscription
Select-AzSubscription -SubscriptionId $sourceAzureSubscriptionId

$sourceStorageAccount = Get-AzStorageAccount -ResourceGroupName $sourceStorageAccountRG -Name $sourceStorageAccountName
$primaryLocation = $sourceStorageAccount.Location

# Set Azure Storage Context
$sourceContext = $sourceStorageAccount.Context

# List the current snapshots on the source share
$snapshots = Get-AzStorageShare `
    -Context $sourceContext.Context | `
Where-Object { $_.Name -eq $sourceStorageFileShareName -and $_.IsSnapshot -eq $true}

# Delete the oldest (1) manual snapshot in the source share if have 180 or more snapshots (Azure Files snapshot limit is 200)
# This leaves a buffer such that there can always be 6 months of daily snapshots and 10 yearly snapshots taken via Azure Backup
# You may need to adjust this buffer based on your snapshot retention policy
If ((($snapshots.count)+20) -ge $maxSnapshots) {
    $manualSnapshots = $snapshots | where-object {$_.ShareProperties.Metadata.Keys -ne "AzureBackupProtected"}
    Remove-AzStorageShare -Share $manualSnapshots[0].CloudFileShare -Force
}

# Take manual snapshot on the source share
# When taking a snapshot using PowerShell, the snapshot's metadata is set to a key-value pair with the key being "AzureBackupProtected"
# The value of "AzureBackupProtected" is set to "True" or "False" depending on whether Azure Backup is enabled
$sourceShare = Get-AzStorageShare -Context $sourceContext.Context -Name $sourceStorageFileShareName
$sourceSnapshot = $sourceShare.CloudFileShare.Snapshot()

# Generate source file share SAS URI
$sourceShareSASURI = New-AzStorageShareSASToken -Context $sourceContext `
  -ExpiryTime(get-date).AddDays(1) -FullUri -ShareName $sourceStorageFileShareName -Permission rl
# Set source file share snapshot SAS URI
$sourceSnapSASURI = $sourceSnapshot.SnapshotQualifiedUri.AbsoluteUri + "&" + $sourceShareSASURI.Split('?')[-1]

#! TARGET Storage Account in a different region
# Get Target Storage Account
$targetStorageAccount = Get-AzStorageAccount -ResourceGroupName $targetStorageAccountRG -Name $targetStorageAccountName

# Set Target Azure Storage Context
$destinationContext = $targetStorageAccount.Context

# Generate target SAS URI
$targetShareSASURI = New-AzStorageShareSASToken -Context $destinationContext `
    -ExpiryTime(get-date).AddDays(1) -FullUri -ShareName $targetStorageFileShareName -Permission rwl

# Create AzCopy syntax command
$sourceSnapshotSASURI = $sourceSnapSASURI
$targetFileShareSASURI = $targetShareSASURI

# Check if target file share contains data
$targetFileShare = Get-AzStorageFile -Sharename $targetStorageFileShareName -Context $destinationContext.Context

# If target share already contains data, use AzCopy sync to sync data from source to target
# Else if target share is empty, use AzCopy copy as it will be more efficient
#
# NOTE: as of 4/22/2023, AzCopy sync for files only supports SAS tokens.
#
if ($targetFileShare) {
     $command = "azcopy", "sync", $sourceSnapshotSASURI, $targetFileShareSASURI, "--preserve-smb-info", "--preserve-smb-permissions", "--recursive"
}
Else {
     $command = "azcopy", "copy", $sourceSnapshotSASURI, $targetFileShareSASURI, "--preserve-smb-info", "--preserve-smb-permissions","--recursive"
}
# Create Azure Container Instance and run the AzCopy job
# The container image (peterdavehello) is publicly available on Docker Hub and has the latest AzCopy version installed
# You could also create your own container image and use it instead
# When you create a new container instance, the default compute resources are set to 1vCPU and 1.5GB RAM
# We recommend starting with 2vCPU and 4GB memory for larger file shares (E.g. 3TB)
# You may need to adjust the CPU and memory based on the size and churn of your file share

$subnetObj = @{id=$containerInstanceSubnetId;name=$containerInstanceSubnetId.split('/')[-1]}

# create the container instance. the funciton will not wait for the CI to execute to avoid hitting function timeout
$container = New-AzContainerInstanceObject -Name container -Image 'peterdavehello/azcopy:latest' -Command $command -RequestCpu 2 -RequestMemoryInGb 4
New-AzContainerGroup -ResourceGroupName $syncAutomationRG -Name azcopyjob -Container $container -OsType Linux -RestartPolicy never `
    -Sku 'Standard' -Location $primaryLocation -SubnetId $subnetObj -NoWait

# List the current snapshots on the target share
$snapshots = Get-AzStorageShare `
    -Context $destinationContext.Context | `
Where-Object { $_.Name -eq $targetStorageFileShareName -and $_.IsSnapshot -eq $true}

# Delete the oldest (1) manual snapshot in the target share if have 190 or more snapshots (Azure Files snapshot limit is 200)
If ((($snapshots.count)+10) -ge $maxSnapshots) {
    $manualSnapshots = $snapshots | where-object {$_.ShareProperties.Metadata.Keys -ne "AzureBackupProtected"}
    Remove-AzStorageShare -Share $manualSnapshots[0].CloudFileShare -Force
}

# Take manual snapshot on the target share
# When taking a snapshot using PowerShell, the snapshot's metadata is set to a key-value pair with the key being "AzureBackupProtected"
# The value of "AzureBackupProtected" is set to "True" or "False" depending on whether Azure Backup is enabled
$targetShare = Get-AzStorageShare -Context $destinationContext.Context -Name $targetStorageFileShareName
$targetShareSnapshot = $targetShare.CloudFileShare.Snapshot()


# Write an information log with the current time.
Write-Host "PowerShell timer trigger function ran! TIME: $currentUTCtime"
