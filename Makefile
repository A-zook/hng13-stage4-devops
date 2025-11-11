# Makefile for VPCctl project

.PHONY: help demo test clean install check-root

# Default target
help:
	@echo "VPCctl Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  demo      - Run the demo script"
	@echo "  test      - Run integration tests"
	@echo "  clean     - Clean up all VPC resources"
	@echo "  teardown  - Alias for clean"
	@echo "  install   - Install dependencies (Ubuntu/Debian)"
	@echo "  check     - Check system requirements"
	@echo "  help      - Show this help message"

# Check if running as root
check-root:
	@if [ "$$(id -u)" != "0" ]; then \
		echo "Error: This command must be run as root (use sudo)"; \
		exit 1; \
	fi

# Run demo
demo: check-root
	@echo "Running VPCctl demo..."
	@chmod +x scripts/demo.sh
	@./scripts/demo.sh

# Run tests
test: check-root
	@echo "Running integration tests..."
	@chmod +x tests/integration_test.sh
	@./tests/integration_test.sh

# Clean up resources
clean: check-root
	@echo "Cleaning up VPC resources..."
	@chmod +x scripts/cleanup.sh
	@./scripts/cleanup.sh

# Alias for clean
teardown: clean

# Install system dependencies
install:
	@echo "Installing system dependencies..."
	@apt update
	@apt install -y iproute2 iptables bridge-utils python3 curl

# Check system requirements
check:
	@echo "Checking system requirements..."
	@echo -n "Python3: "
	@which python3 >/dev/null && echo "✓ Found" || echo "✗ Missing"
	@echo -n "ip command: "
	@which ip >/dev/null && echo "✓ Found" || echo "✗ Missing"
	@echo -n "iptables: "
	@which iptables >/dev/null && echo "✓ Found" || echo "✗ Missing"
	@echo -n "bridge: "
	@which brctl >/dev/null && echo "✓ Found" || echo "✗ Missing (optional)"
	@echo -n "curl: "
	@which curl >/dev/null && echo "✓ Found" || echo "✗ Missing (for tests)"
	@echo ""
	@echo "Root access: $$(if [ "$$(id -u)" = "0" ]; then echo "✓ Running as root"; else echo "✗ Not running as root (required for VPC operations)"; fi)"