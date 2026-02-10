# OpenVision Makefile

.PHONY: setup generate clean open help

# Default target
help:
	@echo "OpenVision Build Commands:"
	@echo ""
	@echo "  make setup     - Install dependencies and generate Xcode project"
	@echo "  make generate  - Generate Xcode project from project.yml"
	@echo "  make open      - Open project in Xcode"
	@echo "  make clean     - Remove generated files"
	@echo ""
	@echo "First time setup:"
	@echo "  1. Edit Config.xcconfig with your Team ID and Meta App ID"
	@echo "  2. Run: make setup"
	@echo "  3. Run: make open"

# Install xcodegen if needed and generate project
setup: check-config
	@echo "Checking for xcodegen..."
	@which xcodegen > /dev/null || (echo "Installing xcodegen..." && brew install xcodegen)
	@echo "Generating Xcode project..."
	@xcodegen generate
	@echo ""
	@echo "✅ Project generated! Run 'make open' to open in Xcode"

# Generate Xcode project
generate: check-config
	@xcodegen generate
	@echo "✅ Project generated!"

# Check that config files exist
check-config:
	@if [ ! -f "Config.xcconfig" ]; then \
		echo "❌ Error: Config.xcconfig not found"; \
		echo "Please copy Config.xcconfig.example to Config.xcconfig and fill in your values"; \
		exit 1; \
	fi
	@if grep -q "XXXXXXXXXX" Config.xcconfig; then \
		echo "⚠️  Warning: Config.xcconfig still has placeholder values"; \
		echo "Please edit Config.xcconfig with your Development Team ID and Meta App ID"; \
	fi

# Open in Xcode
open:
	@if [ -d "OpenVision.xcodeproj" ]; then \
		open OpenVision.xcodeproj; \
	else \
		echo "❌ Project not found. Run 'make setup' first."; \
	fi

# Clean generated files
clean:
	@rm -rf OpenVision.xcodeproj
	@rm -rf .build
	@rm -rf DerivedData
	@echo "✅ Cleaned!"

# Format code (requires swiftformat)
format:
	@which swiftformat > /dev/null || (echo "Installing swiftformat..." && brew install swiftformat)
	@swiftformat OpenVision --indent 4 --swiftversion 5.9

# Lint code (requires swiftlint)
lint:
	@which swiftlint > /dev/null || (echo "Installing swiftlint..." && brew install swiftlint)
	@swiftlint OpenVision
