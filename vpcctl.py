#!/usr/bin/env python3
"""
vpcctl - Virtual Private Cloud management tool for Linux
Production-quality CLI for creating and managing VPCs using native Linux networking
"""

import argparse
import json
import logging
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
import ipaddress
import signal

# Configuration
STATE_DIR = Path("state")
LOGS_DIR = Path("logs")
POLICIES_DIR = Path("policies")

# Ensure directories exist
STATE_DIR.mkdir(exist_ok=True)
LOGS_DIR.mkdir(exist_ok=True)
POLICIES_DIR.mkdir(exist_ok=True)

# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s',
    handlers=[
        logging.FileHandler(LOGS_DIR / "vpcctl.log"),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

class VPCError(Exception):
    """Custom exception for VPC operations"""
    pass

class VPCManager:
    def __init__(self):
        self.state_dir = STATE_DIR
        
    def _run_cmd(self, cmd, check=True, capture_output=True):
        """Execute shell command with logging"""
        logger.info(f"Executing: {' '.join(cmd) if isinstance(cmd, list) else cmd}")
        try:
            if isinstance(cmd, str):
                result = subprocess.run(cmd, shell=True, check=check, 
                                      capture_output=capture_output, text=True)
            else:
                result = subprocess.run(cmd, check=check, 
                                      capture_output=capture_output, text=True)
            if result.stdout:
                logger.debug(f"stdout: {result.stdout.strip()}")
            return result
        except subprocess.CalledProcessError as e:
            logger.error(f"Command failed: {e}")
            if e.stderr:
                logger.error(f"stderr: {e.stderr}")
            raise VPCError(f"Command failed: {e}")

    def _check_root(self):
        """Ensure running as root"""
        if os.geteuid() != 0:
            raise VPCError("This tool must be run as root")

    def _enable_ip_forward(self):
        """Enable IP forwarding"""
        self._run_cmd("sysctl -w net.ipv4.ip_forward=1")

    def _validate_cidr(self, cidr):
        """Validate CIDR format"""
        try:
            return ipaddress.ip_network(cidr, strict=False)
        except ValueError as e:
            raise VPCError(f"Invalid CIDR {cidr}: {e}")

    def _check_cidr_overlap(self, new_cidr, vpc_name=None):
        """Check for CIDR overlaps with existing VPCs"""
        new_net = self._validate_cidr(new_cidr)
        
        for vpc_file in self.state_dir.glob("*.json"):
            if vpc_name and vpc_file.stem == vpc_name:
                continue
                
            with open(vpc_file) as f:
                vpc_data = json.load(f)
                existing_net = ipaddress.ip_network(vpc_data["cidr"])
                
                if new_net.overlaps(existing_net):
                    raise VPCError(f"CIDR {new_cidr} overlaps with VPC {vpc_data['name']} ({vpc_data['cidr']})")

    def _get_vpc_state(self, vpc_name):
        """Load VPC state from file"""
        state_file = self.state_dir / f"{vpc_name}.json"
        if not state_file.exists():
            raise VPCError(f"VPC {vpc_name} does not exist")
        
        with open(state_file) as f:
            return json.load(f)

    def _save_vpc_state(self, vpc_data):
        """Save VPC state to file"""
        state_file = self.state_dir / f"{vpc_data['name']}.json"
        with open(state_file, 'w') as f:
            json.dump(vpc_data, f, indent=2)

    def _bridge_exists(self, bridge_name):
        """Check if bridge exists"""
        try:
            result = self._run_cmd(f"ip link show {bridge_name}")
            return result.returncode == 0
        except:
            return False

    def _netns_exists(self, ns_name):
        """Check if network namespace exists"""
        try:
            result = self._run_cmd(f"ip netns list")
            return ns_name in result.stdout
        except:
            return False

    def create_vpc(self, name, cidr, internet_iface):
        """Create a new VPC"""
        self._check_root()
        logger.info(f"Creating VPC name={name} cidr={cidr} internet_iface={internet_iface}")
        
        # Validate CIDR and check for overlaps
        self._validate_cidr(cidr)
        self._check_cidr_overlap(cidr, name)
        
        bridge_name = f"vpc-{name}-br"
        state_file = self.state_dir / f"{name}.json"
        
        # Check if VPC already exists
        if state_file.exists():
            existing_data = self._get_vpc_state(name)
            if existing_data["cidr"] == cidr and existing_data["internet_iface"] == internet_iface:
                logger.info(f"VPC {name} already exists with same configuration")
                return existing_data
            else:
                raise VPCError(f"VPC {name} exists with different configuration")
        
        try:
            # Create bridge
            if not self._bridge_exists(bridge_name):
                self._run_cmd(f"ip link add name {bridge_name} type bridge")
                self._run_cmd(f"ip link set dev {bridge_name} up")
                
                # Assign bridge IP (first IP in CIDR)
                network = ipaddress.ip_network(cidr)
                bridge_ip = f"{network.network_address + 1}/{network.prefixlen}"
                self._run_cmd(f"ip addr add {bridge_ip} dev {bridge_name}")
            
            # Enable IP forwarding
            self._enable_ip_forward()
            
            # Create VPC state
            vpc_data = {
                "name": name,
                "cidr": cidr,
                "internet_iface": internet_iface,
                "bridge": bridge_name,
                "subnets": {},
                "created": datetime.now().isoformat()
            }
            
            self._save_vpc_state(vpc_data)
            logger.info(f"VPC {name} created successfully")
            return vpc_data
            
        except Exception as e:
            # Rollback on failure
            logger.error(f"Failed to create VPC {name}, rolling back")
            try:
                if self._bridge_exists(bridge_name):
                    self._run_cmd(f"ip link delete {bridge_name}")
            except:
                pass
            raise

    def add_subnet(self, vpc_name, subnet_name, cidr, subnet_type):
        """Add subnet to VPC"""
        self._check_root()
        logger.info(f"Adding subnet vpc={vpc_name} name={subnet_name} cidr={cidr} type={subnet_type}")
        
        # Validate subnet type
        if subnet_type not in ["public", "private"]:
            raise VPCError("Subnet type must be 'public' or 'private'")
        
        # Load VPC state
        vpc_data = self._get_vpc_state(vpc_name)
        
        # Validate subnet CIDR is within VPC CIDR
        vpc_network = ipaddress.ip_network(vpc_data["cidr"])
        subnet_network = self._validate_cidr(cidr)
        
        if not vpc_network.supernet_of(subnet_network):
            raise VPCError(f"Subnet CIDR {cidr} is not within VPC CIDR {vpc_data['cidr']}")
        
        # Check if subnet already exists
        if subnet_name in vpc_data["subnets"]:
            existing = vpc_data["subnets"][subnet_name]
            if existing["cidr"] == cidr and existing["type"] == subnet_type:
                logger.info(f"Subnet {subnet_name} already exists with same configuration")
                return vpc_data
            else:
                raise VPCError(f"Subnet {subnet_name} exists with different configuration")
        
        ns_name = f"vpc-{vpc_name}-ns-{subnet_name}"
        veth_host = f"veth-{vpc_name}-{subnet_name}"
        veth_ns = f"veth-ns-{subnet_name}"
        
        try:
            # Create namespace
            if not self._netns_exists(ns_name):
                self._run_cmd(f"ip netns add {ns_name}")
            
            # Create veth pair
            self._run_cmd(f"ip link add {veth_host} type veth peer name {veth_ns}")
            
            # Attach host side to bridge
            self._run_cmd(f"ip link set {veth_host} master {vpc_data['bridge']}")
            self._run_cmd(f"ip link set {veth_host} up")
            
            # Move peer to namespace and configure
            self._run_cmd(f"ip link set {veth_ns} netns {ns_name}")
            
            # Configure namespace interface
            gateway_ip = str(subnet_network.network_address + 1)
            host_ip = f"{subnet_network.network_address + 2}/{subnet_network.prefixlen}"
            
            self._run_cmd(f"ip netns exec {ns_name} ip link set {veth_ns} up")
            self._run_cmd(f"ip netns exec {ns_name} ip addr add {host_ip} dev {veth_ns}")
            self._run_cmd(f"ip netns exec {ns_name} ip link set lo up")
            
            # Set default route to bridge
            self._run_cmd(f"ip netns exec {ns_name} ip route add default via {gateway_ip}")
            
            # Configure NAT for public subnets
            if subnet_type == "public":
                self._run_cmd(f"iptables -t nat -A POSTROUTING -s {cidr} -o {vpc_data['internet_iface']} -j MASQUERADE")
            
            # Update VPC state
            vpc_data["subnets"][subnet_name] = {
                "cidr": cidr,
                "type": subnet_type,
                "namespace": ns_name,
                "veth_host": veth_host,
                "veth_ns": veth_ns,
                "gateway": gateway_ip,
                "host_ip": host_ip
            }
            
            self._save_vpc_state(vpc_data)
            logger.info(f"Subnet {subnet_name} added successfully")
            return vpc_data
            
        except Exception as e:
            # Rollback on failure
            logger.error(f"Failed to add subnet {subnet_name}, rolling back")
            try:
                self._run_cmd(f"ip netns delete {ns_name}", check=False)
                self._run_cmd(f"ip link delete {veth_host}", check=False)
            except:
                pass
            raise

    def deploy_app(self, vpc_name, subnet_name, app_name, cmd):
        """Deploy application in subnet namespace"""
        self._check_root()
        logger.info(f"Deploying app vpc={vpc_name} subnet={subnet_name} name={app_name} cmd={cmd}")
        
        vpc_data = self._get_vpc_state(vpc_name)
        
        if subnet_name not in vpc_data["subnets"]:
            raise VPCError(f"Subnet {subnet_name} not found in VPC {vpc_name}")
        
        subnet = vpc_data["subnets"][subnet_name]
        ns_name = subnet["namespace"]
        
        # Create app script
        app_script = f"/tmp/app-{app_name}.sh"
        script_content = f"""#!/bin/bash
cd /tmp
{cmd} &
echo $! > /tmp/{app_name}.pid
wait
"""
        
        with open(app_script, 'w') as f:
            f.write(script_content)
        os.chmod(app_script, 0o755)
        
        # Run app in namespace
        self._run_cmd(f"ip netns exec {ns_name} {app_script}", check=False, capture_output=False)
        
        logger.info(f"App {app_name} deployed in namespace {ns_name}")
        print(f"App deployed. Test with: ip netns exec {ns_name} curl localhost")

    def apply_policy(self, policy_file):
        """Apply firewall policy from JSON file"""
        self._check_root()
        logger.info(f"Applying policy from {policy_file}")
        
        if not os.path.exists(policy_file):
            raise VPCError(f"Policy file {policy_file} not found")
        
        with open(policy_file) as f:
            policies = json.load(f)
        
        if not isinstance(policies, list):
            policies = [policies]
        
        for policy in policies:
            subnet_cidr = policy["subnet"]
            
            # Find namespace for this subnet
            ns_name = None
            for vpc_file in self.state_dir.glob("*.json"):
                with open(vpc_file) as f:
                    vpc_data = json.load(f)
                    for subnet_name, subnet_data in vpc_data["subnets"].items():
                        if subnet_data["cidr"] == subnet_cidr:
                            ns_name = subnet_data["namespace"]
                            break
                if ns_name:
                    break
            
            if not ns_name:
                logger.warning(f"No namespace found for subnet {subnet_cidr}")
                continue
            
            # Clear existing vpcctl rules
            self._run_cmd(f"ip netns exec {ns_name} iptables -F INPUT", check=False)
            self._run_cmd(f"ip netns exec {ns_name} iptables -F OUTPUT", check=False)
            
            # Apply ingress rules
            for rule in policy.get("ingress", []):
                port = rule["port"]
                protocol = rule["protocol"]
                action = "ACCEPT" if rule["action"] == "allow" else "DROP"
                
                if port == "any" and protocol == "any":
                    cmd = f"ip netns exec {ns_name} iptables -A INPUT -j {action}"
                elif port == "any":
                    cmd = f"ip netns exec {ns_name} iptables -A INPUT -p {protocol} -j {action}"
                else:
                    cmd = f"ip netns exec {ns_name} iptables -A INPUT -p {protocol} --dport {port} -j {action}"
                
                self._run_cmd(cmd)
            
            # Apply egress rules
            for rule in policy.get("egress", []):
                port = rule["port"]
                protocol = rule["protocol"]
                action = "ACCEPT" if rule["action"] == "allow" else "DROP"
                
                if port == "any" and protocol == "any":
                    cmd = f"ip netns exec {ns_name} iptables -A OUTPUT -j {action}"
                elif port == "any":
                    cmd = f"ip netns exec {ns_name} iptables -A OUTPUT -p {protocol} -j {action}"
                else:
                    cmd = f"ip netns exec {ns_name} iptables -A OUTPUT -p {protocol} --dport {port} -j {action}"
                
                self._run_cmd(cmd)
        
        logger.info("Policy applied successfully")

    def peer_vpcs(self, vpc_a, vpc_b, allowed_cidrs):
        """Create peering between two VPCs"""
        self._check_root()
        logger.info(f"Peering VPCs vpc_a={vpc_a} vpc_b={vpc_b} allowed_cidrs={allowed_cidrs}")
        
        vpc_a_data = self._get_vpc_state(vpc_a)
        vpc_b_data = self._get_vpc_state(vpc_b)
        
        bridge_a = vpc_a_data["bridge"]
        bridge_b = vpc_b_data["bridge"]
        
        # Create peering veth pair
        veth_a = f"peer-{vpc_a}-{vpc_b}"
        veth_b = f"peer-{vpc_b}-{vpc_a}"
        
        try:
            self._run_cmd(f"ip link add {veth_a} type veth peer name {veth_b}")
            
            # Attach to bridges
            self._run_cmd(f"ip link set {veth_a} master {bridge_a}")
            self._run_cmd(f"ip link set {veth_b} master {bridge_b}")
            self._run_cmd(f"ip link set {veth_a} up")
            self._run_cmd(f"ip link set {veth_b} up")
            
            # Add routes for allowed CIDRs
            cidrs = [c.strip() for c in allowed_cidrs.split(",")]
            
            for cidr in cidrs:
                # Route from A to B
                self._run_cmd(f"ip route add {cidr} dev {bridge_a}")
                # Route from B to A  
                self._run_cmd(f"ip route add {cidr} dev {bridge_b}")
            
            logger.info(f"Peering established between {vpc_a} and {vpc_b}")
            
        except Exception as e:
            logger.error(f"Failed to establish peering: {e}")
            raise

    def inspect_vpc(self, vpc_name, json_output=False):
        """Inspect VPC configuration and status"""
        try:
            vpc_data = self._get_vpc_state(vpc_name)
            
            if json_output:
                print(json.dumps(vpc_data, indent=2))
                return
            
            print(f"VPC: {vpc_data['name']}")
            print(f"CIDR: {vpc_data['cidr']}")
            print(f"Bridge: {vpc_data['bridge']}")
            print(f"Internet Interface: {vpc_data['internet_iface']}")
            print(f"Created: {vpc_data['created']}")
            print("\nSubnets:")
            
            for name, subnet in vpc_data["subnets"].items():
                print(f"  {name}:")
                print(f"    CIDR: {subnet['cidr']}")
                print(f"    Type: {subnet['type']}")
                print(f"    Namespace: {subnet['namespace']}")
                print(f"    Gateway: {subnet['gateway']}")
                
        except VPCError as e:
            if json_output:
                print(json.dumps({"error": str(e)}))
            else:
                print(f"Error: {e}")

    def list_vpcs(self, json_output=False):
        """List all VPCs"""
        vpcs = []
        
        for vpc_file in self.state_dir.glob("*.json"):
            with open(vpc_file) as f:
                vpc_data = json.load(f)
                vpcs.append({
                    "name": vpc_data["name"],
                    "cidr": vpc_data["cidr"],
                    "subnets": len(vpc_data["subnets"])
                })
        
        if json_output:
            print(json.dumps(vpcs, indent=2))
        else:
            if not vpcs:
                print("No VPCs found")
            else:
                print("VPCs:")
                for vpc in vpcs:
                    print(f"  {vpc['name']} ({vpc['cidr']}) - {vpc['subnets']} subnets")

    def delete_vpc(self, vpc_name):
        """Delete VPC and all resources"""
        self._check_root()
        logger.info(f"Deleting VPC {vpc_name}")
        
        try:
            vpc_data = self._get_vpc_state(vpc_name)
        except VPCError:
            logger.info(f"VPC {vpc_name} does not exist")
            return
        
        # Delete subnets
        for subnet_name, subnet in vpc_data["subnets"].items():
            ns_name = subnet["namespace"]
            veth_host = subnet["veth_host"]
            
            # Remove NAT rules for public subnets
            if subnet["type"] == "public":
                self._run_cmd(f"iptables -t nat -D POSTROUTING -s {subnet['cidr']} -o {vpc_data['internet_iface']} -j MASQUERADE", check=False)
            
            # Delete namespace and veth
            self._run_cmd(f"ip netns delete {ns_name}", check=False)
            self._run_cmd(f"ip link delete {veth_host}", check=False)
        
        # Delete bridge
        self._run_cmd(f"ip link delete {vpc_data['bridge']}", check=False)
        
        # Remove state file
        state_file = self.state_dir / f"{vpc_name}.json"
        state_file.unlink(missing_ok=True)
        
        logger.info(f"VPC {vpc_name} deleted successfully")

    def teardown_all(self):
        """Delete all VPCs and clean up"""
        self._check_root()
        logger.info("Tearing down all VPCs")
        
        # Delete all VPCs
        for vpc_file in self.state_dir.glob("*.json"):
            vpc_name = vpc_file.stem
            self.delete_vpc(vpc_name)
        
        # Clean up any remaining vpc- resources
        try:
            # List and delete any remaining vpc namespaces
            result = self._run_cmd("ip netns list")
            for line in result.stdout.split('\n'):
                if line.strip().startswith('vpc-'):
                    ns_name = line.strip().split()[0]
                    self._run_cmd(f"ip netns delete {ns_name}", check=False)
            
            # List and delete any remaining vpc bridges
            result = self._run_cmd("ip link show type bridge")
            for line in result.stdout.split('\n'):
                if 'vpc-' in line and '-br' in line:
                    parts = line.split()
                    if len(parts) > 1:
                        bridge_name = parts[1].rstrip(':')
                        self._run_cmd(f"ip link delete {bridge_name}", check=False)
        except:
            pass
        
        logger.info("Teardown completed")

def main():
    parser = argparse.ArgumentParser(description="VPC Control Tool")
    parser.add_argument("--json", action="store_true", help="Output in JSON format")
    
    subparsers = parser.add_subparsers(dest="command", help="Available commands")
    
    # create-vpc
    create_parser = subparsers.add_parser("create-vpc", help="Create a new VPC")
    create_parser.add_argument("--name", required=True, help="VPC name")
    create_parser.add_argument("--cidr", required=True, help="VPC CIDR block")
    create_parser.add_argument("--internet-iface", required=True, help="Internet interface for NAT")
    
    # add-subnet
    subnet_parser = subparsers.add_parser("add-subnet", help="Add subnet to VPC")
    subnet_parser.add_argument("--vpc", required=True, help="VPC name")
    subnet_parser.add_argument("--name", required=True, help="Subnet name")
    subnet_parser.add_argument("--cidr", required=True, help="Subnet CIDR")
    subnet_parser.add_argument("--type", required=True, choices=["public", "private"], help="Subnet type")
    
    # deploy-app
    app_parser = subparsers.add_parser("deploy-app", help="Deploy application in subnet")
    app_parser.add_argument("--vpc", required=True, help="VPC name")
    app_parser.add_argument("--subnet", required=True, help="Subnet name")
    app_parser.add_argument("--name", required=True, help="Application name")
    app_parser.add_argument("--cmd", required=True, help="Command to run")
    
    # apply-policy
    policy_parser = subparsers.add_parser("apply-policy", help="Apply firewall policy")
    policy_parser.add_argument("--policy-file", required=True, help="Policy JSON file")
    
    # peer
    peer_parser = subparsers.add_parser("peer", help="Peer two VPCs")
    peer_parser.add_argument("--vpc-a", required=True, help="First VPC")
    peer_parser.add_argument("--vpc-b", required=True, help="Second VPC")
    peer_parser.add_argument("--allowed-cidrs", required=True, help="Comma-separated allowed CIDRs")
    
    # inspect
    inspect_parser = subparsers.add_parser("inspect", help="Inspect VPC")
    inspect_parser.add_argument("--vpc", required=True, help="VPC name")
    
    # list-vpcs
    subparsers.add_parser("list-vpcs", help="List all VPCs")
    
    # delete-vpc
    delete_parser = subparsers.add_parser("delete-vpc", help="Delete VPC")
    delete_parser.add_argument("--name", required=True, help="VPC name")
    
    # teardown-all
    subparsers.add_parser("teardown-all", help="Delete all VPCs")
    
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        return
    
    vpc_manager = VPCManager()
    
    try:
        if args.command == "create-vpc":
            vpc_manager.create_vpc(args.name, args.cidr, args.internet_iface)
            
        elif args.command == "add-subnet":
            vpc_manager.add_subnet(args.vpc, args.name, args.cidr, args.type)
            
        elif args.command == "deploy-app":
            vpc_manager.deploy_app(args.vpc, args.subnet, args.name, args.cmd)
            
        elif args.command == "apply-policy":
            vpc_manager.apply_policy(args.policy_file)
            
        elif args.command == "peer":
            vpc_manager.peer_vpcs(args.vpc_a, args.vpc_b, args.allowed_cidrs)
            
        elif args.command == "inspect":
            vpc_manager.inspect_vpc(args.vpc, args.json)
            
        elif args.command == "list-vpcs":
            vpc_manager.list_vpcs(args.json)
            
        elif args.command == "delete-vpc":
            vpc_manager.delete_vpc(args.name)
            
        elif args.command == "teardown-all":
            vpc_manager.teardown_all()
            
    except VPCError as e:
        logger.error(f"VPC operation failed: {e}")
        sys.exit(1)
    except KeyboardInterrupt:
        logger.info("Operation cancelled by user")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()