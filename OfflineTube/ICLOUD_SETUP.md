# iCloud metadata sync setup

OfflineTube keeps SwiftData as the local source of truth and uses the user's
private CloudKit database for metadata replication. Media and artwork files are
not uploaded. The app continues using its local SwiftData store when iCloud is
offline, signed out, unavailable, or disabled in Settings.

## Required Apple capability

For an Apple Developer/App Store build, open the `OfflineTube` target in Xcode:

1. Signing & Capabilities → `+ Capability` → **iCloud**.
2. Enable **CloudKit** (not iCloud Documents or key-value storage).
3. Select or create a container, for example
   `iCloud.com.personal.OfflineTube`.
4. Regenerate the provisioning profile so it contains:
   `com.apple.developer.icloud-services = CloudKit` and
   `com.apple.developer.ubiquity-container-identifiers` for that container.
5. Exercise the app against CloudKit's Development environment, inspect the
   generated `MediaMetadata`, `MediaPlaylist`, and `AppSettings` record types,
   then deploy the schema to Production in CloudKit Console before release.

Do not add these entitlements to the unsigned/sideload release workflow unless
the signing identity and provisioning profile actually authorize the selected
container. Without the capability, enabling the toggle reports that iCloud is
unavailable and leaves all local data untouched.

## Conflict and identity rules

- Media records use `sourceID` as their stable identity; playlist records use
  their UUID. This prevents duplicate metadata and playlists across pulls.
- On first contact for a media source, its existing cloud metadata becomes the
  baseline; after that, latest metadata edit wins. Play count is merged using the maximum value and
  recently played keeps the latest date.
- Playlist membership is stored by stable media `sourceID`, not a device-local
  file path. References resolve when that media exists on the current device.
- Local media filenames and artwork filenames never leave the device.
