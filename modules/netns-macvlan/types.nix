rec{
  macvlanType = { lib, config, ... }:
    let
      inherit (lib)
        mkOption
        types
      ;
    in {
    options = {
      parent = mkOption {
        type = types.str;
        description = "Name of the parent interface to create the macvlan on.";
      };

      ipAddrs = mkOption {
        type = with types; coercedTo str (x: [x]) (listOf str);
        default = [];
        description = "List of IP addresses to assign to the macvlan interface.";
      };

      gateway = mkOption {
        type = with types; nullOr str;
        default = null;
        description = "Default gateway for the macvlan interface.";
      };

      ipForward = mkOption {
        type = with types; coercedTo bool (x: if x == false then "no" else "both") (enum [ "ipv4" "ipv6" "both" "no" ]);
        default = "no";
        description = "Enable IP forwarding for the macvlan interface.";
      };
      ipMasquerade = mkOption {
        type = with types; coercedTo bool (x: if x == false then "no" else "both") (enum [ "ipv4" "ipv6" "both" "no" ]);
        default = "no";
        description = "Enable IP masquerading for the macvlan interface and specify the source IP address to masquerade.";
      };

      defaultRoute = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to add a default route via the macvlan interface.";
      };
    };
  };

  netnsType = { lib, name, ... }:
    let
      inherit (lib)
        mkOption
        types;
    in {
    options = {
      name = mkOption {
        type = types.str;
        default = name;
        description = "Name of the network namespace.";
      };

      macvlan = mkOption {
        type = with types; nullOr (submodule macvlanType);
        default = null;
        description = "Configuration for the macvlan interface in the network namespace.";
      };

      nftables = mkOption {
        type = with types; coercedTo (listOf str) (builtins.concatStringsSep "\n") str;
        default = "";
        description = "List of nftables rules to apply to the macvlan interface.";
      };
    };
  };
}
