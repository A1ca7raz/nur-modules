{ lib, config, ... }:
{
  imports = [
    ./netns.nix
    ./gateway.nix
    ./service.nix
    ./egress.nix
  ];

  config = lib.mkIf config.utils.vnet.enable {
    assertions = [
      {
        assertion = config.systemd.network.enable;
        message = "utils.vnet requires systemd-networkd; set systemd.network.enable = true.";
      }
    ];
  };
}
