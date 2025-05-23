# Convert-OPNSenseISCtoDNSMasqDHCP
- Converts OPNSense ISC DHCP scopes / interfaces from an OPNSense config XML into DNSMasq DHCP range entries
- Converts OPNSense ISC DHCP static mappings (reservations) from an OPNSense config XML into DNSMasq Hosts entries

# Parameters
## OPNSenseBackupXML
The path to a valid OPNSense configuration backup XML that has ISC DHCP configurations in it

## OPNSenseURL
The FQDN of your OPNSense instance

## apiKey
The API key of a user that has "Services: Dnsmasq DNS/DHCP: Settings" privileges

## apiKeySecret
The secret of the apiKey above
