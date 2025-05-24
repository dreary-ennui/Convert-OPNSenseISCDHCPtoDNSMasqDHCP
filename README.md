# Convert-OPNSenseISCtoDNSMasqDHCP
With ISC DHCP being deprecated, and recent improvements to dnsmasq implementation in OPNSense, I figured it was time to make the switch in my homelab. I wrote this script to make it easy for me to migrate all of my scopes and static mappings. After using the script, I was able to complete the remainder of configuration and migration pretty easily. Kudos to the OPNSense team - the [documentation](https://docs.opnsense.org/manual/dnsmasq.html) and examples are excellent.

This script performs the following functions:
- Converts OPNSense ISC DHCP scopes / interfaces from an OPNSense config XML into DNSMasq DHCP range entries
- Adds NTP server and Domain name DHCP options during DNSMasq scope creation if they are configured in the ISC DHCP scopes
- Converts OPNSense ISC DHCP static mappings (reservations) from an OPNSense config XML into DNSMasq Hosts entries

The script writes to script host green stuff when good things happen and yellow stuff if you use the -Verbose switch.

# Parameters
## -OPNSenseBackupXML
The path to a valid OPNSense configuration backup XML that has ISC DHCP configurations in it

## -OPNSenseURL
The FQDN of your OPNSense instance

## -apiKey
The API key of a user that has "Services: Dnsmasq DNS/DHCP: Settings" privileges

## -apiKeySecret
The secret of the apiKey above

## -Verbose
A switch parameter that prints additional information to the script host

# Usage example
./Convert-OPNSenseISCDHCPtoDNSMasqDHCP.ps1 -OPNSenseBackupXML "C:\Users\Me\Downloads\config-opnsense.xml" -OPNSenseURL "https://myopnsense.internal" -apiKey "abcdef123456" -apiKeySecret "defghijkl123456789"

