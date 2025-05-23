#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateScript({
        if (-not (Test-Path -Path $_)){
            throw "File $_ does not exist"
        }
        return $true
    })]
    [Parameter(Mandatory=$true)]
    [string]$OPNSenseBackupXML,

    [Parameter(Mandatory=$true)]
    [string]$OPNSenseURL,

    [Parameter(Mandatory=$true)]
    [string]$apiKey,

    [Parameter(Mandatory=$true)]
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
            $addRangeResults = $null
            $addRangeURL = "$OPNSenseURL/api/dnsmasq/settings/add_range"
            $constructor = $null
            if ($XMLdhcpdinterface.range.from -like "::*"){
                $constructor = $XMLdhcpdinterface.PSObject.Properties['Name'].Value
            }
            $addRangeBody = $null
            $addRangeBody = [Ordered]@{
                range = [Ordered]@{
                    constructor = "$constructor"
                    description = ""
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
            Write-Verbose "Attempting to POST to $addRangeURL the contents `'$addRangeBody`'"
            $addRangeResults = Invoke-WebRequest -Uri "$addRangeURL" -Method POST -Headers $headers -Body $addRangeBody -ContentType "application/json" -ErrorAction Stop
            if ($addRangeResults.Content -match "failed") {
                Write-Error -Message "Failed adding range`n URL: $addRangeURL`n Body: $addRangeBody"
                Throw "See Write-Error message above"
            }
            elseif ($addRangeResults.Content -match "saved"){
                Write-Host -ForegroundColor Green "Successfully posted `'$addRangeBody`' to $addrangeURL"
            }
        }
        catch {
            throw $_
        }
    }

    :staticmaploop foreach ($staticMap in $XMLdhcpdinterface.staticmap) {

        # Is current staticmap an IPv6?
        if ($staticMap.duid -and $staticMap.ipaddrv6){
            $staticMapIPv6 = $true
        }
        elseif (($staticMap.mac -and $staticMap.ipaddr)) {
            $staticMapIPv4 = $true
        }

        # Does host already exist?
        foreach ($existingHost in $existingDNSMasqSettings.dnsmasq.hosts.Values){
            if (($staticMapIPv6 -and $null -ne $staticMap.duid) -and $staticMap.duid -eq $existingHost.client_id) {
                # Current host already exists
                Write-Verbose "Host with duid $($staticMap.duid) already exists, skipping host"
                continue staticmaploop
            }
            if (($staticMapIPv4 -and $null -ne $staticMap.mac) -and $staticMap.mac -in $existingHost.hwaddr.values.value) {
                # Current host already exists
                Write-Verbose "Host with MAC $($staticMap.mac) already exists, skipping host"
                continue staticmaploop
            }
        }

        try {
            $addHostResults = $null
            $addHostURL = "$OPNSenseURL/api/dnsmasq/settings/add_host"
            $addHostBody = $null
            $addHostBody = [Ordered]@{
                host = [Ordered]@{
                    aliases = ""
                    client_id = "$($staticMap.duid)"
                    comments = ""
                    descr = "$($staticMap.descr)"
                    domain = ""
                    host = "$($staticMap.hostname)"
                    hwaddr = "$($staticMap.mac)"
                    ignore = ""
                    ip = if ($staticMapIPv6){"$($staticMap.ipaddrv6)"} else {"$($staticMap.ipaddr)"}
                    lease_time = ""
                    set_tag = ""
                }
            } | ConvertTo-Json -Depth 99 -Compress
            Write-Verbose "Attempting to POST to $addHostURL the contents `'$addHostBody`'"
            $addHostResults = Invoke-WebRequest -Uri "$addHostURL" -Method POST -Headers $headers -Body $addHostBody -ContentType "application/json" -ErrorAction Stop
            if ($addHostResults.Content -match "failed") {
                Write-Error -Message "Failed adding host`n URL: $addHostURL`n Body: $addHostBody"
                Throw "See Write-Error message above"
            }
            elseif ($addHostResults.Content -match "saved"){
                Write-Host -ForegroundColor Green "Successfully posted `'$addHostBody`' to $addHostURL"
            }
        }
        catch {
            throw $_
        }
    }


    # Set NTP option for interface
    if ($null -ne $XMLdhcpdinterface.ntpserver -and "" -ne $XMLdhcpdinterface.ntpserver){
        try{
            $addOptionResults = $null
            $addOptionURL = "$OPNSenseURL/api/dnsmasq/settings/add_option"
            $addOptionBody = $null
            $addOptionBody = [Ordered]@{
                option = [Ordered]@{
                    description = ""
                    force = "0"
                    interface = "$($XMLdhcpdinterface.PSObject.Properties['Name'].Value)"
                    option = "42"
                    option6 = ""
                    set_tag = ""
                    tag = ""
                    type = "set"
                    value = "$($XMLdhcpdinterface.ntpserver)"
                }
            } | ConvertTo-Json -Depth 99 -Compress
            Write-Verbose "Attempting to POST to $addOptionURL the contents `'$addOptionBody`'"
            $addOptionResults = Invoke-WebRequest -Uri "$addOptionURL" -Method POST -Headers $headers -Body $addOptionBody -ContentType "application/json" -ErrorAction Stop
            if ($addOptionResults.Content -match "failed") {
                Write-Error -Message "Failed adding option`n URL: $addOptionURL`n Body: $addOptionBody"
                Throw "See Write-Error message above"
            }
            elseif ($addOptionResults.Content -match "saved"){
                Write-Host -ForegroundColor Green "Successfully posted `'$addOptionBody`' to $addOptionURL"
            }
        }
        catch {
            throw $_
        }
    }

    # Set domain name option for interface
    if ($null -ne $XMLdhcpdinterface.domain -and "" -ne $XMLdhcpdinterface.domain){
        try{
            $addOptionResults = $null
            $addOptionURL = "$OPNSenseURL/api/dnsmasq/settings/add_option"
            $addOptionBody = $null
            $addOptionBody = [Ordered]@{
                option = [Ordered]@{
                    description = ""
                    force = "0"
                    interface = "$($XMLdhcpdinterface.PSObject.Properties['Name'].Value)"
                    option = "15"
                    option6 = ""
                    set_tag = ""
                    tag = ""
                    type = "set"
                    value = "$($XMLdhcpdinterface.domain)"
                }
            } | ConvertTo-Json -Depth 99 -Compress
            Write-Verbose "Attempting to POST to $addOptionURL the contents `'$addOptionBody`'"
            $addOptionResults = Invoke-WebRequest -Uri "$addOptionURL" -Method POST -Headers $headers -Body $addOptionBody -ContentType "application/json" -ErrorAction Stop
            if ($addOptionResults.Content -match "failed") {
                Write-Error -Message "Failed adding option`n URL: $addOptionURL`n Body: $addOptionBody"
                Throw "See Write-Error message above"
            }
            elseif ($addOptionResults.Content -match "saved"){
                Write-Host -ForegroundColor Green "Successfully posted `'$addOptionBody`' to $addOptionURL"
            }
        }
        catch {
            throw $_
        }
    }

}