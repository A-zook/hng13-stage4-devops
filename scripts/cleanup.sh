#!/bin/bash
# Cleanup script for VPCctl - removes all VPC resources

set -e

echo "=== VPCctl Cleanup Script ==="
echo "This script removes all VPC-related resources"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

echo "Cleaning up VPC resources..."

# Use vpcctl to clean up managed resources
if [[ -f "./vpcctl.py" ]]; then
    echo "Using vpcctl teardown..."
    python3 ./vpcctl.py teardown-all 2>/dev/null || true
fi

# Manual cleanup of any remaining resources
echo "Performing manual cleanup..."

# Kill any running applications
pkill -f "python3 -m http.server" 2>/dev/null || true

# Remove any remaining vpc namespaces
for ns in $(ip netns list 2>/dev/null | grep "vpc-" | awk '{print $1}' || true); do
    echo "Removing namespace: $ns"
    ip netns delete "$ns" 2>/dev/null || true
done

# Remove any remaining vpc bridges
for bridge in $(ip link show type bridge 2>/dev/null | grep "vpc-.*-br" | awk -F: '{print $2}' | awk '{print $1}' || true); do
    echo "Removing bridge: $bridge"
    ip link delete "$bridge" 2>/dev/null || true
done

# Remove any remaining veth interfaces
for veth in $(ip link show 2>/dev/null | grep "veth-" | awk -F: '{print $2}' | awk '{print $1}' || true); do
    echo "Removing veth: $veth"
    ip link delete "$veth" 2>/dev/null || true
done

for veth in $(ip link show 2>/dev/null | grep "peer-" | awk -F: '{print $2}' | awk '{print $1}' || true); do
    echo "Removing peer veth: $veth"
    ip link delete "$veth" 2>/dev/null || true
done

# Clean up iptables NAT rules (be careful not to remove system rules)
echo "Cleaning up NAT rules..."
iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | grep "10\." | awk '{print $1}' | sort -nr | while read line; do
    iptables -t nat -D POSTROUTING $line 2>/dev/null || true
done

# Clean up state files
if [[ -d "state" ]]; then
    echo "Removing state files..."
    rm -f state/*.json
fi

# Clean up temporary files
rm -f /tmp/app-*.sh /tmp/*.pid 2>/dev/null || true

echo "✓ Cleanup completed"
echo
echo "Remaining network namespaces:"
ip netns list 2>/dev/null | grep -v "^$" || echo "  (none)"
echo
echo "Remaining bridges:"
ip link show type bridge 2>/dev/null | grep -E "^[0-9]+:" | awk -F: '{print $2}' | awk '{print $1}' || echo "  (none)"
echo
echo "If any vpc- resources remain, they may need manual removal"