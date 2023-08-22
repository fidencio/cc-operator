CONTAINERD_VERSION = 1.7.0

BASH = bash

containerd: containerd-container-image

containerd-container-image:
	containerd_version=$(CONTAINERD_VERSION) $(BASH) -x containerd/payload.sh
