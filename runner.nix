{
  cacheDir    ? null,
  commitCount ? 10,
  repo        ? abort "No repo URL given"
}:

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
    url         = repo;
    deepClone   = true;  # Get all revisions, not just latest
    leaveDotGit = true;  # .git is deleted by default, for reproducibility
    stable      = { unsafeSkip = true; };  # Always get latest revision
  };

  # Copies data out of cache, setting up new cache if needed
  setupCache =
    with pkgs;
    with rec {
      go = wrap {
        name  = "setupCache.sh";
        paths = [ bash fail jq ];
        vars  = {
          readme      = writeScript "cacheDir-README" ''
            # Cache for benchmark-runner #

            See http://chriswarbo.net/git/benchmark-runner

            This directory stores benchmark descriptions and results for asv
            benchmarks, keyed by hash. Move/delete these to force a re-run of
            those benchmarks. Use this path as 'cacheDir' to make use of them.
            This should be a world-writable directory.
          '';
        };
        script = ''
          #!/usr/bin/env bash
          set -e

          [[ -n "$cacheDir" ]] || fail "No cacheDir given"

          CONFIG=$(cat)
          [[ -n "$CONFIG"   ]] || fail "No config on stdin"

          echo "$CONFIG" | jq -e 'has("project")' > /dev/null ||
            fail "No 'project' key in config"

          PROJECT=$(echo "$CONFIG" | jq -r '.project' | tr -d '/') ||
            fail "Couldn't read 'project' from config:\n$CONFIG\n"

          [[ -n "$RESULTS" ]] || fail "No RESULTS dir given"

          [[ -d "$cacheDir" ]] || {
            echo "Creating new cacheDir '$cacheDir'" 1>&2
            mkdir -p "$cacheDir"
            mkdir -p "$cacheDir"
            chmod 777 -R "$cacheDir"
            cp "$readme" "$cacheDir/README"
          }

          SHASUM=$(echo "$CONFIG" | ${getSha})
          DIR="$cacheDir/$SHASUM-$PROJECT"

          [[ -d "$DIR" ]] || {
            echo "Creating cache for '$PROJECT' at '$DIR'" 1>&2
            mkdir -p "$DIR/results"
            mkdir -p "$DIR/benchmark-jsons"
            chmod 777 -R "$DIR"
          }

          NAME=$(dirname "$RESULTS")
          echo "Copying initial results (if any) from '$DIR' to '$RESULTS'" 1>&2
          [[ -e "$NAME" ]] || mkdir "$NAME"
          cp -rv "$DIR/results" "$NAME/" 1>&2
          chmod 777 -R "$RESULTS"

          echo "$DIR"
        '';
      };

      test = runCommand "setupCache-test.sh"
        {
          inherit go;
          buildInputs = [ fail jq ];
        }
        ''
          O=$(echo "" | RESULTS="/nowhere" "$go" 2>&1) &&
            fail "Should've failed without cacheDir\n$O"

          export cacheDir="$PWD/cacheDir"

          JSON='{"project": "test"}'
          O=$(echo "$JSON" | "$go" 2>&1) &&
            fail "Should fail without RESULTS\n$O"

          export RESULTS="$PWD/results"

          O=$(               "$go" 2>&1) && fail "Didn't spot no input\n$O"
          O=$(echo "(foo)" | "$go" 2>&1) && fail "Didn't spot non-JSON\n$O"
          O=$(echo "{}"    | "$go" 2>&1) && fail "Didn't need 'project'\n$O"

          [[ -d "$cacheDir" ]] && fail "Shouldn't make dirs when aborting"
          [[ -d "$RESULTS"  ]] && fail "Shouldn't copy dirs when aborting"
          echo "$JSON" | "$go" || fail "Shouldn't fail with project"
          [[ -d "$cacheDir" ]] || fail "Should have made cache dir"
          [[ -d "$RESULTS"  ]] || fail "Should have made results dir"

          shopt -s nullglob
          FOUND=0
          DIRNAME=""
          for D in "$cacheDir"/*-test
          do
            FOUND=1
            DIRNAME="$D"
          done
          [[ "$FOUND" -eq 1 ]] || fail "Should have made project dir"
          CONFHASH=$(echo "$JSON" | ${getSha})
          DIR="$cacheDir/$CONFHASH-test"
          [[ -e "$DIR" ]] ||
            fail "Name should be hash '$DIR', got '$DIRNAME'"
          unset DIRNAME

          mkdir "$DIR/results/machine"
          echo "foo" > "$DIR/results/machine/bar"
          echo "$JSON" | "$go" || fail "Shouldn't fail with cache"

          [[ -e "$RESULTS/machine/bar" ]] || {
            echo "Content of RESULTS ($RESULTS)" 1>&2
            find "$RESULTS" 1>&2
            fail "Should have copied cache"
          }
          GOT=$(cat "$RESULTS/machine/bar")
          [[ "x$GOT" = "xfoo" ]] || fail "Data wasn't copied"

          mkdir "$out"
        '';
    };
    withDeps [ test ] go;

  getSha = "sha256sum | cut -d ' ' -f1";

  # Writes new results to cache
  cacheResults =
    with pkgs;
    with rec {
      go = wrap {
        name   = "cacheResults.sh";
        paths  = [ bash fail ];
        script = ''
          #!/usr/bin/env bash
          set -e

          [[ -n "$DIR"     ]] || fail "No DIR given"
          [[ -e "$DIR"     ]] || fail "DIR '$DIR' doesn't exist"
          [[ -n "$RESULTS" ]] || fail "No RESULTS given"
          [[ -e "$RESULTS" ]] || fail "RESULTS dir '$RESULTS' doesn't exist"

          [[ -e "$DIR/results"         ]] || mkdir "$DIR/results"
          [[ -e "$DIR/benchmark-jsons" ]] || mkdir "$DIR/benchmark-jsons"

          echo "Copying results (if any) to cache '$DIR'" 1>&2
          for D in "$RESULTS"/*
          do
            if [[ -d "$D" ]]
            then
              NAME=$(basename "$D")
              [[ -e "$DIR/results/$NAME" ]] || {
                cp -rv "$D" "$DIR/results/"
              }
              for X in "$D"/*
              do
                XNAME=$(basename "$X")
                [[ -e "$DIR/results/$NAME/$XNAME" ]] ||
                  cp -rv "$X" "$DIR/results/$NAME/"
              done
            fi
          done

          EXIST="$DIR/results/benchmarks.json"
          EXISTHASH="nope"
          [[ -e "$EXIST" ]] &&
            EXISTHASH=$(cat "$EXIST" | ${getSha})

          BENCH="$RESULTS/benchmarks.json"
          BENCHHASH=$(cat "$BENCH" | ${getSha})
          [[ "x$EXISTHASH" = "x$BENCHHASH" ]] || cp -v "$BENCH" "$EXIST"

          TOMAKE="$DIR/benchmark-jsons/$BENCHHASH-benchmarks.json"
          [[ -e "$TOMAKE" ]] || cp -v "$BENCH" "$TOMAKE"

          chmod 777 -R "$DIR" || true
        '';
      };

      test = runCommand "testCacheResults"
        {
          inherit go;
          buildInputs  = [ fail ];
        }
        ''
          O=$(                                 "$go" 2>&1) &&
            fail "Should've failed without DIR\n$O"
          O=$(DIR="/nowhere"                   "$go" 2>&1) &&
            fail "Should've failed without RESULTS\n$O"
          O=$(DIR="/nowhere" RESULTS="/nowhen" "$go" 2>&1) &&
            fail "Should've failed with nonexistent DIR\n$O"

          export DIR="$PWD/dir"
          mkdir "$DIR"
          O=$(RESULTS="/nowhen" "$go" 2>&1) &&
            fail "Should've failed with nonexistent RESULTS\n$O"

          export RESULTS="$PWD/results"
          mkdir "$RESULTS"
          O=$("$go" 2>&1) && fail "Should require benchmarks.json\n$O"

          echo "dummy" > "$RESULTS/benchmarks.json"
          "$go" || fail "Should've succeeded with benchmarks.json"

          [[ -e "$DIR/results/benchmarks.json" ]] ||
            fail "Should copy benchmarks.json"
          GOT=$(cat "$DIR/results/benchmarks.json")
          [[ "x$GOT" = "xdummy" ]] || fail "Expected 'dummy', got '$GOT'"
          unset GOT

          BENCHHASH=$(echo "dummy" | ${getSha})
          BENCH="$DIR/benchmark-jsons/$BENCHHASH-benchmarks.json"
          [[ -e "$BENCH" ]] || fail "No hashed benchmarks.json found"
          GOT=$(cat "$BENCH")
          [[ "x$GOT" = "xdummy" ]] || fail "Hashed should be 'dummy' not '$GOT'"
          unset GOT

          mkdir "$RESULTS/machine"
          echo "foo" > "$RESULTS/machine/bar"
          "$go"
          [[ -e "$DIR/results/machine/bar" ]] || fail "No results/machine/bar"

          GOT=$(cat "$DIR/results/machine/bar")
          [[ "x$GOT" = "xfoo" ]] || fail "Expected 'foo' result, not '$GOT'"

          mkdir "$out"
        '';
    };
    withDeps [ test ] go;

  runner = pkgs.writeScript "benchmark-runner.sh" ''
    #!/usr/bin/env bash
    set -e

    # Real values taken from a Thinkpad X60s
    echo "Generating machine config" 1>&2
    asv machine --arch    "i686"                                           \
                --cpu     "Genuine Intel(R) CPU          L2400  @ 1.66GHz" \
                --machine "dummy"                                          \
                --os      "Linux 4.4.52"                                   \
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
    asv run --show-stderr --machine dummy "$RANGE"

    echo "Starting asv publish" 1>&2
    asv publish
  '';

  run = with pkgs; runCommand "run-benchmarks-${sanitiseName repo}"
    (withNix {
      inherit cacheDir cacheResults dir runner setupCache;
      commitCount = if isInt commitCount then toString commitCount else null;
      buildInputs = [ bash asv-nix fail jq ];
    })
    ''
      shopt -s nullglob
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
          echo "Reading config" 1>&2
          CONFIG=$(grep -v '^ *//' < "$F")

          RESULTS=$(echo "$CONFIG" | jq -r '.results_dir') ||
          RESULTS="$PWD/.asv/results"

          HTML=$(echo "$CONFIG" | jq -r    '.html_dir') ||
          HTML="$PWD/.asv/html"

          export RESULTS
          export HTML

          DIR="/nowhere"
          if [[ -n "$cacheDir" ]]
          then
            DIR=$(echo "$CONFIG" | "$setupCache")
          fi

          if [[ -e shell.nix ]] || [[ -e default.nix ]]
          then
            echo "Running asv in nix-shell" 1>&2
            nix-shell --show-trace --run "$runner"
          else
            echo "No shell.nix or default.nix found, running asv 'bare'" 1>&2
            "$runner"
          fi

          [[ -e "$RESULTS" ]] || fail "No results ($RESULTS) found, aborting"
          [[ -e "$HTML"    ]] || fail "No HTML ($HTML) found, aborting"

          if [[ -n "$cacheDir" ]]
          then
            "$cacheResults"
          fi
        popd

        mkdir "$out"
        cp -r "$RESULTS" "$out"/results
        cp -r "$HTML"    "$out"/html
      done < <(find . -name 'asv.conf.json')

      [[ "$FOUND" -eq 1 ]] || fail "No asv.conf.json found"
    '';

  results = with pkgs; runCommand "benchmark-results-${sanitiseName repo}"
    { inherit run; }
    ''ln -s "$run/results" "$out"'';

  html = with pkgs; runCommand "benchmark-pages-${sanitiseName repo}"
    {
      inherit run;
      buildInputs = [ replace ];
      htmlInliner = import (fetchgit {
        url    = http://chriswarbo.net/git/html-inliner.git;
        rev    = "d24cca4";
        sha256 = "14y4w7l41j9sb7bfgjzidq89wgzhkwxvkgq5wb7qnqjfqcyygi63";
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
      cp -r "$run"/html ./result
      chmod +w -R       ./result

      echo "Fixing up HTML" 1>&2
      find "$PWD/result" -name "*.html" | while read -r F
      do
         CONTENT=$(cat "$F")
             DIR=$(dirname "$F")
        export BASE_URL="file://$DIR"
        echo "$CONTENT" | "$htmlInliner" > "$F"
      done

      echo "Fixing MIME types" 1>&2
      find ./result -name "*.js" | while read -r F
      do
        replace "$pre1" "$post1" -- "$F"
        replace "$pre2" "$post2" -- "$F"
      done

      mv ./result "$out"
      echo "Done" 1>&2
    '';
};
{ inherit html results; }
