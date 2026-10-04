#!/usr/bin/env python3
import os

project_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
xcodeproj_dir = os.path.join(project_dir, "Headroom.xcodeproj")
os.makedirs(xcodeproj_dir, exist_ok=True)
pbxproj_path = os.path.join(xcodeproj_dir, "project.pbxproj")

# We define fixed 24-character hex IDs
# Format: 000000000000000000000000

def fid(prefix, index):
    return f"{prefix:04X}{index:020X}"

# Let's collect core, mac, and ios files
def get_files(subdir):
    res = []
    base = os.path.join(project_dir, subdir)
    for root, _, files in os.walk(base):
        for f in sorted(files):
            if f.endswith(".swift"):
                rel = os.path.relpath(os.path.join(root, f), project_dir)
                res.append((f, rel))
    return res

core_files = get_files("HeadroomCore/Sources/HeadroomCore")
mac_files = get_files("HeadroomMac")
ios_files = get_files("HeadroomIOS")

# ID allocations
# Prefix 0001: PBXFileReference
# Prefix 0002: PBXBuildFile
# Prefix 0003: Groups / Phases
# Prefix 0004: Targets
# Prefix 0005: Configurations

file_refs = {}
build_files = {}

idx = 1
for f, path in core_files + mac_files + ios_files:
    file_id = fid(0x1000, idx)
    file_refs[path] = (file_id, f)
    idx += 1

# Special file references
info_plist_mac_id = fid(0x1000, 100)
entitlements_mac_id = fid(0x1000, 101)
info_plist_ios_id = fid(0x1000, 102)
entitlements_ios_id = fid(0x1000, 103)
icon_mac_id = fid(0x1000, 104)

app_mac_ref = fid(0x1000, 201)
app_ios_ref = fid(0x1000, 202)
framework_core_ref = fid(0x1000, 203)

# Build files
bidx = 1
core_build_files = []
for f, path in core_files:
    bid = fid(0x2000, bidx)
    core_build_files.append((bid, file_refs[path][0], f))
    bidx += 1

mac_build_files = []
for f, path in mac_files:
    bid = fid(0x2000, bidx)
    mac_build_files.append((bid, file_refs[path][0], f))
    bidx += 1

ios_build_files = []
for f, path in ios_files:
    bid = fid(0x2000, bidx)
    ios_build_files.append((bid, file_refs[path][0], f))
    bidx += 1

# Framework build files for linking
core_in_mac_frameworks = fid(0x2000, 301)
core_in_ios_frameworks = fid(0x2000, 302)
core_in_mac_embed = fid(0x2000, 303)
core_in_ios_embed = fid(0x2000, 304)
icon_mac_resource = fid(0x2000, 305)

# Targets
target_core = fid(0x4000, 1)
target_mac = fid(0x4000, 2)
target_ios = fid(0x4000, 3)

# Target dependencies
dep_mac_core = fid(0x4000, 10)
proxy_mac_core = fid(0x4000, 11)
dep_ios_core = fid(0x4000, 12)
proxy_ios_core = fid(0x4000, 13)

# Build Phases
sources_core = fid(0x3000, 1)
frameworks_core = fid(0x3000, 2)
headers_core = fid(0x3000, 3)

sources_mac = fid(0x3000, 10)
frameworks_mac = fid(0x3000, 11)
embed_mac = fid(0x3000, 12)
resources_mac = fid(0x3000, 13)

sources_ios = fid(0x3000, 20)
frameworks_ios = fid(0x3000, 21)
embed_ios = fid(0x3000, 22)

# Configs
project_obj = fid(0x5000, 1)
cfg_proj_debug = fid(0x5000, 2)
cfg_proj_release = fid(0x5000, 3)
cfg_list_proj = fid(0x5000, 4)

cfg_core_debug = fid(0x5000, 10)
cfg_core_release = fid(0x5000, 11)
cfg_list_core = fid(0x5000, 12)

cfg_mac_debug = fid(0x5000, 20)
cfg_mac_release = fid(0x5000, 21)
cfg_list_mac = fid(0x5000, 22)

cfg_ios_debug = fid(0x5000, 30)
cfg_ios_release = fid(0x5000, 31)
cfg_list_ios = fid(0x5000, 32)

main_group = fid(0x3000, 100)
products_group = fid(0x3000, 101)
core_group = fid(0x3000, 102)
mac_group = fid(0x3000, 103)
ios_group = fid(0x3000, 104)

out = []
out.append("// !$*UTF8*$!")
out.append("{")
out.append("\tarchiveVersion = 1;")
out.append("\tclasses = {};")
out.append("\tobjectVersion = 56;")
out.append("\tobjects = {")

# PBXBuildFile
out.append("\n/* Begin PBXBuildFile section */")
for bid, fid_ref, fname in core_build_files:
    out.append(f"\t\t{bid} /* {fname} in Sources */ = {{isa = PBXBuildFile; fileRef = {fid_ref} /* {fname} */; }};")
for bid, fid_ref, fname in mac_build_files:
    out.append(f"\t\t{bid} /* {fname} in Sources */ = {{isa = PBXBuildFile; fileRef = {fid_ref} /* {fname} */; }};")
for bid, fid_ref, fname in ios_build_files:
    out.append(f"\t\t{bid} /* {fname} in Sources */ = {{isa = PBXBuildFile; fileRef = {fid_ref} /* {fname} */; }};")

out.append(f"\t\t{core_in_mac_frameworks} /* HeadroomCore.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {framework_core_ref} /* HeadroomCore.framework */; }};")
out.append(f"\t\t{core_in_ios_frameworks} /* HeadroomCore.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {framework_core_ref} /* HeadroomCore.framework */; }};")
out.append(f"\t\t{core_in_mac_embed} /* HeadroomCore.framework in Embed Frameworks */ = {{isa = PBXBuildFile; fileRef = {framework_core_ref} /* HeadroomCore.framework */; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};")
out.append(f"\t\t{core_in_ios_embed} /* HeadroomCore.framework in Embed Frameworks */ = {{isa = PBXBuildFile; fileRef = {framework_core_ref} /* HeadroomCore.framework */; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};")
out.append(f"\t\t{icon_mac_resource} /* Headroom.icns in Resources */ = {{isa = PBXBuildFile; fileRef = {icon_mac_id} /* Headroom.icns */; }};")
out.append("/* End PBXBuildFile section */")

# PBXContainerItemProxy
out.append("\n/* Begin PBXContainerItemProxy section */")
out.append(f"\t\t{proxy_mac_core} /* PBXContainerItemProxy */ = {{")
out.append(f"\t\t\tisa = PBXContainerItemProxy;")
out.append(f"\t\t\tcontainerPortal = {project_obj} /* Project object */;")
out.append(f"\t\t\tproxyType = 1;")
out.append(f"\t\t\tremoteGlobalIDString = {target_core};")
out.append(f"\t\t\tremoteInfo = HeadroomCore;")
out.append("\t\t};")
out.append(f"\t\t{proxy_ios_core} /* PBXContainerItemProxy */ = {{")
out.append(f"\t\t\tisa = PBXContainerItemProxy;")
out.append(f"\t\t\tcontainerPortal = {project_obj} /* Project object */;")
out.append(f"\t\t\tproxyType = 1;")
out.append(f"\t\t\tremoteGlobalIDString = {target_core};")
out.append(f"\t\t\tremoteInfo = HeadroomCore;")
out.append("\t\t};")
out.append("/* End PBXContainerItemProxy section */")

# PBXCopyFilesBuildPhase
out.append("\n/* Begin PBXCopyFilesBuildPhase section */")
out.append(f"\t\t{embed_mac} /* Embed Frameworks */ = {{")
out.append("\t\t\tisa = PBXCopyFilesBuildPhase;")
out.append("\t\t\tbuildActionMask = 2147483647;")
out.append("\t\t\tdstPath = \"\";")
out.append("\t\t\tdstSubfolderSpec = 10;")
out.append("\t\t\tfiles = (")
out.append(f"\t\t\t\t{core_in_mac_embed} /* HeadroomCore.framework in Embed Frameworks */,")
out.append("\t\t\t);")
out.append("\t\t\tname = \"Embed Frameworks\";")
out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
out.append("\t\t};")
out.append(f"\t\t{embed_ios} /* Embed Frameworks */ = {{")
out.append("\t\t\tisa = PBXCopyFilesBuildPhase;")
out.append("\t\t\tbuildActionMask = 2147483647;")
out.append("\t\t\tdstPath = \"\";")
out.append("\t\t\tdstSubfolderSpec = 10;")
out.append("\t\t\tfiles = (")
out.append(f"\t\t\t\t{core_in_ios_embed} /* HeadroomCore.framework in Embed Frameworks */,")
out.append("\t\t\t);")
out.append("\t\t\tname = \"Embed Frameworks\";")
out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
out.append("\t\t};")
out.append("/* End PBXCopyFilesBuildPhase section */")

# PBXFileReference
out.append("\n/* Begin PBXFileReference section */")
for path, (file_id, fname) in file_refs.items():
    out.append(f"\t\t{file_id} /* {fname} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"{path}\"; sourceTree = \"<group>\"; }};")

out.append(f"\t\t{info_plist_mac_id} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = \"HeadroomMac/Info.plist\"; sourceTree = \"<group>\"; }};")
out.append(f"\t\t{entitlements_mac_id} /* HeadroomMac.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = \"HeadroomMac/HeadroomMac.entitlements\"; sourceTree = \"<group>\"; }};")
out.append(f"\t\t{info_plist_ios_id} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = \"HeadroomIOS/Info.plist\"; sourceTree = \"<group>\"; }};")
out.append(f"\t\t{entitlements_ios_id} /* HeadroomIOSEntitlements.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = \"HeadroomIOS/HeadroomIOSEntitlements.entitlements\"; sourceTree = \"<group>\"; }};")
out.append(f"\t\t{icon_mac_id} /* Headroom.icns */ = {{isa = PBXFileReference; lastKnownFileType = image.icns; path = \"HeadroomMac/Resources/Headroom.icns\"; sourceTree = \"<group>\"; }};")

out.append(f"\t\t{app_mac_ref} /* HeadroomMac.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = HeadroomMac.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
out.append(f"\t\t{app_ios_ref} /* HeadroomIOS.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = HeadroomIOS.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
out.append(f"\t\t{framework_core_ref} /* HeadroomCore.framework */ = {{isa = PBXFileReference; explicitFileType = wrapper.framework; includeInIndex = 0; path = HeadroomCore.framework; sourceTree = BUILT_PRODUCTS_DIR; }};")
out.append("/* End PBXFileReference section */")

# PBXFrameworksBuildPhase
out.append("\n/* Begin PBXFrameworksBuildPhase section */")
out.append(f"\t\t{frameworks_core} /* Frameworks */ = {{")
out.append("\t\t\tisa = PBXFrameworksBuildPhase;")
out.append("\t\t\tbuildActionMask = 2147483647;")
out.append("\t\t\tfiles = ();")
out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
out.append("\t\t};")
out.append(f"\t\t{frameworks_mac} /* Frameworks */ = {{")
out.append("\t\t\tisa = PBXFrameworksBuildPhase;")
out.append("\t\t\tbuildActionMask = 2147483647;")
out.append("\t\t\tfiles = (")
out.append(f"\t\t\t\t{core_in_mac_frameworks} /* HeadroomCore.framework in Frameworks */,")
out.append("\t\t\t);")
out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
out.append("\t\t};")
out.append(f"\t\t{frameworks_ios} /* Frameworks */ = {{")
out.append("\t\t\tisa = PBXFrameworksBuildPhase;")
out.append("\t\t\tbuildActionMask = 2147483647;")
out.append("\t\t\tfiles = (")
out.append(f"\t\t\t\t{core_in_ios_frameworks} /* HeadroomCore.framework in Frameworks */,")
out.append("\t\t\t);")
out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
out.append("\t\t};")
out.append("/* End PBXFrameworksBuildPhase section */")

# PBXGroup
out.append("\n/* Begin PBXGroup section */")
out.append(f"\t\t{main_group} = {{")
out.append("\t\t\tisa = PBXGroup;")
out.append("\t\t\tchildren = (")
out.append(f"\t\t\t\t{core_group} /* HeadroomCore */,")
out.append(f"\t\t\t\t{mac_group} /* HeadroomMac */,")
out.append(f"\t\t\t\t{ios_group} /* HeadroomIOS */,")
out.append(f"\t\t\t\t{products_group} /* Products */,")
out.append("\t\t\t);")
out.append("\t\t\tsourceTree = \"<group>\";")
out.append("\t\t};")

out.append(f"\t\t{products_group} /* Products */ = {{")
out.append("\t\t\tisa = PBXGroup;")
out.append("\t\t\tchildren = (")
out.append(f"\t\t\t\t{framework_core_ref} /* HeadroomCore.framework */,")
out.append(f"\t\t\t\t{app_mac_ref} /* HeadroomMac.app */,")
out.append(f"\t\t\t\t{app_ios_ref} /* HeadroomIOS.app */,")
out.append("\t\t\t);")
out.append("\t\t\tname = Products;")
out.append("\t\t\tsourceTree = \"<group>\";")
out.append("\t\t};")

out.append(f"\t\t{core_group} /* HeadroomCore */ = {{")
out.append("\t\t\tisa = PBXGroup;")
out.append("\t\t\tchildren = (")
for _, path in core_files:
    fid_val, fname = file_refs[path]
    out.append(f"\t\t\t\t{fid_val} /* {fname} */,")
out.append("\t\t\t);")
out.append("\t\t\tname = HeadroomCore;")
out.append("\t\t\tsourceTree = \"<group>\";")
out.append("\t\t};")

out.append(f"\t\t{mac_group} /* HeadroomMac */ = {{")
out.append("\t\t\tisa = PBXGroup;")
out.append("\t\t\tchildren = (")
for _, path in mac_files:
    fid_val, fname = file_refs[path]
    out.append(f"\t\t\t\t{fid_val} /* {fname} */,")
out.append(f"\t\t\t\t{icon_mac_id} /* Headroom.icns */,")
out.append(f"\t\t\t\t{info_plist_mac_id} /* Info.plist */,")
out.append(f"\t\t\t\t{entitlements_mac_id} /* HeadroomMac.entitlements */,")
out.append("\t\t\t);")
out.append("\t\t\tname = HeadroomMac;")
out.append("\t\t\tsourceTree = \"<group>\";")
out.append("\t\t};")

out.append(f"\t\t{ios_group} /* HeadroomIOS */ = {{")
out.append("\t\t\tisa = PBXGroup;")
out.append("\t\t\tchildren = (")
for _, path in ios_files:
    fid_val, fname = file_refs[path]
    out.append(f"\t\t\t\t{fid_val} /* {fname} */,")
out.append(f"\t\t\t\t{info_plist_ios_id} /* Info.plist */,")
out.append(f"\t\t\t\t{entitlements_ios_id} /* HeadroomIOSEntitlements.entitlements */,")
out.append("\t\t\t);")
out.append("\t\t\tname = HeadroomIOS;")
out.append("\t\t\tsourceTree = \"<group>\";")
out.append("\t\t};")
out.append("/* End PBXGroup section */")

# PBXNativeTarget
out.append("\n/* Begin PBXNativeTarget section */")
# Core Target
out.append(f"\t\t{target_core} /* HeadroomCore */ = {{")
out.append("\t\t\tisa = PBXNativeTarget;")
out.append(f"\t\t\tbuildConfigurationList = {cfg_list_core} /* Build configuration list for PBXNativeTarget \"HeadroomCore\" */;")
out.append("\t\t\tbuildPhases = (")
out.append(f"\t\t\t\t{sources_core} /* Sources */,")
out.append(f"\t\t\t\t{frameworks_core} /* Frameworks */,")
out.append("\t\t\t);")
out.append("\t\t\tbuildRules = ();")
out.append("\t\t\tdependencies = ();")
out.append("\t\t\tname = HeadroomCore;")
out.append("\t\t\tproductName = HeadroomCore;")
out.append(f"\t\t\tproductReference = {framework_core_ref} /* HeadroomCore.framework */;")
out.append("\t\t\tproductType = \"com.apple.product-type.framework\";")
out.append("\t\t};")

# Mac Target
out.append(f"\t\t{target_mac} /* HeadroomMac */ = {{")
out.append("\t\t\tisa = PBXNativeTarget;")
out.append(f"\t\t\tbuildConfigurationList = {cfg_list_mac} /* Build configuration list for PBXNativeTarget \"HeadroomMac\" */;")
out.append("\t\t\tbuildPhases = (")
out.append(f"\t\t\t\t{sources_mac} /* Sources */,")
out.append(f"\t\t\t\t{frameworks_mac} /* Frameworks */,")
out.append(f"\t\t\t\t{resources_mac} /* Resources */,")
out.append(f"\t\t\t\t{embed_mac} /* Embed Frameworks */,")
out.append("\t\t\t);")
out.append("\t\t\tbuildRules = ();")
out.append("\t\t\tdependencies = (")
out.append(f"\t\t\t\t{dep_mac_core} /* PBXTargetDependency */,")
out.append("\t\t\t);")
out.append("\t\t\tname = HeadroomMac;")
out.append("\t\t\tproductName = HeadroomMac;")
out.append(f"\t\t\tproductReference = {app_mac_ref} /* HeadroomMac.app */;")
out.append("\t\t\tproductType = \"com.apple.product-type.application\";")
out.append("\t\t};")

# iOS Target
out.append(f"\t\t{target_ios} /* HeadroomIOS */ = {{")
out.append("\t\t\tisa = PBXNativeTarget;")
out.append(f"\t\t\tbuildConfigurationList = {cfg_list_ios} /* Build configuration list for PBXNativeTarget \"HeadroomIOS\" */;")
out.append("\t\t\tbuildPhases = (")
out.append(f"\t\t\t\t{sources_ios} /* Sources */,")
out.append(f"\t\t\t\t{frameworks_ios} /* Frameworks */,")
out.append(f"\t\t\t\t{embed_ios} /* Embed Frameworks */,")
out.append("\t\t\t);")
out.append("\t\t\tbuildRules = ();")
out.append("\t\t\tdependencies = (")
out.append(f"\t\t\t\t{dep_ios_core} /* PBXTargetDependency */,")
out.append("\t\t\t);")
out.append("\t\t\tname = HeadroomIOS;")
out.append("\t\t\tproductName = HeadroomIOS;")
out.append(f"\t\t\tproductReference = {app_ios_ref} /* HeadroomIOS.app */;")
out.append("\t\t\tproductType = \"com.apple.product-type.application\";")
out.append("\t\t};")
out.append("/* End PBXNativeTarget section */")

# PBXProject
out.append("\n/* Begin PBXProject section */")
out.append(f"\t\t{project_obj} /* Project object */ = {{")
out.append("\t\t\tisa = PBXProject;")
out.append("\t\t\tattributes = {")
out.append("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
out.append("\t\t\t\tLastUpgradeCheck = 1600;")
out.append("\t\t\t\tTargetAttributes = {")
out.append(f"\t\t\t\t\t{target_core} = {{ CreatedOnToolsVersion = 16.0; ProvisioningStyle = Manual; }};")
out.append(f"\t\t\t\t\t{target_mac} = {{ CreatedOnToolsVersion = 16.0; ProvisioningStyle = Manual; }};")
out.append(f"\t\t\t\t\t{target_ios} = {{ CreatedOnToolsVersion = 16.0; ProvisioningStyle = Manual; }};")
out.append("\t\t\t\t};")
out.append("\t\t\t};")
out.append(f"\t\t\tbuildConfigurationList = {cfg_list_proj} /* Build configuration list for PBXProject \"Headroom\" */;")
out.append("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
out.append("\t\t\tdevelopmentRegion = en;")
out.append("\t\t\thasScannedForEncodings = 0;")
out.append("\t\t\tknownRegions = (en, Base);")
out.append(f"\t\t\tmainGroup = {main_group};")
out.append(f"\t\t\tproductRefGroup = {products_group} /* Products */;")
out.append("\t\t\tprojectDirPath = \"\";")
out.append("\t\t\tprojectRoot = \"\";")
out.append("\t\t\ttargets = (")
out.append(f"\t\t\t\t{target_core} /* HeadroomCore */,")
out.append(f"\t\t\t\t{target_mac} /* HeadroomMac */,")
out.append(f"\t\t\t\t{target_ios} /* HeadroomIOS */,")
out.append("\t\t\t);")
out.append("\t\t};")
out.append("/* End PBXProject section */")

# PBXResourcesBuildPhase
out.append("\n/* Begin PBXResourcesBuildPhase section */")
out.append(f"\t\t{resources_mac} /* Resources */ = {{")
out.append("\t\t\tisa = PBXResourcesBuildPhase;")
out.append("\t\t\tbuildActionMask = 2147483647;")
out.append("\t\t\tfiles = (")
out.append(f"\t\t\t\t{icon_mac_resource} /* Headroom.icns in Resources */,")
out.append("\t\t\t);")
out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
out.append("\t\t};")
out.append("/* End PBXResourcesBuildPhase section */")

# PBXSourcesBuildPhase
out.append("\n/* Begin PBXSourcesBuildPhase section */")
out.append(f"\t\t{sources_core} /* Sources */ = {{")
out.append("\t\t\tisa = PBXSourcesBuildPhase;")
out.append("\t\t\tbuildActionMask = 2147483647;")
out.append("\t\t\tfiles = (")
for bid, _, fname in core_build_files:
    out.append(f"\t\t\t\t{bid} /* {fname} in Sources */,")
out.append("\t\t\t);")
out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
out.append("\t\t};")

out.append(f"\t\t{sources_mac} /* Sources */ = {{")
out.append("\t\t\tisa = PBXSourcesBuildPhase;")
out.append("\t\t\tbuildActionMask = 2147483647;")
out.append("\t\t\tfiles = (")
for bid, _, fname in mac_build_files:
    out.append(f"\t\t\t\t{bid} /* {fname} in Sources */,")
out.append("\t\t\t);")
out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
out.append("\t\t};")

out.append(f"\t\t{sources_ios} /* Sources */ = {{")
out.append("\t\t\tisa = PBXSourcesBuildPhase;")
out.append("\t\t\tbuildActionMask = 2147483647;")
out.append("\t\t\tfiles = (")
for bid, _, fname in ios_build_files:
    out.append(f"\t\t\t\t{bid} /* {fname} in Sources */,")
out.append("\t\t\t);")
out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
out.append("\t\t};")
out.append("/* End PBXSourcesBuildPhase section */")

# PBXTargetDependency
out.append("\n/* Begin PBXTargetDependency section */")
out.append(f"\t\t{dep_mac_core} /* PBXTargetDependency */ = {{")
out.append("\t\t\tisa = PBXTargetDependency;")
out.append(f"\t\t\ttarget = {target_core} /* HeadroomCore */;")
out.append(f"\t\t\ttargetProxy = {proxy_mac_core} /* PBXContainerItemProxy */;")
out.append("\t\t};")
out.append(f"\t\t{dep_ios_core} /* PBXTargetDependency */ = {{")
out.append("\t\t\tisa = PBXTargetDependency;")
out.append(f"\t\t\ttarget = {target_core} /* HeadroomCore */;")
out.append(f"\t\t\ttargetProxy = {proxy_ios_core} /* PBXContainerItemProxy */;")
out.append("\t\t};")
out.append("/* End PBXTargetDependency section */")

# XCBuildConfiguration
out.append("\n/* Begin XCBuildConfiguration section */")
# Project configurations
out.append(f"\t\t{cfg_proj_debug} /* Debug */ = {{")
out.append("\t\t\tisa = XCBuildConfiguration;")
out.append("\t\t\tbuildSettings = {")
out.append("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
out.append("\t\t\t\tCLANG_ENABLE_MODULES = YES;")
out.append("\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;")
out.append("\t\t\t\tCOPY_PHASE_STRIP = NO;")
out.append("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
out.append("\t\t\t\tENABLE_TESTABILITY = YES;")
out.append("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;")
out.append("\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (\"DEBUG=1\", \"$(inherited)\");")
out.append("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = \"DEBUG $(inherited)\";")
out.append("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
out.append("\t\t\t\tSWIFT_VERSION = 5.0;")
out.append("\t\t\t};")
out.append("\t\t\tname = Debug;")
out.append("\t\t};")

out.append(f"\t\t{cfg_proj_release} /* Release */ = {{")
out.append("\t\t\tisa = XCBuildConfiguration;")
out.append("\t\t\tbuildSettings = {")
out.append("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
out.append("\t\t\t\tCLANG_ENABLE_MODULES = YES;")
out.append("\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;")
out.append("\t\t\t\tCOPY_PHASE_STRIP = NO;")
out.append("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";")
out.append("\t\t\t\tENABLE_NS_ASSERTIONS = NO;")
out.append("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
out.append("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-O\";")
out.append("\t\t\t\tSWIFT_VERSION = 5.0;")
out.append("\t\t\t};")
out.append("\t\t\tname = Release;")
out.append("\t\t};")

# Core configurations
for cid, cname in [(cfg_core_debug, "Debug"), (cfg_core_release, "Release")]:
    out.append(f"\t\t{cid} /* {cname} */ = {{")
    out.append("\t\t\tisa = XCBuildConfiguration;")
    out.append("\t\t\tbuildSettings = {")
    out.append("\t\t\t\tCODE_SIGN_IDENTITY = \"-\";")
    out.append("\t\t\t\tCODE_SIGN_STYLE = Manual;")
    out.append("\t\t\t\tDEFINES_MODULE = YES;")
    out.append("\t\t\t\tDYLIB_COMPATIBILITY_VERSION = 1;")
    out.append("\t\t\t\tDYLIB_CURRENT_VERSION = 1;")
    out.append("\t\t\t\tDYLIB_INSTALL_NAME_BASE = \"@rpath\";")
    out.append("\t\t\t\tGENERATE_INFOPLIST_FILE = YES;")
    out.append("\t\t\t\tINFOPLIST_KEY_CFBundlePackageType = FMWK;")
    out.append("\t\t\t\tINFOPLIST_KEY_NSHumanReadableCopyright = \"\";")
    out.append("\t\t\t\tINSTALL_PATH = \"$(LOCAL_LIBRARY_DIR)/Frameworks\";")
    out.append("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\"$(inherited)\", \"@executable_path/../Frameworks\", \"@loader_path/Frameworks\");")
    out.append("\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;")
    out.append("\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;")
    out.append("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = org.headroom.core;")
    out.append("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
    out.append("\t\t\t\tSKIP_INSTALL = YES;")
    out.append("\t\t\t\tSUPPORTED_PLATFORMS = \"iphoneos iphonesimulator macosx\";")
    out.append("\t\t\t\tSUPPORTS_MACCATALYST = NO;")
    out.append("\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";")
    out.append("\t\t\t};")
    out.append(f"\t\t\tname = {cname};")
    out.append("\t\t};")

# Mac configurations
for cid, cname in [(cfg_mac_debug, "Debug"), (cfg_mac_release, "Release")]:
    out.append(f"\t\t{cid} /* {cname} */ = {{")
    out.append("\t\t\tisa = XCBuildConfiguration;")
    out.append("\t\t\tbuildSettings = {")
    out.append("\t\t\t\tCODE_SIGN_ENTITLEMENTS = HeadroomMac/HeadroomMac.entitlements;")
    out.append("\t\t\t\tCODE_SIGN_IDENTITY = \"-\";")
    out.append("\t\t\t\tCODE_SIGN_STYLE = Manual;")
    out.append("\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;")
    out.append("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;")
    out.append("\t\t\t\tINFOPLIST_FILE = HeadroomMac/Info.plist;")
    out.append("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\"$(inherited)\", \"@executable_path/../Frameworks\");")
    out.append("\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;")
    out.append("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = org.headroom.mac;")
    out.append("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
    out.append("\t\t\t\tSDKROOT = macosx;")
    out.append("\t\t\t\tSUPPORTED_PLATFORMS = macosx;")
    out.append("\t\t\t};")
    out.append(f"\t\t\tname = {cname};")
    out.append("\t\t};")

# iOS configurations
for cid, cname in [(cfg_ios_debug, "Debug"), (cfg_ios_release, "Release")]:
    out.append(f"\t\t{cid} /* {cname} */ = {{")
    out.append("\t\t\tisa = XCBuildConfiguration;")
    out.append("\t\t\tbuildSettings = {")
    out.append("\t\t\t\tCODE_SIGN_ENTITLEMENTS = HeadroomIOS/HeadroomIOSEntitlements.entitlements;")
    out.append("\t\t\t\tCODE_SIGN_IDENTITY = \"-\";")
    out.append("\t\t\t\tCODE_SIGN_STYLE = Manual;")
    out.append("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;")
    out.append("\t\t\t\tINFOPLIST_FILE = HeadroomIOS/Info.plist;")
    out.append("\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;")
    out.append("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\"$(inherited)\", \"@executable_path/Frameworks\");")
    out.append("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = org.headroom.ios;")
    out.append("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
    out.append("\t\t\t\tSDKROOT = iphoneos;")
    out.append("\t\t\t\tSUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\";")
    out.append("\t\t\t\tSUPPORTS_MACCATALYST = NO;")
    out.append("\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";")
    out.append("\t\t\t};")
    out.append(f"\t\t\tname = {cname};")
    out.append("\t\t};")

out.append("/* End XCBuildConfiguration section */")

# XCConfigurationList
out.append("\n/* Begin XCConfigurationList section */")
out.append(f"\t\t{cfg_list_proj} /* Build configuration list for PBXProject \"Headroom\" */ = {{")
out.append("\t\t\tisa = XCConfigurationList;")
out.append(f"\t\t\tbuildConfigurations = ({cfg_proj_debug} /* Debug */, {cfg_proj_release} /* Release */);")
out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
out.append("\t\t\tdefaultConfigurationName = Release;")
out.append("\t\t};")

out.append(f"\t\t{cfg_list_core} /* Build configuration list for PBXNativeTarget \"HeadroomCore\" */ = {{")
out.append("\t\t\tisa = XCConfigurationList;")
out.append(f"\t\t\tbuildConfigurations = ({cfg_core_debug} /* Debug */, {cfg_core_release} /* Release */);")
out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
out.append("\t\t\tdefaultConfigurationName = Release;")
out.append("\t\t};")

out.append(f"\t\t{cfg_list_mac} /* Build configuration list for PBXNativeTarget \"HeadroomMac\" */ = {{")
out.append("\t\t\tisa = XCConfigurationList;")
out.append(f"\t\t\tbuildConfigurations = ({cfg_mac_debug} /* Debug */, {cfg_mac_release} /* Release */);")
out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
out.append("\t\t\tdefaultConfigurationName = Release;")
out.append("\t\t};")

out.append(f"\t\t{cfg_list_ios} /* Build configuration list for PBXNativeTarget \"HeadroomIOS\" */ = {{")
out.append("\t\t\tisa = XCConfigurationList;")
out.append(f"\t\t\tbuildConfigurations = ({cfg_ios_debug} /* Debug */, {cfg_ios_release} /* Release */);")
out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
out.append("\t\t\tdefaultConfigurationName = Release;")
out.append("\t\t};")
out.append("/* End XCConfigurationList section */")

out.append("\t};")
out.append(f"\trootObject = {project_obj} /* Project object */;")
out.append("}")

with open(pbxproj_path, "w") as fp:
    fp.write("\n".join(out) + "\n")

print(f"Generated {pbxproj_path} successfully.")
