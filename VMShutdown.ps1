<#
    .SYNOPSIS
        This Azure Automation runbook automates the shutdown of virtual machines

    .DESCRIPTION

    .PARAMETER connectionName
        The name of an AzureServicePrincipal connection configureed in the automation assets
        that has contributor access to subscriptions.

    .INPUTS
        None.

    .OUTPUTS
#>

param(
    [parameter(Mandatory=$false)]
	[String] $connectionName = "AzureRunAsConnection"
)

$VERSION = "0.1"

# Checks the shutDownAt string to see if the this pime has passed today.
# shutDownAt can be a time value, or list of days of the week and optionally a time value.
function ShouldShutdownNow ([string]$scheduleText)
{	
	# Initialize variables
    $d = [DateTime]::MinValue
    $weekDays = [DayOfWeek].GetEnumValues()

    if (![DateTime]::TryParse($scheduleText, [ref]$d))
    {
        # Break up the text by space
        $parts = $scheduleText.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)

        # Do we have a list of days of the week?
        $days = @($weekDays | ? { $_ -in $parts })

        if ($days -contains [DateTime]::Today.DayOfWeek)
        {
            # list of stings that are not days of the week. One of them should resolve to a time of day.
            $notDays = @($parts | ? { $_ -notin $weekDays })
            # today is in the list of names.
            $time = $notDays | ? { [DateTime]::TryParse($_, [ref]$d) } | % { [DateTime]::Parse($_).TimeOfDay } | select -First 1

            $d = [DateTime]::Today + $time
        }
    }
	
	# Check if current time falls within range
	return ($d -ne ([DateTime]::MinValue) -and $d.Date -eq ([DateTime]::Today) -and $d -lt [DateTime]::UtcNow)
	
}

try
{
    $startTime = [DateTime]::UtcNow

    $spConnection = Get-AutomationConnection -Name $connectionName | Write-Verbose

    $azCtx = Add-AzureRmAccount -ServicePrincipal -TenantId $spConnection.TenantId -ApplicationId $spConnection.ApplicationId -CertificateThumbprint $spConnection.CertificateThumbprint

    $subs = @(Get-AzureRmSubscription -TenantId $armCtx.Context.Tenant.TenantId | ? State -EQ 'Enabled') | Write-Verbose

    foreach($sub in $subs)
    {
        $armCtx = $sub | Set-AzureRmContext

        # Get a list of VMs with the 'shutDownAt' tag value.
        $vms = @(Find-AzureRmResource -ResourceType 'Microsoft.Compute/virtualMachines'  | % { $tags = $_.Tags; $_} | select ResourceGroupName, ResourceName, @{ Name='ShutDownAt'; Expression={$tags['shutDownAt']} })

        # Add the 'shutDownAt' tag value from the resource group, if not set on the resource
        $vms = @($vms | % { $rgTags = (Get-AzureRmResourceGroup -Name $_.ResourceGroupName).Tags; $_ } | select ResourceGroupName, ResourceName, @{ Name='ShutDownAt'; Expression={if ($_.ShutDownAt) {$_.ShutDownAt} else {$rgTags['shutDownAt']}} })

        # Get the power state for each of these VM's
        $vms = @($vms | % { $status = Get-AzureRmVM -Status -ResourceGroupName $_.ResourceGroupName -Name $_.ResourceName; $_ } | select ResourceGroupName, ResourceName, ShutDownAt, @{ Name='PowerState'; Expression={($status.Statuses | ? Code -Like 'PowerState/*').Code.Split('/')[1] }})

        Write-Output $vms

        foreach ($vm in $vms | ? { (ShouldShutdownNow -scheduleText $_.ShutDownAt) -and $_.PowerState -notin 'deallocated','deallocating' })
        {
            Write-Output "Stopping VM `"$($vm.ResourceName)`""
            Stop-AzureRmVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.ResourceName -Force
        }
    }
}
catch
{
    $errorMessage = $_.Exception.Message
    throw "Unexpected exception: $errorMessage"
}
finally
{
    Write-Output "Runbook finished (Duration: $(("{0:hh\:mm\:ss}" -f (([DateTime]::UtcNow) - $startTime))))"
} 