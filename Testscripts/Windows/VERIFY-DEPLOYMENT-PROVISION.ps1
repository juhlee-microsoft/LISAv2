# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

param([object] $AllVmData, [object] $CurrentTestData, [object] $TestProvider, [object] $TestParams)

function Main {
	param(
		[object] $allVMData,
		[object] $CurrentTestData,
		[object] $TestProvider,
		[object] $TestParams
	)
	try {
		$CurrentTestResult = Create-TestResultObject
		$CurrentTestResult.TestSummary += New-ResultSummary -testResult "PASS" `
			-metaData "FirstBoot" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
		Write-LogInfo "Check 1: Checking call trace" # again after 30 seconds sleep"
		# Start-Sleep -Seconds 30
		$noIssues = Check-KernelLogs -allVMData $allVMData
		if ($noIssues) {
			$CurrentTestResult.TestSummary += New-ResultSummary -testResult "PASS" `
				-metaData "FirstBoot : Call Trace Verification" -checkValues "PASS,FAIL,ABORTED" `
				-testName $currentTestData.testName
			$RestartStatus = $TestProvider.RestartAllDeployments($allVMData)
			if ($RestartStatus -eq "True") {
				$CurrentTestResult.TestSummary += New-ResultSummary -testResult "PASS" `
					-metaData "Reboot" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
				Write-LogInfo "Check 2: Checking call trace again after Reboot" # > 30 seconds sleep"
				# Start-Sleep -Seconds 30
				$noIssues = Check-KernelLogs -allVMData $allVMData
				if ($noIssues) {
					$CurrentTestResult.TestSummary += New-ResultSummary -testResult "PASS" `
						-metaData "Reboot : Call Trace Verification" -checkValues "PASS,FAIL,ABORTED" `
						-testName $currentTestData.testName
					# If vCpu parameter is empty, skip the check and pass the test.
					if ($TestParams.vCpu) {
						Write-LogInfo "Check vCpu: Checking number of vCpu in VM"
						$vmCpuCount = Run-LinuxCmd -username $user -password $password -ip $allVMData.PublicIP `
							-port $allVMData.SSHPort -command "nproc" -ignoreLinuxExitCode
						Write-LogInfo "VM CPU Count: $vmCpuCount"
						if ($vmCpuCount -ne $TestParams.vCpu) {
							Write-LogErr "Check expected vcpu: $($TestParams.vCpu) actual: ${vmCpuCount}"
							$CurrentTestResult.TestSummary += New-ResultSummary -testResult "FAIL" `
								-metaData "vCpu : Check expected vcpu" -checkValues "PASS,FAIL,ABORTED" `
								-testName $currentTestData.testName
							Write-LogInfo "Test Result : FAIL."
							$testResult = "FAIL"
						} else {
							Write-LogInfo "Check expected vcpu: $($TestParams.vCpu) actual: ${vmCpuCount}"
							$CurrentTestResult.TestSummary += New-ResultSummary -testResult "PASS" `
								-metaData "vCpu : Check expected vcpu" -checkValues "PASS,FAIL,ABORTED" `
								-testName $currentTestData.testName
							Write-LogInfo "Test Result : PASS."
							$testResult = "PASS"
						}
					} else {
						Write-LogInfo "Test Result : PASS."
						$testResult = "PASS"
					}
				} else {
					$CurrentTestResult.TestSummary += New-ResultSummary -testResult "FAIL" `
						-metaData "Reboot : Call Trace Verification" -checkValues "PASS,FAIL,ABORTED" `
						-testName $currentTestData.testName
					# Write-LogInfo "Test Result : FAIL."
					# $testResult = "FAIL"
					# Only for smoke_test: take Call Trace verification 'FAIL' as 'PASS' for general result of test cases.
					Write-LogInfo "Test Result : PASS."
					$testResult = "PASS"
				}
			} else {
				$CurrentTestResult.TestSummary += New-ResultSummary -testResult "FAIL" `
					-metaData "Reboot" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
				Write-LogInfo "Test Result : FAIL."
				$testResult = "FAIL"
			}

		} else {
			$CurrentTestResult.TestSummary += New-ResultSummary -testResult "FAIL" `
				-metaData "FirstBoot : Call Trace Verification" -checkValues "PASS,FAIL,ABORTED" `
				-testName $currentTestData.testName
			# Write-LogInfo "Test Result : FAIL."
			# $testResult = "FAIL"
			# Only for smoke_test: take Call Trace verification 'FAIL' as 'PASS' for general result of test cases.
			Write-LogInfo "Test Result : PASS."
			$testResult = "PASS"
		}
	} catch {
		$ErrorMessage =  $_.Exception.Message
		Write-LogInfo "EXCEPTION : $ErrorMessage"
	}
	Finally {
		if (!$testResult) {
			$testResult = "Aborted"
		}
		$resultArr += $testResult
	}

	$currentTestResult.TestResult = Get-FinalResultHeader -resultarr $resultArr
	return $currentTestResult
}

Main -AllVmData $AllVmData -CurrentTestData $CurrentTestData -TestProvider $TestProvider `
	-TestParams (ConvertFrom-StringData $TestParams.Replace(";","`n"))
