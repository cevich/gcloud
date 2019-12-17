
# Build container image for gcloud/gsutil from inside a container with buildah

SDK_ARCH = x86_64
SDK_VERS = 267.0.0
SDK_URL = https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-$(SDK_VERS)-linux-$(SDK_ARCH).tar.gz
SDK_DEST_DIR = /opt/google-cloud-sdk
PIPEFAIL = set -eo pipefail &&
BUILDAH = $(PIPEFAIL) buildah
BUILDAH_RUN = $(BUILDAH) run
IMGNAME = gcloud
CTR = $(shell cat ._ctr)
IMG = $(shell cat ._img)
INSTALLROOT = --installroot="$(MNT)"
IMG_BASE_NAME = $(shell source /etc/os-release && echo $$ID)
IMG_BASE_TAG = $(shell source /etc/os-release && echo $$VERSION_ID)
ENTRY = $(SDK_DEST_DIR)/bin/gcloud

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

.PHONY: all
all: $(IMGNAME).tar

# Must be used as a sub-make since no actual guard-foo file ever exists
.PHONY: guard-%
guard-%:
	$(if $($*),,$(error Required variable $* is undefined or empty))

._ctr:
	$(MAKE) guard-BUILDAH guard-IMG_BASE_NAME guard-IMG_BASE_TAG
	$(call run,$@,$(BUILDAH) from $(IMG_BASE_NAME):$(IMG_BASE_TAG))

google-cloud-sdk:
	$(MAKE) guard-PIPEFAIL guard-SDK_URL
	$(PIPEFAIL) curl -L $(SDK_URL) | tar zxf - $@

# dot-underscore filename makes for more specific wild-card cleanup
._upd: ._ctr
	$(MAKE) guard-CTR guard-BUILDAH_RUN
	$(call run,$@,$(BUILDAH_RUN) $(CTR) dnf update -y)

._pkg: ._upd
	$(MAKE) guard-CTR guard-BUILDAH_RUN
	$(call run,$@,$(BUILDAH_RUN) $(CTR) dnf install -y python2)

._cpy: ._ctr google-cloud-sdk
	$(MAKE) guard-CTR guard-BUILDAH guard-SDK_DEST_DIR
	$(call run,$@,$(BUILDAH) copy $(CTR) "$(CURDIR)/google-cloud-sdk" $(SDK_DEST_DIR))

._ins: ._cpy
	$(MAKE) guard-CTR guard-BUILDAH_RUN guard-SDK_DEST_DIR
	$(call run,$@,$(BUILDAH_RUN) $(CTR) $(SDK_DEST_DIR)/install.sh \
					--usage-reporting false \
					--rc-path /etc/environment \
					--quiet)

._cln: ._ins ._pkg ._upd
	$(MAKE) guard-CTR guard-BUILDAH_RUN
	$(BUILDAH_RUN) $(CTR) dnf clean all
	$(call run,$@,$(BUILDAH_RUN) $(CTR) bash -c 'rm -rvf /var/cache/dnf /tmp/* /tmp/.??*')

._cfg: ._ins
	$(MAKE) guard-CTR guard-BUILDAH guard-ENTRY
	$(call run,$@,$(BUILDAH) config --entrypoint $(ENTRY) $(CTR))

._img: ._ctr ._upd ._pkg ._cpy ._ins ._cfg ._cln
	$(MAKE) guard-CTR guard-BUILDAH guard-IMGNAME
	$(call run,$@,$(BUILDAH) commit $(CTR) $(IMGNAME))

$(IMGNAME).tar: ._img
	$(MAKE) guard-IMG guard-BUILDAH
	$(BUILDAH) push $(IMG) docker-archive:$@

.PHONY: clean
clean:
	$(call buildah_cmd_rm,._img,rmi -f)
	$(call buildah_cmd_rm,._ctr,rm)
	-rm -f $(IMGNAME).tar ._???

.PHONY: cleanall
cleanall: clean
	-$(BUILDAH) rm -a
	-rm -rf google-cloud-sdk
