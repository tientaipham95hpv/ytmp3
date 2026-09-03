# CarPlay activation

The CarPlay browsing and playback integration is implemented in
`OfflineTube/Services/CarPlayCoordinator.swift`, but it is deliberately not
registered in the shipping unsigned build.

Apple treats CarPlay Audio as a managed capability. Before activating it:

1. Request and receive Apple's CarPlay Audio approval.
2. Enable the capability on the App ID and regenerate the provisioning profile.
3. Add `com.apple.developer.carplay-audio = true` to the signed target's
   entitlements file.
4. Add a `CPTemplateApplicationSceneSessionRoleApplication` configuration to
   `UIApplicationSceneManifest` in `Info.plist`, using
   `CPTemplateApplicationScene` as the scene class and
   `$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate` as the delegate class.
5. Build with the approved provisioning profile and test with Apple's CarPlay
   Simulator and a physical CarPlay head unit.

Do not add the entitlement to an unsigned or unapproved profile. It won't make
the app appear in CarPlay and can cause signing or installation failures.
