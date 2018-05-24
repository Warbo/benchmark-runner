with rec {
  pinnedConfig = (import <nixpkgs> { config = {}; }).fetchgit {
    url    = http://chriswarbo.net/git/nix-config.git;
    rev    = "84c4dce";
    sha256 = "01adg4yblj5m15qmkq60nycd9d28aa789j28hs2wb34c79lpbi4w";
  };

  configSrc = with builtins.tryEval <nix-config>;
              if success
                 then value
                 else pinnedConfig;
};
import configSrc {}
