# mads Remote — Build-Helfer. Das .xcodeproj wird aus project.yml generiert (nie committen).
PROJECT := mads-remote.xcodeproj
SCHEME  := mads-remote
SIM     := platform=iOS Simulator,name=iPhone 17

.PHONY: gen open build test clean

gen: ## Xcode-Projekt aus project.yml generieren
	xcodegen generate

open: gen ## Projekt in Xcode öffnen
	open $(PROJECT)

build: gen ## Für den iOS-Simulator bauen (kein Signing nötig)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -sdk iphonesimulator \
		-destination 'generic/platform=iOS Simulator' build

test: gen ## Swift-Testing-Tests im Simulator
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -sdk iphonesimulator \
		-destination '$(SIM)' test

clean: ## Generiertes Projekt + Build-Output entfernen
	rm -rf $(PROJECT) build DerivedData
