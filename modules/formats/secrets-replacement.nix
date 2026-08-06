# Adapted from nixpkgs' nixos/lib/utils.nix secret replacement helpers.
{ lib, pkgs }:
let
  inherit (lib)
    attrNames
    concatStringsSep
    escapeShellArg
    escapeShellArgs
    flatten
    imap0
    imap1
    isAttrs
    isDerivation
    isList
    listToAttrs
    mapAttrs
    nameValuePair
    optionalString
    replaceStrings
  ;

  recursiveGetAttrsetWithJqPrefix = item: attr:
    let
      recurse = prefix: value:
        if isAttrs value && value ? ${attr}
        then [ (nameValuePair prefix value) ]
        else if isDerivation value
        then []
        else if isAttrs value
        then map
          (name:
            let
              escapedName = ''"${replaceStrings [ ''"'' "\\" ] [ ''\"'' "\\\\" ] name}"'';
            in
              recurse
                (prefix + (if prefix == "." then "" else ".") + escapedName)
                value.${name}
          )
          (attrNames value)
        else if isList value
        then imap0 (index: entry: recurse (prefix + "[${toString index}]") entry) value
        else [];
    in
      listToAttrs (flatten (recurse "." item));

  tools = {
    json = [ "${pkgs.jq}/bin/jq" ];
    yaml = [
      "${pkgs.yq}/bin/yq"
      "--yaml-output"
      "--yaml-output-grammar-version"
      "1.2"
    ];
    toml = [
      "${pkgs.yq}/bin/tomlq"
      "--toml-output"
    ];
  };
in {
  genSecretsReplacementSnippet = {
    format,
    content,
    input,
    output,
  }:
    let
      secretsRaw = recursiveGetAttrsetWithJqPrefix content "_secret";
      secrets = mapAttrs (_: marker: { quote = true; } // marker) secretsRaw;
      outputWithoutContext = builtins.unsafeDiscardStringContext output;
      outputIsInStore = lib.hasPrefix "${builtins.storeDir}/" outputWithoutContext;
      outputArg = escapeShellArg output;
      filter =
        let
          replacements = concatStringsSep " | " (imap1
            (index: name:
              ''${name} = ($ENV.secret${toString index}${optionalString (!secrets.${name}.quote) " | fromjson"})''
            )
            (attrNames secrets));
        in
          if replacements == "" then "." else replacements;
      command = escapeShellArgs (
        (tools.${format} or (throw "Unsupported secrets replacement format: ${format}"))
        ++ [ filter (toString input) ]
      );
    in
      assert lib.assertMsg (!outputIsInStore) ''
        Secrets replacement output must be outside the Nix store, but got: ${outputWithoutContext}
      '';
      ''
        if [[ -h ${outputArg} ]]; then
          ${pkgs.coreutils}/bin/rm -- ${outputArg}
        fi

        inherit_errexit_enabled=0
        shopt -pq inherit_errexit && inherit_errexit_enabled=1
        shopt -s inherit_errexit
      ''
      + concatStringsSep "\n" (imap1
        (index: name:
          let
            secretPath = escapeShellArg (toString secrets.${name}._secret);
          in ''
            secret${toString index}=$(<${secretPath})
            export secret${toString index}
          ''
        )
        (attrNames secrets))
      + "\n"
      + ''
        ${command} >${outputArg}
        (( ! inherit_errexit_enabled )) && shopt -u inherit_errexit
      '';
}
