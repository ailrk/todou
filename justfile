default:
  @just --list


build:
    cabal2nix . > default.nix
    just buildjs
    nix build


buildjs:
    #!/usr/bin/env bash
    pushd js/
    just build
    popd
    rm -rf data/todou
    mv -fT js/dist/ data/todou


dev:
    just buildjs
    cabal build


repl:
    cabal repl


deps:
    graphmod | dot -Tsvg -o modules.svg


profile:
    cabal clean
    cabal build --enable-profiling --disable-shared
    # run with +RTS -hc -p -l -RTS to get heap dump and prof file


vis:
    hp2ps -c -M todou.hp
    ps2pdf todou.ps


clean:
    cabal clean
    rm -f todou.hp
    rm -f todou.eventlog
    rm -f todou.ps
    rm -f todou.pdf
    rm -f todou.prof
    rm -f todou.aux


watch:
  ghcid -c "cabal repl todou" -s ":set args --storage=dir:_cache --port=5555"  -T "Todou.Main.main" -W


tags:
  mkdir -p tags
  cd tags && \
    rm ./* -rf && \
    concurrently \
      "cabal unpack base" \
      "cabal unpack scotty" \
      "cabal unpack ghc-internal" \
      "cabal unpack aeson" \
      "cabal unpack containers" \
      "cabal unpack text" \
      "cabal unpack bytestring" \
      "cabal unpack time" \
      "cabal unpack amazonka" \
      "cabal unpack amazonka-s3" && \
    fast-tags -R . -o tags

release:
  #!/usr/bin/env bash
  set -euo pipefail

  # Configuration
  APP_NAME="todou"
  DIST_DIR="release"
  SOURCE_BIN="result/bin/$APP_NAME"

  # Dynamic Architecture Detection
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)

  # Standardize arch names
  PLATFORM="${OS}-${ARCH}"

  # Get version from cabal file or fallback to 'latest'
  VERSION=$(grep -m 1 "^version:" *.cabal | awk '{print $2}' || echo "latest")
  ASSET_NAME="${APP_NAME}-${VERSION}-${PLATFORM}"

  echo "Blocking for platform: $PLATFORM (Version: $VERSION)"

  # Cleanup and Setup
  rm -rf "$DIST_DIR"
  mkdir -p "$DIST_DIR"

  if [ ! -f "$SOURCE_BIN" ]; then
      echo "Error: Binary not found at $SOURCE_BIN. Did you run 'nix build'?"
      exit 1
  fi

  # Stamp with git-rev
  git rev-parse --short HEAD > "$DIST_DIR/git-rev"

  # Prepare Binary
  cp "$SOURCE_BIN" "$DIST_DIR/$APP_NAME"
  chmod +x "$DIST_DIR/$APP_NAME"

  # Create Archive
  echo "Creating tarball: ${ASSET_NAME}.tar.gz"

  # Build list of extra files if they exist
  EXTRA_FILES=""
  [ -f "LICENSE" ] && EXTRA_FILES+=" LICENSE"
  [ -f "README.md" ] && EXTRA_FILES+=" README.md"
  EXTRA_FILES+=" git-rev"

  for f in $EXTRA_FILES; do
    if [ -f "$f" ]; then
      cp "$f" "$DIST_DIR/"
      FILES_TO_PACK+=("$f")
    fi
  done

  tar -czvf "$DIST_DIR/${ASSET_NAME}.tar.gz" \
      -C "$DIST_DIR" "$APP_NAME" \
      $EXTRA_FILES

  # Generate Checksum
  (cd "$DIST_DIR" && sha256sum "${ASSET_NAME}.tar.gz" > "${ASSET_NAME}.tar.gz.sha256")

  echo "---------------------------------------"
  echo "Release ready in ./$DIST_DIR:"
  ls -lh "$DIST_DIR/${ASSET_NAME}.tar.gz"*
