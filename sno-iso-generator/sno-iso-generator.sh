#!/bin/bash
#
# Creates ISO image for a SNO (Single Node Openshift) clusters. Downloads the corresponding
# "oc" and "openshift-install" tools from RH's official site and automates the steps in the
# OCP installation guides for SNO clusters, like:
# https://docs.openshift.com/container-platform/4.14/installing/installing_sno/install-sno-preparing-to-install-sno.html
#
# All the cluster names will use the domain "cnfcertlab.org" by default. Change the variable "base_domain" if a different
# domain is needed. The install-config.yaml should exist in the current folder.
#  final cluster name: <$CLUSTER_NAME>.$base_domain
#  final node name   : master0.<$CLUSTER_NAME>.$base_domain
#
# Examples:
#  1. Create 4.14.3 ISO file. Output folder will be "ocp_greyerof-4-14-3"
#    $ OCP_VERSION=4.14.3 ./sno-iso-generator.sh
#  2. Create 4.15.1 ISO file. Output folder "ocp_mysnocluster". Use locally installed "yq" program.
#    $ OCP_VERSION=4.15.1 CLUSTER_NAME=mysnocluster LOCAL_YQ=1 ./sno-iso-generator.sh
#
# Preconditions:
# - The file install-config.yaml must be exist in the current folder and the fields "pullSecret" and "sshKey" must be
#   pre-populated with the user's RH pull secrets and its own ssh public key. The pulic key will be added to the sno
#   server so it can be accessed through the "core" user for debugging.
#
# Dependencies:
# - install-config.yaml: pullSecret and sshKey fields must be pre-populated.
# - yq: by default, it will try to (pull &) use the docker container docker.io/mikefarah/yq,
#      but can use a local yq program if LOCAL_YQ=1 is exported.
#
# Inputs:
# - OCP_VERSION: env var with desired version, e.g. OCP_VERSION=4.13.4
# - PULL_SECRET: path to openshift pull secret file
# - SSH_PUB_KEY: path to public ssh key
# - CLUSTER_NAME: (optional) cluster name. If not set, will be defaulted to greyerof-$OCP_VERSION
# - LOCAL_YQ: (optional) value won't be read. It just tells the script to use the locally installed
#             tool yq. This will avoid downloading the docker container.
#
# Outputs: the script will create a separate folder with all the artifacts needed to build
#          the SNO ISO file. Folder name is ocp_${CLUSTER_NAME}. It will also show the location
#          of both the kubeconfig file and the kubeadmin credentials for the (web) console.
#

base_domain=cnfcertlab.org

# Exit on error
set -o errexit

if [ -z "${OCP_VERSION}" ]; then
  echo "Env var OCP_VERSION was not set."
  exit 1
fi

if [ -z "${PULL_SECRET}" ]; then
  echo "Env var PULL_SECRET was not set. Please set it to your pull secret file path."
  exit 1
fi

if [ -z "${SSH_PUB_KEY}" ]; then
  echo "Env var SSH_PUB_KEY was not set. Please set it to your ssh public key path."
  exit 1
fi

oc_link="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OCP_VERSION/openshift-client-linux.tar.gz"
ocp_install_link="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OCP_VERSION/openshift-install-linux.tar.gz"

ocp_version_str=$(echo "$OCP_VERSION" | tr "." -)

export CLUSTER_NAME=${CLUSTER_NAME:-"greyerof-${ocp_version_str}"}

ARCH=${ARCH:-x86_64}

ocp_folder="ocp_${CLUSTER_NAME}"
if [ -d $ocp_folder ] ; then
  echo "Folder $ocp_folder already exists. Please remove/rename it."
  exit 1
fi

echo "Creating output folder $ocp_folder"
mkdir $ocp_folder

echo "Preparing iso for OCP version ${OCP_VERSION}, cluster name ${CLUSTER_NAME} in folder ${ocp_folder}."
echo "Pull secret path: $PULL_SECRET"
echo "SSH pub key path: $SSH_PUB_KEY"
# read pull secret and ssh public key files
pullSecret="$(cat $PULL_SECRET)"
sshKey=$(cat $SSH_PUB_KEY)

echo "Updating .baseDomain, .metadata.name, .pullSecret and .sshKey from install-config.yaml file..."

# Change (sequentially) the fields .baseDoman and .metadata.name using env vars (internal) $base_domain and (external) $CLUSTER_NAME
if [ -z "${LOCAL_YQ}" ]; then
  echo "Using yq from docker container docker.io/mikefarah/yq"

  cat install-config.yaml | podman run -i --rm docker.io/mikefarah/yq ".baseDomain = \"$base_domain\""          \
                          | podman run -i --rm docker.io/mikefarah/yq ".metadata.name = \"$CLUSTER_NAME\""      \
                          | podman run -i --rm docker.io/mikefarah/yq ".pullSecret = ( $pullSecret | tojson )"  \
                          | podman run -i --rm docker.io/mikefarah/yq ".sshKey = \"$sshKey\"" > $ocp_folder/install-config.yaml
else
  echo "Using local yq program from $(which yq)"
  cat install-config.yaml | yq --yaml-output ".baseDomain = \"$base_domain\""         \
                          | yq --yaml-output ".metadata.name = \"$CLUSTER_NAME\""     \
                          | yq --yaml-output ".pullSecret = ( $pullSecret | tojson )" \
                          | yq --yaml-output ".sshKey = \"$sshKey\"" > $ocp_folder/install-config.yaml
fi

pushd $ocp_folder
  echo "Downloading oc client from $oc_link"
  curl -k $oc_link -o oc.tar.gz

  tar zxf oc.tar.gz
  chmod +x oc

  echo "Downloading openshift-install tool from $ocp_install_link".
  curl -k $ocp_install_link -o openshift-install-linux.tar.gz

  tar zxvf openshift-install-linux.tar.gz
  chmod +x openshift-install

  ISO_URL=$(./openshift-install coreos print-stream-json | grep location | grep $ARCH | grep iso | cut -d\" -f4)

  echo "Downloading template ISO from $ISO_URL"
  curl -L $ISO_URL -o rhcos-live.iso

  mkdir ocp
  cp install-config.yaml ocp

  echo "Creating ignition config"
  ./openshift-install --dir=ocp create single-node-ignition-config

  echo "Creating final ISO image"
  coreos_installer="podman run --privileged --pull always --rm -v /dev:/dev -v /run/udev:/run/udev -v ${PWD}:/data -w /data quay.io/coreos/coreos-installer:release"
  ${coreos_installer} iso ignition embed -fi ocp/bootstrap-in-place-for-live-iso.ign rhcos-live.iso

  mv rhcos-live.iso rhcos-live-ocp-${OCP_VERSION}.iso

  # List the DNS entries to place in /etc/hosts if no DNSmasq entries were set.
  dns_entries="${CLUSTER_NAME}.$base_domain"
  subdomains="api api-int console-openshift-console.apps oauth-openshift.apps canary-openshift-ingress-canary.apps"
  for subdomain in $subdomains; do
    dns_entries+=" $subdomain.${CLUSTER_NAME}.$base_domain"
  done
  echo "List of DNS entries for /etc/hosts (not needed if a DNS server was pre-configured): "
  echo $dns_entries
popd

echo "Openshift $OCP_VERSION files created:"
echo "  ISO        : ${PWD}/$ocp_folder/rhcos-live-ocp-${OCP_VERSION}.iso"
echo "  kubeconfig : ${PWD}/$ocp_folder/ocp/auth/kubeconfig"
