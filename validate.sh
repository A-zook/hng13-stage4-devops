#!/bin/bash

# VPCctl Validation Script
# Quick validation before running comprehensive tests

echo " VPCctl Validation - Quick System Check"
echo "========================================"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED} ERROR${NC}: Must run as root"
   ((ERRORS++))
else
   echo -e "${GREEN} Root privileges${NC}: OK"
fi

# Check dependencies
echo
echo "📦 Checking dependencies..."

deps=("python3" "ip" "iptables" "brctl")
for dep in "${deps[@]}"; do
    if command -v "$dep" >/dev/null 2>&1; then
        echo -e "${GREEN} $dep${NC}: Available"
    else
        echo -e "${RED} $dep${NC}: Missing"
        ((ERRORS++))
    fi
done

# Check if vpcctl.py exists and is executable
if [[ -f "vpcctl.py" ]]; then
    echo -e "${GREEN} vpcctl.py${NC}: Found"
    chmod +x vpcctl.py
else
    echo -e "${RED} vpcctl.py${NC}: Not found"
    ((ERRORS++))
fi

# Check test scripts
if [[ -f "test-vpc.sh" ]]; then
    echo -e "${GREEN} test-vpc.sh${NC}: Found"
    chmod +x test-vpc.sh
else
    echo -e "${RED} test-vpc.sh${NC}: Not found"
    ((ERRORS++))
fi

if [[ -f "tests/integration_test.sh" ]]; then
    echo -e "${GREEN} integration_test.sh${NC}: Found"
    chmod +x tests/integration_test.sh
else
    echo -e "${RED} integration_test.sh${NC}: Not found"
    ((ERRORS++))
fi

# Check internet connectivity
echo
echo " Checking connectivity..."
if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo -e "${GREEN} Internet connectivity${NC}: OK"
else
    echo -e "${YELLOW}  Internet connectivity${NC}: Limited (tests may fail)"
fi

# Detect network interface
IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [[ -n "$IFACE" ]]; then
    echo -e "${GREEN} Network interface${NC}: $IFACE"
else
    echo -e "${YELLOW}  Network interface${NC}: Could not detect default interface"
fi

# Check for existing VPC resources
echo
echo "🧹 Checking for existing VPC resources..."
if ip netns list 2>/dev/null | grep -q "vpc-"; then
    echo -e "${YELLOW}  Existing VPC namespaces${NC}: Found (will be cleaned up)"
else
    echo -e "${GREEN} VPC namespaces${NC}: Clean"
fi

if ip link show type bridge 2>/dev/null | grep -q "vpc-"; then
    echo -e "${YELLOW}  Existing VPC bridges${NC}: Found (will be cleaned up)"
else
    echo -e "${GREEN} VPC bridges${NC}: Clean"
fi

# Summary
echo
echo "📋 Validation Summary"
echo "===================="

if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN} System ready for VPCctl testing${NC}"
    echo
    echo "Next steps:"
    echo "  1. Run integration tests: sudo ./tests/integration_test.sh"
    echo "  2. Run comprehensive demo: sudo ./test-vpc.sh"
    exit 0
else
    echo -e "${RED} $ERRORS error(s) found${NC}"
    echo
    echo "Please fix the above issues before running tests."
    
    if [[ $ERRORS -eq 1 ]] && [[ $EUID -ne 0 ]]; then
        echo "Hint: Run with sudo"
    fi
    
    exit 1
fi