#!/bin/bash
# P.S.E.U.D.O.
# Platform SSO Enforcement (of) User Device Onboarding
# https://github.com/Macjutsu/pseudo
# by Kevin M. White
# Modified: by Mario Alletto for Zilch Technology — April 2026
# Based on upstream v1.0.0-beta5 with Zilch-specific customisations:
#   - Okta-only (Workspace ONE removed)
#   - Mandatory Touch ID
#   - Post-PSSO restart workflow (backgrounded for Jamf policy completion)
#   - Moveable dialogs
#   - Multi-method PSSO registration open (app-sso platform -a primary)
#   - macOS Tahoe state compatibility (POUserStateNormal)

# The next line disables specific ShellCheck codes (https://github.com/koalaman/shellcheck) for the entire script.
# shellcheck disable=SC1003,SC2012,SC2024,SC2207

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
PSEUDO_VERSION="1.0.0-beta5-zilch1"
readonly PSEUDO_VERSION
PSEUDO_DATE="2026/04/28"
readonly PSEUDO_DATE
PSEUDO_USER_AGENT="pseudo/${PSEUDO_VERSION} $(curl --version | head -1 | sed -e 's/curl /curl\//')"
readonly PSEUDO_USER_AGENT

# MARK: *** Startup Workflow ***
################################################################################

# Set default parameters that are used throughout the script.
set_defaults() {
	# Optionally check for the installation of configuration profiles that would be required for the Platform SSO workflow.
	# The format is a comma-separated list of configuration profile identifiers (no spacing around commas).
	# A blank "" value will disable this optional validation.
	CHECK_REQUIRED_CONFIG_PROFILES=""
	readonly CHECK_REQUIRED_CONFIG_PROFILES
	
	# Optionally enable the Touch ID configuration workflow.
	# Supported values: "REQUIRED" or "OPTIONAL". Any other value disables the workflow.
	TOUCH_ID_CONFIG="REQUIRED"
	readonly TOUCH_ID_CONFIG
	
	# Optionally automatically enable Platform SSO related AutoFill extensions.
	# Any value besides "TRUE" disables this option.
	ENABLE_AUTOFILL_EXTENSIONS="TRUE"
	readonly ENABLE_AUTOFILL_EXTENSIONS
	
	# Optional mode that will always run the Platform SSO registration workflow even if previously registered.
	# Any value besides "TRUE" disables this option.
	REPAIR_MODE=""
	readonly REPAIR_MODE
	
	# Optionally (after successful Platform SSO enrolment) update Jamf Pro device inventory.
	# Any value besides "TRUE" disables this option.
	UPDATE_JAMF_PRO="TRUE"
	readonly UPDATE_JAMF_PRO
	
	# *** The remaining parameters are NOT OPTIONAL but can be modified to fit your workflow. ***
	################################################################################
	
	# The name of your company or organisation that appears in dialogs:
	DISPLAY_ORGANIZATION_NAME="Zilch"
	readonly DISPLAY_ORGANIZATION_NAME
	
	# The default screen position for dialogs.
	DISPLAY_DIALOG_POSITION="topright"
	readonly DISPLAY_DIALOG_POSITION
	
	# Path to the log for the main pseudo workflow:
	PSEUDO_LOG="/var/log/pseudo.log"
	readonly PSEUDO_LOG
	
	# The number of seconds to timeout workflow processes if no progress is reported.
	TIMEOUT_WORKFLOW_SECONDS=300
	readonly TIMEOUT_WORKFLOW_SECONDS
	
	# The number of seconds to timeout while waiting for the user to make a selection in swiftDialog.
	TIMEOUT_DIALOG_SECONDS=60
	readonly TIMEOUT_DIALOG_SECONDS
	
	# The number of seconds to timeout while waiting for a system dialog to open.
	TIMEOUT_OPEN_SECONDS=10
	readonly TIMEOUT_OPEN_SECONDS
	
	# Seconds to wait after the PSSO window closes before attempting to re-open.
	PSSO_REOPEN_GRACE_SECONDS=30
	readonly PSSO_REOPEN_GRACE_SECONDS
	
	# Maximum seconds to spend verifying PSSO state via app-sso after dscl confirms registration.
	PSSO_STATE_VERIFY_SECONDS=30
	readonly PSSO_STATE_VERIFY_SECONDS
	
	# Path to the local application restrictions managed PLIST.
	APP_MANAGED_PLIST="/Library/Managed Preferences/com.apple.applicationaccess.plist"
	readonly APP_MANAGED_PLIST
	
	# Path to the local Extensible SSO managed PLIST.
	SSO_MANAGED_PLIST="/Library/Managed Preferences/com.apple.extensiblesso.plist"
	readonly SSO_MANAGED_PLIST
	
	# Target version for swiftDialog:
	SWIFT_DIALOG_TARGET_VERSION="3.0.1"
	readonly SWIFT_DIALOG_TARGET_VERSION
	
	# URL to the swiftDialog package installer download:
	SWIFT_DIALOG_DOWNLOAD_URL="https://github.com/swiftDialog/swiftDialog/releases/download/v3.0.1/dialog-3.0.1-4955.pkg"
	readonly SWIFT_DIALOG_DOWNLOAD_URL
	
	# Path to the local swiftDialog binary:
	SWIFT_DIALOG_BINARY="/usr/local/bin/dialog"
	readonly SWIFT_DIALOG_BINARY
	
	# Path to the local swiftDialog command file:
	SWIFT_DIALOG_COMMAND_FILE="/var/tmp/dialog.log"
	readonly SWIFT_DIALOG_COMMAND_FILE
	
	# Path to the Jamf Pro binary:
	JAMF_PRO_BINARY="/usr/local/bin/jamf"
	readonly JAMF_PRO_BINARY
}

# Append input to the command line and log located at ${PSEUDO_LOG}.
log_pseudo() {
	echo -e "$(date +"%a %b %d %T") $(hostname -s) $(basename "$0")[$$]: $*" | tee -a "${PSEUDO_LOG}"
}

# Send input to the command line only.
log_echo() {
	echo -e "$(date +"%a %b %d %T") $(hostname -s) $(basename "$0")[$$]: Not Logged: $*"
}

# Exit the script with no errors.
exit_success() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}"
	log_pseudo "**** P.S.E.U.D.O. ${PSEUDO_VERSION} - ${PSEUDO_DATE} - EXIT SUCCESS ****"
	exit 0
}

# Exit the script due to an unrecoverable error.
exit_error() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}"
	log_pseudo "**** P.S.E.U.D.O. ${PSEUDO_VERSION} - ${PSEUDO_DATE} - EXIT ERROR ****"
	exit 1
}

# Used prior to another command or function that should be run as the user.
run_as_user() {
	launchctl asuser "${current_user_id}" sudo -u "${current_user_account_name}" "$@"
}

# Helper: check if PSSO state indicates successful registration.
# macOS Tahoe returns "POUserStateNormal (0)" instead of "registered".
psso_is_registered() {
	[[ "${1}" == "registered" ]] || [[ "${1}" == *"Normal"* ]]
}

# Hide all visible applications.
hide_all_apps() {
	osascript > /dev/null 2>&1 <<EOAS
tell application "Finder"
	if (count of windows) is not 0 then
		tell application "Finder" to close every window
		delay 0.1
	end if
end tell
tell application "System Events"
	set visibleApps to every process whose visible is true and name is not "Finder"
	repeat with anApp in visibleApps
		tell anApp to set visible to false
		delay 0.1
	end repeat
end tell
EOAS
}

# Collect parameters for detailed system information.
check_system() {
	macos_version_major=$(sw_vers -productVersion | cut -d'.' -f1)
	macos_version_minor=$(sw_vers -productVersion | cut -d'.' -f2)
	macos_version_patch=$(sw_vers -productVersion | cut -d'.' -f3)
	[[ $macos_version_major -ge 13 ]] && macos_version_extra=$(sw_vers -productVersionExtra | cut -d'.' -f2)
	macos_build=$(sw_vers -buildVersion)
	macos_title="macOS $(awk '/SOFTWARE LICENSE AGREEMENT FOR/' '/System/Library/CoreServices/Setup Assistant.app/Contents/Resources/en.lproj/OSXSoftwareLicense.rtf' | awk -F 'macOS ' '{print $NF}' | awk '{print substr($0, 0, length($0)-1)}' | sed -e 's/[0-9]//g' | xargs)"
	[[ $(echo "${macos_title}" | grep -c 'PRE-RELEASE') -gt 0 ]] && macos_title="macOS Beta"
	mac_cpu_architecture=$(arch)
	if [[ -n $macos_version_patch ]]; then
		[[ -n "${macos_version_extra}" ]] && macos_version_full="${macos_title} ${macos_version_major}.${macos_version_minor}.${macos_version_patch}${macos_version_extra}-${macos_build}"
		[[ -z "${macos_version_extra}" ]] && macos_version_full="${macos_title} ${macos_version_major}.${macos_version_minor}.${macos_version_patch}-${macos_build}"
	else
		[[ -n "${macos_version_extra}" ]] && macos_version_full="${macos_title} ${macos_version_major}.${macos_version_minor}${macos_version_extra}-${macos_build}"
		[[ -z "${macos_version_extra}" ]] && macos_version_full="${macos_title} ${macos_version_major}.${macos_version_minor}-${macos_build}"
	fi
	[[ "${mac_cpu_architecture}" == "arm64" ]] && log_pseudo "Status: Mac computer with Apple silicon running ${macos_version_full}."
	[[ "${mac_cpu_architecture}" == "i386" ]] && log_pseudo "Status: Mac computer with Intel running ${macos_version_full}."
}

# Set ${current_user_account_name} to the currently logged in GUI user or "FALSE" if none.
check_current_user() {
	current_user_account_name="FALSE"
	local current_user_account_name_response
	current_user_account_name_response=$(scutil <<<"show State:/Users/ConsoleUser" | awk '/Name :/ {$1=$2="";print $0;}' | xargs)
	
	if [[ -z "${current_user_account_name_response}" ]] || [[ "${current_user_account_name_response}" == "root" ]] || [[ "${current_user_account_name_response}" == "_mbsetupuser" ]] || [[ "${current_user_account_name_response}" == "loginwindow" ]]; then
		return 0
	else
		current_user_account_name="${current_user_account_name_response}"
		current_user_id=$(id -u "${current_user_account_name}" 2> /dev/null)
		current_user_guid=$(dscl . read "/Users/${current_user_account_name}" GeneratedUID 2> /dev/null | awk '{print $2;}')
		current_user_real_name=$(dscl . read "/Users/${current_user_account_name}" RealName 2> /dev/null | tail -1 | sed -e 's/^RealName: //g' -e 's/^ //g')
		current_user_home_folder=$(dscl . read "/Users/${current_user_account_name}" NFSHomeDirectory 2> /dev/null | awk '{print $2;}')
		current_user_is_admin="FALSE"
		current_user_has_secure_token="FALSE"
		current_user_is_volume_owner="FALSE"
		if [[ -n "${current_user_id}" ]] && [[ -n "${current_user_guid}" ]] && [[ -n "${current_user_real_name}" ]]; then
			[[ $(groups "${current_user_account_name}" 2> /dev/null | grep -c 'admin') -gt 0 ]] && current_user_is_admin="TRUE"
			[[ $(dscl . read "/Users/${current_user_account_name}" AuthenticationAuthority 2> /dev/null | grep -c 'SecureToken') -gt 0 ]] && current_user_has_secure_token="TRUE"
			[[ $(diskutil apfs listcryptousers / 2> /dev/null | grep -c "${current_user_guid}") -gt 0 ]] && current_user_is_volume_owner="TRUE"
		else
			log_pseudo "Error: Unable to determine account details for local user ${current_user_account_name} (${current_user_id})"
			workflow_startup_error="TRUE"
		fi
	fi
}

# Evaluate if the user has a Focus mode enabled which may interfere with notifications.
check_current_user_focus() {
	local plutil_response
	plutil_response=$(plutil -extract data.0.storeAssertionRecords.0.assertionDetails.assertionDetailsModeIdentifier raw -o - "${current_user_home_folder}/Library/DoNotDisturb/DB/Assertions.json" 2>&1)
	if [[ $(echo "${plutil_response}" | grep -c 'permission') -gt 0 ]]; then
		log_pseudo "Warning: Unable to determine user Focus mode because the process that started pseudo doesn't have Full Disk Access permissions."
	elif [[ $(echo "${plutil_response}" | grep -c 'com.apple.') -gt 0 ]]; then
		log_pseudo "Warning: The current user has a Focus mode enabled. This may cause the workflow to fail."
	fi
}

# Get the user's default browser and set ${current_user_default_browser}.
check_current_user_default_browser() {
	local plutil_response
	plutil_response=$(/usr/libexec/PlistBuddy -c "Print :LSHandlers" "${current_user_home_folder}/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist" 2>&1)
	if [[ $(echo "${plutil_response}" | grep -c 'Does Not Exist') -gt 0 ]]; then
		log_pseudo "Warning: Unable to determine user's default browser because the process doesn't have Full Disk Access permissions."
	else
		current_user_default_browser=$(echo "${plutil_response}" | grep -B1 'https' | head -1 | awk '{print $3}')
		log_pseudo "Status: The default browser for user ${current_user_account_name} is Bundle ID ${current_user_default_browser}."
	fi
	if [[ -z "${current_user_default_browser}" ]]; then
		log_pseudo "Warning: No default browser set for user ${current_user_account_name} so assuming Safari."
		current_user_default_browser="com.apple.safari"
	fi
}

# Validate installed configuration profiles based on "${CHECK_REQUIRED_CONFIG_PROFILES}" option.
check_config_profiles() {
	local check_config_profiles_error
	check_config_profiles_error="FALSE"
	local profiles_result
	profiles_result=$(profiles list -output stdout-xml)
	local previous_ifs
	previous_ifs="${IFS}"
	IFS=','
	local required_config_profiles_array
	read -r -a required_config_profiles_array <<<"${CHECK_REQUIRED_CONFIG_PROFILES}"
	for required_config_profile in "${required_config_profiles_array[@]}"; do
		[[ $(echo "${profiles_result}" | grep -c "${required_config_profile}") -eq 0 ]] && log_pseudo "Error: No installed configuration profile matches the following required identifier: ${required_config_profile}" && check_config_profiles_error="TRUE"
	done
	IFS="${previous_ifs}"
	[[ "${check_config_profiles_error}" == "TRUE" ]] && log_pseudo "Error: A required configuration profile is not currently installed." && workflow_startup_error="TRUE"
}

# Prepare pseudo by checking system, Platform SSO config, and user statuses.
workflow_startup() {
	local workflow_startup_error
	workflow_startup_error="FALSE"
	set_defaults
	[[ $(id -u) -ne 0 ]] && log_echo "Exit: pseudo must run with root privileges." && exit 1
	log_pseudo "**** P.S.E.U.D.O. ${PSEUDO_VERSION} - ${PSEUDO_DATE} - STARTUP ****"
	
	# Initial system checks.
	check_system
	[[ $macos_version_major -lt 15 ]] && log_pseudo "Exit: This computer is running macOS ${macos_version_major} and pseudo requires macOS 15 Sequoia or newer." && exit_error
	
	# Validate swiftDialog, if missing or invalid then install and check again.
	killall "dialog" > /dev/null 2>&1
	killall "Dialog" > /dev/null 2>&1
	swift_dialog_app=$(readlink "${SWIFT_DIALOG_BINARY}" 2> /dev/null | sed -e 's/\/Contents.*//')
	if [[ ! -e "${swift_dialog_app}" ]] || [[ ! -e "${SWIFT_DIALOG_BINARY}" ]]; then
		get_swift_dialog
		swift_dialog_app=$(readlink "${SWIFT_DIALOG_BINARY}" 2> /dev/null | sed -e 's/\/Contents.*//')
		{ [[ -e "${swift_dialog_app}" ]] && [[ -e "${SWIFT_DIALOG_BINARY}" ]]; } && check_swift_dialog
		[[ "${swift_dialog_valid}" == "FALSE" ]] && log_pseudo "Error: Unable to validate swiftDialog after installation."
	else
		check_swift_dialog
		if [[ "${swift_dialog_valid}" == "FALSE" ]]; then
			get_swift_dialog
			swift_dialog_app=$(readlink "${SWIFT_DIALOG_BINARY}" 2> /dev/null | sed -e 's/\/Contents.*//')
			{ [[ -e "${swift_dialog_app}" ]] && [[ -e "${SWIFT_DIALOG_BINARY}" ]]; } && check_swift_dialog
		fi
		[[ "${swift_dialog_valid}" == "FALSE" ]] && log_pseudo "Error: Unable to validate swiftDialog after re-installation."
	fi
	[[ "${swift_dialog_valid}" == "FALSE" ]] && workflow_startup_error="TRUE"
	
	# Make sure that we have an active local user account.
	check_current_user
	if [[ "${workflow_startup_error}" == "FALSE" ]] && [[ "${current_user_account_name}" == "FALSE" ]]; then
		log_pseudo "Status: Waiting for an active user with a ${TIMEOUT_WORKFLOW_SECONDS} second timeout..."
		local wait_for_gui_user_start_epoch
		wait_for_gui_user_start_epoch=$(date +%s)
		while [[ "${current_user_account_name}" == "FALSE" ]]; do
			if [[ $(( wait_for_gui_user_start_epoch + TIMEOUT_WORKFLOW_SECONDS )) -lt $(date +%s) ]]; then
				log_pseudo "Error: Waiting for an active user timed out after ${TIMEOUT_WORKFLOW_SECONDS} seconds." && workflow_startup_error="TRUE"
				break
			fi
			sleep 1
			check_current_user
		done
		[[ "${current_user_account_name}" != "FALSE" ]] && log_pseudo "Status: Waiting for an active user took $(( $(date +%s) - wait_for_gui_user_start_epoch )) seconds to complete."
	fi
	
	# Wait for Dock and Finder to open.
	if [[ "${workflow_startup_error}" == "FALSE" ]] && { [[ ! $(pgrep -x "Dock" 2> /dev/null) ]] || [[ ! $(pgrep -x "Finder" 2> /dev/null) ]]; }; then
		log_pseudo "Status: Waiting for the Dock and Finder to open with a ${TIMEOUT_WORKFLOW_SECONDS} second timeout..."
		local wait_for_gui_apps_start_epoch
		wait_for_gui_apps_start_epoch=$(date +%s)
		while [[ ! $(pgrep -x "Dock" 2> /dev/null) ]] || [[ ! $(pgrep -x "Finder" 2> /dev/null) ]]; do
			if [[ $(( wait_for_gui_apps_start_epoch + TIMEOUT_WORKFLOW_SECONDS )) -lt $(date +%s) ]]; then
				log_pseudo "Error: Waiting for the Dock and Finder to open timed out after ${TIMEOUT_WORKFLOW_SECONDS} seconds." && workflow_startup_error="TRUE"
				break
			fi
			sleep 1
		done
		[[ $(pgrep -x "Dock" 2> /dev/null) ]] && [[ $(pgrep -x "Finder" 2> /dev/null) ]] && log_pseudo "Status: Waiting for the Dock and Finder to open took $(( $(date +%s) - wait_for_gui_apps_start_epoch )) seconds to complete."
	fi
	if [[ "${current_user_account_name}" != "FALSE" ]]; then
		log_pseudo "Status: Current active local user is ${current_user_account_name} (${current_user_id})."
		check_current_user_focus
	fi
	
	# Validate configuration profiles if specified.
	[[ -n "${CHECK_REQUIRED_CONFIG_PROFILES}" ]] && check_config_profiles
	
	# Validate Platform SSO configuration (Okta-only).
	if [[ -e "${SSO_MANAGED_PLIST}" ]]; then
		psso_extension_identifier=$(/usr/libexec/PlistBuddy -c "Print :ExtensionIdentifier" "${SSO_MANAGED_PLIST}" 2> /dev/null)
		psso_login_type=$(/usr/libexec/PlistBuddy -c "Print :PlatformSSO:AuthenticationMethod" "${SSO_MANAGED_PLIST}" 2> /dev/null)
		psso_display_name=$(/usr/libexec/PlistBuddy -c "Print :PlatformSSO:AccountDisplayName" "${SSO_MANAGED_PLIST}" 2> /dev/null)
	fi
	if [[ -z "${psso_extension_identifier}" ]] || [[ -z "${psso_login_type}" ]] || [[ -z "${psso_display_name}" ]]; then
		log_pseudo "Warning: Could not resolve required Platform SSO attributes from managed preference at ${SSO_MANAGED_PLIST}."
		log_pseudo "Status: Attempting failover configuration validation via app-sso command..."
		killall "AppSSOAgent" > /dev/null 2>&1
		sleep 1
		local app_sso_response
		app_sso_response=$(app-sso platform -s 2>/dev/null)
		[[ -z "${psso_extension_identifier}" ]] && psso_extension_identifier=$(echo "${app_sso_response}" | sed -e '1,/Device Configuration:/d' | jq -r '.extensionIdentifier' 2> /dev/null)
		[[ -z "${psso_login_type}" ]] && psso_login_type=$(echo "${app_sso_response}" | sed -e '1,/Device Configuration:/d' | jq -r '.loginType' 2> /dev/null)
		[[ -z "${psso_display_name}" ]] && psso_display_name=$(echo "${app_sso_response}" | sed -e '1,/Device Configuration:/d' | jq -r '.accountDisplayName' 2> /dev/null)
	fi
	if [[ -z "${psso_extension_identifier}" ]] || [[ -z "${psso_login_type}" ]]; then
		[[ -z "${psso_extension_identifier}" ]] && log_pseudo "Error: Could not determine Platform SSO extension identifier." && workflow_startup_error="TRUE"
		[[ -z "${psso_login_type}" ]] && log_pseudo "Error: Could not determine Platform SSO login type." && workflow_startup_error="TRUE"
		[[ -z "${psso_display_name}" ]] && log_pseudo "Warning: Could not determine Platform SSO account display name."
	fi
	
	# Validate Okta Verify is installed.
	if [[ "${psso_extension_identifier}" == "com.okta.mobile.auth-service-extension" ]]; then
		if [[ -e "/Applications/Okta Verify.app" ]]; then
			psso_dialog_icon="/Applications/Okta Verify.app/Contents/Resources/AppIcon.icns"
			check_current_user_default_browser
			[[ -z "${current_user_default_browser}" ]] && workflow_startup_error="TRUE"
		else
			log_pseudo "Error: The required Platform SSO software Okta Verify.app is not installed." && workflow_startup_error="TRUE"
		fi
	else
		log_pseudo "Error: Unexpected Platform SSO extension identifier: ${psso_extension_identifier}. Expected com.okta.mobile.auth-service-extension for Okta." && workflow_startup_error="TRUE"
	fi
	
	if [[ "${workflow_startup_error}" == "FALSE" ]]; then
		local psso_login_type_string=""
		[[ $(echo "${psso_login_type}" | grep -c 'SecureEnclave') -gt 0 ]] && psso_login_type_string="Secure Enclave"
		[[ $(echo "${psso_login_type}" | grep -c 'Password') -gt 0 ]] && psso_login_type_string="IdP Password"
		log_pseudo "Status: Platform SSO configuration for Okta using ${psso_login_type_string} authentication with the display name \"${psso_display_name}\"."
	fi
	
	[[ "${REPAIR_MODE}" == "TRUE" ]] && log_pseudo "Warning: Repair mode is enabled. The Platform SSO registration workflow will run even if previously registered."
	[[ "${workflow_startup_error}" == "TRUE" ]] && log_pseudo "Exit: Startup workflow failed due to errors." && exit_error
}

# MARK: *** swiftDialog Integration ***
################################################################################

# Check swiftDialog application for validity and version number.
check_swift_dialog() {
	swift_dialog_valid="FALSE"
	local codesign_response
	codesign_response=$(codesign --verify --verbose "${swift_dialog_app}" 2>&1)
	if [[ $(echo "${codesign_response}" | grep -c 'valid on disk') -gt 0 ]]; then
		local version_response
		version_response=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${swift_dialog_app}/Contents/Info.plist" 2> /dev/null)
		if [[ "${SWIFT_DIALOG_TARGET_VERSION}" == "${version_response}" ]]; then
			swift_dialog_valid="TRUE"
		else
			log_pseudo "Warning: swiftDialog is version ${version_response}, target is ${SWIFT_DIALOG_TARGET_VERSION}."
		fi
	else
		log_pseudo "Warning: Unable to validate signature for swiftDialog:\n${codesign_response}."
	fi
}

# Download and install swiftDialog.
get_swift_dialog() {
	log_pseudo "Status: Attempting to download swiftDialog..."
	local previous_umask
	previous_umask=$(umask)
	umask 077
	local temp_dialog_pkg
	temp_dialog_pkg="$(mktemp).pkg"
	local download_response
	download_response=$(curl --user-agent "${PSEUDO_USER_AGENT}" --connect-timeout "${TIMEOUT_WORKFLOW_SECONDS}" --max-time "${TIMEOUT_WORKFLOW_SECONDS}" --write-out "Total Time: %{time_total}" --location "${SWIFT_DIALOG_DOWNLOAD_URL}" --output "${temp_dialog_pkg}" 2>&1)
	if [[ -f "${temp_dialog_pkg}" ]]; then
		log_pseudo "Status: Successfully downloaded swiftDialog.pkg:\n${download_response}."
		log_pseudo "Status: Attempting to install swiftDialog..."
		local install_response
		install_response=$(installer -verboseR -pkg "${temp_dialog_pkg}" -target / 2>&1)
		if ! { [[ $(echo "${install_response}" | grep -c 'The software was successfully installed.') -gt 0 ]] || [[ $(echo "${install_response}" | grep -c 'The install was successful.') -gt 0 ]]; }; then
			log_pseudo "Error: Unable to install swiftDialog.pkg:\n${install_response}"
		else
			log_pseudo "Status: Successfully installed swiftDialog.pkg:\n${install_response}."
		fi
	else
		log_pseudo "Error: Unable to download swiftDialog.pkg:\n${download_response}."
	fi
	rm -Rf "${temp_dialog_pkg}" > /dev/null 2>&1
	umask "${previous_umask}"
}

# MARK: *** Jamf Pro Integration ***
################################################################################

# Update Jamf Pro device inventory.
jamf_pro_update_inventory() {
	[[ ! -e "${JAMF_PRO_BINARY}" ]] && log_pseudo "Error: Could not locate the Jamf Pro binary at: ${JAMF_PRO_BINARY}" && update_inventory_error="TRUE" && return 0
	log_pseudo "Status: Updating Jamf Pro inventory..."
	local jamf_recon_response
	jamf_recon_response=$("${JAMF_PRO_BINARY}" recon -verbose 2>&1)
	if [[ $(echo "${jamf_recon_response}" | grep -c 'Submitting data') -gt 0 ]]; then
		log_pseudo "Status: Jamf Pro inventory successfully updated."
	else
		log_pseudo "Error: Could not update Jamf Pro inventory:\n${jamf_recon_response}" && update_inventory_error="TRUE"
	fi
}

# Wrapper to run inventory updates.
run_inventory_updates() {
	update_inventory_error="FALSE"
	[[ "${UPDATE_JAMF_PRO}" == "TRUE" ]] && jamf_pro_update_inventory
	[[ "${update_inventory_error}" == "TRUE" ]] && log_pseudo "Warning: Unable to complete one or more requested inventory updates."
}

# MARK: *** Touch ID Workflow ***
################################################################################

# Check to see if the current user has Touch ID enabled.
check_touch_id_user_status() {
	local bioutil_user_ids
	bioutil_user_ids=($(bioutil -c -s | awk '/User/ {print $2 $3}'))
	if [[ $(echo "${bioutil_user_ids[*]}" | grep -c "${current_user_id}") -gt 0 ]]; then
		echo "TRUE"
	else
		echo "FALSE"
	fi
}

# Open the Touch ID System Settings window and return status.
open_touch_id_system_settings() {
	killall "System Settings" > /dev/null 2>&1
	sleep 1
	run_as_user open "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension"
	local open_result
	open_result=$(osascript 2> /dev/null <<EOAS
set openTimeout to (current date) + ${TIMEOUT_OPEN_SECONDS}
tell application "System Events"
	repeat while not (exists window 1 of application process "System Settings")
		delay 0.1
		if (current date) > openTimeout then return "FALSE"
	end repeat
	return "TRUE"
end tell
EOAS
	)
	echo "${open_result}"
}

# Check the status of the Touch ID System Settings window.
check_touch_id_settings_status() {
	local result
	result=$(osascript 2> /dev/null <<EOAS
if application "System Settings" is running then
	tell application "System Events"
		if title of window 1 of process "System Settings" contains "Touch ID" then
			if exists sheet 1 of window 1 of process "System Settings" then
				return "ACTIVE"
			else
				return "OPEN"
			end if
		else
			return "FALSE"
		end if
	end tell
else
	return "FALSE"
end if
EOAS
	)
	echo "${result}"
}

# Hide all other visible applications so only Touch ID System Settings is visible.
# Uses allowedApps list to preserve browsers/Okta Verify during auth flow.
focus_touch_id_settings() {
	osascript > /dev/null 2>&1 <<EOAS
tell application "System Events"
	set allowedApps to {"System Settings", "Dialog", "Finder", ¬
		"Safari", "Google Chrome", "Microsoft Edge", "Firefox", "Arc", ¬
		"Brave Browser", "Okta Verify"}
	
	set frontApp to name of first application process whose frontmost is true
	
	tell application "Finder"
		if (count of windows) is not 0 then
			close every window
			delay 0.1
		end if
	end tell
	
	set visibleApps to every process whose visible is true
	repeat with anApp in visibleApps
		if name of anApp is not in allowedApps then
			tell anApp to set visible to false
			delay 0.1
		end if
	end repeat
	
	if frontApp is not in allowedApps then
		tell process "System Settings" to set frontmost to true
	end if
end tell
EOAS
}

# Open an interactive swiftDialog informing the user that Touch ID is required.
open_dialog_touch_id_required() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}" && sleep 0.1
	hide_all_apps
	log_pseudo "Dialog Open: Touch ID Setup Required"
	"${SWIFT_DIALOG_BINARY}" \
	--title "Touch ID Setup Required" \
	--message "**Touch ID is required for all Mac computers at ${DISPLAY_ORGANIZATION_NAME}.**<br><br>Touch ID provides enhanced security and convenience by allowing you to authenticate using the Mac computer's fingerprint sensor." \
	--icon "SF=touchid,palette=primary,accent,none" \
	--small \
	--moveable \
	--position "${DISPLAY_DIALOG_POSITION}" \
	--timer "${TIMEOUT_DIALOG_SECONDS}" \
	--hidetimerbar \
	--button1text "Enable Touch ID" \
	--quitkey p \
	--hidedefaultkeyboardaction \
	--ontop
	dialog_touch_id_result=$?
	log_pseudo "Dialog Closed: Touch ID Setup Required"
}

# Open an interactive swiftDialog asking the user if they want to enable Touch ID.
open_dialog_touch_id_optional() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}" && sleep 0.1
	hide_all_apps
	log_pseudo "Dialog Open: Touch ID Setup Optional"
	"${SWIFT_DIALOG_BINARY}" \
	--title "Touch ID Setup" \
	--message "**Please take a few moments to enable Touch ID.**<br><br>Touch ID provides enhanced security and convenience by allowing you to authenticate using the Mac computer's fingerprint sensor." \
	--icon "SF=touchid,palette=primary,accent,none" \
	--small \
	--moveable \
	--position "${DISPLAY_DIALOG_POSITION}" \
	--timer "${TIMEOUT_DIALOG_SECONDS}" \
	--hidetimerbar \
	--button1text "Enable Touch ID" \
	--button2text "Skip" \
	--quitkey p \
	--hidedefaultkeyboardaction \
	--ontop
	dialog_touch_id_result=$?
	log_pseudo "Dialog Closed: Touch ID Setup Optional"
}

# Open a swiftDialog to assist while the user enables Touch ID.
open_dialog_touch_id_start() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}" && sleep 0.1
	log_pseudo "Dialog Open: Touch ID Start"
	"${SWIFT_DIALOG_BINARY}" \
	--title "Touch ID Setup" \
	--message "**Enable Touch ID by adding at least one fingerprint in the Touch ID settings.**" \
	--icon "SF=touchid,palette=primary,accent,none" \
	--mini \
	--moveable \
	--position "${DISPLAY_DIALOG_POSITION}" \
	--button1text none \
	--quitkey p \
	--hidedefaultkeyboardaction \
	--ontop &
	disown $!
}

# Open a swiftDialog to inform the user that Touch ID is enabled.
open_dialog_touch_id_success() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}" && sleep 0.1
	log_pseudo "Dialog Open: Touch ID Success"
	"${SWIFT_DIALOG_BINARY}" \
	--title "Touch ID Enabled" \
	--message "**Thank you for enabling Touch ID!**<br><br>You can register additional fingerprints or click \"OK\" to close the Touch ID settings." \
	--icon "SF=touchid,palette=primary,accent,none" \
	--small \
	--moveable \
	--position "${DISPLAY_DIALOG_POSITION}" \
	--timer "${TIMEOUT_DIALOG_SECONDS}" \
	--hidetimerbar \
	--button1text "OK" \
	--quitkey p \
	--hidedefaultkeyboardaction \
	--ontop
	return $?
}

# Open an interactive swiftDialog informing the user that the Touch ID workflow has failed.
open_dialog_touch_id_failed() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}" && sleep 0.1
	hide_all_apps
	log_pseudo "Dialog Open: Touch ID Failed"
	"${SWIFT_DIALOG_BINARY}" \
	--title "Touch ID Setup Failed" \
	--message "**Touch ID setup has failed.**<br><br>Please contact your administrator if this issue persists." \
	--icon caution \
	--overlayicon "SF=touchid,palette=primary,accent,none" \
	--small \
	--moveable \
	--position "${DISPLAY_DIALOG_POSITION}" \
	--button1text "OK" \
	--quitkey p \
	--hidedefaultkeyboardaction \
	--ontop &
	disown $!
}

# The full workflow to check Touch ID status and enable it if required.
workflow_touch_id() {
	local workflow_touch_id_error
	workflow_touch_id_error="FALSE"
	touch_id_workflow_active="FALSE"
	
	# Initial Touch ID system configuration checks.
	local ioreg_result
	ioreg_result=$(ioreg -l 2> /dev/null)
	if [[ $(echo "${ioreg_result}" | grep -c -e '\"AppleBiometricSensor\"=[1-9]') -gt 0 ]]; then
		touch_id_hardware_status="INTERNAL"
	elif [[ $(echo "${ioreg_result}" | grep -c -e 'with Touch ID') -gt 0 ]]; then
		touch_id_hardware_status="EXTERNAL"
	else
		touch_id_hardware_status="FALSE"
	fi
	if [[ "${touch_id_hardware_status}" != "FALSE" ]]; then
		[[ $(/usr/libexec/PlistBuddy -c "Print :allowFingerprintForUnlock" "${APP_MANAGED_PLIST}" 2> /dev/null) == "false" ]] && touch_id_hardware_status="DISABLED"
		[[ $(/usr/libexec/PlistBuddy -c "Print :allowFingerprintModification" "${APP_MANAGED_PLIST}" 2> /dev/null) == "false" ]] && touch_id_hardware_status="DISABLED"
	fi
	
	# Check Touch ID user status — if already enabled, skip.
	local touch_id_user_status
	if [[ "${touch_id_hardware_status}" == "INTERNAL" ]] || [[ "${touch_id_hardware_status}" == "EXTERNAL" ]]; then
		touch_id_user_status=$(check_touch_id_user_status)
		[[ "${touch_id_user_status}" == "TRUE" ]] && log_pseudo "Status: Touch ID is already enabled for local user ${current_user_account_name} (${current_user_id})." && return 0
	fi
	
	# Handle initial Touch ID dialog based on configuration.
	if [[ "${TOUCH_ID_CONFIG}" == "REQUIRED" ]]; then
		[[ "${touch_id_hardware_status}" == "FALSE" ]] && log_pseudo "Warning: Can't enforce Touch ID because this system does not have Touch ID hardware." && return 0
		[[ "${touch_id_hardware_status}" == "DISABLED" ]] && log_pseudo "Warning: Can't enforce Touch ID because a restrictions profile is preventing it." && return 0
		log_pseudo "Status: Informing user that Touch ID is required for local user ${current_user_account_name} (${current_user_id})."
		open_dialog_touch_id_required
	elif [[ "${TOUCH_ID_CONFIG}" == "OPTIONAL" ]]; then
		[[ "${touch_id_hardware_status}" == "FALSE" ]] && log_pseudo "Warning: Can't ask user to enable Touch ID because no Touch ID hardware available." && return 0
		[[ "${touch_id_hardware_status}" == "DISABLED" ]] && log_pseudo "Warning: Can't ask user to enable Touch ID because a restrictions profile is preventing it." && return 0
		log_pseudo "Status: Asking local user ${current_user_account_name} (${current_user_id}) if they want to enable Touch ID."
		open_dialog_touch_id_optional
	else
		log_pseudo "Status: Touch ID workflow is disabled."
		return 0
	fi
	if [[ "${dialog_touch_id_result}" -eq 2 ]]; then
		log_pseudo "Status: The user chose to skip optional Touch ID enablement." && return 0
	elif [[ "${dialog_touch_id_result}" -eq 4 ]]; then
		log_pseudo "Error: The initial Touch ID dialog timed out after ${TIMEOUT_DIALOG_SECONDS} seconds." && workflow_touch_id_error="TRUE"
	elif [[ "${dialog_touch_id_result}" -gt 0 ]]; then
		log_pseudo "Error: The initial Touch ID dialog returned unexpected result: ${dialog_touch_id_result}" && workflow_touch_id_error="TRUE"
	fi
	
	# Open Touch ID settings and wait for the user to register a fingerprint.
	if [[ "${workflow_touch_id_error}" == "FALSE" ]] && [[ "${touch_id_user_status}" == "FALSE" ]]; then
		log_pseudo "Status: Starting Touch ID workflow with a ${TIMEOUT_WORKFLOW_SECONDS} second timeout..."
		touch_id_workflow_active="TRUE"
		local touch_id_settings_status
		local touch_id_workflow_start_epoch
		touch_id_workflow_start_epoch=$(date +%s)
		log_pseudo "Status: Attempting to open Touch ID System Settings..."
		[[ $(open_touch_id_system_settings) == "FALSE" ]] && log_pseudo "Error: Opening Touch ID System Settings timed out after ${TIMEOUT_OPEN_SECONDS} seconds." && workflow_touch_id_error="TRUE"
		[[ "${workflow_touch_id_error}" == "FALSE" ]] && open_dialog_touch_id_start
		while [[ "${workflow_touch_id_error}" == "FALSE" ]] && { [[ "${touch_id_user_status}" == "FALSE" ]] || { [[ "${touch_id_user_status}" == "TRUE" ]] && [[ "${touch_id_settings_status}" == "ACTIVE" ]]; }; }; do
			if [[ $(( touch_id_workflow_start_epoch + TIMEOUT_WORKFLOW_SECONDS )) -lt $(date +%s) ]]; then
				log_pseudo "Error: Touch ID workflow timed out after ${TIMEOUT_WORKFLOW_SECONDS} seconds." && workflow_touch_id_error="TRUE"
				break
			fi
			focus_touch_id_settings
			touch_id_settings_status=$(check_touch_id_settings_status)
			if [[ "${touch_id_settings_status}" == "FALSE" ]]; then
				log_pseudo "Status: Re-opening Touch ID System Settings (user likely closed it)..."
				[[ $(open_touch_id_system_settings) == "FALSE" ]] && log_pseudo "Error: Opening Touch ID System Settings timed out." && workflow_touch_id_error="TRUE"
			fi
			sleep 1
			touch_id_user_status=$(check_touch_id_user_status)
		done
	fi
	
	# Touch ID has been enabled — ask if user wants to register another fingerprint.
	if [[ "${workflow_touch_id_error}" == "FALSE" ]] && [[ "${touch_id_user_status}" == "TRUE" ]]; then
		focus_touch_id_settings
		open_dialog_touch_id_success
		dialog_touch_id_result=$?
		if [[ "${dialog_touch_id_result}" -eq 4 ]]; then
			log_pseudo "Warning: Touch ID success dialog timed out after ${TIMEOUT_DIALOG_SECONDS} seconds."
		fi
	fi
	
	# Cleanup.
	killall "System Settings" > /dev/null 2>&1
	if [[ "${workflow_touch_id_error}" == "FALSE" ]]; then
		log_pseudo "Status: Touch ID is now enabled for local user ${current_user_account_name} (${current_user_id}). The Touch ID workflow took $(( $(date +%s) - touch_id_workflow_start_epoch )) seconds to complete."
	else
		[[ "${touch_id_workflow_active}" == "TRUE" ]] && open_dialog_touch_id_failed
		log_pseudo "Exit: Touch ID workflow failed due to errors." && exit_error
	fi
}

# MARK: *** Platform SSO Workflow ***
################################################################################

# Lightweight dscl-only check — instant, safe for tight loops.
check_psso_dscl_status() {
	local dscl_result
	dscl_result=$(dscl . read /Users/"${current_user_account_name}" dsAttrTypeStandard:AltSecurityIdentities 2> /dev/null | awk -F'SSO:' '/PlatformSSO/ {print $2}')
	if [[ -n "${dscl_result}" ]]; then
		psso_user_status_dscl="${dscl_result}"
	else
		psso_user_status_dscl="FALSE"
	fi
}

# Full status check including app-sso platform -s (backgrounded with timeout to prevent blocking).
check_psso_user_status() {
	check_psso_dscl_status
	psso_user_status_login_name="FALSE"
	psso_user_status_state="FALSE"
	
	if [[ "${psso_user_status_dscl}" != "FALSE" ]]; then
		local app_sso_tmpfile
		app_sso_tmpfile=$(mktemp /tmp/pseudo_appsso.XXXXXX)
	
		run_as_user app-sso platform -s > "${app_sso_tmpfile}" 2>&1 &
		local cmd_pid=$!
	
		local wait_count=0
		while kill -0 "${cmd_pid}" 2>/dev/null && [[ $wait_count -lt 10 ]]; do
			sleep 1
			((wait_count++))
		done
	
		if kill -0 "${cmd_pid}" 2>/dev/null; then
			kill "${cmd_pid}" 2>/dev/null
			wait "${cmd_pid}" 2>/dev/null
			log_pseudo "Warning: app-sso platform -s timed out after 10 seconds."
		else
			wait "${cmd_pid}" 2>/dev/null
		fi
	
		local app_sso_response
		app_sso_response=$(cat "${app_sso_tmpfile}" 2>/dev/null)
		rm -f "${app_sso_tmpfile}"
	
		if [[ -n "${app_sso_response}" ]]; then
			local parsed_login_name
			parsed_login_name=$(echo "${app_sso_response}" | sed -e '1,/User Configuration:/d' | jq -r '.userLoginConfiguration.loginUserName' 2> /dev/null)
			local parsed_state
			parsed_state=$(echo "${app_sso_response}" | sed -e '1,/User Configuration:/d' | jq -r '.state' 2> /dev/null)
			[[ -n "${parsed_login_name}" ]] && [[ "${parsed_login_name}" != "null" ]] && psso_user_status_login_name="${parsed_login_name}"
			[[ -n "${parsed_state}" ]] && [[ "${parsed_state}" != "null" ]] && psso_user_status_state="${parsed_state}"
		fi
	fi
}

# Pre-enable relevant password AutoFill extensions for Okta.
enable_psso_autofill_extensions() {
	local previous_ifs
	previous_ifs="${IFS}"
	IFS=$'\n'
	local plugin_kit_response
	plugin_kit_response=($(run_as_user pluginkit -m 2> /dev/null | grep 'com.okta.mobile'))
	for plugin_kit_item in "${plugin_kit_response[@]}"; do
		[[ $(echo "${plugin_kit_item}" | grep -c -e '\+    ') -gt 0 ]] && log_pseudo "Status: The AutoFill extension with ID $(echo "${plugin_kit_item}" | awk -F' ' '{print $2}' | sed -e 's/(.*$//') is already enabled."
		if [[ $(echo "${plugin_kit_item}" | grep -c -e '-    ') -gt 0 ]]; then
			log_pseudo "Status: Re-enabling AutoFill extension with ID $(echo "${plugin_kit_item}" | awk -F' ' '{print $2}' | sed -e 's/(.*$//')."
			run_as_user pluginkit -e use -i "$(echo "${plugin_kit_item}" | awk -F' ' '{print $2}' | sed -e 's/(.*$//')" > /dev/null 2>&1
		elif [[ $(echo "${plugin_kit_item}" | grep -c -e '\+    ') -eq 0 ]]; then
			log_pseudo "Status: Enabling AutoFill extension with ID $(echo "${plugin_kit_item}" | awk -F' ' '{print $1}' | sed -e 's/(.*$//')."
			run_as_user pluginkit -e use -i "$(echo "${plugin_kit_item}" | awk -F' ' '{print $1}' | sed -e 's/(.*$//')" > /dev/null 2>&1
		fi
	done
	IFS="${previous_ifs}"
}

# Check the status of Platform SSO registration dialog (OPEN/ACTIVE/AUTOFILL/CLOSE/FALSE).
check_psso_registration_status() {
	local result
	result=$(osascript 2> /dev/null <<EOAS
if application "AppSSOAgent" is running then
	tell application "System Events"
		set windowCount to count of every window of application process "AppSSOAgent"
		if windowCount is greater than 1 then
			repeat with i from 1 to windowCount
				set allElements to entire contents of window i of application process "AppSSOAgent"
				repeat with aElement in allElements
					if name of aElement contains "autofill" then
						return "AUTOFILL"
					end if
				end repeat
			end repeat
			return "ACTIVE"
		else if windowCount is equal to 1 then
			if (count of every sheet of window 1 of application process "AppSSOAgent") is greater than 0 then
				return "ACTIVE"
			else
				if (count of every button of window 1 of application process "AppSSOAgent") is greater than 1 then
					return "OPEN"
				else
					return "CLOSE"
				end if
			end if
		else
			return "FALSE"
		end if
	end tell
else
	return "FALSE"
end if
EOAS
	)
	echo "${result}"
}

# Multi-method PSSO registration opener for macOS Tahoe compatibility.
# Method 1: app-sso platform -a (programmatic, bypasses Notification Centre)
# Method 2: app-sso -l + Notification Centre click (secondary)
# Method 3: System Settings UI scripting (tertiary fallback)
open_psso_registration() {
	killall "AppSSOAgent" > /dev/null 2>&1
	sleep 0.5
	
	# ── Method 1: Direct trigger via app-sso platform -a ──────────────────────
	log_pseudo "Status: Trying direct PSSO registration trigger (app-sso platform -a)..."
	run_as_user app-sso platform -a > /dev/null 2>&1 &
	local cmd_pid=$!
	local wait_count=0
	while [[ $wait_count -lt 8 ]]; do
		sleep 1
		((wait_count++))
		local status
		status=$(check_psso_registration_status)
		if [[ "${status}" != "FALSE" ]]; then
			kill "${cmd_pid}" 2>/dev/null; wait "${cmd_pid}" 2>/dev/null
			log_pseudo "Status: PSSO registration window opened via app-sso platform -a."
			echo "TRUE"
			return 0
		fi
	done
	kill "${cmd_pid}" 2>/dev/null; wait "${cmd_pid}" 2>/dev/null
	log_pseudo "Warning: app-sso platform -a did not produce a registration window."
	
	# ── Method 2: app-sso -l then Notification Centre click ───────────────────
	log_pseudo "Status: Trying Notification Centre approach (app-sso -l)..."
	run_as_user app-sso -l > /dev/null 2>&1
	sleep 2
	local open_psso_registration_result
	open_psso_registration_result=$(osascript 2> /dev/null <<EOAS
tell application "System Events"
	tell menu bar 1 of application process "ControlCenter"
		set menuDescriptionList to description of UI elements
		repeat with menuItem from 1 to length of menuDescriptionList
			if item menuItem of menuDescriptionList contains "Clock" then
				set menuNotificationCenter to menuItem
				exit repeat
			end if
		end repeat
	end tell
	tell menu bar 1 of application process "ControlCenter"
		tell menu bar item menuNotificationCenter
			click
		end tell
	end tell
	delay 1
	set foundElement to false
	set ncDebug to ""
	try
		tell application process "NotificationCenter"
			set allElements to entire contents of window 1
		end tell
		repeat with aElement in allElements
			set aElementStaticTexts to static texts of aElement
			repeat with aStaticText in aElementStaticTexts
				set sName to name of aStaticText
				set ncDebug to ncDebug & "|" & sName
				if (sName contains "Registration Required") or ¬
				   (sName contains "Registration required") or ¬
				   (sName contains "registration") or ¬
				   (sName contains "Platform SSO") or ¬
				   (sName contains "Single Sign") then
					set foundElement to true
					set pssoElement to aElement
					exit repeat
				end if
			end repeat
			if (foundElement) then exit repeat
		end repeat
	on error errMsg
		set ncDebug to "ERROR: " & errMsg
	end try
	if foundElement then
		tell pssoElement
			click
		end tell
		delay 1
		tell menu bar 1 of application process "ControlCenter"
			tell menu bar item menuNotificationCenter
				click
			end tell
		end tell
	else
		tell menu bar 1 of application process "ControlCenter"
			tell menu bar item menuNotificationCenter
				click
			end tell
		end tell
		return "FALSE:" & ncDebug
	end if
end tell
EOAS
	)
	
	# Check if Notification Centre method succeeded.
	if [[ "${open_psso_registration_result}" != FALSE* ]]; then
		sleep 1
		local nc_status
		nc_status=$(check_psso_registration_status)
		if [[ "${nc_status}" != "FALSE" ]]; then
			log_pseudo "Status: PSSO registration window opened via Notification Centre."
			echo "TRUE"
			return 0
		fi
	else
		local nc_elements="${open_psso_registration_result#FALSE:}"
		[[ -n "${nc_elements}" ]] && log_pseudo "Warning: No PSSO notification found. NC elements: ${nc_elements}"
		[[ -z "${nc_elements}" ]] && log_pseudo "Warning: No PSSO notification found in Notification Centre (empty or inaccessible)."
	fi
	
	# ── Method 3: System Settings UI scripting (tertiary fallback) ────────────
	log_pseudo "Status: Trying System Settings UI method (tertiary fallback)..."
	killall "System Settings" > /dev/null 2>&1
	sleep 1
	run_as_user open "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"
	local settings_result
	settings_result=$(osascript 2> /dev/null <<EOAS
set openTimeout to (current date) + ${TIMEOUT_OPEN_SECONDS}
tell application "System Events"
	repeat while not (exists window 1 of application process "System Settings")
		delay 0.1
		if (current date) > openTimeout then return "FALSE"
	end repeat
	tell application process "System Settings" to set frontmost to true
	repeat while not (exists button 2 of group 2 of scroll area 1 of group 1 of group 3 of splitter group 1 of group 1 of window 1 of application process "System Settings")
		delay 0.1
		if (current date) > openTimeout then return "FALSE"
	end repeat
	tell button 2 of group 2 of scroll area 1 of group 1 of group 3 of splitter group 1 of group 1 of window 1 of application process "System Settings" to perform action "AXPress"
	repeat while not (exists button 1 of group 2 of scroll area 1 of group 1 of sheet 1 of window 1 of application process "System Settings")
		delay 0.1
		if (current date) > openTimeout then return "FALSE"
	end repeat
	tell button 1 of group 2 of scroll area 1 of group 1 of sheet 1 of window 1 of application process "System Settings" to perform action "AXPress"
	repeat while not (exists window 1 of application process "AppSSOAgent")
		delay 0.1
		if (current date) > openTimeout then return "FALSE"
	end repeat
	tell application "System Settings" to quit
	return "TRUE"
end tell
EOAS
	)
	if [[ "${settings_result}" == "TRUE" ]]; then
		log_pseudo "Status: PSSO registration window opened via System Settings UI scripting."
		echo "TRUE"
		return 0
	fi
	
	killall "System Settings" > /dev/null 2>&1
	log_pseudo "Warning: All PSSO registration open methods failed."
	echo "FALSE"
}

# Close the Platform SSO registration AutoFill window.
close_psso_registration_autofill() {
	osascript > /dev/null 2>&1 <<EOAS
if application "AppSSOAgent" is running then
	tell application "System Events"
		set windowCount to count of every window of application process "AppSSOAgent"
		repeat with i from 1 to windowCount
			set allElements to entire contents of window i of application process "AppSSOAgent"
			repeat with aElement in allElements
				if name of aElement contains "autofill" then
					set autoFillWindow to window i of application process "AppSSOAgent"
					exit repeat
				end if
			end repeat
			if autoFillWindow is not missing value then exit repeat
		end repeat
		if autoFillWindow is not missing value then
			set buttonCount to count of every button of autoFillWindow
			repeat with i from 1 to buttonCount
				if (get value of attribute "AXIdentifier" of button i of autoFillWindow) is equal to "action-button-2" then
					tell button i of autoFillWindow to perform action "AXPress"
					exit repeat
				end if
			end repeat
		end if
	end tell
end if
EOAS
}

# Close the Platform SSO registration window.
close_psso_registration() {
	osascript > /dev/null 2>&1 <<EOAS
if application "AppSSOAgent" is running then
	tell application "System Events"
		if (count of every window of application process "AppSSOAgent") is equal to 1 then
			if (get value of attribute "AXIdentifier" of button 1 of window 1 of application process "AppSSOAgent") is equal to "Primary Button" then
				tell button 1 of window 1 of application process "AppSSOAgent" to perform action "AXPress"
			end if
		end if
	end tell
end if
EOAS
}

# Hide all other visible applications so only Platform SSO registration is visible.
# Uses allowedApps list to preserve browsers/Okta Verify during auth flow.
focus_psso_registration() {
	osascript > /dev/null 2>&1 <<EOAS
tell application "System Events"
	set allowedApps to {"AppSSOAgent", "Single Sign-On", "coreautha", "Dialog", "Finder", ¬
		"Safari", "Google Chrome", "Microsoft Edge", "Firefox", "Arc", ¬
		"Brave Browser", "Okta Verify"}
	
	set frontApp to name of first application process whose frontmost is true
	
	tell application "Finder"
		if (count of windows) is not 0 then
			close every window
			delay 0.1
		end if
	end tell
	
	set visibleApps to every process whose visible is true
	repeat with anApp in visibleApps
		if name of anApp is not in allowedApps then
			tell anApp to set visible to false
			delay 0.1
		end if
	end repeat
	
	if frontApp is not in allowedApps then
		if exists process "Single Sign-On" then
			tell process "Single Sign-On" to set frontmost to true
		else if exists process "AppSSOAgent" then
			tell process "AppSSOAgent" to set frontmost to true
		end if
	end if
end tell
EOAS
}

# Open a combined swiftDialog informing the user about Platform SSO and to click Continue.
open_dialog_psso_start() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}" && sleep 0.1
	log_pseudo "Dialog Open: Platform SSO Start"
	"${SWIFT_DIALOG_BINARY}" \
	--title "Platform SSO Registration Required" \
	--message "**Platform SSO is required for all Mac computers at ${DISPLAY_ORGANIZATION_NAME}.**<br><br>Please click the \"Continue\" button to sign in and register with Platform SSO." \
	--icon "${psso_dialog_icon}" \
	--moveable \
	--small \
	--position "${DISPLAY_DIALOG_POSITION}" \
	--button1text none \
	--quitkey p \
	--hidedefaultkeyboardaction \
	--ontop &
	disown $!
}

# Open a swiftDialog to acknowledge that the user is actively registering with Platform SSO.
open_dialog_psso_active() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}" && sleep 0.1
	log_pseudo "Dialog Open: Platform SSO Active"
	"${SWIFT_DIALOG_BINARY}" \
	--title "Platform SSO Registration" \
	--message "**Please provide your account credentials to proceed with the Platform SSO registration.**<br><br>After the browser opens and you complete sign-in, please return to the Single Sign-On for Mac registration window. It may be hidden behind the browser. Registration will not continue until this window is brought back to the front." \
	--icon "${psso_dialog_icon}" \
	--moveable \
	--height 270 \
	--position "${DISPLAY_DIALOG_POSITION}" \
	--button1text none \
	--quitkey p \
	--hidedefaultkeyboardaction \
	--ontop &
	disown $!
}

# Open a swiftDialog informing the user they need to enter their password to sync.
open_dialog_password_sync() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}" && sleep 0.1
	log_pseudo "Dialog Open: Platform SSO Password Sync"
	"${SWIFT_DIALOG_BINARY}" \
	--title "Platform SSO Registration" \
	--message "**Please enter your Okta password one more time to enable it for macOS account login.**" \
	--icon "SF=person.badge.key,palette=primary,accent,none" \
	--mini \
	--moveable \
	--position "${DISPLAY_DIALOG_POSITION}" \
	--button1text none \
	--quitkey p \
	--hidedefaultkeyboardaction \
	--ontop &
	disown $!
}

# Open a swiftDialog to inform the user that Platform SSO registration was successful.
open_dialog_psso_success() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}" && sleep 0.1
	if [[ $(echo "${psso_login_type}" | grep -c 'Password') -gt 0 ]]; then
		log_pseudo "Dialog Open: Platform SSO Password Success"
		"${SWIFT_DIALOG_BINARY}" \
		--title "Platform SSO Enabled" \
		--message "**Thank you for enabling Okta Platform SSO!**<br><br>Click OK to finalise the process." \
		--icon "${psso_dialog_icon}" \
		--small \
		--moveable \
		--position "${DISPLAY_DIALOG_POSITION}" \
		--button1text "OK" \
		--quitkey p \
		--hidedefaultkeyboardaction \
		--ontop
	else
		log_pseudo "Dialog Open: Platform SSO Secure Enclave Success"
		"${SWIFT_DIALOG_BINARY}" \
		--title "Platform SSO Enabled" \
		--message "**Thank you for enabling Okta Platform SSO!**<br><br>Click OK to finalise the process." \
		--icon "${psso_dialog_icon}" \
		--small \
		--moveable \
		--position "${DISPLAY_DIALOG_POSITION}" \
		--button1text "OK" \
		--quitkey p \
		--hidedefaultkeyboardaction \
		--ontop
	fi
}

# Open an interactive swiftDialog informing the user that the Platform SSO workflow has failed.
open_dialog_psso_failed() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}" && sleep 0.1
	hide_all_apps
	log_pseudo "Dialog Open: Platform SSO Failed"
	"${SWIFT_DIALOG_BINARY}" \
	--title "Platform SSO Registration Failed" \
	--message "**Platform SSO registration has failed.**<br><br>Please contact your administrator if this issue persists." \
	--icon caution \
	--overlayicon "${psso_dialog_icon}" \
	--small \
	--moveable \
	--position "${DISPLAY_DIALOG_POSITION}" \
	--button1text "OK" \
	--quitkey p \
	--hidedefaultkeyboardaction \
	--ontop &
	disown $!
}

# Open the restart countdown dialog.
open_dialog_psso_restart_countdown() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}" && sleep 0.1
	log_pseudo "Dialog Open: Restart Countdown"
	"${SWIFT_DIALOG_BINARY}" \
	--title "Restart Required" \
	--message "**Platform SSO registration is complete.**\n\nYour Mac must restart to finish device setup.\n\nThe computer will automatically restart in **10 minutes**.\n\nPlease save any open work." \
	--markdown \
	--moveable \
	--icon "${psso_dialog_icon}" \
	--position "${DISPLAY_DIALOG_POSITION}" \
	--timer 600 \
	--button1text "Restart Now" \
	--quitkey p \
	--hidedefaultkeyboardaction \
	--ontop
	return $?
}

# Background the shutdown so the script can exit cleanly — gives Jamf ~15 seconds to report policy completion.
restart_computer() {
	log_pseudo "Status: Scheduling restart in 15 seconds to allow Jamf policy completion reporting..."
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}"
	sleep 0.2
	nohup bash -c 'sleep 15 && /sbin/shutdown -r now' &>/dev/null &
	disown $!
}

# The full workflow to check Platform SSO status and register if required.
workflow_psso() {
	# --- Initial check — skip entirely if already fully registered. ---
	check_psso_dscl_status
	if [[ "${psso_user_status_dscl}" != "FALSE" ]]; then
		check_psso_user_status
		log_pseudo "Status: Initial PSSO check — dscl: SET, login_name: ${psso_user_status_login_name}, state: ${psso_user_status_state}"
		if [[ "${REPAIR_MODE}" != "TRUE" ]] && [[ "${psso_user_status_login_name}" != "FALSE" ]] && psso_is_registered "${psso_user_status_state}"; then
			log_pseudo "Status: Platform SSO is already registered for local user ${current_user_account_name} (${current_user_id}) to account ${psso_user_status_login_name}."
			[[ "${ENABLE_AUTOFILL_EXTENSIONS}" == "TRUE" ]] && enable_psso_autofill_extensions
			psso_workflow_active="FALSE"
			return 0
		fi
		log_pseudo "Status: Platform SSO dscl entry exists but state is '${psso_user_status_state}'. Proceeding to registration..."
	fi
	
	# --- Phase 1: User-facing interactive registration. ---
	local workflow_psso_timer=0
	psso_workflow_active="FALSE"
	local psso_window_closed_seconds=0
	local psso_workflow_user_active="FALSE"
	
	while [[ "${psso_user_status_dscl}" == "FALSE" ]] || { [[ "${REPAIR_MODE}" == "TRUE" ]] && ! psso_is_registered "${psso_user_status_state}"; }; do
		[[ $workflow_psso_timer -ge $TIMEOUT_WORKFLOW_SECONDS ]] && log_pseudo "Exit: Platform SSO registration workflow timed out after ${TIMEOUT_WORKFLOW_SECONDS} seconds." && open_dialog_psso_failed && exit_error
	
		# First-time initialisation.
		if [[ "${psso_workflow_active}" == "FALSE" ]]; then
			log_pseudo "Status: Starting Platform SSO registration workflow with a ${TIMEOUT_WORKFLOW_SECONDS} second timeout..."
			[[ "${ENABLE_AUTOFILL_EXTENSIONS}" == "TRUE" ]] && enable_psso_autofill_extensions
	
			local reg_status
			reg_status=$(check_psso_registration_status)
			if [[ "${reg_status}" == "FALSE" ]] || [[ "${reg_status}" == "CLOSE" ]]; then
				log_pseudo "Status: Attempting to open Platform SSO registration..."
				if [[ "$(open_psso_registration)" == "FALSE" ]]; then
					log_pseudo "Warning: Unable to open PSSO registration on initial attempt. Will retry via grace period..."
				fi
			else
				log_pseudo "Status: Platform SSO registration is already open (status: ${reg_status})."
			fi
	
			open_dialog_psso_start
			psso_workflow_active="TRUE"
		fi
	
		# Monitor the registration window.
		local current_status
		current_status=$(check_psso_registration_status)
	
		if [[ "${current_status}" == "ACTIVE" ]] && [[ "${psso_workflow_user_active}" == "FALSE" ]]; then
			log_pseudo "Status: Platform SSO registration is open and the user is actively registering."
			open_dialog_psso_active
			psso_workflow_user_active="TRUE"
			psso_window_closed_seconds=0
		elif [[ "${current_status}" == "AUTOFILL" ]]; then
			log_pseudo "Status: Closing Platform SSO registration AutoFill window..."
			close_psso_registration_autofill
			psso_window_closed_seconds=0
		elif [[ "${current_status}" == "OPEN" ]] || [[ "${current_status}" == "ACTIVE" ]]; then
			focus_psso_registration
			psso_window_closed_seconds=0
		elif [[ "${current_status}" == "CLOSE" ]]; then
			# Registration completed or failed — check dscl.
			check_psso_dscl_status
			if [[ "${psso_user_status_dscl}" != "FALSE" ]]; then
				break
			else
				log_pseudo "Status: PSSO window shows CLOSE but dscl not set. Possible auth failure."
				close_psso_registration
				psso_window_closed_seconds=0
				# Will be re-opened via grace period.
			fi
		else
			# Window is FALSE (not visible).
			((psso_window_closed_seconds++))
			[[ $psso_window_closed_seconds -eq 1 ]] && log_pseudo "Status: PSSO registration window not active. Waiting up to ${PSSO_REOPEN_GRACE_SECONDS}s before retrying..."
	
			if [[ $psso_window_closed_seconds -ge $PSSO_REOPEN_GRACE_SECONDS ]]; then
				psso_window_closed_seconds=0
				log_pseudo "Status: Grace period expired. Attempting to re-open Platform SSO registration..."
				if [[ "$(open_psso_registration)" == "FALSE" ]]; then
					log_pseudo "Warning: Unable to re-open PSSO registration. Continuing to poll dscl..."
				else
					log_pseudo "Status: Successfully re-opened Platform SSO registration."
				fi
			fi
		fi
	
		sleep 1
		check_psso_dscl_status
		((workflow_psso_timer++))
	done
	
	# Mark workflow as active.
	psso_workflow_active="TRUE"
	
	# --- Phase 1.5: Handle password sync if needed. ---
	if [[ "${psso_workflow_user_active}" == "TRUE" ]] && [[ $(echo "${psso_login_type}" | grep -c 'Password') -gt 0 ]]; then
		local post_reg_status
		post_reg_status=$(check_psso_registration_status)
	
		# Close AutoFill if it appeared.
		if [[ "${ENABLE_AUTOFILL_EXTENSIONS}" == "TRUE" ]] && [[ "${post_reg_status}" == "AUTOFILL" ]]; then
			log_pseudo "Status: Closing Platform SSO registration AutoFill window..."
			close_psso_registration_autofill
			sleep 1
			post_reg_status=$(check_psso_registration_status)
		fi
	
		if [[ "${post_reg_status}" == "ACTIVE" ]]; then
			log_pseudo "Status: Waiting for IdP password sync to local user account..."
			open_dialog_password_sync
			local psso_password_start_epoch
			psso_password_start_epoch=$(date +%s)
			while [[ "${post_reg_status}" != "CLOSE" ]] && [[ "${post_reg_status}" != "FALSE" ]]; do
				if [[ $(( psso_password_start_epoch + TIMEOUT_WORKFLOW_SECONDS )) -lt $(date +%s) ]]; then
					log_pseudo "Error: IdP password sync timed out after ${TIMEOUT_WORKFLOW_SECONDS} seconds."
					break
				fi
				focus_psso_registration
				sleep 1
				post_reg_status=$(check_psso_registration_status)
			done
			[[ "${post_reg_status}" == "CLOSE" ]] || [[ "${post_reg_status}" == "FALSE" ]] && log_pseudo "Status: IdP password sync completed in $(( $(date +%s) - psso_password_start_epoch )) seconds."
		fi
	fi
	
	# Close any remaining registration window.
	close_psso_registration
	
	# --- Phase 2: Background state verification. ---
	log_pseudo "Status: Platform SSO dscl entry confirmed. Verifying full registration state (${PSSO_STATE_VERIFY_SECONDS}s timeout)..."
	local state_verify_start
	state_verify_start=$(date +%s)
	
	while true; do
		check_psso_user_status
		log_pseudo "Status: PSSO state verification — login_name: ${psso_user_status_login_name}, state: ${psso_user_status_state}"
	
		if [[ "${psso_user_status_login_name}" != "FALSE" ]] && psso_is_registered "${psso_user_status_state}"; then
			log_pseudo "Status: Platform SSO registration fully verified (state: ${psso_user_status_state}, login_name: ${psso_user_status_login_name})."
			break
		fi
	
		local now
		now=$(date +%s)
		local elapsed=$(( now - state_verify_start ))
		if [[ $elapsed -ge $PSSO_STATE_VERIFY_SECONDS ]]; then
			log_pseudo "Warning: PSSO state verification timed out after ${elapsed}s (state: '${psso_user_status_state}', login_name: '${psso_user_status_login_name}'). Proceeding — dscl entry confirms registration."
			break
		fi
	
		sleep 2
	done
	
	# --- Success path: dialog → recon → restart. ---
	open_dialog_psso_success
	
	log_pseudo "Status: Platform SSO is now registered for local user ${current_user_account_name} (${current_user_id}) to account ${psso_user_status_login_name}. The workflow took ${workflow_psso_timer} seconds to complete."
	
	# Run inventory updates BEFORE the restart countdown.
	run_inventory_updates
	
	# Show restart dialog with countdown.
	open_dialog_psso_restart_countdown
	local dialog_restart_result=$?
	
	if [[ "${dialog_restart_result}" -eq 0 ]]; then
		log_pseudo "Status: User chose immediate restart."
	elif [[ "${dialog_restart_result}" -eq 4 ]]; then
		log_pseudo "Status: Restart countdown expired. Restarting automatically."
	else
		log_pseudo "Status: Restart dialog returned result ${dialog_restart_result}. Restarting for safety."
	fi
	
	# Schedule backgrounded restart and exit cleanly so Jamf can report policy completion.
	restart_computer
	exit_success
}

# MARK: *** Main Workflow ***
################################################################################

main() {
	workflow_startup
	[[ "${REPAIR_MODE}" != "TRUE" ]] && workflow_touch_id
	workflow_psso
	# If we reach here, PSSO was already registered (no restart triggered).
	run_inventory_updates
}

main "$@"
exit_success
