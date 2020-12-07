# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
param([object] $AllVmData,
	  [object] $CurrentTestData)

function Invoke-DpdkTestPmd {
	$testJob = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -command "./StartDpdkTestPmd.sh" -RunInBackground

	#region MONITOR TEST
	while ((Get-Job -Id $testJob).State -eq "Running") {
		$currentStatus = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -command "tail -2 dpdkConsoleLogs.txt | head -1"
		Write-LogInfo "Current Test Status : $currentStatus"
		Wait-Time -seconds 20
	}
	$finalStatus = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -command "cat /root/state.txt"
	Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -download -downloadTo $currentDir -files "*.csv, *.txt, *.log"

	if ($finalStatus -imatch "TestFailed") {
		Write-LogErr "Test failed. Last known status : $currentStatus."
		$testResult = "FAIL"
	}
	elseif ($finalStatus -imatch "TestAborted") {
		Write-LogErr "Test Aborted. Last known status : $currentStatus."
		$testResult = "ABORTED"
	}
	elseif ($finalStatus -imatch "TestCompleted") {
		Write-LogInfo "Test Completed."
		$testResult = "PASS"
		Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -download -downloadTo $currentDir -files "*.tar.gz"
	}
	elseif ($finalStatus -imatch "TestRunning") {
		Write-LogInfo "Powershell background job for test is completed but VM is reporting that test is still running. Please check $LogDir\zkConsoleLogs.txt"
		Write-LogInfo "Content of summary.log : $testSummary"
		$testResult = "PASS"
	}

	if ($testResult -eq "PASS") {
		return $true
	} else {
		return $false
	}
}
function Main {
	# Create test result
	$superUser = "root"
	$resultArr = @()
	$lowerbound = 1000000
	$currentTestResult = Create-TestResultObject
	try {
		$noClient = $true
		$noServer = $true
		foreach ($vmData in $allVMData) {
			if ($vmData.RoleName -imatch "client") {
				$clientVMData = $vmData
				$noClient = $false
			}
			elseif ($vmData.RoleName -imatch "server") {
				$noServer = $false
				$serverVMData = $vmData
			} else {
				Write-LogErr "VM role name is not matched with server or client"
			}
		}
		if ($noClient) {
			Throw "No any master VM defined. Be sure that, Client VM role name matches with the pattern `"*master*`". Aborting Test."
		}
		if ($noServer) {
			Throw "No any slave VM defined. Be sure that, Server machine role names matches with pattern `"*slave*`" Aborting Test."
		}
		#region CONFIGURE VM FOR TERASORT TEST
		Write-LogInfo "CLIENT VM details :"
		Write-LogInfo "  RoleName : $($clientVMData.RoleName)"
		Write-LogInfo "  Public IP : $($clientVMData.PublicIP)"
		Write-LogInfo "  SSH Port : $($clientVMData.SSHPort)"
		Write-LogInfo "  Internal IP : $($clientVMData.InternalIP)"
		Write-LogInfo "SERVER VM details :"
		Write-LogInfo "  RoleName : $($serverVMData.RoleName)"
		Write-LogInfo "  Public IP : $($serverVMData.PublicIP)"
		Write-LogInfo "  SSH Port : $($serverVMData.SSHPort)"
		Write-LogInfo "  Internal IP : $($serverVMData.InternalIP)"

		# PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS IN SAME HOSTED SERVICE.
		Provision-VMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"
		#endregion

		Write-LogInfo "Getting Active NIC Name."
		$getNicCmd = ". ./utils.sh &> /dev/null && get_active_nic_name"
		$clientNicName = (Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -command $getNicCmd).Trim()
		$serverNicName = (Run-LinuxCmd -ip $clientVMData.PublicIP -port $serverVMData.SSHPort -username $superUser -password $password -command $getNicCmd).Trim()
		if ($serverNicName -eq $clientNicName) {
			Write-LogInfo "Client and Server VMs have same nic name: $clientNicName"
		} else {
			Throw "Server and client SRIOV NICs are not same."
		}
		if($currentTestData.SetupConfig.Networking -imatch "SRIOV") {
			$DataPath = "SRIOV"
		} else {
			$DataPath = "Synthetic"
		}
		Write-LogInfo "CLIENT $DataPath NIC: $clientNicName"
		Write-LogInfo "SERVER $DataPath NIC: $serverNicName"

		Write-LogInfo "Generating constants.sh ..."
		$constantsFile = "$LogDir\constants.sh"
		Set-Content -Value "#Generated by Azure Automation." -Path $constantsFile
		Add-Content -Value "vms=$($serverVMData.RoleName),$($clientVMData.RoleName)" -Path $constantsFile
		Add-Content -Value "server=$($serverVMData.InternalIP)" -Path $constantsFile
		Add-Content -Value "client=$($clientVMData.InternalIP)" -Path $constantsFile
		Add-Content -Value "nicName=eth1" -Path $constantsFile
		Add-Content -Value "pciAddress=0002:00:02.0" -Path $constantsFile

		foreach ($param in $currentTestData.TestParameters.param) {
			Add-Content -Value "$param" -Path $constantsFile
			if ($param -imatch "modes") {
				$modes = ($param.Replace("modes=",""))
			}
		}
		$currentKernelVersion = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort `
				-username $user -password $password -command "uname -r"
		if (Is-DpdkCompatible -KernelVersion $currentKernelVersion -DetectedDistro $global:DetectedDistro) {
			Write-LogInfo "Confirmed Kernel version supported: $currentKernelVersion"
		} else {
			Write-LogWarn "Unsupported Kernel version: $currentKernelVersion or unsupported distro $($global:DetectedDistro)"
			return $global:ResultSkipped
		}

		Write-LogInfo "constants.sh created successfully..."
		Write-LogInfo "test modes : $modes"
		Write-LogInfo (Get-Content -Path $constantsFile)
		#endregion

		#region EXECUTE TEST
		$myString = @"
cd /root/
./dpdkTestPmd.sh 2>&1 > dpdkConsoleLogs.txt
. utils.sh
collect_VM_properties
"@
		Set-Content "$LogDir\StartDpdkTestPmd.sh" $myString
		Copy-RemoteFiles -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files "$constantsFile,$LogDir\StartDpdkTestPmd.sh" -username $superUser -password $password -upload
		$null = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -command "chmod +x *.sh" | Out-Null

		$currentDir = "$LogDir\initialSRIOVTest"
		New-Item -Path $currentDir -ItemType Directory | Out-Null
		$initailTest = Invoke-DpdkTestPmd
		if ($initailTest -eq $true) {
			$initialSriovResult = Import-Csv -Path $currentDir\dpdkTestPmd.csv
			Write-LogInfo ($initialSriovResult | Format-Table | Out-String)
			$testResult = "PASS"
		} else {
			$testResult = "FAIL"
			Write-LogErr "Initial DPDK test execution failed"
		}
		$resultArr += $testResult
		$currentTestResult.TestSummary +=  New-ResultSummary -testResult "$($initialSriovResult.DpdkVersion) : TxPPS : $($initialSriovResult.TxPps) : RxPPS : $($initialSriovResult.RxPps)" -metaData "DPDK-TESTPMD : Initial SRIOV" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName

		#disable SRIOV
		$sriovStatus = $false
		$currentDir = "$LogDir\syntheticTest"
		New-Item -Path $currentDir -ItemType Directory | Out-Null
		$sriovStatus = Set-SRIOVInVMs -AllVMData $AllVMData -Disable
		$clientVMData.PublicIP = $AllVMData.PublicIP[0]
		if ($sriovStatus -eq $true) {
			Write-LogInfo "SRIOV is disabled"
			$syntheticTest = Invoke-DpdkTestPmd
			if ($syntheticTest -eq $true){
				$syntheticResult = Import-Csv -Path $currentDir\dpdkTestPmd.csv
				Write-LogInfo ($syntheticResult | Format-Table | Out-String)
				$testResult = "PASS"
			} else {
				$testResult = "FAIL"
				Write-LogErr "Synthetic DPDK test execution failed"
			}
		} else {
			$testResult = "FAIL"
			Write-LogErr "Disable SRIOV is failed"
		}
		$resultArr += $testResult
		$currentTestResult.TestSummary +=  New-ResultSummary -testResult "$($syntheticResult.DpdkVersion) : TxPPS : $($syntheticResult.TxPps) : RxPPS : $($syntheticResult.RxPps)" -metaData "DPDK-TESTPMD : Synthetic" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName

		#enable SRIOV
		$currentDir = "$LogDir\finallSRIOVTest"
		New-Item -Path $currentDir -ItemType Directory | Out-Null
		$sriovStatus = Set-SRIOVInVMs -AllVMData $AllVMData -Enable
		$clientVMData.PublicIP = $AllVMData.PublicIP[0]
		if ($sriovStatus -eq $true) {
			Write-LogInfo "SRIOV is enabled"
			$finalSriovTest = Invoke-DpdkTestPmd
			if ($finalSriovTest -eq $true) {
				$finalSriovResult = Import-Csv -Path $currentDir\dpdkTestPmd.csv
				Write-LogInfo ($finalSriovResult | Format-Table | Out-String)
				$testResult = "PASS"
			} else {
				$testResult = "FAIL"
				Write-LogErr "Re-Enabled SRIOV DPDK test execution failed"
			}
		} else {
			$testResult = "FAIL"
			Write-LogErr "Enable SRIOV is failed"
		}
		$resultArr += $testResult
		$currentTestResult.TestSummary +=  New-ResultSummary -testResult "$($finalSriovResult.DpdkVersion) : TxPps : $($finalSriovResult.TxPps) : RxPps : $($finalSriovResult.RxPps)" -metaData "DPDK-TESTPMD : Re-Enable SRIOV" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
		Write-LogInfo "Comparison of DPDK RxPPS between Initial and Re-Enabled SRIOV"
		if (($null -ne $initialSriovResult.RxPps) -and ($null -ne $finalSriovResult.RxPps)) {
			$loss = [Math]::Round([Math]::Abs($initialSriovResult.RxPps - $finalSriovResult.RxPps)/$initialSriovResult.RxPps*100, 2)
			$lossinpercentage = "$loss"+" %"
			if (($loss -le 5) -or ($initialSriovResult.RxPps -ge $lowerbound -and $finalSriovResult.RxPps -ge $lowerbound)){
				$testResult = "PASS"
				Write-LogInfo "Initial and Re-Enabled SRIOV DPDK RxPPS is greater than $lowerbound (lower bound limit) and difference is : $lossinpercentage"
			} else {
				$testResult = "FAIL"
				Write-LogErr "Initial and Re-Enabled SRIOV DPDK RxPPS is less than $lowerbound (lower bound limit) and difference is : $lossinpercentage"
			}
		} else {
			Write-LogErr "DPDK RxPPS of Initial or Re-Enabled SRIOV is zero."
			$testResult = "FAIL"
		}
		$resultArr += $testResult
		$currentTestResult.TestSummary +=  New-ResultSummary -testResult "$($initialSriovResult.RxPps) : $($finalSriovResult.RxPps) : $($lossinpercentage)" -metaData "DPDK RxPPS : Difference between Initial and Re-Enabled SRIOV" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
		Write-LogInfo "Test result : $testResult"
	} catch {
		$ErrorMessage =  $_.Exception.Message
		$ErrorLine = $_.InvocationInfo.ScriptLineNumber
		Write-LogErr "EXCEPTION : $ErrorMessage at line: $ErrorLine"
		$testResult = "FAIL"
	} finally {
		if (!$testResult) {
			$testResult = "ABORTED"
		}
		$resultArr += $testResult
	}
	$currentTestResult.TestResult = Get-FinalResultHeader -resultarr $resultArr
	return $currentTestResult
}

Main
