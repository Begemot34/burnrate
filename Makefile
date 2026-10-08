.PHONY: test mac mac-run mac-run-demo mac-test mac-install check install lint format

test: mac-test

# the SwiftUI app with the engine inside, plus bin/burnratectl; ad-hoc signed, this Mac only
mac:
	mac/build-app.sh

mac-run: mac
	open mac/dist/Burnrate.app

# fake data, touches no accounts
mac-run-demo: mac
	open mac/dist/Burnrate.app --args -demo YES

mac-test:
	swift test --package-path mac

APP_DIR ?= $(HOME)/Applications

mac-install: mac
	mkdir -p "$(APP_DIR)"
	rm -rf "$(APP_DIR)/Burnrate.app"
	ditto mac/dist/Burnrate.app "$(APP_DIR)/Burnrate.app"

# fetch every source once and print a table
check: mac
	bin/burnratectl check

PREFIX ?= $(HOME)/.local/bin

install: mac
	mkdir -p "$(PREFIX)"
	cp bin/burnratectl "$(PREFIX)/burnratectl"

# swift-format from the toolchain, rules in .swift-format
lint:
	swift format lint --strict -r mac/Package.swift mac/Sources mac/Tests

format:
	swift format -i -r mac/Package.swift mac/Sources mac/Tests
