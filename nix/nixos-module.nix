# The other half of "run this workload as a container": a declarative
# systemd-nspawn NixOS container you drop into an existing NixOS config.
#
#   imports = [ inputs.coldstart.nixosModules.default ];
#   coldstart.containers.zomboid = {
#     execStart = "${pkgs.zomboid-server}/bin/zomboid-server";
#     openFirewall = true;
#     ports.udp = [ 16261 16262 ];
#   };
#
# This is NOT the OCI image running under podman. It is a NixOS system inside
# an nspawn namespace, which is what `containers.<name>` in NixOS means — the
# workload is a systemd service in a full (if tiny) NixOS, so it gets the
# host's Nix store by bind mount rather than a copied one, and there is no
# image to build or push at all. The Kubernetes path and this path deliberately
# share only the workload package.
#
# Networking defaults to the host's namespace, which is the only configuration
# where a UDP game-server port is reachable without forwarding rules. Set
# `privateNetwork = true` for isolation, and the module wires `forwardPorts`
# from `ports` so the declared ports keep working.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.coldstart;

  containerOpts = lib.types.submodule (
    { name, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to define this container. Set false to keep the declaration but stop running it.";
        };

        execStart = lib.mkOption {
          type = lib.types.str;
          example = lib.literalExpression ''"''${pkgs.my-server}/bin/my-server"'';
          description = ''
            The command the container's service runs. An absolute store path —
            the container's PATH is not the host's, so a bare binary name only
            resolves if `packages` puts it there.
          '';
        };

        packages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "Packages placed on the container's system PATH.";
        };

        user = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Unprivileged account inside the container that the service runs as.";
        };

        group = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Primary group of `user`.";
        };

        stateDir = lib.mkOption {
          type = lib.types.path;
          default = "/var/lib/${name}";
          defaultText = lib.literalExpression ''"/var/lib/''${name}"'';
          description = ''
            Where the workload's state lives INSIDE the container, and the
            service's working directory. Also the mount point for
            `hostStateDir`.
          '';
        };

        hostStateDir = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = "/srv/zomboid";
          description = ''
            Host directory bind-mounted at `stateDir`. Null keeps the state
            inside the container's own root, which an `ephemeral` container
            discards on every stop — so a stateful workload wants this set.
          '';
        };

        environment = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = "Environment for the service.";
        };

        ports = {
          tcp = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [ ];
            description = "TCP ports the workload listens on.";
          };
          udp = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [ ];
            description = "UDP ports the workload listens on.";
          };
        };

        openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Open `ports` in the HOST's firewall. Off by default because opening
            a port is a decision about the machine, not about the workload.
          '';
        };

        privateNetwork = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Give the container its own network namespace. The declared `ports`
            are then forwarded from the host, so the workload stays reachable —
            but the source address every connection appears to come from is the
            host, which some game-server browsers and ban systems care about.
          '';
        };

        hostAddress = lib.mkOption {
          type = lib.types.str;
          default = "192.168.100.1";
          description = "Host side of the veth pair. Only used when `privateNetwork` is set.";
        };

        localAddress = lib.mkOption {
          type = lib.types.str;
          default = "192.168.100.2";
          description = "Container side of the veth pair. Only used when `privateNetwork` is set.";
        };

        autoStart = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Start the container at boot.";
        };

        ephemeral = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Discard the container's root filesystem on stop. On by default: with
            `hostStateDir` carrying everything worth keeping, a persistent root
            is just accumulated drift that no longer matches the declaration.
            Turn it off only when the workload writes state outside `stateDir`.
          '';
        };

        serviceConfig = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          description = "Merged over the generated systemd `serviceConfig`.";
        };

        extraContainerConfig = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          description = "Merged over the generated `containers.<name>` attrset.";
        };

        extraConfig = lib.mkOption {
          type = lib.types.deferredModule;
          default = { };
          description = "Extra NixOS configuration evaluated INSIDE the container.";
        };

        stateVersion = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          defaultText = lib.literalExpression "the host's system.stateVersion";
          description = ''
            `system.stateVersion` for the container's own NixOS. Null inherits
            the host's, which is what keeps a container from silently sitting on
            a different stateVersion than the machine it runs on.
          '';
        };
      };
    }
  );

  enabled = lib.filterAttrs (_: c: c.enable) cfg.containers;

  allPorts = c: c.ports.tcp ++ c.ports.udp;

  mkContainer =
    name: c:
    {
      inherit (c) autoStart ephemeral privateNetwork;
    }
    // lib.optionalAttrs c.privateNetwork {
      inherit (c) hostAddress localAddress;
      # Without this every declared port is unreachable the moment the
      # container gets its own namespace — which is the failure mode that makes
      # `privateNetwork` look broken rather than isolating.
      forwardPorts =
        map (p: {
          containerPort = p;
          hostPort = p;
          protocol = "tcp";
        }) c.ports.tcp
        ++ map (p: {
          containerPort = p;
          hostPort = p;
          protocol = "udp";
        }) c.ports.udp;
    }
    // lib.optionalAttrs (c.hostStateDir != null) {
      bindMounts.${c.stateDir} = {
        hostPath = toString c.hostStateDir;
        isReadOnly = false;
      };
    }
    // {
      config =
        { ... }:
        {
          imports = [ c.extraConfig ];

          system.stateVersion = if c.stateVersion != null then c.stateVersion else config.system.stateVersion;
          environment.systemPackages = c.packages;

          users.users.${c.user} = {
            isSystemUser = true;
            group = c.group;
            home = c.stateDir;
          };
          users.groups.${c.group} = { };

          # The container's own firewall, distinct from the host's. With a
          # shared namespace this is a no-op — the host's rules are the only
          # ones in play — but with `privateNetwork` it is what lets the
          # forwarded packets actually arrive.
          networking.firewall = {
            enable = true;
            allowedTCPPorts = c.ports.tcp;
            allowedUDPPorts = c.ports.udp;
          };

          systemd.services.${name} = {
            description = "${name} (coldstart container)";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            environment = c.environment;

            serviceConfig = {
              # `exec` rather than `simple`: systemd then reports a start
              # failure when the binary cannot be executed at all, instead of
              # reporting success and leaving the failure in the journal.
              Type = "exec";
              User = c.user;
              Group = c.group;
              WorkingDirectory = c.stateDir;
              ExecStart = c.execStart;
              Restart = "on-failure";
              RestartSec = 10;

              # StateDirectory would put it under /var/lib and fight the bind
              # mount, so the directory is made directly instead.
              RuntimeDirectory = name;
            }
            // c.serviceConfig;
          };

          systemd.tmpfiles.rules = [
            "d ${c.stateDir} 0750 ${c.user} ${c.group} - -"
          ];
        };
    }
    // c.extraContainerConfig;
in
{
  options.coldstart.containers = lib.mkOption {
    type = lib.types.attrsOf containerOpts;
    default = { };
    description = ''
      Workloads to run as declarative systemd-nspawn NixOS containers on this
      host. Each entry becomes a `containers.<name>`.
    '';
  };

  config = lib.mkIf (enabled != { }) {
    containers = lib.mapAttrs mkContainer enabled;

    # The host firewall, opened only for the containers that asked for it.
    networking.firewall = {
      allowedTCPPorts = lib.concatMap (c: lib.optionals c.openFirewall c.ports.tcp) (
        lib.attrValues enabled
      );
      allowedUDPPorts = lib.concatMap (c: lib.optionals c.openFirewall c.ports.udp) (
        lib.attrValues enabled
      );
    };

    # A bind mount whose host path does not exist makes the container fail to
    # start with a message about the MOUNT, not about the missing directory.
    systemd.tmpfiles.rules = lib.concatMap (
      c: lib.optional (c.hostStateDir != null) "d ${toString c.hostStateDir} 0750 root root - -"
    ) (lib.attrValues enabled);

    assertions = lib.concatLists (
      lib.mapAttrsToList (name: c: [
        {
          assertion = c.execStart != "";
          message = "coldstart.containers.${name}.execStart is empty — the container has nothing to run.";
        }
        {
          assertion = !c.privateNetwork || allPorts c != [ ];
          message = "coldstart.containers.${name} sets privateNetwork with no ports — nothing outside the container could reach it.";
        }
        {
          assertion = c.openFirewall -> allPorts c != [ ];
          message = "coldstart.containers.${name} sets openFirewall with no ports declared.";
        }
      ]) enabled
    );
  };
}
