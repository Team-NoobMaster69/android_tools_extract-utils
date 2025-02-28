#!/bin/bash
#
# Copyright (C) 2016 The CyanogenMod Project
# Copyright (C) 2017-2024 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

PRODUCT_COPY_FILES_LIST=()
PRODUCT_COPY_FILES_HASHES=()
PRODUCT_COPY_FILES_FIXUP_HASHES=()
PRODUCT_PACKAGES_LIST=()
PRODUCT_PACKAGES_HASHES=()
PRODUCT_PACKAGES_FIXUP_HASHES=()
PRODUCT_SYMLINKS_LIST=()
PACKAGE_LIST=()
REQUIRED_PACKAGES_LIST=
EXTRACT_SRC=
EXTRACT_STATE=-1
VENDOR_STATE=-1
VENDOR_RADIO_STATE=-1
COMMON=-1
ARCHES=
FULLY_DEODEXED=-1

KEEP_DUMP=${KEEP_DUMP:-0}
SKIP_CLEANUP=${SKIP_CLEANUP:-0}
EXTRACT_TMP_DIR=$(mktemp -d)
HOST="$(uname | tr '[:upper:]' '[:lower:]')"

#
# cleanup
#
# kill our tmpfiles with fire on exit
#
function cleanup() {
    if [ "$SKIP_CLEANUP" == "true" ] || [ "$SKIP_CLEANUP" == "1" ]; then
        echo "Skipping cleanup of $EXTRACT_TMP_DIR"
    else
        rm -rf "${EXTRACT_TMP_DIR:?}"
    fi
}

trap cleanup 0

#
# setup_vendor_deps
#
# $1: Android root directory
# Sets up common dependencies for extraction
#
function setup_vendor_deps() {
    export ANDROID_ROOT="$1"
    if [ ! -d "$ANDROID_ROOT" ]; then
        echo "\$ANDROID_ROOT must be set and valid before including this script!"
        exit 1
    fi

    export BINARIES_LOCATION="$ANDROID_ROOT"/prebuilts/extract-tools/${HOST}-x86/bin
    export CLANG_BINUTILS="$ANDROID_ROOT"/prebuilts/clang/host/${HOST}-x86/llvm-binutils-stable
    export JDK_BINARIES_LOCATION="$ANDROID_ROOT"/prebuilts/jdk/jdk21/${HOST}-x86/bin
    export COMMON_BINARIES_LOCATION="$ANDROID_ROOT"/prebuilts/extract-tools/common

    export SIMG2IMG="$BINARIES_LOCATION"/simg2img
    export LPUNPACK="$BINARIES_LOCATION"/lpunpack
    export OTA_EXTRACTOR="$BINARIES_LOCATION"/ota_extractor
    export SIGSCAN="$BINARIES_LOCATION"/SigScan
    export STRIPZIP="$BINARIES_LOCATION"/stripzip
    export OBJDUMP="$CLANG_BINUTILS"/llvm-objdump
    export JAVA="$JDK_BINARIES_LOCATION"/java
    export APKTOOL="$COMMON_BINARIES_LOCATION"/apktool/apktool.jar

    for version in 0_8 0_9 0_17_2; do
        export PATCHELF_${version}="$BINARIES_LOCATION"/patchelf-"${version}"
    done

    if [ -z "$PATCHELF_VERSION" ]; then
        export PATCHELF_VERSION=0_9
    fi

    if [ -z "$PATCHELF" ]; then
        local patchelf_variable="PATCHELF_${PATCHELF_VERSION}"
        export PATCHELF=${!patchelf_variable}
    fi
}

#
# setup_vendor
#
# $1: device name
# $2: vendor name
# $3: Android root directory
# $4: is common device - optional, default to false
# $5: cleanup - optional, default to true
# $6: custom vendor makefile name - optional, default to false
#
# Must be called before any other functions can be used. This
# sets up the internal state for a new vendor configuration.
#
function setup_vendor() {
    local DEVICE="$1"
    if [ -z "$DEVICE" ]; then
        echo "\$DEVICE must be set before including this script!"
        exit 1
    fi

    local VENDOR="$2"
    if [ -z "$VENDOR" ]; then
        echo "\$VENDOR must be set before including this script!"
        exit 1
    fi

    export ANDROID_ROOT="$3"
    if [ ! -d "$ANDROID_ROOT" ]; then
        echo "\$ANDROID_ROOT must be set and valid before including this script!"
        exit 1
    fi

    export OUTDIR=vendor/"$VENDOR"/"$DEVICE"
    if [ ! -d "$ANDROID_ROOT/$OUTDIR" ]; then
        mkdir -p "$ANDROID_ROOT/$OUTDIR"
    fi

    VNDNAME="$6"
    if [ -z "$VNDNAME" ]; then
        VNDNAME="$DEVICE"
    fi

    export PRODUCTMK="$ANDROID_ROOT"/"$OUTDIR"/"$VNDNAME"-vendor.mk
    export ANDROIDBP="$ANDROID_ROOT"/"$OUTDIR"/Android.bp
    export ANDROIDMK="$ANDROID_ROOT"/"$OUTDIR"/Android.mk
    export BOARDMK="$ANDROID_ROOT"/"$OUTDIR"/BoardConfigVendor.mk

    if [ "$4" == "true" ] || [ "$4" == "1" ]; then
        COMMON=1
    else
        COMMON=0
    fi

    if [ "$5" == "false" ] || [ "$5" == "0" ]; then
        VENDOR_STATE=1
        VENDOR_RADIO_STATE=1
    else
        VENDOR_STATE=0
        VENDOR_RADIO_STATE=0
    fi

    setup_vendor_deps "$ANDROID_ROOT"
}

# Helper functions for parsing a spec.
# notes: an optional "|SHA1" that may appear in the format is stripped
#        early from the spec in the parse_file_list function, and
#        should not be present inside the input parameter passed
#        to these functions.

#
# input: spec in the form of "src[:dst][;args]"
# output: "src"
#
function src_file() {
    local SPEC="$1"
    local SPLIT=(${SPEC//:/ })
    local ARGS="$(target_args ${SPEC})"
    # Regardless of there being a ":" delimiter or not in the spec,
    # the source file is always either the first, or the only entry.
    local SRC="${SPLIT[0]}"
    # Remove target_args suffix, if present
    echo "${SRC%;${ARGS}}"
}

#
# input: spec in the form of "src[:dst][;args]"
# output: "dst" if present, "src" otherwise.
#
function target_file() {
    local SPEC="${1%%;*}"
    local SPLIT=(${SPEC//:/ })
    local ARGS="$(target_args ${SPEC})"
    local DST=
    case ${#SPLIT[@]} in
    1)
        # The spec doesn't have a : delimiter
        DST="${SPLIT[0]}"
        ;;
    *)
        # The spec actually has a src:dst format
        DST="${SPLIT[1]}"
        ;;
    esac
    # Remove target_args suffix, if present
    echo "${DST%;${ARGS}}"
}

#
# input: spec in the form of "src[:dst][;args]"
# output: "args" if present, "" otherwise.
#
function target_args() {
    local SPEC="$1"
    local SPLIT=(${SPEC//;/ })
    local ARGS=
    case ${#SPLIT[@]} in
    1)
        # No ";" delimiter in the spec.
        ;;
    *)
        # The "args" are whatever comes after the ";" character.
        # Basically the spec stripped of whatever is to the left of ";".
        ARGS="${SPEC#${SPLIT[0]};}"
        ;;
    esac
    echo "${ARGS}"
}

#
# prefix_match:
#
# input:
#   - $1: prefix
#   - (global variable) PRODUCT_PACKAGES_LIST: array of [src:]dst[;args] specs.
# output:
#   - new array consisting of dst[;args] entries where $1 is a prefix of ${dst}.
#
function prefix_match() {
    local PREFIX="$1"
    local NEW_ARRAY=()
    for LINE in "${PRODUCT_PACKAGES_LIST[@]}"; do
        local FILE=$(target_file "$LINE")
        if [[ "$FILE" =~ ^"$PREFIX" ]]; then
            local SPEC_ARGS="${ARGS_LIST[$i - 1]}"
            local ARGS=(${SPEC_ARGS//;/ })
            local FILTERED_ARGS=()

            for ARG in "${ARGS[@]}"; do
                if [[ "$ARG" =~ ^SYMLINK= ]]; then
                    continue
                fi
                FILTERED_ARGS+=("$ARG")
            done

            if [ ${#FILTERED_ARGS[@]} -eq 0 ]; then
                NEW_ARRAY+=("${FILE#"$PREFIX"}")
            else
                NEW_ARRAY+=("${FILE#"$PREFIX"};${FILTERED_ARGS}")
            fi
        fi
    done
    printf '%s\n' "${NEW_ARRAY[@]}" | LC_ALL=C sort
}

#
# prefix_match_file:
#
# $1: the prefix to match on
# $2: the file to match the prefix for
#
# Internal function which returns true if a filename contains the
# specified prefix.
#
function prefix_match_file() {
    local PREFIX="$1"
    local FILE="$2"
    if [[ "$FILE" =~ ^"$PREFIX" ]]; then
        return 0
    else
        return 1
    fi
}

#
# suffix_match_file:
#
# $1: the suffix to match on
# $2: the file to match the suffix for
#
# Internal function which returns true if a filename contains the
# specified suffix.
#
function suffix_match_file() {
    local SUFFIX="$1"
    local FILE="$2"
    if [[ "$FILE" = *"$SUFFIX" ]]; then
        return 0
    else
        return 1
    fi
}

#
# truncate_file
#
# $1: the filename to truncate
# $2: the argument to output the truncated filename to
#
# Internal function which truncates a filename by removing the first dir
# in the path. ex. vendor/lib/libsdmextension.so -> lib/libsdmextension.so
#
function truncate_file() {
    local FILE="$1"
    RETURN_FILE="$2"
    local FIND="${FILE%%/*}"
    local LOCATION="${#FIND}+1"
    echo ${FILE:$LOCATION}
}

#
# write_product_copy_files:
#
# $1: make treble compatible makefile - optional and deprecated, default to true
#
# Creates the PRODUCT_COPY_FILES section in the product makefile for all
# items in the list which do not start with a dash (-).
#
function write_product_copy_files() {
    local COUNT=${#PRODUCT_COPY_FILES_LIST[@]}
    local TARGET=
    local FILE=
    local LINEEND=
    local TREBLE_COMPAT=$1

    if [ "$COUNT" -eq "0" ]; then
        return 0
    fi

    printf '%s\n' "PRODUCT_COPY_FILES += \\" >> "$PRODUCTMK"
    for (( i=1; i<COUNT+1; i++ )); do
        FILE="${PRODUCT_COPY_FILES_LIST[$i-1]}"
        LINEEND=" \\"
        if [ "$i" -eq "$COUNT" ]; then
            LINEEND=""
        fi

        TARGET=$(target_file "$FILE")
        if prefix_match_file "product/" $TARGET ; then
            local OUTTARGET=$(truncate_file $TARGET)
            printf '    %s/proprietary/%s:$(TARGET_COPY_OUT_PRODUCT)/%s%s\n' \
                "$OUTDIR" "$TARGET" "$OUTTARGET" "$LINEEND" >> "$PRODUCTMK"
        elif prefix_match_file "system/product/" $TARGET ; then
            local OUTTARGET=$(truncate_file $TARGET)
            printf '    %s/proprietary/%s:$(TARGET_COPY_OUT_PRODUCT)/%s%s\n' \
                "$OUTDIR" "$TARGET" "$OUTTARGET" "$LINEEND" >> "$PRODUCTMK"
        elif prefix_match_file "system_ext/" $TARGET ; then
            local OUTTARGET=$(truncate_file $TARGET)
            printf '    %s/proprietary/%s:$(TARGET_COPY_OUT_SYSTEM_EXT)/%s%s\n' \
                "$OUTDIR" "$TARGET" "$OUTTARGET" "$LINEEND" >> "$PRODUCTMK"
        elif prefix_match_file "system/system_ext/" $TARGET ; then
            local OUTTARGET=$(truncate_file $TARGET)
            printf '    %s/proprietary/%s:$(TARGET_COPY_OUT_SYSTEM_EXT)/%s%s\n' \
                "$OUTDIR" "$TARGET" "$OUTTARGET" "$LINEEND" >> "$PRODUCTMK"
        elif prefix_match_file "odm/" $TARGET ; then
            local OUTTARGET=$(truncate_file $TARGET)
            printf '    %s/proprietary/%s:$(TARGET_COPY_OUT_ODM)/%s%s\n' \
                "$OUTDIR" "$TARGET" "$OUTTARGET" "$LINEEND" >> "$PRODUCTMK"
        elif prefix_match_file "vendor/odm/" $TARGET ; then
            local OUTTARGET=$(truncate_file $TARGET)
            printf '    %s/proprietary/%s:$(TARGET_COPY_OUT_ODM)/%s%s\n' \
                "$OUTDIR" "$TARGET" "$OUTTARGET" "$LINEEND" >> "$PRODUCTMK"
        elif prefix_match_file "system/vendor/odm/" $TARGET ; then
            local OUTTARGET=$(truncate_file $TARGET)
            printf '    %s/proprietary/%s:$(TARGET_COPY_OUT_ODM)/%s%s\n' \
                "$OUTDIR" "$TARGET" "$OUTTARGET" "$LINEEND" >> "$PRODUCTMK"
        elif prefix_match_file "vendor/" $TARGET ; then
            local OUTTARGET=$(truncate_file $TARGET)
            printf '    %s/proprietary/%s:$(TARGET_COPY_OUT_VENDOR)/%s%s\n' \
                "$OUTDIR" "$TARGET" "$OUTTARGET" "$LINEEND" >> "$PRODUCTMK"
        elif prefix_match_file "vendor_dlkm/" $TARGET ; then
            local OUTTARGET=$(truncate_file $TARGET)
            printf '    %s/proprietary/%s:$(TARGET_COPY_OUT_VENDOR_DLKM)/%s%s\n' \
                "$OUTDIR" "$TARGET" "$OUTTARGET" "$LINEEND" >> "$PRODUCTMK"
        elif prefix_match_file "system/vendor/" $TARGET ; then
            local OUTTARGET=$(truncate_file $TARGET)
            printf '    %s/proprietary/%s:$(TARGET_COPY_OUT_VENDOR)/%s%s\n' \
                "$OUTDIR" "$TARGET" "$OUTTARGET" "$LINEEND" >> "$PRODUCTMK"
        elif prefix_match_file "system/" $TARGET ; then
            local OUTTARGET=$(truncate_file $TARGET)
            printf '    %s/proprietary/%s:$(TARGET_COPY_OUT_SYSTEM)/%s%s\n' \
                "$OUTDIR" "$TARGET" "$OUTTARGET" "$LINEEND" >> "$PRODUCTMK"
        elif prefix_match_file "recovery/" $TARGET ; then
            local OUTTARGET=$(truncate_file $TARGET)
            printf '    %s/proprietary/%s:$(TARGET_COPY_OUT_RECOVERY)/%s%s\n' \
                "$OUTDIR" "$TARGET" "$OUTTARGET" "$LINEEND" >> "$PRODUCTMK"
        elif prefix_match_file "vendor_ramdisk/" $TARGET ; then
            local OUTTARGET=$(truncate_file $TARGET)
            printf '    %s/proprietary/%s:$(TARGET_COPY_OUT_VENDOR_RAMDISK)/%s%s\n' \
                "$OUTDIR" "$TARGET" "$OUTTARGET" "$LINEEND" >> "$PRODUCTMK"
        else
            printf '    %s/proprietary/%s:$(TARGET_COPY_OUT_SYSTEM)/%s%s\n' \
                "$OUTDIR" "$TARGET" "$TARGET" "$LINEEND" >> "$PRODUCTMK"
        fi
    done
    return 0
}

#
# write_blueprint_packages:
#
# $1: The LOCAL_MODULE_CLASS for the given module list
# $2: /system, /odm, /product, /system_ext, or /vendor partition
# $3: type-specific extra flags
# $4: Name of the array holding the target list
#
# Internal function which writes out the BUILD_PREBUILT stanzas
# for all modules in the list. This is called by write_product_packages
# after the modules are categorized.
#
function write_blueprint_packages() {

    local CLASS="$1"
    local PARTITION="$2"
    local EXTRA="$3"

    # Yes, this is a horrible hack - we create a new array using indirection
    local ARR_NAME="$4[@]"
    local FILELIST=("${!ARR_NAME}")

    local FILE=
    local ARGS=
    local BASENAME=
    local EXTENSION=
    local PKGNAME=
    local SRC=
    local STEM=
    local OVERRIDEPKG=
    local REQUIREDPKG=
    local DISABLE_CHECKELF=

    [ "$COMMON" -eq 1 ] && local VENDOR="${VENDOR_COMMON:-$VENDOR}"

    for P in "${FILELIST[@]}"; do
        FILE=$(target_file "$P")
        ARGS=$(target_args "$P")
        ARGS=(${ARGS//;/ })

        BASENAME=$(basename "$FILE")
        DIRNAME=$(dirname "$FILE")
        EXTENSION=${BASENAME##*.}
        PKGNAME=${BASENAME%.*}

        if [ "$CLASS" = "EXECUTABLES" ] && [ "$EXTENSION" != "sh" ]; then
            PKGNAME="$BASENAME"
            EXTENSION=""
        fi

        if [ "$CLASS" = "ETC" ] && [ "$EXTENSION" = "xml" ]; then
            PKGNAME="$BASENAME"
        fi

        # Allow overriding module name
        STEM=
        if [ "$TARGET_ENABLE_CHECKELF" == "true" ]; then
            DISABLE_CHECKELF=
        else
            DISABLE_CHECKELF="true"
        fi
        for ARG in "${ARGS[@]}"; do
            if [[ "$ARG" =~ "MODULE" ]]; then
                STEM="$PKGNAME"
                PKGNAME=${ARG#*=}
            elif [[ "$ARG" == "DISABLE_CHECKELF" ]]; then
                DISABLE_CHECKELF="true"
            fi
        done

        # Add to final package list
        PACKAGE_LIST+=("$PKGNAME")

        SRC="proprietary"
        if [ "$PARTITION" = "system" ]; then
            SRC+="/system"
        elif [ "$PARTITION" = "vendor" ]; then
            SRC+="/vendor"
        elif [ "$PARTITION" = "product" ]; then
            SRC+="/product"
        elif [ "$PARTITION" = "system_ext" ]; then
            SRC+="/system_ext"
        elif [ "$PARTITION" = "odm" ]; then
            SRC+="/odm"
        fi

        if [ "$CLASS" = "SHARED_LIBRARIES" ]; then
            printf 'cc_prebuilt_library_shared {\n'
            printf '\tname: "%s",\n' "$PKGNAME"
            if [ ! -z "$STEM" ]; then
                printf '\tstem: "%s",\n' "$STEM"
            fi
            printf '\towner: "%s",\n' "$VENDOR"
            printf '\tstrip: {\n'
            printf '\t\tnone: true,\n'
            printf '\t},\n'
            printf '\ttarget: {\n'
            if [ "$EXTRA" = "both" ]; then
                printf '\t\tandroid_arm: {\n'
                printf '\t\t\tsrcs: ["%s/lib/%s"],\n' "$SRC" "$FILE"
                if [ -z "$DISABLE_CHECKELF" ]; then
                    printf '\t\t\tshared_libs: [%s],\n' "$(basename -s .so $(${OBJDUMP} -x "$ANDROID_ROOT"/"$OUTDIR"/"$SRC"/lib/"$FILE" 2>/dev/null |grep NEEDED) 2>/dev/null |grep -v ^NEEDED$ |sed 's/-3.9.1//g' |sed 's/\(.*\)/"\1",/g' |tr '\n' ' ')"
                fi
                printf '\t\t},\n'
                printf '\t\tandroid_arm64: {\n'
                printf '\t\t\tsrcs: ["%s/lib64/%s"],\n' "$SRC" "$FILE"
                if [ -z "$DISABLE_CHECKELF" ]; then
                    printf '\t\t\tshared_libs: [%s],\n' "$(basename -s .so $(${OBJDUMP} -x "$ANDROID_ROOT"/"$OUTDIR"/"$SRC"/lib64/"$FILE" 2>/dev/null |grep NEEDED) 2>/dev/null |grep -v ^NEEDED$ |sed 's/-3.9.1//g' |sed 's/\(.*\)/"\1",/g' |tr '\n' ' ')"
                fi
                printf '\t\t},\n'
            elif [ "$EXTRA" = "64" ]; then
                printf '\t\tandroid_arm64: {\n'
                printf '\t\t\tsrcs: ["%s/lib64/%s"],\n' "$SRC" "$FILE"
                if [ -z "$DISABLE_CHECKELF" ]; then
                    printf '\t\t\tshared_libs: [%s],\n' "$(basename -s .so $(${OBJDUMP} -x "$ANDROID_ROOT"/"$OUTDIR"/"$SRC"/lib64/"$FILE" 2>/dev/null |grep NEEDED) 2>/dev/null |grep -v ^NEEDED$ |sed 's/-3.9.1//g' |sed 's/\(.*\)/"\1",/g' |tr '\n' ' ')"
                fi
                printf '\t\t},\n'
            else
                printf '\t\tandroid_arm: {\n'
                printf '\t\t\tsrcs: ["%s/lib/%s"],\n' "$SRC" "$FILE"
                if [ -z "$DISABLE_CHECKELF" ]; then
                    printf '\t\t\tshared_libs: [%s],\n' "$(basename -s .so $(${OBJDUMP} -x "$ANDROID_ROOT"/"$OUTDIR"/"$SRC"/lib/"$FILE" 2>/dev/null |grep NEEDED) 2>/dev/null |grep -v ^NEEDED$ |sed 's/-3.9.1//g' |sed 's/\(.*\)/"\1",/g' |tr '\n' ' ')"
                fi
                printf '\t\t},\n'
            fi
            printf '\t},\n'
            if [ "$EXTRA" != "none" ]; then
                printf '\tcompile_multilib: "%s",\n' "$EXTRA"
            fi
            if [ ! -z "$DISABLE_CHECKELF" ]; then
                printf '\tcheck_elf_files: false,\n'
            fi
        elif [ "$CLASS" = "RFSA" ]; then
            printf 'prebuilt_rfsa {\n'
            printf '\tname: "%s",\n' "$PKGNAME"
            printf '\tfilename: "%s",\n' "$BASENAME"
            printf '\towner: "%s",\n' "$VENDOR"
            printf '\tsrc: "%s/lib/rfsa/%s",\n' "$SRC" "$FILE"
        elif [ "$CLASS" = "APEX" ]; then
            printf 'prebuilt_apex {\n'
            printf '\tname: "%s",\n' "$PKGNAME"
            printf '\towner: "%s",\n' "$VENDOR"
            SRC="$SRC/apex"
            printf '\tsrc: "%s/%s",\n' "$SRC" "$FILE"
            printf '\tfilename: "%s",\n' "$FILE"
        elif [ "$CLASS" = "APPS" ]; then
            printf 'android_app_import {\n'
            printf '\tname: "%s",\n' "$PKGNAME"
            printf '\towner: "%s",\n' "$VENDOR"
            if [ "$EXTRA" = "priv-app" ]; then
                SRC="$SRC/priv-app"
            else
                SRC="$SRC/app"
            fi
            printf '\tapk: "%s/%s",\n' "$SRC" "$FILE"
            USE_PLATFORM_CERTIFICATE="true"
            for ARG in "${ARGS[@]}"; do
                if [ "$ARG" = "PRESIGNED" ]; then
                    USE_PLATFORM_CERTIFICATE="false"
                    printf '\tpreprocessed: true,\n'
                    printf '\tpresigned: true,\n'
                elif [ "$ARG" = "SKIPAPKCHECKS" ]; then
                    printf '\tskip_preprocessed_apk_checks: true,\n'
                elif [[ "$ARG" =~ "OVERRIDES" ]]; then
                    OVERRIDEPKG=${ARG#*=}
                    OVERRIDEPKG=${OVERRIDEPKG//,/\", \"}
                    printf '\toverrides: ["%s"],\n' "$OVERRIDEPKG"
                elif [[ "$ARG" =~ "REQUIRED" ]]; then
                    REQUIREDPKG=${ARG#*=}
                    REQUIRED_PACKAGES_LIST+="$REQUIREDPKG,"
                    printf '\trequired: ["%s"],\n' "${REQUIREDPKG//,/\", \"}"
                elif [[ "$ARG" =~ "SYMLINK" ]]; then
                    continue
                elif [ ! -z "$ARG" ]; then
                    USE_PLATFORM_CERTIFICATE="false"
                    printf '\tcertificate: "%s",\n' "$ARG"
                fi
            done
            if [ "$USE_PLATFORM_CERTIFICATE" = "true" ]; then
                printf '\tcertificate: "platform",\n'
            fi
        elif [ "$CLASS" = "JAVA_LIBRARIES" ]; then
            printf 'dex_import {\n'
            printf '\tname: "%s",\n' "$PKGNAME"
            printf '\towner: "%s",\n' "$VENDOR"
            printf '\tjars: ["%s/framework/%s"],\n' "$SRC" "$FILE"
        elif [ "$CLASS" = "ETC" ]; then
            if [ "$EXTENSION" = "xml" ]; then
                printf 'prebuilt_etc_xml {\n'
            else
                printf 'prebuilt_etc {\n'
            fi
            printf '\tname: "%s",\n' "$PKGNAME"
            printf '\towner: "%s",\n' "$VENDOR"
            printf '\tsrc: "%s/etc/%s",\n' "$SRC" "$FILE"
            printf '\tfilename_from_src: true,\n'
        elif [ "$CLASS" = "EXECUTABLES" ]; then
            if ! objdump -a "$ANDROID_ROOT"/"$OUTDIR"/"$SRC"/bin/"$FILE" 2>/dev/null |grep -c 'file format elf' > /dev/null; then
                # This is not an elf file, assume it's a shell script that doesn't have an extension
                # Setting extension here does not change the target extension, only the module type
                EXTENSION="sh"
            fi
            if [ "$EXTENSION" = "sh" ]; then
                printf 'sh_binary {\n'
            else
                printf 'cc_prebuilt_binary {\n'
            fi
            printf '\tname: "%s",\n' "$PKGNAME"
            printf '\towner: "%s",\n' "$VENDOR"
            if [ "$EXTENSION" != "sh" ]; then
                printf '\ttarget: {\n'
                if objdump -a "$ANDROID_ROOT"/"$OUTDIR"/"$SRC"/bin/"$FILE" |grep -c 'file format elf64' > /dev/null; then
                    printf '\t\tandroid_arm64: {\n'
                else
                    printf '\t\tandroid_arm: {\n'
                fi
                printf '\t\t\tsrcs: ["%s/bin/%s"],\n' "$SRC" "$FILE"
                if [ -z "$DISABLE_CHECKELF" ]; then
                    printf '\t\t\tshared_libs: [%s],\n' "$(basename -s .so $(${OBJDUMP} -x "$ANDROID_ROOT"/"$OUTDIR"/"$SRC"/bin/"$FILE" 2>/dev/null |grep NEEDED) 2>/dev/null |grep -v ^NEEDED$ |sed 's/-3.9.1//g' |sed 's/\(.*\)/"\1",/g' |tr '\n' ' ')"
                fi
                printf '\t\t},\n'
                printf '\t},\n'
                if objdump -a "$ANDROID_ROOT"/"$OUTDIR"/"$SRC"/bin/"$FILE" |grep -c 'file format elf64' > /dev/null; then
                    printf '\tcompile_multilib: "%s",\n' "64"
                else
                    printf '\tcompile_multilib: "%s",\n' "32"
                fi
                if [ ! -z "$DISABLE_CHECKELF" ]; then
                    printf '\tcheck_elf_files: false,\n'
                fi
                printf '\tstrip: {\n'
                printf '\t\tnone: true,\n'
                printf '\t},\n'
                printf '\tprefer: true,\n'
            else
                printf '\tsrc: "%s/bin/%s",\n' "$SRC" "$FILE"
                printf '\tfilename: "%s",\n' "$BASENAME"
            fi
        else
            printf '\tsrcs: ["%s/%s"],\n' "$SRC" "$FILE"
        fi
        if [ "$CLASS" = "APPS" ]; then
            printf '\tdex_preopt: {\n'
            printf '\t\tenabled: false,\n'
            printf '\t},\n'
        fi
        if [ "$CLASS" = "SHARED_LIBRARIES" ] || [ "$CLASS" = "EXECUTABLES" ] || [ "$CLASS" = "RFSA" ] ; then
            if [ "$DIRNAME" != "." ]; then
                if [ "$EXTENSION" = "sh" ]; then
                    printf '\tsub_dir: "%s",\n' "$DIRNAME"
                else
                    printf '\trelative_install_path: "%s",\n' "$DIRNAME"
                fi
            fi
        fi
        if [ "$CLASS" = "ETC" ] ; then
            if [ "$DIRNAME" != "." ]; then
                printf '\tsub_dir: "%s",\n' "$DIRNAME"
            fi
        fi
        if [ "$CLASS" = "SHARED_LIBRARIES" ]; then
            printf '\tprefer: true,\n'
        fi
        if [ "$EXTRA" = "priv-app" ]; then
            printf '\tprivileged: true,\n'
        fi
        if [ "$PARTITION" = "vendor" ]; then
            printf '\tsoc_specific: true,\n'
        elif [ "$PARTITION" = "product" ]; then
            printf '\tproduct_specific: true,\n'
        elif [ "$PARTITION" = "system_ext" ]; then
            printf '\tsystem_ext_specific: true,\n'
        elif [ "$PARTITION" = "odm" ]; then
            printf '\tdevice_specific: true,\n'
        fi
        printf '}\n\n'
    done
}

#
# write_product_packages:
#
# This function will create prebuilt entries in the
# Android.bp and associated PRODUCT_PACKAGES list in the
# product makefile for all files in the blob list which
# start with a single dash (-) character.
#
function write_product_packages() {
    PACKAGE_LIST=()

    # Sort the package list for comm
    PRODUCT_PACKAGES_LIST=($( printf '%s\n' "${PRODUCT_PACKAGES_LIST[@]}" | LC_ALL=C sort))

    local COUNT=${#PRODUCT_PACKAGES_LIST[@]}

    if [ "$COUNT" = "0" ]; then
        return 0
    fi

    # Figure out what's 32-bit, what's 64-bit, and what's multilib
    # I really should not be doing this in bash due to shitty array passing :(
    local T_LIB32=( $(prefix_match "lib/") )
    local T_LIB64=( $(prefix_match "lib64/") )
    local MULTILIBS=( $(LC_ALL=C comm -12 <(printf '%s\n' "${T_LIB32[@]}") <(printf '%s\n' "${T_LIB64[@]}")) )
    local LIB32=( $(LC_ALL=C comm -23 <(printf '%s\n'  "${T_LIB32[@]}") <(printf '%s\n' "${MULTILIBS[@]}")) )
    local LIB64=( $(LC_ALL=C comm -23 <(printf '%s\n' "${T_LIB64[@]}") <(printf '%s\n' "${MULTILIBS[@]}")) )

    if [ "${#MULTILIBS[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "" "both" "MULTILIBS" >> "$ANDROIDBP"
    fi
    if [ "${#LIB32[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "" "32" "LIB32" >> "$ANDROIDBP"
    fi
    if [ "${#LIB64[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "" "64" "LIB64" >> "$ANDROIDBP"
    fi

    local T_S_LIB32=( $(prefix_match "system/lib/") )
    local T_S_LIB64=( $(prefix_match "system/lib64/") )
    local S_MULTILIBS=( $(LC_ALL=C comm -12 <(printf '%s\n' "${T_S_LIB32[@]}") <(printf '%s\n' "${T_S_LIB64[@]}")) )
    local S_LIB32=( $(LC_ALL=C comm -23 <(printf '%s\n'  "${T_S_LIB32[@]}") <(printf '%s\n' "${S_MULTILIBS[@]}")) )
    local S_LIB64=( $(LC_ALL=C comm -23 <(printf '%s\n' "${T_S_LIB64[@]}") <(printf '%s\n' "${S_MULTILIBS[@]}")) )

    if [ "${#S_MULTILIBS[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "system" "both" "S_MULTILIBS" >> "$ANDROIDBP"
    fi
    if [ "${#S_LIB32[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "system" "32" "S_LIB32" >> "$ANDROIDBP"
    fi
    if [ "${#S_LIB64[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "system" "64" "S_LIB64" >> "$ANDROIDBP"
    fi

    local T_V_LIB32=( $(prefix_match "vendor/lib/") )
    local T_V_LIB64=( $(prefix_match "vendor/lib64/") )
    local V_RFSA=( $(prefix_match "vendor/lib/rfsa/") )
    local V_MULTILIBS=( $(LC_ALL=C comm -12 <(printf '%s\n' "${T_V_LIB32[@]}") <(printf '%s\n' "${T_V_LIB64[@]}")) )
    local V_LIB32=( $(LC_ALL=C comm -23 <(printf '%s\n' "${T_V_LIB32[@]}") <(printf '%s\n' "${V_MULTILIBS[@]}")) )
    local V_LIB32=( $(LC_ALL=C grep -v 'rfsa/' <(printf '%s\n' "${V_LIB32[@]}")) )
    local V_LIB64=( $(LC_ALL=C comm -23 <(printf '%s\n' "${T_V_LIB64[@]}") <(printf '%s\n' "${V_MULTILIBS[@]}")) )

    if [ "${#V_MULTILIBS[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "vendor" "both" "V_MULTILIBS" >> "$ANDROIDBP"
    fi
    if [ "${#V_LIB32[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "vendor" "32" "V_LIB32" >> "$ANDROIDBP"
    fi
    if [ "${#V_LIB64[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "vendor" "64" "V_LIB64" >> "$ANDROIDBP"
    fi
    if [ "${#V_RFSA[@]}" -gt "0" ]; then
        write_blueprint_packages "RFSA" "vendor" "" "V_RFSA" >> "$ANDROIDBP"
    fi

    local T_P_LIB32=( $(prefix_match "product/lib/") )
    local T_P_LIB64=( $(prefix_match "product/lib64/") )
    local P_MULTILIBS=( $(LC_ALL=C comm -12 <(printf '%s\n' "${T_P_LIB32[@]}") <(printf '%s\n' "${T_P_LIB64[@]}")) )
    local P_LIB32=( $(LC_ALL=C comm -23 <(printf '%s\n' "${T_P_LIB32[@]}") <(printf '%s\n' "${P_MULTILIBS[@]}")) )
    local P_LIB64=( $(LC_ALL=C comm -23 <(printf '%s\n' "${T_P_LIB64[@]}") <(printf '%s\n' "${P_MULTILIBS[@]}")) )

    if [ "${#P_MULTILIBS[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "product" "both" "P_MULTILIBS" >> "$ANDROIDBP"
    fi
    if [ "${#P_LIB32[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "product" "32" "P_LIB32" >> "$ANDROIDBP"
    fi
    if [ "${#P_LIB64[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "product" "64" "P_LIB64" >> "$ANDROIDBP"
    fi

    local T_SE_LIB32=( $(prefix_match "system_ext/lib/") )
    local T_SE_LIB64=( $(prefix_match "system_ext/lib64/") )
    local SE_MULTILIBS=( $(LC_ALL=C comm -12 <(printf '%s\n' "${T_SE_LIB32[@]}") <(printf '%s\n' "${T_SE_LIB64[@]}")) )
    local SE_LIB32=( $(LC_ALL=C comm -23 <(printf '%s\n' "${T_SE_LIB32[@]}") <(printf '%s\n' "${SE_MULTILIBS[@]}")) )
    local SE_LIB64=( $(LC_ALL=C comm -23 <(printf '%s\n' "${T_SE_LIB64[@]}") <(printf '%s\n' "${SE_MULTILIBS[@]}")) )

    if [ "${#SE_MULTILIBS[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "system_ext" "both" "SE_MULTILIBS" >> "$ANDROIDBP"
    fi
    if [ "${#SE_LIB32[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "system_ext" "32" "SE_LIB32" >> "$ANDROIDBP"
    fi
    if [ "${#SE_LIB64[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "system_ext" "64" "SE_LIB64" >> "$ANDROIDBP"
    fi

    local T_O_LIB32=( $(prefix_match "odm/lib/") )
    local T_O_LIB64=( $(prefix_match "odm/lib64/") )
    local O_MULTILIBS=( $(LC_ALL=C comm -12 <(printf '%s\n' "${T_O_LIB32[@]}") <(printf '%s\n' "${T_O_LIB64[@]}")) )
    local O_LIB32=( $(LC_ALL=C comm -23 <(printf '%s\n' "${T_O_LIB32[@]}") <(printf '%s\n' "${O_MULTILIBS[@]}")) )
    local O_LIB64=( $(LC_ALL=C comm -23 <(printf '%s\n' "${T_O_LIB64[@]}") <(printf '%s\n' "${O_MULTILIBS[@]}")) )

    if [ "${#O_MULTILIBS[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "odm" "both" "O_MULTILIBS" >> "$ANDROIDBP"
    fi
    if [ "${#O_LIB32[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "odm" "32" "O_LIB32" >> "$ANDROIDBP"
    fi
    if [ "${#O_LIB64[@]}" -gt "0" ]; then
        write_blueprint_packages "SHARED_LIBRARIES" "odm" "64" "O_LIB64" >> "$ANDROIDBP"
    fi

    # APEX
    local APEX=( $(prefix_match "apex/") )
    if [ "${#APEX[@]}" -gt "0" ]; then
        write_blueprint_packages "APEX" "" "" "APEX" >> "$ANDROIDBP"
    fi
    local S_APEX=( $(prefix_match "system/apex/") )
    if [ "${#S_APEX[@]}" -gt "0" ]; then
        write_blueprint_packages "APEX" "system" "" "S_APEX" >> "$ANDROIDBP"
    fi
    local V_APEX=( $(prefix_match "vendor/apex/") )
    if [ "${#V_APEX[@]}" -gt "0" ]; then
        write_blueprint_packages "APEX" "vendor" "" "V_APEX" >> "$ANDROIDBP"
    fi
    local SE_APEX=( $(prefix_match "system_ext/apex/") )
    if [ "${#SE_APEX[@]}" -gt "0" ]; then
        write_blueprint_packages "APEX" "system_ext" "" "SE_APEX" >> "$ANDROIDBP"
    fi

    # Apps
    local APPS=( $(prefix_match "app/") )
    if [ "${#APPS[@]}" -gt "0" ]; then
        write_blueprint_packages "APPS" "" "" "APPS" >> "$ANDROIDBP"
    fi
    local PRIV_APPS=( $(prefix_match "priv-app/") )
    if [ "${#PRIV_APPS[@]}" -gt "0" ]; then
        write_blueprint_packages "APPS" "" "priv-app" "PRIV_APPS" >> "$ANDROIDBP"
    fi
    local S_APPS=( $(prefix_match "system/app/") )
    if [ "${#S_APPS[@]}" -gt "0" ]; then
        write_blueprint_packages "APPS" "system" "" "S_APPS" >> "$ANDROIDBP"
    fi
    local S_PRIV_APPS=( $(prefix_match "system/priv-app/") )
    if [ "${#S_PRIV_APPS[@]}" -gt "0" ]; then
        write_blueprint_packages "APPS" "system" "priv-app" "S_PRIV_APPS" >> "$ANDROIDBP"
    fi
    local V_APPS=( $(prefix_match "vendor/app/") )
    if [ "${#V_APPS[@]}" -gt "0" ]; then
        write_blueprint_packages "APPS" "vendor" "" "V_APPS" >> "$ANDROIDBP"
    fi
    local V_PRIV_APPS=( $(prefix_match "vendor/priv-app/") )
    if [ "${#V_PRIV_APPS[@]}" -gt "0" ]; then
        write_blueprint_packages "APPS" "vendor" "priv-app" "V_PRIV_APPS" >> "$ANDROIDBP"
    fi
    local P_APPS=( $(prefix_match "product/app/") )
    if [ "${#P_APPS[@]}" -gt "0" ]; then
        write_blueprint_packages "APPS" "product" "" "P_APPS" >> "$ANDROIDBP"
    fi
    local P_PRIV_APPS=( $(prefix_match "product/priv-app/") )
    if [ "${#P_PRIV_APPS[@]}" -gt "0" ]; then
        write_blueprint_packages "APPS" "product" "priv-app" "P_PRIV_APPS" >> "$ANDROIDBP"
    fi
    local SE_APPS=( $(prefix_match "system_ext/app/") )
    if [ "${#SE_APPS[@]}" -gt "0" ]; then
        write_blueprint_packages "APPS" "system_ext" "" "SE_APPS" >> "$ANDROIDBP"
    fi
    local SE_PRIV_APPS=( $(prefix_match "system_ext/priv-app/") )
    if [ "${#SE_PRIV_APPS[@]}" -gt "0" ]; then
        write_blueprint_packages "APPS" "system_ext" "priv-app" "SE_PRIV_APPS" >> "$ANDROIDBP"
    fi
    local O_APPS=( $(prefix_match "odm/app/") )
    if [ "${#O_APPS[@]}" -gt "0" ]; then
        write_blueprint_packages "APPS" "odm" "" "O_APPS" >> "$ANDROIDBP"
    fi
    local O_PRIV_APPS=( $(prefix_match "odm/priv-app/") )
    if [ "${#O_PRIV_APPS[@]}" -gt "0" ]; then
        write_blueprint_packages "APPS" "odm" "priv-app" "O_PRIV_APPS" >> "$ANDROIDBP"
    fi

    # Framework
    local FRAMEWORK=( $(prefix_match "framework/") )
    if [ "${#FRAMEWORK[@]}" -gt "0" ]; then
        write_blueprint_packages "JAVA_LIBRARIES" "" "" "FRAMEWORK" >> "$ANDROIDBP"
    fi
    local S_FRAMEWORK=( $(prefix_match "system/framework/") )
    if [ "${#S_FRAMEWORK[@]}" -gt "0" ]; then
        write_blueprint_packages "JAVA_LIBRARIES" "system" "" "S_FRAMEWORK" >> "$ANDROIDBP"
    fi
    local V_FRAMEWORK=( $(prefix_match "vendor/framework/") )
    if [ "${#V_FRAMEWORK[@]}" -gt "0" ]; then
        write_blueprint_packages "JAVA_LIBRARIES" "vendor" "" "V_FRAMEWORK" >> "$ANDROIDBP"
    fi
    local P_FRAMEWORK=( $(prefix_match "product/framework/") )
    if [ "${#P_FRAMEWORK[@]}" -gt "0" ]; then
        write_blueprint_packages "JAVA_LIBRARIES" "product" "" "P_FRAMEWORK" >> "$ANDROIDBP"
    fi
    local SE_FRAMEWORK=( $(prefix_match "system_ext/framework/") )
    if [ "${#SE_FRAMEWORK[@]}" -gt "0" ]; then
        write_blueprint_packages "JAVA_LIBRARIES" "system_ext" "" "SE_FRAMEWORK" >> "$ANDROIDBP"
    fi
    local O_FRAMEWORK=( $(prefix_match "odm/framework/") )
    if [ "${#O_FRAMEWORK[@]}" -gt "0" ]; then
        write_blueprint_packages "JAVA_LIBRARIES" "odm" "" "O_FRAMEWORK" >> "$ANDROIDBP"
    fi

    # Etc
    local ETC=( $(prefix_match "etc/") )
    if [ "${#ETC[@]}" -gt "0" ]; then
        write_blueprint_packages "ETC" "" "" "ETC" >> "$ANDROIDBP"
    fi
    local S_ETC=( $(prefix_match "system/etc/") )
    if [ "${#S_ETC[@]}" -gt "0" ]; then
        write_blueprint_packages "ETC" "system" "" "S_ETC" >> "$ANDROIDBP"
    fi
    local V_ETC=( $(prefix_match "vendor/etc/") )
    if [ "${#V_ETC[@]}" -gt "0" ]; then
        write_blueprint_packages "ETC" "vendor" "" "V_ETC" >> "$ANDROIDBP"
    fi
    local P_ETC=( $(prefix_match "product/etc/") )
    if [ "${#P_ETC[@]}" -gt "0" ]; then
        write_blueprint_packages "ETC" "product" "" "P_ETC" >> "$ANDROIDBP"
    fi
    local SE_ETC=( $(prefix_match "system_ext/etc/") )
    if [ "${#SE_ETC[@]}" -gt "0" ]; then
        write_blueprint_packages "ETC" "system_ext" "" "SE_ETC" >> "$ANDROIDBP"
    fi
    local O_ETC=( $(prefix_match "odm/etc/") )
    if [ "${#O_ETC[@]}" -gt "0" ]; then
        write_blueprint_packages "ETC" "odm" "" "O_ETC" >> "$ANDROIDBP"
    fi

    # Executables
    local BIN=( $(prefix_match "bin/") )
    if [ "${#BIN[@]}" -gt "0"  ]; then
        write_blueprint_packages "EXECUTABLES" "" "" "BIN" >> "$ANDROIDBP"
    fi
    local S_BIN=( $(prefix_match "system/bin/") )
    if [ "${#S_BIN[@]}" -gt "0"  ]; then
        write_blueprint_packages "EXECUTABLES" "system" "" "S_BIN" >> "$ANDROIDBP"
    fi
    local V_BIN=( $(prefix_match "vendor/bin/") )
    if [ "${#V_BIN[@]}" -gt "0" ]; then
        write_blueprint_packages "EXECUTABLES" "vendor" "" "V_BIN" >> "$ANDROIDBP"
    fi
    local P_BIN=( $(prefix_match "product/bin/") )
    if [ "${#P_BIN[@]}" -gt "0" ]; then
        write_blueprint_packages "EXECUTABLES" "product" "" "P_BIN" >> "$ANDROIDBP"
    fi
    local SE_BIN=( $(prefix_match "system_ext/bin/") )
    if [ "${#SE_BIN[@]}" -gt "0" ]; then
        write_blueprint_packages "EXECUTABLES" "system_ext" "" "SE_BIN" >> "$ANDROIDBP"
    fi
    local O_BIN=( $(prefix_match "odm/bin/") )
    if [ "${#O_BIN[@]}" -gt "0" ]; then
        write_blueprint_packages "EXECUTABLES" "odm" "" "O_BIN" >> "$ANDROIDBP"
    fi

    write_package_definition "${PACKAGE_LIST[@]}" >> "$PRODUCTMK"
}


#
# write_symlink_packages:
#
# Creates symlink entries in the Android.bp and related PRODUCT_PACKAGES
# list in the product makefile for all files in the blob list which has
# SYMLINK argument.
#
function write_symlink_packages() {
    local FILE=
    local ARGS=
    local ARCH=
    local BASENAME=
    local PKGNAME=
    local PREFIX=
    local SYMLINK_BASENAME=
    local SYMLINK_PACKAGES=()

    # Sort the symlinks list for comm
    PRODUCT_SYMLINKS_LIST=($( printf '%s\n' "${PRODUCT_SYMLINKS_LIST[@]}" | LC_ALL=C sort))

    local COUNT=${#PRODUCT_SYMLINKS_LIST[@]}

    if [ "$COUNT" = "0" ]; then
        return 0
    fi

    for LINE in "${PRODUCT_SYMLINKS_LIST[@]}"; do
        FILE=$(target_file "$LINE")
        if [[ "$LINE" =~ '/lib64/' || "$LINE" =~ '/lib/arm64/' ]]; then
            ARCH="64"
        elif [[ "$LINE" =~ '/lib/' ]]; then
            ARCH="32"
        fi
        BASENAME=$(basename "$FILE")
        ARGS=$(target_args "$LINE")
        ARGS=(${ARGS//;/ })
        for ARG in "${ARGS[@]}"; do
            if [[ "$ARG" =~ "SYMLINK" ]]; then
                SYMLINKS=${ARG#*=}
                SYMLINKS=(${SYMLINKS//,/ })
                for SYMLINK in "${SYMLINKS[@]}"; do
                    SYMLINK_BASENAME=$(basename "$SYMLINK")
                    PKGNAME="${BASENAME%.*}_${SYMLINK_BASENAME%.*}_symlink${ARCH}"
                    if [[ "${SYMLINK_PACKAGES[@]}" =~ "$PKGNAME" ]]; then
                        PKGNAME+="_$(grep -o "$PKGNAME" <<< ${SYMLINK_PACKAGES[*]} | wc -l)"
                    fi
                    {
                        printf 'install_symlink {\n'
                        printf '\tname: "%s",\n' "$PKGNAME"
                        if prefix_match_file "vendor/" "$SYMLINK"; then
                            PREFIX='vendor/'
                            printf '\tsoc_specific: true,\n'
                        elif prefix_match_file "product/" "$SYMLINK"; then
                            PREFIX='product/'
                            printf '\tproduct_specific: true,\n'
                        elif prefix_match_file "system_ext/" "$SYMLINK"; then
                            PREFIX='system_ext/'
                            printf '\tsystem_ext_specific: true,\n'
                        elif prefix_match_file "odm/" "$SYMLINK"; then
                            PREFIX='odm/'
                            printf '\tdevice_specific: true,\n'
                        fi
                        printf '\tinstalled_location: "%s",\n' "${SYMLINK#"$PREFIX"}"
                        printf '\tsymlink_target: "/%s",\n' "$FILE"
                        printf '}\n\n'
                    } >> "$ANDROIDBP"
                    SYMLINK_PACKAGES+=("$PKGNAME")
                done
            fi
        done
    done

    write_package_definition "${SYMLINK_PACKAGES[@]}" >> "$PRODUCTMK"
}

#
# write_single_product_copy_files:
#
# $1: the file to be copied
#
# Creates a PRODUCT_COPY_FILES section in the product makefile for the
# item provided in $1.
#
function write_single_product_copy_files() {
    local FILE="$1"
    if [ -z "$FILE" ]; then
        echo "A file must be provided to write_single_product_copy_files()!"
        exit 1
    fi

    local TARGET=$(target_file "$FILE")
    local OUTTARGET=$(truncate_file $TARGET)

    printf '%s\n' "PRODUCT_COPY_FILES += \\" >> "$PRODUCTMK"
    printf '    %s/proprietary/%s:$(TARGET_COPY_OUT_PRODUCT)/%s\n' \
        "$OUTDIR" "$TARGET" "$OUTTARGET" >> "$PRODUCTMK"
}

#
# write_single_product_packages:
#
# $1: the package to be built
#
# Creates a PRODUCT_PACKAGES section in the product makefile for the
# item provided in $1.
#
function write_single_product_packages() {
    local PACKAGE="$1"
    if [ -z "$PACKAGE" ]; then
        echo "A package must be provided to write_single_product_packages()!"
        exit 1
    fi

    printf '\n%s\n' "PRODUCT_PACKAGES += \\" >> "$PRODUCTMK"
    printf '    %s%s\n' "$PACKAGE" >> "$PRODUCTMK"
}

#
# write_rro_androidmanifest:
#
# $2: target package for the RRO overlay
#
# Creates an AndroidManifest.xml for an RRO overlay.
#
function write_rro_androidmanifest() {
    local TARGET_PACKAGE="$1"

    cat << EOF
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="$TARGET_PACKAGE.vendor"
    android:versionCode="1"
    android:versionName="1.0">
    <application android:hasCode="false" />
    <overlay
        android:targetPackage="$TARGET_PACKAGE"
        android:isStatic="true"
        android:priority="0"/>
</manifest>
EOF
}

#
# write_rro_blueprint:
#
# $1: package name for the RRO overlay
# $2: target partition for the RRO overlay
#
# Creates an Android.bp for an RRO overlay.
#
function write_rro_blueprint() {
    local PKGNAME="$1"
    local PARTITION="$2"

    printf 'runtime_resource_overlay {\n'
    printf '\tname: "%s",\n' "$PKGNAME"
    printf '\ttheme: "%s",\n' "$PKGNAME"
    printf '\tsdk_version: "%s",\n' "current"
    printf '\taaptflags: ["%s"],\n' "--keep-raw-values"

    if [ "$PARTITION" = "vendor" ]; then
        printf '\tsoc_specific: true,\n'
    elif [ "$PARTITION" = "product" ]; then
        printf '\tproduct_specific: true,\n'
    elif [ "$PARTITION" = "system_ext" ]; then
        printf '\tsystem_ext_specific: true,\n'
    elif [ "$PARTITION" = "odm" ]; then
        printf '\tdevice_specific: true,\n'
    fi
    printf '}\n'
}

#
# write_blueprint_header:
#
# $1: file which will be written to
#
# writes out the warning message regarding manual file modifications.
# note that this is not an append operation, and should
# be executed first!
#
function write_blueprint_header() {
    if [ -f $1 ]; then
        rm $1
    fi

    [ "$COMMON" -eq 1 ] && local DEVICE="$DEVICE_COMMON"
    [ "$COMMON" -eq 1 ] && local VENDOR="${VENDOR_COMMON:-$VENDOR}"

    cat << EOF >> $1
// Automatically generated file. DO NOT MODIFY
//
// This file is generated by device/$VENDOR/$DEVICE/setup-makefiles.sh

EOF
}

#
# write_makefile_header:
#
# $1: file which will be written to
#
# writes out the warning message regarding manual file modifications.
# note that this is not an append operation, and should
# be executed first!
#
function write_makefile_header() {
    if [ -f $1 ]; then
        rm $1
    fi

    [ "$COMMON" -eq 1 ] && local DEVICE="$DEVICE_COMMON"
    [ "$COMMON" -eq 1 ] && local VENDOR="${VENDOR_COMMON:-$VENDOR}"

    cat << EOF >> $1
# Automatically generated file. DO NOT MODIFY
#
# This file is generated by device/$VENDOR/$DEVICE/setup-makefiles.sh

EOF
}

#
# write_xml_header:
#
# $1: file which will be written to
#
# writes out the warning message regarding manual file modifications.
# note that this is not an append operation, and should
# be executed first!
#
function write_xml_header() {
    if [ -f $1 ]; then
        rm $1
    fi

    [ "$COMMON" -eq 1 ] && local DEVICE="$DEVICE_COMMON"
    [ "$COMMON" -eq 1 ] && local VENDOR="${VENDOR_COMMON:-$VENDOR}"

    cat << EOF >> $1
<?xml version="1.0" encoding="utf-8"?>
<!--
    Automatically generated file. DO NOT MODIFY

    This file is generated by device/$VENDOR/$DEVICE/setup-makefiles.sh
-->
EOF
}

#
# write_rro_package:
#
# $1: the RRO package name
# $2: the RRO target package
# $3: the partition for the RRO overlay
#
# Generates the file structure for an RRO overlay.
#
function write_rro_package() {
    local PKGNAME="$1"
    if [ -z "$PKGNAME" ]; then
        echo "A package name must be provided to write_rro_package()!"
        exit 1
    fi

    local TARGET_PACKAGE="$2"
    if [ -z "$TARGET_PACKAGE" ]; then
        echo "A target package must be provided to write_rro_package()!"
        exit 1
    fi

    local PARTITION="$3"
    if [ -z "$PARTITION" ]; then
        PARTITION="vendor"
    fi

    local RROBP="$ANDROID_ROOT"/"$OUTDIR"/rro_overlays/"$PKGNAME"/Android.bp
    local RROMANIFEST="$ANDROID_ROOT"/"$OUTDIR"/rro_overlays/"$PKGNAME"/AndroidManifest.xml

    write_blueprint_header "$RROBP"
    write_xml_header "$RROMANIFEST"

    write_rro_blueprint "$PKGNAME" "$PARTITION" >> "$RROBP"
    write_rro_androidmanifest "$TARGET_PACKAGE" >> "$RROMANIFEST"
}

#
# write_package_definition:
#
# $@: list of packages
#
# writes out the final PRODUCT_PACKAGES list
#
function write_package_definition() {
    local PACKAGE_LIST=("${@}")
    local PACKAGE_COUNT=${#PACKAGE_LIST[@]}

    if [ "$PACKAGE_COUNT" -eq "0" ]; then
        return 0
    fi

    printf '\n%s\n' "PRODUCT_PACKAGES += \\"
    for (( i=1; i<PACKAGE_COUNT+1; i++ )); do
        local SKIP=false
        local LINEEND=" \\"
        if [ "$i" -eq "$PACKAGE_COUNT" ]; then
            LINEEND=""
        fi
        for PKG in $(tr "," "\n" <<< "$REQUIRED_PACKAGES_LIST"); do
            if [[ $PKG == "${PACKAGE_LIST[$i - 1]}" ]]; then
                SKIP=true
                break
            fi
        done
        # Skip adding of the package to product makefile if it's in the required list
        if [[ $SKIP == false ]]; then
            printf '    %s%s\n' "${PACKAGE_LIST[$i - 1]}" "$LINEEND" >> "$PRODUCTMK"
        fi
    done
}

#
# write_headers:
#
# $1: devices falling under common to be added to guard - optional
# $2: custom guard - optional
#
# Calls write_makefile_header for each of the makefiles and
# write_blueprint_header for Android.bp and creates the initial
# path declaration and device guard for the Android.mk
#
function write_headers() {
    write_makefile_header "$ANDROIDMK"

    GUARD="$2"
    if [ -z "$GUARD" ]; then
        GUARD="TARGET_DEVICE"
    fi

    cat << EOF >> "$ANDROIDMK"
LOCAL_PATH := \$(call my-dir)

EOF
    if [ "$COMMON" -ne 1 ]; then
        cat << EOF >> "$ANDROIDMK"
ifeq (\$($GUARD),$DEVICE)

EOF
    else
        if [ -z "$1" ]; then
            echo "Argument with devices to be added to guard must be set!"
            exit 1
        fi
        cat << EOF >> "$ANDROIDMK"
ifneq (\$(filter $1,\$($GUARD)),)

EOF
    fi

    write_makefile_header "$BOARDMK"
    write_makefile_header "$PRODUCTMK"
    write_blueprint_header "$ANDROIDBP"

    cat << EOF >> "$ANDROIDBP"
soong_namespace {
	imports: [
EOF

    if [ ! -z "$DEVICE_COMMON" -a "$COMMON" -ne 1 ]; then
        cat << EOF >> "$ANDROIDBP"
		"vendor/${VENDOR_COMMON:-$VENDOR}/$DEVICE_COMMON",
EOF
    fi
    vendor_imports "$ANDROIDBP"

    cat << EOF >> "$ANDROIDBP"
	],
}

EOF

    [ "$COMMON" -eq 1 ] && local DEVICE="$DEVICE_COMMON"
    [ "$COMMON" -eq 1 ] && local VENDOR="${VENDOR_COMMON:-$VENDOR}"
    cat << EOF >> "$PRODUCTMK"
PRODUCT_SOONG_NAMESPACES += \\
    vendor/$VENDOR/$DEVICE

EOF
}

#
# write_footers:
#
# Closes the inital guard and any other finalization tasks. Must
# be called as the final step.
#
function write_footers() {
    cat << EOF >> "$ANDROIDMK"
endif
EOF
}

# Return success if adb is up and not in recovery
function _adb_connected {
    {
        if [[ "$(adb get-state)" == device ]]
        then
            return 0
        fi
    } 2>/dev/null

    return 1
};

#
# parse_file_list:
#
# $1: input file
# $2: blob section in file - optional
#
# Sets PRODUCT_PACKAGES and PRODUCT_COPY_FILES while parsing the input file
#
function parse_file_list() {
    if [ -z "$1" ]; then
        echo "An input file is expected!"
        exit 1
    elif [ ! -f "$1" ]; then
        echo "Input file "$1" does not exist!"
        exit 1
    fi

    if [ -n "$2" ]; then
        echo "Using section \"$2\""
        LIST=$EXTRACT_TMP_DIR/files.txt
        # Match all lines starting with first line found to start* with '#'
        # comment and contain** $2, and ending with first line to be empty*.
        # *whitespaces (tabs, spaces) at the beginning of lines are discarded
        # **the $2 match is case-insensitive
        cat $1 | sed -n '/^[[:space:]]*#.*'"$2"'/I,/^[[:space:]]*$/ p' > $LIST
    else
        LIST=$1
    fi

    PRODUCT_PACKAGES_LIST=()
    PRODUCT_PACKAGES_HASHES=()
    PRODUCT_PACKAGES_FIXUP_HASHES=()
    PRODUCT_SYMLINKS_LIST=()
    PRODUCT_COPY_FILES_LIST=()
    PRODUCT_COPY_FILES_HASHES=()
    PRODUCT_COPY_FILES_FIXUP_HASHES=()

    while read -r line; do
        if [ -z "$line" ]; then continue; fi

        # If the line has a pipe delimiter, a sha1 hash should follow.
        # This indicates the file should be pinned and not overwritten
        # when extracting files.
        local SPLIT=(${line//\|/ })
        local COUNT=${#SPLIT[@]}
        local SPEC=${SPLIT[0]}
        local HASH="x"
        local FIXUP_HASH="x"
        if [ "$COUNT" -gt "1" ]; then
            HASH=${SPLIT[1]}
        fi
        if [ "$COUNT" -gt "2" ]; then
            FIXUP_HASH=${SPLIT[2]}
        fi
        if [[ "$SPEC" =~ 'SYMLINK=' ]]; then
            PRODUCT_SYMLINKS_LIST+=("${SPEC#-}")
        fi
        # if line starts with a dash, it needs to be packaged
        if [[ "$SPEC" =~ ^- ]]; then
            PRODUCT_PACKAGES_LIST+=("${SPEC#-}")
            PRODUCT_PACKAGES_HASHES+=("$HASH")
            PRODUCT_PACKAGES_FIXUP_HASHES+=("$FIXUP_HASH")
        # if line contains apex, apk, jar or vintf fragment, it needs to be packaged
        elif suffix_match_file ".apex" "$(src_file "$SPEC")" || \
             suffix_match_file ".apk" "$(src_file "$SPEC")" || \
             suffix_match_file ".jar" "$(src_file "$SPEC")" || \
             [[ "$TARGET_ENABLE_CHECKELF" == "true" && \
                ( "${SPEC%%;*}" == *".so" || \
                  "$SPEC" == *"bin/"* || \
                  "$SPEC" == *"lib/rfsa"* ) ]] || \
             [[ "$SPEC" == *"etc/vintf/manifest/"* ]]; then
            PRODUCT_PACKAGES_LIST+=("$SPEC")
            PRODUCT_PACKAGES_HASHES+=("$HASH")
            PRODUCT_PACKAGES_FIXUP_HASHES+=("$FIXUP_HASH")
        else
            PRODUCT_COPY_FILES_LIST+=("$SPEC")
            PRODUCT_COPY_FILES_HASHES+=("$HASH")
            PRODUCT_COPY_FILES_FIXUP_HASHES+=("$FIXUP_HASH")
        fi

    done < <(grep -v -E '(^#|^[[:space:]]*$)' "$LIST" | LC_ALL=C sort | uniq)
}

#
# write_makefiles:
#
# $1: file containing the list of items to extract
# $2: make treble compatible makefile - optional
#
# Calls write_product_copy_files, write_product_packages and
# lastly write_symlink_packages on the given file and appends
# to the Android.bp as well as the product makefile.
#
function write_makefiles() {
    parse_file_list "$1"
    write_product_copy_files "$2"
    write_product_packages
    write_symlink_packages
}

#
# append_firmware_calls_to_makefiles:
#
# $1: file containing the list of items to extract
#
# Appends the calls to all images present in radio folder to Android.mk
# and radio AB_OTA_PARTITIONS to BoardConfigVendor.mk
#
function append_firmware_calls_to_makefiles() {
    parse_file_list "$1"

    local FILELIST=(${PRODUCT_COPY_FILES_LIST[@]})
    local COUNT=${#FILELIST[@]}

    if [[ ${FILELIST[*]} =~ ";AB" ]]; then
        printf '%s\n' "AB_OTA_PARTITIONS += \\" >> "$BOARDMK"
    fi

    for (( i=1; i<COUNT+1; i++ )); do
        local DST_FILE=$(target_file "${FILELIST[$i-1]}")
        local ARGS=$(target_args "${FILELIST[$i-1]}")
        local SHA1=$(get_hash "$ANDROID_ROOT"/"$OUTDIR"/radio/"$DST_FILE")
        DST_FILE_NAME=(${DST_FILE//.img/ })
        ARGS=(${ARGS//;/ })
        LINEEND=" \\"
        if [ "$i" -eq "$COUNT" ]; then
            LINEEND=""
        fi

        for ARG in "${ARGS[@]}"; do
            if [[ "$ARG" =~ "AB" ]]; then
                printf '    %s%s\n' "$DST_FILE_NAME" "$LINEEND" >> "$BOARDMK"
            fi
        done
        printf '%s\n' "\$(call add-radio-file-sha1-checked,radio/$DST_FILE,$SHA1)" >> "$ANDROIDMK"
    done
    printf '\n' >> "$ANDROIDMK"
}

#
# get_file:
#
# $1: input file
# $2: target file/folder
# $3: source of the file (can be "adb" or a local folder)
#
# Silently extracts the input file to defined target
# Returns success if file can be pulled from the device or found locally
#
function get_file() {
    local SRC="$3"

    if [ "$SRC" = "adb" ]; then
        # try to pull
        adb pull "$1"           "$2" >/dev/null 2>&1 && return 0
        adb pull "${1#/system}" "$2" >/dev/null 2>&1 && return 0
        adb pull "system/$1"    "$2" >/dev/null 2>&1 && return 0

        return 1
    else
        # try to copy
        cp -Lr "$SRC/$1"           "$2" 2>/dev/null && return 0
        cp -Lr "$SRC/${1#/system}" "$2" 2>/dev/null && return 0
        cp -Lr "$SRC/system/$1"    "$2" 2>/dev/null && return 0

        # try /vendor/odm for devices without /odm partition
        [[ "$1" == /system/odm/* ]] && cp -Lr "$SRC/vendor/${1#/system}" "$2" 2>/dev/null && return 0

        return 1
    fi
};

#
# oat2dex:
#
# $1: extracted apk|jar (to check if deodex is required)
# $2: odexed apk|jar to deodex
# $3: source of the odexed apk|jar
#
# Convert apk|jar .odex in the corresposing classes.dex
#
function oat2dex() {
    local CUSTOM_TARGET="$1"
    local OEM_TARGET="$2"
    local SRC="$3"
    local TARGET=
    local OAT=

    if [ -z "$BAKSMALIJAR" ] || [ -z "$SMALIJAR" ]; then
        export BAKSMALIJAR="$ANDROID_ROOT"/prebuilts/extract-tools/common/smali/baksmali.jar
        export SMALIJAR="$ANDROID_ROOT"/prebuilts/extract-tools/common/smali/smali.jar
    fi

    if [ -z "$VDEXEXTRACTOR" ]; then
        export VDEXEXTRACTOR="$ANDROID_ROOT"/prebuilts/extract-tools/${HOST}-x86/bin/vdexExtractor
    fi

    if [ -z "$CDEXCONVERTER" ]; then
        export CDEXCONVERTER="$ANDROID_ROOT"/prebuilts/extract-tools/${HOST}-x86/bin/compact_dex_converter
    fi

    # Extract existing boot.oats to the temp folder
    if [ -z "$ARCHES" ]; then
        echo "Checking if system is odexed and locating boot.oats..."
        for ARCH in "arm64" "arm" "x86_64" "x86"; do
            mkdir -p "$EXTRACT_TMP_DIR/system/framework/$ARCH"
            if get_file "/system/framework/$ARCH" "$EXTRACT_TMP_DIR/system/framework/" "$SRC"; then
                ARCHES+="$ARCH "
            else
                rmdir "$EXTRACT_TMP_DIR/system/framework/$ARCH"
            fi
        done
    fi

    if [ -z "$ARCHES" ]; then
        FULLY_DEODEXED=1 && return 0 # system is fully deodexed, return
    fi

    if [ ! -f "$CUSTOM_TARGET" ]; then
        return;
    fi

    if grep "classes.dex" "$CUSTOM_TARGET" >/dev/null; then
        return 0 # target apk|jar is already odexed, return
    fi

    for ARCH in $ARCHES; do
        BOOTOAT="$EXTRACT_TMP_DIR/system/framework/$ARCH/boot.oat"

        local OAT="$(dirname "$OEM_TARGET")/oat/$ARCH/$(basename "$OEM_TARGET" ."${OEM_TARGET##*.}").odex"
        local VDEX="$(dirname "$OEM_TARGET")/oat/$ARCH/$(basename "$OEM_TARGET" ."${OEM_TARGET##*.}").vdex"

        if get_file "$OAT" "$EXTRACT_TMP_DIR" "$SRC"; then
            if get_file "$VDEX" "$EXTRACT_TMP_DIR" "$SRC"; then
                "$VDEXEXTRACTOR" -o "$EXTRACT_TMP_DIR/" -i "$EXTRACT_TMP_DIR/$(basename "$VDEX")" > /dev/null
                CLASSES=$(ls "$EXTRACT_TMP_DIR/$(basename "${OEM_TARGET%.*}")_classes"*)
                for CLASS in $CLASSES; do
                    NEWCLASS=$(echo "$CLASS" | sed 's/.*_//;s/cdex/dex/')
                    # Check if we have to deal with CompactDex
                    if [[ "$CLASS" == *.cdex ]]; then
                        "$CDEXCONVERTER" "$CLASS" &>/dev/null
                        mv "$CLASS.new" "$EXTRACT_TMP_DIR/$NEWCLASS"
                    else
                        mv "$CLASS" "$EXTRACT_TMP_DIR/$NEWCLASS"
                    fi
                done
            else
                "$JAVA" -jar "$BAKSMALIJAR" deodex -o "$EXTRACT_TMP_DIR/dexout" -b "$BOOTOAT" -d "$EXTRACT_TMP_DIR" "$EXTRACT_TMP_DIR/$(basename "$OAT")"
                "$JAVA" -jar "$SMALIJAR" assemble "$EXTRACT_TMP_DIR/dexout" -o "$EXTRACT_TMP_DIR/classes.dex"
            fi
        elif [[ "$CUSTOM_TARGET" =~ .jar$ ]]; then
            JAROAT="$EXTRACT_TMP_DIR/system/framework/$ARCH/boot-$(basename ${OEM_TARGET%.*}).oat"
            JARVDEX="/system/framework/boot-$(basename ${OEM_TARGET%.*}).vdex"
            if [ ! -f "$JAROAT" ]; then
                JAROAT=$BOOTOAT
            fi
            if [ ! -f "$JARVDEX" ]; then
                JARVDEX="/system/framework/$ARCH/boot-$(basename ${OEM_TARGET%.*}).vdex"
            fi
            # try to extract classes.dex from boot.vdex for frameworks jars
            # fallback to boot.oat if vdex is not available
            if get_file "$JARVDEX" "$EXTRACT_TMP_DIR" "$SRC"; then
                "$VDEXEXTRACTOR" -o "$EXTRACT_TMP_DIR/" -i "$EXTRACT_TMP_DIR/$(basename "$JARVDEX")" > /dev/null
                CLASSES=$(ls "$EXTRACT_TMP_DIR/$(basename "${JARVDEX%.*}")_classes"* 2> /dev/null)
                for CLASS in $CLASSES; do
                    NEWCLASS=$(echo "$CLASS" | sed 's/.*_//;s/cdex/dex/')
                    # Check if we have to deal with CompactDex
                    if [[ "$CLASS" == *.cdex ]]; then
                        "$CDEXCONVERTER" "$CLASS" &>/dev/null
                        mv "$CLASS.new" "$EXTRACT_TMP_DIR/$NEWCLASS"
                    else
                        mv "$CLASS" "$EXTRACT_TMP_DIR/$NEWCLASS"
                    fi
                done
            else
                "$JAVA" -jar "$BAKSMALIJAR" deodex -o "$EXTRACT_TMP_DIR/dexout" -b "$BOOTOAT" -d "$EXTRACT_TMP_DIR" "$JAROAT/$OEM_TARGET"
                "$JAVA" -jar "$SMALIJAR" assemble "$EXTRACT_TMP_DIR/dexout" -o "$EXTRACT_TMP_DIR/classes.dex"
            fi
        else
            continue
        fi

    done

    rm -rf "$EXTRACT_TMP_DIR/dexout"
}

#
# init_adb_connection:
#
# Starts adb server and waits for the device
#
function init_adb_connection() {
    adb start-server # Prevent unexpected starting server message from adb get-state in the next line
    if ! _adb_connected; then
        echo "No device is online. Waiting for one..."
        echo "Please connect USB and/or enable USB debugging"
        until _adb_connected; do
            sleep 1
        done
        echo "Device Found."
    fi

    # Retrieve IP and PORT info if we're using a TCP connection
    TCPIPPORT=$(adb devices | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+[^0-9]+' \
        | head -1 | awk '{print $1}')
    adb root &> /dev/null
    sleep 0.3
    if [ -n "$TCPIPPORT" ]; then
        # adb root just killed our connection
        # so reconnect...
        adb connect "$TCPIPPORT"
    fi
    adb wait-for-device &> /dev/null
    sleep 0.3
}

#
# fix_xml:
#
# $1: xml file to fix
#
function fix_xml() {
    local XML="$1"
    local TEMP_XML="$EXTRACT_TMP_DIR/`basename "$XML"`.temp"

    grep -a '^<?xml version' "$XML" > "$TEMP_XML"
    grep -av '^<?xml version' "$XML" >> "$TEMP_XML"

    mv "$TEMP_XML" "$XML"
}

function get_hash() {
    local FILE="$1"

    if [ "$(uname)" == "Darwin" ]; then
        shasum "${FILE}" | awk '{print $1}'
    else
        sha1sum "${FILE}" | awk '{print $1}'
    fi
}

function print_spec() {
    local SPEC_PRODUCT_PACKAGE="$1"
    local SPEC_SRC_FILE="$2"
    local SPEC_DST_FILE="$3"
    local SPEC_ARGS="$4"
    local SPEC_HASH="$5"
    local SPEC_FIXUP_HASH="$6"

    local PRODUCT_PACKAGE=""
    if [ ${SPEC_PRODUCT_PACKAGE} = true ]; then
        PRODUCT_PACKAGE="-"
    fi
    local SRC=""
    if [ ! -z "${SPEC_SRC_FILE}" ] && [ "${SPEC_SRC_FILE}" != "${SPEC_DST_FILE}" ]; then
        SRC="${SPEC_SRC_FILE}:"
    fi
    local DST=""
    if [ ! -z "${SPEC_DST_FILE}" ]; then
        DST="${SPEC_DST_FILE}"
    fi
    local ARGS=""
    if [ ! -z "${SPEC_ARGS}" ]; then
        ARGS=";${SPEC_ARGS}"
    fi
    local HASH=""
    if [ ! -z "${SPEC_HASH}" ] && [ "${SPEC_HASH}" != "x" ]; then
        HASH="|${SPEC_HASH}"
    fi
    local FIXUP_HASH=""
    if [ ! -z "${SPEC_FIXUP_HASH}" ] && [ "${SPEC_FIXUP_HASH}" != "x" ] && [ "${SPEC_FIXUP_HASH}" != "${SPEC_HASH}" ]; then
        FIXUP_HASH="|${SPEC_FIXUP_HASH}"
    fi
    printf '%s%s%s%s%s%s\n' "${PRODUCT_PACKAGE}" "${SRC}" "${DST}" "${ARGS}" "${HASH}" "${FIXUP_HASH}"
}

# Helper function to be used by device-level extract-files.sh
# to patch a jar
#   $1: path to blob file.
#   $2: path to patch file or directory with patches.
#   ...: arguments to be passed to apktool
#
function apktool_patch() {
    local APK_PATH="$1"
    shift

    local PATCHES_PATH="$1"
    shift

    local PATCHES_PATHS=$(find "$PATCHES_PATH" -name "*.patch" | sort)

    local TEMP_DIR=$(mktemp -dp "$EXTRACT_TMP_DIR")
    "$JAVA" -jar "$APKTOOL" d "$APK_PATH" -o "$TEMP_DIR" -f "$@"

    while IFS= read -r PATCH_PATH; do
        echo "Applying patch $PATCH_PATH"
        patch -p1 -d "$TEMP_DIR" < "$PATCH_PATH"
    done <<< "$PATCHES_PATHS"

    # apktool modifies timestamps, we cannot use its output.
    # To get reproductible builds, use stripzip to strip the timestamps.
    "$JAVA" -jar "$APKTOOL" b "$TEMP_DIR" -o "$APK_PATH"

    "$STRIPZIP" "$APK_PATH"
}

# To be overridden by device-level extract-files.sh
# Parameters:
#   $1: spec name of a blob. Can be used for filtering.
#       If the spec is "src:dest", then $1 is "dest".
#       If the spec is "src", then $1 is "src".
#   $2: path to blob file. Can be used for fixups.
#
function blob_fixup() {
    :
}

# To be overridden by device-level extract-files.sh
# Parameters:
#   $1: Path to vendor Android.bp
#
function vendor_imports() {
    :
}

#
# prepare_images:
#
# Positional parameters:
# $1: path to extracted system folder or an ota zip file
#
function prepare_images() {
    # Consume positional parameters
    local SRC="$1"; shift
    local KEEP_DUMP_DIR="$SRC"

    if [ -f "$SRC" ] && [ "${SRC##*.}" == "zip" ]; then
        local BASENAME=$(basename "$SRC")
        local DIRNAME=$(dirname "$SRC")
        DUMPDIR="$EXTRACT_TMP_DIR"/system_dump
        KEEP_DUMP_DIR="$DIRNAME"/"${BASENAME%.zip}"
        if [ "$KEEP_DUMP" == "true" ] || [ "$KEEP_DUMP" == "1" ]; then
            rm -rf "$KEEP_DUMP_DIR"
            mkdir "$KEEP_DUMP_DIR"
        fi

        # Check if we're working with the same zip that was passed last time.
        # If so, let's just use what's already extracted.
        MD5=`md5sum "$SRC"| awk '{print $1}'`
        OLDMD5=`cat "$DUMPDIR"/zipmd5.txt`

        if [ "$MD5" != "$OLDMD5" ]; then
            rm -rf "$DUMPDIR"
            mkdir "$DUMPDIR"
            unzip "$SRC" -d "$DUMPDIR"
            echo "$MD5" > "$DUMPDIR"/zipmd5.txt

            # Extract A/B OTA
            if [ -a "$DUMPDIR"/payload.bin ]; then
                for PARTITION in "system" "odm" "product" "system_ext" "vendor"
                do
                    "$OTA_EXTRACTOR" --payload "$DUMPDIR"/payload.bin --output_dir "$DUMPDIR" --partitions "$PARTITION" &2>&1
                done
                wait
            fi

            for PARTITION in "system" "odm" "product" "system_ext" "vendor"
            do
                # If OTA is block based, extract it.
                if [ -a "$DUMPDIR"/"$PARTITION".new.dat.br ]; then
                    echo "Converting "$PARTITION".new.dat.br to "$PARTITION".new.dat"
                    brotli -d "$DUMPDIR"/"$PARTITION".new.dat.br
                    rm "$DUMPDIR"/"$PARTITION".new.dat.br
                fi
                if [ -a "$DUMPDIR"/"$PARTITION".new.dat ]; then
                    echo "Converting "$PARTITION".new.dat to "$PARTITION".img"
                    python "$ANDROID_ROOT"/tools/extract-utils/sdat2img.py "$DUMPDIR"/"$PARTITION".transfer.list "$DUMPDIR"/"$PARTITION".new.dat "$DUMPDIR"/"$PARTITION".img 2>&1
                    rm -rf "$DUMPDIR"/"$PARTITION".new.dat "$DUMPDIR"/"$PARTITION"
                    mkdir "$DUMPDIR"/"$PARTITION" "$DUMPDIR"/tmp
                    extract_img_data "$DUMPDIR"/"$PARTITION".img "$DUMPDIR"/"$PARTITION"/
                    rm "$DUMPDIR"/"$PARTITION".img
                fi
                if [ -a "$DUMPDIR"/"$PARTITION".img ]; then
                    extract_img_data "$DUMPDIR"/"$PARTITION".img "$DUMPDIR"/"$PARTITION"/
                fi
            done
        fi

        SRC="$DUMPDIR"
    fi

    local SUPERIMG=""

    if [ -d "$SRC" ] && [ -f "$SRC"/super.img ]; then
        SUPERIMG="$SRC"/super.img
    elif [ -d "$SRC" ] && [ -f "$SRC"/super.img_sparsechunk.0 ]; then
        SUPERIMG="$(find $SRC -name 'super.img_sparsechunk.*' | sort -V | xargs)"
    fi

    if [ -n "$SUPERIMG" ]; then
        DUMPDIR="$EXTRACT_TMP_DIR"/super_dump
        mkdir -p "$DUMPDIR"

        echo "Unpacking super.img"
        "$SIMG2IMG" $SUPERIMG "$DUMPDIR"/super.raw

        for PARTITION in "system" "odm" "product" "system_ext" "vendor"
        do
            echo "Preparing "$PARTITION""
            if "$LPUNPACK" -p "$PARTITION"_a "$DUMPDIR"/super.raw "$DUMPDIR" ; then
                mv "$DUMPDIR"/"$PARTITION"_a.img "$DUMPDIR"/"$PARTITION".img
            else
                "$LPUNPACK" -p "$PARTITION" "$DUMPDIR"/super.raw "$DUMPDIR"
            fi
        done
        rm "$DUMPDIR"/super.raw

        if [ "$KEEP_DUMP" == "true" ] || [ "$KEEP_DUMP" == "1" ]; then
            rm -rf "$KEEP_DUMP_DIR"/super_dump
            cp -a "$DUMPDIR" "$KEEP_DUMP_DIR"/super_dump
        fi

        SRC="$DUMPDIR"
    fi

    if [ -d "$SRC" ] && [ -f "$SRC"/system.img ]; then
        DUMPDIR="$EXTRACT_TMP_DIR"/system_dump
        mkdir -p "$DUMPDIR"

        for PARTITION in "system" "odm" "product" "system_ext" "vendor"
        do
            echo "Extracting "$PARTITION""
            local IMAGE="$SRC"/"$PARTITION".img
            if [ -f "$IMAGE" ]; then
                if [[ $(file -b "$IMAGE") == EROFS* ]]; then
                    fsck.erofs --extract="$DUMPDIR"/"$PARTITION" "$IMAGE"
                elif [[ $(file -b "$IMAGE") == Linux* ]]; then
                    extract_img_data "$IMAGE" "$DUMPDIR"/"$PARTITION"
                elif [[ $(file -b "$IMAGE") == Android* ]]; then
                    "$SIMG2IMG" "$IMAGE" "$DUMPDIR"/"$PARTITION".raw
                    extract_img_data "$DUMPDIR"/"$PARTITION".raw "$DUMPDIR"/"$PARTITION"/
                else
                    echo "Unsupported "$IMAGE""
                fi
            fi
        done

        if [ "$KEEP_DUMP" == "true" ] || [ "$KEEP_DUMP" == "1" ]; then
            rm -rf "$KEEP_DUMP_DIR"/output
            cp -a "$DUMPDIR" "$KEEP_DUMP_DIR"/output
        fi

        SRC="$DUMPDIR"
    fi

    EXTRACT_SRC="$SRC"
    EXTRACT_STATE=1
}

#
# extract:
#
# Positional parameters:
# $1: file containing the list of items to extract (aka proprietary-files.txt)
# $2: path to extracted system folder, an ota zip file, or "adb" to extract from device
# $3: section in list file to extract - optional. Setting section via $3 is deprecated.
#
# Non-positional parameters (coming after $2):
# --section: preferred way of selecting the portion to parse and extract from
#            proprietary-files.txt
# --kang: if present, this option will activate the printing of hashes for the
#         extracted blobs. Useful with --section for subsequent pinning of
#         blobs taken from other origins.
#
function extract() {
    # Consume positional parameters
    local PROPRIETARY_FILES_TXT="$1"; shift
    local SRC="$1"; shift
    local SECTION=""
    local KANG=false

    # Consume optional, non-positional parameters
    while [ "$#" -gt 0 ]; do
        case "$1" in
        -s|--section)
            SECTION="$2"; shift
            ;;
        -k|--kang)
            KANG=true
            DISABLE_PINNING=1
            ;;
        *)
            # Backwards-compatibility with the old behavior, where $3, if
            # present, denoted an optional positional ${SECTION} argument.
            # Users of ${SECTION} are encouraged to migrate from setting it as
            # positional $3, to non-positional --section ${SECTION}, the
            # reason being that it doesn't scale to have more than 1 optional
            # positional argument.
            SECTION="$1"
            ;;
        esac
        shift
    done

    if [ -z "$OUTDIR" ]; then
        echo "Output dir not set!"
        exit 1
    fi

    parse_file_list "${PROPRIETARY_FILES_TXT}" "${SECTION}"

    # Allow failing, so we can try $DEST and/or $FILE
    set +e

    local FILELIST=( ${PRODUCT_COPY_FILES_LIST[@]} ${PRODUCT_PACKAGES_LIST[@]} )
    local HASHLIST=( ${PRODUCT_COPY_FILES_HASHES[@]} ${PRODUCT_PACKAGES_HASHES[@]} )
    local FIXUP_HASHLIST=( ${PRODUCT_COPY_FILES_FIXUP_HASHES[@]} ${PRODUCT_PACKAGES_FIXUP_HASHES[@]} )
    local PRODUCT_COPY_FILES_COUNT=${#PRODUCT_COPY_FILES_LIST[@]}
    local COUNT=${#FILELIST[@]}
    local OUTPUT_ROOT="$ANDROID_ROOT"/"$OUTDIR"/proprietary
    local OUTPUT_TMP="$EXTRACT_TMP_DIR"/"$OUTDIR"/proprietary

    if [ "$SRC" = "adb" ]; then
        init_adb_connection
    fi

    if [ "$EXTRACT_STATE" -ne "1" ]; then
        prepare_images "$SRC"
    fi

    if [ "$VENDOR_STATE" -eq "0" ]; then
        echo "Cleaning output directory ($OUTPUT_ROOT).."
        rm -rf "${OUTPUT_TMP:?}"
        mkdir -p "${OUTPUT_TMP:?}"
        if [ -d "$OUTPUT_ROOT" ]; then
            mv "${OUTPUT_ROOT:?}/"* "${OUTPUT_TMP:?}/"
        fi
        VENDOR_STATE=1
    fi

    echo "Extracting ${COUNT} files in ${PROPRIETARY_FILES_TXT} from ${EXTRACT_SRC}:"

    for (( i=1; i<COUNT+1; i++ )); do

        local SPEC_SRC_FILE=$(src_file "${FILELIST[$i-1]}")
        local SPEC_DST_FILE=$(target_file "${FILELIST[$i-1]}")
        local SPEC_ARGS=$(target_args "${FILELIST[$i-1]}")
        local OUTPUT_DIR=
        local TMP_DIR=
        local SRC_FILE=
        local DST_FILE=
        local IS_PRODUCT_PACKAGE=false

        # Note: this relies on the fact that the ${FILELIST[@]} array
        # contains first ${PRODUCT_COPY_FILES_LIST[@]}, then ${PRODUCT_PACKAGES_LIST[@]}.
        if [ "${i}" -gt "${PRODUCT_COPY_FILES_COUNT}" ]; then
            IS_PRODUCT_PACKAGE=true
        fi

        OUTPUT_DIR="${OUTPUT_ROOT}"
        TMP_DIR="${OUTPUT_TMP}"
        SRC_FILE="/system/${SPEC_SRC_FILE}"
        DST_FILE="/system/${SPEC_DST_FILE}"

        # Strip the file path in the vendor repo of "system", if present
        local BLOB_DISPLAY_NAME="${DST_FILE#/system/}"
        local VENDOR_REPO_FILE="$OUTPUT_DIR/${BLOB_DISPLAY_NAME}"
        mkdir -p $(dirname "${VENDOR_REPO_FILE}")

        # Check pinned files
        local HASH="$(echo ${HASHLIST[$i-1]} | awk '{ print tolower($0); }')"
        local FIXUP_HASH="$(echo ${FIXUP_HASHLIST[$i-1]} | awk '{ print tolower($0); }')"
        local KEEP=""
        if [ "$DISABLE_PINNING" != "1" ] && [ "$HASH" != "x" ]; then
            if [ -f "${VENDOR_REPO_FILE}" ]; then
                local PINNED="${VENDOR_REPO_FILE}"
            else
                local PINNED="${TMP_DIR}${DST_FILE#/system}"
            fi
            if [ -f "$PINNED" ]; then
                local TMP_HASH=$(get_hash "${PINNED}")
                if [ "${TMP_HASH}" = "${HASH}" ] || [ "${TMP_HASH}" = "${FIXUP_HASH}" ]; then
                    KEEP="1"
                    if [ ! -f "${VENDOR_REPO_FILE}" ]; then
                        cp -p "$PINNED" "${VENDOR_REPO_FILE}"
                    fi
                fi
            fi
        fi

        if [ "${KANG}" = false ]; then
            printf '  - %s\n' "${BLOB_DISPLAY_NAME}"
        fi

        if [ "$KEEP" = "1" ]; then
            if [ "${FIXUP_HASH}" != "x" ]; then
                printf '    + keeping pinned file with hash %s\n' "${FIXUP_HASH}"
            else
                printf '    + keeping pinned file with hash %s\n' "${HASH}"
            fi
        else
            FOUND=false
            # Try custom target first.
            # Also try to search for files stripped of
            # the "/system" prefix, if we're actually extracting
            # from a system image.
            for CANDIDATE in "${DST_FILE}" "${SRC_FILE}"; do
                get_file ${CANDIDATE} ${VENDOR_REPO_FILE} ${EXTRACT_SRC} && {
                    FOUND=true
                    break
                }
            done

            if [ "${FOUND}" = false ]; then
                colored_echo red "    !! ${BLOB_DISPLAY_NAME}: file not found in source"
                continue
            fi

            # Blob fixup pipeline has 2 parts: one that is fixed and
            # one that is user-configurable
            local PRE_FIXUP_HASH=$(get_hash ${VENDOR_REPO_FILE})
            # Deodex apk|jar if that's the case
            if [[ "$FULLY_DEODEXED" -ne "1" && "${VENDOR_REPO_FILE}" =~ .(apk|jar)$ ]]; then
                oat2dex "${VENDOR_REPO_FILE}" "${SRC_FILE}" "$EXTRACT_SRC"
                if [ -f "$EXTRACT_TMP_DIR/classes.dex" ]; then
                    touch -t 200901010000 "$EXTRACT_TMP_DIR/classes"*
                    zip -gjq "${VENDOR_REPO_FILE}" "$EXTRACT_TMP_DIR/classes"*
                    rm "$EXTRACT_TMP_DIR/classes"*
                    printf '    (updated %s from odex files)\n' "${SRC_FILE}"
                fi
            elif [[ "${VENDOR_REPO_FILE}" =~ .xml$ ]]; then
                fix_xml "${VENDOR_REPO_FILE}"
            fi
            # Now run user-supplied fixup function
            blob_fixup "${BLOB_DISPLAY_NAME}" "${VENDOR_REPO_FILE}"
            local POST_FIXUP_HASH=$(get_hash ${VENDOR_REPO_FILE})

            if [ -f "${VENDOR_REPO_FILE}" ]; then
                local DIR=$(dirname "${VENDOR_REPO_FILE}")
                local TYPE="${DIR##*/}"
                if [ "$TYPE" = "bin" ]; then
                    chmod 755 "${VENDOR_REPO_FILE}"
                else
                    chmod 644 "${VENDOR_REPO_FILE}"
                fi
            fi

            if [ "${KANG}" =  true ]; then
                print_spec "${IS_PRODUCT_PACKAGE}" "${SPEC_SRC_FILE}" "${SPEC_DST_FILE}" "${SPEC_ARGS}" "${PRE_FIXUP_HASH}" "${POST_FIXUP_HASH}"
            fi

            # Check and print whether the fixup pipeline actually did anything.
            # This isn't done right after the fixup pipeline because we want this print
            # to come after print_spec above, when in kang mode.
            if [ "${PRE_FIXUP_HASH}" != "${POST_FIXUP_HASH}" ]; then
                printf "    + Fixed up %s\n" "${BLOB_DISPLAY_NAME}"
                # Now sanity-check the spec for this blob.
                if [ "${KANG}" = false ] && [ "${FIXUP_HASH}" = "x" ] && [ "${HASH}" != "x" ]; then
                    colored_echo yellow "WARNING: The ${BLOB_DISPLAY_NAME} file was fixed up, but it is pinned."
                    colored_echo yellow "This is a mistake and you want to either remove the hash completely, or add an extra one."
                fi
            fi
        fi

    done

    # Don't allow failing
    set -e
}

#
# extract_carriersettings:
#
# Convert prebuilt protobuf CarrierSettings files to CarrierConfig vendor.xml
#
function extract_carriersettings() {
    local CARRIERSETTINGS_EXTRACTOR="$ANDROID_ROOT"/lineage/scripts/carriersettings-extractor/carriersettings_extractor.py
    local SRC="$ANDROID_ROOT"/"$OUTDIR"/proprietary/product/etc/CarrierSettings
    local CARRIERSETTINGS_OUTPUT_DIR="$ANDROID_ROOT"/"$OUTDIR"/rro_overlays/CarrierConfigOverlay/res/xml

    mkdir -p "$CARRIERSETTINGS_OUTPUT_DIR"
    python3 "$CARRIERSETTINGS_EXTRACTOR" -i "$SRC" -v "$CARRIERSETTINGS_OUTPUT_DIR"
}

#
# To be overridden by device-level extract-files.sh
#
function prepare_firmware() {
    :
}

#
# extract_firmware:
#
# $1: file containing the list of items to extract
# $2: path to extracted radio folder
#
function extract_firmware() {
    if [ -z "$OUTDIR" ]; then
        echo "Output dir not set!"
        exit 1
    fi

    parse_file_list "$1"

    # Don't allow failing
    set -e

    local FILELIST=( ${PRODUCT_COPY_FILES_LIST[@]} )
    local COUNT=${#FILELIST[@]}
    local SRC="$2"
    local OUTPUT_DIR="$ANDROID_ROOT"/"$OUTDIR"/radio

    if [ "$VENDOR_RADIO_STATE" -eq "0" ]; then
        echo "Cleaning firmware output directory ($OUTPUT_DIR).."
        rm -rf "${OUTPUT_DIR:?}/"*
        VENDOR_RADIO_STATE=1
    fi

    echo "Extracting $COUNT files in $1 from $SRC:"

    prepare_firmware

    for (( i=1; i<COUNT+1; i++ )); do
        local SRC_FILE=$(src_file "${FILELIST[$i-1]}")
        local DST_FILE=$(target_file "${FILELIST[$i-1]}")
        local COPY_FILE=

        printf '  - %s \n' "radio/$DST_FILE"

        if [ ! -d "$OUTPUT_DIR" ]; then
            mkdir -p "$OUTPUT_DIR"
        fi
        if [ "$SRC" = "adb" ]; then
            local PARTITION="${DST_FILE%.*}"

            if [[ "${FILELIST[$i-1]}" == *\;AB ]]; then
                local SLOT=$(adb shell getprop ro.boot.slot_suffix | rev | cut -c1)
                PARTITION="${PARTITION}_${SLOT}"
            fi

            if adb pull "/dev/block/by-name/${PARTITION}" "$OUTPUT_DIR/$DST_FILE"; then
                chmod 644 "$OUTPUT_DIR/$DST_FILE"
            else
                colored_echo yellow "${DST_FILE} not found, skipping copy"
            fi

            continue
        fi
        if [ -f "$SRC" ] && [ "${SRC##*.}" == "zip" ]; then
            # Extract A/B OTA
            if [ -a "$DUMPDIR"/payload.bin ]; then
                "$OTA_EXTRACTOR" --payload "$DUMPDIR"/payload.bin --output_dir "$DUMPDIR" --partitions $(basename "${DST_FILE%.*}") 2>&1
                if [ -f "$DUMPDIR/$(basename $DST_FILE)" ]; then
                    COPY_FILE="$DUMPDIR/$(basename $DST_FILE)"
                fi
            fi
        else
            if [ -f "$SRC/$SRC_FILE" ]; then
                COPY_FILE="$SRC/$SRC_FILE"
            elif [ -f "$SRC/$DST_FILE" ]; then
                COPY_FILE="$SRC/$DST_FILE"
            fi
            if [[ $(file -b "$COPY_FILE") == Android* ]]; then
                "$SIMG2IMG" "$COPY_FILE" "$SRC"/"$(basename "$COPY_FILE").raw"
                COPY_FILE="$SRC"/"$(basename "$COPY_FILE").raw"
            fi
        fi

        if [ -f "$COPY_FILE" ]; then
            cp "$COPY_FILE" "$OUTPUT_DIR/$DST_FILE"
            chmod 644 "$OUTPUT_DIR/$DST_FILE"
        else
            colored_echo yellow "${DST_FILE} not found, skipping copy"
        fi
    done
}

function extract_img_data() {
    local image_file="$1"
    local out_dir="$2"
    local logFile="$EXTRACT_TMP_DIR/debugfs.log"

    if [ ! -d "$out_dir" ]; then
        mkdir -p "$out_dir"
    fi

    if [[ "$HOST_OS" == "Darwin" ]]; then
        debugfs -R "rdump / \"$out_dir\"" "$image_file" &> "$logFile" || {
            echo "[-] Failed to extract data from '$image_file'"
            abort 1
        }
    else
        debugfs -R 'ls -p' "$image_file" 2>/dev/null | cut -d '/' -f6 | while read -r entry
        do
            debugfs -R "rdump \"$entry\" \"$out_dir\"" "$image_file" >> "$logFile" 2>&1 || {
                echo "[-] Failed to extract data from '$image_file'"
                abort 1
            }
        done
    fi

    local symlink_err="rdump: Attempt to read block from filesystem resulted in short read while reading symlink"
    if grep -Fq "$symlink_err" "$logFile"; then
        echo "[-] Symlinks have not been properly processed from $image_file"
        echo "[!] You might not have a compatible debugfs version"
        abort 1
    fi
}

function array_contains() {
    local element
    for element in "${@:2}"; do [[ "$element" == "$1" ]] && return 0; done
    return 1
}

function generate_prop_list_from_image() {
    local image_file="$1"
    local image_dir="$EXTRACT_TMP_DIR/image-temp"
    local output_list="$2"
    local output_list_tmp="$EXTRACT_TMP_DIR/_proprietary-blobs.txt"
    local -n skipped_files="$3"
    local component="$4"
    local partition="$component"

    mkdir -p "$image_dir"

    if [[ $(file -b "$image_file") == EROFS* ]]; then
        fsck.erofs --extract="$image_dir" "$image_file"
    elif [[ $(file -b "$image_file") == Linux* ]]; then
        extract_img_data "$image_file" "$image_dir"
    elif [[ $(file -b "$image_file") == Android* ]]; then
        "$SIMG2IMG" "$image_file" "$image_dir"/"$(basename "$image_file").raw"
        extract_img_data "$image_dir"/"$(basename "$image_file").raw" "$image_dir"
        rm "$image_dir"/"$(basename "$image_file").raw"
    else
        echo "Unsupported "$image_file""
    fi

    if [ -z "$component" ]; then
        partition="vendor"
    elif [[ "$component" == "carriersettings" ]]; then
        partition="product"
    fi

    find "$image_dir" -not -type d | sed "s#^$image_dir/##" | while read -r FILE
    do
        if [[ "$component" == "carriersettings" ]] && ! prefix_match_file "etc/CarrierSettings" "$FILE" ; then
            continue
        fi
        if suffix_match_file ".odex" "$FILE" || suffix_match_file ".vdex" "$FILE" ; then
            continue
        fi
        # Skip device defined skipped files since they will be re-generated at build time
        if array_contains "$FILE" "${skipped_files[@]}"; then
            continue
        fi
        echo "$partition/$FILE" >> "$output_list_tmp"
    done

    # Sort merged file with all lists
    LC_ALL=C sort -u "$output_list_tmp" > "$output_list"

    # Clean-up
    rm -f "$output_list_tmp"
}

function colored_echo() {
    IFS=" "
    local color=$1;
    shift
    if ! [[ $color =~ '^[0-9]$' ]] ; then
        case $(echo $color | tr '[:upper:]' '[:lower:]') in
        black) color=0 ;;
        red) color=1 ;;
        green) color=2 ;;
        yellow) color=3 ;;
        blue) color=4 ;;
        magenta) color=5 ;;
        cyan) color=6 ;;
        white|*) color=7 ;; # white or invalid color
        esac
    fi
    if [ -t 1 ] ; then tput setaf $color; fi
    printf '%s\n' "$*"
    if [ -t 1 ] ; then tput sgr0; fi
}
