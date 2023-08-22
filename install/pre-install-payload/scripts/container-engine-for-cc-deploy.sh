#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

die() {
	msg="$*"
	echo "ERROR: $msg" >&2
	exit 1
}

function host_systemctl() {
	nsenter --target 1 --mount systemctl "${@}"
}

function get_container_engine() {
	local containerRuntimeVersion=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')
	local container_engine=$(echo "${containerRuntimeVersion}" | awk -F '[:]' '{print $1}')
	local container_engine_version=$(echo "${containerRuntimeVersion}" | awk -F '[:]' '{print $2}')

	if [[ "${container_engine_version}" ~= "1.7" ]]; then
		# containerd will not be replaced as the minimum
		# version installed in the node is good enough
		# for CoCo.
		INSTALL_CONTAINERD="false"
	fi

	if [ "${INSTALL_CONTAINERD}" = "true" ]; then
		if [ "${container_engine}" != "containerd" ]; then
			die "${container_engine} is not yet supported"
		fi
	fi

	echo "$container_engine"	
}

function set_container_engine() {
	# Those are intentionally not set as local

	container_engine=$(get_container_engine)
}

function install_containerd_artifacts() {
	echo "Copying containerd-for-cc artifacts onto host"

	local artifacts_dir="/opt/confidential-containers-pre-install-artifacts"

	install -D -m 755 ${artifacts_dir}/opt/confidential-containers/bin/containerd /opt/confidential-containers/bin/containerd
	install -D -m 644 ${artifacts_dir}/etc/systemd/system/containerd.service.d/containerd-for-cc-override.conf /etc/systemd/system/containerd.service.d/containerd-for-cc-override.conf
}

function uninstall_containerd_artifacts() {
	echo "Removing containerd-for-cc artifacts from host"

	echo "Removing the systemd drop-in file"
	rm -f /etc/systemd/system/${container_engine}.service.d/${container_engine}-for-cc-override.conf
	echo "Removing the systemd drop-in file's directory, if empty"
	[ -d /etc/systemd/system/${container_engine}.service.d ] && rmdir --ignore-fail-on-non-empty /etc/systemd/system/${container_engine}.service.d
	
	restart_systemd_service

	echo "Removing the containerd binary"
	rm -f /opt/confidential-containers/bin/containerd
	echo "Removing the /opt/confidential-containers directory"
	[ -d /opt/confidential-containers/bin ] && rmdir --ignore-fail-on-non-empty -p /opt/confidential-containers/bin
	[ -d /opt/confidential-containers ] && rmdir --ignore-fail-on-non-empty -p /opt/confidential-containers
}

function restart_systemd_service() {
	host_systemctl daemon-reload
	echo "Restarting ${container_engine}"
	host_systemctl restart "${container_engine}"
}

label_node() {
	case "${1}" in
	install)
		kubectl label node "${NODE_NAME}" cc-preinstall/done=true
		;;
	uninstall)
		kubectl label node "${NODE_NAME}" cc-postuninstall/done=true
		;;
	*)
		;;
	esac
}

function print_help() {
	echo "Help: ${0} [install/uninstall]"
}

function main() {
	echo "INSTALL_CONTAINERD: ${INSTALL_CONTAINERD}"

	# script requires that user is root
	local euid=$(id -u)
	if [ ${euid} -ne 0 ]; then
		die "This script must be run as root"
	fi

	local action=${1:-}
	if [ -z "${action}" ]; then
		print_help && die ""
	fi

	set_container_engine

	case "${action}" in
	install)
		if [ "${INSTALL_CONTAINERD}" = "true" ]; then
			install_containerd_artifacts
		fi
		restart_systemd_service
		;;
	uninstall)
		# Adjustment for s390x (clefos:7)
		# It is identified that a node is not labeled during post-uninstall,
		# if the function is called after container engine is restarted by systemctl.
		# This results in having the uninstallation not triggered.
		if [ "$(uname -m)" = "s390x" ]; then
			label_node "${action}"
		fi
		if [ "${INSTALL_CONTAINERD}" = "true" ]; then
			uninstall_containerd_artifacts
		fi
		;;
	*)
		print_help
		;;
	esac

	label_node "${action}"


	# It is assumed this script will be called as a daemonset. As a result, do
	# not return, otherwise the daemon will restart and reexecute the script.
	sleep infinity
}

main "$@"
