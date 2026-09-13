DART ?= dart
FLUTTER ?= flutter
NPM ?= npm

.PHONY: setup analyze test check
.NOTPARALLEL:

setup:
	$(NPM) ci --prefix tool/gateway --include=dev --no-audit --no-fund
	cd packages/handrail_ai_client && $(DART) pub get
	cd packages/handrail_ai_widgets && $(FLUTTER) pub get

analyze:
	cd packages/handrail_ai_client && $(DART) analyze --fatal-infos
	cd packages/handrail_ai_widgets && $(FLUTTER) analyze --no-pub --fatal-infos

test:
	cd packages/handrail_ai_client && $(DART) test --concurrency=1
	cd packages/handrail_ai_widgets && $(FLUTTER) test --no-pub --concurrency=1

check: analyze test
