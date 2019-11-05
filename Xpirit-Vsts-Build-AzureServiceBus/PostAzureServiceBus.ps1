Trace-VstsEnteringInvocation $MyInvocation

$error = $false

# Get inputs.
$serviceBusNamespace = Get-VstsInput -Name ServiceBusNamespace -Require
$queueName = Get-VstsInput -Name QueueName -Require
$senderKeyName = Get-VstsInput -Name SenderKeyName -Require
$senderKey = Get-VstsInput -Name SenderKey -Require
$message = Get-VstsInput -Name Message -Require
$properties = Get-VstsInput -Name CustomMessageProperties

#True if running in china

$isMooncake = $false 
try
{
    $tmp = Get-VstsInput -Name IsMooncake -Require
    $isMooncake = [System.Convert]::ToBoolean($tmp) 
} catch [FormatException] {
  #then just false
}

# Remove all commands imported from VstsTaskSdk, other than Out-Default.
Get-ChildItem -LiteralPath function: |
    Where-Object {
        ($_.ModuleName -eq 'VstsTaskSdk' -and $_.Name -ne 'Out-Default') -or
        ($_.Name -eq 'Invoke-VstsTaskScript') 
    } |
    Remove-Item

# For compatibility with the legacy handler implementation, set the error action
# preference to continue. An implication of changing the preference to Continue,
# is that Invoke-VstsTaskScript will no longer handle setting the result to failed.
$global:ErrorActionPreference = 'Continue'

#Post to azure service bus script
function New-SaSToken {
    param (
        [parameter(Mandatory=$True, Position=1)] [String] $ResourceUri,
        [parameter(Mandatory=$True, Position=2)] [String] $KeyName,
        [parameter(Mandatory=$True, Position=3)] [String] $Key
    )

    $sinceEpoch = (Get-Date).ToUniversalTime() - ([datetime]'1/1/1970')
    $weekInSeconds = 7 * 24 * 60 * 60
    $expiry = [System.Convert]::ToString([int]($sinceEpoch.TotalSeconds) + $weekInSeconds)

    $encodedResourceUri = [System.Web.HttpUtility]::UrlEncode($ResourceUri)

    $stringToSign = $encodedResourceUri + "`n" + $expiry
    $stringToSignBytes = [System.Text.Encoding]::UTF8.GetBytes($stringToSign)
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($Key)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
    $hashOfStringToSign = $hmac.ComputeHash($stringToSignBytes)
    $signature = [System.Convert]::ToBase64String($hashOfStringToSign)
    $encodedSignature = [System.Web.HttpUtility]::UrlEncode($signature)

    $sasToken = "SharedAccessSignature sr=$encodedResourceUri&sig=$encodedSignature&se=$expiry&skn=$KeyName"

    return $sasToken
}

function Send-Message {
    param (
            [parameter(Mandatory=$True, Position=1)] [String] $RestApiUri,
            [parameter(Mandatory=$True, Position=2)] [String] $SasToken,
            [parameter(Mandatory=$True, Position=3)] [String] $Message,
            [parameter(Mandatory=$True, Position=4)] [string] $MessageProperties
    )

    $headers = @{'Authorization'=$SasToken}

    $brokerProperties = @{
        State='Active'
    }
    $brokerPropertiesJson = ConvertTo-Json $brokerProperties -Compress
    $headers.Add('BrokerProperties',$brokerPropertiesJson)
    # application Properties
    $appPropName = 'Priority'
    $appPropValue = 'High'
    $headers.Add($appPropName,$appPropValue)
    
    # custom message properties
    if (-Not [string]::IsNullOrEmpty($MessageProperties))
    {
        $props = $MessageProperties.Split(';')
        
        foreach ($prop in $props)
        {
            $pair = $prop.Split('=')
            $headers.Add($pair[0], $pair[1])
        }
    }
    
    $messageToPost = [System.Text.Encoding]::UTF8.GetBytes($Message)
    
    $contentType = 'application/atom+xml;type=entry;charset=utf-8'
    
    try {
        Invoke-RestMethod -Method Post -Uri $RestApiUri -Headers $headers -Body $messageToPost -ContentType $contentType
        Write-Host "Rest API call success for $RestApiUri" -ForegroundColor Green
        $error = $false
    }
    catch {
        Write-Host "Rest API call failed for $RestApiUri" -ForegroundColor Red
        $error = $true
    }

    write-host 'Sent message: '$Message
    Write-Host "With application property $appPropName = $appPropValue"
}

$resourceUri = "https://$serviceBusNamespace.servicebus.windows.net/$queueName"
if ($isMooncake) { $resourceUri = "https://$serviceBusNamespace.servicebus.chinacloudapi.cn/$queueName" }

# SENDING MESSAGE
$sendMessageRestUri = "$resourceUri/messages?timeout=60";
$senderSasToken = New-SaSToken -ResourceUri $resourceUri -KeyName $senderKeyName -Key $senderKey

Send-Message -RestApiUri $sendMessageRestUri -SasToken $senderSasToken -Message $message -MessageProperties $properties

#Clean up variables
Remove-Variable -Name sendMessageRestUri
Remove-Variable -Name senderSasToken
Remove-Variable -Name resourceUri
Remove-Variable -Name serviceBusNamespace
Remove-Variable -Name queueName
Remove-Variable -Name senderKey
Remove-Variable -Name senderKeyName
Remove-Variable -Name message
Remove-Variable -Name properties

if ($error){
    "##vso[task.complete result=Failed]"
}
