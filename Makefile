.PHONY: help check login whoami config remote assets big track status commit push pull \
        verify roundtrip debug debug-off clean clean-assets clean-roundtrip clean-s3

.DEFAULT_GOAL := help

# Git Bash / MSYS rewrites an argument that looks like a POSIX path, so
# `git config lfs-dal.root /utopia-online/lfs-test` is stored as
# `D:/apps/scoop/apps/git/<version>/utopia-online/lfs-test` and every upload goes
# to a key the IAM policy denies. Turn that off for everything make runs.
export MSYS_NO_PATHCONV := 1
export MSYS2_ARG_CONV_EXCL := *

# ---------------------------------------------------------------------------
# Scratch repo for exercising the Utopia LFS setup (lfs-dal -> S3, via SSO).
#
# Typical first run:
#   make check            tools installed?
#   make login            aws sso login
#   make whoami           must be the git-lfs-developer role
#   make config remote    wire up lfs-dal; point origin at GitHub
#   make assets commit push verify
#   make roundtrip        fresh clone gets the files back from S3
#
# Needs a POSIX sh (WSL, Git Bash, or scoop's sh) and python3.
# ---------------------------------------------------------------------------

SSO_SESSION ?= utopia-online
# Profile that assumes the git-lfs developer role (see docs/git-lfs-usage.md in
# utopia-online-platform).
AWS_PROFILE ?= shared-services-lfs
REGION      ?= ap-southeast-2

# Key prefix inside the bucket. The developer role can only write under the
# repository keys configured in Terraform (utopia-online, rogue-agents,
# utopia-modules), so a made-up key like /test-lfs/lfs is denied. A scratch
# folder under an existing key works today and is easy to delete (clean-s3).
# Add a `test-lfs` key to lfs_repositories if you want it to have its own prefix.
ROOT        ?= /utopia-online/lfs-test
PREFIX       = $(patsubst /%,%,$(ROOT))

# The bucket name embeds the AWS account ID, so it is looked up from your login
# rather than written down. Override with BUCKET=<name> to skip the lookup.
ACCOUNT_ID   = $(shell aws --profile $(AWS_PROFILE) sts get-caller-identity --query Account --output text 2>/dev/null)
BUCKET      ?= $(if $(ACCOUNT_ID),utopia-online-shared-services-git-lfs-$(ACCOUNT_ID))
NEED_BUCKET  = bucket="$(BUCKET)"; test -n "$$bucket" || { echo "No bucket: run 'make login' first, or pass BUCKET=<name>."; exit 1; }

BRANCH      ?= main
# Git history goes to GitHub; only the LFS objects go to S3. The repo is public,
# so keep anything sensitive out of it (the bucket name stays in .git/config).
REMOTE_URL  ?= git@github.com:utopia-investments/test-lfs.git
MSG         ?= Add LFS test assets

SMALL_MB    ?= 1
# Above ~8 MB S3 clients switch to multipart, which is what the IAM policy's
# multipart actions exist for. Keep this above that.
MEDIUM_MB   ?= 32
BIG_MB      ?= 600

PY          ?= $(shell command -v python3 || command -v python)
# Wraps a command so lfs-dal sees your SSO login as AWS_* variables.
A2W          = aws2-wrap --profile $(AWS_PROFILE)

# $(call MKBLOB,<path>,<megabytes>): incompressible random file, written in 1 MiB chunks.
define MKBLOB
$(PY) -c "import os,sys; f=open(sys.argv[1],'wb'); [f.write(os.urandom(1<<20)) for _ in range(int(sys.argv[2]))]; f.close()" $(1) $(2)
endef

help:
	@echo "test-lfs: exercise lfs-dal against the Utopia LFS bucket"
	@echo ""
	@echo "Session:"
	@echo "  check        Are git, git-lfs, lfs-dal, aws and aws2-wrap installed?"
	@echo "  login        aws sso login (session $(SSO_SESSION))"
	@echo "  whoami       Show who you are; fails unless it is the git-lfs-developer role"
	@echo ""
	@echo "Set up:"
	@echo "  config       Configure this clone for lfs-dal (bucket looked up from your login)"
	@echo "  remote       Point origin at $(REMOTE_URL)"
	@echo "  assets       Create test files: $(SMALL_MB) MB, $(MEDIUM_MB) MB (multipart) and a .umap"
	@echo "  big          Also create a $(BIG_MB) MB file (BIG_MB=...); slow and a real upload"
	@echo ""
	@echo "Use:"
	@echo "  track        git lfs track *.uasset *.umap"
	@echo "  status       Tracked files and the active transfer agent"
	@echo "  commit       Stage and commit (MSG=...)"
	@echo "  push         aws2-wrap git push origin $(BRANCH)"
	@echo "  pull         aws2-wrap git lfs pull"
	@echo ""
	@echo "Check:"
	@echo "  verify       List the S3 objects and show their encryption (expect SSEKMSKeyId)"
	@echo "  roundtrip    Fresh clone from origin, pull from S3, compare to the originals"
	@echo "  debug        Turn on lfs-dal logging to log-lfs-dal.txt (debug-off reverses it)"
	@echo ""
	@echo "Clean up:"
	@echo "  clean        clean-assets + clean-roundtrip"
	@echo "  clean-s3     Delete s3://<bucket>/$(PREFIX)/ (needs CONFIRM=yes)"
	@echo ""
	@echo "Settings now: AWS_PROFILE=$(AWS_PROFILE) ROOT=$(ROOT) REGION=$(REGION)"

# ---------------------------------------------------------------------------
# Session
# ---------------------------------------------------------------------------

check:
	@ok=1; for t in git git-lfs lfs-dal aws aws2-wrap; do \
	  if command -v $$t >/dev/null 2>&1; then echo "ok       $$t"; else echo "MISSING  $$t"; ok=0; fi; \
	done; \
	[ $$ok = 1 ] || { echo ""; echo "Install the missing tools: see docs/git-lfs-usage.md step 1."; exit 1; }

login:
	aws sso login --sso-session $(SSO_SESSION)

whoami:
	@arn=$$(aws --profile $(AWS_PROFILE) sts get-caller-identity --query Arn --output text) || exit 1; \
	echo "$$arn"; \
	case "$$arn" in \
	  *git-lfs-developer*) echo "ok: git-lfs-developer role" ;; \
	  *) echo "WARNING: not the git-lfs-developer role, so pushes will be denied. Check AWS_PROFILE=$(AWS_PROFILE)."; exit 1 ;; \
	esac

# ---------------------------------------------------------------------------
# Set up
# ---------------------------------------------------------------------------

# DIR lets `roundtrip` configure its fresh clone the same way: make config DIR=.roundtrip
DIR ?= .

# Idempotent. lfs-dal fails with 'The configuration file at ".lfsdalconfig" could
# not be read' if that file is missing, so it always exists and is committed. It
# holds only the non-secret settings. The bucket name embeds the account ID, so
# it (and the root) go in .git/config, which is never committed.
config:
	@$(NEED_BUCKET); \
	git -C $(DIR) lfs install --local && \
	git -C $(DIR) config lfs.standalonetransferagent lfs-dal && \
	git -C $(DIR) config lfs.customtransfer.lfs-dal.path lfs-dal && \
	git -C $(DIR) config -f .lfsconfig lfs.url lfs-dal && \
	git -C $(DIR) config -f .lfsdalconfig lfs-dal.scheme s3 && \
	git -C $(DIR) config -f .lfsdalconfig lfs-dal.region $(REGION) && \
	git -C $(DIR) config lfs-dal.bucket "$$bucket" && \
	git -C $(DIR) config lfs-dal.root $(ROOT) && \
	{ git -C $(DIR) config --unset lfs-dal.scheme; git -C $(DIR) config --unset lfs-dal.region; true; } 2>/dev/null; \
	echo "Configured $(DIR): bucket=$$bucket root=$$(git -C $(DIR) config lfs-dal.root) region=$(REGION)"

remote:
	@if git remote get-url origin >/dev/null 2>&1; then git remote set-url origin "$(REMOTE_URL)"; else git remote add origin "$(REMOTE_URL)"; fi
	@git remote -v

assets:
	@mkdir -p assets
	@[ -f assets/small.uasset ]  || $(call MKBLOB,assets/small.uasset,$(SMALL_MB))
	@[ -f assets/medium.uasset ] || $(call MKBLOB,assets/medium.uasset,$(MEDIUM_MB))
	@[ -f assets/level.umap ]    || $(call MKBLOB,assets/level.umap,4)
	@ls -l assets

big:
	@mkdir -p assets
	@[ -f assets/big.uasset ] || $(call MKBLOB,assets/big.uasset,$(BIG_MB))
	@ls -l assets/big.uasset

# ---------------------------------------------------------------------------
# Use
# ---------------------------------------------------------------------------

track:
	git lfs track "*.uasset" "*.umap"

status:
	@git lfs env 2>&1 | grep -iE 'transfer|endpoint' || true
	@echo "--- tracked by LFS"
	@git lfs ls-files

commit: track
	git add .gitattributes .lfsconfig .lfsdalconfig .gitignore Makefile assets
	@git diff --cached --quiet && echo "Nothing to commit." || git commit -m "$(MSG)"

push: remote
	$(A2W) git push -u origin $(BRANCH)

pull:
	$(A2W) git lfs pull

# ---------------------------------------------------------------------------
# Check
# ---------------------------------------------------------------------------

verify:
	@$(NEED_BUCKET); \
	echo "== objects under s3://$$bucket/$(PREFIX)/"; \
	aws --profile $(AWS_PROFILE) s3 ls "s3://$$bucket/$(PREFIX)/" --recursive --human-readable || exit 1; \
	key=$$(aws --profile $(AWS_PROFILE) s3api list-objects-v2 --bucket "$$bucket" --prefix "$(PREFIX)/" --max-items 1 --query 'Contents[0].Key' --output text); \
	[ -n "$$key" ] && [ "$$key" != "None" ] || { echo "No objects yet. Run: make push"; exit 1; }; \
	echo "== encryption of $$key (expect SSEKMSKeyId)"; \
	aws --profile $(AWS_PROFILE) s3api head-object --bucket "$$bucket" --key "$$key" \
	  --query '{Size:ContentLength,Encryption:ServerSideEncryption,SSEKMSKeyId:SSEKMSKeyId}'

# A fresh clone from origin must get the real files back from S3, not pointers.
roundtrip: clean-roundtrip
	GIT_LFS_SKIP_SMUDGE=1 git clone --quiet "$(REMOTE_URL)" .roundtrip
	@$(MAKE) --no-print-directory config DIR=.roundtrip
	cd .roundtrip && $(A2W) git lfs pull
	@$(PY) -c "import filecmp,glob,sys; bad=[f for f in glob.glob('assets/*') if not filecmp.cmp(f,'.roundtrip/'+f,shallow=False)]; print('MISMATCH:',bad) if bad else print('roundtrip ok: every file matches the original'); sys.exit(1 if bad else 0)"

debug:
	git config lfs.customtransfer.lfs-dal.args "--log-output=log-lfs-dal.txt --log-level=debug"
	git config lfs.customtransfer.lfs-dal.concurrent false
	@echo "Logging to log-lfs-dal.txt. 'make debug-off' to stop."

debug-off:
	-git config --unset lfs.customtransfer.lfs-dal.args
	-git config --unset lfs.customtransfer.lfs-dal.concurrent

# ---------------------------------------------------------------------------
# Clean up
# ---------------------------------------------------------------------------

clean: clean-assets clean-roundtrip

clean-assets:
	rm -rf assets

clean-roundtrip:
	rm -rf .roundtrip

# Deletes real objects in the shared bucket, so it is guarded twice: you must say
# CONFIRM=yes, and the prefix must contain "lfs-test".
clean-s3:
	@$(NEED_BUCKET); \
	case "$(PREFIX)" in *lfs-test*) ;; *) echo "Refusing: prefix '$(PREFIX)' does not look like a test prefix."; exit 1 ;; esac; \
	[ "$(CONFIRM)" = "yes" ] || { echo "This deletes s3://$$bucket/$(PREFIX)/. Re-run with CONFIRM=yes."; exit 1; }; \
	aws --profile $(AWS_PROFILE) s3 rm "s3://$$bucket/$(PREFIX)/" --recursive
