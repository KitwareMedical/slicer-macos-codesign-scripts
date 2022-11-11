# Slicer macOS codesigning scripts

macOS shell script to extract, codesign, and re-packsign a dmg package for either Slicer or Slicer-based applications.
The script also create a pkg installer.

## Usage

See https://github.com/Slicer/Slicer/wiki/Signing-Application-Packages#macos

## Acknowledgments and History

* 2022

  * Renamed `macos-codesign-scripts` to `slicer-macos-codesign-scripts`

  * The `macos-codesign-scripts` repository was transferred from the `jcfr` GitHub user to the `KitwareMedical` GitHub organization.

  * Jean-Christophe Fillion-Robin updated entitlements to support installing Slicer extensions or python packages providing unsigned libraries. See [Slicer#6065](https://github.com/Slicer/Slicer/issues/6065#issuecomment-1132504575)

* 2020: Jean-Christophe Fillion-Robin updated the signing script and included the required entitlements to support notarization.

* 2018: Jean-Christophe Fillion-Robin created `https://github.com/jcfr/macos-codesign-scripts` adapted from an original script contributed by Chuck Atkins.

* 2016: Max Smolens created the page [https://www.slicer.org/wiki/Documentation/Nightly/Developers/Mac_OS_X_Code_Signing](https://web.archive.org/web/20210117191150/https://www.slicer.org/wiki/Documentation/Nightly/Developers/Mac_OS_X_Code_Signing).

## License

It is covered by the Apache License Version 2.0:

https://www.apache.org/licenses/LICENSE-2.0

The license file was added at revision [d50ac0f][commit-add-license] on 2022-10-11, but you may
consider that the license applies to all prior revisions as well.

[commit-add-license]: https://github.com/KitwareMedical/slicer-macos-codesign-scripts/commit/d50ac0fb28d09d6262d34c6a335132b79a322734
