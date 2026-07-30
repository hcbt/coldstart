# coldstart

Run a Nix-built workload as a container, two ways:

- **Kubernetes** — an OCI image built by Nix, and a Helm chart that runs it.
- **An existing NixOS host** — a declarative `systemd-nspawn` container, no
  image and no registry involved.

The two paths share the workload package and nothing else. That is deliberate:
an nspawn container gets the host's Nix store by bind mount, so building and
pushing an image for it would be pure ceremony.

```nix
{
  inputs.coldstart.url = "github:hcbt/coldstart";

  # …

  imports = [ inputs.coldstart.flakeModules.default ];

  perSystem = { pkgs, ... }: {
    coldstart.images.my-server = {
      packages = [ pkgs.my-server ];
      entrypoint = [ "/bin/my-server" ];
      withNix = false;
    };
  };
}
```

`nix build .#my-server` produces a `docker-archive` ready to push.

## What the image adds on top of `dockerTools`

Everything here is something a from-scratch Nix image is **missing** rather
than something it gets wrong. Each absence is invisible at build time, invisible
on inspection, invisible at startup — and costs a full deploy round-trip to find.

| | Why |
| --- | --- |
| `/usr/bin/env` | The kernel resolves a shebang's interpreter path literally. Nix patches its own shebangs to store paths, so the absence stays hidden until the first script Nix did not touch tries to run — which is every vendor launcher ever shipped. |
| `/etc/passwd` entry | Nix resolves the current user through `getpwuid`, not `$HOME`. With no entry for the pod's uid, every nix command fails with `cannot determine user's home directory`, and setting `HOME` does not help. |
| Registered Nix DB | Without it the store paths are present but unregistered, and every nix command fails. `includeNixDB` costs reproducibility (`db.sqlite` embeds timestamps) and is usually worth it. |
| A container-shaped `nix.conf` | The container is already the isolation boundary, and there are no build users inside it to hand a sandboxed build to. |
| TLS roots | There is no `/etc/ssl` at all otherwise, and failures surface as opaque certificate errors. |
| skopeo trust policy | skopeo refuses to do anything without one (`no policy.json file found`), and nixpkgs ships no default. Only with `withSkopeo`. |

`withNix = false` drops Nix and its ~200M of closure — right for a workload
that only ever *runs*, wrong for anything calling `nix build` itself.

## The chart

Points a GitOps controller straight at `chart/`, or renders to plain YAML:

```nix
coldstart.lib.renderChart {
  inherit pkgs;
  releaseName = "my-server";
  namespace = "games";
  values = { image.repository = "ghcr.io/OWNER/my-server"; };
}
```

Every option is documented inline in [`chart/values.yaml`](chart/values.yaml).
The ones worth knowing before you start:

- **`nixStore.enabled` is off by default.** An image built by `mkImage` already
  carries its whole closure at `/nix`, read-only, which is all a workload needs
  in order to run. Turn it on only for a container that builds derivations of
  its own — it seeds a *writable* store from the image with two initContainers.
- **`persistence` is a real PVC**, because unlike the Nix store it is not
  re-derivable. It is chowned to the workload's uid by an initContainer, since
  a fresh PVC arrives root-owned and the workload is not root.
- **No `fsGroup`, ever, by default.** It marks the volume root setgid, every
  directory created beneath inherits it, and nix's own seccomp filter then
  denies the `chmod` that `unpackPhase` performs — so every derivation with an
  unpack phase fails with a message that looks nothing like a permissions
  problem. `chart/values.yaml` has the long version.
- **`strategy: Recreate`.** A rolling update starts the new pod before the old
  one is gone, and two pods cannot hold one ReadWriteOnce volume.
- **`hostPort` beats a Service for single-node UDP.** A NodePort Service
  rewrites the client's source address unless `externalTrafficPolicy: Local`,
  and game-server browsers and ban systems care about that address.

The chart refuses to render what cannot work: no image repository, an unknown
`kind`, a multi-replica Deployment sharing one ReadWriteOnce claim, a Service
with no ports, a 1Password item with no path.

## The NixOS container

For a host that already runs NixOS, where an image buys nothing:

```nix
imports = [ inputs.coldstart.nixosModules.default ];

coldstart.containers.my-server = {
  execStart = "${pkgs.my-server}/bin/my-server";
  hostStateDir = "/srv/my-server";
  openFirewall = true;
  ports.udp = [ 16261 16262 ];
};
```

Each entry becomes a `containers.<name>` running the workload as an
unprivileged systemd service inside its own NixOS.

- Networking **shares the host namespace by default**, which is the only
  configuration where a UDP port is reachable with no forwarding rules.
  `privateNetwork = true` isolates it and the module wires `forwardPorts` from
  the declared ports — at the cost of every connection appearing to come from
  the host.
- `ephemeral` is **on**: with `hostStateDir` carrying everything worth keeping,
  a persistent container root is just drift that no longer matches the
  declaration.
- `openFirewall` is **off**. Opening a port is a decision about the machine, not
  about the workload.

## Publishing an image

A reusable workflow, for the repository that defines the image:

```yaml
jobs:
  image:
    permissions:
      contents: read
      packages: write
    uses: hcbt/coldstart/.github/workflows/build-push-image.yml@master
    with:
      package: my-server-image
      image: ghcr.io/${{ github.repository_owner }}/my-server
    secrets:
      registry-password: ${{ secrets.GITHUB_TOKEN }}
```

Pushed with skopeo — no daemon, and Nix already produced a `docker-archive`.

Keep the `latest` tag. Reproducible images are all stamped at epoch 0, so any
"newest build" tag ordering sees them as equally old and never picks a winner;
tracking the digest of one mutable tag is the strategy that works
(argocd-image-updater's `updateStrategy: digest`).

## Consumers

- [snowplow](https://github.com/hcbt/snowplow) — self-hosted GitHub Actions
  runners.
- [nixzoid](https://github.com/hcbt/nixzoid) — a Project Zomboid dedicated
  server.

## Development

```
nix develop
nix flake check
nix fmt
```

New files must be `git add`ed before any `nix` command sees them.
