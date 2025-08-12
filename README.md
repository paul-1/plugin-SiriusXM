# SiriusXM Plugin for Lyrion Media Server

A plugin for streaming SiriusXM satellite radio through Lyrion Media Server using the SiriusXM-Perl helper application.

## Requirements

- Lyrion Media Server 8.3 or higher
- SiriusXM subscription
- PlayHLS v1.1 (With ffmpeg install in the OS)
- SiriusXM Proxy Server (Included from https://github.com/paul-1/SiriusXM-Perl)

## Installation

1. Download the plugin from the Lyrion Media Server plugin repository or install manually
2. Add https://github.com/paul-1/plugin-SiriusXM/releases/latest/download/repo.xml at the bottom of the plugin manager.
3. Configure your SiriusXM credentials in the plugin settings

### Plugin Settings

Access the plugin settings through:
1. Lyrion Media Server web interface
2. Settings → Plugins → SiriusXM

Configure the following:
- **Username**: Your SiriusXM username or email address
- **Password**: Your SiriusXM account password
- **Port**: The system port to use for the Proxy (default:9999)
- **Audio Quality**: Select preferred streaming quality (Low/Medium/High)
- **Region**: United States or Canada (Default:US)
- **Metadata**: This is polled from a 3rd party un-official SXM track information site. Data often lags playback.

## Usage

Once configured:
1. The SiriusXM service will appear in your music sources
2. Browse available channels and content
3. Select channels to start streaming

## Features

- Stream live SiriusXM channels
- Browse channel categories and favorites
- Integration with Lyrion Media Server interface

## Troubleshooting

### Common Issues

**"Login failed"**
- Check your SiriusXM username and password
- Verify your SiriusXM subscription is active
- Ensure the helper application can connect to SiriusXM servers

**"No channels available"**
- Restart the plugin or Lyrion Media Server
- Check network connectivity
- Verify SiriusXM subscription includes streaming access
- Check <lyrion log directory>/sxmproxy.log (You may need to increase the log level of the proxy on the plugin settings page.

**"No Audio"**
- Verify PlayHLS v1.1 is properly installed
- Verify FFMpeg is installed in the host os.

## Support

For issues and support:
- Check the [GitHub Issues](https://github.com/paul-1/plugin-SiriusXM/issues)
- Review the plugin logs in Lyrion Media Server
- Verify the SiriusXM-Perl helper application is working independently

## License

This project is licensed under the GPL-2.0 License - see the repository for details.

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.
