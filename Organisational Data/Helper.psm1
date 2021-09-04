$RetryableThrottlingErrors = @(
    "Server Unavailable",
    "ErrorServerBusy",
    "The server cannot service this request right now",
    "The operation has timed out",
    "Unable to complete this action. Try again later"
    )

Function IsRetryableThrottlingError {
    param(
        [string]$errorMessage
    )

    foreach($retryableError in $RetryableThrottlingErrors)
    {
        if($errorMessage -like "*$retryableError*")
        {
            return $true
        }
    }

    return $false
}

function New-FakeThrottlingException {
    param( [string] $exceptionString = $null
    )

    if([string]::IsNullOrEmpty($exceptionString)) {
        $exceptionString = $script:RetryableThrottlingErrors[$($RetryableThrottlingErrors.Count) - 1] # just take the last one
    }

    throw "INJECTED THROTTLING EXCEPTION: $exceptionString"
}