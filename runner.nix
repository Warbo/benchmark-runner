{ repo ? null }:

with builtins;
with rec {
  pinnedConfig = (import <nixpkgs> { config = {}; }).fetchgit {
    url    = http://chriswarbo.net/git/nix-config.git;
    rev    = "fd0535c";
    sha256 = "1ag9r7q1wnlz26s4h4q85ggy2bvj2s4nx6n0g1m40qirxqmnyj47";
  };

  configSrc = with tryEval <nix-config>;
              if success
                 then value
                 else pinnedConfig;

  pkgs = import configSrc {};

  dir = pkgs.latestGit {
    inherit url;
    deepClone   = true;  # Get all revisions, not just latest
    leaveDotGit = true;  # .git is deleted by default, for reproducibility
    stable      = { unsafeSkip = true; };  # Always get latest revision
  };

  url = with tryEval <repo> // { env = getEnv "REPO"; };
        if success
           then value
           else if env != ""
                   then env
                   else abort "No <repo> or REPO given";

  run = with pkgs; runCommand "run-benchmarks-${sanitiseName url}"
    (withNix {
      inherit dir;
      buildInputs = [ bash asv-nix fail jq ];
      runner      = writeScript "benchmark-runner.sh" ''
        #!/usr/bin/env bash
        set -e

        # Real values taken from a Thinkpad X60s
        echo "Generating machine config" 1>&2
        asv machine --arch    "i686"                                            \
                    --cpu     "Genuine Intel(R) CPU           L2400  @ 1.66GHz" \
                    --machine "dummy"                                           \
                    --os      "Linux 4.4.52"                                    \
                    --ram     "3093764"

        echo "Starting asv run" 1>&2
        asv run --show-stderr --machine dummy

        echo "Starting asv publish" 1>&2
        asv publish
      '';
    })
    ''
      export HOME="$PWD/home"
      mkdir "$HOME"

      echo "Making mutable copy of '$dir' to benchmark" 1>&2
      cp -r "$dir" ./src
      chmod +w -R ./src
      cd ./src

      FOUND=0
      while read -r F
      do
        FOUND=1
        pushd "$(dirname "$F")"
          if [[ -e shell.nix ]] || [[ -e default.nix ]]
          then
            echo "Running asv in nix-shell" 1>&2
            nix-shell --show-trace --run "$runner"
          else
            echo "No shell.nix or default.nix found, running asv 'bare'" 1>&2
            "$runner"
          fi
        popd

        echo "Finding output" 1>&2
        CONFIG=$(grep -v '^ *//' < "$F")
        RESULTS=$(echo "$CONFIG" | jq -r '.results_dir') ||
        RESULTS="$PWD/.asv/results"
           HTML=$(echo "$CONFIG" | jq -r    '.html_dir') ||
           HTML="$PWD/.asv/html"

        [[ -e "$RESULTS" ]] || fail "No results ($RESULTS) found, aborting"
        [[ -e "$HTML"    ]] || fail "No HTML ($HTML) found, aborting"

        mkdir "$out"
        cp -r "$RESULTS" "$out"/results
        cp -r "$HTML"    "$out"/html
      done < <(find . -name 'asv.conf.json')

      [[ "$FOUND" -eq 1 ]] || fail "No asv.conf.json found"
    '';

  results = with pkgs; runCommand "benchmark-results-${sanitiseName url}"
    { inherit run; }
    ''ln -s "$run/results" "$out"'';

  html = with pkgs; runCommand "benchmark-pages-${sanitiseName url}"
    {
      inherit run;
      htmlInliner = import (fetchgit {
        url    = http://chriswarbo.net/git/html-inliner.git;
        rev    = "9911aa8";
        sha256 = "0ls9hh5zq4kifc5k2zlfjccvfp3yka48076v3igr4mnf7rfrlvrk";
      });
      pre1  = "url: 'regressions.json',";
      post1 = ''
        url: 'regressions.json',
        beforeSend: function(xhr){
          if (xhr.overrideMimeType) {
            xhr.overrideMimeType("application/json");
          }
        },
      '';
      pre2  = ''dataType: "json",'';
      post2 = ''
        dataType: "json",
        beforeSend: function(xhr){
          if (xhr.overrideMimeType) {
            xhr.overrideMimeType("application/json");
          }
        },
      '';
    }
    ''
      cp -r "$run"/html    "$out"
      chmod +w -R "$out"

      echo "Fixing up HTML" 1>&2
      find "$out" -name "*.html" | while read -r F
      do
        CONTENT=$(cat "$F")
        echo "$CONTENT" | "$htmlInliner" > "$F"
      done

      echo "Fixing MIME types" 1>&2
      find "$out" -name "*.js" | while read -r F
      do
        replace "$pre" "$post" -- "$F"
      done
    '';

};
{ inherit html results; }
