<#
.SYNOPSIS
The Script will create a Workplace Analytics Organization file based off your current Azure Active Directory Information by using Azure AD and
the MSOnline service

.DESCRIPTION
The file generated by this script is intended to be used as part of Workplace Analytics HR data upload.  Please see the documentation for more context - https://docs.microsoft.com/en-us/workplace-analytics/

#Script Prerequisites 
   + Powershell version greater than 5.0. If you are on an earlier version of powershell, please refer to the documentation at https://docs.microsoft.com/en-us/skypeforbusiness/set-up-your-computer-for-windows-powershell/download-and-install-windows-powershell-5-1         
   + Azure Active Directory Module.  Installation instructions can be found here - https://docs.microsoft.com/en-us/powershell/azure/active-directory/install-adv2?view=azureadps-2.0
   + MSOnline module.  Installation instructions can be found here - https://docs.microsoft.com/en-us/powershell/azure/active-directory/install-msonlinev1?view=azureadps-1.0

#CSV Schema.  To understand these fields and their requirements, please see the Workplace Analytics organization file documentation - https://docs.microsoft.com/en-us/workplace-analytics/setup/prepare-organizational-data

    PersonID 
        Type: String.  A user's primary smtp address

    EffectiveDate
        Type: String.  Start date that this information is current. Must be able to be cast to the .NET type 'datetime'

    ManagerID
        Type: String.  A user's manager. Must be in valid SMTP format

    Organization
        Type: String.  Currently set to the user's Azure AD Department field

    LevelDesignation
        Type: String

    NumDirectReports
        Type: Integer.  The number of direct reports found in Azure AD

    SupervisorIndicator
        Type: String.  One of three values indicating whether this user manages no people, is a manager, or is a manager of managers

    ManagerIsMissingFlag
        Type: String.  If there was no manager found in AD or there was an error during lookup, this value is 'TRUE', otherwise 'FALSE'

#Optional Properties
    City
        Type: String. City property from a Get-MsolUser call

    Country
        Type: String. Country property from a Get-MsolUser call

    Title
        Type: String. Title property from a Get-MsolUser call

    Office
        Type: String. Office property from a Get-MsolUser call


.PARAMETER MSOLCredential
The credential of a user that can authenticate with the MSOnline service and execute the Get-MsolUser cmdlet
type: pscredential

.PARAMETER AzureADCredential
the credential of a user that can authenticate with Azure AD service and execute read-only cmdlets like Get-AzureADUser
type: pscredential

.PARAMETER RequireCredentialPrompt
If your organization's IT requires multifactor authentication, this switch will allow you to authenticate by prompting you for credentials
using the built-in prompts provided by Connect-AzureAD and Connect-MsolService cmdlets

.PARAMETER EffectiveDateOption
Used to determine the EffectiveDate.  
'InitialPull' is the option you'd select if this is the first time generating an organization file for Workplace Analytics
'Delta' is the option you'd select if you've already uploaded an in use organization file in Workplace Analytics and are using this script to generate an updated one

.PARAMETER SkipOptionalProperties
As part of information gathering, there are additional properties available via Azure AD and MSOL that are not required by Workplace Analytics.  
If you want to skip gathering those properties, use this switch.
The optional properties are Country, City, Title, Office

.PARAMETER InjectThrottling
Only used for debugging.  An end user should not use this switch as it would greatly hinder performance.

.INPUTS

Generate-WpaOrganizationFile.ps1 does not accept input from the pipeline.  Please see parameter section above.

.OUTPUTS
Log file is generated in .\Logs\

#usermailboxinfo.csv
Contains user principal name, primary SMTP address, and department info for mailboxes gathered through the Get-MsolUser call.  Used by the rest of the script to know which users to gather
Azure AD information for.   

#WpAOrgFile.csv
This is the end product output for this script that contains Azure AD information for all real user mailboxes found in the tenant.  It is advised not to open this file during script execution as doing so
could create a write lock on this file and cause the script to halt.

.EXAMPLE
.\Generate-WpaOrganizationFile.ps1 -MSOLCredential $MsolCred -AzureADCredential $AzureADcred

.EXAMPLE
.\Generate-WpaOrganizationFile.ps1 -RequireCredentialPrompt

.EXAMPLE
.\Generate-WpaOrganizationFile.ps1 -RequireCredentialPrompt -SkipOptionalProperties

#>
#Requires -Version 5
#Requires -Modules AzureAD
#Requires -Modules MSOnline
param(
    [Parameter(ParameterSetName='SimpleCreds')]
    [pscredential]$MSOLCredential,
    [Parameter(ParameterSetName='SimpleCreds')]
    [pscredential]$AzureADCredential,
    [Parameter(ParameterSetName='MFA')]
    [Switch]$RequireCredentialPrompt,
    [ValidateSet("InitialPull","Delta")]
    [string]$EffectiveDateOption = "InitialPull",
    [switch]$SkipOptionalProperties,
    [switch]$InjectThrottling
)
Function Write-Log {
    param(
        [Parameter(Mandatory=$true,Position=0)]
        [string] $Message,

        [ValidateSet('Info','Debug', 'Warning','Error')]
        [string] $LogLevel = 'Info',

        [string]$LogPath,

        [switch]$Silent

        )
        if(!$PSScriptRoot) {
            $PSScriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent 
        }
        if(-not $LogPath) {
            #IE: <where this module lives>\<The script's name calling this imported function>.log
            $LogPath = "$PSScriptRoot\Logs\" +( ($MyInvocation.PSCommandPath | Split-Path -Leaf).split('.') )[0] + ".log"
        }
        if(-not (Test-Path "$PSScriptRoot\Logs")) {
            New-item "$PSScriptRoot\Logs" -ItemType Directory | Out-Null
        }
        if(-not (Test-Path $LogPath)) {
            New-Item $LogPath -ItemType File | Out-Null  
        }
        $timestamp = (Get-Date).toString("yyyy_MM_dd HH:mm:ss")
        $string = "[$timestamp] [$loglevel] :: $Message"
        $string | Out-File -FilePath $LogPath -Append 
        #Writing message here instead of $string because the time stamp + $loglevel addition is visually messy
        if($LogLevel -eq 'Info' -and -not $Silent) {
            Write-Host $Message
        }
        if($LogLevel -eq 'Error') {
            Write-Error $Message
        }
        if($LogLevel -eq 'Warning') {
            Write-Warning $Message
        }
        else {
            Write-Verbose $Message 
        }
}

Function Get-MissingManagerDomain{
    Write-Log "Determining default domain for missing manager field"
    $defaultDomain = Get-AzureADDomain | Where-Object {$_.isDefault -eq "True"} | Select-Object -First 1
    if($defaultDomain){
        return $defaultDomain.Name    
    }
    else{
        $defaultDomain = Get-AzureADDomain | Where-Object {$_.IsRoot -eq "true"} | Select-Object -First 1
        return $defaultDomain.Name
    }

}

function Get-AllMailboxRealUsers{
    # Either reads in usermailboxinfo.csv file if it exists or makes Get-Mailbox call to retrieve info
    try{
        $userinfoPath = "$PSScriptRoot\usermailboxinfo.csv"
        if(-not (Test-Path $userinfoPath)) {
            if(-not $script:MSOLCredential -and -not $RequireCredentialPrompt){
                $script:MSOLCredential = Get-Credential -Message "Please Enter your MSOnline credentials"
            }
            if($RequireCredentialPrompt){
                Connect-MsolService -ErrorAction Stop | Out-Null
            }
            else{
                Write-Log "Connecting to MSOL service with user $($script:MSOLCredential.UserName)..."
                Connect-MsolService -Credential $script:MSOLCredential -ErrorAction Stop | Out-Null
            }

            Write-Log "Calling Get-MsolUser to gather information of real user mailboxes.  If you have a large organization, this could take a while."
            for($i = 1;$i -le $script:MaxRetriesFromThrottling; $i++){
                try{
                    if($injectThrottling -and $i -eq 1){
                        # only inject one fake throttling exception
                        New-FakeThrottlingException
                    }
                    # MSExchRecipientTypeDetails -eq 1, user has a onprem mailbox
                    # MSExchRecipientTypeDetails -eq 2147483648, user has a migrated mailbox
                    # CloudExchangeRecipientDisplayType -eq 1073741824, user has a cloud native mailbox.  in this case MSExchRecipientTypeDetails is blank 
                    $tempUserinfo = Get-MsolUser -EnabledFilter EnabledOnly -All -ErrorAction Stop | Where-Object {$_.MSExchRecipientTypeDetails -eq 1 -or $_.MSExchRecipientTypeDetails -eq 2147483648 -or $_.CloudExchangeRecipientDisplayType -eq 1073741824} | Select-Object $propertiesToGather 
                    # Grabbing PrimarySMTP here in a wonky way so that we can compare it later against the potentially partial org file ( PersonID field ) to skip users we've already gathered info for
                    # since we do not save off the UPN to file as part of the org file info
                    foreach($entry in $tempUserinfo){
                        if($entry.ProxyAddresses){
                            $primarySMTPString = ($entry.ProxyAddresses | Where-Object {$_ -clike "SMTP*"})
                            if(-not $primarySMTPString){
                                Write-Log "User $($entry.UserPrincipalName) has proxy addresses but no primary SMTP address could be found. Setting their primarySMTP to null" -Silent
                                $primarySMTP = $null
                            }
                            else{
                                $primarySMTP = $primarySMTPString.split(':')[1]
                            } 
                        }
                        else{
                            Write-Log "User $($entry.UserPrincipalName) has no ProxyAddresses, setting their primarySMTP to null" -Silent
                            $primarySMTP = $null
                        }
                        $entry | Add-Member -MemberType NoteProperty -Name "PrimarySMTPAddress" -Value $primarySMTP
                        $entry | Add-Member -MemberType NoteProperty -Name "isProcessed" -Value $false 
                    }
                    $userinfo = $tempUserinfo | Select-Object ($propertiesToGather + @("isProcessed",'PrimarySMTPAddress'))
                    $userinfo| Export-Csv -NoTypeInformation -Path $userinfoPath -Encoding UTF8
                    Write-Log "Found $($userinfo.count) user mailboxes using Get-MsolUser"
                    break
                }
                catch{
                    if((IsRetryableThrottlingError -errorMessage $_.Exception.Message) -and ($i -lt $script:MaxRetriesFromThrottling)){
                        Write-Log "Encountered a throttling error during Get-MsolUser call.  Attempting try #$($i+1) after sleeping $script:ThrottleWaitTimeInSeconds seconds. Exception: $($_.Exception.Message)" -LogLevel Warning
                        Start-Sleep -Seconds $script:ThrottleWaitTimeInSeconds
                    }
                    else{
                        throw $_
                    }
                }
            } # end for  
        }
        else{
            #read in $psscriptRoot
            Write-Log "Found a user info csv at $userinfoPath, using that as the list of users to gather organization information for"
            $userInfo = Import-Csv -Path $userinfoPath -Encoding UTF8 -ErrorAction Stop
            Write-Log "Found $($userinfo.count) users in the user info file"
        }    
        return $userinfo
        
    }
    catch{
        Throw $_
    }
    
}

function Get-UserManager{
    param([string]$UserUPN)

    for($i = 1;$i -le $MaxRetriesFromThrottling; $i++){
        try{
            if($injectThrottling -and $i -eq 1){
                # only inject one fake throttling exception
                New-FakeThrottlingException
            }
            $userManagerInfo = Get-AzureADUserManager -ObjectId $UserUPN -ErrorAction Stop
            return $userManagerInfo

        }
        catch{
            if((IsRetryableThrottlingError -errorMessage $_.Exception.Message) -and ($i -lt $MaxRetriesFromThrottling)){
                Write-Log "Encountered a throttling error during Get-AzureADUserManager call.  Attempting try #$($i+1) after sleeping $script:ThrottleWaitTimeInSeconds seconds. Exception: $($_.Exception.Message)" -LogLevel Warning
                Start-Sleep -Seconds $script:ThrottleWaitTimeInSeconds
            }
            else{
                throw $_
            }
        }
    }
}

function Get-BasicUserADInfo{
    # return an object for user Department, PrimarySMTPAddress
    param([string]$UserUPN)

    for($i = 1;$i -le $MaxRetriesFromThrottling; $i++){
        try{
            if($injectThrottling -and $i -eq 1){
                # only inject one fake throttling exception
                New-FakeThrottlingException
            }
            $basicInfo = Get-AzureADUser -ObjectId $UserUPN -ErrorAction Stop
            return $basicInfo 
        }
        catch{
            if((IsRetryableThrottlingError -errorMessage $_.Exception.Message) -and ($i -lt $MaxRetriesFromThrottling)){
                Write-Log "Encountered a throttling error during Get-AzureADUser call.  Attempting try #$($i+1) after sleeping $script:ThrottleWaitTimeInSeconds seconds. Exception: $($_.Exception.Message)" -LogLevel Warning
                Start-Sleep -Seconds $script:ThrottleWaitTimeInSeconds
            }
            else{
                throw $_
            }
        }
    } # end for 
}

function Get-UserDirectReport{
    param($UserUPN)

    for($i = 1;$i -le $MaxRetriesFromThrottling; $i++){
        try{
            if($injectThrottling -and $i -eq 1){
                # only inject one fake throttling exception
                New-FakeThrottlingException
            }
            $directReports = Get-AzureADUserDirectReport -ObjectId $UserUPN -ErrorAction Stop
            return $directReports
        }
        catch{
            if((IsRetryableThrottlingError -errorMessage $_.Exception.Message) -and ($i -lt $MaxRetriesFromThrottling)){
                Write-Log "Encountered a throttling error during Get-AzureADUserDirectReport call.  Attempting try #$($i+1) after sleeping $script:ThrottleWaitTimeInSeconds seconds. Exception: $($_.Exception.Message)" -LogLevel Warning
                Start-Sleep -Seconds $script:ThrottleWaitTimeInSeconds
            }
            else{
                throw $_
            }
        }
    } # end for
    

}

function Verify-CSVSchema{
    param($CSVSchema,
          $CurrentPropertySchema)

    $columns = Get-Member -InputObject $CSVSchema -MemberType NoteProperty
    $userObjProps = Get-Member -InputObject $CurrentPropertySchema -MemberType NoteProperty
    $csvpropertyMissingString = $null
    $objpropertyMissingString = $null
    # Need to ensure all of csv columns are in current obj properties AND all of the object propertoes is in csv columns
    foreach($csvColumnName in $columns.Name){
        if($csvColumnName -notin $userObjProps.Name){
            if($null -eq $csvpropertyMissingString){
                $csvpropertyMissingString = "$csvColumnName"
            }
            else{
                $csvpropertyMissingString += ", $csvColumnName"  
            }    
        }    
    }
    foreach($objProp in $userObjProps.Name){
        if( $objProp -notin $columns.Name){
            if($null -eq $objpropertyMissingString){
                $objpropertyMissingString = "$objProp"
            }
            else{
                $objpropertyMissingString += ", $objProp"  
            }            
        }
    }
    if($csvpropertyMissingString -or $objpropertyMissingString){
        if($csvpropertyMissingString -and -not $objpropertyMissingString){
            $explanationString = "Found columns in the temporary organization csv at $OrgfileLocation that are not selected in the current execution. Please rerun the script without the 'SkipOptionalParameters' switch, or fix the csv file."
            $explanationString += "`n Columns: $csvpropertyMissingString"    
        }
        elseif(-not $csvpropertyMissingString -and $objpropertyMissingString){
            $explanationString = "Found columns in the optional properties not currently in the temporary organization csv.  Please rerun the script with the 'SkipOptionalParameters' switch"
            $explanationString += "`n Columns: $objpropertyMissingString"
            $explanationString += "`n If you have manually removed a column from  the organization file, you may need to delete the organization file at $OrgfileLocation and rerun this script."
        }
        else{
            $explanationString = "Found a schema mismatch between current CSV columns and selected properties to gather.  Please ensure to use the same options between script executions and try again." 
            $explanationString += "`n If you have manually removed a column from  the organization file, you may need to delete it at $OrgfileLocation and rerun this script."
            $explanationString += "`nColumns in the organization csv not in the selected object properties: $csvpropertyMissingString "
            $explanationString += "`nColumns in the select object properties not in the organization csv: $objpropertyMissingString "
        }
        $columnObj = [PSCustomObject]@{CSVColumnSchema= $columns.Name; SelectedPropertySchema=$userObjProps.Name}
        $errorstring = "$explanationString`n `n$($columnObj | ForEach-Object {"CSV:$($_.CSVColumnSchema) `nCurrent Property Schema:$($_.SelectedPropertySchema)"})"
        Throw $errorstring
    }
}

Function Get-CurrentSchema{
    $baseProps = [pscustomobject]@{PersonID=$null  
                                         EffectiveDate = $null
                                         ManagerID = $null
                                         Organization= $null
                                         LevelDesignation = $null
                                         ManagerIsMissingFlag = $null
                                         SupervisorIndicator = $null
                                         NumberOfDirectReports = $null
                                         }
    if(-not $script:SkipOptionalProperties){
        foreach($prop in $script:optionalProperties ){
            $baseProps | Add-Member -MemberType NoteProperty -Name $prop -Value $null           
        }
    }
    return $baseProps
}

function Get-SupervisorIndicator{
    param([string]$SMTP,
          $Table)
    # if we called this function, the user is at least a manager.
    $returnValue = $script:foundAsManagerValue
    # for each direct report, if they are also in the manager table, mark them as a supervisor
    foreach($entry in $Table.$SMTP){
        if($table.Containskey($entry)){
            $returnValue = $script:identifedAsSupervisor
            break
        }
    }
    return $returnValue
}

# script start
Set-StrictMode -Version 1
Write-Log "    ---- Script Execution Start ----"
$scriptVersion = "1.0.1"

try{
    Import-Module "$PSScriptRoot\helper.psm1" -DisableNameChecking -Force -ErrorAction Stop
}
catch{
    Write-Log "Could not import helper module from `'$PSScriptRoot\helper.psm1`'.`n$_ `nExiting."
    Write-Log "Stack trace:: $($_.ScriptStackTrace)" -Silent
    Exit 1    
}
Write-Log "Script version: $scriptVersion" -Silent
if($RequireCredentialPrompt){
    Write-Log "Multi-factor authorization specified"
    Write-Host "Since you specified 'RequireCredentialPrompt' , you will be prompted twice for credential information.
The first is the AzureAD credentials used to connect to the AzureAD service.
If you are prompted a second time it will be for the MSOnline service which is used to gather user mailbox information" -ForegroundColor Cyan
}
if(-not $AzureADCredential -and -not $RequireCredentialPrompt){
    $AzureADCredential= Get-Credential -Message "Enter AzureAD admin user credentials: "
}
try{
    if($RequireCredentialPrompt){
        Write-Log "Connecting to Azure AD service"
        Connect-AzureAD -ErrorAction Stop | Out-Null
    }
    else{
        Write-Log "Connecting to Azure AD service with admin: $($AzureADCredential.UserName)"
        Connect-AzureAD -Credential $AzureADCredential -ErrorAction Stop | Out-Null
    }
}
catch{
    Write-Log "Could not connect to Azure AD service.`n$_  `nExiting" -LogLevel Error
    Write-Log "Stack trace:: $($_.ScriptStackTrace)" -Silent
    exit 1
}
#script level constants
$MaxRetriesFromThrottling = 5
$ThrottleWaitTimeInSeconds= 10 #seconds
$OrgfileLocation = "$PSScriptRoot\WpAOrgFile.csv"

$scriptStart = [datetime]::Now

#Determine EffectiveDate
if($EffectiveDateOption -eq "InitialPull"){
    $effectiveDateDefult = [datetime]::new(1970,1,1).ToString("MM-dd-yyyy")
}
elseif($EffectiveDateOption -eq "Delta"){
    $effectiveDateDefult = [datetime]::now.ToString("MM-dd-yyyy")    
}
if(Test-Path $OrgfileLocation){
    $firstline = Import-Csv $OrgfileLocation | Select-Object -first 1
    if($firstline){
        $EFFECTIVEDATE = $firstline.EffectiveDate
    }
    else{
        $EFFECTIVEDATE = $effectiveDateDefult
    }
}
else{
    $EFFECTIVEDATE = $effectiveDateDefult
}

$LEVELDESIGNATIONVALUE = "__novalue__"

#missing org file defaults
$DEFAULTMISSINGFIELD = "__missing__"
$defaultDomain = Get-MissingManagerDomain
$MISSINGMANAGERFIELD = "UserIsMissingManager@$defaultDomain"
$MISSINGDEPARTMENTFIELD = $DEFAULTMISSINGFIELD

# Error org file defaults
$DEFAULTERRORFIELD = "__error__"
$ERRORDEPARTMENTFIELD = $DEFAULTERRORFIELD
$ERRORMANAGERFIELD = "ErrorDuringManagerRetrieval@$defaultDomain"
$ERRORSUPERVISORINDICATORFIELD = $DEFAULTERRORFIELD

# other values
$idAsManagertemp = "__temp__"
$foundAsManagerValue = "Manager"
$notFoundAsManagerValue = "NotIdentifiedAsManager"
$identifedAsSupervisor = "Manager+"

[System.Collections.ArrayList]$propertiesToGather = @('UserPrincipalName','ProxyAddresses','Department')
$optionalProperties = @('Office','City','Title','Country')
if(-not $SkipOptionalProperties){
    $propertiesToGather += $optionalProperties
}

$MAXUSERSINCACHE = 250

[System.Collections.ArrayList]$userCache = @()

# if we have an org file already, load that into memory to use as a skip list
try{
    $noSMTPCount = 0
    [hashtable]$allUsers = @{}
    Get-AllMailboxRealUsers  | ForEach-Object{
        if($_.PrimarySMTPAddress){
            $allUsers.add($_.PrimarySMTPAddress,$_)
        }
        else{
            Write-Log "User $($_.UserPrincipalName) does not have a primary SMTP address, skipping gathering info." -Silent
            $noSMTPCount++
        }
            
    }# end foreach
    if($noSMTPCount -gt 0){
        Write-Log "Found $noSMTPCount users without a primary SMTP address.  Please see the log file for additional details. Continuing to process users with Primary SMTP addresses "  -LogLevel Warning  
    }
}
catch{
    Write-Log "Could not get all real user mailboxes.`n$_  `nExiting." -LogLevel Error
    Write-Log "Stack trace:: $($_.ScriptStackTrace)" -Silent
    Exit 1
}
if($allUsers.Count -le 0){
    Write-Log "Could not find any real mailbox users to process. Please verify there are either:
 - Entries in the userinfo csv located at: $PSScriptRoot\usermailboxinfo.csv  OR
 - The credentials used for the Get-MsolUser can retrieve user info
 
 Exiting." -LogLevel Error
 Write-Log "Stack trace:: $($_.ScriptStackTrace)" -Silent
    Exit 1
}

# Once a user is identified as a manager, add them to this set to reduce the number of network 
# calls to Get-AzureADUserDirectReports and Get-AzureAdUserManager
# smtp managerID,Arraylist[string] direct report smtp

# [string]managerID, directreportSMTP New-Object System.Collections.Generic.HashSet[string]
[hashtable]$directReportTable = @{}
$orgFilePresent = $False
if(Test-Path $OrgfileLocation){
    $orgFilePresent = $true 
    $firstLine = Import-Csv $OrgfileLocation -Encoding UTF8 -ErrorAction Stop | Select-Object -first 1
    $currentSchema = Get-CurrentSchema
    try{
        Verify-CSVSchema -CSVSchema $firstLine -CurrentPropertySchema $currentSchema 
    }
    catch{
        Write-Log "Failed to validate schema. Exiting.`n`n$($_.Exception.Message)" -LogLevel Error
        exit 1
    }
}

if($orgFilePresent){
    try{
        $tempOrgFileContents = Import-Csv $OrgfileLocation -Encoding UTF8 -ErrorAction Stop
        Write-Log "Out of $($allUsers.Count) users found, $($tempOrgFileContents.Count) users already in the org file located at $OrgfileLocation."
        Foreach($entry in $tempOrgFileContents){
            # for all users we have already gathered AAD info for, set their hashtable value to false so when
            # we later iterate over all the keys, check and skip re-gathereing info for the given user
            try{
                if($allUsers.ContainsKey($entry.PersonID)){
                    $allUsers[$entry.PersonID].isProcessed = $true
                }
            }
            catch{
                Write-Log "Could not access the all users hashtable.  Please resolve the issue and re-run the script.`n$_" -LogLevel Error
                Write-Log "Stack trace:: $($_.ScriptStackTrace)" -Silent
                Exit 1
            }

            try{
                # https://docs.microsoft.com/en-us/windows-server/administration/performance-tuning/powershell/script-authoring-considerations
                [void][mailaddress]$entry.ManagerID     
            }
            catch{
                # the cast attempt to mailaddress type throws an error if the cast fails, eg: __missing__ is not 
                # a valid SMTP address
            }

            try{
                if(-not $directReportTable.ContainsKey($entry.ManagerID)){
                    # create a new entry in the table with the key being the manager SMTP and the value being a new 
                    # direct report set.  Cast to void to avoid writing result to output pipeline
                    [void]($directReportTable.Add($entry.ManagerID,(New-Object System.Collections.Generic.HashSet[string])) )  
                }

                [void](($directReportTable.($entry.ManagerID)).Add($entry.PersonID))
 
            }
            catch{
                Write-Log "$($_.Exception.Message)`nCould not add $($entry.ManagerID) to the manager table" -LogLevel Warning
            }            
        } # end foreach
        Write-Log "Found $($directReportTable.Count) managers in org file"
    }
    catch{
        Write-Log "Could not load current org file"
    }   
}

$filteredUsersCount = $allUsers.Count
$getManagerErrors = 0
$getDepartmentErrors = 0
$getSupervisorIndicatorerrors = 0

Write-Log "Starting processing for Azure AD Mailbox users."
#index for progress
$currentUserCount = 0
#(smtp string, UPN string)
$smtpToUpnLookup = @{}

foreach($entry in $allUsers.GetEnumerator()){
    $user = $allUsers[$entry.name]
    $smtpToUpnLookup.Add($user.PrimarySMTPAddress,$user.UserPrincipalName)
    $currentUserCount++
    Write-Progress -Activity "Gathering initial Azure AD information for user mailboxes.  Currently $currentUserCount out of $($allUsers.Count)" -Id 1 -PercentComplete (($currentUserCount/$allUsers.Count)*100)
    if([System.Convert]::ToBoolean($user.isProcessed)){
        # if the lookup returns false, this user was found in the partially completed org file and 
        # we'll skip re-gathering their info.  The counter is used later to display some stats
        $filteredUsersCount--
        continue    
    }
    
    $currentUserInfo = Get-CurrentSchema
    $currentUserInfo.PersonID= $user.PrimarySMTPAddress
    $currentUserInfo.EffectiveDate = $EFFECTIVEDATE
    $currentUserInfo.LevelDesignation = $LEVELDESIGNATIONVALUE
    if(-not $SkipOptionalProperties){
        foreach($prop in $optionalProperties ){
            $tempvalue = $user.$prop
            if(-not $tempvalue){
                $tempvalue = $DEFAULTMISSINGFIELD
            }
            $currentUserInfo.$prop = $tempvalue 
        }
    } 
    try{
        if($user.Department){
            $currentUserInfo.Organization = $user.Department
        }
        else{
            $basicInfo = Get-BasicUserADInfo -UserUPN $user.UserPrincipalName
            if($basicInfo.Department){
                $currentUserInfo.Organization = $basicInfo.Department
            }
            else{
                $currentUserInfo.Organization = $MISSINGDEPARTMENTFIELD
            }
        }
    }
    catch{
        Write-Log "Error encountered while retrieving Organization information for user: $($user.UserPrincipalName). Setting their Organization field to: $ERRORDEPARTMENTFIELD `n$_" -LogLevel Warning
        $currentUserInfo.Organization = $ERRORDEPARTMENTFIELD
        $getDepartmentErrors++  
    }
    try{
        $managerID = Get-UserManager -UserUPN $user.UserPrincipalName
        if($managerID){
            $currentUserInfo.ManagerID = $managerID.mail # primary SMTP
            $currentUserInfo.ManagerIsMissingFlag = $False
            if(-not $directReportTable.ContainsKey($managerID.mail)){
                [void]($directReportTable.Add($managerID.mail,(New-Object System.Collections.Generic.HashSet[string])))
            }
            [void](($directReportTable.($managerID.mail)).Add($user.PrimarySMTPAddress))

        }
        else{
            $currentUserInfo.ManagerID = $MISSINGMANAGERFIELD
            $currentUserInfo.ManagerIsMissingFlag = $true
        }
    }
    catch{
        Write-Log "Error encountered while retrieving Manager information for user: $($user.UserPrincipalName). Setting their ManagerID field to: $ERRORMANAGERFIELD `n$_" -LogLevel Warning
        $currentUserInfo.ManagerID = $ERRORMANAGERFIELD
        $currentUserInfo.ManagerIsMissingFlag = $true
        $getManagerErrors++
    }
    try{
        $currentUserInfo.SupervisorIndicator = $idAsManagertemp
        $currentUserInfo.NumberOfDirectReports = $idAsManagertemp
    }
    catch{
        Write-Log "Error encountered while retrieving Direct Report information for user: $($user.UserPrincipalName). Setting their SupervisorIndicator field to: $ERRORSUPERVISORINDICATORFIELD `n$_" -LogLevel Warning
        $currentUserInfo.SupervisorIndicator = $ERRORSUPERVISORINDICATORFIELD

    }
    try{
        [void]$userCache.Add($currentUserInfo)
    }
    catch{
       Write-Log "Failed to write current user to cache `n$_"
    }
    try{
        if($userCache.Count -eq $MAXUSERSINCACHE){
            $userCache | Export-Csv -Path $OrgfileLocation -Append -Encoding UTF8 -NoTypeInformation -ErrorAction Stop
            $userCache.Clear()
            Write-Log "Wrote $MAXUSERSINCACHE users to the temporary org file located at $OrgfileLocation" -Silent
        }
    }
    catch{
        Write-Log "Could not write current batch of users to $OrgfileLocation. Please resolve the error then rerun the script so the script can proceed with identifying managers.`n$_ `nExiting." -LogLevel Error
        Write-Log "Stack trace:: $($_.ScriptStackTrace)" -Silent
        exit 1
    }
}
try{
    if($userCache.Count -gt 0){
        $userCache | Export-Csv -Path $OrgfileLocation -Append -Encoding UTF8 -NoTypeInformation -ErrorAction Stop
        $userCache.Clear()
    }
}
catch{
    Write-Log "Could not write current batch of users to $OrgfileLocation. Please resolve the error then re-run the script.`n$_`nExiting." -LogLevel Error
    Write-Log "Stack trace:: $($_.ScriptStackTrace)" -Silent
    exit 1
}

Write-Progress -Id 1 -Completed -Activity "First pass processing completed"

try{
    $currentOrgFile = Import-Csv -Path $OrgfileLocation -Encoding UTF8 -ErrorAction Stop
}
catch{
    Write-Log "Could not load org file.  Please verify a csv file exists at $OrgfileLocation and re-run this script to continue with identifedAsManager classification.`n$_`nExiting" -LogLevel Error
    Write-Log "Stack trace:: $($_.ScriptStackTrace)" -Silent
    Exit 1    
}
try{
    $currentCount= 0
    $alreadyFoundManagerInfoCount = 0
    $requiredAnUpdateCount = 0
    $lookupFailures = 0
    $totalCount = $currentOrgFile.Count
    # now that we have full manager information, for every user we didn't previously identify,
    # go back through and look them up in the completed manager set
    $currentOrgFile | ForEach-Object{
        $currentCount++
        $temp = $_
        Write-Progress -Activity "Gathering direct report information for user mailboxes.  Currently $currentCount out of $totalCount" -Id 2 -PercentComplete (($currentCount/$totalCount)*100) 

        if($temp.SupervisorIndicator -eq $idAsManagertemp){
            # only update this count if an update to the current in-memory collection is required.  This prevents writing the same information
            # over and over
            $requiredAnUpdateCount++
            if($directReportTable.ContainsKey($temp.PersonID)){
                $temp.NumberOfDirectReports = ($directReportTable.($temp.PersonID)).Count
                $temp.SupervisorIndicator= Get-SupervisorIndicator -SMTP $temp.PersonID  -Table $directReportTable     
            }
            else{
                #Version 2 will not do AD lookup in the situation where there are no hit in the direct report table
                $temp.NumberOfDirectReports = 0
                $temp.SupervisorIndicator = $notFoundAsManagerValue
            }    
        }
        else{
            ++$alreadyFoundManagerInfoCount    
        }
        if($requiredAnUpdateCount -eq $MAXUSERSINCACHE){
            $requiredAnUpdateCount = 0
            #save every so often
            $currentOrgFile | Export-Csv -path $OrgfileLocation -NoTypeInformation -Force -Encoding UTF8
            Write-Log "Updated $OrgfileLocation with the latest $MAXUSERSINCACHE processed users" -Silent
        }
    }
    # overwrite org file with latest results
    $currentOrgFile | Export-Csv -path $OrgfileLocation -NoTypeInformation -Force -Encoding UTF8
}
catch{
    Write-Log "Could not gather direct report information for azure ad users in the org file.  Please fix the error and rerun this script. `n$_" -LogLevel Error
    Write-Log "Stack trace:: $($_.ScriptStackTrace)" -Silent
    Exit 1
}
Write-Progress -Activity "Gathering direct report information for user mailboxes.  Currently $currentCount out of $totalCount" -Id 2 -Completed
$scriptEnd = [datetime]::Now

Write-Log "Found that $alreadyFoundManagerInfoCount users were already identified as manager or not." -Silent
$timespan = $scriptEnd - $scriptStart
if($timespan.Totalminutes -lt 1 ){
    $formattedTimespan = $timespan.TotalSeconds.ToString('#.##') 
    $unitString = "seconds"
      
}
elseif($timespan.Totalminutes -le 60){
    $formattedTimespan = $timespan.TotalMinutes.ToString('#.##')
    $unitString = "minutes"  
}
else{
    $formattedTimespan = $timespan.TotalHours.ToString('#.##')
    $unitString = "hours"     
}

Write-Log "Execution completed.  Here are some stats: "
$processedUsers = [math]::Max($filteredUsersCount, $requiredAnUpdateCount)
Write-Log "

Total Execution Time: $formattedTimespan $unitString

Users processed this run: $processedUsers out of $($allUsers.Count)
Errors retrieving manager information: $getManagerErrors
Errors retrieving department information: $getDepartmentErrors
Errors retrieving direct report information:$getSupervisorIndicatorerrors
SMTP to UPN lookup failures using cache: $lookupFailures
Users skipped as a result of missing Primary SMTP: $noSMTPCount"


$totalUsersInCSV = $currentOrgFile.Count
$departmentErrorsInCsv = 0
$departmentMissingInCsv = 0

$managerIDErrorsInCsv = 0
$managerIDMissingInCsv = 0

$supervisorIndicatorErrorsInCsv = 0

foreach($entry in $currentOrgFile){
    if($entry.Organization -eq $ERRORDEPARTMENTFIELD){
        $departmentErrorsInCsv++
    }
    elseif($entry.Organization -eq $MISSINGDEPARTMENTFIELD ){
        $departmentMissingInCsv++
    }

    if($entry.ManagerID -eq $ERRORMANAGERFIELD ){
        $managerIDErrorsInCsv++
    }
    elseif($entry.ManagerID -eq $MISSINGMANAGERFIELD){
        $managerIDMissingInCsv++
    }

    if($entry.supervisorIndicator -eq $ERRORSUPERVISORINDICATORFIELD){
        $supervisorIndicatorErrorsInCsv++
    }
}

$managerIDCoverage = [double]((($totalUsersInCSV - ($managerIDErrorsInCsv+$managerIDMissingInCsv))/$totalUsersInCSV ) * 100).toString('#.##')
$departmentCoverage = [double]((($totalUsersInCSV - ($departmentErrorsInCsv+$departmentMissingInCsv))/$totalUsersInCSV ) * 100).toString('#.##')
$supervisorIndicatorCoverage = [double]((($totalUsersInCSV - $supervisorIndicatorErrorsInCsv)/$totalUsersInCSV ) * 100).toString('#.##')
# gather some org stats if there are at least 1 non-missing org value
$groups = $currentOrgFile | Group-Object organization | Where-Object {$_.Name -ne '__missing__'}
$countWithOrgValue = 0
$groups| ForEach-Object {$countWithOrgValue += $_.Count}
$orgStatsString = $null
if($groups.Count -gt 0){
    $orgStatsString = "`n`tTotal number of Organizations found: $($groups.count)
    Average person count per organization: $([double]($countWithOrgValue/$groups.count).ToString('#'))"   
}

Write-Log "
---------------------------------------------------------
Current Coverage with auto-generated Org file at $($OrgfileLocation):
    ManagerID coverage: $($managerIDCoverage)%
    Organization coverage: $($departmentCoverage)%
    SupervisorIndicator coverage: $($supervisorIndicatorCoverage)% $orgStatsString
"

Write-Log "Please be advised when inspecting the generated organization file that any missing or errored manager fields are tagged with a default value:
No Manger Found in Azure Active Directory: `'$MISSINGMANAGERFIELD`'
An Error occurred when attempting to retrieve the user's managerID: `'$ERRORMANAGERFIELD`' "