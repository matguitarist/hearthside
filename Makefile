.DEFAULT_GOAL := help
SHELL := /bin/bash

DATA_DIR := wow-data
DATA     := $(DATA_DIR)/Data

.PHONY: help build native ship app release-mac fetch-data clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

fetch-data: ## Download the game data (a WoW 1.12.1 client) from archive.org
	./tools/fetch-data.sh

build: fetch-data ## Fetch data + build the native game (release)
	cargo build --release -p warcraft-survivors

native: fetch-data ## Build + run the native desktop version
	WOW_DATA=$(DATA) cargo run --release -p warcraft-survivors

ship: fetch-data ## Build the optimized native binary (fat LTO, ~15 min)
	cargo build --profile ship -p warcraft-survivors

app: ## Build the signed macOS app (launcher + game) into target/macos/
	./tools/macos-app.sh

release-mac: ## Build, notarize and package the macOS app + Sparkle appcast (macos/README.md)
	./tools/macos-app.sh --release

clean: ## Remove the fetched game data
	rm -rf $(DATA_DIR)
