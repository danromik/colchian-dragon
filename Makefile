.PHONY: app debug run dev release notarize install clean

APP_NAME = Colchian Dragon
BUNDLE_ID = com.danromik.colchian-dragon

# Quit a running copy gracefully, so it restores normal sleep before the new build launches.
QUIT_RUNNING = -osascript -e 'if application id "$(BUNDLE_ID)" is running then' \
	-e 'tell application id "$(BUNDLE_ID)" to quit' -e 'delay 1' -e 'end if'

app:            ## Release build, ad-hoc signed
	scripts/build-app.sh

debug:          ## Debug build for the host architecture
	CONFIG=debug ARCHS="$$(uname -m)" scripts/build-app.sh

run: debug      ## Build and launch (quits a running copy first)
	$(QUIT_RUNNING)
	open "build/$(APP_NAME).app"

dev: debug      ## Like run, but with a Dock icon
	$(QUIT_RUNNING)
	open "build/$(APP_NAME).app" --args -showDockIcon YES

release:        ## Developer ID build: make release SIGN_IDENTITY="Developer ID Application: ..."
	@test -n "$(SIGN_IDENTITY)" || (echo 'Set SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"' && exit 1)
	SIGN_IDENTITY="$(SIGN_IDENTITY)" scripts/build-app.sh

notarize:       ## Notarize and staple the app (after make release)
	scripts/notarize.sh

install: app    ## Copy to /Applications
	$(QUIT_RUNNING)
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "build/$(APP_NAME).app" /Applications/
	open "/Applications/$(APP_NAME).app"

clean:
	rm -rf .build build
