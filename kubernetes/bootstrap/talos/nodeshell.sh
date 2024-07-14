#!/bin/bash

if [ $# -ne 1 ]; then
    echo "Usage: $0 <node>"
    exit 1
fi

NODE=$1
POD_NAME="ubuntu-shell-$(date +%s)"
CONTAINER_NAME="ubuntu-shell"

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

# Exec into the shell of the Pod
kubectl exec -it $POD_NAME --container $CONTAINER_NAME -- /bin/bash

# Cleanup: Delete the Pod after exiting
kubectl delete pod $POD_NAME
