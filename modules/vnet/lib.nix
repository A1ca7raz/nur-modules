{ lib }:
let
  inherit (lib)
    concatMap
    filter
    foldl'
    mapAttrsToList
    splitString
    toInt
    ;

  pow = base: exponent:
    if exponent == 0 then 1 else base * pow base (exponent - 1);

  ipv4ToInt = address:
    let
      octets = map toInt (splitString "." address);
    in
    if
      builtins.length octets != 4
      || !(builtins.all (octet: octet >= 0 && octet <= 255) octets)
    then
      throw "${address} is not a valid IPv4 address"
    else
      foldl' (value: octet: value * 256 + octet) 0 octets;

  intToIPv4 = value:
    lib.concatMapStringsSep "." toString [
      (builtins.bitAnd (builtins.div value 16777216) 255)
      (builtins.bitAnd (builtins.div value 65536) 255)
      (builtins.bitAnd (builtins.div value 256) 255)
      (builtins.bitAnd value 255)
    ];

  parseIPv4CIDR = cidr:
    let
      parts = splitString "/" cidr;
      address = if parts == [ ] then "" else builtins.head parts;
      prefixLength = if builtins.length parts == 2 then toInt (builtins.elemAt parts 1) else -1;
      addressValue = ipv4ToInt address;
      hostBits = 32 - prefixLength;
      size = if prefixLength >= 0 && prefixLength <= 32 then pow 2 hostBits else 0;
      hostMask = size - 1;
      networkValue = builtins.bitAnd addressValue (4294967295 - hostMask);
    in
    if builtins.length parts != 2 || prefixLength < 0 || prefixLength > 32 then
      throw "${cidr} must be an IPv4 CIDR with prefix length 0..32"
    else
      {
        inherit prefixLength size networkValue;
        network = "${intToIPv4 networkValue}/${toString prefixLength}";
      };
in
rec {
  hash = value: builtins.hashString "sha256" value;
  shortHash = value: builtins.substring 0 11 (hash value);
  sanitizeName = value:
    lib.concatMapStrings
      (
        character:
        if builtins.match "[A-Za-z0-9_.-]" character != null then character else "-"
      )
      (lib.stringToCharacters value);
  nftIdentifier = value:
    lib.concatMapStrings
      (
        character:
        if builtins.match "[A-Za-z0-9_]" character != null then character else "_"
      )
      (lib.stringToCharacters value);
  kernelName = prefix: value:
    let
      available = 15 - builtins.stringLength prefix;
      sanitized = sanitizeName value;
    in
    if available < 1 then
      throw "vnet interface prefix ${prefix} is too long"
    else
      "${prefix}${builtins.substring 0 available sanitized}";

  gatewayDevice = name: kernelName "vbr-" name;
  prefixDelegationDevice = name: kernelName "vpd-" name;

  linkName = serviceName: interfaceName:
    sanitizeName (
      if lib.hasPrefix "${serviceName}-" interfaceName then
        interfaceName
      else
        "${serviceName}-${interfaceName}"
    );
  gatewayLinkServiceName = serviceName: interfaceName:
    "vnet-gateway-${linkName serviceName interfaceName}";
  egressLinkServiceName = serviceName:
    "vnet-egress-${sanitizeName serviceName}";
  peerLinkServiceName = members:
    "vnet-peer-${lib.concatMapStringsSep "-and-" (
      member: linkName member.serviceName member.interfaceName
    ) members}";

  macAddress = value:
    let
      digest = hash value;
    in
    lib.concatStringsSep ":" [
      "02"
      (builtins.substring 0 2 digest)
      (builtins.substring 2 2 digest)
      (builtins.substring 4 2 digest)
      (builtins.substring 6 2 digest)
      (builtins.substring 8 2 digest)
    ];

  peerLinkNames = value: key: {
    sourceInterface = kernelName "vp0-" value;
    targetInterface = kernelName "vp1-" value;
    sourceMac = macAddress "peer-source:${key}";
    targetMac = macAddress "peer-target:${key}";
  };

  egressPeerLinkNames = value: key: {
    sourceInterface = kernelName "vpe0-" value;
    targetInterface = kernelName "vpe-" value;
    sourceMac = macAddress "peer-source:${key}";
    targetMac = macAddress "peer-target:${key}";
  };

  rawLinks = services:
    concatMap
      (
        serviceName:
        mapAttrsToList
          (interfaceName: interface: {
            key = "${serviceName}:${interfaceName}";
            inherit interfaceName interface serviceName;
            service = services.${serviceName};
          })
          services.${serviceName}.interfaces
      )
      (builtins.attrNames services);

  ipv4Network = cidr: (parseIPv4CIDR cidr).network;

  parseIPv4Pool = pool:
    let
      parsed = parseIPv4CIDR pool;
      inherit (parsed) prefixLength size networkValue;
    in
    if prefixLength < 1 || prefixLength > 30 then
      throw "utils.vnet.egress.ipv4.pool must be an IPv4 CIDR with prefix length 1..30"
    else
      parsed // {
        capacity = size - 2;
        addressAt = addressId:
          if addressId < 1 || addressId > size - 2 then
            throw "IPv4 address ID ${toString addressId} is outside ${pool}"
          else
            intToIPv4 (networkValue + addressId);
      };

  egressAddressId = services: serviceName:
    2 + lib.lists.findFirstIndex
      (candidate: candidate == serviceName)
      (throw "missing utils.vnet service ${serviceName}")
      (builtins.attrNames services);

  allocateEgressLinks = cfg: services:
    let
      pool = parseIPv4Pool cfg.egress.ipv4.pool;
      serviceNames = builtins.attrNames services;
      privateServiceNames = filter
        (
          serviceName:
          services.${serviceName}.enable && services.${serviceName}.privateNetwork
        )
        serviceNames;
    in
    if !cfg.egress.enable then
      [ ]
    else
      map
        (
          serviceName:
          let
            service = services.${serviceName};
            addressId = egressAddressId services serviceName;
            key = "${serviceName}:vnet-egress";
          in
          ({
            inherit key serviceName service addressId;
            interfaceName = "vnet-egress";
            interface = {
              addresses = [ ];
              gateway = null;
              peer = {
                service = "host";
                endpoint = null;
              };
              defaultRoute =
                if service.egress.enable then {
                  via = null;
                  metric = null;
                } else null;
            };
            ipv4Address = "${pool.addressAt addressId}/32";
            internet = service.egress.enable;
            ipv6 = service.egress.enable && service.egress.enableIPv6;
          } // egressPeerLinkNames serviceName key)
        )
        privateServiceNames;
}
