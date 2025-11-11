# VPCctl - Virtual Private Cloud Management Tool

A production-quality CLI tool for creating and managing Virtual Private Clouds (VPCs) on Linux using native networking primitives.

## Features

- Create and manage multiple isolated VPCs
- Public and private subnets with NAT support
- Network namespace isolation
- JSON-based firewall policies
- VPC peering capabilities
- Complete resource cleanup
- Comprehensive logging

## Architecture

```
Host Network
    │
    ├── VPC-A (10.10.0.0/16)
    │   ├── Bridge: vpc-testvpc-br
    │   ├── Public Subnet (10.10.1.0/24) ──NAT──> Internet
    │   │   └── Namespace: vpc-testvpc-ns-public
    │   └── Private Subnet (10.10.2.0/24)
    │       └── Namespace: vpc-testvpc-ns-private
    │
    └── VPC-B (10.20.0.0/16)
        └── Bridge: vpc-othervpc-br
            └── Subnets...
```

## Requirements

- Linux (Ubuntu 22.04+ recommended)
- Root privileges
- iproute2, iptables, bridge-utils

## Installation

```bash
git clone <repository>
cd vpcctl
sudo python3 vpcctl.py --help
```

## Usage Examples

### Create VPC and Subnets

```bash
# Create VPC
sudo ./vpcctl.py create-vpc --name testvpc --cidr 10.20.0.0/16 --internet-iface eth0

# Add public subnet (with NAT)
sudo ./vpcctl.py add-subnet --vpc testvpc --name public --cidr 10.20.1.0/24 --type public

# Add private subnet (no internet access)
sudo ./vpcctl.py add-subnet --vpc testvpc --name private --cidr 10.20.2.0/24 --type private
```

### Deploy Applications

```bash
# Deploy web server in public subnet
sudo ./vpcctl.py deploy-app --vpc testvpc --subnet public --name web-public --cmd "python3 -m http.server 80"

# Deploy web server in private subnet
sudo ./vpcctl.py deploy-app --vpc testvpc --subnet private --name web-private --cmd "python3 -m http.server 80"
```

### Test Connectivity

```bash
# Test from private to public subnet (intra-VPC)
sudo ip netns exec vpc-testvpc-ns-private curl http://10.20.1.2

# Test internet access from public subnet
sudo ip netns exec vpc-testvpc-ns-public curl http://ifconfig.co

# Test internet access from private subnet (should fail)
sudo ip netns exec vpc-testvpc-ns-private curl http://ifconfig.co
```

### Apply Firewall Policies

```bash
# Apply security policy
sudo ./vpcctl.py apply-policy --policy-file policies/deny-ssh.json
```

### VPC Peering

```bash
# Create second VPC
sudo ./vpcctl.py create-vpc --name othervpc --cidr 10.30.0.0/16 --internet-iface eth0

# Establish peering
sudo ./vpcctl.py peer --vpc-a testvpc --vpc-b othervpc --allowed-cidrs 10.20.0.0/16,10.30.0.0/16
```

### Management Commands

```bash
# List all VPCs
sudo ./vpcctl.py list-vpcs

# Inspect VPC details
sudo ./vpcctl.py inspect --vpc testvpc

# Delete specific VPC
sudo ./vpcctl.py delete-vpc --name testvpc

# Clean up everything
sudo ./vpcctl.py teardown-all
```

## JSON Output

Add `--json` flag for machine-readable output:

```bash
sudo ./vpcctl.py list-vpcs --json
sudo ./vpcctl.py inspect --vpc testvpc --json
```

## Firewall Policy Format

Create JSON policy files in `policies/` directory:

```json
[
  {
    "subnet": "10.20.2.0/24",
    "ingress": [
      {"port": 80, "protocol": "tcp", "action": "deny"},
      {"port": 22, "protocol": "tcp", "action": "deny"}
    ],
    "egress": [
      {"port": "any", "protocol": "any", "action": "allow"}
    ]
  }
]
```

## Testing

Run the integration test suite:

```bash
sudo ./tests/integration_test.sh
```

Or run the demo script:

```bash
sudo ./scripts/demo.sh
```

## Cleanup

Always clean up resources when done:

```bash
sudo ./vpcctl.py teardown-all
sudo ./scripts/cleanup.sh
```

## Logging

All operations are logged to:
- Console output
- `logs/vpcctl.log` file

## Troubleshooting

1. **Permission denied**: Ensure running as root
2. **Command not found**: Install required packages: `apt install iproute2 iptables bridge-utils`
3. **CIDR overlap**: Use non-overlapping CIDR blocks for different VPCs
4. **Interface not found**: Verify internet interface name with `ip link show`

## State Management

VPC state is stored in `state/` directory as JSON files. Each VPC has its own state file for idempotency and inspection.