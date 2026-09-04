APP        := Sarvkrit
SCHEME     := Sarvkrit
PROJECT    := $(APP).xcodeproj
BUILD_DIR  := build
DIST_DIR   := dist
# Pin the destination. Left to itself xcodebuild enumerates simulator runtimes and fails the
# whole invocation when CoreSimulator is out of step with Xcode — which has nothing to do
# with this Mac-only app.
DEST       := -destination 'platform=macOS,arch=arm64'
RELEASE_APP := $(BUILD_DIR)/Build/Products/Release/$(APP).app

.PHONY: all generate build debug test preview run dmg notarize release install uninstall clean

all: build

generate:
	xcodegen generate

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		$(DEST) -derivedDataPath $(BUILD_DIR) build

debug: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		$(DEST) -derivedDataPath $(BUILD_DIR) build

## The unit tests are hosted *inside* Sarvkrit.app, and the shipped app sets
## LSMultipleInstancesProhibited — so LaunchServices refuses to start the test host while a copy
## of Sarvkrit is running, failing with a bare "Could not launch SarvkritTests". Stop it first.
test: generate
	@pkill -f "Sarvkrit.app/Contents/MacOS/Sarvkrit" 2>/dev/null && echo "stopped running Sarvkrit" && sleep 1 || true
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		$(DEST) -derivedDataPath $(BUILD_DIR) test
	@## And leave none running afterwards. A surviving Debug test host makes the single-instance
	@## guard silently exit the copy in /Applications, so you end up testing stale code.
	@pkill -f "Sarvkrit.app/Contents/MacOS/Sarvkrit" 2>/dev/null && echo "stopped leftover test host" || true

## Render the snapshot suites' PNGs so a visual change can actually be looked at.
## The variable reaches the test host through the scheme (see project.yml): xcodebuild does not
## pass its own environment down, so exporting it in the shell does nothing.
PREVIEW_DIR ?= $(BUILD_DIR)/preview
preview: generate
	@pkill -f "Sarvkrit.app/Contents/MacOS/Sarvkrit" 2>/dev/null && sleep 1 || true
	@mkdir -p $(PREVIEW_DIR)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		$(DEST) -derivedDataPath $(BUILD_DIR) \
		SARVKRIT_PREVIEW_DIR=$(abspath $(PREVIEW_DIR)) test
	@echo "previews written to $(abspath $(PREVIEW_DIR))"
	@pkill -f "Sarvkrit.app/Contents/MacOS/Sarvkrit" 2>/dev/null || true

## Launch the release build. Note the Accessibility grant follows the app's *location*, so
## running from build/ and running from /Applications are two separate grants.
run: build
	open $(RELEASE_APP)

dmg: build
	./scripts/build-dmg.sh $(RELEASE_APP) $(DIST_DIR)

notarize:
	./scripts/notarize.sh $(DIST_DIR)/$(APP).dmg

## Cuts a notarized GitHub release: bump, build, notarize, and only then tag and publish.
## Notarization is the gate — nothing is tagged or uploaded if Gatekeeper would still block it.
##   make release VERSION=1.0.1
release:
	./scripts/release.sh $(VERSION)

## Install to /Applications, which is where Launch at Login actually wants the app to live.
install: build
	rm -rf /Applications/$(APP).app
	cp -R $(RELEASE_APP) /Applications/
	@echo "Installed to /Applications/$(APP).app"

## Removes the installed copy. Worth doing after a bundle-ID change: the old bundle is a
## different app to macOS, and leaving it around means two launchable Sarvkrits.
uninstall:
	rm -rf /Applications/$(APP).app
	@echo "Removed /Applications/$(APP).app"

clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR) $(PROJECT)
