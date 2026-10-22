# Homebrew distribution

FVM GUI is distributed as a versioned macOS cask from a separate tap. The app repo's release workflow builds an unsigned Release app when a `v*` tag is pushed, publishes `FVM-GUI.zip` and its SHA-256 file to GitHub Releases, and attaches a matching `fvm-gui.rb` cask file.

## Bootstrap the tap

Create a public GitHub repository named `homebrew-tap` under `lephuhao24`. After the first app release completes, download `fvm-gui.rb` from that release and commit it to `Casks/fvm-gui.rb` in the tap repository. For later app releases, replace that cask file with the matching release asset and push the update.

Users can then install with:

```sh
brew install --cask lephuhao24/tap/fvm-gui
```

The cask requires macOS 14 or newer. The fully qualified install command trusts only this cask in the non-official tap; users should review the cask and release before installing. Users who want to install by short name can first run `brew trust --cask lephuhao24/tap/fvm-gui`.

## Release a version

Update `MARKETING_VERSION` in the Xcode project, commit the release source, and push a matching tag such as `v1.0`. The tag version must use numeric `major.minor` or `major.minor.patch` form and match the app's marketing version. GitHub Actions builds with Xcode 27, creates the ZIP without code signing, calculates its SHA-256, publishes the release assets, and generates the cask from the exact ZIP checksum. To retry or finish an existing tag after a workflow change, run the workflow manually from the default branch and enter that tag.

The workflow requires GitHub Actions to be enabled with the default `GITHUB_TOKEN` permissions for release contents. It does not need an Apple signing secret for tester releases.

## Signing before wider distribution

The current workflow intentionally publishes unsigned, unnotarized tester builds. They may trigger Gatekeeper warnings and are only suitable for a small group that trusts the release source and verifies its checksum. Do not present them as ready for broad public distribution.

Before wider distribution, add a Developer ID Application signing identity and notarization credentials to protected GitHub Actions secrets. Update the workflow to sign the app with Hardened Runtime, submit it with `notarytool`, wait for acceptance, staple the ticket with `stapler`, and verify the signed app before creating the ZIP. Apple requires Developer ID signing and Hardened Runtime for notarization. See [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [Homebrew's tap guide](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap).
