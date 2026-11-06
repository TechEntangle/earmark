import CoreSpotlight
import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  // a conversation tapped in Spotlight
  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if userActivity.activityType == CSSearchableItemActionType,
      let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String
    {
      IntentBridge.shared.send("conversation", ["id": id])
      return
    }
    super.scene(scene, continue: userActivity)
  }
}
