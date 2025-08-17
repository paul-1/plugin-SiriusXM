package Plugins::SiriusXM::TrackDurationDB;

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::OSDetect;
use DBI;
use File::Spec::Functions qw(catdir);

my $log = logger('plugin.siriusxm.trackdb');
my $prefs = preferences('plugin.siriusxm');

my $dbh;

# Initialize the database
sub init {
    my $class = shift;
    
    # Get the LMS cache directory for database storage
    my $cacheDir = Slim::Utils::OSDetect::dirsFor('cache');
    my $dbFile = catdir($cacheDir, 'siriusxm_durations.db');
    
    # Ensure directory exists
    my $dbDir = (File::Spec->splitpath($dbFile))[1];
    if (!-d $dbDir) {
        eval { 
            require File::Path;
            File::Path::make_path($dbDir);
        };
        if ($@) {
            $log->error("Failed to create cache directory $dbDir: $@");
            return;
        }
    }
    
    eval {
        $dbh = DBI->connect("dbi:SQLite:dbname=$dbFile", "", "", {
            RaiseError => 1,
            AutoCommit => 1,
            sqlite_unicode => 1,
        });
        
        # Create table if it doesn't exist
        $dbh->do(q{
            CREATE TABLE IF NOT EXISTS track_durations (
                xmplaylist_id TEXT PRIMARY KEY,
                title TEXT,
                artist TEXT,
                duration_seconds INTEGER,
                musicbrainz_score INTEGER,
                created_at INTEGER,
                updated_at INTEGER
            )
        });
        
        # Create index for faster lookups
        $dbh->do(q{
            CREATE INDEX IF NOT EXISTS idx_track_lookup 
            ON track_durations(title, artist)
        });
        
        $log->info("Track duration database initialized: $dbFile");
    };
    
    if ($@) {
        $log->error("Failed to initialize track duration database: $@");
        $dbh = undef;
    }
}

# Get duration for a track by xmplaylist ID
sub getDuration {
    my ($class, $xmplaylist_id) = @_;
    
    return unless $dbh && $xmplaylist_id;
    
    eval {
        my $sth = $dbh->prepare("SELECT duration_seconds FROM track_durations WHERE xmplaylist_id = ?");
        $sth->execute($xmplaylist_id);
        my ($duration) = $sth->fetchrow_array();
        $sth->finish();
        
        if (defined $duration) {
            $log->debug("Found cached duration for $xmplaylist_id: ${duration}s");
            return $duration;
        }
    };
    
    if ($@) {
        $log->warn("Database error getting duration for $xmplaylist_id: $@");
    }
    
    return;
}

# Store duration for a track
sub storeDuration {
    my ($class, $xmplaylist_id, $title, $artist, $duration_seconds, $musicbrainz_score) = @_;
    
    return unless $dbh && $xmplaylist_id && defined $duration_seconds;
    
    my $now = time();
    
    eval {
        my $sth = $dbh->prepare(q{
            INSERT OR REPLACE INTO track_durations 
            (xmplaylist_id, title, artist, duration_seconds, musicbrainz_score, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        });
        
        $sth->execute($xmplaylist_id, $title, $artist, $duration_seconds, $musicbrainz_score, $now, $now);
        $sth->finish();
        
        $log->debug("Stored duration for $xmplaylist_id ($title by $artist): ${duration_seconds}s");
    };
    
    if ($@) {
        $log->warn("Database error storing duration for $xmplaylist_id: $@");
    }
}

# Check if we have a duration for a track (by title/artist if ID not available)
sub findDurationByTrack {
    my ($class, $title, $artist) = @_;
    
    return unless $dbh && $title && $artist;
    
    eval {
        my $sth = $dbh->prepare(q{
            SELECT duration_seconds FROM track_durations 
            WHERE LOWER(title) = LOWER(?) AND LOWER(artist) = LOWER(?)
            ORDER BY updated_at DESC LIMIT 1
        });
        $sth->execute($title, $artist);
        my ($duration) = $sth->fetchrow_array();
        $sth->finish();
        
        if (defined $duration) {
            $log->debug("Found cached duration by track lookup ($title by $artist): ${duration}s");
            return $duration;
        }
    };
    
    if ($@) {
        $log->warn("Database error finding duration by track: $@");
    }
    
    return;
}

# Clean up old entries (optional maintenance)
sub cleanup {
    my ($class, $days_old) = @_;
    
    return unless $dbh;
    
    $days_old ||= 90; # Default to 90 days
    my $cutoff = time() - ($days_old * 24 * 60 * 60);
    
    eval {
        my $sth = $dbh->prepare("DELETE FROM track_durations WHERE created_at < ?");
        my $rows = $sth->execute($cutoff);
        $sth->finish();
        
        $log->info("Cleaned up $rows old duration entries (older than $days_old days)");
    };
    
    if ($@) {
        $log->warn("Database error during cleanup: $@");
    }
}

# Close database connection
sub shutdown {
    my $class = shift;
    
    if ($dbh) {
        $dbh->disconnect();
        $dbh = undef;
        $log->debug("Track duration database connection closed");
    }
}

1;