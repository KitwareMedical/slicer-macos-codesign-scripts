#!/usr/bin/env bash

function log {
  echo
  echo "  --  " "$@"
  echo
}

if [ $# -ne 5 ]
then
  log "Usage: $0 identifier version dev_id_application dev_id_installer /path/to/file.dmg"
  exit 1
fi

script_name=$(basename $0)

umask 022

id="$1"
ver="$2"
pkg="$5"
pkg_base="$(basename ${pkg} .dmg)"
vol_name="/Volumes/${pkg_base}"
cert_name_app="$3"
cert_name_inst="$4"

log "Extracting major.minor version from ${ver}"
ver_major=$(echo ${ver} | cut -d. -f1)
ver_minor=$(echo ${ver} | cut -d. -f2)
log " ${ver_major}.${ver_minor}"

log "Backing up the original DMG"
cp ${pkg} ${pkg_base}.orig.dmg

log "Extract SLA"
hdiutil unflatten ${pkg}
DeRez -only 'LPic' -only 'STR#' -only 'TEXT' ${pkg} > sla.r
hdiutil flatten ${pkg}

log "Convert from original image to uncompressed read-write"
hdiutil convert ${pkg} -format UDRW -o ${pkg_base}.rw
rm -f ${pkg}
if [ $? -ne 0 ]
then
  exit
fi

hdiutil attach -mountpoint ${vol_name} ${pkg_base}.rw.dmg
app_dir=$(ls -d ${vol_name}/*.app)
log "Mount: ${app_dir}"

app_name=$(basename ${app_dir})
log "Application: ${app_name}"

lib_dir=$(ls -d ${vol_name}/${app_name}/Contents/lib/${app_name%.*}-*)
lib_subdir=$(basename ${lib_dir})
log "Library subdirectory: ${lib_subdir}"

log "Create temporary directory"
# Avoid error like the following:
#
#  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/codesign_allocate:
#  can't write output file: /Volumes/Slicer-4.10.0-macosx-amd64/Slicer.app/Contents/Frameworks/QtWebEngineCore.framework/Versions/Current/QtWebEngineCore.cstemp (No space left on device)
#  /Volumes/Slicer-4.10.0-macosx-amd64/Slicer.app: the codesign_allocate helper tool cannot be found or used
#
temp_dir=$(mktemp -d)
tmp_vol_name=/Volumes/$(basename ${temp_dir})
tmp_dmg_name=$(basename ${temp_dir}).rw.dmg
tmp_app_dir=${tmp_vol_name}/${app_name}

log "Create ${tmp_dmg_name}"
hdiutil create ${tmp_dmg_name} -fs HFS+ -size 2g -format UDRW -srcfolder ${temp_dir}

log "Mount ${tmp_dmg_name}"
hdiutil attach -mountpoint ${tmp_vol_name} ${tmp_dmg_name}

log "Create directory ${tmp_app_dir}"
mkdir -p ${tmp_app_dir}

log "Copy content from ${app_dir} to ${tmp_app_dir}"
# -a option ensure symlinks and attributes are preserved
cp -aR ${app_dir}/* ${tmp_app_dir}/

plist_file=${tmp_app_dir}/Contents/Info.plist

log "Extracting CFBundleIdentifier value from Info.plist"
current_id=$(plutil -extract CFBundleIdentifier xml1 -o - ${plist_file} | xmllint --xpath //string/text\(\) 2>/dev/null -)
log "Extracting CFBundleIdentifier value from Info.plist [${current_id}]"

if [[ "${current_id}" == "" ]]; then
  log "Updating info.plist setting CFBundleIdentifier to '${id}'"
  plutil -replace CFBundleIdentifier -string ${id} ${plist_file}
elif [[ "${current_id}" != "${id}" ]]; then
  log "error: Identifier found in Info.plist [${current_id}] is different from Identifier passed as ${script_name} argument [${id}]"
  exit 1
fi

log "Remove invalid LC_RPATH referencing absolute directories"
for lib in $(find ${tmp_app_dir}/Contents/lib/${lib_subdir} -perm +111 -type f -name "*.dylib");  do
  args=""
  for absolute_rpath in $(otool -l ${lib} | grep -A 3 LC_RPATH | grep "path /" | tr -s ' ' | cut -d" " -f3); do
    args="${args} -delete_rpath ${absolute_rpath}"
  done
  if [[ ${args} != "" ]]; then
    log "  fixing ${lib}"
    install_name_tool ${args} ${lib}
  fi
done

chmod -R ugo+rX ${tmp_app_dir}

do_sign(){
  codesign --verify --verbose=4 --options=runtime -i ${id} -s "${cert_name_app}" $@
  if [ $? -ne 0 ]
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
  paths=""
  for path in "$@"; do
    paths="$paths $path"
    ((++idx))
    if [[ $(($idx % $max_args)) == 0 ]]; then
      do_sign ${paths}
      paths=""
    fi
  done
  if [[ $paths != "" ]]; then
    do_sign ${paths}
  fi
}

# Exclude files incorrectly marked as executable (png, python scripts, ...)
for dir in \
    bin \
    lib \
; do
  log "Signing ${dir}"
  sign_paths $(find ${tmp_app_dir}/Contents/${dir} -perm +111 -type f ! -name "*.py" ! -name "*.png" )
done

log "Signing App"
do_sign --deep "${tmp_app_dir}"

# Exit and detach if signing failed
if [ $? -ne 0 ]
then
  hdiutil detach "${tmp_vol_name}"
  hdiutil detach "${vol_name}"
  exit
fi

log "Copy signed files back to ${app_dir}"
rm -rf ${app_dir}/*
cp -aR ${tmp_app_dir}/* ${app_dir}/

log "Generating PKG"
pkgbuild --sign "${cert_name_inst}" --root ${app_dir} --identifier ${id} --version ${ver} --install-location="/Applications/${app_name}" ${pkg_base}.pkg

log "Umount temporary volume: ${tmp_vol_name}"
hdiutil detach ${tmp_vol_name}

log "Remove temporary DMG: ${tmp_dmg_name}"
rm -f ${tmp_dmg_name}

log "Umount volume: ${vol_name}"
hdiutil detach "${vol_name}"

log "Convert to intermediate format needed for rez tool."
hdiutil convert ${pkg_base}.rw.dmg -format UDRO -o ${pkg_base}.ro
rm -f ${pkg_base}.rw.dmg

log "Re-insert SLA with rez tool."
hdiutil unflatten ${pkg_base}.ro.dmg
Rez sla.r -a -o ${pkg_base}.ro.dmg
hdiutil flatten ${pkg_base}.ro.dmg
rm -f sla.r

log "Convert back to read-only, compressed image."
hdiutil convert ${pkg_base}.ro.dmg -format UDZO -imagekey zlib-level=9 -ov -o ${pkg}
rm -f ${pkg_base}.ro.dmg

log "Signing DMG"
codesign --verify --verbose --display --deep -i ${id} -s "${cert_name_app}" ${pkg}

log "Mount signed DMG"
device=$(yes | hdiutil attach -noverify ${pkg} | grep 'Apple_HFS' | egrep '^/dev/' | sed 1q | awk '{print $1}')

log "Checking mounted filesystem: ${device}"
fsck_hfs ${device}

log "Check if Gatekeeper will accept the app's signature: ${app_dir}"
spctl -a -t exec -vv ${app_dir}

log "Umount volume: ${vol_name}"
hdiutil detach "${vol_name}"
