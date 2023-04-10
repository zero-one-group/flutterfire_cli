import 'dart:convert';
import 'dart:io';

import 'package:cli_util/cli_logging.dart';
import 'package:path/path.dart' as path;

import '../common/strings.dart';
import '../common/utils.dart';
import '../firebase/firebase_options.dart';

import '../flutter_app.dart';

// Use for both macOS & iOS
class FirebaseAppleSetup {
  FirebaseAppleSetup(
    this.platformOptions,
    this.flutterApp,
    this.fullPathToServiceFile,
    this.googleServicePathSpecified,
    this.logger,
    this.generateDebugSymbolScript,
    this.buildConfiguration,
    this.target,
    this.platform,
  );
  // Either "iOS" or "macOS"
  final String platform;
  final FlutterApp? flutterApp;
  final FirebaseOptions platformOptions;
  String? fullPathToServiceFile;
  bool googleServicePathSpecified;
  final Logger logger;
  final bool? generateDebugSymbolScript;
  // This allows us to update to the required "GoogleService-Info.plist" file name for iOS target or build configuration writes.
  String? updatedServiceFilePath;
  String? buildConfiguration;
  String? target;

  String get xcodeProjFilePath {
    return path.join(
      Directory.current.path,
      platform.toLowerCase(),
      'Runner.xcodeproj',
    );
  }

  Future<void> _addFlutterFireDebugSymbolsScript(
    Logger logger,
    ProjectConfiguration projectConfiguration, {
    String target = 'Runner',
  }) async {
    final paths = _addPathToExecutablesForBuildPhaseScripts();
    if (paths != null) {
      final debugSymbolScript = await Process.run('ruby', [
        '-e',
        _debugSymbolsScript(
          target,
          paths,
          projectConfiguration,
        ),
      ]);

      if (debugSymbolScript.exitCode != 0) {
        throw Exception(debugSymbolScript.stderr);
      }

      if (debugSymbolScript.stdout != null) {
        logger.stdout(debugSymbolScript.stdout as String);
      }
    } else {
      logger.stdout(
        noPathsToExecutables,
      );
    }
  }

  String _debugSymbolsScript(
    // Always "Runner" for "build configuration" setup
    String target,
    String pathsToExecutables,
    ProjectConfiguration projectConfiguration,
  ) {
    var command =
        'flutterfire upload-crashlytics-symbols --upload-symbols-script-path=\$PODS_ROOT/FirebaseCrashlytics/upload-symbols --debug-symbols-path=\${DWARF_DSYM_FOLDER_PATH}/\${DWARF_DSYM_FILE_NAME} --info-plist-path=\${SRCROOT}/\${BUILT_PRODUCTS_DIR}/\${INFOPLIST_PATH} --platform=${platform.toLowerCase()} --apple-project-path=\${SRCROOT} ';

    switch (projectConfiguration) {
      case ProjectConfiguration.buildConfiguration:
        command += r'--build-configuration=${CONFIGURATION}';
        break;
      case ProjectConfiguration.target:
        command += '--target=$target';
        break;
      case ProjectConfiguration.defaultConfig:
        command += '--default-config=default';
    }

    return '''
require 'xcodeproj'
xcodeFile='$xcodeProjFilePath'
runScriptName='$debugSymbolScriptName'
project = Xcodeproj::Project.open(xcodeFile)


# multi line argument for bash script
bashScript = %q(
#!/bin/bash
PATH=\${PATH}:$pathsToExecutables
$command
)

for target in project.targets 
  if (target.name == '$target')
    phase = target.shell_script_build_phases().find do |item|
      if defined? item && item.name
        item.name == runScriptName
      end
    end

    if (!phase.nil?)
      phase.remove_from_project()
    end
    
    phase = target.new_shell_script_build_phase(runScriptName)
    phase.shell_script = bashScript
    project.save()   
  end  
end
''';
  }

  String _bundleServiceFileScript(String pathsToExecutables) {
    final command =
        'flutterfire bundle-service-file --plist-destination=\${BUILT_PRODUCTS_DIR}/\${PRODUCT_NAME}.app --build-configuration=\${CONFIGURATION} --platform=${platform.toLowerCase()} --apple-project-path=\${SRCROOT}';

    return '''
require 'xcodeproj'
xcodeFile='$xcodeProjFilePath'
runScriptName='$bundleServiceScriptName'
project = Xcodeproj::Project.open(xcodeFile)


# multi line argument for bash script
bashScript = %q(
#!/bin/bash
PATH=\${PATH}:$pathsToExecutables
$command
)

for target in project.targets 
  if (target.name == 'Runner')
    phase = target.shell_script_build_phases().find do |item|
      if defined? item && item.name
        item.name == runScriptName
      end
    end

    if (!phase.nil?)
      phase.remove_from_project()
    end
    
    phase = target.new_shell_script_build_phase(runScriptName)
    phase.shell_script = bashScript
    project.save()   
  end  
end
    ''';
  }

  final debugSymbolScriptName =
      'FlutterFire: "flutterfire upload-crashlytics-symbols"';
  final bundleServiceScriptName =
      'FlutterFire: "flutterfire bundle-service-file"';

  Future<void> _updateFirebaseJsonFile(
    FlutterApp flutterApp,
    String appId,
    String projectId,
    bool debugSymbolScript,
    String targetOrBuildConfiguration,
    String pathToServiceFile,
    ProjectConfiguration projectConfiguration,
  ) async {
    final file = File(path.join(flutterApp.package.path, 'firebase.json'));

    final relativePathFromProject =
        path.relative(pathToServiceFile, from: flutterApp.package.path);

    // "buildConfiguration", "targets" or "default" property
    final configuration = getProjectConfigurationProperty(projectConfiguration);

    final fileAsString = await file.readAsString();

    final map = jsonDecode(fileAsString) as Map;

    final flutterConfig = map[kFlutter] as Map;
    final applePlatform = flutterConfig[kPlatforms] as Map;
    final appleConfig =
        applePlatform[platform.toLowerCase() == 'ios' ? kIos : kMacos] as Map;

    final configurationMaps = appleConfig[configuration] as Map?;

    Map? configurationMap;
    // For "build configuration" or "target" we need to create a nested map if it does not exist
    if (ProjectConfiguration.target == projectConfiguration ||
        ProjectConfiguration.buildConfiguration == projectConfiguration) {
      if (configurationMaps?[targetOrBuildConfiguration] == null) {
        // ignore: implicit_dynamic_map_literal
        configurationMaps?[targetOrBuildConfiguration] = {};
      }
      configurationMap = configurationMaps?[targetOrBuildConfiguration] as Map;
    } else {
      // Only a single map in "default" configuration.
      configurationMap = configurationMaps;
    }

    configurationMap?[kProjectId] = projectId;
    configurationMap?[kAppId] = appId;
    configurationMap?[kUploadDebugSymbols] = debugSymbolScript;
    configurationMap?[kServiceFileOutput] = relativePathFromProject;

    final mapJson = json.encode(map);

    file.writeAsStringSync(mapJson);
  }

  bool _shouldRunUploadDebugSymbolScript(
    bool? generateDebugSymbolScript,
    Logger logger,
  ) {
    if (generateDebugSymbolScript != null) {
      return generateDebugSymbolScript;
    } else {
      // Unspecified, so we prompt
      final addSymbolScript = promptBool(
        "Do you want an '$debugSymbolScriptName' adding to the build phases of your $platform project?",
      );

      if (addSymbolScript == false) {
        logger.stdout(
          logSkippingDebugSymbolScript,
        );
      }
      return addSymbolScript;
    }
  }

  Future<void> _updateFirebaseJsonAndDebugSymbolScript(
    String pathToServiceFile,
    ProjectConfiguration projectConfiguration,
    String targetOrBuildConfiguration,
  ) async {
    final runDebugSymbolScript = _shouldRunUploadDebugSymbolScript(
      generateDebugSymbolScript,
      logger,
    );

    if (runDebugSymbolScript) {
      await _addFlutterFireDebugSymbolsScript(
        logger,
        projectConfiguration,
      );
    }

    await _updateFirebaseJsonFile(
      flutterApp!,
      platformOptions.appId,
      platformOptions.projectId,
      runDebugSymbolScript,
      targetOrBuildConfiguration,
      pathToServiceFile,
      projectConfiguration,
    );
  }

  String? _addPathToExecutablesForBuildPhaseScripts() {
    final envVars = Platform.environment;
    final paths = envVars['PATH'];
    if (paths != null) {
      final array = paths.split(':');
      // Need to add paths to PATH variable in Xcode environment to execute FlutterFire & Dart executables.
      // The resulting output will be paths specific to your machine. Here is how it might look in the Build Phase script in Xcode:
      // e.g. PATH=${PATH}:/Users/yourname/sdks/flutter/bin/cache/dart-sdk/bin:/Users/yourname/sdks/flutter/bin:/Users/yourname/.pub-cache/bin
      // This script is replaced every time you call `flutterfire configure` so the path variable is always specific to the machine
      // This does work on the presumption that you have the Dart & FlutterFire CLI (in .pub-cache/ directory) on your path on your machine setup
      final pathsToAddToScript = array.where((path) {
        if (path.contains('dart-sdk') ||
            path.contains('flutter') ||
            path.contains('.pub-cache')) {
          return true;
        }
        return false;
      });

      return pathsToAddToScript.join(':');
    } else {
      logger.stdout(
        noPathVariableFound,
      );
      return null;
    }
  }

  Future<List<String>> _findTargetsAvailable() async {
    final targetScript = _findingTargetsScript();

    final result = await Process.run('ruby', [
      '-e',
      targetScript,
    ]);

    if (result.exitCode != 0) {
      throw Exception(result.stderr);
    }
    // Retrieve the targets to prompt the user to select one
    final targets = (result.stdout as String).split(',');

    return targets;
  }

  String _findingTargetsScript() {
    return '''
require 'xcodeproj'
xcodeProject='$xcodeProjFilePath'
project = Xcodeproj::Project.open(xcodeProject)

response = Array.new

project.targets.each do |target|
  response << target.name
end

if response.length == 0
  abort("There are no targets in your Xcode workspace. Please create a target and try again.")
end

\$stdout.write response.join(',')
''';
  }

  Future<List<String>> _findBuildConfigurationsAvailable() async {
    final buildConfigurationScript = _findingBuildConfigurationsScript();

    final result = await Process.run('ruby', [
      '-e',
      buildConfigurationScript,
    ]);

    if (result.exitCode != 0) {
      throw Exception(result.stderr);
    }
    // Retrieve the build configurations to prompt the user to select one
    final buildConfigurations = (result.stdout as String).split(',');

    return buildConfigurations;
  }

  String _findingBuildConfigurationsScript() {
    return '''
require 'xcodeproj'
xcodeProject='$xcodeProjFilePath'

project = Xcodeproj::Project.open(xcodeProject)

response = Array.new

project.build_configurations.each do |configuration|
  response << configuration
end

if response.length == 0
  abort("There are no build configurations in your Xcode workspace. Please create a build configuration and try again.")
end

\$stdout.write response.join(',')
''';
  }

  String _addServiceFileToTarget(
    String googleServiceInfoFile,
    String targetName,
  ) {
    return '''
require 'xcodeproj'
googleFile='$googleServiceInfoFile'
xcodeFile='$xcodeProjFilePath'
targetName='$targetName'

project = Xcodeproj::Project.open(xcodeFile)

file = project.new_file(googleFile)
target = project.targets.find { |target| target.name == targetName }

if(target)
  exists = target.resources_build_phase.files.find do |file|
    if defined? file && file.file_ref && file.file_ref.path
      if file.file_ref.path.is_a? String
        file.file_ref.path.include? 'GoogleService-Info.plist'
      end
    end
  end  
  if !exists
    target.add_resources([file])
    project.save
  end
else
  abort("Could not find target: \$targetName in your Xcode workspace. Please create a target named \$targetName and try again.")
end  
''';
  }

  Future<void> _writeGoogleServiceFileToTargetProject(
    String serviceFilePath,
    String target,
  ) async {
    final addServiceFileToTargetScript = _addServiceFileToTarget(
      serviceFilePath,
      target,
    );

    final resultServiceFileToTarget = await Process.run('ruby', [
      '-e',
      addServiceFileToTargetScript,
    ]);

    if (resultServiceFileToTarget.exitCode != 0) {
      throw Exception(resultServiceFileToTarget.stderr);
    }
  }

  Future<File> _createServiceFileToSpecifiedPath(
    String pathToServiceFile,
  ) async {
    await Directory(path.dirname(pathToServiceFile)).create(recursive: true);

    return File(pathToServiceFile);
  }

  Future<void> _writeGoogleServiceFileToPath(String pathToServiceFile) async {
    final file = await _createServiceFileToSpecifiedPath(pathToServiceFile);

    if (!file.existsSync()) {
      await file.writeAsString(platformOptions.optionsSourceContent);
    } else {
      logger.stdout(serviceFileAlreadyExists);
    }
  }

  String _promptForPathToServiceFile() {
    final pathToServiceFile = promptInput(
      'Enter a path for your $platform "GoogleService-Info.plist" ("${platform.toLowerCase()}-out" argument.) file in your Flutter project. It is required if you set "${platform.toLowerCase()}-build-config" argument. Example input: ${platform.toLowerCase()}/dev',
      validator: (String x) {
        if (RegExp(r'^(?![#\/.])(?!.*[#\/.]$).*').hasMatch(x) &&
            !path.basename(x).contains('.')) {
          return true;
        } else {
          return 'Do not start or end path with a forward slash, nor specify the filename. Example: ${platform.toLowerCase()}/dev';
        }
      },
    );
    return path.join(
      flutterApp!.package.path,
      pathToServiceFile,
      platformOptions.optionsSourceFileName,
    );
  }

  Future<void> _createBuildConfigurationSetup(String pathToServiceFile) async {
    final buildConfigurations = await _findBuildConfigurationsAvailable();

    final buildConfigurationExists =
        buildConfigurations.contains(buildConfiguration);

    if (buildConfigurationExists) {
      await _buildConfigurationWrites(pathToServiceFile);
    } else {
      throw MissingFromXcodeProjectException(
        platform,
        'build configuration',
        buildConfiguration!,
        buildConfigurations,
      );
    }
  }

  Future<void> _createTargetSetup(String pathToServiceFile) async {
    final targets = await _findTargetsAvailable();

    final targetExists = targets.contains(target);

    if (targetExists) {
      await _targetWrites(pathToServiceFile);
    } else {
      throw MissingFromXcodeProjectException(
        platform,
        'target',
        target!,
        targets,
      );
    }
  }

  Future<void> _writeBundleServiceFileScriptToProject(
    String serviceFilePath,
    String buildConfiguration,
    Logger logger,
  ) async {
    final paths = _addPathToExecutablesForBuildPhaseScripts();
    if (paths != null) {
      final addBuildPhaseScript = _bundleServiceFileScript(paths);

      // Add "bundle-service-file" script to Build Phases in Xcode project
      final resultBuildPhase = await Process.run('ruby', [
        '-e',
        addBuildPhaseScript,
      ]);

      if (resultBuildPhase.exitCode != 0) {
        throw Exception(resultBuildPhase.stderr);
      }

      if (resultBuildPhase.stdout != null) {
        logger.stdout(resultBuildPhase.stdout as String);
      }
    } else {
      logger.stdout(
        noPathsToExecutables,
      );
    }
  }

  Future<void> _buildConfigurationWrites(String pathToServiceFile) async {
    await _writeGoogleServiceFileToPath(pathToServiceFile);
    await _writeBundleServiceFileScriptToProject(
      fullPathToServiceFile!,
      buildConfiguration!,
      logger,
    );
    await _updateFirebaseJsonAndDebugSymbolScript(
      pathToServiceFile,
      ProjectConfiguration.buildConfiguration,
      buildConfiguration!,
    );
  }

  Future<void> _targetWrites(
    String pathToServiceFile, {
    ProjectConfiguration projectConfiguration = ProjectConfiguration.target,
  }) async {
    await _writeGoogleServiceFileToPath(pathToServiceFile);
    await _writeGoogleServiceFileToTargetProject(
      pathToServiceFile,
      target!,
    );

    await _updateFirebaseJsonAndDebugSymbolScript(
      pathToServiceFile,
      projectConfiguration,
      target!,
    );
  }

  Future<void> apply() async {
    if (!Platform.isMacOS) return;

    if (!googleServicePathSpecified && target != null) {
      fullPathToServiceFile = _promptForPathToServiceFile();
      await _createTargetSetup(fullPathToServiceFile!);
    } else if (!googleServicePathSpecified && buildConfiguration != null) {
      fullPathToServiceFile = _promptForPathToServiceFile();
      await _createBuildConfigurationSetup(fullPathToServiceFile!);
    } else if (googleServicePathSpecified) {
      final googleServiceFileName = path.basename(fullPathToServiceFile!);

      if (googleServiceFileName != platformOptions.optionsSourceFileName) {
        final response = promptBool(
          'The file name must be "${platformOptions.optionsSourceFileName}" if you\'re bundling with your $platform target or build configuration. Do you want to change filename to "${platformOptions.optionsSourceFileName}"?',
        );

        // Change filename to "GoogleService-Info.plist" if user wants to, it is required for target or build configuration setup
        if (response == true) {
          fullPathToServiceFile = path.join(
            path.dirname(fullPathToServiceFile!),
            platformOptions.optionsSourceFileName,
          );
        }
      }
        
      // Write the service file to the desired location. No other configuration
      await _writeGoogleServiceFileToPath(fullPathToServiceFile!);
        
    } else {
      // Default setup. Continue to write file to Runner/GoogleService-Info.plist if no "fullPathToServiceFile", "build configuration" and "target" is provided
      // Update "Runner", default target
      target = 'Runner';
      final defaultProjectPath = path.join(
        Directory.current.path,
        platform.toLowerCase(),
        target,
        platformOptions.optionsSourceFileName,
      );

      // Make target default "Runner"
      await _targetWrites(
        defaultProjectPath,
        projectConfiguration: ProjectConfiguration.defaultConfig,
      );
    }
  }
}
