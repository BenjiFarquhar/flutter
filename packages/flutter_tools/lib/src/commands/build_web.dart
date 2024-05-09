// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import '../base/common.dart';
import '../base/file_system.dart';
import '../base/utils.dart';
import '../build_info.dart';
import '../features.dart';
import '../globals.dart' as globals;
import '../project.dart';
import '../runner/flutter_command.dart'
    show DevelopmentArtifact, FlutterCommandResult, FlutterOptions;
import '../web/compile.dart';
import '../web/file_generators/flutter_service_worker_js.dart';
import '../web/web_constants.dart';
import '../web_template.dart';
import 'build.dart';

class BuildWebCommand extends BuildSubCommand {
  BuildWebCommand({
    required super.logger,
    required FileSystem fileSystem,
    required bool verboseHelp,
  }) : _fileSystem = fileSystem, super(verboseHelp: verboseHelp) {
    addTreeShakeIconsFlag();
    usesTargetOption();
    usesOutputDir();
    usesPubOption();
    usesBuildNumberOption();
    usesBuildNameOption();
    addBuildModeFlags(verboseHelp: verboseHelp, excludeDebug: true);
    usesDartDefineOption();
    addEnableExperimentation(hide: !verboseHelp);
    addNullSafetyModeOptions(hide: !verboseHelp);
    addNativeNullAssertions();

    //
    // Flutter web-specific options
    //
    argParser.addSeparator('Flutter web options');
    argParser.addOption('base-href',
      help: 'Overrides the href attribute of the <base> tag in web/index.html. '
          'No change is done to web/index.html file if this flag is not provided. '
          'The value has to start and end with a slash "/". '
          'For more information: https://developer.mozilla.org/en-US/docs/Web/HTML/Element/base'
    );
    argParser.addOption(
      'pwa-strategy',
      defaultsTo: ServiceWorkerStrategy.offlineFirst.cliName,
      help: 'The caching strategy to be used by the PWA service worker.',
      allowed: ServiceWorkerStrategy.values.map((ServiceWorkerStrategy e) => e.cliName),
      allowedHelp: CliEnum.allowedHelp(ServiceWorkerStrategy.values),
    );
    usesWebRendererOption();
    usesWebResourcesCdnFlag();

    //
    // Common compilation options among JavaScript and Wasm
    //
    argParser.addOption(
      'optimization-level',
      abbr: 'O',
      help:
          'Sets the optimization level used for Dart compilation to JavaScript/Wasm.',
      defaultsTo: '${WebCompilerConfig.kDefaultOptimizationLevel}',
      allowed: const <String>['0', '1', '2', '3', '4'],
    );

    //
    // JavaScript compilation options
    //
    argParser.addSeparator('JavaScript compilation options');
    argParser.addFlag('csp',
      negatable: false,
      help: 'Disable dynamic generation of code in the generated output. '
            'This is necessary to satisfy CSP restrictions (see http://www.w3.org/TR/CSP/).'
    );
    argParser.addFlag(
      'source-maps',
      help: 'Generate a sourcemap file. These can be used by browsers '
            'to view and debug the original source code of a compiled and minified Dart '
            'application.'
    );
    argParser.addOption('dart2js-optimization',
      help: 'Sets the optimization level used for Dart compilation to JavaScript. '
            'Deprecated: Please use "-O=<level>" / "--optimization-level=<level>".',
       allowed: const <String>['O1', 'O2', 'O3', 'O4'],
     );
    argParser.addFlag('dump-info', negatable: false,
      help: 'Passes "--dump-info" to the Javascript compiler which generates '
          'information about the generated code is a .js.info.json file.'
    );
    argParser.addFlag('no-frequency-based-minification', negatable: false,
      help: 'Disables the frequency based minifier. '
          'Useful for comparing the output between builds.'
    );

    //
    // WebAssembly compilation options
    //
    argParser.addSeparator('WebAssembly compilation options');
    argParser.addFlag(
      FlutterOptions.kWebWasmFlag,
      help: 'Compile to WebAssembly (with fallback to JavaScript).\n$kWasmMoreInfo',
      negatable: false,
    );
    argParser.addFlag(
      'strip-wasm',
      help: 'Whether to strip the resulting wasm file of static symbol names.',
      defaultsTo: true,
    );
  }

  final FileSystem _fileSystem;

  @override
  Future<Set<DevelopmentArtifact>> get requiredArtifacts async =>
      const <DevelopmentArtifact>{
        DevelopmentArtifact.web,
      };

  @override
  final String name = 'web';

  @override
  bool get hidden => !featureFlags.isWebEnabled;

  @override
  final String description = 'Build a web application bundle.';

  @override
  Future<FlutterCommandResult> runCommand() async {
    if (!featureFlags.isWebEnabled) {
      throwToolExit('"build web" is not currently supported. To enable, run "flutter config --enable-web".');
    }

    final int optimizationLevel = int.parse(stringArg('optimization-level')!);

    final String? dart2jsOptimizationLevelValue = stringArg('dart2js-optimization');
    final int jsOptimizationLevel =  dart2jsOptimizationLevelValue != null
        ? int.parse(dart2jsOptimizationLevelValue.substring(1))
        : optimizationLevel;

    final List<WebCompilerConfig> compilerConfigs;
    if (boolArg('wasm')) {
      if (stringArg(FlutterOptions.kWebRendererFlag) != argParser.defaultFor(FlutterOptions.kWebRendererFlag)) {
        throwToolExit('"--${FlutterOptions.kWebRendererFlag}" cannot be combined with "--${FlutterOptions.kWebWasmFlag}"');
      }
      globals.logger.printBox(
        title: 'New feature',
        '''
  WebAssembly compilation is new. Understand the details before deploying to production.
  $kWasmMoreInfo''',
      );

      compilerConfigs = <WebCompilerConfig>[
        WasmCompilerConfig(
          optimizationLevel: optimizationLevel,
          stripWasm: boolArg('strip-wasm'),
          renderer: WebRendererMode.skwasm,
        ),
        JsCompilerConfig(
          csp: boolArg('csp'),
          optimizationLevel: jsOptimizationLevel,
          dumpInfo: boolArg('dump-info'),
          nativeNullAssertions: boolArg('native-null-assertions'),
          noFrequencyBasedMinification: boolArg('no-frequency-based-minification'),
          sourceMaps: boolArg('source-maps'),
          renderer: WebRendererMode.canvaskit,
        )];
    } else {
      WebRendererMode webRenderer = WebRendererMode.auto;
      if (argParser.options.containsKey(FlutterOptions.kWebRendererFlag)) {
        webRenderer = WebRendererMode.values.byName(stringArg(FlutterOptions.kWebRendererFlag)!);
      }
      compilerConfigs = <WebCompilerConfig>[JsCompilerConfig(
        csp: boolArg('csp'),
        optimizationLevel: jsOptimizationLevel,
        dumpInfo: boolArg('dump-info'),
        nativeNullAssertions: boolArg('native-null-assertions'),
        noFrequencyBasedMinification: boolArg('no-frequency-based-minification'),
        sourceMaps: boolArg('source-maps'),
        renderer: webRenderer,
      )];
    }

    final FlutterProject flutterProject = FlutterProject.current();
    final String target = stringArg('target')!;
    final BuildInfo buildInfo = await getBuildInfo();
    if (buildInfo.isDebug) {
      throwToolExit('debug builds cannot be built directly for the web. Try using "flutter run"');
    }
    final String? baseHref = stringArg('base-href');
    if (baseHref != null && !(baseHref.startsWith('/') && baseHref.endsWith('/'))) {
      throwToolExit(
        'Received a --base-href value of "$baseHref"\n'
        '--base-href should start and end with /',
      );
    }
    if (!flutterProject.web.existsSync()) {
      throwToolExit('Missing index.html.');
    }
    if (!_fileSystem.currentDirectory
        .childDirectory('web')
        .childFile('index.html')
        .readAsStringSync()
        .contains(kBaseHrefPlaceholder) &&
        baseHref != null) {
      throwToolExit(
        "Couldn't find the placeholder for base href. "
        'Please add `<base href="$kBaseHrefPlaceholder">` to web/index.html'
      );
    }

    // Currently supporting options [output-dir] and [output] as
    // valid approaches for setting output directory of build artifacts
    final String? outputDirectoryPath = stringArg('output');

    displayNullSafetyMode(buildInfo);
    final WebBuilder webBuilder = WebBuilder(
      logger: globals.logger,
      processManager: globals.processManager,
      buildSystem: globals.buildSystem,
      fileSystem: globals.fs,
      flutterVersion: globals.flutterVersion,
      usage: globals.flutterUsage,
      analytics: globals.analytics,
    );
    await webBuilder.buildWeb(
      flutterProject,
      target,
      buildInfo,
      ServiceWorkerStrategy.fromCliName(stringArg('pwa-strategy')),
      compilerConfigs: compilerConfigs,
      baseHref: baseHref,
      outputDirectoryPath: outputDirectoryPath,
    );
    return FlutterCommandResult.success();
  }
}
