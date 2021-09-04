Set-ExecutionPolicy RemoteSigned

#Connect to Azure AD
Install-Module -Name AzureAD -AllowClobber

#Connect to Office 365
Install-Module MSOnline

cd '.\Organisational Data'
Unblock-File .\helper.psm1
Unblock-File .\Generate-WpaOrganizationFile.ps1