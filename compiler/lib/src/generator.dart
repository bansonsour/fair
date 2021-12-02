/*
 * Copyright (C) 2005-present, 58.com.  All rights reserved.
 * Use of this source code is governed by a BSD type license that can be
 * found in the LICENSE file.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:dart_style/dart_style.dart';
import 'package:fair_annotation/fair_annotation.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as path;
import 'package:source_gen/source_gen.dart';

import 'helper.dart';

class BundleGenerator extends GeneratorForAnnotation<FairPatch>
    with FairCompiler {
  final _elements = <String, Element>{};

  @override
  Future<String> generateForAnnotatedElement(
      Element element, ConstantReader annotation, BuildStep buildStep) async {
    if (element is! ClassElement) {
      throw InvalidGenerationSourceError(
        '`@FairPatch()` can only be used on classes.',
        element: element,
      );
    }
    print('[Fair] Compile ${buildStep.inputId.path} into bundle...');
    final tmp = await temp;
    tmp.writeAsBytesSync(await buildStep.readAsBytes(buildStep.inputId));
    var r = await compile(buildStep, ['-f', tmp.absolute.path]);
    tmp.deleteSync();
    if (r.success) {
      // TODO support multiple annotated widgets in one dart file
      var e = _elements.putIfAbsent(element.source.uri.path, () => element);
      if (e != element) {
        throw InvalidGenerationSourceError(
            'Each .dart file should contain only one @FairPatch Widget.\n'
            'Both ${e.name} and ${element.name} exist inside ${e.source.uri}\n'
            'Please spilt them into separated .dart file',
            element: element);
      }
    } else {
      print('[Fair] Failed to generate bundle for $element');
      print('[Fair] ${r.message}');
    }
    return r.data;
  }
}

class BindingGenerator extends GeneratorForAnnotation<FairBinding> {
  StringBuffer buffer;
  bool generated = false;

  @override
  Future<String> generateForAnnotatedElement(
      Element element, ConstantReader annotation, BuildStep buildStep) async {
    var dir = path.join('.dart_tool', 'build', 'fairc', 'source');
    if (buffer == null) {
      buffer = StringBuffer();
      buffer.writeln('# Generated by Fair on ${DateTime.now()}.');
    }

    var resource =
        annotation.peek('packages')?.listValue?.map((e) => e.toStringValue());
    var list = [];
    if (resource != null && resource.isNotEmpty) {
      await Future.forEach(
          resource
              .where((p) => p.startsWith('package:') && p.endsWith('.dart')),
          (element) async {
        buffer.writeln(element);
        var str = element
            .toString()
            .substring(0, element.toString().indexOf('\/') + 1);
        var assetId = AssetId.resolve(element);
        await _transitSource(buildStep, assetId, dir).then((value) {
          var elements = [];
          value.readAsLinesSync().forEach((element) {
            if (element.startsWith('export')) {
              var package = element.substring(
                  element.indexOf('\'') + 1, element.lastIndexOf('\''));
              elements
                  .add(element.contains('package:') ? package : str + package);
            }
          });
          if (elements != null && elements.isNotEmpty) {
            list.addAll(elements);
          }
        });
      });
      if (list != null && list.isNotEmpty) {
        await Future.forEach(
            list.where((p) => p.startsWith('package:') && p.endsWith('.dart')),
            (element) async {
          buffer.writeln(element);
          var assetId = AssetId.resolve(element);
          await _transitSource(buildStep, assetId, dir);
        });
      }

    }

    var package = File(path.join(dir, 'fair.binding'))
      ..createSync(recursive: true);
    await package.writeAsString(buffer.toString());
    // FairBinding only work with class
    if (element is ClassElement) {
      buffer.writeln('${buildStep.inputId.uri}');
      await _transitSource(buildStep, buildStep.inputId, dir);
    }
    if (!generated) {
      generated = true;
      return '${package.absolute.path}';
    }
    return null;
  }

  Future<File> _transitSource(
      BuildStep buildStep, AssetId assetId, String dir) async {
    var annotatedSource = await File(path.join(dir, assetId.package,
        assetId.changeExtension('.fair.dart').path.replaceAll('/', '_')))
        .create(recursive: true);

    var source = await _replaceRelativeImport(await buildStep.readAsString(assetId), assetId);
    annotatedSource.writeAsStringSync(source);
    return annotatedSource;
  }

  /// replace relative import path to absolute path
  Future<String> _replaceRelativeImport(String sourceStr,AssetId assetId) async{
    var source = StringBuffer();
    var ls = LineSplitter();
    var lines = ls.convert(sourceStr);;
    lines.forEach((line) {
      if (line.startsWith('import') && !line.contains(':')) {
        var asset = line.replaceFirst('import', '').replaceAll('\'', '').replaceAll(';', '').trim();
        try {
          var lAssetId = AssetId.resolve(Uri.parse(asset),from: assetId);
          line = 'import \'package:${assetId.package}${lAssetId.path.replaceFirst('lib', '')}\';';
        } catch (e) {
          print(e);
        }
      }
      source.write('$line\n');
    });

    return source.toString();
  }
}

class PackageBuilder extends Builder with FairCompiler {
  /// covert `package://` into `file:///` path
  // ignore: unused_element
  List<String> _package2path(Iterable<String> packageList) {
    var nameMap = <String, String>{};
    packageList.forEach((e) {
      final end = e.indexOf('/');
      nameMap.putIfAbsent(e.substring(e.indexOf(':') + 1, end),
          () => e.substring(end + 1).trimRight());
    });

    var p = File('.packages');
    if (p.existsSync()) {
      final localPackagePaths = p.readAsLinesSync();
      var packagesMap = <String, String>{};
      localPackagePaths.forEach((e) {
        final end = e.indexOf(':');
        packagesMap.putIfAbsent(
            e.substring(0, end), () => e.substring(end + 1).trimRight());
      });
      return nameMap
          .map((key, value) => MapEntry(key, packagesMap[key] + value))
          .values;
    }
    return [];
  }

  @override
  FutureOr<void> build(BuildStep buildStep) async {
    var assets = await buildStep
        .findAssets(Glob('lib/**.fair.ignore', recursive: true))
        .toList();
    if (assets == null || assets.isEmpty) {
      return;
    }

    var bundlePath = (await buildStep.readAsString(assets.first)).trimRight();

    var annotated = File(bundlePath)
        .readAsLinesSync()
        .toSet()
        .where((l) => !l.startsWith('#'))
        .map((e) => 'import \'$e\';')
        .toSet();

    var dir = path.join('.dart_tool', 'build', 'fairc', 'source');
    var r = await compile(buildStep, ['-k', 'dart', '-d', dir]);
    String generated;
    if (!r.success) {
      throw Exception(
          '[Fair] Failed to generate widget binding from =>\n$dir\n${r.message}');
    }
    Directory(dir).deleteSync(recursive: true);
    var builder = StringBuffer('// Generated by Fair on ${DateTime.now()}.\n');
    annotated.forEach((element) => builder.writeln(element));
    builder.writeln(r.data);
    generated = builder.toString();
    var fair =
        AssetId(buildStep.inputId.package, 'lib/src/generated.fair.dart');
    try {
      var formatSource = DartFormatter().format(generated);
      await buildStep.writeAsString(fair, formatSource);
      print('[Fair] New binding generated. ${fair.uri}');
    } catch (e) {
      print('======== Dart Source ========');
      print(generated);
      print('======== Dart Source ========');
      throw Exception('[Fair] format failed. \n$e');
    }
  }

  @override
  Map<String, List<String>> get buildExtensions => const {
        r'$lib$': ['src/generated.fair.dart']
      };
}
