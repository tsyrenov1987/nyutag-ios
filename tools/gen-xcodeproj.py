#!/usr/bin/env python3
"""Свой генератор Xcode-проекта Нютага. Только стандартная библиотека Python 3.

Запуск из корня репозитория:  python3 tools/gen-xcodeproj.py
Пишет Nyutag.xcodeproj/project.pbxproj, схему Nyutag.xcscheme, Info.plist, entitlements
и каталог Assets.xcassets. Идентификаторы выводятся из хэша имени, поэтому повторный
запуск даёт тот же файл.
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEAM = "643UT34CF8"
APP_ID = "chat.nyutag.messenger"
NSE_ID = APP_ID + ".nse"
WIDGET_ID = APP_ID + ".widget"
GROUP = "group.chat.nyutag.messenger"
BGTASK = APP_ID + ".background.refresh"
IOS = "26.0"


def uid(name):
    return hashlib.md5(("nyutag:" + name).encode()).hexdigest().upper()[:24]


def q(s):
    s = str(s)
    if s and all((c.isascii() and c.isalnum()) or c in "._/" for c in s):
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write(rel, text):
    path = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


# ---------- plist и entitlements ----------

def plist(body):
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0">\n<dict>\n' + body + '</dict>\n</plist>\n')


def arr(key, items, indent="\t"):
    i = indent
    return "%s<key>%s</key>\n%s<array>\n%s%s</array>\n" % (
        i, key, i, "".join("%s\t<string>%s</string>\n" % (i, x) for x in items), i)


APP_INFO = plist(
    "\t<key>CFBundleURLTypes</key>\n\t<array>\n\t\t<dict>\n"
    "\t\t\t<key>CFBundleTypeRole</key>\n\t\t\t<string>Viewer</string>\n"
    "\t\t\t<key>CFBundleURLName</key>\n\t\t\t<string>" + APP_ID + "</string>\n"
    + arr("CFBundleURLSchemes", ["nyutag"], "\t\t\t")
    + "\t\t</dict>\n\t</array>\n"
    + arr("BGTaskSchedulerPermittedIdentifiers", [BGTASK])
    # Экран запуска: лого на синем (цвет и картинка из Assets.xcassets), без сториборда.
    + "\t<key>UILaunchScreen</key>\n\t<dict>\n\t\t<key>UIColorName</key>\n\t\t<string>LogoBlue</string>\n"
    + "\t\t<key>UIImageName</key>\n\t\t<string>LogoMark</string>\n\t</dict>\n"
    + arr("UIBackgroundModes", ["remote-notification", "fetch", "voip", "audio"])
    + "\t<key>ITSAppUsesNonExemptEncryption</key>\n\t<false/>\n"
    + "\t<key>NSContactsUsageDescription</key>\n\t<string>Нютаг сверяет номера из книжки с сервером, чтобы показать, кто из знакомых уже здесь. Номера не сохраняются.</string>\n"
    + "\t<key>NSCameraUsageDescription</key>\n\t<string>Камера нужна для видеозвонков: картинка уходит собеседнику зашифрованной.</string>\n"
    + "\t<key>NSMicrophoneUsageDescription</key>\n\t<string>Микрофон нужен для звонков: голос уходит собеседнику зашифрованным.</string>\n"
    + "\t<key>NyutagAppGroup</key>\n\t<string>$(NYUTAG_APP_GROUP)</string>\n"
)

NSE_INFO = plist(
    "\t<key>NyutagAppGroup</key>\n\t<string>$(NYUTAG_APP_GROUP)</string>\n"
    "\t<key>NSExtension</key>\n\t<dict>\n"
    "\t\t<key>NSExtensionPointIdentifier</key>\n\t\t<string>com.apple.usernotifications.service</string>\n"
    "\t\t<key>NSExtensionPrincipalClass</key>\n\t\t<string>$(PRODUCT_MODULE_NAME).NotificationService</string>\n"
    "\t</dict>\n"
)

# Виджет «Зурхай»: без группы приложений, данные календаря лежат в его бандле.
WIDGET_INFO = plist(
    "\t<key>NSExtension</key>\n\t<dict>\n"
    "\t\t<key>NSExtensionPointIdentifier</key>\n\t\t<string>com.apple.widgetkit-extension</string>\n"
    "\t</dict>\n"
)


def entitlements(extra):
    return plist(arr("com.apple.security.application-groups", ["$(NYUTAG_APP_GROUP)"]) + extra
                 + arr("keychain-access-groups", ["$(AppIdentifierPrefix)$(NYUTAG_APP_GROUP)"]))


APP_ENT = entitlements("\t<key>aps-environment</key>\n\t<string>development</string>\n")
NSE_ENT = entitlements("")

# ---------- pbxproj ----------
# Объект: (id, комментарий, isa, поля[(ключ, значение-как-есть)], многострочный?)

objs = []


def add(name, comment, isa, fields, multiline=False):
    i = uid(name)
    objs.append((i, comment, isa, fields, multiline))
    return i


def lst(ids):
    return "(" + " ".join(i + "," for i in ids) + ")"


F = {}


def fileref(key, path, kind):
    F[key] = add("fref:" + key, os.path.basename(path), "PBXFileReference",
                 [("lastKnownFileType", kind), ("path", q(path)), ("sourceTree", '"<group>"')])


fileref("app_swift", "NyutagApp.swift", "sourcecode.swift")
fileref("content_swift", "ContentView.swift", "sourcecode.swift")
fileref("accounts_swift", "AppAccounts.swift", "sourcecode.swift")
fileref("selfcheck_swift", "SelfCheck.swift", "sourcecode.swift")
fileref("pushdoor_swift", "PushDoor.swift", "sourcecode.swift")
fileref("ringer_swift", "CallRinger.swift", "sourcecode.swift")
fileref("doors_net", "NetworkWatch.swift", "sourcecode.swift")
fileref("doors_hub", "DoorHub.swift", "sourcecode.swift")
# Экраны: все .swift из App/Nyutag/UI, новый файл попадает в проект повторным запуском генератора.
UI_FILES = sorted(n for n in os.listdir(os.path.join(ROOT, "App", "Nyutag", "UI")) if n.endswith(".swift"))
for name in UI_FILES:
    fileref("ui:" + name, name, "sourcecode.swift")
fileref("assets", "Assets.xcassets", "folder.assetcatalog")
# Иконка в формате Icon Composer (слои юрты и соёмбо на синем); каталог ассетов иконки не держит.
fileref("appicon", "AppIcon.icon", "folder.iconcomposer.icon")
fileref("app_plist", "Info.plist", "text.plist.xml")
# Переводы запросов доступа (контакты, камера, микрофон) на английский: ревьюер и люди с английским телефоном.
# Бурятского языка в iOS нет, его запросы системы показать не могут.
fileref("infoplist_strings", "InfoPlist.xcstrings", "text.json.xcstrings")
fileref("app_ent", "Nyutag.entitlements", "text.plist.entitlements")
# папка-ссылка: если nyutag-catalogue.txt (в gitignore) нет, в бандл попадает только .example.
# Не «Resources»: с такой папкой в корне .app CFBundle считает бандл старым и не находит Info.plist.
fileref("resources", "Catalogue", "folder")
# Календарь: даты Сагаалгана и дни зурхая, общий для вкладки «Календарь» и виджета.
fileref("calendar", "Calendar", "folder")
fileref("nse_swift", "NotificationService.swift", "sourcecode.swift")
fileref("nse_plist", "Info.plist", "text.plist.xml")
fileref("nse_ent", "NyutagNSE.entitlements", "text.plist.entitlements")
fileref("widget_swift", "ZurkhaiWidget.swift", "sourcecode.swift")
fileref("widget_plist", "Info.plist", "text.plist.xml")
APP_PROD = add("prod:app", "Nyutag.app", "PBXFileReference",
               [("explicitFileType", "wrapper.application"), ("includeInIndex", "0"),
                ("path", "Nyutag.app"), ("sourceTree", "BUILT_PRODUCTS_DIR")])
NSE_PROD = add("prod:nse", "NyutagNSE.appex", "PBXFileReference",
               [("explicitFileType", "wrapper.app-extension"), ("includeInIndex", "0"),
                ("path", "NyutagNSE.appex"), ("sourceTree", "BUILT_PRODUCTS_DIR")])
WIDGET_PROD = add("prod:widget", "NyutagWidget.appex", "PBXFileReference",
                  [("explicitFileType", "wrapper.app-extension"), ("includeInIndex", "0"),
                   ("path", "NyutagWidget.appex"), ("sourceTree", "BUILT_PRODUCTS_DIR")])

PKG = uid("pkg")
PROD_APP = uid("pkgprod:app")
PROD_NSE = uid("pkgprod:nse")
PROD_WIDGET = uid("pkgprod:widget")


def bf(key, fileid, comment, phase):
    return add("bf:" + key, "%s in %s" % (comment, phase), "PBXBuildFile", [("fileRef", fileid)])


b_swift_app = bf("app_swift", F["app_swift"], "NyutagApp.swift", "Sources")
b_swift_content = bf("content_swift", F["content_swift"], "ContentView.swift", "Sources")
b_swift_accounts = bf("accounts_swift", F["accounts_swift"], "AppAccounts.swift", "Sources")
b_swift_selfcheck = bf("selfcheck_swift", F["selfcheck_swift"], "SelfCheck.swift", "Sources")
b_swift_pushdoor = bf("pushdoor_swift", F["pushdoor_swift"], "PushDoor.swift", "Sources")
b_swift_ringer = bf("ringer_swift", F["ringer_swift"], "CallRinger.swift", "Sources")
b_doors = [bf("doors_net", F["doors_net"], "NetworkWatch.swift", "Sources"),
           bf("doors_hub", F["doors_hub"], "DoorHub.swift", "Sources")]
b_ui = [bf("ui:" + n, F["ui:" + n], n, "Sources") for n in UI_FILES]
b_assets = bf("assets", F["assets"], "Assets.xcassets", "Resources")
b_appicon = bf("appicon", F["appicon"], "AppIcon.icon", "Resources")
b_res = bf("resources", F["resources"], "Catalogue", "Resources")
b_infoplist_strings = bf("infoplist_strings", F["infoplist_strings"], "InfoPlist.xcstrings", "Resources")
b_cal_app = bf("calendar:app", F["calendar"], "Calendar", "Resources")
b_cal_widget = bf("calendar:widget", F["calendar"], "Calendar", "Resources")
b_swift_widget = bf("widget_swift", F["widget_swift"], "ZurkhaiWidget.swift", "Sources")
b_pkg_widget = add("bf:pkg_widget", "NyutagCore in Frameworks", "PBXBuildFile", [("productRef", PROD_WIDGET)])
b_embed_widget = add("bf:embed_widget", "NyutagWidget.appex in Embed Foundation Extensions", "PBXBuildFile",
                     [("fileRef", WIDGET_PROD), ("settings", "{ATTRIBUTES = (RemoveHeadersOnCopy, ); }")])
b_swift_nse = bf("nse_swift", F["nse_swift"], "NotificationService.swift", "Sources")
b_pkg_app = add("bf:pkg_app", "NyutagCore in Frameworks", "PBXBuildFile", [("productRef", PROD_APP)])
b_pkg_nse = add("bf:pkg_nse", "NyutagCore in Frameworks", "PBXBuildFile", [("productRef", PROD_NSE)])
b_embed = add("bf:embed", "NyutagNSE.appex in Embed Foundation Extensions", "PBXBuildFile",
              [("fileRef", NSE_PROD), ("settings", "{ATTRIBUTES = (RemoveHeadersOnCopy, ); }")])


def phase(name, isa, files, extra=()):
    return add("phase:" + name, name, isa,
               [("buildActionMask", "2147483647")] + list(extra) +
               [("files", lst(files)), ("runOnlyForDeploymentPostprocessing", "0")])


ph_app_src = phase("Sources:app", "PBXSourcesBuildPhase", [b_swift_app, b_swift_content, b_swift_accounts, b_swift_selfcheck, b_swift_pushdoor, b_swift_ringer] + b_doors + b_ui)
ph_app_fw = phase("Frameworks:app", "PBXFrameworksBuildPhase", [b_pkg_app])
ph_app_res = phase("Resources:app", "PBXResourcesBuildPhase", [b_assets, b_appicon, b_res, b_cal_app, b_infoplist_strings])
ph_embed = phase("Embed Foundation Extensions", "PBXCopyFilesBuildPhase", [b_embed, b_embed_widget],
                 [("dstPath", '""'), ("dstSubfolderSpec", "13")])
ph_nse_src = phase("Sources:nse", "PBXSourcesBuildPhase", [b_swift_nse])
ph_nse_fw = phase("Frameworks:nse", "PBXFrameworksBuildPhase", [b_pkg_nse])
ph_nse_res = phase("Resources:nse", "PBXResourcesBuildPhase", [])
ph_widget_src = phase("Sources:widget", "PBXSourcesBuildPhase", [b_swift_widget])
ph_widget_fw = phase("Frameworks:widget", "PBXFrameworksBuildPhase", [b_pkg_widget])
ph_widget_res = phase("Resources:widget", "PBXResourcesBuildPhase", [b_cal_widget])


def group(key, comment, children, path=None, name=None):
    f = [("children", lst(children))]
    if path:
        f.append(("path", q(path)))
    if name:
        f.append(("name", q(name)))
    f.append(("sourceTree", '"<group>"'))
    return add("grp:" + key, comment, "PBXGroup", f)


g_doors = group("doors", "Doors", [F["doors_net"], F["doors_hub"]], "Doors")
g_ui = group("ui", "UI", [F["ui:" + n] for n in UI_FILES], "UI")
g_nyutag = group("nyutag", "Nyutag", [F["app_swift"], F["content_swift"], F["accounts_swift"], F["selfcheck_swift"], F["pushdoor_swift"], F["ringer_swift"], g_doors, g_ui, F["assets"], F["appicon"], F["app_plist"], F["infoplist_strings"], F["app_ent"]], "Nyutag")
g_nse = group("nse", "NyutagNSE", [F["nse_swift"], F["nse_plist"], F["nse_ent"]], "NyutagNSE")
g_widget = group("widget", "NyutagWidget", [F["widget_swift"], F["widget_plist"]], "NyutagWidget")
g_apps = group("apps", "App", [g_nyutag, g_nse, g_widget, F["resources"], F["calendar"]], "App")
g_products = group("products", "Products", [APP_PROD, NSE_PROD, WIDGET_PROD], None, "Products")
g_main = group("main", "Main", [g_apps, g_products])

PROJ_COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
    "CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "1", "DEVELOPMENT_TEAM": TEAM,
    "ENABLE_STRICT_OBJC_MSGSEND": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": IOS, "MARKETING_VERSION": "2.0", "SDKROOT": "iphoneos",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_VERSION": "6.0", "TARGETED_DEVICE_FAMILY": "1",
}
PROJ_DEBUG = dict(PROJ_COMMON, DEBUG_INFORMATION_FORMAT="dwarf", ENABLE_TESTABILITY="YES", GCC_OPTIMIZATION_LEVEL="0",
                  ONLY_ACTIVE_ARCH="YES", SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG", SWIFT_OPTIMIZATION_LEVEL="-Onone")
PROJ_RELEASE = dict(PROJ_COMMON, DEBUG_INFORMATION_FORMAT="dwarf-with-dsym", SWIFT_COMPILATION_MODE="wholemodule",
                    SWIFT_OPTIMIZATION_LEVEL="-O", VALIDATE_PRODUCT="YES")

APP_S = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_ENTITLEMENTS": "App/Nyutag/Nyutag.entitlements", "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "YES", "INFOPLIST_FILE": "App/Nyutag/Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "Нютаг", "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
    "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES", "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone":
        "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
    "PRODUCT_BUNDLE_IDENTIFIER": APP_ID, "PRODUCT_NAME": "Nyutag", "SWIFT_EMIT_LOC_STRINGS": "YES",
}
NSE_S = {
    "APPLICATION_EXTENSION_API_ONLY": "YES", "CODE_SIGN_ENTITLEMENTS": "App/NyutagNSE/NyutagNSE.entitlements",
    "GENERATE_INFOPLIST_FILE": "YES", "INFOPLIST_FILE": "App/NyutagNSE/Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "Нютаг",
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
    "PRODUCT_BUNDLE_IDENTIFIER": NSE_ID, "PRODUCT_NAME": "NyutagNSE", "SKIP_INSTALL": "YES",
}
WIDGET_S = {
    "APPLICATION_EXTENSION_API_ONLY": "YES", "GENERATE_INFOPLIST_FILE": "YES", "INFOPLIST_FILE": "App/NyutagWidget/Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "Нютаг",
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
    "PRODUCT_BUNDLE_IDENTIFIER": WIDGET_ID, "PRODUCT_NAME": "NyutagWidget", "SKIP_INSTALL": "YES",
}


def cfg(key, name, s):
    bs = "{\n" + "".join("\t\t\t\t%s = %s;\n" % (q(k), q(v)) for k, v in sorted(s.items())) + "\t\t\t}"
    return add("cfg:%s:%s" % (key, name), name, "XCBuildConfiguration",
               [("buildSettings", bs), ("name", name)], True)


def cfglist(key, kind, name, ids):
    return add("cfglist:" + key, 'Build configuration list for %s "%s"' % (kind, name), "XCConfigurationList",
               [("buildConfigurations", lst(ids)), ("defaultConfigurationIsVisible", "0"),
                ("defaultConfigurationName", "Release")])


cl_proj = cfglist("proj", "PBXProject", "Nyutag", [cfg("proj", "Debug", PROJ_DEBUG), cfg("proj", "Release", PROJ_RELEASE)])
# Отладочная сборка — отдельное приложение «Нютаг β» со своей группой: на iPhone она живёт рядом
# с магазинным Нютагом и не трогает его базу и связку ключей.
APP_DEBUG = dict(APP_S, PRODUCT_BUNDLE_IDENTIFIER=APP_ID + ".dev", NYUTAG_APP_GROUP=GROUP + ".dev",
                 INFOPLIST_KEY_CFBundleDisplayName="Нютаг β")
NSE_DEBUG = dict(NSE_S, PRODUCT_BUNDLE_IDENTIFIER=APP_ID + ".dev.nse", NYUTAG_APP_GROUP=GROUP + ".dev")
APP_RELEASE = dict(APP_S, NYUTAG_APP_GROUP=GROUP)
NSE_RELEASE = dict(NSE_S, NYUTAG_APP_GROUP=GROUP)
cl_app = cfglist("app", "PBXNativeTarget", "Nyutag", [cfg("app", "Debug", APP_DEBUG), cfg("app", "Release", APP_RELEASE)])
cl_widget = cfglist("widget", "PBXNativeTarget", "NyutagWidget",
                    [cfg("widget", "Debug", dict(WIDGET_S, PRODUCT_BUNDLE_IDENTIFIER=APP_ID + ".dev.widget")),
                     cfg("widget", "Release", WIDGET_S)])
cl_nse = cfglist("nse", "PBXNativeTarget", "NyutagNSE", [cfg("nse", "Debug", NSE_DEBUG), cfg("nse", "Release", NSE_RELEASE)])

T_APP, T_NSE, T_WIDGET, PROJECT = uid("target:app"), uid("target:nse"), uid("target:widget"), uid("project")
proxy = add("proxy:nse", "PBXContainerItemProxy", "PBXContainerItemProxy",
            [("containerPortal", PROJECT), ("proxyType", "1"), ("remoteGlobalIDString", T_NSE), ("remoteInfo", "NyutagNSE")])
dep = add("dep:nse", "PBXTargetDependency", "PBXTargetDependency", [("target", T_NSE), ("targetProxy", proxy)])
proxy_widget = add("proxy:widget", "PBXContainerItemProxy", "PBXContainerItemProxy",
                   [("containerPortal", PROJECT), ("proxyType", "1"), ("remoteGlobalIDString", T_WIDGET), ("remoteInfo", "NyutagWidget")])
dep_widget = add("dep:widget", "PBXTargetDependency", "PBXTargetDependency", [("target", T_WIDGET), ("targetProxy", proxy_widget)])


def target(tid, name, cl, phases, deps, prod_dep, prod, ptype):
    objs.append((tid, name, "PBXNativeTarget",
                 [("buildConfigurationList", cl), ("buildPhases", lst(phases)), ("buildRules", "()"),
                  ("dependencies", lst(deps)), ("name", name), ("packageProductDependencies", lst([prod_dep])),
                  ("productName", name), ("productReference", prod), ("productType", q(ptype))], False))


target(T_APP, "Nyutag", cl_app, [ph_app_src, ph_app_fw, ph_app_res, ph_embed], [dep, dep_widget], PROD_APP, APP_PROD,
       "com.apple.product-type.application")
target(T_NSE, "NyutagNSE", cl_nse, [ph_nse_src, ph_nse_fw, ph_nse_res], [], PROD_NSE, NSE_PROD,
       "com.apple.product-type.app-extension")
target(T_WIDGET, "NyutagWidget", cl_widget, [ph_widget_src, ph_widget_fw, ph_widget_res], [], PROD_WIDGET, WIDGET_PROD,
       "com.apple.product-type.app-extension")

objs.append((PKG, 'XCLocalSwiftPackageReference "."', "XCLocalSwiftPackageReference", [("relativePath", ".")], False))
objs.append((PROD_APP, "NyutagCore", "XCSwiftPackageProductDependency", [("package", PKG), ("productName", "NyutagCore")], False))
objs.append((PROD_NSE, "NyutagCore", "XCSwiftPackageProductDependency", [("package", PKG), ("productName", "NyutagCore")], False))
objs.append((PROD_WIDGET, "NyutagCore", "XCSwiftPackageProductDependency", [("package", PKG), ("productName", "NyutagCore")], False))
objs.append((PROJECT, "Project object", "PBXProject", [
    ("attributes", "{BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 2600; LastUpgradeCheck = 2600; "
                   "TargetAttributes = {%s = {CreatedOnToolsVersion = 26.0; }; %s = {CreatedOnToolsVersion = 26.0; }; %s = {CreatedOnToolsVersion = 26.0; }; }; }" % (T_APP, T_NSE, T_WIDGET)),
    ("buildConfigurationList", cl_proj), ("compatibilityVersion", '"Xcode 14.0"'), ("developmentRegion", "ru"),
    ("hasScannedForEncodings", "0"), ("knownRegions", "(ru, en, Base, )"), ("mainGroup", g_main),
    ("packageReferences", lst([PKG])), ("productRefGroup", g_products), ("projectDirPath", '""'), ("projectRoot", '""'),
    ("targets", lst([T_APP, T_NSE, T_WIDGET]))], False))

ISA_ORDER = ["PBXBuildFile", "PBXContainerItemProxy", "PBXCopyFilesBuildPhase", "PBXFileReference",
             "PBXFrameworksBuildPhase", "PBXGroup", "PBXNativeTarget", "PBXProject", "PBXResourcesBuildPhase",
             "PBXSourcesBuildPhase", "PBXTargetDependency", "XCBuildConfiguration", "XCConfigurationList",
             "XCLocalSwiftPackageReference", "XCSwiftPackageProductDependency"]


def render():
    out = ["// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n"]
    for isa in ISA_ORDER:
        group_objs = sorted([o for o in objs if o[2] == isa], key=lambda o: o[0])
        if not group_objs:
            continue
        out.append("\n/* Begin %s section */\n" % isa)
        for i, c, _, fields, ml in group_objs:
            body = "isa = %s; " % isa + "".join("%s = %s; " % (k, v) for k, v in fields)
            if ml:
                body = "\n\t\t\tisa = %s;\n" % isa + "".join("\t\t\t%s = %s;\n" % (k, v) for k, v in fields) + "\t\t"
                out.append("\t\t%s /* %s */ = {%s};\n" % (i, c, body))
            else:
                out.append("\t\t%s /* %s */ = {%s};\n" % (i, c, body))
        out.append("/* End %s section */\n" % isa)
    out.append("\t};\n\trootObject = %s /* Project object */;\n}\n" % PROJECT)
    return "".join(out)


SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "%(app)s" BuildableName = "Nyutag.app" BlueprintName = "Nyutag" ReferencedContainer = "container:Nyutag.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "%(app)s" BuildableName = "Nyutag.app" BlueprintName = "Nyutag" ReferencedContainer = "container:Nyutag.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
""" % {"app": T_APP}

INFO = '  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n'
ASSET_CONTENTS = "{\n" + INFO + "}\n"
ACCENT = '{\n  "colors" : [\n    {\n      "idiom" : "universal"\n    }\n  ],\n' + INFO + "}\n"

if __name__ == "__main__":
    write("Nyutag.xcodeproj/project.pbxproj", render())
    write("Nyutag.xcodeproj/xcshareddata/xcschemes/Nyutag.xcscheme", SCHEME)
    write("App/Nyutag/Info.plist", APP_INFO)
    write("App/Nyutag/Nyutag.entitlements", APP_ENT)
    write("App/NyutagNSE/Info.plist", NSE_INFO)
    write("App/NyutagNSE/NyutagNSE.entitlements", NSE_ENT)
    write("App/NyutagWidget/Info.plist", WIDGET_INFO)
    write("App/Nyutag/Assets.xcassets/Contents.json", ASSET_CONTENTS)
    write("App/Nyutag/Assets.xcassets/AccentColor.colorset/Contents.json", ACCENT)
    print("Готово: Nyutag.xcodeproj")
