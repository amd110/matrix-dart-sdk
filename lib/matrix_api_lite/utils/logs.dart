/* MIT License
*
* Copyright (C) 2019, 2020, 2021 Famedly GmbH
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
*/

import 'package:matrix/matrix_api_lite/utils/print_logs_native.dart'
    if (dart.library.js_interop) 'print_logs_web.dart';

enum Level {
  wtf,
  error,
  warning,
  info,
  debug,
  verbose,
}

typedef LogCallback = void Function(LogEvent event);

class Logs {
  static final Logs _singleton = Logs._internal();

  /// Override this function if you want to convert a stacktrace for some reason
  /// for example to apply a source map in the browser.
  static StackTrace? Function(StackTrace?) stackTraceConverter = (s) => s;

  factory Logs() {
    return _singleton;
  }

  Level level = Level.info;
  bool nativeColors = true;

  // 仅保留最近 N 条日志，防止长时间运行后 OOM
  static const int _maxOutputEvents = 500;
  final List<LogEvent> outputEvents = [];

  /// Callback to receive log events for external logging (e.g., Sentry).
  /// Called before console output on all platforms including web.
  LogCallback? onLog;

  Logs._internal();

  void addLogEvent(LogEvent logEvent) {
    // onLog 回调在 level 过滤前执行，确保外部日志系统（如 Crashlytics）收到全部事件
    onLog?.call(logEvent);

    if (logEvent.level.index <= level.index) {
      // 只存储达到当前 level 阈值的事件，避免 debug 日志在生产环境中无限累积
      if (outputEvents.length >= _maxOutputEvents) {
        outputEvents.removeAt(0);
      }
      outputEvents.add(logEvent);
      logEvent.printOut();
    }
  }

  void wtf(String title, [Object? exception, StackTrace? stackTrace]) =>
      addLogEvent(
        LogEvent(
          title,
          exception: exception,
          stackTrace: stackTraceConverter(stackTrace),
          level: Level.wtf,
        ),
      );

  void e(String title, [Object? exception, StackTrace? stackTrace]) =>
      addLogEvent(
        LogEvent(
          title,
          exception: exception,
          stackTrace: stackTraceConverter(stackTrace),
          level: Level.error,
        ),
      );

  void w(String title, [Object? exception, StackTrace? stackTrace]) =>
      addLogEvent(
        LogEvent(
          title,
          exception: exception,
          stackTrace: stackTraceConverter(stackTrace),
          level: Level.warning,
        ),
      );

  void i(String title, [Object? exception, StackTrace? stackTrace]) =>
      addLogEvent(
        LogEvent(
          title,
          exception: exception,
          stackTrace: stackTraceConverter(stackTrace),
          level: Level.info,
        ),
      );

  void d(String title, [Object? exception, StackTrace? stackTrace]) =>
      addLogEvent(
        LogEvent(
          title,
          exception: exception,
          stackTrace: stackTraceConverter(stackTrace),
          level: Level.debug,
        ),
      );

  void v(String title, [Object? exception, StackTrace? stackTrace]) =>
      addLogEvent(
        LogEvent(
          title,
          exception: exception,
          stackTrace: stackTraceConverter(stackTrace),
          level: Level.verbose,
        ),
      );
}

// ignore: avoid_print
class LogEvent {
  final String title;
  final Object? exception;
  final StackTrace? stackTrace;
  final Level level;

  LogEvent(
    this.title, {
    this.exception,
    this.stackTrace,
    this.level = Level.debug,
  });

  /// Returns a formatted string representation of this log event.
  /// Useful for sending to external logging systems.
  String toFormattedString() {
    var logsStr = title;
    if (exception != null) {
      logsStr += ' - $exception';
    }
    if (stackTrace != null) {
      logsStr += '\n$stackTrace';
    }
    return logsStr;
  }

  /// Returns a map representation of this log event.
  /// Useful for structured logging systems.
  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'level': level.name,
      if (exception != null) 'exception': exception.toString(),
      if (stackTrace != null) 'stackTrace': stackTrace.toString(),
    };
  }
}
