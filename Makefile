# mads Remote — Build-Helfer. Das .xcodeproj wird aus project.yml generiert (nie committen).
PROJECT := mads-remote.xcodeproj
SCHEME  := mads-remote
SIM     := platform=iOS Simulator,name=iPhone 17

.PHONY: gen open build test device strip-xattr clean

gen: ## Xcode-Projekt aus project.yml generieren
	xcodegen generate

open: gen ## Projekt in Xcode öffnen
	open $(PROJECT)

strip-xattr: ## Extended Attributes aus den Quellen werfen
	# Ohne das scheitert das Signieren fürs Gerät an „resource fork, Finder information, or
	# similar detritus not allowed": ein `com.apple.quarantine` an einer Asset-Datei reicht,
	# und die fangen sich Dateien schon beim Kopieren aus Downloads/iCloud ein.
	xattr -cr App

device: gen strip-xattr ## Release aufs angeschlossene Gerät bauen + installieren (DEVICE=<udid>)
	@test -n "$(DEVICE)" || { echo "DEVICE=<udid> setzen. Verfügbare Geräte:"; xcrun devicectl list devices; exit 1; }
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination 'platform=iOS,id=$(DEVICE)' -derivedDataPath build/DerivedData-device \
		-allowProvisioningUpdates build
	xcrun devicectl device install app --device $(DEVICE) \
		build/DerivedData-device/Build/Products/Release-iphoneos/mads-remote.app

build: gen ## Für den iOS-Simulator bauen (kein Signing nötig)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -sdk iphonesimulator \
		-destination 'generic/platform=iOS Simulator' build

test: gen ## Swift-Testing-Tests im Simulator
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -sdk iphonesimulator \
		-destination '$(SIM)' test

clean: ## Generiertes Projekt + Build-Output entfernen
	rm -rf $(PROJECT) build DerivedData
