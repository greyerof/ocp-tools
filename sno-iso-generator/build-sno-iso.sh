#!/bin/bash
#
# Creates ISO image for a SNO cluster.
# Inputs:
#   OCP_VERSION: env var with desired version, e.g. OCP_VERSION=4.13.4
#   CLUSTER_NAME: (optional) cluster name. If not set, will be defaulted to greyerof-$OCP_VERSION
#   LOCAL_YQ: (optional) value won't be read. It just tells the script to use the locally installed
#             tool yq. This will avoid downloading the docker container.
#

# Set exit on error
set -o errexit

if [ -z "${OCP_VERSION}" ]; then
  echo "Env var OCP_VERSION was not set."
  exit 1
fi

ocp_version_str=$(echo "$OCP_VERSION" | tr "." -)
base_domain=cnfcertlab.org

export CLUSTER_NAME=${CLUSTER_NAME:-"greyerof-${ocp_version_str}"}

ARCH=${ARCH:-x86_64}


ocp_folder="ocp_${CLUSTER_NAME}"
if [ -d $ocp_folder ] ; then
  echo "Folder $ocp_folder already exists. Please remove/rename it."
  exit 1
fi

mkdir $ocp_folder

echo "Preparing iso for OCP version ${OCP_VERSION}, cluster name ${CLUSTER_NAME} in folder ${ocp_folder}."

# Change (sequentially) the fields .baseDoman and .metadata.name using env vars (internal) $base_domain and (external) $CLUSTER_NAME
if [ -z "${LOCAL_YQ}" ]; then
  cat install-config.yaml | podman run -i --rm docker.io/mikefarah/yq ".baseDomain = \"$base_domain\"" \
                          | podman run -i --rm docker.io/mikefarah/yq ".metadata.name = \"${CLUSTER_NAME}\"" > $ocp_folder/install-config.yaml
else
  cat install-config.yaml | yq --yaml-output ".baseDomain = \"$base_domain\"" \
                          | yq --yaml-output ".metadata.name = \"${CLUSTER_NAME}\"" > $ocp_folder/install-config.yaml
fi

pushd $ocp_folder
  curl -k https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OCP_VERSION/openshift-client-linux.tar.gz -o oc.tar.gz
  tar zxf oc.tar.gz
  chmod +x oc

  curl -k https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OCP_VERSION/openshift-install-linux.tar.gz -o openshift-install-linux.tar.gz
  tar zxvf openshift-install-linux.tar.gz
  chmod +x openshift-install

  ISO_URL=$(./openshift-install coreos print-stream-json | grep location | grep $ARCH | grep iso | cut -d\" -f4)
  curl -L $ISO_URL -o rhcos-live.iso

  mkdir ocp
  cp install-config.yaml ocp

  ./openshift-install --dir=ocp create single-node-ignition-config

  ls -la ocp/

  coreos_installer="podman run --privileged --pull always --rm -v /dev:/dev -v /run/udev:/run/udev -v ${PWD}:/data -w /data quay.io/coreos/coreos-installer:release"
  ${coreos_installer} iso ignition embed -fi ocp/bootstrap-in-place-for-live-iso.ign rhcos-live.iso

  mv rhcos-live.iso rhcos-live-ocp-${OCP_VERSION}.iso

  subdomains="api api-int console-openshift-console.apps oauth-openshift.apps canary-openshift-ingress-canary.apps"

  entry="10.0.2.15 ${CLUSTER_NAME}.$base_domain"
  for subdomain in $subdomains; do
    entry+=" $subdomain.${CLUSTER_NAME}.$base_domain"
  done
  echo $entry
popd

echo "Openshift $OCP_VERSION files created:"
echo "  ISO        : ${PWD}/$ocp_folder/rhcos-live-ocp-${OCP_VERSION}.iso"
echo "  kubeconfig : ${PWD}/$ocp_folder/ocp/auth/kubeconfig"

