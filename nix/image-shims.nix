# The things the image has to supply itself, because nothing upstream does.
#
# Both are absences rather than misconfigurations, so neither shows up when the
# image is built, or inspected, or started — only when the workload happens to
# need them. Both cost a full deploy round-trip to find.
#
# Kept out of image.nix so `checks.nix` can exercise them directly: proving
# either one works means RUNNING it, and building a whole image to do that
# would pull the workload's entire closure into `nix flake check`.
{ pkgs }:
let
  inherit (pkgs) lib;
in
{
  # `#!/usr/bin/env <interp>` is the dominant portable shebang, and the kernel
  # resolves that path literally — no PATH search, no fallback, no error the
  # script itself can handle. Nix patches its own shebangs to absolute store
  # paths, so nothing in the base image needs /usr/bin/env and its absence stays
  # invisible until the first script Nix did not patch tries to run:
  #
  #   /usr/bin/env: bad interpreter: No such file or directory
  #
  # Game servers and other prebuilt vendor payloads are full of such scripts —
  # they ship their own launcher and Nix never touches it.
  #
  # A symlink to the `env` already in the image, so this adds no closure.
  usrBinEnv = pkgs.runCommand "usr-bin-env" { } ''
    mkdir -p $out/usr/bin
    ln -s ${lib.getExe' pkgs.coreutils-full "env"} $out/usr/bin/env
  '';

  # skopeo refuses to do anything without a trust policy, and nixpkgs ships no
  # default one ("no policy.json file found"). Accept any image: a container
  # that pushes images only ever pushes ones it just built itself.
  containersPolicy = pkgs.writeTextDir "etc/containers/policy.json" (
    builtins.toJSON {
      default = [ { type = "insecureAcceptAnything"; } ];
    }
  );

  # The CA bundle under the names the rest of the world compiled into its
  # binaries.
  #
  # `pkgs.cacert` ships exactly one bundle, at
  # /etc/ssl/certs/ca-bundle.crt, and Nix-built software finds it because
  # $SSL_CERT_FILE points there. A VENDORED binary does not read that variable:
  # it links its own OpenSSL, which falls back to the path it was compiled
  # with — /etc/ssl/certs/ca-certificates.crt on Debian and most builds,
  # /etc/pki/tls/certs/ca-bundle.crt on RHEL, /etc/ssl/cert.pem for stock
  # OpenSSL. None of those exist in a from-scratch Nix image.
  #
  # So TLS silently has no roots, and the failure surfaces nowhere near the
  # cause — Steam's client, for one, logs
  #
  #   opensslconnection.cpp (1636) : unable to load trusted SSL root certificates
  #
  # and then simply never reaches its master servers, while the process itself
  # keeps running and looks healthy.
  #
  # Symlinks to the bundle already in the image, so this adds no closure.
  caCertCompat = pkgs.runCommand "ca-cert-compat" { } ''
    mkdir -p $out/etc/ssl/certs $out/etc/pki/tls/certs
    bundle=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt

    ln -s "$bundle" $out/etc/ssl/certs/ca-certificates.crt
    ln -s "$bundle" $out/etc/ssl/cert.pem
    ln -s "$bundle" $out/etc/pki/tls/certs/ca-bundle.crt
  '';
}
