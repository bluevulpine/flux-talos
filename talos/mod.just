set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

scripts_dir := justfile_dir() + '/scripts'
talos_dir := justfile_dir() + '/talos'
controller := `talosctl config info -o yaml | yq -e '.endpoints[0]'`

[private]
default:
    just -l talos

[doc('Apply Talos config to a node')]
apply-node node *args:
    just talos render-config "{{ node }}" | talosctl -n "{{ node }}" apply-config -f /dev/stdin {{ args }}

[doc('Download Talos machine image')]
download-image version schematic:
    gum spin --title "Downloading Talos {{ version }} ..." -- \
    curl -sfL --remove-on-error --retry 5 --retry-delay 5 --retry-all-errors \
        -o "{{ talos_dir }}/talos-{{ version }}-{{ replace_regex(schematic, '^(.{8}).*', '$1') }}.iso" \
        "https://factory.talos.dev/image/{{ schematic }}/{{ version }}/metal-amd64.iso"
    just log info "Downloaded Talos" version "{{ version }}" schematic "{{ schematic }}"

[doc('Generate schematic ID from Talos schematic')]
gen-schematic-id:
    curl -sX POST --data-binary @<(just template "{{ talos_dir }}/schematic.yaml.j2") "https://factory.talos.dev/schematics" | jq -r '.id'

[doc('Reboot a node')]
reboot-node node:
    gum confirm "Reboot node {{ node }}?" --default="No" && \
        talosctl -n {{ node }} reboot -m powercycle || exit 0

[doc('Render Talos config for a node')]
render-config node:
    export IS_CONTROLLER="$(just talos machine-controller {{ node }})"; \
    talosctl machineconfig patch <(just template "{{ talos_dir }}/machineconfig.yaml.j2") \
        -p @<(just template "{{ talos_dir }}/nodes/{{ node }}.yaml.j2")

[doc('Reset a node')]
reset-node node:
    gum confirm "Reset node {{ node }}?" --default="No" && \
        talosctl -n "{{ node }}" reset --graceful=false || exit 0

[doc('Shutdown a node')]
shutdown-node node:
    gum confirm "Shutdown node {{ node }}?" --default="No" && \
        talosctl -n "{{ node }}" shutdown --force || exit 0

[doc('Upgrade Kubernetes version on the cluster')]
upgrade-k8s version:
    talosctl -n "{{ controller }}" upgrade-k8s --to {{ version }}

[doc('Upgrade Talos version on a node')]
upgrade-node node:
    talosctl -n "{{ node }}" upgrade -i "$(just talos machine-image)" -m powercycle --timeout=10m

# =============================================================================
# Cluster Rebuild Recipes
# =============================================================================

[doc('Generate new Talos secrets (DESTRUCTIVE - creates new secrets file)')]
gen-secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! gum confirm "This will GENERATE NEW TALOS SECRETS. The new file will be created as talsecret.sops.yaml.new for review. Continue?" --default="No"; then
        exit 0
    fi
    just log info "Generating new Talos secrets..."
    talhelper gensecret > "{{ talos_dir }}/talsecret.sops.yaml.new"
    just log info "New secrets generated at {{ talos_dir }}/talsecret.sops.yaml.new"
    just log warn "To use the new secrets:"
    just log warn "  1. Review the file: cat {{ talos_dir }}/talsecret.sops.yaml.new"
    just log warn "  2. Encrypt with SOPS: sops -e -i {{ talos_dir }}/talsecret.sops.yaml.new"
    just log warn "  3. Replace old secrets: mv {{ talos_dir }}/talsecret.sops.yaml.new {{ talos_dir }}/talsecret.sops.yaml"
    just log warn "  4. Regenerate configs: just talos gen-config"

[doc('Generate Talos machine configs from talconfig.yaml using talhelper')]
gen-config:
    just log info "Generating Talos machine configs with talhelper..."
    talhelper genconfig -c "{{ talos_dir }}/talconfig.yaml" -o "{{ talos_dir }}/clusterconfig"
    just log info "Machine configs generated in {{ talos_dir }}/clusterconfig/"

[doc('Apply generated config to a node (uses talhelper-generated configs)')]
apply-generated node *args:
    #!/usr/bin/env bash
    set -euo pipefail
    config_file="{{ talos_dir }}/clusterconfig/home-kubernetes-{{ node }}.yaml"
    if [[ ! -f "$config_file" ]]; then
        just log fatal "Config file not found: $config_file. Run 'just talos gen-config' first."
    fi
    just log info "Applying config to {{ node }}..."
    talosctl -n "{{ node }}" apply-config -f "$config_file" {{ args }}

[doc('Reset all nodes (DESTRUCTIVE - requires confirmation for each node)')]
reset-all:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! gum confirm "This will RESET ALL CLUSTER NODES. This is destructive and cannot be undone. Continue?" --default="No"; then
        exit 0
    fi
    nodes=$(talosctl config info -o yaml | yq -e '.nodes | .[]')
    for node in $nodes; do
        just talos reset-node "$node"
    done

[doc('Bootstrap cluster from scratch using talhelper-generated configs')]
bootstrap-cluster:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! gum confirm "This will BOOTSTRAP A NEW CLUSTER. Ensure all nodes are reset and configs are generated. Continue?" --default="No"; then
        exit 0
    fi

    just log info "Step 1: Applying Talos configs to all nodes..."
    nodes=$(talosctl config info -o yaml | yq -e '.nodes | .[]')
    for node in $nodes; do
        config_file="{{ talos_dir }}/clusterconfig/home-kubernetes-${node}.yaml"
        if [[ ! -f "$config_file" ]]; then
            just log fatal "Config file not found: $config_file. Run 'just talos gen-config' first."
        fi
        just log info "Applying config to $node..."
        talosctl -n "$node" apply-config -f "$config_file" --insecure || true
    done

    just log info "Step 2: Waiting for nodes to be ready..."
    sleep 30

    just log info "Step 3: Bootstrapping Kubernetes on first control plane..."
    controller=$(talosctl config info -o yaml | yq -e '.endpoints[0]')
    until talosctl -n "$controller" bootstrap 2>&1 | grep -q "AlreadyExists"; do
        just log info "Waiting for Kubernetes bootstrap to complete..."
        sleep 10
    done

    just log info "Step 4: Fetching kubeconfig..."
    talosctl kubeconfig -n "$controller" -f --force-context-name main "{{ justfile_dir() }}"

    just log info "Cluster bootstrap complete!"
    just log info "Next steps:"
    just log info "  1. Wait for nodes: kubectl get nodes --watch"
    just log info "  2. Bootstrap Flux: flux bootstrap github ..."

[doc('Full cluster rebuild workflow (DESTRUCTIVE)')]
rebuild:
    #!/usr/bin/env bash
    set -euo pipefail
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                    CLUSTER REBUILD WORKFLOW                       ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║ This will perform a FULL CLUSTER REBUILD with the following:     ║"
    echo "║   1. Generate new Talos secrets (optional)                        ║"
    echo "║   2. Generate machine configs                                     ║"
    echo "║   3. Reset all nodes                                              ║"
    echo "║   4. Bootstrap the cluster                                        ║"
    echo "║                                                                    ║"
    echo "║ ⚠️  THIS IS DESTRUCTIVE AND CANNOT BE UNDONE                      ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    if ! gum confirm "Do you want to proceed with the cluster rebuild?" --default="No"; then
        exit 0
    fi

    if gum confirm "Do you want to generate NEW secrets? (Required for security incident rotation)" --default="No"; then
        just talos gen-secrets
        echo ""
        if ! gum confirm "Have you encrypted and moved the new secrets file? (See instructions above)" --default="No"; then
            just log fatal "Please complete the secrets rotation before continuing."
        fi
    fi

    just log info "Generating machine configs..."
    just talos gen-config

    just log info "Resetting all nodes..."
    just talos reset-all

    just log info "Waiting 60 seconds for nodes to reset..."
    sleep 60

    just log info "Bootstrapping cluster..."
    just talos bootstrap-cluster

[private]
machine-controller node:
    just template "{{ talos_dir }}/nodes/{{ node }}.yaml.j2" | yq -e 'select(.machine) | (.machine.type == "controlplane") // ""'

[private]
machine-image:
    just template "{{ talos_dir }}/machineconfig.yaml.j2" | yq -e 'select(.machine) | .machine.install.image'
