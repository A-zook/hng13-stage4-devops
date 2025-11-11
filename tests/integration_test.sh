#!/bin/bash
# Integration tests for VPCctl

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Test results
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== VPCctl Integration Tests ==="
echo "Running comprehensive test suite..."
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}FAIL${NC}: Tests must be run as root"
   exit 1
fi

# Detect internet interface
INTERNET_IFACE=$(ip route | grep default | head -1 | awk '{print $5}')
if [[ -z "$INTERNET_IFACE" ]]; then
    INTERNET_IFACE="eth0"
fi

echo "Using internet interface: $INTERNET_IFACE"
echo

# Helper functions
pass_test() {
    echo -e "${GREEN}PASS${NC}: $1"
    ((TESTS_PASSED++))
}

fail_test() {
    echo -e "${RED}FAIL${NC}: $1"
    ((TESTS_FAILED++))
    FAILED_TESTS+=("$1")
}

run_test() {
    local test_name="$1"
    local test_command="$2"
    
    echo -n "Testing: $test_name... "
    
    if eval "$test_command" >/dev/null 2>&1; then
        pass_test "$test_name"
        return 0
    else
        fail_test "$test_name"
        return 1
    fi
}

# Cleanup before tests
echo "Cleaning up before tests..."
./vpcctl.py teardown-all 2>/dev/null || true
sleep 1

# Test 1: VPC Creation
echo "Test 1: VPC and Subnet Creation"
./vpcctl.py create-vpc --name testvpc --cidr 10.20.0.0/16 --internet-iface $INTERNET_IFACE
./vpcctl.py add-subnet --vpc testvpc --name public --cidr 10.20.1.0/24 --type public
./vpcctl.py add-subnet --vpc testvpc --name private --cidr 10.20.2.0/24 --type private

# Check if resources were created
run_test "Bridge exists" "ip link show vpc-testvpc-br"
run_test "Public namespace exists" "ip netns list | grep vpc-testvpc-ns-public"
run_test "Private namespace exists" "ip netns list | grep vpc-testvpc-ns-private"
run_test "Public namespace has IP" "ip netns exec vpc-testvpc-ns-public ip addr show | grep 10.20.1.2"
run_test "Private namespace has IP" "ip netns exec vpc-testvpc-ns-private ip addr show | grep 10.20.2.2"

echo

# Test 2: Deploy applications
echo "Test 2: Application Deployment"
./vpcctl.py deploy-app --vpc testvpc --subnet public --name web-public --cmd "python3 -m http.server 8080" &
sleep 2
./vpcctl.py deploy-app --vpc testvpc --subnet private --name web-private --cmd "python3 -m http.server 8080" &
sleep 2

run_test "Public web server responds" "timeout 5 ip netns exec vpc-testvpc-ns-public curl -s http://localhost:8080 | grep -q 'Directory listing'"
run_test "Private web server responds" "timeout 5 ip netns exec vpc-testvpc-ns-private curl -s http://localhost:8080 | grep -q 'Directory listing'"

echo

# Test 3: Intra-VPC connectivity
echo "Test 3: Intra-VPC Connectivity"
run_test "Private can reach public subnet" "timeout 5 ip netns exec vpc-testvpc-ns-private curl -s http://10.20.1.2:8080 | grep -q 'Directory listing'"
run_test "Public can reach private subnet" "timeout 5 ip netns exec vpc-testvpc-ns-public curl -s http://10.20.2.2:8080 | grep -q 'Directory listing'"

echo

# Test 4: NAT functionality
echo "Test 4: NAT Functionality"
run_test "Public subnet has internet access" "timeout 10 ip netns exec vpc-testvpc-ns-public ping -c 2 8.8.8.8"
run_test "Private subnet blocked from internet" "! timeout 5 ip netns exec vpc-testvpc-ns-private ping -c 1 8.8.8.8"

echo

# Test 5: VPC Isolation
echo "Test 5: VPC Isolation"
./vpcctl.py create-vpc --name othervpc --cidr 10.30.0.0/16 --internet-iface $INTERNET_IFACE
./vpcctl.py add-subnet --vpc othervpc --name public --cidr 10.30.1.0/24 --type public

run_test "Second VPC created" "ip link show vpc-othervpc-br"
run_test "VPCs are isolated" "! timeout 5 ip netns exec vpc-testvpc-ns-public ping -c 1 10.30.1.2"

echo

# Test 6: VPC Peering
echo "Test 6: VPC Peering"
./vpcctl.py peer --vpc-a testvpc --vpc-b othervpc --allowed-cidrs 10.20.0.0/16,10.30.0.0/16

# Note: Peering test may need additional routing configuration
run_test "Peering veth created" "ip link show | grep -q peer-testvpc-othervpc"

echo

# Test 7: Firewall Policies
echo "Test 7: Firewall Policies"
./vpcctl.py apply-policy --policy-file policies/deny-ssh.json

run_test "Policy applied to namespace" "ip netns exec vpc-testvpc-ns-private iptables -L INPUT | grep -q DROP"

echo

# Test 8: Management Commands
echo "Test 8: Management Commands"
run_test "List VPCs works" "./vpcctl.py list-vpcs | grep -q testvpc"
run_test "Inspect VPC works" "./vpcctl.py inspect --vpc testvpc | grep -q 'VPC: testvpc'"
run_test "JSON output works" "./vpcctl.py list-vpcs --json | python3 -m json.tool"

echo

# Test 9: Idempotency
echo "Test 9: Idempotency"
run_test "Re-creating VPC is idempotent" "./vpcctl.py create-vpc --name testvpc --cidr 10.20.0.0/16 --internet-iface $INTERNET_IFACE"
run_test "Re-adding subnet is idempotent" "./vpcctl.py add-subnet --vpc testvpc --name public --cidr 10.20.1.0/24 --type public"

echo

# Test 10: Cleanup
echo "Test 10: Resource Cleanup"
./vpcctl.py delete-vpc --name testvpc
./vpcctl.py delete-vpc --name othervpc

run_test "VPC deleted" "! ip link show vpc-testvpc-br 2>/dev/null"
run_test "Namespaces removed" "! ip netns list | grep vpc-testvpc-ns"

# Final cleanup
./vpcctl.py teardown-all
run_test "All resources cleaned up" "! ip netns list | grep vpc-"

echo

# Test Results Summary
echo "=== Test Results Summary ==="
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
echo -e "Total tests: $((TESTS_PASSED + TESTS_FAILED))"

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo
    echo -e "${RED}Failed tests:${NC}"
    for test in "${FAILED_TESTS[@]}"; do
        echo "  - $test"
    done
    echo
    exit 1
else
    echo
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi