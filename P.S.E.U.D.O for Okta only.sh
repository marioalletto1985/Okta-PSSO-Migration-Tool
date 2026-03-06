#!/bin/bash
# P.S.E.U.D.O.
# Platform SSO Enforcement (of) User Device Onboarding
# https://github.com/Macjutsu/pseudo
# by Kevin M. White
# edited by Mario Alletto for Zilch Technology March 2026
# Okta-only build — all Microsoft Entra/Company Portal and Workspace One references removed.

# The next line disables specific ShellCheck codes (https://github.com/koalaman/shellcheck) for the entire script.
# shellcheck disable=SC2012,SC2024,SC2207

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
PSEUDO_VERSION="1.0.0-beta3"
readonly PSEUDO_VERSION
PSEUDO_DATE="2026/02/25"
readonly PSEUDO_DATE
PSEUDO_USER_AGENT="pseudo/${PSEUDO_VERSION} $(curl --version | head -1 | sed -e 's/curl /curl\//')"
readonly PSEUDO_USER_AGENT

# MARK: *** Startup Workflow ***
################################################################################

# Set default parameters that are used throughout the script.
set_defaults() {
	CHECK_REQUIRED_CONFIG_PROFILES=""
	readonly CHECK_REQUIRED_CONFIG_PROFILES

	TOUCH_ID_CONFIG="REQUIRED"
	readonly TOUCH_ID_CONFIG

	UPDATE_JAMF_PRO="TRUE"
	readonly UPDATE_JAMF_PRO

	DISPLAY_ORGANIZATION_NAME="Zilch"
	readonly DISPLAY_ORGANIZATION_NAME

	DISPLAY_DIALOG_POSITION="topright"
	readonly DISPLAY_DIALOG_POSITION

	PSEUDO_LOG="/var/log/pseudo.log"
	readonly PSEUDO_LOG

	TIMEOUT_DEFAULT_SECONDS=300
	readonly TIMEOUT_DEFAULT_SECONDS

	SSO_MANAGED_PLIST="/Library/Managed Preferences/com.apple.extensiblesso.plist"
	readonly SSO_MANAGED_PLIST

	SWIFT_DIALOG_TARGET_VERSION="3.0.0.4952"
	readonly SWIFT_DIALOG_TARGET_VERSION

	SWIFT_DIALOG_DOWNLOAD_URL="https://github.com/swiftDialog/swiftDialog/releases/download/v3.0.0/dialog-3.0.0-4952.pkg"
	readonly SWIFT_DIALOG_DOWNLOAD_URL

	SWIFT_DIALOG_BINARY="/usr/local/bin/dialog"
	readonly SWIFT_DIALOG_BINARY

	SWIFT_DIALOG_COMMAND_FILE="/var/tmp/dialog.log"
	readonly SWIFT_DIALOG_COMMAND_FILE

	JAMF_PRO_BINARY="/usr/local/bin/jamf"
	readonly JAMF_PRO_BINARY

	# CHANGED: Removed WORKSPACE_ONE_BINARY — Jamf-only environment.

	# Seconds to wait after the PSSO window closes before attempting to re-open via notification.
	PSSO_REOPEN_GRACE_SECONDS=30
	readonly PSSO_REOPEN_GRACE_SECONDS

	# Maximum seconds to spend verifying PSSO state via app-sso after dscl confirms registration.
	PSSO_STATE_VERIFY_SECONDS=30
	readonly PSSO_STATE_VERIFY_SECONDS
}

log_pseudo() {
	echo -e "$(date +"%a %b %d %T") $(hostname -s) $(basename "$0")[$$]: $*" | tee -a "${PSEUDO_LOG}"
}

log_echo() {
	echo -e "$(date +"%a %b %d %T") $(hostname -s) $(basename "$0")[$$]: Not Logged: $*"
}

interactive_interrupt() {
	log_pseudo "**** P.S.E.U.D.O. ${PSEUDO_VERSION} - ${PSEUDO_DATE} - INTERACTIVE INTERRUPT - PRESS ENTER TO CONTINUE OR CTRL-C TO EXIT ****"
	read -n 1 -p -r > /dev/null 2>&1
}

exit_success() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}"
	log_pseudo "**** P.S.E.U.D.O. ${PSEUDO_VERSION} - ${PSEUDO_DATE} - EXIT SUCCESS ****"
	exit 0
}

exit_error() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}"
	log_pseudo "**** P.S.E.U.D.O. ${PSEUDO_VERSION} - ${PSEUDO_DATE} - EXIT ERROR ****"
	exit 1
}

run_as_user() {
	launchctl asuser "${current_user_id}" sudo -u "${current_user_account_name}" "$@"
}

# CHANGED: Helper function to check if PSSO state indicates successful registration.
# macOS Tahoe returns "POUserStateNormal (0)" instead of "registered".
psso_is_registered() {
	[[ "${1}" == "registered" ]] || [[ "${1}" == *"Normal"* ]]
}

hide_all_apps() {
	osascript <<EOAS
tell application "Finder"
	if (count of windows) is not 0 then
		tell application "Finder" to close every window
		delay 0.1
	end if
end tell
tell application "System Events"
	set visibleApps to every process whose visible is true and name is not "Finder"
	repeat with anApp in visibleApps
		tell anApp
			set visible to false
		end tell
		delay 0.1
	end repeat
end tell
EOAS
}

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
	local ioreg_result
	ioreg_result=$(ioreg -l 2> /dev/null)
	if [[ $(echo "${ioreg_result}" | grep -c -e '\"AppleBiometricSensor\"=[1-9]') -gt 0 ]]; then
		[[ "${mac_cpu_architecture}" == "arm64" ]] && log_pseudo "Status: Mac computer with Apple silicon and built-in Touch ID sensor running ${macos_version_full}."
		[[ "${mac_cpu_architecture}" == "i386" ]] && log_pseudo "Status: Mac computer with Intel and built-in Touch ID sensor running ${macos_version_full}."
		touch_id_hardware_status="INTERNAL"
	elif [[ $(echo "${ioreg_result}" | grep -c -e 'with Touch ID') -gt 0 ]]; then
		[[ "${mac_cpu_architecture}" == "arm64" ]] && log_pseudo "Status: Mac computer with Apple silicon and Magic Keyboard with Touch ID running ${macos_version_full}."
		[[ "${mac_cpu_architecture}" == "i386" ]] && log_pseudo "Status: Mac computer with Intel and Magic Keyboard with Touch ID running ${macos_version_full}."
		touch_id_hardware_status="EXTERNAL"
	else
		[[ "${mac_cpu_architecture}" == "arm64" ]] && log_pseudo "Status: Mac computer with Apple silicon (no Touch ID) running ${macos_version_full}."
		[[ "${mac_cpu_architecture}" == "i386" ]] && log_pseudo "Status: Mac computer with Intel (no Touch ID) running ${macos_version_full}."
		touch_id_hardware_status="FALSE"
	fi
}

check_swift_dialog() {
	swift_dialog_valid="FALSE"
	local codesign_response
	codesign_response=$(codesign --verify --verbose "${swift_dialog_app}" 2>&1)
	if [[ $(echo "${codesign_response}" | grep -c 'valid on disk') -gt 0 ]]; then
		local version_response
		version_response=$("${SWIFT_DIALOG_BINARY}" --version)
		if [[ "${SWIFT_DIALOG_TARGET_VERSION}" == "${version_response}" ]]; then
			swift_dialog_valid="TRUE"
		else
			log_pseudo "Warning: swiftDialog at path is currently version ${version_response}, this does not match target version ${SWIFT_DIALOG_TARGET_VERSION}."
		fi
	else
		log_pseudo "Warning: unable validate signature for swiftDialog:\n${codesign_response}."
	fi
}

get_swift_dialog() {
	log_pseudo "Status: Attempting to download swiftDialog..."
	local previous_umask
	previous_umask=$(umask)
	umask 077
	local temp_file
	temp_file="$(mktemp).pkg"
	local download_response
	download_response=$(curl --user-agent "${PSEUDO_USER_AGENT}" --connect-timeout "${TIMEOUT_DEFAULT_SECONDS}" --max-time "${TIMEOUT_DEFAULT_SECONDS}" --write-out "Total Time: %{time_total}" --location "${SWIFT_DIALOG_DOWNLOAD_URL}" --output "${temp_file}" 2>&1)
	if [[ -f "${temp_file}" ]]; then
		log_pseudo "Status: Successfully downloaded swiftDialog.pkg:\n${download_response}."
		log_pseudo "Status: Attempting to install swiftDialog..."
		local install_response
		install_response=$(installer -verboseR -pkg "${temp_file}" -target / 2>&1)
		if ! { [[ $(echo "${install_response}" | grep -c 'The software was successfully installed.') -gt 0 ]] || [[ $(echo "${install_response}" | grep -c 'The install was successful.') -gt 0 ]]; }; then
			log_pseudo "Error: Unable to install swiftDialog.pkg:\n${install_response}"
		else
			log_pseudo "Status: Successfully installed swiftDialog.pkg:\n${install_response}."
		fi
	else
		log_pseudo "Error: Unable to download swiftDialog.pkg:\n${download_response}."
	fi
	rm -Rf "${temp_file}" > /dev/null 2>&1
	umask "${previous_umask}"
}

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
		current_user_is_admin="FALSE"
		current_user_has_secure_token="FALSE"
		current_user_is_volume_owner="FALSE"
		if [[ -n "${current_user_id}" ]] && [[ -n "${current_user_guid}" ]] && [[ -n "${current_user_real_name}" ]]; then
			[[ $(groups "${current_user_account_name}" 2> /dev/null | grep -c 'admin') -gt 0 ]] && current_user_is_admin="TRUE"
			[[ $(dscl . read "/Users/${current_user_account_name}" AuthenticationAuthority 2> /dev/null | grep -c 'SecureToken') -gt 0 ]] && current_user_has_secure_token="TRUE"
			[[ $(diskutil apfs listcryptousers / 2> /dev/null | grep -c "${current_user_guid}") -gt 0 ]] && current_user_is_volume_owner="TRUE"
		else
			log_pseudo "Exit: Unable to determine account details for local user ${current_user_account_name} (${current_user_id})" && exit_error
		fi
	fi
}

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
	[[ "${check_config_profiles_error}" == TRUE ]] && log_pseudo "Exit: A required configuration profile is not currently installed." && exit_error
}

workflow_startup() {
	local workflow_startup_error
	workflow_startup_error="FALSE"
	set_defaults
	[[ $(id -u) -ne 0 ]] && log_echo "Exit: pseudo must run with root privileges." && exit 1
	log_pseudo "**** P.S.E.U.D.O. ${PSEUDO_VERSION} - ${PSEUDO_DATE} - STARTUP ****"

	check_system
	[[ $macos_version_major -lt 15 ]] && log_pseudo "Exit: This computer is running macOS ${macos_version_major} and pseudo requires macOS 15 Sequoia or newer." && exit_error

	killall "dialog" > /dev/null 2>&1
	killall "Dialog" > /dev/null 2>&1
	swift_dialog_app=$(command -v /usr/local/bin/dialog 2> /dev/null | sed -e 's/\/Contents.*//')
	if [[ ! -e "${swift_dialog_app}" ]] || [[ ! -e "${SWIFT_DIALOG_BINARY}" ]]; then
		get_swift_dialog
		{ [[ -e "${swift_dialog_app}" ]] && [[ -e "${SWIFT_DIALOG_BINARY}" ]]; } && check_swift_dialog
		[[ "${swift_dialog_valid}" == "FALSE" ]] && log_pseudo "Exit: Unable to validate swiftDialog after installation."
	else
		check_swift_dialog
		if [[ "${swift_dialog_valid}" == "FALSE" ]]; then
			get_swift_dialog
			{ [[ -e "${swift_dialog_app}" ]] && [[ -e "${SWIFT_DIALOG_BINARY}" ]]; } && check_swift_dialog
		fi
		[[ "${swift_dialog_valid}" == "FALSE" ]] && log_pseudo "Exit: Unable to validate swiftDialog after re-installation."
	fi
	[[ "${swift_dialog_valid}" == "FALSE" ]] && exit_error

	check_current_user
	local wait_for_user_timer
	wait_for_user_timer=0
	while [[ "${current_user_account_name}" == "FALSE" ]]; do
		[[ $wait_for_user_timer -eq $TIMEOUT_DEFAULT_SECONDS ]] && log_pseudo "Status: Waiting for an active user timed out after ${TIMEOUT_DEFAULT_SECONDS} seconds." && exit_error
		[[ $wait_for_user_timer -eq 0 ]] && log_pseudo "Status: Waiting for an active user with a ${TIMEOUT_DEFAULT_SECONDS} second timeout..."
		sleep 1
		check_current_user
		((wait_for_user_timer++))
	done
	[[ ${wait_for_user_timer} -gt 0 ]] && log_pseudo "Status: Waiting for an active user took ${wait_for_user_timer} seconds to complete."

	local wait_for_dock_timer
	wait_for_dock_timer=0
	while ! pgrep -x "Dock" > /dev/null; do
		[[ $wait_for_dock_timer -eq $TIMEOUT_DEFAULT_SECONDS ]] && log_pseudo "Status: Waiting for the Dock to open timed out after ${TIMEOUT_DEFAULT_SECONDS} seconds." && exit_error
		[[ $wait_for_dock_timer -eq 0 ]] && log_pseudo "Status: Waiting for the Dock to open with a ${TIMEOUT_DEFAULT_SECONDS} second timeout..."
		sleep 1
		((wait_for_dock_timer++))
	done
	[[ ${wait_for_dock_timer} -gt 0 ]] && log_pseudo "Status: Waiting for the Dock to open took ${wait_for_dock_timer} seconds to complete."
	log_pseudo "Status: Current active local user is ${current_user_account_name} (${current_user_id})."

	[[ -n "${CHECK_REQUIRED_CONFIG_PROFILES}" ]] && check_config_profiles
	if [[ -e "${SSO_MANAGED_PLIST}" ]]; then
		psso_extension_identifier=$(/usr/libexec/PlistBuddy -c "Print :ExtensionIdentifier" "${SSO_MANAGED_PLIST}" 2> /dev/null)
		[[ -z "${psso_extension_identifier}" ]] && log_pseudo "Error: Could not determine Platform SSO extension identifier. This is a required value for Platform SSO." && workflow_startup_error="TRUE"
		psso_login_type=$(/usr/libexec/PlistBuddy -c "Print :PlatformSSO:AuthenticationMethod" "${SSO_MANAGED_PLIST}" 2> /dev/null)
		[[ -z "${psso_login_type}" ]] && log_pseudo "Error: Could not determine Platform SSO login type. This is a required value for Platform SSO." && workflow_startup_error="TRUE"
		psso_display_name=$(/usr/libexec/PlistBuddy -c "Print :PlatformSSO:AccountDisplayName" "${SSO_MANAGED_PLIST}" 2> /dev/null)
		[[ -z "${psso_display_name}" ]] && log_pseudo "Warning: Could not determine Platform SSO account display name. This should be specified for the best user experience."
	else
		log_pseudo "Exit: Could not locate the managed configuration for Platform SSO at the expected path: ${SSO_MANAGED_PLIST}" && exit_error
	fi

	if [[ "${psso_extension_identifier}" == "com.okta.mobile.auth-service-extension" ]]; then
		if [[ -e "/Applications/Okta Verify.app" ]]; then
			psso_dialog_icon="/Applications/Okta Verify.app/Contents/Resources/AppIcon.icns"
			[[ -n "${psso_display_name}" ]] && log_pseudo "Status: Platform SSO configuration for Okta using ${psso_login_type} authentication with the display name of \"${psso_display_name}\"."
			[[ -z "${psso_display_name}" ]] && log_pseudo "Status: Platform SSO configuration for Okta using ${psso_login_type} authentication."
		else
			log_pseudo "Error: The required Platform SSO software Okta Verify.app is not installed." && workflow_startup_error="TRUE"
		fi
	else
		log_pseudo "Error: Unexpected Platform SSO extension identifier: ${psso_extension_identifier}. Expected com.okta.mobile.auth-service-extension for Okta." && workflow_startup_error="TRUE"
	fi
	[[ "${workflow_startup_error}" == "TRUE" ]] && log_pseudo "Exit: Startup workflow failed." && exit_error
}

# MARK: *** Jamf Pro Integration ***
################################################################################

jamf_pro_update_inventory() {
	[[ ! -e "${JAMF_PRO_BINARY}" ]] && log_pseudo "Error: Could not locate the Jamf Pro binary in the expected location: ${JAMF_PRO_BINARY}" && update_inventory_error="TRUE" && return 0
	if [[ "${touch_id_workflow_active}" == "TRUE" ]] || [[ "${psso_workflow_active}" == "TRUE" ]]; then
		log_pseudo "Status: Updating Jamf Pro inventory..."
		local jamf_recon_response
		jamf_recon_response=$("${JAMF_PRO_BINARY}" recon -verbose 2>&1)
		if [[ $(echo "${jamf_recon_response}" | grep -c 'Submitting data') -gt 0 ]]; then
			log_pseudo "Status: Jamf Pro inventory successfully updated."
		else
			log_pseudo "Error: Could not update Jamf Pro inventory:\n${jamf_recon_response}" && update_inventory_error="TRUE"
		fi
	fi
}

# MARK: *** Touch ID Workflow ***
################################################################################

check_touch_id_user_status() {
	touch_id_user_status="FALSE"
	local bioutil_user_ids
	bioutil_user_ids=($(bioutil -c -s | awk '/User/ {print $2 $3}'))
	[[ $(echo "${bioutil_user_ids[*]}" | grep -c "${current_user_id}") -gt 0 ]] && touch_id_user_status="TRUE"
}

check_touch_id_settings_active() {
	local touch_id_settings_active_result
	touch_id_settings_active_result=$(osascript <<EOAS
if application "System Settings" is running then
	tell application "System Settings"
		if (exists window "Touch ID & Password") then
			return "TRUE"
		else
			return "FALSE"
		end if
	end tell
else
	return "FALSE"
end if
EOAS
	)
	echo "${touch_id_settings_active_result}"
}

check_touch_id_fingerprint_sheet_active() {
	local touch_id_fingerprint_sheet_active_result
	touch_id_fingerprint_sheet_active_result=$(osascript <<EOAS
if application "System Settings" is running then
	tell application "System Events"
		tell process "System Settings"
			if (exists sheet 1 of window "Touch ID & Password") then
				return "TRUE"
			else
				return "FALSE"
			end if
		end tell
	end tell
else
	return "FALSE"
end if
EOAS
	)
	echo "${touch_id_fingerprint_sheet_active_result}"
}

open_touch_id_system_settings() {
	run_as_user open "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension"
}

focus_touch_id_settings() {
	osascript <<EOAS
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
			tell anApp
				set visible to false
			end tell
			delay 0.1
		end if
	end repeat

	if frontApp is not in allowedApps then
		tell process "System Settings"
			set frontmost to true
		end tell
	end if
end tell
EOAS
}

open_dialog_touch_id_required() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}"
	sleep 0.1
	hide_all_apps
	"${SWIFT_DIALOG_BINARY}" \
		--title "Touch ID Setup Required" \
		--message "**Touch ID is required for all Mac computers at ${DISPLAY_ORGANIZATION_NAME}.**<br><br>Touch ID provides enhanced security and convenience by allowing you to authenticate using the Mac computer's fingerprint sensor." \
		--icon "SF=touchid,colour=auto" \
		--small \
		--position "${DISPLAY_DIALOG_POSITION}" \
		--timer "${TIMEOUT_DEFAULT_SECONDS}" \
		--hidetimerbar \
		--button1text "Enable Touch ID" \
		--quitkey p \
		--hidedefaultkeyboardaction \
		--ontop
	return $?
}

open_dialog_touch_id_optional() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}"
	sleep 0.1
	hide_all_apps
	"${SWIFT_DIALOG_BINARY}" \
		--title "Touch ID Setup" \
		--message "**Please take a few moments to enable Touch ID.**<br><br>Touch ID provides enhanced security and convenience by allowing you to authenticate using the Mac computer's fingerprint sensor." \
		--icon "SF=touchid,colour=auto" \
		--small \
		--position "${DISPLAY_DIALOG_POSITION}" \
		--timer "${TIMEOUT_DEFAULT_SECONDS}" \
		--hidetimerbar \
		--button1text "Enable Touch ID" \
		--button2text "Skip" \
		--quitkey p \
		--hidedefaultkeyboardaction \
		--ontop
	return $?
}

open_dialog_touch_id_start() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}"
	sleep 0.1
	"${SWIFT_DIALOG_BINARY}" \
		--title "Touch ID Setup" \
		--message "Enable Touch ID by adding at least one fingerprint in the Touch ID settings." \
		--icon "SF=touchid,colour=auto" \
		--mini \
		--position "${DISPLAY_DIALOG_POSITION}" \
		--button1text none \
		--quitkey p \
		--hidedefaultkeyboardaction \
		--ontop &
	sleep 0.1
	disown $!
}

open_dialog_touch_id_success() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}"
	sleep 0.1
	"${SWIFT_DIALOG_BINARY}" \
		--title "Touch ID Enabled" \
		--message "Thank you for enabling Touch ID! You can register additional fingerprints or click \"OK\" to close the Touch ID settings." \
		--icon "SF=touchid,colour=auto" \
		--mini \
		--position "${DISPLAY_DIALOG_POSITION}" \
		--button1text "OK" \
		--quitkey p \
		--hidedefaultkeyboardaction \
		--ontop
	sleep 0.1
}

workflow_touch_id() {
	[[ "${touch_id_hardware_status}" != "FALSE" ]] && check_touch_id_user_status
	if [[ "${touch_id_hardware_status}" != "FALSE" ]] && [[ "${touch_id_user_status}" == "TRUE" ]]; then
		log_pseudo "Status: Touch ID is already enabled for local user ${current_user_account_name} (${current_user_id})."
		return 0
	fi

	local dialog_touch_id_result
	if [[ "${TOUCH_ID_CONFIG}" == "REQUIRED" ]]; then
		[[ "${touch_id_hardware_status}" == "FALSE" ]] && log_pseudo "Warning: Can't enforce Touch ID enablement because this computer does not have access to Touch ID hardware." && return 0
		log_pseudo "Status: Informing user that Touch ID is required and will be configured for local user ${current_user_account_name} (${current_user_id})."
		open_dialog_touch_id_required
		dialog_touch_id_result=$?
	elif [[ "${TOUCH_ID_CONFIG}" == "OPTIONAL" ]]; then
		[[ "${touch_id_hardware_status}" == "FALSE" ]] && log_pseudo "Warning: Can't ask user to enable Touch ID because this computer does not have access to Touch ID hardware." && return 0
		log_pseudo "Status: Asking local user ${current_user_account_name} (${current_user_id}) if they want to enable optional Touch ID."
		open_dialog_touch_id_optional
		dialog_touch_id_result=$?
	else
		log_pseudo "Status: Touch ID workflow is disabled."
		return 0
	fi

	if [[ "${dialog_touch_id_result}" -eq 2 ]]; then
		log_pseudo "Status: The user chose to skip the optional Touch ID enablement." && return 0
	elif [[ "${dialog_touch_id_result}" -eq 4 ]]; then
		log_pseudo "Error: The initial Touch ID user dialog timed out after ${TIMEOUT_DEFAULT_SECONDS} seconds." && exit_error
	elif [[ "${dialog_touch_id_result}" -gt 0 ]]; then
		log_pseudo "Error: The initial Touch ID user dialog returned unexpected result: ${dialog_touch_id_result}" && exit_error
	fi

	touch_id_workflow_timer=0
	touch_id_workflow_active="FALSE"
	while [[ "${touch_id_user_status}" == "FALSE" ]] || { [[ "${touch_id_user_status}" == "TRUE" ]] && [[ "$(check_touch_id_fingerprint_sheet_active)" == "TRUE" ]]; }; do
		[[ $touch_id_workflow_timer -eq $TIMEOUT_DEFAULT_SECONDS ]] && log_pseudo "Exit: Touch ID workflow timed out after ${TIMEOUT_DEFAULT_SECONDS} seconds." && exit_error
		if [[ "${touch_id_workflow_active}" == "FALSE" ]]; then
			log_pseudo "Status: Starting Touch ID workflow with a ${TIMEOUT_DEFAULT_SECONDS} second timeout..."
			if [[ "$(check_touch_id_settings_active)" == "FALSE" ]]; then
				killall "System Settings" > /dev/null 2>&1
				sleep 1
				log_pseudo "Status: Opening Touch ID System Settings."
				open_touch_id_system_settings
			else
				log_pseudo "Status: Touch ID System Settings is already open."
			fi
			open_dialog_touch_id_start
			touch_id_workflow_active="TRUE"
		fi
		if [[ "$(check_touch_id_settings_active)" == "FALSE" ]]; then
			log_pseudo "Status: Re-opening Touch ID System Settings (the user likely closed System Settings)."
			open_touch_id_system_settings
		fi
		focus_touch_id_settings
		sleep 1
		check_touch_id_user_status
		((touch_id_workflow_timer++))
	done
	focus_touch_id_settings
	open_dialog_touch_id_success
	killall "System Settings" > /dev/null 2>&1
	log_pseudo "Status: Touch ID is now enabled for local user ${current_user_account_name} (${current_user_id}). The workflow took ${touch_id_workflow_timer} seconds to complete."
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

# Full status check including app-sso platform -s.
# Runs app-sso in the background with a 10-second timeout to prevent blocking.
check_psso_user_status() {
	check_psso_dscl_status
	psso_user_status_login_name="FALSE"
	psso_user_status_state="FALSE"

	if [[ "${psso_user_status_dscl}" != "FALSE" ]]; then
		local app_sso_tmpfile
		app_sso_tmpfile=$(mktemp /tmp/pseudo_appsso.XXXXXX)

		# Run app-sso in the background with output captured to temp file.
		run_as_user app-sso platform -s > "${app_sso_tmpfile}" 2>&1 &
		local cmd_pid=$!

		# Wait up to 10 seconds for the command to complete.
		local wait_count=0
		while kill -0 "${cmd_pid}" 2>/dev/null && [[ $wait_count -lt 10 ]]; do
			sleep 1
			((wait_count++))
		done

		# If still running after 10s, kill it and move on.
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

enable_psso_autofill_extensions() {
	local previous_ifs
	previous_ifs="${IFS}"
	IFS=$'\n'
	local plugin_kit_response
	plugin_kit_response=($(run_as_user pluginkit -m 2> /dev/null | grep 'com.okta.mobile'))
	for plugin_kit_item in "${plugin_kit_response[@]}"; do
		[[ $(echo "${plugin_kit_item}" | grep -c '+') -gt 0 ]] && log_pseudo "Status: The AutoFill extension with ID $(echo "${plugin_kit_item}" | awk -F' ' '{print $2}' | sed -e 's/(.*$//') is already enabled."
		if [[ $(echo "${plugin_kit_item}" | grep -c '+') -eq 0 ]]; then
			log_pseudo "Status: Enabling AutoFill extension with ID $(echo "${plugin_kit_item}" | awk -F' ' '{print $1}' | sed -e 's/(.*$//')."
			run_as_user pluginkit -e use -i "$(echo "${plugin_kit_item}" | awk -F' ' '{print $1}' | sed -e 's/(.*$//')" > /dev/null 2>&1
		fi
	done
	IFS="${previous_ifs}"
}

check_psso_registration_active() {
	local psso_registration_active_result
	psso_registration_active_result=$(osascript <<EOAS
tell application "System Events"
	if exists process "Single Sign-On" then
		if (exists window 1 of application process "AppSSOAgent" of application "System Events") then
			return "TRUE"
		else
			return "FALSE"
		end if
	else
		return "FALSE"
	end if
end tell
EOAS
	)
	echo "${psso_registration_active_result}"
}

open_psso_registration() {
	killall "AppSSOAgent" > /dev/null 2>&1
	run_as_user app-sso -l > /dev/null 2>&1
	sleep 1
	local open_psso_registration_result
	open_psso_registration_result=$(osascript <<EOAS
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
	tell application process "NotificationCenter"
		set allElements to entire contents of window 1
	end tell
	set foundElement to false
	repeat with aElement in allElements
		set aElementStaticTexts to static texts of aElement
		repeat with aStaticText in aElementStaticTexts
			if (name of aStaticText contains "Registration Required") then
				set foundElement to true
				set pssoElement to aElement
				exit repeat
			end if
		end repeat
		if (foundElement) then exit repeat
	end repeat
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
		return "FALSE"
	end if
end tell
EOAS
	)
	echo "${open_psso_registration_result}"
}

focus_psso_registration() {
	osascript <<EOAS
tell application "System Events"
	set allowedApps to {"AppSSOAgent", "Single Sign-On", "Dialog", "Finder", ¬
		"Safari", "Google Chrome", "Microsoft Edge", "Firefox", "Zoom", ¬
		"Brave Browser", "Slack", "Okta Verify"}

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
			tell anApp
				set visible to false
			end tell
			delay 0.1
		end if
	end repeat

	if frontApp is not in allowedApps then
		if exists process "Single Sign-On" then
			tell process "Single Sign-On"
				set frontmost to true
			end tell
		end if
	end if
end tell
EOAS
}

open_dialog_psso_start() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}"
	sleep 0.1
	"${SWIFT_DIALOG_BINARY}" \
		--title "Platform SSO Registration Required" \
		--message "**Platform SSO is required for all Mac computers at ${DISPLAY_ORGANIZATION_NAME}.**<br><br>Please click the \"Continue\" button to sign in and register with Platform SSO." \
		--icon "${psso_dialog_icon}" \
		--small \
		--position "${DISPLAY_DIALOG_POSITION}" \
		--button1text none \
		--quitkey p \
		--hidedefaultkeyboardaction \
		--ontop &
	sleep 0.1
	disown $!
}

open_dialog_psso_success() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}"
	sleep 0.1
	"${SWIFT_DIALOG_BINARY}" \
		--title "Platform SSO Registration Complete" \
		--message "Thank you for registering Platform SSO! Click \"OK\" to close this dialog." \
		--icon "${psso_dialog_icon}" \
		--mini \
		--position "${DISPLAY_DIALOG_POSITION}" \
		--button1text "OK" \
		--quitkey p \
		--hidedefaultkeyboardaction \
		--ontop
	sleep 0.1
}

open_dialog_psso_restart_countdown() {
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}"
	sleep 0.1

	"${SWIFT_DIALOG_BINARY}" \
		--title "Restart Required" \
		--message "**Platform SSO registration is complete.**\n\nYour Mac must restart to finish device setup.\n\nThe computer will automatically restart in **10 minutes**.\n\nPlease save any open work." \
		--markdown \
		--icon "${psso_dialog_icon}" \
		--position "${DISPLAY_DIALOG_POSITION}" \
		--timer 600 \
		--button1text "Restart Now" \
		--quitkey p \
		--hidedefaultkeyboardaction \
		--ontop

	return $?
}

# CHANGED: Background the shutdown so the script can exit cleanly.
# Gives Jamf binary ~15 seconds to capture exit code and report policy completion.
restart_computer() {
	log_pseudo "Status: Scheduling restart in 15 seconds to allow Jamf policy completion reporting..."
	echo "quit:" >> "${SWIFT_DIALOG_COMMAND_FILE}"
	sleep 0.2
	nohup bash -c 'sleep 15 && /sbin/shutdown -r now' &>/dev/null &
	disown $!
}

# CHANGED: Removed workspace_one_update_inventory reference — Jamf-only environment.
run_inventory_updates() {
	update_inventory_error="FALSE"
	[[ "${UPDATE_JAMF_PRO}" == "TRUE" ]] && jamf_pro_update_inventory
	[[ "${update_inventory_error}" == "TRUE" ]] && log_pseudo "Warning: Unable to complete one or more requested inventory updates."
}

# The full workflow to check Platform SSO status and if required open interfaces and dialogs to register with Platform SSO.
workflow_psso() {
	# --- Initial check — skip entirely if already fully registered. ---
	check_psso_dscl_status
	if [[ "${psso_user_status_dscl}" != "FALSE" ]]; then
		check_psso_user_status
		log_pseudo "Status: Initial PSSO check — dscl: SET, login_name: ${psso_user_status_login_name}, state: ${psso_user_status_state}"
		# CHANGED: Use psso_is_registered() to match both "registered" and "POUserStateNormal (0)" on macOS Tahoe.
		if [[ "${psso_user_status_login_name}" != "FALSE" ]] && psso_is_registered "${psso_user_status_state}"; then
			log_pseudo "Status: Platform SSO is already registered for local user ${current_user_account_name} (${current_user_id}) to account ${psso_user_status_login_name}."
			psso_workflow_active="FALSE"
			return 0
		fi
		log_pseudo "Status: Platform SSO dscl entry exists but state is '${psso_user_status_state}'. Proceeding to state verification..."
	fi

	# --- Phase 1: User-facing interactive registration. ---
	# Only runs if the dscl entry is missing (user has never completed auth).
	# Uses the lightweight dscl-only check — no app-sso calls in this loop.
	local workflow_psso_timer=0
	psso_workflow_active="FALSE"
	local psso_registration_opened="FALSE"
	local psso_window_closed_seconds=0

	while [[ "${psso_user_status_dscl}" == "FALSE" ]]; do
		[[ $workflow_psso_timer -eq $TIMEOUT_DEFAULT_SECONDS ]] && log_pseudo "Exit: Platform SSO registration workflow timed out after ${TIMEOUT_DEFAULT_SECONDS} seconds." && exit_error

		# First-time initialisation.
		if [[ "${psso_workflow_active}" == "FALSE" ]]; then
			log_pseudo "Status: Starting Platform SSO registration workflow with a ${TIMEOUT_DEFAULT_SECONDS} second timeout..."
			enable_psso_autofill_extensions

			if [[ "$(check_psso_registration_active)" == "FALSE" ]]; then
				log_pseudo "Status: Attempting to open Platform SSO registration..."
				[[ "$(open_psso_registration)" == "FALSE" ]] && log_pseudo "Exit: Unable to open Platform SSO registration." && exit_error
				psso_registration_opened="TRUE"
			else
				log_pseudo "Status: Platform SSO registration is already open."
				psso_registration_opened="TRUE"
			fi

			open_dialog_psso_start
			psso_workflow_active="TRUE"
		fi

		# Monitor the registration window.
		if [[ "$(check_psso_registration_active)" == "TRUE" ]]; then
			psso_window_closed_seconds=0
			psso_registration_opened="TRUE"
			focus_psso_registration
		else
			if [[ "${psso_registration_opened}" == "TRUE" ]]; then
				((psso_window_closed_seconds++))
				[[ $psso_window_closed_seconds -eq 1 ]] && log_pseudo "Status: Platform SSO registration window closed. Waiting up to ${PSSO_REOPEN_GRACE_SECONDS}s for background registration to complete..."

				if [[ $psso_window_closed_seconds -ge $PSSO_REOPEN_GRACE_SECONDS ]]; then
					psso_window_closed_seconds=0
					log_pseudo "Status: Grace period expired. Attempting to re-open Platform SSO registration..."
					if [[ "$(open_psso_registration)" == "FALSE" ]]; then
						log_pseudo "Warning: Unable to re-open Platform SSO registration via notification. Continuing to poll dscl..."
					else
						log_pseudo "Status: Successfully re-opened Platform SSO registration."
					fi
				fi
			else
				log_pseudo "Status: Attempting to open Platform SSO registration..."
				[[ "$(open_psso_registration)" == "FALSE" ]] && log_pseudo "Exit: Unable to open Platform SSO registration." && exit_error
				psso_registration_opened="TRUE"
			fi
		fi

		sleep 1
		check_psso_dscl_status
		((workflow_psso_timer++))
	done

	# Mark workflow as active (covers both fresh-registration and dscl-already-set paths).
	psso_workflow_active="TRUE"

	# --- Phase 2: Background state verification. ---
	# The dscl entry is confirmed. Now verify full registration state via app-sso
	# with a hard timeout — app-sso platform -s can block after fresh registration.
	log_pseudo "Status: Platform SSO dscl entry confirmed. Verifying full registration state (${PSSO_STATE_VERIFY_SECONDS}s timeout)..."

	local state_verify_start
	state_verify_start=$(date +%s)

	while true; do
		check_psso_user_status
		log_pseudo "Status: PSSO state verification — login_name: ${psso_user_status_login_name}, state: ${psso_user_status_state}"

		# CHANGED: Use psso_is_registered() to match both "registered" and "POUserStateNormal (0)" on macOS Tahoe.
		if [[ "${psso_user_status_login_name}" != "FALSE" ]] && psso_is_registered "${psso_user_status_state}"; then
			log_pseudo "Status: Platform SSO registration fully verified (state: ${psso_user_status_state}, login_name: ${psso_user_status_login_name})."
			break
		fi

		# Timeout — proceed anyway; dscl entry is authoritative.
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
	dialog_restart_result=$?

	if [[ "${dialog_restart_result}" -eq 0 ]]; then
		log_pseudo "Status: User chose immediate restart."
	elif [[ "${dialog_restart_result}" -eq 4 ]]; then
		log_pseudo "Status: Restart countdown expired. Restarting automatically."
	else
		log_pseudo "Status: Restart dialog returned result ${dialog_restart_result}. Restarting for safety."
	fi

	# CHANGED: Schedule backgrounded restart and exit cleanly so Jamf can report policy completion.
	restart_computer
	exit_success
}

# MARK: *** Main Workflow ***
################################################################################

main() {
	workflow_startup
	workflow_touch_id
	workflow_psso
	# If we reach here, PSSO was already registered (no restart triggered).
	run_inventory_updates
}

main "$@"
exit_success
