pkgs:
with builtins;
with pkgs;
with rec {
  go = wrap {
    name  = "benchmark-runner";
    paths = [ (python.withPackages (p: [ asv-nix ])) bash fail jq nix.out ];
    vars  = withNix {
      inherit (import ./cache.nix pkgs) cacheResults setupCache;
      asvNix         = asv-nix;
      GIT_SSL_CAINFO = "${cacert}/etc/ssl/certs/ca-bundle.crt";
      runner         = pkgs.writeScript "benchmark-runner.sh" ''
        #!/usr/bin/env bash
        set -e

        # Real values taken from a Thinkpad X60s
        echo "Generating machine config" 1>&2
        asv machine                                                   \
          --arch    "i686"                                            \
          --cpu     "Genuine Intel(R) CPU          L2400  @ 1.66GHz"  \
          --machine "dummy"                                           \
          --os      "Linux 4.4.52"                                    \
          --ram     "3093764"

        # Default to everything since last run (which is all, for uncached)
        RANGE="NEW"
        if [[ -n "$commitCount" ]]
        then
          # @{N} is the Nth ancestor of current branch (0 would be HEAD)
          # foo..bar is bar and ancestors, excluding foo and ancestors
          RANGE="@{$commitCount}..HEAD"
        fi

        echo "Running asv on range $RANGE" 1>&2
        O=$(asv run --show-stderr --machine dummy "$RANGE" |
            tee >(cat 1>&2)) || {
          if echo "$O" | grep 'No commit hashes selected' > /dev/null
          then
            echo "No commits needed benchmarking, so asv run bailed out" 1>&2
          else
            fail "asv run failed, and it wasn't for lack of commits"
          fi
        }

        echo "Starting asv publish" 1>&2
        asv publish
      '';
    };
    script = ''
      #!/usr/bin/env bash
      set   -e
      shopt -s nullglob

      [[ -n "$dir" ]] || fail "No 'dir' given"

      GOT=0
      while read -r F; do GOT=1; done < <(find "$dir" -name 'asv.conf.json')
      [[ "$GOT" -eq 1 ]] || fail "No asv.conf.json found"
      unset GOT

      TEMPDIR=$(mktemp -d --tmpdir "benchmark-runner-temp-XXXXX")
      function cleanUp {
        rm -rf "$TEMPDIR"
      }
      trap cleanUp EXIT
      pushd "$TEMPDIR"

        export HOME="$PWD/home"
        mkdir "$HOME"

        echo "Making mutable copy of '$dir' to benchmark" 1>&2
        cp -r "$dir" ./src
        chmod +w -R  ./src

        pushd ./src
          while read -r F
          do
            pushd "$(dirname "$F")"
              echo "Reading config" 1>&2
              CONFIG=$(grep -v '^ *//' < "$F")

              RESULTS=$(echo "$CONFIG" | jq -r '.results_dir') ||
              RESULTS="$PWD/.asv/results"
              RESULTS=$(readlink -f "$RESULTS")

              HTML=$(echo "$CONFIG" | jq -r    '.html_dir') ||
              HTML="$PWD/.asv/html"
              HTML=$(readlink -f "$HTML")

              export RESULTS
              export HTML

              DIR="/nowhere"
              [[ -z "$cacheDir" ]] || DIR=$(echo "$CONFIG" | "$setupCache")

              if [[ -e shell.nix ]] || [[ -e default.nix ]]
              then
                echo "Running asv in nix-shell" 1>&2
                nix-shell --show-trace --run "$runner"
              else
                echo "No nix-shell file found, running asv 'bare'" 1>&2
                "$runner"
              fi

              [[ -e "$RESULTS" ]] || fail "No results ($RESULTS) found"
              [[ -e "$HTML"    ]] || fail "No HTML ($HTML) found"

              export DIR
              [[ -z "$cacheDir" ]] || "$cacheResults"
            popd
            break
          done < <(find . -name 'asv.conf.json')
        popd
      popd
      mv "$RESULTS" ./results
      mv "$HTML"    ./html
    '';
  };

  test = runCommand "benchmark-runner-test"
    {
      inherit go;
      buildInputs = [ fail git jq ];
      project     = attrsToDirs {
        "asv.conf.json" = writeScript "example-asv.conf.json" (toJSON {
          benchmark_dir = "b"; branches = [ "master" ]; builders = {};
          dvcs = "git"; env_dir = "e"; environment_type = "nix"; html_dir = "h";
          installer = "x: import (x.root + \"/x.nix\")"; matrix = {};
          plugins = [ "asv_nix" ]; project = "test"; repo = ".";
          results_dir = "r"; version = 1;
        });
        b = { "__init__.py" = writeScript "empty" "";
              "x.py" = writeScript "x.py" ''def track_x(): return 42''; };
        "x.nix" = writeScript "dummy" ''
          (import <nixpkgs> {}).runCommand "env" {} ${"''"}
            mkdir -p "$out/bin"
            ln -s "${python}/bin/python" "$out/bin/python"
          ${"''"}
        '';
      };
    }
    ''
      export HOME="$PWD/home"
      mkdir "$HOME"
      git config --global user.email "you@example.com"
      git config --global user.name  "Your Name"

      O=$("$go" 2>&1) && fail "Shouldn't succeed with no dir\n$O"

      function makeGit {
        pushd project
          git init .
          git add -A
          git commit -m "Initial commit"
          sed -e 's/42/24/g' -i b/x.py
          git add b/x.py
          git commit -m "Swap number"
        popd
      }

      cp -r "$project" project
      chmod +w -R project
      makeGit project
      dir="$PWD/project" "$go" || fail "Didn't benchmark bare project"
      [[ -e results ]]         || fail "No results dir found when bare"
      [[ -e html    ]]         || fail "No html dir found when bare"
      rm -rf results html project

      cp -r "$project" project
      chmod +w -R project
      mv project/x.nix project/default.nix
      sed -e 's@/x.nix@@g' -i project/asv.conf.json
      makeGit project
      dir="$PWD/project" "$go" || fail "Didn't benchmark nix-shell project"
      [[ -e results ]]         || fail "No results dir found when nix-shell"
      [[ -e html    ]]         || fail "No html dir found when nix-shell"
      rm -rf results html

      dir="$PWD/project" cacheDir="$PWD/cache" "$go" ||
        fail "Didn't work with empty cache"

      [[ -e cache   ]] || fail "No cache dir made"
      [[ -e results ]] || fail "No results made when caching"
      [[ -e html    ]] || fail "No html made when cachine"

      FOUND=0
      while read -r D
      do
        FOUND=1
      done < <(find cache -type d -name "*-test")
      [[ "$FOUND" -eq 1 ]] || fail "Didn't find cached result"

      rm -rf results html
      dir="$PWD/project" cacheDir="$PWD/cache" "$go" ||
        fail "Didn't work with populated cache"
      [[ -e results ]] || fail "No results when cached"
      [[ -e html    ]] || fail "No html when cached"

      mkdir "$out"
    '';
};
withDeps [ test ] go
