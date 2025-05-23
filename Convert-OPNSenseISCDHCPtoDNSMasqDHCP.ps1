#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateScript({
        if (-not (Test-Path -Path $_)){
            throw "File $_ does not exist"
        }
        return $true
    })]
    [string]$OPNSenseBackupXML,

    [string]$OPNSenseURL,

    [string]$apiKey,

    [string]$apiKeySecret,

    [switch]$allowDupeRanges,

    [switch]$ConvertDisabledRanges
)

function Get-OpnsenseDNSMasqSettings {
    param(
        $opnsenseURL, $headers
    )
    try {
        $existingDNSMasqSettingsRaw = $null
        $existingDNSMasqSettingsRaw = Invoke-WebRequest -Uri "$OPNSenseURL/api/dnsmasq/settings/get" -Method GET -Headers $headers -ErrorAction Stop
    } catch { Throw $_ }
    $existingDNSMasqSettings = $existingDNSMasqSettingsRaw.Content | ConvertFrom-Json -AsHashtable
    return $existingDNSMasqSettings
}

# Parse XML Content and verify format
[xml]$OPNSenseXMLContent = Get-Content -Path $OPNSenseBackupXML -Raw
if ((-not ($OPNSenseXMLContent.opnsense.dhcpd)) -or (-not ($OPNSenseXMLContent.opnsense.dhcpdv6)) ){
    throw "File $_ not in expected format"
}

# Validate Opnsense DNSMasq API Access and get existing dnsmasq settings
$userpass = "${apiKey}:${apiKeySecret}"
$encodedAuth = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($userpass))
$headers = @{Authorization = "Basic $encodedAuth"}
$existingDNSMasqSettings = Get-OpnsenseDNSMasqSettings -opnsenseURL $OPNSenseURL -headers $headers


# Add dhcpd and dhcpd6 stuff to a single array
$dhcpdContentsFromXML = $OPNSenseXMLContent.opnsense.dhcpd.ChildNodes + $OPNSenseXMLContent.opnsense.dhcpdv6.ChildNodes

# Iterate through XML Content and do stuff
:XMLinterfaceloop foreach ($XMLdhcpdinterface in $dhcpdContentsFromXML) {
    # Init values
    $xmlInterfaceStaticMaps = $null
    $existingDNSMasqSettings = $null
    $skipRangeCreation = $false
    $xmlInterfaceStaticMaps = $XMLdhcpdinterface.staticmap

    # Is this range disabled?
    if ($ConvertDisabledRanges -or ((-not $convertDisabledRanges) -and $XMLdhcpdinterface.enable -ne 1)){
        continue XMLinterfaceloop
    }

    # Does this range have at least a from and a to configured?
    if ("" -eq $XMLdhcpdinterface.range.from -or "" -eq $XMLdhcpdinterface.range.to){
        continue XMLinterfaceloop
    }

    # Does interface's configured range already exist or is interface already configured for a range?
    
    $existingDNSMasqSettings = Get-OpnsenseDNSMasqSettings -opnsenseURL $OPNSenseURL -headers $headers

    foreach ($existingRange in $existingDNSMasqSettings.dnsmasq.dhcp_ranges.Values){
        if (($existingRange.interface[$XMLdhcpdinterface.name].selected -eq 1) -and (($XMLdhcpdinterface.range.from -eq $existingRange.start_addr) -and ($XMLdhcpdinterface.range.to -eq $existingRange.end_addr))) {
            # Current interface already selected for an existing range and from/to values the same
            Write-Verbose "Existing range $($existingRange.start_addr) - $($existingRange.end_addr) found for interface $($XMLdhcpdinterface.name) with same start and end address"
            $skipRangeCreation = $true
        }
    }

    # Interface's configured range does not already exist, or $allowDupeRanges is configured, so create it
    if ($skipRangeCreation -eq $false -or $allowDupeRanges -eq $true) {

        try{
            $AddRangeResults = $null
            $AddRangeURL = "$OPNSenseURL/api/dnsmasq/settings/add_range"
            $constructor = $null
            if ($XMLdhcpdinterface.range.from -like "::*"){
                $constructor = $XMLdhcpdinterface.PSObject.Properties['Name'].Value
            }
            $body = $null
            $body = [Ordered]@{
                range = [Ordered]@{
                    constructor = "$constructor"
                    description = "Created by https://github.com/dreary-ennui/Convert-OPNSenseISCDHCPtoDNSMasqDHCP"
                    domain = "$($XMLdhcpdinterface.domain)"
                    start_addr = "$($XMLdhcpdinterface.range.from)"
                    end_addr = "$($XMLdhcpdinterface.range.to)"
                    interface = "$($XMLdhcpdinterface.PSObject.Properties['Name'].Value)"
                    lease_time = ""
                    mode = ""
                    nosync = "0"
                    prefix_len = ""
                    ra_interval = ""
                    ra_mode = ""
                    ra_mtu = ""
                    ra_priority = ""
                    ra_router_lifetime = ""
                    set_tag = ""
                }
            } | ConvertTo-Json -Depth 99 -Compress
            Write-Verbose "Attempting to POST to $addRangeURL the contents `'$body`'"
            $AddRangeResults = Invoke-WebRequest -Uri "$addRangeURL" -Method POST -Headers $headers -Body $body -ContentType "application/json" -ErrorAction Stop
            if ($AddRangeResults.Content -match "failed") {
                Write-Error -Message "Failed adding range`n URL: $addRangeURL`n Body: $body"
                Throw "See Write-Error message above"
            }
            elseif ($AddRangeResults.Content -match "saved"){
                Write-Host -ForegroundColor Green "Successfully posted `'$body`' to $addrangeURL"
            }
        }
        catch {
            throw $_
        }
    }

    :XMLstaticmaploop foreach ($xmlInterfaceStaticMap in $xmlInterfaceStaticMaps) {
        if (-not ($xmlInterfaceStaticMap.mac -and $xmlInterfaceStaticMap.ipaddr)) {
            continue XMLstaticmaploop
        }

    }
}