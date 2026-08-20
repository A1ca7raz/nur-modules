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
in
rec {
  hash = value: builtins.hashString "sha256" value;
  shortHash = value: builtins.substring 0 11 (hash value);
  kernelName = prefix: value:
    "${prefix}${builtins.substring 0 (15 - builtins.stringLength prefix) (hash value)}";

  gatewayDevice = name: kernelName "gw" "gateway:${name}";
  prefixDelegationDevice = name: kernelName "pd" "prefix-delegation:${name}";

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

  peerLinkNames = key: {
    sourceInterface = kernelName "p0" "peer-source:${key}";
    targetInterface = kernelName "p1" "peer-target:${key}";
    targetFinalInterface = "peer-${builtins.substring 0 10 (hash key)}";
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

  isEgressLink = cfg: link:
    cfg.egress.enable
    && link.interface.peer != null
    && link.interface.peer.service == "host"
    && link.interface.defaultRoute != null;

  parseIPv4Pool = pool:
    let
      parts = splitString "/" pool;
      address = if parts == [ ] then "" else builtins.head parts;
      prefixLength = if builtins.length parts == 2 then toInt (builtins.elemAt parts 1) else -1;
      addressValue = ipv4ToInt address;
      hostBits = 32 - prefixLength;
      size = if prefixLength >= 0 && prefixLength <= 32 then pow 2 hostBits else 0;
      hostMask = size - 1;
      networkValue = builtins.bitAnd addressValue (4294967295 - hostMask);
    in
    if builtins.length parts != 2 || prefixLength < 1 || prefixLength > 30 then
      throw "utils.vnet.egress.ipv4.pool must be an IPv4 CIDR with prefix length 1..30"
    else
      {
        inherit prefixLength size networkValue;
        network = "${intToIPv4 networkValue}/${toString prefixLength}";
        capacity = size - 2;
        addressAt = addressId:
          if addressId < 1 || addressId > size - 2 then
            throw "IPv4 address ID ${toString addressId} is outside ${pool}"
          else
            intToIPv4 (networkValue + addressId);
      };

  allocateEgressLinks = cfg: services:
    let
      pool = parseIPv4Pool cfg.egress.ipv4.pool;
      links = filter (isEgressLink cfg) (rawLinks services);
      explicitIds = map (link: link.interface.addressId) (
        filter (link: link.interface.addressId != null) links
      );
      nextFree = used: candidate:
        if builtins.elem candidate used then nextFree used (candidate + 1) else candidate;
      allocation = foldl'
        (
          state: link:
            let
              addressId =
                if link.interface.addressId != null then
                  link.interface.addressId
                else
                  nextFree (explicitIds ++ state.used) 2;
              names = peerLinkNames link.key;
            in
            {
              used = state.used ++ [ addressId ];
              links = state.links ++ [
                (link // names // {
                  inherit addressId;
                  ipv4Address = "${pool.addressAt addressId}/32";
                })
              ];
            }
        )
        { used = [ 1 ]; links = [ ]; }
        links;
    in
    allocation.links;
}
