# PhantomTWAMM Makefile
# Provides convenient commands for development and deployment

.PHONY: help build test test-unit test-fuzz test-integration test-lib coverage clean deploy-local deploy-testnet deploy-mainnet

# Default target
help:
	@echo "PhantomTWAMM Development Commands"
	@echo "=================================="
	@echo ""
	@echo "Build Commands:"
	@echo "  build          - Build the project"
	@echo "  clean          - Clean build artifacts"
	@echo ""
	@echo "Test Commands:"
	@echo "  test           - Run all tests"
	@echo "  test-unit      - Run unit tests only"
	@echo "  test-fuzz      - Run fuzz tests only"
	@echo "  test-integration - Run integration tests only"
	@echo "  test-lib       - Run library tests only"
	@echo "  coverage       - Run tests with coverage report"
	@echo ""
	@echo "Deployment Commands:"
	@echo "  deploy-local   - Deploy to local Anvil"
	@echo "  deploy-testnet - Deploy to testnet"
	@echo "  deploy-mainnet - Deploy to mainnet"
	@echo ""

# Build commands
build:
	@echo "Building PhantomTWAMM..."
	forge build

clean:
	@echo "Cleaning build artifacts..."
	forge clean
	rm -rf out/
	rm -rf cache/

# Test commands
test:
	@echo "Running all tests..."
	forge test --no-match-test "testFuzzTickSpacing|testFuzzGasLimit"

test-unit:
	@echo "Running unit tests..."
	forge test --match-path "test/unit/*"

test-fuzz:
	@echo "Running fuzz tests..."
	forge test --match-path "test/fuzz/*"

test-integration:
	@echo "Running integration tests..."
	forge test --match-path "test/integration/*"

test-lib:
	@echo "Running library tests..."
	forge test --match-path "test/lib/*"

coverage:
	@echo "Running tests with coverage..."
	forge coverage --ir-minimum

# Deployment commands
deploy-local:
	@echo "Deploying to local Anvil..."
	@if ! pgrep -f "anvil" > /dev/null; then \
		echo "Starting Anvil..."; \
		anvil --host 0.0.0.0 --port 8545 & \
		sleep 3; \
	fi
	forge script script/SimpleDeploy.s.sol --rpc-url http://localhost:8545 --broadcast

deploy-testnet:
	@echo "Deploying to testnet..."
	@if [ -z "$$RPC_URL" ]; then \
		echo "Error: RPC_URL environment variable not set"; \
		exit 1; \
	fi
	forge script script/DeployPhantomTWAMM.s.sol --rpc-url $$RPC_URL --broadcast --verify

deploy-mainnet:
	@echo "Deploying to mainnet..."
	@if [ -z "$$MAINNET_RPC" ]; then \
		echo "Error: MAINNET_RPC environment variable not set"; \
		exit 1; \
	fi
	forge script script/DeployPhantomTWAMM.s.sol --rpc-url $$MAINNET_RPC --broadcast --verify

# Development utilities
install:
	@echo "Installing dependencies..."
	forge install
	npm install

setup: install
	@echo "Setting up development environment..."
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "Created .env file from .env.example"; \
		echo "Please edit .env with your configuration"; \
	fi

# Gas optimization
gas-report:
	@echo "Generating gas report..."
	forge test --gas-report --no-match-test "testFuzzTickSpacing|testFuzzGasLimit"

# Security checks
slither:
	@echo "Running Slither security analysis..."
	@if command -v slither >/dev/null 2>&1; then \
		slither .; \
	else \
		echo "Slither not installed. Install with: pip install slither-analyzer"; \
	fi

# Documentation
docs:
	@echo "Generating documentation..."
	@if command -v forge doc >/dev/null 2>&1; then \
		forge doc --build; \
	else \
		echo "Forge doc not available. Install latest Foundry version."; \
	fi