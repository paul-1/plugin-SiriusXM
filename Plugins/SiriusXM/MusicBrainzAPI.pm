package Plugins::SiriusXM::MusicBrainzAPI;

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Networking::SimpleAsyncHTTP;
use JSON::XS;
use URI::Escape;

my $log = logger('plugin.siriusxm.musicbrainz');

# MusicBrainz API endpoint
use constant MUSICBRAINZ_URL => 'https://musicbrainz.org/ws/2/recording';

# Minimum score threshold (75%)
use constant MIN_SCORE_THRESHOLD => 75;

# Search for track duration using MusicBrainz API
sub searchTrackDuration {
    my ($class, $title, $artist, $callback) = @_;
    
    return unless $title && $artist && $callback;
    
    # Clean up search terms
    $title = _cleanSearchTerm($title);
    $artist = _cleanSearchTerm($artist);
    
    # Build search query
    my $query = uri_escape("recording:\"$title\" AND artist:\"$artist\"");
    my $url = MUSICBRAINZ_URL . "?query=$query&limit=10&fmt=json";
    
    $log->debug("Searching MusicBrainz for: $title by $artist");
    
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $response = shift;
            $class->_processResponse($title, $artist, $response, $callback);
        },
        sub {
            my ($http, $error) = @_;
            $log->warn("MusicBrainz API error: $error");
            $callback->();
        },
        {
            timeout => 20,
            # User-Agent required by MusicBrainz
            'User-Agent' => 'LMS-SiriusXM-Plugin/1.0 (https://github.com/paul-1/plugin-SiriusXM)',
        }
    );
    
    $http->get($url);
}

# Process MusicBrainz API response
sub _processResponse {
    my ($class, $title, $artist, $response, $callback) = @_;
    
    my $content = $response->content;
    my $data;
    
    eval {
        $data = decode_json($content);
    };
    
    if ($@) {
        $log->warn("Failed to parse MusicBrainz response: $@");
        $callback->();
        return;
    }
    
    my $recordings = $data->{recordings};
    unless ($recordings && @$recordings) {
        $log->debug("No recordings found for: $title by $artist");
        $callback->();
        return;
    }
    
    # Find the best match based on score and release date
    my $best_match;
    my $best_score = 0;
    my $best_release_date;
    
    foreach my $recording (@$recordings) {
        my $score = $recording->{score} || 0;
        
        # Skip if below threshold
        next if $score < MIN_SCORE_THRESHOLD;
        
        # Check if this recording has a duration
        my $length = $recording->{length};
        next unless defined $length;
        
        # Convert milliseconds to seconds
        my $duration_seconds = int($length / 1000);
        next if $duration_seconds <= 0;
        
        # Get earliest release date
        my $release_date = _getEarliestReleaseDate($recording);
        
        # Update best match if score is higher, or if score is equal and this has an older release date
        my $is_better = ($score > $best_score);
        if ($score == $best_score && defined $release_date && defined $best_release_date) {
            $is_better = ($release_date lt $best_release_date);
        } elsif ($score == $best_score && defined $release_date && !defined $best_release_date) {
            $is_better = 1;
        }
        
        if ($is_better) {
            $best_score = $score;
            $best_release_date = $release_date;
            $best_match = {
                duration => $duration_seconds,
                score => $score,
                title => $recording->{title},
                length_ms => $length,
                release_date => $release_date,
            };
        }
    }
    
    if ($best_match) {
        $log->info("Found MusicBrainz match for '$title' by '$artist': " . 
                  $best_match->{duration} . "s (score: $best_score%)");
        
        $callback->($best_match->{duration}, $best_score);
    } else {
        $log->debug("No suitable MusicBrainz matches found for: $title by $artist (threshold: " . MIN_SCORE_THRESHOLD . "%)");
        $callback->();
    }
}

# Clean search terms for better matching
sub _cleanSearchTerm {
    my $term = shift || '';
    
    # Remove common noise
    $term =~ s/\s*\(.*?\)\s*//g;  # Remove parentheses content
    $term =~ s/\s*\[.*?\]\s*//g;  # Remove brackets content
    $term =~ s/\s*feat\.?\s+.*$//i; # Remove featuring
    $term =~ s/\s*ft\.?\s+.*$//i;   # Remove ft.
    $term =~ s/\s*with\s+.*$//i;    # Remove with
    $term =~ s/^\s+|\s+$//g;        # Trim whitespace
    $term =~ s/\s+/ /g;             # Normalize whitespace
    
    return $term;
}

# Get the earliest release date from a recording's releases
sub _getEarliestReleaseDate {
    my $recording = shift;
    
    my $releases = $recording->{releases};
    return unless $releases && @$releases;
    
    my $earliest_date;
    
    foreach my $release (@$releases) {
        my $date = $release->{'first-release-date'} || $release->{date};
        next unless $date;
        
        # Normalize date format (handle partial dates like "1975" or "1975-06")
        if ($date =~ /^(\d{4})(?:-(\d{2}))?(?:-(\d{2}))?/) {
            my ($year, $month, $day) = ($1, $2 || '01', $3 || '01');
            $date = sprintf("%04d-%02d-%02d", $year, $month, $day);
        }
        
        if (!defined $earliest_date || $date lt $earliest_date) {
            $earliest_date = $date;
        }
    }
    
    return $earliest_date;
}

1;