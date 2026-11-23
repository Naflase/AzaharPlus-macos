#!/bin/bash -e
#
# Post-process a macOS app bundle produced by `ninja bundle` when building
# against Homebrew's ffmpeg@7.
#
# macdeployqt (run with -always-overwrite) replaces the FFmpeg dylibs the app
# was linked against with the minimal FFmpeg build shipped with Qt, which lacks
# symbols the app needs (e.g. av_vlog). This script:
#   - copies the ffmpeg@7 dylibs back into Contents/Frameworks,
#   - recursively bundles their non-system dependencies,
#   - bundles SDL3, which Homebrew's sdl2-compat (pulled in by libavdevice)
#     loads at runtime,
#   - rewrites install names to @executable_path/../Frameworks,
#   - re-signs the bundle ad hoc and verifies that it is self-contained.
#
# Usage: .ci/macos-fix-bundle.sh path/to/App.app

if [ $# -ne 1 ] || [ ! -d "$1/Contents/MacOS" ]; then
    echo "Usage: $0 path/to/App.app" >&2
    exit 1
fi

APP="$(cd "$1" && pwd)"
FW="$APP/Contents/Frameworks"
REF='@executable_path/../Frameworks'
BREW_PREFIX="$(brew --prefix)"
FFMPEG_LIB="$(brew --prefix ffmpeg@7)/lib"
SDL3_LIB="$(brew --prefix sdl3)/lib"
FFMPEG_LIBS="avcodec avdevice avfilter avformat avutil postproc swresample swscale"

if [ ! -d "$FFMPEG_LIB" ]; then
    echo "ffmpeg@7 is not installed (brew install ffmpeg@7)" >&2
    exit 1
fi

mkdir -p "$FW"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
QUEUE="$WORK/queue"   # lines: <bundled file>|<original source file>
DONE="$WORK/done"
: > "$QUEUE"
: > "$DONE"

# install_name_tool always warns that it invalidates the code signature; we
# re-sign at the end, so only hide that warning.
int() {
    local err status=0
    err="$(install_name_tool "$@" 2>&1)" || status=$?
    if [ -n "$err" ]; then
        echo "$err" | grep -v "invalidate the code signature" >&2 || true
    fi
    return $status
}

is_system() {
    case "$1" in
        /usr/lib/*|/System/*) return 0 ;;
    esac
    return 1
}

# Find the file a dependency refers to, outside the bundle.
# $1 = dependency as recorded in the binary, $2 = original path of the binary.
resolve_source() {
    local dep="$1" origin_dir b candidate
    origin_dir="$(dirname "$2")"
    b="$(basename "$dep")"
    case "$dep" in
        /*)
            [ -e "$dep" ] && { echo "$dep"; return 0; } ;;
        @loader_path/*)
            candidate="$origin_dir/${dep#@loader_path/}"
            [ -e "$candidate" ] && { echo "$candidate"; return 0; } ;;
    esac
    for candidate in "$origin_dir/$b" "$BREW_PREFIX/lib/$b" "$BREW_PREFIX"/opt/*/lib/"$b"; do
        [ -e "$candidate" ] && { echo "$candidate"; return 0; }
    done
    return 1
}

# Copy a library into Frameworks (replacing any existing copy) and queue it.
add_lib() {
    local src="$1" name="${2:-$(basename "$1")}"
    rm -f "$FW/$name"
    cp -L "$src" "$FW/$name"
    chmod u+w "$FW/$name"
    # A fresh copy has to be processed again.
    grep -vxF "$FW/$name" "$DONE" > "$WORK/done.tmp" || true
    mv "$WORK/done.tmp" "$DONE"
    echo "$FW/$name|$src" >> "$QUEUE"
    echo "Bundled $name (from $src)"
}

process_queue() {
    local entry f src name dep b dep_src rpath
    while [ -s "$QUEUE" ]; do
        entry="$(head -n 1 "$QUEUE")"
        tail -n +2 "$QUEUE" > "$WORK/queue.tmp" && mv "$WORK/queue.tmp" "$QUEUE"
        f="${entry%%|*}"
        src="${entry#*|}"
        grep -qxF "$f" "$DONE" && continue
        echo "$f" >> "$DONE"

        name="$(basename "$f")"
        int -id "$REF/$name" "$f"

        # Dependencies (skipping the library's own install name).
        otool -L "$f" | tail -n +2 | awk '{print $1}' | while read -r dep; do
            is_system "$dep" && continue
            b="$(basename "$dep")"
            [ "$b" = "$name" ] && continue
            if [ ! -e "$FW/$b" ]; then
                if ! dep_src="$(resolve_source "$dep" "$src")"; then
                    echo "ERROR: cannot resolve $dep (needed by $name)" >&2
                    exit 1
                fi
                add_lib "$dep_src" "$b"
            fi
            [ "$dep" = "$REF/$b" ] || int -change "$dep" "$REF/$b" "$f"
        done

        # Drop rpaths pointing outside the bundle.
        otool -l "$f" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | while read -r rpath; do
            case "$rpath" in
                @*) ;;
                *) int -delete_rpath "$rpath" "$f" ;;
            esac
        done
    done
}

# 1. Put back the FFmpeg 7 libraries the app was linked against.
for lib in $FFMPEG_LIBS; do
    for path in "$FFMPEG_LIB"/lib$lib.*.dylib; do
        file_name="$(basename "$path")"
        # Only the lib<name>.<major>.dylib names are used as install names.
        if echo "$file_name" | grep -qE "^lib$lib\.[0-9]+\.dylib$"; then
            add_lib "$path"
        fi
    done
done
# Also fix up the Homebrew libraries macdeployqt already copied: they may still
# use @rpath references to libraries it did not bundle, or absolute rpaths.
for path in "$FW"/*.dylib; do
    [ -L "$path" ] || echo "$path|$path" >> "$QUEUE"
done
process_queue

# 2. Homebrew's SDL2 is sdl2-compat, which loads SDL3 at runtime and aborts if
#    it cannot be found.
if [ -e "$FW/libSDL2-2.0.0.dylib" ]; then
    add_lib "$SDL3_LIB/libSDL3.0.dylib" libSDL3.dylib
    process_queue
fi

# 3. Re-sign ad hoc.
codesign --force --deep -s - "$APP"

# 4. Verify the bundle is self-contained.
EXE_DIR="$APP/Contents/MacOS"

list_rpaths() {
    otool -l "$1" | awk '/cmd LC_RPATH/{getline; getline; print $2}'
}

# Expand @loader_path/@executable_path. $1 = path, $2 = loader directory.
expand_path() {
    local p="${1/#@executable_path/$EXE_DIR}"
    echo "${p/#@loader_path/$2}"
}

EXE_RPATHS="$(for e in "$EXE_DIR"/*; do
    list_rpaths "$e" | while IFS= read -r r; do expand_path "$r" "$EXE_DIR"; done
done)"

is_external() {
    case "$1" in
        /opt/homebrew/*|/usr/local/*|*externals/qt*) return 0 ;;
    esac
    return 1
}

errors=0
while IFS= read -r -d '' f; do
    [ "$(file -b --mime-type "$f")" = "application/x-mach-binary" ] || continue
    loader_dir="$(dirname "$f")"
    rpaths="$EXE_RPATHS"
    while IFS= read -r rpath; do
        [ -n "$rpath" ] || continue
        if is_external "$rpath"; then
            echo "ERROR: $f has external rpath $rpath" >&2
            errors=$((errors + 1))
        fi
        rpaths="$(expand_path "$rpath" "$loader_dir")
$rpaths"
    done < <(list_rpaths "$f")

    while read -r dep rest; do
        case "$dep" in
            "$f"*) continue ;; # "<file> (architecture ...)" header lines
        esac
        if is_external "$dep"; then
            echo "ERROR: $f links to external $dep" >&2
            errors=$((errors + 1))
            continue
        fi
        case "$dep" in
            @executable_path/*|@loader_path/*)
                if [ ! -e "$(expand_path "$dep" "$loader_dir")" ]; then
                    echo "ERROR: $f links to missing $dep" >&2
                    errors=$((errors + 1))
                fi ;;
            @rpath/*)
                found=0
                while IFS= read -r rpath; do
                    [ -n "$rpath" ] && [ -e "$rpath/${dep#@rpath/}" ] && { found=1; break; }
                done <<< "$rpaths"
                if [ $found -eq 0 ]; then
                    echo "ERROR: $f links to unresolved $dep" >&2
                    errors=$((errors + 1))
                fi ;;
        esac
    done < <(otool -L "$f" | tail -n +2)
done < <(find "$APP" -type f -print0)

if [ $errors -ne 0 ]; then
    echo "Bundle verification failed with $errors error(s)" >&2
    exit 1
fi

codesign --verify --deep --strict "$APP"
echo "Bundle fixed and verified: $APP"
