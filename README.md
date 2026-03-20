I have developed a script to help streamline the process of adding computers to Intune Autopilot and getting them enrolled.  The issue has been automating the process of both adding them to autopilot and also enrolling them during OOBE.  Microsoft does not support those steps natively so my script gets around that by adding an OOBE reset once the autopilot add portion has been completed and verified.  This works on previously used PCs as well as brand new OEM machines.

"UploadAutopilotHash-TEMPLATE.ps1" is mainly intended for brand new out of the box PCs that need to get their hash uploaded (or for PCs that need to get added and are ready to be reset to OOBE status), but can also be used on previously used machines as long as you are ok with keeping their installed apps installed. 
Pre-req's for this script:
  - Autopilot device profile has been set up in Intune, ideally in "self-driven" mode.
  - Enterprise app in Azure has been created, usually named something like "Autopilot hash upload".
  - Graph application permissions for read/write all have been added to the application and admin has granted request.
  - Secret key has been created for app.
  - Copy and paste the tenant id, client id (app id), and key value you have stored somewhere into the script as noted near the top.
If deploying a brand new PC, ideally it's best to pacakge it into a ppkg file via Windows Configuration designer, and put the ppkg on the root of a USB stick.
Plug the USB stick into the PC, power it on, connect it to internet, and the script will take over and after it has been added to autopilot it will do an OOBE reset and reboot.
After the reset and reboot, OOBE should automatically see that the PC is tied to autopilot and begin Intune enrollment.  A windows login screen should be ready within a few minutes, ready for an Intune licensed user to log in.
