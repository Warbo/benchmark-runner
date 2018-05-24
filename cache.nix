pkgs:
with builtins;
with pkgs // { getSha = "sha256sum | cut -d ' ' -f1"; };
{
  # Copies data out of cache, setting up new cache if needed
  setupCache =
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
          set   -e
          shopt -s nullglob

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
          [[ -e "$NAME" ]] || mkdir -p "$NAME"
          if [[ -e "$RESULTS" ]]
          then
            for X in "$DIR/results"/*
            do
              cp -rv "$X" "$RESULTS"/ 1>&2
            done
          else
            cp -rv "$DIR/results"   "$RESULTS"  1>&2
          fi
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

  # Writes new results to cache
  cacheResults =
    with pkgs;
    with rec {
      go = wrap {
        name   = "cacheResults.sh";
        paths  = [ bash fail ];
        script = ''
          #!/usr/bin/env bash
          set   -e
          shopt -s nullglob

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
}
