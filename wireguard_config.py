#!/usr/bin/env python3
"""Validate the lab's wg-quick profile without executing it or printing keys."""
import argparse
import base64
import ipaddress
import json
import re
import sys
from pathlib import Path


def validate_config(path, student_network):
    network = ipaddress.ip_network(student_network, strict=True)
    if network.prefixlen == 0:
        raise ValueError("Student network must not be a default route")
    interface, peers, section = {}, [], None
    for number, raw in enumerate(Path(path).read_text(encoding="utf-8-sig").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line == "[Interface]":
            if section is not None:
                raise ValueError("Expected exactly one Interface followed by Peer sections")
            section = interface
            continue
        if line == "[Peer]":
            if section is None:
                raise ValueError("Interface must precede Peer")
            section = {}
            peers.append(section)
            continue
        if section is None or "=" not in line:
            raise ValueError(f"Invalid syntax at line {number}")
        key, value = (part.strip() for part in line.split("=", 1))
        permitted = ({"PrivateKey", "Address", "ListenPort", "MTU", "DNS", "SaveConfig"}
                     if section is interface else
                     {"PublicKey", "PresharedKey", "Endpoint", "AllowedIPs", "PersistentKeepalive"})
        if key not in permitted:
            # In particular, never execute wg-quick shell hooks supplied by a profile.
            raise ValueError(f"Unsupported directive at line {number}; hooks and custom routing require manual review")
        if key in section or not value:
            raise ValueError(f"Duplicate or empty directive at line {number}")
        section[key] = value

    def check_key(mapping, key):
        try:
            decoded = base64.b64decode(mapping[key], validate=True)
        except (KeyError, ValueError):
            raise ValueError(f"Missing or invalid {key}") from None
        if len(decoded) != 32:
            raise ValueError(f"Invalid {key} length")

    check_key(interface, "PrivateKey")
    try:
        addresses = [ipaddress.ip_interface(value.strip())
                     for value in interface["Address"].split(",")]
    except (KeyError, ValueError):
        raise ValueError("Missing or invalid Interface Address") from None
    if not any(address.version == network.version for address in addresses):
        raise ValueError("Lab address and student network must share an IP family")
    if interface.get("SaveConfig", "false").lower() != "false":
        raise ValueError("SaveConfig=true would overwrite the installed profile; review it manually")
    for key, lower, upper in (("ListenPort", 1, 65535), ("MTU", 576, 65535)):
        if key in interface and (not interface[key].isdigit() or not lower <= int(interface[key]) <= upper):
            raise ValueError(f"Invalid {key}")
    if not peers:
        raise ValueError("At least one Peer is required")
    warnings, routed = [], False
    routes_seen, keys_seen = [], set()
    for peer in peers:
        check_key(peer, "PublicKey")
        if peer["PublicKey"] in keys_seen:
            raise ValueError("Duplicate peer public key")
        keys_seen.add(peer["PublicKey"])
        if "PresharedKey" in peer:
            check_key(peer, "PresharedKey")
        endpoint = peer.get("Endpoint", "")
        match = re.fullmatch(r"(\[[0-9a-fA-F:]+\]|[A-Za-z0-9][A-Za-z0-9.-]*):([0-9]+)", endpoint)
        if not match or not 1 <= int(match[2]) <= 65535:
            raise ValueError("Each lab peer needs a valid outbound Endpoint host:port")
        if match[1].startswith("["):
            try:
                ipaddress.IPv6Address(match[1][1:-1])
            except ValueError:
                raise ValueError("Invalid IPv6 Endpoint") from None
        try:
            routes = [ipaddress.ip_network(value.strip(), strict=True)
                      for value in peer["AllowedIPs"].split(",")]
        except (KeyError, ValueError):
            raise ValueError("Missing or invalid peer AllowedIPs") from None
        for route in routes:
            if route.prefixlen == 0:
                raise ValueError("Full-tunnel AllowedIPs requires manual review; use explicit VPN routes")
            if any(route.version == old.version and route.overlaps(old) for old in routes_seen):
                raise ValueError("Overlapping AllowedIPs require manual review")
            routes_seen.append(route)
        carries_students = any(route.version == network.version and network.subnet_of(route) for route in routes)
        routed |= carries_students
        keepalive = peer.get("PersistentKeepalive", "0")
        if not keepalive.isdigit() or not 0 <= int(keepalive) <= 65535:
            raise ValueError("Invalid PersistentKeepalive")
        if carries_students and int(keepalive) == 0:
            warnings.append("Set PersistentKeepalive=25 on the lab's hub peer to maintain NAT reachability while idle")
    if not routed:
        raise ValueError("AllowedIPs must include a route covering the student source network for replies")
    return {"addresses": [str(value) for value in addresses],
            "student_network": str(network), "peers": len(peers),
            "requires_resolvconf": "DNS" in interface, "warnings": warnings}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("--student-network", required=True)
    args = parser.parse_args()
    try:
        result = validate_config(args.config, args.student_network)
    except (OSError, UnicodeError):
        parser.exit(1, "ERROR: cannot read the configuration file\n")
    except ValueError as error:
        # Messages never include profile contents, keys or underlying parser exceptions.
        message = str(error) if not isinstance(error, (ipaddress.AddressValueError, ipaddress.NetmaskValueError)) else "Invalid IP network"
        parser.exit(1, f"ERROR: {message}\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
