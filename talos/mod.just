set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']

scripts_dir := justfile_dir() + '/scripts'
talos_dir := justfile_dir() + '/talos'
# First control-plane node, read from topf.yaml so the module loads with no talosconfig present.
controller := shell('yq -e "$1" "$2"', '[.nodes[] | select(.role == "control-plane")][0].ip', talos_dir + '/topf.yaml')

[private]
default:
    just -l talos

[doc('Download Talos machine image')]
download-image version schematic:
    gum spin --title "Downloading Talos {{ version }} ..." -- \
    curl -sfL --remove-on-error --retry 5 --retry-delay 5 --retry-all-errors \
        -o "{{ talos_dir }}/talos-{{ version }}-{{ replace_regex(schematic, '^(.{8}).*', '$1') }}.iso" \
        "https://factory.talos.dev/image/{{ schematic }}/{{ version }}/metal-amd64.iso"
    just log info "Downloaded Talos" version "{{ version }}" schematic "{{ schematic }}"

[doc('Reboot a node')]
reboot-node node:
    gum confirm "Reboot node {{ node }}?" --default="No" && \
        talosctl -n {{ node }} reboot -m powercycle || exit 0

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

[doc('Upgrade Talos on a node by hostname, using the installer image topf renders for it')]
upgrade-node node:
    #!/usr/bin/env bash
    set -euo pipefail
    ip=$(NODE="{{ node }}" yq -e '.nodes[] | select(.host == strenv(NODE)) | .ip' "{{ talos_dir }}/topf.yaml")
    # The rendered config holds the cluster PKI in plaintext: private dir, always removed.
    tmp=$(mktemp -d)
    chmod 700 "$tmp"
    trap 'rm -rf "$tmp"' EXIT
    (cd "{{ talos_dir }}" && topf --nodes-filter "^{{ node }}\$" render -o "$tmp" >/dev/null)
    image=$(yq -e '.machine.install.image' "$tmp/{{ node }}.yaml")
    just log info "Upgrading {{ node }} ($ip) to $image"
    talosctl -n "$ip" upgrade -i "$image" -m powercycle --timeout=10m

# =============================================================================
# Cluster Rebuild Recipes
# =============================================================================

[doc('Generate a new Talos PKI bundle into secrets.sops.yaml (DESTRUCTIVE - every node must be rebuilt)')]
gen-secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! gum confirm "This will GENERATE A NEW TALOS PKI and overwrite talos/secrets.sops.yaml. Continue?" --default="No"; then
        exit 0
    fi
    # talos/secrets.yaml is gitignored and is topf's default plaintext path; it never outlives this recipe.
    plain="{{ talos_dir }}/secrets.yaml"
    trap 'rm -f "$plain" "{{ talos_dir }}/secrets.sops.yaml.new"' EXIT
    talosctl gen secrets -o "$plain" --force
    sops --filename-override "{{ talos_dir }}/secrets.sops.yaml" --input-type yaml --output-type yaml -e "$plain" > "{{ talos_dir }}/secrets.sops.yaml.new"
    mv "{{ talos_dir }}/secrets.sops.yaml.new" "{{ talos_dir }}/secrets.sops.yaml"
    just log info "New PKI written to {{ talos_dir }}/secrets.sops.yaml"
    # The old talosconfig holds an admin cert signed by the OLD CA; every talosctl call would fail mTLS.
    # Redirect only: it contains the admin cert and key.
    (umask 077 && cd "{{ talos_dir }}" && topf talosconfig > talosconfig.new && mv talosconfig.new talosconfig)
    just log info "Regenerated talos/talosconfig against the new PKI"
    just log warn "Existing nodes still hold the OLD PKI; rebuild them (just talos rebuild) before applying."
    just log warn "Never run 'topf secrets': it can print or mint plaintext PKI."

[doc('Apply the topf config to one node by hostname (verify mTLS first: talosctl -n <ip> version)')]
apply-node node *args:
    cd "{{ talos_dir }}" && topf --nodes-filter "^{{ node }}\$" apply {{ args }}

[doc('Apply the topf config to every node in talos/topf.yaml')]
apply-all *args:
    cd "{{ talos_dir }}" && topf apply {{ args }}

[doc('Reset all nodes (DESTRUCTIVE - requires confirmation for each node)')]
reset-all:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! gum confirm "This will RESET ALL CLUSTER NODES. This is destructive and cannot be undone. Continue?" --default="No"; then
        exit 0
    fi
    # topf.yaml is the node inventory; reset workers before control-plane nodes.
    nodes=$(yq -e '(.nodes[] | select(.role != "control-plane") | .ip), (.nodes[] | select(.role == "control-plane") | .ip)' "{{ talos_dir }}/topf.yaml")
    for node in $nodes; do
        just talos reset-node "$node"
    done

[doc('Bootstrap cluster from scratch using topf. Fails fast: one unreachable node aborts the apply step (the old flow skipped it)')]
bootstrap-cluster:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! gum confirm "This will BOOTSTRAP A NEW CLUSTER. Ensure all nodes are reset. Continue?" --default="No"; then
        exit 0
    fi

    just log info "Step 1: Applying Talos configs to all nodes..."
    just talos apply-all

    just log info "Step 2: Waiting for nodes to be ready..."
    sleep 30

    just log info "Step 3: Bootstrapping Kubernetes on first control plane..."
    controller="{{ controller }}"
    # Succeeds once etcd bootstraps (exit 0) or already has (AlreadyExists); any other error is retried up to 30 times.
    for attempt in $(seq 1 30); do
        if out=$(talosctl -n "$controller" bootstrap 2>&1) || [[ "$out" == *AlreadyExists* ]]; then
            break
        fi
        if [[ "$attempt" -eq 30 ]]; then
            just log fatal "Kubernetes bootstrap did not succeed after 30 attempts" "last_error" "$out"
        fi
        just log info "Waiting for Kubernetes bootstrap to complete..." "attempt" "$attempt"
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
    echo "║   2. Reset all nodes                                              ║"
    echo "║   3. Bootstrap the cluster                                        ║"
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
        if ! gum confirm "Is the new secrets.sops.yaml committed or otherwise safe? (Nodes are about to be reset)" --default="No"; then
            just log fatal "Please complete the secrets rotation before continuing."
        fi
    fi

    just log info "Resetting all nodes..."
    just talos reset-all

    just log info "Waiting 60 seconds for nodes to reset..."
    sleep 60

    just log info "Bootstrapping cluster..."
    just talos bootstrap-cluster
