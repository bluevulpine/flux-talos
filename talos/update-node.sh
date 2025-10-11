#!/bin/bash

if [ $# -ne 1 ]; then
    echo "Usage: $0 <node>"
    exit 1
fi

NODE=$1
POD_NAME="ubuntu-shell-$(date +%s)"
CONTAINER_NAME="ubuntu-shell"
DISK_IMAGE_URL="https://factory.talos.dev/image/f47e6cd2634c7a96988861031bcc4144468a1e3aef82cca4f5b5ca3fffef778a/v1.7.5/metal-arm64.raw.xz"

# Create the Pod manifest in a temporary file
cat <<EOF > /tmp/ubuntu-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
spec:
  nodeName: $NODE
  containers:
  - name: $CONTAINER_NAME
    image: ubuntu
    command: ["sleep", "infinity"]
    securityContext:
      privileged: true
EOF

# Create the Pod
kubectl create -f /tmp/ubuntu-pod.yaml

# Wait for the Pod to start
echo "Waiting for Pod '$POD_NAME' to start..."
kubectl wait --for=condition=Ready pod/$POD_NAME --timeout=30s

# Install pv and xz-utils in the Ubuntu container
kubectl exec -it $POD_NAME --container $CONTAINER_NAME -- apt-get update
kubectl exec -it $POD_NAME --container $CONTAINER_NAME -- apt-get install -y pv xz-utils curl

# Fetch the disk image, decompress it with xz, and write to /dev/sda with pv progress
echo "Fetching and writing disk image with progress..."
kubectl exec -it $POD_NAME --container $CONTAINER_NAME -- sh -c "curl -sSL $DISK_IMAGE_URL | xz -dc | pv | dd of=/dev/sda bs=4M"

# Cleanup: Delete the Pod after completing the operation
kubectl delete pod $POD_NAME
