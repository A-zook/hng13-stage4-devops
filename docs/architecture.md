# VPCctl Architecture

## Overview

VPCctl implements Virtual Private Clouds using native Linux networking primitives. Each VPC is an isolated network environment with its own subnets, routing, and security policies.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        Host Network                              │
│                                                                 │
│  ┌─────────────────┐                ┌─────────────────┐        │
│  │   VPC-A         │                │   VPC-B         │        │
│  │ (10.10.0.0/16)  │                │ (10.20.0.0/16)  │        │
│  │                 │                │                 │        │
│  │ ┌─────────────┐ │                │ ┌─────────────┐ │        │
│  │ │Bridge       │ │    Peering     │ │Bridge       │ │        │
│  │ │vpc-A-br     │◄├────────────────┤►│vpc-B-br     │ │        │
│  │ │10.10.0.1/16 │ │   (optional)   │ │10.20.0.1/16 │ │        │
│  │ └─────────────┘ │                │ └─────────────┘ │        │
│  │        │        │                │        │        │        │
│  │   ┌────┴────┐   │                │   ┌────┴────┐   │        │
│  │   │ veth    │   │                │   │ veth    │   │        │
│  │   │ pairs   │   │                │   │ pairs   │   │        │
│  │   └────┬────┘   │                │   └────┬────┘   │        │
│  │        │        │                │        │        │        │
│  │ ┌──────▼──────┐ │                │ ┌──────▼──────┐ │        │
│  │ │Public Subnet│ │                │ │Public Subnet│ │        │
│  │ │10.10.1.0/24 │ │                │ │10.20.1.0/24 │ │        │
│  │ │   (netns)   │ │                │ │   (netns)   │ │        │
│  │ │     NAT     │ │                │ │     NAT     │ │        │
│  │ └─────────────┘ │                │ └─────────────┘ │        │
│  │        │        │                │        │        │        │
│  │ ┌──────▼──────┐ │                │ ┌──────▼──────┐ │        │
│  │ │Private      │ │                │ │Private      │ │        │
│  │ │Subnet       │ │                │ │Subnet       │ │        │
│  │ │10.10.2.0/24 │ │                │ │10.20.2.0/24 │ │        │
│  │ │   (netns)   │ │                │ │   (netns)   │ │        │
│  │ │  No Internet│ │                │ │  No Internet│ │        │
│  │ └─────────────┘ │                │ └─────────────┘ │        │
│  └─────────────────┘                └─────────────────┘        │
│                                                                 │
│                           │                                     │
│                           ▼                                     │
│                    ┌─────────────┐                             │
│                    │   Internet  │                             │
│                    │ (via NAT)   │                             │
│                    └─────────────┘                             │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### 1. VPC (Virtual Private Cloud)
- **Implementation**: Linux bridge (`vpc-<name>-br`)
- **Purpose**: Acts as virtual router/switch for the VPC
- **IP Assignment**: First IP in VPC CIDR (e.g., 10.10.0.1/16)
- **Isolation**: Each VPC has its own bridge, ensuring network isolation

### 2. Subnets
- **Implementation**: Network namespaces (`vpc-<vpc>-ns-<subnet>`)
- **Types**:
  - **Public**: Has NAT for internet access
  - **Private**: Internal-only, no internet access
- **Connectivity**: Connected to VPC bridge via veth pairs

### 3. Network Connectivity

#### Veth Pairs
```
Host Side: veth-<vpc>-<subnet> (attached to bridge)
    │
    └── Namespace Side: veth-ns-<subnet> (inside netns)
```

#### Routing
- **Intra-VPC**: All subnets can communicate via bridge
- **Internet Access**: Public subnets use NAT (MASQUERADE)
- **Default Route**: Points to bridge IP (VPC gateway)

### 4. NAT Implementation
```bash
iptables -t nat -A POSTROUTING -s <subnet-cidr> -o <internet-iface> -j MASQUERADE
```

### 5. Firewall Policies
- **Implementation**: iptables rules inside namespaces
- **Scope**: Per-subnet ingress/egress rules
- **Format**: JSON-based policy files

### 6. VPC Peering
- **Implementation**: Dedicated veth pair between bridges
- **Routing**: Static routes for allowed CIDRs
- **Control**: Explicit CIDR allowlists

## Data Flow

### 1. Intra-VPC Communication
```
Namespace A → veth → Bridge → veth → Namespace B
```

### 2. Internet Access (Public Subnets)
```
Namespace → veth → Bridge → Host → NAT → Internet
```

### 3. VPC Peering
```
VPC-A Namespace → Bridge-A → Peering veth → Bridge-B → VPC-B Namespace
```

## State Management

### File Structure
```
state/
├── vpc1.json          # VPC metadata
├── vpc2.json
└── ...

Each VPC file contains:
{
  "name": "vpc-name",
  "cidr": "10.10.0.0/16",
  "bridge": "vpc-name-br",
  "internet_iface": "eth0",
  "subnets": {
    "subnet-name": {
      "cidr": "10.10.1.0/24",
      "type": "public|private",
      "namespace": "vpc-name-ns-subnet",
      "veth_host": "veth-name-subnet",
      "veth_ns": "veth-ns-subnet",
      "gateway": "10.10.1.1",
      "host_ip": "10.10.1.2/24"
    }
  }
}
```

## Security Model

### 1. Network Isolation
- **VPC Level**: Separate bridges prevent cross-VPC communication
- **Subnet Level**: Network namespaces provide process isolation
- **Default Deny**: No communication between VPCs unless explicitly peered

### 2. Firewall Policies
- **Namespace-scoped**: Rules apply only within specific subnets
- **Stateless**: Simple allow/deny rules for ports and protocols
- **Deterministic**: Rules applied in consistent order

### 3. NAT Security
- **Outbound Only**: NAT only allows outbound connections
- **Source-based**: NAT rules tied to specific subnet CIDRs
- **Interface-specific**: NAT limited to configured internet interface

## Scalability Considerations

### Limits
- **VPCs**: Limited by available bridge interfaces (~65k theoretical)
- **Subnets**: Limited by network namespaces (~32k per VPC)
- **Performance**: Bridge forwarding performance depends on host resources

### Best Practices
- **CIDR Planning**: Use non-overlapping CIDRs
- **Resource Cleanup**: Always clean up unused resources
- **Monitoring**: Check logs for resource usage and errors

## Troubleshooting

### Common Issues
1. **CIDR Overlap**: Validate CIDR ranges before creation
2. **Permission Denied**: Ensure running as root
3. **Interface Not Found**: Verify internet interface exists
4. **Namespace Conflicts**: Check for existing namespaces

### Debugging Commands
```bash
# List namespaces
ip netns list

# Show bridges
ip link show type bridge

# Check routes in namespace
ip netns exec <namespace> ip route

# View iptables rules
ip netns exec <namespace> iptables -L

# Test connectivity
ip netns exec <namespace> ping <target>
```