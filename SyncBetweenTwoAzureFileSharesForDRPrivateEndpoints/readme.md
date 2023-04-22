# Sync Azure Files Shares with Private Endpoints

## DESCRIPTION

An Azure Function example that automatically creates incremental backups of an Azure Files system on a customer-defined schedule and stores the backups in a separate storage account.
It does so by leveraging AzCopy with the sync parameter, which is similar to Robocopy /MIR. Only changes will be copied with every backup, and any deletions on the source will be mirrored on the target.
In this example, AzCopy is running in a Container inside an Azure Container Instance using Service Principal in Azure AD.

### Required infrastructure:

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

### Recommended infrastructure:

- Application Insights, configured to monitor the Function App and alert on failures
- An Activity Log Alert, configured to monitor the Container Instance for failures

## NOTES

Based on: https://github.com/Azure-Samples/azure-files-samples/blob/master/SyncBetweenTwoAzureFileSharesForDR/SyncBetweenTwoFileShares.ps1

- Moves execution from Azure Automation to Azure Function in order to enable VNET integration and Private Endpoints on Storage Accounts
- Uses the Managed Identity of the Function App to create the Container Instance
- Updates the container instance commands based on current syntax

Author1  : Matthew Bratschun (Microsoft FastTrack for Azure)
Version  : 1.0
Date     : 22-March-2023
Updated  : 