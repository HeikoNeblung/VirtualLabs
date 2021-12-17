﻿<#
Copyright 2017 Microsoft Corporation

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.


Version 2.0 February 2017

.SYNOPSIS
This is a sample script for automatically scaling Remote Desktop Services (RDS) in Micrsoft Azure

.Description
This script will automatically start/stop remote desktop (RD) session host VMs based on the number of user sessions and peak/off-peak time period specified in the configuration file.
During the peak hours, the script will start necessary session hosts in the session collection to meet the demands of users.
During the off-peak hours, the script will shutdown the session hosts and only keep the minimum number of session hosts.
You can schedule the script to run at a certain time interval on the RD Connection Broker server in your RDS deployment in Azure.
#>

<#
.SYNOPSIS
Function for writing the log
#>
Function Write-Log {
    Param(
        [int]$level
        , [string]$Message
        , [ValidateSet("Info", "Warning", "Error")][string]$severity = 'Info'
        , [string]$logname = $rdslog
        , [string]$color = "white"
    )
    $time = get-date
    Add-Content $logname -value ("{0} - [{1}] {2}" -f $time, $severity, $Message)
    if ($interactive) {
        switch ($severity) {
            'Error' { $color = 'Red' }
            'Warning' { $color = 'Yellow' }
        }
        if ($level -le $VerboseLogging) {
            if ($color -match "Red|Yellow") {
                Write-Host ("{0} - [{1}] {2}" -f $time, $severity, $Message) -ForegroundColor $color -BackgroundColor Black
                if ($severity -eq 'Error') {
                    throw $Message
                }
            }
            else {
                Write-Host ("{0} - [{1}] {2}" -f $time, $severity, $Message) -ForegroundColor $color
            }
        }
    }
    else {
        switch ($severity) {
            'Info' { Write-Verbose -Message $Message }
            'Warning' { Write-Warning -Message $Message }
            'Error' {
                throw $Message
            }
        }
    }
}

<#
.SYNOPSIS
Function for writing the usage log
#>
Function Write-UsageLog {
    Param(
        [string]$collectionName,
        [int]$corecount,
        [int]$vmcount,
        [string]$logfilename = $rdsusagelog
    )
    $time = get-date
    Add-Content $logfilename -value ("{0}, {1}, {2}, {3}" -f $time, $collectionName, $corecount, $vmcount)
}

<#
.SYNOPSIS
Function for getting VM scale sets insatnce running state. Returns true when instance is running and false when not running
#>
Function Get-VmssInstanceRunningState {
    Param(
        [string]$ResourceGroupName,
        [string]$ScaleSetName,
        [int]$InstanceId
    )
    $IsVmRunning = $false

    $InstanceDetail = Get-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $ScaleSetName -InstanceId $InstanceId -InstanceView
    foreach ($VMStatus in $InstanceDetail.Statuses) {
        if ($VMStatus.Code.CompareTo("PowerState/running") -eq 0) {
            $IsVmRunning = $true
            break
        }
    }
    return $IsVmRunning
}

<#
.SYNOPSIS
Function for creating variable from XML
#>
Function Set-ScriptVariable ($Name, $Value) {
    Invoke-Expression ("`$Script:" + $Name + " = `"" + $Value + "`"")
}

<#
Variables
#>
#Current Path
$CurrentPath = Split-Path $script:MyInvocation.MyCommand.Path

#XMl Configuration File Path
$XMLPath = "$CurrentPath\Config.xml"

#Log path
$rdslog = "$CurrentPath\RDSScale.log"

#usage log path
$rdsusagelog = "$CurrentPath\RDSUsage.log"


###### Verify XML file ######
If (Test-Path $XMLPath) {
    write-verbose "Found $XMLPath"
    write-verbose "Validating file..."
    try {
        $Variable = [XML] (Get-Content $XMLPath)
    }
    catch {
        # $Validate = $false
        Write-Error "$XMLPath is invalid. Check XML syntax - Unable to proceed"
        Write-Log 3 "$XMLPath is invalid. Check XML syntax - Unable to proceed" "Error"
        exit 1
    }
}
Else {
    # $Validate = $false
    write-error "Missing $XMLPath - Unable to proceed"
    Write-Log 3 "Missing $XMLPath - Unable to proceed" "Error"
    exit 1
}

##### Load XML Configuration values as variables #########
Write-Verbose "loading values from Config.xml"
$Variable = [XML] (Get-Content "$XMLPath")
$Variable.RDSScale.Azure | ForEach-Object { $_.Variable } | Where-Object { $_.Name -ne $null } | ForEach-Object { Set-ScriptVariable -Name $_.Name -Value $_.Value }
$Variable.RDSScale.RDSScaleSettings | ForEach-Object { $_.Variable } | Where-Object { $_.Name -ne $null } | ForEach-Object { Set-ScriptVariable -Name $_.Name -Value $_.Value }

#Load RDS ps Module
Import-Module -Name RemoteDesktop

Try {
    $ConnectionBrokerFQDN = (Get-RDConnectionBrokerHighAvailability -ErrorAction Stop).ActiveManagementServer
}
Catch {
    Write-Host "RD Active Management Server unreachable. Setting to the local host."
    Set-RDActiveManagementServer –ManagementServer "$env:computername.$env:userdnsdomain"
    $ConnectionBrokerFQDN = (Get-RDConnectionBrokerHighAvailability).ActiveManagementServer
}

If (!$ConnectionBrokerFQDN) {
    # If null then this must not be a HA RDCB configuration, so assume RDCB is the local host.
    $ConnectionBrokerFQDN = "$env:computername.$env:userdnsdomain"
}

Write-Host "RD Active Management server:" $ConnectionBrokerFQDN

If ("$env:computername.$env:userdnsdomain" -ne $ConnectionBrokerFQDN) {
    Write-Host "RD Active Management Server is not the local host. Exiting."
    Write-Log 1 "RD Active Management Server is not the local host. Exiting." "Info"

    exit 0
}

#Load Azure ps module
Import-Module -Name Az

#To use certificate based authentication for service principal, please uncomment the following line
#Add-AzureRmAccount -ServicePrincipal -CertificateThumbprint $AADAppCertThumbprint -ApplicationId $AADApplicationId -TenantId $AADTenantId

#The the following three lines is to use password/secret based authentication for service principal, to use certificate based authentication, please comment those lines, and uncomment the above line
# $secpasswd = ConvertTo-SecureString $AADServicePrincipalSecret -AsPlainText -Force
# $appcreds = New-Object System.Management.Automation.PSCredential ($AADApplicationId, $secpasswd)

# don't save azure credentials
Disable-AzContextAutosave -Scope Process
# Add-AzureRmAccount -ServicePrincipal -Credential $appcreds -TenantId $AADTenantId
# Connect-AzAccount -ServicePrincipal -Credential $appcreds -TenantId $AADTenantId -SubscriptionId $CurrentSubscriptionId
Connect-AzAccount -Identity -SubscriptionId $CurrentSubscriptionId

#select the current Azure Subscription specified in the config
# Select-AzureRmSubscription -SubscriptionName $CurrentAzureSubscriptionName

#Construct Begin time and End time for the Peak period
$CurrentDateTime = Get-Date
Write-Log 3 "Starting RDS Scale Optimization: Current Date Time is: $CurrentDateTime" "Info"

#Azure is using UTC time, justify it to the pacific time
# $CurrentDateTime = $CurrentDateTime.AddHours($TimeDifferenceInHours);

$BeginPeakDateTime = [DateTime]::Parse($CurrentDateTime.ToShortDateString() + ' ' + $BeginPeakTime)

$EndPeakDateTime = [DateTime]::Parse($CurrentDateTime.ToShortDateString() + ' ' + $EndPeakTime)

#check the calculated end time is later than begin time in case of time zone
if ($EndPeakDateTime -lt $BeginPeakDateTime) {
    $EndPeakDateTime = $EndPeakDateTime.AddDays(1)
}

#get the available collections in the RDS
try {
    $Collections = Get-RDSessionCollection -ConnectionBroker $ConnectionBrokerFQDN -ErrorAction Stop
}
catch {
    Write-Log 1 "Failed to retrieve RDS collections: $($_.exception.message)" "Error"
    Exit 1
}

#check if it is during the peak or off-peak time
if ($CurrentDateTime -ge $BeginPeakDateTime -and $CurrentDateTime -le $EndPeakDateTime) {
    #Peak time
    Write-Host "It is in peak hours now"
    Write-Log 3 "Peak hours: starting session hosts as needed based on current workloads." "Info"
    Write-Log 1 "Looping thru available collection list ..." "Info"

    Foreach ($collection in $Collections) {
        Write-Host ("Processing collection {0}" -f $collection.CollectionName)
        Write-Log 1 "Processing collection: $($collection.CollectionName)" "Info"

        #Get the Session Hosts in the collection
        try {
            $RDSessionHost = Get-RDSessionHost -ConnectionBroker $ConnectionBrokerFQDN -CollectionName $collection.CollectionName
        }
        catch {
            Write-Log 1 "Failed to retrieve RDS session hosts in collection $($collection.CollectionName) : $($_.exception.message)" "Error"
            Exit 1
        }

        #Get the User Sessions in the collection
        try {
            $CollectionUserSessions = Get-RDUserSession -ConnectionBroker $ConnectionBrokerFQDN -CollectionName $collection.CollectionName -ErrorAction Stop
        }
        catch {
            Write-Log 1 "Failed to retrieve user sessions in collection:$($collection.CollectionName) with error: $($_.exception.message)" "Error"
            Exit 1
        }

        #check the number of running session hosts
        $numberOfRunningHost = 0

        #total of running cores
        $totalRunningCores = 0

        #total capacity of sessions of running VMs
        $AvailableSessionCapacity = 0

        # Get Azure Virtual Machines
        try {
            $VMSSInstances = Get-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $ScaleSetName -ErrorAction Stop
        }
        catch {
            Write-Log 1 "Failed to retrieve VMSS $ScaleSetName instance information for resource group: $ResourceGroupName from Azure with error: $($_.exception.message)" "Error"
            Exit 1
        }

        # get powerstate of all sessionhosts
        foreach ($sessionHost in $RDSessionHost) {
            write-log 1 "Checking session host: $($sessionHost.SessionHost)" "Info"

            foreach ($VMSSInstance in $VMSSInstances) {
                if ($sessionHost.SessionHost.ToLower().Contains($VMSSInstance.OsProfile.ComputerName.ToLower() + ".")) {

                    #check the azure vm is running or not
                    $IsVmRunning = Get-VmssInstanceRunningState -ResourceGroupName $ResourceGroupName -ScaleSetName $ScaleSetName -InstanceId $VMSSInstance.InstanceId
                    if ($IsVmRunning -eq $true) {
                        $numberOfRunningHost = $numberOfRunningHost + 1

                        # we need to calculate available capacity of sessions
                        $coresAvailable = Get-AzVMSize -Location $VMSSInstance.Location | Where-Object Name -eq $VMSSInstance.Sku.Name
                        $AvailableSessionCapacity = $AvailableSessionCapacity + $coresAvailable.NumberOfCores * $SessionThresholdPerCPU

                        $totalRunningCores = $totalRunningCores + $coresAvailable.NumberOfCores
                    }
                    Break # break out of the inner foreach loop once a match is found and checked
                }
            }
        } # end get powerState of all sessionhosts

        write-host "Current number of running hosts: " $numberOfRunningHost
        write-log 1 "Current number of running hosts: $numberOfRunningHost" "Info"

        if ($numberOfRunningHost -lt $PeakTimeMinimumNumberOfRDSH) {

            Write-Log 1 "Current number of running session hosts is less than minimum requirements, start session host ..." "Info"

            #start VM to meet the minimum requirement
            foreach ($sessionHost in $RDSessionHost) {

                #refresh the azure VM list
                try {
                    $VMSSInstances = Get-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $ScaleSetName -ErrorAction Stop
                }
                catch {
                    Write-Log 1 "Failed to retrieve VMSS $ScaleSetName instance information for resource group: $ResourceGroupName from Azure with error: $($_.exception.message)" "Error"
                    Exit 1
                }
                #check whether the number of running VMs meets the minimum or not
                if ($numberOfRunningHost -lt $PeakTimeMinimumNumberOfRDSH) {
                    foreach ($VMSSInstance in $VMSSInstances) {
                        if ($sessionHost.SessionHost.ToLower().Contains($VMSSInstance.OsProfile.ComputerName.ToLower() + ".")) {
                            #check if the azure VM is running or not
                            $IsVmRunning = Get-VmssInstanceRunningState -ResourceGroupName $ResourceGroupName -ScaleSetName $ScaleSetName -InstanceId $VMSSInstance.InstanceId

                            if ($IsVmRunning -eq $false) {
                                #start the azure VM
                                try {
                                    Write-Log 1 "Starting Azure VM: $($VMSSInstance.OsProfile.ComputerName) and waiting for it to start up ..." "Info"
                                    Start-AzVmss -ResourceGroupName $ResourceGroupName -VMScaleSetName $ScaleSetName -InstanceId $VMSSInstance.InstanceId -ErrorAction Stop
                                }
                                catch {
                                    Write-Log 1 "Failed to start Azure VM: $($VMSSInstance.OsProfile.ComputerName) with error: $($_.exception.message)" "Error"
                                    Exit 1
                                }

                                try {
                                    Write-Log 1 "Disabling DrainMode on $($sessionHost.SessionHost)" "Info"
                                    Set-RDSessionHost -SessionHost $sessionHost.SessionHost -NewConnectionAllowed Yes -ConnectionBroker $ConnectionBrokerFQDN -ErrorAction Stop
                                }
                                catch {
                                    Write-Log 1 "Failed to disable DrainMode on $($sessionHost.SessionHost)" "Error"
                                    Exit 1
                                }

                                # we need to calculate available capacity of sessions
                                $coresAvailable = Get-AzVMSize -Location $VMSSInstance.Location | Where-Object Name -eq $VMSSInstance.Sku.Name
                                $AvailableSessionCapacity = $AvailableSessionCapacity + $coresAvailable.NumberOfCores * $SessionThresholdPerCPU
                                $numberOfRunningHost = $numberOfRunningHost + 1
                                $totalRunningCores = $totalRunningCores + $coresAvailable.NumberOfCores
                                if ($numberOfRunningHost -ge $PeakTimeMinimumNumberOfRDSH) {
                                    break;
                                }
                            }
                            Break # break out of the inner foreach loop once a match is found and checked
                        }
                    }
                }
            }
        } # if ($numberOfRunningHost -lt $PeakTimeMinimumNumberOfRDSH) {
        else {
            #check if the available capacity meets the number of sessions or not
            write-Log 1 "Current total number of user sessions: $($CollectionUserSessions.Count)" "Info"
            Write-Log 1 "Current available session capacity is: $AvailableSessionCapacity" "Info"
            if ($CollectionUserSessions.Count -ge $AvailableSessionCapacity) {
                Write-Log 1 "Current available session capacity is less than demanded user sessions, starting session host" "Info"
                #running out of capacity, we need to start more VMs if there are any
                # Get Azure Virtual Machines
                try {
                    $VMSSInstances = Get-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $ScaleSetName -ErrorAction Stop
                }
                catch {
                    Write-Log 1 "Failed to retrieve VMSS $ScaleSetName instance information for resource group: $ResourceGroupName from Azure with error: $($_.exception.message)" "Error"
                    Exit 1
                }
                foreach ($sessionHost in $RDSessionHost) {
                    if ($CollectionUserSessions.Count -ge $AvailableSessionCapacity) {
                        foreach ($VMSSInstance in $VMSSInstances) {
                            #check if the azure VM is running or not
                            $IsVmRunning = Get-VmssInstanceRunningState -ResourceGroupName $ResourceGroupName -ScaleSetName $ScaleSetName -InstanceId $VMSSInstance.InstanceId


                            if ($sessionHost.SessionHost.ToLower().Contains($VMSSInstance.OsProfile.ComputerName.ToLower() + ".")) {
                                #check if the Azure VM is running or not
                                if ($IsVmRunning -eq $false) {
                                    #start the Azure VM
                                    try {
                                        Write-Log 1 "Starting Azure VM: $($VMSSInstance.OsProfile.ComputerName) and waiting for it to start up ..." "Info"
                                        Start-AzVmss -ResourceGroupName $ResourceGroupName -VMScaleSetName $ScaleSetName -InstanceId $VMSSInstance.InstanceId -ErrorAction Stop
                                    }
                                    catch {
                                        Write-Log 1 "Failed to start Azure VM: $($VMSSInstance.OsProfile.ComputerName) with error: $($_.exception.message)" "Error"
                                        Exit 1
                                    }

                                    try {
                                        Write-Log 1 "Disabling DrainMode on $($sessionHost.SessionHost)" "Info"
                                        Set-RDSessionHost -SessionHost $sessionHost.SessionHost -NewConnectionAllowed Yes -ConnectionBroker $ConnectionBrokerFQDN -ErrorAction Stop
                                    }
                                    catch {
                                        Write-Log 1 "Failed to disable DrainMode on $($sessionHost.SessionHost)" "Error"
                                        Exit 1
                                    }

                                    # we need to calculate available capacity of sessions
                                    $coresAvailable = Get-AzVMSize -Location $VMSSInstance.Location | Where-Object Name -eq $VMSSInstance.Sku.Name
                                    $AvailableSessionCapacity = $AvailableSessionCapacity + $coresAvailable.NumberOfCores * $SessionThresholdPerCPU
                                    $numberOfRunningHost = $numberOfRunningHost + 1
                                    $totalRunningCores = $totalRunningCores + $coresAvailable.NumberOfCores

                                    Write-Log 1 "new available session capacity is: $AvailableSessionCapacity" "Info"
                                    if ($AvailableSessionCapacity -gt $CollectionUserSessions.Count) {
                                        break;
                                    }
                                }
                                Break # break out of the inner foreach loop once a match is found and checked
                            }
                        }
                    }
                }
            }
        }

        #write to the usage log
        Write-UsageLog $collection.CollectionName $totalRunningCores $numberOfRunningHost
    }
}
else {
    write-host "It is Off-peak hours"
    write-log 3 "It is off-peak hours. Starting to scale down RD session hosts..." "Info"
    Foreach ($collection in $Collections) {

        Write-Host ("Processing collection {0}" -f $collection.CollectionName)

        Write-Log 3 "Processing collection $($collection.CollectionName)"
        #Get the Session Hosts in the collection
        try {
            $RDSessionHost = Get-RDSessionHost -ConnectionBroker $ConnectionBrokerFQDN -CollectionName $collection.CollectionName
        }
        catch {
            Write-Log 1 "Failed to retrieve session hosts in collection: $($collection.CollectionName) with error: $($_.exception.message)" "Error"
            Exit 1
        }

        #check the number of running session hosts
        $numberOfRunningHost = 0

        #total of running cores
        $totalRunningCores = 0

        foreach ($sessionHost in $RDSessionHost) {

            #refresh the Azure VM list
            try {
                $VMSSInstances = Get-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $ScaleSetName -ErrorAction Stop
            }
            catch {
                Write-Log 1 "Failed to retrieve VMSS $ScaleSetName instance information for resource group: $ResourceGroupName from Azure with error: $($_.exception.message)" "Error"
                Exit 1
            }
            foreach ($VMSSInstance in $VMSSInstances) {
                if ($sessionHost.SessionHost.ToLower().Contains($VMSSInstance.OsProfile.ComputerName.ToLower() + ".")) {
                    #check if the azure VM is running or not
                    $IsVmRunning = Get-VmssInstanceRunningState -ResourceGroupName $ResourceGroupName -ScaleSetName $ScaleSetName -InstanceId $VMSSInstance.InstanceId

                    if ($IsVmRunning -eq $true) {
                        $numberOfRunningHost = $numberOfRunningHost + 1

                        # we need to calculate available capacity of sessions
                        $coresAvailable = Get-AzVMSize -Location $VMSSInstance.Location | Where-Object Name -eq $VMSSInstance.Sku.Name
                        $AvailableSessionCapacity = $AvailableSessionCapacity + $coresAvailable.NumberOfCores * $SessionThresholdPerCPU

                        $totalRunningCores = $totalRunningCores + $coresAvailable.NumberOfCores
                    }
                    Break # break out of the inner foreach loop once a match is found and checked
                }
            }
        }

        write-host "Current number of running hosts: " $numberOfRunningHost
        write-log 1 "Current number of running hosts: $numberOfRunningHost" "Info"

        if ($numberOfRunningHost -gt $MinimumNumberOfRDSH) {
            Write-Log 1 "Current number of running session hosts is greater than minimum requirements, stopping session host ..." "Info"
            #shutdown VM to meet the minimum requirement

            #refresh the Azure VM list
            try {
                $VMSSInstances = Get-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $ScaleSetName -ErrorAction Stop
            }
            catch {
                Write-Log 1 "Failed to retrieve VMSS $ScaleSetName instance information for resource group: $ResourceGroupName from Azure with error: $($_.exception.message)" "Error"
                Exit 1
            }
            foreach ($sessionHost in $RDSessionHost) {
                if ($numberOfRunningHost -gt $MinimumNumberOfRDSH) {
                    foreach ($VMSSInstance in $VMSSInstances) {
                        if ($sessionHost.SessionHost.ToLower().Contains($VMSSInstance.OsProfile.ComputerName.ToLower() + ".")) {
                            #check if the azure VM is running or not
                            $IsVmRunning = Get-VmssInstanceRunningState -ResourceGroupName $ResourceGroupName -ScaleSetName $ScaleSetName -InstanceId $VMSSInstance.InstanceId

                            if ($IsVmRunning -eq $true) {
                                #ensure the running Azure VM is set as drain mode
                                try {
                                    Write-Log 1 "Enable DrainMode on $($sessionHost.SessionHost)" "Info"
                                    Set-RDSessionHost -SessionHost $sessionHost.SessionHost -NewConnectionAllowed NotUntilReboot -ConnectionBroker $ConnectionBrokerFQDN -ErrorAction Stop
                                }
                                catch {
                                    write-log 1 "Failed to set drain mode on session host: $($sessionHost.SessionHost) with error: $($_.exception.message)" "Error"
                                    Exit 1
                                }

                                #notify user to log off session
                                #Get the user sessions in the collection
                                try {
                                    $CollectionUserSessions = Get-RDUserSession -ConnectionBroker $ConnectionBrokerFQDN -CollectionName $collection.CollectionName -ErrorAction Stop
                                }
                                catch {
                                    Write-Log 1 "Failed to retrieve user sessions in collection: $($collection.CollectionName) with error: $($_.exception.message)" "Error"
                                    Exit 1
                                }

                                Write-Log 1 "Counting the current sessions on the host..." "Info"
                                $existingSession = 0
                                foreach ($session in $CollectionUserSessions) {
                                    if ($session.HostServer -eq $sessionHost.SessionHost) {
                                        if ($LimitSecondsToForceLogOffUser -ne 0) {
                                            #send notification
                                            try {
                                                Send-RDUserMessage -HostServer $session.HostServer -UnifiedSessionID $session.UnifiedSessionId -MessageTitle $LogOffMessageTitle -MessageBody "$($LogOffMessageBody) You will logged off in $($LimitSecondsToForceLogOffUser) seconds." -ErrorAction Stop
                                            }
                                            catch {
                                                write-log 1 "Failed to send message to user with error: $($_.exception.message)" "Error"
                                                Exit 1
                                            }
                                        }
                                        $existingSession = $existingSession + 1
                                    }
                                }

                                #wait for n seconds to log off user
                                Start-Sleep -Seconds $LimitSecondsToForceLogOffUser

                                if ($LimitSecondsToForceLogOffUser -ne 0) {
                                    #force users to log off
                                    Write-Log 1 "Force users to log off on $($sessionHost.SessionHost) ..." "Info"
                                    try {
                                        $CollectionUserSessions = Get-RDUserSession -ConnectionBroker $ConnectionBrokerFQDN -CollectionName $collection.CollectionName -ErrorAction Stop
                                    }
                                    catch {
                                        write-log 1 "Failed to retrieve list of user sessions in collection: $($collection.CollectionName) with error: $($_.exception.message)" "Error"
                                        exit 1
                                    }
                                    foreach ($session in $CollectionUserSessions) {
                                        if ($session.HostServer -eq $sessionHost.SessionHost) {
                                            #log off user
                                            try {
                                                Invoke-RDUserLogoff -HostServer $session.HostServer -UnifiedSessionID $session.UnifiedSessionId -Force -ErrorAction Stop
                                                $existingSession = $existingSession - 1
                                            }
                                            catch {
                                                write-log 1 "Failed to log off user with error: $($_.exception.message)" "Error"
                                                exit 1
                                            }
                                        }
                                    }
                                }

                                #check the session count before shutting down the VM
                                if ($existingSession -eq 0) {

                                    #shutdown the Azure VM
                                    try {
                                        Write-Log 1 "Stopping Azure VM: $($VMSSInstance.OsProfile.ComputerName) and waiting for it to stop ..." "Info"
                                        Stop-AzVmss -ResourceGroupName $ResourceGroupName -VMScaleSetName $ScaleSetName -InstanceId $VMSSInstance.InstanceId -Force -ErrorAction Stop
                                    }
                                    catch {
                                        Write-Log 1 "Failed to stop Azure VM: $($VMSSInstance.OsProfile.ComputerName) with error: $($_.exception.message)" "Error"
                                        Exit 1
                                    }

                                    $coresFreedUp = Get-AzVMSize -Location $VMSSInstance.Location | Where-Object Name -eq $VMSSInstance.Sku.Name
                                    #decrement the number of running session host
                                    $numberOfRunningHost = $numberOfRunningHost - 1
                                    $totalRunningCores = $totalRunningCores - $coresFreedUp.NumberOfCores
                                }
                                else {
                                    Write-Log 1 "Can't shutdown. There are $existingSession sessions left on $($sessionHost.SessionHost)" "Error"
                                }
                            }
                            Break # break out of the inner foreach loop once a match is found and checked
                        }
                    }
                }
            }
        }

        #write to the usage log
        Write-UsageLog $collection.CollectionName $totalRunningCores $numberOfRunningHost
    }
}

Write-Log 3 "End RDS Scale Optimization." "Info"
