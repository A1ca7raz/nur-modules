{ lib, config, pkgs, ... }:
let
  inherit (lib)
    foldlAttrs
    forEach
    mkOption
    optional
    optionals
    mkIf
    types
  ;

  cfg = config.utils.netns4macvlan;

  ip = "${pkgs.iproute2}/bin/ip";

  inherit (import ./types.nix) netnsType;
in {
  options.utils.netns4macvlan = mkOption {
    type = with types; attrsOf (submodule netnsType);
    default = {};
    description = "Configuration for netns with macvlan interfaces.";
  };

  config = mkIf (cfg != {}) {
    systemd.services = foldlAttrs (acc: name: val: {
      "netns-${name}" = {
        description = "Named network namespace for ${name}";
        documentation = [
          "https://github.com/systemd/systemd/issues/2741#issuecomment-336736214"
        ];
        requires = [ "network-online.target" ];
        after = [ "network-online.target" ];

        unitConfig.StopWhenUnneeded = true;

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
            # Create and attach netns to current service process
            (pkgs.writeShellScript "netns-attach-${name}" ''
              ${ip} netns attach ${name} $$
            '')

            "${ip} link set dev lo up"
          ] ++ optional config.networking.nftables.enable (
            # Load the nftables ruleset of this netns.
            pkgs.writeScript "nftables-ruleset" ''
              #!${pkgs.nftables}/bin/nft -f
              flush ruleset
              ${val.nftables}
            ''
          );

          ExecStop = [
            # Delete the macvlan interface from the default namespace
            "${ip} netns del ${name}"
          ];
        };
      };

      "netns-${name}-helper" = {
        description = "Helper service for netns ${name}";
        documentation = [
          "https://github.com/systemd/systemd/issues/2741#issuecomment-336736214"
        ];
        bindsTo = [ "netns-${name}.service" ];
        after = [ "netns-${name}.service" ];
        unitConfig.StopWhenUnneeded = true;

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = [
            # Move the macvlan interface to the netns
            "${ip} link set iv-${name} netns ${name}"
          ] ++ forEach val.macvlan.ipAddrs (ip_:
            "${ip} -n ${name} addr add ${ip_} dev iv-${name}"
          ) ++ [
            "${ip} -n ${name} link set dev iv-${name} up"
          ] ++ optionals val.macvlan.defaultRoute [
            "${ip} -n ${name} route add default via ${val.macvlan.gateway} dev iv-${name}"
          ];

          ExecStop = [
            "${ip} -n ${name} link set iv-${name} netns 1"
            "${ip} link set iv-${name} down"
          ];
        };
      };
    } // acc) {} cfg;

    systemd.network.netdevs = foldlAttrs (acc: name: val: {
      "ipvlan-${name}" = {
        netdevConfig = {
          Name = "iv-${name}";
          Kind = "ipvlan";
        };
      };
    } // acc) {} cfg;

    systemd.network.networks = foldlAttrs (acc: name: val: {
      "ipvlan-${name}" = {
        matchConfig.Name = "iv-${name}";
        networkConfig = {
          Address = val.macvlan.ipAddrs;
          Gateway = val.macvlan.gateway;
          IPMasquerade = val.macvlan.ipMasquerade;
          IPv4Forwarding = if val.macvlan.ipForward == "ipv4" || val.macvlan.ipForward == "both" then "yes" else "no";
          IPv6Forwarding = if val.macvlan.ipForward == "ipv6" || val.macvlan.ipForward == "both" then "yes" else "no";
        };
      };
    } // acc)
      (foldlAttrs
        (acc: name: val: {
          ${val.macvlan.parent}.ipvlan = if acc ? "${val.macvlan.parent}" then acc.${val.macvlan.parent} ++ [ "iv-${name}" ] else [ "iv-${name}" ];
        } // acc) {} cfg)
      cfg;
  };
}
