#!/bin/bash
# Quick validation script for VPCctl

echo "=== VPCctl Validation ==="

# Check if files exist
echo "Checking project files..."
FILES=(
    "vpcctl.py"
    "README.md"
    "Makefile"
    "scripts/demo.sh"
    "scripts/cleanup.sh"
    "tests/integration_test.sh"
    "policies/deny-ssh.json"
    "docs/architecture.md"
)

for file in "${FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "✓ $file"
    else
        echo "✗ $file (missing)"
    fi
done

echo
echo "Checking directories..."
DIRS=("state" "logs" "policies" "scripts" "tests" "docs")

for dir in "${DIRS[@]}"; do
    if [ -d "$dir" ]; then
        echo "✓ $dir/"
    else
        echo "✗ $dir/ (missing)"
    fi
done

echo
echo "Checking Python syntax..."
if python3 -m py_compile vpcctl.py 2>/dev/null; then
    echo "✓ vpcctl.py syntax valid"
else
    echo "✗ vpcctl.py syntax error"
fi

echo
echo "Checking help output..."
if python3 vpcctl.py --help >/dev/null 2>&1; then
    echo "✓ vpcctl.py help works"
else
    echo "✗ vpcctl.py help failed"
fi

echo
echo "System requirements:"
echo -n "  Python3: "
which python3 >/dev/null && echo "✓" || echo "✗"
echo -n "  ip command: "
which ip >/dev/null && echo "✓" || echo "✗"
echo -n "  iptables: "
which iptables >/dev/null && echo "✓" || echo "✗"

echo
if [ "$EUID" -eq 0 ]; then
    echo "✓ Running as root (ready for VPC operations)"
else
    echo "ℹ Not running as root (use sudo for VPC operations)"
fi

echo
echo "Validation complete!"
echo "Run 'sudo make demo' to test the system"