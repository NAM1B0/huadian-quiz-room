"""Deterministic Xcode project generator. Python standard library; no CocoaPods."""
from pathlib import Path
import hashlib
import json
import plistlib

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "HuadianQuiz.xcodeproj"
objects = {}

def ident(key):
    return hashlib.sha1(key.encode()).hexdigest()[:24].upper()

def add(key, isa, **values):
    uid = ident(key)
    objects[uid] = {"isa": isa, **values}
    return uid

def ref(path, kind, tree="<group>"):
    return add("file:" + path, "PBXFileReference", lastKnownFileType=kind, path=path, sourceTree=tree)

def phase(target, kind, files):
    builds = [add(target + ":build:" + file, "PBXBuildFile", fileRef=file) for file in files]
    return add(target + ":phase:" + kind, kind, buildActionMask="2147483647", files=builds, runOnlyForDeploymentPostprocessing="0")

def configs(key, common, debug=None, release=None):
    values = []
    for name, extra in [("Debug", debug or {}), ("Release", release or {})]:
        settings = {**common, **extra}
        values.append(add(key + ":" + name, "XCBuildConfiguration", buildSettings=settings, name=name))
    return add(key + ":configs", "XCConfigurationList", buildConfigurations=values, defaultConfigurationIsVisible="0", defaultConfigurationName="Release")

app_sources = [ref("Sources/" + p.name, "sourcecode.swift") for p in sorted((ROOT / "Sources").glob("*.swift"))]
unit_sources = [ref("Tests/" + p.name, "sourcecode.swift") for p in sorted((ROOT / "Tests").glob("*.swift"))]
ui_sources = [ref("UITests/" + p.name, "sourcecode.swift") for p in sorted((ROOT / "UITests").glob("*.swift"))]
resource_folder = ROOT / "Resources"
resource_folder.mkdir(exist_ok=True)
(resource_folder / "question-bank.pdf").write_bytes((ROOT.parent / "source" / "题库原文.pdf").read_bytes())
resources = [ref("../bank.json", "text.json"), ref("Resources/question-bank.pdf", "image.pdf"), ref("Assets.xcassets", "folder.assetcatalog"), ref("PrivacyInfo.xcprivacy", "text.xml")]
info = ref("Info.plist", "text.plist.xml")
products = []
targets = []
project_id = ident("project")

common = {"IPHONEOS_DEPLOYMENT_TARGET": "26.0", "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0",
          "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "SWIFT_STRICT_CONCURRENCY": "targeted",
          "TARGETED_DEVICE_FAMILY": "1", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
          "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO", "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
          "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": "", "ENABLE_USER_SCRIPT_SANDBOXING": "YES"}
project_config = configs("project", common,
    {"SWIFT_OPTIMIZATION_LEVEL": "-Onone", "DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)", "ONLY_ACTIVE_ARCH": "YES"},
    {"SWIFT_COMPILATION_MODE": "wholemodule", "SWIFT_OPTIMIZATION_LEVEL": "-O", "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "VALIDATE_PRODUCT": "YES"})

for target, source, product_type, suffix in [
    ("HuadianQuiz", app_sources, "com.apple.product-type.application", "app"),
    ("HuadianQuizTests", unit_sources, "com.apple.product-type.bundle.unit-test", "xctest"),
    ("HuadianQuizUITests", ui_sources, "com.apple.product-type.bundle.ui-testing", "xctest")]:
    product = add(target + ":product", "PBXFileReference", explicitFileType="wrapper.application" if suffix == "app" else "wrapper.cfbundle", includeInIndex="0", path=target + "." + suffix, sourceTree="BUILT_PRODUCTS_DIR")
    products.append(product)
    phases = [phase(target, "PBXSourcesBuildPhase", source), phase(target, "PBXFrameworksBuildPhase", []), phase(target, "PBXResourcesBuildPhase", resources if suffix == "app" else [])]
    settings = {"PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "io.github.nam1b0." + target.lower(),
                "SWIFT_EMIT_LOC_STRINGS": "YES", "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"], "GENERATE_INFOPLIST_FILE": "YES"}
    dependencies = []
    if suffix == "app":
        settings.update({"INFOPLIST_FILE": "Info.plist", "GENERATE_INFOPLIST_FILE": "NO", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor", "MARKETING_VERSION": "1.0.4", "CURRENT_PROJECT_VERSION": "10403", "OTHER_LDFLAGS": ["$(inherited)", "-lsqlite3"]})
    else:
        proxy = add(target + ":proxy", "PBXContainerItemProxy", containerPortal=project_id, proxyType="1", remoteGlobalIDString=ident("target:HuadianQuiz"), remoteInfo="HuadianQuiz")
        dependencies = [add(target + ":dependency", "PBXTargetDependency", target=ident("target:HuadianQuiz"), targetProxy=proxy)]
        settings["OTHER_LDFLAGS"] = ["$(inherited)", "-lsqlite3"]
        if suffix == "xctest" and target.endswith("UITests"):
            settings["TEST_TARGET_NAME"] = "HuadianQuiz"
        else:
            settings.update({"TEST_HOST": "$(BUILT_PRODUCTS_DIR)/HuadianQuiz.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/HuadianQuiz", "BUNDLE_LOADER": "$(TEST_HOST)"})
    target_config = configs(target, settings)
    targets.append(add("target:" + target, "PBXNativeTarget", buildConfigurationList=target_config, buildPhases=phases, buildRules=[], dependencies=dependencies, name=target, productName=target, productReference=product, productType=product_type))

product_group = add("products", "PBXGroup", children=products, name="Products", sourceTree="<group>")
main_group = add("main", "PBXGroup", children=app_sources + unit_sources + ui_sources + resources + [info, product_group], sourceTree="<group>")
add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2600", "TargetAttributes": {ident("target:" + name): {"CreatedOnToolsVersion": "26.0", **({"TestTargetID": ident("target:HuadianQuiz")} if name != "HuadianQuiz" else {})} for name in ["HuadianQuiz", "HuadianQuizTests", "HuadianQuizUITests"]}}, buildConfigurationList=project_config, compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans", hasScannedForEncodings="0", knownRegions=["zh-Hans", "en", "Base"], mainGroup=main_group, productRefGroup=product_group, projectDirPath="", projectRoot="", targets=targets)

def serialize(value, level=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (level + 1) + json.dumps(k, ensure_ascii=False) + " = " + serialize(v, level + 1) + ";\n" for k, v in value.items()) + "\t" * level + "}"
    if isinstance(value, list):
        return "(" + ", ".join(serialize(v, level) for v in value) + ("," if value else "") + ")"
    return json.dumps(value, ensure_ascii=False)

PROJECT.mkdir(exist_ok=True)
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize({"archiveVersion": "1", "classes": {}, "objectVersion": "56", "objects": objects, "rootObject": project_id}) + "\n", encoding="utf-8")
scheme_folder = PROJECT / "xcshareddata" / "xcschemes"
scheme_folder.mkdir(parents=True, exist_ok=True)
def build_ref(name, ext):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target:" + name)}" BuildableName="{name}.{ext}" BlueprintName="{name}" ReferencedContainer="container:HuadianQuiz.xcodeproj"/>'
app_ref = build_ref("HuadianQuiz", "app")
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>
<TestableReference skipped="NO" parallelizable="NO">{build_ref("HuadianQuizTests", "xctest")}</TestableReference>
<TestableReference skipped="NO" parallelizable="NO">{build_ref("HuadianQuizUITests", "xctest")}</TestableReference>
</Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
(scheme_folder / "HuadianQuiz.xcscheme").write_text(scheme, encoding="utf-8")
info_plist = {"CFBundleDevelopmentRegion": "zh_CN", "CFBundleDisplayName": "华电题库", "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "$(PRODUCT_NAME)", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)", "LSRequiresIPhoneOS": True, "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False}, "UILaunchScreen": {}, "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"], "UIRequiredDeviceCapabilities": ["arm64"], "ITSAppUsesNonExemptEncryption": False}
with (ROOT / "Info.plist").open("wb") as f:
    plistlib.dump(info_plist, f, sort_keys=False)
with (ROOT / "PrivacyInfo.xcprivacy").open("wb") as f:
    plistlib.dump({"NSPrivacyTracking": False, "NSPrivacyCollectedDataTypes": [], "NSPrivacyTrackingDomains": [], "NSPrivacyAccessedAPITypes": [{"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategorySystemBootTime", "NSPrivacyAccessedAPITypeReasons": ["35F9.1"]}, {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp", "NSPrivacyAccessedAPITypeReasons": ["C617.1"]}]}, f)
print("Generated Xcode project with", len(app_sources), "app sources and", len(unit_sources) + len(ui_sources), "test sources.")
