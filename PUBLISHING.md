# Publishing the ZebChat iOS SDK

Released from the public mirror's GitHub Actions (macOS runners), so no Mac is needed.

## Accounts

- GitHub repository **`techavenuelabs/zebchat-ios`** (public): the mirror of `sdks/ios`. Swift Package
  Manager needs `Package.swift` at a repository root, so the monorepo cannot be the package
  source (same approach as the Drupal module).
- CocoaPods trunk owner for the pod **`ZebChat`** (hello@zebchat.com). Without Ruby, register
  through the trunk API, click the link in the email, then store the returned `token` as the
  mirror's Actions secret `COCOAPODS_TRUNK_TOKEN` (Settings → Secrets and variables → Actions):

  ```bash
  curl -s -X POST https://trunk.cocoapods.org/api/v1/sessions -H 'Content-Type: application/json'     -d '{"email":"hello@zebchat.com","name":"ZebChat","description":"GitHub Actions"}'
  ```

  Co-owners: `pod trunk add-owner ZebChat <email>`.

## Versioning

Semantic versioning, tags **without** a `v` prefix (`1.0.0`), as SPM and CocoaPods expect.

- Patch: fixes. Minor: new API, backward compatible. Major: breaking API changes or a higher
  minimum iOS.
- Bump **both** `ZebChat.version` in `Sources/ZebChat/ZebChat.swift` (sent to the API as
  `sdk=ios/<version>`) and `s.version` in `ZebChat.podspec`; `VersionTests` fails if they differ.
- The bridge version (`MobileBridge.version`) changes only with the `mobile.html` contract in
  `packages/types/src/mobile.ts`, never with a release.

## Release

1. CI green on `main` for `.github/workflows/sdk-ios.yml` (unit tests, example build, `pod lib lint`).
2. Copy `sdks/ios` (tracked files, `git archive HEAD:sdks/ios`) into a clone of the mirror,
   commit and push `main`. `.github/workflows/release.yml` comes with it and is only active there.
3. Tag the mirror and push the tag (`git tag 1.0.0 && git push origin 1.0.0`, no `v` prefix).
   SPM resolves the tag directly. The Release workflow checks the tag against the podspec and
   `ZebChat.version`, runs the unit tests and runs `pod trunk push`. Create a GitHub release for
   the tag with the changelog.
4. Check https://cocoapods.org/pods/ZebChat (the trunk index can take a few minutes).
5. Then release the wrappers that depend on it (Flutter `zebchat`, `@zebchat/react-native`) with
   their pod dependency raised to the new version. Native SDKs always go first.

## Local consumers

The Flutter and React Native examples resolve the pod from the monorepo:

```ruby
pod 'ZebChat', :path => '../../../ios'
```
