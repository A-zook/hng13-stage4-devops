#!/bin/bash
# VPCctl initialization script

echo "Initializing VPCctl project..."

# Create required directories
mkdir -p state logs

# Make scripts executable
chmod +x vpcctl.py
chmod +x scripts/*.sh
chmod +x tests/*.sh

# Check system requirements
echo "Checking system requirements..."

# Check for required commands
REQUIRED_COMMANDS="ip iptables python3"
MISSING_COMMANDS=""

for cmd in $REQUIRED_COMMANDS; do
    if ! command -v $cmd >/dev/null 2>&1; then
        MISSING_COMMANDS="$MISSING_COMMANDS $cmd"
    fi
done

if [ -n "$MISSING_COMMANDS" ]; then
    echo "Warning: Missing required commands:$MISSING_COMMANDS"
    echo "Install with: sudo apt install iproute2 iptables python3"
fi

# Check root access
if [ "$EUID" -ne 0 ]; then
    echo "Note: VPC operations require root privileges (use sudo)"
fi

echo "VPCctl initialization complete!"
echo ""
echo "Quick start:"
echo "  sudo ./vpcctl.py --help"
echo "  sudo make demo"
echo "  sudo make test"