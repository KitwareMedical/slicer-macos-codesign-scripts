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

umask 022

id="$1"
ver="$2"
pkg="$5"
pkg_base="$(basename ${pkg} .dmg)"
vol_name="/Volumes/${pkg_base}"
cert_name_app="$3"
cert_name_inst="$4"

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

log "Mount"
hdiutil attach -mountpoint ${vol_name} ${pkg_base}.rw.dmg
app_dir=$(ls -d ${vol_name}/*.app)
log "  ${app_dir}"

log "Cleanup frameworks"
for D in ${app_dir}/Contents/Frameworks/*.framework
do
  echo "  $(basename ${D})"
  if [ -d ${D}/Helpers ]
  then
    pushd ${D} > /dev/null
    mv -v Helpers Versions/Current/Helpers
    popd > /dev/null
  fi
done
chmod -R ugo+rX ${app_dir}

log "Signing App"
codesign --verify --verbose=4 --deep -i ${id} -s "${cert_name_app}" "${app_dir}"
if [ $? -ne 0 ]
then
  hdiutil detach "${vol_name}"
  exit
fi

log "Generating PKG"
pkgbuild --sign "${cert_name_inst}" --root ${app_dir} --identifier ${id} --version ${ver} --install-location="/Applications/${app_name}" ${pkg_base}.pkg

log "Convert to intermediate format needed for rez tool."
hdiutil detach "${vol_name}"
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
