# SiriusXM Plugin Improvements

This document describes the improvements made to the SiriusXM plugin's proxy management and logging system.

## Changes Made

### 1. Process Management Upgrade
- **Replaced**: `Proc::Simple` → `Proc::Background`
- **Benefits**: Better process lifecycle management and signal handling
- **Fallback**: Still supports basic `fork()` if Proc::Background is unavailable

### 2. Enhanced Logging Configuration

#### Log Level Mapping
The plugin now automatically maps LMS log levels to proxy verbosity levels:

| LMS Level | Proxy Level | Description |
|-----------|-------------|-------------|
| FATAL (0) | ERROR       | Critical errors only |
| ERROR (1) | ERROR       | Error messages |
| WARN (2)  | WARN        | Warning messages |
| INFO (3)  | INFO        | General information |
| DEBUG (4) | DEBUG       | Detailed debugging |

#### Log File Redirection
- **Primary**: Proxy output goes to `sxm-proxy.log` in LMS log directory
- **Fallback**: Uses `/tmp/sxm-proxy.log` if LMS log directory is unavailable
- **Auto-creation**: Creates log directories if they don't exist

### 3. Log Rotation Implementation
- **Trigger**: When log file exceeds 10MB
- **Retention**: Keeps up to 5 historical log files
- **Naming**: `sxm-proxy.log.1`, `sxm-proxy.log.2`, etc.
- **Cleanup**: Automatically removes oldest logs when limit is reached

### 4. Improved Process Cleanup
- **Graceful shutdown**: Sends TERM signal first
- **Force kill**: Uses KILL signal if process doesn't respond within 5 seconds
- **Environment cleanup**: Removes SXM_USER and SXM_PASS variables on shutdown

## Technical Implementation

### New Methods Added

#### `getLogLevel()`
Maps current plugin log level to appropriate proxy verbosity setting.

#### `getLogFilePath()`
Determines the correct log file path with multiple fallback options.

#### `rotateLogFile($log_file)`
Handles log rotation when file size exceeds the configured limit.

### Modified Methods

#### `startProxy()`
- Added log level detection and mapping
- Implemented log file redirection via shell commands
- Added log directory safety checks
- Enhanced error handling

#### `stopProxy()`
- Updated for Proc::Background compatibility
- Improved signal handling and timeout management

#### `isProxyRunning()`
- Updated to use Proc::Background's `alive()` method

## Configuration

No additional configuration is required. The improvements work automatically with existing plugin settings:

- **Log level**: Inherits from plugin's current log level setting
- **Log location**: Automatically determined from LMS installation
- **Process management**: Uses best available method (Proc::Background or fork)

## Compatibility

- **Backward compatible**: Works with existing plugin configurations
- **Graceful degradation**: Falls back to basic fork() if Proc::Background unavailable
- **Cross-platform**: Handles different LMS log directory conventions

## Benefits

1. **Better Process Management**: More reliable proxy startup and shutdown
2. **Automated Logging**: No manual log configuration required
3. **Log Rotation**: Prevents log files from consuming excessive disk space
4. **Improved Debugging**: Automatic log level adjustment based on plugin settings
5. **Enhanced Reliability**: Better error handling and fallback mechanisms