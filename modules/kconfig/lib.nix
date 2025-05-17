{ pkgs }:
rec {
  writeConfigScript = pkgs.writeShellApplication {
    name = "write_kconfig";
    runtimeInputs = [ pkgs.python3 ];
    text = ''python ${./write_config.py} "$@"'';
  };

  ##############################################################################
  # Generate a command to run the config-writer script by first sending in the
  # attribute-set as json. Here a is the attribute-set.
  #
  # Type: AttrSet -> string
  writeConfig =
    fileName: json:
    let
      jsonStr = builtins.toJSON json;
      # Writing to file handles special characters better than passing it in as
      # an argument to the script.
      jsonFile = pkgs.writeText "${fileName}.data.json" jsonStr;
    in
      pkgs.writeShellApplication {
        name = "write_kconfig_${fileName}";
        runtimeInputs = [ writeConfigScript ];
        text = ''
          write_kconfig ${jsonFile} "$@"
        '';
      };
}
