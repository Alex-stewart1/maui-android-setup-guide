# .NET 10 + .NET MAUI Android Setup (No IDE)

This guide walks through setting up a fresh system for building .NET MAUI Android applications **without installing an IDE** such as Visual Studio or Rider.

---

# 1. Install .NET 10 SDK

Download and install the .NET 10 SDK:

- https://dotnet.microsoft.com/en-us/download/dotnet/10.0

After installation, verify it is installed correctly:

```bash
dotnet --version
````

---

# 2. Install .NET MAUI Workloads

Install the MAUI templates and workloads:

```bash
dotnet new install Microsoft.Maui.Templates
dotnet workload install maui
```

You can verify installed workloads with:

```bash
dotnet workload list
```

---

# 3. Install Microsoft OpenJDK 21

Download and install the recommended Microsoft OpenJDK version.

At the time of writing, this is:

* OpenJDK 21

Download link:

* [https://learn.microsoft.com/en-us/java/openjdk/download#openjdk-21](https://learn.microsoft.com/en-us/java/openjdk/download#openjdk-21)

After installation, note the installation path. Example:

```text
C:\Program Files\Microsoft\jdk-21-hotspot
```

---

# 4. Install Android SDK Command Line Tools

Go to the Android Studio downloads page:

* [https://developer.android.com/studio#download](https://developer.android.com/studio#download)

Scroll down to:

```text
Command Line Tools Only
```

Download the ZIP file for your operating system.

---

# 5. Create Android SDK Directory

Create an Android SDK directory somewhere on your drive.

Recommended example:

```text
C:\Program Files (x86)\Android\android-sdk
```

Keeping it near the root of the drive avoids path-length issues.

---

# 6. Extract Command Line Tools

Extract the downloaded ZIP into your Android SDK directory.

You should end up with something similar to:

```text
android-sdk\
└── cmdline-tools\
```

---

# 7. Fix Google's Folder Nesting Issue

Google ships the command line tools with an incorrect nesting structure for some tooling.

By default, extraction often looks like this:

```text
android-sdk\cmdline-tools\bin
```

You must restructure it so the final path becomes:

```text
android-sdk\cmdline-tools\latest\bin
```

Final expected structure:

```text
android-sdk\
└── cmdline-tools\
    └── latest\
        ├── bin
        ├── lib
        └── source.properties
```

This avoids issues with MAUI and Android tooling later.

---

# 8. Accept Android SDK Licenses

Open a terminal in:

```text
android-sdk\cmdline-tools\latest\bin
```

Run:

```bash
sdkmanager --licenses
```

Accept all licenses.

---

# 9. Install Required Android SDK Components

From the same terminal location, run:

```bash
sdkmanager "platform-tools" "emulator" "tools"
```

You may also want to install a platform and build-tools version:

```bash
sdkmanager "platforms;android-35" "build-tools;35.0.0"
```

---

# 10. Configure Environment Variables

## ANDROID_HOME

Create a system environment variable:

```text
ANDROID_HOME
```

Value:

```text
C:\Program Files (x86)\Android\android-sdk
```

---

## JAVA_HOME

Create a system environment variable:

```text
JAVA_HOME
```

Value:

```text
C:\Program Files\Microsoft\jdk-21-hotspot
```

> Do not point JAVA_HOME to the `bin` directory.

---

## PATH

Add the following to your system `PATH`:

```text
%ANDROID_HOME%\cmdline-tools\latest\bin
%ANDROID_HOME%\platform-tools
%ANDROID_HOME%\emulator
%JAVA_HOME%\bin
```

Optional legacy tools path:

```text
%ANDROID_HOME%\tools
```

---

# 11. Verify Installation

Verify Java:

```bash
java -version
```

Verify Android SDK manager:

```bash
sdkmanager --version
```

Verify MAUI:

```bash
dotnet workload list
```

---

# 12. Create and Build a MAUI Android Project

Create a new project:

```bash
dotnet new maui -n MauiTestApp
cd MauiTestApp
```

Build Android:

```bash
dotnet build -f net10.0-android
```

If everything is configured correctly, the build should complete successfully.

---

# Common Issues

## `JAVA_HOME is set incorrectly`

Make sure `JAVA_HOME` points to the JDK root folder, not the `bin` folder.

Correct:

```text
C:\Program Files\Microsoft\jdk-21-hotspot
```

Incorrect:

```text
C:\Program Files\Microsoft\jdk-21-hotspot\bin
```

---

## `sdkmanager` Not Found

Ensure this exists in your PATH:

```text
%ANDROID_HOME%\cmdline-tools\latest\bin
```

---

## Android SDK Not Detected

Verify:

* `ANDROID_HOME` is set correctly
* SDK folders exist
* `platform-tools` is installed

---

# Emulator Setup

Install additional emulator packages:

```bash
sdkmanager "system-images;android-35;google_apis;x86_64"
sdkmanager "system-images;android-35;google_apis_playstore;x86_64"
```

## Create Standard Emulator

```bash
avdmanager create avd -n Pixel_Emulator_API_35 -k "system-images;android-35;google_apis;x86_64"
```

## Create Pixel 6 Pro Play Store Emulator

```bash
avdmanager create avd -n Pixel_6_Pro_API_35_Play -k "system-images;android-35;google_apis_playstore;x86_64" --device "pixel_6_pro"
```

## Start Emulator

```bash
emulator -avd Pixel_Emulator_API_35
```

Or:

```bash
emulator -avd Pixel_6_Pro_API_35_Play
```

---

# Running a MAUI App on the Emulator

With the emulator already running, start the MAUI Android app using:

```bash
dotnet build -t:Run -f net10.0-android
```

This will build, deploy, and launch the application on the running emulator.

---

# Emulator Window Off-Screen (Windows)

If the emulator is running but the window is off-screen:

1. Open Task Manager:

```text
Ctrl + Shift + Esc
```

2. Find the process:

```text
qemu-system-x86_64
```

3. Expand the process tree to locate the specific emulator instance.

4. Right-click the emulator process and choose:

```text
Maximize
```

or:

```text
Bring to front
```

---

# Emulator Timeout Configuration

The default emulator wait timeout before automatic termination is:

```text
20 seconds
```

You can change this value using:

```text
ANDROID_EMULATOR_WAIT_TIME_BEFORE_KILL
```

Example:

```bash
set ANDROID_EMULATOR_WAIT_TIME_BEFORE_KILL=60
```

This sets the timeout to 60 seconds.

---

# Useful Commands

## Update Android SDK Packages

```bash
sdkmanager --update
```

## List Installed SDK Packages

```bash
sdkmanager --list
```

## List Available Android Virtual Devices

```bash
emulator -list-avds
```

## Start a Specific Emulator

```bash
emulator -avd Pixel_6_Pro_API_35_Play
```

## Verify Connected Devices

```bash
adb devices
```