
# Build container image for gcloud/gsutil from inside a container with buildah

SDK_ARCH = x86_64
SDK_VERS = 267.0.0
SDK_URL = https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-$(SDK_VERS)-linux-$(SDK_ARCH).tar.gz
SDK_DEST_DIR = /opt/google-cloud-sdk
PIPEFAIL = set -eo pipefail &&
BUILDAH = $(PIPEFAIL) buildah
BUILDAH_RUN = $(BUILDAH) run
GCLOUD_CTR = $(shell cat ._gcloudctr)
GSUTIL_CTR = $(shell cat ._gsutilctr)
GCLOUD_IMG = $(shell cat ._gcloudimg)
GSUTIL_IMG = $(shell cat ._gsutilimg)
INSTALLROOT = --installroot="$(MNT)"
IMG_BASE_NAME = $(shell source /etc/os-release && echo $$ID)
IMG_BASE_TAG = $(shell source /etc/os-release && echo $$VERSION_ID)
# The INPUT_ prefix added by github action
INPUT_ARTIFACTS_DIRPATH ?= $(abspath $(CURDIR))

# Cleanup helper: If the file $(1) exists, execute buildah command $(2)
# with the contents of $(1) as an argument, then remove $(1), ignoring
# errors for all commands.
define buildah_cmd_rm
	-test -r "$(1)" && $(BUILDAH) $(2) "$$(<$(1))"
	-rm -f "$(1)"
endef

# Execution state helper: Create/Update the file $(1) with stdout
# of command $(2), unless unsuccessful then remove $(1) and exit non-zero
define run
	-rm -f "$(1)"
	$(2) | tee "$(1)" || rm -f "$(1)"
	test -r "$(1)"
endef

# Given string $(1) convert it to upper-case
override upcase = $(shell echo "$(1)" | tr a-z A-Z)

.PHONY: all
all: gcloud gsutil

.PHONY: gcloud
gcloud: $(INPUT_ARTIFACTS_DIRPATH)/gcloud.tar

.PHONY: gsutil
gcloud: $(INPUT_ARTIFACTS_DIRPATH)/gsutil.tar

# Must be used as a sub-make since no actual guard-foo file ever exists
.PHONY: guard-%
guard-%:
	$(if $($*),,$(error Required variable $* is undefined or empty))

._gcloudctr:
	# Destroy any pre-existing "old" image
	$(call buildah_cmd_rm,._gcloudimg,rmi -f)
	# Destroy any pre-existing "old" state
	$(call buildah_cmd_rm,._gcloudctr,rm)
	$(MAKE) guard-BUILDAH guard-IMG_BASE_NAME guard-IMG_BASE_TAG
	$(call run,$@,$(BUILDAH) from $(IMG_BASE_NAME):$(IMG_BASE_TAG))

._gsutilctr: ._gcloudimg
	# Destroy any pre-existing "old" image
	$(call buildah_cmd_rm,._gsutilimg,rmi -f)
	# Destroy any pre-existing "old" state
	$(call buildah_cmd_rm,._gsutilctr,rm)
	$(MAKE) guard-BUILDAH guard-GCLOUD_IMG
	$(call run,$@,$(BUILDAH) from $(GCLOUD_IMG))

google-cloud-sdk:
	$(MAKE) guard-PIPEFAIL guard-SDK_URL
	$(PIPEFAIL) curl -L $(SDK_URL) | tar zxf - $@

# dot-underscore filename makes for more specific wild-card cleanup
._upd: ._gcloudctr
	$(MAKE) guard-GCLOUD_CTR guard-BUILDAH_RUN
	$(call run,$@,$(BUILDAH_RUN) $(GCLOUD_CTR) dnf update -y)

._pkg: ._upd
	$(MAKE) guard-GCLOUD_CTR guard-BUILDAH_RUN
	$(call run,$@,$(BUILDAH_RUN) $(GCLOUD_CTR) dnf install -y python2)

._cpy: ._gcloudctr google-cloud-sdk
	$(MAKE) guard-GCLOUD_CTR guard-BUILDAH guard-SDK_DEST_DIR
	$(call run,$@,$(BUILDAH) copy $(GCLOUD_CTR) "$(CURDIR)/google-cloud-sdk" $(SDK_DEST_DIR))

._ins: ._cpy
	$(MAKE) guard-GCLOUD_CTR guard-BUILDAH_RUN guard-SDK_DEST_DIR
	$(call run,$@,$(BUILDAH_RUN) $(GCLOUD_CTR) $(SDK_DEST_DIR)/install.sh \
					--usage-reporting false \
					--rc-path /etc/environment \
					--quiet)

._cln: ._ins ._pkg ._upd
	$(MAKE) guard-GCLOUD_CTR guard-BUILDAH_RUN
	$(BUILDAH_RUN) $(GCLOUD_CTR) dnf clean all
	$(call run,$@,$(BUILDAH_RUN) $(GCLOUD_CTR) bash -c 'rm -rvf /var/cache/dnf /tmp/* /tmp/.??*')

._gcloudimg: ._gcloudctr ._upd ._pkg ._cpy ._ins ._cln
	# Destroy any pre-existing "old" image
	$(call buildah_cmd_rm,._gcloudimg,rmi -f)
	$(MAKE) guard-BUILDAH guard-SDK_DEST_DIR guard-GCLOUD_CTR
	$(BUILDAH) config --entrypoint $(SDK_DEST_DIR)/bin/gcloud $(GCLOUD_CTR)
	$(call run,$@,$(BUILDAH) commit $(GCLOUD_CTR) gcloud)

._gsutilimg: ._gsutilctr
	# Destroy any pre-existing "old" image
	$(call buildah_cmd_rm,._gsutilimg,rmi -f)
	$(MAKE) guard-GSUTIL_CTR guard-BUILDAH guard-SDK_DEST_DIR
	$(BUILDAH) config --entrypoint $(SDK_DEST_DIR)/bin/gsutil $(GSUTIL_CTR)
	$(call run,$@,$(BUILDAH) commit $(GSUTIL_CTR) gsutil)

$(INPUT_ARTIFACTS_DIRPATH)/%.tar:
	$(MAKE) ._$(*)img
	$(MAKE) guard-INPUT_ARTIFACTS_DIRPATH guard-$(call upcase,$*)_IMG guard-BUILDAH
	$(BUILDAH) push $(*) docker-archive:$@

.PHONY: clean
clean:
	$(call buildah_cmd_rm,._gsutilimg,rmi -f)
	$(call buildah_cmd_rm,._GSUTIL_CTR,rm)
	$(call buildah_cmd_rm,._gcloudimg,rmi -f)
	$(call buildah_cmd_rm,._GCLOUD_CTR,rm)
	-rm -f ._???* $(INPUT_ARTIFACTS_DIRPATH)/*.tar

.PHONY: cleanall
cleanall: clean
	-$(BUILDAH) rm -a
	-rm -rf google-cloud-sdk
