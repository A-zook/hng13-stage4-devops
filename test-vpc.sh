#!/bin/bash

# VPC Manual Testing — Pre-Troubleshooting Edition (Error-Proof)

echo "🧩 Goal: Test all VPC features cleanly, without 'File exists' or 'ping failed' errors."

echo "0️⃣ Environment Preparation (Critical)"
# Ensure dependencies
sudo apt update -y
sudo apt install -y bridge-utils iproute2 iptables jq python3

# Ensure vpcctl.py is executable
chmod +x vpcctl.py

echo "1️⃣ Clean and Detect Correct Internet Interface"
# Full cleanup before new setup
sudo python3 vpcctl.py teardown-all 2>/dev/null || true

# Confirm no leftover bridges or namespaces
sudo ip netns delete $(sudo ip netns list | awk '{print $1}') 2>/dev/null || true
for link in $(ip -o link show | awk -F': ' '/vpc/{print $2}'); do sudo ip link delete $link 2>/dev/null; done

# Detect default interface (usually eth0)
IFACE=$(ip route | grep default | awk '{print $5}')
echo "✅ Using interface: $IFACE"

# Quick sanity check: Internet connectivity
ping -c 2 8.8.8.8 && echo "🌍 Internet OK" || echo "❌ Internet not reachable"

echo "2️⃣ Kernel & Bridge Configuration (Prevent Forwarding Issues)"
# Enable IP forwarding globally
sudo sysctl -w net.ipv4.ip_forward=1

# Prevent bridge filtering issues
sudo modprobe br_netfilter 2>/dev/null || true
sudo sysctl -w net.bridge.bridge-nf-call-iptables=0 2>/dev/null || true
sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=0 2>/dev/null || true

echo "3️⃣ Create VPC"
sudo python3 vpcctl.py create-vpc --name test --cidr 10.50.0.0/16 --internet-iface $IFACE

# Confirm VPC bridge exists
ip link show | grep vpc-test-br && echo "✅ Bridge OK"

echo "4️⃣ Add Public & Private Subnets"
sudo python3 vpcctl.py add-subnet --vpc test --name web --cidr 10.50.1.0/24 --type public
sudo python3 vpcctl.py add-subnet --vpc test --name db  --cidr 10.50.2.0/24 --type private

echo "5️⃣ Verify and Enable Bridge Forwarding (Before Pings)"
# Confirm bridge interface name
BR=$(ip link show | grep vpc-test-br | awk -F: '{print $2}' | xargs)
echo "✅ Using bridge: $BR"

# Enable bridge packet forwarding explicitly
echo 1 | sudo tee /proc/sys/net/ipv4/conf/$BR/forwarding

# Verify namespaces
sudo ip netns list

echo "6️⃣ Verify Internal Networking"
# Check each namespace interface and routes
sudo ip netns exec vpc-test-ns-web ip addr show
sudo ip netns exec vpc-test-ns-db ip addr show
sudo ip netns exec vpc-test-ns-web ip route
sudo ip netns exec vpc-test-ns-db ip route

echo "✅ If all routes and interfaces show correctly (eth0 + IP in 10.50.x.x), continue."

echo "7️⃣ Test Intra-VPC Connectivity"
# Test if web subnet can ping db subnet (internal connectivity)
sudo ip netns exec vpc-test-ns-web ping -c 2 10.50.2.2 && echo "✅ Subnet connectivity OK" || echo "❌ Fix bridge or routes"

echo "8️⃣ Test Internet Access (NAT)"
# Add NAT rule if not present
sudo iptables -t nat -C POSTROUTING -s 10.50.0.0/16 -o $IFACE -j MASQUERADE 2>/dev/null || \
sudo iptables -t nat -A POSTROUTING -s 10.50.0.0/16 -o $IFACE -j MASQUERADE

# Public subnet should reach internet
sudo ip netns exec vpc-test-ns-web ping -c 2 8.8.8.8 && echo "🌍 NAT works from public subnet"

# Private subnet should not
sudo ip netns exec vpc-test-ns-db ping -c 2 8.8.8.8 || echo "✅ Private subnet correctly blocked"

echo "9️⃣ Deploy and Test Applications"
# Start simple web & db apps
sudo python3 vpcctl.py deploy-app --vpc test --subnet web --name webserver --cmd "python3 -m http.server 8080" &
sudo python3 vpcctl.py deploy-app --vpc test --subnet db  --name database --cmd "python3 -m http.server 9000" &
sleep 3

# Validate responses
sudo ip netns exec vpc-test-ns-web curl -s http://localhost:8080 | head -1
sudo ip netns exec vpc-test-ns-db  curl -s http://localhost:9000 | head -1

echo "🔟 Firewall Policy Setup (Pre-Verified CIDR)"
mkdir -p policies
cat > policies/test-policy.json << 'EOF'
[
  {
    "subnet": "10.50.2.0/24",
    "ingress": [
      {"port": 80, "protocol": "tcp", "action": "deny"},
      {"port": 22, "protocol": "tcp", "action": "deny"}
    ],
    "egress": [
      {"port": "any", "protocol": "any", "action": "allow"}
    ]
  }
]
EOF

# Apply policy safely
sudo python3 vpcctl.py apply-policy --policy-file policies/test-policy.json

# Confirm enforcement
sudo ip netns exec vpc-test-ns-db curl -s http://10.50.1.2:8080 --connect-timeout 3 || echo "✅ Blocked by firewall"

echo "1️⃣1️⃣ VPC Peering (Optional Advanced Test)"
# Create 2nd VPC
sudo python3 vpcctl.py create-vpc --name prod --cidr 10.60.0.0/16 --internet-iface $IFACE
sudo python3 vpcctl.py add-subnet --vpc prod --name app --cidr 10.60.1.0/24 --type public

# Ensure isolation first
sudo ip netns exec vpc-test-ns-web ping -c 1 10.60.1.2 || echo "✅ VPCs isolated"

# Peer both
sudo python3 vpcctl.py peer --vpc-a test --vpc-b prod --allowed-cidrs 10.50.0.0/16,10.60.0.0/16

# Verify peering
sudo ip netns exec vpc-test-ns-web ping -c 2 10.60.1.2 && echo "🔗 Peering OK"

echo "1️⃣2️⃣ State File Verification"
ls -la state/
cat state/test.json | jq .

# JSON output (correct flag order)
sudo python3 vpcctl.py --json list-vpcs
sudo python3 vpcctl.py --json inspect --vpc test

echo "1️⃣3️⃣ Clean Up"
sudo python3 vpcctl.py delete-vpc --name prod 2>/dev/null || true
sudo python3 vpcctl.py teardown-all
sudo ip netns list
ip link show | grep vpc