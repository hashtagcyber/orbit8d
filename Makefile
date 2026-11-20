APP := build/Orbit8D.app

.PHONY: app run test clean

# The audio-capture permission prompt needs a real app bundle with an Info.plist.
app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/Orbit8D $(APP)/Contents/MacOS/
	cp Support/Info.plist $(APP)/Contents/
	codesign --force --sign - $(APP)

run: app
	open $(APP)

test:
	swift test

clean:
	rm -rf .build build
