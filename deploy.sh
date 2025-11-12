#!/bin/bash
# Deploy VPCctl to remote server

SERVER_IP="18.132.200.41"
KEY_PATH="~/.ssh/web-server-key-pem.pem"
REMOTE_USER="ubuntu"
PROJECT_NAME="vpcctl"

echo "Deploying VPCctl to $SERVER_IP..."

# Create deployment archive
tar -czf vpcctl-deploy.tar.gz \
    vpcctl.py \
    README.md \
    QUICKSTART.md \
    Makefile \
    init.sh \
    validate.sh \
    scripts/ \
    tests/ \
    policies/ \
    docs/ \
    .gitignore

echo "Created deployment archive"

# Transfer to server
scp -i $KEY_PATH vpcctl-deploy.tar.gz $REMOTE_USER@$SERVER_IP:~/

# Extract and setup on server
ssh -i $KEY_PATH $REMOTE_USER@$SERVER_IP << 'EOF'
    # Extract project
    tar -xzf vpcctl-deploy.tar.gz
    
    # Create directories
    mkdir -p state logs
    
    # Make scripts executable
    chmod +x vpcctl.py *.sh scripts/*.sh tests/*.sh
    
    # Install dependencies
    sudo apt update
    sudo apt install -y iproute2 iptables bridge-utils python3 curl
    
    # Validate setup
    ./validate.sh
    
    echo "VPCctl deployed successfully!"
    echo "Run: sudo ./vpcctl.py --help"
EOF

echo "Deployment complete!"