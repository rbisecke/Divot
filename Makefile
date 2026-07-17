# Divot — build & validation entry points. Run from the repo root.
DEVICE ?=
SIM ?= platform=iOS Simulator,name=iPhone 17
PROJECT = ios/Divot.xcodeproj
SCHEME = Divot

.PHONY: bootstrap generate validate test device-test placeholder

bootstrap:            ## one-time on a fresh clone
	brew install xcodegen xcbeautify
	$(MAKE) generate

generate:             ## regenerate the Xcode project from ios/project.yml
	xcodegen generate --spec ios/project.yml --project ios

validate:             ## T1 engine golden checks (headless, no Xcode needed)
	bash SwingCore/validate.sh
	@grep -qE "ALL PASS, [0-9]+ checks" /tmp/sc.log && grep -E "ALL PASS, [0-9]+ checks" /tmp/sc.log | tail -1 | sed 's/^/engine: /' || (echo "engine: FAILED" && exit 1)

test: generate        ## T2 simulator: unit + a11y audit + screenshot tour
	set -o pipefail; NSUnbufferedIO=YES xcodebuild test \
	  -project $(PROJECT) -scheme $(SCHEME) -destination '$(SIM)' | xcbeautify

device-test: generate ## T3 on-device (make device-test DEVICE=<udid>)
	set -o pipefail; NSUnbufferedIO=YES xcodebuild test \
	  -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=iOS,id=$(DEVICE)' \
	  -allowProvisioningUpdates | xcbeautify

placeholder:          ## regenerate the synthetic test clip
	swift tools/make_placeholder_clip.swift
