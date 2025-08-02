# SiriusXM Plugin for Logitech Media Server

A plugin for streaming SiriusXM satellite radio through Logitech Media Server using the SiriusXM-Perl helper application.

## Requirements

- Logitech Media Server 8.3 or higher
- SiriusXM subscription
- PlayHLS v1.1 (With ffmpeg)
- SiriusXM Proxy Server (Included from https://github.com/paul-1/SiriusXM-Perl)

## Installation

1. Download the plugin from the Logitech Media Server plugin repository or install manually
2. Install and configure the SiriusXM-Perl helper application
3. Configure your SiriusXM credentials in the plugin settings

## Configuration

### Plugin Settings

Access the plugin settings through:
1. Logitech Media Server web interface
2. Settings → Plugins → SiriusXM

Configure the following:
- **Username**: Your SiriusXM username or email address
- **Password**: Your SiriusXM account password
- **Port**: The system port to use for the Proxy (default:9999)
- **Audio Quality**: Select preferred streaming quality (Low/Medium/High)
- **Region**: United States or Canada (Default:US)

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

**"Login failed"**
- Check your SiriusXM username and password
- Verify your SiriusXM subscription is active
- Ensure the helper application can connect to SiriusXM servers

**"No channels available"**
- Restart the plugin or Logitech Media Server
- Check network connectivity
- Verify SiriusXM subscription includes streaming access
- Verify PlayHLS v1.1 is properly installed

## Support

For issues and support:
- Check the [GitHub Issues](https://github.com/paul-1/plugin-SiriusXM/issues)
- Review the plugin logs in Logitech Media Server
- Verify the SiriusXM-Perl helper application is working independently

## License

This project is licensed under the GPL-2.0 License - see the repository for details.

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.
