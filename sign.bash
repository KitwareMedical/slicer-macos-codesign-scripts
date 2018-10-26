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

log "Resize"
# Avoid error like the following:
#
#  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/codesign_allocate:
#  can't write output file: /Volumes/Slicer-4.10.0-macosx-amd64/Slicer.app/Contents/Frameworks/QtWebEngineCore.framework/Versions/Current/QtWebEngineCore.cstemp (No space left on device)
#  /Volumes/Slicer-4.10.0-macosx-amd64/Slicer.app: the codesign_allocate helper tool cannot be found or used
#
hdiutil resize -size 2g ${pkg_base}.rw.dmg

log "Mount"
hdiutil attach -mountpoint ${vol_name} ${pkg_base}.rw.dmg
app_dir=$(ls -d ${vol_name}/*.app)
log "  ${app_dir}"

log "Cleanup Slicer QtWebEngineCore framework"
framework_dir=${app_dir}/Contents/Frameworks/QtWebEngineCore.framework
if [ -d ${framework_dir}/Helpers ]; then
  pushd ${framework_dir} > /dev/null
  mv -v Helpers Versions/Current/Helpers
  executable=Versions/Current/Helpers/QtWebEngineProcess.app/Contents/MacOS/QtWebEngineProcess
  install_name_tool -rpath @loader_path/../../../../../../ @loader_path/../../../../../../../../ $executable
  ln -s Versions/Current/Helpers Helpers
  popd > /dev/null
fi

log "Remove invalid LC_RPATH referencing absolute directories"
for lib in $(find ${app_dir}/Contents/lib/Slicer-4.10 -perm +111 -type f -name "*.dylib");  do
  args=""
  for absolute_rpath in $(otool -l ${lib} | grep -A 3 LC_RPATH | grep "path /" | tr -s ' ' | cut -d" " -f3); do
    args="${args} -delete_rpath ${absolute_rpath}"
  done
  if [[ ${args} != "" ]]; then
    log "  fixing ${lib}"
    install_name_tool ${args} ${lib}
  fi
done


chmod -R ugo+rX ${app_dir}

do_sign(){
  codesign --verify --verbose=4 -i ${id} -s "${cert_name_app}" $@
  if [ $? -ne 0 ]
  then
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

# Explicitly sign executable files outside of standard location but exclude
# libraries that are opened using dlopen (Qt Plugins and python modules), and
# exclude files incorrectly marked as executable (png, python scripts, ...)
for dir in \
    bin \
    lib/Slicer-4.10 \
; do
  log "Signing ${dir}"
  sign_paths $(find ${app_dir}/Contents/${dir} -perm +111 -type f ! -name "*Python.so" ! -name "*PythonQt.so" ! -name "*.py" ! -name "*.png" ! -name "*PythonD.dylib")
done

log "Signing App"
do_sign --deep "${app_dir}"
if [ $? -ne 0 ]
then
  hdiutil detach "${vol_name}"
  exit
fi

log "Generating PKG"
pkgbuild --sign "${cert_name_inst}" --root ${app_dir} --identifier ${id} --version ${ver} --install-location="/Applications/${app_name}" ${pkg_base}.pkg

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
