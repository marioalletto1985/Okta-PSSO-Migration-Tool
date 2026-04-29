# P.S.E.U.D.O. — Okta Only Edition

**Platform SSO Enforcement (of) User Device Onboarding**

A customised fork of [Macjutsu/pseudo](https://github.com/Macjutsu/pseudo) for Zilch Technology's macOS fleet, tailored to enforce Okta Platform SSO registration via Jamf Pro.

---

## Overview

P.S.E.U.D.O. automates the Platform SSO onboarding experience for end users. It guides them through Touch ID setup and Okta Platform SSO registration with interactive swiftDialog prompts, then restarts the Mac to finalise device enrolment.

This edition is purpose-built for Zilch's environment:

- **Okta-only** — Workspace ONE and Microsoft Entra ID references removed
- **Jamf Pro managed** — deployed as a Jamf Pro policy
- **macOS Tahoe compatible** — handles `POUserStateNormal (0)` state string
- **Post-registration restart** — ensures Desktop MFA is activated

---

## Workflow

1. Startup checks                                 │
│     • macOS 15+ validation                      │
│     • swiftDialog install/validate              │
│     • Active user detection                     │
│     • Okta Verify installed                     │
│     • Platform SSO config profile present       │
├─────────────────────────────────────────────────┤
│  2. Touch ID (Required)                         │
│     • Prompts user to enrol fingerprint         │
│     • Waits for bioutil confirmation            │
├─────────────────────────────────────────────────┤
│  3. Platform SSO Registration                   │
│     • Multi-method open:                        │
│       ① app-sso platform -a (primary)           │
│       ② app-sso -l + Notification Centre        │
│       ③ System Settings UI scripting            │
│     • Monitors registration state               │
│     • Handles IdP password sync                 │
│     • Verifies via dscl + app-sso platform -s   │
├─────────────────────────────────────────────────┤
│  4. Post-registration                           │
│     • Jamf Pro inventory update (recon)         │
│     • 10-minute restart countdown               │
│     • Backgrounded shutdown (Jamf can report)   │


---

## Requirements

| Requirement | Detail |
|-------------|--------|
| macOS | 15 Sequoia or newer (tested on macOS 26 Tahoe) |
| Architecture | Apple Silicon (arm64) |
| MDM | Jamf Pro with Extensible SSO profile deployed |
| IdP | Okta with Platform SSO configured |
| Software | [Okta Verify.app](https://help.okta.com/en-us/content/topics/mobile/okta-verify-overview.htm) installed |
| Dialog | [swiftDialog 3.0.1](https://github.com/swiftDialog/swiftDialog) (auto-installed if missing) |
| Privileges | Must run as root |

---

## Configuration

All configuration is set in the `set_defaults()` function:

```bash
DISPLAY_ORGANIZATION_NAME="Zilch"      # Shown in user-facing dialogs
TOUCH_ID_CONFIG="REQUIRED"             # REQUIRED | OPTIONAL | "" (disabled)
ENABLE_AUTOFILL_EXTENSIONS="TRUE"      # Auto-enable Okta AutoFill extensions
UPDATE_JAMF_PRO="TRUE"                 # Run jamf recon after registration
REPAIR_MODE=""                         # Set to "TRUE" to force re-registration


