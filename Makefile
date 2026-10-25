.PHONY: app install run clean

app:
	./scripts/build-app.sh

install:
	./scripts/build-app.sh --install

run: app
	open build/QuickInstall.app

clean:
	rm -rf .build build
