import 'dart:async';
import 'dart:convert'; // For utf8 encoding if needed
import 'dart:io' as io; // Use 'io' prefix
import 'dart:typed_data'; // For Uint8List

// Potentially needed for kDebugMode, if not already imported transitively
// import 'package:flutter/foundation.dart'; // Use kDebugMode

// Assume shared stdio helpers are defined in shared/stdio.dart
import 'package:mcp_dart/src/shared/stdio.dart'; // Adjust import path as needed
// Assume Transport interface is defined in shared/transport.dart
import 'package:mcp_dart/src/shared/transport.dart'; // Adjust import path as needed
// Assume types are defined in types.dart
import 'package:mcp_dart/src/types.dart'; // Adjust import path as needed

/// Configuration parameters for launching the stdio server process.
class StdioServerParameters {
  /// The executable command to run to start the server process.
  final String command;

  /// Command line arguments to pass to the executable.
  final List<String> args;

  /// Environment variables to use when spawning the process.
  /// If null, a default restricted environment might be inherited (see [getDefaultEnvironment]).
  final Map<String, String>? environment;

  /// How to handle the stderr stream of the child process.
  /// Defaults to [io.ProcessStdio.inheritStdio], printing to the parent's stderr.
  /// Can be set to [io.ProcessStdio.pipe] to capture stderr via the [stderr] stream getter.
  final io.ProcessStartMode stderrMode;

  /// The working directory to use when spawning the process.
  /// If null, inherits the current working directory.
  final String? workingDirectory;

  /// Creates parameters for launching the stdio server.
  const StdioServerParameters({
    required this.command,
    this.args = const [],
    this.environment, // Consider defaulting using getDefaultEnvironment() if null
    this.stderrMode = io.ProcessStartMode.inheritStdio,
    this.workingDirectory,
  });
}

// Note: DEFAULT_INHERITED_ENV_VARS and getDefaultEnvironment from the TS code
// provide a mechanism to create a restricted default environment.
// This can be complex to replicate perfectly across platforms in Dart.
// For simplicity, this conversion allows passing a custom environment or
// defaulting to inheriting the parent's environment (which is dart:io's default).
// If strict environment control is needed, implement a Dart equivalent of
// getDefaultEnvironment() based on io.Platform.environment.

/// Client transport for stdio: connects to a server by spawning a process
/// and communicating with it over stdin/stdout pipes.
///
/// This transport requires `dart:io` and is suitable for command-line clients
/// or desktop applications that manage a server subprocess.
class StdioClientTransport implements Transport {
  /// Configuration for launching the server process.
  final StdioServerParameters _serverParams;

  /// The running server process, null until [start] is called and completes.
  io.Process? _process;

  /// Used to signal process termination during [close].
  final Completer<void> _exitCompleter = Completer<void>();

  /// Buffer for incoming data from the process's stdout.
  final ReadBuffer _readBuffer = ReadBuffer();

  /// Flag to prevent multiple starts.
  bool _started = false;

  // ADD: Flag to prevent concurrent cleanup
  bool _isCleaningUp = false;

  /// Subscriptions to the process's stdout and stderr streams.
  StreamSubscription<List<int>>? _stdoutSubscription;
  StreamSubscription<List<int>>?
  _stderrSubscription; // Only used if stderrMode is pipe

  /// Callback for when the connection (process) is closed.
  @override
  void Function()? onclose;

  /// Callback for reporting errors (e.g., process spawn failure, stream errors).
  @override
  void Function(Error error)? onerror;

  /// Callback for received messages parsed from the process's stdout.
  @override
  void Function(JsonRpcMessage message)? onmessage;

  /// Session ID is not applicable to stdio transport.
  @override
  String? get sessionId => null;

  /// Creates a stdio client transport.
  ///
  /// Requires [serverParams] detailing how to launch the server process.
  StdioClientTransport(this._serverParams);

  /// Starts the server process and establishes communication pipes.
  ///
  /// Spawns the process defined in [_serverParams] and sets up listeners
  /// on its stdout and stderr streams. Completes when the process has
  /// successfully started. Throws exceptions if the process fails to start.
  /// Throws [StateError] if already started.
  @override
  Future<void> start() async {
    if (_started) {
      throw StateError(
        "StdioClientTransport already started! If using Client class, note that connect() calls start() automatically.",
      );
    }
    _started = true;
    _isCleaningUp = false; // Reset cleanup flag on new start attempt

    final mode = (_serverParams.stderrMode == io.ProcessStartMode.normal)
        ? io.ProcessStartMode.normal // Use normal for pipe access
        : io.ProcessStartMode.inheritStdio; // More direct inheritance

    try {
      // Start the process.
      _process = await io.Process.start(
        _serverParams.command,
        _serverParams.args,
        workingDirectory: _serverParams.workingDirectory,
        environment:
            _serverParams.environment, // Use provided or inherit Dart default
        // Assuming runInShell is false based on previous code
        runInShell: false,
        mode: mode, // Handles stdin/stdout/stderr piping/inheritance
      );

      print("StdioClientTransport: Process started (PID: \${_process?.pid})");

      // --- Setup stream listeners ---

      // Listen to stdout for messages
      _stdoutSubscription = _process!.stdout.listen(
        _onStdoutData,
        onError: _onStreamError,
        onDone: _onStdoutDone,
        cancelOnError: false, // Handle errors explicitly
      );

      // Listen to stderr if piped
      if (_serverParams.stderrMode == io.ProcessStartMode.normal) {
        _stderrSubscription = _process!.stderr.listen(
          (data) {
            // Log stderr, potentially report as non-fatal error?
            final errorMsg = utf8.decode(data, allowMalformed: true);
            print("Server stderr: \$errorMsg");
            // Optionally report stderr content via onerror
            // _reportError(StateError("Server stderr: \$errorMsg"));
          },
          onError: _onStreamError, // Report stderr stream errors too
          onDone: () {
            print("StdioClientTransport: Process stderr closed.");
          },
          cancelOnError: false,
        );
      }

      // Handle process exit without awaiting here
      unawaited(
        _process!.exitCode.then(_onProcessExit).catchError(_onProcessExitError),
      );

      // Start successful
      return Future.value();

    } catch (error, stackTrace) {
      // Handle errors during Process.start()
      print("StdioClientTransport: Failed to start process: \$error");
      _started = false; // Reset state
      final startError = StateError(
        "Failed to start server process: \$error\n\$stackTrace",
      );
      _reportError(startError); // Use helper to report error
      await close(); // Attempt cleanup immediately on start failure
      throw startError; // Rethrow to signal failure
    }
  }

  /// Provides access to the stderr stream of the child process,
  /// but only if [StdioServerParameters.stderrMode] was set to
  /// [io.ProcessStdio.pipe] during construction.
  /// Returns null if stderr is not piped or if the process is not running.
  Stream<List<int>>? get stderr {
    if (_serverParams.stderrMode == io.ProcessStartMode.normal &&
        _process != null) {
      return _process!.stderr;
    }
    return null;
  }

  /// Internal handler for data received from the process's stdout.
  void _onStdoutData(List<int> chunk) {
    if (chunk is! Uint8List) chunk = Uint8List.fromList(chunk);
    _readBuffer.append(chunk);
    _processReadBuffer();
  }

  /// Internal handler for when the process's stdout stream closes.
  void _onStdoutDone() {
    print("StdioClientTransport: Process stdout closed.");
    // If stdout closes unexpectedly (i.e., not during cleanup), trigger cleanup.
    if (!_isCleaningUp) {
      print(
        "StdioClientTransport: Stdout closed unexpectedly, initiating cleanup.",
      );
      _reportError(StateError("Process stdout closed unexpectedly."));
      unawaited(close());
    }
  }

  /// Internal handler for errors on process stdout/stderr streams.
  void _onStreamError(dynamic error, StackTrace stackTrace) {
    // Ignore stream errors if we are already cleaning up, as they are expected
    if (_isCleaningUp) {
      print(
        "StdioClientTransport: Stream error occurred during cleanup: \$error",
      );
      return;
    }
    print("StdioClientTransport: Stream error occurred: \$error");
    final Error streamError = (error is Error)
        ? error
            : StateError("Process stream error: \$error\n\$stackTrace");
    _reportError(streamError);
    // Consider if stream errors should trigger close() - often yes
    unawaited(close());
  }

  /// Internal handler processing buffered stdout data for messages.
  void _processReadBuffer() {
    while (true) {
      try {
        final message = _readBuffer.readMessage();
        if (message == null) break; // No complete message
        try {
          onmessage?.call(message);
        } catch (e) {
          print("Error in onmessage handler: \$e");
          onerror?.call(StateError("Error in onmessage handler: \$e"));
        }
      } catch (error) {
        final Error parseError = (error is Error)
            ? error
                : StateError("Message parsing error: \$error");
        try {
          onerror?.call(parseError);
        } catch (e) {
          print("Error in onerror handler: \$e");
        }
        print(
          "StdioClientTransport: Error processing read buffer: \$parseError. Skipping data.",
        );
        // Consider clearing buffer or attempting recovery depending on error type.
        // Clearing might be safest for unknown parsing errors.
        // _readBuffer.clear();
        break; // Stop processing buffer on error for now
      }
    }
  }

  /// Internal handler for when the process exits.
  void _onProcessExit(int exitCode) {
    print("StdioClientTransport: Process exited with code \$exitCode.");
    // Only trigger cleanup if not already cleaning up
    if (!_isCleaningUp) {
      print(
        "StdioClientTransport: Process exited unexpectedly, initiating cleanup.",
      );
      final exitError = StateError(
        "Process exited unexpectedly with code \$exitCode.",
      );
      _reportError(exitError);
      unawaited(close()); // Initiate cleanup
    } else {
      print("StdioClientTransport: Process exited during cleanup sequence.");
    }
    // Ensure the completer is finished regardless
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete();
    }
  }

  /// Internal handler for errors retrieving the process exit code.
  void _onProcessExitError(dynamic error, StackTrace stackTrace) {
    print("StdioClientTransport: Error waiting for process exit: \$error");
    // Only trigger cleanup if not already cleaning up
    if (!_isCleaningUp) {
      print(
        "StdioClientTransport: Error waiting for exit, initiating cleanup.",
      );
      final Error exitError =
          (error is Error)
              ? error
              : StateError("Process exit error: \$error\n\$stackTrace");
      _reportError(exitError);
      unawaited(close()); // Initiate cleanup
    } else {
      print(
        "StdioClientTransport: Error waiting for process exit during cleanup sequence.",
      );
    }
    // Ensure the completer is finished with an error regardless
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.completeError(error, stackTrace);
    }
  }

  /// Closes the transport connection by terminating the server process
  /// and cleaning up resources.
  ///
  /// Sends a SIGTERM signal (or SIGKILL on timeout/Windows) to the process.
  @override
  Future<void> close() async {
    // Prevent concurrent cleanup
    if (_isCleaningUp) {
      print('StdioClientTransport: Cleanup already in progress, skipping.');
      return _exitCompleter
          .future; // Return existing future if cleanup is running
    }

    // Check if already closed or never started properly
    if (!_started && _process == null) {
      print('StdioClientTransport: Already closed or never started.');
      if (!_exitCompleter.isCompleted) {
        _exitCompleter.complete(); // Ensure completer finishes
      }
      return;
    }

    _isCleaningUp = true; // Set flag immediately
    print("StdioClientTransport: Closing transport...");

    // Mark as not started *after* setting the cleanup flag
    _started = false;

    // Cancel stream subscriptions safely
    await _stdoutSubscription?.cancel().catchError((e) {
      print("StdioClientTransport: Error cancelling stdout subscription: \$e");
    });
    await _stderrSubscription?.cancel().catchError((e) {
      print("StdioClientTransport: Error cancelling stderr subscription: \$e");
    });
    _stdoutSubscription = null;
    _stderrSubscription = null;

    _readBuffer.clear();

    // Terminate the process
    final processToKill = _process;
    _process = null; // Clear reference early

    if (processToKill != null) {
      print(
        "StdioClientTransport: Terminating process (PID: \${processToKill.pid})...",
      );
      try {
        // Close stdin first to signal server if possible
        await processToKill.stdin.close().catchError((e) {
          print("StdioClientTransport: Error closing process stdin: \$e");
        });
      } catch (e) {
        print("StdioClientTransport: Exception closing process stdin: \$e");
      }

      // Attempt graceful termination first
      bool killed = processToKill.kill(io.ProcessSignal.sigterm);
      if (!killed) {
        print(
          "StdioClientTransport: Failed to send SIGTERM or process already exited.",
        );
        // If SIGTERM fails or wasn't sent (e.g., process already dead),
        // rely on the exitCode future completing.
      } else {
        // Give a short grace period for SIGTERM before SIGKILL
        try {
          await _exitCompleter.future.timeout(const Duration(seconds: 2));
          print(
            "StdioClientTransport: Process terminated gracefully after SIGTERM.",
          );
        } on TimeoutException {
          print(
            "StdioClientTransport: Process did not exit after SIGTERM, sending SIGKILL.",
          );
          try {
            // Attempt to kill again, ignore error if already exited
            processToKill.kill(io.ProcessSignal.sigkill);
          } catch (e) {
            print(
              "StdioClientTransport: Error sending SIGKILL (process likely already exited): \$e",
            );
          }
        } catch (e) {
          // Error waiting for exit after SIGTERM (might have exited quickly)
          print(
            "StdioClientTransport: Error waiting for process exit after SIGTERM: \$e",
          );
          // Ensure SIGKILL if waiting failed unexpectedly
          try {
            processToKill.kill(io.ProcessSignal.sigkill);
          } catch (killErr) {
            print(
              "StdioClientTransport: Error sending SIGKILL after wait error: \$killErr",
            );
          }
        }
      }
    } else {
      print("StdioClientTransport: Process was already null during cleanup.");
    }

    // Ensure exit completer is finished if not already
    if (!_exitCompleter.isCompleted) {
      print("StdioClientTransport: Completing exit completer during cleanup.");
      _exitCompleter.complete();
    }

    // Invoke the onclose callback
    _reportClose(); // Use helper

    print("StdioClientTransport: Transport closed.");

    // Resetting _isCleaningUp can be complex. Generally safer to leave it true
    // after the first successful cleanup, unless restart logic is needed.
    // If cleanup needs to be retryable, reset it here:
    // _isCleaningUp = false;

    // Return the completer's future
    return _exitCompleter.future;
  }

  /// Sends a [JsonRpcMessage] to the server process via its stdin.
  ///
  /// Serializes the message to JSON with a newline and writes it to the
  /// process's stdin stream. Throws [StateError] if the transport is not started
  /// or the process is not running or stdin is unavailable.
  @override
  Future<void> send(JsonRpcMessage message) async {
    final currentProcess = _process; // Capture locally
    final currentStdin = currentProcess?.stdin; // Capture stdin locally

    // Check if started, process exists, and stdin is available
    if (!_started || currentProcess == null || currentStdin == null) {
      final errorMsg =
          "StdioClientTransport cannot send: Not started, process is null, or stdin is unavailable.";
      print(errorMsg);
      // Don't throw if cleaning up, just log and return
      if (_isCleaningUp) {
        print("StdioClientTransport: Attempted send during cleanup, ignoring.");
        return;
      }
      throw StateError(errorMsg);
    }

    try {
      final jsonString = serializeMessage(message);
      // Use kDebugMode or a logging framework for conditional printing
      // if (kDebugMode) {
      //   print('StdioClientTransport SEND: \$jsonString');
      // }
      currentStdin.write(
        jsonString,
      ); // Use write, serializeMessage adds newline
      await currentStdin.flush(); // Ensure data is sent
    } catch (error, stackTrace) {
      // Check if we are already cleaning up to avoid redundant actions/errors
      if (_isCleaningUp) {
        print(
          "StdioClientTransport: Write error occurred during cleanup: \$error",
        );
        // Don't re-throw or re-cleanup if already cleaning up
        return;
      }
      print("StdioClientTransport: Error writing to process stdin: \$error");
      final Error sendError = (error is Error)
          ? error
              : StateError("Process stdin write error: \$error\n\$stackTrace");

      _reportError(sendError); // Use helper

      // Initiate cleanup if write fails, as the connection is likely broken
      unawaited(
        close(),
      ); // Use unawaited as cleanup is async but we don't need its result here

      throw sendError; // Rethrow after initiating cleanup
    }
  }

  // --- MOVE HELPER METHODS INSIDE THE CLASS ---

  // Helper to safely call onerror
  void _reportError(Error error) {
    // Avoid reporting non-critical errors during cleanup? Optional.
    // if (_isCleaningUp) return;
    try {
      onerror?.call(error); // Now accesses the instance member
    } catch (e, s) {
      print("StdioClientTransport: Error in onerror handler: \$e\n\$s");
    }
  }

  // Helper to safely call onclose
  void _reportClose() {
    try {
      onclose?.call(); // Now accesses the instance member
    } catch (e, s) {
      print("StdioClientTransport: Error in onclose handler: \$e\n\$s");
    }
  }
  // --- END MOVED HELPER METHODS ---
} // End of StdioClientTransport class
