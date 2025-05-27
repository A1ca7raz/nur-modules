{ config, lib, pkgs, ... }:
let
  inherit (lib)
    mkEnableOption
    mkIf
    concatStrings
    mapAttrsToList
    optionalString
    optional
  ;

  cfg = config.utils.netns;

  ip = "${pkgs.iproute2}/bin/ip";

  # Register the netns with a binding mount to /var/run/netns/$name to keep it alive,
  # and make sure resolv.conf can be used in BindReadOnlyPaths=
  # For propagating changes in that file to the services bind mounting it,
  # updating must not remove the file, but only truncate it.
  netnsAttach = pkgs.writeShellScript "netns-attach" ''
    ${ip} netns attach $1 $$
    mkdir -p /etc/netns/$1
    touch /etc/netns/$1/resolv.conf || true
  '';
in {
  options.utils.netns = {
    enable = mkEnableOption "enable netns management";
  };

  # https://github.com/NixOS/nixpkgs/blob/098ea34ea7427dc279b9f926ea6d4c537a27fcfb/nixos/modules/services/networking/netns.nix
  config = mkIf cfg.enable {
    systemd.services."netns@" = {
      description = "Named network namespace %I";
      documentation = [
        "https://github.com/systemd/systemd/issues/2741#issuecomment-336736214"
      ];
      requires = [ "network-online.target" ];
      after = [ "network-online.target" ];

      unitConfig = {
        StopWhenUnneeded = true;
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Let systemd create the netns so that PrivateNetwork=true
        # with JoinsNamespaceOf="netns-${name}.service" works.
        PrivateNetwork = true;
        # PrivateNetwork=true implies PrivateMounts=true by default,
        # which would prevent the persisting and sharing of /var/run/netns/$name
        # causing `ip netns exec $name $SHELL` outside of this service to fail with:
        # Error: Peer netns reference is invalid.
        # As `stat -f -c %T /var/run/netns/$name` would not be "nsfs" in those mntns.
        # See https://serverfault.com/questions/961504/cannot-create-nested-network-namespace
        PrivateMounts = false;

        ExecStart = [
          ''${netnsAttach} "%i"''

          # Bringing the loopback interface is almost always a good thing.
          "${ip} link set dev lo up"

          # Use --ignore because some keys may no longer exist in that new namespace,
          # like net.ipv6.conf.eth0.addr_gen_mode or net.core.rmem_max
          ''
            ${pkgs.procps}/bin/sysctl --ignore -p ${
              pkgs.writeScript "sysctl" (
                concatStrings (
                  mapAttrsToList (
                    n: v: optionalString (v != null) "${n}=${if v == false then "0" else toString v}\n"
                  ) config.boot.kernel.sysctl
                )
              )
            }
          ''
        ] ++
        # Load the nftables ruleset of this netns.
        optional config.networking.nftables.enable (
          pkgs.writeScript "nftables-ruleset" ''
            #!${pkgs.nftables}/bin/nft -f
            flush ruleset
            ${config.networking.nftables.ruleset}
          ''
        );

        ExecStop = "${ip} netns del %i";
      };
    };
  };
}
