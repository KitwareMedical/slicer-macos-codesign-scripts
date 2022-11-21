#!/usr/bin/env bash

script_name=$(basename "$0")
readonly script_name

usage="usage: $script_name <identifier> <version> <dev_id_application> <dev_id_installer> [--] <package>.dmg

Sign the \"<application>.app\" bundle inside the given \"<package>.dmg\" disk image.
Also produce a \"<package>.pkg\" installer.
"
readonly usage

function log {
  echo
  echo "  --  " "$@"
  echo
}

if [ $# -ne 5 ]
then
  log "$usage"
  exit 1
fi

script_dir=$(cd "$(dirname "$0")" || exit 1; pwd)
readonly script_dir

umask 022

id="$1"
readonly id

ver="$2"
readonly ver

pkg="$5"
readonly pkg

pkg_base="$(basename "${pkg}" .dmg)"
readonly pkg_base

vol_name="/Volumes/${pkg_base}"
readonly vol_name

cert_name_app="$3"
readonly cert_name_app

cert_name_inst="$4"
readonly cert_name_inst

log "Extracting major.minor version from ${ver}"
ver_major=$(echo "${ver}" | cut -d. -f1)
readonly ver_major

ver_minor=$(echo "${ver}" | cut -d. -f2)
readonly ver_minor

log " ${ver_major}.${ver_minor}"

for command in \
  codesign \
  fsck_hfs \
  hdiutil \
  install_name_tool \
  pkgbuild \
  plutil \
  spctl \
; do
  if ! command -v "${command}" &> /dev/null; then
    echo -e >&2 "ERROR: \"${command}\" not found!\n"
    exit 1
  fi
done

has_hdiutil_udifderez=false
if hdiutil help 2>&1 | grep -q udifderez; then
  has_hdiutil_udifderez=true
fi

has_hdiutil_udifrez=false
if hdiutil help 2>&1 | grep -q udifrez; then
  has_hdiutil_udifrez=true
fi

log "Backing up the original DMG"
cp "${pkg}" "${pkg_base}.orig.dmg"

log "Create temporary directory"
temp_dir=$(mktemp -d)
readonly temp_dir

if $has_hdiutil_udifderez && $has_hdiutil_udifrez; then
  log "Extract SLA"
  readonly sla_xml="$temp_dir/sla.xml"
  hdiutil udifderez -xml "$pkg" > "$sla_xml"
  plutil -remove 'blkx' "$sla_xml"
  plutil -remove 'plst' "$sla_xml"
  log "Extract SLA [$sla_xml]"
else
  log "Extract SLA (skipping: \"hdiutil udifderez\" is not available)"
fi

log "Convert from original image to uncompressed read-write"
hdiutil convert "${pkg}" -format UDRW -o "${pkg_base}.rw"
if ! rm -f "${pkg}";
then
  exit
fi

hdiutil attach -mountpoint "${vol_name}" "${pkg_base}.rw.dmg"
app_dir=$(ls -d "${vol_name}"/*.app)
readonly app_dir
log "Mount: ${app_dir}"

app_name=$(basename "${app_dir}")
readonly app_name
log "Application: ${app_name}"

lib_dir=$(ls -d "${vol_name}/${app_name}/Contents/lib/${app_name%.*}"-*)
readonly lib_dir
lib_subdir=$(basename "${lib_dir}")
readonly lib_subdir
log "Library subdirectory: ${lib_subdir}"

tmp_vol_name=/Volumes/$(basename "${temp_dir}")
readonly tmp_vol_name

tmp_dmg_name=$(basename "${temp_dir}").rw.dmg
readonly tmp_dmg_name

tmp_app_dir=${tmp_vol_name}/${app_name}
readonly tmp_app_dir

# Explicitly creating a volume and copying the package files is required
# to avoid error like the following:
#
#  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/codesign_allocate:
#  can't write output file: /Volumes/Slicer-4.10.0-macosx-amd64/Slicer.app/Contents/Frameworks/QtWebEngineCore.framework/Versions/Current/QtWebEngineCore.cstemp (No space left on device)
#  /Volumes/Slicer-4.10.0-macosx-amd64/Slicer.app: the codesign_allocate helper tool cannot be found or used
#
log "Create ${tmp_dmg_name}"
hdiutil create "${tmp_dmg_name}" -fs HFS+ -size 2g -format UDRW -srcfolder "${temp_dir}"

log "Mount ${tmp_dmg_name}"
hdiutil attach -mountpoint "${tmp_vol_name}" "${tmp_dmg_name}"

log "Create directory ${tmp_app_dir}"
mkdir -p "${tmp_app_dir}"

log "Copy content from ${app_dir} to ${tmp_app_dir}"
# -a option ensure symlinks and attributes are preserved
cp -aR "${app_dir}"/* "${tmp_app_dir}"/

plist_file=${tmp_app_dir}/Contents/Info.plist
readonly plist_file

log "Extracting CFBundleIdentifier value from Info.plist"
current_id=$(plutil -extract CFBundleIdentifier xml1 -o - "${plist_file}" | xmllint --xpath //string/text\(\) 2>/dev/null -)
readonly current_id
log "Extracting CFBundleIdentifier value from Info.plist [${current_id}]"

if [[ "${current_id}" == "" ]]; then
  log "Updating info.plist setting CFBundleIdentifier to '${id}'"
  plutil -replace CFBundleIdentifier -string "${id}" "${plist_file}"
elif [[ "${current_id}" != "${id}" ]]; then
  log "error: Identifier found in Info.plist [${current_id}] is different from Identifier passed as ${script_name} argument [${id}]"
  exit 1
fi

log "Remove invalid LC_RPATH referencing absolute directories"
find "${tmp_app_dir}/Contents/lib/${lib_subdir}" -perm +111 -type f -name "*.dylib" -print0 | while IFS= read -r -d '' lib
do
  args=()
  for absolute_rpath in $(otool -l "${lib}" | grep -A 3 LC_RPATH | grep "path /" | tr -s ' ' | cut -d" " -f3); do
    args+=("-delete_rpath")
    args+=("${absolute_rpath}")
  done
  if [[ ${#args[@]} -gt 0 ]]; then
    log "  fixing ${lib}"
    install_name_tool "${args[@]}" "${lib}"
  fi
done

chmod -R ugo+rX "${tmp_app_dir}"

do_sign(){
  if ! codesign \
    --verify \
    --force \
    --verbose=4 \
    --entitlements "${script_dir}/entitlements.plist" \
    --options=runtime \
    -i "${id}" \
    -s "${cert_name_app}" \
    "$@";
  then
    hdiutil detach "${tmp_vol_name}"
    hdiutil detach "${vol_name}"
    exit
  fi
}

# To speed up signing, invoke codesign with multiple files but limit to <max_args>
# per invocation. This is needed to avoid "too many arguments" errors.
sign_paths(){
  max_args=200
  idx=0
  paths=()
  for path in "$@"; do
    paths+=("$path")
    ((++idx))
    if [[ $((idx % max_args)) == 0 ]]; then
      do_sign "${paths[@]}"
      paths=()
    fi
  done
  if [[ ${#paths[@]} -gt 0 ]]; then
    do_sign "${paths[@]}"
  fi
}

# Ensure all libraries are executable
find "${tmp_app_dir}/Contents/" -type f \( -name '*.so' -o -name '*.dylib' \) ! -perm -a+x -print0 | xargs -0 chmod +x

# Exclude files incorrectly marked as executable (png, python scripts, ...)
for dir in \
    bin \
    lib \
; do
  log "Signing ${dir}"

  # See https://stackoverflow.com/questions/23356779/how-can-i-store-the-find-command-results-as-an-array-in-bash/23357277#23357277
  paths=()
  while IFS=  read -r -d $'\0' path; do
      paths+=("$path")
  done < <(find "${tmp_app_dir}/Contents/${dir}" -perm +111 -type f ! -name "*.py" ! -name "*.png" -print0)

  sign_paths "${paths[@]}"
done

# Delete QtWebEngineCore.framework
# * This is required for signing Slicer (or Slicer-based) package prior Slicer@b0e0361be (2022.11.21)
#   introduced through PR-6685
# * See https://github.com/Slicer/Slicer/pull/6685 and https://github.com/Slicer/Slicer/commit/b0e0361be4f42aad2e5bb52142d9e0ed7df9d393
if [[ -d "${tmp_app_dir}/Contents/Frameworks/QtWebEngineCore.framework" ]]; then
  log "Removing QtWebEngineCore.framework"
  rm -rf "${tmp_app_dir}/Contents/Frameworks/QtWebEngineCore.framework"
fi

log "Signing App"
if ! do_sign --deep "${tmp_app_dir}";
then
  # Exit and detach if signing failed
  hdiutil detach "${tmp_vol_name}"
  hdiutil detach "${vol_name}"
  exit
fi

log "Copy signed files back to ${app_dir}"
rm -rf "${app_dir:?}"/*
cp -aR "${tmp_app_dir}"/* "${app_dir}"/

log "Generating PKG"
pkgbuild --sign "${cert_name_inst}" --root "${app_dir}" --identifier "${id}" --version "${ver}" --install-location="/Applications/${app_name}" "${pkg_base}".pkg

log "Umount temporary volume: ${tmp_vol_name}"
hdiutil detach "${tmp_vol_name}"

log "Remove temporary DMG: ${tmp_dmg_name}"
rm -f "${tmp_dmg_name}"

log "Umount volume: ${vol_name}"
hdiutil detach "${vol_name}"

log "Convert to intermediate format needed for rez tool."
hdiutil convert "${pkg_base}.rw.dmg" -format UDRO -o "${pkg_base}.ro"
rm -f "${pkg_base}.rw.dmg"

log "Convert back to read-only, compressed image."
hdiutil convert "${pkg_base}.ro.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "${pkg}"
rm -f "${pkg_base}.ro.dmg"

if $has_hdiutil_udifderez && $has_hdiutil_udifrez; then
  log "Re-insert SLA."
  hdiutil udifrez -xml "${sla_xml}" '' "$pkg"
  rm -f "${sla_xml}"
else
  log "Re-insert SLA (skipping: \"hdiutil udifrez\" is not available)"
fi

log "Signing DMG"
codesign --verify --verbose --display --deep -i "${id}" -s "${cert_name_app}" "${pkg}"

log "Mount signed DMG"
device=$(yes | hdiutil attach -noverify "${pkg}" | grep 'Apple_HFS' | grep -E '^/dev/' | sed 1q | awk '{print $1}')
readonly device

log "Checking mounted filesystem: ${device}"
fsck_hfs "${device}"

log "Check if Gatekeeper will accept the app's signature: ${app_dir}"
spctl -a -t exec -vv "${app_dir}"

log "Umount volume: ${vol_name}"
hdiutil detach "${vol_name}"
