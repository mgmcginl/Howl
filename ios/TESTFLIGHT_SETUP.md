# TestFlight Setup Without A Mac

This is the path for building and uploading the iPhone app from GitHub Actions.

## What You Need

- Apple Developer Program membership
- Access to your Apple Developer account
- Access to App Store Connect
- Admin access on this GitHub repo so you can add secrets
- OpenSSL on Windows, macOS, or Linux

## Overview

You will do four things:

1. Create a bundle identifier in Apple Developer.
2. Create the App Store Connect app record.
3. Create signing assets and an App Store Connect API key.
4. Add GitHub secrets and run the `iOS Release` workflow.

## 1. Create The Bundle Identifier

In Apple Developer:

1. Open `Certificates, Identifiers & Profiles`.
2. Go to `Identifiers`.
3. Create an `App ID`.
4. Choose a unique bundle ID like `com.yourname.howl.ios`.
5. Enable only the capabilities you actually need.

Use that exact bundle ID later in:

- App Store Connect
- your provisioning profile
- the GitHub Actions workflow input

## 2. Create The App Store Connect App Record

In App Store Connect:

1. Open `Apps`.
2. Create a new iOS app.
3. Use the same bundle ID you created above.
4. Pick a SKU you will remember.

You only need to do this once per bundle ID.

## 3. Create A Distribution Certificate Without A Mac

You need an `Apple Distribution` certificate as a `.p12`.

### Generate a private key and CSR with OpenSSL

On Windows PowerShell:

```powershell
openssl genrsa -out ios_distribution.key 2048
openssl req -new -key ios_distribution.key -out ios_distribution.csr
```

When prompted, the values are not very important for CI. Keep the files safe.

### Create the certificate in Apple Developer

1. Open `Certificates`.
2. Create a new certificate.
3. Choose `Apple Distribution`.
4. Upload `ios_distribution.csr`.
5. Download the resulting `.cer` file.

### Convert the certificate into `.p12`

On Windows PowerShell:

```powershell
openssl x509 -in ios_distribution.cer -inform DER -out ios_distribution.pem -outform PEM
openssl pkcs12 -export -inkey ios_distribution.key -in ios_distribution.pem -out ios_distribution.p12
```

You will be asked for a password. Save it. That becomes `P12_PASSWORD`.

## 4. Create An App Store Provisioning Profile

In Apple Developer:

1. Open `Profiles`.
2. Create a new profile.
3. Choose `App Store`.
4. Pick the bundle ID you created earlier.
5. Pick the `Apple Distribution` certificate.
6. Download the `.mobileprovision` file.

## 5. Create An App Store Connect API Key

In App Store Connect:

1. Open `Users and Access`.
2. Open `Integrations`.
3. Create an API key.
4. Use a key with access that can upload builds.
5. Download the `.p8` key once. Apple will not show it again.

Save:

- the `.p8` file
- the `Key ID`
- the `Issuer ID`

Use a team API key, not an individual personal shortcut. The GitHub workflow expects the standard App Store Connect API key flow.

## 6. Convert Files To Base64

GitHub secrets are easier if the binary files are base64 encoded first.

On Windows PowerShell:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("ios_distribution.p12")) | Set-Content build_certificate_base64.txt
[Convert]::ToBase64String([IO.File]::ReadAllBytes("YourProfile.mobileprovision")) | Set-Content build_profile_base64.txt
[Convert]::ToBase64String([IO.File]::ReadAllBytes("AuthKey_ABC123XYZ.p8")) | Set-Content app_store_connect_key_base64.txt
```

## 7. Add GitHub Secrets

In GitHub, add these repository secrets:

- `BUILD_CERTIFICATE_BASE64`
  The contents of `build_certificate_base64.txt`
- `P12_PASSWORD`
  The password you chose when exporting the `.p12`
- `BUILD_PROVISION_PROFILE_BASE64`
  The contents of `build_profile_base64.txt`
- `KEYCHAIN_PASSWORD`
  Any strong random password for the temporary CI keychain
- `APP_STORE_CONNECT_API_KEY_BASE64`
  The contents of `app_store_connect_key_base64.txt`
- `APP_STORE_CONNECT_KEY_ID`
  From App Store Connect
- `APP_STORE_CONNECT_ISSUER_ID`
  From App Store Connect

## 8. Run The Workflow

In GitHub Actions:

1. Run `iOS Release`.
2. Enter the bundle ID you registered, for example `com.yourname.howl.ios`.
3. Enter a marketing version like `0.1.0`.
4. Leave `build_number` blank unless you need a specific one.
5. Leave `upload_to_testflight` enabled.

What the workflow does:

- generates the Xcode project
- imports the certificate and provisioning profile
- archives a signed iOS build
- exports an `.ipa`
- uploads the `.ipa` as a GitHub artifact
- uploads the build to App Store Connect / TestFlight

## 9. What Success Looks Like

- The `iOS Release` workflow finishes successfully.
- An `.ipa` artifact is attached to the run.
- App Store Connect shows a new build processing.
- After processing, the build appears in TestFlight.

## Common Failure Modes

- Bundle ID mismatch
  The workflow input, provisioning profile, and App Store Connect app must all use the same bundle ID.

- Wrong certificate/profile pairing
  The App Store provisioning profile must include the exact distribution certificate used to create the `.p12`.

- Missing App Store Connect permissions
  The API key must have enough access to upload builds.

- Bad base64 secret
  If a decoded file is corrupt, signing or upload will fail early.

- Capability mismatch
  If the provisioning profile or App ID does not match the app capabilities, the archive step can fail.

## Recommended First Run

Use:

- a fresh unique bundle ID
- version `0.1.0`
- blank build number
- upload enabled

If the first run fails, collect:

- the failing GitHub Actions step
- the exact error text
- whether failure happened during archive, export, or upload

That will usually tell us the real problem immediately.
