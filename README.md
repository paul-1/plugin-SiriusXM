# SiriusXM Plugin for Logitech Media Server

A plugin for streaming SiriusXM satellite radio through Logitech Media Server using the SiriusXM-Perl helper application.

## Requirements

- Logitech Media Server 7.9 or higher
- SiriusXM subscription
- SiriusXM-Perl helper application (separate installation required)

## Installation

1. Download the plugin from the Logitech Media Server plugin repository or install manually
2. Install and configure the SiriusXM-Perl helper application
3. Configure your SiriusXM credentials in the plugin settings
4. Set the path to the SiriusXM-Perl helper application in settings
5. Restart Logitech Media Server

## Configuration

### Plugin Settings

Access the plugin settings through:
1. Logitech Media Server web interface
2. Settings → Plugins → SiriusXM

Configure the following:
- **Username**: Your SiriusXM username or email address
- **Password**: Your SiriusXM account password
- **Audio Quality**: Select preferred streaming quality (Low/Medium/High)
- **Helper Application Path**: Full path to the SiriusXM-Perl helper executable

### SiriusXM-Perl Helper

This plugin requires the separate SiriusXM-Perl helper application for authentication and streaming. 

Download and install from: [SiriusXM-Perl Repository](https://github.com/paul-1/SiriusXM-Perl)

## Usage

Once configured:
1. The SiriusXM service will appear in your music sources
2. Browse available channels and content
3. Select channels to start streaming

## Features

- Stream live SiriusXM channels
- Browse channel categories and favorites
- Multiple audio quality options
- Integration with Logitech Media Server interface

## Troubleshooting

### Common Issues

**"Helper application not found"**
- Verify the helper application path in plugin settings
- Ensure the SiriusXM-Perl helper is properly installed and executable

**"Login failed"**
- Check your SiriusXM username and password
- Verify your SiriusXM subscription is active
- Ensure the helper application can connect to SiriusXM servers

**"No channels available"**
- Restart the plugin or Logitech Media Server
- Check network connectivity
- Verify SiriusXM subscription includes streaming access

## Support

For issues and support:
- Check the [GitHub Issues](https://github.com/paul-1/plugin-SiriusXM/issues)
- Review the plugin logs in Logitech Media Server
- Verify the SiriusXM-Perl helper application is working independently

## License

This project is licensed under the GPL-3.0 License - see the repository for details.

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.