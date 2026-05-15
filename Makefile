
#########
# Build #
#########

build: ## Build zignore
	zig build
.PHONY: build

test: ## Run unit tests
	zig build test
.PHONY: test

clean: ## Remove build artifacts
	rm -rf zig-out .zig-cache release-build
.PHONY: clean

###########
# Release #
###########

# Mirrors .github/workflows/release.yml so a contributor can rehearse the
# release matrix locally before tagging. Outputs land in release-build/.
# Needs GNU tar (provided by the nix devShell).

TARGETS := \
    x86_64-linux-musl \
    aarch64-linux-musl \
    x86_64-macos \
    aarch64-macos

VERSION           := $(shell sed -nE 's/.*\.version = "([^"]+)".*/\1/p' build.zig.zon)
SOURCE_DATE_EPOCH := $(shell git log -1 --pretty=%ct 2>/dev/null || date +%s)

release-build: ## Cross-compile + package the full release matrix into release-build/
	@rm -rf release-build && mkdir -p release-build
	@$(foreach t,$(TARGETS), \
	    echo "==> $(t)"; \
	    rm -rf zig-out .zig-cache; \
	    SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH) \
	      zig build -Dtarget=$(t) --release=safe -Dstrip=true; \
	    tar --sort=name --owner=0 --group=0 --numeric-owner \
	        --mtime="@$(SOURCE_DATE_EPOCH)" --format=ustar \
	        -cf - -C zig-out/bin zignore \
	      | gzip -n -9 > "release-build/zignore-$(VERSION)-$(t).tar.gz"; \
	)
	@cd release-build && sha256sum zignore-* > SHA256SUMS && cat SHA256SUMS
.PHONY: release-build

repro: ## Verify a published release matches a local rebuild (usage: make repro TAG=v0.2.0)
	@test -n "$(TAG)" || { echo "usage: make repro TAG=v0.2.0" >&2; exit 1; }
	@scripts/repro.sh $(TAG)
.PHONY: repro

#########
# Utils #
#########

# `git subtree` only runs from the repo toplevel. This project lives inside
# a larger monorepo (lab/), so compute the toplevel + this dir's prefix and
# cd into the toplevel for each subtree call. Falls back to no-op prefix when
# this dir *is* the toplevel.
TOPLEVEL := $(shell git rev-parse --show-toplevel)
PREFIX   := $(shell git rev-parse --show-prefix)

SUBTREES += github/gitignore

$(addprefix vendor/,$(SUBTREES)): vendor/%:
	cd $(TOPLEVEL) && git subtree add --prefix=$(PREFIX)$@ https://github.com/$* main -m "Add https://github.com/$*" --squash

update-subtrees: $(addprefix vendor/,$(SUBTREES)) ## Pull latest changes from git subtrees
	$(foreach repo,$(SUBTREES),\
		cd $(TOPLEVEL) && git subtree pull --prefix=$(PREFIX)vendor/$(repo) https://github.com/$(repo) main -m "Update https://github.com/$(repo)" --squash || :; )
.PHONY: update-subtrees

# Shell color variables
esc:=$(shell printf '\033')
reset:=$(esc)[0m
category:=$(esc)[33m
command:=$(esc)[36m
help_width:=60

help: ## Show this help
	@echo
	@echo "$(category)Usage:$(reset)"
	@echo "    make $(command)<target>$(reset)"
	@awk -v c='$(category)' -v r='$(reset)' -v cmd='$(command)' -v w=$(help_width) ' \
		BEGIN { l = 4 } \
		FNR == NR { \
			if ($$0 ~ /[ \t]## /) { \
				n = substr($$0, 1, index($$0, ":") - 1); \
				if (length(n) > mw) mw = length(n) \
			} \
			next \
		} \
		/^# .+ #$$/ { \
			sub(/^# /, ""); sub(/ #$$/, ""); \
			rt = w - length - 2 - l; if (rt < 3) rt = 3; \
			dl = sprintf("%*s", l, ""); gsub(/ /, "-", dl); \
			dr = sprintf("%*s", rt, ""); gsub(/ /, "-", dr); \
			printf "\n%s%s %s %s%s\n", c, dl, $$0, dr, r; next \
		} \
		/[ \t]## / { \
			n = substr($$0, 1, index($$0, ":") - 1); \
			d = substr($$0, index($$0, "## ") + 3); \
			printf "%s%s%s%*s  %s\n", cmd, n, r, mw - length(n), "", d \
		}' $(MAKEFILE_LIST) $(MAKEFILE_LIST)
.PHONY: help
