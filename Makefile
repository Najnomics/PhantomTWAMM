# PhantomTWAMM Hook Makefile
# Convenience commands for development and deployment

.PHONY: help install build test test-verbose clean format lint coverage deploy-anvil deploy-demo start-anvil stop-anvil gas-snapshot

# Default target
help:
	@echo "🎭 PhantomTWAMM Hook - Available Commands:"
	@echo ""
	@echo "📦 Setup & Dependencies:"
	@echo "  install          Install all dependencies (pnpm + forge)"
	@echo "  clean            Clean build artifacts"
	@echo ""
	@echo "🔨 Build & Test:"
	@echo "  build            Compile all contracts"
	@echo "  test             Run all tests"
	@echo "  test-verbose     Run tests with verbose output"
	@echo "  coverage         Generate coverage report"
	@echo "  gas-snapshot     Create gas usage snapshot"
	@echo ""
	@echo "🎨 Code Quality:"
	@echo "  format           Format all Solidity files"
	@echo "  lint             Run linter on contracts"
	@echo ""
	@echo "🚀 Deployment:"
	@echo "  start-anvil      Start local Anvil blockchain"
	@echo "  deploy-anvil     Deploy to local Anvil"
	@echo "  deploy-demo      Run demo on deployed contracts"
	@echo "  stop-anvil       Stop local Anvil blockchain"
	@echo ""
	@echo "🔍 Development:"
	@echo "  status           Show project status"

# Setup and dependencies
install:
	@echo "📦 Installing dependencies..."
	pnpm install || echo "Warning: pnpm install failed, continuing with forge..."
	forge install
	@echo "✅ Dependencies installed"

# Build
build:
	@echo "🔨 Building contracts..."
	forge build --via-ir
	@echo "✅ Build complete"

# Testing
test:
	@echo "🧪 Running tests..."
	forge test --via-ir
	@echo "✅ Tests complete"

test-verbose:
	@echo "🧪 Running tests (verbose)..."
	forge test -vvv --via-ir
	@echo "✅ Verbose tests complete"

coverage:
	@echo "📊 Generating coverage report..."
	forge coverage --ir-minimum --report lcov
	@echo "✅ Coverage report generated"

gas-snapshot:
	@echo "⛽ Creating gas snapshot..."
	forge snapshot --via-ir
	@echo "✅ Gas snapshot created"

# Code quality
format:
	@echo "🎨 Formatting code..."
	forge fmt
	@echo "✅ Code formatted"

lint:
	@echo "🔍 Linting contracts..."
	forge fmt --check
	@echo "✅ Linting complete"

# Clean
clean:
	@echo "🧹 Cleaning build artifacts..."
	forge clean
	rm -rf cache/
	rm -rf out/
	@echo "✅ Clean complete"

# Anvil development
start-anvil:
	@echo "🔥 Starting Anvil blockchain..."
	@pkill -f anvil || true
	@sleep 1
	anvil --host 0.0.0.0 --port 8545 --chain-id 31337 &
	@echo "✅ Anvil started on port 8545"

stop-anvil:
	@echo "🛑 Stopping Anvil..."
	@pkill -f anvil || true
	@echo "✅ Anvil stopped"

deploy-anvil:
	@echo "🚀 Deploying to Anvil..."
	@if ! pgrep -f anvil > /dev/null; then \
		echo "❌ Anvil not running. Start it with 'make start-anvil'"; \
		exit 1; \
	fi
	forge script script/DeployPhantomTWAMM.s.sol \
		--rpc-url http://localhost:8545 \
		--private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
		--broadcast \
		--via-ir \
		-v
	@echo "✅ Deployment to Anvil complete"

deploy-demo:
	@echo "🎭 Running demo..."
	@if ! pgrep -f anvil > /dev/null; then \
		echo "❌ Anvil not running. Start it with 'make start-anvil'"; \
		exit 1; \
	fi
	# Note: This requires deployed contract addresses from deploy-anvil
	@echo "⚠️  Demo requires deployed contracts. Run 'make deploy-anvil' first."
	@echo "✅ Demo setup instructions displayed"

# Development helpers
status:
	@echo "📊 PhantomTWAMM Project Status:"
	@echo ""
	@echo "📁 Structure:"
	@find src -name "*.sol" | wc -l | xargs echo "  Contracts:"
	@find test -name "*.sol" | wc -l | xargs echo "  Tests:"
	@find script -name "*.sol" | wc -l | xargs echo "  Scripts:"
	@echo ""
	@echo "🔧 Environment:"
	@echo "  Solidity: $(shell forge --version | head -1)"
	@echo "  Node: $(shell node --version 2>/dev/null || echo 'Not installed')"
	@echo "  pnpm: $(shell pnpm --version 2>/dev/null || echo 'Not installed')"
	@echo ""
	@echo "📦 Dependencies:"
	@echo "  Forge libs: $(shell ls lib 2>/dev/null | wc -l | xargs echo)"
	@echo "  Node modules: $(shell [ -d node_modules ] && echo 'Installed' || echo 'Not installed')"
	@echo ""
	@if pgrep -f anvil > /dev/null; then \
		echo "🔥 Anvil: Running"; \
	else \
		echo "🔥 Anvil: Not running"; \
	fi

# Advanced deployment (with environment variables)
deploy-testnet:
	@echo "🌐 Deploying to testnet..."
	@if [ -z "$$PRIVATE_KEY" ]; then \
		echo "❌ PRIVATE_KEY environment variable required"; \
		exit 1; \
	fi
	@if [ -z "$$RPC_URL" ]; then \
		echo "❌ RPC_URL environment variable required"; \
		exit 1; \
	fi
	forge script script/DeployPhantomTWAMM.s.sol \
		--rpc-url $$RPC_URL \
		--private-key $$PRIVATE_KEY \
		--broadcast \
		--verify \
		--via-ir \
		-v
	@echo "✅ Testnet deployment complete"

# CI/CD helpers
ci-test:
	@echo "🤖 Running CI tests..."
	forge fmt --check
	forge build --via-ir
	forge test --via-ir
	forge coverage --ir-minimum
	@echo "✅ CI tests passed"

# Quick start for new developers
quickstart:
	@echo "🚀 PhantomTWAMM Quick Start"
	@echo ""
	@echo "Setting up development environment..."
	make install
	make build
	make test
	@echo ""
	@echo "✅ Setup complete! You can now:"
	@echo "  1. Run 'make start-anvil' to start local blockchain"
	@echo "  2. Run 'make deploy-anvil' to deploy contracts"
	@echo "  3. Run 'make test' to run tests"
	@echo "  4. Edit contracts in src/"
	@echo ""
	@echo "📖 See README.md for detailed documentation"

# Development workflow
dev:
	@echo "🔄 Development workflow starting..."
	make format
	make build
	make test
	@echo "✅ Development cycle complete"