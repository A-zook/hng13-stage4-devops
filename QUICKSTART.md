# VPCctl Quick Start Guide

## 5-Minute Setup and Demo

### Prerequisites
- Linux system (Ubuntu 22.04+ recommended)
- Root access (sudo)
- Basic networking tools (usually pre-installed)

### 1. Initialize Project
```bash
# Make scripts executable and check requirements
chmod +x *.sh scripts/*.sh tests/*.sh
./validate.sh
```

### 2. Install Dependencies (if needed)
```bash
sudo apt update
sudo apt install iproute2 iptables bridge-utils python3 curl
sudo apt install build-essential
```

### 3. Run Quick Demo
```bash
# Run the complete demo (5 minutes)
sudo make demo

# Or run individual commands:
sudo ./vpcctl.py create-vpc --name test --cidr 10.20.0.0/16 --internet-iface eth0
sudo ./vpcctl.py add-subnet --vpc test --name public --cidr 10.20.1.0/24 --type public
sudo ./vpcctl.py list-vpcs
sudo ./vpcctl.py teardown-all
```

### 4. Run Tests
```bash
# Run comprehensive integration tests
sudo make test
```

### 5. Cleanup
```bash
# Clean up all resources
sudo make clean
```

## Key Commands

| Command | Description |
|---------|-------------|
| `create-vpc` | Create new VPC with CIDR |
| `add-subnet` | Add public/private subnet |
| `deploy-app` | Run app in namespace |
| `apply-policy` | Apply firewall rules |
| `peer` | Connect two VPCs |
| `inspect` | Show VPC details |
| `list-vpcs` | List all VPCs |
| `delete-vpc` | Remove specific VPC |
| `teardown-all` | Remove everything |

## Example Workflow

```bash
# 1. Create VPC
sudo ./vpcctl.py create-vpc --name myvpc --cidr 10.10.0.0/16 --internet-iface eth0

# 2. Add subnets
sudo ./vpcctl.py add-subnet --vpc myvpc --name web --cidr 10.10.1.0/24 --type public
sudo ./vpcctl.py add-subnet --vpc myvpc --name db --cidr 10.10.2.0/24 --type private

# 3. Deploy applications
sudo ./vpcctl.py deploy-app --vpc myvpc --subnet web --name webserver --cmd "python3 -m http.server 80"

# 4. Test connectivity
sudo ip netns exec vpc-myvpc-ns-web curl http://localhost
sudo ip netns exec vpc-myvpc-ns-web ping 8.8.8.8  # Should work (public subnet)
sudo ip netns exec vpc-myvpc-ns-db ping 8.8.8.8   # Should fail (private subnet)

# 5. Apply security policy
sudo ./vpcctl.py apply-policy --policy-file policies/deny-ssh.json

# 6. Clean up
sudo ./vpcctl.py delete-vpc --name myvpc
```

## Troubleshooting

### Common Issues
1. **Permission denied**: Use `sudo` for all VPC operations
2. **Command not found**: Install missing packages with `sudo make install`
3. **CIDR overlap**: Use different IP ranges for each VPC
4. **Interface not found**: Check your internet interface name with `ip link show`

### Debug Commands
```bash
# Check namespaces
sudo ip netns list

# Check bridges
sudo ip link show type bridge

# Check routes in namespace
sudo ip netns exec vpc-name-ns-subnet ip route

# View logs
tail -f logs/vpcctl.log
```

## Files Overview

```
vpcctl/
├── vpcctl.py           # Main CLI tool
├── README.md           # Full documentation
├── QUICKSTART.md       # This file
├── Makefile           # Automation commands
├── scripts/
│   ├── demo.sh        # 5-minute demo
│   └── cleanup.sh     # Resource cleanup
├── tests/
│   └── integration_test.sh  # Test suite
├── policies/
│   ├── deny-ssh.json  # Sample firewall policy
│   └── allow-web.json # Web service policy
├── docs/
│   └── architecture.md # Technical details
├── state/             # Runtime VPC metadata
└── logs/              # Operation logs
```

Ready to start? Run `sudo make demo`!