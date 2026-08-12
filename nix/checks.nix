# Tests. All offline: `helm template` needs no cluster, and every assertion runs
# against the rendered YAML with yq rather than grep — the templates carry long
# comments that survive into the output, so a grep for `hostPort` matches a
# comment about host ports whether or not the field is there.
{ inputs }:
{ pkgs, lib }:
let
  chart = ../chart;
  exampleValues = ../examples/values-example.yaml;

  # What the image adds on top of nixpkgs. Imported directly rather than
  # reached for inside a built image: the shim is only meaningfully tested
  # by RUNNING it, and building an image to do that would pull the whole
  # workload closure into every `nix flake check`.
  shims = import ./image-shims.nix { inherit pkgs; };

  # `nix flake check` does not look at `flake.lib`, `flake.flakeModules` or
  # `flake.nixosModules` ("The following flake outputs are unchecked"), so
  # the consumer-facing half of this repo is only covered by the checks
  # that use these.
  coldstart = import ./lib.nix { inherit lib; };

  # The smallest values that render at all. Everything else is a default,
  # which is the point: a chart whose defaults do not render is a chart
  # nobody can adopt incrementally.
  minimalArgs = [
    "--set"
    "image.repository=ghcr.io/OWNER/app"
  ];

  # Renders the chart, then runs the given assertions with $manifests bound
  # to the rendered file.
  mkRenderCheck =
    {
      name,
      helmArgs ? [ ],
      values ? [ ],
      script,
    }:
    pkgs.runCommand name
      {
        nativeBuildInputs = [
          pkgs.kubernetes-helm
          pkgs.yq-go
        ];
      }
      ''
        export HELM_CACHE_HOME="$TMPDIR/cache" HELM_CONFIG_HOME="$TMPDIR/config" HELM_DATA_HOME="$TMPDIR/data"
        manifests="$TMPDIR/manifests.yaml"
        helm template test ${chart} --namespace games \
          ${lib.concatMapStringsSep " " (v: "--values ${v}") values} \
          ${lib.escapeShellArgs helmArgs} > "$manifests"

        fail() { echo "FAIL: $*" >&2; exit 1; }
        # Every assertion below is `expected actual message`.
        eq() { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; }

        workload() { yq 'select(.kind == "Deployment" or .kind == "StatefulSet")' "$manifests"; }
        container() { workload | yq '.spec.template.spec.containers[0]'; }
        kinds() { yq -N '.kind' "$manifests" | sort -u; }

        ${script}

        touch $out
      '';
in
{
  # The devenv module, evaluated the way a devenv project evaluates it: bare
  # `lib.evalModules` with the arguments devenv supplies, plus a stub `outputs`
  # option standing in for devenv's own. Without this the module is published
  # and never exercised, and an option added to image-options.nix could stop
  # reaching it without anything saying so.
  devenv-module =
    let
      evaluated = lib.evalModules {
        specialArgs = { inherit pkgs lib; };
        modules = [
          { options.outputs = lib.mkOption { type = lib.types.attrsOf lib.types.package; }; }
          (import ./devenv-module.nix)
          {
            coldstart.images.probe = {
              name = "probe";
              withNix = false;
              entrypoint = [ "/bin/sh" ];
            };
          }
        ];
      };
    in
    pkgs.runCommand "devenv-module" { } ''
      case ${lib.escapeShellArg evaluated.config.outputs.probe.name} in
        probe*) ;;
        *) echo "the devenv module produced an unexpected image name" >&2; exit 1 ;;
      esac
      touch $out
    '';

  # helm's own schema/template validation, and proof the example values
  # documented in the README actually render.
  chart-lint =
    pkgs.runCommand "chart-lint"
      {
        nativeBuildInputs = [ pkgs.kubernetes-helm ];
      }
      ''
        export HELM_CACHE_HOME="$TMPDIR/cache" HELM_CONFIG_HOME="$TMPDIR/config" HELM_DATA_HOME="$TMPDIR/data"
        helm lint ${chart} --values ${exampleValues}
        touch $out
      '';

  # The chart must refuse to render something that cannot work, rather
  # than emit a Deployment with an empty image name or a set of replicas
  # that will deadlock on one volume.
  chart-rejects-incomplete-values =
    pkgs.runCommand "chart-rejects-incomplete-values"
      {
        nativeBuildInputs = [ pkgs.kubernetes-helm ];
      }
      ''
        export HELM_CACHE_HOME="$TMPDIR/cache" HELM_CONFIG_HOME="$TMPDIR/config" HELM_DATA_HOME="$TMPDIR/data"

        rejects() {
          msg="$1"; shift
          if helm template test ${chart} --namespace games "$@" > /dev/null 2>&1; then
            echo "FAIL: $msg" >&2
            exit 1
          fi
        }

        rejects "chart rendered with no image.repository"
        rejects "chart rendered with an unknown kind" \
          ${lib.escapeShellArgs minimalArgs} --set kind=DaemonSet
        # A Deployment cannot scale past one replica on a ReadWriteOnce
        # claim; every replica but one sits Pending on Multi-Attach.
        rejects "chart rendered a multi-replica Deployment with persistence" \
          ${lib.escapeShellArgs minimalArgs} --set replicas=3 --set persistence.enabled=true
        rejects "chart rendered a Service with no ports" \
          ${lib.escapeShellArgs minimalArgs} --set service.enabled=true
        rejects "chart rendered a OnePasswordItem with no itemPath" \
          ${lib.escapeShellArgs minimalArgs} --set onePasswordItems[0].name=secrets

        touch $out
      '';

  # The defaults have to produce a pod that could actually start, with
  # nothing enabled that was not asked for. Every `false` default here is
  # a decision the values file argues for at length.
  chart-render-defaults = mkRenderCheck {
    name = "chart-render-defaults";
    helmArgs = minimalArgs;
    script = ''
      eq "Deployment" "$(kinds)" "the defaults render a Deployment and nothing else"

      eq "ghcr.io/OWNER/app:latest" "$(container | yq '.image')" \
        "image comes from values"
      eq "Recreate" "$(workload | yq '.spec.strategy.type')" \
        "Recreate, so a ReadWriteOnce volume is never contended during a rollout"

      # An image built by mkImage declares its own entrypoint, so the
      # chart must not invent one.
      eq "null" "$(container | yq '.command')" "no command is imposed by default"
      eq "null" "$(container | yq '.args')" "no args are imposed by default"

      eq 1000 "$(workload | yq '.spec.template.spec.securityContext.runAsUser')" \
        "the workload runs unprivileged"
      # fsGroup breaks every nix unpack phase. See values.yaml.
      eq "null" "$(workload | yq '.spec.template.spec.securityContext.fsGroup')" \
        "no fsGroup is ever set by default"

      # The Nix store copy is a CI concern, not a general one: a workload
      # that only runs needs nothing but the image's read-only /nix.
      eq "null" "$(workload | yq '.spec.template.spec.initContainers')" \
        "no initContainers when neither the store nor a volume is enabled"
      eq "tmp" "$(workload | yq -N '.spec.template.spec.volumes[].name' | tr '\n' ' ' | sed 's/ $//')" \
        "only /tmp is mounted by default"
    '';
  };

  # The example the README leads with. Rendering it is what keeps the
  # documented values from drifting away from the chart.
  chart-render-example = mkRenderCheck {
    name = "chart-render-example";
    values = [ exampleValues ];
    script = ''
                  eq "Deployment
      OnePasswordItem
      PersistentVolumeClaim" "$(kinds)" "the example renders its volume and its secret"

                  eq "16261" "$(container | yq '.ports[] | select(.name == "game") | .containerPort')" \
                    "declared ports reach the container"
                  eq "UDP" "$(container | yq '.ports[] | select(.name == "game") | .protocol')" \
                    "the protocol is carried through — a UDP server published as TCP is silently unreachable"
                  eq "16261" "$(container | yq '.ports[] | select(.name == "game") | .hostPort')" \
                    "hostPort.enabled binds the port on the node"

                  # No Service: the example binds host ports instead, and a
                  # Service rendered anyway would be a second, conflicting
                  # answer to how traffic arrives.
                  eq "" "$(yq 'select(.kind == "Service") | .metadata.name' "$manifests")" \
                    "no Service unless asked for"

                  eq "20Gi" "$(yq 'select(.kind == "PersistentVolumeClaim") | .spec.resources.requests.storage' "$manifests")" \
                    "the claim is sized from values"
                  eq "keep" "$(yq 'select(.kind == "PersistentVolumeClaim") | .metadata.annotations["helm.sh/resource-policy"]' "$manifests")" \
                    "the save volume outlives the release"

                  # A freshly provisioned PVC is root-owned, and the
                  # workload is not root.
                  eq "chown-data" "$(workload | yq '.spec.template.spec.initContainers[0].name')" \
                    "the data volume is handed to the workload's uid"
                  eq 0 "$(workload | yq '.spec.template.spec.initContainers[0].securityContext.runAsUser')" \
                    "the chown runs as root, or it cannot chown"

                  eq 120 "$(workload | yq '.spec.template.spec.terminationGracePeriodSeconds')" \
                    "the grace period comes from values — a SIGKILL mid-save corrupts the world"

                  eq "my-server-secrets" "$(yq 'select(.kind == "OnePasswordItem") | .metadata.name' "$manifests")" \
                    "the 1Password item creates the Secret env references"
    '';
  };

  # The CI-runner shape: a writable store seeded from the image.
  chart-render-nix-store = mkRenderCheck {
    name = "chart-render-nix-store";
    helmArgs = minimalArgs ++ [
      "--set"
      "nixStore.enabled=true"
      "--set"
      "nss.enabled=true"
    ];
    script = ''
                  eq "seed-nix-store chown-nix-store" \
                    "$(workload | yq -N '.spec.template.spec.initContainers[].name' | tr '\n' ' ' | sed 's/ $//')" \
                    "both store initContainers, in order — the copy must precede the chown"

                  # Root copied them; fsGroup would only touch the volume
                  # root, not the modes cp created underneath.
                  eq "chown -R 1000:1000 /mnt/nix && chmod g-s /mnt/nix" \
                    "$(workload | yq '.spec.template.spec.initContainers[1].args[1]')" \
                    "store ownership handed to the workload user"

                  eq "15Gi" "$(workload | yq '.spec.template.spec.volumes[] | select(.name == "nix-store") | .emptyDir.sizeLimit')" \
                    "store size limit comes from values"

                  eq "/nix" "$(container | yq '.volumeMounts[] | select(.name == "nix-store") | .mountPath')" \
                    "the workload sees the seeded store at /nix, over the image's own"

                  eq "ConfigMap
      Deployment" "$(kinds)" "nss.enabled adds the passwd/group ConfigMap"
                  eq 2 "$(container | yq '[.volumeMounts[] | select(.name == "nss")] | length')" \
                    "/etc/passwd and /etc/group are both mounted"
    '';
  };

  # A StatefulSet exists here for exactly one reason: per-replica volumes.
  # If it rendered the same shared claim a Deployment does, choosing it
  # would buy nothing.
  chart-render-statefulset = mkRenderCheck {
    name = "chart-render-statefulset";
    helmArgs = minimalArgs ++ [
      "--set"
      "kind=StatefulSet"
      "--set"
      "replicas=3"
      "--set"
      "persistence.enabled=true"
      "--set"
      "service.enabled=true"
      "--set"
      "service.type=NodePort"
      "--set"
      "service.externalTrafficPolicy=Local"
      "--set"
      "ports[0].name=game"
      "--set"
      "ports[0].containerPort=16261"
      "--set"
      "ports[0].protocol=UDP"
    ];
    script = ''
                  eq "Service
      StatefulSet" "$(kinds)" "a StatefulSet and its Service"

                  eq "data" "$(workload | yq '.spec.volumeClaimTemplates[0].metadata.name')" \
                    "storage is a volumeClaimTemplate, not one shared claim"
                  # A `select` that matches nothing yields no output at
                  # all, which is why this compares against "" and not
                  # "null" — the latter is what an absent FIELD renders as.
                  eq "" "$(workload | yq '.spec.template.spec.volumes[] | select(.name == "data")')" \
                    "no shared data volume alongside the template"
                  eq "test-coldstart" "$(workload | yq '.spec.serviceName')" \
                    "a StatefulSet needs its governing Service by name"

                  eq "Local" "$(yq 'select(.kind == "Service") | .spec.externalTrafficPolicy' "$manifests")" \
                    "source addresses are preserved when asked for"
                  eq "UDP" "$(yq 'select(.kind == "Service") | .spec.ports[0].protocol' "$manifests")" \
                    "the Service publishes UDP, not the default TCP"
    '';
  };

  # externalTrafficPolicy is only valid on NodePort/LoadBalancer; the API
  # server rejects a ClusterIP Service carrying it. Rendering it anyway
  # would produce YAML that passes every offline check and fails on apply.
  chart-clusterip-drops-traffic-policy = mkRenderCheck {
    name = "chart-clusterip-drops-traffic-policy";
    helmArgs = minimalArgs ++ [
      "--set"
      "service.enabled=true"
      "--set"
      "service.externalTrafficPolicy=Local"
      "--set"
      "ports[0].name=api"
      "--set"
      "ports[0].containerPort=8080"
    ];
    script = ''
      eq "null" "$(yq 'select(.kind == "Service") | .spec.externalTrafficPolicy' "$manifests")" \
        "a ClusterIP Service must not carry externalTrafficPolicy"
    '';
  };

  # The kernel resolves a shebang's interpreter path literally, so the
  # only thing that proves the image's /usr/bin/env works is EXEC'ing a
  # script through it. `test -e` would pass for a dangling symlink and
  # `test -x` for a directory, and a present-but-unusable path is exactly
  # the failure this guards:
  #
  #   /usr/bin/env: bad interpreter: No such file or directory
  usr-bin-env-runs-scripts =
    pkgs.runCommand "usr-bin-env-runs-scripts"
      {
        nativeBuildInputs = [ pkgs.bashInteractive ];
      }
      ''
        fail() { echo "FAIL: $*" >&2; exit 1; }

        # Written the way a vendor's own launcher is written — an
        # interpreter NAME, which only /usr/bin/env can turn into a path.
        printf '%s\n' \
          '#!${shims.usrBinEnv}/usr/bin/env bash' \
          'echo "interpreter-resolved-from-PATH"' > portable
        chmod +x portable

        ran=$(./portable) || fail "a #!…/usr/bin/env bash script could not exec"
        [ "$ran" = "interpreter-resolved-from-PATH" ] \
          || fail "the script ran under something unexpected (got '$ran')"

        touch $out
      '';

  # A vendored binary's own OpenSSL reads a compiled-in path, not
  # $SSL_CERT_FILE, so the bundle has to exist under the conventional
  # names. `pkgs.cacert` ships only ca-bundle.crt.
  #
  # Existence alone is not the test: `test -e` passes for a link to a
  # directory and `test -s` for a truncated file, and either would leave
  # TLS with no roots. So each path is RESOLVED and then PARSED — a
  # dangling symlink fails the grep, a truncated bundle fails the count,
  # and anything that is not PEM fails openssl.
  ca-certificates-compat =
    pkgs.runCommand "ca-certificates-compat"
      {
        nativeBuildInputs = [ pkgs.openssl ];
      }
      ''
        fail() { echo "FAIL: $*" >&2; exit 1; }
        root=${shims.caCertCompat}

        for p in \
          etc/ssl/certs/ca-certificates.crt \
          etc/ssl/cert.pem \
          etc/pki/tls/certs/ca-bundle.crt
        do
          # -e follows symlinks, so a dangling link is caught here rather
          # than by a TLS handshake months later.
          [ -e "$root/$p" ] || fail "$p is missing or dangling"

          n=$(grep -c 'BEGIN CERTIFICATE' "$root/$p" || true)
          [ "$n" -gt 50 ] || fail "$p holds $n certificates, so it is not the full bundle"

          openssl x509 -in "$root/$p" -noout -subject > /dev/null 2>&1 \
            || fail "$p is not parseable as PEM"
        done

        touch $out
      '';

}
# Evaluating the image is the test: it proves the derivation and every
# option path is well-formed, without pulling a workload closure into a
# check. `nix build .#example-image` in CI is what proves it builds.
// lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  image-evaluates =
    let
      mkImage = args: import ./image.nix args;
      variants = [
        (mkImage { inherit pkgs; })
        (mkImage {
          inherit pkgs;
          name = "custom";
          packages = [ pkgs.hello ];
          withNix = false;
          withCacert = false;
          withSkopeo = true;
          basePackages = [ ];
          extraPackages = [ pkgs.yq-go ];
          entrypoint = [ "/bin/hello" ];
          exposedPorts."16261/udp" = { };
          workingDir = "/srv";
          extraConfig.StopSignal = "SIGINT";
          env.TMPDIR = null;
          user = {
            uid = 1234;
            gid = 1234;
            home = "/home/app";
          };
          labels."org.opencontainers.image.source" = "https://github.com/OWNER/REPO";
        })
      ];
    in
    pkgs.runCommand "image-evaluates" { } ''
      ${lib.concatMapStringsSep "\n" (
        d: "echo ${lib.escapeShellArg (builtins.unsafeDiscardStringContext d.drvPath)}"
      ) variants}
      touch $out
    '';

  # The nspawn half. A NixOS module is only as good as the system it
  # produces, and nothing above evaluates it — so build a real
  # nixosSystem with two containers and assert on the result. A
  # mis-typed option or a bad `containers.<name>` attribute fails this
  # derivation's instantiation, which is the point.
  nixos-module =
    let
      system = inputs.nixpkgs-project.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          coldstart.nixosModules.default
          (
            { ... }:
            {
              boot.loader.grub.enable = false;
              fileSystems."/".device = "/dev/null";
              system.stateVersion = "24.05";

              coldstart.containers = {
                shared = {
                  execStart = "/bin/true";
                  hostStateDir = "/srv/shared";
                  openFirewall = true;
                  ports.udp = [ 16261 ];
                };
                isolated = {
                  execStart = "/bin/true";
                  privateNetwork = true;
                  ports.tcp = [ 8080 ];
                  # Deliberately NOT opened on the host, to prove
                  # openFirewall is per-container rather than global.
                  openFirewall = false;
                };
                off = {
                  enable = false;
                  execStart = "/bin/true";
                };
              };
            }
          )
        ];
      };
      cfg = system.config;
      containers = cfg.containers;
      json = pkgs.writeText "nixos-module.json" (
        builtins.toJSON {
          names = builtins.attrNames containers;
          hostTcp = cfg.networking.firewall.allowedTCPPorts;
          hostUdp = cfg.networking.firewall.allowedUDPPorts;
          sharedBind = containers.shared.bindMounts."/var/lib/shared".hostPath;
          sharedPrivateNetwork = containers.shared.privateNetwork;
          isolatedForwards = containers.isolated.forwardPorts;
          # The container's own NixOS, not the host's.
          innerUdp = containers.shared.config.networking.firewall.allowedUDPPorts;
          innerExecStart = containers.shared.config.systemd.services.shared.serviceConfig.ExecStart;
          innerUser = containers.shared.config.systemd.services.shared.serviceConfig.User;
          innerStateVersion = containers.shared.config.system.stateVersion;
        }
      );
    in
    pkgs.runCommand "nixos-module"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        fail() { echo "FAIL: $*" >&2; exit 1; }
        eq() { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; }
        get() { jq -r "$1" ${json}; }

        # `enable = false` must not leave a container behind.
        eq "isolated shared" "$(get '.names | sort | join(" ")')" \
          "a disabled container is not defined"

        # Ports are opened on the host only for the container that asked.
        eq "16261" "$(get '.hostUdp | join(" ")')" "openFirewall opens the declared UDP port"
        eq "" "$(get '.hostTcp | join(" ")')" \
          "a container with openFirewall=false must not open its port on the host"

        eq "/srv/shared" "$(get '.sharedBind')" "hostStateDir is bind-mounted at stateDir"
        eq "false" "$(get '.sharedPrivateNetwork')" \
          "the default shares the host namespace, or a UDP port is unreachable without forwarding"

        # privateNetwork without forwarding is an unreachable container,
        # which is the failure that makes the option look broken.
        eq "8080" "$(get '.isolatedForwards[0].hostPort')" "privateNetwork forwards the declared ports"
        eq "tcp" "$(get '.isolatedForwards[0].protocol')" "the forward carries the protocol"

        eq "16261" "$(get '.innerUdp | join(" ")')" "the container's own firewall opens the port too"
        eq "/bin/true" "$(get '.innerExecStart')" "execStart reaches the service"
        eq "shared" "$(get '.innerUser')" "the service runs as the unprivileged user, not root"
        eq "24.05" "$(get '.innerStateVersion')" \
          "the container inherits the host's stateVersion rather than pinning its own"

        touch $out
      '';
}
