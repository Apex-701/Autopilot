I have developed a few scripts to help streamline the process of adding computers to Intune Autopilot and getting them enrolled.

"UploadAutopilotHash-TEMPLATE.ps1" is intended for brand new out of the box PCs that need to get their hash uploaded (or for PCs that need to get added and are ready to be reset to OOBE status). 
Pre-req's for this script:
  - Autopilot device profile has been set up in Intune, ideally in "self-driven" mode.
  - Enterprise app in Azure has been created, usually named something like "Autopilot hash upload".
  - Go to the app registration for it, add graph application permissions for read/write all, then grant permissions request.
  - Create a new secret key, store the key value somewhere safe and not public facing
  - Copy and paste the tenant id, client id (app id), and key value you have stored somewhere into the script as noted near the top.
If deploying a brand new PC, ideally it's best to pacakge it into a ppkg file via Windows Configuration designer, and put the ppkg on the root of a USB stick.
Plug the USB stick into the PC, power it on, connect it to internet, and the script will take over and after it has been added to autopilot it will do an OOBE reset and reboot.
After the reset and reboot, OOBE should automatically see that the PC is tied to autopilot and begin Intune enrollment.  A windows login screen should be ready within a few minutes, ready for an Intune licensed user to log in.
