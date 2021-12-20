using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Output "Alert recieved, processing..."

#topdesk static information
$topdeskOperatorName = "TOPDESKCONNECTOR"
$topdeskOperatorGroupName = "solvo it"
$topdeskCategoryName = "SIM"
$topdeskSubcategoryName = "Server"
$topdeskCallTypeName = "Fejl"
$topdeskEntryTypeName = "SIM"
$callerLookupEmail = "azure-noreply@microsoft.com"

#Sign in to Topdesk
$topdeskPassword = ConvertTo-SecureString -String $ENV:TopdeskSecret -AsPlainText -Force
$topdeskCredentials = New-Object -TypeName "System.Management.Automation.PSCredential" -ArgumentList $ENV:TopdeskUser, $topdeskPassword
Connect-TdService -Url $ENV:TopdeskUrl -ApplicationPassword $topdeskCredentials


# Interact with query parameters or the body of the request.
$alert = $request.body
$signalType = $alert.body.data.essentials.signalType
$monitorCondition = $alert.body.data.essentials.monitorCondition

#Get Topdesk priority id, input is Azure Alert severity; Sev0-4
function GetTopdeskPriorityId {
    [CmdletBinding()]
    param (
        [string]$azAlertSeverity
    )
    
    $topdeskPriorityMapping = @{
        Sev0 = "1. Kritisk"
        Sev1 = "2. Høj"
        Sev2 = "3. Normal"
        Sev3 = "3. Normal"
        Sev4 = "5. Uden tidsfrist"
    }

    $priorityName = $topdeskPriorityMapping.item($azAlertSeverity)
    $tdPriority = Get-TdPriority -Name $priorityName
    return $tdPriority
}


function GetTopdeskProssingStatus {
    [CmdletBinding()]
    param (
        [string]$azAlertMonitorCondition
    )

    $topdeskProsssingStatusMapping = @{
        Fired = "Registreret"
        Resolved = "Lukket"
    }

    $prossingStatusName = $topdeskProsssingStatusMapping.item($azAlertMonitorCondition)
    $tdProcessingStatus = Get-TdProcessingStatus -Name $prossingStatusName
    return $tdProcessingStatus
}


function GetTopdeskOperatorGroup {
    [CmdletBinding()]
    param (
        [string]$tdOperatorGroupName
    
        )
    $tdOperatorGroup = Get-TdOperatorGroup -NameFragment $tdOperatorGroupName | Where-Object {$_.groupName -eq $tdOperatorGroupName}
    return $tdOperatorGroup
}


function GetTopdeskCategory {
    [CmdletBinding()]
    param (
        [string]$tdCategoryName
    
        )
    $tdCategory = Get-TdCategory -Name $tdCategoryName
    return $tdCategory
}

function MetricAlertInfo {
    param (
        [Parameter(Mandatory=$true)]
        [Object]$alert
    )

    try {
        $newLine = " <br> "
        $computerName = "Computername: " + ($alert.body.data.alertContext.condition.allOf.dimensions | Where-Object {$_.name -eq "Computer"}).value
        $metricValue = "Metric value: " + $alert.body.data.alertContext.condition.allOf.metricValue
        $threshold = "Threshold: " + $alert.body.data.alertContext.condition.allOf.threshold
        
        #Create action text
        $incidentRequest = $computerName + $newLine + $metricValue + $newLine + $threshold

        return $incidentRequest
    }
    catch {
        
    }
}

function CreateTopdeskTicket {
    param (
        [Parameter(Mandatory=$true)]
        [string]$CallerLookupEmail,
        
        [Parameter(Mandatory=$true)]
        [string]$BriefDescription,
        
        [Parameter(Mandatory=$true)]
        [string]$Category,
        
        [Parameter(Mandatory=$true)]
        [string]$PriorityId,
        
        [Parameter(Mandatory=$true)]
        [string]$CallTypeId,
        
        [Parameter(Mandatory=$true)]
        [string]$EntryTypeId,
        
        [Parameter(Mandatory=$true)]
        [string]$OperatorId,
        
        [Parameter(Mandatory=$true)]
        [string]$Request,
        
        [Parameter(Mandatory=$true)]
        [string]$ExternalNumber
    )

    try {
        $tdIncident = New-TdIncident -CallerLookupEmail $CallerLookupEmail `
                                     -BriefDescription $BriefDescription `
                                     -Category $Category `
                                     -PriorityId $PriorityId `
                                     -CallTypeId $CallTypeId `
                                     -EntryTypeId $EntryTypeId `
                                     -OperatorId $OperatorId `
                                     -Request $Request `
                                     -ExternalNumber $ExternalNumber

        if ($tdIncident) {
            Write-Output "Successfully created ticket" $tdIncident.number
        }
    }
    catch {
        
    }
}

function CloseTopdeskTicket {
    param (
        [Parameter(Mandatory=$true)]
        [string]$alertId,

        [Parameter(Mandatory=$true)]
        [string]$processingStatus    
    )

    #Get existing incident from TOPdesk based on Azure alert id
    try {
        $tdIncident = Get-TdIncident -ExternalNumber $alertId
        if ($tdIncident) {        
            Write-Output "Found existing Topdesk ticket" $tdIncident.number "with external number " $alertId " - closing ticket..."
            Set-TdIncident -Number $tdIncident.number -ProcessingStatus $processingStatus
        }
    }
    catch {
        
    }
}

$tdPriority = GetTopdeskPriorityId $alert.body.data.essentials.severity  #for test use input "Sev3"

$tdProcessingStatus = GetTopdeskProssingStatus $alert.body.data.essentials.monitorCondition

$tdOperatorGroup = GetTopdeskOperatorGroup $topdeskOperatorGroupName

$tdCategory = GetTopdeskCategory $topdeskCategoryName

$tdOperator = Get-TdOperator -TOPdeskLoginName $topdeskOperatorName
$tdCallType = Get-TdCallType -Name $topdeskCallTypeName
$tdEntryType = Get-TdEntryType -Name $topdeskEntryTypeName

#Filter alert ID to guid
$alertId = $alert.body.data.essentials.alertId.split("/")[-1]

if ($signalType -eq "Metric") {
    $Request = MetricAlertInfo -alert $alert
}


if ($monitorCondition -eq "Fired") {
    Write-Output "Received signal.. Condition is Fired - creating ticket in Topdesk: " $ENV:topdeskUrl
    CreateTopdeskTicket -CallerLookupEmail $callerLookupEmail `
                        -BriefDescription $alert.body.data.essentials.description `
                        -Category $tdCategory.name `
                        -PriorityId $tdPriority.id `
                        -CallTypeId $tdCallType.id `
                        -EntryTypeId $tdEntryType.id `
                        -OperatorId $tdOperator.id `
                        -Request $Request `
                        -ExternalNumber $alertId
}


if ($monitorCondition -eq "Resolved") {
    Write-Output "Received signal.. Condition is Resolved - closing ticket in Topdesk: " $ENV:topdeskUrl
    CloseTopdeskTicket -alertId $alertId `
                       -processingStatus $tdProcessingStatus.id
}