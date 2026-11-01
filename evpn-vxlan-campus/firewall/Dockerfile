# FRR plus a real packet filter, for the nodes standing in for Palo Altos.
#
# The stock FRR image routes and nothing else, which made the firewall nodes
# a routing hop wearing a firewall's name. That is not a cosmetic gap: the
# visitor zone turned out to be reachable from campus by way of the internet
# edge, because separation that lives only in routing tables is not policy.
#
# nftables gives these nodes an actual default-deny between zones, which is
# what a PAN-OS box provides with zones and the absence of an inter-zone rule.
FROM quay.io/frrouting/frr:10.7.0

RUN apk add --no-cache nftables iptables conntrack-tools

