# SiriusXM Plugin for Lyrion Music Server

Always reference these instructions first and fallback to search or bash commands only when you encounter unexpected information that does not match the info here.

This is a Lyrion Music Server (LMS) plugin for streaming SiriusXM satellite radio, written in Perl with a proxy server component. The plugin integrates with LMS to provide SiriusXM channel browsing and streaming capabilities.

## Working Effectively

### Essential Setup Commands
Run these commands in sequence - NEVER CANCEL any of them:

```bash
# Install system dependencies - takes 8-15 seconds
sudo apt-get update  # NEVER CANCEL: Takes 8-15 seconds
sudo apt-get install -y libxml2-utils perl # NEVER CANCEL: Takes 12-15 seconds

# Clone LMS server for testing - takes 15 seconds  
export LMSROOT="$(pwd)/lms-server"
git clone --depth 1 --branch public/9.0 https://github.com/LMS-Community/slimserver.git $LMSROOT  # NEVER CANCEL: Takes 15 seconds

```

### Validation Suite - Run Before Any Changes
Execute the complete validation suite - NEVER CANCEL this process:

```bash
# Complete validation takes 30 seconds - NEVER CANCEL
time bash -c '
echo "=== PLUGIN VALIDATION SUITE ==="

# 1. XML validation (< 1 second)
xmllint --noout Plugins/SiriusXM/install.xml || exit 1
xmllint --noout repo.xml || exit 1
echo "✓ XML validation passed"

# 2. Plugin structure validation (< 1 second)
perl -e "
use strict; use warnings;
use lib \"lms-server\"; use lib \"lms-server/CPAN\";
my @modules = glob(\"Plugins/SiriusXM/*.pm\");
foreach my \$module (@modules) {
    open(my \$fh, \"<\", \$module) or die \"Cannot open \$module: \$!\";
    my \$content = do { local $/; <\$fh> }; close(\$fh);
    if (\$content =~ /^package\\s+Plugins::SiriusXM::\\w+;/m) {
        print \"✓ \$module has proper package declaration\\n\";
    } else { die \"✗ \$module missing proper package declaration\\n\"; }
    if (\$content =~ /use strict;/ && \$content =~ /use warnings;/) {
        print \"✓ \$module has strict and warnings\\n\";
    } else { die \"✗ \$module missing strict/warnings pragmas\\n\"; }
}
print \"All modules passed structure validation\\n\";
" || exit 1

# 3. Directory structure validation (< 1 second)
test -d Plugins/SiriusXM || exit 1
test -d Plugins/SiriusXM/HTML/EN/plugins/SiriusXM/settings || exit 1
test -d .github/workflows || exit 1
test -f Plugins/SiriusXM/install.xml || exit 1
test -f repo.xml || exit 1
test -f Plugins/SiriusXM/strings.txt || exit 1
test -f README.md || exit 1
test -f .gitignore || exit 1
test -f Plugins/SiriusXM/Plugin.pm || exit 1
test -f Plugins/SiriusXM/API.pm || exit 1
test -f Plugins/SiriusXM/Settings.pm || exit 1
test -f Plugins/SiriusXM/HTML/EN/plugins/SiriusXM/settings/basic.html || exit 1
echo "✓ Directory structure validation passed"

# 4. Strings file validation (< 1 second)
grep -q "PLUGIN_SIRIUSXM" Plugins/SiriusXM/strings.txt || exit 1
grep -q "EN" Plugins/SiriusXM/strings.txt || exit 1
echo "✓ Strings file validation passed"

# 5. HTML template validation (< 1 second)
grep -q "PLUGIN_SIRIUSXM" Plugins/SiriusXM/HTML/EN/plugins/SiriusXM/settings/basic.html || exit 1
grep -q "pref_username" Plugins/SiriusXM/HTML/EN/plugins/SiriusXM/settings/basic.html || exit 1
grep -q "pref_password" Plugins/SiriusXM/HTML/EN/plugins/SiriusXM/settings/basic.html || exit 1
grep -q "pref_port" Plugins/SiriusXM/HTML/EN/plugins/SiriusXM/settings/basic.html || exit 1
grep -q "pref_quality" Plugins/SiriusXM/HTML/EN/plugins/SiriusXM/settings/basic.html || exit 1
echo "✓ HTML template validation passed"

# 6. Menu system validation (< 1 second)
grep -q "toplevelMenu" Plugins/SiriusXM/Plugin.pm || exit 1
grep -q "validateHLSSupport" Plugins/SiriusXM/Plugin.pm || exit 1
grep -q "searchMenu" Plugins/SiriusXM/Plugin.pm || exit 1
grep -q "browseByGenre" Plugins/SiriusXM/Plugin.pm || exit 1
echo "✓ Menu system validation passed"

echo "=== ALL VALIDATION COMPLETE ==="
'

# 7. Test SXM Proxy
perl -I$LMSROOT Plugins/SiriusXM/Bin/sxm.pl --lmsroot $LMSROOT d_startup --help 2>&1 | tee output.txt
grep -q "Show this help message" || exit 1
echo "✓ SXM Proxy start validation passed"

```

### Plugin Packaging
To create a plugin package for distribution:

```bash
# Create plugin package - takes 1-2 seconds
mkdir -p /tmp/plugin-package/package
cp -r Plugins/SiriusXM /tmp/plugin-package/package/
cd /tmp/plugin-package/package
zip -r ../SiriusXM-$(date +%Y%m%d).zip SiriusXM/
cd -
ls -la /tmp/plugin-package/SiriusXM-*.zip
```

## Validation

### Automatic Validation (CI/CD)
- **NEVER CANCEL CI builds**: GitHub Actions test suite completes in 60-90 seconds
- CI runs complete validation including LMS server module testing
- All XML files are validated with xmllint
- Perl modules are tested for proper package declarations and pragmas
- Directory structure, strings files, and HTML templates are validated
- Menu system functions are verified

### Manual Validation Requirements
- **ALWAYS run the validation suite before committing changes**
- **ALWAYS validate XML files after editing install.xml or repo.xml**
- **DO NOT skip plugin structure validation** - it catches critical errors
- Test plugin packaging after significant changes
- Verify all required files exist in correct locations

### JSON::XS and Module Testing
The PERL5LIB environment setup works correctly for structural validation, but has known limitations:

**Expected JSON::XS Version Conflict**
```bash
# Test JSON::XS functionality - version conflict is expected
export PERL5LIB=$(pwd)/lms-server/CPAN/arch:$(pwd)/lms-server:$(pwd)/lms-server/CPAN:$PERL5LIB
perl -e "use JSON::XS; print 'Version: ' . $JSON::XS::VERSION"
# Error: version 4.03 does not match bootstrap parameter 2.3
# This is expected in test environments and doesn't affect plugin functionality
```

**Alternative JSON Testing**
```bash 
# Use JSON::PP for JSON functionality testing in development
perl -e "use JSON::PP; my $json = JSON::PP->new(); print 'JSON::PP works: ' . $json->encode({test => 'OK'})"
```

**Module Validation Limitations**
- Individual plugin modules cannot be syntax-checked due to missing runtime dependencies
- Use the validation suite for structural checking instead of `perl -c` 
- Log::Log4perl::Logger and Audio::Scan modules are only available in full LMS runtime
- Focus on package declaration and pragma validation rather than syntax compilation

### Plugin Structure Validation  
- All .pm files must have proper `package Plugins::SiriusXM::ClassName;` declarations
- All modules must include `use strict;` and `use warnings;` pragmas
- HTML templates must contain required preference elements
- Strings file must follow LMS format with PLUGIN_SIRIUSXM tokens

## Common Tasks

### Repository Structure
```
.
├── .github/workflows/          # CI/CD automation
│   ├── release.yml            # Automated releases and packaging
│   └── test.yml               # Comprehensive test suite
├── Plugins/SiriusXM/          # Main plugin directory
│   ├── Plugin.pm              # Main plugin entry point 
│   ├── API.pm                 # SiriusXM API integration
│   ├── Settings.pm            # Plugin settings management
│   ├── ProtocolHandler.pm     # Stream protocol handling
│   ├── install.xml            # Plugin metadata for LMS
│   ├── strings.txt            # Internationalization strings
│   ├── Bin/                   # Proxy server components
│   │   ├── sxm.pl            # SiriusXM proxy server (Perl)
│   │   └── lib/              # Bundled Perl modules
│   └── HTML/EN/plugins/SiriusXM/  # Web interface templates
│       └── settings/basic.html    # Settings page template
├── repo.xml                   # Plugin repository configuration
└── README.md                  # Documentation
```

### Key Files and Their Purpose
- **`Plugins/SiriusXM/Plugin.pm`**: Main plugin class, contains menu system (`toplevelMenu`, `searchMenu`, `browseByGenre`), HLS validation (`validateHLSSupport`)
- **`Plugins/SiriusXM/API.pm`**: SiriusXM service API integration and channel data handling
- **`Plugins/SiriusXM/Settings.pm`**: Plugin preferences and configuration management  
- **`Plugins/SiriusXM/ProtocolHandler.pm`**: Handles SiriusXM stream URLs and protocol, also handles metadata for music
- **`Plugins/SiriusXM/Bin/sxm.pl`**: Standalone proxy server for SiriusXM streams (uses LMS logging system via Slim::Utils::Log)
- **`install.xml`**: Plugin metadata - version, description, LMS compatibility  
- **`repo.xml`**: Repository configuration for plugin distribution
- **`basic.html`**: Settings page template with user preferences form

### Working with Plugin Code
- **PERL5LIB environment setup works correctly**: The configured paths provide access to LMS modules for structural validation
- **JSON::XS version conflicts are expected**: System version (4.03) conflicts with LMS bundled version (2.3) in test environments - this is normal and doesn't affect plugin functionality in LMS runtime
- **Plugin modules require LMS runtime dependencies**: Individual syntax checking fails due to missing Log::Log4perl::Logger, Audio::Scan, etc. - use the validation suite instead
- **Proxy server (sxm.pl) uses LMS logging**: Now uses Slim::Utils::Log with 'plugin.siriusxm.proxy' category instead of bundled Log4perl
- **No bundled modules**: lib directory removed - all dependencies provided by LMS runtime
- **Validation suite provides comprehensive testing**: Focuses on structural validation (package declarations, pragmas, file structure) rather than runtime dependencies

### Making Changes
- **ALWAYS backup important files before major changes**
- **Update version numbers in both install.xml and repo.xml for releases**
- **Test HTML templates by validating required form elements exist**
- **Update strings.txt when adding new user-facing text**
- **Run packaging test after modifying file structure**

### Troubleshooting
- **XML validation errors**: Use `xmllint --noout <file>` to check for malformed XML
- **Plugin structure issues**: Run the structure validation to identify missing package declarations
- **Missing files**: Use directory structure validation to ensure all required files exist
- **HTML template problems**: Check that all preference elements (`pref_username`, `pref_password`, etc.) exist
- **JSON::XS version conflicts**: Expected in test environments - use JSON::PP for development testing
- **Module syntax check failures**: Individual plugin modules require full LMS runtime - use validation suite instead
- **Proxy logging issues**: sxm.pl now uses LMS logging system - ensure PERL5LIB includes LMS paths
- **Packaging issues**: Test with the packaging commands to identify missing or extra files

### Development Workflow
1. **Set up environment**: Run essential setup commands
2. **Run validation suite**: Ensure current state is valid
3. **Make minimal changes**: Focus on specific functionality
4. **Re-run validation**: Verify changes don't break anything
5. **Test packaging**: Ensure plugin can be properly packaged
6. **Commit changes**: Use descriptive commit messages

### Time Expectations
- **Environment setup**: 30-45 seconds total
- **Full validation suite**: 30 seconds - NEVER CANCEL
- **Plugin packaging**: 1-2 seconds
- **CI/CD pipeline**: 60-90 seconds - NEVER CANCEL

### Network and Dependency Notes
- **cpanm network access is blocked**: Use pre-installed system packages instead
- **LMS server modules required for testing**: Clone LMS repository as shown in setup
- **JSON::XS version conflicts exist**: System version 4.03 vs LMS version 2.3 - use JSON::PP for testing
- **Runtime dependencies unavailable**: Log::Log4perl::Logger, Audio::Scan only available in full LMS installation
- **Proxy server now uses LMS logging**: sxm.pl uses Slim::Utils::Log instead of bundled Log4perl modules
- **No bundled Perl modules**: lib directory removed - LMS provides all needed modules
- **Validation focuses on structure**: Package declarations, pragmas, file structure rather than runtime compilation

Always prioritize the validation commands shown above over ad-hoc testing, as they provide comprehensive coverage without requiring a full LMS installation.
