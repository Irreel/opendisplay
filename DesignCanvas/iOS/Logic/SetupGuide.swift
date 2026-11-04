// What the waiting screen's setup guide hands the designer to paste into Claude Code on the
// Mac. It asks Claude Code to make exactly the change the Mac app's "every session" switch
// makes (X20, `ClaudeSettingsManager`): the mod inside the installed app, listed in
// `CLAUDE_CODE_PLUGIN_DIRS`. Same path, so the switch reads as on afterwards, and turning it
// off there undoes this too. `SetupGuideTests` holds the two to each other.

import Foundation

enum SetupGuide {
    /// The Release Mac app's bundle id, which is also how the mod finds the app
    /// (`MAC_BUNDLE_ID` in `mod/hooks/register.js`).
    static let macBundleID = "com.designcanvas.mac"

    static let modPrompt = """
    Turn on Design Canvas for every Claude Code session on this Mac:

    1. Find the Design Canvas app with mdfind "kMDItemCFBundleIdentifier == '\(macBundleID)'" (usually /Applications/Design Canvas.app). If it isn't installed, stop and tell me. If there are several, ask me which one.
    2. Its mod is the folder Contents/Resources/mod inside the app. Check that hooks/register.js is in it.
    3. Add that folder's absolute path to env.CLAUDE_CODE_PLUGIN_DIRS in ~/.claude/settings.json. The value is a ":"-separated list: keep the entries already in it and don't add the path twice. Change nothing else in the file, and if it isn't valid JSON, stop and tell me.
    4. Tell me when it's done. New Claude Code sessions load Design Canvas from then on.
    """
}
